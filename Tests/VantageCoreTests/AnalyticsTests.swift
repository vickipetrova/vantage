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

    // MARK: - What stops a whole run

    /// "Not ready yet" is the normal answer for most apps just after analytics is switched on, so
    /// treating it as fatal would mean nobody ever saw any analytics at all.
    func testNotReadyYetDoesNotStopTheRun() {
        XCTAssertFalse(AnalyticsError.notReadyYet.stopsTheRun)
        XCTAssertFalse(AnalyticsError.badResponse.stopsTheRun)
        XCTAssertFalse(AnalyticsError.corruptSegment.stopsTheRun)
    }

    func testAKeyOrRoleProblemStopsTheRun() {
        XCTAssertTrue(AnalyticsError.noKey.stopsTheRun)
        XCTAssertTrue(AnalyticsError.notAllowedToRequest(detail: nil).stopsTheRun)
        XCTAssertTrue(AnalyticsError.rateLimited.stopsTheRun)
        XCTAssertTrue(AnalyticsError.network.stopsTheRun)
    }

    // MARK: - What the panel is allowed to call "waiting"

    /// **Only the two generating cases are Apple still working** — `notReadyYet` and
    /// `restartedAfterInactivity`. Everything else is a failure and must be shown as one.
    ///
    /// `stopsTheRun` used to stand in for this, and the two questions are not the same one: it asks
    /// "should the other apps still be tried?", which is `false` for a hard HTTP error that has
    /// nothing to do with waiting. The panel read that `false` as "waiting", so a `405` on the
    /// create-request POST was rendered as "Apple is preparing your first report — this is not an
    /// error" every refresh for a month. See `ASCToken.mint`.
    func testOnlyNotReadyYetCountsAsWaitingForApple() {
        XCTAssertTrue(AnalyticsError.notReadyYet.isWaitingForApple)

        for error: AnalyticsError in [.http(405, detail: nil), .http(500, detail: "boom"),
                                      .badResponse, .corruptSegment, .noKey, .rateLimited,
                                      .network, .notAllowedToRequest(detail: nil)] {
            XCTAssertFalse(error.isWaitingForApple, "\(error) is a failure, not a wait")
        }
    }

    /// A non-fatal error must not lose Apple's own explanation — that text is the only clue the
    /// user gets, and swallowing it is what made this bug invisible.
    func testANonFatalHTTPErrorStillDescribesItself() {
        XCTAssertEqual(AnalyticsError.http(405, detail: "The request method is not valid")
            .errorDescription, "The request method is not valid")
        XCTAssertEqual(AnalyticsError.http(500, detail: nil).errorDescription,
                       "App Store Connect returned HTTP 500.")
    }

    /// "Open Settings…" is only ever the fix for a key or a role. Offering it for a 500 or a bad
    /// gzip tells the user to go and break credentials that are working perfectly.
    func testOnlyCredentialProblemsPointAtSettings() {
        XCTAssertTrue(AnalyticsError.noKey.suggestsCheckingCredentials)
        XCTAssertTrue(AnalyticsError.notAllowedToRequest(detail: nil).suggestsCheckingCredentials)

        for error: AnalyticsError in [.notReadyYet, .rateLimited, .network, .badResponse,
                                      .corruptSegment, .http(500, detail: nil)] {
            XCTAssertFalse(error.suggestsCheckingCredentials, "\(error) is not a credential problem")
        }
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

    // MARK: - Covering the gap since the last look

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysLater(_ days: Int) -> Date {
        Self.now.addingTimeInterval(Double(days) * 24 * 60 * 60)
    }

    /// Nothing cached: take the opening window, not the whole retention period. A first refresh
    /// already costs a segments call and a download per instance per app.
    func testAFirstFetchTakesTheOpeningWindow() {
        XCTAssertEqual(store.instancesNeeded("6478", now: Self.now),
                       AnalyticsStore.openingInstances)
    }

    /// Even a cache fetched minutes ago revisits the last few days, because Apple revises a day as
    /// late events land and a day isn't final until two days after it.
    func testAFreshCacheStillRevisitsTheDaysApplesStillRevising() {
        store.merge([day(19, impressions: 1)], for: "6478", now: Self.now)
        XCTAssertEqual(store.instancesNeeded("6478", now: Self.now),
                       AnalyticsStore.revisionOverlap)
    }

    /// The bug this closes: `instanceLimit` was a fixed 7, so a fortnight away left days 8–14
    /// permanently missing even though Apple still held them.
    func testAGapLongerThanAWeekIsCoveredRatherThanTruncated() {
        store.merge([day(19, impressions: 1)], for: "6478", now: Self.now)
        XCTAssertEqual(store.instancesNeeded("6478", now: daysLater(14)),
                       14 + AnalyticsStore.revisionOverlap)
    }

    /// Apple keeps daily instances for 35 days. Asking for more is not wrong so much as pointless,
    /// and it is the one limit no amount of code can route around.
    func testCoverageStopsAtApplesRetentionWindow() {
        store.merge([day(19, impressions: 1)], for: "6478", now: Self.now)
        XCTAssertEqual(store.instancesNeeded("6478", now: daysLater(400)),
                       AnalyticsStore.retentionInstances)
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

/// Which of the three things to do about an app's report requests.
///
/// Pure and separate from the client for the same reason the decoders are: this is where the month
/// of silence actually lived, and a decision that can be tested is a decision that can be trusted.
final class AnalyticsRequestDecisionTests: XCTestCase {
    private func request(_ id: String, _ accessType: String = "ONGOING",
                         stopped: Bool = false) -> AnalyticsRequest {
        AnalyticsRequest(id: id, accessType: accessType, stoppedDueToInactivity: stopped)
    }

    func testALiveOngoingRequestIsUsed() {
        XCTAssertEqual(AnalyticsRequestDecision.decide(from: [request("abc")]), .use("abc"))
    }

    func testNothingAtAllMeansCreateOne() {
        XCTAssertEqual(AnalyticsRequestDecision.decide(from: []), .create)
    }

    /// **The dead end this closes.** Apple stops generating for a request nobody reads. The old
    /// code filtered the stopped request out and fell through to `create`, which Apple answers
    /// `409 STATE_ERROR — You already have such an entity`, mapped to `notReadyYet`. The panel then
    /// said "Apple is preparing your first report" forever, with no way back.
    func testAStoppedRequestIsRestartedRatherThanBlindlyRecreated() {
        XCTAssertEqual(AnalyticsRequestDecision.decide(from: [request("dead", stopped: true)]),
                       .restart("dead"))
    }

    func testALiveRequestIsPreferredOverAStoppedOne() {
        let decision = AnalyticsRequestDecision.decide(
            from: [request("dead", stopped: true), request("live")])
        XCTAssertEqual(decision, .use("live"))
    }

    /// A snapshot stops after one generation, so it can't serve a daily chart and must not be
    /// mistaken for a request that will keep producing.
    func testAOneTimeSnapshotIsNotMistakenForAnOngoingRequest() {
        XCTAssertEqual(
            AnalyticsRequestDecision.decide(from: [request("snap", "ONE_TIME_SNAPSHOT")]), .create)
    }

    /// A restart sends a `DELETE` to a path built from this ID, so a hostile one must be refused
    /// whole rather than cleaned up into a request that deletes something else.
    func testARequestIDGoingIntoADeletePathIsValidatedNotSanitized() {
        XCTAssertTrue(
            AnalyticsDecoder.isWellFormedRequestID("3f2504e0-4f89-11d3-9a0c-0305e82c3301"))

        for hostile in ["../../v1/users", "abc/../../apps", "", String(repeating: "a", count: 65),
                        "3f2504e0 4f89", "3f2504e0?filter=x", "zzzz-not-hex"] {
            XCTAssertFalse(AnalyticsDecoder.isWellFormedRequestID(hostile), "accepted \(hostile)")
        }
    }

    /// Restarting means Apple's 24–48 hours begins again — a wait, and one that needs different
    /// words from "preparing your first report", since it isn't the first.
    func testARestartIsAWaitAndNotACredentialProblem() {
        XCTAssertTrue(AnalyticsError.restartedAfterInactivity.isWaitingForApple)
        XCTAssertFalse(AnalyticsError.restartedAfterInactivity.stopsTheRun)
        XCTAssertFalse(AnalyticsError.restartedAfterInactivity.suggestsCheckingCredentials)
        let text = AnalyticsError.restartedAfterInactivity.errorDescription
        XCTAssertEqual(text?.contains("stopped"), true)
    }
}
