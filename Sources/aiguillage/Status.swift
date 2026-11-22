import AiguillageCore
import Darwin
import Foundation

enum StatusSocket {
    static let path = StatusSocketPath.path

    private static func makeAddress() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, c) in path.utf8.enumerated() where i < buf.count - 1 { buf[i] = c }
        }
        return addr
    }

    /// Connects, sends `request` (one JSON line) and reads the whole reply. Returns nil if nobody
    /// listens. An empty/default request keeps the old behaviour (a status query).
    static func query(_ request: ControlRequest = .status) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = makeAddress()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return nil }
        if var line = try? JSONEncoder().encode(request) {
            line.append(0x0A) // newline terminates the request
            line.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// Serves clients on a background thread. The socket is world-accessible (0666) so `aiguillage
    /// status` (and the unprivileged menu bar app) work without sudo: a status query only reads
    /// JSON back, while control commands (`stop`, `set-mode`) act on the already-root daemon.
    ///
    /// `handle` turns a parsed request into a reply plus an optional side effect to run *after* the
    /// reply is sent (used by `stop` to tear down and exit once the client has its ack).
    static func serve(handle: @escaping (ControlRequest) -> (reply: Data, after: (() -> Void)?)) throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UtunError("status socket: \(errnoString())") }
        var addr = makeAddress()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw UtunError("bind \(path): \(errnoString())") }
        chmod(path, 0o666)
        guard listen(fd, 8) == 0 else { throw UtunError("listen \(path): \(errnoString())") }
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let request = readRequest(client)
                let (reply, after) = handle(request)
                reply.withUnsafeBytes { raw in
                    var off = 0
                    while off < raw.count {
                        let n = write(client, raw.baseAddress! + off, raw.count - off)
                        if n <= 0 { break }
                        off += n
                    }
                }
                close(client)
                after?()
            }
        }
        thread.name = "status"
        thread.start()
    }

    /// Reads one request line. An old client that connects and only reads sends nothing, so we cap
    /// the wait with a short receive timeout and fall back to a status query. A malformed or partial
    /// payload also decodes to a status query — it never throws.
    private static func readRequest(_ client: Int32) -> ControlRequest {
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while data.count < 8192 {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break } // EOF, timeout or error
            data.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break } // newline: request complete
        }
        guard !data.isEmpty, let req = try? JSONDecoder().decode(ControlRequest.self, from: data) else {
            return .status
        }
        return req
    }

    static func remove() {
        unlink(path)
    }
}

/// `aiguillage status [--json]`.
func runStatus(json: Bool) -> Int32 {
    guard let data = StatusSocket.query() else {
        FileHandle.standardError.write("aiguillage is not running (no answer on \(StatusSocket.path))\n".data(using: .utf8)!)
        return 1
    }
    if json {
        FileHandle.standardOutput.write(data)
        print()
        return 0
    }
    guard let s = try? JSONDecoder().decode(StatusSnapshot.self, from: data) else {
        FileHandle.standardError.write("unreadable status reply\n".data(using: .utf8)!)
        return 1
    }
    print("aiguillage pid \(s.pid) on \(s.utun), mode \(s.mode), dns \(s.dnsMode), up \(s.uptimeSeconds)s")
    if s.links.isEmpty { print("  no links") }
    for l in s.links {
        let rtt = l.rttMs.map { "\($0)ms" } ?? "-"
        print("  \(l.role.padding(toLength: 9, withPad: " ", startingAt: 0)) \(l.name.padding(toLength: 6, withPad: " ", startingAt: 0)) \(l.state.padding(toLength: 7, withPad: " ", startingAt: 0)) rtt \(rtt)  up \(formatBytes(l.bytesUp)) down \(formatBytes(l.bytesDown))  tcp \(l.activeTCP) udp \(l.activeUDP)  (\(l.displayName), \(l.address))")
    }
    print("  flows: tcp \(s.tcpFlows), udp \(s.udpFlows), nat \(s.natEntries), dns queries \(s.dnsQueries), rule-learned addresses \(s.learnedRuleAddresses)")
    print("rules:")
    for r in s.rules { print("  \(r.pattern) = \(r.policy)  [\(r.source)]") }
    let pinned = s.flows.filter { $0.rule != nil }
    print("flows matched by a rule: \(pinned.count)")
    for f in pinned {
        print("  \(f.proto) \(f.destination) via \(f.link ?? "-")  rule \(f.rule!) (\(f.policy ?? "-")), \(f.ageSeconds)s")
    }
    return 0
}
