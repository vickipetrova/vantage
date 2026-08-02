import XCTest
@testable import VantageCore

/// Conversion is where a total can go quietly wrong: a missing rate that silently drops a currency
/// looks exactly like a smaller sales day. No network here — the feed is a fixture string.
final class FXTests: XCTestCase {
    /// A trimmed copy of the real ECB feed's shape, including its nested Cube elements.
    private let feed = """
    <?xml version="1.0" encoding="UTF-8"?>
    <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" \
    xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
      <gesmes:subject>Reference rates</gesmes:subject>
      <Cube>
        <Cube time='2026-07-31'>
          <Cube currency='USD' rate='1.1500'/>
          <Cube currency='CZK' rate='25.000'/>
          <Cube currency='GBP' rate='0.8500'/>
          <Cube currency='TRY' rate='40.000'/>
        </Cube>
      </Cube>
    </gesmes:Envelope>
    """

    private func rates() throws -> FXRates {
        try XCTUnwrap(FX.parse(Data(feed.utf8)))
    }

    private func decimal(_ string: String) -> Decimal {
        Decimal(string: string, locale: Locale(identifier: "en_US_POSIX"))!
    }

    // MARK: - Parsing

    func testParsesEveryRate() throws {
        let rates = try rates()
        XCTAssertEqual(rates.perEUR["USD"], decimal("1.15"))
        XCTAssertEqual(rates.perEUR["CZK"], decimal("25"))
        XCTAssertEqual(rates.published, "2026-07-31")
    }

    /// EUR is the base and isn't listed in the feed, so it has to be added or every EUR amount
    /// becomes unconvertible.
    func testEURIsAlwaysPresentAsTheBase() throws {
        XCTAssertEqual(try rates().perEUR["EUR"], 1)
        XCTAssertTrue(try rates().canConvert("EUR"))
    }

    func testRejectsAFeedThatIsntTheFeed() {
        XCTAssertNil(FX.parse(Data("<html>maintenance</html>".utf8)))
        XCTAssertNil(FX.parse(Data()))
        XCTAssertNil(FX.parse(Data("not xml at all".utf8)))
    }

    // MARK: - Converting

    func testConvertsViaEUR() throws {
        // 25 CZK = 1 EUR = 1.15 USD
        XCTAssertEqual(try rates().convert(25, from: "CZK", to: "USD"), decimal("1.15"))
    }

    func testSameCurrencyIsUntouched() throws {
        // Not merely equal — it must not round-trip through two divisions and come back changed.
        XCTAssertEqual(try rates().convert(decimal("14.70"), from: "USD", to: "USD"),
                       decimal("14.70"))
    }

    func testCurrencyCodesAreCaseInsensitive() throws {
        XCTAssertEqual(try rates().convert(25, from: "czk", to: "usd"), decimal("1.15"))
    }

    func testUnknownCurrencyConvertsToNil() throws {
        // QAR is a currency Apple pays in and the ECB doesn't publish. This is the real case.
        XCTAssertNil(try rates().convert(decimal("2.09"), from: "QAR", to: "USD"))
        XCTAssertFalse(try rates().canConvert("QAR"))
    }

    // MARK: - Whole days

    func testConvertsADaysProceeds() throws {
        let (converted, unconverted) = try rates().convert(
            ["USD": decimal("14.70"), "CZK": decimal("90.83")], to: "USD")
        // 90.83 CZK / 25 * 1.15 = 4.17818
        XCTAssertEqual(converted, decimal("14.70") + decimal("4.178180"))
        XCTAssertTrue(unconverted.isEmpty)
    }

    /// The decision that matters: money the ECB can't price is reported, not dropped. A total that
    /// silently omits a currency is the plausible-looking wrong number this app exists to avoid.
    func testUnconvertibleMoneyIsReportedNotDropped() throws {
        let (converted, unconverted) = try rates().convert(
            ["USD": decimal("10.00"), "QAR": decimal("2.09")], to: "USD")
        XCTAssertEqual(converted, decimal("10.00"))
        XCTAssertEqual(unconverted["QAR"], decimal("2.09"))
    }

    func testZeroAmountsAreIgnoredEntirely() throws {
        let (converted, unconverted) = try rates().convert(["QAR": 0, "USD": 0], to: "USD")
        XCTAssertEqual(converted, 0)
        XCTAssertTrue(unconverted.isEmpty, "a zero in an unpriceable currency is not a remainder")
    }

    func testEmptyProceedsConvertToZero() throws {
        let (converted, unconverted) = try rates().convert([:], to: "USD")
        XCTAssertEqual(converted, 0)
        XCTAssertTrue(unconverted.isEmpty)
    }

    func testNegativeProceedsConvertToNegative() throws {
        let (converted, _) = try rates().convert(["CZK": decimal("-25")], to: "USD")
        XCTAssertEqual(converted, decimal("-1.15"))
    }

    // MARK: - Staleness

    func testFreshRatesArentStale() {
        let rates = FXRates(perEUR: ["USD": decimal("1.15")], published: "2026-07-31",
                            fetchedAt: Date())
        XCTAssertFalse(rates.isStale)
    }

    /// The ECB publishes on TARGET working days only, so a weekend feed is legitimately old. Age is
    /// measured from the fetch, not from the published date, or every Saturday would refetch on a
    /// loop for a file that hasn't changed.
    func testRatesOlderThanADayAreStale() {
        let rates = FXRates(perEUR: ["USD": decimal("1.15")], published: "2026-07-31",
                            fetchedAt: Date(timeIntervalSinceNow: -25 * 60 * 60))
        XCTAssertTrue(rates.isStale)
    }

    func testRatesSurviveEncodingExactly() throws {
        let original = try rates()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(FXRates.self, from: data)
        XCTAssertEqual(restored.perEUR, original.perEUR)
        XCTAssertEqual(restored.published, original.published)
    }
}
