import Foundation

/// One customer review, as Vantage stores and renders it.
///
/// Flattened from Apple's JSON:API shape on the way in — the response nests the response body in a
/// sideloaded `included` array keyed by relationship, which is a fine wire format and a poor thing
/// to carry through a view.
public struct CustomerReview: Equatable, Codable, Sendable, Identifiable {
    /// Apple's opaque resource ID. Also the id used when publishing a response.
    public let id: String
    /// The app this review belongs to. Not in Apple's payload — reviews are fetched per app, so it
    /// comes from the request rather than the response.
    public let appleID: String
    /// 1…5. Apple documents no other value; anything else is rejected at decode time rather than
    /// rendered as a row of zero stars.
    public let rating: Int
    public let title: String
    public let body: String
    public let reviewerNickname: String
    public let createdDate: Date
    /// ISO-3166 alpha-**3** here — note that the sales report uses a different form. Do not reuse a
    /// territory mapping between the two without checking.
    public let territory: String
    public let response: ReviewResponse?

    public init(id: String, appleID: String, rating: Int, title: String, body: String,
                reviewerNickname: String, createdDate: Date, territory: String,
                response: ReviewResponse?) {
        self.id = id
        self.appleID = appleID
        self.rating = rating
        self.title = title
        self.body = body
        self.reviewerNickname = reviewerNickname
        self.createdDate = createdDate
        self.territory = territory
        self.response = response
    }

    /// Decoded leniently, like `DaySales`, so a cache written by an older build stays readable
    /// instead of forcing a full refetch every time a field is added.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        appleID = try container.decode(String.self, forKey: .appleID)
        rating = try container.decode(Int.self, forKey: .rating)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        reviewerNickname = try container.decodeIfPresent(String.self, forKey: .reviewerNickname) ?? ""
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        territory = try container.decodeIfPresent(String.self, forKey: .territory) ?? ""
        response = try container.decodeIfPresent(ReviewResponse.self, forKey: .response)
    }
}

/// The developer's reply, if there is one.
public struct ReviewResponse: Equatable, Codable, Sendable {
    /// The `customerReviewResponses` resource ID — what a delete needs.
    public let id: String
    public let body: String
    public let state: State
    public let lastModifiedDate: Date

    /// Apple publishes exactly two states.
    ///
    /// `pendingPublish` is the **normal** state immediately after publishing — Apple says plainly
    /// that responses don't appear in the App Store instantly. Treating it as an error would report
    /// every successful reply as a failure.
    public enum State: String, Codable, Sendable {
        case published = "PUBLISHED"
        case pendingPublish = "PENDING_PUBLISH"

        public var label: String {
            switch self {
            case .published: return "Published"
            case .pendingPublish: return "Awaiting publication"
            }
        }
    }

    public init(id: String, body: String, state: State, lastModifiedDate: Date) {
        self.id = id
        self.body = body
        self.state = state
        self.lastModifiedDate = lastModifiedDate
    }
}

/// Decodes Apple's JSON:API payloads into `CustomerReview`.
///
/// Kept separate from the network client for the same reason `ReportParser` is: the request path
/// and the parsing path fail independently and can be debugged independently. Everything here is
/// pure and takes `Data`.
///
/// **Every field degrades.** A review whose `body` Apple omits is still a review worth showing;
/// only `id`, `rating` and `createdDate` are load-bearing, and a row missing one of those is
/// skipped rather than rendered as a blank. Same rule as the TSV parser: a malformed row costs one
/// row, not the fetch.
public enum ReviewDecoder {
    /// What one page of `GET /v1/apps/{id}/customerReviews` yields.
    public struct Page: Equatable {
        public let reviews: [CustomerReview]
        /// Apple's `links.next`, already absolute. `nil` on the last page.
        public let next: URL?
        /// Rows that couldn't be read at all, counted rather than surfaced — the same bargain
        /// `DaySales.skippedRows` makes.
        public let skipped: Int
    }

    public static func page(from data: Data, appleID: String) -> Page? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["data"] as? [[String: Any]]
        else { return nil }

        // `included` carries the sideloaded responses. Indexed by id so each review can find its
        // own without a nested scan.
        var responses: [String: ReviewResponse] = [:]
        for entry in (object["included"] as? [[String: Any]]) ?? [] {
            guard entry["type"] as? String == "customerReviewResponses",
                  let response = response(from: entry)
            else { continue }
            responses[response.id] = response
        }

        var reviews: [CustomerReview] = []
        var skipped = 0
        for row in rows {
            if let review = review(from: row, appleID: appleID, responses: responses) {
                reviews.append(review)
            } else {
                skipped += 1
            }
        }

        var next: URL?
        if let links = object["links"] as? [String: Any],
           let string = links["next"] as? String,
           let url = URL(string: string),
           // The next-page URL comes out of a response body and decides where the next authenticated
           // request goes. It must stay on Apple's API host — a redirect to anywhere else would
           // otherwise carry the bearer token with it.
           url.scheme == "https", url.host == ASCReviewsClient.host {
            next = url
        }

        return Page(reviews: reviews, next: next, skipped: skipped)
    }

    private static func review(from row: [String: Any], appleID: String,
                               responses: [String: ReviewResponse]) -> CustomerReview? {
        guard row["type"] as? String == "customerReviews",
              let id = row["id"] as? String,
              let attributes = row["attributes"] as? [String: Any],
              let rating = attributes["rating"] as? Int,
              // Apple documents 1…5 and nothing else. A 0 or a 7 means the payload isn't what we
              // think it is, and a row of zero stars would be a confident lie.
              (1...5).contains(rating),
              let created = date(attributes["createdDate"])
        else { return nil }

        // The response is linked by relationship, not embedded. A review with no reply has the
        // relationship absent entirely.
        var response: ReviewResponse?
        if let relationships = row["relationships"] as? [String: Any],
           let link = relationships["response"] as? [String: Any],
           let data = link["data"] as? [String: Any],
           let responseID = data["id"] as? String {
            response = responses[responseID]
        }

        return CustomerReview(
            id: id,
            appleID: appleID,
            rating: rating,
            title: (attributes["title"] as? String) ?? "",
            body: (attributes["body"] as? String) ?? "",
            reviewerNickname: (attributes["reviewerNickname"] as? String) ?? "",
            createdDate: created,
            territory: (attributes["territory"] as? String) ?? "",
            response: response)
    }

    /// The body of a successful `POST /v1/customerReviewResponses` — a single resource under
    /// `data`, rather than the array-plus-`included` shape a listing returns.
    public static func singleResponse(from data: Data) -> ReviewResponse? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = object["data"] as? [String: Any],
              entry["type"] as? String == "customerReviewResponses"
        else { return nil }
        return response(from: entry)
    }

    static func response(from entry: [String: Any]) -> ReviewResponse? {
        guard let id = entry["id"] as? String,
              let attributes = entry["attributes"] as? [String: Any]
        else { return nil }
        return ReviewResponse(
            id: id,
            body: (attributes["responseBody"] as? String) ?? "",
            // An unrecognised state is treated as awaiting publication rather than as published.
            // If Apple adds a third, claiming a reply is live when it isn't is the worse mistake.
            state: (attributes["state"] as? String).flatMap(ReviewResponse.State.init(rawValue:))
                ?? .pendingPublish,
            lastModifiedDate: date(attributes["lastModifiedDate"]) ?? Date(timeIntervalSince1970: 0))
    }

    /// Apple sends ISO 8601 with fractional seconds on some fields and without on others, in the
    /// same payload. Both are tried rather than assuming.
    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain = ISO8601DateFormatter()
}
