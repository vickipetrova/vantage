import Foundation

/// A span of report days asked for by the CLI or an MCP client.
///
/// Wider than the panel's `OverviewRange` on purpose: the panel shows three fixed windows, but a
/// question from a terminal or an agent can be about any stretch of the cache — a quarter, a launch
/// week, everything since the app started collecting.
///
/// **Parsing refuses rather than guesses.** An agent calls this without a person reading the
/// arguments first, so an unrecognised value that quietly meant "30 days" would answer a question
/// nobody asked with a number that looks like an answer.
public enum QueryRange: Equatable, Sendable {
    /// The `n` days ending at the newest cached day.
    case last(Int)
    /// From and to, inclusive. An open end is filled from the cache.
    case between(from: ReportDate?, to: ReportDate?)

    /// Everything cached.
    public static let all = QueryRange.between(from: nil, to: nil)

    /// A question asked without a range is almost always "how am I doing" rather than "what
    /// happened yesterday".
    public static let `default` = QueryRange.last(30)

    /// A hundred years. Not a limit on the cache — only on how big a number is worth believing.
    public static let maxDays = 36_500

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Reads the CLI's flags or the MCP tool's arguments. At most one style may be used: `range`,
    /// `days`, or `from`/`to`.
    ///
    /// - `range`: `1d`, `7d`, `30d`, any `Nd`, `all`, or the words `day`, `week`, `month`.
    /// - `days`: a whole number of days.
    /// - `from`, `to`: `YYYY-MM-DD`, either or both.
    public static func parse(range: String? = nil, days: String? = nil,
                             from: String? = nil, to: String? = nil) throws -> QueryRange {
        let styles = [range != nil, days != nil, from != nil || to != nil].filter { $0 }.count
        guard styles <= 1 else {
            throw Invalid(description: "Use one of: a range, a number of days, or from/to dates.")
        }

        if let range {
            let value = range.trimmingCharacters(in: .whitespaces).lowercased()
            switch value {
            case "all": return .all
            case "day", "yesterday": return .last(1)
            case "week": return .last(7)
            case "month": return .last(30)
            default:
                guard value.hasSuffix("d"), let count = Int(value.dropLast()) else {
                    throw Invalid(description: "Unknown range '\(range)'. "
                                  + "Use 1d, 7d, 30d, any number of days like 90d, or all.")
                }
                return try .last(validated(count, as: range))
            }
        }

        if let days {
            guard let count = Int(days.trimmingCharacters(in: .whitespaces)) else {
                throw Invalid(description: "'\(days)' isn't a whole number of days.")
            }
            return try .last(validated(count, as: days))
        }

        if from != nil || to != nil {
            let start = try from.map { try date($0) }
            let end = try to.map { try date($0) }
            if let start, let end, end < start {
                throw Invalid(description: "The range ends (\(end)) before it starts (\(start)).")
            }
            return .between(from: start, to: end)
        }

        return .default
    }

    private static func validated(_ count: Int, as written: String) throws -> Int {
        guard (1...maxDays).contains(count) else {
            throw Invalid(description: "'\(written)' is out of range — use 1 to \(maxDays) days.")
        }
        return count
    }

    private static func date(_ string: String) throws -> ReportDate {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        guard let date = ReportDate(apiString: trimmed), date.isValidCalendarDay else {
            throw Invalid(description: "'\(string)' isn't a date — use YYYY-MM-DD.")
        }
        return date
    }

    // MARK: - Resolving

    public struct Resolved: Equatable, Sendable {
        public let start: ReportDate
        public let end: ReportDate
        /// Calendar days in the range, cached or not.
        public var dayCount: Int { start.days(to: end) + 1 }
    }

    /// Pins the range to real dates, given what's cached.
    ///
    /// A range is allowed to reach past the cache in either direction: the caller compares
    /// `dayCount` with the days actually found, which is what lets a response say "3 of 365 days
    /// cached" instead of implying the rest were zero.
    public func resolve(oldest: ReportDate, newest: ReportDate) -> Resolved {
        switch self {
        case .last(let count):
            return Resolved(start: newest.adding(days: -(max(count, 1) - 1)), end: newest)
        case .between(let from, let to):
            // An open end never crosses the fixed one: `from` after everything cached is a
            // one-day range at `from`, not a range that finishes before it begins.
            let end = to ?? max(newest, from ?? newest)
            let start = from ?? min(oldest, end)
            return Resolved(start: start, end: end)
        }
    }

    /// Short and unambiguous, for the `range` field of a response.
    public var label: String {
        switch self {
        case .last(let count): return "\(count)d"
        case .between(nil, nil): return "all"
        case .between(let from, let to):
            return "\(from?.apiString ?? "")..\(to?.apiString ?? "")"
        }
    }
}
