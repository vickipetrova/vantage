import Foundation

/// Publishes and deletes replies to customer reviews.
///
/// **A separate type from `ASCReviewsClient`, not a second role on it.** Swift can't make a
/// conformance conditional on how a value was constructed, so the only way to keep "a reader cannot
/// be handed a write" true by construction is for the write capability to live in a type that
/// simply isn't created unless replies are switched on. `PanelModel` holds this as an optional and
/// leaves it nil whenever `Prefs.repliesEnabled` is false or no key exists.
///
/// Everything this does is public and permanent-ish: a reply appears on the App Store under the
/// developer's name. The confirmation that guards it is `ReplyDraft`'s — and `publishResponse`
/// takes a `ConfirmedReply`, which only `ReplyDraft.confirm()` can produce, so "the user has seen
/// this exact text" is a property of the argument rather than an assumption about the caller.
public struct ASCReviewsWriter: ReviewsWriter {
    private static let host = "api.appstoreconnect.apple.com"
    private static let path = "/v1/customerReviewResponses"

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

    // MARK: - Publish

    /// Apple's endpoint is create-**or-update**: posting for a review that already has a response
    /// replaces it, with no separate route and no indication in the response that anything was
    /// overwritten. The caller must have confirmed a replacement explicitly — see `ReplyDraft`.
    public func publishResponse(_ reply: ConfirmedReply,
                                completion: @escaping (Result<ReviewResponse, Error>) -> Void) {
        let payload: [String: Any] = [
            "data": [
                "type": "customerReviewResponses",
                "attributes": ["responseBody": reply.body],
                "relationships": [
                    "review": ["data": ["type": "customerReviews", "id": reply.reviewID]],
                ],
            ],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              var request = Self.request(method: "POST", path: Self.path, key: keyProvider())
        else {
            completion(.failure(ReviewsError.noKey))
            return
        }
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        Self.send(request, expecting: 201) { result in
            completion(result.flatMap { data in
                guard let data, let response = ReviewDecoder.singleResponse(from: data) else {
                    // The reply may well have been published — Apple returned 201 — so this must
                    // not read as "nothing happened". A refresh will show the truth.
                    return .failure(ReviewsError.badResponse)
                }
                return .success(response)
            })
        }
    }

    // MARK: - Delete

    public func deleteResponse(responseID: String,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        // **Validated, not encoded.** An earlier version percent-encoded this with
        // `.urlPathAllowed`, which is the character set for a whole *path* — it permits `/` and `.`
        // and leaves "x/../../v1/apps/123" byte-identical. That turns a DELETE carrying an
        // Admin-role token into a request against a different endpoint once a gateway normalizes
        // the path, and the `scope` claim would be minted for the un-normalized path, so it
        // wouldn't necessarily catch it either.
        //
        // The ID comes from a response body (`included[].id`), which this codebase already treats
        // as untrusted — it is why `links.next` is host-checked. Apple's resource IDs are
        // base64url-shaped, so anything outside that alphabet is refused outright, the same answer
        // `firstPageURL` and both disk caches give.
        guard Self.isWellFormedResourceID(responseID),
              let request = Self.request(method: "DELETE", path: "\(Self.path)/\(responseID)",
                                         key: keyProvider())
        else {
            completion(.failure(ReviewsError.noKey))
            return
        }

        Self.send(request, expecting: 204) { result in
            completion(result.map { _ in () })
        }
    }

    /// Apple's opaque resource IDs are base64url: letters, digits, `-`, `.`, `_`, `~`.
    ///
    /// Refusing the whole value is the only answer that can't be wrong — sanitizing would defeat a
    /// traversal while silently addressing some *other* real resource.
    static func isWellFormedResourceID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 256 else { return false }
        return id.allSatisfy { character in
            character.isLetter || character.isNumber || "-._~".contains(character)
        }
    }

    // MARK: - Plumbing

    private static func request(method: String, path: String, key: ASCKey?) -> URLRequest? {
        guard let key,
              let url = URL(string: "https://\(host)\(path)"),
              // Scope carries the method, so a token minted for this POST cannot be replayed as
              // anything else — including a DELETE of the same resource.
              let token = try? ASCToken.mint(key: key, method: method, path: path)
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func send(_ request: URLRequest, expecting success: Int,
                             completion: @escaping (Result<Data?, Error>) -> Void) {
        session.dataTask(with: request) { data, response, error in
            if error != nil {
                completion(.failure(ReviewsError.network))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(ReviewsError.badResponse))
                return
            }
            let detail = data.flatMap { ASCErrorBody.summary(from: $0, redacting: "") }

            switch http.statusCode {
            case success:
                completion(.success(data))
            case 401:
                completion(.failure(ReviewsError.unauthorized))
            case 403:
                // The overwhelmingly likely cause is the role: App Manager can read reviews and
                // cannot answer them. See docs/REVIEWS_API.md.
                completion(.failure(ReviewsError.notAllowedToReply(detail: detail)))
            case 404:
                completion(.failure(ReviewsError.rejected(
                    detail: "That reply no longer exists — it may have been removed already.")))
            case 409, 422:
                completion(.failure(ReviewsError.rejected(detail: detail)))
            case 429:
                completion(.failure(ReviewsError.rateLimited))
            default:
                completion(.failure(ReviewsError.http(http.statusCode, detail: detail)))
            }
        }.resume()
    }
}
