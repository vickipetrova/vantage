import AppKit
import VantageCore

/// Owns the status item: the title in the menu bar, and what each mouse button does to it.
///
/// Left click toggles the panel. Right click opens a three-item `NSMenu` — Refresh, Settings, Quit
/// — so muscle memory and keyboard shortcuts keep working now that the dropdown is gone.
///
/// Everything this used to render lives in the panel. What's left is the title, which is the one
/// piece of Vantage that has to be right at a glance without opening anything.
///
/// Knows nothing about App Store Connect. It is handed `[DaySales]` and a rate table and renders
/// them, so a second `SalesProvider` is a matter of writing one file — keep provider-specific
/// strings out of here.
final class StatusItemController: NSObject {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Left click. Handed the button so the panel can anchor itself under the status item, which
    /// moves whenever another menu bar app appears or the display changes.
    var onTogglePanel: ((NSStatusBarButton) -> Void)?
    /// Called before the right-click menu opens, so an open panel doesn't sit under it.
    var onWillShowMenu: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    /// Most recent first.
    private var days: [DaySales] = []
    private var rates: FXRates?
    private var error: Error?
    private var hasCredentials = true

    override init() {
        super.init()
        menu.autoenablesItems = false
        // Static now that it holds only commands. The v0.1 menu was rebuilt on every open because
        // it rendered live data; this one has nothing to keep up to date.
        menu.addItem(action("Refresh Now", key: "r", selector: #selector(refreshClicked)))
        menu.addItem(action("Settings…", key: ",", selector: #selector(settingsClicked)))
        menu.addItem(.separator())
        menu.addItem(action("Quit Vantage", key: "q", selector: #selector(quitClicked)))

        // Deliberately *not* `statusItem.menu = menu`. Assigning a menu makes AppKit open it on
        // left click and never call the button's action, which is exactly the behaviour v0.2
        // replaces. The menu is attached for the length of a right click instead — see `showMenu`.
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        renderTitle()
    }

    // MARK: - Clicks

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        // Control-click is a right click on a one-button trackpad, and AppKit doesn't translate it
        // for us here.
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary { showMenu() } else { onTogglePanel?(button) }
    }

    /// Opens the menu for one click, then detaches it.
    ///
    /// `performClick` on a status item with a menu attached gives the real thing — native
    /// placement, the highlighted button, keyboard navigation — where `popUp(positioning:)` gives
    /// a menu floating near the cursor with no button highlight. Detaching immediately afterward is
    /// what keeps left click ours.
    private func showMenu() {
        onWillShowMenu?()
        statusItem.menu = menu
        // `defer`, because an attached menu is precisely the state this trick exists to avoid: with
        // one attached, AppKit opens it on left click and never calls the button's action. An early
        // return out of the tracking loop would make that permanent.
        defer { statusItem.menu = nil }
        statusItem.button?.performClick(nil)
    }

    // MARK: - Input

    func update(days: [DaySales], rates: FXRates?, error: Error?) {
        self.days = days.sorted { $0.date > $1.date }
        self.rates = rates
        self.error = error
        self.hasCredentials = true
        renderTitle()
    }

    func showNoCredentials() {
        days = []
        error = SalesError.noCredentials
        hasCredentials = false
        renderTitle()
    }

    // MARK: - Menu bar title

    /// `$142 · 89↓`, or one of the three plain states: `…` loading, `!` error, `–` nothing yet.
    private func renderTitle() {
        guard let button = statusItem.button else { return }

        guard let latest = days.first else {
            button.attributedTitle = NSAttributedString()
            if !hasCredentials || error != nil { button.title = hasCredentials ? "!" : "–" }
            else { button.title = "…" }
            return
        }

        let units = Metric.units(in: latest, metrics: Prefs.metrics)
        let figures = money(latest.proceeds, compact: true).headline
            + " · \(Fmt.downloadsWithArrow(units))"

        // A marker only when the figures are actually behind what Apple has published — never for a
        // failed refresh that left nothing missing. Marking the ordinary case would train people to
        // ignore the marker for the times it means something, and this is the one surface that is
        // always on screen.
        let freshness = Freshness.evaluate(newestCached: latest.date,
                                           lastSuccess: Prefs.lastRefreshSuccess,
                                           error: error)
        let text = freshness.marksMenuBar ? "⚠︎ " + figures : figures

        // Monospaced digits so the title doesn't shuffle sideways as the numbers tick over.
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
        button.toolTip = freshness.problem.map { "\(freshness.headline) — \($0)" }
            ?? freshness.headline
    }

    /// Formats proceeds for display, via the rate table currently on hand.
    ///
    /// The decisions this makes — what to do when rates are missing, which currency to show, what
    /// to say about the ones it can't convert — live in `VantageCore.Money` and are covered by
    /// `MoneyTests`. This is only the binding of that function to the controller's own state.
    private func money(_ proceeds: [String: Decimal], compact: Bool = false) -> MoneyText {
        Money.text(for: proceeds, rates: rates, displayCurrency: Prefs.displayCurrency,
                   compact: compact)
    }

    // MARK: - Menu items

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
