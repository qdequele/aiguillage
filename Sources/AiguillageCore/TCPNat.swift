/// The TCP "system stack" redirect: app SYNs to D:dport are rewritten so the kernel delivers them
/// to our own listener on 198.18.0.1:LPORT, using a NAT port to remember the original destination.
///
/// Not thread-safe: the daemon wraps it in a lock.

/// The 4-tuple of an app's original connection.
public struct FlowKey: Hashable, CustomStringConvertible, Sendable {
    public let srcIP: IPv4
    public let srcPort: UInt16
    public let dstIP: IPv4
    public let dstPort: UInt16

    public init(srcIP: IPv4, srcPort: UInt16, dstIP: IPv4, dstPort: UInt16) {
        self.srcIP = srcIP
        self.srcPort = srcPort
        self.dstIP = dstIP
        self.dstPort = dstPort
    }

    public var description: String { "\(srcIP):\(srcPort) -> \(dstIP):\(dstPort)" }
}

public struct NatEntry: Equatable, Sendable {
    public let key: FlowKey
    public let natPort: UInt16
    public let createdAt: Double
    public var accepted = false
    public var closedAt: Double?
}

public final class TCPNatTable {
    public let portRange: ClosedRange<UInt16>
    public let maxEntries: Int
    /// Entries never accepted by the listener expire this long after creation.
    public let unacceptedTTL: Double
    /// Entries are removed this long after their relay closed.
    public let closedTTL: Double

    private var byKey: [FlowKey: UInt16] = [:]
    private var byPort: [UInt16: NatEntry] = [:]
    private var nextPort: UInt16

    public init(portRange: ClosedRange<UInt16> = 20000...60000, maxEntries: Int = 8192,
                unacceptedTTL: Double = 30, closedTTL: Double = 10) {
        precondition(portRange.count >= maxEntries, "port range smaller than table")
        self.portRange = portRange
        self.maxEntries = maxEntries
        self.unacceptedTTL = unacceptedTTL
        self.closedTTL = closedTTL
        nextPort = portRange.lowerBound
    }

    public var count: Int { byPort.count }

    public func entry(forKey key: FlowKey) -> NatEntry? {
        byKey[key].flatMap { byPort[$0] }
    }

    public func entry(forNatPort port: UInt16) -> NatEntry? {
        byPort[port]
    }

    /// Returns the entry for `key`, creating one if `isNewConnection` (a pure SYN).
    /// A pure SYN for a flow whose relay already closed gets a fresh NAT port, because the old
    /// one may still be in TIME_WAIT on the listener side.
    /// Returns nil when there is no entry and none may be created (not a SYN, or table full).
    public func lookupOrCreate(_ key: FlowKey, isNewConnection: Bool, now: Double) -> NatEntry? {
        if let port = byKey[key], let e = byPort[port] {
            if isNewConnection && e.closedAt != nil {
                remove(port: port)
            } else {
                return e
            }
        }
        guard isNewConnection else { return nil }
        if byPort.count >= maxEntries {
            expire(now: now)
            if byPort.count >= maxEntries && !evictOldestClosed() {
                return nil
            }
        }
        guard let port = allocatePort() else { return nil }
        let e = NatEntry(key: key, natPort: port, createdAt: now)
        byKey[key] = port
        byPort[port] = e
        return e
    }

    /// Called by the listener when it accepts a connection from 198.18.0.2:natPort.
    @discardableResult
    public func markAccepted(natPort: UInt16) -> NatEntry? {
        guard var e = byPort[natPort] else { return nil }
        e.accepted = true
        byPort[natPort] = e
        return e
    }

    /// Called when the relay for this NAT port is fully closed.
    public func markClosed(natPort: UInt16, now: Double) {
        guard var e = byPort[natPort], e.closedAt == nil else { return }
        e.closedAt = now
        byPort[natPort] = e
    }

    /// Removes expired entries. Returns how many were removed.
    @discardableResult
    public func expire(now: Double) -> Int {
        var victims: [UInt16] = []
        for (port, e) in byPort {
            if let closed = e.closedAt {
                if now - closed >= closedTTL { victims.append(port) }
            } else if !e.accepted && now - e.createdAt >= unacceptedTTL {
                victims.append(port)
            }
        }
        victims.forEach(remove(port:))
        return victims.count
    }

    private func remove(port: UInt16) {
        if let e = byPort.removeValue(forKey: port) {
            byKey.removeValue(forKey: e.key)
        }
    }

    private func evictOldestClosed() -> Bool {
        let oldest = byPort.values.filter { $0.closedAt != nil }.min { $0.closedAt! < $1.closedAt! }
        guard let victim = oldest else { return false }
        remove(port: victim.natPort)
        return true
    }

    /// Round-robin over the range, skipping ports in use, so a port is not reused right away.
    private func allocatePort() -> UInt16? {
        for _ in 0..<portRange.count {
            let p = nextPort
            nextPort = p == portRange.upperBound ? portRange.lowerBound : p + 1
            if byPort[p] == nil { return p }
        }
        return nil
    }
}

/// Decides what to do with each IPv4/TCP packet read from the utun.
public final class TCPRedirector {
    public enum Action: Equatable {
        /// Write these bytes back to the utun.
        case write([UInt8])
        case drop(String)
    }

    public let listenerPort: UInt16
    public let table: TCPNatTable
    let local = TunnelAddresses.local
    let peer = TunnelAddresses.peer

    public init(listenerPort: UInt16, table: TCPNatTable = TCPNatTable()) {
        self.listenerPort = listenerPort
        self.table = table
    }

    public func handle(_ packet: IPv4Packet, now: Double) -> Action {
        var b = packet.bytes
        guard let seg = TCPSegment(packet: b, range: packet.payloadRange) else { return .drop("bad tcp header") }
        let src = packet.src, dst = packet.dst
        let sport = seg.srcPort(b), dport = seg.dstPort(b)

        // Reply from our listener towards the NAT address: restore the original endpoints.
        if src == local && sport == listenerPort && dst == peer {
            guard let e = table.entry(forNatPort: dport) else { return .drop("listener reply for unknown nat port \(dport)") }
            rewriteIPv4TCP(&b, src: e.key.dstIP, srcPort: e.key.dstPort, dst: e.key.srcIP, dstPort: e.key.srcPort)
            return .write(b)
        }

        // Only DNS is served on the peer address.
        if dst == peer && dport != 53 { return .drop("tcp to tunnel peer port \(dport)") }
        if dst.isMulticast || dst.isBroadcast { return .drop("tcp to multicast/broadcast") }
        // Tailscale (CGNAT) destinations belong to its utun; never relay them out a physical link.
        if dst.isCGNAT { return .drop("tcp to CGNAT/Tailscale address \(dst)") }

        let flags = seg.flags(b)
        let isNew = flags.contains(.syn) && !flags.contains(.ack)
        let key = FlowKey(srcIP: src, srcPort: sport, dstIP: dst, dstPort: dport)
        guard let e = table.lookupOrCreate(key, isNewConnection: isNew, now: now) else {
            // Unknown non-SYN (e.g. a connection from before a restart): reset it so the app reconnects.
            if let rst = buildIPv4TCPReset(answering: packet) { return .write(rst) }
            return .drop("no nat entry for \(key)")
        }
        rewriteIPv4TCP(&b, src: peer, srcPort: e.natPort, dst: local, dstPort: listenerPort)
        return .write(b)
    }
}
