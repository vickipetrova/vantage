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

        let units = Metric.units(in: latest, metrics: Prefs.metrics)
        let text = money(latest.proceeds, compact: true).headline
            + " · \(Fmt.downloadsWithArrow(units))"

        // Monospaced digits so the title doesn't shuffle sideways as the numbers tick over.
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
        ])
    }

    /// What to print for a bag of per-currency proceeds, and what to say underneath it.
    private struct MoneyText {
        let headline: String
        /// Lines the dropdown adds to account for anything the headline doesn't cover.
        let notes: [String]
        /// The converted total, for ranking apps against each other.
        let sortKey: Decimal
    }

    /// Formats proceeds, degrading honestly when rates are missing.
    ///
    /// With rates: one figure in the display currency, marked `≈`, plus a note naming any currency
    /// the ECB doesn't publish. Without rates: the largest single currency **in its own currency**
    /// plus a count of the others.
    ///
    /// What it must never do is print a converted-looking zero. An earlier version returned 0 when
    /// there was no rate table, so a day with real revenue rendered as `≈ $0.00` — indistinguishable
    /// from a day that earned nothing.
    private func money(_ proceeds: [String: Decimal], compact: Bool = false) -> MoneyText {
        let format = compact ? Fmt.moneyCompact : Fmt.money
        let nonZero = proceeds.filter { $0.value != 0 }

        guard let rates else {
            let ranked = nonZero.sorted { abs($0.value) > abs($1.value) }
            guard let largest = ranked.first else {
                return MoneyText(headline: format(0, Prefs.displayCurrency), notes: [], sortKey: 0)
            }
            let others = ranked.count - 1
            return MoneyText(
                headline: format(largest.value, largest.key),
                notes: others > 0
                    ? ["+ \(others) other \(others == 1 ? "currency" : "currencies")"] : [],
                sortKey: largest.value)
        }

        let (converted, unconverted) = rates.convert(nonZero, to: Prefs.displayCurrency)
        let notes = unconverted.sorted { $0.key < $1.key }.map {
            "+ \(Fmt.money($0.value, currency: $0.key)) — no ECB rate"
        }
        // No `≈` in the menu bar. It's a permanent fixture of the title rather than a warning about
        // any particular number, and at that size it reads as clutter. The dropdown keeps it, along
        // with the line naming the rate date — that's where someone checking a figure is looking.
        let marker = compact ? "" : "≈ "
        return MoneyText(headline: marker + format(converted, Prefs.displayCurrency),
                         notes: notes, sortKey: converted)
    }

    // MARK: - Dropdown

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let error, days.isEmpty {
            for line in Fmt.wrap((error as? SalesError)?.errorDescription ?? "Something went wrong.") {
                menu.addItem(row(line))
            }
            menu.addItem(footnote("Checked \(Fmt.clock(Date()))"))
        } else if days.isEmpty {
            menu.addItem(footnote("Loading…"))
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

        let total = money(latest.proceeds)
        let units = Metric.units(in: latest, metrics: Prefs.metrics)
        menu.addItem(row("\(total.headline) · \(Fmt.downloadsWithArrow(units))"))

        // Against the trailing week, excluding the day itself — comparing a day to an average it's
        // part of flattens exactly the spike worth noticing.
        let previous = Array(days.dropFirst().prefix(7))
        if !previous.isEmpty {
            let average = Metric.units(in: previous, metrics: Prefs.metrics) / Decimal(previous.count)
            menu.addItem(footnote("vs 7-day average: \(Fmt.change(from: average, to: units))"))
        }

        if latest.origin == .assumedZero {
            menu.addItem(row("No report published — recorded as zero"))
        }
        for note in total.notes { menu.addItem(footnote(note)) }
    }

    private func buildApps(_ menu: NSMenu) {
        guard let latest = days.first, !latest.apps.isEmpty else { return }
        menu.addItem(.separator())

        let ranked = latest.apps.sorted { money($0.proceeds).sortKey > money($1.proceeds).sortKey }
        for app in ranked.prefix(Self.appRowLimit) {
            let units = Metric.units(in: app, metrics: Prefs.metrics)
            menu.addItem(row("\(app.title)   \(money(app.proceeds).headline)"
                             + " · \(Fmt.downloadsWithArrow(units))"))
        }
        if ranked.count > Self.appRowLimit {
            menu.addItem(footnote("+\(ranked.count - Self.appRowLimit) more"))
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
            let total = money(totals)
            let units = Metric.units(in: window, metrics: Prefs.metrics)
            menu.addItem(header(label))
            menu.addItem(row("\(total.headline) · \(Fmt.downloadsWithArrow(units))"))
            for note in total.notes { menu.addItem(footnote(note)) }
        }
    }

    private func buildFreshness(_ menu: NSMenu) {
        guard let latest = days.first else { return }
        menu.addItem(.separator())
        menu.addItem(footnote("Report for \(Fmt.reportDate(latest.date))"
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
            menu.addItem(footnote("≈ converted at ECB rates for \(rates.published)"))
        } else {
            menu.addItem(footnote("Exchange rates unavailable — showing one currency"))
        }
        let skipped = days.reduce(0) { $0 + $1.skippedRows }
        if skipped > 0 { menu.addItem(footnote("⚠︎ \(skipped) unreadable rows skipped")) }
        if let error {
            for line in Fmt.wrap((error as? SalesError)?.errorDescription ?? "Last refresh failed.") {
                menu.addItem(row(line))
            }
        }
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
        // Derived from the menu font rather than pinned at 10pt: the rows below are now
        // `menuFont(ofSize: 0)`, so a fixed size would drift out of proportion the moment someone
        // raises their menu bar text size. Two points down from the row font, semibold.
        let base = NSFont.menuFont(ofSize: 0).pointSize
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: base - 2, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        item.isEnabled = false
        return item
    }

    /// A primary data row: the numbers people came here to read.
    ///
    /// Informational rows are disabled so they never take a selection highlight — they aren't
    /// actions. But AppKit dims a *plain* title on a disabled item, so every figure in this menu
    /// rendered as though it were an unavailable command. An attributed title keeps the
    /// foreground colour it was given regardless of enabled state, which is why `header` never had
    /// the problem and these rows did.
    private func row(_ text: String) -> NSMenuItem {
        item(text, color: .labelColor)
    }

    /// A de-emphasized row: context about the numbers rather than the numbers themselves.
    ///
    /// Secondary rather than dimmed-by-accident. The distinction is the point — everything used to
    /// look like this whether it meant to or not.
    private func footnote(_ text: String) -> NSMenuItem {
        item(text, color: .secondaryLabelColor)
    }

    private func item(_ text: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        // `menuFont(ofSize: 0)` is the system's own menu font at its own size. Hardcoding a size
        // would break at the larger menu-bar text settings people actually use.
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: color,
        ])
        // Enabled, despite these rows not being commands.
        //
        // A disabled item is drawn dimmed by macOS *regardless* of the foreground colour its
        // attributed title specifies — verified directly: disabled items with `labelColor`, with a
        // colour resolved to sRGB, and with `textColor` all render identically grey, while enabled
        // items render at full strength. So enabled state, not colour, is the only lever, and the
        // whole panel reads as unavailable without this.
        //
        // `action` stays nil, so there is nothing to fire. The cost is that macOS treats them as
        // selectable: they can highlight under the pointer, and a click dismisses the menu without
        // doing anything.
        item.isEnabled = true
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
