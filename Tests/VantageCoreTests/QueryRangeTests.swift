import XCTest
@testable import VantageCore

/// The ranges the CLI and MCP accept. An agent chooses these without a human reading them first,
/// so a malformed one has to be refused with a reason rather than quietly read as thirty days.
final class QueryRangeTests: XCTestCase {
    private func parse(range: String? = nil, days: String? = nil,
                       from: String? = nil, to: String? = nil) throws -> QueryRange {
        try QueryRange.parse(range: range, days: days, from: from, to: to)
    }

    private func date(_ string: String) -> ReportDate { ReportDate(apiString: string)! }

    // MARK: - Parsing

    func testNothingAskedForIsThirtyDays() throws {
        XCTAssertEqual(try parse(), .last(30))
    }

    func testTheOriginalRangesStillWork() throws {
        XCTAssertEqual(try parse(range: "1d"), .last(1))
        XCTAssertEqual(try parse(range: "7d"), .last(7))
        XCTAssertEqual(try parse(range: "30d"), .last(30))
        XCTAssertEqual(try parse(range: "week"), .last(7))
        XCTAssertEqual(try parse(range: "MONTH"), .last(30))
    }

    func testAnyNumberOfDaysIsAccepted() throws {
        XCTAssertEqual(try parse(range: "400d"), .last(400))
        XCTAssertEqual(try parse(days: "400"), .last(400))
        XCTAssertEqual(try parse(days: " 90 "), .last(90))
    }

    func testAllIsEverythingCached() throws {
        XCTAssertEqual(try parse(range: "all"), .all)
    }

    func testExplicitDates() throws {
        XCTAssertEqual(try parse(from: "2025-10-01", to: "2026-03-31"),
                       .between(from: date("2025-10-01"), to: date("2026-03-31")))
        XCTAssertEqual(try parse(from: "2025-10-01"), .between(from: date("2025-10-01"), to: nil))
        XCTAssertEqual(try parse(to: "2026-03-31"), .between(from: nil, to: date("2026-03-31")))
    }

    /// Previously an unknown range silently meant thirty days, which answers a question nobody
    /// asked with a number that looks like an answer.
    func testAnUnknownRangeIsRefusedRatherThanDefaulted() {
        XCTAssertThrowsError(try parse(range: "quarter"))
        XCTAssertThrowsError(try parse(range: "d"))
        XCTAssertThrowsError(try parse(range: "-5d"))
    }

    func testNonsenseDaysAreRefused() {
        XCTAssertThrowsError(try parse(days: "0"))
        XCTAssertThrowsError(try parse(days: "-3"))
        XCTAssertThrowsError(try parse(days: "ten"))
        XCTAssertThrowsError(try parse(days: String(QueryRange.maxDays + 1)))
    }

    func testMalformedDatesAreRefused() {
        XCTAssertThrowsError(try parse(from: "2026-13-01"))
        XCTAssertThrowsError(try parse(to: "yesterday"))
        XCTAssertThrowsError(try parse(from: "2026-02-30"))
    }

    func testABackwardsRangeIsRefused() {
        XCTAssertThrowsError(try parse(from: "2026-03-31", to: "2025-10-01"))
    }

    /// Two ways of saying the range at once can't both be honoured, and picking one silently would
    /// answer a different question from the one asked.
    func testMixingStylesIsRefused() {
        XCTAssertThrowsError(try parse(range: "7d", days: "30"))
        XCTAssertThrowsError(try parse(range: "7d", from: "2026-01-01"))
        XCTAssertThrowsError(try parse(days: "30", to: "2026-01-01"))
    }

    func testTheRefusalSaysWhatWasWrong() {
        XCTAssertThrowsError(try parse(from: "2026-13-01")) { error in
            XCTAssertTrue("\(error)".contains("2026-13-01"), "\(error)")
        }
    }

    // MARK: - Resolving against the cache

    private let oldest = ReportDate(year: 2025, month: 9, day: 1)
    private let newest = ReportDate(year: 2026, month: 9, day: 15)

    func testLastEndsAtTheNewestCachedDay() {
        let resolved = QueryRange.last(7).resolve(oldest: oldest, newest: newest)
        XCTAssertEqual(resolved.end, newest)
        XCTAssertEqual(resolved.start, date("2026-09-09"))
        XCTAssertEqual(resolved.dayCount, 7)
    }

    /// A range reaching past the cache still reports its real length, so `daysCached` can say it
    /// isn't all there.
    func testLastCanReachPastTheOldestCachedDay() {
        let resolved = QueryRange.last(1000).resolve(oldest: oldest, newest: newest)
        XCTAssertEqual(resolved.dayCount, 1000)
        XCTAssertLessThan(resolved.start, oldest)
    }

    func testAllSpansTheWholeCache() {
        let resolved = QueryRange.all.resolve(oldest: oldest, newest: newest)
        XCTAssertEqual(resolved.start, oldest)
        XCTAssertEqual(resolved.end, newest)
        XCTAssertEqual(resolved.dayCount, 380)
    }

    func testOpenEndsAreFilledFromTheCache() {
        let from = QueryRange.between(from: date("2026-09-01"), to: nil)
            .resolve(oldest: oldest, newest: newest)
        XCTAssertEqual(from.end, newest)

        let to = QueryRange.between(from: nil, to: date("2025-12-31"))
            .resolve(oldest: oldest, newest: newest)
        XCTAssertEqual(to.start, oldest)
    }

    /// A `from` after everything cached must not produce a range that ends before it starts.
    func testAnOpenEndNeverResolvesBackwards() {
        let resolved = QueryRange.between(from: date("2030-01-01"), to: nil)
            .resolve(oldest: oldest, newest: newest)
        XCTAssertEqual(resolved.start, date("2030-01-01"))
        XCTAssertEqual(resolved.end, date("2030-01-01"))
        XCTAssertEqual(resolved.dayCount, 1)
    }

    func testLabels() {
        XCTAssertEqual(QueryRange.last(30).label, "30d")
        XCTAssertEqual(QueryRange.all.label, "all")
        XCTAssertEqual(QueryRange.between(from: date("2025-10-01"), to: date("2026-03-31")).label,
                       "2025-10-01..2026-03-31")
        XCTAssertEqual(QueryRange.between(from: date("2025-10-01"), to: nil).label, "2025-10-01..")
    }
}
