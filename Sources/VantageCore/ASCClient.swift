import Foundation

/// The App Store Connect half: mint a JWT, ask for one day's Summary Sales report, decompress it.
///
/// Nothing here logs a credential, a token, or a URL containing the vendor number. Error cases are
/// deliberately coarse (`SalesError`) so that nothing Apple returns in a body can end up rendered
/// in the menu or pasted into a GitHub issue.
///
public struct ASCClient: SalesProvider {
    public let name = "App Store Connect"

    private static let host = "api.appstoreconnect.apple.com"

    /// Ephemeral, so no report of yours is written to a URL cache on disk, and redirect-refusing,
    /// so the bearer token cannot be forwarded to a host this app never named.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    /// Where credentials come from. Injectable so tests can drive the request builder without
    /// touching the real Keychain.
    private let credentialsProvider: () -> Credentials?

    public init(credentials: @escaping () -> Credentials? = { KeychainStore.credentials() }) {
        self.credentialsProvider = credentials
    }

    // MARK: - Fetch

    public func fetch(_ date: ReportDate, completion: @escaping (Result<DaySales?, Error>) -> Void) {
        fetchTSV(date) { result in
            completion(result.map { tsv in
                tsv.map { ReportParser.parse($0, date: date, fetchedAt: Date()) }
            })
        }
    }

    /// The raw decompressed report, or nil when Apple has no report for that date.
    ///
    /// Kept separate from `fetch` so the network path and the parsing path fail independently and
    /// can be debugged independently.
    public func fetchTSV(_ date: ReportDate,
                         completion: @escaping (Result<String?, Error>) -> Void) {
        guard let credentials = credentialsProvider() else {
            completion(.failure(SalesError.noCredentials))
            return
        }

        let query = Self.query(vendorNumber: credentials.vendorNumber, date: date)
        guard let url = URL(string: "https://\(Self.host)/v1/salesReports?\(query)"),
              let token = try? ASCToken.mint(key: credentials.key, method: "GET",
                                             path: "/v1/salesReports?\(query)")
        else {
            completion(.failure(SalesError.noCredentials))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // No Accept header on purpose. This endpoint has a history of answering 406 to
        // `application/a-gzip`, and the body is self-identifying: gzip starts 1f 8b, an error
        // starts '{'. Sniffing beats negotiating.

        Self.session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(SalesError.network))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(SalesError.badReport))
                return
            }

            switch http.statusCode {
            case 200:
                guard Gunzip.isGzip(data),
                      let inflated = try? Gunzip.decompress(data),
                      let text = String(data: inflated, encoding: .utf8)
                else {
                    completion(.failure(SalesError.badReport))
                    return
                }
                completion(.success(text))

            case 404:
                // Undocumented, and ambiguous: either the report isn't published yet, or the day
                // genuinely had no units and Apple never generated one. Answering "no report"
                // and letting the scheduler decide by the clock is the only honest split.
                // See docs/REPORT_FORMAT.md.
                completion(.success(nil))

            case 401:
                completion(.failure(SalesError.unauthorized(detail: detail(data, credentials))))
            case 403:
                completion(.failure(SalesError.forbidden(detail: detail(data, credentials))))
            case 429:
                completion(.failure(SalesError.rateLimited))
            default:
                completion(.failure(SalesError.http(http.statusCode,
                                                    detail: detail(data, credentials))))
            }
        }.resume()
    }

    /// Apple's explanation for a refusal, with the vendor number taken out of it.
    private func detail(_ data: Data, _ credentials: Credentials) -> String? {
        ASCErrorBody.summary(from: data, redacting: credentials.vendorNumber)
    }

    // MARK: - The request

    /// Built by hand rather than with `URLComponents` so the string used in the URL and the string
    /// embedded in the token's `scope` claim are identical by construction. Apple's own examples
    /// leave the brackets unencoded, and a scope that doesn't match the request byte for byte is
    /// rejected.
    static func query(vendorNumber: String, date: ReportDate) -> String {
        [
            "filter[frequency]=DAILY",
            "filter[reportType]=SALES",
            "filter[reportSubType]=SUMMARY",
            "filter[vendorNumber]=\(vendorNumber)",
            "filter[reportDate]=\(date.apiString)",
            "filter[version]=1_0",
        ].joined(separator: "&")
    }

}
