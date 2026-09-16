import SwiftUI
import VantageCore

/// One app, at the days currently selected on the Overview.
///
/// Shares the time window with Overview on purpose: clicking into an app while looking at a week
/// in March and landing on yesterday would silently change the question being asked.
struct AppDetailView: View {
    @ObservedObject var model: PanelModel
    let appleID: String

    private var detail: AppDetailModel {
        AppDetailModel.build(appleID: appleID, days: model.days, rates: model.rates,
                             error: model.error, metrics: model.metrics,
                             displayCurrency: Prefs.displayCurrency, span: model.span)
    }

    var body: some View {
        let detail = self.detail
        VStack(alignment: .leading, spacing: 0) {
            header(detail)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.section) {
                    if let notFound = detail.notFound {
                        Footnote(text: notFound).card()
                    } else {
                        VStack(alignment: .leading, spacing: Theme.Space.row) {
                            TimeControls(model: model)
                            if let headline = detail.summary.headline {
                                HeadlineCard(headline: headline)
                            }
                        }
                        TrendCard(model: model, appleID: appleID)
                        reviews
                        VStack(alignment: .leading, spacing: Theme.Space.tight) {
                            ForEach(detail.summary.footnotes, id: \.self) { Footnote(text: $0) }
                        }
                    }
                }
                .padding(Theme.Space.section)
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Header

    private func header(_ detail: AppDetailModel) -> some View {
        HStack(spacing: Theme.Space.row) {
            BackButton { model.navigate(to: .overview) }
            AppIconView(icon: model.icons[appleID], side: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(detail.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: Theme.Space.tight) {
                    if let listing = model.listings[appleID],
                       let average = listing.averageRating {
                        Text("★ \(Fmt.rating(average))")
                            .monospacedDigit()
                        if let count = listing.ratingCount {
                            Text("· \(Fmt.downloads(Decimal(count))) ratings")
                                .monospacedDigit()
                        }
                        Text("·")
                    }
                    Text("Apple ID \(detail.appleID)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.section)
        .padding(.vertical, Theme.Space.card)
        .onAppear {
            model.loadIconIfNeeded(appleID)
            model.loadListingIfNeeded(appleID)
            model.loadReviews()
        }
    }

    // MARK: - Cards

    /// This app's reviews, inline. Same cards as the Reviews section, without the app name on each
    /// one — it would repeat the header on every card.
    @ViewBuilder
    private var reviews: some View {
        let reviews = model.reviews[appleID] ?? []
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            SectionHeader("Reviews")
            if !model.hasReviewsKey {
                Footnote(text: "Add a reviews key in Settings to see reviews for this app.")
            } else if let error = model.reviewsError {
                Footnote(text: (error as? ReviewsError)?.errorDescription
                         ?? "Couldn't load reviews.")
            } else if reviews.isEmpty {
                Footnote(text: model.isLoadingReviews
                         ? "Loading reviews…" : "No reviews for this app yet.")
            } else {
                ForEach(reviews.prefix(5)) { review in
                    ReviewCard(model: model, review: review, appTitle: nil)
                }
                if reviews.count > 5 {
                    Button("See all \(reviews.count) reviews") { model.navigate(to: .reviews) }
                        .controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Back

private struct BackButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.08 : 0.04))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Back to Overview")
        .accessibilityLabel("Back to Overview")
    }
}
