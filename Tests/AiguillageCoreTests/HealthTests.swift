import Testing
@testable import AiguillageCore

@Suite struct LinkHealthTests {
    @Test func firstResultDecides() {
        var a = LinkHealth()
        #expect(a.record(.success(rtt: 0.05)) == .up)
        var b = LinkHealth()
        #expect(b.record(.failure) == .down)
        var c = LinkHealth()
        #expect(c.record(.captive) == .captive)
    }

    @Test func downAfterTwoFailures() {
        var h = LinkHealth()
        h.record(.success(rtt: 0.05))
        #expect(h.record(.failure) == nil)
        #expect(h.state == .up)
        #expect(h.record(.failure) == .down)
    }

    @Test func singleFailureIsForgiven() {
        var h = LinkHealth()
        h.record(.success(rtt: 0.05))
        h.record(.failure)
        h.record(.success(rtt: 0.05))
        #expect(h.record(.failure) == nil)
        #expect(h.state == .up)
    }

    @Test func upAfterThreeSuccesses() {
        var h = LinkHealth()
        h.record(.failure)
        #expect(h.record(.success(rtt: 0.1)) == nil)
        #expect(h.record(.success(rtt: 0.1)) == nil)
        #expect(h.record(.success(rtt: 0.1)) == .up)
    }

    @Test func failureResetsSuccessStreak() {
        var h = LinkHealth()
        h.record(.failure)
        h.record(.success(rtt: 0.1))
        h.record(.success(rtt: 0.1))
        h.record(.failure)
        h.record(.success(rtt: 0.1))
        h.record(.success(rtt: 0.1))
        #expect(h.state == .down)
        #expect(h.record(.success(rtt: 0.1)) == .up)
    }

    @Test func captiveTransitions() {
        var h = LinkHealth()
        h.record(.success(rtt: 0.05))
        h.record(.captive)
        #expect(h.record(.captive) == .captive) // portal appeared
        #expect(h.record(.failure) == .down)    // while not up, follows the latest result
        #expect(h.record(.captive) == .captive)
    }

    @Test func rttEWMA() {
        var h = LinkHealth()
        h.record(.success(rtt: 0.1))
        #expect(h.rtt == 0.1)
        h.record(.success(rtt: 0.5))
        #expect(abs(h.rtt! - 0.2) < 1e-9) // 0.1 + 0.25 * 0.4
        h.record(.failure)
        #expect(abs(h.rtt! - 0.2) < 1e-9) // failures do not touch the RTT
    }

    @Test func connectFailuresMarkDown() {
        var h = LinkHealth()
        h.record(.success(rtt: 0.05))
        #expect(h.recordConnect(success: false) == nil)
        #expect(h.recordConnect(success: false) == nil)
        #expect(h.recordConnect(success: true) == nil) // resets the streak
        h.recordConnect(success: false)
        h.recordConnect(success: false)
        #expect(h.recordConnect(success: false) == .down)
        // Probes must then bring it back with three successes.
        h.record(.success(rtt: 0.05))
        h.record(.success(rtt: 0.05))
        #expect(h.record(.success(rtt: 0.05)) == .up)
    }
}

@Suite struct SchedulingTests {
    @Test func stagger() {
        #expect(Scheduling.stagger(firstLinkState: .up, firstLinkRTT: 0.05) == 0.3)
        #expect(abs(Scheduling.stagger(firstLinkState: .up, firstLinkRTT: 0.2) - 0.4) < 1e-9)
        #expect(Scheduling.stagger(firstLinkState: .up, firstLinkRTT: 0.9) == 1.0)
        #expect(Scheduling.stagger(firstLinkState: .up, firstLinkRTT: nil) == 0.3)
        #expect(Scheduling.stagger(firstLinkState: .down, firstLinkRTT: 0.2) == 0)
        #expect(Scheduling.stagger(firstLinkState: .captive, firstLinkRTT: 0.2) == 0)
        #expect(Scheduling.stagger(firstLinkState: .unknown, firstLinkRTT: nil) == 0)
    }

    @Test func order() {
        #expect(Scheduling.order([(id: "en0", state: .up), (id: "en7", state: .up)]) == ["en0", "en7"])
        #expect(Scheduling.order([(id: "en0", state: .captive), (id: "en7", state: .up)]) == ["en7", "en0"])
        #expect(Scheduling.order([(id: "en0", state: .down), (id: "en7", state: .down)]) == ["en0", "en7"])
    }

    @Test func probeInterval() {
        #expect(Scheduling.probeInterval(state: .up, isSecondary: false, primaryIsUp: true) == 2)
        #expect(Scheduling.probeInterval(state: .up, isSecondary: true, primaryIsUp: true) == 5)
        #expect(Scheduling.probeInterval(state: .up, isSecondary: true, primaryIsUp: false) == 2)
        #expect(Scheduling.probeInterval(state: .down, isSecondary: true, primaryIsUp: true) == 1)
    }

    @Test func udpRepin() {
        var t = UDPPinTracker()
        t.didSend(now: 0)
        t.didSend(now: 0.5)
        #expect(!t.shouldRepin(now: 2, otherLinkHealthy: true)) // only 2 datagrams
        t.didSend(now: 1)
        #expect(!t.shouldRepin(now: 1.4, otherLinkHealthy: true)) // window not elapsed
        #expect(t.shouldRepin(now: 1.5, otherLinkHealthy: true))
        #expect(!t.shouldRepin(now: 1.5, otherLinkHealthy: false))
        t.didReceive()
        #expect(!t.shouldRepin(now: 10, otherLinkHealthy: true))
    }

    @Test func planWithoutRuleUsesGlobalMode() {
        let p = Scheduling.plan(policy: nil, globalMode: .race, primary: LinkCandidate(id: "en0", state: .up), secondary: LinkCandidate(id: "en7", state: .up))
        #expect(p == LinkPlan(links: ["en0", "en7"], mode: .race))
    }

    @Test func planCellularForcesSecondary() {
        let p = Scheduling.plan(policy: .cellular, globalMode: .race, primary: LinkCandidate(id: "en0", state: .up), secondary: LinkCandidate(id: "en7", state: .up))
        #expect(p == LinkPlan(links: ["en7"], mode: .failover))
        let w = Scheduling.plan(policy: .wifi, globalMode: .race, primary: LinkCandidate(id: "en0", state: .up), secondary: LinkCandidate(id: "en7", state: .up))
        #expect(w.links == ["en0"])
    }

    @Test func planForcedLinkDownFailsOver() {
        let p = Scheduling.plan(policy: .cellular, globalMode: .race, primary: LinkCandidate(id: "en0", state: .up), secondary: LinkCandidate(id: "en7", state: .down))
        #expect(p.links == ["en0", "en7"])
        #expect(p.mode == .failover)
        #expect(p.note != nil)
        let absent = Scheduling.plan(policy: .cellular, globalMode: .race, primary: LinkCandidate(id: "en0", state: .up), secondary: nil)
        #expect(absent.links == ["en0"])
        #expect(absent.note != nil)
    }

    @Test func bestPicksHigherScore() {
        let wifi = LinkCandidate(id: "en0", state: .up, rtt: 0.400)
        let phone = LinkCandidate(id: "en7", state: .up, rtt: 0.060)
        #expect(Scheduling.best(primary: wifi, secondary: phone)?.id == "en7") // clearly faster
        let slowPhone = LinkCandidate(id: "en7", state: .up, rtt: 0.900) // weak 4G in a tunnel
        #expect(Scheduling.best(primary: wifi, secondary: slowPhone)?.id == "en0")
        let flaky = LinkCandidate(id: "en0", state: .up, rtt: 0.100, recentFailures: 1)
        let steady = LinkCandidate(id: "en7", state: .up, rtt: 0.110)
        #expect(Scheduling.best(primary: flaky, secondary: steady)?.id == "en7") // RTT tied, fewer failures
    }

    @Test func bestTieGoesToPrimary() {
        let wifi = LinkCandidate(id: "en0", state: .up, rtt: 0.100)
        let phone = LinkCandidate(id: "en7", state: .up, rtt: 0.070) // within the 50 ms margin
        #expect(Scheduling.best(primary: wifi, secondary: phone)?.id == "en0")
        #expect(Scheduling.best(primary: LinkCandidate(id: "en0", state: .unknown),
                                secondary: LinkCandidate(id: "en7", state: .unknown))?.id == "en0")
    }

    @Test func bestNeverPicksDownWhenOtherIsUp() {
        let deadWifi = LinkCandidate(id: "en0", state: .down, rtt: 0.010) // great RTT history, now dead
        let phone = LinkCandidate(id: "en7", state: .up, rtt: 0.800)
        #expect(Scheduling.best(primary: deadWifi, secondary: phone)?.id == "en7")
        let portal = LinkCandidate(id: "en0", state: .captive, rtt: 0.010)
        #expect(Scheduling.best(primary: portal, secondary: phone)?.id == "en7")
        let deadPhone = LinkCandidate(id: "en7", state: .down)
        #expect(Scheduling.best(primary: LinkCandidate(id: "en0", state: .up, rtt: 0.9), secondary: deadPhone)?.id == "en0")
        #expect(Scheduling.best(primary: nil, secondary: phone)?.id == "en7")
    }

    @Test func planBestDialsOneLinkFirst() {
        let p = Scheduling.plan(policy: .best, globalMode: .race,
                                primary: LinkCandidate(id: "en0", state: .down),
                                secondary: LinkCandidate(id: "en7", state: .up))
        #expect(p == LinkPlan(links: ["en7", "en0"], mode: .failover))
        let tie = Scheduling.plan(policy: .best, globalMode: .race,
                                  primary: LinkCandidate(id: "en0", state: .up, rtt: 0.1),
                                  secondary: LinkCandidate(id: "en7", state: .up, rtt: 0.1))
        #expect(tie.links.first == "en0")
        #expect(tie.mode == .failover) // never a race
    }

    @Test func planBlockAndModeOverrides() {
        let b = Scheduling.plan(policy: .block, globalMode: .race, primary: LinkCandidate(id: "en0", state: .up), secondary: nil)
        #expect(b.blocked && b.links.isEmpty)
        let f = Scheduling.plan(policy: .failover, globalMode: .race, primary: LinkCandidate(id: "en0", state: .up), secondary: LinkCandidate(id: "en7", state: .up))
        #expect(f.mode == .failover && f.links == ["en0", "en7"])
        let r = Scheduling.plan(policy: .race, globalMode: .failover, primary: LinkCandidate(id: "en0", state: .up), secondary: nil)
        #expect(r.mode == .race)
    }
}
