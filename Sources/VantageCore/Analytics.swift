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
    case rateLimited
    case http(Int, detail: String?)
    case network
    case badResponse
    /// A segment's bytes didn't match the checksum Apple gave for them.
    case corruptSegment

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
