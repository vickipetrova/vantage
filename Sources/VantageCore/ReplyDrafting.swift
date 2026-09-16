import Foundation

/// Whether Draft can be offered, in the terms the composer needs rather than Apple's.
///
/// Apple's three unavailable reasons collapse to what the user can do about each. "Your Mac can't"
/// and "this macOS can't" are both `.hidden`, because a button that can never work is noise.
/// "Switched off" is not hidden, because the fix is one toggle away and hiding the feature would
/// keep it a secret.
public enum DraftAvailability: Equatable, Sendable {
    case available
    /// macOS before 26, a Mac that can't run Apple Intelligence, or a build made without the
    /// framework.
    case hidden
    /// Apple Intelligence is switched off in System Settings.
    case turnedOff
    /// Switched on, but the model is still downloading.
    case preparing

    public var message: String? {
        switch self {
        case .available, .hidden: return nil
        case .turnedOff: return "Turn on Apple Intelligence to draft replies."
        case .preparing: return "Apple Intelligence is still getting ready."
        }
    }
}

/// Why a draft didn't arrive, and whether trying again could change that.
///
/// `FoundationModels`' own errors are translated into these at the adapter's boundary, so nothing
/// above it needs to know which framework produced the draft.
public enum DraftError: Error, Equatable, Sendable {
    /// Guardrails, an explicit refusal, or refusal text in place of a reply.
    case declined
    case unsupportedLanguage
    /// The model answered, but with something `DraftCleanup` won't put in the editor.
    case rejected
    case unavailable(DraftAvailability)
    /// Rate limited, busy, context overflow, or anything unforeseen.
    case failed

    public var message: String {
        switch self {
        case .declined:
            return "Apple Intelligence won't draft a reply to this review. You can still write one yourself."
        case .unsupportedLanguage:
            return "Apple Intelligence can't write in this review's language yet."
        case .rejected:
            return "That draft didn't pass Vantage's checks."
        case .unavailable(let availability):
            return availability.message ?? DraftError.failed.message
        case .failed:
            return "Couldn't draft a reply just now."
        }
    }

    /// Offered only where the model's randomness could produce a different outcome. A guardrail
    /// or an unsupported language answers the same way every time, and a button that repeats the
    /// same failure is a trap.
    public var canRetry: Bool {
        switch self {
        case .rejected, .failed: return true
        case .declined, .unsupportedLanguage, .unavailable: return false
        }
    }
}
