import Foundation

/// Which days the panel is looking at: a length, and where it ends.
///
/// `OverviewRange` answered "how many days"; this adds "which ones", so the panel can step back a
/// week, pan the chart to March, or show a custom stretch — without the views doing date
/// arithmetic, which is exactly the kind of calculation that goes wrong untested at a month or a
/// daylight-saving boundary.
///
/// **`end == nil` means Latest**, and follows the newest cached day as new reports land. A window
/// pinned to a date that happens to be today's newest would silently stop updating tomorrow.
public struct TimeWindow: Equatable, Sendable {
    public private(set) var length: Int
    /// The preset this window is, or `nil` for a custom length.
    public private(set) var preset: OverviewRange?
    /// The last day covered, or `nil` for the newest cached day.
    public private(set) var end: ReportDate?

    /// The chart never shows fewer days than this, so a single day still has a month of context.
    public static let minimumChartDays = 30

    public init(preset: OverviewRange) {
        self.length = preset.days
        self.preset = preset
        self.end = nil
    }

    private init(length: Int, preset: OverviewRange?, end: ReportDate?) {
        self.length = max(1, length)
        self.preset = preset
        self.end = end
    }

    /// A custom window, over the days the cache actually has.
    ///
    /// The ends may be given in either order, and each is pulled into `oldest...newest`. The date
    /// fields that feed this are deliberately unbounded — a field with a maximum date clamps every
    /// keystroke, so typing a month before its year snaps the whole date to the cap and throws the
    /// entry away, which is what `CustomRangeEditor` says. Bounding the answer instead of the
    /// typing is what makes them usable, and it's the same clamp `shifted` applies to a drag.
    ///
    /// One end reaching the newest day, or past it, becomes Latest.
    public static func custom(from: ReportDate, to: ReportDate,
                              oldest: ReportDate, newest: ReportDate) -> TimeWindow {
        let (low, high) = from <= to ? (from, to) : (to, from)
        // `min` with `newest` too: an empty cache reports the same day as both ends, and a
        // half-written one could report them the wrong way round.
        let floor = min(oldest, newest)
        let start = min(max(low, floor), newest)
        let finish = min(max(high, floor), newest)
        return TimeWindow(length: start.days(to: finish) + 1, preset: nil,
                          end: finish >= newest ? nil : finish)
    }

    public var isLatest: Bool { end == nil }

    // MARK: - Dates

    public func endDate(newest: ReportDate) -> ReportDate { min(end ?? newest, newest) }

    public func startDate(newest: ReportDate) -> ReportDate {
        endDate(newest: newest).adding(days: -(length - 1))
    }

    /// "9 – 15 Sep 2026". Carries the year, because once you can step back through time, "15 Sep"
    /// stops meaning this September.
    public func dateLabel(newest: ReportDate) -> String {
        Fmt.spanWithYear(from: startDate(newest: newest), to: endDate(newest: newest))
    }

    // MARK: - Moving

    /// The same end, a different preset. Switching 7D to 30D while looking at March stays in March.
    public func selecting(_ preset: OverviewRange) -> TimeWindow {
        TimeWindow(length: preset.days, preset: preset, end: end)
    }

    /// Back (negative) or forward (positive) by whole periods — a ‹ or › press.
    public func stepped(by periods: Int, oldest: ReportDate, newest: ReportDate) -> TimeWindow {
        shifted(byDays: periods * length, oldest: oldest, newest: newest)
    }

    /// Back (negative) or forward (positive) by days — a drag or a swipe on the chart.
    ///
    /// Clamped at both ends: never past the newest day, and never so far back that the window
    /// starts before the oldest cached day. A window of nothing but gaps answers no question.
    public func shifted(byDays days: Int, oldest: ReportDate, newest: ReportDate) -> TimeWindow {
        let target = endDate(newest: newest).adding(days: days)
        let lowest = min(oldest.adding(days: length - 1), newest)
        let clamped = max(lowest, min(target, newest))
        return TimeWindow(length: length, preset: preset, end: clamped >= newest ? nil : clamped)
    }

    public var latest: TimeWindow { TimeWindow(length: length, preset: preset, end: nil) }

    public func canStepBack(oldest: ReportDate, newest: ReportDate) -> Bool {
        startDate(newest: newest) > oldest
    }

    public func canStepForward(newest: ReportDate) -> Bool {
        endDate(newest: newest) < newest
    }

    // MARK: - What gets computed

    /// What the headline card totals.
    ///
    /// "Last 7 days" only while it's true. Stepped back, the same seven days are no longer the
    /// last seven, and the title says what they are instead of what they used to be.
    public func span(newest: ReportDate) -> OverviewModel.Span {
        let title: String
        if isLatest, let preset {
            title = preset.label
        } else {
            title = length == 1 ? "1 day" : "\(length) days"
        }
        return OverviewModel.Span(title: title, length: length, end: endDate(newest: newest))
    }

    /// The chart: the window plus the same stretch before it, which is what the comparison line
    /// measures against. The window itself is the shaded band at the right edge.
    public func chart(newest: ReportDate) -> (length: Int, end: ReportDate) {
        (max(Self.minimumChartDays, length * 2), endDate(newest: newest))
    }
}
