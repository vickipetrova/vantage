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
        XCTAssertNil(query.sales(range: .month))
        XCTAssertTrue(query.apps(range: .month).isEmpty)
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
        let snapshot = try! XCTUnwrap(query.sales(range: .week))

        XCTAssertEqual(snapshot.to, yesterday.apiString)
        XCTAssertEqual(snapshot.from, yesterday.adding(days: -6).apiString)
        XCTAssertEqual(snapshot.daysCached, 3, "and says so rather than implying seven")
        XCTAssertEqual(snapshot.daysInRange, 7)
        XCTAssertEqual(snapshot.downloads, 30)
    }

    /// Without a rate table there is no single number, and a zero would read as "earned nothing".
    func testMoneyIsNilRatherThanZeroWhenNothingCanBeConverted() {
        save(ReportDate.yesterday(), units: 5, usd: 12, sales: 20)
        let snapshot = try! XCTUnwrap(query.sales(range: .month))
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
        let apps = query.apps(range: .month)
        XCTAssertEqual(apps.count, 1)
        XCTAssertEqual(apps.first?.appleID, "6478")
        XCTAssertEqual(apps.first?.title, "Vantage")
        XCTAssertEqual(apps.first?.downloads, 42)
        XCTAssertNil(apps.first?.averageRating, "no listing cached, so no rating is invented")
    }

    // MARK: - Everything is Codable

    /// Both consumers are JSON. A snapshot that can't encode is a snapshot nobody can read.
    func testEverySnapshotEncodes() throws {
        save(ReportDate.yesterday(), units: 1, usd: 1, sales: 2)
        let encoder = JSONEncoder()
        XCTAssertNoThrow(try encoder.encode(XCTUnwrap(query.sales(range: .month))))
        XCTAssertNoThrow(try encoder.encode(query.apps(range: .month)))
        XCTAssertNoThrow(try encoder.encode(query.reviews()))
        XCTAssertNoThrow(try encoder.encode(query.engagement()))
        XCTAssertNoThrow(try encoder.encode(query.status()))
    }
}
