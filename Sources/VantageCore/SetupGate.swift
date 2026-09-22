import Foundation

/// What Vantage opens when it launches with nothing to show.
///
/// In Core rather than in `AppDelegate` for the same reason `EngagementState` is: deciding it in
/// the caller is how a hard failure ends up reading as a normal wait.
public enum SetupGate {
    public enum Destination: Equatable {
        /// Credentials exist. Render and refresh.
        case normalLaunch
        /// Nothing stored and the user has never been through setup.
        case wizard
        /// Nothing stored, but they've done this before — they skipped the walkthrough, or they
        /// pressed Forget credentials. The form is the faster answer for them.
        case settings
    }

    public static func destination(hasCredentials: Bool, setupCompleted: Bool) -> Destination {
        guard !hasCredentials else { return .normalLaunch }
        return setupCompleted ? .settings : .wizard
    }
}
