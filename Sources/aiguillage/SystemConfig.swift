import AiguillageCore
import Foundation
import SystemConfiguration

/// Interface address and routes for the utun. Only the four half-space routes are ever added
/// (0/1, 128/1, ::/1, 8000::/1): anything more specific — LAN subnets, Tailscale's 100.64/10 and
/// per-peer routes, its fd7a:115c:a1e0::/48 — keeps winning by longest-prefix match.
/// The routes are tied to the utun and vanish when it is closed, so nothing is removed by hand.
enum TunnelConfig {
    static func configure(_ ifname: String) throws {
        try run("/sbin/ifconfig", [ifname, TunnelAddresses.local.description, TunnelAddresses.peer.description,
                                   "netmask", TunnelAddresses.netmask, "mtu", "1500", "up"])
        do {
            try run("/sbin/route", ["-n", "add", "-net", "0.0.0.0/1", "-interface", ifname])
            try run("/sbin/route", ["-n", "add", "-net", "128.0.0.0/1", "-interface", ifname])
        } catch let e as ShellError where e.output.contains("File exists") {
            throw UtunError("\(e.description)\nAnother tunnel already owns 0/1 or 128/1 (a VPN, or a Tailscale exit node). Disconnect it and retry.")
        }
        Log.info("\(ifname): \(TunnelAddresses.local) -> \(TunnelAddresses.peer), routes 0/1 and 128/1 installed")

        // IPv6: capture it so it can be refused quickly (apps then fall back to IPv4).
        do {
            try run("/sbin/ifconfig", [ifname, "inet6", "\(TunnelAddresses.ipv6Local)/64", "alias"])
            try run("/sbin/route", ["-n", "add", "-inet6", "::/1", "-interface", ifname])
            try run("/sbin/route", ["-n", "add", "-inet6", "8000::/1", "-interface", ifname])
            Log.info("\(ifname): IPv6 \(TunnelAddresses.ipv6Local)/64, routes ::/1 and 8000::/1 installed (IPv6 is refused)")
        } catch {
            Log.warn("IPv6 setup failed, IPv6 traffic will not be captured: \(error)")
        }
    }
}

/// Per-physical-link interface-scoped (`-ifscope`) default-half routes.
///
/// The global 0/1 + 128/1 routes on the utun shadow each link's real default route even for
/// IP_BOUND_IF-scoped lookups: a scoped lookup still picks the most-specific global route (0/1 →
/// utun), sees its interface differs from the bound one, and returns ENETUNREACH instead of
/// falling back to the link's own 0/0. These `-ifscope` routes give the bound lookup a specific
/// path for off-link destinations via the link's own gateway. They only match lookups scoped to
/// that interface (our egress sockets), so they never affect normal/global routing.
///
/// Unlike the utun routes, these are NOT tied to the utun fd, so they do not auto-vanish on crash.
/// We track and delete exactly what we added on teardown; leftovers after a `kill -9` are harmless
/// (scoped, unused unless something binds to that interface) and cleared on the next `up`.
final class ScopedRouteManager {
    private let lock = NSLock()
    /// ifname -> the gateways we installed routes for (so a router change triggers remove+reinstall).
    private var installed: [String: (v4: IPv4, v6: String?)] = [:]

    /// Installs/updates scoped routes so the set matches `links` exactly.
    func reconcile(_ links: [LinkInfo]) {
        lock.lock()
        defer { lock.unlock() }
        let desired = Dictionary(links.map { ($0.name, (v4: $0.router, v6: $0.routerV6)) },
                                 uniquingKeysWith: { a, _ in a })
        for (name, cur) in installed where desired[name]?.v4 != cur.v4 || desired[name]?.v6 != cur.v6 {
            removeLocked(name: name, gateways: cur)
        }
        for (name, gw) in desired where installed[name] == nil {
            installLocked(name: name, gateways: gw)
        }
    }

    private func installLocked(name: String, gateways gw: (v4: IPv4, v6: String?)) {
        // Delete-then-add makes it idempotent across restarts that kept the same gateway.
        for net in ["0.0.0.0/1", "128.0.0.0/1"] {
            _ = try? run("/sbin/route", ["-n", "delete", "-net", net, gw.v4.description, "-ifscope", name], allowFailure: true)
            do {
                try run("/sbin/route", ["-n", "add", "-net", net, gw.v4.description, "-ifscope", name])
            } catch {
                Log.warn("scoped route add \(net) via \(gw.v4) ifscope \(name) failed: \(error)")
            }
        }
        if let v6 = gw.v6 {
            for net in ["::/1", "8000::/1"] {
                _ = try? run("/sbin/route", ["-n", "delete", "-inet6", "-net", net, v6, "-ifscope", name], allowFailure: true)
                _ = try? run("/sbin/route", ["-n", "add", "-inet6", "-net", net, v6, "-ifscope", name], allowFailure: true)
            }
        }
        installed[name] = gw
        Log.info("scoped egress routes for \(name): 0/1 + 128/1 via \(gw.v4) -ifscope \(name)" +
                 (gw.v6.map { " (+ ::/1,8000::/1 via \($0))" } ?? ""))
    }

    private func removeLocked(name: String, gateways gw: (v4: IPv4, v6: String?)) {
        for net in ["0.0.0.0/1", "128.0.0.0/1"] {
            _ = try? run("/sbin/route", ["-n", "delete", "-net", net, gw.v4.description, "-ifscope", name], allowFailure: true)
        }
        if let v6 = gw.v6 {
            for net in ["::/1", "8000::/1"] {
                _ = try? run("/sbin/route", ["-n", "delete", "-inet6", "-net", net, v6, "-ifscope", name], allowFailure: true)
            }
        }
        installed[name] = nil
        Log.info("removed scoped egress routes for \(name)")
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        for (name, gw) in installed { removeLocked(name: name, gateways: gw) }
    }

    /// Best-effort deletion of the scoped routes for the currently discovered links, used at
    /// startup (before reinstalling) and by `aiguillage restore`. It cannot clean routes whose
    /// gateway has since changed; those leftovers are harmless.
    static func deleteForDiscoveredLinks() {
        for link in LinkDiscovery.discover() {
            for net in ["0.0.0.0/1", "128.0.0.0/1"] {
                _ = try? run("/sbin/route", ["-n", "delete", "-net", net, link.router.description, "-ifscope", link.name], allowFailure: true)
            }
            if let v6 = link.routerV6 {
                for net in ["::/1", "8000::/1"] {
                    _ = try? run("/sbin/route", ["-n", "delete", "-inet6", "-net", net, v6, "-ifscope", link.name], allowFailure: true)
                }
            }
        }
    }
}

enum DNSMode: String {
    case dynamicstore, networksetup, none
}

/// Points the system resolver at 198.18.0.2.
final class SystemDNS {
    let mode: DNSMode
    private var store: SCDynamicStore?
    private var key: String?
    static let stateFile = "/var/run/aiguillage-dns.json"
    static let serverAddress = TunnelAddresses.peer.description
    /// Our resolver's SearchOrder; Tailscale's match-all supplemental resolver uses ~102000,
    /// the regular per-service resolvers ~200000. Lower wins.
    static let searchOrder = 1

    init(mode: DNSMode) {
        self.mode = mode
    }

    func apply(linkNames: [String]) throws {
        switch mode {
        case .none:
            Log.info("dns: --dns-mode none, system DNS left alone (queries to 198.18.0.2 still work)")
        case .dynamicstore:
            try applyDynamicStore()
        case .networksetup:
            try NetworkSetupDNS.apply(interfaces: linkNames)
        }
        flushCache()
    }

    /// Adds services that appeared after startup (networksetup mode only).
    func linksChanged(_ linkNames: [String]) {
        guard mode == .networksetup else { return }
        do {
            try NetworkSetupDNS.apply(interfaces: linkNames)
        } catch {
            Log.warn("dns: networksetup update failed: \(error)")
        }
    }

    func teardown() {
        switch mode {
        case .none:
            return
        case .dynamicstore:
            if let store, let key {
                SCDynamicStoreRemoveValue(store, key as CFString)
                Log.info("dns: removed \(key)")
            }
            store = nil
        case .networksetup:
            NetworkSetupDNS.restore()
        }
        flushCache()
    }

    private func applyDynamicStore() throws {
        // Session keys disappear automatically when this process exits or crashes.
        let options = [kSCDynamicStoreUseSessionKeys: kCFBooleanTrue] as CFDictionary
        guard let store = SCDynamicStoreCreateWithOptions(nil, "aiguillage" as CFString, options, nil, nil) else {
            throw UtunError("SCDynamicStoreCreateWithOptions failed: \(String(cString: SCErrorString(SCError())))")
        }
        let key = "State:/Network/Service/\(UUID().uuidString)/DNS"
        let value: [String: Any] = [
            "ServerAddresses": [SystemDNS.serverAddress],
            "SupplementalMatchDomains": [""],
            "SearchOrder": SystemDNS.searchOrder,
        ]
        guard SCDynamicStoreSetValue(store, key as CFString, value as CFDictionary) else {
            throw UtunError("SCDynamicStoreSetValue(\(key)) failed: \(String(cString: SCErrorString(SCError())))")
        }
        self.store = store
        self.key = key
        Log.info("dns: set \(key) = \(SystemDNS.serverAddress) (match-all supplemental, SearchOrder \(SystemDNS.searchOrder))")
    }

    private func flushCache() {
        _ = try? run("/usr/bin/dscacheutil", ["-flushcache"], allowFailure: true)
        _ = try? run("/usr/bin/killall", ["-HUP", "mDNSResponder"], allowFailure: true)
    }

    /// Reads `scutil --dns` and reports where our resolver sits among match-all resolvers.
    /// Returns human-readable lines; `ok` is false when ours is missing or appears to be outranked.
    static func verify(mode: DNSMode) -> (ok: Bool, lines: [String]) {
        guard let out = try? run("/usr/sbin/scutil", ["--dns"], allowFailure: true) else {
            return (false, ["could not run scutil --dns"])
        }
        let resolvers = parseScutilDNS(out)
        var lines: [String] = []
        func describe(_ r: ScutilResolver) -> String {
            "resolver #\(r.number) \(r.nameservers.joined(separator: ",")) on \(r.interface ?? "-") order \(r.order.map(String.init) ?? "-")" +
                (r.flags.isEmpty ? "" : " [\(r.flags)]")
        }
        func whoIs(_ r: ScutilResolver) -> String {
            if r.nameservers.contains("100.100.100.100") { return "Tailscale MagicDNS (100.100.100.100)" }
            if r.interface?.hasPrefix("utun") == true || r.interface?.hasPrefix("ipsec") == true { return "a tunnel resolver" }
            return "another resolver"
        }
        let ourResolvers = resolvers.filter { $0.nameservers.contains(serverAddress) }
        guard !ourResolvers.isEmpty else {
            lines.append("198.18.0.2 is NOT in scutil --dns: the system resolver will not use Aiguillage.")
            if mode == .dynamicstore { lines.append("retry with: sudo aiguillage up --dns-mode networksetup") }
            return (false, lines)
        }

        if mode == .networksetup {
            // networksetup makes 198.18.0.2 a *primary* (non-supplemental) resolver on the service.
            // The first primary resolver is what macOS consults for names not matched by a more
            // specific supplemental (e.g. Tailscale keeps *.ts.net by specificity).
            let primaries = resolvers.filter { !$0.flags.contains("Supplemental") && !$0.options.contains("mdns") && !$0.nameservers.isEmpty }
            let oursPrimary = primaries.contains { $0.nameservers.contains(serverAddress) }
            if let first = primaries.first { lines.append("first primary resolver: \(describe(first))") }
            if oursPrimary, primaries.first?.nameservers.contains(serverAddress) == true {
                lines.append("ours (198.18.0.2) is the first primary resolver — good")
                lines.append("verify with: dig +short claude.ai ; dig +short <peer>.<tailnet>.ts.net ; scutil --dns | head -20")
                return (true, lines)
            }
            if oursPrimary {
                lines.append("198.18.0.2 is a primary resolver but not the first; check with `dig +short claude.ai`")
            } else {
                lines.append("WARNING: 198.18.0.2 is present but as a supplemental resolver, not primary: \(describe(ourResolvers[0]))")
            }
            lines.append("verify with: dig +short claude.ai ; dig +short <peer>.<tailnet>.ts.net ; scutil --dns | head -20")
            return (false, lines)
        }

        // dynamicstore (supplemental match-all): compare against other match-all resolvers.
        let matchAll = matchAllResolversByPriority(resolvers)
        guard let ours = matchAll.firstIndex(where: { $0.nameservers.contains(serverAddress) }) else {
            lines.append("198.18.0.2 is listed but not as a match-all resolver: \(describe(ourResolvers[0]))")
            lines.append("retry with: sudo aiguillage up --dns-mode networksetup (the default)")
            return (false, lines)
        }
        if let first = matchAll.first { lines.append("first match-all resolver: \(describe(first))") }
        if ours == 0 {
            lines.append("ours (198.18.0.2) is first among \(matchAll.count) match-all resolver(s)")
            return (true, lines)
        }
        for r in matchAll[..<ours] {
            lines.append("WARNING: \(whoIs(r)) is ahead of ours: \(describe(r)) — lookups go there first and die with the link it uses")
        }
        lines.append("ours is at position \(ours + 1) of \(matchAll.count); use --dns-mode networksetup (the default) instead")
        return (false, lines)
    }
}

/// `networksetup -setdnsservers` on the services of the active links, with the previous values
/// saved in /var/run so they can be restored after a crash (`aiguillage restore`).
enum NetworkSetupDNS {
    static let tool = "/usr/sbin/networksetup"

    /// service name -> previous servers ([] means "Empty", i.e. DHCP-provided).
    static func loadState() -> [String: [String]] {
        guard let data = FileManager.default.contents(atPath: SystemDNS.stateFile),
              let dict = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
        return dict
    }

    static func saveState(_ state: [String: [String]]) throws {
        let data = try JSONEncoder().encode(state)
        guard FileManager.default.createFile(atPath: SystemDNS.stateFile, contents: data) else {
            throw UtunError("cannot write \(SystemDNS.stateFile)")
        }
    }

    /// BSD interface name -> network service name, from `networksetup -listnetworkserviceorder`.
    static func serviceNames() -> [String: String] {
        guard let out = try? run(tool, ["-listnetworkserviceorder"], allowFailure: true) else { return [:] }
        var result: [String: String] = [:]
        var lastService: String?
        for line in out.split(separator: "\n").map(String.init) {
            if line.hasPrefix("("), let close = line.firstIndex(of: ")"), !line.hasPrefix("(Hardware") {
                lastService = String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("(Hardware Port:"), let r = line.range(of: "Device: ") {
                let dev = line[r.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                if let s = lastService, !dev.isEmpty { result[dev] = s }
            }
        }
        return result
    }

    static func currentServers(_ service: String) -> [String] {
        guard let out = try? run(tool, ["-getdnsservers", service], allowFailure: true) else { return [] }
        if out.contains("aren't any") { return [] }
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.contains(" ") }
    }

    static func apply(interfaces: [String]) throws {
        let names = serviceNames()
        var state = loadState()
        for ifname in interfaces {
            guard let service = names[ifname] else {
                Log.warn("dns: no network service found for \(ifname)")
                continue
            }
            if state[service] != nil { continue } // already applied
            let previous = currentServers(service).filter { $0 != SystemDNS.serverAddress }
            state[service] = previous
            try saveState(state) // save before changing anything
            try run(tool, ["-setdnsservers", service, SystemDNS.serverAddress])
            Log.info("dns: \(service) -> \(SystemDNS.serverAddress) (was \(previous.isEmpty ? "DHCP" : previous.joined(separator: " ")))")
        }
    }

    /// Restores saved values and deletes the state file. Safe to call when there is nothing saved.
    @discardableResult
    static func restore() -> Bool {
        let state = loadState()
        guard !state.isEmpty || FileManager.default.fileExists(atPath: SystemDNS.stateFile) else { return false }
        var allOK = true
        for (service, previous) in state.sorted(by: { $0.key < $1.key }) {
            let args = ["-setdnsservers", service] + (previous.isEmpty ? ["Empty"] : previous)
            do {
                try run(tool, args)
                Log.info("dns: restored \(service) to \(previous.isEmpty ? "DHCP (Empty)" : previous.joined(separator: " "))")
            } catch {
                allOK = false
                Log.error("dns: could not restore \(service): \(error)")
            }
        }
        if allOK { try? FileManager.default.removeItem(atPath: SystemDNS.stateFile) }
        return true
    }
}
