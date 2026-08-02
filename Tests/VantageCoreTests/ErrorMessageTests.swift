import XCTest
@testable import VantageCore

/// Error text is the only diagnostic this app has — there is no log to read — and it goes straight
/// into the menu, which means straight into screenshots. Both halves of that matter: it has to say
/// enough to act on, and it must never quote a credential back.
final class ErrorMessageTests: XCTestCase {
    private func body(_ detail: String, title: String = "The request is forbidden") -> Data {
        Data(#"{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","title":"\#(title)","detail":"\#(detail)"}]}"#.utf8)
    }

    func testPrefersApplesDetailOverItsGenericTitle() {
        let summary = ASCErrorBody.summary(
            from: body("This request requires an in-effect agreement that has not been signed or has expired."),
            redacting: "12345678")
        XCTAssertEqual(summary, "This request requires an in-effect agreement that has not been signed or has expired.")
    }

    func testFallsBackToTitleWhenThereIsNoDetail() {
        let data = Data(#"{"errors":[{"status":"403","title":"The request is forbidden"}]}"#.utf8)
        XCTAssertEqual(ASCErrorBody.summary(from: data, redacting: "12345678"),
                       "The request is forbidden")
    }

    /// Apple quotes request parameters back in `detail`, and one of those parameters is the vendor
    /// number. It must not survive into anything renderable.
    func testRedactsTheVendorNumber() {
        let summary = ASCErrorBody.summary(
            from: body("Invalid vendor number specified: 87654321"), redacting: "87654321")
        XCTAssertEqual(summary, "Invalid vendor number specified: <vendor number>")
        XCTAssertFalse(summary!.contains("87654321"))
    }

    func testCapsRunawayDetail() {
        let summary = ASCErrorBody.summary(from: body(String(repeating: "x", count: 500)),
                                           redacting: "12345678")
        XCTAssertLessThanOrEqual(summary!.count, 161)
        XCTAssertTrue(summary!.hasSuffix("…"))
    }

    func testReturnsNilForABodyThatIsntAnErrorResponse() {
        XCTAssertNil(ASCErrorBody.summary(from: Data("not json".utf8), redacting: "1"))
        XCTAssertNil(ASCErrorBody.summary(from: Data(#"{"errors":[]}"#.utf8), redacting: "1"))
        XCTAssertNil(ASCErrorBody.summary(from: Data(#"{"data":{}}"#.utf8), redacting: "1"))
    }

    func testEmptyVendorNumberDoesntRedactEverything() {
        // Guards against a replacingOccurrences(of: "") pathology.
        XCTAssertEqual(ASCErrorBody.summary(from: body("Something went wrong"), redacting: ""),
                       "Something went wrong")
    }

    // MARK: - What the menu ends up saying

    /// The message that cost an afternoon: a missing Paid Apps Agreement arrives as a 403, and the
    /// obvious reading of a 403 — "the key's role is wrong" — sends you to the wrong page entirely.
    func testAgreementRefusalSaysWhereToGo() {
        let message = SalesError.forbidden(
            detail: "This request requires an in-effect agreement that has not been signed or has expired."
        ).errorDescription
        XCTAssertTrue(message!.contains("Business"), message!)
    }

    func testOtherForbiddenReasonsAreLeftAlone() {
        let message = SalesError.forbidden(detail: "Invalid vendor number specified.").errorDescription
        XCTAssertEqual(message, "Invalid vendor number specified.")
    }

    func testForbiddenWithoutDetailStillSaysSomethingUseful() {
        let message = SalesError.forbidden(detail: nil).errorDescription
        XCTAssertTrue(message!.contains("Sales and Reports"), message!)
    }

    func testNoCredentialsPointsAtSettings() {
        XCTAssertTrue(SalesError.noCredentials.errorDescription!.contains("Settings"))
    }
}
