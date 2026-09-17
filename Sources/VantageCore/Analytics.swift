import Foundation

/// The Analytics Reports API's four-step lifecycle, as types.
///
/// Nothing here is a single request. To see one number you ask Apple to start generating a report,
/// wait a day or two, list the reports that request produced, list the *instances* of one of them,
/// list the *segments* of one instance, and download each segment. `docs/ANALYTICS_API.md` has the
/// routes; this file has the shapes.
public enum AnalyticsCategory: String, Codable, Sendable, CaseIterable {
    case appStoreEngagement = "APP_STORE_ENGAGEMENT"
    case commerce = "COMMERCE"
    case appUsage = "APP_USAGE"
    case frameworkUsage = "FRAMEWORK_USAGE"
    case performance = "PERFORMANCE"

    public var label: String {
        switch self {
        case .appStoreEngagement: return "App Store engagement"
        case .commerce: return "Commerce"
        case .appUsage: return "App usage"
        case .frameworkUsage: return "Framework usage"
        case .performance: return "Performance"
        }
    }
}

/// Apple's opaque handle for "keep generating reports for this app".
public struct AnalyticsRequest: Equatable, Codable, Sendable {
    public let id: String
    /// `ONGOING` requests keep producing daily reports; `ONE_TIME_SNAPSHOT` stops after one.
    public let accessType: String
    /// Apple stops generating for a request nobody reads. Surfaced so the panel can say why the
    /// numbers stopped rather than showing a silently frozen chart.
    public let stoppedDueToInactivity: Bool

    public init(id: String, accessType: String, stoppedDueToInactivity: Bool) {
        self.id = id
        self.accessType = accessType
        self.stoppedDueToInactivity = stoppedDueToInactivity
    }
}

/// What to do about an app's existing report requests, decided before any of it is acted on.
///
/// Pure and separate from the client for the same reason the decoders are — and for a sharper one:
/// the previous version of this decision was three lines inside a completion handler, it was wrong,
/// and nothing could see that it was wrong.
public enum AnalyticsRequestDecision: Equatable, Sendable {
    /// A live `ONGOING` request. Read its reports.
    case use(String)
    /// An `ONGOING` request Apple has stopped generating for. Delete it, then create a fresh one —
    /// creating without deleting is answered `409 STATE_ERROR`, which is the dead end that cost a
    /// month of analytics.
    case restart(String)
    /// Nothing usable exists.
    case create

    public static func decide(from requests: [AnalyticsRequest]) -> AnalyticsRequestDecision {
        // Snapshots stop after one generation, so they can never feed a daily chart.
        let ongoing = requests.filter { $0.accessType == "ONGOING" }
        if let live = ongoing.first(where: { !$0.stoppedDueToInactivity }) {
            return .use(live.id)
        }
        if let stopped = ongoing.first {
            return .restart(stopped.id)
        }
        return .create
    }
}

/// Which `ONE_TIME_SNAPSHOT` request an app's history comes from.
///
/// Separate from `AnalyticsRequestDecision` because the two access types answer different
/// questions and must not interfere: `ONGOING` feeds the daily chart from its own creation
/// onwards, and a snapshot is the only way to reach what came before it. Apple accepts one of
/// each for the same app — verified against the live API on 2026-09-17.
public enum AnalyticsSnapshotDecision: Equatable, Sendable {
    /// Read this snapshot's instances.
    case use(String)
    /// No snapshot exists for this app yet.
    case create

    public static func decide(from requests: [AnalyticsRequest]) -> AnalyticsSnapshotDecision {
        let snapshots = requests.filter { $0.accessType == "ONE_TIME_SNAPSHOT" }
        // A stopped snapshot is a finished one, not a broken one: "one time" means it generates
        // once and stops. Its instances stay readable until Apple expires them, and asking for a
        // second request for the same app is how a `409 STATE_ERROR` dead end starts.
        if let live = snapshots.first(where: { !$0.stoppedDueToInactivity }) {
            return .use(live.id)
        }
        if let finished = snapshots.first {
            return .use(finished.id)
        }
        return .create
    }
}

public struct AnalyticsReport: Equatable, Sendable {
    public let id: String
    public let name: String
    public let category: AnalyticsCategory?
}

public struct AnalyticsInstance: Equatable, Sendable {
    public let id: String
    public let granularity: String
    /// The day Apple processed this data — **not** the day the data describes.
    public let processingDate: String
}

/// What one history import actually managed to fetch.
///
/// The days **and** the instances they came from, because a history walk is allowed to stop
/// part-way: a segments call that fails, or a download that never finishes, still leaves everything
/// before it true. Returning only the days would let the caller assume the whole batch landed and
/// record instances that were never read — and a snapshot instance recorded but not imported is a
/// day that exists nowhere once Apple expires it 35 days later.
///
/// So the caller records `completedInstanceIDs` and nothing else. An instance is completed only
/// when its segments were listed and every one of them downloaded.
public struct AnalyticsHistorySlice: Equatable, Sendable {
    public let days: [EngagementDay]
    public let completedInstanceIDs: [String]

    public init(days: [EngagementDay], completedInstanceIDs: [String]) {
        self.days = days
        self.completedInstanceIDs = completedInstanceIDs
    }
}

public struct AnalyticsSegment: Equatable, Sendable {
    public let id: String
    /// A pre-signed AWS S3 URL, valid for **five minutes** from the moment the segments call
    /// returned. There is no re-issuing it: a slow download means listing the segments again.
    public let url: URL
    /// MD5 of the compressed bytes, per Apple.
    public let checksum: String
    public let sizeInBytes: Int
}

/// Everything that can go wrong, in the words the panel will show.
public enum AnalyticsError: LocalizedError, Equatable {
    case noKey
    /// The key can't create a report request. That needs Admin — a lesser role can only download
    /// reports for a request that already exists.
    case notAllowedToRequest(detail: String?)
    /// A request exists and Apple hasn't produced anything for it yet. Not a failure: Apple takes
    /// 24–48 hours to generate the first report.
    case notReadyYet
    /// Apple had stopped generating because nothing read the reports for long enough. The dead
    /// request has been deleted and a fresh one created, so the 24–48 hour wait starts again.
    /// Whatever was already downloaded is untouched — `AnalyticsStore` is an archive, not a mirror.
    case restartedAfterInactivity
    case rateLimited
    case http(Int, detail: String?)
    case network
    case badResponse
    /// A segment's bytes didn't match the checksum Apple gave for them.
    case corruptSegment

    /// Whether this should stop a whole run rather than skip one app. See `ReviewsError.stopsTheRun`.
    ///
    /// `notReadyYet` is explicitly *not* fatal: one app awaiting its first report says nothing about
    /// the others, and on a portfolio where analytics was just switched on it is the normal answer
    /// for most of them.
    public var stopsTheRun: Bool {
        switch self {
        case .noKey, .notAllowedToRequest, .rateLimited, .network:
            return true
        case .notReadyYet, .restartedAfterInactivity, .http, .badResponse, .corruptSegment:
            return false
        }
    }

    /// Whether this is Apple still working, rather than something being wrong.
    ///
    /// **Only the two cases where Apple is genuinely generating qualify** — a first report, or a
    /// replacement for one Apple stopped. This is deliberately not `!stopsTheRun`. Those are two
    /// different questions: `stopsTheRun` asks whether the *other* apps are still worth trying,
    /// which is `false` for a hard HTTP error that says nothing about waiting. The panel used
    /// `!stopsTheRun` to decide what to say, so a `405 METHOD_NOT_ALLOWED` on the create-request
    /// POST was rendered as "Apple is preparing your first report — this is not an error", on every
    /// refresh, for a month, while Apple's actual message was discarded. See `ASCToken.mint` for
    /// what caused that 405.
    public var isWaitingForApple: Bool {
        switch self {
        case .notReadyYet, .restartedAfterInactivity: return true
        default: return false
        }
    }

    /// Whether pointing the user at Settings is the actual fix.
    ///
    /// A key or a role, and nothing else. Offering "Open Settings…" for a 500 or a failed checksum
    /// invites someone to go and replace credentials that are working.
    public var suggestsCheckingCredentials: Bool {
        switch self {
        case .noKey, .notAllowedToRequest:
            return true
        case .notReadyYet, .restartedAfterInactivity, .rateLimited, .http, .network, .badResponse,
             .corruptSegment:
            return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noKey:
            return "Analytics needs the reviews key — add one in Settings."
        case .notAllowedToRequest(let detail):
            let base = "That key can't start an analytics report. Apple requires an Admin key to "
                + "create the request; once it exists, a lesser key can read the results."
            guard let detail else { return base }
            return "\(base) App Store Connect said: \(detail)"
        case .notReadyYet:
            return "Apple is generating your first report. This takes a day or two, and Vantage "
                + "will pick it up on its own."
        case .restartedAfterInactivity:
            return "Apple had stopped generating this report because nothing read it for a while. "
                + "Vantage has started a new one — the first report takes another day or two. "
                + "Analytics already downloaded is unaffected."
        case .rateLimited:
            return "App Store Connect is rate limiting. Try again shortly."
        case .http(let code, let detail):
            return detail ?? "App Store Connect returned HTTP \(code)."
        case .network:
            return "Couldn't download the analytics report."
        case .badResponse:
            return "Couldn't read the analytics report App Store Connect returned."
        case .corruptSegment:
            return "An analytics report failed its checksum and was discarded."
        }
    }
}

/// Decodes the JSON:API payloads of each lifecycle step.
///
/// Pure, and separate from the client for the same reason `ReportParser` and `ReviewDecoder` are:
/// the request path and the parsing path fail independently.
public enum AnalyticsDecoder {
    public static func requests(from data: Data) -> [AnalyticsRequest] {
        rows(in: data, ofType: "analyticsReportRequests").compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let attributes = row["attributes"] as? [String: Any] ?? [:]
            return AnalyticsRequest(
                id: id,
                accessType: (attributes["accessType"] as? String) ?? "",
                stoppedDueToInactivity:
                    (attributes["stoppedDueToInactivity"] as? Bool) ?? false)
        }
    }

    /// A `POST` returns one resource under `data` rather than an array.
    public static func request(from data: Data) -> AnalyticsRequest? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = object["data"] as? [String: Any],
              row["type"] as? String == "analyticsReportRequests",
              let id = row["id"] as? String
        else { return nil }
        let attributes = row["attributes"] as? [String: Any] ?? [:]
        return AnalyticsRequest(id: id,
                                accessType: (attributes["accessType"] as? String) ?? "",
                                stoppedDueToInactivity:
                                    (attributes["stoppedDueToInactivity"] as? Bool) ?? false)
    }

    public static func reports(from data: Data) -> [AnalyticsReport] {
        rows(in: data, ofType: "analyticsReports").compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let attributes = row["attributes"] as? [String: Any] ?? [:]
            return AnalyticsReport(
                id: id,
                name: (attributes["name"] as? String) ?? "",
                // An unrecognised category is left nil rather than guessed at — Apple has added
                // categories before and will again.
                category: (attributes["category"] as? String)
                    .flatMap(AnalyticsCategory.init(rawValue:)))
        }
    }

    public static func instances(from data: Data) -> [AnalyticsInstance] {
        rows(in: data, ofType: "analyticsReportInstances").compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            let attributes = row["attributes"] as? [String: Any] ?? [:]
            return AnalyticsInstance(
                id: id,
                granularity: (attributes["granularity"] as? String) ?? "",
                processingDate: (attributes["processingDate"] as? String) ?? "")
        }
    }

    /// Segment URLs are the one place in this app that legitimately points off Apple's estate, so
    /// they are checked hard: `https`, and a host under `amazonaws.com`.
    ///
    /// A URL that fails either test is dropped rather than fetched. That costs one segment of one
    /// day's analytics; following it could cost anything.
    public static func segments(from data: Data) -> [AnalyticsSegment] {
        rows(in: data, ofType: "analyticsReportSegments").compactMap { row in
            guard let id = row["id"] as? String,
                  let attributes = row["attributes"] as? [String: Any],
                  let string = attributes["url"] as? String,
                  let url = URL(string: string),
                  isPermittedSegmentHost(url)
            else { return nil }
            return AnalyticsSegment(
                id: id,
                url: url,
                checksum: (attributes["checksum"] as? String) ?? "",
                sizeInBytes: (attributes["sizeInBytes"] as? Int) ?? 0)
        }
    }

    /// Apple's report-request IDs are UUIDs, and one is about to be interpolated into a URL path
    /// that a `DELETE` will be sent to.
    ///
    /// **Validated, never sanitized** — the same rule `ASCReviewsWriter.isWellFormedResourceID`
    /// follows, and it matters more here than anywhere: stripping the awkward characters out of a
    /// hostile value would defeat the traversal while leaving a well-formed request to delete some
    /// *other* real resource. Refusing the whole value is the only answer that can't be wrong.
    public static func isWellFormedRequestID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else { return false }
        return id.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    /// Apple hands out pre-signed S3 URLs, so the tightest honest constraint is the S3 domain — the
    /// bucket and region vary and are not documented as stable.
    ///
    /// The leading dot matters: without it `evilamazonaws.com` passes.
    public static func isPermittedSegmentHost(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".amazonaws.com")
    }

    private static func rows(in data: Data, ofType type: String) -> [[String: Any]] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else { return [] }
        return rows.filter { $0["type"] as? String == type }
    }
}
