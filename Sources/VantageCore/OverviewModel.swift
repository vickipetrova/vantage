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
        public let units: Decimal
        public let unitsLabel: String
        /// `nil` when there's no prior week to compare against.
        public let comparison: String?
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

    public struct WindowTotal: Equatable, Identifiable {
        public let label: String
        public let money: MoneyText
        public let unitsLabel: String
        public var id: String { label }
    }

    public let headline: Headline?
    /// Ranked by converted proceeds, descending. Not truncated — the panel scrolls, so the v0.1
    /// "+n more" row has nothing left to hide.
    public let apps: [AppRow]
    public let windows: [WindowTotal]
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
                headline: nil, apps: [], windows: [], footnotes: [], warnings: [],
                emptyMessage: message ?? "Loading…",
                checkedAt: error == nil ? nil : "Checked \(Fmt.clock(now))")
        }

        // MARK: Headline

        let window = Array(days.prefix(range.days))
        let units = Metric.units(in: window, metrics: metrics)
        let total = money(sum(window))

        // The intended span, not the cached one: "Last 7 days" means seven days ending at the
        // newest report, whether or not all seven are on disk. Naming only the cached ones would
        // quietly redefine the range every time a fetch failed.
        let end = latest.date
        let start = end.adding(days: -(range.days - 1))

        let headline = Headline(
            title: range.label,
            dateLabel: Fmt.span(from: start, to: end),
            money: total,
            units: units,
            unitsLabel: Fmt.downloadsWithArrow(units),
            comparison: comparison(range: range, days: days, units: units, metrics: metrics),
            // Only meaningful for a single day. Across a week, one guessed day among seven doesn't
            // make the total a guess, and saying so would overstate it.
            assumedZeroNote: range == .yesterday && latest.origin == .assumedZero
                ? "No report published — recorded as zero" : nil)

        // MARK: Apps

        var apps: [AppRow] = []
        for app in aggregate(window) {
            let appUnits = Metric.units(in: app, metrics: metrics)
            apps.append(AppRow(appleID: app.appleID, title: app.title,
                               money: money(app.proceeds), units: appUnits,
                               unitsLabel: Fmt.downloadsWithArrow(appUnits)))
        }
        // Ties broken by title so the order is stable across renders rather than inheriting
        // whatever order the parser happened to produce.
        apps.sort { left, right in
            left.money.sortKey == right.money.sortKey
                ? left.title < right.title
                : left.money.sortKey > right.money.sortKey
        }

        // MARK: Windows

        // The ranges the headline *isn't* showing. Repeating the selected one beside itself would
        // spend the card's most valuable corner saying the same number twice.
        let windows = OverviewRange.allCases.filter { $0 != range }.compactMap { other -> WindowTotal? in
            let otherWindow = Array(days.prefix(other.days))
            guard !otherWindow.isEmpty else { return nil }
            let otherUnits = Metric.units(in: otherWindow, metrics: metrics)
            return WindowTotal(label: other.label, money: money(sum(otherWindow)),
                               unitsLabel: Fmt.downloadsWithArrow(otherUnits))
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

        var warnings: [String] = []
        let skipped = days.reduce(0) { $0 + $1.skippedRows }
        if skipped > 0 {
            warnings.append("\(skipped) unreadable row\(skipped == 1 ? "" : "s") skipped")
        }
        if let error {
            warnings.append((error as? SalesError)?.errorDescription ?? "Last refresh failed.")
        }

        return OverviewModel(headline: headline, apps: apps, windows: windows,
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

    /// One `AppSales` per app, totalled across the window.
    ///
    /// Product-type tallies are summed rather than the `downloads` field, so the rows answer for
    /// whichever metrics are switched on — a breakdown that doesn't sum to its own total is worse
    /// than no breakdown.
    private static func aggregate(_ days: [DaySales]) -> [AppSales] {
        var proceeds: [String: [String: Decimal]] = [:]
        var units: [String: [String: Decimal]] = [:]
        var downloads: [String: Decimal] = [:]
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
                for (type, count) in app.unitsByProductType {
                    units[app.appleID, default: [:]][type, default: 0] += count
                }
                downloads[app.appleID, default: 0] += app.downloads
            }
        }

        return order.map { id in
            AppSales(appleID: id, title: titles[id] ?? id, downloads: downloads[id] ?? 0,
                     proceeds: proceeds[id] ?? [:], unitsByProductType: units[id] ?? [:])
        }
    }

    /// What the figure is measured against.
    ///
    /// A single day is compared to the **average** of the seven before it, because one day against
    /// one day is mostly weekday-versus-weekend noise. A week or a month is compared to the
    /// immediately preceding window of the same length, where like-for-like already holds.
    private static func comparison(range: OverviewRange, days: [DaySales],
                                   units: Decimal, metrics: Set<Metric>) -> String? {
        switch range {
        case .yesterday:
            // Excluding the day itself — comparing a day to an average it's part of flattens
            // exactly the spike worth noticing.
            let previous = Array(days.dropFirst().prefix(7))
            guard !previous.isEmpty else { return nil }
            let average = Metric.units(in: previous, metrics: metrics) / Decimal(previous.count)
            return "vs 7-day average: \(Fmt.change(from: average, to: units))"
        case .week, .month:
            let previous = Array(days.dropFirst(range.days).prefix(range.days))
            guard !previous.isEmpty else { return nil }
            let total = Metric.units(in: previous, metrics: metrics)
            return "vs previous \(range.days) days: \(Fmt.change(from: total, to: units))"
        }
    }
}
