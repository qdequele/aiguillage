import AiguillageCore
import Foundation

/// Answers DNS queries that reach the utun (UDP port 53, any destination).
/// AAAA questions get an empty NOERROR; everything else is raced over the links' own resolvers.
/// Answers for names matching a routing rule teach the rule router their A records.
final class DNSForwarder {
    unowned let engine: Engine
    static let secondDelay = 0.15
    static let graceAfterNegative = 0.4
    static let upstreamTimeout = 3.0
    private(set) var queriesTotal = 0
    private(set) var inFlight = 0

    init(engine: Engine) {
        self.engine = engine
    }

    /// Resolves `query` and calls `reply` at most once (never when every upstream failed).
    func resolve(_ query: [UInt8], reply: @escaping ([UInt8]) -> Void) {
        queriesTotal += 1
        guard let message = DNSMessage(query), !message.isResponse else { return }
        if message.questionType == DNSType.aaaa, let empty = DNS.emptyResponse(to: query) {
            Log.debug("dns \(message.questionName ?? "?") AAAA -> empty (IPv6 disabled)")
            reply(empty)
            return
        }
        let links = engine.links.orderedLinks()
        guard !links.isEmpty else { return }

        var race = DNSRaceState(linkCount: links.count)
        var sent: Set<Int> = []
        let name = message.questionName ?? "?"
        let started = monotonicNow()
        inFlight += 1
        var counted = true

        func done() {
            if counted { inFlight -= 1; counted = false }
            // Outstanding bound DNS sockets self-close on their own timeout.
        }

        func handle(_ decision: DNSRaceState.Decision, from link: Link?) {
            switch decision {
            case .reply(let bytes):
                done()
                Log.debug("dns \(name) answered via \(link?.name ?? "grace") in \(Int((monotonicNow() - started) * 1000))ms")
                learn(name: name, response: bytes)
                reply(bytes)
            case .giveUp:
                done()
                Log.debug("dns \(name): no upstream answered")
            case .wait(let startGrace, let sendRemaining):
                if sendRemaining {
                    for i in links.indices { send(i) }
                }
                if startGrace {
                    engine.queue.asyncAfter(deadline: .now() + DNSForwarder.graceAfterNegative) {
                        handle(race.graceExpired(), from: nil)
                    }
                }
            }
        }

        func send(_ i: Int) {
            guard !race.finished, !sent.contains(i) else { return }
            sent.insert(i)
            let link = links[i]
            let idx = link.ifIndex
            guard idx != 0, let server = link.info.resolvers.first else {
                handle(race.failed(i), from: link)
                return
            }
            dnsQuery(query, server: server, ifIndex: idx, timeout: DNSForwarder.upstreamTimeout,
                     queue: engine.queue) { response in
                if let response {
                    handle(race.received(response, from: i), from: link)
                } else {
                    handle(race.failed(i), from: link)
                }
            }
        }

        send(0)
        if links.count > 1 {
            let delay = links[0].isUp ? DNSForwarder.secondDelay : 0
            engine.queue.asyncAfter(deadline: .now() + delay) { send(1) }
        }
    }

    private func learn(name: String, response: [UInt8]) {
        let records = DNS.aRecordsWithTTL(in: response)
        guard !records.isEmpty else { return }
        if let rule = engine.router.learn(host: name, records: records, now: monotonicNow()) {
            Log.debug("dns \(name): rule \(rule.description) now applies to \(records.map(\.ip.description).joined(separator: ", "))")
        }
    }
}
