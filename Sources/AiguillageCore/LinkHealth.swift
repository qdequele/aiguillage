/// Pure link health state machine fed by probe results and TCP connect results.

public enum LinkState: String, Codable, Sendable {
    /// No probe has completed yet.
    case unknown
    case up
    /// The captive-portal probe got an HTTP answer, but not Apple's "Success" page.
    case captive
    case down
}

public enum ProbeResult: Equatable, Sendable {
    case success(rtt: Double)
    case captive
    case failure
}

public struct LinkHealthConfig: Sendable {
    /// Consecutive failed (or captive) probes before an `up` link leaves `up`.
    public var failuresToLeaveUp = 2
    /// Consecutive successful probes before a non-up link becomes `up`.
    public var successesToBecomeUp = 3
    /// Consecutive failed relay connects (see `recordConnect`) before an `up` link is marked down.
    public var connectFailuresToDown = 3
    /// Weight of a new RTT sample in the EWMA.
    public var rttAlpha = 0.25

    public init() {}
}

public struct LinkHealth: Sendable {
    public let config: LinkHealthConfig
    public private(set) var state: LinkState = .unknown
    /// Smoothed RTT in seconds, from successful probes.
    public private(set) var rtt: Double?
    public private(set) var consecutiveSuccesses = 0
    public private(set) var consecutiveFailures = 0
    public private(set) var consecutiveConnectFailures = 0

    public init(config: LinkHealthConfig = LinkHealthConfig()) {
        self.config = config
    }

    public var isUp: Bool { state == .up }

    /// Applies a probe result. Returns the new state if it changed.
    ///
    /// Rules: the first result decides directly (so startup is not delayed); afterwards `up` is left
    /// after `failuresToLeaveUp` consecutive non-successes (becoming `captive` or `down` according to
    /// the latest result), and `up` is reached after `successesToBecomeUp` consecutive successes.
    /// While not up, the state follows the latest non-success result (captive vs down).
    @discardableResult
    public mutating func record(_ result: ProbeResult) -> LinkState? {
        let old = state
        switch result {
        case .success(let sample):
            consecutiveSuccesses += 1
            consecutiveFailures = 0
            rtt = rtt.map { $0 + config.rttAlpha * (sample - $0) } ?? sample
            if state == .unknown || (state != .up && consecutiveSuccesses >= config.successesToBecomeUp) {
                state = .up
                consecutiveConnectFailures = 0
            }
        case .captive, .failure:
            consecutiveFailures += 1
            consecutiveSuccesses = 0
            let target: LinkState = result == .captive ? .captive : .down
            if state != .up || consecutiveFailures >= config.failuresToLeaveUp {
                state = target
            }
        }
        return state == old ? nil : state
    }

    /// Feeds the outcome of a relay connection attempt on this link.
    /// Repeated failures while the probe still says `up` mark the link down early (the probe then
    /// needs `successesToBecomeUp` successes to bring it back).
    @discardableResult
    public mutating func recordConnect(success: Bool) -> LinkState? {
        if success {
            consecutiveConnectFailures = 0
            return nil
        }
        consecutiveConnectFailures += 1
        if state == .up && consecutiveConnectFailures >= config.connectFailuresToDown {
            state = .down
            consecutiveSuccesses = 0
            consecutiveConnectFailures = 0
            return .down
        }
        return nil
    }
}
