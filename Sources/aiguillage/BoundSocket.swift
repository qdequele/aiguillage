import AiguillageCore
import Darwin
import Foundation

// Outbound egress uses raw BSD sockets bound to a physical interface with IP_BOUND_IF.
//
// Why not Network.framework's `requiredInterface`: once our utun owns the 0/1 + 128/1 default
// routes, Network.framework stops considering a physical interface a globally-viable path to an
// arbitrary host, so a connection *required* on that interface is rejected immediately with
// ENETDOWN. IP_BOUND_IF instead forces a *scoped* route lookup, which finds the interface's own
// default route (e.g. en0 via 10.53.0.1) and bypasses our 0/1 routes entirely. The inbound side
// (the NWListener on 198.18.0.1) keeps using Network.framework; that works.

/// IP_BOUND_IF is 25, IPV6_BOUND_IF is 125 on Darwin; the imported constants are used when present.
#if canImport(Darwin)
let kIPBoundIF = IP_BOUND_IF
let kIPv6BoundIF = IPV6_BOUND_IF
#else
let kIPBoundIF: Int32 = 25
let kIPv6BoundIF: Int32 = 125
#endif

struct SocketError: Error, CustomStringConvertible {
    let message: String
    let errnoValue: Int32
    var description: String {
        errnoValue == 0 ? message : "\(message): \(String(cString: strerror(errnoValue))) (errno \(errnoValue))"
    }
    init(_ message: String, _ errnoValue: Int32 = errno) {
        self.message = message
        self.errnoValue = errnoValue
    }
}

private func sockaddrIPv4(_ ip: IPv4, _ port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: ip.value.bigEndian)
    return addr
}

/// Creates a non-blocking IPv4 socket bound to `ifIndex` via IP_BOUND_IF.
func makeBoundSocket(type: Int32, ifIndex: UInt32) throws -> Int32 {
    let fd = socket(AF_INET, type, 0)
    guard fd >= 0 else { throw SocketError("socket()") }
    var idx = UInt32(ifIndex)
    guard setsockopt(fd, IPPROTO_IP, kIPBoundIF, &idx, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
        let e = errno
        close(fd)
        throw SocketError("setsockopt(IP_BOUND_IF)", e)
    }
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// A TCP connection going out one physical interface, driven on a GCD queue.
/// One receive and one send may be outstanding at a time (the relay uses strict backpressure).
final class BoundTCPConnection {
    let fd: Int32
    let queue: DispatchQueue
    private(set) var closed = false
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var connectTimer: DispatchSourceTimer?

    private init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    private var connectDone = false
    private var onConnect: ((Error?) -> Void)?

    /// Starts a bound, non-blocking connect to `ip:port`. The object is returned immediately so the
    /// caller can `close()` it to cancel an in-flight connect (e.g. the loser of a race).
    /// `onConnect(nil)` means connected; `onConnect(error)` means failed/timed out. It fires once,
    /// on `queue`, unless the connection is closed first.
    static func start(to ip: IPv4, port: UInt16, ifIndex: UInt32, timeout: Double, queue: DispatchQueue,
                      onConnect: @escaping (Error?) -> Void) -> BoundTCPConnection? {
        let fd: Int32
        do {
            fd = try makeBoundSocket(type: SOCK_STREAM, ifIndex: ifIndex)
        } catch {
            queue.async { onConnect(error) }
            return nil
        }
        let conn = BoundTCPConnection(fd: fd, queue: queue)
        conn.onConnect = onConnect
        var addr = sockaddrIPv4(ip, port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 {
            queue.async { conn.finishConnect(nil) } // connected immediately (rare)
            return conn
        }
        guard errno == EINPROGRESS else {
            let e = errno
            queue.async { conn.finishConnect(SocketError("connect(\(ip):\(port))", e)) }
            return conn
        }
        // The socket becomes writable when the handshake finishes (or fails: check SO_ERROR).
        let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        ws.setEventHandler { [weak conn] in
            guard let conn else { return }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            conn.finishConnect(err == 0 ? nil : SocketError("connect(\(ip):\(port))", err))
        }
        conn.writeSource = ws
        ws.resume()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak conn] in
            conn?.finishConnect(SocketError("connect timeout to \(ip):\(port)", ETIMEDOUT))
        }
        conn.connectTimer = timer
        timer.resume()
        return conn
    }

    private func finishConnect(_ error: Error?) {
        guard !connectDone, !closed else { return }
        connectDone = true
        writeSource?.cancel()
        writeSource = nil
        connectTimer?.cancel()
        connectTimer = nil
        let handler = onConnect
        onConnect = nil
        handler?(error)
    }

    /// Reads up to `max` bytes. completion(data, isEOF): nil data = error; empty data + isEOF = FIN.
    func receive(max: Int = 65536, _ completion: @escaping (Data?, Bool) -> Void) {
        guard !closed else { completion(nil, false); return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            src.cancel()
            self.readSource = nil
            var buf = [UInt8](repeating: 0, count: max)
            let n = buf.withUnsafeMutableBytes { Darwin.read(self.fd, $0.baseAddress, $0.count) }
            if n > 0 {
                completion(Data(buf[0..<n]), false)
            } else if n == 0 {
                completion(Data(), true) // peer sent FIN
            } else if errno == EAGAIN || errno == EINTR {
                self.receive(max: max, completion) // spurious wakeup
            } else {
                completion(nil, false)
            }
        }
        readSource = src
        src.resume()
    }

    /// Writes all of `data`, waiting for writability on EAGAIN. completion(error).
    func send(_ data: Data, _ completion: @escaping (Error?) -> Void) {
        guard !closed else { completion(SocketError("send on closed socket", 0)); return }
        guard !data.isEmpty else { completion(nil); return }
        var offset = 0
        func attempt() {
            let result: Int = data.withUnsafeBytes { raw -> Int in
                while offset < data.count {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), data.count - offset)
                    if n > 0 {
                        offset += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                        return -1 // need to wait for writability
                    } else {
                        return -2 // error
                    }
                }
                return 0 // done
            }
            switch result {
            case 0:
                completion(nil)
            case -2:
                completion(SocketError("write()"))
            default:
                let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
                ws.setEventHandler { [weak self] in
                    guard let self, !self.closed else { return }
                    ws.cancel()
                    self.writeSource = nil
                    attempt()
                }
                writeSource = ws
                ws.resume()
            }
        }
        attempt()
    }

    /// Sends FIN on our side (SHUT_WR) while still able to read.
    func shutdownWrite() {
        guard !closed else { return }
        Darwin.shutdown(fd, SHUT_WR)
    }

    func close() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        writeSource?.cancel()
        connectTimer?.cancel()
        readSource = nil
        writeSource = nil
        connectTimer = nil
        Darwin.close(fd)
    }
}

/// A connected UDP socket going out one physical interface. One receive loop, fire-and-forget sends.
final class BoundUDPSocket {
    let fd: Int32
    let queue: DispatchQueue
    private(set) var closed = false
    private var readSource: DispatchSourceRead?

    private init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// Creates a UDP socket bound to the interface and connected to `ip:port` (so send/recv work
    /// without re-specifying the peer, and only its replies are delivered).
    static func connected(to ip: IPv4, port: UInt16, ifIndex: UInt32, queue: DispatchQueue) throws -> BoundUDPSocket {
        let fd = try makeBoundSocket(type: SOCK_DGRAM, ifIndex: ifIndex)
        var addr = sockaddrIPv4(ip, port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else {
            let e = errno
            Darwin.close(fd)
            throw SocketError("udp connect(\(ip):\(port))", e)
        }
        return BoundUDPSocket(fd: fd, queue: queue)
    }

    func send(_ data: Data) {
        guard !closed else { return }
        data.withUnsafeBytes { _ = Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// Delivers each received datagram to `handler` until the socket is closed.
    func receiveLoop(_ handler: @escaping (Data) -> Void) {
        guard !closed else { return }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = buf.withUnsafeMutableBytes { Darwin.recv(self.fd, $0.baseAddress, $0.count, 0) }
            if n > 0 { handler(Data(buf[0..<n])) }
        }
        readSource = src
        src.resume()
    }

    func close() {
        guard !closed else { return }
        closed = true
        readSource?.cancel()
        readSource = nil
        Darwin.close(fd)
    }
}

/// Hidden diagnostic: raw socket + IP_BOUND_IF + blocking connect, prints success/errno.
/// Isolates the egress path from the rest of the daemon.
func runBindTest(_ args: ArraySlice<String>) -> Int32 {
    let a = Array(args)
    guard a.count == 3, let port = UInt16(a[2]), let ip = IPv4(a[1]) else {
        FileHandle.standardError.write("usage: aiguillage bindtest <ifname> <ipv4> <port>\n".data(using: .utf8)!)
        return 2
    }
    let ifname = a[0]
    let idx = if_nametoindex(ifname)
    guard idx != 0 else {
        print("if_nametoindex(\(ifname)) = 0: no such interface")
        return 1
    }
    print("interface \(ifname) index \(idx); connecting to \(ip):\(port) bound via IP_BOUND_IF...")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else {
        print("socket() failed: \(String(cString: strerror(errno)))")
        return 1
    }
    defer { close(fd) }
    var bound = UInt32(idx)
    guard setsockopt(fd, IPPROTO_IP, kIPBoundIF, &bound, socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
        print("setsockopt(IP_BOUND_IF) failed: \(String(cString: strerror(errno)))")
        return 1
    }
    var addr = sockaddrIPv4(ip, port)
    let started = monotonicNow()
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    let ms = Int((monotonicNow() - started) * 1000)
    if rc == 0 {
        print("SUCCESS: connected in \(ms) ms (egress via \(ifname) works; IP_BOUND_IF bypasses the utun routes)")
        return 0
    }
    print("FAILED after \(ms) ms: \(String(cString: strerror(errno))) (errno \(errno))")
    return 1
}
