import AiguillageCore
import Foundation
import Network

/// The local TCP listener on 198.18.0.1 that receives the redirected app connections, and the
/// relays that carry them over a physical link. Everything runs on the engine queue.
final class TCPRelayServer {
    unowned let engine: Engine
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    private var relays: [ObjectIdentifier: TCPRelay] = [:]

    init(engine: Engine) {
        self.engine = engine
    }

    var activeRelays: [TCPRelay] { Array(relays.values) }

    /// Starts the listener bound to 198.18.0.1 on a kernel-chosen port and waits until it is ready.
    func start() throws -> UInt16 {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        // Bind to the tunnel address only: binding 0.0.0.0 would expose an open relay on the LAN.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address(Data(TunnelAddresses.local.bytes))!), port: .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let e):
                failure = e
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: engine.queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw UtunError("TCP listener did not become ready within 5 s") }
        if let failure { throw UtunError("TCP listener failed: \(failure)") }
        guard let p = listener.port?.rawValue, p != 0 else { throw UtunError("TCP listener has no port") }
        self.listener = listener
        port = p
        return p
    }

    func stop() {
        listener?.cancel()
        relays.values.forEach { $0.close(reset: true) }
    }

    private func accept(_ conn: NWConnection) {
        guard case .hostPort(let host, let peerPort) = conn.endpoint,
              case .ipv4(let addr) = host,
              IPv4(bytes: [UInt8](addr.rawValue), at: 0) == TunnelAddresses.peer else {
            Log.warn("tcp: rejecting unexpected connection from \(conn.endpoint)")
            conn.forceCancel()
            return
        }
        let natPort = peerPort.rawValue
        guard let entry = engine.withNat({ $0.markAccepted(natPort: natPort) }) else {
            Log.debug("tcp: no nat entry for port \(natPort)")
            conn.forceCancel()
            return
        }
        let relay = TCPRelay(server: self, inbound: conn, key: entry.key, natPort: natPort)
        relays[ObjectIdentifier(relay)] = relay
        relay.start()
    }

    func remove(_ relay: TCPRelay) {
        relays[ObjectIdentifier(relay)] = nil
    }

    /// Resets every relay carried by `link` so apps reconnect at once (on the other link).
    func cancelRelays(onLink name: String) {
        let victims = relays.values.filter { $0.winnerLink?.name == name }
        if !victims.isEmpty {
            Log.info("tcp: resetting \(victims.count) connection(s) on \(name)")
        }
        victims.forEach { $0.close(reset: true) }
    }
}

final class TCPRelay {
    unowned let server: TCPRelayServer
    let inbound: NWConnection
    let key: FlowKey
    let natPort: UInt16
    let openedAt = monotonicNow()
    private(set) var decision: RouteDecision?
    private(set) var winnerLink: Link?
    private var winnerConn: BoundTCPConnection?
    private var candidates: [Link] = []
    private var attempts: [Int: (conn: BoundTCPConnection, startedAt: Double)] = [:]
    private var started: Set<Int> = []
    private var closed = false
    private var upstreamDone = false   // app -> server direction finished
    private var downstreamDone = false // server -> app direction finished

    private var engine: Engine { server.engine }

    init(server: TCPRelayServer, inbound: NWConnection, key: FlowKey, natPort: UInt16) {
        self.server = server
        self.inbound = inbound
        self.key = key
        self.natPort = natPort
    }

    var isDNS: Bool { key.dstIP == TunnelAddresses.peer && key.dstPort == 53 }

    func start() {
        inbound.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .waiting:
                self?.close(reset: true)
            default:
                break
            }
        }
        inbound.start(queue: engine.queue)

        decision = isDNS ? nil : engine.router.decision(for: key.dstIP, now: monotonicNow())
        let (plan, links) = engine.links.plan(policy: decision?.policy, mode: engine.mode)
        if plan.blocked {
            Log.info("tcp \(key.dstIP):\(key.dstPort): blocked by rule \(decision!.label)")
            close(reset: true)
            return
        }
        if let note = plan.note, let d = decision {
            Log.info("tcp \(key.dstIP):\(key.dstPort) rule \(d.label): \(note)")
        }
        candidates = links
        guard !candidates.isEmpty else {
            Log.debug("tcp \(key): no usable link")
            close(reset: true)
            return
        }
        startAttempt(0)
        guard candidates.count > 1 else { return }
        switch plan.mode {
        case .race:
            let delay = engine.links.stagger(first: candidates[0])
            engine.queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.startAttempt(1) }
        case .failover:
            engine.queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, self.winnerConn == nil, self.attempts[0] != nil else { return }
                Log.debug("tcp \(self.key): \(self.candidates[0].name) attempt timed out, failing over")
                self.attemptFailed(0)
            }
        }
    }

    /// The real outbound endpoint: for the DNS special case, the chosen link's upstream resolver.
    private func target(on link: Link) -> IPv4? {
        isDNS ? link.info.resolvers.first : key.dstIP
    }

    private var targetPort: UInt16 { isDNS ? 53 : key.dstPort }

    private func startAttempt(_ i: Int) {
        guard !closed, winnerConn == nil, i < candidates.count, !started.contains(i) else { return }
        started.insert(i)
        let link = candidates[i]
        let idx = link.ifIndex
        guard idx != 0, let ip = target(on: link) else {
            attemptFailed(i)
            return
        }
        Log.debug("tcp \(key): trying \(link.name)")
        // The connect timeout is 1 s in failover (quick fall-through) else the race default.
        let conn = BoundTCPConnection.start(to: ip, port: targetPort, ifIndex: idx, timeout: 10,
                                            queue: engine.queue) { [weak self] error in
            guard let self else { return }
            if let error {
                if self.attempts[i] != nil {
                    Log.debug("tcp \(self.key): \(link.name) failed: \(error)")
                    self.attemptFailed(i)
                }
            } else {
                self.won(i)
            }
        }
        guard let conn else { return } // start() already reported the failure via the handler
        attempts[i] = (conn, monotonicNow())
    }

    private func attemptFailed(_ i: Int) {
        guard let a = attempts.removeValue(forKey: i) else {
            if attempts.isEmpty && started.count >= candidates.count && winnerConn == nil { close(reset: true) }
            return
        }
        a.conn.close()
        engine.links.recordConnect(on: candidates[i].name, success: false)
        if winnerConn != nil || closed { return }
        if i + 1 < candidates.count && !started.contains(i + 1) {
            startAttempt(i + 1)
        } else if attempts.isEmpty {
            Log.debug("tcp \(key): all links failed")
            close(reset: true)
        }
    }

    private func won(_ i: Int) {
        guard winnerConn == nil, !closed, let a = attempts.removeValue(forKey: i) else { return }
        let link = candidates[i]
        winnerConn = a.conn
        winnerLink = link
        link.activeTCP += 1
        engine.links.recordConnect(on: link.name, success: true)
        // Cancel the losers. A loser that had been trying for a while counts as a failure.
        for (j, other) in attempts {
            other.conn.close()
            if monotonicNow() - other.startedAt >= Prober.timeout {
                engine.links.recordConnect(on: candidates[j].name, success: false)
            }
        }
        attempts.removeAll()
        let rule = decision.map { " rule \($0.label)" } ?? ""
        Log.debug("tcp \(key) via \(link.name)\(rule) (\(Int((monotonicNow() - openedAt) * 1000))ms)")
        pumpInboundToOutbound(a.conn)
        pumpOutboundToInbound(a.conn)
    }

    /// App -> server. Reads from the inbound NWConnection, writes to the bound socket; FIN becomes
    /// a write shutdown. Backpressure: the next receive waits for the send to complete.
    private func pumpInboundToOutbound(_ out: BoundTCPConnection) {
        inbound.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.winnerLink?.bytesUp += UInt64(data.count)
                out.send(data) { [weak self] err in
                    guard let self, !self.closed else { return }
                    if err != nil {
                        self.close(reset: true)
                    } else if isComplete {
                        out.shutdownWrite()
                        self.directionFinished(upstream: true)
                    } else {
                        self.pumpInboundToOutbound(out)
                    }
                }
            } else if isComplete {
                out.shutdownWrite()
                self.directionFinished(upstream: true)
            } else if error != nil {
                self.close(reset: true)
            } else {
                self.pumpInboundToOutbound(out)
            }
        }
    }

    /// Server -> app. Reads from the bound socket, writes to the inbound NWConnection; EOF becomes
    /// a final message (FIN) to the app.
    private func pumpOutboundToInbound(_ out: BoundTCPConnection) {
        out.receive(max: 65536) { [weak self] data, isEOF in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.winnerLink?.bytesDown += UInt64(data.count)
                self.inbound.send(content: data, completion: .contentProcessed { [weak self] err in
                    guard let self, !self.closed else { return }
                    if err != nil {
                        self.close(reset: true)
                    } else if isEOF {
                        self.sendInboundFIN()
                        self.directionFinished(upstream: false)
                    } else {
                        self.pumpOutboundToInbound(out)
                    }
                })
            } else if isEOF {
                self.sendInboundFIN()
                self.directionFinished(upstream: false)
            } else {
                self.close(reset: true) // read error
            }
        }
    }

    private func sendInboundFIN() {
        inbound.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func directionFinished(upstream: Bool) {
        if upstream { upstreamDone = true } else { downstreamDone = true }
        if upstreamDone && downstreamDone {
            close(reset: false)
        }
    }

    /// Tears down both sides. `reset` aborts (RST) instead of closing gracefully.
    func close(reset: Bool) {
        guard !closed else { return }
        closed = true
        for a in attempts.values { a.conn.close() }
        attempts.removeAll()
        winnerConn?.close()
        if reset { inbound.forceCancel() } else { inbound.cancel() }
        if let link = winnerLink { link.activeTCP -= 1 }
        let port = natPort
        let now = monotonicNow()
        engine.withNat { $0.markClosed(natPort: port, now: now) }
        server.remove(self)
    }
}
