import Testing
@testable import AiguillageCore

@Suite struct TCPRedirectTests {
    let app = TunnelAddresses.local
    let server = IPv4(93, 184, 216, 34)
    let lport: UInt16 = 61000

    @Test func roundTripBothDirections() throws {
        let r = TCPRedirector(listenerPort: lport)
        // App SYN -> listener.
        let syn = makeTCP(src: app, sport: 50123, dst: server, dport: 443, flags: .syn, payload: [])
        guard case .write(let toListener) = r.handle(IPv4Packet(syn)!, now: 0) else {
            Issue.record("SYN not rewritten")
            return
        }
        let ip1 = try #require(IPv4Packet(toListener))
        #expect(ip1.headerChecksumValid)
        #expect(ipv4TCPChecksumValid(toListener))
        #expect(ip1.src == TunnelAddresses.peer)
        #expect(ip1.dst == TunnelAddresses.local)
        let seg1 = TCPSegment(packet: toListener, range: ip1.payloadRange)!
        let natPort = seg1.srcPort(toListener)
        #expect(seg1.dstPort(toListener) == lport)
        #expect(seg1.seq(toListener) == 0x0102_0304) // untouched
        #expect(r.table.entry(forNatPort: natPort)?.key == FlowKey(srcIP: app, srcPort: 50123, dstIP: server, dstPort: 443))

        // Listener SYN-ACK with payload -> app, appears to come from the server.
        let synack = makeTCP(src: TunnelAddresses.local, sport: lport, dst: TunnelAddresses.peer, dport: natPort,
                             flags: [.syn, .ack], seq: 999, ack: 0x0102_0305, payload: Array("hello".utf8))
        guard case .write(let toApp) = r.handle(IPv4Packet(synack)!, now: 0.1) else {
            Issue.record("reply not rewritten")
            return
        }
        let ip2 = try #require(IPv4Packet(toApp))
        #expect(ip2.headerChecksumValid)
        #expect(ipv4TCPChecksumValid(toApp))
        #expect(ip2.src == server)
        #expect(ip2.dst == app)
        let seg2 = TCPSegment(packet: toApp, range: ip2.payloadRange)!
        #expect(seg2.srcPort(toApp) == 443)
        #expect(seg2.dstPort(toApp) == 50123)
        #expect(Array(toApp[(ip2.headerLength + 20)...]) == Array("hello".utf8))

        // Following app ACK uses the same NAT port.
        let ackPkt = makeTCP(src: app, sport: 50123, dst: server, dport: 443, flags: .ack, seq: 0x0102_0305, ack: 1000)
        guard case .write(let again) = r.handle(IPv4Packet(ackPkt)!, now: 0.2) else {
            Issue.record("ack not rewritten")
            return
        }
        #expect(read16(again, 20) == natPort)
        #expect(ipv4TCPChecksumValid(again))
    }

    @Test func ignoresIncomingChecksums() throws {
        var syn = makeTCP(src: app, sport: 1, dst: server, dport: 80, flags: .syn)
        syn[10] = 0xde; syn[11] = 0xad // corrupt IP checksum
        syn[36] = 0xbe; syn[37] = 0xef // corrupt TCP checksum
        guard case .write(let out) = TCPRedirector(listenerPort: lport).handle(IPv4Packet(syn)!, now: 0) else {
            Issue.record("not rewritten")
            return
        }
        #expect(IPv4Packet(out)!.headerChecksumValid)
        #expect(ipv4TCPChecksumValid(out))
    }

    @Test func dropsAndResets() {
        let r = TCPRedirector(listenerPort: lport)
        // To the peer address on a non-DNS port: dropped.
        let toPeer = makeTCP(src: app, sport: 2, dst: TunnelAddresses.peer, dport: 80, flags: .syn)
        #expect(r.handle(IPv4Packet(toPeer)!, now: 0) == .drop("tcp to tunnel peer port 80"))
        // To the peer on port 53: redirected.
        let dns = makeTCP(src: app, sport: 3, dst: TunnelAddresses.peer, dport: 53, flags: .syn)
        if case .write = r.handle(IPv4Packet(dns)!, now: 0) {} else { Issue.record("dns tcp not redirected") }
        // Tailscale / CGNAT destination: dropped, never relayed.
        let ts = makeTCP(src: app, sport: 4, dst: IPv4(100, 100, 100, 100), dport: 443, flags: .syn)
        if case .drop = r.handle(IPv4Packet(ts)!, now: 0) {} else { Issue.record("cgnat not dropped") }
        // Non-SYN without a NAT entry: answered with a RST.
        let stray = makeTCP(src: app, sport: 5, dst: server, dport: 443, flags: .ack, ack: 77)
        guard case .write(let rst) = r.handle(IPv4Packet(stray)!, now: 0) else {
            Issue.record("stray packet not reset")
            return
        }
        let ip = IPv4Packet(rst)!
        #expect(TCPSegment(packet: rst, range: ip.payloadRange)!.flags(rst) == .rst)
        #expect(ip.src == server && ip.dst == app)
        // Listener reply for an unknown NAT port: dropped.
        let orphan = makeTCP(src: TunnelAddresses.local, sport: lport, dst: TunnelAddresses.peer, dport: 12345, flags: .ack)
        if case .drop = r.handle(IPv4Packet(orphan)!, now: 0) {} else { Issue.record("orphan reply not dropped") }
    }
}

@Suite struct NatTableTests {
    func key(_ port: UInt16) -> FlowKey {
        FlowKey(srcIP: IPv4(198, 18, 0, 1), srcPort: port, dstIP: IPv4(1, 2, 3, 4), dstPort: 443)
    }

    @Test func allocationIsUniqueAndStable() {
        let t = TCPNatTable(portRange: 1000...1009, maxEntries: 10)
        let a = t.lookupOrCreate(key(1), isNewConnection: true, now: 0)!
        let b = t.lookupOrCreate(key(2), isNewConnection: true, now: 0)!
        #expect(a.natPort != b.natPort)
        #expect(t.lookupOrCreate(key(1), isNewConnection: true, now: 1)?.natPort == a.natPort) // SYN retransmit
        #expect(t.lookupOrCreate(key(1), isNewConnection: false, now: 1)?.natPort == a.natPort)
        #expect(t.lookupOrCreate(key(3), isNewConnection: false, now: 1) == nil) // no entry from non-SYN
        #expect(t.count == 2)
    }

    @Test func collisionSkipsPortsInUse() {
        let t = TCPNatTable(portRange: 1000...1002, maxEntries: 3)
        let ports = (1...3).map { t.lookupOrCreate(key($0), isNewConnection: true, now: 0)!.natPort }
        #expect(Set(ports) == [1000, 1001, 1002])
        #expect(t.lookupOrCreate(key(4), isNewConnection: true, now: 0) == nil) // full, nothing closed
        // Free 1001; the allocator wraps around and must skip 1000 and 1002, still in use.
        t.markClosed(natPort: 1001, now: 0)
        let e = t.lookupOrCreate(key(5), isNewConnection: true, now: 1)!
        #expect(e.natPort == 1001)
        #expect(t.entry(forNatPort: 1000)?.key == key(1))
    }

    @Test func expiry() {
        let t = TCPNatTable(unacceptedTTL: 30, closedTTL: 10)
        let never = t.lookupOrCreate(key(1), isNewConnection: true, now: 0)!
        let open = t.lookupOrCreate(key(2), isNewConnection: true, now: 0)!
        let closed = t.lookupOrCreate(key(3), isNewConnection: true, now: 0)!
        t.markAccepted(natPort: open.natPort)
        t.markAccepted(natPort: closed.natPort)
        t.markClosed(natPort: closed.natPort, now: 25)
        #expect(t.expire(now: 29) == 0)
        #expect(t.expire(now: 30) == 1) // never accepted
        #expect(t.entry(forNatPort: never.natPort) == nil)
        #expect(t.expire(now: 34.9) == 0)
        #expect(t.expire(now: 35) == 1) // closed 10 s ago
        #expect(t.entry(forNatPort: open.natPort) != nil) // accepted and alive: kept
        #expect(t.expire(now: 10_000) == 0)
    }

    @Test func newSynAfterCloseGetsFreshPort() {
        let t = TCPNatTable()
        let a = t.lookupOrCreate(key(1), isNewConnection: true, now: 0)!
        t.markAccepted(natPort: a.natPort)
        t.markClosed(natPort: a.natPort, now: 1)
        let b = t.lookupOrCreate(key(1), isNewConnection: true, now: 2)!
        #expect(b.natPort != a.natPort)
        #expect(t.entry(forNatPort: a.natPort) == nil)
        #expect(!b.accepted)
    }

    @Test func fullTableEvictsOldestClosed() {
        let t = TCPNatTable(portRange: 1...4, maxEntries: 2)
        let a = t.lookupOrCreate(key(1), isNewConnection: true, now: 0)!
        let b = t.lookupOrCreate(key(2), isNewConnection: true, now: 0)!
        t.markClosed(natPort: b.natPort, now: 2)
        t.markClosed(natPort: a.natPort, now: 1)
        #expect(t.lookupOrCreate(key(3), isNewConnection: true, now: 3) != nil)
        #expect(t.entry(forNatPort: a.natPort) == nil) // oldest closed went first
        #expect(t.entry(forNatPort: b.natPort) != nil)
    }
}
