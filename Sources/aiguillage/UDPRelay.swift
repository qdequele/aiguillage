import AiguillageCore
import Foundation

struct UDPKey: Hashable, CustomStringConvertible {
    let srcIP: IPv4, srcPort: UInt16, dstIP: IPv4, dstPort: UInt16
    var description: String { "\(srcIP):\(srcPort) -> \(dstIP):\(dstPort)" }
}

/// One app UDP flow, carried by one connected UDP socket pinned to a link.
final class UDPFlow {
    let key: UDPKey
    let decision: RouteDecision?
    var link: Link
    var conn: BoundUDPSocket
    var tracker = UDPPinTracker()
    var lastActivity = monotonicNow()

    init(key: UDPKey, decision: RouteDecision?, link: Link, conn: BoundUDPSocket) {
        self.key = key
        self.decision = decision
        self.link = link
        self.conn = conn
    }
}

/// Per-flow UDP NAT. Runs on the engine queue.
final class UDPRelay {
    unowned let engine: Engine
    private(set) var flows: [UDPKey: UDPFlow] = [:]
    private var timer: DispatchSourceTimer?
    private var ipID: UInt16 = 0
    static let idleTimeout = 60.0
    static let maxFlows = 4096

    init(engine: Engine) {
        self.engine = engine
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: engine.queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        flows.values.forEach { $0.conn.close() }
        flows.removeAll()
    }

    /// Handles an app datagram (not DNS, not to the tunnel peer).
    func handle(src: IPv4, dst: IPv4, datagram: UDPDatagram) {
        let key = UDPKey(srcIP: src, srcPort: datagram.srcPort, dstIP: dst, dstPort: datagram.dstPort)
        let now = monotonicNow()
        let flow: UDPFlow
        if let f = flows[key] {
            flow = f
        } else {
            guard flows.count < UDPRelay.maxFlows else {
                Log.debug("udp: flow table full, dropping \(key)")
                return
            }
            let decision = engine.router.decision(for: dst, now: now)
            let (plan, links) = engine.links.plan(policy: decision?.policy, mode: engine.mode)
            if plan.blocked {
                Log.debug("udp \(key): blocked by rule \(decision!.label)")
                return
            }
            if let note = plan.note, let d = decision {
                Log.info("udp \(dst):\(datagram.dstPort) rule \(d.label): \(note)")
            }
            guard let link = links.first, let conn = makeConnection(key: key, link: link) else {
                Log.debug("udp \(key): no usable link")
                return
            }
            flow = UDPFlow(key: key, decision: decision, link: link, conn: conn)
            flows[key] = flow
            link.activeUDP += 1
            attach(flow)
            Log.debug("udp \(key) via \(link.name)" + (decision.map { " rule \($0.label)" } ?? ""))
        }
        flow.lastActivity = now
        flow.tracker.didSend(now: now)
        let data = Data(datagram.payload)
        flow.link.bytesUp += UInt64(data.count)
        flow.conn.send(data)
        maybeRepin(flow, now: now)
    }

    private func makeConnection(key: UDPKey, link: Link) -> BoundUDPSocket? {
        let idx = link.ifIndex
        guard idx != 0 else { return nil }
        return try? BoundUDPSocket.connected(to: key.dstIP, port: key.dstPort, ifIndex: idx, queue: engine.queue)
    }

    private func attach(_ flow: UDPFlow) {
        let conn = flow.conn
        conn.receiveLoop { [weak self, weak flow] data in
            guard let self, let flow, flow.conn === conn, !data.isEmpty else { return }
            flow.tracker.didReceive()
            flow.lastActivity = monotonicNow()
            flow.link.bytesDown += UInt64(data.count)
            self.ipID &+= 1
            let packet = buildIPv4UDP(src: flow.key.dstIP, srcPort: flow.key.dstPort,
                                      dst: flow.key.srcIP, dstPort: flow.key.srcPort,
                                      payload: [UInt8](data), id: self.ipID)
            self.engine.writeIPv4(packet)
        }
    }

    private func remove(_ flow: UDPFlow) {
        guard flows[flow.key] === flow else { return }
        flows[flow.key] = nil
        flow.link.activeUDP -= 1
        flow.conn.close()
    }

    /// Moves a flow to another link with a fresh socket.
    private func repin(_ flow: UDPFlow, to link: Link, reason: String) {
        guard let conn = makeConnection(key: flow.key, link: link) else { return }
        Log.debug("udp \(flow.key): re-pin \(flow.link.name) -> \(link.name) (\(reason))")
        flow.conn.close()
        flow.link.activeUDP -= 1
        flow.link = link
        link.activeUDP += 1
        flow.conn = conn
        flow.tracker = UDPPinTracker()
        attach(flow)
    }

    private func otherLink(than link: Link) -> Link? {
        engine.links.links.first { $0 !== link && $0.isUp }
    }

    private func maybeRepin(_ flow: UDPFlow, now: Double) {
        // A flow forced to a link by a rule stays there while that link is up.
        if let p = flow.decision?.policy, p == .cellular || p == .wifi, flow.link.isUp { return }
        guard let other = otherLink(than: flow.link) else { return }
        if flow.tracker.shouldRepin(now: now, otherLinkHealthy: true) {
            repin(flow, to: other, reason: "no replies")
        }
    }

    private func sweep() {
        let now = monotonicNow()
        for flow in Array(flows.values) {
            if now - flow.lastActivity > UDPRelay.idleTimeout {
                remove(flow)
            } else {
                maybeRepin(flow, now: now)
            }
        }
    }

    /// The link went down: move its flows to the other link if it is up, else drop them.
    func linkLost(_ name: String) {
        let affected = flows.values.filter { $0.link.name == name }
        for flow in affected {
            if let other = otherLink(than: flow.link) {
                repin(flow, to: other, reason: "\(name) lost")
            } else {
                remove(flow)
            }
        }
    }
}
