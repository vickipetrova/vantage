import Foundation

/// Currency, unit counts and dates as strings. Pure formatting, no state, no AppKit — so every
/// rounding decision in the app is covered by `swift test`.
public enum Fmt {
    /// The glyph after a download count. A downwards arrow, not an emoji: it inherits the menu
    /// bar's font and colour instead of dropping a coloured picture into the title.
    public static let downloadArrow = "↓"

    // MARK: - Money

    /// Money for the menu bar: symbol, no decimals, no grouping ambiguity. `$142`.
    ///
    /// Rounded to whole units because a menu bar title that reads `$142.37` is four characters of
    /// precision nobody acts on, and it makes the title jitter. The dropdown shows the cents.
    public static func moneyCompact(_ amount: Decimal, currency: String) -> String {
        format(amount, currency: currency, fractionDigits: 0)
    }

    /// Money for the dropdown: symbol and two decimals. `$142.37`.
    public static func money(_ amount: Decimal, currency: String) -> String {
        format(amount, currency: currency, fractionDigits: 2)
    }

    /// Currency formatters are expensive to build and there are only a handful of
    /// (currency, precision) pairs in play, so they're built once and reused.
    ///
    /// A panel render formats money roughly twice per app row; at a few hundred apps that was
    /// hundreds of `NumberFormatter` constructions per frame, and the panel rerenders every time an
    /// app icon arrives. `NumberFormatter` is not thread-safe, so this is confined to the main
    /// thread — which is where every caller already is, since all of them are rendering.
    private static var currencyFormatters: [String: NumberFormatter] = [:]

    private static func currencyFormatter(_ currency: String,
                                          _ fractionDigits: Int) -> NumberFormatter {
        let key = "\(currency)|\(fractionDigits)"
        if let cached = currencyFormatters[key] { return cached }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        // Bankers' rounding would make daily totals that don't sum to the weekly one.
        formatter.roundingMode = .halfUp
        currencyFormatters[key] = formatter
        return formatter
    }

    private static let unitFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private static func format(_ amount: Decimal, currency: String, fractionDigits: Int) -> String {
        let formatter = currencyFormatter(currency, fractionDigits)
        // NSDecimalNumber, not Double: the whole point of carrying Decimal this far is not to
        // hand the money to binary floating point at the last step.
        let number = NSDecimalNumber(decimal: amount)
        if let string = formatter.string(from: number) { return string }
        // An unknown or misspelled currency code leaves NumberFormatter without a symbol. Falling
        // back to "123.45 XYZ" is honest; returning "–" would hide real money.
        return "\(number.stringValue) \(currency)"
    }

    // MARK: - Units

    /// A download count. Decimal because Apple's Units column is `DECIMAL(18,2)` — partial refunds
    /// really do produce fractions — but nobody wants to read `89.00 downloads`, so it's rounded
    /// for display. Negative counts are shown as-is; they mean refunds outweighed sales.
    public static func downloads(_ units: Decimal) -> String {
        let rounded = NSDecimalNumber(decimal: units)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0,
                raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false))
        return unitFormatter.string(from: rounded) ?? rounded.stringValue
    }

    /// `89↓`, for the menu bar and the per-app rows.
    public static func downloadsWithArrow(_ units: Decimal) -> String {
        downloads(units) + downloadArrow
    }

    /// A rate, to one decimal place. `3.4%`.
    ///
    /// One decimal rather than none: page view rates live in the low single digits, and rounding
    /// 3.4% and 2.6% both to "3%" hides the only movement there is.
    public static func percent(_ value: Decimal) -> String {
        let rounded = NSDecimalNumber(decimal: value).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 1, raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false))
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return (formatter.string(from: rounded) ?? rounded.stringValue) + "%"
    }

    /// A day against a baseline: `▲ 24%`, `▼ 8%`, or `—` when there's nothing to compare with.
    ///
    /// Percentages of a zero baseline are undefined, not infinite, and a day's first sale is not a
    /// hundred-percent rise — so those cases say "new" rather than inventing a number.
    public static func change(from baseline: Decimal, to value: Decimal) -> String {
        // A week that only refunded is not growth. "new" is for a first sale, so it needs the
        // value to actually be positive.
        guard baseline != 0 else {
            if value == 0 { return "—" }
            return value > 0 ? "new" : "down from nothing"
        }
        let ratio = (value - baseline) / abs(baseline) * 100
        let rounded = NSDecimalNumber(decimal: ratio).rounding(
            accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
                raiseOnUnderflow: false, raiseOnDivideByZero: false)).intValue
        if rounded == 0 { return "— level" }
        return rounded > 0 ? "▲ \(rounded)%" : "▼ \(abs(rounded))%"
    }

    // MARK: - Dates

    /// A report date, written the way the reader's region writes dates. Medium style, so
    /// "2 Aug 2026" rather than an all-numeric form that means different days on different
    /// continents — this string exists specifically to remove ambiguity about which day is meant.
    public static func reportDate(_ date: ReportDate) -> String {
        dayFormatter.string(from: date.startOfDay)
    }

    /// A span of report days, for a header that covers more than one.
    ///
    /// Drops the year while both ends share it — "22 Jul – 19 Aug" rather than
    /// "22 Jul 2026 – 19 Aug 2026", which is twice the width for one bit of information. A span
    /// crossing new year keeps both years, because that's exactly when the year matters.
    public static func span(from start: ReportDate, to end: ReportDate) -> String {
        guard start != end else { return reportDate(start) }
        if start.year == end.year {
            return "\(shortDayFormatter.string(from: start.startOfDay))"
                + " – \(shortDayFormatter.string(from: end.startOfDay))"
        }
        return "\(reportDate(start)) – \(reportDate(end))"
    }

    /// A review's date. A real instant rather than a report day, so it stays in the local zone —
    /// unlike everything derived from a sales report, which is Pacific.
    public static func reviewDate(_ date: Date) -> String {
        reviewDateFormatter.string(from: date)
    }

    /// Local wall-clock time in the user's 12- or 24-hour preference, for "fetched HH:mm".
    public static func clock(_ date: Date) -> String {
        clockFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        // The date being formatted is a Pacific midnight. Rendering it in the viewer's zone would
        // print the previous day for anyone west of Pacific and, worse, would be right most of the
        // time — so it would only be wrong occasionally, which is harder to notice.
        formatter.timeZone = ReportDate.pacific
        return formatter
    }()

    private static let shortDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        // Template rather than a literal pattern: "d MMM" and "MMM d" are both right, in different
        // regions, and the template picks whichever the reader expects.
        formatter.setLocalizedDateFormatFromTemplate("dMMM")
        formatter.timeZone = ReportDate.pacific
        return formatter
    }()

    private static let reviewDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        // Region-driven: 13:45 or 1:45 PM as the user expects. A hardcoded "HH:mm" is wrong for
        // most of the world. This one is a real instant, so it stays in the local zone.
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()
}
