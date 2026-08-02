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

    /// Phase 3: one line per cached day, so every figure can be checked against App Store Connect
    /// individually. Phase 4 replaces this with the real design.
    ///
    /// Deliberately unconverted — each day shows its own proceeds currencies as Apple reported
    /// them. Currency conversion arrives in Phase 4, and checking totals against the source is
    /// easier before a conversion step sits between them.
    func show(days: [DaySales], warning: Error? = nil) {
        guard let latest = days.max(by: { $0.date < $1.date }) else {
            showLoading()
            return
        }

        title = "\(Self.money(latest.proceeds)) · \(Fmt.downloadsWithArrow(latest.downloads))"

        var rows: [String] = []
        for day in days.sorted(by: { $0.date > $1.date }) {
            let marker = day.origin == .assumedZero ? "  (assumed zero)" : ""
            let skipped = day.skippedRows > 0 ? "  ⚠︎ \(day.skippedRows) rows skipped" : ""
            rows.append("\(day.date.apiString)   \(Self.money(day.proceeds))"
                        + " · \(Fmt.downloadsWithArrow(day.downloads))\(marker)\(skipped)")
        }
        rows.append("")
        rows.append("\(days.count) days cached · updated \(Fmt.clock(Date()))")
        if let warning {
            rows += Fmt.wrap((warning as? SalesError)?.errorDescription ?? "Some days failed.")
        }
        lines = rows
        render()
    }

    /// Every currency the day earned in, unconverted: `$84.00 + CZK 100.00`. A day with no
    /// proceeds reads as a plain zero in the user's own currency rather than as nothing at all.
    private static func money(_ proceeds: [String: Decimal]) -> String {
        let parts = proceeds
            .filter { $0.value != 0 }
            .sorted { $0.key < $1.key }
            .map { Fmt.money($0.value, currency: $0.key) }
        guard !parts.isEmpty else {
            return Fmt.money(0, currency: Locale.current.currency?.identifier ?? "USD")
        }
        return parts.joined(separator: " + ")
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
