import AiguillageCore
import Darwin
import Foundation

/// Another tunnel interface on the machine (Tailscale, a VPN...).
struct OtherTunnel {
    let name: String
    let addresses: [IPv4]
    /// Tailscale is recognised by an address in 100.64.0.0/10 on a utun.
    var isTailscale: Bool { name.hasPrefix("utun") && addresses.contains { $0.isCGNAT } }
}

enum Tunnels {
    static func isTunnelName(_ n: String) -> Bool {
        n.hasPrefix("utun") || n.hasPrefix("ipsec") || n.hasPrefix("ppp")
    }

    /// Tunnel interfaces that carry an IPv4 address (via getifaddrs).
    static func list(excluding ours: String? = nil) -> [OtherTunnel] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var byName: [String: [IPv4]] = [:]
        var p = head
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            let name = String(cString: ifa.pointee.ifa_name)
            guard isTunnelName(name), name != ours, let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { IPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)) }
            byName[name, default: []].append(ip)
        }
        return byName.sorted { $0.key < $1.key }.map { OtherTunnel(name: $0.key, addresses: $0.value) }
    }

    /// Human-readable lines about other tunnels: Tailscale is reported as compatible; a tunnel is
    /// only a problem when it holds the default route (0/0, or 0/1 + 128/1).
    static func report(excluding given: String? = nil) -> (info: [String], warnings: [String]) {
        // Our own utun (address 198.18.0.1) is never reported as a conflict.
        let ours = given ?? list().first { $0.addresses.contains(TunnelAddresses.local) }?.name
        let tunnels = list(excluding: ours)
        let routesText = (try? run("/usr/sbin/netstat", ["-rn", "-f", "inet"], allowFailure: true)) ?? ""
        let holders = defaultRouteHolders(parseNetstatRoutes(routesText), excluding: ours).filter(isTunnelName)
        var info: [String] = []
        var warnings: [String] = []
        for t in tunnels where t.isTailscale {
            info.append("Tailscale detected on \(t.name) (\(t.addresses.map(\.description).joined(separator: ", "))): compatible — tailnet routes (100.64.0.0/10, peers, MagicDNS ts.net) stay on \(t.name)")
        }
        for h in holders {
            let t = tunnels.first { $0.name == h }
            if t?.isTailscale == true {
                warnings.append("\(h) (Tailscale) holds the default route: an exit node is active. Aiguillage's 0/1 + 128/1 routes would bypass the exit node (or collide with its own 0/1 routes). Disable the exit node before `aiguillage up`.")
            } else {
                warnings.append("\(h) holds the default route (another VPN?). Aiguillage's 0/1 + 128/1 routes would take over its traffic, or fail if it uses 0/1 + 128/1 itself. Disconnect it before `aiguillage up`.")
            }
        }
        return (info, warnings)
    }
}
