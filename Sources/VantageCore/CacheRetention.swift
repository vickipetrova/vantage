import Foundation

/// What's cached, and deleting the older part of it when the user asks.
///
/// **Nothing calls `delete` on its own.** Apple deletes daily sales reports after a year and
/// analytics instances after 35 days, so past those points this cache is the only copy there is.
/// Deleting is a button in Settings behind a confirmation, and the confirmation's wording is built
/// here — where it's tested — rather than in the view that shows it.
public struct CacheRetention {
    private let reports: ReportStore
    private let analytics: AnalyticsStore

    public init(reports: ReportStore = ReportStore(), analytics: AnalyticsStore = AnalyticsStore()) {
        self.reports = reports
        self.analytics = analytics
    }

    // MARK: - Summary

    public struct Summary: Equatable {
        public let salesDays: Int
        public let oldest: ReportDate?
        public let newest: ReportDate?
        /// The whole cache directory — analytics, reviews and icons included.
        public let bytes: Int64

        /// "312 days of sales, 3 Jul 2025 – 15 Sep 2026 · 1.3 MB"
        public var text: String {
            guard let oldest, let newest else { return "Nothing cached yet." }
            let count = salesDays == 1 ? "1 day" : "\(salesDays) days"
            return "\(count) of sales, \(Fmt.span(from: oldest, to: newest))"
                + " · \(Fmt.bytes(bytes))"
        }
    }

    public func summary() -> Summary {
        let dates = reports.cachedDates()
        return Summary(salesDays: dates.count, oldest: dates.first, newest: dates.last,
                       bytes: reports.bytesOnDisk())
    }

    // MARK: - Deleting

    public struct Deletion: Equatable {
        public let salesDays: Int
        public let analyticsDays: Int

        public init(salesDays: Int, analyticsDays: Int) {
            self.salesDays = salesDays
            self.analyticsDays = analyticsDays
        }

        public var isEmpty: Bool { salesDays == 0 && analyticsDays == 0 }
    }

    /// What `delete(before:)` would remove, without removing it.
    public func preview(before cutoff: ReportDate) -> Deletion {
        Deletion(salesDays: reports.cachedDates().filter { $0 < cutoff }.count,
                 analyticsDays: analytics.cachedDates().filter { $0 < cutoff }.count)
    }

    /// Deletes sales and analytics days before `cutoff`. The cutoff day itself is kept.
    @discardableResult
    public func delete(before cutoff: ReportDate) -> Deletion {
        Deletion(salesDays: reports.prune(keepingSince: cutoff),
                 analyticsDays: analytics.prune(keepingSince: cutoff))
    }

    /// The confirmation shown before deleting.
    ///
    /// Says three things, because each has surprised someone: what goes, that it can't be undone,
    /// and — when the cutoff falls inside the history setting — that those days come straight back
    /// on the next refresh. Without that last line the button looks broken the next morning.
    public static func confirmation(for deletion: Deletion, before cutoff: ReportDate,
                                    historyDays: Int, now: Date = Date()) -> String {
        var parts: [String] = []
        var what: [String] = []
        if deletion.salesDays > 0 { what.append(days(deletion.salesDays) + " of sales") }
        if deletion.analyticsDays > 0 { what.append(days(deletion.analyticsDays) + " of analytics") }
        parts.append("Deletes \(what.joined(separator: " and ")) from before "
                     + "\(Fmt.reportDate(cutoff)). This can't be undone.")

        let fetchFrom = ReportDate.yesterday(now: now).adding(days: -(historyDays - 1))
        if deletion.salesDays > 0, fetchFrom < cutoff {
            parts.append("Sales from \(Fmt.reportDate(fetchFrom)) onward are inside your history "
                         + "setting, so Vantage will download those days again on the next refresh.")
        }

        parts.append("Apple keeps sales reports for a year and analytics for 35 days. "
                     + "Anything older exists only in Vantage's copy.")
        return parts.joined(separator: "\n\n")
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count) days"
    }
}
