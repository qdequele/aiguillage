import AiguillageCore
import Foundation
import Network
import SystemConfiguration

/// A physical interface usable as an outbound link.
struct LinkInfo: Equatable {
    var name: String          // BSD name, e.g. en0
    var displayName: String   // e.g. "Wi-Fi", "iPhone USB"
    var serviceID: String
    var address: IPv4
    var router: IPv4
    /// IPv6 default gateway, if the link has one (used only for the scoped IPv6 egress routes).
    var routerV6: String?
    var resolvers: [IPv4]
    var resolverSource: String // "dynamicstore", "dhcp", "fallback"
    var isWiFi: Bool

    /// Address/router identify the attached network; a change means a new network.
    func sameNetwork(as other: LinkInfo) -> Bool {
        name == other.name && address == other.address && router == other.router && routerV6 == other.routerV6
    }
}

enum LinkDiscovery {
    static let ignoredPrefixes = ["lo", "utun", "bridge", "awdl", "llw", "ipsec", "ppp", "gif", "stf", "anpi", "ap", "vmenet"]
    static let fallbackResolvers = [IPv4(1, 1, 1, 1), IPv4(8, 8, 8, 8)]

    /// Lists physical interfaces that have an IPv4 address and a router, from SCDynamicStore.
    static func discover() -> [LinkInfo] {
        guard let store = SCDynamicStoreCreate(nil, "aiguillage-discovery" as CFString, nil, nil) else { return [] }
        let pattern = "State:/Network/Service/[^/]+/IPv4" as CFString
        let keys = (SCDynamicStoreCopyKeyList(store, pattern) as? [String]) ?? []
        let hardware = hardwareInfo()
        var links: [LinkInfo] = []
        for key in keys.sorted() {
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let ifname = dict["InterfaceName"] as? String,
                  !ignoredPrefixes.contains(where: { ifname.hasPrefix($0) }),
                  let router = (dict["Router"] as? String).flatMap(IPv4.init),
                  let address = (dict["Addresses"] as? [String])?.compactMap(IPv4.init).first,
                  !address.isBenchmarkRange,
                  !links.contains(where: { $0.name == ifname }) else { continue }
            let serviceID = key.components(separatedBy: "/")[3]
            let (resolvers, source) = resolversFor(interface: ifname, serviceID: serviceID, store: store)
            let v6Key = "State:/Network/Service/\(serviceID)/IPv6" as CFString
            let routerV6 = (SCDynamicStoreCopyValue(store, v6Key) as? [String: Any])?["Router"] as? String
            let hw = hardware[ifname]
            links.append(LinkInfo(name: ifname, displayName: hw?.name ?? ifname, serviceID: serviceID,
                                  address: address, router: router, routerV6: routerV6, resolvers: resolvers,
                                  resolverSource: source, isWiFi: hw?.isWiFi ?? false))
        }
        return links
    }

    /// The link's own resolvers: SCDynamicStore state first, then the DHCP option via ipconfig,
    /// then public fallbacks. Our own 198.18.0.0/15 addresses are always filtered out (in
    /// networksetup mode the service DNS points at 198.18.0.2).
    static func resolversFor(interface: String, serviceID: String, store: SCDynamicStore) -> ([IPv4], String) {
        let key = "State:/Network/Service/\(serviceID)/DNS" as CFString
        if let dns = SCDynamicStoreCopyValue(store, key) as? [String: Any],
           let servers = dns["ServerAddresses"] as? [String] {
            let v4 = servers.compactMap(IPv4.init).filter { usableResolver($0) }
            if !v4.isEmpty { return (v4, "dynamicstore") }
        }
        if let out = try? run("/usr/sbin/ipconfig", ["getoption", interface, "domain_name_server"], allowFailure: true) {
            let v4 = out.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," })
                .compactMap { IPv4(String($0)) }.filter { usableResolver($0) }
            if !v4.isEmpty { return (v4, "dhcp") }
        }
        return (fallbackResolvers, "fallback")
    }

    private static func usableResolver(_ ip: IPv4) -> Bool {
        !ip.isBenchmarkRange && !ip.isLoopback && !ip.isCGNAT && ip.value != 0
    }

    /// BSD name -> (user-visible name, is Wi-Fi), from SCNetworkInterface.
    static func hardwareInfo() -> [String: (name: String, isWiFi: Bool)] {
        var out: [String: (String, Bool)] = [:]
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        for iface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(iface) as String? else { continue }
            let name = (SCNetworkInterfaceGetLocalizedDisplayName(iface) as String?) ?? bsd
            let type = SCNetworkInterfaceGetInterfaceType(iface) as String?
            out[bsd] = (name, type == (kSCNetworkInterfaceTypeIEEE80211 as String))
        }
        return out
    }
}

/// Watches NWPathMonitor only to react quickly when interfaces appear or disappear (iPhone
/// plugged in, Wi-Fi network change). Egress no longer needs NWInterface objects: a link is
/// usable as soon as `if_nametoindex(name) != 0` and discovery found an IPv4 router for it.
final class InterfaceRegistry {
    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "aiguillage.paths")
    private let ready = DispatchSemaphore(value: 0)
    private var signalledReady = false
    var onChange: (() -> Void)?

    func start() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            guard let self else { return }
            if !self.signalledReady {
                self.signalledReady = true
                self.ready.signal()
            }
            self.onChange?()
        }
        m.start(queue: queue)
        monitor = m
    }

    /// Waits (briefly) for the monitor's first update.
    func waitForInitialPaths(timeout: Double = 1.0) {
        _ = ready.wait(timeout: .now() + timeout)
    }

    func stop() {
        monitor?.cancel()
    }
}
