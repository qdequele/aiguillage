/// Pure decisions used by the relays: link order, race stagger, probe interval, UDP re-pinning.

public enum Scheduling {
    /// Delay before starting the second connection attempt in race mode:
    /// `clamp(2 × primary RTT, 300 ms, 1 s)`, or 0 when the first link is not up.
    public static func stagger(firstLinkState: LinkState, firstLinkRTT: Double?,
                               minimum: Double = 0.3, maximum: Double = 1.0) -> Double {
        guard firstLinkState == .up else { return 0 }
        guard let rtt = firstLinkRTT else { return minimum }
        return min(max(2 * rtt, minimum), maximum)
    }

    /// Orders links for a new flow: `up` links first, then the others, each group keeping the
    /// given preference order (primary before secondary).
    public static func order<ID>(_ links: [(id: ID, state: LinkState)]) -> [ID] {
        links.filter { $0.state == .up }.map(\.id) + links.filter { $0.state != .up }.map(\.id)
    }

    /// Seconds to wait before the next probe of a link.
    public static func probeInterval(state: LinkState, isSecondary: Bool, primaryIsUp: Bool) -> Double {
        if state != .up { return 1 }
        if isSecondary && primaryIsUp { return 5 }
        return 2
    }
}

public enum RelayMode: String, Codable, Sendable {
    case race, failover
}

/// Which links a new flow may use, in order, and how to use them.
public struct LinkPlan<ID: Equatable>: Equatable {
    public var links: [ID]
    public var mode: RelayMode
    public var blocked = false
    /// Set when a forced link was unavailable and we fell back.
    public var note: String?
}

/// What the planner knows about a link when a flow opens.
public struct LinkCandidate<ID: Equatable>: Equatable {
    public var id: ID
    public var state: LinkState
    /// Smoothed probe RTT in seconds, if known.
    public var rtt: Double?
    /// Recent failures (consecutive failed probes + consecutive failed connects).
    public var recentFailures: Int

    public init(id: ID, state: LinkState, rtt: Double? = nil, recentFailures: Int = 0) {
        self.id = id
        self.state = state
        self.rtt = rtt
        self.recentFailures = recentFailures
    }
}

extension Scheduling {
    /// RTT difference under which two links of the same state count as tied for `best`.
    public static let bestRTTMargin = 0.05

    static func stateRank(_ s: LinkState) -> Int {
        switch s {
        case .up: return 3
        case .captive: return 2
        case .unknown: return 1
        case .down: return 0
        }
    }

    /// Picks the healthier link: state (up > captive > unknown > down), then lower RTT EWMA
    /// (only if the gap exceeds `margin`), then fewer recent failures. A tie goes to the primary,
    /// which saves cellular data.
    public static func best<ID>(primary: LinkCandidate<ID>?, secondary: LinkCandidate<ID>?,
                                margin: Double = bestRTTMargin) -> LinkCandidate<ID>? {
        guard let p = primary else { return secondary }
        guard let s = secondary else { return p }
        let rp = stateRank(p.state), rs = stateRank(s.state)
        if rp != rs { return rp > rs ? p : s }
        if let a = p.rtt, let b = s.rtt, abs(a - b) > margin { return a < b ? p : s }
        if p.recentFailures != s.recentFailures { return p.recentFailures < s.recentFailures ? p : s }
        return p
    }

    /// Applies a rule policy (nil = no rule) on top of the global mode.
    /// `cellular`/`wifi` use only the forced link while it is up; when it is not, the flow fails
    /// over to whatever is usable rather than failing. `best` dials only the healthier link (the
    /// other one is tried only if that attempt fails, as in failover). `block` always blocks.
    public static func plan<ID: Equatable>(policy: LinkPolicy?, globalMode: RelayMode,
                                           primary: LinkCandidate<ID>?,
                                           secondary: LinkCandidate<ID>?) -> LinkPlan<ID> {
        let present = [primary, secondary].compactMap { $0 }
        let all = order(present.map { (id: $0.id, state: $0.state) })
        switch policy {
        case nil:
            return LinkPlan(links: all, mode: globalMode)
        case .race?:
            return LinkPlan(links: all, mode: .race)
        case .failover?:
            return LinkPlan(links: all, mode: .failover)
        case .block?:
            return LinkPlan(links: [], mode: globalMode, blocked: true)
        case .best?:
            guard let pick = best(primary: primary, secondary: secondary) else {
                return LinkPlan(links: [], mode: .failover)
            }
            return LinkPlan(links: [pick.id] + all.filter { $0 != pick.id }, mode: .failover)
        case .cellular?, .wifi?:
            let forced = policy == .cellular ? secondary : primary
            if let forced, forced.state == .up {
                return LinkPlan(links: [forced.id], mode: .failover)
            }
            let what = policy == .cellular ? "secondary (cellular)" : "primary (wifi)"
            return LinkPlan(links: all, mode: .failover,
                            note: forced == nil ? "\(what) link absent, failing over" : "\(what) link \(forced!.state.rawValue), failing over")
        }
    }
}

/// Tracks whether a UDP flow looks dead on its current link.
/// Re-pin when ≥ `minDatagrams` were sent since the last reply and the oldest of them is at least
/// `window` seconds old, provided the other link is healthy.
public struct UDPPinTracker: Sendable {
    public var minDatagrams = 3
    public var window = 1.5
    public private(set) var unanswered = 0
    public private(set) var firstUnansweredAt: Double?

    public init() {}

    public mutating func didSend(now: Double) {
        if unanswered == 0 { firstUnansweredAt = now }
        unanswered += 1
    }

    public mutating func didReceive() {
        unanswered = 0
        firstUnansweredAt = nil
    }

    public func shouldRepin(now: Double, otherLinkHealthy: Bool) -> Bool {
        guard otherLinkHealthy, unanswered >= minDatagrams, let first = firstUnansweredAt else { return false }
        return now - first >= window
    }
}
