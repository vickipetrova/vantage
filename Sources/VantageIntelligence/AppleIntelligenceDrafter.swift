import Foundation
import VantageCore
#if canImport(FoundationModels)
import FoundationModels
import Observation
import NaturalLanguage
#endif

/// The drafter for this Mac, or nil where there can't be one: a build without the framework, or
/// macOS before 26. The app asks this instead of carrying `#available` checks of its own.
///
/// The framework is weak-linked (verified with `otool -l`: `LC_LOAD_WEAK_DYLIB`), so the app still
/// launches on macOS 13–15, where it doesn't exist.
public func makeReplyDrafter() -> ReplyDrafter? {
    #if canImport(FoundationModels)
    if #available(macOS 26, *) { return AppleIntelligenceDrafter() }
    #endif
    return nil
}

#if canImport(FoundationModels)
/// Apple's on-device model behind `ReplyDrafter`.
///
/// **No network, ever.** `SystemLanguageModel` runs on this Mac. Private Cloud Compute is a
/// different type and is deliberately not used.
///
/// Lenient guardrails because one-star reviews are often angry, and the default guardrails throw on
/// exactly the reviews that most need an answer. With `String` output that mode returns a refusal
/// instead of throwing, which `DraftCleanup` recognises. Nothing drafted is published without the
/// confirmation sheet.
@available(macOS 26, *)
final class AppleIntelligenceDrafter: ReplyDrafter {
    static let maximumResponseTokens = 400

    private let model = SystemLanguageModel(useCase: .general,
                                            guardrails: .permissiveContentTransformations)
    private let lock = NSLock()
    /// A session prewarmed for one request, used by the next draft of that request and then dropped.
    private var warm: (request: DraftRequest, session: LanguageModelSession)?

    var availability: DraftAvailability { Self.map(model.availability) }

    func prewarm(_ request: DraftRequest) {
        guard availability == .available else { return }
        let session = LanguageModelSession(model: model, instructions: Self.instructions(for: request))
        session.prewarm(promptPrefix: Prompt(request.prompt))
        lock.withLock { warm = (request, session) }
    }

    func draft(_ request: DraftRequest) async throws -> String {
        // A new session per draft: no history, so Try again isn't steered by the draft it replaces.
        let session: LanguageModelSession = lock.withLock {
            defer { warm = nil }
            if let warm, warm.request == request { return warm.session }
            return LanguageModelSession(model: model, instructions: Self.instructions(for: request))
        }
        do {
            let response = try await session.respond(
                to: request.prompt,
                options: GenerationOptions(maximumResponseTokens: Self.maximumResponseTokens))
            return response.content
        } catch let error as LanguageModelSession.GenerationError {
            throw Self.map(error)
        }
    }

    func observeAvailability(_ onChange: @escaping () -> Void) {
        withObservationTracking {
            _ = model.availability
        } onChange: { [weak self] in
            // Fires once, before the value changes. Hop, then read and re-register.
            DispatchQueue.main.async {
                onChange()
                self?.observeAvailability(onChange)
            }
        }
    }

    // MARK: - Language, decided in code rather than left to the model

    /// `ReplyPrompt` already asks for a reply "in the same language as the review", but that line
    /// alone wasn't enough: a German or Japanese review came back in English in evaluation. This
    /// detects the review's language from `request.prompt` — never `instructions`, which is ours —
    /// and appends one line naming it when it isn't English, which the model follows far more
    /// reliably than the generic instruction on its own.
    static func instructions(for request: DraftRequest) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(request.prompt)
        guard let language = recognizer.dominantLanguage, language != .english,
              let name = Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
        else { return request.instructions }
        return request.instructions + "\nThe review is written in \(name). Write the reply in \(name)."
    }

    // MARK: - Mapping, at the boundary

    static func map(_ availability: SystemLanguageModel.Availability) -> DraftAvailability {
        switch availability {
        case .available:
            return .available
        case .unavailable(.appleIntelligenceNotEnabled):
            return .turnedOff
        case .unavailable(.modelNotReady):
            return .preparing
        case .unavailable:
            // deviceNotEligible, and any reason a later macOS adds.
            return .hidden
        }
    }

    static func map(_ error: LanguageModelSession.GenerationError) -> DraftError {
        switch error {
        case .guardrailViolation, .refusal:
            return .declined
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .assetsUnavailable:
            return .unavailable(.preparing)
        default:
            // rateLimited, concurrentRequests, exceededContextWindowSize, decodingFailure,
            // unsupportedGuide, and anything added later.
            return .failed
        }
    }
}
#endif
