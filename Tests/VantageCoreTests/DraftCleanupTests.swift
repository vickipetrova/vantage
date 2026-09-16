import XCTest
@testable import VantageCore

/// What the model returns is untrusted text on its way into a box that publishes to the App Store.
/// Each rule here is one thing that must never reach that box, or one habit of the model that would
/// otherwise make every draft need hand-editing.
final class DraftCleanupTests: XCTestCase {
    private func cleaned(_ raw: String) -> String? {
        if case .success(let text) = DraftCleanup.clean(raw) { return text }
        return nil
    }

    private func error(_ raw: String) -> DraftError? {
        if case .failure(let error) = DraftCleanup.clean(raw) { return error }
        return nil
    }

    // MARK: - Passes through

    func testAGoodReplyIsUntouched() {
        let reply = "Sorry about the crash on export in 1.4.2. Thanks for telling us exactly when it happens."
        XCTAssertEqual(cleaned(reply), reply)
    }

    /// Version numbers, star counts and dates are ordinary in a reply and must not look like
    /// phone numbers or links.
    func testNumbersThatAreNotContactDetailsPass() {
        XCTAssertNotNil(cleaned("Thanks for the report. Version 2.3 should behave better, and we appreciate the detail."))
        XCTAssertNotNil(cleaned("Thanks for 5 stars! We release updates every 2 weeks."))
        XCTAssertNotNil(cleaned("Thanks for using Vantage.app every day."))
    }

    // MARK: - Tidying

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(cleaned("  \n Thanks for the kind words! \n\n"), "Thanks for the kind words!")
    }

    func testWrappingQuotesAreRemoved() {
        XCTAssertEqual(cleaned("\"Thanks for the kind words!\""), "Thanks for the kind words!")
        XCTAssertEqual(cleaned("“Thanks for the kind words!”"), "Thanks for the kind words!")
    }

    /// Quotes at both ends that aren't a pair around the whole reply are part of the text.
    func testQuotesInsideTheReplyAreKept() {
        let reply = "\"Export\" is on our list, and so is \"dark mode\""
        XCTAssertEqual(cleaned(reply), reply)
    }

    func testALeadingLabelIsRemoved() {
        XCTAssertEqual(cleaned("Reply: Thanks for the kind words!"), "Thanks for the kind words!")
        XCTAssertEqual(cleaned("Here’s a response:\nThanks for the kind words!"), "Thanks for the kind words!")
        XCTAssertEqual(cleaned("Here is a reply: \"Thanks for the kind words!\""), "Thanks for the kind words!")
    }

    func testAPlaceholderSignOffIsRemoved() {
        XCTAssertEqual(cleaned("Thanks for the kind words!\n\nBest,\n[Your Name]"), "Thanks for the kind words!")
        XCTAssertEqual(cleaned("Thanks for the kind words!\nBest regards, [Developer Name]"), "Thanks for the kind words!")
    }

    func testWindowsLineEndingsDoNotHideASignOff() {
        XCTAssertEqual(cleaned("Thanks for the kind words!\r\n\r\nBest,\r\n[Your Name]"), "Thanks for the kind words!")
    }

    // MARK: - Declined

    func testAnEnglishRefusalIsDeclined() {
        XCTAssertEqual(error("I'm sorry, but I can't help with that request."), .declined)
        XCTAssertEqual(error("I’m sorry, but I can’t assist with that."), .declined)
        XCTAssertEqual(error("I cannot help with this."), .declined)
    }

    /// A long reply that happens to open with an apology is a reply, not a refusal.
    func testALongApologyIsNotARefusal() {
        let reply = "I'm sorry, but I can't reproduce the crash yet on my own Mac, which makes this one hard. "
            + "Thank you for describing the export steps in such detail, it gives us a clear place to start "
            + "looking, and we really appreciate you taking the time to write."
        XCTAssertGreaterThanOrEqual(reply.count, 200)
        XCTAssertEqual(cleaned(reply), reply)
    }

    // MARK: - Rejected

    func testEmptyOutputIsRejected() {
        XCTAssertEqual(error(""), .rejected)
        XCTAssertEqual(error("  \"\"  "), .rejected)
        XCTAssertEqual(error("Best,\n[Your Name]"), .rejected)
    }

    func testLinksAreRejected() {
        XCTAssertEqual(error("Thanks! See https://example.com for help."), .rejected)
        XCTAssertEqual(error("Thanks! Visit example.com/help for more."), .rejected)
    }

    func testEmailAddressesAreRejected() {
        XCTAssertEqual(error("Thanks! Email us at help@example.com."), .rejected)
    }

    func testPhoneNumbersAreRejected() {
        XCTAssertEqual(error("Thanks! Call us on +1 408 555 0100."), .rejected)
    }

    func testAPlaceholderLeftInTheBodyIsRejected() {
        XCTAssertEqual(error("Thanks! The fix ships in [version] next week."), .rejected)
    }

    func testOverlongOutputIsRejected() {
        XCTAssertEqual(error(String(repeating: "a", count: ReplyValidation.maxLength + 1)), .rejected)
    }

    // MARK: - Messages

    func testOnlyRetryableErrorsOfferTryAgain() {
        XCTAssertTrue(DraftError.rejected.canRetry)
        XCTAssertTrue(DraftError.failed.canRetry)
        XCTAssertFalse(DraftError.declined.canRetry)
        XCTAssertFalse(DraftError.unsupportedLanguage.canRetry)
        XCTAssertFalse(DraftError.unavailable(.turnedOff).canRetry)
    }

    func testUnavailableErrorsSayWhy() {
        XCTAssertEqual(DraftError.unavailable(.turnedOff).message, "Turn on Apple Intelligence to draft replies.")
        XCTAssertEqual(DraftError.unavailable(.preparing).message, "Apple Intelligence is still getting ready.")
        XCTAssertEqual(DraftError.unavailable(.hidden).message, DraftError.failed.message)
    }
}