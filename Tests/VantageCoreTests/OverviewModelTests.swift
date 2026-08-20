import XCTest
@testable import VantageCore

/// The dropdown's arithmetic, finally testable.
///
/// Every rule here was previously enforced only by reading `MenuController` — it lived in a type
/// that can't be constructed without a real status item, so none of it could be covered.
final class OverviewModelTests: XCTestCase {
    private let rates = FXRates(perEUR: ["EUR": 1, "USD": Decimal(string: "1.10")!],
                                published: "2026-08-19", fetchedAt: Date())

    /// 20 Aug 2026, mid-morning Pacific — so `ReportDate.yesterday(now:)` is the 19th.
    private var now: Date { ReportDate(year: 2026, month: 8, day: 20).pacificTime(hour: 11) }
    private var yesterday: ReportDate { ReportDate(year: 2026, month: 8, day: 19) }

    private func day(_ date: ReportDate,
                     units: Decimal,
                     proceeds: [String: Decimal] = ["USD": 10],
                     origin: DaySales.Origin = .observed,
                     apps: [AppSales] = [],
                     skipped: Int = 0) -> DaySales {
        DaySales(date: date, origin: origin, downloads: units, proceeds: proceeds, apps: apps,
                 fetchedAt: now, skippedRows: skipped,
                 unitsByProductType: ["1": units])
    }

    private func build(_ days: [DaySales], rates: FXRates? = nil,
                       error: Error? = nil) -> OverviewModel {
        OverviewModel.build(days: days, rates: rates ?? self.rates, error: error,
                            metrics: [.installs], displayCurrency: "USD", now: now)
    }

    // MARK: - Empty states

    func testNoDaysAndNoErrorIsLoading() {
        let model = OverviewModel.build(days: [], rates: nil, error: nil, metrics: [.installs],
                                        displayCurrency: "USD", now: now)
        XCTAssertEqual(model.emptyMessage, "Loading…")
        XCTAssertNil(model.checkedAt, "Nothing failed, so there's nothing to say it retried")
        XCTAssertTrue(model.isEmpty)
    }

    func testNoDaysWithAnErrorShowsTheErrorAndWhenItWasChecked() {
        let model = build([], error: SalesError.network)
        XCTAssertEqual(model.emptyMessage, SalesError.network.errorDescription)
        XCTAssertNotNil(model.checkedAt)
        XCTAssertNil(model.headline)
    }

    /// An error alongside real data must not blank the data — the numbers are still true, the
    /// refresh just didn't add to them.
    func testAnErrorWithCachedDaysStillShowsTheNumbers() {
        let model = build([day(yesterday, units: 10)], error: SalesError.rateLimited)
        XCTAssertNil(model.emptyMessage)
        XCTAssertNotNil(model.headline)
        XCTAssertTrue(model.warnings.contains(SalesError.rateLimited.errorDescription!))
    }

    // MARK: - The seven-day comparison

    /// The rule that makes the comparison mean anything: a day is compared against the week
    /// *before* it. Averaging a day into its own baseline flattens the spike worth noticing.
    func testSevenDayAverageExcludesTheDayItself() {
        // Yesterday spikes to 100; the seven days before it are all 10.
        var days = [day(yesterday, units: 100)]
        for offset in 1...7 {
            days.append(day(yesterday.adding(days: -offset), units: 10))
        }
        let model = build(days)
        // Against a baseline of 10 that's +900%. Had yesterday been included the baseline would be
        // 21.25 and the figure a much tamer +371%.
        XCTAssertEqual(model.headline?.comparison, "vs 7-day average: ▲ 900%")
    }

    func testComparisonIsAbsentWithOnlyOneDay() {
        let model = build([day(yesterday, units: 10)])
        XCTAssertNil(model.headline?.comparison,
                     "One day has no prior week, and inventing a baseline would be a lie")
    }

    func testComparisonLooksNoFurtherBackThanSevenDays() {
        var days = [day(yesterday, units: 10)]
        for offset in 1...7 { days.append(day(yesterday.adding(days: -offset), units: 10)) }
        // An eighth day far outside the window must not move the average.
        days.append(day(yesterday.adding(days: -8), units: 100_000))
        XCTAssertEqual(build(days).headline?.comparison, "vs 7-day average: — level")
    }

    // MARK: - Origin

    func testAnAssumedZeroDaySaysSo() {
        let model = build([day(yesterday, units: 0, proceeds: [:], origin: .assumedZero)])
        XCTAssertEqual(model.headline?.assumedZeroNote, "No report published — recorded as zero")
    }

    func testAnObservedDayCarriesNoSuchNote() {
        XCTAssertNil(build([day(yesterday, units: 5)]).headline?.assumedZeroNote)
    }

    // MARK: - Freshness

    func testSaysWhenTheNewestReportIsNotTheNewestPossible() {
        let stale = yesterday.adding(days: -3)
        let model = build([day(stale, units: 5)])
        XCTAssertTrue(model.footnotes.contains { $0.contains("isn't published yet") },
                      "\(model.footnotes)")
    }

    func testSaysNothingAboutPublicationWhenTheNewestDayIsCached() {
        let model = build([day(yesterday, units: 5)])
        XCTAssertFalse(model.footnotes.contains { $0.contains("isn't published yet") },
                       "\(model.footnotes)")
    }

    func testNamesTheRateDateWhenRatesArePresent() {
        let model = build([day(yesterday, units: 5)])
        XCTAssertTrue(model.footnotes.contains { $0.contains("2026-08-19") }, "\(model.footnotes)")
    }

    func testSaysRatesAreUnavailableRatherThanStayingSilent() {
        let model = OverviewModel.build(days: [day(yesterday, units: 5)], rates: nil, error: nil,
                                        metrics: [.installs], displayCurrency: "USD", now: now)
        XCTAssertTrue(model.footnotes.contains { $0.contains("unavailable") }, "\(model.footnotes)")
    }

    // MARK: - Warnings

    func testSkippedRowsAreSummedAcrossEveryCachedDay() {
        let days = [day(yesterday, units: 1, skipped: 2),
                    day(yesterday.adding(days: -1), units: 1, skipped: 3)]
        XCTAssertTrue(build(days).warnings.contains("5 unreadable rows skipped"),
                      "\(build(days).warnings)")
    }

    func testASingleSkippedRowIsNotPluralised() {
        let model = build([day(yesterday, units: 1, skipped: 1)])
        XCTAssertTrue(model.warnings.contains("1 unreadable row skipped"), "\(model.warnings)")
    }

    func testNoWarningWhenNothingWasSkipped() {
        XCTAssertTrue(build([day(yesterday, units: 1)]).warnings.isEmpty)
    }

    // MARK: - App rows

    private func app(_ id: String, _ title: String, _ proceeds: [String: Decimal],
                     units: Decimal = 1) -> AppSales {
        AppSales(appleID: id, title: title, downloads: units, proceeds: proceeds,
                 unitsByProductType: ["1": units])
    }

    func testAppsAreRankedByConvertedProceeds() {
        // 100 EUR converts to 110 USD, so it outranks the 50 USD app despite the smaller number.
        let day = day(yesterday, units: 3, apps: [
            app("1", "Fifty", ["USD": 50]),
            app("2", "Hundred EUR", ["EUR": 100]),
            app("3", "Ten", ["USD": 10]),
        ])
        XCTAssertEqual(build([day]).apps.map(\.title), ["Hundred EUR", "Fifty", "Ten"])
    }

    /// Dictionary and parser ordering are both unstable; the rows must not be.
    func testTiedAppsAreOrderedByTitle() {
        let day = day(yesterday, units: 2, apps: [
            app("1", "Zebra", ["USD": 10]),
            app("2", "Alpha", ["USD": 10]),
        ])
        XCTAssertEqual(build([day]).apps.map(\.title), ["Alpha", "Zebra"])
    }

    /// v0.1 capped the list at eight and hid the rest behind "+n more". The panel scrolls, so
    /// there's nothing left to hide behind.
    func testEveryAppIsListed() {
        let apps = (1...20).map { app("\($0)", "App \($0)", ["USD": Decimal($0)]) }
        XCTAssertEqual(build([day(yesterday, units: 20, apps: apps)]).apps.count, 20)
    }

    func testAppRowsCarryTheAppleIDSoTheyCanNavigate() {
        let day = day(yesterday, units: 1, apps: [app("6478", "Vantage", ["USD": 1])])
        XCTAssertEqual(build([day]).apps.first?.appleID, "6478")
    }

    // MARK: - Windows

    func testWindowsSumProceedsAcrossTheirLength() {
        var days: [DaySales] = []
        for offset in 0..<10 {
            days.append(day(yesterday.adding(days: -offset), units: 1, proceeds: ["USD": 10]))
        }
        let model = build(days)
        XCTAssertEqual(model.windows.count, 2)
        XCTAssertEqual(model.windows[0].label, "Last 7 days")
        XCTAssertEqual(model.windows[0].money.sortKey, 70)
        // Only ten days are cached, so the 30-day window totals what exists rather than padding.
        XCTAssertEqual(model.windows[1].money.sortKey, 100)
    }

    func testWindowsAreOmittedWhenThereAreNoDays() {
        XCTAssertTrue(build([]).windows.isEmpty)
    }

    // MARK: - Range

    private func run(_ days: [DaySales], _ range: OverviewRange) -> OverviewModel {
        OverviewModel.build(days: days, rates: rates, error: nil, metrics: [.installs],
                            displayCurrency: "USD", range: range, now: now)
    }

    /// Ten days of 10 units and $10 each.
    private var tenDays: [DaySales] {
        (0..<10).map { day(yesterday.adding(days: -$0), units: 10, proceeds: ["USD": 10]) }
    }

    func testHeadlineTotalsTheSelectedRange() {
        XCTAssertEqual(run(tenDays, .yesterday).headline?.units, 10)
        XCTAssertEqual(run(tenDays, .week).headline?.units, 70)
        // Only ten days exist, so the 30-day range totals what's cached rather than padding.
        XCTAssertEqual(run(tenDays, .month).headline?.units, 100)
    }

    func testHeadlineMoneyFollowsTheRangeToo() {
        XCTAssertEqual(run(tenDays, .yesterday).headline?.money.sortKey, 10)
        XCTAssertEqual(run(tenDays, .week).headline?.money.sortKey, 70)
    }

    func testHeadlineTitleNamesTheRange() {
        XCTAssertEqual(run(tenDays, .yesterday).headline?.title, "Yesterday")
        XCTAssertEqual(run(tenDays, .week).headline?.title, "Last 7 days")
        XCTAssertEqual(run(tenDays, .month).headline?.title, "Last 30 days")
    }

    /// The span is what the range *means*, not what happens to be cached — otherwise a failed fetch
    /// silently redefines "last 7 days" as "the four days that worked".
    func testSpanCoversTheIntendedRangeEvenWithDaysMissing() {
        let sparse = [day(yesterday, units: 1), day(yesterday.adding(days: -6), units: 1)]
        let label = run(sparse, .week).headline?.dateLabel
        XCTAssertEqual(label, Fmt.span(from: yesterday.adding(days: -6), to: yesterday))
    }

    /// Showing "Last 7 days" beside a headline that already says "Last 7 days" wastes the card's
    /// most valuable corner on a repeat.
    func testTrailingWindowsAreTheRangesNotSelected() {
        XCTAssertEqual(run(tenDays, .yesterday).windows.map(\.label),
                       ["Last 7 days", "Last 30 days"])
        XCTAssertEqual(run(tenDays, .week).windows.map(\.label), ["Yesterday", "Last 30 days"])
        XCTAssertEqual(run(tenDays, .month).windows.map(\.label), ["Yesterday", "Last 7 days"])
    }

    /// A day against a day is weekday-versus-weekend noise; a week against a week isn't.
    func testWeekAndMonthCompareAgainstThePrecedingWindow() {
        var days = (0..<7).map { day(yesterday.adding(days: -$0), units: 20) }
        days += (7..<14).map { day(yesterday.adding(days: -$0), units: 10) }
        // 140 this week against 70 last week.
        XCTAssertEqual(run(days, .week).headline?.comparison, "vs previous 7 days: ▲ 100%")
    }

    func testComparisonIsAbsentWithoutAPrecedingWindow() {
        let days = (0..<7).map { day(yesterday.adding(days: -$0), units: 10) }
        XCTAssertNil(run(days, .week).headline?.comparison)
    }

    /// One guessed day among seven doesn't make the week's total a guess.
    func testAssumedZeroIsOnlyCalledOutForASingleDay() {
        var days = [day(yesterday, units: 0, proceeds: [:], origin: .assumedZero)]
        days += (1..<7).map { day(yesterday.adding(days: -$0), units: 10) }
        XCTAssertNotNil(run(days, .yesterday).headline?.assumedZeroNote)
        XCTAssertNil(run(days, .week).headline?.assumedZeroNote)
    }

    // MARK: - App aggregation across a range

    func testAppRowsSumAcrossTheRange() {
        let days = (0..<7).map { offset in
            day(yesterday.adding(days: -offset), units: 5,
                apps: [app("1", "Vantage", ["USD": 3], units: 5)])
        }
        let week = run(days, .week)
        XCTAssertEqual(week.apps.count, 1)
        XCTAssertEqual(week.apps.first?.units, 35)
        XCTAssertEqual(week.apps.first?.money.sortKey, 21)
    }

    /// An app that only sold on one day of the week still belongs in the week's list.
    func testAnAppPresentOnOnlyOneDayStillAppears() {
        var days = [day(yesterday, units: 1, apps: [app("1", "Daily", ["USD": 1], units: 1)])]
        days.append(day(yesterday.adding(days: -1), units: 2,
                        apps: [app("1", "Daily", ["USD": 1], units: 1),
                               app("2", "Rare", ["USD": 9], units: 1)]))
        XCTAssertEqual(Set(run(days, .week).apps.map(\.title)), ["Daily", "Rare"])
    }

    /// Apple's titles are localized and apps do get renamed; the newest name is the right one.
    func testAggregationKeepsTheMostRecentTitle() {
        let days = [day(yesterday, units: 1, apps: [app("1", "New Name", ["USD": 1])]),
                    day(yesterday.adding(days: -1), units: 1,
                        apps: [app("1", "Old Name", ["USD": 1])])]
        XCTAssertEqual(run(days, .week).apps.first?.title, "New Name")
    }

    // MARK: - Metrics

    /// Toggling a metric changes every figure derived from units, and must do so without a refetch —
    /// the per-product-type tally is already on disk.
    func testUnitsFollowTheSelectedMetrics() {
        let day = DaySales(date: yesterday, origin: .observed, downloads: 10,
                           proceeds: ["USD": 10], apps: [], fetchedAt: now,
                           unitsByProductType: ["1": 10, "IA1": 5])
        let installs = OverviewModel.build(days: [day], rates: rates, error: nil,
                                           metrics: [.installs], displayCurrency: "USD", now: now)
        let both = OverviewModel.build(days: [day], rates: rates, error: nil,
                                       metrics: [.installs, .inAppPurchases],
                                       displayCurrency: "USD", now: now)
        XCTAssertEqual(installs.headline?.units, 10)
        XCTAssertEqual(both.headline?.units, 15)
    }
}
