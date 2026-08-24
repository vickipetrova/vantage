import XCTest
@testable import VantageCore

/// Whether the panel is telling the truth about how current it is.
///
/// Every branch here used to be reachable only by opening the app at the right moment with the wifi
/// off, which is why a three-day-old panel looked fine for three days.
final class FreshnessTests: XCTestCase {
    /// 24 Aug 2026, mid-afternoon Pacific — past the publication window, so the 23rd should exist.
    private var afternoon: Date { ReportDate(year: 2026, month: 8, day: 24).pacificTime(hour: 15) }
    /// Early morning Pacific, before Apple publishes.
    private var earlyMorning: Date { ReportDate(year: 2026, month: 8, day: 24).pacificTime(hour: 6) }

    private func date(_ day: Int) -> ReportDate { ReportDate(year: 2026, month: 8, day: day) }

    // MARK: - Current

    func testEverythingCachedReadsAsUpToDate() {
        let freshness = Freshness.evaluate(newestCached: date(23), lastSuccess: afternoon,
                                           error: nil, now: afternoon)
        XCTAssertEqual(freshness.severity, .current)
        XCTAssertEqual(freshness.headline, "Up to date")
        XCTAssertNil(freshness.problem)
        XCTAssertFalse(freshness.marksMenuBar)
    }

    /// Before Apple's morning window has closed, being one day behind is the normal state — Apple
    /// simply hasn't generated it yet, so nothing it has published is missing.
    ///
    /// This reads as "Up to date" rather than explaining Pacific time, which was three lines of
    /// text in a strip that has room for one.
    func testWaitingForYesterdayBeforeApplePublishesReadsAsUpToDate() {
        let freshness = Freshness.evaluate(newestCached: date(22), lastSuccess: earlyMorning,
                                           error: nil, now: earlyMorning)
        XCTAssertEqual(freshness.severity, .current)
        XCTAssertEqual(freshness.headline, "Up to date")
        XCTAssertFalse(freshness.marksMenuBar)
    }

    /// Once the window has closed, the same one-day gap is a real shortfall and says so.
    func testTheSameGapAfterThePublicationWindowIsBehind() {
        let freshness = Freshness.evaluate(newestCached: date(22), lastSuccess: afternoon,
                                           error: nil, now: afternoon)
        XCTAssertEqual(freshness.severity, .behind)
        XCTAssertEqual(freshness.headline, "1 day behind")
    }

    // MARK: - Behind

    /// The case that prompted all of this: data from the 21st, still on screen on the 24th, with
    /// the only hint a grey footnote at the bottom of one section.
    func testThreeDaysBehindSaysSoAndMarksTheMenuBar() {
        let freshness = Freshness.evaluate(
            newestCached: date(20), lastSuccess: nil,
            error: SalesError.network, now: afternoon)
        XCTAssertEqual(freshness.severity, .behind)
        XCTAssertEqual(freshness.headline, "3 days behind")
        XCTAssertEqual(freshness.problem, SalesError.network.errorDescription)
        XCTAssertTrue(freshness.marksMenuBar,
                      "Stale figures in the menu bar have to say they're stale")
    }

    func testOneDayBehindPastThePublicationWindowIsBehind() {
        let freshness = Freshness.evaluate(newestCached: date(22), lastSuccess: afternoon,
                                           error: nil, now: afternoon)
        XCTAssertEqual(freshness.severity, .behind)
        XCTAssertEqual(freshness.headline, "1 day behind", "and not '1 days'")
    }

    // MARK: - Failure with nothing missing

    /// A refresh that fails while everything Apple has published is already cached is worth showing
    /// — but quietly. The figures are right, and marking the menu bar here would train people to
    /// ignore the marker for the times it matters.
    func testAFailedRefreshWithNothingMissingIsAWarningNotAnAlarm() {
        let freshness = Freshness.evaluate(newestCached: date(23), lastSuccess: afternoon,
                                           error: SalesError.network, now: afternoon)
        XCTAssertEqual(freshness.severity, .warning)
        XCTAssertEqual(freshness.headline, "Up to date")
        XCTAssertNotNil(freshness.problem, "The failure is still stated")
        XCTAssertFalse(freshness.marksMenuBar)
    }

    // MARK: - Nothing at all

    func testNoReportsYetAndNoErrorIsAWarning() {
        let freshness = Freshness.evaluate(newestCached: nil, lastSuccess: nil, error: nil,
                                           now: afternoon)
        XCTAssertEqual(freshness.severity, .warning)
        XCTAssertEqual(freshness.headline, "No reports yet")
    }

    func testNoReportsAndAFailureIsTheLoudestState() {
        let freshness = Freshness.evaluate(newestCached: nil, lastSuccess: nil,
                                           error: SalesError.noCredentials, now: afternoon)
        XCTAssertEqual(freshness.severity, .behind)
        XCTAssertEqual(freshness.problem, SalesError.noCredentials.errorDescription)
    }

    // MARK: - Last updated

    func testLastUpdatedIsRelativeSoItAnswersTheQuestionBeingAsked() {
        let freshness = Freshness.evaluate(
            newestCached: date(23), lastSuccess: afternoon.addingTimeInterval(-3600),
            error: nil, now: afternoon)
        // "14:32" only tells you whether data is current if you also know what time it is.
        XCTAssertEqual(freshness.lastUpdated, Fmt.relative(afternoon.addingTimeInterval(-3600),
                                                          from: afternoon))
        XCTAssertTrue(freshness.lastUpdated?.contains("hour") == true, "\(freshness.lastUpdated!)")
    }

    func testNoSuccessYetHasNoLastUpdated() {
        XCTAssertNil(Freshness.evaluate(newestCached: nil, lastSuccess: nil, error: nil,
                                        now: afternoon).lastUpdated)
    }

    /// Reviews failures reach the same banner and must not fall through to the generic message.
    func testAReviewsFailureKeepsItsOwnWording() {
        let freshness = Freshness.evaluate(newestCached: date(23), lastSuccess: afternoon,
                                           error: ReviewsError.noKey, now: afternoon)
        XCTAssertEqual(freshness.problem, ReviewsError.noKey.errorDescription)
    }

    // MARK: - Day arithmetic

    func testDaysBeforeCountsPacificDays() {
        XCTAssertEqual(date(20).daysBefore(date(23)), 3)
        XCTAssertEqual(date(23).daysBefore(date(23)), 0)
        XCTAssertEqual(date(24).daysBefore(date(23)), -1)
    }

    /// Across a month boundary, where naive subtraction of the day field gives nonsense.
    func testDaysBeforeCrossesMonths() {
        XCTAssertEqual(ReportDate(year: 2026, month: 7, day: 30)
                        .daysBefore(ReportDate(year: 2026, month: 8, day: 2)), 3)
    }
}

/// Relative time, which is what the panel shows instead of a clock reading.
final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testUnderAMinuteIsJustNow() {
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-5), from: now), "just now")
        XCTAssertEqual(Fmt.relative(now, from: now), "just now")
    }

    /// A clock that jumped backwards must not produce "in 3 hours" about a fetch that has already
    /// happened.
    func testAFutureDateStillReadsAsJustNow() {
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(3600), from: now), "just now")
    }

    func testMinutesAndHoursAndDaysAreNamed() {
        XCTAssertTrue(Fmt.relative(now.addingTimeInterval(-300), from: now).contains("minute"))
        XCTAssertTrue(Fmt.relative(now.addingTimeInterval(-7200), from: now).contains("hour"))
        XCTAssertTrue(Fmt.relative(now.addingTimeInterval(-3 * 86400), from: now).contains("day"))
    }
}
