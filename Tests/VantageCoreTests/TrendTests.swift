import XCTest
@testable import VantageCore

/// A chart that disagrees with the numbers printed above it is worse than no chart, so the
/// normalization, the gaps and the sign handling are all pinned here rather than trusted to a view.
final class TrendTests: XCTestCase {
    private let rates = FXRates(perEUR: ["EUR": 1, "USD": Decimal(string: "1.10")!],
                                published: "2026-08-19", fetchedAt: Date())
    private let end = ReportDate(year: 2026, month: 8, day: 19)

    private func day(_ date: ReportDate, units: Decimal,
                     proceeds: [String: Decimal] = [:],
                     apps: [AppSales] = []) -> DaySales {
        DaySales(date: date, origin: .observed, downloads: units, proceeds: proceeds, apps: apps,
                 fetchedAt: Date(), unitsByProductType: ["1": units])
    }

    private func build(_ days: [DaySales], _ series: TrendSeries = .metric(.installs),
                       length: Int = 5, rates: FXRates? = nil,
                       appleID: String? = nil) -> TrendData {
        Trend.series(days: days, series: series, length: length, endingAt: end,
                     rates: rates ?? self.rates, displayCurrency: "USD", appleID: appleID)
    }

    // MARK: - Shape

    func testProducesOnePointPerDayOldestFirst() {
        let data = build([day(end, units: 5)], length: 5)
        XCTAssertEqual(data.points.count, 5)
        XCTAssertEqual(data.points.first?.date, end.adding(days: -4))
        XCTAssertEqual(data.points.last?.date, end)
    }

    // MARK: - Gaps

    /// The rule the whole type exists for: a day that was never fetched is not a day that earned
    /// nothing, and drawing it as zero invents a crash.
    func testAnUncachedDayIsAGapNotAZero() {
        // Only the newest and oldest days are cached; the three between them are missing.
        let days = [day(end, units: 10), day(end.adding(days: -4), units: 10)]
        let data = build(days, length: 5)
        XCTAssertEqual(data.points.map(\.value), [10, nil, nil, nil, 10])
        XCTAssertEqual(data.points.map { $0.unit == nil }, [false, true, true, true, false])
    }

    /// A cached day that genuinely earned nothing *is* a zero, and must stay distinguishable from
    /// the gap above.
    func testACachedZeroDayIsAValueNotAGap() {
        let days = [day(end, units: 10), day(end.adding(days: -1), units: 0)]
        let data = build(days, length: 2)
        XCTAssertEqual(data.points.map(\.value), [0, 10])
        XCTAssertNotNil(data.points.first?.unit)
    }

    func testNothingCachedProducesAllGaps() {
        let data = build([], length: 3)
        XCTAssertEqual(data.points.count, 3)
        XCTAssertTrue(data.points.allSatisfy { $0.value == nil })
        XCTAssertFalse(data.hasData)
    }

    // MARK: - Normalization

    func testRangeAlwaysIncludesZeroSoSmallWobblesAreNotExaggerated() {
        let days = (0..<3).map { day(end.adding(days: -$0), units: 40 + Decimal($0)) }
        let data = build(days, length: 3)
        XCTAssertEqual(data.lower, 0, "A floor of 40 would make a 5% wobble look like a collapse")
        XCTAssertEqual(data.upper, 42)
    }

    func testNormalizationSpansZeroToOne() {
        let days = [day(end, units: 100), day(end.adding(days: -1), units: 0)]
        let data = build(days, length: 2)
        XCTAssertEqual(data.points.first?.unit, 0)
        XCTAssertEqual(data.points.last?.unit, 1)
    }

    /// An all-zero series must not divide by zero, and must not be drawn as a line through the
    /// middle that looks like ordinary activity.
    func testAnAllZeroSeriesIsFlatAlongTheFloor() {
        let days = (0..<3).map { day(end.adding(days: -$0), units: 0) }
        let data = build(days, length: 3)
        XCTAssertEqual(data.points.compactMap(\.unit), [0, 0, 0])
        XCTAssertNil(data.zeroUnit, "Zero is already the floor; a second line there says nothing")
    }

    // MARK: - Negatives

    /// Refund days are real and carry negative units. Never floored, and the axis has to show.
    func testNegativeValuesPushTheFloorBelowZeroAndRaiseAZeroLine() {
        let days = [day(end, units: 100), day(end.adding(days: -1), units: -50)]
        let data = build(days, length: 2)
        XCTAssertEqual(data.lower, -50)
        XCTAssertEqual(data.upper, 100)
        // Zero sits a third of the way up a range running -50…100.
        XCTAssertEqual(data.zeroUnit ?? 0, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(data.points.first?.unit, 0)
    }

    func testAnAllNegativeSeriesStillPutsZeroAtTheTop() {
        let days = [day(end, units: -10), day(end.adding(days: -1), units: -20)]
        let data = build(days, length: 2)
        XCTAssertEqual(data.upper, 0, "Zero is the ceiling of a week that only refunded")
        XCTAssertEqual(data.zeroUnit, 1)
    }

    // MARK: - Proceeds

    func testProceedsAreConvertedBeforeCharting() {
        let days = [day(end, units: 0, proceeds: ["EUR": 100])]
        let data = build(days, .proceeds, length: 1)
        XCTAssertEqual(data.points.first?.value, 110)
    }

    /// Several currencies with no rate table is not a number, and the chart says so instead of
    /// drawing the largest one as though it were the total.
    func testProceedsWithoutRatesAreUnavailableRatherThanWrong() {
        let days = [day(end, units: 0, proceeds: ["EUR": 100, "USD": 50])]
        let data = Trend.series(days: days, series: .proceeds, length: 1, endingAt: end,
                                rates: nil, displayCurrency: "USD")
        XCTAssertNotNil(data.unavailable)
        XCTAssertTrue(data.points.isEmpty)
    }

    func testUnitMetricsChartFineWithoutRates() {
        let days = [day(end, units: 7)]
        let data = Trend.series(days: days, series: .metric(.installs), length: 1, endingAt: end,
                                rates: nil, displayCurrency: "USD")
        XCTAssertNil(data.unavailable, "Downloads need no exchange rate")
        XCTAssertEqual(data.points.first?.value, 7)
    }

    // MARK: - Per app

    private func app(_ id: String, units: Decimal, proceeds: [String: Decimal] = [:]) -> AppSales {
        AppSales(appleID: id, title: "App \(id)", downloads: units, proceeds: proceeds,
                 unitsByProductType: ["1": units])
    }

    func testRestrictingToOneAppIgnoresTheRest() {
        let days = [day(end, units: 30, apps: [app("1", units: 10), app("2", units: 20)])]
        XCTAssertEqual(build(days, length: 1, appleID: "1").points.first?.value, 10)
        XCTAssertEqual(build(days, length: 1, appleID: "2").points.first?.value, 20)
    }

    /// A day the app sold nothing on is a zero for that app, not a gap — the day was fetched.
    func testAnAppAbsentFromACachedDayReadsAsZeroNotAGap() {
        let days = [day(end, units: 20, apps: [app("2", units: 20)])]
        let data = build(days, length: 1, appleID: "1")
        XCTAssertEqual(data.points.first?.value, 0)
        XCTAssertNotNil(data.points.first?.unit)
    }

    // MARK: - The axis labels

    /// `upperLabel`/`lowerLabel` had no assertions at all, despite existing in Core specifically so
    /// "the axis can't disagree with the figures above it about how a number is written". Blanking
    /// them, or putting cents on a proceeds axis, both passed the suite.
    func testTheAxisLabelsAreFormattedForTheirSeries() {
        let units = build([day(end, units: 1234)], .metric(.installs), length: 1)
        XCTAssertTrue(units.upperLabel.contains("1") && units.upperLabel.contains("234"),
                      units.upperLabel)
        XCTAssertFalse(units.upperLabel.contains("$"), "Downloads are not money: \(units.upperLabel)")

        let money = build([day(end, units: 0, proceeds: ["USD": 1500])], .proceeds, length: 1)
        XCTAssertTrue(money.upperLabel.contains("1") && money.upperLabel.contains("500"),
                      money.upperLabel)
        // Compact, like the menu bar title — an axis is read for magnitude.
        XCTAssertFalse(money.upperLabel.contains(".00"), money.upperLabel)
    }

    func testTheFloorLabelIsZeroForAnOrdinarySeries() {
        let data = build([day(end, units: 50)], length: 1)
        XCTAssertTrue(data.lowerLabel.contains("0"), data.lowerLabel)
    }

    // MARK: - The zero line

    /// Removing the `lower < 0` guard draws a zero line along the floor of every all-positive
    /// chart, which reads as data.
    func testAnAllPositiveSeriesHasNoZeroLine() {
        let days = (0..<3).map { day(end.adding(days: -$0), units: 10 + Decimal($0)) }
        XCTAssertNil(build(days, length: 3).zeroUnit)
    }

    // MARK: - Per-app metric selection

    /// The per-app path resolved units through `Metric`, but the fixture set `downloads` equal to
    /// the tally, so substituting `app.downloads` passed. These differ deliberately.
    func testAPerAppSeriesCountsTheChosenMetricNotTheDownloadsField() {
        let app = AppSales(appleID: "1", title: "Mine", downloads: 999,
                           proceeds: [:], unitsByProductType: ["1": 7, "IA1": 3])
        let days = [day(end, units: 0, apps: [app])]

        XCTAssertEqual(build(days, .metric(.installs), length: 1, appleID: "1").points.first?.value,
                       7)
        XCTAssertEqual(
            build(days, .metric(.inAppPurchases), length: 1, appleID: "1").points.first?.value, 3)
    }

    // MARK: - Duplicate dates

    /// Two entries for one date shouldn't silently pick the later one — the cache is keyed by date,
    /// so a duplicate means something upstream is wrong and the first is as good an answer as any,
    /// but it must be deterministic.
    func testDuplicateDatesResolveDeterministically() {
        let days = [day(end, units: 10), day(end, units: 999)]
        XCTAssertEqual(build(days, length: 1).points.first?.value, 10)
    }

    // MARK: - Proceeds with a currency the ECB doesn't publish

    /// The chart took only the converted total, so a day holding both dollars and Taiwan dollars was
    /// plotted at the dollars alone — lower than the figure printed directly above it, with nothing
    /// saying why.
    func testADayWithUnconvertibleMoneyIsAGapAndIsCalledOut() {
        let days = [day(end, units: 0, proceeds: ["USD": 100, "TWD": 30_000]),
                    day(end.adding(days: -1), units: 0, proceeds: ["USD": 50])]
        let data = build(days, .proceeds, length: 2)

        XCTAssertNil(data.points.last?.value, "The mixed day can't be stated as one number")
        XCTAssertEqual(data.points.first?.value, 50)
        XCTAssertNotNil(data.note, "and the chart has to say a day is missing")
    }

    // MARK: - Storage round trip

    func testSeriesSurvivesUserDefaultsRoundTrip() {
        for series in TrendSeries.displayOrder {
            XCTAssertEqual(TrendSeries(rawValue: series.rawValue), series, series.label)
        }
    }

    func testUnknownStoredSeriesIsRejectedRatherThanGuessed() {
        XCTAssertNil(TrendSeries(rawValue: "metric:somethingApplAdded"))
        XCTAssertNil(TrendSeries(rawValue: "nonsense"))
    }
}
