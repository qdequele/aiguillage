import AppKit
import Foundation

/// Self-contained in-app updater against GitHub Releases. No Sparkle, no signing keys: the app is
/// ad-hoc signed and distributed as a DMG, so updating means swapping the `.app` bundle in place and
/// stripping the `com.apple.quarantine` xattr off the copy (otherwise Gatekeeper would force the
/// right-click → Open dance again on the downloaded build).
///
/// Flow: check the `releases/latest` API → compare to the running bundle's version → on confirm,
/// download the DMG, run an install script that mounts it, replaces this bundle, (optionally)
/// refreshes the launchd daemon binary, then relaunches once this process exits.
enum Updater {
    static let repoSlug = "qdequele/aiguillage"
    /// GitHub requires a User-Agent; keep it generic (no user identity).
    static let userAgent = "aiguillage-updater"

    struct Release {
        let version: String        // tag, e.g. "v0.1.2"
        let dmgURL: URL
        let pageURL: String
        let notes: String
    }

    // MARK: Version

    /// The running bundle's CFBundleShortVersionString (e.g. "v0.1.1"), or nil outside a `.app`.
    static func currentVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// True when running from an installed `.app` with a parseable version — i.e. a build we can
    /// actually swap in place. A bare `.build/release` binary can check but not self-install.
    static func canSelfInstall() -> Bool {
        Bundle.main.bundlePath.hasSuffix(".app") && semver(currentVersion() ?? "").isEmpty == false
    }

    /// Leading-numeric components of a tag: "v0.1.2" → [0,1,2], "v0.1.1-3-gabc" → [0,1,1].
    static func semver(_ s: String) -> [Int] {
        var t = Substring(s)
        if t.first == "v" || t.first == "V" { t = t.dropFirst() }
        let core = t.prefix { $0.isNumber || $0 == "." }
        return core.split(separator: ".").compactMap { Int($0) }
    }

    /// Lexicographic compare of numeric components, shorter padded with zeros. remote > local.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let a = semver(remote), b = semver(local)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Check

    /// Fetches the latest non-prerelease release off the main thread. completion runs on main.
    static func checkLatest(_ completion: @escaping (Result<Release, Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, err in
            let result: Result<Release, Error>
            if let err {
                result = .failure(err)
            } else if let data, let rel = parseRelease(data) {
                result = .success(rel)
            } else {
                result = .failure(UpdateError.message("Could not read the release feed"))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    private static func parseRelease(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let assets = obj["assets"] as? [[String: Any]] else { return nil }
        let dmg = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".dmg") == true }
        guard let dmgStr = dmg?["browser_download_url"] as? String, let dmgURL = URL(string: dmgStr) else {
            return nil
        }
        return Release(version: tag,
                       dmgURL: dmgURL,
                       pageURL: obj["html_url"] as? String ?? "https://github.com/\(repoSlug)/releases",
                       notes: (obj["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    enum UpdateError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(m) = self { return m }; return nil }
    }

    // MARK: Install

    /// Downloads the DMG and swaps this bundle for it, then relaunches. completion(nil) on success
    /// (the app is about to relaunch), or completion(errorMessage) on failure. Runs work off main.
    static func performUpdate(_ release: Release, completion: @escaping (String?) -> Void) {
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else {
            completion("Not running from an installed app — download it from the releases page instead.")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let dmg = try download(release.dmgURL)
                defer { try? FileManager.default.removeItem(at: dmg) }
                try install(dmgPath: dmg.path, appPath: appPath)
                DispatchQueue.main.async {
                    completion(nil)
                    NSApp.terminate(nil) // the detached relaunch waits for this PID to exit
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                DispatchQueue.main.async { completion(msg) }
            }
        }
    }

    /// Synchronous download to a temp file (small DMG, ~1 MB).
    private static func download(_ url: URL) throws -> URL {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 120
        let sem = DispatchSemaphore(value: 0)
        var fileURL: URL?
        var failure: Error?
        URLSession.shared.downloadTask(with: req) { tmp, resp, err in
            defer { sem.signal() }
            if let err { failure = err; return }
            guard let tmp, let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                failure = UpdateError.message("Download failed (HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0))")
                return
            }
            // downloadTask deletes tmp when the handler returns — move it out first.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("aiguillage-update-\(UUID().uuidString).dmg")
            do { try FileManager.default.moveItem(at: tmp, to: dest); fileURL = dest }
            catch { failure = error }
        }.resume()
        sem.wait()
        if let failure { throw failure }
        guard let fileURL else { throw UpdateError.message("Download produced no file") }
        return fileURL
    }

    /// Writes and runs the install script. Uses an admin prompt when the launchd daemon is present
    /// (its binary lives in /usr/local/bin and a kickstart needs root) or when the app's parent
    /// directory isn't writable; otherwise runs unprivileged.
    private static func install(dmgPath: String, appPath: String) throws {
        let launchdInstalled = FileManager.default.fileExists(
            atPath: "/Library/LaunchDaemons/com.qdequelen.aiguillage.plist")
        let parent = (appPath as NSString).deletingLastPathComponent
        let needsAdmin = launchdInstalled || !FileManager.default.isWritableFile(atPath: parent)

        let pid = ProcessInfo.processInfo.processIdentifier
        let script = installScript(dmg: dmgPath, app: appPath, pid: pid, refreshDaemon: launchdInstalled)
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiguillage-install-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        if needsAdmin {
            try runWithAdmin(scriptPath: scriptURL.path)
        } else {
            try runShell(scriptPath: scriptURL.path)
        }
    }

    /// The install script. It mounts the DMG, replaces the bundle, strips quarantine, optionally
    /// refreshes the launchd daemon binary, and schedules a relaunch once this PID exits. The
    /// relaunch is backgrounded in a subshell so an admin `do shell script` returns promptly.
    private static func installScript(dmg: String, app: String, pid: Int32, refreshDaemon: Bool) -> String {
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var daemonRefresh = ""
        if refreshDaemon {
            daemonRefresh = """
            if [ -f /Library/LaunchDaemons/com.qdequelen.aiguillage.plist ]; then
              cp "$APP/Contents/MacOS/aiguillage" /usr/local/bin/aiguillage
              codesign --force --sign - /usr/local/bin/aiguillage >/dev/null 2>&1 || true
              launchctl kickstart -k system/com.qdequelen.aiguillage >/dev/null 2>&1 || true
            fi
            """
        }
        return """
        #!/bin/sh
        set -e
        DMG=\(q(dmg))
        APP=\(q(app))
        PID=\(pid)
        MNT="$(mktemp -d /tmp/aiguillage-mnt.XXXXXX)"
        hdiutil attach "$DMG" -nobrowse -noverify -mountpoint "$MNT" >/dev/null
        SRC="$MNT/Aiguillage.app"
        if [ ! -d "$SRC" ]; then
          SRC="$(find "$MNT" -maxdepth 1 -name '*.app' -print -quit)"
        fi
        xattr -dr com.apple.quarantine "$SRC" >/dev/null 2>&1 || true
        rm -rf "$APP"
        cp -R "$SRC" "$APP"
        xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true
        \(daemonRefresh)
        hdiutil detach "$MNT" >/dev/null 2>&1 || true
        rmdir "$MNT" >/dev/null 2>&1 || true
        # Relaunch after the running menu-bar app exits (backgrounded so an admin prompt returns now).
        ( while kill -0 "$PID" 2>/dev/null; do sleep 0.2; done; sleep 0.4; open "$APP" ) >/dev/null 2>&1 </dev/null &
        exit 0
        """
    }

    private static func runShell(scriptPath: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptPath]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UpdateError.message("Install script failed (code \(p.terminationStatus))")
        }
    }

    private static func runWithAdmin(scriptPath: String) throws {
        let cmd = "/bin/sh \(scriptPath.replacingOccurrences(of: "'", with: "'\\''"))"
        let apple = "do shell script \"\(appleEscape(cmd))\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", apple]
        let pipe = Pipe()
        p.standardError = pipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if out.contains("-128") || out.localizedCaseInsensitiveContains("cancel") {
                throw UpdateError.message("cancelled")
            }
            throw UpdateError.message(out.isEmpty ? "Install failed (code \(p.terminationStatus))" : out)
        }
    }

    private static func appleEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
