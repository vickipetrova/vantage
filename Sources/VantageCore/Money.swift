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
    ///
    /// **Only meaningful when `isComparable`.** Without a usable rate table this is an amount in
    /// whichever currency the row happened to lead with, and comparing two of those ranks by
    /// exchange rate rather than by money.
    public let sortKey: Decimal
    /// Whether `sortKey` may be compared with another `MoneyText`'s.
    public let isComparable: Bool

    public init(headline: String, notes: [String], sortKey: Decimal, isComparable: Bool = true) {
        self.headline = headline
        self.notes = notes
        self.sortKey = sortKey
        self.isComparable = isComparable
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

        func unconvertedText(_ bag: [String: Decimal]) -> MoneyText {
            // Prefer the display currency when it's actually in the bag: picking the largest
            // nominal amount instead means ¥15,000 (about $100) outranks $900, and the headline
            // shows the currency with the biggest number rather than the most money.
            let ranked = bag.sorted { left, right in
                if left.key == displayCurrency { return true }
                if right.key == displayCurrency { return false }
                return abs(left.value) > abs(right.value)
            }
            guard let largest = ranked.first else {
                return MoneyText(headline: format(0, displayCurrency), notes: [], sortKey: 0,
                                 isComparable: false)
            }
            let others = ranked.count - 1
            return MoneyText(
                headline: format(largest.value, largest.key),
                notes: others > 0
                    ? ["+ \(others) other \(others == 1 ? "currency" : "currencies")"] : [],
                // Not comparable across currencies, and callers must not rank on it — see
                // `isComparable`.
                sortKey: largest.value,
                isComparable: false)
        }

        guard let rates else { return unconvertedText(nonZero) }

        let (converted, unconverted) = rates.convert(nonZero, to: displayCurrency)

        // Rates exist but none of them apply — Apple pays in plenty of currencies the ECB doesn't
        // publish (TWD, AED, VND, NGN…). Falling through here would print "≈ $0.00" over real
        // revenue, which is the same lie the no-rates path was written to avoid, arriving through a
        // different door.
        if converted == 0, !unconverted.isEmpty {
            return unconvertedText(unconverted)
        }
        let notes = unconverted.sorted { $0.key < $1.key }.map {
            "+ \(Fmt.money($0.value, currency: $0.key)) — no ECB rate"
        }
        let marker = compact ? "" : "≈ "
        return MoneyText(headline: marker + format(converted, displayCurrency),
                         notes: notes, sortKey: converted)
    }
}
