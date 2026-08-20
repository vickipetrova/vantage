import Foundation

/// Reads customer reviews from App Store Connect.
///
/// Same host and the same redirect-refusing session as `ASCClient`, but a **different key**: the
/// sales key can't see reviews, and this one is never used for sales. Each client is handed its own
/// credentials closure, so that separation is structural rather than a convention.
///
/// There is no portfolio-wide reviews endpoint. Reviews are per app, so a whole-portfolio view is
/// one request per app — which is why fetching happens when the section is opened rather than on
/// the background poll timer.
public struct ASCReviewsClient: ReviewsProvider {
    static let host = "api.appstoreconnect.apple.com"

    /// Apple's documented maximum for this endpoint.
    static let pageLimit = 200

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: NoRedirects.shared, delegateQueue: nil)
    }()

    private let keyProvider: () -> ASCKey?

    public init(key: @escaping () -> ASCKey? = { KeychainStore.reviewsKey() }) {
        self.keyProvider = key
    }

    // MARK: - Fetch

    public func reviews(forApp appleID: String, limit: Int = 50,
                        completion: @escaping (Result<[CustomerReview], Error>) -> Void) {
        guard keyProvider() != nil else {
            completion(.failure(ReviewsError.noKey))
            return
        }
        guard let url = Self.firstPageURL(appleID: appleID, limit: limit) else {
            completion(.failure(ReviewsError.badResponse))
            return
        }
        fetchPage(url, appleID: appleID, limit: limit, collected: [], completion: completion)
    }

    /// Walks `links.next` until the limit is reached or Apple stops offering one.
    private func fetchPage(_ url: URL, appleID: String, limit: Int,
                           collected: [CustomerReview],
                           completion: @escaping (Result<[CustomerReview], Error>) -> Void) {
        guard let key = keyProvider() else {
            completion(.failure(ReviewsError.noKey))
            return
        }
        // The scope claim must match the request byte for byte, including the query — and each page
        // is a different query, so each page gets its own token.
        let path = url.path + (url.query.map { "?\($0)" } ?? "")
        guard let token = try? ASCToken.mint(key: key, method: "GET", path: path) else {
            completion(.failure(ReviewsError.noKey))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        Self.session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(ReviewsError.network))
                return
            }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(ReviewsError.badResponse))
                return
            }

            switch http.statusCode {
            case 200:
                guard let page = ReviewDecoder.page(from: data, appleID: appleID) else {
                    completion(.failure(ReviewsError.badResponse))
                    return
                }
                let total = collected + page.reviews
                // Stop at the limit even when Apple offers another page: a portfolio-wide view is
                // already one request per app, and an app with ten thousand reviews would otherwise
                // spend the whole hourly budget on its own history.
                if let next = page.next, total.count < limit {
                    fetchPage(next, appleID: appleID, limit: limit, collected: total,
                              completion: completion)
                } else {
                    completion(.success(Array(total.prefix(limit))))
                }

            case 401:
                completion(.failure(ReviewsError.unauthorized))
            case 403:
                completion(.failure(ReviewsError.forbidden(detail: Self.detail(data))))
            case 429:
                completion(.failure(ReviewsError.rateLimited))
            default:
                completion(.failure(ReviewsError.http(http.statusCode, detail: Self.detail(data))))
            }
        }.resume()
    }

    // MARK: - The request

    /// Built by hand rather than with `URLComponents`, exactly as the sales query is, so the string
    /// in the URL and the string in the token's `scope` claim are identical by construction.
    static func firstPageURL(appleID: String, limit: Int) -> URL? {
        // Digits only, **validated rather than sanitized**: the Apple ID arrives from a parsed TSV
        // and is about to become part of a URL path. Filtering non-digits out would turn
        // "../../v1/users" into "1" — traversal defeated, but now silently requesting a different
        // real app's reviews. Refusing the whole value is the only answer that can't be wrong.
        guard !appleID.isEmpty, appleID.allSatisfy({ $0.isNumber }) else { return nil }
        let safe = appleID
        let query = [
            "limit=\(min(limit, pageLimit))",
            // Newest first. The panel shows recent reviews; page one should be the useful one.
            "sort=-createdDate",
            // Sideloads the developer's reply so an existing response doesn't cost a request each.
            "include=response",
            "fields[customerReviews]=rating,title,body,reviewerNickname,createdDate,territory,response",
        ].joined(separator: "&")
        return URL(string: "https://\(host)/v1/apps/\(safe)/customerReviews?\(query)")
    }

    /// Apple's explanation for a refusal.
    ///
    /// No vendor number to redact here — the reviews endpoints don't take one — but the same length
    /// cap and URL-stripping apply, because anything shown in the panel can end up in a screenshot.
    private static func detail(_ data: Data) -> String? {
        ASCErrorBody.summary(from: data, redacting: "")
    }
}
