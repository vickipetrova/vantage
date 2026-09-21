import AppKit
import Combine
import VantageCore

/// What the setup wizard shows and does.
///
/// The view is dumb, as everywhere else: it renders these properties and calls these methods. The
/// order, the copy and the shape notes all come from `SetupFlow` in Core; this type adds the three
/// things Core can't have — the Keychain, an `NSOpenPanel`, and one real request.
///
/// **Nothing is written to the Keychain until `saveAndTest()`.** A wizard closed at step three
/// leaves nothing behind, which is both the tidier and the more private answer. The `.p8` is held
/// in memory between choosing it and saving, and is never rendered.
final class SetupModel: ObservableObject {
    /// How the one real request is going.
    enum TestState: Equatable {
        case idle
        case running
        case succeeded
        /// The message is already written for the user; `step` is where Back should land, if
        /// anywhere.
        case failed(message: String, step: SetupStep?)
    }

    // MARK: - Callbacks

    /// Sales credentials were saved, so the app can start fetching.
    var onCredentialsChanged: (() -> Void)?
    /// The reviews key was saved, so the panel can drop a stale "no key" state.
    var onReviewsKeyChanged: (() -> Void)?
    /// The last screen was reached. The window closes.
    var onFinished: (() -> Void)?
    /// Skip was pressed. The window closes and Settings opens.
    var onSkipped: (() -> Void)?
    /// One real request, injected so this type knows nothing about App Store Connect.
    var testConnection: ((@escaping (Result<Void, Error>) -> Void) -> Void)?

    // MARK: - State

    @Published private(set) var flow = SetupFlow()
    @Published private(set) var testState: TestState = .idle

    /// Held between choosing the file and `saveAndTest()`. Never published, never rendered.
    private var pendingPrivateKey: String?
    private var pendingReviewsPrivateKey: String?
    /// Whatever the picker last said, good or bad.
    @Published private(set) var keyFileStatus: String?
    @Published private(set) var keyFileStatusIsError = false

    var step: SetupStep { flow.step }
    var note: CredentialShape.Note { flow.note }
    var canGoBack: Bool { flow.canGoBack && testState != .running }
    var link: SetupLink? { step.link }

    /// "Step 3 of 5", or nothing on the three outcome screens.
    var progressLabel: String? {
        guard let progress = step.progress else { return nil }
        return "Step \(progress.index) of \(progress.total)"
    }

    /// Whether this step's `.p8` has been chosen yet.
    var keyFileLoaded: Bool {
        switch step {
        case .privateKey: return pendingPrivateKey != nil
        case .reviewsPrivateKey: return pendingReviewsPrivateKey != nil
        default: return false
        }
    }

    /// The current step's typed value. The view binds straight to this.
    var fieldText: String {
        get { step.field.map { flow.value(for: $0) } ?? "" }
        set {
            guard let field = step.field else { return }
            flow.setValue(newValue, for: field)
        }
    }

    // MARK: - Moving

    func advance() {
        // Leaving the four sales values behind is the moment to write them.
        if step == .vendorNumber {
            flow.advance()
            saveAndTest()
            return
        }
        // Same for the three optional ones.
        if step == .reviewsPrivateKey {
            saveReviewsKey()
            flow.advance()
            finish()
            return
        }
        flow.advance()
        clearStepStatus()
    }

    func back() {
        guard canGoBack else { return }
        flow.back()
        clearStepStatus()
    }

    func chooseReviews(_ wanted: Bool) {
        flow.chooseReviews(wanted)
        flow.advance()
        clearStepStatus()
        if flow.isComplete { finish() }
    }

    /// The user would rather paste the values into Settings themselves. Respected permanently —
    /// the wizard never opens by itself again.
    func skip() {
        Prefs.setupCompleted = true
        onSkipped?()
    }

    func finish() {
        Prefs.setupCompleted = true
        onFinished?()
    }

    func open(_ link: SetupLink) {
        NSWorkspace.shared.open(link.url)
    }

    private func clearStepStatus() {
        keyFileStatus = nil
        keyFileStatusIsError = false
        if testState != .running { testState = .idle }
    }

    // MARK: - The .p8

    func chooseKeyFile() {
        switch PrivateKeyFile.choose() {
        case .chosen(let contents):
            if step == .reviewsPrivateKey {
                pendingReviewsPrivateKey = contents
            } else {
                pendingPrivateKey = contents
            }
            keyFileStatus = "Key loaded."
            keyFileStatusIsError = false
        case .cancelled:
            keyFileStatus = nil
            keyFileStatusIsError = false
        case .failed(let message):
            keyFileStatus = message
            keyFileStatusIsError = true
        }
    }

    // MARK: - Saving and testing

    /// Writes the four sales values, then makes one real request.
    ///
    /// Save first, test second, in that order and with no button between them: the sequence was
    /// the thing nothing disclosed in the old form, where Save and Test sat side by side as peers
    /// and pressing the wrong one first produced a correct error about an undisclosed rule.
    private func saveAndTest() {
        for (key, value) in flow.salesValues {
            KeychainStore.set(value, for: key)
        }
        if let pendingPrivateKey { KeychainStore.set(pendingPrivateKey, for: .privateKey) }
        onCredentialsChanged?()

        testState = .running
        testConnection? { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.testState = .succeeded
                // Straight on to the offer; a success screen with a Continue button is a click
                // that asks nothing.
                self.flow.advance()
            case .failure(let error):
                let sales = error as? SalesError
                self.testState = .failed(
                    message: sales?.errorDescription ?? "Couldn't reach App Store Connect.",
                    step: sales?.likelyStep)
            }
        }
    }

    /// Back from a failure, to the field Apple's error implicates.
    func retryFromFailure() {
        guard case .failed(_, let target) = testState else { return }
        testState = .idle
        flow.goTo(target ?? .vendorNumber)
    }

    /// Tries the same four values again, for a failure that wasn't about the values.
    func testAgain() {
        flow.goTo(.saveAndTest)
        saveAndTest()
    }

    private func saveReviewsKey() {
        for (key, value) in flow.reviewsValues {
            KeychainStore.set(value, for: key)
        }
        if let pendingReviewsPrivateKey {
            KeychainStore.set(pendingReviewsPrivateKey, for: .reviewsPrivateKey)
        }
        onReviewsKeyChanged?()
    }
}
