import AppKit
import VantageCore

/// Wiring. In v0.1 this owns the provider, the disk cache, and the scheduler that watches for
/// Apple to publish yesterday's report.
///
/// Scaffold state: the menu exists and renders the pre-first-report state. The provider, cache and
/// scheduler arrive in Phases 2–4.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = MenuController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, no dock icon.
        menuController.showNoCredentials()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
