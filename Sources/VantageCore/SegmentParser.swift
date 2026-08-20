import Foundation

/// One day of App Store engagement, as Vantage displays it.
public struct EngagementDay: Equatable, Codable, Sendable {
    public let date: ReportDate
    /// Times the app appeared in front of someone — search results, Today, a browse row.
    public let impressions: Decimal
    /// Times someone actually opened the product page.
    public let pageViews: Decimal

    public init(date: ReportDate, impressions: Decimal, pageViews: Decimal) {
        self.date = date
        self.impressions = impressions
        self.pageViews = pageViews
    }

    /// Page views as a share of impressions. `nil` when nothing was shown, because a rate with no
    /// denominator is not zero — it's undefined, and drawing it as zero invents a bad day.
    public var conversion: Decimal? {
        guard impressions > 0 else { return nil }
        return pageViews / impressions * 100
    }
}

/// Turns an analytics segment's TSV into `EngagementDay`s.
///
/// The same discipline as `ReportParser`, for the same reasons: columns are matched by **normalized
/// name** rather than by position, because Apple reorders and adds them; a malformed row costs one
/// row rather than the file; and unknown event names are counted separately rather than folded into
/// something they might not be.
///
/// Read `docs/ANALYTICS_API.md` before changing any of this.
public enum SegmentParser {
    public struct Result: Equatable {
        /// Oldest first.
        public let days: [EngagementDay]
        public let skippedRows: Int
        /// Event names the parser didn't recognise, so a renamed event shows up as a gap in the
        /// numbers *and* a note, rather than silently as zero.
        public let unknownEvents: Set<String>
    }

    /// Apple's event values for the App Store Discovery and Engagement report.
    ///
    /// Matched case- and space-insensitively: the same report has shipped "Page view" and
    /// "Page View" in different periods.
    private static let impressionEvents: Set<String> = ["impression", "impressionunique"]
    private static let pageViewEvents: Set<String> = ["pageview", "pageviewunique"]

    public static func parse(_ tsv: String) -> Result {
        // Line endings are normalized *before* splitting, exactly as `ReportParser` does.
        //
        // Splitting on "\n" and stripping a trailing "\r" afterwards looks equivalent and is not:
        // Swift treats CRLF as a **single** `Character`, so `split(separator: "\n")` never matches
        // it and a CRLF file comes back as one enormous line. A test caught this; the dead
        // stripping code would have hidden it forever.
        var lines = tsv
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard !lines.isEmpty else {
            return Result(days: [], skippedRows: 0, unknownEvents: [])
        }

        let header = lines.removeFirst().split(separator: "\t", omittingEmptySubsequences: false)
            .map { normalize(String($0)) }
        guard let dateColumn = header.firstIndex(of: "date"),
              let eventColumn = header.firstIndex(of: "event"),
              let countColumn = header.firstIndex(of: "counts")
        else {
            // Without those three the file isn't the report we think it is. Reporting nothing is
            // right; guessing at column positions is how a chart ends up plotting territory codes.
            return Result(days: [], skippedRows: lines.count, unknownEvents: [])
        }

        var impressions: [ReportDate: Decimal] = [:]
        var pageViews: [ReportDate: Decimal] = [:]
        var skipped = 0
        var unknown: Set<String> = []

        for line in lines {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count > max(dateColumn, max(eventColumn, countColumn)),
                  let date = ReportDate(apiString: fields[dateColumn].trimmingCharacters(
                      in: .whitespaces)),
                  // Decimal(string:) rather than Int: Apple's count columns are documented as
                  // decimal, and a locale-sensitive parse here would read "1,234" as 1.
                  let count = Decimal(string: fields[countColumn].trimmingCharacters(
                      in: .whitespaces), locale: Locale(identifier: "en_US_POSIX"))
            else {
                skipped += 1
                continue
            }

            let event = normalize(fields[eventColumn])
            if impressionEvents.contains(event) {
                impressions[date, default: 0] += count
            } else if pageViewEvents.contains(event) {
                pageViews[date, default: 0] += count
            } else if !event.isEmpty {
                unknown.insert(fields[eventColumn].trimmingCharacters(in: .whitespaces))
            }
        }

        let dates = Set(impressions.keys).union(pageViews.keys).sorted()
        let days = dates.map {
            EngagementDay(date: $0, impressions: impressions[$0] ?? 0, pageViews: pageViews[$0] ?? 0)
        }
        return Result(days: days, skippedRows: skipped, unknownEvents: unknown)
    }

    /// Lowercased, with spaces and underscores removed — so "Page View", "page view" and
    /// "Page_View" are one thing, and a column rename that only changes case costs nothing.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
