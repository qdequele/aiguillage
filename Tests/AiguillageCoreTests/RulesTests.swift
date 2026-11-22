import Testing
@testable import AiguillageCore

@Suite struct RoutingRuleTests {
    @Test func parsePatterns() {
        #expect(RulePattern("Example.COM.") == .exact("example.com"))
        #expect(RulePattern("*.anthropic.com") == .subdomains("anthropic.com"))
        #expect(RulePattern("192.0.2.7") == .cidr(IPv4(192, 0, 2, 7), 32))
        #expect(RulePattern("192.0.2.77/24") == .cidr(IPv4(192, 0, 2, 0), 24)) // normalised
        #expect(RulePattern("1.2.3.4/33") == nil)
        #expect(RulePattern("a*.b.com") == nil)
        #expect(RulePattern("") == nil)
    }

    @Test func parseLines() throws {
        #expect(try RoutingRule.parse("  # comment", source: .file) == nil)
        #expect(try RoutingRule.parse("", source: .file) == nil)
        let r = try #require(try RoutingRule.parse("*.claude.ai = cellular # pin", source: .file))
        #expect(r.pattern == .subdomains("claude.ai") && r.policy == .cellular && r.source == .file)
        let c = try #require(try RoutingRule.parse("example.com=BLOCK", source: .cli))
        #expect(c.policy == .block)
        #expect(throws: RuleError.self) { try RoutingRule.parse("example.com", source: .cli) }
        #expect(throws: RuleError.self) { try RoutingRule.parse("example.com = fast", source: .cli) }
        #expect(throws: RuleError("line 2: invalid pattern '**'")) {
            try RoutingRule.parseFile("a.com = wifi\n** = wifi\n")
        }
    }

    @Test func suffixMatching() {
        let set = RuleSet(defaults: defaultRoutingRules)
        #expect(set.rule(forHost: "api.anthropic.com")?.policy == .best)
        #expect(set.rule(forHost: "API.Anthropic.com.")?.policy == .best)
        #expect(set.rule(forHost: "anthropic.com")?.pattern == .exact("anthropic.com"))
        #expect(set.rule(forHost: "claude.ai")?.policy == .best)
        #expect(set.rule(forHost: "a.b.claude.ai")?.policy == .best)
        #expect(set.rule(forHost: "notanthropic.com") == nil)
        #expect(set.rule(forHost: "anthropic.com.evil.net") == nil)
    }

    @Test func mostSpecificRuleWins() {
        let set = RuleSet(defaults: [], cli: [
            RoutingRule(pattern: RulePattern("*.example.com")!, policy: .wifi, source: .cli),
            RoutingRule(pattern: RulePattern("*.cdn.example.com")!, policy: .cellular, source: .cli),
            RoutingRule(pattern: RulePattern("www.example.com")!, policy: .block, source: .cli),
        ])
        #expect(set.rule(forHost: "a.example.com")?.policy == .wifi)
        #expect(set.rule(forHost: "x.cdn.example.com")?.policy == .cellular)
        #expect(set.rule(forHost: "www.example.com")?.policy == .block)
    }

    @Test func precedenceCliOverFileOverDefault() throws {
        let file = try RoutingRule.parseFile("""
        # train setup
        *.anthropic.com = wifi
        claude.ai = race
        example.org = block
        """)
        let cli = [try RoutingRule.parse("*.anthropic.com=failover", source: .cli)!]
        let set = RuleSet(defaults: defaultRoutingRules, file: file, cli: cli)
        #expect(set.rule(forHost: "api.anthropic.com")?.policy == .failover)
        #expect(set.rule(forHost: "api.anthropic.com")?.source == .cli)
        #expect(set.rule(forHost: "claude.ai")?.policy == .race)
        #expect(set.rule(forHost: "claude.ai")?.source == .file)
        #expect(set.rule(forHost: "anthropic.com")?.source == .builtin)
        #expect(set.rule(forHost: "example.org")?.policy == .block)
        // No duplicates after merging.
        #expect(set.rules.filter { $0.pattern == .subdomains("anthropic.com") }.count == 1)
        // Defaults can be switched off entirely.
        #expect(RuleSet(defaults: [], file: [], cli: []).rule(forHost: "api.anthropic.com") == nil)
    }

    @Test func addressRulesUseLongestPrefix() {
        let set = RuleSet(defaults: [], file: [
            RoutingRule(pattern: RulePattern("10.0.0.0/8")!, policy: .wifi, source: .file),
            RoutingRule(pattern: RulePattern("10.1.0.0/16")!, policy: .cellular, source: .file),
        ])
        #expect(set.rule(forIP: IPv4(10, 2, 3, 4))?.policy == .wifi)
        #expect(set.rule(forIP: IPv4(10, 1, 3, 4))?.policy == .cellular)
        #expect(set.rule(forIP: IPv4(11, 0, 0, 1)) == nil)
    }
}

@Suite struct RuleRouterTests {
    let ip1 = IPv4(160, 79, 104, 10)
    let ip2 = IPv4(160, 79, 104, 11)

    @Test func learnsMatchingNamesOnly() {
        let r = RuleRouter(ruleSet: RuleSet())
        #expect(r.learn(host: "api.anthropic.com", records: [(ip1, 300)], now: 0)?.policy == .best)
        #expect(r.learn(host: "example.com", records: [(ip2, 300)], now: 0) == nil)
        let d = r.decision(for: ip1, now: 1)
        #expect(d?.policy == .best)
        #expect(d?.host == "api.anthropic.com")
        #expect(d?.label == "*.anthropic.com (api.anthropic.com)")
        #expect(r.decision(for: ip2, now: 1) == nil)
    }

    @Test func ttlIsClampedAndExpires() {
        let r = RuleRouter(ruleSet: RuleSet())
        r.learn(host: "claude.ai", records: [(ip1, 5), (ip2, 999_999)], now: 0)
        #expect(r.decision(for: ip1, now: 59) != nil)   // 5 s TTL clamped up to 60 s
        #expect(r.decision(for: ip1, now: 60) == nil)
        #expect(r.decision(for: ip2, now: 3599) != nil) // huge TTL clamped down to 1 h
        #expect(r.decision(for: ip2, now: 3600) == nil)
        #expect(r.learnedCount == 0) // lookups dropped the expired entries
    }

    @Test func expireSweeps() {
        let r = RuleRouter(ruleSet: RuleSet())
        r.learn(host: "claude.ai", records: [(ip1, 120)], now: 0)
        r.learn(host: "api.anthropic.com", records: [(ip2, 600)], now: 0)
        r.expire(now: 200)
        #expect(r.learnedCount == 1)
    }

    @Test func relearningRefreshesTTL() {
        let r = RuleRouter(ruleSet: RuleSet())
        r.learn(host: "claude.ai", records: [(ip1, 60)], now: 0)
        r.learn(host: "claude.ai", records: [(ip1, 60)], now: 50)
        #expect(r.decision(for: ip1, now: 100) != nil)
    }

    @Test func fallsBackToAddressRules() {
        let set = RuleSet(defaults: [], cli: [RoutingRule(pattern: RulePattern("203.0.113.0/24")!, policy: .block, source: .cli)])
        let r = RuleRouter(ruleSet: set)
        #expect(r.decision(for: IPv4(203, 0, 113, 9), now: 0)?.policy == .block)
        #expect(r.decision(for: IPv4(203, 0, 113, 9), now: 0)?.host == nil)
    }

    @Test func boundedSize() {
        let r = RuleRouter(ruleSet: RuleSet(), maxLearned: 2)
        r.learn(host: "claude.ai", records: [(IPv4(1, 1, 1, 1), 300), (IPv4(1, 1, 1, 2), 300), (IPv4(1, 1, 1, 3), 300)], now: 0)
        #expect(r.learnedCount == 2)
    }
}
