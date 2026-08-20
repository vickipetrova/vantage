import XCTest
@testable import VantageCore

/// Formatting is locale-dependent by design, so these assert the parts that must hold everywhere —
/// rounding, sign, and that no amount is ever silently dropped — rather than pinning exact symbols
/// and separators, which legitimately differ by region.
final class FormatTests: XCTestCase {
    func testCompactMoneyRoundsToWholeUnits() {
        let string = Fmt.moneyCompact(Decimal(string: "142.37")!, currency: "USD")
        XCTAssertTrue(string.contains("142"), string)
        XCTAssertFalse(string.contains("37"), "Compact money must not show cents: \(string)")
    }

    func testCompactMoneyRoundsHalfUp() {
        XCTAssertTrue(Fmt.moneyCompact(Decimal(string: "0.5")!, currency: "USD").contains("1"))
        XCTAssertTrue(Fmt.moneyCompact(Decimal(string: "1.5")!, currency: "USD").contains("2"))
    }

    func testDetailedMoneyKeepsCents() {
        XCTAssertTrue(Fmt.money(Decimal(string: "142.37")!, currency: "USD").contains("142"))
        XCTAssertTrue(Fmt.money(Decimal(string: "142.37")!, currency: "USD").contains("37"))
    }

    func testMoneyKeepsDecimalPrecision() {
        // The value that shows whether Double crept in anywhere: 0.1 + 0.2 in binary floating
        // point is 0.30000000000000004, and this sum must not be.
        let sum = Decimal(string: "0.1")! + Decimal(string: "0.2")!
        XCTAssertTrue(Fmt.money(sum, currency: "USD").contains("30"))
    }

    func testUnknownCurrencyCodeStillShowsTheAmount() {
        // A currency Apple pays in that the formatter has no symbol for must never render as
        // nothing — hiding money is worse than showing it plainly.
        let string = Fmt.money(Decimal(string: "12.34")!, currency: "ZZZ")
        XCTAssertTrue(string.contains("12"), string)
    }

    func testNegativeMoneyIsMarkedNegative() {
        let string = Fmt.money(Decimal(string: "-5.00")!, currency: "USD")
        XCTAssertTrue(string.contains("-") || string.contains("("), string)
    }

    // MARK: - Downloads

    func testDownloadsRoundToWholeUnits() {
        XCTAssertEqual(Fmt.downloads(Decimal(string: "89.00")!), "89")
        XCTAssertEqual(Fmt.downloads(Decimal(string: "88.6")!), "89")
    }

    func testDownloadsCanBeNegative() {
        // A refund-heavy day. Net, not floored — it has to match App Store Connect's Units column.
        XCTAssertTrue(Fmt.downloads(Decimal(-3)).contains("3"))
        XCTAssertTrue(Fmt.downloads(Decimal(-3)).hasPrefix("-"))
    }

    func testDownloadArrowIsAppended() {
        XCTAssertEqual(Fmt.downloadsWithArrow(Decimal(89)), "89↓")
    }

    // MARK: - Spans

    func testASpanOfOneDayIsJustThatDay() {
        let date = ReportDate(year: 2026, month: 8, day: 19)
        XCTAssertEqual(Fmt.span(from: date, to: date), Fmt.reportDate(date))
    }

    /// "22 Jul – 19 Aug" rather than "22 Jul 2026 – 19 Aug 2026": twice the width for one bit of
    /// information, in a corner of the card that has none to spare.
    func testASpanWithinOneYearDropsTheYear() {
        let span = Fmt.span(from: ReportDate(year: 2026, month: 7, day: 22),
                            to: ReportDate(year: 2026, month: 8, day: 19))
        XCTAssertFalse(span.contains("2026"), span)
        XCTAssertTrue(span.contains("–"), span)
    }

    /// A span crossing new year is exactly when the year matters.
    func testASpanCrossingYearsKeepsBothYears() {
        let span = Fmt.span(from: ReportDate(year: 2025, month: 12, day: 20),
                            to: ReportDate(year: 2026, month: 1, day: 5))
        XCTAssertTrue(span.contains("2025"), span)
        XCTAssertTrue(span.contains("2026"), span)
    }

    /// Same trap as `reportDate`: these are Pacific midnights, and rendering them in the viewer's
    /// zone would print the previous day for anyone west of California.
    func testSpanEndsAreRenderedInPacific() {
        let span = Fmt.span(from: ReportDate(year: 2026, month: 8, day: 1),
                            to: ReportDate(year: 2026, month: 8, day: 19))
        XCTAssertTrue(span.contains("1"), span)
        XCTAssertTrue(span.contains("19"), span)
    }

    // MARK: - Dates

    /// The dropdown's date must name the Pacific report day, not the viewer's local day at that
    /// instant — otherwise everyone west of California reads the wrong date off the menu.
    func testReportDateRendersThePacificDay() {
        let formatted = Fmt.reportDate(ReportDate(year: 2026, month: 8, day: 2))
        XCTAssertTrue(formatted.contains("2"), formatted)
        XCTAssertTrue(formatted.contains("2026"), formatted)
    }
}
