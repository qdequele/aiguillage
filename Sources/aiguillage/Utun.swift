import Darwin
import Foundation

/// A kernel utun device opened through the utun control socket. Requires root.
/// Every packet carries a 4-byte big-endian address family header (AF_INET / AF_INET6).
/// The interface (and every route pointing at it) disappears when the fd is closed or the
/// process dies.
final class Utun {
    let fd: Int32
    let name: String

    /// _IOWR('N', 3, struct ctl_info): the macro is not imported into Swift.
    private static let CTLIOCGINFO: UInt = 0xC000_0000 | (UInt(MemoryLayout<ctl_info>.size) & 0x1fff) << 16 | UInt(UInt8(ascii: "N")) << 8 | 3

    private init(fd: Int32, name: String) {
        self.fd = fd
        self.name = name
    }

    static func open() throws -> Utun {
        let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard fd >= 0 else { throw UtunError("socket(PF_SYSTEM) failed: \(errnoString())") }

        var info = ctl_info()
        let control = "com.apple.net.utun_control"
        withUnsafeMutableBytes(of: &info.ctl_name) { buf in
            for (i, c) in control.utf8.enumerated() where i < buf.count - 1 { buf[i] = c }
        }
        guard ioctl(fd, CTLIOCGINFO, &info) == 0 else {
            Darwin.close(fd)
            throw UtunError("ioctl(CTLIOCGINFO) failed: \(errnoString())")
        }

        // sc_unit 0 lets the kernel pick the first free utunN.
        var addr = sockaddr_ctl()
        addr.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        addr.sc_family = UInt8(AF_SYSTEM)
        addr.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        addr.sc_id = info.ctl_id
        addr.sc_unit = 0
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size))
            }
        }
        guard rc == 0 else {
            let err = errnoString()
            Darwin.close(fd)
            throw UtunError("connect(utun_control) failed: \(err) (are you root?)")
        }

        var nameBuf = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var len = socklen_t(nameBuf.count)
        guard getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, &nameBuf, &len) == 0 else {
            Darwin.close(fd)
            throw UtunError("getsockopt(UTUN_OPT_IFNAME) failed: \(errnoString())")
        }
        let name = String(cString: nameBuf)
        return Utun(fd: fd, name: name)
    }

    /// Blocking read of one packet. Returns (address family, packet) or nil on error/EOF.
    func readPacket(buffer: inout [UInt8]) -> (family: UInt32, packet: [UInt8])? {
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            guard n > 4 else { return n == 4 ? (0, []) : nil }
            let family = UInt32(buffer[0]) << 24 | UInt32(buffer[1]) << 16 | UInt32(buffer[2]) << 8 | UInt32(buffer[3])
            return (family, Array(buffer[4..<n]))
        }
    }

    func write(_ packet: [UInt8], family: Int32) {
        let f = UInt32(family)
        var out: [UInt8] = [UInt8(f >> 24), UInt8(f >> 16 & 0xff), UInt8(f >> 8 & 0xff), UInt8(f & 0xff)]
        out += packet
        let n = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if n < 0 {
            Log.debug("utun write failed: \(errnoString())")
        }
    }

    func close() {
        Darwin.close(fd)
    }
}

struct UtunError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func errnoString() -> String {
    String(cString: strerror(errno))
}
