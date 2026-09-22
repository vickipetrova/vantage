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

    /// Whether the failure on screen names a field worth returning to.
    ///
    /// False for a network drop, a rate limit, a bad report, and an agreement 403 — none of which
    /// are fixed by editing a credential. `SalesError.likelyStep` decides; this is the view's
    /// question about the same answer.
    var canFixFromFailure: Bool {
        if case .failed(_, let step) = testState { return step != nil }
        return false
    }

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
        // `back()` defends itself; so must this. A transition while a request is in flight leaves
        // testState and flow.step disagreeing, and the completion then mutates a screen the user left.
        guard testState != .running else { return }
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

    /// Fresh state for a re-opened wizard.
    ///
    /// `SetupWindow` calls this only when the previous run finished (`flow.isComplete`) — "Run
    /// setup again…" is the only route back in once setup is marked done, and it must not land on
    /// the same Done screen with Done as its only control. A wizard the user merely *closed*
    /// mid-flow is a different case and must not call this: reopening it should resume where they
    /// left off, not throw away what they typed.
    func reset() {
        flow = SetupFlow()
        testState = .idle
        pendingPrivateKey = nil
        pendingReviewsPrivateKey = nil
        keyFileStatus = nil
        keyFileStatusIsError = false
        reviewsMissingFields = []
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
                // The raw `.p8` text has done its job — it's in the Keychain — and has no reason
                // to keep living in process memory for the rest of the session. Not cleared until
                // here: `keyFileLoaded` still reads `pendingPrivateKey` for the "Loaded" badge if
                // the user goes Back from a *failure* to re-choose the file.
                self.pendingPrivateKey = nil
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
    ///
    /// Does nothing when the failure names no field — a network drop, a rate limit, a bad report,
    /// or an agreement 403 aren't fixed by editing a credential, and sending the user to re-edit a
    /// value that was already correct is exactly what `likelyStep` returning `nil` exists to
    /// prevent. `canFixFromFailure` is how the view knows not to offer this button at all.
    func retryFromFailure() {
        guard case .failed(_, let target) = testState, let target else { return }
        testState = .idle
        flow.goTo(target)
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
        let privateKeyChosen = pendingReviewsPrivateKey != nil
        if let pendingReviewsPrivateKey {
            KeychainStore.set(pendingReviewsPrivateKey, for: .reviewsPrivateKey)
        }
        // Same reasoning as the sales key: the raw text has been written, so it doesn't need to
        // keep living in process memory for the rest of the session. The reviews step has no
        // failure screen to return to, so there's no "Loaded" badge that still needs it.
        pendingReviewsPrivateKey = nil
        // "Save and finish" never blocks, so a value can still be missing after this — `flow`
        // already knows which of the three it wrote, without touching the Keychain to find out.
        reviewsMissingFields = flow.missingReviewsFields(privateKeyChosen: privateKeyChosen)
        onReviewsKeyChanged?()
    }

    /// Which of the three reviews values `saveReviewsKey()` couldn't write, if it has run.
    /// Empty when the user declined the reviews key, and empty again after `reset()`.
    @Published private(set) var reviewsMissingFields: [KeychainStore.Key] = []

    /// True once the user has chosen to set up a reviews key but "Save and finish" landed on the
    /// Done screen with one of the three values still missing — nothing else tells them.
    var reviewsKeyIncomplete: Bool { !reviewsMissingFields.isEmpty }

    /// The Done screen's extra line, naming what's still missing and where to finish it. `nil`
    /// when there's nothing to say — the common case.
    var reviewsKeyIncompleteMessage: String? {
        guard reviewsKeyIncomplete else { return nil }
        let names = reviewsMissingFields.map(SettingsModel.label).joined(separator: ", ")
        return "The reviews key is missing \(names). Finish it in Settings › Reviews & Analytics."
    }
}
