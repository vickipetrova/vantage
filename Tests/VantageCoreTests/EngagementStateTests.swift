import XCTest
@testable import VantageCore

/// Why the Overview has no engagement figures to show — in one note, decided in Core.
///
/// These four situations look alike on screen and mean completely different things: "wait a day",
/// "add a key", "your key is wrong", and "nothing is wrong at all". Reading one as another is what
/// made the old Analytics tab report a hard failure as a normal wait for a month.
final class EngagementStateTests: XCTestCase {
    func testNothingToSayWhenThereAreDays() {
        XCTAssertNil(EngagementState.note(hasKey: true, isLoading: false, hasDays: true, error: nil))
    }

    /// A failed refresh with days already cached is the status bar's business, not a note under
    /// the chart — the figures on screen are still true.
    func testAnErrorWithDaysCachedSaysNothingHere() {
        XCTAssertNil(EngagementState.note(hasKey: true, isLoading: false, hasDays: true,
                                          error: AnalyticsError.badResponse))
    }

    func testNoKeyAsksForOneAndOffersSettings() {
        let note = EngagementState.note(hasKey: false, isLoading: false, hasDays: false, error: nil)
        XCTAssertEqual(note?.title, "Analytics needs a key")
        XCTAssertTrue(note?.offersSettings == true)
        XCTAssertTrue(note?.body.contains("Settings") == true)
    }

    func testLoadingSaysSo() {
        let note = EngagementState.note(hasKey: true, isLoading: true, hasDays: false, error: nil)
        XCTAssertEqual(note?.title, "Checking with App Store Connect…")
        XCTAssertFalse(note?.offersSettings == true)
    }

    /// Loading changes the headline, not the explanation underneath it — a titled card with no
    /// body is what the old Analytics tab never showed.
    func testLoadingKeepsTheWaitingExplanation() {
        let loading = EngagementState.note(hasKey: true, isLoading: true, hasDays: false, error: nil)
        let waiting = EngagementState.note(hasKey: true, isLoading: false, hasDays: false, error: nil)
        XCTAssertEqual(loading?.body, waiting?.body)
        XCTAssertFalse(loading?.body.isEmpty == true)
    }

    /// The normal state for a day or two after analytics is switched on. Not an error, and the
    /// note must not offer the Settings button — that suggests the key is wrong when it isn't.
    func testWaitingForApplesFirstReportIsNotAnError() {
        let note = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                        error: AnalyticsError.notReadyYet)
        XCTAssertEqual(note?.title, "Apple is preparing your first report")
        XCTAssertTrue(note?.body.contains("24 to 48 hours") == true)
        XCTAssertFalse(note?.offersSettings == true)
    }

    func testNoErrorAndNoDaysIsAlsoAWait() {
        let note = EngagementState.note(hasKey: true, isLoading: false, hasDays: false, error: nil)
        XCTAssertEqual(note?.title, "Apple is preparing your first report")
    }

    func testAHardFailureSaysWhatWentWrong() {
        let note = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                        error: AnalyticsError.badResponse)
        XCTAssertEqual(note?.title, "Analytics couldn't load")
        XCTAssertEqual(note?.body, AnalyticsError.badResponse.errorDescription)
    }

    func testOnlyCredentialErrorsOfferSettings() {
        let credentials = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                               error: AnalyticsError.noKey)
        XCTAssertTrue(credentials?.offersSettings == true)

        let other = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                         error: AnalyticsError.badResponse)
        XCTAssertFalse(other?.offersSettings == true)
    }
}
