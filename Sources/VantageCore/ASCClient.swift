import CryptoKit
import Foundation

/// The App Store Connect half: mint a JWT, ask for one day's Summary Sales report, decompress it.
///
/// Nothing here logs a credential, a token, or a URL containing the vendor number. Error cases are
/// deliberately coarse (`SalesError`) so that nothing Apple returns in a body can end up rendered
/// in the menu or pasted into a GitHub issue.
///
/// `SalesProvider` conformance lands with `ReportParser` in Phase 3; until then the useful entry
/// point is `fetchTSV`, which is also what the network path is debugged through.
public struct ASCClient {
    public let name = "App Store Connect"

    private static let host = "api.appstoreconnect.apple.com"

    /// Ephemeral: no response of yours is written to a URL cache on disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Where credentials come from. Injectable so tests can drive the request builder without
    /// touching the real Keychain.
    private let credentialsProvider: () -> Credentials?

    public init(credentials: @escaping () -> Credentials? = { KeychainStore.credentials() }) {
        self.credentialsProvider = credentials
    }

    // MARK: - Fetch

    /// The raw decompressed report, or nil when Apple has no report for that date.
    ///
    /// Kept separate from the eventual `fetch` so the network path and the parsing path fail
    /// independently and can be debugged independently.
    public func fetchTSV(_ date: ReportDate,
                         completion: @escaping (Result<String?, Error>) -> Void) {
        guard let credentials = credentialsProvider() else {
            completion(.failure(SalesError.noCredentials))
            return
        }

        let query = Self.query(vendorNumber: credentials.vendorNumber, date: date)
        guard let url = URL(string: "https://\(Self.host)/v1/salesReports?\(query)"),
              let token = try? Self.token(for: credentials, path: "/v1/salesReports?\(query)")
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
                completion(.failure(SalesError.unauthorized))
            case 403:
                completion(.failure(SalesError.forbidden))
            case 429:
                completion(.failure(SalesError.rateLimited))
            default:
                completion(.failure(SalesError.http(http.statusCode)))
            }
        }.resume()
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

    // MARK: - The token

    /// How long a minted token stays valid. Apple rejects anything over 20 minutes for this
    /// endpoint; five is plenty for a batch of at most thirty requests and limits what a leaked
    /// token is worth.
    static let tokenLifetime: TimeInterval = 5 * 60

    /// Mints an ES256 JWT for one request.
    ///
    /// `path` is the exact path and query the token will be used against, so the `scope` claim
    /// matches. Scope is optional in Apple's spec; setting it means a token that escapes somehow
    /// can fetch one report for one day and nothing else — not, say, the whole account.
    static func token(for credentials: Credentials, path: String,
                      now: Date = Date()) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        let header: [String: Any] = [
            "alg": "ES256",
            "kid": credentials.keyID,
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "iss": credentials.issuerID,
            "iat": issuedAt,
            "exp": issuedAt + Int(tokenLifetime),
            "aud": "appstoreconnect-v1",
            "scope": ["GET \(path)"],
        ]

        let signingInput = try base64URL(json: header) + "." + base64URL(json: payload)
        let key = try P256.Signing.PrivateKey(pemRepresentation: credentials.privateKey)
        // JWS wants the raw r‖s pair, 64 bytes. `derRepresentation` is the other encoding and is
        // silently accepted by nothing.
        let signature = try key.signature(for: Data(signingInput.utf8)).rawRepresentation
        return signingInput + "." + base64URL(signature)
    }

    private static func base64URL(json object: [String: Any]) throws -> String {
        // `.sortedKeys` only so the same input produces the same token, which makes the signing
        // path testable. Apple doesn't care about key order.
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
