import XCTest
@testable import VantageCore

/// Backfill against a stub provider. No network, no real cache.
final class BackfillTests: XCTestCase {
    /// Answers whatever the test tells it to, and records what it was asked for.
    private final class StubProvider: SalesProvider {
        let name = "Stub"
        var answers: [String: Result<DaySales?, Error>] = [:]
        private(set) var requested: [ReportDate] = []
        private let lock = NSLock()

        func fetch(_ date: ReportDate, completion: @escaping (Result<DaySales?, Error>) -> Void) {
            lock.lock()
            requested.append(date)
            let answer = answers[date.apiString] ?? .success(nil)
            lock.unlock()
            completion(answer)
        }
    }

    private var directory: URL!
    private var store: ReportStore!
    private var provider: StubProvider!
    private var backfill: Backfill!

    private let today = ReportDate(year: 2026, month: 8, day: 2)

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VantageBackfill-\(UUID().uuidString)", isDirectory: true)
        store = ReportStore(directory: directory)
        provider = StubProvider()
        backfill = Backfill(provider: provider, store: store)
        backfill.delayBetweenRequests = 0  // Tests shouldn't pay for politeness.
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func day(_ date: ReportDate, downloads: Decimal = 10) -> DaySales {
        DaySales(date: date, origin: .observed, downloads: downloads,
                 proceeds: ["USD": 1], apps: [], fetchedAt: Date())
    }

    @discardableResult
    private func run(_ dates: [ReportDate], userInitiated: Bool = false,
                     now: Date) -> (days: [DaySales], error: Error?) {
        let finished = expectation(description: "backfill finished")
        var collected: [DaySales] = []
        var failure: Error?
        backfill.run(dates: dates, userInitiated: userInitiated, now: now,
                     onDay: { collected.append($0) },
                     completion: { failure = $0; finished.fulfill() })
        wait(for: [finished], timeout: 5)
        return (collected, failure)
    }

    /// 2026-08-03 12:00 PDT — past the cutoff for 08-02, so a missing report is a real zero.
    private let afterCutoff = Date(timeIntervalSince1970: 1_785_783_600)

    // MARK: - Ordering

    /// Yesterday is what the menu bar shows, so it must be the first request, not the thirtieth.
    func testFetchesNewestFirst() {
        let dates = today.lastDays(5)
        for date in dates { provider.answers[date.apiString] = .success(day(date)) }
        run(dates, now: afterCutoff)
        XCTAssertEqual(provider.requested.map(\.apiString),
                       ["2026-08-02", "2026-08-01", "2026-07-31", "2026-07-30", "2026-07-29"])
    }

    func testCachedDaysAreNotRequestedAgain() {
        let dates = today.lastDays(3)
        store.save(day(dates[1]))
        for date in dates { provider.answers[date.apiString] = .success(day(date)) }

        run(dates, now: afterCutoff)
        XCTAssertEqual(provider.requested.count, 2)
        XCTAssertFalse(provider.requested.contains(dates[1]))
    }

    func testEverythingCachedMakesNoRequests() {
        let dates = today.lastDays(3)
        for date in dates { store.save(day(date)) }
        let result = run(dates, now: afterCutoff)
        XCTAssertTrue(provider.requested.isEmpty)
        XCTAssertTrue(result.days.isEmpty)
        XCTAssertNil(result.error)
    }

    func testFetchedDaysArePersisted() {
        let dates = today.lastDays(2)
        for date in dates { provider.answers[date.apiString] = .success(day(date, downloads: 7)) }
        run(dates, now: afterCutoff)
        XCTAssertEqual(store.load(dates[0])?.downloads, 7)
        XCTAssertEqual(store.load(dates[1])?.downloads, 7)
    }

    // MARK: - The missing-report rule

    /// Past the cutoff, a missing report is recorded as a zero — provisionally.
    func testAMissingReportPastTheCutoffIsCachedAsAssumedZero() {
        let date = ReportDate(year: 2026, month: 8, day: 2)
        provider.answers[date.apiString] = .success(nil)

        let result = run([date], now: afterCutoff)
        XCTAssertEqual(result.days.count, 1)
        XCTAssertEqual(store.load(date)?.origin, .assumedZero)
        XCTAssertEqual(store.load(date)?.downloads, 0)
    }

    /// Before the cutoff it stays unresolved, so the menu can say "not published yet" rather than
    /// showing a zero that isn't true.
    func testAMissingReportBeforeTheCutoffIsNotCached() {
        let date = ReportDate(year: 2026, month: 8, day: 2)
        provider.answers[date.apiString] = .success(nil)
        // 2026-08-03 07:00 PDT, before the 10:00 cutoff.
        let beforeCutoff = Date(timeIntervalSince1970: 1_785_765_600)

        let result = run([date], now: beforeCutoff)
        XCTAssertTrue(result.days.isEmpty)
        XCTAssertNil(store.load(date))
    }

    /// The escape hatch: a report that landed late corrects itself on Refresh Now.
    func testRefreshNowRefetchesAnAssumedZeroAndOverturnsIt() {
        let date = ReportDate(year: 2026, month: 8, day: 2)
        store.save(DaySales.zero(on: date, fetchedAt: afterCutoff))

        // Nothing happens without asking.
        run([date], now: afterCutoff)
        XCTAssertTrue(provider.requested.isEmpty)

        // Apple published it after all.
        provider.answers[date.apiString] = .success(day(date, downloads: 89))
        let result = run([date], userInitiated: true, now: afterCutoff)

        XCTAssertEqual(provider.requested.count, 1)
        XCTAssertEqual(result.days.first?.downloads, 89)
        XCTAssertEqual(store.load(date)?.origin, .observed)
        XCTAssertEqual(store.load(date)?.downloads, 89)
    }

    func testRefreshNowStillDoesntRefetchAPublishedDay() {
        let date = ReportDate(year: 2026, month: 8, day: 2)
        store.save(day(date, downloads: 5))
        run([date], userInitiated: true, now: afterCutoff)
        XCTAssertTrue(provider.requested.isEmpty)
    }

    // MARK: - Failure

    /// One refused day must not cost the other twenty-nine.
    func testAFailedDayDoesntStopTheRest() {
        let dates = today.lastDays(3)
        for date in dates { provider.answers[date.apiString] = .success(day(date)) }
        provider.answers[dates[1].apiString] = .failure(SalesError.rateLimited)

        let result = run(dates, now: afterCutoff)
        XCTAssertEqual(provider.requested.count, 3)
        XCTAssertEqual(result.days.count, 2)
        XCTAssertEqual(result.error as? SalesError, .rateLimited)
        XCTAssertNil(store.load(dates[1]))
    }

    func testTheFirstErrorIsTheOneReported() {
        let dates = today.lastDays(2)
        // Newest first, so 08-02 fails before 08-01.
        provider.answers[dates[1].apiString] = .failure(SalesError.forbidden(detail: "first"))
        provider.answers[dates[0].apiString] = .failure(SalesError.network)

        let result = run(dates, now: afterCutoff)
        XCTAssertEqual(result.error as? SalesError, .forbidden(detail: "first"))
    }

    func testAnEmptyDateListCompletesImmediately() {
        let result = run([], now: afterCutoff)
        XCTAssertTrue(result.days.isEmpty)
        XCTAssertNil(result.error)
    }
}
