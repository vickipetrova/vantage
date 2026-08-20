import Foundation

/// What to print for a bag of per-currency proceeds, and what to say underneath it.
///
/// A day's proceeds arrive as several currencies at once, and collapsing them into one number is a
/// display decision with three different right answers depending on whether exchange rates are
/// available. `MoneyText` is that decision's result: the figure, whatever the figure doesn't cover,
/// and a single comparable number for ranking.
public struct MoneyText: Equatable, Sendable {
    /// The figure itself, already formatted.
    public let headline: String
    /// Lines the caller should show underneath, accounting for anything the headline leaves out.
    public let notes: [String]
    /// The converted total, for ranking apps against each other. Never displayed.
    public let sortKey: Decimal

    public init(headline: String, notes: [String], sortKey: Decimal) {
        self.headline = headline
        self.notes = notes
        self.sortKey = sortKey
    }
}

/// Turns per-currency proceeds into something printable, degrading honestly when rates are missing.
///
/// This lives in `VantageCore` rather than in the view for one reason: it is the only display logic
/// in the app that makes real decisions about money, and the decision it gets wrong is invisible.
/// See `testNeverPrintsAConvertedLookingZero` — an earlier version returned 0 when there was no
/// rate table, so a day with real revenue rendered as `≈ $0.00`, indistinguishable from a day that
/// earned nothing.
public enum Money {
    /// Formats proceeds for display.
    ///
    /// With rates: one figure in `displayCurrency`, marked `≈`, plus a note naming any currency the
    /// ECB doesn't publish. Without rates: the largest single currency **in its own currency**,
    /// plus a count of the others.
    ///
    /// `compact` is the menu bar's form — no cents, and no `≈`. The marker is a permanent fixture
    /// of the title rather than a warning about any particular number, and at that size it reads as
    /// clutter. The panel keeps it, along with the line naming the rate date; that's where someone
    /// checking a figure is looking.
    public static func text(for proceeds: [String: Decimal],
                            rates: FXRates?,
                            displayCurrency: String,
                            compact: Bool = false) -> MoneyText {
        let format = compact ? Fmt.moneyCompact : Fmt.money
        let nonZero = proceeds.filter { $0.value != 0 }

        guard let rates else {
            let ranked = nonZero.sorted { abs($0.value) > abs($1.value) }
            guard let largest = ranked.first else {
                return MoneyText(headline: format(0, displayCurrency), notes: [], sortKey: 0)
            }
            let others = ranked.count - 1
            return MoneyText(
                headline: format(largest.value, largest.key),
                notes: others > 0
                    ? ["+ \(others) other \(others == 1 ? "currency" : "currencies")"] : [],
                sortKey: largest.value)
        }

        let (converted, unconverted) = rates.convert(nonZero, to: displayCurrency)
        let notes = unconverted.sorted { $0.key < $1.key }.map {
            "+ \(Fmt.money($0.value, currency: $0.key)) — no ECB rate"
        }
        let marker = compact ? "" : "≈ "
        return MoneyText(headline: marker + format(converted, displayCurrency),
                         notes: notes, sortKey: converted)
    }
}
