import Foundation

/// Whether what's on screen is current, and what to say if it isn't.
///
/// This exists because a failed refresh used to be a grey line at the bottom of one section. The
/// numbers stayed on screen looking authoritative, and the only hint that they were three days old
/// was a footnote below the fold — so the app looked like it was working right up until someone
/// noticed the figures hadn't moved.
///
/// Pure and injectable, so every branch is covered by `swift test` rather than by opening the panel
/// at the right moment with the wifi off.
public struct Freshness: Equatable {
    /// How loudly to say it.
    public enum Severity: Equatable {
        /// Everything Apple has published is on disk. Say so quietly.
        case current
        /// A refresh hasn't worked lately, but nothing is actually missing yet.
        case warning
        /// Numbers on screen are behind what Apple has published.
        case behind
    }

    public let severity: Severity
    /// The short line: "Up to date", "3 days behind".
    public let headline: String
    /// When Vantage last got something from Apple, in words. `nil` before the first success.
    public let lastUpdated: String?
    /// What went wrong, if the last attempt failed.
    public let problem: String?
    /// Whether the menu bar title should carry a warning marker.
    ///
    /// **Only when data is actually behind.** A failed refresh while everything Apple has published
    /// is already cached is not a problem the user needs to see in their menu bar — the numbers are
    /// right, and marking them would train people to ignore the marker.
    public var marksMenuBar: Bool { severity == .behind }

    public static func evaluate(newestCached: ReportDate?,
                                lastSuccess: Date?,
                                error: Error?,
                                now: Date = Date()) -> Freshness {
        let updated = lastSuccess.map { Fmt.relative($0, from: now) }
        let problem = error.map { error -> String in
            (error as? SalesError)?.errorDescription
                ?? (error as? ReviewsError)?.errorDescription
                ?? "Couldn't reach App Store Connect."
        }

        guard let newestCached else {
            return Freshness(severity: error == nil ? .warning : .behind,
                             headline: "No reports yet",
                             lastUpdated: updated, problem: problem)
        }

        let newestPossible = ReportDate.yesterday(now: now)
        let behind = newestCached.daysBefore(newestPossible)

        if behind <= 0 {
            // Nothing is missing. A failed refresh here is worth showing, but quietly — there is
            // nothing to fix and nothing is wrong with the figures.
            return Freshness(severity: error == nil ? .current : .warning,
                             headline: "Up to date",
                             lastUpdated: updated, problem: problem)
        }

        // Apple publishes the previous day during the morning Pacific, so being one day behind
        // before that window closes is the normal state rather than a fault.
        // One day behind before Apple's morning window has closed is the normal state, not a
        // shortfall — Apple simply hasn't generated it yet. Nothing Apple has published is missing,
        // so this reads as up to date rather than spending three lines explaining Pacific time.
        if behind == 1, newestPossible.mayStillArrive(now: now) {
            return Freshness(severity: error == nil ? .current : .warning,
                             headline: "Up to date",
                             lastUpdated: updated, problem: problem)
        }

        return Freshness(severity: .behind,
                         headline: behind == 1 ? "1 day behind" : "\(behind) days behind",
                         lastUpdated: updated, problem: problem)
    }

}

extension ReportDate {
    /// How many days this is before `other`. Negative when it's after.
    public func daysBefore(_ other: ReportDate) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        var pacific = calendar
        pacific.timeZone = ReportDate.pacific
        let components = pacific.dateComponents([.day], from: startOfDay, to: other.startOfDay)
        return components.day ?? 0
    }
}
