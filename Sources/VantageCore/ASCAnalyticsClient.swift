import CryptoKit
import Foundation

/// A source of App Store engagement figures.
public protocol AnalyticsProvider {
    /// - Parameter instances: how many of the newest daily instances to pull. The caller works this
    ///   out from what it already has — see `AnalyticsStore.instancesNeeded` — so that an absence
    ///   longer than a week repairs itself instead of leaving a permanent hole.
    func engagement(forApp appleID: String, instances: Int,
                    completion: @escaping (Result<[EngagementDay], Error>) -> Void)

    /// The app's `ONE_TIME_SNAPSHOT` daily instances, **oldest processing date first**, creating
    /// the snapshot request if the app has none yet.
    ///
    /// An `ONGOING` request only produces days from its own creation onwards, so the history Apple
    /// still holds is reachable no other way. A newly created snapshot answers with an empty list:
    /// Apple takes 24–48 hours to generate one, exactly as it does for the first ongoing report.
    func snapshotInstances(forApp appleID: String,
                           completion: @escaping (Result<[String], Error>) -> Void)

    /// Downloads and parses specific instances. The caller decides which, and how many.
    ///
    /// Answers with an `AnalyticsHistorySlice` rather than bare days because this walk may stop
    /// part-way — and the caller records the instances it is told completed, never the ones it
    /// asked for. See `AnalyticsHistorySlice`.
    func history(instanceIDs: [String],
                 completion: @escaping (Result<AnalyticsHistorySlice, Error>) -> Void)
}

/// Walks the Analytics Reports API's four steps and parses what falls out.
///
/// Nothing about this is one request. Ask Apple to keep generating reports for an app, list the
/// reports that request produced, list one report's instances, list an instance's segments, then
/// download each segment from a pre-signed S3 URL that expires in five minutes. See
/// `docs/ANALYTICS_API.md`.
///
/// Uses the **reviews key**, because creating the report request needs Admin and the sales key must
/// stay on its minimal role. A key that can't create one gets a specific error saying so rather than
/// a bare 403.
public struct ASCAnalyticsClient: AnalyticsProvider {
    private static let host = "api.appstoreconnect.apple.com"

    /// The fallback when a caller doesn't say how many instances it needs.
    ///
    /// Each instance is a separate segments call plus one download per segment, so this is the main
    /// lever on how much of the hourly budget analytics costs. It is **not** a ceiling any more:
    /// `AnalyticsStore.instancesNeeded` sizes each refresh to the gap since the last one, because a
    /// fixed cap here silently abandoned every day older than the cap. See that method.
    public static let defaultInstances = AnalyticsStore.openingInstances

    /// The report Vantage reads. Apple ships a Standard and a Detailed variant; Standard omits the
    /// fields that carry uniquely identifiable data, and impressions and page views are in both.
    static let reportNameFragment = "discovery and engagement"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    /// A second session for the S3 downloads, with **no default headers at all**.
    ///
    /// Kept separate so there is no path by which an `Authorization` header could reach a host
    /// outside Apple's estate. The URL is pre-signed; it needs nothing from us.
    private static let downloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [:]
        return URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    private let keyProvider: () -> ASCKey?

    public init(key: @escaping () -> ASCKey? = { KeychainStore.reviewsKey() }) {
        self.keyProvider = key
    }

    // MARK: - Entry point

    public func engagement(forApp appleID: String, instances: Int = defaultInstances,
                           completion: @escaping (Result<[EngagementDay], Error>) -> Void) {
        guard keyProvider() != nil else {
            completion(.failure(AnalyticsError.noKey))
            return
        }
        guard !appleID.isEmpty, appleID.allSatisfy({ $0.isNumber }) else {
            completion(.failure(AnalyticsError.badResponse))
            return
        }

        // Step 1: does a request already exist? Creating a second one for the same app is both
        // wasteful and, with `ONGOING`, a 409.
        get("/v1/apps/\(appleID)/analyticsReportRequests?limit=50") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                switch AnalyticsRequestDecision.decide(from: AnalyticsDecoder.requests(from: data)) {
                case .use(let id):
                    self.reports(for: id, instances: instances, completion: completion)

                case .create:
                    self.start(appleID: appleID, answering: .notReadyYet, completion: completion)

                case .restart(let dead):
                    // Apple stops generating for a request nobody reads, and will not restart one:
                    // POSTing over it is answered `409 STATE_ERROR`. The dead request has to go
                    // first. Nothing already downloaded is at risk — `AnalyticsStore` keeps its own
                    // copy, which is the whole reason it merges rather than mirrors.
                    self.delete(requestID: dead) { result in
                        switch result {
                        case .failure(let error):
                            completion(.failure(error))
                        case .success:
                            self.start(appleID: appleID, answering: .restartedAfterInactivity,
                                       completion: completion)
                        }
                    }
                }
            }
        }
    }

    /// Creates a request and reports the wait that follows, which is the only honest answer: a
    /// brand-new request has nothing behind it for 24–48 hours. Saying so is the whole difference
    /// between "working" and "broken".
    private func start(appleID: String, answering wait: AnalyticsError,
                       completion: @escaping (Result<[EngagementDay], Error>) -> Void) {
        createRequest(appleID: appleID) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success: completion(.failure(wait))
            }
        }
    }

    /// Deletes a report request. Apple lists `CREATE, DELETE, GET_INSTANCE` as this resource's
    /// operations, and 204 is the documented success.
    private func delete(requestID: String,
                        completion: @escaping (Result<Void, Error>) -> Void) {
        guard AnalyticsDecoder.isWellFormedRequestID(requestID),
              let request = signedRequest(method: "DELETE",
                                          path: "/v1/analyticsReportRequests/\(requestID)")
        else {
            completion(.failure(AnalyticsError.badResponse))
            return
        }
        Self.send(request, expecting: 204) { completion($0.map { _ in () }) }
    }

    // MARK: - Step 2: create

    private func createRequest(appleID: String, accessType: String = "ONGOING",
                               completion: @escaping (Result<AnalyticsRequest, Error>) -> Void) {
        let payload: [String: Any] = [
            "data": [
                "type": "analyticsReportRequests",
                // ONGOING for the daily chart; ONE_TIME_SNAPSHOT once per app for the history
                // that predates it. Apple accepts one of each for the same app.
                "attributes": ["accessType": accessType],
                "relationships": ["app": ["data": ["type": "apps", "id": appleID]]],
            ],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              var request = signedRequest(method: "POST", path: "/v1/analyticsReportRequests")
        else {
            completion(.failure(AnalyticsError.noKey))
            return
        }
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        Self.send(request, expecting: 201) { result in
            completion(result.flatMap { data in
                guard let data, let created = AnalyticsDecoder.request(from: data) else {
                    return .failure(AnalyticsError.badResponse)
                }
                return .success(created)
            })
        }
    }

    // MARK: - History, from a one-time snapshot

    public func snapshotInstances(forApp appleID: String,
                                  completion: @escaping (Result<[String], Error>) -> Void) {
        guard keyProvider() != nil else {
            completion(.failure(AnalyticsError.noKey))
            return
        }
        guard !appleID.isEmpty, appleID.allSatisfy({ $0.isNumber }) else {
            completion(.failure(AnalyticsError.badResponse))
            return
        }

        get("/v1/apps/\(appleID)/analyticsReportRequests?limit=50") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                switch AnalyticsSnapshotDecision.decide(from: AnalyticsDecoder.requests(from: data)) {
                case .create:
                    // Nothing to read for a day or two. Creating it is the whole point of this
                    // call on a first run; the instances arrive on a later refresh.
                    self.createRequest(appleID: appleID, accessType: "ONE_TIME_SNAPSHOT") { result in
                        completion(result.map { _ in [] })
                    }
                case .use(let requestID):
                    self.engagementReportID(for: requestID) { result in
                        switch result {
                        case .failure(let error):
                            completion(.failure(error))
                        case .success(let reportID):
                            self.get("/v1/analyticsReports/\(reportID)/instances"
                                     + "?filter[granularity]=DAILY&limit=200") { result in
                                completion(result.map { data in
                                    AnalyticsDecoder.instances(from: data)
                                        // Oldest first: the caller imports a capped bite per
                                        // refresh, and each bite should extend the history.
                                        .sorted { $0.processingDate < $1.processingDate }
                                        .map(\.id)
                                })
                            }
                        }
                    }
                }
            }
        }
    }

    public func history(instanceIDs: [String],
                        completion: @escaping (Result<AnalyticsHistorySlice, Error>) -> Void) {
        guard keyProvider() != nil else {
            completion(.failure(AnalyticsError.noKey))
            return
        }
        guard !instanceIDs.isEmpty else {
            completion(.success(AnalyticsHistorySlice(days: [], completedInstanceIDs: [])))
            return
        }
        // Same walk as a daily refresh: segments, then one pre-signed download at a time.
        let instances = instanceIDs.map {
            AnalyticsInstance(id: $0, granularity: "DAILY", processingDate: "")
        }
        collect(instances, index: 0, days: [], completed: [], completion: completion)
    }

    // MARK: - Step 3: the report

    private func reports(for requestID: String, instances: Int,
                         completion: @escaping (Result<[EngagementDay], Error>) -> Void) {
        engagementReportID(for: requestID) { result in
            switch result {
            case .failure(let error): completion(.failure(error))
            case .success(let reportID):
                self.instances(for: reportID, limit: instances, completion: completion)
            }
        }
    }

    /// The one report in the engagement category that carries impressions and page views. Shared
    /// by the daily walk and the history import, which differ only in which request they start from.
    private func engagementReportID(for requestID: String,
                                    completion: @escaping (Result<String, Error>) -> Void) {
        get("/v1/analyticsReportRequests/\(requestID)/reports"
            + "?filter[category]=APP_STORE_ENGAGEMENT&limit=200") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                // Matched on the name rather than taking the first: the engagement category holds
                // several reports, and only this one carries impressions and page views.
                guard let report = AnalyticsDecoder.reports(from: data).first(where: {
                    SegmentParser.normalize($0.name)
                        .contains(SegmentParser.normalize(Self.reportNameFragment))
                }) else {
                    completion(.failure(AnalyticsError.notReadyYet))
                    return
                }
                completion(.success(report.id))
            }
        }
    }

    // MARK: - Step 4: instances, then segments

    private func instances(for reportID: String, limit: Int,
                           completion: @escaping (Result<[EngagementDay], Error>) -> Void) {
        get("/v1/analyticsReports/\(reportID)/instances"
            + "?filter[granularity]=DAILY&limit=200") { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(let data):
                let instances = AnalyticsDecoder.instances(from: data)
                    .sorted { $0.processingDate > $1.processingDate }
                    .prefix(max(1, limit))
                guard !instances.isEmpty else {
                    completion(.failure(AnalyticsError.notReadyYet))
                    return
                }
                // The daily walk has no use for which instances finished — it re-asks for the
                // newest few every refresh anyway. Only the history import records them.
                self.collect(Array(instances), index: 0, days: [], completed: []) { result in
                    completion(result.map(\.days))
                }
            }
        }
    }

    /// One instance at a time. Sequential for the same reason `Backfill` is: a burst is the fastest
    /// route to a 429, and these URLs expire five minutes after they're handed out — so fetching
    /// segment lists far ahead of the downloads would guarantee some of them go stale.
    ///
    /// `completed` carries the instances that fully landed — segments listed **and** every segment
    /// downloaded. It is what the history import records, and recording anything more would freeze
    /// a day that was never actually read.
    private func collect(_ instances: [AnalyticsInstance], index: Int, days: [EngagementDay],
                         completed: [String],
                         completion: @escaping (Result<AnalyticsHistorySlice, Error>) -> Void) {
        func slice() -> AnalyticsHistorySlice {
            AnalyticsHistorySlice(days: EngagementMerge.merge(days), completedInstanceIDs: completed)
        }
        guard index < instances.count else {
            completion(.success(slice()))
            return
        }
        get("/v1/analyticsReportInstances/\(instances[index].id)/segments?limit=200") { result in
            switch result {
            case .failure(let error):
                // Partial data beats none: whatever downloaded already is still true. Nothing at
                // all is a plain failure — there is no partial truth to report.
                if days.isEmpty && completed.isEmpty {
                    completion(.failure(error))
                } else {
                    completion(.success(slice()))
                }
            case .success(let data):
                let segments = AnalyticsDecoder.segments(from: data)
                self.download(segments, index: 0, days: days, whole: true) { collected, whole in
                    // An instance that lost a segment is *not* completed: asking again next refresh
                    // costs one instance, and not asking loses that day for good.
                    self.collect(instances, index: index + 1, days: collected,
                                 completed: whole ? completed + [instances[index].id] : completed,
                                 completion: completion)
                }
            }
        }
    }

    /// - Parameter whole: whether every segment so far downloaded, checksummed and parsed. Handed
    ///   back so `collect` can tell a complete instance from a partial one.
    private func download(_ segments: [AnalyticsSegment], index: Int, days: [EngagementDay],
                          whole: Bool,
                          completion: @escaping ([EngagementDay], Bool) -> Void) {
        guard index < segments.count else {
            completion(days, whole)
            return
        }
        let segment = segments[index]
        Self.downloadSession.dataTask(with: segment.url) { data, response, _ in
            var collected = days
            var whole = whole
            if let data,
               (response as? HTTPURLResponse)?.statusCode == 200,
               Self.matchesChecksum(data, segment.checksum),
               let inflated = try? Gunzip.decompress(data),
               let text = String(data: inflated, encoding: .utf8) {
                collected += SegmentParser.parse(text).days
            } else {
                whole = false
            }
            // A segment that fails costs that segment. Apple splits one instance across several,
            // and losing one shouldn't discard the rest of the day.
            self.download(segments, index: index + 1, days: collected, whole: whole,
                          completion: completion)
        }.resume()
    }

    /// Apple publishes an MD5 for each segment. Weak as a hash, but it's what's offered, and it
    /// catches the truncated download — which is the failure this actually guards against.
    static func matchesChecksum(_ data: Data, _ expected: String) -> Bool {
        guard !expected.isEmpty else { return true }
        let digest = Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return digest.caseInsensitiveCompare(expected) == .orderedSame
    }

    // MARK: - Plumbing

    private func signedRequest(method: String, path: String) -> URLRequest? {
        guard let key = keyProvider(),
              let url = URL(string: "https://\(Self.host)\(path)"),
              let token = try? ASCToken.mint(key: key, method: method, path: path)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func get(_ path: String, completion: @escaping (Result<Data, Error>) -> Void) {
        guard let request = signedRequest(method: "GET", path: path) else {
            completion(.failure(AnalyticsError.noKey))
            return
        }
        Self.send(request, expecting: 200) { result in
            completion(result.flatMap { data in
                guard let data else { return .failure(AnalyticsError.badResponse) }
                return .success(data)
            })
        }
    }

    private static func send(_ request: URLRequest, expecting success: Int,
                             completion: @escaping (Result<Data?, Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(AnalyticsError.network))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(AnalyticsError.badResponse))
                return
            }
            let detail = data.flatMap { ASCErrorBody.summary(from: $0, redacting: "") }

            switch http.statusCode {
            case success:
                completion(.success(data))
            case 401, 403:
                completion(.failure(AnalyticsError.notAllowedToRequest(detail: detail)))
            case 404:
                completion(.failure(AnalyticsError.notReadyYet))
            case 409:
                // A request for this app already exists. Harmless, and the next refresh finds it.
                completion(.failure(AnalyticsError.notReadyYet))
            case 429:
                completion(.failure(AnalyticsError.rateLimited))
            default:
                completion(.failure(AnalyticsError.http(http.statusCode, detail: detail)))
            }
        }.resume()
    }
}

/// Merges days that arrive from several segments and several instances.
public enum EngagementMerge {
    /// Sums duplicates rather than letting the last one win.
    ///
    /// Apple splits one day across multiple segments, and consecutive instances legitimately repeat
    /// a date as late data lands — so both "add" and "replace" are wrong in some case. Summing
    /// within a refresh is right because each segment holds a distinct slice; **replacing** across
    /// refreshes is right because a later instance supersedes an earlier one, and that is
    /// `AnalyticsStore`'s job rather than this one's.
    public static func merge(_ days: [EngagementDay]) -> [EngagementDay] {
        var impressions: [ReportDate: Decimal] = [:]
        var pageViews: [ReportDate: Decimal] = [:]
        for day in days {
            impressions[day.date, default: 0] += day.impressions
            pageViews[day.date, default: 0] += day.pageViews
        }
        return impressions.keys.sorted().map {
            EngagementDay(date: $0, impressions: impressions[$0] ?? 0,
                          pageViews: pageViews[$0] ?? 0)
        }
    }
}
