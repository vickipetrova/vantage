import Foundation

/// A source of customer reviews, so the panel never learns where they come from.
///
/// Mirrors `SalesProvider`. Read-only **by design**: publishing a reply is a separate protocol, so a
/// type that can only read cannot accidentally be handed a write. See the note on `ReviewsWriter`
/// when that lands.
public protocol ReviewsProvider {
    /// Newest first. `limit` caps how many are fetched across all pages.
    func reviews(forApp appleID: String, limit: Int,
                 completion: @escaping (Result<[CustomerReview], Error>) -> Void)
}

/// Publishing and deleting replies.
///
/// **A separate protocol from `ReviewsProvider` on purpose.** A type that can only read cannot be
/// handed a write by mistake, and a caller that only needs to read can be given something with no
/// write methods on it at all. The separation costs one protocol and removes a whole class of
/// accident from a code path that publishes text to the App Store under the developer's name.
///
/// Nothing conforms to this until replies are enabled — see `Prefs.repliesEnabled` and the consent
/// step in Settings. Replying requires an Admin key in practice; see `docs/REVIEWS_API.md`.
public protocol ReviewsWriter {
    /// `POST /v1/customerReviewResponses`. Apple's endpoint is create-**or-update** with no
    /// distinction, so this silently replaces an existing reply.
    ///
    /// Takes a `ConfirmedReply` rather than a review ID and a string, so it cannot be called with
    /// text the user hasn't confirmed — that value can only come from `ReplyDraft.confirm()`.
    func publishResponse(_ reply: ConfirmedReply,
                         completion: @escaping (Result<ReviewResponse, Error>) -> Void)

    /// `DELETE /v1/customerReviewResponses/{id}`.
    func deleteResponse(responseID: String,
                        completion: @escaping (Result<Void, Error>) -> Void)
}

/// Everything that can go wrong fetching reviews, in the words the panel will show.
///
/// Its own type rather than a `SalesError` case. "No reviews key" and "no App Store Connect key" are
/// different problems with different fixes, and one error enum covering both would inevitably tell
/// somebody to re-enter credentials that are already correct.
public enum ReviewsError: LocalizedError, Equatable {
    /// No reviews key configured. Not a failure — the expected state until someone adds one.
    case noKey
    case unauthorized
    /// The key works but isn't allowed to read reviews. Almost always the role.
    case forbidden(detail: String?)
    case rateLimited
    case http(Int, detail: String?)
    case network
    case badResponse
    /// A write refused on role grounds. Distinct from `.forbidden` because the fix is different and
    /// much bigger: reading needs App Manager, replying needs Admin.
    case notAllowedToReply(detail: String?)
    /// Apple accepted the request and refused the content — 409 or 422.
    case rejected(detail: String?)

    public var errorDescription: String? {
        switch self {
        case .noKey:
            return "Reviews need their own App Store Connect key — add one in Settings."
        case .unauthorized:
            return "App Store Connect rejected the reviews key. Check the Issuer ID, Key ID and "
                + ".p8 file — all three have to come from the same key."
        case .forbidden(let detail):
            // The role is the overwhelmingly likely cause, and Apple's own message doesn't say so.
            // Naming the minimum role is the one useful thing to add.
            let base = "That key isn't allowed to read reviews. It needs at least the App Manager "
                + "role — the Sales and Reports role can't see them."
            guard let detail else { return base }
            return "\(base) App Store Connect said: \(detail)"
        case .rateLimited:
            return "App Store Connect is rate limiting. Try again shortly."
        case .http(let code, let detail):
            return detail ?? "App Store Connect returned HTTP \(code)."
        case .network:
            return "Can't reach api.appstoreconnect.apple.com."
        case .badResponse:
            return "Couldn't read the reviews App Store Connect returned."
        case .notAllowedToReply(let detail):
            // Apple's own message doesn't name the role, and the obvious guess — App Manager, which
            // is what reading needs — is the wrong one. See docs/REVIEWS_API.md.
            let base = "That key isn't allowed to reply. Replying needs an Admin key; the App "
                + "Manager role can read reviews but not answer them."
            guard let detail else { return base }
            return "\(base) App Store Connect said: \(detail)"
        case .rejected(let detail):
            return detail ?? "App Store Connect wouldn't accept that reply."
        }
    }
}
