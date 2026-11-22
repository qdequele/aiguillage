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

    func start() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        updateIcon(for: nil)
        render(latest)
        refresh()
        scheduleTimer(interval: closedInterval)
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
        let symbol: String
        switch overall(s) {
        case .stopped: symbol = "power"
        case .healthy: symbol = "antenna.radiowaves.left.and.right"
        case .degraded: symbol = "antenna.radiowaves.left.and.right.slash"
        case .down: symbol = "exclamationmark.triangle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Aiguillage")
            ?? NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Aiguillage")
        image?.isTemplate = true // adapts to a light or dark menu bar
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
            header.title = "Aiguillage : actif (pid \(s.pid), \(s.utun))"
        } else {
            header.title = "Aiguillage : arrêté"
        }
        header.isEnabled = false
        menu.addItem(header)

        if let s {
            menu.addItem(.separator())
            if s.links.isEmpty {
                let none = NSMenuItem(title: "aucun lien", action: nil, keyEquivalent: "")
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
                if link.role == "primary" { text += " · primaire" }
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

            let flows = NSMenuItem(title: "Flux actifs : TCP \(s.tcpFlows) · UDP \(s.udpFlows) · NAT \(s.natEntries) · DNS \(s.dnsQueries)",
                                   action: nil, keyEquivalent: "")
            flows.isEnabled = false
            menu.addItem(flows)

            // Routing rules with the number of active flows each pinned.
            let rulesHeader = NSMenuItem(title: "Règles :", action: nil, keyEquivalent: "")
            rulesHeader.isEnabled = false
            menu.addItem(rulesHeader)
            if s.rules.isEmpty {
                let none = NSMenuItem(title: "   aucune", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            for r in s.rules {
                let count = s.flows.filter { $0.rule?.hasPrefix(r.pattern) == true }.count
                let item = NSMenuItem(title: "   \(r.pattern) = \(r.policy) [\(r.source)] — \(count) flux",
                                      action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let startItem = NSMenuItem(title: "Démarrer le démon…", action: #selector(startDaemon), keyEquivalent: "")
        startItem.target = self
        startItem.isEnabled = (s == nil)
        menu.addItem(startItem)

        let stopItem = NSMenuItem(title: "Arrêter le démon", action: #selector(stopDaemon), keyEquivalent: "")
        stopItem.target = self
        stopItem.isEnabled = (s != nil)
        menu.addItem(stopItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quitter (laisse le démon tourner)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: Actions

    @objc private func startDaemon() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let error = DaemonClient.startWithAdminPrompt()
            DispatchQueue.main.async {
                if let error, error != "annulé" {
                    self?.alert("Démarrage impossible", error)
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
