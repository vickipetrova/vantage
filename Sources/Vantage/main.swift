import AppKit
import VantageCore

/// Wiring: a provider, a cache, and the backfill that fills the gap between them.
///
/// Phase 3 state: the dropdown lists each cached day with its totals, so the numbers can be checked
/// against App Store Connect line by line. Phase 4 replaces that with the real design — menu bar
/// title, per-app rows, 7- and 30-day windows, currency conversion, and the scheduler.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = MenuController()
    private let settingsWindow = SettingsWindow()
    private let store = ReportStore()
    private let backfill: Backfill

    /// How far back the first run reaches. Thirty days covers the 7- and 30-day windows the menu
    /// shows, and Apple keeps daily reports for a year, so a wider net is possible but pointless.
    private static let backfillDays = 30

    override init() {
        backfill = Backfill(provider: ASCClient(), store: ReportStore())
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, no dock icon.
        MainMenu.install()  // Without this, ⌘V doesn't work in the Settings fields.

        menuController.onRefresh = { [weak self] in self?.refresh(userInitiated: true) }
        menuController.onSettings = { [weak self] in self?.settingsWindow.show() }
        settingsWindow.onCredentialsChanged = { [weak self] in self?.refresh(userInitiated: true) }

        guard KeychainStore.hasCredentials else {
            // First launch: nothing to show and nothing to fetch, so open the one window that
            // fixes that rather than sitting there displaying a dash.
            menuController.showNoCredentials()
            settingsWindow.show()
            return
        }
        showCached()
        refresh(userInitiated: false)
    }

    private var window: [ReportDate] { ReportDate.yesterday().lastDays(Self.backfillDays) }

    /// Renders whatever is already on disk. Instant, offline, and the reason a relaunch doesn't
    /// stare blankly while thirty requests go out.
    private func showCached() {
        let days = store.loadAll(window)
        if days.isEmpty {
            menuController.showLoading()
        } else {
            menuController.show(days: days)
        }
    }

    private func refresh(userInitiated: Bool) {
        guard KeychainStore.hasCredentials else {
            menuController.showNoCredentials()
            return
        }
        backfill.run(dates: window, userInitiated: userInitiated, onDay: { _ in
            // Each day lands independently, so the menu fills in as they arrive rather than
            // staying empty until the last request returns.
            DispatchQueue.main.async { [weak self] in self?.showCached() }
        }, completion: { error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let days = self.store.loadAll(self.window)
                if let error, days.isEmpty {
                    self.menuController.show(error: error)
                } else {
                    // Some days are on screen, so a failure on one of them is a footnote rather
                    // than a reason to blank everything out.
                    self.menuController.show(days: days, warning: error)
                }
            }
        })
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
