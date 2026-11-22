/// Destination-based link pinning.
///
/// Rules map a hostname pattern or an IPv4 address/CIDR to a policy. Hostnames are matched when
/// the DNS forwarder resolves them: the A records it returns are remembered (for their TTL,
/// clamped) so the TCP/UDP relays can look the destination IP up when a flow opens.

public enum LinkPolicy: String, Codable, CaseIterable, Sendable {
    /// Force the secondary link (the iPhone / 5G).
    case cellular
    /// Force the primary link (the Wi-Fi).
    case wifi
    /// Dial only the currently healthier link (state, then RTT, then failures); ties go to the
    /// primary. Follows the better link without paying for a second connection.
    case best
    case race
    case failover
    case block
}

public enum RulePattern: Hashable, CustomStringConvertible, Sendable {
    /// `example.com`: exactly that name.
    case exact(String)
    /// `*.example.com`: any name strictly below example.com.
    case subdomains(String)
    /// `192.0.2.0/24` or `192.0.2.7` (= /32).
    case cidr(IPv4, Int)

    public init?(_ text: String) {
        let s = text.trimmingCharacters(in: " \t").lowercased().trimmingSuffix(".")
        guard !s.isEmpty else { return nil }
        if let slash = s.firstIndex(of: "/") {
            guard let ip = IPv4(String(s[..<slash])), let len = Int(s[s.index(after: slash)...]), (0...32).contains(len) else { return nil }
            self = .cidr(IPv4(len == 0 ? 0 : ip.value & ~UInt32(0) << (32 - len)), len)
        } else if let ip = IPv4(s) {
            self = .cidr(ip, 32)
        } else if s.hasPrefix("*.") {
            let base = String(s.dropFirst(2))
            guard RulePattern.validName(base) else { return nil }
            self = .subdomains(base)
        } else {
            guard RulePattern.validName(s) else { return nil }
            self = .exact(s)
        }
    }

    private static func validName(_ s: String) -> Bool {
        !s.isEmpty && !s.contains("*") && !s.contains(" ") && !s.hasPrefix(".")
    }

    public var description: String {
        switch self {
        case .exact(let n): return n
        case .subdomains(let n): return "*.\(n)"
        case .cidr(let ip, let len): return len == 32 ? ip.description : "\(ip)/\(len)"
        }
    }

    /// Match strength for a hostname (higher = more specific), nil if no match.
    func specificity(host: String) -> Int? {
        switch self {
        case .exact(let n): return host == n ? 1000 + n.count : nil
        case .subdomains(let n): return host.hasSuffix("." + n) ? n.count : nil
        case .cidr: return nil
        }
    }

    func matches(ip: IPv4) -> Int? {
        guard case .cidr(let net, let len) = self else { return nil }
        let mask: UInt32 = len == 0 ? 0 : ~UInt32(0) << (32 - len)
        return ip.value & mask == net.value ? len : nil
    }
}

public enum RuleSource: String, Codable, Sendable {
    case builtin, file, cli
}

public struct RoutingRule: Equatable, Sendable {
    public let pattern: RulePattern
    public let policy: LinkPolicy
    public let source: RuleSource

    public init(pattern: RulePattern, policy: LinkPolicy, source: RuleSource) {
        self.pattern = pattern
        self.policy = policy
        self.source = source
    }

    public var description: String { "\(pattern) = \(policy.rawValue)" }

    /// Parses `pattern = policy` (or `pattern=policy`). Returns nil for blank/comment lines,
    /// throws a message for malformed ones.
    public static func parse(_ line: String, source: RuleSource) throws -> RoutingRule? {
        let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = content.trimmingCharacters(in: " \t\r")
        if trimmed.isEmpty { return nil }
        let parts = trimmed.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: " \t") }
        guard parts.count == 2 else { throw RuleError("expected 'pattern = policy', got '\(trimmed)'") }
        guard let pattern = RulePattern(parts[0]) else { throw RuleError("invalid pattern '\(parts[0])'") }
        guard let policy = LinkPolicy(rawValue: parts[1].lowercased()) else {
            throw RuleError("invalid policy '\(parts[1])' (use \(LinkPolicy.allCases.map(\.rawValue).joined(separator: ", ")))")
        }
        return RoutingRule(pattern: pattern, policy: policy, source: source)
    }

    /// Parses a whole rules file. Errors carry the line number.
    public static func parseFile(_ text: String, source: RuleSource = .file) throws -> [RoutingRule] {
        var out: [RoutingRule] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            do {
                if let r = try parse(String(line), source: source) { out.append(r) }
            } catch let e as RuleError {
                throw RuleError("line \(i + 1): \(e.description)")
            }
        }
        return out
    }
}

public struct RuleError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ d: String) { description = d }
}

/// ---------------------------------------------------------------------------------------------
/// DEFAULT RULES — edit this list to change what is pinned out of the box.
/// Claude / Anthropic traffic uses `best`: whichever link is healthier right now (the iPhone is
/// not always better than the train Wi-Fi, e.g. in tunnels). Use `cellular` to force the iPhone.
/// Disable all of them with `aiguillage up --no-default-rules`; override one with a rules file
/// or `--rule` using the same pattern.
/// ---------------------------------------------------------------------------------------------
public let defaultRoutingRules: [RoutingRule] = [
    ("anthropic.com", LinkPolicy.best),
    ("*.anthropic.com", .best),   // api.anthropic.com, console.anthropic.com, ...
    ("claude.ai", .best),
    ("*.claude.ai", .best),
    ("claude.com", .best),
    ("*.claude.com", .best),
].map { RoutingRule(pattern: RulePattern($0.0)!, policy: $0.1, source: .builtin) }

/// The effective rule list after precedence: CLI overrides file overrides defaults
/// (a later layer replaces a rule with the same pattern).
public struct RuleSet: Sendable {
    public private(set) var rules: [RoutingRule]

    public init(defaults: [RoutingRule] = defaultRoutingRules, file: [RoutingRule] = [], cli: [RoutingRule] = []) {
        var merged: [RoutingRule] = []
        for layer in [defaults, file, cli] {
            for r in layer {
                if let i = merged.firstIndex(where: { $0.pattern == r.pattern }) {
                    merged[i] = r
                } else {
                    merged.append(r)
                }
            }
        }
        rules = merged
    }

    /// Most specific hostname rule matching `host` (exact beats wildcard, longer suffix wins).
    public func rule(forHost host: String) -> RoutingRule? {
        let h = host.lowercased().trimmingSuffix(".")
        var best: (RoutingRule, Int)?
        for r in rules {
            if let s = r.pattern.specificity(host: h), s > (best?.1 ?? -1) { best = (r, s) }
        }
        return best?.0
    }

    /// Longest-prefix address rule matching `ip`.
    public func rule(forIP ip: IPv4) -> RoutingRule? {
        var best: (RoutingRule, Int)?
        for r in rules {
            if let s = r.pattern.matches(ip: ip), s > (best?.1 ?? -1) { best = (r, s) }
        }
        return best?.0
    }
}

/// What the relays need to know when a flow opens.
public struct RouteDecision: Equatable, Sendable {
    public let rule: RoutingRule
    /// The hostname that taught us this IP, if the match came from DNS.
    public let host: String?

    public var policy: LinkPolicy { rule.policy }
    public var label: String { host.map { "\(rule.pattern) (\($0))" } ?? rule.pattern.description }
}

/// IP -> rule map learned from DNS answers, plus address rules. Not thread-safe.
public final class RuleRouter {
    public static let minTTL = 60.0
    public static let maxTTL = 3600.0

    public let ruleSet: RuleSet
    private var learned: [IPv4: (decision: RouteDecision, expiresAt: Double)] = [:]
    public let maxLearned: Int

    public init(ruleSet: RuleSet, maxLearned: Int = 20000) {
        self.ruleSet = ruleSet
        self.maxLearned = maxLearned
    }

    public var learnedCount: Int { learned.count }

    /// Records the A records of a DNS answer if its question name matches a rule.
    /// Returns the matching rule, if any.
    @discardableResult
    public func learn(host: String, records: [(ip: IPv4, ttl: UInt32)], now: Double) -> RoutingRule? {
        guard let rule = ruleSet.rule(forHost: host), !records.isEmpty else { return nil }
        if learned.count + records.count > maxLearned { expire(now: now) }
        let decision = RouteDecision(rule: rule, host: host.lowercased().trimmingSuffix("."))
        for r in records where learned.count < maxLearned || learned[r.ip] != nil {
            let ttl = min(max(Double(r.ttl), RuleRouter.minTTL), RuleRouter.maxTTL)
            learned[r.ip] = (decision, now + ttl)
        }
        return rule
    }

    /// The rule for a destination: DNS-learned first, then address rules.
    public func decision(for ip: IPv4, now: Double) -> RouteDecision? {
        if let e = learned[ip] {
            if e.expiresAt > now { return e.decision }
            learned[ip] = nil
        }
        return ruleSet.rule(forIP: ip).map { RouteDecision(rule: $0, host: nil) }
    }

    public func expire(now: Double) {
        learned = learned.filter { $0.value.expiresAt > now }
    }
}

extension StringProtocol {
    func trimmingCharacters(in set: String) -> String {
        var s = Substring(self)
        while let f = s.first, set.contains(f) { s.removeFirst() }
        while let l = s.last, set.contains(l) { s.removeLast() }
        return String(s)
    }

    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : String(self)
    }
}
