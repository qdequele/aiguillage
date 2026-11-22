import AiguillageCore
import Darwin
import Foundation

/// Talks to the root daemon over its unix socket (`/var/run/aiguillage.sock`, mode 0666), and
/// starts it through a GUI admin prompt. All socket I/O is blocking and meant to run off the main
/// thread.
enum DaemonClient {
    static let socketPath = StatusSocketPath.path
    static let logPath = "/tmp/aiguillage.log"

    // MARK: Socket

    private static func makeAddress() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            for (i, c) in socketPath.utf8.enumerated() where i < buf.count - 1 { buf[i] = c }
        }
        return addr
    }

    /// Connects, sends one JSON request line, reads the whole reply. Returns nil if nobody listens.
    static func send(_ request: ControlRequest) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = makeAddress()
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return nil }
        if var line = try? JSONEncoder().encode(request) {
            line.append(0x0A)
            line.withUnsafeBytes { raw in
                var off = 0
                while off < raw.count {
                    let n = write(fd, raw.baseAddress! + off, raw.count - off)
                    if n <= 0 { break }
                    off += n
                }
            }
        }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    /// Current daemon status, or nil when the daemon is not running.
    static func fetchStatus() -> StatusSnapshot? {
        guard let data = send(.status), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(StatusSnapshot.self, from: data)
    }

    /// Asks the already-root daemon to tear itself down (no password needed). Returns true on ack.
    @discardableResult
    static func stop() -> Bool {
        guard let data = send(.stop), let resp = try? JSONDecoder().decode(ControlResponse.self, from: data) else {
            return false
        }
        return resp.ok
    }

    /// Switches the live race/failover mode. Returns true on ack.
    @discardableResult
    static func setMode(_ mode: String) -> Bool {
        guard let data = send(.setMode(mode)), let resp = try? JSONDecoder().decode(ControlResponse.self, from: data) else {
            return false
        }
        return resp.ok
    }

    // MARK: Start (needs root)

    /// The `aiguillage` daemon binary. Resolution order: `AIGUILLAGE_BIN` override, the sibling of
    /// this executable (same `.build/<config>/` dir), then `/usr/local/bin/aiguillage`.
    static func resolveDaemonBinary() -> String {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["AIGUILLAGE_BIN"], fm.isExecutableFile(atPath: override) {
            return override
        }
        var candidates: [String] = []
        if let exe = Bundle.main.executablePath {
            candidates.append((exe as NSString).deletingLastPathComponent + "/aiguillage")
        }
        candidates.append("/usr/local/bin/aiguillage")
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        return candidates.first ?? "aiguillage"
    }

    /// Extra arguments passed after `up` (default: none → the daemon's own defaults: mode race,
    /// dns-mode networksetup). Overridable with `AIGUILLAGE_UP_ARGS` (space-separated).
    static func upArguments() -> [String] {
        guard let raw = ProcessInfo.processInfo.environment["AIGUILLAGE_UP_ARGS"], !raw.isEmpty else { return [] }
        return raw.split(separator: " ").map(String.init)
    }

    /// Launches the daemon detached, with a macOS admin password prompt. The daemon keeps running
    /// after the prompt returns (nohup + background + output redirected to the log). This blocks on
    /// the dialog, so call it off the main thread. Returns nil on success, else an error message.
    static func startWithAdminPrompt() -> String? {
        let bin = resolveDaemonBinary()
        guard FileManager.default.isExecutableFile(atPath: bin) else {
            return "binaire introuvable : \(bin)"
        }
        let argv = ([bin, "up"] + upArguments()).map(shellQuote).joined(separator: " ")
        let shellCommand = "nohup \(argv) >> \(shellQuote(logPath)) 2>&1 &"
        let appleScript = "do shell script \"\(appleEscape(shellCommand))\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return "osascript: \(error)"
        }
        if p.terminationStatus != 0 {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // -128 is the AppleScript "user cancelled" code.
            if out.contains("-128") || out.localizedCaseInsensitiveContains("cancel") { return "annulé" }
            return out.isEmpty ? "échec (code \(p.terminationStatus))" : out
        }
        return nil
    }

    /// Single-quotes a shell argument.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes a string for an AppleScript double-quoted literal.
    private static func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
