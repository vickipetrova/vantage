import XCTest
@testable import VantageCore

/// The reviews cache. A TTL cache, unlike `ReportStore`'s archive — the distinction is the point.
final class ReviewStoreTests: XCTestCase {
    private var directory: URL!
    private var store: ReviewStore!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-review-tests-\(UUID().uuidString)")
        store = ReviewStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func review(_ id: String, rating: Int = 5,
                        response: ReviewResponse? = nil) -> CustomerReview {
        CustomerReview(id: id, appleID: "6478", rating: rating, title: "Title \(id)",
                       body: "Body \(id)", reviewerNickname: "Invented Tester",
                       createdDate: Date(timeIntervalSince1970: 1_800_000_000),
                       territory: "GBR", response: response)
    }

    func testRoundTrips() {
        XCTAssertTrue(store.save([review("a"), review("b")], for: "6478"))
        XCTAssertEqual(store.load("6478")?.map(\.id), ["a", "b"])
    }

    func testAnUncachedAppReadsAsAbsentNotEmpty() {
        XCTAssertNil(store.load("9999"))
    }

    func testResponsesSurviveTheRoundTrip() {
        let response = ReviewResponse(id: "r1", body: "Thanks!", state: .pendingPublish,
                                      lastModifiedDate: Date(timeIntervalSince1970: 1_800_000_100))
        store.save([review("a", response: response)], for: "6478")
        XCTAssertEqual(store.load("6478")?.first?.response?.state, .pendingPublish)
        XCTAssertEqual(store.load("6478")?.first?.response?.body, "Thanks!")
    }

    // MARK: - Freshness

    func testAnUncachedAppNeedsFetching() {
        XCTAssertTrue(store.needsFetch("6478"))
    }

    func testAFreshlyCachedAppDoesNot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.save([review("a")], for: "6478", now: now)
        XCTAssertFalse(store.needsFetch("6478", now: now.addingTimeInterval(60)))
    }

    /// The whole reason this isn't an archive: a response can be written, edited or deleted from
    /// App Store Connect's web UI while Vantage isn't looking.
    func testACachedAppGoesStaleAndIsRefetched() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.save([review("a")], for: "6478", now: now)
        XCTAssertTrue(store.needsFetch("6478", now: now.addingTimeInterval(ReviewStore.maxAge + 1)))
    }

    /// Stale is not blank. Drawing an hour-old review beats emptying the panel while a fetch runs.
    func testStaleReviewsAreStillReadable() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.save([review("a")], for: "6478", now: now)
        XCTAssertEqual(store.load("6478")?.count, 1)
        XCTAssertTrue(store.needsFetch("6478", now: now.addingTimeInterval(ReviewStore.maxAge + 1)))
    }

    // MARK: - Corruption and paths

    /// Same rule as the report cache: unusable is treated as absent, because the fix for both is a
    /// refetch and that's what "not cached" already causes.
    func testACorruptFileReadsAsAbsent() throws {
        store.save([review("a")], for: "6478")
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("6478.json"))
        XCTAssertNil(store.load("6478"))
        XCTAssertTrue(store.needsFetch("6478"))
    }

    func testNonNumericAppleIDsAreRefused() {
        XCTAssertFalse(store.save([review("a")], for: "../../etc/passwd"))
        XCTAssertFalse(store.save([review("a")], for: "../../123/x"))
        XCTAssertFalse(store.save([review("a")], for: ""))
        XCTAssertNil(store.load("../../123/x"))
    }

    // MARK: - Forgetting

    func testForgettingOneAppLeavesTheOthers() {
        store.save([review("a")], for: "6478")
        store.save([review("b")], for: "1234")
        store.forget("6478")
        XCTAssertNil(store.load("6478"))
        XCTAssertNotNil(store.load("1234"))
    }

    /// Reviews were readable only because the reviews key existed. Taking the key back has to take
    /// the cached text with it.
    func testForgettingEverythingClearsTheCache() {
        store.save([review("a")], for: "6478")
        store.save([review("b")], for: "1234")
        store.forgetAll()
        XCTAssertNil(store.load("6478"))
        XCTAssertNil(store.load("1234"))
    }
}
