import AiguillageCore
import AppKit

/// Owns the status-bar item and its menu. Polls the daemon socket every ~2 s while the menu is open
/// and ~5 s otherwise, reflects state in an SF Symbol, and drives the Start/Stop/mode controls.
final class StatusController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var latest: StatusSnapshot?

    private let openInterval: TimeInterval = 2
    private let closedInterval: TimeInterval = 5

    // Update state.
    private var latestRelease: Updater.Release?
    private var lastUpdateCheck: Date?
    private var isUpdating = false
    private let updateCheckInterval: TimeInterval = 6 * 3600

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon(for: nil)
        render(latest)
        refresh()
        scheduleTimer(interval: closedInterval)
        checkForUpdates(manual: false) // quiet check on launch
    }

    // MARK: Polling

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fetches the snapshot off the main thread, then updates the UI on the main thread.
    private func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snap = DaemonClient.fetchStatus()
            DispatchQueue.main.async {
                guard let self else { return }
                self.latest = snap
                self.updateIcon(for: snap)
                self.render(snap)
            }
        }
    }

    // MARK: Icon

    private enum Overall { case stopped, healthy, degraded, down }

    private func overall(_ s: StatusSnapshot?) -> Overall {
        guard let s else { return .stopped }
        if s.links.isEmpty { return .down }
        let ups = s.links.filter { $0.state == "up" }.count
        if ups == s.links.count { return .healthy }
        if ups == 0 { return .down }
        return .degraded
    }

    private func updateIcon(for s: StatusSnapshot?) {
        // "arrow.triangle.branch" reads as a railway switch (an "aiguillage") — it fits a tool
        // that routes traffic down one of two tracks. State is carried by colour so it reads at a
        // glance; the system colours below adapt to a light or dark menu bar.
        let color: NSColor
        switch overall(s) {
        case .stopped:  color = .secondaryLabelColor
        case .healthy:  color = .systemGreen
        case .degraded: color = .systemOrange
        case .down:     color = .systemRed
        }
        let base = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "Aiguillage")
            ?? NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Aiguillage")
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let image = base?.withSymbolConfiguration(cfg)
        image?.isTemplate = false // keep the state colour (a template image renders monochrome)
        statusItem.button?.image = image
    }

    // MARK: Menu

    private func dot(_ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: "\u{25CF} ", attributes: [.foregroundColor: color])
    }

    private func render(_ s: StatusSnapshot?) {
        menu.removeAllItems() // AppKit keeps the menu open while we repopulate it

        let header = NSMenuItem()
        if let s {
            header.title = "Aiguillage: running (pid \(s.pid), \(s.utun))"
        } else {
            header.title = "Aiguillage: stopped"
        }
        header.isEnabled = false
        menu.addItem(header)

        if let s {
            menu.addItem(.separator())
            if s.links.isEmpty {
                let none = NSMenuItem(title: "no links", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for link in s.links {
                let color: NSColor
                switch link.state {
                case "up": color = .systemGreen
                case "captive": color = .systemOrange
                default: color = .systemRed
                }
                let rtt = link.rttMs.map { "\($0)ms" } ?? "-"
                var text = "\(link.displayName) — \(link.state) · \(rtt) · \u{2191}\(formatBytes(link.bytesUp)) \u{2193}\(formatBytes(link.bytesDown)) · tcp \(link.activeTCP) udp \(link.activeUDP)"
                if link.role == "primary" { text += " · primary" }
                let attr = NSMutableAttributedString(attributedString: dot(color))
                attr.append(NSAttributedString(string: text))
                let item = NSMenuItem()
                item.attributedTitle = attr
                item.isEnabled = false
                menu.addItem(item)
            }

            menu.addItem(.separator())

            // Mode submenu (live toggle via the control socket).
            let modeItem = NSMenuItem(title: "Mode : \(s.mode)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for m in ["race", "failover"] {
                let mi = NSMenuItem(title: m, action: #selector(selectMode(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = m
                mi.state = (m == s.mode) ? .on : .off
                sub.addItem(mi)
            }
            modeItem.submenu = sub
            menu.addItem(modeItem)

            let flows = NSMenuItem(title: "Active flows: TCP \(s.tcpFlows) · UDP \(s.udpFlows) · NAT \(s.natEntries) · DNS \(s.dnsQueries)",
                                   action: nil, keyEquivalent: "")
            flows.isEnabled = false
            menu.addItem(flows)

            // Routing rules with the number of active flows each pinned.
            let rulesHeader = NSMenuItem(title: "Rules:", action: nil, keyEquivalent: "")
            rulesHeader.isEnabled = false
            menu.addItem(rulesHeader)
            if s.rules.isEmpty {
                let none = NSMenuItem(title: "   none", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for r in s.rules {
                let count = s.flows.filter { $0.rule?.hasPrefix(r.pattern) == true }.count
                let item = NSMenuItem(title: "   \(r.pattern) = \(r.policy) [\(r.source)] — \(count) flows",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let startItem = NSMenuItem(title: "Start the daemon…", action: #selector(startDaemon), keyEquivalent: "")
        startItem.target = self
        startItem.isEnabled = (s == nil)
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Stop the daemon", action: #selector(stopDaemon), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = (s != nil)
        menu.addItem(stopItem)

        menu.addItem(.separator())

        // Updates.
        if isUpdating {
            let item = NSMenuItem(title: "Updating…", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if let rel = latestRelease,
                  let cur = Updater.currentVersion(),
                  Updater.isNewer(rel.version, than: cur) {
            let update = NSMenuItem(title: "⬆ Update to \(rel.version)…", action: #selector(startUpdate), keyEquivalent: "")
            update.target = self
            // Bold so it stands out as the actionable item.
            update.attributedTitle = NSAttributedString(
                string: update.title,
                attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)])
            menu.addItem(update)
        }
        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdatesClicked), keyEquivalent: "")
        check.target = self
        check.isEnabled = !isUpdating
        menu.addItem(check)

        if let v = Updater.currentVersion() {
            let ver = NSMenuItem(title: "Aiguillage \(v)", action: nil, keyEquivalent: "")
            ver.isEnabled = false
            menu.addItem(ver)
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit (leaves the daemon running)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func startDaemon() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = DaemonClient.startWithAdminPrompt()
            DispatchQueue.main.async {
                if let error, error != "cancelled" {
                    self?.alert("Could not start", error)
                }
                self?.refresh()
            }
        }
    }

    @objc private func stopDaemon() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = DaemonClient.stop()
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = DaemonClient.setMode(mode)
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Updates

    /// Background check (throttled) or an explicit one from the menu. On a manual check it reports
    /// the outcome; on a quiet check it just refreshes the menu if an update appeared.
    private func checkForUpdates(manual: Bool) {
        if !manual, let last = lastUpdateCheck, Date().timeIntervalSince(last) < updateCheckInterval {
            return
        }
        lastUpdateCheck = Date()
        Updater.checkLatest { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let rel):
                self.latestRelease = rel
                self.render(self.latest)
                if manual {
                    if let cur = Updater.currentVersion(), Updater.isNewer(rel.version, than: cur) {
                        self.offerUpdate(rel)
                    } else {
                        self.alert("You're up to date", "Aiguillage \(Updater.currentVersion() ?? "") is the latest version.")
                    }
                }
            case .failure(let err):
                if manual {
                    self.alert("Couldn't check for updates", err.localizedDescription)
                }
            }
        }
    }

    @objc private func checkForUpdatesClicked() {
        checkForUpdates(manual: true)
    }

    @objc private func startUpdate() {
        guard let rel = latestRelease else { return }
        offerUpdate(rel)
    }

    /// Confirmation dialog, then runs the swap-in-place update (or opens the page if we can't
    /// self-install, e.g. a bare `.build` binary).
    private func offerUpdate(_ rel: Release) {
        guard Updater.canSelfInstall() else {
            if let url = URL(string: rel.pageURL) { NSWorkspace.shared.open(url) }
            return
        }
        let a = NSAlert()
        a.messageText = "Update to \(rel.version)?"
        var info = "You have \(Updater.currentVersion() ?? "an older version"). This downloads and installs \(rel.version), then relaunches Aiguillage."
        if FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.qdequelen.aiguillage.plist") {
            info += "\n\nThe background service will be refreshed too — you'll be asked for your admin password once."
        }
        if !rel.notes.isEmpty {
            info += "\n\n— Release notes —\n" + String(rel.notes.prefix(600))
        }
        a.informativeText = info
        a.addButton(withTitle: "Update")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        isUpdating = true
        render(latest)
        Updater.performUpdate(rel) { [weak self] error in
            guard let self else { return }
            // On success the app is terminating to relaunch; nothing more to do here.
            guard let error else { return }
            self.isUpdating = false
            self.render(self.latest)
            if error != "cancelled" {
                self.alert("Update failed", error)
            }
        }
    }

    private typealias Release = Updater.Release

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.addButton(withTitle: "OK")
        a.runModal()
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        render(latest) // show the freshest cached data immediately
        refresh()
        checkForUpdates(manual: false) // throttled; refreshes the menu if a new version appears
        scheduleTimer(interval: openInterval)
    }

    func menuDidClose(_ menu: NSMenu) {
        scheduleTimer(interval: closedInterval)
    }
}

/// Compact byte formatter (self-contained: the daemon target's helper is not linkable here).
func formatBytes(_ n: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(n)
    var i = 0
    while v >= 1024 && i < units.count - 1 {
        v /= 1024
        i += 1
    }
    return i == 0 ? "\(n)B" : String(format: "%.1f%@", v, units[i])
}
