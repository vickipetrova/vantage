import XCTest
@testable import VantageCore

/// The critical test file in this repo.
///
/// Every other kind of bug here is visible — a broken menu looks broken. A parsing bug produces a
/// number that looks exactly like a real one, and nobody checks a figure that seems plausible.
/// So the assertions are exact, and every fixture exists because of a specific way Apple's format
/// can mislead a reader.
final class ReportParserTests: XCTestCase {
    private let date = ReportDate(year: 2026, month: 8, day: 1)

    /// Fixtures are read from `Tests/Fixtures/` by path rather than through a resource bundle, so
    /// they stay plain files anyone can open, diff and edit.
    private func fixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)          // …/Tests/VantageCoreTests/ThisFile.swift
            .deletingLastPathComponent()                    // …/Tests/VantageCoreTests
            .deletingLastPathComponent()                    // …/Tests
            .appendingPathComponent("Fixtures/\(name)")
        return try String(contentsOf: root, encoding: .utf8)
    }

    private func parse(_ name: String) throws -> DaySales {
        ReportParser.parse(try fixture(name), date: date, fetchedAt: Date())
    }

    private func decimal(_ string: String) -> Decimal {
        Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))!
    }

    // MARK: - A believable day

    /// Swift treats CRLF as a single `Character`, so a parser that splits on "\n" and strips a
    /// trailing "\r" afterwards reads a CRLF file as one enormous line and finds nothing. This one
    /// normalizes first; the sibling analytics parser did not, and shipped with the bug until a
    /// test found it.
    func testCRLFLineEndingsParseTheSameAsLF() {
        let lf = "Provider\tSKU\tDeveloper Proceeds\tUnits\tApple Identifier\tTitle\t"
            + "Product Type Identifier\tCurrency of Proceeds\tParent Identifier\n"
            + "APPLE\tSKU1\t1.50\t10\t123\tMy App\t1\tUSD\t\n"
        let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
        let date = ReportDate(year: 2026, month: 8, day: 19)

        let fromLF = ReportParser.parse(lf, date: date, fetchedAt: Date())
        let fromCRLF = ReportParser.parse(crlf, date: date, fetchedAt: Date())

        XCTAssertEqual(fromLF.downloads, 10)
        XCTAssertEqual(fromCRLF.downloads, fromLF.downloads)
        XCTAssertEqual(fromCRLF.proceeds, fromLF.proceeds)
    }

    func testTypicalDayTotals() throws {
        let day = try parse("typical-day.tsv")
        XCTAssertEqual(day.downloads, 133)
        XCTAssertEqual(day.proceeds["USD"], decimal("84.00"))
        XCTAssertEqual(day.proceeds["CZK"], decimal("100.00"))
        XCTAssertEqual(day.proceeds["GBP"], decimal("4.80"))
        XCTAssertEqual(day.proceeds.count, 3)
        XCTAssertEqual(day.skippedRows, 0)
        XCTAssertEqual(day.origin, .observed)
        XCTAssertEqual(day.date, date)
    }

    /// Grouped by Apple Identifier, not by Title: an In-App Purchase row puts the product ID in the
    /// Title column, so grouping by title would split one app into several.
    func testTypicalDayGroupsByApp() throws {
        let day = try parse("typical-day.tsv")
        XCTAssertEqual(day.apps.count, 2)

        let one = try XCTUnwrap(day.apps.first { $0.appleID == "1111111111" })
        XCTAssertEqual(one.downloads, 108)
        XCTAssertEqual(one.proceeds["USD"], decimal("84.00"))
        XCTAssertEqual(one.proceeds["GBP"], decimal("4.80"))

        let two = try XCTUnwrap(day.apps.first { $0.appleID == "2222222222" })
        XCTAssertEqual(two.downloads, 25)
        XCTAssertEqual(two.proceeds["CZK"], decimal("100.00"))
    }

    func testPerAppTotalsSumToTheDayTotal() throws {
        let day = try parse("typical-day.tsv")
        XCTAssertEqual(day.apps.reduce(Decimal(0)) { $0 + $1.downloads }, day.downloads)
        for (currency, total) in day.proceeds {
            let summed = day.apps.reduce(Decimal(0)) { $0 + ($1.proceeds[currency] ?? 0) }
            XCTAssertEqual(summed, total, "per-app \(currency) doesn't sum to the day total")
        }
    }

    // MARK: - What counts as a download

    func testUpdatesAndRedownloadsAreNotDownloads() throws {
        let day = try parse("updates-and-redownloads.tsv")
        // 833 units in the file; exactly 3 of them are acquisitions.
        XCTAssertEqual(day.downloads, 3)
        XCTAssertTrue(day.proceeds.isEmpty)
        XCTAssertEqual(day.skippedRows, 0)
    }

    /// The plan's map said "1, 1F, 1T family" and would have silently dropped every Mac sale.
    func testMacAndBundleAndCustomAppCodesAllCount() throws {
        let day = try parse("mac-and-bundles.tsv")
        // 10 + 2 + 3 + 1 + 5 + 2 + 1 units across F1, F1-B, 1-B, 1E, 1T, 1EU, 1EP.
        XCTAssertEqual(day.downloads, 24)
        // 50.00 + 20.00 + 6.00 + 100.00 + 5.00 + 100.00 + 25.00
        XCTAssertEqual(day.proceeds["USD"], decimal("306.00"))
    }

    /// Apple's sample report uses 1AY, which appears nowhere in Apple's product type table. An
    /// unknown code must count as revenue and never as an install.
    func testUnknownProductTypesCountAsRevenueOnly() throws {
        let day = try parse("unknown-product-types.tsv")
        XCTAssertEqual(day.downloads, 4)
        XCTAssertEqual(day.proceeds["USD"], decimal("22.79"))
        XCTAssertEqual(day.skippedRows, 0, "an unknown type is not a malformed row")
    }

    // MARK: - Refunds

    func testRefundsSubtractFromBothCounts() throws {
        let day = try parse("refunds.tsv")
        XCTAssertEqual(day.downloads, 50)         // 100 sold, 50 refunded
        XCTAssertEqual(day.proceeds["USD"], decimal("21.00"))  // 70.00 − 35.00 − 14.00
    }

    /// Negative is the honest answer, and it's what App Store Connect's Units column shows.
    func testNetCanGoNegativeAndIsNotFloored() throws {
        let day = try parse("refunds-exceed-sales.tsv")
        XCTAssertEqual(day.downloads, -20)
        XCTAssertEqual(day.proceeds["USD"], decimal("-14.00"))
    }

    // MARK: - Blank currency

    /// Free-app rows in a real report carry units and no Currency of Proceeds at all. Bucketing
    /// them under "" would put a nameless currency in the dropdown.
    func testFreeAppRowsDontCreateAnEmptyCurrency() throws {
        let day = try parse("free-apps-blank-currency.tsv")
        XCTAssertEqual(day.downloads, 3)
        XCTAssertEqual(day.proceeds["CZK"], decimal("24.00"))
        XCTAssertEqual(day.proceeds.count, 1)
        XCTAssertNil(day.proceeds[""])
        XCTAssertFalse(day.proceeds.keys.contains(where: \.isEmpty))
    }

    /// A zero-proceeds row with a currency shouldn't invent a currency with nothing in it.
    func testZeroProceedsDoesntCreateACurrencyBucket() throws {
        let day = try parse("updates-and-redownloads.tsv")
        XCTAssertNil(day.proceeds["CZK"])
    }

    // MARK: - Damage

    func testMalformedRowsCostOneRowEach() throws {
        let day = try parse("malformed-rows.tsv")
        XCTAssertEqual(day.downloads, 30)                     // the two readable rows
        XCTAssertEqual(day.proceeds["USD"], decimal("17.00")) // 7.00 + 10.00
        XCTAssertEqual(day.skippedRows, 3)
    }

    func testAPublishedReportWithNoRowsIsAllZeroes() throws {
        let day = try parse("zero-sales-day.tsv")
        XCTAssertEqual(day.downloads, 0)
        XCTAssertTrue(day.proceeds.isEmpty)
        XCTAssertTrue(day.apps.isEmpty)
        XCTAssertEqual(day.skippedRows, 0)
        // Observed, not assumed: Apple published this, it just has nothing in it.
        XCTAssertEqual(day.origin, .observed)
    }

    func testEmptyInputDoesntCrash() {
        let day = ReportParser.parse("", date: date, fetchedAt: Date())
        XCTAssertEqual(day.downloads, 0)
        XCTAssertTrue(day.proceeds.isEmpty)
    }

    func testGarbageInputDoesntCrash() {
        let day = ReportParser.parse("this is not a report at all\nnor is this\n",
                                     date: date, fetchedAt: Date())
        XCTAssertEqual(day.downloads, 0)
        XCTAssertTrue(day.proceeds.isEmpty)
    }

    // MARK: - Format tolerance

    func testHandlesCarriageReturns() throws {
        let crlf = try fixture("typical-day.tsv").replacingOccurrences(of: "\n", with: "\r\n")
        let day = ReportParser.parse(crlf, date: date, fetchedAt: Date())
        XCTAssertEqual(day.downloads, 133)
        XCTAssertEqual(day.proceeds["USD"], decimal("84.00"))
    }

    /// Apple's field reference calls this column "Developer Proceeds (per unit)" while every real
    /// report writes "Developer Proceeds". Both have to work, because Apple can't decide.
    func testAcceptsEitherSpellingOfTheProceedsColumn() throws {
        let renamed = try fixture("typical-day.tsv")
            .replacingOccurrences(of: "Developer Proceeds",
                                  with: "Developer Proceeds (per unit)")
        let day = ReportParser.parse(renamed, date: date, fetchedAt: Date())
        XCTAssertEqual(day.proceeds["USD"], decimal("84.00"))
    }

    /// Columns are found by name, so a reordered or extended report still parses. Apple has added
    /// columns to this report before and will again.
    func testColumnsAreFoundByNameNotPosition() throws {
        let original = try fixture("typical-day.tsv")
        let lines = original.split(separator: "\n", omittingEmptySubsequences: false)
        let reversed = lines.map { line -> String in
            line.isEmpty ? "" : line.split(separator: "\t", omittingEmptySubsequences: false)
                .reversed().joined(separator: "\t")
        }.joined(separator: "\n")

        let day = ReportParser.parse(reversed, date: date, fetchedAt: Date())
        XCTAssertEqual(day.downloads, 133)
        XCTAssertEqual(day.proceeds["USD"], decimal("84.00"))
    }

    func testAReportWithoutTheColumnsWeNeedIsNotSilentlyZero() {
        let tsv = "Provider\tTitle\tVersion\nAPPLE\tApp One\t1.0\n"
        let day = ReportParser.parse(tsv, date: date, fetchedAt: Date())
        XCTAssertEqual(day.downloads, 0)
        // The row wasn't read, so it must show up in the tally rather than passing as a zero day.
        XCTAssertEqual(day.skippedRows, 1)
    }

    // MARK: - Precision

    /// Money is Decimal end to end. In binary floating point 0.1 + 0.2 != 0.3, and a day's total is
    /// thousands of such additions.
    func testMoneyMathIsExact() {
        let header = "Product Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds"
            + "\tTitle\tApple Identifier"
        let rows = (0..<3).map { _ in "IA1\t1\t0.10\tUSD\tApp One\t1" }
        let day = ReportParser.parse(([header] + rows).joined(separator: "\n"),
                                     date: date, fetchedAt: Date())
        XCTAssertEqual(day.proceeds["USD"], decimal("0.30"))
    }

    /// Units is DECIMAL(18,2) — partial refunds really do produce fractions.
    func testFractionalUnitsAreKept() {
        let header = "Product Type Identifier\tUnits\tDeveloper Proceeds\tCurrency of Proceeds"
            + "\tTitle\tApple Identifier"
        let day = ReportParser.parse("\(header)\n1F\t2.50\t1.00\tUSD\tApp One\t1",
                                     date: date, fetchedAt: Date())
        XCTAssertEqual(day.downloads, decimal("2.50"))
        XCTAssertEqual(day.proceeds["USD"], decimal("2.50"))
    }

    // MARK: - Diagnostics

    /// "Downloads" is a judgement call; the per-type tally is not. It's what makes a disagreement
    /// with App Store Connect answerable without re-downloading the report and diffing by hand.
    func testTallyRecordsEveryProductTypeIncludingOnesThatArentDownloads() throws {
        let day = try parse("updates-and-redownloads.tsv")
        XCTAssertEqual(day.unitsByProductType["7"], 500)
        XCTAssertEqual(day.unitsByProductType["3"], 40)
        XCTAssertEqual(day.unitsByProductType["1"], 3)
        XCTAssertEqual(day.unitsByProductType.values.reduce(0, +), 833)
    }

    func testTallyKeepsUnknownCodesUnderTheirOwnName() throws {
        let day = try parse("unknown-product-types.tsv")
        XCTAssertEqual(day.unitsByProductType["1AY"], 1)
        XCTAssertEqual(day.unitsByProductType["ZZ9"], 2)
    }

    /// Downloads must always equal the tally restricted to first-download codes — otherwise the
    /// diagnostic and the number it explains have drifted apart.
    func testDownloadsEqualTheFirstDownloadSliceOfTheTally() throws {
        for name in ["typical-day.tsv", "mac-and-bundles.tsv", "refunds.tsv",
                     "free-apps-blank-currency.tsv", "updates-and-redownloads.tsv"] {
            let day = try parse(name)
            let expected = day.unitsByProductType
                .filter { ReportParser.firstDownloadTypes.contains($0.key) }
                .values.reduce(Decimal(0), +)
            XCTAssertEqual(day.downloads, expected, name)
        }
    }

    // MARK: - In-app purchases belong to their app

    /// An In-App Purchase row carries its *own* Apple Identifier and names its app only through
    /// Parent Identifier, which holds the app's SKU. Grouping on Apple Identifier alone lists every
    /// purchase product as though it were an app — which is exactly what the real report did.
    func testInAppPurchasesRollUpToTheirParentApp() throws {
        let day = try parse("typical-day.tsv")
        XCTAssertEqual(day.apps.count, 2, "purchase products must not appear as apps")
        XCTAssertEqual(Set(day.apps.map(\.appleID)), ["1111111111", "2222222222"])
    }

    func testParentAppKeepsItsOwnNameNotThePurchaseProducts() throws {
        let day = try parse("typical-day.tsv")
        XCTAssertEqual(day.apps.first { $0.appleID == "1111111111" }?.title, "App One")
        XCTAssertEqual(day.apps.first { $0.appleID == "2222222222" }?.title, "App Two")
    }

    func testFreeAppKeepsItsPurchaseRevenue() throws {
        let day = try parse("free-apps-blank-currency.tsv")
        XCTAssertEqual(day.apps.count, 1)
        let app = try XCTUnwrap(day.apps.first)
        XCTAssertEqual(app.title, "Free App")
        XCTAssertEqual(app.downloads, 3)
        XCTAssertEqual(app.proceeds["CZK"], decimal("24.00"))
    }

    /// When the parent app sold nothing that day it has no rows, so its SKU can't be resolved to an
    /// Apple ID. Its purchases should still group together rather than scattering into one row per
    /// product.
    func testOrphanedPurchasesGroupUnderTheirParentSKU() throws {
        let day = try parse("orphan-iap.tsv")
        XCTAssertEqual(day.apps.count, 1)
        XCTAssertEqual(day.apps.first?.appleID, "GONEAPP")
        XCTAssertEqual(day.apps.first?.proceeds["USD"], decimal("17.15"))
        XCTAssertEqual(day.downloads, 0)
    }

    /// The invariant that keeps a breakdown honest: per-app rows and the day above them must count
    /// the same units, whichever metrics are on.
    func testPerAppUnitsReconcileWithTheDayForEveryMetricCombination() throws {
        for name in ["typical-day.tsv", "free-apps-blank-currency.tsv", "orphan-iap.tsv",
                     "mac-and-bundles.tsv", "updates-and-redownloads.tsv", "refunds.tsv"] {
            let day = try parse(name)
            for metrics in [Set<Metric>([.installs]),
                            [.installs, .inAppPurchases],
                            [.inAppPurchases, .subscriptions],
                            Set(Metric.allCases)] {
                let perApp = day.apps.reduce(Decimal(0)) { $0 + Metric.units(in: $1, metrics: metrics) }
                XCTAssertEqual(perApp, Metric.units(in: day, metrics: metrics),
                               "\(name) with \(metrics.map(\.rawValue).sorted())")
            }
        }
    }
    // MARK: - Gross customer sales

    private func report(_ rows: [[String]]) -> String {
        let header = ["Provider", "SKU", "Developer Proceeds", "Units", "Apple Identifier",
                      "Title", "Product Type Identifier", "Currency of Proceeds",
                      "Parent Identifier", "Customer Price", "Customer Currency"]
        return ([header] + rows).map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
    }

    private func parse(_ rows: [[String]]) -> DaySales {
        ReportParser.parse(report(rows), date: ReportDate(year: 2026, month: 8, day: 19),
                           fetchedAt: Date())
    }

    func testGrossSalesAreReadInTheCustomersCurrency() {
        let day = parse([["APPLE", "sku1", "0.70", "10", "111", "App One", "1", "USD", "",
                          "0.99", "USD"]])
        XCTAssertEqual(day.sales["USD"], Decimal(string: "9.90"))
        XCTAssertEqual(day.proceeds["USD"], Decimal(string: "7.00"),
                       "and proceeds are untouched")
    }

    /// The currency a customer pays in is not the currency you're paid in, and adding the two
    /// together would be meaningless — so they are separate bags.
    func testGrossAndProceedsCurrenciesAreKeptApart() {
        let day = parse([["APPLE", "sku1", "0.70", "10", "111", "App One", "1", "USD", "",
                          "150", "JPY"]])
        XCTAssertEqual(day.sales["JPY"], 1500)
        XCTAssertNil(day.sales["USD"])
        XCTAssertEqual(day.proceeds["USD"], Decimal(string: "7.00"))
    }

    /// The trap, straight from Apple's own wording: "Refunds have negative values for Units and
    /// Customer Price, and positive values for Developer Proceeds."
    ///
    /// So `units × customerPrice` is **positive** on a refund — a refund that increases gross sales.
    /// The sign belongs to the price; the units only say how many.
    func testARefundReducesGrossSalesRatherThanIncreasingIt() {
        let day = parse([["APPLE", "sku1", "0.70", "-50", "111", "App One", "1F", "USD", "",
                          "-0.99", "USD"]])
        XCTAssertEqual(day.sales["USD"], Decimal(string: "-49.50"))
        // And the opposite convention still holds for proceeds, where only the units are negative.
        XCTAssertEqual(day.proceeds["USD"], Decimal(string: "-35.00"))
    }

    func testAMixOfSalesAndRefundsNets() {
        let day = parse([["APPLE", "sku1", "0.70", "100", "111", "App One", "1", "USD", "",
                          "0.99", "USD"],
                         ["APPLE", "sku1", "0.70", "-50", "111", "App One", "1F", "USD", "",
                          "-0.99", "USD"]])
        XCTAssertEqual(day.sales["USD"], Decimal(string: "49.50"))
    }

    /// Free apps carry units and no price at all. Nothing changed hands, so nothing is recorded —
    /// a zero would be indistinguishable from a paid app that sold nothing.
    func testAFreeRowContributesNoGross() {
        let day = parse([["APPLE", "sku1", "0", "40", "111", "App One", "1F", "", "", "0", ""]])
        XCTAssertTrue(day.sales.isEmpty)
        XCTAssertEqual(day.downloads, 40, "and the downloads still count")
    }

    /// A report without the columns is still a valid report — it just has no gross in it.
    func testAReportWithoutCustomerPriceColumnsStillParses() {
        let header = ["Provider", "SKU", "Developer Proceeds", "Units", "Apple Identifier",
                      "Title", "Product Type Identifier", "Currency of Proceeds",
                      "Parent Identifier"]
        let tsv = ([header] + [["APPLE", "sku1", "0.70", "10", "111", "App One", "1", "USD", ""]])
            .map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n"
        let day = ReportParser.parse(tsv, date: ReportDate(year: 2026, month: 8, day: 19),
                                     fetchedAt: Date())
        XCTAssertTrue(day.sales.isEmpty)
        XCTAssertEqual(day.proceeds["USD"], Decimal(string: "7.00"))
    }

    func testGrossIsRecordedPerAppAsWellAsPerDay() {
        let day = parse([["APPLE", "sku1", "0.70", "10", "111", "App One", "1", "USD", "",
                          "0.99", "USD"],
                         ["APPLE", "sku2", "0.70", "5", "222", "App Two", "1", "USD", "",
                          "1.99", "USD"]])
        let one = day.apps.first { $0.appleID == "111" }
        let two = day.apps.first { $0.appleID == "222" }
        XCTAssertEqual(one?.sales["USD"], Decimal(string: "9.90"))
        XCTAssertEqual(two?.sales["USD"], Decimal(string: "9.95"))
    }

    /// Stamped so `ReportStore` can tell a complete parse from an older, thinner one.
    func testAParsedDayRecordsWhichParserReadIt() {
        XCTAssertEqual(parse([["APPLE", "sku1", "0.70", "10", "111", "App One", "1", "USD", "",
                               "0.99", "USD"]]).parserVersion, ReportParser.version)
    }

}
