import XCTest
@testable import VantageCore

/// The read-only query layer the CLI and the MCP server both go through.
///
/// The point of the type is what it *can't* do, so these check the shape of what it returns and
/// that the honest-nil cases stay nil rather than becoming zero.
final class CacheQueryTests: XCTestCase {
    private var directory: URL!
    private var query: CacheQuery!
    private var reports: ReportStore!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-query-tests-\(UUID().uuidString)")
        reports = ReportStore(directory: directory)
        query = CacheQuery(
            reports: reports,
            reviews: ReviewStore(directory: directory.appendingPathComponent("reviews")),
            analytics: AnalyticsStore(directory: directory.appendingPathComponent("analytics")),
            listings: AppListingStore(directory: directory.appendingPathComponent("listings")),
            fx: FX(directory: directory))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func save(_ date: ReportDate, units: Decimal, usd: Decimal, sales: Decimal = 0) {
        reports.save(DaySales(
            date: date, origin: .observed, downloads: units, proceeds: ["USD": usd],
            apps: [AppSales(appleID: "6478", title: "Vantage", downloads: units,
                            proceeds: ["USD": usd], unitsByProductType: ["1": units],
                            sales: ["USD": sales])],
            fetchedAt: Date(), unitsByProductType: ["1": units],
            sales: ["USD": sales], parserVersion: ReportParser.version))
    }

    // MARK: - Empty

    /// With nothing cached there is nothing to say, and saying "zero" would be a claim about a
    /// business rather than about a cache.
    func testAnEmptyCacheYieldsNoSalesSnapshot() {
        XCTAssertNil(query.sales(range: .last(30)))
        XCTAssertTrue(query.apps(range: .last(30)).isEmpty)
        XCTAssertTrue(query.reviews().isEmpty)
        XCTAssertTrue(query.engagement().isEmpty)
    }

    func testStatusWorksOnAnEmptyCache() {
        let status = query.status()
        XCTAssertNil(status.newestReport)
        XCTAssertEqual(status.daysCached, 0)
        XCTAssertEqual(status.appsWithReviewsCached, 0)
    }

    // MARK: - Sales

    func testSalesReportsTheRangeItActuallyCovers() {
        let yesterday = ReportDate.yesterday()
        for offset in 0..<3 {
            save(yesterday.adding(days: -offset), units: 10, usd: 5, sales: 8)
        }
        let snapshot = try! XCTUnwrap(query.sales(range: .last(7)))

        XCTAssertEqual(snapshot.to, yesterday.apiString)
        XCTAssertEqual(snapshot.from, yesterday.adding(days: -6).apiString)
        XCTAssertEqual(snapshot.daysCached, 3, "and says so rather than implying seven")
        XCTAssertEqual(snapshot.daysInRange, 7)
        XCTAssertEqual(snapshot.downloads, 30)
    }

    /// Without a rate table there is no single number, and a zero would read as "earned nothing".
    func testMoneyIsNilRatherThanZeroWhenNothingCanBeConverted() {
        save(ReportDate.yesterday(), units: 5, usd: 12, sales: 20)
        let snapshot = try! XCTUnwrap(query.sales(range: .last(30)))
        // No rates file was written in setUp, so nothing is convertible.
        XCTAssertNil(snapshot.proceeds)
        XCTAssertEqual(snapshot.downloads, 5, "but units need no rate and are still reported")
    }

    /// JSONEncoder writes a Decimal at full precision, which turns a converted total into
    /// 14.914876209903571 — exact, and noise to anything reading it as money.
    func testMoneyIsRoundedToCents() {
        XCTAssertEqual(CacheQuery.rounded(Decimal(string: "14.914876209903571")),
                       Decimal(string: "14.91"))
        XCTAssertEqual(CacheQuery.rounded(Decimal(string: "0.005")), Decimal(string: "0.01"))
        XCTAssertNil(CacheQuery.rounded(nil))
    }

    // MARK: - Apps

    func testAppsCarryTheirIdentityAndUnits() {
        save(ReportDate.yesterday(), units: 42, usd: 9)
        let apps = query.apps(range: .last(30))
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.appleID, "6478")
        XCTAssertEqual(apps.first?.title, "Vantage")
        XCTAssertEqual(apps.first?.downloads, 42)
        XCTAssertNil(apps.first?.averageRating, "no listing cached, so no rating is invented")
    }

    // MARK: - Any range

    /// The query layer used to read a fixed 60 days, so anything older was invisible however long
    /// the app had been collecting it.
    func testReadsTheWholeCacheNotAFixedWindow() throws {
        let yesterday = ReportDate.yesterday()
        save(yesterday, units: 1, usd: 1)
        save(yesterday.adding(days: -500), units: 7, usd: 1)

        let all = try XCTUnwrap(query.sales(range: .all))
        XCTAssertEqual(all.downloads, 8)
        XCTAssertEqual(all.daysCached, 2)
        XCTAssertEqual(all.daysInRange, 501)
        XCTAssertEqual(all.from, yesterday.adding(days: -500).apiString)
        XCTAssertEqual(all.range, "all")

        XCTAssertEqual(query.status().daysCached, 2)
        XCTAssertEqual(query.status().oldestReport, yesterday.adding(days: -500).apiString)
    }

    func testExplicitDatesSelectExactlyThoseDays() throws {
        let yesterday = ReportDate.yesterday()
        for offset in 0..<100 { save(yesterday.adding(days: -offset), units: 1, usd: 1) }
        let from = yesterday.adding(days: -60)
        let to = yesterday.adding(days: -51)

        let snapshot = try XCTUnwrap(query.sales(range: .between(from: from, to: to)))
        XCTAssertEqual(snapshot.from, from.apiString)
        XCTAssertEqual(snapshot.to, to.apiString)
        XCTAssertEqual(snapshot.downloads, 10)
        XCTAssertEqual(snapshot.daysCached, 10)
        XCTAssertEqual(snapshot.daysInRange, 10)
    }

    /// Asking for more than is cached is allowed, and says so rather than implying full coverage.
    func testALongerRangeThanTheCacheSaysHowMuchIsThere() throws {
        save(ReportDate.yesterday(), units: 3, usd: 1)
        let snapshot = try XCTUnwrap(query.sales(range: .last(365)))
        XCTAssertEqual(snapshot.daysCached, 1)
        XCTAssertEqual(snapshot.daysInRange, 365)
        XCTAssertEqual(snapshot.range, "365d")
    }

    func testAppsFollowTheRangeToo() {
        let yesterday = ReportDate.yesterday()
        save(yesterday, units: 1, usd: 1)
        save(yesterday.adding(days: -200), units: 50, usd: 1)
        XCTAssertEqual(query.apps(range: .last(7)).first?.downloads, 1)
        XCTAssertEqual(query.apps(range: .all).first?.downloads, 51)
    }

    // MARK: - Everything is Codable

    /// Both consumers are JSON. A snapshot that can't encode is a snapshot nobody can read.
    func testEverySnapshotEncodes() throws {
        save(ReportDate.yesterday(), units: 1, usd: 1, sales: 2)
        let encoder = JSONEncoder()
        XCTAssertNoThrow(try encoder.encode(XCTUnwrap(query.sales(range: .last(30)))))
        XCTAssertNoThrow(try encoder.encode(query.apps(range: .last(30))))
        XCTAssertNoThrow(try encoder.encode(query.reviews()))
        XCTAssertNoThrow(try encoder.encode(query.engagement()))
        XCTAssertNoThrow(try encoder.encode(query.status()))
    }
}
