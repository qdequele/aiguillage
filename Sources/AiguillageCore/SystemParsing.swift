/// Pure parsers for the output of `scutil --dns` and `netstat -rn -f inet`, used to check DNS
/// priority and to detect other tunnels (Tailscale, VPNs).

public struct ScutilResolver: Equatable, Sendable {
    public var number: Int
    public var domain: String?
    public var nameservers: [String] = []
    public var interface: String?
    public var flags: String = ""
    public var options: String = ""
    public var order: Int?

    /// A resolver that applies to every name (no domain, not mDNS).
    public var isMatchAll: Bool { domain == nil && !options.contains("mdns") && !nameservers.isEmpty }
}

/// Parses the first ("DNS configuration", unscoped) section of `scutil --dns`.
public func parseScutilDNS(_ text: String) -> [ScutilResolver] {
    var out: [ScutilResolver] = []
    var current: ScutilResolver?
    var started = false
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: " \t")
        if line.hasPrefix("DNS configuration") {
            if started { break } // the scoped section starts here
            started = true
            continue
        }
        if line.hasPrefix("resolver #") {
            if let c = current { out.append(c) }
            current = ScutilResolver(number: Int(line.dropFirst("resolver #".count)) ?? out.count + 1)
            continue
        }
        guard current != nil, let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: " \t")
        let value = line[line.index(after: colon)...].trimmingCharacters(in: " \t")
        switch key {
        case "domain": current!.domain = value
        case "options": current!.options = value
        case "flags": current!.flags = value
        case "order": current!.order = Int(value)
        case "if_index":
            // "25 (utun6)"
            if let open = value.firstIndex(of: "("), let close = value.firstIndex(of: ")"), open < close {
                current!.interface = String(value[value.index(after: open)..<close])
            }
        default:
            if key.hasPrefix("nameserver[") { current!.nameservers.append(value) }
        }
    }
    if let c = current { out.append(c) }
    return out
}

/// Match-all resolvers sorted by priority (lowest `order` first; resolvers without order last,
/// in listing order).
public func matchAllResolversByPriority(_ resolvers: [ScutilResolver]) -> [ScutilResolver] {
    resolvers.enumerated()
        .filter { $0.element.isMatchAll }
        .sorted { ($0.element.order ?? Int.max, $0.offset) < ($1.element.order ?? Int.max, $1.offset) }
        .map(\.element)
}

public struct RouteEntry: Equatable, Sendable {
    public var destination: String
    public var gateway: String
    public var flags: String
    public var interface: String

    /// Scoped routes (flag I) only apply to sockets bound to that interface.
    public var isScoped: Bool { flags.contains("I") }
}

/// Parses `netstat -rn -f inet` (or inet6) lines into route entries.
public func parseNetstatRoutes(_ text: String) -> [RouteEntry] {
    var out: [RouteEntry] = []
    var inTable = false
    for raw in text.split(separator: "\n") {
        let cols = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if cols.first == "Destination" {
            inTable = true
            continue
        }
        guard inTable, cols.count >= 4 else { continue }
        out.append(RouteEntry(destination: cols[0], gateway: cols[1], flags: cols[2], interface: cols[3]))
    }
    return out
}

/// Interfaces that hold the (unscoped) IPv4 default route: either `default` itself, or the pair
/// 0/1 + 128.0/1 used by VPNs (and by us). `excluding` is our own utun.
public func defaultRouteHolders(_ routes: [RouteEntry], excluding: String? = nil) -> [String] {
    var halves: [String: Set<String>] = [:]
    var holders: [String] = []
    for r in routes where !r.isScoped && r.interface != excluding {
        switch r.destination {
        case "default", "0.0.0.0/0", "0/0":
            if !holders.contains(r.interface) { holders.append(r.interface) }
        case "0/1", "0.0.0.0/1", "128.0/1", "128.0.0.0/1", "128/1":
            halves[r.interface, default: []].insert(r.destination.hasPrefix("128") ? "hi" : "lo")
        default:
            break
        }
    }
    for (iface, set) in halves.sorted(by: { $0.key < $1.key }) where set.count == 2 && !holders.contains(iface) {
        holders.append(iface)
    }
    return holders
}
