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
        VStack(alignment: .leading, spacing: 0) {
            if appleID == nil { header }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.row) {
                    content
                }
                .padding(Theme.Space.section)
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear { model.loadReviews() }
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
    private var content: some View {
        if !model.hasReviewsKey {
            NoReviewsKeyCard(onSettings: model.onSettings)
        } else if let error = model.reviewsError {
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
            ForEach(reviews) { review in
                ReviewCard(model: model, review: review,
                           appTitle: appleID == nil ? model.titleForApp(review.appleID) : nil)
            }
        }
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
                 + "them behind a different role. Add a second App Store Connect key with at least "
                 + "the App Manager role.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings…") { onSettings?() }
                .controlSize(.small)
        }
        .card()
    }
}
