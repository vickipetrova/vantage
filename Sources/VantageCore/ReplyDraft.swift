import Foundation

/// A reply being written, as a state machine.
///
/// **This type is where "never send without an explicit confirm" is enforced.** Not by a sheet, not
/// by a convention in a view — by the fact that `.sending` is reachable from exactly one state, and
/// that state is only entered by the user asking to publish. A view can't skip a step it has no
/// transition for, and the invariant is testable without standing up any UI.
///
/// The stakes are why: a reply is published to the App Store under the developer's name, visible to
/// everyone, and Apple's `POST` is create-*or-update* with no distinction — so an accidental send
/// can silently overwrite a reply that was already there.
public struct ReplyDraft: Equatable {
    public enum Stage: Equatable {
        /// Being typed. The only state the text can change in.
        case editing
        /// The user asked to publish and is looking at exactly what will be sent.
        case awaitingConfirmation
        /// In flight. Reachable **only** from `.awaitingConfirmation`.
        case sending
        case sent(state: ReviewResponse.State)
        case failed(message: String)
    }

    public private(set) var stage: Stage
    public private(set) var text: String
    /// The reply already published, if any. Its presence changes the confirmation from "publish" to
    /// "replace", which is the difference between adding a reply and overwriting one.
    public let existing: ReviewResponse?

    public init(existing: ReviewResponse? = nil) {
        self.existing = existing
        self.text = existing?.body ?? ""
        self.stage = .editing
    }

    public var isReplacement: Bool { existing != nil }

    /// Whether the text is publishable. Not the same as whether it may be sent — see `confirm()`.
    public var validation: ReplyValidation.Result { ReplyValidation.check(text) }

    // MARK: - Transitions

    /// Text may only change while editing. A draft awaiting confirmation shows exactly what will be
    /// sent, and letting it change underneath that would make the confirmation meaningless.
    public mutating func edit(_ newText: String) {
        guard stage == .editing else { return }
        text = newText
    }

    /// Step one of two. Refuses invalid text, so the confirmation is never shown for something that
    /// would be rejected on arrival.
    @discardableResult
    public mutating func requestConfirmation() -> Bool {
        guard stage == .editing, validation.isValid else { return false }
        stage = .awaitingConfirmation
        return true
    }

    /// Step two of two, and **the only way into `.sending`**.
    ///
    /// Returns the text to publish, or nil when the draft isn't awaiting confirmation — which is
    /// what makes "send without confirming" un-expressible rather than merely discouraged.
    @discardableResult
    public mutating func confirm() -> String? {
        guard stage == .awaitingConfirmation else { return nil }
        stage = .sending
        return ReplyValidation.normalize(text)
    }

    /// Backing out of the confirmation returns to editing with the text intact.
    public mutating func cancelConfirmation() {
        guard stage == .awaitingConfirmation else { return }
        stage = .editing
    }

    public mutating func succeeded(state: ReviewResponse.State) {
        guard stage == .sending else { return }
        stage = .sent(state: state)
    }

    public mutating func failed(_ message: String) {
        guard stage == .sending else { return }
        stage = .failed(message: message)
    }

    /// After a failure, back to editing so the text can be fixed and tried again.
    public mutating func retry() {
        guard case .failed = stage else { return }
        stage = .editing
    }
}

/// What makes a reply publishable.
public enum ReplyValidation {
    /// The App Store's own limit. Apple documents no maximum for `responseBody`, so this is
    /// enforced client-side — discovering it as a 422 after the user has written 6,000 characters
    /// is a worse way to find out.
    public static let maxLength = 5_970

    public struct Result: Equatable {
        public let isValid: Bool
        /// What's wrong, or nil when nothing is. Also nil for an untouched empty draft — telling
        /// someone their reply is empty before they've typed anything is nagging, not help.
        public let message: String?
        public let remaining: Int
    }

    /// Trailing whitespace is trimmed before sending, because it counts toward Apple's limit and
    /// nobody means it.
    public static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func check(_ text: String) -> Result {
        let normalized = normalize(text)
        let remaining = maxLength - normalized.count

        if normalized.isEmpty {
            return Result(isValid: false, message: nil, remaining: maxLength)
        }
        if remaining < 0 {
            return Result(isValid: false,
                          message: "\(-remaining) character\(remaining == -1 ? "" : "s") too long. "
                            + "The App Store allows \(maxLength).",
                          remaining: remaining)
        }
        return Result(isValid: true, message: nil, remaining: remaining)
    }
}
