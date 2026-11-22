import AiguillageCore
import Darwin
import Foundation

enum LinkRole: String, Codable {
    case primary, secondary
}

/// One managed link: discovery info, health, counters. Lives on the engine queue.
final class Link {
    let role: LinkRole
    var info: LinkInfo
    var health = LinkHealth()
    var bytesUp: UInt64 = 0
    var bytesDown: UInt64 = 0
    var activeTCP = 0
    var activeUDP = 0
    /// Bumped when this object is retired, so its probe loop stops.
    var retired = false

    init(role: LinkRole, info: LinkInfo) {
        self.role = role
        self.info = info
    }

    var name: String { info.name }
    var state: LinkState { health.state }
    /// Kernel interface index, looked up live (0 once the interface disappears). Egress binds to it.
    var ifIndex: UInt32 { if_nametoindex(info.name) }
    /// Usable for egress: present in the kernel and healthy.
    var isUp: Bool { health.isUp && ifIndex != 0 }
    var isPresent: Bool { ifIndex != 0 }
}

/// Discovers the two links, probes them, and answers "which link(s) should this flow use".
/// All methods must be called on `queue`.
final class LinkManager {
    let queue: DispatchQueue
    let registry: InterfaceRegistry
    let prober: Prober
    let primaryOverride: String?
    let secondaryOverride: String?

    private(set) var primary: Link?
    private(set) var secondary: Link?

    /// Called when a link stops being usable (left `up`, disappeared, or changed network).
    var onLinkLost: ((String) -> Void)?
    /// Called after every discovery pass with the current links' info (for scoped-route syncing).
    var onLinksUpdated: (([LinkInfo]) -> Void)?

    init(queue: DispatchQueue, registry: InterfaceRegistry, primary: String?, secondary: String?) {
        self.queue = queue
        self.registry = registry
        self.prober = Prober(queue: queue)
        primaryOverride = primary
        secondaryOverride = secondary
    }

    var links: [Link] { [primary, secondary].compactMap { $0 } }

    func link(named name: String) -> Link? {
        links.first { $0.name == name }
    }

    func start() {
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        discoveryTimer = timer
        registry.onChange = { [weak self] in
            self?.queue.async { self?.refresh() }
        }
    }

    private var discoveryTimer: DispatchSourceTimer?

    /// Picks primary/secondary among discovered interfaces.
    static func assignRoles(_ found: [LinkInfo], primary: String?, secondary: String?) -> (LinkInfo?, LinkInfo?) {
        let p: LinkInfo?
        if let primary {
            p = found.first { $0.name == primary }
        } else {
            p = found.first { $0.isWiFi } ?? found.first { $0.name != secondary }
        }
        let s: LinkInfo?
        if let secondary {
            s = found.first { $0.name == secondary && $0.name != p?.name }
        } else {
            s = found.first { $0.name != p?.name && !$0.isWiFi } ?? found.first { $0.name != p?.name }
        }
        return (p, s)
    }

    func refresh() {
        let found = LinkDiscovery.discover()
        let (p, s) = LinkManager.assignRoles(found, primary: primaryOverride, secondary: secondaryOverride)
        primary = update(primary, with: p, role: .primary)
        secondary = update(secondary, with: s, role: .secondary)
        onLinksUpdated?(links.map(\.info))
    }

    private func update(_ current: Link?, with info: LinkInfo?, role: LinkRole) -> Link? {
        if let current, let info, current.info.sameNetwork(as: info) {
            if current.info.resolvers != info.resolvers {
                Log.info("\(role.rawValue) \(info.name): resolvers now \(info.resolvers.map(\.description).joined(separator: ", "))")
            }
            current.info = info
            return current
        }
        if let current {
            current.retired = true
            if let info {
                Log.info("\(role.rawValue) \(current.name): network changed (\(current.info.address) -> \(info.address) on \(info.name))")
            } else {
                Log.info("\(role.rawValue) \(current.name): gone")
            }
            onLinkLost?(current.name)
        }
        guard let info else { return nil }
        let link = Link(role: role, info: info)
        Log.info("\(role.rawValue) link: \(info.name) (\(info.displayName)) \(info.address) via \(info.router), dns \(info.resolvers.map(\.description).joined(separator: ", ")) [\(info.resolverSource)]")
        if link.ifIndex == 0 {
            Log.warn("\(info.name): if_nametoindex is 0; link unusable until the interface appears")
        }
        scheduleProbe(link, after: 0)
        return link
    }

    private func scheduleProbe(_ link: Link, after delay: Double) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !link.retired else { return }
            let idx = link.ifIndex
            guard idx != 0 else {
                self.apply(.failure, detail: "interface absent", to: link)
                self.scheduleProbe(link, after: 1)
                return
            }
            self.prober.probe(link: link.info, ifIndex: idx) { result, detail in
                guard !link.retired else { return }
                self.apply(result, detail: detail, to: link)
                let interval = Scheduling.probeInterval(state: link.state, isSecondary: link.role == .secondary,
                                                        primaryIsUp: self.primary?.isUp ?? false)
                self.scheduleProbe(link, after: interval)
            }
        }
    }

    private func apply(_ result: ProbeResult, detail: String, to link: Link) {
        let old = link.state
        if case .success(let rtt) = result {
            Log.debug("probe \(link.name): ok \(formatRTT(rtt))")
        } else {
            Log.debug("probe \(link.name): \(result) (\(detail))")
        }
        if let new = link.health.record(result) {
            transitioned(link, from: old, to: new, reason: detail)
        }
    }

    /// Feeds a relay connect outcome into the link's health.
    func recordConnect(on name: String, success: Bool) {
        guard let link = link(named: name) else { return }
        let old = link.state
        if let new = link.health.recordConnect(success: success) {
            transitioned(link, from: old, to: new, reason: "repeated connect failures")
        }
    }

    private func transitioned(_ link: Link, from old: LinkState, to new: LinkState, reason: String) {
        Log.info("link \(link.name) (\(link.role.rawValue)): \(old.rawValue) -> \(new.rawValue)" +
                 (new == .up ? " rtt \(formatRTT(link.health.rtt))" : " (\(reason))"))
        if old == .up && new != .up {
            onLinkLost?(link.name)
        }
    }

    /// Links to try for a new flow, best first. Absent interfaces are skipped.
    func orderedLinks() -> [Link] {
        let usable = links.filter { $0.isPresent }
        let ids = Scheduling.order(usable.map { (id: $0.name, state: $0.state) })
        return ids.compactMap { link(named: $0) }
    }

    /// Links and mode for a new flow, given the matching rule's policy (nil = no rule).
    func plan(policy: LinkPolicy?, mode: RelayMode) -> (plan: LinkPlan<String>, links: [Link]) {
        func entry(_ l: Link?) -> LinkCandidate<String>? {
            guard let l, l.isPresent else { return nil }
            return LinkCandidate(id: l.name, state: l.state, rtt: l.health.rtt,
                                 recentFailures: l.health.consecutiveFailures + l.health.consecutiveConnectFailures)
        }
        let p = Scheduling.plan(policy: policy, globalMode: mode, primary: entry(primary), secondary: entry(secondary))
        return (p, p.links.compactMap { link(named: $0) })
    }

    /// Delay before racing the second link, given the first one chosen.
    func stagger(first: Link) -> Double {
        Scheduling.stagger(firstLinkState: first.state, firstLinkRTT: first.health.rtt)
    }
}
