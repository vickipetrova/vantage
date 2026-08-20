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
        var draft = ReplyDraft()
        draft.edit("Thanks for the report — fixed in 1.2.")

        XCTAssertNil(draft.confirm(), "Confirming straight from editing must not produce text")
        XCTAssertEqual(draft.stage, .editing, "and must not move the draft toward sending")
    }

    func testTheOnlyRouteToSendingIsRequestThenConfirm() {
        var draft = ReplyDraft()
        draft.edit("Thanks!")

        XCTAssertTrue(draft.requestConfirmation())
        XCTAssertEqual(draft.stage, .awaitingConfirmation)

        XCTAssertEqual(draft.confirm(), "Thanks!")
        XCTAssertEqual(draft.stage, .sending)
    }

    /// Confirming twice must not produce a second send. Double-clicking Publish is not two replies.
    func testConfirmingTwiceSendsOnce() {
        var draft = ReplyDraft()
        draft.edit("Thanks!")
        draft.requestConfirmation()

        XCTAssertEqual(draft.confirm(), "Thanks!")
        XCTAssertNil(draft.confirm(), "The second confirm has nothing to send")
    }

    /// A draft awaiting confirmation shows exactly what will be published. If the text could change
    /// underneath that, the confirmation would be about something else.
    func testTextCannotChangeWhileAwaitingConfirmation() {
        var draft = ReplyDraft()
        draft.edit("Original")
        draft.requestConfirmation()

        draft.edit("Something else entirely")
        XCTAssertEqual(draft.text, "Original")
        XCTAssertEqual(draft.confirm(), "Original")
    }

    func testTextCannotChangeWhileSending() {
        var draft = ReplyDraft()
        draft.edit("Original")
        draft.requestConfirmation()
        draft.confirm()

        draft.edit("Changed")
        XCTAssertEqual(draft.text, "Original")
    }

    // MARK: - Backing out

    func testCancellingConfirmationKeepsTheText() {
        var draft = ReplyDraft()
        draft.edit("A considered reply")
        draft.requestConfirmation()
        draft.cancelConfirmation()

        XCTAssertEqual(draft.stage, .editing)
        XCTAssertEqual(draft.text, "A considered reply")
    }

    func testCancellingOutsideConfirmationDoesNothing() {
        var draft = ReplyDraft()
        draft.edit("x")
        draft.cancelConfirmation()
        XCTAssertEqual(draft.stage, .editing)
    }

    // MARK: - Validation gates the confirmation

    /// The confirmation is never shown for text Apple would reject — the user shouldn't have to
    /// read a summary of something that can't be sent.
    func testEmptyTextCannotReachConfirmation() {
        var draft = ReplyDraft()
        XCTAssertFalse(draft.requestConfirmation())
        XCTAssertEqual(draft.stage, .editing)

        draft.edit("   \n\t  ")
        XCTAssertFalse(draft.requestConfirmation(), "Whitespace is not a reply")
    }

    func testOverlongTextCannotReachConfirmation() {
        var draft = ReplyDraft()
        draft.edit(String(repeating: "a", count: ReplyValidation.maxLength + 1))
        XCTAssertFalse(draft.requestConfirmation())
    }

    // MARK: - Outcomes

    func testSuccessRecordsWhetherApplePublishedItYet() {
        var draft = ReplyDraft()
        draft.edit("Thanks!")
        draft.requestConfirmation()
        draft.confirm()
        draft.succeeded(state: .pendingPublish)
        XCTAssertEqual(draft.stage, .sent(state: .pendingPublish))
    }

    func testAFailureCanBeEditedAndRetried() {
        var draft = ReplyDraft()
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
        var draft = ReplyDraft()
        draft.succeeded(state: .published)
        XCTAssertEqual(draft.stage, .editing)
        draft.failed("nope")
        XCTAssertEqual(draft.stage, .editing)
    }

    // MARK: - Replacing an existing reply

    /// Apple's POST is create-or-update with no distinction, so overwriting is silent at the API
    /// level. The draft has to know, so the confirmation can say "replace" rather than "publish".
    func testADraftForAnAnsweredReviewStartsFromTheExistingReply() {
        let draft = ReplyDraft(existing: published("Our original reply."))
        XCTAssertTrue(draft.isReplacement)
        XCTAssertEqual(draft.text, "Our original reply.",
                       "Editing a reply starts from it, not from a blank box")
    }

    func testADraftForAnUnansweredReviewIsNotAReplacement() {
        let draft = ReplyDraft()
        XCTAssertFalse(draft.isReplacement)
        XCTAssertEqual(draft.text, "")
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

    func testNormalizeTrimsButLeavesTheMiddleAlone() {
        XCTAssertEqual(ReplyValidation.normalize("  a  b  "), "a  b")
    }
}
