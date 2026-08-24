import Foundation

/// Everything the Overview section displays, computed from a cache and a rate table.
///
/// This is the v0.1 dropdown's arithmetic, lifted out of the view that used to do it inline. All of
/// it was previously untested — the seven-day comparison, the ranking, the freshness rules — because
/// it lived in a type that can't be constructed without a real status item.
///
/// Pure and injectable: no `Prefs`, no `Date()` without an argument, no AppKit. The view reads these
/// fields and styles them; it computes nothing.
/// How much of the cache the Overview summarises.
///
/// One control governing the headline, the app rows and the chart's highlight, rather than three
/// separate scopes the user has to keep in their head.
public enum OverviewRange: String, CaseIterable, Sendable {
    case yesterday
    case week
    case month

    public var days: Int {
        switch self {
        case .yesterday: return 1
        case .week: return 7
        case .month: return 30
        }
    }

    /// The heading over the figure.
    public var label: String {
        switch self {
        case .yesterday: return "Yesterday"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }

    /// The segmented control's text, where the full labels wouldn't fit.
    public var shortLabel: String {
        switch self {
        case .yesterday: return "1D"
        case .week: return "7D"
        case .month: return "30D"
        }
    }
}

public struct OverviewModel: Equatable {
    /// Yesterday's figures, and what qualifies them.
    public struct Headline: Equatable {
        /// "Yesterday", "Last 7 days"…
        public let title: String
        /// The days covered, formatted. Always shown — a range label alone has been wrong often
        /// enough to be worth naming the dates every time.
        public let dateLabel: String
        public let money: MoneyText
        /// Gross customer spend for the same range. `nil` when no cached day in it was read by a
        /// parser that knew about gross — showing zero would claim the range earned nothing.
        public let sales: MoneyText?
        public let units: Decimal
        public let unitsLabel: String
        /// `nil` when there's no prior window to compare against.
        public let comparison: String?
        /// Set when the range isn't fully cached, so a low total isn't read as a quiet week.
        public let coverage: String?
        /// Set when Apple published no report and the day was recorded as zero, which is a guess
        /// rather than an observation and has to say so.
        public let assumedZeroNote: String?
    }

    public struct AppRow: Equatable, Identifiable {
        public let appleID: String
        public let title: String
        public let money: MoneyText
        public let units: Decimal
        public let unitsLabel: String
        public var id: String { appleID }
    }

    public let headline: Headline?
    /// Ranked by converted proceeds, descending. Not truncated — the panel scrolls, so the v0.1
    /// "+n more" row has nothing left to hide.
    public let apps: [AppRow]
    /// Context about the numbers: which report, when fetched, how money was converted.
    public let footnotes: [String]
    /// Things that went wrong but didn't stop the numbers being shown.
    public let warnings: [String]
    /// Set when there is nothing to display at all — loading, or a failure with an empty cache.
    public let emptyMessage: String?
    /// Companion to `emptyMessage` on the failure path, so a stuck panel still shows it retried.
    public let checkedAt: String?

    public var isEmpty: Bool { emptyMessage != nil }

    // MARK: - Build

    /// - Parameters:
    ///   - days: newest first.
    ///   - range: what the headline and the app rows cover.
    ///   - now: injected so the "fetched at" and "checked at" strings are testable.
    public static func build(days: [DaySales],
                             rates: FXRates?,
                             error: Error?,
                             metrics: Set<Metric>,
                             displayCurrency: String,
                             range: OverviewRange = .yesterday,
                             now: Date = Date()) -> OverviewModel {
        let days = days.sorted { $0.date > $1.date }

        func money(_ proceeds: [String: Decimal]) -> MoneyText {
            Money.text(for: proceeds, rates: rates, displayCurrency: displayCurrency)
        }

        guard let latest = days.first else {
            let message = error.map { ($0 as? SalesError)?.errorDescription
                ?? "Something went wrong." }
            return OverviewModel(
                headline: nil, apps: [], footnotes: [], warnings: [],
                emptyMessage: message ?? "Loading…",
                checkedAt: error == nil ? nil : "Checked \(Fmt.clock(now))")
        }

        // MARK: Headline

        // **Selected by date, not by position.** `days.prefix(range.days)` looks equivalent and is
        // not: the cache can have holes — one date that persistently 500s, one corrupt file — and
        // `Backfill` deliberately carries on past them. With a hole inside the window, taking the
        // first seven *entries* reaches back past the range and totals days the label doesn't
        // cover. That produced $5,020 under a heading reading "Aug 13 – Aug 19".
        let end = latest.date
        let start = end.adding(days: -(range.days - 1))
        let window = days.filter { $0.date >= start && $0.date <= end }
        let units = Metric.units(in: window, metrics: metrics)
        let total = money(sum(window))

        // Only if some day in the range was actually read for it. A range of days parsed before
        // gross existed has no gross, and a zero there would read as "nobody bought anything".
        let knowsSales = window.contains { $0.parserVersion >= 1 }
        let grossTotal = knowsSales ? money(sumSales(window)) : nil

        let headline = Headline(
            title: range.label,
            dateLabel: Fmt.span(from: start, to: end),
            money: total,
            sales: grossTotal,
            units: units,
            unitsLabel: Fmt.downloadsWithArrow(units),
            comparison: comparison(range: range, days: days, end: end, units: units,
                                   metrics: metrics),
            coverage: window.count < range.days
                ? "\(window.count) of \(range.days) days cached" : nil,
            // Only meaningful for a single day. Across a week, one guessed day among seven doesn't
            // make the total a guess, and saying so would overstate it.
            assumedZeroNote: range == .yesterday && latest.origin == .assumedZero
                ? "No report published — recorded as zero" : nil)

        // MARK: Apps

        var apps: [AppRow] = []
        for app in aggregate(window, metrics: metrics) {
            apps.append(AppRow(appleID: app.appleID, title: app.title,
                               money: money(app.proceeds), units: app.units,
                               unitsLabel: Fmt.downloadsWithArrow(app.units)))
        }
        // Ranked by money only when the figures are actually comparable. Without a usable rate
        // table each row's `sortKey` is an amount in whichever currency it led with, so sorting on
        // it ranks by exchange rate — ¥15,000 (about $100) above $900. Units are cross-currency by
        // construction, so they're the honest fallback.
        //
        // Ties broken by title either way, so the order is stable across renders rather than
        // inheriting whatever order the parser happened to produce.
        let comparable = apps.allSatisfy(\.money.isComparable)
        apps.sort { left, right in
            let leftKey = comparable ? left.money.sortKey : left.units
            let rightKey = comparable ? right.money.sortKey : right.units
            return leftKey == rightKey ? left.title < right.title : leftKey > rightKey
        }

        // MARK: Footnotes

        var footnotes = ["Report for \(Fmt.reportDate(latest.date))"
                         + " · fetched \(Fmt.clock(latest.fetchedAt))"]

        // Apple publishes a day's report the next morning. If the newest cached day isn't the
        // newest that could exist, say which day is on screen rather than letting "yesterday" imply
        // something untrue.
        let newestPossible = ReportDate.yesterday(now: now)
        if latest.date < newestPossible {
            footnotes.append("\(Fmt.reportDate(newestPossible))'s report isn't published yet"
                             + " — showing \(Fmt.reportDate(latest.date)).")
        }

        if let rates {
            footnotes.append("≈ converted at ECB rates for \(rates.published)")
        } else {
            footnotes.append("Exchange rates unavailable — showing one currency")
        }

        // MARK: Warnings

        // Deliberately **not** the refresh error. That belongs to `Freshness` and the status bar
        // across the top of every section — repeating it down here is what let "Can't reach
        // api.appstoreconnect.apple.com" sit unnoticed below the fold for three days.
        var warnings: [String] = []
        let skipped = days.reduce(0) { $0 + $1.skippedRows }
        if skipped > 0 {
            warnings.append("\(skipped) unreadable row\(skipped == 1 ? "" : "s") skipped")
        }

        return OverviewModel(headline: headline, apps: apps,
                             footnotes: footnotes, warnings: warnings,
                             emptyMessage: nil, checkedAt: nil)
    }

    // MARK: - Helpers

    /// Proceeds across several days, currency by currency. Never collapsed to one number here —
    /// that needs rates, and it's `Money`'s decision.
    private static func sum(_ days: [DaySales]) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for day in days {
            for (currency, amount) in day.proceeds { totals[currency, default: 0] += amount }
        }
        return totals
    }

    /// Gross customer spend across several days, in the currencies customers paid in.
    private static func sumSales(_ days: [DaySales]) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for day in days {
            for (currency, amount) in day.sales { totals[currency, default: 0] += amount }
        }
        return totals
    }

    /// One app's totals across the window.
    struct Aggregated {
        let appleID: String
        let title: String
        let proceeds: [String: Decimal]
        let units: Decimal
    }

    /// Totals each app across the window.
    ///
    /// **Units are resolved per day and then summed**, not merged into one product-type dictionary
    /// and resolved once. `Metric.units` falls back to the legacy `downloads` field when a day
    /// carries no per-product-type tally, and that is a per-*day* decision — merging first means one
    /// modern day in the window makes the merged dictionary non-empty, and every legacy day's units
    /// silently vanish from the row while still counting in the headline above it. A breakdown that
    /// doesn't sum to its own total is worse than no breakdown.
    private static func aggregate(_ days: [DaySales], metrics: Set<Metric>) -> [Aggregated] {
        var proceeds: [String: [String: Decimal]] = [:]
        var units: [String: Decimal] = [:]
        var titles: [String: String] = [:]
        var order: [String] = []

        // Newest first, so the first title seen is the most recent one Apple used. Titles are
        // localized and do get renamed; showing last month's name for this month's app is worse
        // than showing today's for both.
        for day in days {
            for app in day.apps {
                if titles[app.appleID] == nil {
                    titles[app.appleID] = app.title
                    order.append(app.appleID)
                }
                for (currency, amount) in app.proceeds {
                    proceeds[app.appleID, default: [:]][currency, default: 0] += amount
                }
                units[app.appleID, default: 0] += Metric.units(in: app, metrics: metrics)
            }
        }

        return order.map { id in
            Aggregated(appleID: id, title: titles[id] ?? id,
                       proceeds: proceeds[id] ?? [:], units: units[id] ?? 0)
        }
    }

    /// What the figure is measured against.
    ///
    /// **Both sides are per-day averages over the days actually cached**, never raw totals. Totals
    /// compare two windows' *coverage* as much as their content: eight flat days used to read as
    /// "▲ 600%" because seven days of 20 were compared against the single earlier day that happened
    /// to be on disk. Averaging makes a partial window scale correctly, which is what the
    /// single-day branch always did and the others didn't.
    ///
    /// A single day is still measured against the seven before it rather than the one before it —
    /// day against day is mostly weekday-versus-weekend noise.
    private static func comparison(range: OverviewRange, days: [DaySales], end: ReportDate,
                                   units: Decimal, metrics: Set<Metric>) -> String? {
        let length = range == .yesterday ? 7 : range.days
        // The window immediately before this one, by date.
        let previousEnd = end.adding(days: -range.days)
        let previousStart = previousEnd.adding(days: -(length - 1))
        let previous = days.filter { $0.date >= previousStart && $0.date <= previousEnd }
        guard !previous.isEmpty else { return nil }

        let baseline = Metric.units(in: previous, metrics: metrics) / Decimal(previous.count)

        // The current side is averaged the same way, so both are per-day figures.
        let start = end.adding(days: -(range.days - 1))
        let current = days.filter { $0.date >= start && $0.date <= end }
        guard !current.isEmpty else { return nil }
        let value = units / Decimal(current.count)

        let label = range == .yesterday ? "7-day average" : "previous \(range.days) days"
        // Named, because this line sits under a money figure and measures units.
        return "Downloads vs \(label): \(Fmt.change(from: baseline, to: value))"
    }
}
