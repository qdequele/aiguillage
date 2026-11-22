/// Minimal IPv4 / IPv6 / TCP / UDP parsing and building.
/// Packets are plain `[UInt8]`; the views below only validate lengths and read fields.

public enum IPProto {
    public static let tcp: UInt8 = 6
    public static let udp: UInt8 = 17
}

public struct TCPFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let fin = TCPFlags(rawValue: 0x01)
    public static let syn = TCPFlags(rawValue: 0x02)
    public static let rst = TCPFlags(rawValue: 0x04)
    public static let psh = TCPFlags(rawValue: 0x08)
    public static let ack = TCPFlags(rawValue: 0x10)
}

@inline(__always) func read16(_ b: [UInt8], _ i: Int) -> UInt16 {
    UInt16(b[i]) << 8 | UInt16(b[i + 1])
}

@inline(__always) func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
}

@inline(__always) func write16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) {
    b[i] = UInt8(v >> 8)
    b[i + 1] = UInt8(v & 0xff)
}

@inline(__always) func write32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
    b[i] = UInt8(v >> 24)
    b[i + 1] = UInt8(v >> 16 & 0xff)
    b[i + 2] = UInt8(v >> 8 & 0xff)
    b[i + 3] = UInt8(v & 0xff)
}

// MARK: - IPv4

/// A validated view on an IPv4 packet. `bytes` is trimmed to the header's total length.
public struct IPv4Packet {
    public var bytes: [UInt8]
    public let headerLength: Int

    public init?(_ raw: [UInt8]) {
        guard raw.count >= 20, raw[0] >> 4 == 4 else { return nil }
        let ihl = Int(raw[0] & 0x0f) * 4
        let total = Int(read16(raw, 2))
        guard ihl >= 20, total >= ihl, total <= raw.count else { return nil }
        bytes = total == raw.count ? raw : Array(raw[0..<total])
        headerLength = ihl
    }

    public var proto: UInt8 { bytes[9] }
    public var src: IPv4 { IPv4(bytes: bytes, at: 12) }
    public var dst: IPv4 { IPv4(bytes: bytes, at: 16) }
    public var totalLength: Int { bytes.count }

    /// True if this is any fragment (MF set or non-zero offset).
    public var isFragment: Bool {
        let flagsFrag = read16(bytes, 6)
        return flagsFrag & 0x2000 != 0 || flagsFrag & 0x1fff != 0
    }

    public var payloadRange: Range<Int> { headerLength..<bytes.count }

    /// True if the stored header checksum is correct.
    public var headerChecksumValid: Bool {
        Checksum.internet(bytes, 0..<headerLength) == 0
    }
}

/// Recomputes the IPv4 header checksum in place.
public func fixIPv4HeaderChecksum(_ b: inout [UInt8]) {
    let ihl = Int(b[0] & 0x0f) * 4
    write16(&b, 10, 0)
    write16(&b, 10, Checksum.internet(b, 0..<ihl))
}

/// Builds a 20-byte IPv4 header (no options) followed by `payload`. Checksum included.
public func buildIPv4(src: IPv4, dst: IPv4, proto: UInt8, id: UInt16, payload: [UInt8]) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 20)
    b[0] = 0x45
    write16(&b, 2, UInt16(20 + payload.count))
    write16(&b, 4, id)
    b[8] = 64 // TTL
    b[9] = proto
    write32(&b, 12, src.value)
    write32(&b, 16, dst.value)
    write16(&b, 10, Checksum.internet(b, 0..<20))
    return b + payload
}

// MARK: - TCP

/// A validated view on the TCP segment inside an IPv4 or IPv6 packet.
public struct TCPSegment {
    public let offset: Int // start of the TCP header inside the packet bytes
    public let length: Int // header + payload

    public init?(packet bytes: [UInt8], range: Range<Int>) {
        guard range.count >= 20 else { return nil }
        let dataOffset = Int(bytes[range.lowerBound + 12] >> 4) * 4
        guard dataOffset >= 20, dataOffset <= range.count else { return nil }
        offset = range.lowerBound
        length = range.count
    }

    public func srcPort(_ b: [UInt8]) -> UInt16 { read16(b, offset) }
    public func dstPort(_ b: [UInt8]) -> UInt16 { read16(b, offset + 2) }
    public func seq(_ b: [UInt8]) -> UInt32 { read32(b, offset + 4) }
    public func ack(_ b: [UInt8]) -> UInt32 { read32(b, offset + 8) }
    public func flags(_ b: [UInt8]) -> TCPFlags { TCPFlags(rawValue: b[offset + 13] & 0x3f) }
    public func headerLength(_ b: [UInt8]) -> Int { Int(b[offset + 12] >> 4) * 4 }
    public func payloadLength(_ b: [UInt8]) -> Int { length - headerLength(b) }
    public var range: Range<Int> { offset..<(offset + length) }
}

/// Rewrites addresses and ports of an IPv4/TCP packet and recomputes both checksums from scratch.
public func rewriteIPv4TCP(_ b: inout [UInt8], src: IPv4, srcPort: UInt16, dst: IPv4, dstPort: UInt16) {
    let ihl = Int(b[0] & 0x0f) * 4
    write32(&b, 12, src.value)
    write32(&b, 16, dst.value)
    write16(&b, ihl, srcPort)
    write16(&b, ihl + 2, dstPort)
    fixIPv4HeaderChecksum(&b)
    write16(&b, ihl + 16, 0)
    let sum = Checksum.transport4(src: src, dst: dst, proto: IPProto.tcp, b, ihl..<b.count)
    write16(&b, ihl + 16, sum)
}

/// True if the TCP checksum of an IPv4/TCP packet is correct.
public func ipv4TCPChecksumValid(_ b: [UInt8]) -> Bool {
    guard let p = IPv4Packet(b) else { return false }
    let sum = Checksum.transport4(src: p.src, dst: p.dst, proto: IPProto.tcp, p.bytes, p.payloadRange)
    return sum == 0
}

/// Builds a 20-byte TCP header (no options, no payload) with a correct checksum for IPv4.
func buildTCPHeader(srcPort: UInt16, dstPort: UInt16, seq: UInt32, ack: UInt32, flags: TCPFlags) -> [UInt8] {
    var t = [UInt8](repeating: 0, count: 20)
    write16(&t, 0, srcPort)
    write16(&t, 2, dstPort)
    write32(&t, 4, seq)
    write32(&t, 8, ack)
    t[12] = 5 << 4
    t[13] = flags.rawValue
    return t
}

/// Sequence numbers for a RST answering `segment` (RFC 793 reset generation).
func resetNumbers(_ b: [UInt8], _ seg: TCPSegment) -> (seq: UInt32, ack: UInt32, flags: TCPFlags) {
    let f = seg.flags(b)
    if f.contains(.ack) {
        return (seg.ack(b), 0, [.rst])
    }
    var len = UInt32(seg.payloadLength(b))
    if f.contains(.syn) { len &+= 1 }
    if f.contains(.fin) { len &+= 1 }
    return (0, seg.seq(b) &+ len, [.rst, .ack])
}

/// Builds an IPv4 TCP RST answering the given IPv4/TCP packet, or nil if it is itself a RST.
public func buildIPv4TCPReset(answering packet: IPv4Packet) -> [UInt8]? {
    let b = packet.bytes
    guard packet.proto == IPProto.tcp,
          let seg = TCPSegment(packet: b, range: packet.payloadRange),
          !seg.flags(b).contains(.rst) else { return nil }
    let n = resetNumbers(b, seg)
    var tcp = buildTCPHeader(srcPort: seg.dstPort(b), dstPort: seg.srcPort(b), seq: n.seq, ack: n.ack, flags: n.flags)
    write16(&tcp, 16, Checksum.transport4(src: packet.dst, dst: packet.src, proto: IPProto.tcp, tcp, 0..<20))
    return buildIPv4(src: packet.dst, dst: packet.src, proto: IPProto.tcp, id: 0, payload: tcp)
}

// MARK: - UDP

public struct UDPDatagram {
    public let srcPort: UInt16
    public let dstPort: UInt16
    public let payload: [UInt8]

    /// Parses the UDP datagram inside an IPv4 packet.
    public init?(_ packet: IPv4Packet) {
        let b = packet.bytes
        let r = packet.payloadRange
        guard packet.proto == IPProto.udp, r.count >= 8 else { return nil }
        let len = Int(read16(b, r.lowerBound + 4))
        guard len >= 8, len <= r.count else { return nil }
        srcPort = read16(b, r.lowerBound)
        dstPort = read16(b, r.lowerBound + 2)
        payload = Array(b[(r.lowerBound + 8)..<(r.lowerBound + len)])
    }
}

/// Builds a full IPv4+UDP packet with valid checksums.
public func buildIPv4UDP(src: IPv4, srcPort: UInt16, dst: IPv4, dstPort: UInt16, payload: [UInt8], id: UInt16) -> [UInt8] {
    var udp = [UInt8](repeating: 0, count: 8)
    write16(&udp, 0, srcPort)
    write16(&udp, 2, dstPort)
    write16(&udp, 4, UInt16(8 + payload.count))
    udp += payload
    var sum = Checksum.transport4(src: src, dst: dst, proto: IPProto.udp, udp, 0..<udp.count)
    if sum == 0 { sum = 0xFFFF } // 0 means "no checksum" in UDP
    write16(&udp, 6, sum)
    return buildIPv4(src: src, dst: dst, proto: IPProto.udp, id: id, payload: udp)
}

public func ipv4UDPChecksumValid(_ b: [UInt8]) -> Bool {
    guard let p = IPv4Packet(b) else { return false }
    return Checksum.transport4(src: p.src, dst: p.dst, proto: IPProto.udp, p.bytes, p.payloadRange) == 0
}

// MARK: - IPv6

/// Minimal IPv6 view: fixed header only, extension headers are not walked.
public struct IPv6Packet {
    public let bytes: [UInt8]

    public init?(_ raw: [UInt8]) {
        guard raw.count >= 40, raw[0] >> 4 == 6 else { return nil }
        let payloadLen = Int(read16(raw, 4))
        guard 40 + payloadLen <= raw.count else { return nil }
        bytes = Array(raw[0..<(40 + payloadLen)])
    }

    public var nextHeader: UInt8 { bytes[6] }
    public var src: [UInt8] { Array(bytes[8..<24]) }
    public var dst: [UInt8] { Array(bytes[24..<40]) }
    public var payloadRange: Range<Int> { 40..<bytes.count }

    /// True for a TCP segment with SYN set and ACK clear (a connection attempt).
    public var isTCPSyn: Bool {
        guard nextHeader == IPProto.tcp, let seg = TCPSegment(packet: bytes, range: payloadRange) else { return false }
        let f = seg.flags(bytes)
        return f.contains(.syn) && !f.contains(.ack)
    }
}

/// Builds an IPv6 TCP RST+ACK answering a TCP SYN, or nil if the packet is not a TCP SYN.
public func buildIPv6TCPReset(answering packet: IPv6Packet) -> [UInt8]? {
    guard packet.isTCPSyn, let seg = TCPSegment(packet: packet.bytes, range: packet.payloadRange) else { return nil }
    let b = packet.bytes
    let n = resetNumbers(b, seg)
    var tcp = buildTCPHeader(srcPort: seg.dstPort(b), dstPort: seg.srcPort(b), seq: n.seq, ack: n.ack, flags: n.flags)
    write16(&tcp, 16, Checksum.transport6(src: packet.dst, dst: packet.src, proto: IPProto.tcp, tcp, 0..<20))
    var h = [UInt8](repeating: 0, count: 40)
    h[0] = 0x60
    write16(&h, 4, UInt16(tcp.count))
    h[6] = IPProto.tcp
    h[7] = 64 // hop limit
    h.replaceSubrange(8..<24, with: packet.dst)
    h.replaceSubrange(24..<40, with: packet.src)
    return h + tcp
}
