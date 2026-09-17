import Foundation

/// One note about why there are no engagement figures, and whether Settings is the fix.
public struct EngagementNote: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Offered only where it's the actual fix. A key button under "come back tomorrow" suggests
    /// something is wrong with the key, and under an HTTP 500 it invites replacing credentials
    /// that work.
    public let offersSettings: Bool

    public init(title: String, body: String, offersSettings: Bool) {
        self.title = title
        self.body = body
        self.offersSettings = offersSettings
    }
}

/// Turns the analytics situation into that note. In Core, not a view, so `swift test` covers the
/// difference between "wait a day" and "your key is wrong".
public enum EngagementState {
    private static let waitingExplanation = "Vantage has asked Apple to start generating analytics for your apps. Apple "
        + "takes 24 to 48 hours to produce the first one, and there is nothing else to "
        + "do — it will appear here on its own. This is not an error."

    /// `nil` when there is nothing to say — which includes a failed refresh over days that are
    /// already cached: those figures are still true, and the status bar carries the failure.
    public static func note(hasKey: Bool,
                            isLoading: Bool,
                            hasDays: Bool,
                            error: Error?) -> EngagementNote? {
        guard !hasDays else { return nil }

        guard hasKey else {
            return EngagementNote(
                title: "Analytics needs a key",
                body: "Analytics uses the same key as Reviews — there isn't a separate one. Add it "
                    + "under Settings › Reviews & Analytics. Apple requires an Admin key to start "
                    + "generating a report, and takes 24 to 48 hours to produce the first one.",
                offersSettings: true)
        }

        if isLoading {
            return EngagementNote(title: "Checking with App Store Connect…",
                                  body: waitingExplanation, offersSettings: false)
        }

        // Asked of the error itself, where a test can reach it. Deriving this from `!stopsTheRun`
        // answers a different question and reported every hard failure as a normal wait.
        let analytics = error as? AnalyticsError
        let isWaiting = analytics.map(\.isWaitingForApple) ?? (error == nil)
        if isWaiting {
            return EngagementNote(
                title: "Apple is preparing your first report",
                body: waitingExplanation,
                offersSettings: false)
        }

        return EngagementNote(
            title: "Analytics couldn't load",
            body: analytics?.errorDescription ?? "Couldn't load analytics.",
            offersSettings: analytics?.suggestsCheckingCredentials == true)
    }
}
