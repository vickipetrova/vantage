import SwiftUI
import VantageCore

/// One review, and the reply to it if there is one.
struct ReviewCard: View {
    @ObservedObject var model: PanelModel
    let review: CustomerReview
    /// Shown on the portfolio-wide list, omitted on an app's own page where it would repeat the
    /// header on every card.
    let appTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(spacing: Theme.Space.tight) {
                RatingStars(rating: review.rating)
                if let appTitle {
                    Text(appTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.tight)
                Text(Fmt.reviewDate(review.createdDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !review.title.isEmpty {
                Text(review.title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !review.body.isEmpty {
                Text(review.body)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    // Long reviews are long. Truncating loses the complaint; the panel scrolls.
                    .textSelection(.enabled)
            }

            HStack(spacing: Theme.Space.tight) {
                if !review.reviewerNickname.isEmpty {
                    Text(review.reviewerNickname)
                }
                if !review.territory.isEmpty {
                    Text("·")
                    Text(review.territory)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if let response = review.response {
                ResponseBlock(response: response,
                              canDelete: model.repliesEnabled && model.drafts[review.id] == nil,
                              isDeleting: model.deletingReplies.contains(review.id),
                              onDelete: {
                                  model.deleteReply(to: review.id, responseID: response.id)
                              })
            }

            if let draft = model.drafts[review.id] {
                ReplyComposer(
                    review: review,
                    draft: Binding(
                        get: { draft },
                        set: { new in model.updateDraft(review.id) { $0 = new } }),
                    onPublish: { model.publishReply(to: review.id) },
                    onCancel: { model.cancelReply(to: review.id) })
                    .padding(.top, 2)
            } else if model.repliesEnabled {
                HStack {
                    Spacer(minLength: 0)
                    Button(review.response == nil ? "Reply" : "Edit reply") {
                        model.beginReply(to: review)
                    }
                    .controlSize(.small)
                }
            }
        }
        .card()
    }
}

/// The developer's published reply.
private struct ResponseBlock: View {
    let response: ReviewResponse
    let canDelete: Bool
    let isDeleting: Bool
    let onDelete: () -> Void

    /// Deleting is a second click, never the first. It removes something published under the
    /// developer's name, and Apple gives nothing back to undo it with.
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 9))
                Text("Your reply")
                    .font(.system(size: 10, weight: .semibold))
                // PENDING_PUBLISH is the normal state right after replying — Apple says responses
                // don't appear in the App Store instantly — so it's stated plainly rather than
                // styled as a warning.
                if response.state == .pendingPublish {
                    Text("· \(response.state.label)")
                        .font(.system(size: 10))
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.secondary)

            Text(response.body)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if isDeleting {
                Text("Removing…").font(.caption).foregroundColor(.secondary)
            } else if confirming {
                HStack(spacing: Theme.Space.tight) {
                    Text("Remove this reply from the App Store?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("Keep it") { confirming = false }.controlSize(.small)
                    // Named for what it does, and only reachable from the confirmation.
                    Button("Remove reply") {
                        confirming = false
                        onDelete()
                    }
                    .controlSize(.small)
                }
                .padding(.top, 2)
            } else if canDelete {
                HStack {
                    Spacer(minLength: 0)
                    Button("Delete reply…") { confirming = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(.leading, Theme.Space.row)
        .padding(.top, 2)
        // A leading rule rather than a nested card: the reply belongs to the review above it, and a
        // second card inside the first reads as a second review.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 2)
        }
    }
}

/// A rating, as filled and empty stars.
struct RatingStars: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { position in
                Image(systemName: position <= rating ? "star.fill" : "star")
                    .font(.system(size: 9))
                    // Not red for one star and green for five. A rating is what somebody said, not
                    // a status, and colouring it editorialises a list you're meant to read.
                    .foregroundColor(position <= rating ? .secondary : Color.secondary.opacity(0.35))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(rating) out of 5 stars")
    }
}
