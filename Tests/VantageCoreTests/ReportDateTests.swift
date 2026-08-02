import XCTest
@testable import VantageCore

/// The report calendar is Pacific and the viewer's is not. Every test here fixes an instant in
/// absolute time and asserts which *report day* it belongs to — that mapping is where a wrong
/// day's money comes from.
final class ReportDateTests: XCTestCase {
    /// An instant, written in UTC, so the expectations below are unambiguous.
    private func utc(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    func testAPIStringIsZeroPadded() {
        XCTAssertEqual(ReportDate(year: 2026, month: 2, day: 7).apiString, "2026-02-07")
    }

    func testRoundTripsThroughAPIString() {
        let date = ReportDate(year: 2026, month: 12, day: 31)
        XCTAssertEqual(ReportDate(apiString: date.apiString), date)
    }

    func testRejectsNonAPIDateStrings() {
        XCTAssertNil(ReportDate(apiString: "08/02/2026"))  // A report's own Begin Date format.
        XCTAssertNil(ReportDate(apiString: "2026-8-2"))
        XCTAssertNil(ReportDate(apiString: "2026-13-01"))
        XCTAssertNil(ReportDate(apiString: ""))
    }

    // MARK: - Which day is it in Pacific

    func testJustBeforePacificMidnightIsStillTheSameDay() {
        // 2026-08-02 23:59 PDT is 2026-08-03 06:59 UTC.
        XCTAssertEqual(ReportDate(pacificDayContaining: utc("2026-08-03T06:59:00Z")),
                       ReportDate(year: 2026, month: 8, day: 2))
    }

    func testJustAfterPacificMidnightIsTheNextDay() {
        // 2026-08-03 00:01 PDT is 2026-08-03 07:01 UTC.
        XCTAssertEqual(ReportDate(pacificDayContaining: utc("2026-08-03T07:01:00Z")),
                       ReportDate(year: 2026, month: 8, day: 3))
    }

    /// The case that motivates the whole type: breakfast in Berlin is still the previous day in
    /// California, so the newest finished report day is two calendar days back in local terms.
    func testBerlinBreakfastAsksForTwoLocalDaysAgo() {
        // 2026-08-03 08:00 CEST is 2026-08-03 06:00 UTC, which is 2026-08-02 23:00 PDT.
        let now = utc("2026-08-03T06:00:00Z")
        XCTAssertEqual(ReportDate(pacificDayContaining: now), ReportDate(year: 2026, month: 8, day: 2))
        XCTAssertEqual(ReportDate.yesterday(now: now), ReportDate(year: 2026, month: 8, day: 1))
    }

    func testYesterdayCrossesMonthBoundaries() {
        // 2026-08-01 12:00 PDT.
        XCTAssertEqual(ReportDate.yesterday(now: utc("2026-08-01T19:00:00Z")),
                       ReportDate(year: 2026, month: 7, day: 31))
    }

    func testYesterdayCrossesYearBoundaries() {
        // 2027-01-01 12:00 PST.
        XCTAssertEqual(ReportDate.yesterday(now: utc("2027-01-01T20:00:00Z")),
                       ReportDate(year: 2026, month: 12, day: 31))
    }

    func testArithmeticCrossesLeapDay() {
        XCTAssertEqual(ReportDate(year: 2028, month: 3, day: 1).adding(days: -1),
                       ReportDate(year: 2028, month: 2, day: 29))
    }

    // MARK: - Daylight saving

    /// Pacific springs forward on 2026-03-08. A 23-hour day must not shift the boundary, and the
    /// "is it 10am yet" deadline must still land at 10am local.
    func testDayBoundariesSurviveSpringForward() {
        let dst = ReportDate(year: 2026, month: 3, day: 8)
        XCTAssertEqual(dst.adding(days: 1), ReportDate(year: 2026, month: 3, day: 9))
        // 10:00 PDT on the short day is 17:00 UTC, not 18:00 as naive midnight-plus-10-hours gives.
        XCTAssertEqual(dst.pacificTime(hour: 10), utc("2026-03-08T17:00:00Z"))
    }

    /// And falls back on 2026-11-01, a 25-hour day.
    func testDayBoundariesSurviveFallBack() {
        let dst = ReportDate(year: 2026, month: 11, day: 1)
        XCTAssertEqual(dst.adding(days: 1), ReportDate(year: 2026, month: 11, day: 2))
        XCTAssertEqual(dst.pacificTime(hour: 10), utc("2026-11-01T18:00:00Z"))
    }

    // MARK: - Ranges

    func testLastDaysIsOldestFirstAndInclusive() {
        let days = ReportDate(year: 2026, month: 8, day: 2).lastDays(3)
        XCTAssertEqual(days.map(\.apiString), ["2026-07-31", "2026-08-01", "2026-08-02"])
    }

    func testLastDaysOfZeroIsEmpty() {
        XCTAssertEqual(ReportDate(year: 2026, month: 8, day: 2).lastDays(0).count, 0)
    }

    // MARK: - "Might it still arrive?"

    func testReportMayStillArriveBeforeTheCutoff() {
        let day = ReportDate(year: 2026, month: 8, day: 2)
        // 2026-08-03 09:59 PDT — one minute before the 10:00 cutoff.
        XCTAssertTrue(day.mayStillArrive(now: utc("2026-08-03T16:59:00Z")))
    }

    func testReportIsGivenUpOnAfterTheCutoff() {
        let day = ReportDate(year: 2026, month: 8, day: 2)
        // 2026-08-03 10:01 PDT.
        XCTAssertFalse(day.mayStillArrive(now: utc("2026-08-03T17:01:00Z")))
    }

    func testAnOlderDayIsNeverStillWaiting() {
        XCTAssertFalse(ReportDate(year: 2026, month: 6, day: 1)
            .mayStillArrive(now: utc("2026-08-03T16:00:00Z")))
    }
}
