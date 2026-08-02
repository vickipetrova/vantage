import AppKit
import VantageCore

/// Owns the status item: the title in the menu bar and the dropdown behind it.
///
/// Knows nothing about App Store Connect. It is handed values and renders them, so a second
/// `SalesProvider` is a matter of writing one file — keep provider-specific strings out.
final class MenuController: NSObject, NSMenuDelegate {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    /// The pre-first-report title from the plan: not loading, not an error, just nothing yet.
    private var title = "–"
    private var lines: [String] = ["Loading…"]

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render()
    }

    // MARK: - Input

    func showNoCredentials() {
        title = "–"
        lines = Fmt.wrap(SalesError.noCredentials.errorDescription ?? "")
        render()
    }

    func showLoading() {
        title = "…"
        lines = ["Fetching…"]
        render()
    }

    func show(error: Error) {
        title = "!"
        // Plus a timestamp: without it, pressing Refresh Now on a failure looks like it did
        // nothing at all, because the message it redraws is identical to the one it replaced.
        lines = Fmt.wrap((error as? SalesError)?.errorDescription ?? "Something went wrong.")
            + ["Checked \(Fmt.clock(Date()))"]
        render()
    }

    /// Phase 2 only: enough of a dropdown to confirm a real report arrived and landed on disk.
    /// Replaced by the real rendering once `ReportParser` and `ReportStore` exist.
    func showRawReport(date: ReportDate, lineCount: Int, path: String) {
        title = "✓"
        lines = [
            "Report for \(Fmt.reportDate(date))",
            "\(lineCount) lines · fetched \(Fmt.clock(Date()))",
        ] + Fmt.wrap("Saved to \(path)")
        render()
    }

    func showNoReportYet(date: ReportDate) {
        title = "–"
        lines = ["No report for \(Fmt.reportDate(date)) yet."]
        render()
    }

    private func render() {
        // Monospaced digits so the title doesn't shuffle sideways as the numbers change.
        statusItem.button?.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
    }

    // MARK: - Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in lines { menu.addItem(row(line)) }
        menu.addItem(.separator())
        menu.addItem(action("Refresh Now", key: "r", selector: #selector(refreshClicked)))
        menu.addItem(action("Settings…", key: ",", selector: #selector(settingsClicked)))
        menu.addItem(action("Quit Vantage", key: "q", selector: #selector(quitClicked)))
    }

    private func row(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, key: String, selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = true
        return item
    }

    @objc private func refreshClicked() { onRefresh?() }
    @objc private func settingsClicked() { onSettings?() }
    @objc private func quitClicked() { NSApp.terminate(nil) }
}
