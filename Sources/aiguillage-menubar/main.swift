import AppKit

// Plain SwiftPM executable (no .app bundle): an accessory app has no Dock icon and no main window,
// just the status-bar item. This runs fine as a bare binary under Command Line Tools.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = StatusController()
let delegate = AppDelegate(controller: controller)
app.delegate = delegate
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: StatusController

    init(controller: StatusController) {
        self.controller = controller
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}
