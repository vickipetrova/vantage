import Foundation

/// When to go looking for a new report.
///
/// Apple publishes a day's report the next morning, "generally available by 8 a.m. Pacific Time".
/// So there is exactly one interesting window per day, and polling outside it is pure noise: the
/// answer cannot change. Vantage checks hourly from 05:00 PT until the report lands, then stops
/// until the next morning.
///
/// Pure functions over an injected clock, so every branch is testable without waiting for 5am.
public enum Schedule {
    /// Whether a poll is worth making right now.
    ///
    /// - Parameters:
    ///   - newestCached: the most recent report date already on disk, if any.
    ///   - now: the current instant.
    public static func shouldPoll(newestCached: ReportDate?, now: Date = Date()) -> Bool {
        let target = ReportDate.yesterday(now: now)

        // Already have the newest report that can exist. Nothing to ask for.
        if let newestCached, newestCached >= target { return false }

        // Before Apple's window opens, asking is guaranteed to 404.
        let opens = target.adding(days: 1).pacificTime(hour: ReportDate.pollingStartsAtPacificHour)
        return now >= opens
    }

    /// When the next poll should happen, given that one just ran.
    ///
    /// Inside the publication window it's hourly. Outside it, it's whenever the window next opens —
    /// which is the difference between a handful of requests a day and a hundred.
    public static func nextPoll(newestCached: ReportDate?, now: Date = Date()) -> Date {
        if shouldPoll(newestCached: newestCached, now: now) {
            return now.addingTimeInterval(3600)
        }
        // The next window opens the morning after the newest report that could exist.
        let nextTarget = ReportDate.yesterday(now: now).adding(days: 1)
        let opens = nextTarget.adding(days: 1)
            .pacificTime(hour: ReportDate.pollingStartsAtPacificHour)
        // A clock that has moved backwards (sleep, time-zone change, NTP correction) must not
        // produce a date in the past and spin.
        return max(opens, now.addingTimeInterval(600))
    }

    /// Whether a freshly fetched day deserves the morning notification.
    ///
    /// Only the newest report that could exist, only once, and never for a day written off as an
    /// assumed zero — announcing "$0 · 0 downloads" for a report Apple never published would be
    /// telling the user something that isn't known to be true.
    public static func shouldNotify(about day: DaySales, alreadyNotified: Bool,
                                    now: Date = Date()) -> Bool {
        guard !alreadyNotified else { return false }
        guard day.origin == .observed else { return false }
        return day.date == ReportDate.yesterday(now: now)
    }
}
