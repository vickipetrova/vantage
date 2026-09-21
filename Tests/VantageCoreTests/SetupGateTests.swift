import XCTest
@testable import VantageCore

/// Which window opens at launch.
///
/// Three inputs, three outcomes, and one of them is the migration: an existing user with working
/// credentials must never be shown a walkthrough for something they've already done.
final class SetupGateTests: XCTestCase {

    func testCredentialsMeanNormalLaunch() {
        XCTAssertEqual(SetupGate.destination(hasCredentials: true, setupCompleted: false),
                       .normalLaunch)
        XCTAssertEqual(SetupGate.destination(hasCredentials: true, setupCompleted: true),
                       .normalLaunch)
    }

    /// The actual first run.
    func testNothingStoredAndNeverSetUpOpensTheWizard() {
        XCTAssertEqual(SetupGate.destination(hasCredentials: false, setupCompleted: false),
                       .wizard)
    }

    /// Someone who pressed Skip, or who finished setup and later pressed Forget credentials. They
    /// know what an Issuer ID is; hand them the form.
    func testNothingStoredButSetUpBeforeOpensSettings() {
        XCTAssertEqual(SetupGate.destination(hasCredentials: false, setupCompleted: true),
                       .settings)
    }

    /// The wizard is the only outcome that needs the flag written; the other two already know.
    func testOnlyTheWizardIsReachableTwice() {
        XCTAssertNotEqual(SetupGate.destination(hasCredentials: false, setupCompleted: true),
                          .wizard)
    }
}
