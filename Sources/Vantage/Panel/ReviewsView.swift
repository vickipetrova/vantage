import SwiftUI
import VantageCore

/// Recent customer reviews across the portfolio.
struct ReviewsView: View {
    @ObservedObject var model: PanelModel
    /// `nil` shows the whole portfolio; an Apple ID shows one app's.
    var appleID: String?

    @State private var minimumRating: Int = 0
    @State private var onlyUnanswered = false

    private var reviews: [CustomerReview] {
        let base = appleID.map { model.reviews[$0] ?? [] } ?? model.allReviews
        return base.filter { review in
            (minimumRating == 0 || review.rating <= minimumRating)
                && (!onlyUnanswered || review.response == nil)
        }
    }

    var body: some View {
        // Read once. As a computed property this ran twice per body pass, and each run sorted every
        // cached review in the portfolio — which the reply composer triggers on every keystroke.
        let reviews = self.reviews
        VStack(alignment: .leading, spacing: 0) {
            if appleID == nil { header }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.row) {
                    content(reviews)
                }
                .padding(Theme.Space.section)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            model.loadReviews()
            // The same lookup that supplies each icon, so the rating costs nothing extra.
            for id in appleID.map({ [$0] }) ?? model.reviewableAppleIDs {
                model.loadListingIfNeeded(id)
                model.loadIconIfNeeded(id)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Space.row) {
            Text("Reviews")
                .font(.system(size: 15, weight: .semibold))
            if model.isLoadingReviews {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
            Spacer(minLength: 0)
            filters
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.card)
    }

    private var filters: some View {
        HStack(spacing: Theme.Space.tight) {
            Menu {
                Button { minimumRating = 0 } label: { label("All ratings", on: minimumRating == 0) }
                ForEach([1, 2, 3, 4], id: \.self) { rating in
                    Button { minimumRating = rating } label: {
                        label("\(rating) star\(rating == 1 ? "" : "s") and below",
                              on: minimumRating == rating)
                    }
                }
            } label: {
                Text(minimumRating == 0 ? "All ratings" : "≤ \(minimumRating)★")
                    .font(.system(size: 10, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Toggle("Unanswered", isOn: $onlyUnanswered)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
        }
    }

    @ViewBuilder
    private func label(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    // MARK: - Content

    @ViewBuilder
    private func content(_ reviews: [CustomerReview]) -> some View {
        if !model.hasReviewsKey {
            NoReviewsKeyCard(onSettings: model.onSettings)
        } else if let error = model.reviewsError, reviews.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.row) {
                Text((error as? ReviewsError)?.errorDescription ?? "Couldn't load reviews.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings…") { model.onSettings?() }
                    .controlSize(.small)
            }
            .card()
        } else if reviews.isEmpty {
            Footnote(text: model.isLoadingReviews
                     ? "Loading reviews…"
                     : "No reviews match. Apple only returns reviews written on the App Store.")
                .card()
        } else {
            RatingsStrip(model: model, appleID: appleID)
            // A refresh that failed while there is still something cached is a warning above the
            // list, never instead of it. Replacing what somebody is reading with an error card
            // loses the data they came for, and it's still right there in memory.
            if let error = model.reviewsError {
                WarningRow(text: (error as? ReviewsError)?.errorDescription
                           ?? "Couldn't refresh reviews.")
            }
            LazyVStack(alignment: .leading, spacing: Theme.Space.row) {
                ForEach(reviews) { review in
                    ReviewCard(model: model, review: review,
                               appTitle: appleID == nil ? model.titleForApp(review.appleID) : nil)
                }
            }
        }
    }
}

/// Each app's App Store rating, above its reviews.
///
/// The reviews below are the ones people wrote; this is the number everyone else sees. Both come
/// from Apple, neither is derived from the other, and showing an average computed from the fifty
/// reviews Vantage happens to have fetched would be a different — and wrong — number.
private struct RatingsStrip: View {
    @ObservedObject var model: PanelModel
    let appleID: String?

    private var ids: [String] {
        (appleID.map { [$0] } ?? model.reviewableAppleIDs)
            .filter { model.listings[$0]?.averageRating != nil }
    }

    var body: some View {
        if !ids.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                SectionHeader("App Store rating")
                ForEach(ids, id: \.self) { id in
                    if let listing = model.listings[id] {
                        RatingRow(title: model.titleForApp(id),
                                  icon: model.icons[id],
                                  listing: listing)
                    }
                }
            }
            .card()
        }
    }
}

private struct RatingRow: View {
    let title: String
    let icon: NSImage?
    let listing: AppListing

    var body: some View {
        HStack(spacing: Theme.Space.row) {
            AppIconView(icon: icon, side: 22)
            Text(title).lineLimit(1)
            Spacer(minLength: Theme.Space.tight)
            if let average = listing.averageRating {
                // Rounded for the stars, exact beside them — five stars can't show 4.7, and
                // rounding is the only honest way to draw it, so the number says what it really is.
                RatingStars(rating: Int(NSDecimalNumber(decimal: average).rounding(
                    accordingToBehavior: NSDecimalNumberHandler(
                        roundingMode: .plain, scale: 0, raiseOnExactness: false,
                        raiseOnOverflow: false, raiseOnUnderflow: false,
                        raiseOnDivideByZero: false)).intValue))
                Text(Fmt.rating(average))
                    .font(.callout)
                    .monospacedDigit()
            }
            if let count = listing.ratingCount {
                Text("(\(Fmt.downloads(Decimal(count))))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .font(.callout)
    }
}

/// The empty state before a reviews key exists.
///
/// Not an error — it's the expected condition for anyone who only wanted sales. It says what the key
/// is for and, deliberately, that it is a *second* key rather than the one already configured.
private struct NoReviewsKeyCard: View {
    let onSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Text("Reviews need their own key")
                .font(.system(size: 13, weight: .semibold))
            Text("The Sales and Reports key Vantage already has can't read reviews — Apple gates "
                 + "them behind a different role. Add a second key with at least the App Manager "
                 + "role under Settings › Reviews & Analytics. The same key powers Analytics.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…") { onSettings?() }
                .controlSize(.small)
        }
        .card()
    }
}
