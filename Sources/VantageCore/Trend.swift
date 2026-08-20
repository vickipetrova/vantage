import Foundation

/// What a trend chart plots.
///
/// Single-select, unlike `Prefs.metrics` — that set decides what the `↓` figure counts everywhere,
/// which is a different question from which one line to draw.
public enum TrendSeries: Hashable, Sendable {
    /// Converted proceeds. Unavailable without a rate table, and says so rather than drawing zero.
    case proceeds
    case metric(Metric)

    public var label: String {
        switch self {
        case .proceeds: return "Proceeds"
        case .metric(let metric): return metric.label
        }
    }

    /// Everything offerable, proceeds first.
    public static var displayOrder: [TrendSeries] {
        [.proceeds] + Metric.displayOrder.map(TrendSeries.metric)
    }

    // MARK: - Storage

    /// Round-trips through `UserDefaults` as a string, so a build that adds a metric doesn't
    /// invalidate a stored choice.
    public var rawValue: String {
        switch self {
        case .proceeds: return "proceeds"
        case .metric(let metric): return "metric:\(metric.rawValue)"
        }
    }

    public init?(rawValue: String) {
        if rawValue == "proceeds" {
            self = .proceeds
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
    public static func series(days: [DaySales],
                              series: TrendSeries,
                              length: Int,
                              endingAt end: ReportDate,
                              rates: FXRates?,
                              displayCurrency: String,
                              appleID: String? = nil) -> TrendData {
        // Proceeds across several currencies is not a number without rates, and the honest answer
        // is to draw nothing and say why — the same rule the headline figure follows.
        if case .proceeds = series, rates == nil {
            return TrendData(points: [], lower: 0, upper: 0, zeroUnit: nil,
                             upperLabel: "", lowerLabel: "",
                             unavailable: "Exchange rates unavailable — can't chart proceeds")
        }

        let byDate = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        let dates = end.lastDays(length).sorted()

        var values: [ReportDate: Decimal] = [:]
        for date in dates {
            guard let day = byDate[date] else { continue }  // Absent stays absent.
            values[date] = value(of: series, in: day, appleID: appleID,
                                 rates: rates, displayCurrency: displayCurrency)
        }

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
        case .proceeds: return Fmt.moneyCompact(value, currency: displayCurrency)
        case .metric: return Fmt.downloads(value)
        }
    }

    private static func value(of series: TrendSeries, in day: DaySales, appleID: String?,
                              rates: FXRates?, displayCurrency: String) -> Decimal {
        switch series {
        case .proceeds:
            let proceeds: [String: Decimal]
            if let appleID {
                proceeds = day.apps.first { $0.appleID == appleID }?.proceeds ?? [:]
            } else {
                proceeds = day.proceeds
            }
            return Money.text(for: proceeds, rates: rates,
                              displayCurrency: displayCurrency).sortKey
        case .metric(let metric):
            if let appleID {
                guard let app = day.apps.first(where: { $0.appleID == appleID }) else { return 0 }
                return Metric.units(in: app, metrics: [metric])
            }
            return metric.units(in: day)
        }
    }

    /// The single Decimal→Double crossing in the app, isolated so it's easy to check that nothing
    /// displayed as a number passes through it.
    private static func double(_ value: Decimal) -> Double {
        NSDecimalNumber(decimal: value).doubleValue
    }
}
