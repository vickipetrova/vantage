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
    }

    /// The refresh error belongs to `Freshness` and the status bar, which is at the top of every
    /// section. Repeating it in a footnote at the bottom of one section is exactly how it went
    /// unnoticed for three days.
    func testTheRefreshErrorIsNotRepeatedInTheFootnotes() {
        let model = build([day(yesterday, units: 10)], error: SalesError.network)
        XCTAssertFalse(model.warnings.contains { $0.contains("reach") }, "\(model.warnings)")
        XCTAssertTrue(model.warnings.isEmpty)
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
        XCTAssertEqual(model.headline?.comparison, "Downloads vs 7-day average: ▲ 900%")
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
        XCTAssertEqual(build(days).headline?.comparison, "Downloads vs 7-day average: — level")
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


    /// A day against a day is weekday-versus-weekend noise; a week against a week isn't.
    func testWeekAndMonthCompareAgainstThePrecedingWindow() {
        var days = (0..<7).map { day(yesterday.adding(days: -$0), units: 20) }
        days += (7..<14).map { day(yesterday.adding(days: -$0), units: 10) }
        // 140 this week against 70 last week.
        XCTAssertEqual(run(days, .week).headline?.comparison, "Downloads vs previous 7 days: ▲ 100%")
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

    // MARK: - Regressions: windows are date-scoped, not positional

    /// The worst bug found in v0.2 review.
    ///
    /// `days.prefix(7)` looks equivalent to "the last seven days" and isn't: the cache can have
    /// holes, and taking the first seven *entries* reaches back past the range. This produced a
    /// five-figure total under a heading naming a week that contained twenty dollars.
    func testARangeTotalsOnlyTheDaysInsideIt() {
        // Two recent days, a five-day hole, then a run of very large days outside the week.
        var days = [day(yesterday, units: 1, proceeds: ["USD": 10]),
                    day(yesterday.adding(days: -1), units: 1, proceeds: ["USD": 10])]
        for offset in 9...14 {
            days.append(day(yesterday.adding(days: -offset), units: 100,
                            proceeds: ["USD": 1000]))
        }

        let week = run(days, .week)
        XCTAssertEqual(week.headline?.units, 2, "Only the two days inside the week count")
        XCTAssertEqual(week.headline?.money.sortKey, 20)
    }


    /// A range that isn't fully cached says so, rather than reading as a quiet week.
    func testAPartlyCachedRangeReportsItsCoverage() {
        let days = [day(yesterday, units: 1), day(yesterday.adding(days: -1), units: 1)]
        XCTAssertEqual(run(days, .week).headline?.coverage, "2 of 7 days cached")
        XCTAssertNil(run(days, .yesterday).headline?.coverage, "One day, one day cached")
    }

    // MARK: - Regressions: comparisons average, and are date-scoped

    /// Eight flat days used to read as "▲ 600%": seven days of 20 were compared against the single
    /// earlier day that happened to be on disk. Comparing per-day averages makes a partial window
    /// scale correctly.
    func testAFlatRunDoesNotReadAsGrowthWhenThePreviousWindowIsShort() {
        let days = (0..<8).map { day(yesterday.adding(days: -$0), units: 20) }
        XCTAssertEqual(run(days, .week).headline?.comparison,
                       "Downloads vs previous 7 days: — level")
    }

    /// The previous window is the seven days before this one — not "whatever comes next in the
    /// array", which a hole would otherwise fill with much older days.
    func testThePreviousWindowIsSelectedByDate() {
        // This week: 7 days of 20. Then a gap. Then very old, very large days.
        var days = (0..<7).map { day(yesterday.adding(days: -$0), units: 20) }
        for offset in 20...25 {
            days.append(day(yesterday.adding(days: -offset), units: 10_000))
        }
        XCTAssertNil(run(days, .week).headline?.comparison,
                     "Nothing is cached in the preceding week, so there is nothing to compare with")
    }

    /// The divisor is the whole answer when the baseline window is partly cached: with three days
    /// on disk, dividing by seven understates a spike by more than double. Every earlier test
    /// supplied exactly seven prior days, so a hardcoded `/ 7` passed.
    func testTheBaselineDividesByTheDaysActuallyCached() {
        // Yesterday at 100. Only three of the seven prior days are cached, each at 10.
        var days = [day(yesterday, units: 100)]
        for offset in 1...3 { days.append(day(yesterday.adding(days: -offset), units: 10)) }

        // Baseline is 30/3 = 10, so 100 is ▲ 900%. Dividing by 7 would give 4.29 and ▲ 2233%.
        XCTAssertEqual(run(days, .yesterday).headline?.comparison,
                       "Downloads vs 7-day average: ▲ 900%")
    }

    /// "Previous 7 days" must mean exactly that. With thirty days cached, taking everything older
    /// than this week would silently compare against twenty-three days.
    func testTheBaselineWindowIsBoundedAtBothEnds() {
        // This week: 7 days of 10. Last week: 7 days of 10. Before that: very large days.
        var days = (0..<14).map { day(yesterday.adding(days: -$0), units: 10) }
        for offset in 14..<30 {
            days.append(day(yesterday.adding(days: -offset), units: 10_000))
        }
        XCTAssertEqual(run(days, .week).headline?.comparison,
                       "Downloads vs previous 7 days: — level")
    }

    /// The parameter contract says newest first; `build` sorts defensively, and nothing tested it.
    func testBuildSortsItsInputRatherThanTrustingIt() {
        let ascending = (0..<3).map { day(yesterday.adding(days: -(2 - $0)), units: Decimal($0)) }
        // Oldest-first input. The headline must still be yesterday's figure.
        XCTAssertEqual(run(ascending, .yesterday).headline?.units, 2)
    }

    // MARK: - Regressions: app rows keep the per-day legacy fallback

    /// `Metric.units` falls back to the legacy `downloads` field when a day carries no
    /// per-product-type tally — a per-*day* decision. Merging the window into one dictionary first
    /// meant a single modern day made the merged tally non-empty, and every legacy day's units
    /// silently vanished from the row while still counting in the headline above it.
    func testAppRowsSumToTheHeadlineAcrossLegacyAndModernDays() {
        let modern = AppSales(appleID: "1", title: "Mine", downloads: 5,
                              proceeds: ["USD": 1], unitsByProductType: ["1": 5])
        // No per-product-type tally: a day written by an older build.
        let legacy = AppSales(appleID: "1", title: "Mine", downloads: 5,
                              proceeds: ["USD": 1], unitsByProductType: [:])

        var days: [DaySales] = []
        for offset in 0..<3 {
            days.append(DaySales(date: yesterday.adding(days: -offset), origin: .observed,
                                 downloads: 5, proceeds: ["USD": 1], apps: [modern],
                                 fetchedAt: now, unitsByProductType: ["1": 5]))
        }
        for offset in 3..<7 {
            days.append(DaySales(date: yesterday.adding(days: -offset), origin: .observed,
                                 downloads: 5, proceeds: ["USD": 1], apps: [legacy],
                                 fetchedAt: now, unitsByProductType: [:]))
        }

        let week = run(days, .week)
        XCTAssertEqual(week.headline?.units, 35)
        XCTAssertEqual(week.apps.first?.units, 35,
                       "A breakdown that doesn't sum to its own total is worse than no breakdown")
    }

    // MARK: - Regressions: ranking

    /// Without a usable rate table, ranking on the money figure ranks by exchange rate — ¥15,000 is
    /// about $100 and would beat $900. Units are cross-currency by construction.
    func testWithoutRatesAppsAreRankedByUnitsRatherThanRawAmounts() {
        let day = day(yesterday, units: 3, apps: [
            app("1", "Yen", ["JPY": 15_000], units: 1),
            app("2", "Dollars", ["USD": 900], units: 50),
        ])
        let model = OverviewModel.build(days: [day], rates: nil, error: nil, metrics: [.installs],
                                        displayCurrency: "USD", range: .yesterday, now: now)
        XCTAssertEqual(model.apps.map(\.title), ["Dollars", "Yen"])
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

    // MARK: - Arbitrary spans

    /// The CLI asks for spans the panel never shows: a length of its choosing, ending on a date of
    /// its choosing rather than the newest cached day.
    func testASpanCanEndBeforeTheNewestDay() {
        let days = (0..<20).map { day(yesterday.adding(days: -$0), units: Decimal($0 + 1)) }
        let end = yesterday.adding(days: -10)
        let model = OverviewModel.build(
            days: days, rates: rates, error: nil, metrics: [.installs], displayCurrency: "USD",
            span: .init(title: "Custom", length: 3, end: end), now: now)
        // Offsets 10, 11, 12 → units 11 + 12 + 13.
        XCTAssertEqual(model.headline?.units, 36)
        XCTAssertEqual(model.headline?.title, "Custom")
        XCTAssertEqual(model.headline?.dateLabel, Fmt.span(from: end.adding(days: -2), to: end))
        XCTAssertEqual(model.headline?.comparison?.contains("previous 3 days"), true)
    }

    func testALongSpanReportsItsCoverage() {
        let days = (0..<10).map { day(yesterday.adding(days: -$0), units: 1) }
        let model = OverviewModel.build(
            days: days, rates: rates, error: nil, metrics: [.installs], displayCurrency: "USD",
            span: .init(title: "Last 400 days", length: 400), now: now)
        XCTAssertEqual(model.headline?.coverage, "10 of 400 days cached")
        XCTAssertEqual(model.headline?.units, 10)
    }

    /// The panel's three ranges go through the same path, so they must still read the same.
    func testTheRangeOverloadMatchesItsSpan() {
        let days = (0..<40).map { day(yesterday.adding(days: -$0), units: Decimal($0)) }
        for range in OverviewRange.allCases {
            let viaRange = OverviewModel.build(days: days, rates: rates, error: nil,
                                               metrics: [.installs], displayCurrency: "USD",
                                               range: range, now: now)
            let viaSpan = OverviewModel.build(days: days, rates: rates, error: nil,
                                              metrics: [.installs], displayCurrency: "USD",
                                              span: range.span, now: now)
            XCTAssertEqual(viaRange, viaSpan, "\(range)")
        }
    }

    // MARK: - Engagement

    private func engagementDay(_ date: ReportDate, impressions: Decimal,
                               pageViews: Decimal) -> EngagementDay {
        EngagementDay(date: date, impressions: impressions, pageViews: pageViews)
    }

    func testTheHeadlineCarriesEngagementForTheSpan() {
        let day = day(yesterday, units: 10, apps: [app("1", "Mine", ["USD": 5]),
                                                    app("2", "Theirs", ["USD": 5])])
        let engagement = ["1": [engagementDay(yesterday, impressions: 1_000, pageViews: 45)],
                          "2": [engagementDay(yesterday, impressions: 1_140, pageViews: 51)]]
        let model = OverviewModel.build(days: [day], rates: nil, error: nil, metrics: [.installs],
                                        displayCurrency: "USD",
                                        span: OverviewModel.Span(title: "Yesterday", length: 1),
                                        engagement: engagement, now: now)

        XCTAssertEqual(model.headline?.engagement?.impressions, 2_140)
        XCTAssertEqual(model.headline?.engagement?.pageViews, 96)
        XCTAssertNil(model.headline?.engagementNote, "Figures and a note are mutually exclusive")
    }

    /// Apple finalises a day about two days after it, so the newest sales day usually has no
    /// analytics. Saying so beats a blank space or a zero.
    func testASpanWithNoEngagementSaysSoInsteadOfShowingZeros() {
        let model = OverviewModel.build(
            days: [day(yesterday, units: 10)], rates: nil, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: ["1": [engagementDay(yesterday.adding(days: -30), impressions: 5,
                                             pageViews: 1)]],
            now: now)

        XCTAssertNil(model.headline?.engagement)
        XCTAssertEqual(model.headline?.engagementNote,
                       "Impressions not available yet for these days")
    }

    /// "Not available **yet**" promises figures that are coming. With no reviews key nothing is
    /// coming, and the card below already explains that a key is what's missing — two different
    /// answers to the same question, one of them false.
    func testWithNoEngagementSourceTheHeadlineSaysNothingAboutImpressions() {
        let model = OverviewModel.build(
            days: [day(yesterday, units: 10)], rates: nil, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            hasEngagementSource: false, now: now)

        XCTAssertNil(model.headline?.engagement)
        XCTAssertNil(model.headline?.engagementNote,
                     "The card explains the missing key; the headline must not contradict it")
    }

    /// The same span, with a key: the note is the right answer again.
    func testWithAnEngagementSourceTheHeadlineStillSaysTheyArePending() {
        let model = OverviewModel.build(
            days: [day(yesterday, units: 10)], rates: nil, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            hasEngagementSource: true, now: now)

        XCTAssertEqual(model.headline?.engagementNote,
                       "Impressions not available yet for these days")
    }

    func testTheRetentionFootnoteAppearsOnlyWithEngagementFigures() {
        let note = "Apple keeps analytics for 35 days — older days are Vantage's own copy."

        let withEngagement = OverviewModel.build(
            days: [day(yesterday, units: 10)], rates: nil, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: ["1": [engagementDay(yesterday, impressions: 10, pageViews: 1)]], now: now)
        XCTAssertTrue(withEngagement.footnotes.contains(note))

        let without = OverviewModel.build(
            days: [day(yesterday, units: 10)], rates: nil, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            now: now)
        XCTAssertFalse(without.footnotes.contains(note))
    }

    func testAppRowsCarryTheirOwnImpressions() {
        let day = day(yesterday, units: 2, apps: [app("1", "Mine", ["USD": 5]),
                                                   app("2", "Theirs", ["USD": 5])])
        let model = OverviewModel.build(
            days: [day], rates: nil, error: nil, metrics: [.installs], displayCurrency: "USD",
            span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: ["1": [engagementDay(yesterday, impressions: 340, pageViews: 12)]], now: now)

        XCTAssertEqual(model.apps.first { $0.appleID == "1" }?.impressions, 340)
        XCTAssertNil(model.apps.first { $0.appleID == "2" }?.impressions,
                     "An app with no analytics shows nothing, never 0")
    }

    /// `AppRowView` renders this string rather than composing it — a view renders strings, it
    /// doesn't build them.
    func testAppRowsCarryAReadyMadeImpressionsLabel() {
        let day = day(yesterday, units: 2, apps: [app("1", "Mine", ["USD": 5]),
                                                   app("2", "Theirs", ["USD": 5])])
        let model = OverviewModel.build(
            days: [day], rates: nil, error: nil, metrics: [.installs], displayCurrency: "USD",
            span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: ["1": [engagementDay(yesterday, impressions: 340, pageViews: 12)]], now: now)

        XCTAssertEqual(model.apps.first { $0.appleID == "1" }?.impressionsLabel, "340 impressions")
        XCTAssertNil(model.apps.first { $0.appleID == "2" }?.impressionsLabel,
                     "An app with no analytics shows nothing, never 0")
    }

}
