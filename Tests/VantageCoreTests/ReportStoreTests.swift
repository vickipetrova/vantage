import XCTest
@testable import VantageCore

/// The cache decides what gets re-fetched, so its bugs show up as numbers that never correct
/// themselves. Each test uses a fresh temporary directory — none of this touches the real cache.
final class ReportStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ReportStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VantageStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = ReportStore(directory: directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func day(_ date: ReportDate, origin: DaySales.Origin = .observed,
                     downloads: Decimal = 42) -> DaySales {
        DaySales(date: date, origin: origin, downloads: downloads,
                 proceeds: ["USD": Decimal(string: "12.34")!],
                 apps: [AppSales(appleID: "1111111111", title: "App One",
                                 downloads: downloads,
                                 proceeds: ["USD": Decimal(string: "12.34")!])],
                 fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), skippedRows: 1)
    }

    private let date = ReportDate(year: 2026, month: 8, day: 1)

    // MARK: - Round trip

    func testSavesAndLoadsADay() {
        XCTAssertTrue(store.save(day(date)))
        let loaded = store.load(date)
        XCTAssertEqual(loaded, day(date))
    }

    /// Money must survive the cache exactly. A Decimal that round-trips through Double would come
    /// back subtly different and nobody would ever notice.
    func testMoneySurvivesTheRoundTripExactly() {
        let awkward = Decimal(string: "0.1")! + Decimal(string: "0.2")!
        let original = DaySales(date: date, origin: .observed, downloads: Decimal(string: "2.50")!,
                                proceeds: ["USD": awkward], apps: [], fetchedAt: Date())
        store.save(original)
        XCTAssertEqual(store.load(date)?.proceeds["USD"], Decimal(string: "0.30")!)
        XCTAssertEqual(store.load(date)?.downloads, Decimal(string: "2.50")!)
    }

    func testLoadingAnAbsentDayReturnsNil() {
        XCTAssertNil(store.load(date))
    }

    func testLoadAllSkipsAbsentDays() {
        store.save(day(date))
        store.save(day(date.adding(days: -2)))
        let loaded = store.loadAll(date.lastDays(3))
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.map(\.date.apiString), ["2026-07-30", "2026-08-01"])
    }

    // MARK: - Damage

    /// A corrupt file must behave like an absent one, so the fix is an automatic re-fetch rather
    /// than a permanently broken day.
    func testACorruptFileIsTreatedAsMissing() throws {
        store.save(day(date))
        let file = directory.appendingPathComponent("2026-08-01.json")
        try Data("{ this is not json".utf8).write(to: file)

        XCTAssertNil(store.load(date))
        XCTAssertTrue(store.needsFetch(date))
    }

    func testAnEmptyFileIsTreatedAsMissing() throws {
        store.save(day(date))
        try Data().write(to: directory.appendingPathComponent("2026-08-01.json"))
        XCTAssertNil(store.load(date))
    }

    /// A file whose contents claim a different date would attribute one day's money to another.
    func testAFileWhoseContentsDisagreeWithItsNameIsRejected() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mismatched = day(ReportDate(year: 2026, month: 7, day: 1))
        let encoder = JSONEncoder()
        try encoder.encode(mismatched).write(
            to: directory.appendingPathComponent("2026-08-01.json"))
        XCTAssertNil(store.load(date))
    }

    // MARK: - What gets re-fetched

    func testAnObservedDayIsNeverFetchedAgain() {
        store.save(day(date, origin: .observed))
        XCTAssertFalse(store.needsFetch(date))
        XCTAssertFalse(store.needsFetch(date, userInitiated: true),
                       "a published report is immutable — even Refresh Now must not refetch it")
    }

    /// The escape hatch: a day written off as zero is a guess, and Refresh Now is how a user
    /// overturns it when a report lands later than Apple's published window.
    func testAnAssumedZeroDayIsRefetchedOnlyWhenTheUserAsks() {
        store.save(day(date, origin: .assumedZero, downloads: 0))
        XCTAssertFalse(store.needsFetch(date))
        XCTAssertTrue(store.needsFetch(date, userInitiated: true))
    }

    func testAnUncachedDayAlwaysNeedsFetching() {
        XCTAssertTrue(store.needsFetch(date))
        XCTAssertTrue(store.needsFetch(date, userInitiated: true))
    }

    // MARK: - Housekeeping

    func testForgetRemovesADay() {
        store.save(day(date))
        store.forget(date)
        XCTAssertNil(store.load(date))
    }

    func testPruneRemovesOnlyDaysBeforeTheCutoff() {
        for offset in 0..<5 { store.save(day(date.adding(days: -offset))) }
        store.prune(keepingSince: date.adding(days: -2))

        XCTAssertNotNil(store.load(date))
        XCTAssertNotNil(store.load(date.adding(days: -2)))
        XCTAssertNil(store.load(date.adding(days: -3)))
        XCTAssertNil(store.load(date.adding(days: -4)))
    }

    func testPruneLeavesUnrelatedFilesAlone() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stray = directory.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: stray)
        store.save(day(date.adding(days: -10)))

        store.prune(keepingSince: date)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
    }

    func testPruningAnEmptyDirectoryDoesntCrash() {
        store.prune(keepingSince: date)
    }
}
