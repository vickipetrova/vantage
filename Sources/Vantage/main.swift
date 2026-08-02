import AppKit
import VantageCore

/// Wiring. In v0.1 this owns the provider, the disk cache, and the scheduler that watches for Apple
/// to publish yesterday's report.
///
/// Phase 2 state: one fetch of one day, straight to disk, so the credentials and the whole network
/// path can be verified against real numbers before any parsing exists to be wrong about them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let menuController = MenuController()
    private let settingsWindow = SettingsWindow()
    private let client = ASCClient()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Menu bar only, no dock icon.

        menuController.onRefresh = { [weak self] in self?.refresh() }
        menuController.onSettings = { [weak self] in self?.settingsWindow.show() }
        settingsWindow.onCredentialsChanged = { [weak self] in self?.refresh() }

        guard KeychainStore.hasCredentials else {
            // First launch: there is nothing to show and nothing to fetch, so open the one window
            // that fixes that rather than sitting there displaying a dash.
            menuController.showNoCredentials()
            settingsWindow.show()
            return
        }
        refresh()
    }

    private func refresh() {
        guard KeychainStore.hasCredentials else {
            menuController.showNoCredentials()
            return
        }
        let date = ReportDate.yesterday()
        menuController.showLoading()

        client.fetchTSV(date) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success(nil):
                    self.menuController.showNoReportYet(date: date)
                case .success(.some(let tsv)):
                    self.save(tsv, for: date)
                case .failure(let error):
                    self.menuController.show(error: error)
                }
            }
        }
    }

    /// Phase 2 only. Writes the decompressed report where it can be opened and compared against
    /// App Store Connect by hand. Phase 3 replaces this with the parsed, cached day summary — this
    /// app has no reason to keep raw reports around long-term.
    private func save(_ tsv: String, for date: ReportDate) {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Vantage/raw", isDirectory: true)
        let file = directory.appendingPathComponent("\(date.apiString).tsv")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try tsv.write(to: file, atomically: true, encoding: .utf8)
            // The path is safe to display: the filename is a date, never the vendor number.
            menuController.showRawReport(
                date: date,
                lineCount: tsv.split(separator: "\n").count,
                path: file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        } catch {
            menuController.show(error: SalesError.badReport)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
