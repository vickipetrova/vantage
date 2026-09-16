import XCTest
@testable import VantageCore

/// The confirm-before-send requirement, expressed as a type and tested as one.
///
/// A sheet can be dismissed, bypassed by a keyboard shortcut, or skipped by a future refactor that
/// looks harmless. A transition that doesn't exist can't be any of those things.
final class ReplyDraftTests: XCTestCase {
    private func published(_ body: String) -> ReviewResponse {
        ReviewResponse(id: "resp-1", body: body, state: .published,
                       lastModifiedDate: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - The invariant

    /// The whole point of the type.
    func testSendingIsUnreachableWithoutConfirming() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks for the report — fixed in 1.2.")

        XCTAssertNil(draft.confirm(), "Confirming straight from editing must not produce text")
        XCTAssertEqual(draft.stage, .editing, "and must not move the draft toward sending")
    }

    func testTheOnlyRouteToSendingIsRequestThenConfirm() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")

        XCTAssertTrue(draft.requestConfirmation())
        XCTAssertEqual(draft.stage, .awaitingConfirmation)

        XCTAssertEqual(draft.confirm()?.body, "Thanks!")
        XCTAssertEqual(draft.stage, .sending)
    }

    /// Confirming twice must not produce a second send. Double-clicking Publish is not two replies.
    func testConfirmingTwiceSendsOnce() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")
        draft.requestConfirmation()

        XCTAssertEqual(draft.confirm()?.body, "Thanks!")
        XCTAssertNil(draft.confirm(), "The second confirm has nothing to send")
    }

    /// A draft awaiting confirmation shows exactly what will be published. If the text could change
    /// underneath that, the confirmation would be about something else.
    func testTextCannotChangeWhileAwaitingConfirmation() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Original")
        draft.requestConfirmation()

        draft.edit("Something else entirely")
        XCTAssertEqual(draft.text, "Original")
        XCTAssertEqual(draft.confirm()?.body, "Original")
    }

    func testTextCannotChangeWhileSending() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Original")
        draft.requestConfirmation()
        draft.confirm()

        draft.edit("Changed")
        XCTAssertEqual(draft.text, "Original")
    }

    // MARK: - Backing out

    func testCancellingConfirmationKeepsTheText() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("A considered reply")
        draft.requestConfirmation()
        draft.cancelConfirmation()

        XCTAssertEqual(draft.stage, .editing)
        XCTAssertEqual(draft.text, "A considered reply")
    }

    func testCancellingOutsideConfirmationDoesNothing() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("x")
        draft.cancelConfirmation()
        XCTAssertEqual(draft.stage, .editing)
    }

    // MARK: - Validation gates the confirmation

    /// The confirmation is never shown for text Apple would reject — the user shouldn't have to
    /// read a summary of something that can't be sent.
    func testEmptyTextCannotReachConfirmation() {
        var draft = ReplyDraft(reviewID: "review-1")
        XCTAssertFalse(draft.requestConfirmation())
        XCTAssertEqual(draft.stage, .editing)

        draft.edit("   \n\t  ")
        XCTAssertFalse(draft.requestConfirmation(), "Whitespace is not a reply")
    }

    func testOverlongTextCannotReachConfirmation() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit(String(repeating: "a", count: ReplyValidation.maxLength + 1))
        XCTAssertFalse(draft.requestConfirmation())
    }

    // MARK: - Outcomes

    func testSuccessRecordsWhetherApplePublishedItYet() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")
        draft.requestConfirmation()
        draft.confirm()
        draft.succeeded(state: .pendingPublish)
        XCTAssertEqual(draft.stage, .sent(state: .pendingPublish))
    }

    func testAFailureCanBeEditedAndRetried() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")
        draft.requestConfirmation()
        draft.confirm()
        draft.failed("App Store Connect is rate limiting.")
        XCTAssertEqual(draft.stage, .failed(message: "App Store Connect is rate limiting."))

        draft.retry()
        XCTAssertEqual(draft.stage, .editing)
        XCTAssertEqual(draft.text, "Thanks!", "The text survives so it can be fixed, not retyped")
    }

    /// An outcome may only be recorded for something actually in flight.
    func testOutcomesAreIgnoredOutsideSending() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.succeeded(state: .published)
        XCTAssertEqual(draft.stage, .editing)
        draft.failed("nope")
        XCTAssertEqual(draft.stage, .editing)
    }

    // MARK: - Guards the mutation testing found unprotected

    /// Cancelling from `.sending` would drag an in-flight reply back to editable, which is the one
    /// path that turns confirm-before-send into publish-twice.
    func testCancellingCannotPullBackAnInFlightReply() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")
        draft.requestConfirmation()
        draft.confirm()

        draft.cancelConfirmation()
        XCTAssertEqual(draft.stage, .sending)
        XCTAssertNil(draft.confirm(), "and it must still be impossible to send a second time")
    }

    /// Retrying is for failures. From `.sent` it would offer to publish again over a reply that
    /// already went out.
    func testRetryOnlyAppliesToAFailure() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")
        draft.requestConfirmation()
        draft.confirm()
        draft.succeeded(state: .published)

        draft.retry()
        XCTAssertEqual(draft.stage, .sent(state: .published))
    }

    func testRetryDoesNothingWhileEditingOrSending() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.retry()
        XCTAssertEqual(draft.stage, .editing)

        draft.edit("Thanks!")
        draft.requestConfirmation()
        draft.confirm()
        draft.retry()
        XCTAssertEqual(draft.stage, .sending)
    }

    /// `normalize` is tested on its own; that `confirm()` actually applies it was not, so the draft
    /// would have published whatever whitespace the box contained.
    func testConfirmPublishesTheNormalizedText() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("  Thanks — fixed in 1.2.\n\n  ")
        draft.requestConfirmation()
        XCTAssertEqual(draft.confirm()?.body, "Thanks — fixed in 1.2.")
    }

    /// A confirmation is bound to one review, so it can't be handed to a call that publishes it
    /// against another.
    func testTheConfirmationCarriesTheReviewItAnswers() {
        var draft = ReplyDraft(reviewID: "review-99")
        draft.edit("Thanks!")
        draft.requestConfirmation()
        XCTAssertEqual(draft.confirm()?.reviewID, "review-99")
    }

    func testTextSurvivesARoundTripThroughTheConfirmation() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("A considered reply")
        draft.requestConfirmation()
        draft.cancelConfirmation()
        draft.edit("A considered reply, revised")
        XCTAssertTrue(draft.requestConfirmation())
        XCTAssertEqual(draft.confirm()?.body, "A considered reply, revised")
    }

    // MARK: - Replacing an existing reply

    /// Apple's POST is create-or-update with no distinction, so overwriting is silent at the API
    /// level. The draft has to know, so the confirmation can say "replace" rather than "publish".
    func testADraftForAnAnsweredReviewStartsFromTheExistingReply() {
        let draft = ReplyDraft(reviewID: "review-1", existing: published("Our original reply."))
        XCTAssertTrue(draft.isReplacement)
        XCTAssertEqual(draft.text, "Our original reply.",
                       "Editing a reply starts from it, not from a blank box")
    }

    func testADraftForAnUnansweredReviewIsNotAReplacement() {
        let draft = ReplyDraft(reviewID: "review-1")
        XCTAssertFalse(draft.isReplacement)
        XCTAssertEqual(draft.text, "")
    }

    // MARK: - Drafting with Apple Intelligence

    func testADraftReplacesTheTextAndCanBeUndone() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("My own start")

        XCTAssertTrue(draft.beginDrafting())
        XCTAssertTrue(draft.applyDraft("A generated reply."))
        XCTAssertEqual(draft.text, "A generated reply.")
        XCTAssertEqual(draft.assist, .drafted(original: "My own start"))

        draft.undoDraft()
        XCTAssertEqual(draft.text, "My own start")
        XCTAssertEqual(draft.assist, .idle)
    }

    func testUndoRestoresEmptyText() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.beginDrafting()
        draft.applyDraft("A generated reply.")
        draft.undoDraft()
        XCTAssertEqual(draft.text, "")
    }

    /// Try again replaces one draft with another. Undo is for getting back to what *you* had.
    func testUndoAfterTryAgainRestoresTheOriginalNotThePreviousDraft() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Mine")
        draft.beginDrafting()
        draft.applyDraft("First draft.")
        draft.beginDrafting()
        draft.applyDraft("Second draft.")

        XCTAssertEqual(draft.text, "Second draft.")
        draft.undoDraft()
        XCTAssertEqual(draft.text, "Mine")
    }

    func testAFailedTryAgainCanStillBeUndone() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Mine")
        draft.beginDrafting()
        draft.applyDraft("First draft.")
        draft.beginDrafting()
        draft.draftFailed(.failed)

        XCTAssertEqual(draft.assist, .failed(.failed, undo: "Mine"))
        XCTAssertEqual(draft.undoText, "Mine")
        XCTAssertEqual(draft.text, "First draft.", "A failure leaves the box as it was")
        draft.undoDraft()
        XCTAssertEqual(draft.text, "Mine")
    }

    func testAFirstFailureOffersNoUndo() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Mine")
        draft.beginDrafting()
        draft.draftFailed(.declined)
        XCTAssertEqual(draft.assist, .failed(.declined, undo: nil))
        XCTAssertNil(draft.undoText)

        draft.undoDraft()
        XCTAssertEqual(draft.text, "Mine")
    }

    /// The model takes seconds. Anything typed in that time is the user's and must not be
    /// overwritten by a draft they've stopped waiting for.
    func testADraftArrivingAfterTypingIsDiscarded() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.beginDrafting()
        draft.edit("I started typing")

        XCTAssertFalse(draft.applyDraft("A generated reply."))
        XCTAssertEqual(draft.text, "I started typing")
        XCTAssertEqual(draft.assist, .idle)
    }

    /// SwiftUI writes the binding back with an unchanged value. That isn't typing.
    func testWritingTheSameTextBackIsNotAnEdit() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Same")
        draft.beginDrafting()
        draft.edit("Same")
        XCTAssertTrue(draft.applyDraft("A generated reply."))
    }

    func testEditingADraftMakesItYours() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.beginDrafting()
        draft.applyDraft("A generated reply.")
        draft.edit("A generated reply, edited.")

        XCTAssertEqual(draft.assist, .idle)
        XCTAssertNil(draft.undoText)
    }

    func testEditingClearsAFailure() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.beginDrafting()
        draft.draftFailed(.rejected)
        draft.edit("x")
        XCTAssertEqual(draft.assist, .idle)
    }

    func testDraftingCannotStartTwice() {
        var draft = ReplyDraft(reviewID: "review-1")
        XCTAssertTrue(draft.beginDrafting())
        XCTAssertFalse(draft.beginDrafting())
    }

    func testDraftingOnlyStartsWhileEditing() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")
        draft.requestConfirmation()
        XCTAssertFalse(draft.beginDrafting())
        XCTAssertEqual(draft.assist, .idle)
    }

    /// The confirmation shows exactly what will be sent. A draft landing after it opened would
    /// change the text underneath it.
    func testADraftCannotLandDuringConfirmation() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.edit("Thanks!")
        draft.beginDrafting()
        XCTAssertTrue(draft.requestConfirmation())
        XCTAssertEqual(draft.assist, .idle)

        XCTAssertFalse(draft.applyDraft("A generated reply."))
        XCTAssertEqual(draft.confirm()?.body, "Thanks!")
    }

    func testResultsAreIgnoredWhenNotDrafting() {
        var draft = ReplyDraft(reviewID: "review-1")
        XCTAssertFalse(draft.applyDraft("Out of nowhere"))
        draft.draftFailed(.failed)
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.assist, .idle)
    }

    /// The invariant, restated for the new transitions: no sequence of them publishes anything.
    func testDraftingNeverReachesSending() {
        var draft = ReplyDraft(reviewID: "review-1")
        draft.beginDrafting()
        draft.applyDraft("A generated reply.")
        draft.beginDrafting()
        draft.draftFailed(.failed)
        draft.undoDraft()
        draft.beginDrafting()
        draft.applyDraft("Another.")

        XCTAssertEqual(draft.stage, .editing)
        XCTAssertNil(draft.confirm())
    }
}

/// What can be published, and what the composer says about it while you type.
final class ReplyValidationTests: XCTestCase {
    /// An untouched box shouldn't be scolded for being empty.
    func testAnEmptyDraftIsInvalidButSaysNothing() {
        let result = ReplyValidation.check("")
        XCTAssertFalse(result.isValid)
        XCTAssertNil(result.message)
        XCTAssertEqual(result.remaining, ReplyValidation.maxLength)
    }

    func testWhitespaceOnlyIsNotAReply() {
        XCTAssertFalse(ReplyValidation.check("   \n  \t ").isValid)
    }

    func testOrdinaryTextIsValid() {
        let result = ReplyValidation.check("Thanks — this is fixed in 1.2.")
        XCTAssertTrue(result.isValid)
        XCTAssertNil(result.message)
    }

    /// Apple documents no maximum, so this is enforced here rather than discovered as a 422 after
    /// someone has written six thousand characters.
    func testTheAppStoreLimitIsEnforcedLocally() {
        let atLimit = String(repeating: "a", count: ReplyValidation.maxLength)
        XCTAssertTrue(ReplyValidation.check(atLimit).isValid)
        XCTAssertEqual(ReplyValidation.check(atLimit).remaining, 0)

        let over = String(repeating: "a", count: ReplyValidation.maxLength + 5)
        XCTAssertFalse(ReplyValidation.check(over).isValid)
        XCTAssertEqual(ReplyValidation.check(over).remaining, -5)
        XCTAssertTrue(ReplyValidation.check(over).message?.contains("5 characters too long") == true)
    }

    /// Surrounding whitespace counts toward Apple's limit and nobody means it.
    func testLengthIsMeasuredAfterTrimming() {
        let padded = "  " + String(repeating: "a", count: ReplyValidation.maxLength) + "  "
        XCTAssertTrue(ReplyValidation.check(padded).isValid)
    }

    /// Pinned as a literal, deliberately.
    ///
    /// Every other assertion here is written against `ReplyValidation.maxLength` symbolically, so
    /// changing the constant kept the whole suite green — and this number is stated as fact in both
    /// `SECURITY.md` and `docs/REVIEWS_API.md`. It is community-tested rather than published by
    /// Apple, which is all the more reason for one test to hold it still.
    func testTheLimitIsTheAppStoreFigureTheDocsQuote() {
        XCTAssertEqual(ReplyValidation.maxLength, 5_970)
    }

    func testNormalizeTrimsButLeavesTheMiddleAlone() {
        XCTAssertEqual(ReplyValidation.normalize("  a  b  "), "a  b")
    }
}
