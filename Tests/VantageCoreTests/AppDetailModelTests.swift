import XCTest
@testable import VantageCore

/// The detail section narrows the cache to one app and then reuses `OverviewModel`, so these cover
/// the narrowing — the part that's new — rather than re-testing the range arithmetic.
final class AppDetailModelTests: XCTestCase {
    private let rates = FXRates(perEUR: ["EUR": 1, "USD": Decimal(string: "1.10")!],
                                published: "2026-08-19", fetchedAt: Date())
    private var now: Date { ReportDate(year: 2026, month: 8, day: 20).pacificTime(hour: 11) }
    private var yesterday: ReportDate { ReportDate(year: 2026, month: 8, day: 19) }

    private func app(_ id: String, _ title: String, _ proceeds: [String: Decimal],
                     units: Decimal = 1) -> AppSales {
        AppSales(appleID: id, title: title, downloads: units, proceeds: proceeds,
                 unitsByProductType: ["1": units])
    }

    private func day(_ date: ReportDate, apps: [AppSales], skipped: Int = 0,
                     origin: DaySales.Origin = .observed) -> DaySales {
        var proceeds: [String: Decimal] = [:]
        var units: [String: Decimal] = [:]
        for app in apps {
            for (currency, amount) in app.proceeds { proceeds[currency, default: 0] += amount }
            for (type, count) in app.unitsByProductType { units[type, default: 0] += count }
        }
        return DaySales(date: date, origin: origin, downloads: 0, proceeds: proceeds, apps: apps,
                        fetchedAt: now, skippedRows: skipped, unitsByProductType: units)
    }

    private func build(_ appleID: String, _ days: [DaySales],
                       range: OverviewRange = .yesterday) -> AppDetailModel {
        AppDetailModel.build(appleID: appleID, days: days, rates: rates, error: nil,
                             metrics: [.installs], displayCurrency: "USD", range: range, now: now)
    }

    // MARK: - Narrowing

    func testFiguresCoverOnlyTheChosenApp() {
        let days = [day(yesterday, apps: [app("1", "Mine", ["USD": 10], units: 5),
                                          app("2", "Theirs", ["USD": 99], units: 50)])]
        let detail = build("1", days)
        XCTAssertEqual(detail.summary.headline?.money.sortKey, 10)
        XCTAssertEqual(detail.summary.headline?.units, 5)
    }

    func testTakesTheMostRecentTitle() {
        let days = [day(yesterday, apps: [app("1", "New Name", ["USD": 1])]),
                    day(yesterday.adding(days: -1), apps: [app("1", "Old Name", ["USD": 1])])]
        XCTAssertEqual(build("1", days).title, "New Name")
    }

    /// The day was fetched and the app earned nothing on it. Narrowing must keep that day — as a
    /// zero — rather than dropping it, or the newest report silently becomes the newest day this
    /// app happened to sell on and every date on screen shifts with it.
    func testADayTheAppDidNotSellOnIsKeptAsAZero() {
        let days = [day(yesterday, apps: [app("2", "Theirs", ["USD": 99])]),
                    day(yesterday.adding(days: -1), apps: [app("1", "Mine", ["USD": 5])])]
        let detail = build("1", days, range: .week)

        XCTAssertEqual(detail.summary.headline?.units, 1, "Only the day it sold on contributes")
        // Freshness still names yesterday, the day this app sold nothing — had that day been
        // dropped, the report date would have slid back to the day before.
        XCTAssertTrue(
            detail.summary.footnotes.contains { $0.contains(Fmt.reportDate(yesterday)) },
            "\(detail.summary.footnotes)")
        XCTAssertFalse(detail.summary.footnotes.contains { $0.contains("isn't published yet") },
                       "Yesterday is cached, so nothing is outstanding")
    }

    func testAppTotalsSumAcrossTheRange() {
        let days = (0..<7).map { offset in
            day(yesterday.adding(days: -offset), apps: [app("1", "Mine", ["USD": 3], units: 2)])
        }
        let detail = build("1", days, range: .week)
        XCTAssertEqual(detail.summary.headline?.money.sortKey, 21)
        XCTAssertEqual(detail.summary.headline?.units, 14)
    }

    // MARK: - Not found

    func testAnAppInNoCachedDaySaysSoRatherThanShowingZeroes() {
        let days = [day(yesterday, apps: [app("2", "Theirs", ["USD": 99])])]
        let detail = build("1", days)
        XCTAssertNotNil(detail.notFound)
        XCTAssertEqual(detail.title, "1", "With no title anywhere, the ID is the honest fallback")
    }

    func testAnAppPresentAnywhereInTheWindowIsFound() {
        let days = [day(yesterday, apps: [app("2", "Theirs", ["USD": 99])]),
                    day(yesterday.adding(days: -5), apps: [app("1", "Mine", ["USD": 1])])]
        XCTAssertNil(build("1", days, range: .month).notFound)
    }

    // MARK: - Warnings

    /// A malformed row belongs to the report, not to any app in it. Attributing it per app would
    /// show the same warning once for every app on screen.
    func testSkippedRowsAreNotAttributedToAnIndividualApp() {
        let days = [day(yesterday, apps: [app("1", "Mine", ["USD": 1])], skipped: 4)]
        XCTAssertTrue(build("1", days).summary.warnings.isEmpty,
                      "\(build("1", days).summary.warnings)")
    }

    /// Freshness is a property of the report and stays visible on the detail section too — it's
    /// still the thing that says which day is on screen.
    func testFreshnessFootnotesSurviveTheNarrowing() {
        let days = [day(yesterday, apps: [app("1", "Mine", ["USD": 1])])]
        XCTAssertTrue(build("1", days).summary.footnotes.contains { $0.contains("Report for") })
    }

    // MARK: - Engagement

    func testAnAppsHeadlineCarriesItsOwnEngagement() {
        let days = [day(yesterday, apps: [app("1", "Mine", ["USD": 1]), app("2", "Theirs", ["USD": 1])])]
        let engagement = ["1": [EngagementDay(date: yesterday, impressions: 340, pageViews: 12)],
                          "2": [EngagementDay(date: yesterday, impressions: 999, pageViews: 99)]]
        let model = AppDetailModel.build(
            appleID: "1", days: days, rates: rates, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: engagement, now: now)

        XCTAssertEqual(model.summary.headline?.engagement?.impressions, 340,
                       "One app's figures, not the portfolio's")
    }

    func testAnAppWithNoEngagementGetsTheNote() {
        let days = [day(yesterday, apps: [app("1", "Mine", ["USD": 1])])]
        let model = AppDetailModel.build(
            appleID: "1", days: days, rates: rates, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: [:], now: now)

        XCTAssertNil(model.summary.headline?.engagement)
        XCTAssertEqual(model.summary.headline?.engagementNote,
                       "Impressions not available yet for these days")
    }

    /// The detail section is the Overview's arithmetic on one app, so the "no key, no promise"
    /// rule has to reach it too — otherwise the same panel says two different things depending on
    /// which card you clicked.
    func testWithNoEngagementSourceAnAppsHeadlineSaysNothingAboutImpressions() {
        let days = [day(yesterday, apps: [app("1", "Mine", ["USD": 1])])]
        let model = AppDetailModel.build(
            appleID: "1", days: days, rates: rates, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: [:], hasEngagementSource: false, now: now)

        XCTAssertNil(model.summary.headline?.engagementNote)
    }
}
