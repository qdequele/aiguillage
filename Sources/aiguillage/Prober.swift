import AiguillageCore
import Foundation

/// Sends one DNS query over a UDP socket bound to `ifIndex` to `server:53` and returns the first
/// response datagram (or nil on timeout/error). `completion` is called exactly once on `queue`.
func dnsQuery(_ query: [UInt8], server: IPv4, ifIndex: UInt32, timeout: Double,
              queue: DispatchQueue, completion: @escaping ([UInt8]?) -> Void) {
    let sock: BoundUDPSocket
    do {
        sock = try BoundUDPSocket.connected(to: server, port: 53, ifIndex: ifIndex, queue: queue)
    } catch {
        completion(nil)
        return
    }
    var done = false
    func finish(_ r: [UInt8]?) {
        guard !done else { return }
        done = true
        sock.close()
        completion(r)
    }
    sock.receiveLoop { data in finish([UInt8](data)) }
    sock.send(Data(query))
    queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
}

/// Captive-portal probe pinned to one link: resolves captive.apple.com through the link's own
/// resolver (bound to the link, not the system resolver which points at us), then does a plain
/// HTTP GET and expects Apple's "Success" page.
final class Prober {
    static let host = "captive.apple.com"
    static let timeout = 1.5

    private let queue: DispatchQueue
    /// Last address that produced an `up` result, per link name, to save a DNS round-trip.
    private var cachedAddress: [String: (ip: IPv4, at: Double)] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Calls `completion` exactly once on `queue`.
    func probe(link: LinkInfo, ifIndex: UInt32, completion: @escaping (ProbeResult, String) -> Void) {
        let deadline = monotonicNow() + Prober.timeout
        var done = false
        var tcp: BoundTCPConnection?
        func finish(_ r: ProbeResult, _ detail: String) {
            guard !done else { return }
            done = true
            tcp?.close()
            if case .success = r {} else { self.cachedAddress[link.name] = nil }
            completion(r, detail)
        }
        queue.asyncAfter(deadline: .now() + Prober.timeout) { finish(.failure, "timeout") }

        let startHTTP: (IPv4) -> Void = { ip in
            guard !done else { return }
            self.http(ip: ip, ifIndex: ifIndex, deadline: deadline) { conn, result, detail in
                tcp = conn
                if case .success = result { self.cachedAddress[link.name] = (ip, monotonicNow()) }
                finish(result, detail)
            }
        }

        if let c = cachedAddress[link.name], monotonicNow() - c.at < 300 {
            startHTTP(c.ip)
            return
        }
        guard let resolver = link.resolvers.first else {
            finish(.failure, "no resolver")
            return
        }
        let q = DNS.buildQuery(id: UInt16.random(in: 1...UInt16.max), name: Prober.host, type: DNSType.a)
        dnsQuery(q, server: resolver, ifIndex: ifIndex, timeout: max(0.1, deadline - monotonicNow()),
                 queue: queue) { response in
            guard let response, let ip = DNS.aRecords(in: response).first else {
                finish(.failure, "dns via \(resolver) failed")
                return
            }
            startHTTP(ip)
        }
    }

    /// Opens a bound TCP connection, sends the captive GET, and classifies the answer.
    /// The connection is handed to the caller so it can be cancelled on the overall timeout.
    private func http(ip: IPv4, ifIndex: UInt32, deadline: Double,
                      completion: @escaping (BoundTCPConnection?, ProbeResult, String) -> Void) {
        let started = monotonicNow()
        var conn: BoundTCPConnection?
        conn = BoundTCPConnection.start(to: ip, port: 80, ifIndex: ifIndex,
                                        timeout: max(0.1, deadline - started), queue: queue) { error in
            if let error {
                completion(conn, .failure, "tcp: \(error)")
                return
            }
            guard let c = conn else { return }
            let rtt = monotonicNow() - started // TCP handshake time ≈ one RTT
            let req = "GET /hotspot-detect.html HTTP/1.0\r\nHost: \(Prober.host)\r\nUser-Agent: CaptiveNetworkSupport/1.0 wispr\r\nAccept: */*\r\nConnection: close\r\n\r\n"
            c.send(Data(req.utf8)) { err in
                if let err {
                    completion(c, .failure, "send: \(err)")
                    return
                }
                self.readResponse(c, received: Data(), rtt: rtt, completion: completion)
            }
        }
    }

    private func readResponse(_ conn: BoundTCPConnection, received: Data, rtt: Double,
                              completion: @escaping (BoundTCPConnection?, ProbeResult, String) -> Void) {
        conn.receive(max: 16384) { data, isEOF in
            var acc = received
            if let data { acc.append(data) }
            let text = String(decoding: acc, as: UTF8.self)
            let statusOK = text.hasPrefix("HTTP/1.1 200") || text.hasPrefix("HTTP/1.0 200")
            if statusOK && text.contains("Success") {
                completion(conn, .success(rtt: rtt), "ok")
            } else if data == nil || isEOF || acc.count > 65536 {
                if acc.isEmpty {
                    completion(conn, .failure, "empty http response")
                } else {
                    let first = text.split(separator: "\r\n").first.map(String.init) ?? ""
                    completion(conn, .captive, "unexpected answer: \(first)")
                }
            } else {
                self.readResponse(conn, received: acc, rtt: rtt, completion: completion)
            }
        }
    }
}
