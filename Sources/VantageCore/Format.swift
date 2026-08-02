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

    private static func format(_ amount: Decimal, currency: String, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = .current
        formatter.currencyCode = currency
        formatter.minimumFractionDigits = fractionDigits
        formatter.maximumFractionDigits = fractionDigits
        // Bankers' rounding would make daily totals that don't sum to the weekly one.
        formatter.roundingMode = .halfUp
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.maximumFractionDigits = 0
        return formatter.string(from: rounded) ?? rounded.stringValue
    }

    /// `89↓`, for the menu bar and the per-app rows.
    public static func downloadsWithArrow(_ units: Decimal) -> String {
        downloads(units) + downloadArrow
    }

    // MARK: - Menu text

    /// Breaks a long message into menu-width lines.
    ///
    /// `NSMenu` sizes itself to its widest item and never wraps, so a single long sentence stretches
    /// the dropdown clear across the screen. Apple's error strings are long sentences. Wrapping at a
    /// fixed column keeps a menu the width of a menu.
    ///
    /// Measured in characters rather than points, which is approximate — but the menu is one font
    /// at one size, and being roughly right here is worth more than the layout pass it would take
    /// to be exactly right.
    public static func wrap(_ text: String, width: Int = 46) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty {
                current = String(word)
            } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        // A single word longer than the limit — a filesystem path, typically — is left whole
        // rather than chopped mid-token, which would make it unreadable and unselectable.
        return lines.isEmpty ? [text] : lines
    }

    // MARK: - Dates

    /// A report date, written the way the reader's region writes dates. Medium style, so
    /// "2 Aug 2026" rather than an all-numeric form that means different days on different
    /// continents — this string exists specifically to remove ambiguity about which day is meant.
    public static func reportDate(_ date: ReportDate) -> String {
        dayFormatter.string(from: date.startOfDay)
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

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        // Region-driven: 13:45 or 1:45 PM as the user expects. A hardcoded "HH:mm" is wrong for
        // most of the world. This one is a real instant, so it stays in the local zone.
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter
    }()
}
