import AppKit
import VantageCore

/// Owns the status item: the title in the menu bar and the dropdown behind it.
///
/// Knows nothing about App Store Connect. It is handed `[DaySales]` and a rate table and renders
/// them, so a second `SalesProvider` is a matter of writing one file — keep provider-specific
/// strings out of here.
final class MenuController: NSObject, NSMenuDelegate {
    var onRefresh: (() -> Void)?
    var onSettings: (() -> Void)?
    /// Called when a metric is toggled, so the app can re-render from the cache. No refetch — every
    /// metric is computed from the per-product-type tally already on disk.
    var onMetricsChanged: (() -> Void)?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    /// Most recent first.
    private var days: [DaySales] = []
    private var rates: FXRates?
    private var error: Error?
    private var hasCredentials = true

    /// Per-app rows shown before collapsing the tail into "+n more". Enough for a portfolio, few
    /// enough that the menu doesn't become a spreadsheet.
    private static let appRowLimit = 8

    override init() {
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        renderTitle()
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

        let money = converted(latest.proceeds)
        let units = Metric.units(in: latest, metrics: Prefs.metrics)
        let text = "\(Fmt.moneyCompact(money.converted, currency: Prefs.displayCurrency))"
            + " · \(Fmt.downloadsWithArrow(units))"

        // Monospaced digits so the title doesn't shuffle sideways as the numbers tick over.
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
    }

    private func converted(_ proceeds: [String: Decimal])
        -> (converted: Decimal, unconverted: [String: Decimal]) {
        guard let rates else {
            // No rate table yet. Showing the largest single currency beats showing nothing, and
            // the dropdown says why the total isn't a total.
            let largest = proceeds.max { abs($0.value) < abs($1.value) }
            guard let largest else { return (0, [:]) }
            return (0, [largest.key: largest.value])
        }
        return rates.convert(proceeds, to: Prefs.displayCurrency)
    }

    // MARK: - Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error, days.isEmpty {
            for line in Fmt.wrap((error as? SalesError)?.errorDescription ?? "Something went wrong.") {
                menu.addItem(row(line))
            }
            menu.addItem(row("Checked \(Fmt.clock(Date()))"))
        } else if days.isEmpty {
            menu.addItem(row("Loading…"))
        } else {
            buildYesterday(menu)
            buildApps(menu)
            buildWindows(menu)
            buildFreshness(menu)
        }

        menu.addItem(.separator())
        if !days.isEmpty { menu.addItem(metricsItem()) }
        menu.addItem(action("Refresh Now", key: "r", selector: #selector(refreshClicked)))
        menu.addItem(action("Settings…", key: ",", selector: #selector(settingsClicked)))
        menu.addItem(action("Quit Vantage", key: "q", selector: #selector(quitClicked)))
    }

    private func buildYesterday(_ menu: NSMenu) {
        guard let latest = days.first else { return }
        menu.addItem(header("YESTERDAY — \(Fmt.reportDate(latest.date))"))

        let money = converted(latest.proceeds)
        let units = Metric.units(in: latest, metrics: Prefs.metrics)
        menu.addItem(row("\(approx(money.converted)) · \(Fmt.downloadsWithArrow(units))"))

        // Against the trailing week, excluding the day itself — comparing a day to an average it's
        // part of flattens exactly the spike worth noticing.
        let previous = Array(days.dropFirst().prefix(7))
        if !previous.isEmpty {
            let average = Metric.units(in: previous, metrics: Prefs.metrics) / Decimal(previous.count)
            menu.addItem(row("vs 7-day average: \(Fmt.change(from: average, to: units))"))
        }

        if latest.origin == .assumedZero {
            menu.addItem(row("No report published — recorded as zero"))
        }
        for (currency, amount) in money.unconverted.sorted(by: { $0.key < $1.key }) {
            menu.addItem(row("+ \(Fmt.money(amount, currency: currency)) not converted"))
        }
    }

    private func buildApps(_ menu: NSMenu) {
        guard let latest = days.first, !latest.apps.isEmpty else { return }
        menu.addItem(.separator())

        let ranked = latest.apps.sorted { converted($0.proceeds).converted > converted($1.proceeds).converted }
        for app in ranked.prefix(Self.appRowLimit) {
            let money = converted(app.proceeds).converted
            let units = Metric.units(in: app, metrics: Prefs.metrics)
            menu.addItem(row("\(app.title)   \(approx(money)) · \(Fmt.downloadsWithArrow(units))"))
        }
        if ranked.count > Self.appRowLimit {
            menu.addItem(row("+\(ranked.count - Self.appRowLimit) more"))
        }
    }

    private func buildWindows(_ menu: NSMenu) {
        menu.addItem(.separator())
        for (label, count) in [("LAST 7 DAYS", 7), ("LAST 30 DAYS", 30)] {
            let window = Array(days.prefix(count))
            guard !window.isEmpty else { continue }
            var totals: [String: Decimal] = [:]
            for day in window {
                for (currency, amount) in day.proceeds { totals[currency, default: 0] += amount }
            }
            let money = converted(totals)
            let units = Metric.units(in: window, metrics: Prefs.metrics)
            menu.addItem(header(label))
            menu.addItem(row("\(approx(money.converted)) · \(Fmt.downloadsWithArrow(units))"))
        }
    }

    private func buildFreshness(_ menu: NSMenu) {
        guard let latest = days.first else { return }
        menu.addItem(.separator())
        menu.addItem(row("Report for \(Fmt.reportDate(latest.date))"
                         + " · fetched \(Fmt.clock(latest.fetchedAt))"))

        // Apple publishes a day's report the next morning. If the newest cached day isn't the
        // newest that could exist, say which day is on screen rather than letting "yesterday" imply
        // something untrue.
        let newestPossible = ReportDate.yesterday()
        if latest.date < newestPossible {
            for line in Fmt.wrap("\(Fmt.reportDate(newestPossible))'s report isn't published yet"
                                 + " — showing \(Fmt.reportDate(latest.date)).") {
                menu.addItem(row(line))
            }
        }
        if let rates {
            menu.addItem(row("≈ converted at ECB rates for \(rates.published)"))
        } else {
            menu.addItem(row("Exchange rates unavailable — showing one currency"))
        }
        let skipped = days.reduce(0) { $0 + $1.skippedRows }
        if skipped > 0 { menu.addItem(row("⚠︎ \(skipped) unreadable rows skipped")) }
        if let error {
            for line in Fmt.wrap((error as? SalesError)?.errorDescription ?? "Last refresh failed.") {
                menu.addItem(row(line))
            }
        }
    }

    /// Money in the dropdown always carries the `≈`: it's a conversion at daily reference rates,
    /// and Apple's monthly financial reports are the authority.
    private func approx(_ amount: Decimal) -> String {
        "≈ " + Fmt.money(amount, currency: Prefs.displayCurrency)
    }

    // MARK: - Metrics submenu

    /// Which units the `↓` counts. Installs only by default, because that's what the arrow means —
    /// but App Store Connect's own dashboard adds in-app purchases to its headline figure, so the
    /// ability to reconcile against it has to be one click away.
    private func metricsItem() -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(header("COUNT AS DOWNLOADS"))

        guard let latest = days.first else { return NSMenuItem() }
        for metric in Metric.displayOrder {
            let units = metric.units(in: latest)
            let item = action("\(metric.label)  (\(Fmt.downloads(units)))",
                              key: "", selector: #selector(toggleMetric(_:)))
            item.state = Prefs.metrics.contains(metric) ? .on : .off
            item.representedObject = metric.rawValue
            submenu.addItem(item)
        }

        let item = NSMenuItem(title: "Metrics to show", action: nil, keyEquivalent: "")
        item.isEnabled = true
        item.submenu = submenu
        return item
    }

    @objc private func toggleMetric(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let metric = Metric(rawValue: raw) else { return }
        Prefs.toggle(metric)
        renderTitle()
        onMetricsChanged?()
    }

    // MARK: - Item builders

    private func header(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
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
