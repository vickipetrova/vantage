import SwiftUI
import VantageCore

/// Writing a reply, and confirming it before it goes anywhere.
///
/// The two-step flow isn't enforced here — it's enforced by `ReplyDraft`, which has no transition
/// from editing to sending. This view can only offer the steps that exist.
struct ReplyComposer: View {
    let review: CustomerReview
    @Binding var draft: ReplyDraft
    let draftAvailability: DraftAvailability
    let onPublish: () -> Void
    let onCancel: () -> Void
    let onDraft: () -> Void
    let onUndoDraft: () -> Void
    let onOpenAppleIntelligenceSettings: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            switch draft.stage {
            case .editing:
                editor
            case .awaitingConfirmation:
                ConfirmSheet(review: review, draft: draft,
                             onPublish: onPublish,
                             onBack: { draft.cancelConfirmation() })
            case .sending:
                HStack(spacing: Theme.Space.tight) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Publishing…").font(.caption).foregroundColor(.secondary)
                }
            case .sent(let state):
                sent(state)
            case .failed(let message):
                failed(message)
            }
        }
    }

    // MARK: - Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            // TextField(axis:) is macOS 13, which is the floor — a multi-line box without needing
            // NSViewRepresentable around NSTextView.
            TextField(draft.isReplacement ? "Edit your reply" : "Write a reply",
                      text: Binding(get: { draft.text }, set: { draft.edit($0) }),
                      axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...8)
                .focused($isFocused)

            assistStatus

            HStack(spacing: Theme.Space.tight) {
                if draft.assist == .idle, draftAvailability != .hidden {
                    Button(action: onDraft) {
                        Label("Draft", systemImage: "sparkles")
                    }
                    .controlSize(.small)
                    .disabled(draftAvailability == .preparing)
                    .help("Draft a reply using Apple Intelligence on this Mac")
                }
                if let message = draft.validation.message {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if draft.validation.remaining < 500 {
                    // Only near the ceiling. A counter that's always there is noise for the 99% of
                    // replies nowhere near 5,970 characters.
                    Text("\(draft.validation.remaining) characters left")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                // "Review…" not "Publish": this button opens the confirmation, and a button that
                // says Publish but doesn't publish is exactly the ambiguity this flow exists to
                // remove.
                Button(draft.isReplacement ? "Review replacement…" : "Review reply…") {
                    draft.requestConfirmation()
                }
                .controlSize(.small)
                .disabled(!draft.validation.isValid)
            }
        }
        .onAppear { isFocused = true }
    }

    /// Drafting progress, the "drafted" disclosure, or why drafting didn't work. Empty when idle and
    /// available, so a composer nobody drafts in looks exactly as it did.
    @ViewBuilder
    private var assistStatus: some View {
        switch draft.assist {
        case .idle:
            if draftAvailability == .preparing, let message = draftAvailability.message {
                Text(message).font(.caption).foregroundColor(.secondary)
            }
        case .drafting:
            HStack(spacing: Theme.Space.tight) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Drafting…").font(.caption).foregroundColor(.secondary)
            }
        case .drafted:
            HStack(spacing: Theme.Space.tight) {
                // Apple's guidance: say where AI was used, and that it can be wrong.
                Text("Drafted with Apple Intelligence. Check it before publishing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Undo", action: onUndoDraft).buttonStyle(.link).font(.caption)
                Button("Try again", action: onDraft).buttonStyle(.link).font(.caption)
            }
        case .failed(let error, let undo):
            HStack(spacing: Theme.Space.tight) {
                Text(error.message)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if error == .unavailable(.turnedOff) {
                    Button("Open Settings", action: onOpenAppleIntelligenceSettings)
                        .buttonStyle(.link).font(.caption)
                }
                if undo != nil {
                    Button("Undo", action: onUndoDraft).buttonStyle(.link).font(.caption)
                }
                if error.canRetry {
                    Button("Try again", action: onDraft).buttonStyle(.link).font(.caption)
                }
            }
        }
    }

    // MARK: - Outcomes

    private func sent(_ state: ReviewResponse.State) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(draft.isReplacement ? "Reply replaced" : "Reply published",
                  systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.secondary)
            if state == .pendingPublish {
                // Apple says plainly that responses don't appear in the App Store instantly. Saying
                // so here stops the next thirty minutes looking like a failure.
                Text("Apple doesn't publish replies instantly — it may take a while to appear.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(message)
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).controlSize(.small)
                Button("Edit and try again") { draft.retry() }.controlSize(.small)
            }
        }
    }
}

/// The last thing between a draft and the App Store.
///
/// Shows the exact text that will be published, says who will see it, and — when there's already a
/// reply — shows what is about to be overwritten. Apple's `POST` is create-or-update with no
/// distinction, so a replacement is silent at the API level and has to be loud here.
struct ConfirmSheet: View {
    let review: CustomerReview
    let draft: ReplyDraft
    let onPublish: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.row) {
            Label(draft.isReplacement ? "Replace your published reply?" : "Publish this reply?",
                  systemImage: "exclamationmark.bubble")
                .font(.system(size: 12, weight: .semibold))

            Text("This will appear on the App Store under your developer name, publicly, next to "
                 + "the review by \(review.reviewerNickname.isEmpty ? "this customer" : review.reviewerNickname).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let existing = draft.existing {
                LabelledBlock(title: "Replacing", text: existing.body, muted: true)
            }
            LabelledBlock(title: draft.isReplacement ? "With" : "Your reply",
                          text: ReplyValidation.normalize(draft.text), muted: false)

            HStack {
                Spacer(minLength: 0)
                Button("Back", action: onBack).controlSize(.small)
                // Named for what it does. Never "OK".
                Button(draft.isReplacement ? "Replace reply" : "Publish reply", action: onPublish)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.card)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}

private struct LabelledBlock: View {
    let title: String
    let text: String
    let muted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            Text(text)
                .font(.callout)
                .foregroundColor(muted ? .secondary : .primary)
                .strikethrough(muted)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
