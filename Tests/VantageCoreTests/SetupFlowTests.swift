import XCTest
@testable import VantageCore

/// The order of first-run setup, and where Back goes.
///
/// The flow branches once — at the offer to also set up the reviews key — so the interesting cases
/// are both sides of that branch and the progress counter, which must not count a path the user
/// has not chosen.
final class SetupFlowTests: XCTestCase {

    // MARK: - Forward, the short way

    func testSalesPathReachesSaveAndTest() {
        var flow = SetupFlow()
        XCTAssertEqual(flow.step, .createKey)
        flow.advance(); XCTAssertEqual(flow.step, .issuerID)
        flow.advance(); XCTAssertEqual(flow.step, .keyID)
        flow.advance(); XCTAssertEqual(flow.step, .privateKey)
        flow.advance(); XCTAssertEqual(flow.step, .vendorNumber)
        flow.advance(); XCTAssertEqual(flow.step, .saveAndTest)
        flow.advance(); XCTAssertEqual(flow.step, .offerReviews)
    }

    func testDecliningReviewsEndsTheFlow() {
        var flow = SetupFlow()
        flow.goTo(.offerReviews)
        flow.chooseReviews(false)
        flow.advance()
        XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isComplete)
    }

    // MARK: - Forward, through the branch

    func testAcceptingReviewsAddsThreeSteps() {
        var flow = SetupFlow()
        flow.goTo(.offerReviews)
        flow.chooseReviews(true)
        flow.advance(); XCTAssertEqual(flow.step, .reviewsIssuerID)
        flow.advance(); XCTAssertEqual(flow.step, .reviewsKeyID)
        flow.advance(); XCTAssertEqual(flow.step, .reviewsPrivateKey)
        flow.advance(); XCTAssertEqual(flow.step, .done)
        XCTAssertTrue(flow.isComplete)
    }

    func testDoneIsTerminal() {
        var flow = SetupFlow()
        flow.goTo(.done)
        flow.advance()
        XCTAssertEqual(flow.step, .done)
    }

    // MARK: - Back

    func testBackWalksTheValueSteps() {
        var flow = SetupFlow()
        flow.goTo(.vendorNumber)
        flow.back(); XCTAssertEqual(flow.step, .privateKey)
        flow.back(); XCTAssertEqual(flow.step, .keyID)
        flow.back(); XCTAssertEqual(flow.step, .issuerID)
        flow.back(); XCTAssertEqual(flow.step, .createKey)
    }

    /// Three screens have nowhere sensible to go back to: the first one, the offer (whose previous
    /// step already wrote to the Keychain and tested), and the last one.
    func testTheThreeScreensWithNoBack() {
        for step in [SetupStep.createKey, .offerReviews, .done] {
            var flow = SetupFlow()
            flow.goTo(step)
            XCTAssertFalse(flow.canGoBack, "\(step) should have no Back")
            flow.back()
            XCTAssertEqual(flow.step, step, "\(step) moved on a back() it should have ignored")
        }
    }

    func testBackFromSaveAndTestReturnsToTheLastValue() {
        var flow = SetupFlow()
        flow.goTo(.saveAndTest)
        XCTAssertTrue(flow.canGoBack)
        flow.back()
        XCTAssertEqual(flow.step, .vendorNumber)
    }

    func testBackFromFirstReviewsStepReturnsToTheOffer() {
        var flow = SetupFlow()
        flow.goTo(.reviewsIssuerID)
        flow.back()
        XCTAssertEqual(flow.step, .offerReviews)
    }

    // MARK: - Values

    func testValuesAreStoredAndTrimmedOnRead() {
        var flow = SetupFlow()
        flow.setValue("  2X9R4HXF34 ", for: .keyID)
        XCTAssertEqual(flow.value(for: .keyID), "2X9R4HXF34")
    }

    func testUnsetValueIsEmpty() {
        XCTAssertEqual(SetupFlow().value(for: .vendorNumber), "")
    }

    func testSalesAndReviewsValuesAreSeparate() {
        var flow = SetupFlow()
        flow.setValue("a", for: .issuerID)
        flow.setValue("b", for: .reviewsIssuerID)
        XCTAssertEqual(flow.salesValues[.issuerID], "a")
        XCTAssertNil(flow.salesValues[.reviewsIssuerID])
        XCTAssertEqual(flow.reviewsValues[.reviewsIssuerID], "b")
        XCTAssertNil(flow.reviewsValues[.issuerID])
    }

    /// The note for whatever the current step is asking for, so the view doesn't decide.
    func testNoteFollowsTheCurrentStep() {
        var flow = SetupFlow()
        flow.goTo(.issuerID)
        flow.setValue("2X9R4HXF34", for: .issuerID)
        XCTAssertEqual(flow.note, .looksLike(.keyID))
    }

    func testStepsWithNoFieldHaveNoNote() {
        var flow = SetupFlow()
        flow.goTo(.createKey)
        XCTAssertEqual(flow.note, .ok)
    }

    // MARK: - The rule from Task 1, at the flow level

    /// The shape check must never stop the flow moving. Garbage in every field, and Continue still
    /// continues.
    func testAdvanceIsNeverBlockedByShape() {
        var flow = SetupFlow()
        flow.goTo(.issuerID)
        flow.setValue("nonsense", for: .issuerID)
        flow.advance()
        XCTAssertEqual(flow.step, .keyID)

        flow.setValue("", for: .keyID)
        flow.advance()
        XCTAssertEqual(flow.step, .privateKey)
    }

    // MARK: - The progress counter

    /// Five screens lead to a working app; the counter says so. It must not say "of 10" to someone
    /// who has not yet chosen whether to do the reviews key.
    func testSalesStepsCountToFive() {
        XCTAssertEqual(SetupStep.createKey.progress?.total, 5)
        XCTAssertEqual(SetupStep.createKey.progress?.index, 1)
        XCTAssertEqual(SetupStep.vendorNumber.progress?.index, 5)
        XCTAssertEqual(SetupStep.vendorNumber.progress?.total, 5)
    }

    func testReviewsStepsCountToThree() {
        XCTAssertEqual(SetupStep.reviewsIssuerID.progress?.index, 1)
        XCTAssertEqual(SetupStep.reviewsIssuerID.progress?.total, 3)
        XCTAssertEqual(SetupStep.reviewsPrivateKey.progress?.index, 3)
        XCTAssertEqual(SetupStep.reviewsPrivateKey.progress?.total, 3)
    }

    /// Outcomes, not work remaining.
    func testOutcomeScreensHaveNoCounter() {
        XCTAssertNil(SetupStep.saveAndTest.progress)
        XCTAssertNil(SetupStep.offerReviews.progress)
        XCTAssertNil(SetupStep.done.progress)
    }

    // MARK: - Copy

    /// Every step the user reads has something to read. A blank screen with a Continue button is
    /// the failure this whole feature exists to fix.
    func testEveryStepHasTitleAndInstruction() {
        for step in SetupStep.allCases {
            XCTAssertFalse(step.title.isEmpty, "\(step) has no title")
            XCTAssertFalse(step.instruction.isEmpty, "\(step) has no instruction")
        }
    }

    /// Every step that takes a typed value names the field it writes to, and no other step does.
    func testFieldsMatchTheTypedSteps() {
        XCTAssertEqual(SetupStep.issuerID.field, .issuerID)
        XCTAssertEqual(SetupStep.reviewsPrivateKey.field, .reviewsPrivateKey)
        XCTAssertNil(SetupStep.createKey.field)
        XCTAssertNil(SetupStep.saveAndTest.field)
        XCTAssertNil(SetupStep.offerReviews.field)
        XCTAssertNil(SetupStep.done.field)
    }
}

/// Which step a failed connection test sends the user back to.
///
/// Optional on purpose. Three of these errors are not credential problems at all, and sending
/// someone to re-edit an Issuer ID that was correct is worse than saying "try again".
final class SalesErrorLikelyStepTests: XCTestCase {

    /// A 403 is the role. The key itself is fine — it was made wrong, which is step one.
    func testForbiddenPointsAtTheRole() {
        XCTAssertEqual(SalesError.forbidden(detail: nil).likelyStep, .createKey)
        XCTAssertEqual(SalesError.forbidden(detail: "Nope").likelyStep, .createKey)
    }

    /// A 401 means the three values don't agree with each other. Start at the first of them.
    func testUnauthorizedPointsAtTheFirstOfTheThree() {
        XCTAssertEqual(SalesError.unauthorized(detail: nil).likelyStep, .issuerID)
    }

    func testNoCredentialsPointsAtTheFirstField() {
        XCTAssertEqual(SalesError.noCredentials.likelyStep, .issuerID)
    }

    /// Not credential problems. No field to send anyone to.
    func testTransientAndUnknownFailuresPointNowhere() {
        XCTAssertNil(SalesError.network.likelyStep)
        XCTAssertNil(SalesError.rateLimited.likelyStep)
        XCTAssertNil(SalesError.badReport.likelyStep)
        XCTAssertNil(SalesError.http(500, detail: nil).likelyStep)
    }
}
