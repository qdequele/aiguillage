import Testing
@testable import AiguillageCore

/// Builds an IPv4/TCP packet with valid checksums (20-byte TCP header, optional payload).
func makeTCP(src: IPv4, sport: UInt16, dst: IPv4, dport: UInt16, flags: TCPFlags,
             seq: UInt32 = 0x0102_0304, ack: UInt32 = 0, payload: [UInt8] = [], id: UInt16 = 0x1234) -> [UInt8] {
    var tcp = buildTCPHeader(srcPort: sport, dstPort: dport, seq: seq, ack: ack, flags: flags)
    write16(&tcp, 14, 65535) // window
    tcp += payload
    write16(&tcp, 16, Checksum.transport4(src: src, dst: dst, proto: IPProto.tcp, tcp, 0..<tcp.count))
    var ip = buildIPv4(src: src, dst: dst, proto: IPProto.tcp, id: id, payload: tcp)
    ip[6] = 0x40 // DF
    fixIPv4HeaderChecksum(&ip)
    return ip
}

@Suite struct ChecksumTests {
    @Test func rfcExampleHeader() {
        // Classic example header (Wikipedia "IPv4 header checksum"): checksum 0xB861.
        var h: [UInt8] = [0x45, 0x00, 0x00, 0x73, 0x00, 0x00, 0x40, 0x00, 0x40, 0x11, 0x00, 0x00,
                          0xc0, 0xa8, 0x00, 0x01, 0xc0, 0xa8, 0x00, 0xc7]
        #expect(Checksum.internet(h, 0..<20) == 0xB861)
        h[10] = 0xB8
        h[11] = 0x61
        #expect(Checksum.internet(h, 0..<20) == 0)
    }

    @Test func oddLengthPadsWithZero() {
        #expect(Checksum.internet([0x01], 0..<1) == ~UInt16(0x0100))
        #expect(Checksum.internet([0x12, 0x34, 0x56], 0..<3) == ~UInt16(0x1234 + 0x5600))
    }

    @Test func carryIsFolded() {
        // 0xFFFF + 0x0001 = 0x10000 -> folds to 0x0001 -> complement 0xFFFE.
        #expect(Checksum.internet([0xff, 0xff, 0x00, 0x01], 0..<4) == 0xFFFE)
    }

    @Test func tcpVectorMatchesIndependentComputation() {
        // Reference values computed with an independent Python implementation.
        let p = makeTCP(src: IPv4(198, 18, 0, 1), sport: 51000, dst: IPv4(93, 184, 216, 34), dport: 443, flags: .syn)
        #expect(read16(p, 10) == 0x2CAE)
        #expect(read16(p, 36) == 0xE6FA)
        #expect(ipv4TCPChecksumValid(p))
        #expect(IPv4Packet(p)!.headerChecksumValid)
    }
}

@Suite struct PacketTests {
    @Test func parsesIPv4AndTCP() throws {
        let p = makeTCP(src: IPv4(198, 18, 0, 1), sport: 1000, dst: IPv4(1, 2, 3, 4), dport: 80, flags: [.syn], payload: [1, 2, 3])
        let ip = try #require(IPv4Packet(p))
        #expect(ip.proto == IPProto.tcp)
        #expect(ip.src == IPv4(198, 18, 0, 1))
        #expect(ip.dst == IPv4(1, 2, 3, 4))
        #expect(!ip.isFragment)
        let seg = try #require(TCPSegment(packet: ip.bytes, range: ip.payloadRange))
        #expect(seg.srcPort(ip.bytes) == 1000)
        #expect(seg.dstPort(ip.bytes) == 80)
        #expect(seg.payloadLength(ip.bytes) == 3)
        #expect(seg.flags(ip.bytes) == .syn)
    }

    @Test func rejectsTruncatedAndDetectsFragments() {
        var p = makeTCP(src: IPv4(10, 0, 0, 1), sport: 1, dst: IPv4(10, 0, 0, 2), dport: 2, flags: .syn)
        #expect(IPv4Packet(Array(p.prefix(30))) == nil)
        #expect(IPv4Packet([0x60] + Array(p.dropFirst())) == nil)
        p[6] = 0x20 // MF
        #expect(IPv4Packet(p)!.isFragment)
        p[6] = 0x00
        p[7] = 0x10 // offset
        #expect(IPv4Packet(p)!.isFragment)
    }

    @Test func udpBuildAndParse() throws {
        let b = buildIPv4UDP(src: IPv4(8, 8, 8, 8), srcPort: 53, dst: IPv4(198, 18, 0, 1), dstPort: 5555, payload: [9, 8, 7], id: 1)
        #expect(ipv4UDPChecksumValid(b))
        let ip = try #require(IPv4Packet(b))
        #expect(ip.headerChecksumValid)
        let d = try #require(UDPDatagram(ip))
        #expect(d.srcPort == 53)
        #expect(d.dstPort == 5555)
        #expect(d.payload == [9, 8, 7])
    }

    @Test func ipv4ResetForSyn() throws {
        let syn = makeTCP(src: IPv4(198, 18, 0, 1), sport: 4000, dst: IPv4(1, 1, 1, 1), dport: 443, flags: .syn, seq: 100)
        let rst = try #require(buildIPv4TCPReset(answering: IPv4Packet(syn)!))
        #expect(ipv4TCPChecksumValid(rst))
        let ip = IPv4Packet(rst)!
        let seg = TCPSegment(packet: rst, range: ip.payloadRange)!
        #expect(ip.src == IPv4(1, 1, 1, 1))
        #expect(seg.dstPort(rst) == 4000)
        #expect(seg.flags(rst) == [.rst, .ack])
        #expect(seg.ack(rst) == 101)
        // Never answer a RST with a RST.
        #expect(buildIPv4TCPReset(answering: IPv4Packet(rst)!) == nil)
    }

    @Test func ipv6ResetForSyn() throws {
        var tcp = buildTCPHeader(srcPort: 5000, dstPort: 443, seq: 7, ack: 0, flags: .syn)
        let src: [UInt8] = [0xfd, 0x61, 0x69, 0x67, 0x75, 0x69] + [UInt8](repeating: 0, count: 9) + [1]
        let dst: [UInt8] = [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [2]
        write16(&tcp, 16, Checksum.transport6(src: src, dst: dst, proto: IPProto.tcp, tcp, 0..<20))
        var h = [UInt8](repeating: 0, count: 40)
        h[0] = 0x60
        write16(&h, 4, 20)
        h[6] = IPProto.tcp
        h[7] = 64
        h.replaceSubrange(8..<24, with: src)
        h.replaceSubrange(24..<40, with: dst)
        let p = try #require(IPv6Packet(h + tcp))
        #expect(p.isTCPSyn)
        let rst = try #require(buildIPv6TCPReset(answering: p))
        let r = IPv6Packet(rst)!
        #expect(r.src == dst)
        #expect(r.dst == src)
        #expect(Checksum.transport6(src: r.src, dst: r.dst, proto: IPProto.tcp, rst, r.payloadRange) == 0)
        let seg = TCPSegment(packet: rst, range: r.payloadRange)!
        #expect(seg.ack(rst) == 8)
        #expect(seg.flags(rst) == [.rst, .ack])
    }

    @Test func addressHelpers() {
        #expect(IPv4("198.18.0.2") == TunnelAddresses.peer)
        #expect(IPv4("1.2.3") == nil)
        #expect(IPv4("1.2.3.256") == nil)
        #expect(IPv4(198, 19, 255, 255).isBenchmarkRange)
        #expect(!IPv4(198, 20, 0, 0).isBenchmarkRange)
        #expect(IPv4(100, 64, 0, 1).isCGNAT)
        #expect(IPv4(100, 127, 255, 255).isCGNAT)
        #expect(IPv4(100, 100, 100, 100).isCGNAT)
        #expect(!IPv4(100, 128, 0, 0).isCGNAT)
        #expect(!IPv4(100, 63, 255, 255).isCGNAT)
        #expect(isTailscaleIPv6([0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + [UInt8](repeating: 0, count: 9) + [0x53]))
        #expect(!isTailscaleIPv6([0xfd, 0x61, 0x69, 0x67, 0x75, 0x69] + [UInt8](repeating: 0, count: 10)))
    }
}
