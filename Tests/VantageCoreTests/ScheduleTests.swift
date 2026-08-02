import XCTest
@testable import VantageCore

/// The scheduler decides how often this app talks to Apple. Getting it wrong is either a hundred
/// pointless requests a day or a report that never arrives, and neither is visible from the menu.
final class ScheduleTests: XCTestCase {
    private func pacific(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Date {
        ReportDate(year: year, month: month, day: day).pacificTime(hour: hour)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> ReportDate {
        ReportDate(year: year, month: month, day: day)
    }

    // MARK: - Whether to poll

    /// Before 05:00 PT the report provably doesn't exist yet, so asking is a guaranteed 404.
    func testDoesntPollBeforeTheWindowOpens() {
        XCTAssertFalse(Schedule.shouldPoll(newestCached: date(2026, 7, 31),
                                           now: pacific(2026, 8, 2, 4)))
    }

    func testPollsOnceTheWindowOpens() {
        XCTAssertTrue(Schedule.shouldPoll(newestCached: date(2026, 7, 31),
                                          now: pacific(2026, 8, 2, 5)))
    }

    func testKeepsPollingThroughTheDayWhileTheReportIsMissing() {
        XCTAssertTrue(Schedule.shouldPoll(newestCached: date(2026, 7, 31),
                                          now: pacific(2026, 8, 2, 15)))
    }

    /// The whole point: once yesterday's report is in, there is nothing left to ask for today.
    func testStopsPollingOnceTheNewestReportIsCached() {
        XCTAssertFalse(Schedule.shouldPoll(newestCached: date(2026, 8, 1),
                                           now: pacific(2026, 8, 2, 11)))
    }

    func testPollsWhenNothingIsCachedAtAll() {
        XCTAssertTrue(Schedule.shouldPoll(newestCached: nil, now: pacific(2026, 8, 2, 12)))
    }

    /// A Mac asleep for a week wakes with several days missing and should go straight out.
    func testPollsWhenTheCacheIsDaysBehind() {
        XCTAssertTrue(Schedule.shouldPoll(newestCached: date(2026, 7, 20),
                                          now: pacific(2026, 8, 2, 9)))
    }

    /// A cache newer than the newest possible report shouldn't send the scheduler into a loop.
    func testACacheFromTheFutureDoesntPoll() {
        XCTAssertFalse(Schedule.shouldPoll(newestCached: date(2026, 9, 1),
                                           now: pacific(2026, 8, 2, 12)))
    }

    // MARK: - When next

    func testRetriesHourlyWhileWaiting() {
        let now = pacific(2026, 8, 2, 6)
        XCTAssertEqual(Schedule.nextPoll(newestCached: date(2026, 7, 31), now: now),
                       now.addingTimeInterval(3600))
    }

    /// Having got today's report, the next useful moment is tomorrow morning — not an hour from
    /// now, twenty-four times over.
    func testSleepsUntilTomorrowMorningOnceCaughtUp() {
        let next = Schedule.nextPoll(newestCached: date(2026, 8, 1), now: pacific(2026, 8, 2, 11))
        XCTAssertEqual(next, pacific(2026, 8, 3, 5))
    }

    func testSleepsUntilThisMorningWhenWokenBeforeTheWindow() {
        let next = Schedule.nextPoll(newestCached: date(2026, 8, 1), now: pacific(2026, 8, 2, 2))
        XCTAssertEqual(next, pacific(2026, 8, 3, 5))
    }

    /// Clocks move backwards — sleep, time-zone changes, NTP corrections. A next-poll date in the
    /// past would fire immediately and spin.
    func testNextPollIsNeverInThePast() {
        for hour in 0...23 {
            let now = pacific(2026, 8, 2, hour)
            XCTAssertGreaterThan(Schedule.nextPoll(newestCached: date(2026, 8, 1), now: now), now)
            XCTAssertGreaterThan(Schedule.nextPoll(newestCached: nil, now: now), now)
        }
    }

    // MARK: - Notification

    private func day(_ date: ReportDate, origin: DaySales.Origin = .observed) -> DaySales {
        DaySales(date: date, origin: origin, downloads: 89, proceeds: ["USD": 142],
                 apps: [], fetchedAt: Date())
    }

    func testNotifiesForYesterdaysReport() {
        XCTAssertTrue(Schedule.shouldNotify(about: day(date(2026, 8, 1)), alreadyNotified: false,
                                            now: pacific(2026, 8, 2, 9)))
    }

    func testDoesntNotifyTwiceForTheSameDay() {
        XCTAssertFalse(Schedule.shouldNotify(about: day(date(2026, 8, 1)), alreadyNotified: true,
                                             now: pacific(2026, 8, 2, 9)))
    }

    /// Backfilling a month must not fire thirty notifications.
    func testDoesntNotifyForOlderDaysArrivingInABackfill() {
        XCTAssertFalse(Schedule.shouldNotify(about: day(date(2026, 7, 15)), alreadyNotified: false,
                                             now: pacific(2026, 8, 2, 9)))
    }

    /// "$0 · 0 downloads" for a report Apple never published would be announcing something that
    /// isn't known to be true.
    func testDoesntNotifyAboutAnAssumedZero() {
        XCTAssertFalse(Schedule.shouldNotify(about: day(date(2026, 8, 1), origin: .assumedZero),
                                             alreadyNotified: false, now: pacific(2026, 8, 2, 9)))
    }
}
