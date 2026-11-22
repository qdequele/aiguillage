import AiguillageCore
import Darwin
import Foundation

/// `aiguillage doctor`: unprivileged checks. Probes run bound to each link, like the daemon's.
func runDoctor() -> Int32 {
    print("aiguillage doctor")
    print(geteuid() == 0 ? "running as root" : "running unprivileged (fine for doctor; `up` needs sudo)")

    let found = LinkDiscovery.discover()
    let (primary, secondary) = LinkManager.assignRoles(found, primary: nil, secondary: nil)
    print("\nlinks:")
    if found.isEmpty { print("  none (no physical interface with an IPv4 address and a router)") }
    let queue = DispatchQueue(label: "doctor")
    let prober = Prober(queue: queue)
    for link in found {
        let role = link.name == primary?.name ? "primary" : link.name == secondary?.name ? "secondary" : "unused"
        let idx = if_nametoindex(link.name)
        print("  \(link.name) (\(link.displayName))\(link.isWiFi ? " wifi" : "") role \(role)")
        print("    address \(link.address) router \(link.router)")
        print("    resolvers \(link.resolvers.map(\.description).joined(separator: ", ")) [\(link.resolverSource)]")
        guard idx != 0 else {
            print("    if_nametoindex = 0: interface absent (the daemon could not bind to it)")
            continue
        }
        let sem = DispatchSemaphore(value: 0)
        var line = ""
        queue.async {
            prober.probe(link: link, ifIndex: idx) { result, detail in
                switch result {
                case .success(let rtt): line = "up (rtt \(formatRTT(rtt)))"
                case .captive: line = "captive (\(detail))"
                case .failure: line = "down (\(detail))"
                }
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 5)
        print("    probe http://\(Prober.host)/hotspot-detect.html bound to \(link.name) (IP_BOUND_IF): \(line.isEmpty ? "no result" : line)")
    }

    print("\ntunnels:")
    let tunnels = Tunnels.report()
    if tunnels.info.isEmpty && tunnels.warnings.isEmpty { print("  no other tunnel holds the default route") }
    tunnels.info.forEach { print("  \($0)") }
    tunnels.warnings.forEach { print("  WARNING: \($0)") }
    if tunnels.warnings.isEmpty && !tunnels.info.isEmpty { print("  no other tunnel holds the default route") }

    print("\nsystem DNS (match-all resolvers, by priority):")
    if let out = try? run("/usr/sbin/scutil", ["--dns"], allowFailure: true) {
        let all = matchAllResolversByPriority(parseScutilDNS(out))
        for r in all {
            let tag = r.nameservers.contains("100.100.100.100") ? " (Tailscale MagicDNS)" :
                r.nameservers.contains(SystemDNS.serverAddress) ? " (Aiguillage)" : ""
            print("  order \(r.order.map(String.init) ?? "-") \(r.nameservers.joined(separator: ", ")) on \(r.interface ?? "-")\(tag)")
        }
        if all.contains(where: { $0.nameservers.contains("100.100.100.100") }) {
            print("  note: default --dns-mode networksetup installs 198.18.0.2 as a *primary* resolver on the active services, which outranks Tailscale's supplemental; ts.net names keep going to MagicDNS by specificity")
        }
    }

    print("\nrouting rules:")
    do {
        let (rules, files) = try loadRules(cli: [], noDefaults: false)
        print("  files: \(files.isEmpty ? "none (looked at \(rulesFilePaths().joined(separator: ", ")))" : files.joined(separator: ", "))")
        for r in rules.rules { print("  \(r.description)  [\(r.source.rawValue)]") }
    } catch {
        print("  ERROR: \(error)")
    }

    print("\ndaemon:")
    if let data = StatusSocket.query(), let s = try? JSONDecoder().decode(StatusSnapshot.self, from: data) {
        print("  running (pid \(s.pid) on \(s.utun)); \(s.tcpFlows) tcp / \(s.udpFlows) udp flows")
        for f in s.flows where f.rule != nil {
            print("  \(f.proto) \(f.destination) via \(f.link ?? "-") rule \(f.rule!) (\(f.policy ?? "-"))")
        }
    } else {
        print("  not running")
    }
    if FileManager.default.fileExists(atPath: SystemDNS.stateFile) {
        print("  WARNING: \(SystemDNS.stateFile) exists: DNS was changed by --dns-mode networksetup; run `sudo aiguillage restore` if the daemon is not running")
    }
    return 0
}
