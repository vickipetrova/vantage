import Foundation

/// One app's slice of the cache, in the shape the detail section renders.
///
/// Deliberately thin: it narrows `[DaySales]` to a single app and then hands the result to
/// `OverviewModel`, so the range totals, the comparison rule and the freshness footnotes are the
/// same code — and the same tests — that the Overview uses. A second implementation of "last 7 days
/// versus the 7 before it" is a second implementation that can disagree with the first.
public struct AppDetailModel: Equatable {
    public let appleID: String
    public let title: String
    /// Range totals, comparison and notes, computed exactly as the Overview computes them.
    public let summary: OverviewModel
    /// Set when this app appears in no cached day at all — a stale link, or a report that no longer
    /// mentions it.
    public let notFound: String?

    public static func build(appleID: String,
                             days: [DaySales],
                             rates: FXRates?,
                             error: Error?,
                             metrics: Set<Metric>,
                             displayCurrency: String,
                             range: OverviewRange = .yesterday,
                             now: Date = Date()) -> AppDetailModel {
        let days = days.sorted { $0.date > $1.date }
        // Newest first, so the first title found is the most recent name Apple used for it.
        let title = days.lazy.compactMap { day in
            day.apps.first { $0.appleID == appleID }?.title
        }.first

        let summary = OverviewModel.build(days: narrow(days, to: appleID), rates: rates,
                                          error: error, metrics: metrics,
                                          displayCurrency: displayCurrency, range: range, now: now)

        return AppDetailModel(
            appleID: appleID,
            title: title ?? appleID,
            summary: summary,
            notFound: title == nil
                ? "No cached day mentions this app. It may have been removed from sale, or sold "
                    + "nothing in the last 30 days."
                : nil)
    }

    /// Rewrites each day so its totals are this app's totals.
    ///
    /// A day the app didn't sell on becomes a **zero**, not a gap: the day was fetched, and the app
    /// earning nothing that day is an observation. Dropping the day entirely would instead tell the
    /// chart it has no data there, which is a different and untrue claim.
    private static func narrow(_ days: [DaySales], to appleID: String) -> [DaySales] {
        days.map { day in
            let app = day.apps.first { $0.appleID == appleID }
            return DaySales(
                date: day.date,
                origin: day.origin,
                downloads: app?.downloads ?? 0,
                proceeds: app?.proceeds ?? [:],
                apps: app.map { [$0] } ?? [],
                fetchedAt: day.fetchedAt,
                // Skipped rows are a property of the report, not of any app in it. Attributing
                // them here would repeat one warning once per app.
                skippedRows: 0,
                unitsByProductType: app?.unitsByProductType ?? [:])
        }
    }
}
