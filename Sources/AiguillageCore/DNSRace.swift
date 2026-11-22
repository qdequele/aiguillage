/// Decides which upstream answer to return when a DNS query is sent over several links.
///
/// The first positive answer (NOERROR with records) wins immediately. A negative answer
/// (NXDOMAIN / SERVFAIL / empty) is held for a grace period so the other link can still give a
/// positive one; when every link has answered or failed, the best negative (most preferred link)
/// is returned. Indices are link positions in preference order.
public struct DNSRaceState {
    public enum Decision: Equatable {
        /// Return these bytes to the client; the race is over.
        case reply([UInt8])
        /// Keep waiting. `startGrace`: start the grace timer now. `sendRemaining`: query every
        /// link not queried yet, without waiting for the normal delay.
        case wait(startGrace: Bool, sendRemaining: Bool)
        /// No link produced any answer; drop the query (the client will retry).
        case giveUp
    }

    public let linkCount: Int
    public private(set) var finished = false
    private var completed: Set<Int> = []
    private var negatives: [Int: [UInt8]] = [:]
    private var graceStarted = false

    public init(linkCount: Int) {
        self.linkCount = linkCount
    }

    public mutating func received(_ response: [UInt8], from index: Int) -> Decision {
        guard !finished else { return .wait(startGrace: false, sendRemaining: false) }
        switch DNS.classify(response: response) {
        case .positive:
            finished = true
            return .reply(response)
        case .negative:
            negatives[index] = response
            completed.insert(index)
            if let d = finishIfAllCompleted() { return d }
            let start = !graceStarted
            graceStarted = true
            return .wait(startGrace: start, sendRemaining: true)
        case .invalid:
            return failed(index)
        }
    }

    public mutating func failed(_ index: Int) -> Decision {
        guard !finished else { return .wait(startGrace: false, sendRemaining: false) }
        completed.insert(index)
        if let d = finishIfAllCompleted() { return d }
        return .wait(startGrace: false, sendRemaining: true)
    }

    public mutating func graceExpired() -> Decision {
        guard !finished, let best = bestNegative() else { return .wait(startGrace: false, sendRemaining: false) }
        finished = true
        return .reply(best)
    }

    private mutating func finishIfAllCompleted() -> Decision? {
        guard completed.count >= linkCount else { return nil }
        finished = true
        if let best = bestNegative() { return .reply(best) }
        return .giveUp
    }

    private func bestNegative() -> [UInt8]? {
        negatives.keys.min().flatMap { negatives[$0] }
    }
}
