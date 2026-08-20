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
        }
    }
}
