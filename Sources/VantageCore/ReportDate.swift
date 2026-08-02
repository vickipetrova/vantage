import Foundation

/// A single day in Apple's sales reporting calendar.
///
/// This is a distinct type rather than a `Date` because the two are not the same thing and
/// confusing them is the easiest way to display the wrong day's money. A daily sales report covers
/// 00:00–23:59 **Pacific Time** and is identified by a bare `YYYY-MM-DD` string; it has no time
/// component and no relationship to the viewer's time zone. A developer in Berlin asking for
/// "yesterday" at breakfast is asking about a day that, in Pacific terms, ended two calendar days
/// ago — and Apple will happily return a report for the day they meant to ask about instead.
///
/// So: every report date in Vantage is anchored to `America/Los_Angeles`, and the UI always shows
/// the date it is talking about rather than trusting the word "yesterday" to be unambiguous.
public struct ReportDate: Hashable, Comparable, Codable, CustomStringConvertible, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Apple's reporting time zone. Not configurable, because it isn't a preference — it's a
    /// property of the reports themselves.
    public static let pacific = TimeZone(identifier: "America/Los_Angeles")!

    /// A Gregorian calendar pinned to Pacific and to a fixed locale, so day arithmetic can't drift
    /// with the user's region settings.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    // MARK: - Now

    /// The Pacific calendar day containing `instant`.
    public init(pacificDayContaining instant: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: instant)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// The most recent day that has finished in Pacific time — the newest report that can exist.
    ///
    /// `now` is a parameter so this is testable at the boundaries, where it matters: 23:59 PT and
    /// 00:01 PT must land on different days, and both must be right for a caller in Berlin.
    public static func yesterday(now: Date = Date()) -> ReportDate {
        ReportDate(pacificDayContaining: now).adding(days: -1)
    }

    // MARK: - Arithmetic

    public func adding(days: Int) -> ReportDate {
        let shifted = Self.calendar.date(byAdding: .day, value: days, to: startOfDay)!
        return ReportDate(pacificDayContaining: shifted)
    }

    /// The instant this report day begins, 00:00 Pacific.
    public var startOfDay: Date { pacificTime(hour: 0) }

    /// The instant it becomes `hour`:00 Pacific on this report day.
    ///
    /// Built from calendar components rather than by adding `hour * 3600` to midnight: on the two
    /// days a year when Pacific shifts, that arithmetic is off by an hour, and both of those days
    /// are days this app has to decide whether a report is late.
    public func pacificTime(hour: Int) -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = hour
        parts.timeZone = Self.pacific
        // A day that doesn't exist can't be reached through the initializers the app uses (they
        // all come from real dates), but a hand-written `ReportDate(2026, 2, 30)` would land here.
        // Calendar normalizes it rather than trapping.
        return Self.calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
    }

    /// The `n` report days ending at (and including) this one, oldest first.
    public func lastDays(_ n: Int) -> [ReportDate] {
        guard n > 0 else { return [] }
        return (0..<n).map { adding(days: -($0)) }.reversed()
    }

    // MARK: - Strings

    /// The `filter[reportDate]` value Apple expects, and the cache filename. Zero-padded, always.
    public var apiString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { apiString }

    /// Parses `YYYY-MM-DD`. Returns nil for anything else — including the `MM/DD/YYYY` that appears
    /// in a report's own Begin Date column, which is a different format for a different purpose.
    public init?(apiString: String) {
        let parts = apiString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    // MARK: - Comparable

    public static func < (lhs: ReportDate, rhs: ReportDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

// MARK: - Publication schedule

extension ReportDate {
    /// Apple publishes a day's report the following morning, "generally available by 8 a.m.
    /// Pacific Time". Vantage starts asking at 05:00 PT and retries hourly.
    public static let pollingStartsAtPacificHour = 5

    /// The hour, Pacific, after which a still-missing report stops meaning "not published yet".
    ///
    /// Apple only generates a Summary Sales report when at least one unit sold, so a 404 is
    /// ambiguous: either the report is late, or the day genuinely had no sales and no report will
    /// ever exist. Two hours past Apple's own 8 a.m. guideline is where Vantage stops waiting and
    /// records a zero — provisionally. See `docs/REPORT_FORMAT.md`.
    public static let assumeZeroAfterPacificHour = 10

    /// Whether a missing report for this date should still be read as "not published yet".
    public func mayStillArrive(now: Date = Date()) -> Bool {
        now < adding(days: 1).pacificTime(hour: Self.assumeZeroAfterPacificHour)
    }
}
