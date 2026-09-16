import XCTest
@testable import VantageCore

/// Moving through time in the panel. Every rule the ‹ › buttons and the chart drag follow lives
/// here, so a boundary that goes wrong goes wrong in a test rather than on screen.
final class TimeWindowTests: XCTestCase {
    private let newest = ReportDate(year: 2026, month: 9, day: 15)
    private let oldest = ReportDate(year: 2025, month: 9, day: 16)
    private func date(_ s: String) -> ReportDate { ReportDate(apiString: s)! }

    // MARK: - Latest

    func testAPresetStartsAtLatest() {
        let window = TimeWindow(preset: .week)
        XCTAssertTrue(window.isLatest)
        XCTAssertEqual(window.endDate(newest: newest), newest)
        XCTAssertEqual(window.startDate(newest: newest), date("2026-09-09"))
        XCTAssertFalse(window.canStepForward(newest: newest))
        XCTAssertTrue(window.canStepBack(oldest: oldest, newest: newest))
    }

    /// Latest follows new reports, rather than freezing on whatever was newest when it was chosen.
    func testLatestFollowsTheNewestDay() {
        let window = TimeWindow(preset: .yesterday)
        XCTAssertEqual(window.endDate(newest: newest.adding(days: 1)), newest.adding(days: 1))
    }

    // MARK: - Stepping

    func testStepBackMovesAWholePeriod() {
        let back = TimeWindow(preset: .week).stepped(by: -1, oldest: oldest, newest: newest)
        XCTAssertFalse(back.isLatest)
        XCTAssertEqual(back.endDate(newest: newest), date("2026-09-08"))
        XCTAssertEqual(back.startDate(newest: newest), date("2026-09-02"))
        XCTAssertTrue(back.canStepForward(newest: newest))
    }

    func testSteppingForwardToTheNewestDayIsLatestAgain() {
        let back = TimeWindow(preset: .month).stepped(by: -2, oldest: oldest, newest: newest)
        XCTAssertTrue(back.stepped(by: 2, oldest: oldest, newest: newest).isLatest)
        XCTAssertTrue(back.stepped(by: 5, oldest: oldest, newest: newest).isLatest,
                      "and can't overshoot into days that don't exist yet")
    }

    func testCantStepBackPastTheOldestCachedDay() {
        let far = TimeWindow(preset: .week).stepped(by: -500, oldest: oldest, newest: newest)
        XCTAssertEqual(far.startDate(newest: newest), oldest)
        XCTAssertFalse(far.canStepBack(oldest: oldest, newest: newest))
    }

    /// With less cached than one window, there's nowhere to go — and no crash finding that out.
    func testACacheShorterThanTheWindowStaysAtLatest() {
        let recent = newest.adding(days: -3)
        let window = TimeWindow(preset: .month).shifted(byDays: -10, oldest: recent, newest: newest)
        XCTAssertTrue(window.isLatest)
        XCTAssertFalse(window.canStepBack(oldest: recent, newest: newest))
    }

    // MARK: - Panning

    func testPanningMovesByDays() {
        let panned = TimeWindow(preset: .week).shifted(byDays: -3, oldest: oldest, newest: newest)
        XCTAssertEqual(panned.endDate(newest: newest), date("2026-09-12"))
        XCTAssertEqual(panned.length, 7)
    }

    // MARK: - Presets and custom

    /// Switching 7D to 30D while looking at March stays in March.
    func testChangingPresetKeepsTheEnd() {
        let march = TimeWindow(preset: .week)
            .shifted(byDays: newest.days(to: date("2026-03-31")), oldest: oldest, newest: newest)
        let month = march.selecting(.month)
        XCTAssertEqual(month.endDate(newest: newest), date("2026-03-31"))
        XCTAssertEqual(month.length, 30)
        XCTAssertEqual(month.preset, .month)
    }

    func testCustomCoversBothEndsInclusive() {
        let window = TimeWindow.custom(from: date("2026-03-01"), to: date("2026-03-31"),
                                       newest: newest)
        XCTAssertNil(window.preset)
        XCTAssertEqual(window.length, 31)
        XCTAssertEqual(window.startDate(newest: newest), date("2026-03-01"))
        XCTAssertEqual(window.endDate(newest: newest), date("2026-03-31"))
    }

    func testCustomAcceptsEndsInEitherOrder() {
        XCTAssertEqual(
            TimeWindow.custom(from: date("2026-03-31"), to: date("2026-03-01"), newest: newest),
            TimeWindow.custom(from: date("2026-03-01"), to: date("2026-03-31"), newest: newest))
    }

    func testACustomRangeReachingTodayIsLatest() {
        let window = TimeWindow.custom(from: date("2026-09-01"), to: date("2026-12-31"),
                                       newest: newest)
        XCTAssertTrue(window.isLatest)
        XCTAssertEqual(window.length, 122)
    }

    func testACustomRangeStepsByItsOwnLength() {
        let window = TimeWindow.custom(from: date("2026-03-01"), to: date("2026-03-10"),
                                       newest: newest)
        let back = window.stepped(by: -1, oldest: oldest, newest: newest)
        XCTAssertEqual(back.startDate(newest: newest), date("2026-02-19"))
        XCTAssertEqual(back.endDate(newest: newest), date("2026-02-28"))
    }

    // MARK: - Titles, labels, chart

    /// "Last 7 days" is only true at Latest.
    func testTheTitleStopsSayingLastOnceSteppedBack() {
        let window = TimeWindow(preset: .week)
        XCTAssertEqual(window.span(newest: newest).title, "Last 7 days")
        XCTAssertEqual(window.stepped(by: -1, oldest: oldest, newest: newest)
            .span(newest: newest).title, "7 days")
        XCTAssertEqual(TimeWindow(preset: .yesterday).stepped(by: -1, oldest: oldest, newest: newest)
            .span(newest: newest).title, "1 day")
    }

    func testTheSpanIsWhatTheHeadlineTotals() {
        let back = TimeWindow(preset: .week).stepped(by: -1, oldest: oldest, newest: newest)
        let span = back.span(newest: newest)
        XCTAssertEqual(span.length, 7)
        XCTAssertEqual(span.end, date("2026-09-08"))
    }

    func testTheDateLabelCarriesTheYear() {
        let label = TimeWindow(preset: .week).dateLabel(newest: newest)
        XCTAssertTrue(label.contains("2026"), label)
    }

    func testTheChartShowsTheWindowAndThePeriodBeforeIt() {
        XCTAssertEqual(TimeWindow(preset: .yesterday).chart(newest: newest).length, 30)
        XCTAssertEqual(TimeWindow(preset: .week).chart(newest: newest).length, 30)
        XCTAssertEqual(TimeWindow(preset: .month).chart(newest: newest).length, 60)
        let back = TimeWindow(preset: .week).stepped(by: -1, oldest: oldest, newest: newest)
        XCTAssertEqual(back.chart(newest: newest).end, date("2026-09-08"))
    }

    // MARK: - Calendar dates

    /// A date picker speaks the user's calendar; a report day is a date with no zone. Converting by
    /// instant would shift the day for anyone far from Pacific.
    func testCalendarDatesRoundTripInAnyZone() {
        for zone in ["Pacific/Kiritimati", "Europe/Berlin", "Pacific/Pago_Pago"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: zone)!
            let day = date("2026-03-08")
            XCTAssertEqual(ReportDate(calendarDate: day.calendarDate(in: calendar),
                                      calendar: calendar), day, zone)
        }
    }
}
