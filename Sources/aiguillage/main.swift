import AiguillageCore
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage:
  aiguillage up [--primary IF] [--secondary IF] [--mode race|failover]
                [--dns-mode networksetup|dynamicstore|none] [--rule 'PATTERN=POLICY']...
                [--no-default-rules] [--selftest] [--verbose]   (root; --dns-mode default networksetup)
  aiguillage status [--json]
  aiguillage doctor
  aiguillage restore                                      (root) undo networksetup DNS changes

rules: PATTERN is example.com, *.example.com, 192.0.2.0/24 or 192.0.2.7;
       POLICY is best (healthiest link now, recommended), cellular (force secondary),
       wifi (force primary), race, failover or block.
       Files: /etc/aiguillage/rules.conf, ~/.config/aiguillage/rules.conf ("pattern = policy" lines).
"""

func parseUp(_ args: ArraySlice<String>) throws -> UpOptions {
    var o = UpOptions()
    var it = args.makeIterator()
    func value(_ flag: String) throws -> String {
        guard let v = it.next() else { throw UsageError(description: "\(flag) needs a value") }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--primary": o.primary = try value(a)
        case "--secondary": o.secondary = try value(a)
        case "--mode":
            let v = try value(a)
            guard let m = RelayMode(rawValue: v) else { throw UsageError(description: "--mode must be race or failover") }
            o.mode = m
        case "--dns-mode":
            let v = try value(a)
            guard let m = DNSMode(rawValue: v) else { throw UsageError(description: "--dns-mode must be dynamicstore, networksetup or none") }
            o.dnsMode = m
        case "--rule": o.cliRules.append(try value(a))
        case "--no-default-rules": o.noDefaultRules = true
        case "--selftest": o.selftest = true
        case "--verbose", "-v": o.verbose = true
        default: throw UsageError(description: "unknown option \(a)")
        }
    }
    return o
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "up":
    do {
        let options = try parseUp(args.dropFirst())
        // Validate rules before asking for anything else.
        _ = try loadRules(cli: options.cliRules, noDefaults: options.noDefaultRules)
        Daemon(options: options).run()
    } catch {
        FileHandle.standardError.write("aiguillage: \(error)\n\n\(usage)\n".data(using: .utf8)!)
        exit(2)
    }
case "status":
    exit(runStatus(json: args.contains("--json")))
case "doctor":
    exit(runDoctor())
case "bindtest":
    // Hidden diagnostic: raw socket + IP_BOUND_IF + connect. Run as root while `up` is NOT running.
    guard geteuid() == 0 else {
        FileHandle.standardError.write("aiguillage: bindtest must run as root: sudo aiguillage bindtest <ifname> <ipv4> <port>\n".data(using: .utf8)!)
        exit(1)
    }
    exit(runBindTest(args.dropFirst()))
case "restore":
    guard geteuid() == 0 else {
        FileHandle.standardError.write("aiguillage: restore must run as root: sudo aiguillage restore\n".data(using: .utf8)!)
        exit(1)
    }
    if StatusSocket.query() != nil {
        FileHandle.standardError.write("aiguillage: the daemon is running; stop it (Ctrl-C) and it restores DNS itself\n".data(using: .utf8)!)
        exit(1)
    }
    let restoredDNS = NetworkSetupDNS.restore()
    // Also clear any scoped egress routes left by a crashed `up` (best-effort, for present links).
    ScopedRouteManager.deleteForDiscoveredLinks()
    if !restoredDNS { print("no saved DNS state to restore (\(SystemDNS.stateFile) absent); cleared any leftover scoped routes") }
    exit(0)
case "help", "--help", "-h":
    print(usage)
default:
    FileHandle.standardError.write("\(usage)\n".data(using: .utf8)!)
    exit(2)
}
