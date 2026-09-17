import Foundation

/// Engagement for the days the panel is showing: how many people saw the app, how many opened its
/// page, and what share that is.
///
/// Conversion is the one figure neither API returns and the reason the two numbers belong side by
/// side. It is `nil` rather than zero when nobody saw the app at all, because 0 ÷ 0 is not 0%.
///
/// `nil` from `build` means the span holds no engagement day — which is normal, not an error:
/// Apple finalises a day about two days later, and an `ONGOING` report request only produces days
/// from its own creation onwards.
public struct EngagementSummary: Equatable, Sendable {
    public let impressions: Decimal
    public let pageViews: Decimal
    /// Page views as a percentage of impressions. `nil` when there were no impressions.
    public let conversion: Decimal?
    /// How many **distinct dates** in the span actually had data.
    ///
    /// Dates, not rows: the portfolio hands in every app's days flattened together, so counting
    /// rows would report three apps over a week as 21 days — a figure that can exceed the span it
    /// claims to describe.
    public let daysCovered: Int

    public init(impressions: Decimal, pageViews: Decimal, conversion: Decimal?, daysCovered: Int) {
        self.impressions = impressions
        self.pageViews = pageViews
        self.conversion = conversion
        self.daysCovered = daysCovered
    }

    /// - Parameter days: any order; only the span is used.
    public static func build(days: [EngagementDay],
                             from start: ReportDate,
                             to end: ReportDate) -> EngagementSummary? {
        let window = days.filter { $0.date >= start && $0.date <= end }
        guard !window.isEmpty else { return nil }

        let impressions = window.reduce(Decimal(0)) { $0 + $1.impressions }
        let pageViews = window.reduce(Decimal(0)) { $0 + $1.pageViews }
        return EngagementSummary(
            impressions: impressions,
            pageViews: pageViews,
            conversion: impressions > 0 ? pageViews / impressions * 100 : nil,
            daysCovered: Set(window.map(\.date)).count)
    }

    /// The headline's engagement line.
    public var line: String {
        var parts = ["\(Fmt.downloads(impressions)) impressions",
                     "\(Fmt.downloads(pageViews)) page views"]
        if let conversion {
            parts.append("\(Fmt.percent(conversion)) viewed")
        }
        return parts.joined(separator: " · ")
    }
}
