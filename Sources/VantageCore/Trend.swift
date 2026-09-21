import Foundation

/// What a trend chart plots.
///
/// Single-select, unlike `Prefs.metrics` — that set decides what the `↓` figure counts everywhere,
/// which is a different question from which one line to draw.
public enum TrendSeries: Hashable, Sendable {
    /// Converted proceeds — what reaches you. Unavailable without a rate table, and says so rather
    /// than drawing zero.
    case proceeds
    /// Converted gross customer spend — what changed hands, before Apple's cut.
    case sales
    case metric(Metric)
    /// App Store engagement, from the analytics reports rather than the sales reports. Absent for
    /// days Apple hasn't finalised — about two days — and for days before the report request
    /// existed.
    case impressions
    case pageViews

    public var label: String {
        switch self {
        case .proceeds: return "Proceeds"
        case .sales: return "Sales"
        case .metric(let metric): return metric.label
        case .impressions: return "Impressions"
        case .pageViews: return "Page views"
        }
    }

    /// Everything offerable: money first, then units, then engagement.
    public static var displayOrder: [TrendSeries] {
        [.proceeds, .sales] + Metric.displayOrder.map(TrendSeries.metric) + [.impressions, .pageViews]
    }

    /// Whether this series is money, and so needs a rate table.
    var isMoney: Bool {
        switch self {
        case .proceeds, .sales: return true
        case .metric, .impressions, .pageViews: return false
        }
    }

    // MARK: - Storage

    /// Round-trips through `UserDefaults` as a string, so a build that adds a metric doesn't
    /// invalidate a stored choice.
    public var rawValue: String {
        switch self {
        case .proceeds: return "proceeds"
        case .sales: return "sales"
        case .metric(let metric): return "metric:\(metric.rawValue)"
        case .impressions: return "impressions"
        case .pageViews: return "pageViews"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "proceeds" {
            self = .proceeds
            return
        }
        if rawValue == "sales" {
            self = .sales
            return
        }
        if rawValue == "impressions" {
            self = .impressions
            return
        }
        if rawValue == "pageViews" {
            self = .pageViews
            return
        }
        guard rawValue.hasPrefix("metric:"),
              let metric = Metric(rawValue: String(rawValue.dropFirst("metric:".count)))
        else { return nil }
        self = .metric(metric)
    }
}

/// One day on the chart.
public struct TrendPoint: Equatable, Sendable {
    public let date: ReportDate
    /// `nil` for a day that isn't cached. **A gap is not a zero** — a day Vantage never fetched and
    /// a day that earned nothing are different facts, and plotting the first as the second draws a
    /// crash that didn't happen.
    public let value: Decimal?
    /// The same value mapped to 0…1 for drawing. Geometry, not money — this is the only place a
    /// figure becomes a `Double`, and nothing downstream of it is displayed as a number.
    public let unit: Double?

    public init(date: ReportDate, value: Decimal?, unit: Double?) {
        self.date = date
        self.value = value
        self.unit = unit
    }
}

public struct TrendData: Equatable, Sendable {
    /// Oldest first, one entry per day in the window whether or not it's cached.
    public let points: [TrendPoint]
    /// The bottom and top of the drawn range, already widened to include zero.
    public let lower: Decimal
    public let upper: Decimal
    /// Where the zero line sits in 0…1, or `nil` when zero is the floor and needs no line.
    public let zeroUnit: Double?
    /// The top and bottom of the range, formatted for the axis — money for proceeds, counts for
    /// units. Done here rather than in the view so the axis can't disagree with the figures above
    /// it about how a number is written.
    public let upperLabel: String
    public let lowerLabel: String
    /// Set when the series can't be drawn at all, in words the panel can show.
    public let unavailable: String?

    public var hasData: Bool { points.contains { $0.value != nil } }
}

public enum Trend {
    /// Builds a chart series.
    ///
    /// - Parameters:
    ///   - days: any order; only the window is used.
    ///   - end: the newest day on the chart, inclusive.
    ///   - appleID: restricts to one app. `nil` totals the whole portfolio.
    ///   - engagement: analytics days, used only by `.impressions` and `.pageViews`.
    public static func series(days: [DaySales],
                              series: TrendSeries,
                              length: Int,
                              endingAt end: ReportDate,
                              rates: FXRates?,
                              displayCurrency: String,
                              appleID: String? = nil,
                              engagement: [EngagementDay] = []) -> TrendData {
        // Proceeds across several currencies is not a number without rates, and the honest answer
        // is to draw nothing and say why — the same rule the headline figure follows.
        if series.isMoney, rates == nil {
            return TrendData(points: [], lower: 0, upper: 0, zeroUnit: nil,
                             upperLabel: "", lowerLabel: "",
                             unavailable: "Exchange rates unavailable — can't chart money")
        }

        // Engagement comes from a different API with a different schedule, so it has its own
        // lookup. Everything below — gaps, the range including zero, the labels — is the same.
        if series == .impressions || series == .pageViews {
            let byDate = Dictionary(engagement.map { ($0.date, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let dates = end.lastDays(length).sorted()
            var values: [ReportDate: Decimal] = [:]
            for date in dates {
                guard let day = byDate[date] else { continue }  // Absent stays absent.
                values[date] = series == .impressions ? day.impressions : day.pageViews
            }
            return numeric(values: values, dates: dates, series: series,
                           displayCurrency: displayCurrency)
        }

        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let dates = end.lastDays(length).sorted()

        var values: [ReportDate: Decimal] = [:]
        for date in dates {
            guard let day = byDate[date] else { continue }  // Absent stays absent.
            let resolved = value(of: series, in: day, appleID: appleID,
                                 rates: rates, displayCurrency: displayCurrency)
            guard let amount = resolved.value else { continue }
            // A day holding money the ECB doesn't publish a rate for is **plotted, not dropped**.
            //
            // An earlier version made it a gap, reasoning that the convertible part alone
            // understates. True — but a gap says "no data" about a day we have data for, and the
            // result on a real portfolio paid partly in QAR, AED and COP was a chart full of holes
            // that looked like failed fetches. The headline card handles this exact case by showing
            // the converted total and naming what it leaves out; the chart now matches, because a
            // chart that behaves differently from the number above it is its own kind of wrong.
            values[date] = amount
        }

        return numeric(values: values, dates: dates, series: series, displayCurrency: displayCurrency)
    }

    /// The drawn shape, once the values are known: range including zero, gaps preserved, labels.
    private static func numeric(values: [ReportDate: Decimal],
                                dates: [ReportDate],
                                series: TrendSeries,
                                displayCurrency: String) -> TrendData {
        let present = values.values
        // The drawn range always includes zero: a downloads chart whose floor is 40 exaggerates
        // every wobble, and one with refunds in it needs the axis visible to read the sign.
        let lower = min(0, present.min() ?? 0)
        let upper = max(0, present.max() ?? 0)
        let span = upper - lower

        let points = dates.map { date -> TrendPoint in
            guard let value = values[date] else { return TrendPoint(date: date, value: nil, unit: nil) }
            // span == 0 means every cached day is exactly zero. Flat along the floor, not a
            // divide-by-zero and not a line through the middle pretending to be data.
            let unit = span == 0 ? 0 : Self.double((value - lower) / span)
            return TrendPoint(date: date, value: value, unit: unit)
        }

        return TrendData(points: points, lower: lower, upper: upper,
                         // Only worth a line when it isn't already the floor.
                         zeroUnit: lower < 0 && span != 0 ? Self.double(-lower / span) : nil,
                         upperLabel: label(upper, for: series, displayCurrency: displayCurrency),
                         lowerLabel: label(lower, for: series, displayCurrency: displayCurrency),
                         unavailable: nil)
    }

    private static func label(_ value: Decimal, for series: TrendSeries,
                              displayCurrency: String) -> String {
        switch series {
        // Compact: an axis label is read for magnitude, and cents on it are four characters nobody
        // acts on — the same call the menu bar title makes.
        case .proceeds, .sales: return Fmt.moneyCompact(value, currency: displayCurrency)
        case .metric, .impressions, .pageViews: return Fmt.downloads(value)
        }
    }

    /// One day's value. `value` is nil when the day can't be stated as a number at all; `partial`
    /// marks a day that could be stated but left something out.
    private static func value(of series: TrendSeries, in day: DaySales, appleID: String?,
                              rates: FXRates?, displayCurrency: String)
        -> (value: Decimal?, partial: Bool) {
        switch series {
        case .proceeds, .sales:
            let proceeds: [String: Decimal]
            let isSales = series == .sales
            if let appleID {
                let app = day.apps.first { $0.appleID == appleID }
                proceeds = (isSales ? app?.sales : app?.proceeds) ?? [:]
            } else {
                proceeds = isSales ? day.sales : day.proceeds
            }
            guard let rates else { return (nil, true) }
            // Straight to the rate table rather than through `Money`, so the unconverted remainder
            // is visible here — `Money` collapses it into a note the chart can't render.
            let (converted, unconverted) = rates.convert(proceeds.filter { $0.value != 0 },
                                                         to: displayCurrency)
            // Only a day with money and *nothing* convertible is unplottable: there is no number to
            // draw. A day that is partly convertible is drawn at the part that is, and flagged.
            if converted == 0, !unconverted.isEmpty { return (nil, true) }
            return (converted, !unconverted.isEmpty)
        case .metric(let metric):
            if let appleID {
                guard let app = day.apps.first(where: { $0.appleID == appleID }) else {
                    return (0, false)
                }
                return (Metric.units(in: app, metrics: [metric]), false)
            }
            return (metric.units(in: day), false)
        case .impressions, .pageViews:
            // Handled earlier in `series(...)`, which never calls this function for engagement.
            return (nil, true)
        }
    }

    /// The single Decimal→Double crossing in the app, isolated so it's easy to check that nothing
    /// displayed as a number passes through it.
    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
