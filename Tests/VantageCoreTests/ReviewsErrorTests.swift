import XCTest
@testable import VantageCore

/// `ReviewsError`'s messages, which had no tests at all while `SalesError`'s had sixteen.
///
/// These strings are the whole user-facing explanation when reviews don't work, they name specific
/// Apple roles, and — like every other error in this app — they can end up in a screenshot attached
/// to a public issue.
final class ReviewsErrorTests: XCTestCase {
    /// Not having a reviews key is the expected state for anyone who only wanted sales. It must
    /// read as a thing to do, not as a failure, and must not be confused with the sales key.
    func testNoKeyPointsAtSettingsAndSaysItIsItsOwnKey() {
        let message = try! XCTUnwrap(ReviewsError.noKey.errorDescription)
        XCTAssertTrue(message.contains("Settings"), message)
        XCTAssertTrue(message.lowercased().contains("their own")
                      || message.lowercased().contains("own key"), message)
    }

    /// A 401 is about the three values, and says which three — Apple's own body is boilerplate that
    /// names none of them.
    func testUnauthorizedNamesTheThreeValuesToCheck() {
        let message = try! XCTUnwrap(ReviewsError.unauthorized.errorDescription)
        XCTAssertTrue(message.contains("Issuer ID"), message)
        XCTAssertTrue(message.contains("Key ID"), message)
        XCTAssertTrue(message.contains(".p8"), message)
    }

    /// A read refused is almost always the role, and the useful thing to add is which role — Apple's
    /// message doesn't say.
    func testForbiddenNamesTheRoleThatCanRead() {
        let message = try! XCTUnwrap(ReviewsError.forbidden(detail: nil).errorDescription)
        XCTAssertTrue(message.contains("App Manager"), message)
    }

    /// A write refused needs a *different* answer, and the obvious guess — App Manager, which is
    /// what reading needs — is the wrong one. These two must never collapse into one message.
    func testAWriteRefusalAsksForAdminNotAppManager() {
        let message = try! XCTUnwrap(ReviewsError.notAllowedToReply(detail: nil).errorDescription)
        XCTAssertTrue(message.contains("Admin"), message)
        XCTAssertNotEqual(message, ReviewsError.forbidden(detail: nil).errorDescription)
    }

    func testApplesOwnExplanationIsAppendedWhenThereIsOne() {
        let message = try! XCTUnwrap(
            ReviewsError.forbidden(detail: "Insufficient permissions").errorDescription)
        XCTAssertTrue(message.contains("Insufficient permissions"), message)
    }

    func testRejectedPrefersApplesExplanation() {
        XCTAssertEqual(ReviewsError.rejected(detail: "Response too long").errorDescription,
                       "Response too long")
        XCTAssertNotNil(ReviewsError.rejected(detail: nil).errorDescription,
                        "and still says something when Apple says nothing")
    }

    func testEveryCaseHasAMessage() {
        let cases: [ReviewsError] = [
            .noKey, .unauthorized, .forbidden(detail: nil), .rateLimited,
            .http(500, detail: nil), .network, .badResponse,
            .notAllowedToReply(detail: nil), .rejected(detail: nil),
        ]
        for error in cases {
            let message = error.errorDescription ?? ""
            XCTAssertFalse(message.isEmpty, "\(error) has no message")
            // A message ending mid-sentence is a truncation bug; these are whole sentences.
            XCTAssertTrue(message.hasSuffix(".") || message.hasSuffix("?"), message)
        }
    }

    /// Reviews failures must never be reported in the sales key's words. "Check your App Store
    /// Connect key" sends someone to re-enter a credential that is already correct.
    func testReviewsErrorsAreNotTheSalesErrorsWordForWord() {
        XCTAssertNotEqual(ReviewsError.noKey.errorDescription,
                          SalesError.noCredentials.errorDescription)
        XCTAssertNotEqual(ReviewsError.network.errorDescription.map { $0 + "x" },
                          SalesError.network.errorDescription)
    }

    /// The reviews endpoints take no vendor number, but Apple's bodies are still capped and
    /// stripped of URLs before they can reach the panel and, from there, a screenshot.
    func testApplesBodyIsStillScrubbedOnTheReviewsPath() {
        let body = Data("""
        {"errors":[{"title":"Forbidden","detail":"Nope. Learn more at https://developer.apple.com/x"}]}
        """.utf8)
        let summary = try! XCTUnwrap(ASCErrorBody.summary(from: body, redacting: ""))
        XCTAssertFalse(summary.contains("http"), summary)
        XCTAssertFalse(summary.contains("Learn more"), summary)
    }
}
