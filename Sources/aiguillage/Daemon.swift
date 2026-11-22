import AiguillageCore
import Darwin
import Foundation

struct UpOptions {
    var primary: String?
    var secondary: String?
    var mode: RelayMode = .race
    // networksetup is the default: it installs 198.18.0.2 as a *primary* resolver on the active
    // services, which outranks Tailscale's match-all supplemental. dynamicstore (a supplemental
    // resolver) cannot win that ordering — see README.
    var dnsMode: DNSMode = .networksetup
    var verbose = false
    var cliRules: [String] = []
    var noDefaultRules = false
    var selftest = false
}

/// Rules files, lowest precedence first: /etc, then the invoking user's ~/.config
/// (under sudo, SUDO_USER's home rather than root's).
func rulesFilePaths() -> [String] {
    var home = NSHomeDirectory()
    if let user = ProcessInfo.processInfo.environment["SUDO_USER"], let pw = getpwnam(user) {
        home = String(cString: pw.pointee.pw_dir)
    }
    return ["/etc/aiguillage/rules.conf", "\(home)/.config/aiguillage/rules.conf"]
}

/// Builds the effective rule set: CLI overrides files, files override the built-in defaults.
func loadRules(cli: [String], noDefaults: Bool) throws -> (RuleSet, [String]) {
    var fileRules: [RoutingRule] = []
    var loaded: [String] = []
    for path in rulesFilePaths() where FileManager.default.fileExists(atPath: path) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw UsageError(description: "cannot read \(path)")
        }
        do {
            fileRules += try RoutingRule.parseFile(text)
        } catch let e as RuleError {
            throw UsageError(description: "\(path): \(e.description)")
        }
        loaded.append(path)
    }
    // Later rules in the file list replace earlier ones with the same pattern.
    let fileSet = RuleSet(defaults: [], file: fileRules).rules
    var cliRules: [RoutingRule] = []
    for r in cli {
        do {
            if let rule = try RoutingRule.parse(r, source: .cli) { cliRules.append(rule) }
        } catch let e as RuleError {
            throw UsageError(description: "--rule '\(r)': \(e.description)")
        }
    }
    return (RuleSet(defaults: noDefaults ? [] : defaultRoutingRules, file: fileSet, cli: cliRules), loaded)
}

/// Shared state of the running daemon. Everything except the NAT table and the utun fd is only
/// touched on `queue`.
final class Engine {
    let queue: DispatchQueue
    /// Global race/failover mode. Read on `queue` when a flow opens; the control socket can retune
    /// it live (new flows pick up the new mode, existing ones keep their decision).
    private(set) var mode: RelayMode
    let links: LinkManager
    let router: RuleRouter
    let utun: Utun
    private let natLock = NSLock()
    private let natTable = TCPNatTable()
    private var redirector: TCPRedirector?
    private(set) var tcp: TCPRelayServer!
    private(set) var udp: UDPRelay!
    private(set) var dns: DNSForwarder!
    private var dnsIPID: UInt16 = 0

    init(queue: DispatchQueue, mode: RelayMode, links: LinkManager, router: RuleRouter, utun: Utun) {
        self.queue = queue
        self.mode = mode
        self.links = links
        self.router = router
        self.utun = utun
        tcp = TCPRelayServer(engine: self)
        udp = UDPRelay(engine: self)
        dns = DNSForwarder(engine: self)
    }

    /// Applies a new global mode on the engine queue (serialised with flow creation and snapshots).
    func setMode(_ newMode: RelayMode) {
        queue.async { self.mode = newMode }
    }

    func withNat<T>(_ body: (TCPNatTable) -> T) -> T {
        natLock.lock()
        defer { natLock.unlock() }
        return body(natTable)
    }

    func setListenerPort(_ port: UInt16) {
        natLock.lock()
        redirector = TCPRedirector(listenerPort: port, table: natTable)
        natLock.unlock()
    }

    func writeIPv4(_ packet: [UInt8]) {
        utun.write(packet, family: AF_INET)
    }

    /// Called on the utun reader thread for every packet.
    func handlePacket(family: UInt32, _ packet: [UInt8]) {
        if family == UInt32(AF_INET6) {
            handleIPv6(packet)
            return
        }
        guard family == UInt32(AF_INET), let p = IPv4Packet(packet) else { return }
        if p.isFragment { return }
        switch p.proto {
        case IPProto.tcp:
            natLock.lock()
            let action = redirector?.handle(p, now: monotonicNow())
            natLock.unlock()
            switch action {
            case .write(let bytes)?:
                writeIPv4(bytes)
            case .drop(let why)?:
                Log.debug("drop tcp: \(why)")
            case nil:
                break
            }
        case IPProto.udp:
            guard let d = UDPDatagram(p) else { return }
            let src = p.src, dst = p.dst
            if dst.isCGNAT {
                Log.debug("drop udp to CGNAT/Tailscale \(dst):\(d.dstPort)")
                return
            }
            if d.dstPort == 53 {
                queue.async {
                    self.dns.resolve(d.payload) { reply in
                        self.dnsIPID &+= 1
                        self.writeIPv4(buildIPv4UDP(src: dst, srcPort: 53, dst: src, dstPort: d.srcPort,
                                                    payload: reply, id: self.dnsIPID))
                    }
                }
                return
            }
            if dst == TunnelAddresses.peer || dst.isMulticast || dst.isBroadcast { return }
            queue.async { self.udp.handle(src: src, dst: dst, datagram: d) }
        default:
            return // ICMP and everything else: dropped
        }
    }

    private func handleIPv6(_ packet: [UInt8]) {
        guard let p = IPv6Packet(packet) else { return }
        if isTailscaleIPv6(p.dst) { return } // belongs to Tailscale's utun: never answer for it
        if let rst = buildIPv6TCPReset(answering: p) {
            utun.write(rst, family: AF_INET6)
        }
    }

    func snapshot(dnsMode: DNSMode, startedAt: Double) -> StatusSnapshot {
        let now = monotonicNow()
        let linkStatus = links.links.map { l in
            StatusSnapshot.LinkStatus(role: l.role.rawValue, name: l.name, displayName: l.info.displayName,
                                      address: l.info.address.description, router: l.info.router.description,
                                      resolvers: l.info.resolvers.map(\.description), state: l.state.rawValue,
                                      rttMs: l.health.rtt.map { Int(($0 * 1000).rounded()) },
                                      bytesUp: l.bytesUp, bytesDown: l.bytesDown,
                                      activeTCP: l.activeTCP, activeUDP: l.activeUDP)
        }
        var flows: [StatusSnapshot.FlowStatus] = []
        for r in tcp.activeRelays.prefix(400) {
            flows.append(.init(proto: "tcp", source: "\(r.key.srcIP):\(r.key.srcPort)",
                               destination: "\(r.key.dstIP):\(r.key.dstPort)", link: r.winnerLink?.name,
                               rule: r.decision?.label, policy: r.decision?.policy.rawValue,
                               ageSeconds: Int(now - r.openedAt)))
        }
        for f in udp.flows.values.prefix(100) {
            flows.append(.init(proto: "udp", source: "\(f.key.srcIP):\(f.key.srcPort)",
                               destination: "\(f.key.dstIP):\(f.key.dstPort)", link: f.link.name,
                               rule: f.decision?.label, policy: f.decision?.policy.rawValue,
                               ageSeconds: Int(now - f.lastActivity)))
        }
        return StatusSnapshot(
            pid: getpid(), utun: utun.name, mode: mode.rawValue, dnsMode: dnsMode.rawValue,
            uptimeSeconds: Int(now - startedAt), links: linkStatus,
            tcpFlows: tcp.activeRelays.count, udpFlows: udp.flows.count,
            natEntries: withNat { $0.count }, dnsQueries: dns.queriesTotal,
            learnedRuleAddresses: router.learnedCount,
            rules: router.ruleSet.rules.map { .init(pattern: $0.pattern.description, policy: $0.policy.rawValue, source: $0.source.rawValue) },
            flows: flows)
    }

    func summaryLine() -> String {
        let parts = links.links.map { l in
            "\(l.name) \(l.state.rawValue) \(formatRTT(l.health.rtt)) up \(formatBytes(l.bytesUp)) down \(formatBytes(l.bytesDown)) tcp \(l.activeTCP) udp \(l.activeUDP)"
        }
        let pinned = tcp.activeRelays.filter { $0.decision != nil }.count
        return "summary: " + (parts.isEmpty ? "no links" : parts.joined(separator: " | ")) +
            " | nat \(withNat { $0.count }) dns \(dns.queriesTotal) rule-pinned tcp \(pinned)"
    }
}

/// `aiguillage up`.
final class Daemon {
    let options: UpOptions
    private var utun: Utun?
    private var engine: Engine?
    private var registry = InterfaceRegistry()
    private var systemDNS: SystemDNS
    private let scopedRoutes = ScopedRouteManager()
    private var signalSources: [DispatchSourceSignal] = []
    private var timers: [DispatchSourceTimer] = []
    private let startedAt = monotonicNow()
    private var tornDown = false

    init(options: UpOptions) {
        self.options = options
        systemDNS = SystemDNS(mode: options.dnsMode)
    }

    func run() -> Never {
        guard geteuid() == 0 else {
            fail("`aiguillage up` must run as root: sudo \(CommandLine.arguments[0]) up ...")
        }
        if StatusSocket.query() != nil {
            fail("another aiguillage instance is already running (\(StatusSocket.path) answers). Stop it first.")
        }
        do {
            try start()
        } catch {
            Log.error("\(error)")
            teardown()
            exit(1)
        }
        dispatchMain()
    }

    private func fail(_ message: String) -> Never {
        FileHandle.standardError.write("aiguillage: \(message)\n".data(using: .utf8)!)
        exit(1)
    }

    private func start() throws {
        Log.verbose = options.verbose
        let (ruleSet, files) = try loadRules(cli: options.cliRules, noDefaults: options.noDefaultRules)
        Log.info("aiguillage starting: mode \(options.mode.rawValue), dns-mode \(options.dnsMode.rawValue)")
        Log.info("rules (\(ruleSet.rules.count))\(files.isEmpty ? "" : " from defaults + \(files.joined(separator: ", "))"): " +
                 ruleSet.rules.map { "\($0.description) [\($0.source.rawValue)]" }.joined(separator: "; "))

        // A previous run in networksetup mode may have crashed: undo it first.
        if NetworkSetupDNS.restore() {
            Log.warn("restored DNS settings left by a previous run")
        }
        let tunnels = Tunnels.report()
        tunnels.info.forEach { Log.info($0) }
        tunnels.warnings.forEach { Log.warn($0) }

        registry.start()
        registry.waitForInitialPaths()

        let utun = try Utun.open()
        self.utun = utun
        Log.info("opened \(utun.name)")
        try TunnelConfig.configure(utun.name)
        // Clear any scoped egress routes a previous run left behind, then let the reconcile below
        // reinstall fresh ones for the links present now.
        ScopedRouteManager.deleteForDiscoveredLinks()

        let queue = DispatchQueue(label: "aiguillage.engine")
        let links = LinkManager(queue: queue, registry: registry, primary: options.primary, secondary: options.secondary)
        let engine = Engine(queue: queue, mode: options.mode, links: links, router: RuleRouter(ruleSet: ruleSet), utun: utun)
        self.engine = engine

        // Listener first (it needs 198.18.0.1 to exist), then the packet loop.
        let port = try engine.tcp.start()
        engine.setListenerPort(port)
        Log.info("tcp listener on \(TunnelAddresses.local):\(port)")
        startReader(engine: engine, utun: utun)

        queue.sync {
            links.onLinkLost = { [weak engine] name in
                engine?.tcp.cancelRelays(onLink: name)
                engine?.udp.linkLost(name)
            }
            // Keep the per-link scoped egress routes in sync as links appear/disappear/change router.
            links.onLinksUpdated = { [weak self] infos in self?.scopedRoutes.reconcile(infos) }
            links.start()
            engine.udp.start()
        }
        let names = queue.sync { links.links.map(\.name) }
        if names.isEmpty {
            Log.warn("no physical link with an IPv4 router yet; waiting for one to appear")
        }

        if options.selftest {
            runSelftest(engine: engine)
        }

        try systemDNS.apply(linkNames: names)
        if options.dnsMode != .none {
            // configd needs a moment to publish the new resolver configuration.
            let dnsMode = options.dnsMode
            queue.asyncAfter(deadline: .now() + 1.5) {
                let (ok, lines) = SystemDNS.verify(mode: dnsMode)
                for l in lines { ok ? Log.info("dns check: \(l)") : Log.warn("dns check: \(l)") }
            }
        }

        let dnsMode = options.dnsMode
        let startedAt = self.startedAt
        func controlReply(_ response: ControlResponse) -> Data {
            (try? JSONEncoder().encode(response)) ?? Data()
        }
        try StatusSocket.serve { [weak engine, weak self] request in
            switch request.cmd {
            case "stop":
                // Ack first, then run the normal teardown (same path as SIGTERM) and exit.
                Log.info("stop requested via control socket")
                return (controlReply(ControlResponse(ok: true)), { self?.teardown(); exit(0) })
            case "set-mode":
                guard let raw = request.mode, let m = RelayMode(rawValue: raw) else {
                    return (controlReply(ControlResponse(ok: false, error: "set-mode needs mode race|failover")), nil)
                }
                engine?.setMode(m)
                Log.info("mode set to \(m.rawValue) via control socket")
                return (controlReply(ControlResponse(ok: true)), nil)
            default: // "status" and anything unknown: a read-only snapshot.
                guard let engine else { return (Data(), nil) }
                let snap = engine.queue.sync { engine.snapshot(dnsMode: dnsMode, startedAt: startedAt) }
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                return ((try? enc.encode(snap)) ?? Data(), nil)
            }
        }

        startTimers(engine: engine)
        installSignalHandlers()
        Log.info("up. `aiguillage status` for details, Ctrl-C to stop.")
    }

    /// `--selftest`: right after the utun + scoped routes are installed, do a bound off-link TCP
    /// connect per present link. This reproduces the exact failing condition (routes up) in one
    /// command — unlike `bindtest`, which installs no routes. Runs on the engine queue; the daemon
    /// keeps running normally afterwards.
    private func runSelftest(engine: Engine) {
        let target = IPv4(1, 1, 1, 1)
        engine.queue.async {
            let links = engine.links.links
            if links.isEmpty { Log.warn("selftest: no present link to test"); return }
            for link in links {
                let idx = link.ifIndex
                guard idx != 0 else { Log.warn("selftest \(link.name): interface absent"); continue }
                let started = monotonicNow()
                var conn: BoundTCPConnection?
                conn = BoundTCPConnection.start(to: target, port: 443, ifIndex: idx, timeout: 4,
                                                queue: engine.queue) { error in
                    conn?.close()
                    if let error {
                        Log.warn("selftest \(link.name): FAILED bound connect to \(target):443 — \(error)")
                    } else {
                        Log.info("selftest \(link.name): ok (rtt \(Int((monotonicNow() - started) * 1000))ms, bound to \(link.name) -> \(target):443)")
                    }
                }
            }
        }
    }

    private func startReader(engine: Engine, utun: Utun) {
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 65536 + 4)
            while true {
                guard let (family, packet) = utun.readPacket(buffer: &buffer) else {
                    Log.debug("utun read loop ended: \(errnoString())")
                    return
                }
                if !packet.isEmpty { engine.handlePacket(family: family, packet) }
            }
        }
        thread.name = "utun-reader"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func startTimers(engine: Engine) {
        let queue = engine.queue
        // NAT and rule-cache expiry.
        let expiry = DispatchSource.makeTimerSource(queue: queue)
        expiry.schedule(deadline: .now() + 5, repeating: 5)
        expiry.setEventHandler { [weak engine] in
            guard let engine else { return }
            let now = monotonicNow()
            engine.withNat { _ = $0.expire(now: now) }
            engine.router.expire(now: now)
        }
        expiry.resume()

        // Periodic one-line summary.
        let summary = DispatchSource.makeTimerSource(queue: queue)
        summary.schedule(deadline: .now() + 30, repeating: 30)
        summary.setEventHandler { [weak engine] in
            guard let engine else { return }
            Log.info(engine.summaryLine())
        }
        summary.resume()

        // networksetup mode: cover links that appear later (e.g. iPhone plugged in).
        var known = Set<String>()
        let dnsWatch = DispatchSource.makeTimerSource(queue: queue)
        dnsWatch.schedule(deadline: .now() + 5, repeating: 5)
        dnsWatch.setEventHandler { [weak engine, weak self] in
            guard let engine, let self else { return }
            let names = Set(engine.links.links.map(\.name))
            if !names.isSubset(of: known) {
                known.formUnion(names)
                self.systemDNS.linksChanged(Array(names))
            }
        }
        dnsWatch.resume()
        timers = [expiry, summary, dnsWatch]
    }

    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.teardown()
                exit(0)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    func teardown() {
        guard !tornDown else { return }
        tornDown = true
        Log.info("shutting down")
        // DNS first, so the system resolver never points at a dead 198.18.0.2.
        systemDNS.teardown()
        if let engine {
            engine.queue.sync {
                engine.tcp.stop()
                engine.udp.stop()
            }
        }
        StatusSocket.remove()
        // Scoped egress routes are NOT tied to the utun fd, so remove exactly what we installed.
        scopedRoutes.removeAll()
        utun?.close() // the interface and its (global) routes disappear with the fd
        registry.stop()
        Log.info("ciao les naz!")
    }
}
