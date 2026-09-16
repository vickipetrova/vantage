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

    /// `parserVersion` defaults to the current one: these tests are about origin, and a day read
    /// by an older parser is refetched regardless of origin — which has its own tests below.
    private func day(_ date: ReportDate, origin: DaySales.Origin = .observed,
                     downloads: Decimal = 42,
                     parserVersion: Int = ReportParser.version) -> DaySales {
        DaySales(date: date, origin: origin, downloads: downloads,
                 proceeds: ["USD": Decimal(string: "12.34")!],
                 apps: [AppSales(appleID: "1111111111", title: "App One",
                                 downloads: downloads,
                                 proceeds: ["USD": Decimal(string: "12.34")!])],
                 fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), skippedRows: 1,
                 parserVersion: parserVersion)
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

    /// A day's *report* is immutable; our reading of it is not. A day parsed before the parser
    /// learned to read gross customer sales holds none, and no amount of waiting will add it — so
    /// it is refetched once, and exactly once.
    func testADayReadByAnOlderParserIsRefetchedOnce() {
        store.save(day(date, origin: .observed, parserVersion: 0))
        XCTAssertTrue(store.needsFetch(date), "an incomplete parse is worth one more request")

        // Re-read by the current parser, it settles down again.
        store.save(day(date, origin: .observed, parserVersion: ReportParser.version))
        XCTAssertFalse(store.needsFetch(date))
        XCTAssertFalse(store.needsFetch(date, userInitiated: true))
    }

    /// The rule still holds for the case it was written for — this must not become a licence to
    /// refetch settled days for any other reason.
    func testAStaleParseIsTheOnlyThingThatOverridesImmutability() {
        store.save(day(date, origin: .observed, parserVersion: ReportParser.version + 1))
        XCTAssertFalse(store.needsFetch(date), "a newer parse than ours is still complete enough")
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
