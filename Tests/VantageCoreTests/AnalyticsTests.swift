import XCTest
@testable import VantageCore

/// The Analytics lifecycle's JSON, its S3 host check, and the merging cache.
final class AnalyticsDecodingTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testDecodesExistingRequests() {
        let json = """
        {"data":[{"type":"analyticsReportRequests","id":"req-1","attributes":
          {"accessType":"ONGOING","stoppedDueToInactivity":false}}]}
        """
        let requests = AnalyticsDecoder.requests(from: data(json))
        XCTAssertEqual(requests.first?.id, "req-1")
        XCTAssertEqual(requests.first?.accessType, "ONGOING")
        XCTAssertFalse(requests.first?.stoppedDueToInactivity ?? true)
    }

    /// Apple stops generating for a request nobody reads. A stopped request must be visible, not
    /// treated as usable — otherwise the chart just quietly stops moving.
    func testAStoppedRequestIsDecodedAsStopped() {
        let json = """
        {"data":[{"type":"analyticsReportRequests","id":"req-1","attributes":
          {"accessType":"ONGOING","stoppedDueToInactivity":true}}]}
        """
        XCTAssertTrue(AnalyticsDecoder.requests(from: data(json)).first?.stoppedDueToInactivity
                      ?? false)
    }

    /// A POST returns one resource under `data`, not an array.
    func testDecodesTheCreatedRequest() {
        let json = """
        {"data":{"type":"analyticsReportRequests","id":"new-1","attributes":
          {"accessType":"ONGOING"}}}
        """
        XCTAssertEqual(AnalyticsDecoder.request(from: data(json))?.id, "new-1")
    }

    func testDecodesReportsAndTheirCategories() {
        let json = """
        {"data":[
          {"type":"analyticsReports","id":"r1","attributes":
            {"name":"App Store Discovery and Engagement Standard",
             "category":"APP_STORE_ENGAGEMENT"}},
          {"type":"analyticsReports","id":"r2","attributes":
            {"name":"App Store Installation and Deletion Standard","category":"COMMERCE"}}
        ]}
        """
        let reports = AnalyticsDecoder.reports(from: data(json))
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports.first?.category, .appStoreEngagement)
        XCTAssertEqual(reports.last?.category, .commerce)
    }

    /// Apple has added categories before and will again; an unknown one must not be guessed at.
    func testAnUnknownCategoryDecodesToNilRatherThanADefault() {
        let json = """
        {"data":[{"type":"analyticsReports","id":"r1","attributes":
          {"name":"Something New","category":"SOMETHING_NEW"}}]}
        """
        XCTAssertNil(AnalyticsDecoder.reports(from: data(json)).first?.category)
        XCTAssertEqual(AnalyticsDecoder.reports(from: data(json)).first?.name, "Something New")
    }

    func testDecodesInstances() {
        let json = """
        {"data":[{"type":"analyticsReportInstances","id":"i1","attributes":
          {"granularity":"DAILY","processingDate":"2026-08-19"}}]}
        """
        let instances = AnalyticsDecoder.instances(from: data(json))
        XCTAssertEqual(instances.first?.processingDate, "2026-08-19")
        XCTAssertEqual(instances.first?.granularity, "DAILY")
    }

    // MARK: - Segment URLs

    private func segmentJSON(_ url: String) -> String {
        """
        {"data":[{"type":"analyticsReportSegments","id":"s1","attributes":
          {"url":"\(url)","checksum":"abc123","sizeInBytes":2048}}]}
        """
    }

    func testAcceptsApplesPreSignedS3URL() {
        let url = "https://asp-us-west-2.s3.us-west-2.amazonaws.com/report.gz?X-Amz-Signature=x"
        let segments = AnalyticsDecoder.segments(from: data(segmentJSON(url)))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments.first?.checksum, "abc123")
        XCTAssertEqual(segments.first?.sizeInBytes, 2048)
    }

    /// This is the one URL in the whole app that legitimately leaves Apple's estate, so it gets the
    /// tightest constraint that's still honest: the S3 domain.
    func testRefusesASegmentURLOutsideS3() {
        for hostile in ["https://evil.example.com/report.gz",
                        "https://api.appstoreconnect.apple.com.evil.test/x.gz"] {
            XCTAssertTrue(AnalyticsDecoder.segments(from: data(segmentJSON(hostile))).isEmpty,
                          hostile)
        }
    }

    /// The leading dot matters — without it this passes.
    func testRefusesALookalikeAmazonHost() {
        let lookalike = "https://evilamazonaws.com/report.gz"
        XCTAssertTrue(AnalyticsDecoder.segments(from: data(segmentJSON(lookalike))).isEmpty)
    }

    func testRefusesANonHTTPSSegmentURL() {
        let plain = "http://asp.s3.us-west-2.amazonaws.com/report.gz"
        XCTAssertTrue(AnalyticsDecoder.segments(from: data(segmentJSON(plain))).isEmpty)
    }

    func testMalformedPayloadsDecodeToNothing() {
        XCTAssertTrue(AnalyticsDecoder.requests(from: data("not json")).isEmpty)
        XCTAssertTrue(AnalyticsDecoder.reports(from: data("{}")).isEmpty)
        XCTAssertTrue(AnalyticsDecoder.segments(from: Data()).isEmpty)
        XCTAssertNil(AnalyticsDecoder.request(from: data("{}")))
    }

    // MARK: - Checksums

    func testAMatchingChecksumPasses() {
        // MD5 of "hello" — the well-known vector.
        XCTAssertTrue(ASCAnalyticsClient.matchesChecksum(
            Data("hello".utf8), "5d41402abc4b2a76b9719d911017c592"))
    }

    func testChecksumComparisonIsCaseInsensitive() {
        XCTAssertTrue(ASCAnalyticsClient.matchesChecksum(
            Data("hello".utf8), "5D41402ABC4B2A76B9719D911017C592"))
    }

    /// The failure this actually guards against is a truncated download.
    func testATruncatedDownloadFailsItsChecksum() {
        XCTAssertFalse(ASCAnalyticsClient.matchesChecksum(
            Data("hell".utf8), "5d41402abc4b2a76b9719d911017c592"))
    }

    func testNoChecksumOfferedIsNotTreatedAsAFailure() {
        XCTAssertTrue(ASCAnalyticsClient.matchesChecksum(Data("hello".utf8), ""))
    }
}

/// The merging cache — a third behaviour again from the immutable report archive and the TTL
/// reviews cache.
final class AnalyticsStoreTests: XCTestCase {
    private var directory: URL!
    private var store: AnalyticsStore!

    override func setUp() {
        super.setUp()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vantage-analytics-tests-\(UUID().uuidString)")
        store = AnalyticsStore(directory: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func day(_ d: Int, impressions: Decimal, pageViews: Decimal = 0) -> EngagementDay {
        EngagementDay(date: ReportDate(year: 2026, month: 8, day: d),
                      impressions: impressions, pageViews: pageViews)
    }

    func testRoundTrips() {
        store.merge([day(19, impressions: 100)], for: "6478")
        XCTAssertEqual(store.load("6478")?.first?.impressions, 100)
    }

    /// History accumulates across refreshes, because each refresh only fetches the newest few
    /// instances and Apple discards anything past 35 days.
    func testOlderDaysSurviveARefreshThatDoesNotIncludeThem() {
        store.merge([day(1, impressions: 10), day(2, impressions: 20)], for: "6478")
        store.merge([day(3, impressions: 30)], for: "6478")

        XCTAssertEqual(store.load("6478")?.count, 3)
        XCTAssertEqual(store.load("6478")?.first?.date, ReportDate(year: 2026, month: 8, day: 1))
    }

    /// Apple revises a day as late events land. Newer data for a date replaces older data rather
    /// than adding to it — summing would double-count every refresh.
    func testFreshDataForADateReplacesRatherThanAccumulates() {
        store.merge([day(19, impressions: 100)], for: "6478")
        store.merge([day(19, impressions: 130)], for: "6478")
        XCTAssertEqual(store.load("6478")?.count, 1)
        XCTAssertEqual(store.load("6478")?.first?.impressions, 130)
    }

    func testDaysAreStoredOldestFirst() {
        store.merge([day(3, impressions: 1), day(1, impressions: 1), day(2, impressions: 1)],
                    for: "6478")
        XCTAssertEqual(store.load("6478")?.map(\.date.day), [1, 2, 3])
    }

    func testFreshnessFollowsTheCacheLifetime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(store.needsFetch("6478", now: now))
        store.merge([day(19, impressions: 1)], for: "6478", now: now)
        XCTAssertFalse(store.needsFetch("6478", now: now.addingTimeInterval(60)))
        XCTAssertTrue(store.needsFetch(
            "6478", now: now.addingTimeInterval(AnalyticsStore.maxAge + 1)))
    }

    func testNonNumericAppleIDsAreRefused() {
        XCTAssertFalse(store.save([day(19, impressions: 1)], for: "../../123/x"))
        XCTAssertNil(store.load("../../123/x"))
    }

    // MARK: - Merging within one refresh

    /// Apple splits one day across several segments, so within a single fetch the parts add up.
    func testSegmentsOfOneDaySumWithinARefresh() {
        let merged = EngagementMerge.merge([day(19, impressions: 600, pageViews: 60),
                                            day(19, impressions: 400, pageViews: 40)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.impressions, 1000)
        XCTAssertEqual(merged.first?.pageViews, 100)
    }
}
