import XCTest
@testable import VantageCore

/// Pins the behaviour the menu bar title and the panel both depend on.
///
/// These exist because this logic moved out of the view layer in v0.2, and because the one bug it
/// has already had — a converted-looking zero standing in for real revenue — is silent. Assertions
/// avoid pinning currency symbols and separators, which legitimately differ by region.
final class MoneyTests: XCTestCase {
    /// EUR is the ECB's base and is always 1. USD and GBP are plausible, not current — nothing here
    /// depends on the actual rate, only on the arithmetic being applied at all.
    private let rates = FXRates(
        perEUR: ["EUR": 1, "USD": Decimal(string: "1.10")!, "GBP": Decimal(string: "0.85")!],
        published: "2026-08-19",
        fetchedAt: Date())

    // MARK: - With rates

    func testConvertsToTheDisplayCurrencyAndMarksItApproximate() {
        let text = Money.text(for: ["EUR": 100], rates: rates, displayCurrency: "USD")
        XCTAssertTrue(text.headline.hasPrefix("≈ "), text.headline)
        XCTAssertTrue(text.headline.contains("110"), text.headline)
        XCTAssertEqual(text.sortKey, 110)
        XCTAssertTrue(text.notes.isEmpty)
    }

    func testSumsSeveralCurrenciesIntoOneFigure() {
        let text = Money.text(for: ["EUR": 100, "GBP": Decimal(string: "8.50")!],
                              rates: rates, displayCurrency: "USD")
        // 100 EUR -> 110 USD, 8.50 GBP -> 11 USD.
        XCTAssertEqual(text.sortKey, 121)
        XCTAssertTrue(text.notes.isEmpty)
    }

    func testNamesCurrenciesTheECBDoesNotPublish() {
        let text = Money.text(for: ["EUR": 100, "XYZ": 50], rates: rates, displayCurrency: "USD")
        XCTAssertEqual(text.sortKey, 110, "An unconvertible currency must not enter the total")
        XCTAssertEqual(text.notes.count, 1)
        XCTAssertTrue(text.notes[0].contains("XYZ"), text.notes[0])
        XCTAssertTrue(text.notes[0].contains("no ECB rate"), text.notes[0])
    }

    func testUnconvertedNotesAreOrderedSoTheOutputIsStable() {
        let text = Money.text(for: ["ZZZ": 1, "AAA": 2, "MMM": 3],
                              rates: rates, displayCurrency: "USD")
        XCTAssertEqual(text.notes.count, 3)
        // Dictionary iteration order is not stable; the notes must be.
        XCTAssertTrue(text.notes[0].contains("AAA"), text.notes[0])
        XCTAssertTrue(text.notes[1].contains("MMM"), text.notes[1])
        XCTAssertTrue(text.notes[2].contains("ZZZ"), text.notes[2])
    }

    // MARK: - Without rates

    /// The regression this whole type exists to prevent.
    func testNeverPrintsAConvertedLookingZero() {
        let text = Money.text(for: ["JPY": 50_000], rates: nil, displayCurrency: "USD")
        XCTAssertFalse(text.headline.contains("≈"),
                       "No rates means nothing was converted, so nothing may claim to be")
        XCTAssertTrue(text.headline.contains("50"), text.headline)
        XCTAssertEqual(text.sortKey, 50_000)
    }

    func testWithoutRatesShowsTheLargestCurrencyInItsOwnCurrency() {
        let text = Money.text(for: ["EUR": 10, "USD": 100], rates: nil, displayCurrency: "GBP")
        XCTAssertEqual(text.sortKey, 100)
        XCTAssertEqual(text.notes, ["+ 1 other currency"])
    }

    func testWithoutRatesCountsTheRemainingCurrencies() {
        let text = Money.text(for: ["EUR": 10, "USD": 100, "GBP": 5],
                              rates: nil, displayCurrency: "USD")
        XCTAssertEqual(text.notes, ["+ 2 other currencies"])
    }

    /// Largest by magnitude, not by signed value — a big refund day is still the currency that
    /// matters most, and ranking by signed value would surface a trivial positive instead.
    func testWithoutRatesRanksByMagnitudeSoRefundsStillWin() {
        let text = Money.text(for: ["USD": -500, "EUR": 1], rates: nil, displayCurrency: "USD")
        XCTAssertEqual(text.sortKey, -500)
    }

    // MARK: - Empty and zero

    func testNoProceedsRendersZeroInTheDisplayCurrency() {
        let text = Money.text(for: [:], rates: nil, displayCurrency: "USD")
        XCTAssertTrue(text.headline.contains("0"), text.headline)
        XCTAssertEqual(text.sortKey, 0)
        XCTAssertTrue(text.notes.isEmpty)
    }

    /// A currency present with a zero balance is not a currency worth naming.
    func testZeroBalancesAreNotCountedAsOtherCurrencies() {
        let text = Money.text(for: ["USD": 100, "EUR": 0], rates: nil, displayCurrency: "USD")
        XCTAssertTrue(text.notes.isEmpty, "\(text.notes)")
    }

    // MARK: - Compact, the menu bar's form

    /// The menu bar title must not carry `≈`. It's a permanent fixture there rather than a warning
    /// about any particular number, and it reads as clutter at that size.
    func testCompactOmitsTheApproximationMarker() {
        let text = Money.text(for: ["EUR": 100], rates: rates, displayCurrency: "USD", compact: true)
        XCTAssertFalse(text.headline.contains("≈"), text.headline)
    }

    func testCompactDropsTheCents() {
        let text = Money.text(for: ["USD": Decimal(string: "142.37")!],
                              rates: rates, displayCurrency: "USD", compact: true)
        XCTAssertTrue(text.headline.contains("142"), text.headline)
        XCTAssertFalse(text.headline.contains("37"), "Compact must not show cents: \(text.headline)")
    }

    func testCompactStillReportsTheFullSortKey() {
        let text = Money.text(for: ["USD": Decimal(string: "142.37")!],
                              rates: rates, displayCurrency: "USD", compact: true)
        XCTAssertEqual(text.sortKey, Decimal(string: "142.37")!,
                       "Rounding is for display only; ranking uses the real number")
    }

    // MARK: - Decimal discipline

    func testMoneyNeverPassesThroughBinaryFloatingPoint() {
        // 0.1 + 0.2 is 0.30000000000000004 in Double. Three such amounts, converted at 1.10,
        // must come out exactly 0.33 — a Double anywhere in the path shows up in the last digits.
        let proceeds = ["EUR": Decimal(string: "0.1")! + Decimal(string: "0.2")!]
        let text = Money.text(for: proceeds, rates: rates, displayCurrency: "USD")
        XCTAssertEqual(text.sortKey, Decimal(string: "0.33")!)
    }
}
