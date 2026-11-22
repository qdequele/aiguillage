/// An IPv4 address stored as a host-order UInt32.
public struct IPv4: Hashable, Comparable, CustomStringConvertible, Sendable, Codable {
    public var value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// Parses dotted-quad notation ("192.0.2.1"). Returns nil for anything else.
    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, let n = UInt8(part) else { return nil }
            v = v << 8 | UInt32(n)
        }
        value = v
    }

    /// Reads 4 bytes in network order at `offset`.
    public init(bytes: [UInt8], at offset: Int) {
        self.init(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    public var bytes: [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    public var description: String {
        "\(value >> 24).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }

    public var isMulticast: Bool { value >> 28 == 0xE }
    public var isBroadcast: Bool { value == 0xFFFF_FFFF }
    public var isLoopback: Bool { value >> 24 == 127 }

    /// True for 100.64.0.0/10 (CGNAT, used by Tailscale). Never relayed out a physical link.
    public var isCGNAT: Bool { value >> 22 == (100 << 2 | 64 >> 6) }

    /// True for 198.18.0.0/15, the benchmarking range used for the tunnel addresses.
    public var isBenchmarkRange: Bool { value >> 17 == (198 << 7 | 18 >> 1) }

    public static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.value < rhs.value }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let ip = IPv4(s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "invalid IPv4 \(s)")
        }
        self = ip
    }
}

/// Addresses used by the tunnel. Shared by Core and the daemon so tests use the real values.
public enum TunnelAddresses {
    /// Local address of the utun; apps' packets come from here.
    public static let local = IPv4(198, 18, 0, 1)
    /// Peer address of the utun; used as NAT source and as the DNS server address.
    public static let peer = IPv4(198, 18, 0, 2)
    public static let netmask = "255.255.255.252"
    /// ULA given to the utun so IPv6 traffic is captured (and refused).
    /// Deliberately outside Tailscale's fd7a:115c:a1e0::/48.
    public static let ipv6Local = "fd61:6967:7569::1"
}

/// True if a 16-byte IPv6 address is inside Tailscale's ULA prefix fd7a:115c:a1e0::/48.
public func isTailscaleIPv6(_ a: [UInt8]) -> Bool {
    a.count == 16 && Array(a[0..<6]) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
}
