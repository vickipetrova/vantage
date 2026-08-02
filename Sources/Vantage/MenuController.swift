import AppKit
import VantageCore

/// Owns the status item: the title in the menu bar and the dropdown behind it.
///
/// Knows nothing about App Store Connect. It is handed `DaySales` values and renders them, so a
/// second `SalesProvider` is a matter of writing one file — keep provider-specific strings out.
final class MenuController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    /// The pre-first-report title from the plan: not loading, not an error, just nothing yet.
    private var title = "–"
    private var detail = "Loading…"

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        render()
    }

    func showNoCredentials() {
        title = "–"
        detail = SalesError.noCredentials.errorDescription ?? ""
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
        menu.addItem(row(detail))
        menu.addItem(.separator())
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

    @objc private func quitClicked() { NSApp.terminate(nil) }
}
