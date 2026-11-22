import Foundation

/// Status JSON served on the unix socket and shared by the daemon (`aiguillage status`) and the
/// menu bar app. Kept in the core library so both decode the exact same shape — no drift.
public struct StatusSnapshot: Codable, Sendable {
    public struct LinkStatus: Codable, Sendable {
        public var role: String
        public var name: String
        public var displayName: String
        public var address: String
        public var router: String
        public var resolvers: [String]
        public var state: String
        public var rttMs: Int?
        public var bytesUp: UInt64
        public var bytesDown: UInt64
        public var activeTCP: Int
        public var activeUDP: Int

        public init(role: String, name: String, displayName: String, address: String, router: String,
                    resolvers: [String], state: String, rttMs: Int?, bytesUp: UInt64, bytesDown: UInt64,
                    activeTCP: Int, activeUDP: Int) {
            self.role = role
            self.name = name
            self.displayName = displayName
            self.address = address
            self.router = router
            self.resolvers = resolvers
            self.state = state
            self.rttMs = rttMs
            self.bytesUp = bytesUp
            self.bytesDown = bytesDown
            self.activeTCP = activeTCP
            self.activeUDP = activeUDP
        }
    }

    public struct RuleStatus: Codable, Sendable {
        public var pattern: String
        public var policy: String
        public var source: String

        public init(pattern: String, policy: String, source: String) {
            self.pattern = pattern
            self.policy = policy
            self.source = source
        }
    }

    public struct FlowStatus: Codable, Sendable {
        public var proto: String
        public var source: String
        public var destination: String
        public var link: String?
        public var rule: String?
        public var policy: String?
        public var ageSeconds: Int

        public init(proto: String, source: String, destination: String, link: String?, rule: String?,
                    policy: String?, ageSeconds: Int) {
            self.proto = proto
            self.source = source
            self.destination = destination
            self.link = link
            self.rule = rule
            self.policy = policy
            self.ageSeconds = ageSeconds
        }
    }

    public var pid: Int32
    public var utun: String
    public var mode: String
    public var dnsMode: String
    public var uptimeSeconds: Int
    public var links: [LinkStatus]
    public var tcpFlows: Int
    public var udpFlows: Int
    public var natEntries: Int
    public var dnsQueries: Int
    public var learnedRuleAddresses: Int
    public var rules: [RuleStatus]
    /// Active flows (capped at 500).
    public var flows: [FlowStatus]

    public init(pid: Int32, utun: String, mode: String, dnsMode: String, uptimeSeconds: Int,
                links: [LinkStatus], tcpFlows: Int, udpFlows: Int, natEntries: Int, dnsQueries: Int,
                learnedRuleAddresses: Int, rules: [RuleStatus], flows: [FlowStatus]) {
        self.pid = pid
        self.utun = utun
        self.mode = mode
        self.dnsMode = dnsMode
        self.uptimeSeconds = uptimeSeconds
        self.links = links
        self.tcpFlows = tcpFlows
        self.udpFlows = udpFlows
        self.natEntries = natEntries
        self.dnsQueries = dnsQueries
        self.learnedRuleAddresses = learnedRuleAddresses
        self.rules = rules
        self.flows = flows
    }
}

/// Request written by a client on the status socket. Backwards compatible: an empty or unparseable
/// request (and `cmd == "status"`) is treated as a status query, so the old `aiguillage status` CLI
/// — which used to just connect and read — keeps working.
public struct ControlRequest: Codable, Sendable {
    public var cmd: String
    /// Only for `cmd == "set-mode"`: "race" or "failover".
    public var mode: String?

    public init(cmd: String = "status", mode: String? = nil) {
        self.cmd = cmd
        self.mode = mode
    }

    public static let status = ControlRequest(cmd: "status")
    public static let stop = ControlRequest(cmd: "stop")
    public static func setMode(_ mode: String) -> ControlRequest { ControlRequest(cmd: "set-mode", mode: mode) }
}

/// Reply to a control command (`stop`, `set-mode`). Status queries reply with a `StatusSnapshot`.
public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?

    public init(ok: Bool, error: String? = nil) {
        self.ok = ok
        self.error = error
    }
}

public enum StatusSocketPath {
    public static let path = "/var/run/aiguillage.sock"
}
