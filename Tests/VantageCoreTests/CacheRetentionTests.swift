import XCTest
@testable import VantageCore

/// Deleting cached history. Past Apple's retention this is the only copy of the data, so every
/// test here is about deleting exactly what was asked and saying plainly what that costs.
final class CacheRetentionTests: XCTestCase {
    private var directory: URL!
    private var reports: ReportStore!
    private var analytics: AnalyticsStore!
    private var retention: CacheRetention!

    /// 16 Sep 2026, midday Pacific — yesterday is the 15th.
    private let now = ReportDate(year: 2026, month: 9, day: 16).pacificTime(hour: 12)
    private let yesterday = ReportDate(year: 2026, month: 9, day: 15)

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-retention-tests-\(UUID().uuidString)")
        reports = ReportStore(directory: directory)
        analytics = AnalyticsStore(directory: directory.appendingPathComponent("analytics"))
        retention = CacheRetention(reports: reports, analytics: analytics)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func saveSales(_ date: ReportDate) {
        reports.save(DaySales(date: date, origin: .observed, downloads: 1, proceeds: ["USD": 1],
                              apps: [], fetchedAt: now, parserVersion: ReportParser.version))
    }

    private func engagement(_ date: ReportDate) -> EngagementDay {
        EngagementDay(date: date, impressions: 10, pageViews: 1)
    }

    // MARK: - Summary

    func testAnEmptyCacheSummarisesAsEmpty() {
        let summary = retention.summary()
        XCTAssertEqual(summary.salesDays, 0)
        XCTAssertNil(summary.oldest)
        XCTAssertEqual(summary.text, "Nothing cached yet.")
    }

    func testSummaryCountsDaysAndSpan() {
        for offset in [0, 1, 400] { saveSales(yesterday.adding(days: -offset)) }
        let summary = retention.summary()
        XCTAssertEqual(summary.salesDays, 3)
        XCTAssertEqual(summary.oldest, yesterday.adding(days: -400))
        XCTAssertEqual(summary.newest, yesterday)
        XCTAssertGreaterThan(summary.bytes, 0)
        XCTAssertTrue(summary.text.hasPrefix("3 days of sales"), summary.text)
    }

    /// Analytics lives in a subdirectory; the size shown is what Vantage's cache really takes.
    func testSummarySizeIncludesAnalytics() {
        saveSales(yesterday)
        let before = retention.summary().bytes
        analytics.merge((0..<30).map { engagement(yesterday.adding(days: -$0)) }, for: "6478")
        XCTAssertGreaterThan(retention.summary().bytes, before)
    }

    // MARK: - Preview and delete

    func testPreviewCountsWithoutDeleting() {
        for offset in 0..<10 { saveSales(yesterday.adding(days: -offset)) }
        analytics.merge((0..<10).map { engagement(yesterday.adding(days: -$0)) }, for: "6478")

        let cutoff = yesterday.adding(days: -6)
        let preview = retention.preview(before: cutoff)
        XCTAssertEqual(preview.salesDays, 3)
        XCTAssertEqual(preview.analyticsDays, 3)
        XCTAssertEqual(retention.summary().salesDays, 10, "a preview deletes nothing")
    }

    func testDeleteRemovesOnlyDaysBeforeTheCutoff() {
        for offset in 0..<10 { saveSales(yesterday.adding(days: -offset)) }
        analytics.merge((0..<10).map { engagement(yesterday.adding(days: -$0)) }, for: "6478")

        let cutoff = yesterday.adding(days: -6)
        let deleted = retention.delete(before: cutoff)

        XCTAssertEqual(deleted.salesDays, 3)
        XCTAssertEqual(deleted.analyticsDays, 3)
        XCTAssertNotNil(reports.load(cutoff), "the cutoff day itself is kept")
        XCTAssertNil(reports.load(cutoff.adding(days: -1)))
        XCTAssertEqual(analytics.load("6478")?.first?.date, cutoff)
        XCTAssertTrue(retention.preview(before: cutoff).isEmpty)
    }

    /// The same calendar date across two apps is one day of analytics, not two.
    func testAnalyticsDaysAreCountedByDateNotByApp() {
        let old = yesterday.adding(days: -100)
        analytics.merge([engagement(old)], for: "6478")
        analytics.merge([engagement(old)], for: "9999")
        XCTAssertEqual(retention.preview(before: yesterday).analyticsDays, 1)
    }

    // MARK: - Confirmation

    func testConfirmationStatesWhatGoesAndThatItCantBeUndone() {
        let text = CacheRetention.confirmation(
            for: .init(salesDays: 40, analyticsDays: 12),
            before: ReportDate(year: 2025, month: 1, day: 1), historyDays: 365, now: now)
        XCTAssertTrue(text.contains("40 days of sales"), text)
        XCTAssertTrue(text.contains("12 days of analytics"), text)
        XCTAssertTrue(text.contains("can't be undone"), text)
    }

    /// Deleting inside the history window just re-downloads it on the next refresh — worth saying,
    /// or the button looks broken the next morning.
    func testConfirmationWarnsWhenDeletedDaysWillBeFetchedAgain() {
        let inside = CacheRetention.confirmation(
            for: .init(salesDays: 200, analyticsDays: 0),
            before: yesterday.adding(days: -90), historyDays: 365, now: now)
        XCTAssertTrue(inside.contains("download"), inside)

        let outside = CacheRetention.confirmation(
            for: .init(salesDays: 200, analyticsDays: 0),
            before: yesterday.adding(days: -90), historyDays: 30, now: now)
        XCTAssertFalse(outside.contains("download"), outside)
    }
}
