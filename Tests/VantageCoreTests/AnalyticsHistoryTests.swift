import XCTest
@testable import VantageCore

/// Importing an app's analytics history once, from a `ONE_TIME_SNAPSHOT` request.
///
/// An `ONGOING` request only produces days from its own creation onwards — verified against the
/// live API on 2026-09-17, where a three-day-old request had exactly one daily instance. The
/// history Apple still holds is reachable only through a snapshot, which is generated once and
/// then stops.
final class AnalyticsHistoryTests: XCTestCase {
    private func request(_ id: String, _ accessType: String,
                         stopped: Bool = false) -> AnalyticsRequest {
        AnalyticsRequest(id: id, accessType: accessType, stoppedDueToInactivity: stopped)
    }

    // MARK: - Which snapshot request to use

    func testNoSnapshotMeansCreateOne() {
        XCTAssertEqual(AnalyticsSnapshotDecision.decide(from: []), .create)
        XCTAssertEqual(AnalyticsSnapshotDecision.decide(from: [request("a", "ONGOING")]), .create)
    }

    func testAnExistingSnapshotIsUsed() {
        let requests = [request("ongoing", "ONGOING"), request("snap", "ONE_TIME_SNAPSHOT")]
        XCTAssertEqual(AnalyticsSnapshotDecision.decide(from: requests), .use("snap"))
    }

    /// A snapshot stops after it has generated — that's what "one time" means, and it is not a
    /// reason to ask for another. Its instances stay readable until Apple expires them, and
    /// creating a second request for the same app is how the `409` dead end starts.
    func testAStoppedSnapshotIsStillUsedRatherThanReplaced() {
        let requests = [request("snap", "ONE_TIME_SNAPSHOT", stopped: true)]
        XCTAssertEqual(AnalyticsSnapshotDecision.decide(from: requests), .use("snap"))
    }

    func testALiveSnapshotWinsOverAStoppedOne() {
        let requests = [request("old", "ONE_TIME_SNAPSHOT", stopped: true),
                        request("new", "ONE_TIME_SNAPSHOT")]
        XCTAssertEqual(AnalyticsSnapshotDecision.decide(from: requests), .use("new"))
    }

    // MARK: - Importing once, in bounded chunks

    private func store() -> AnalyticsStore {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("analytics-history-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return AnalyticsStore(directory: directory)
    }

    func testHistoryIsWantedUntilItHasBeenImported() {
        let store = store()
        XCTAssertTrue(store.needsHistory("123"))

        store.markHistoryImported("123")
        XCTAssertFalse(store.needsHistory("123"))
    }

    /// A day's engagement and the history flag live in the same file, so importing must not undo
    /// the merge — and merging must not undo the flag.
    func testTheHistoryFlagAndTheDaysSurviveEachOther() {
        let store = store()
        let day = EngagementDay(date: ReportDate(year: 2026, month: 9, day: 16),
                                impressions: 10, pageViews: 2)
        store.merge([day], for: "123")
        store.markHistoryImported("123")
        store.merge([day], for: "123")

        XCTAssertFalse(store.needsHistory("123"), "Merging a day is not a reason to re-import")
        XCTAssertEqual(store.load("123"), [day])
    }

    /// Apple can hold years of history, and each instance is a segments call plus a download. A
    /// refresh takes a bounded bite and the next one continues, so a first run can't turn into
    /// hundreds of requests.
    func testOnlyACappedNumberOfInstancesIsTakenPerRefresh() {
        let store = store()
        let all = (1...120).map { "instance-\($0)" }

        let first = store.pendingHistoryInstances(all, for: "123")
        XCTAssertEqual(first.count, AnalyticsStore.historyInstanceCap)

        store.recordHistoryInstances(first, for: "123")
        let second = store.pendingHistoryInstances(all, for: "123")
        XCTAssertEqual(second.count, AnalyticsStore.historyInstanceCap)
        XCTAssertTrue(Set(first).isDisjoint(with: Set(second)), "A second bite takes new instances")
    }

    func testImportingEveryInstanceLeavesNothingPending() {
        let store = store()
        let all = ["a", "b", "c"]
        store.recordHistoryInstances(all, for: "123")
        XCTAssertTrue(store.pendingHistoryInstances(all, for: "123").isEmpty)
    }

    /// Instance IDs are opaque UUIDs, so the store can't order them itself — the caller lists them
    /// oldest first by processing date, and the order it gives is the order imported. The point of
    /// the import is the past, so a run that stops early should have extended the history rather
    /// than re-fetched what the ongoing request already covers.
    func testTheGivenOrderIsThePriority() {
        let store = store()
        let oldestFirst = ["9d1c…-2024-06", "3a77…-2025-01", "0b52…-2026-09"]
        XCTAssertEqual(store.pendingHistoryInstances(oldestFirst, for: "123"), oldestFirst)

        store.recordHistoryInstances([oldestFirst[0]], for: "123")
        XCTAssertEqual(store.pendingHistoryInstances(oldestFirst, for: "123"),
                       Array(oldestFirst.dropFirst()))
    }

    /// A download that gives up part-way must leave the rest of the work to do.
    ///
    /// `ASCAnalyticsClient.collect` degrades on purpose — a segments call that fails mid-run still
    /// returns whatever parsed before it, because partial data is true data. What it may **not** do
    /// is let the caller record the whole batch: the instances that never ran would be marked
    /// imported, the app marked done, and those days would exist nowhere once Apple expires them.
    /// So the slice names the instances it actually finished, and only those are recorded.
    func testOnlyTheInstancesTheSliceCompletedAreRecorded() {
        let store = store()
        let asked = ["a", "b", "c", "d"]
        let slice = AnalyticsHistorySlice(
            days: [EngagementDay(date: ReportDate(year: 2026, month: 9, day: 16),
                                 impressions: 10, pageViews: 2)],
            completedInstanceIDs: ["a", "b"])

        store.merge(slice.days, for: "123")
        store.recordHistoryInstances(slice.completedInstanceIDs, for: "123")

        XCTAssertEqual(store.pendingHistoryInstances(asked, for: "123"), ["c", "d"],
                       "What failed or never ran is still pending")
        XCTAssertTrue(store.needsHistory("123"),
                      "An app is done only when nothing is left, not when a run ends")
    }

    /// The other half of the same rule: a slice that completed nothing records nothing, so the next
    /// refresh asks for exactly the same instances again.
    func testASliceThatCompletedNothingRecordsNothing() {
        let store = store()
        let slice = AnalyticsHistorySlice(days: [], completedInstanceIDs: [])
        store.recordHistoryInstances(slice.completedInstanceIDs, for: "123")

        XCTAssertEqual(store.pendingHistoryInstances(["a", "b"], for: "123"), ["a", "b"])
        XCTAssertTrue(store.needsHistory("123"))
    }

    /// The cache file predates this feature on every existing install.
    func testAnEntryWrittenBeforeThisFeatureStillWantsItsHistory() throws {
        let store = store()
        let day = EngagementDay(date: ReportDate(year: 2026, month: 9, day: 16),
                                impressions: 10, pageViews: 2)
        store.merge([day], for: "123")

        XCTAssertTrue(store.needsHistory("123"))
        XCTAssertEqual(store.pendingHistoryInstances(["a"], for: "123"), ["a"])
    }
}
