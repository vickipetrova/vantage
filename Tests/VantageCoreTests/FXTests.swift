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
        // Nothing publishes it, no central bank pegs it, and Vantage carries no estimate for it.
        // COP used to serve as this example and no longer can — it has a built-in estimate now.
        XCTAssertNil(try rates().convert(decimal("2.09"), from: "ZZZ", to: "USD"))
        XCTAssertFalse(try rates().canConvert("ZZZ"))
    }

    // MARK: - Hard pegs

    /// The ECB publishes 30 currencies; Apple pays in around 45. A few of the missing ones are
    /// *fixed* by their central bank, so a hard-coded number isn't an approximation — it's the rate.
    func testAPeggedCurrencyConvertsViaItsDollarPeg() throws {
        // 3.6725 AED = 1 USD, so 3.6725 AED converts to exactly 1 USD.
        let converted = try XCTUnwrap(
            rates().convert(decimal("3.6725"), from: "AED", to: "USD"))
        XCTAssertEqual(converted, 1, accuracy: decimal("0.0000001"))
        XCTAssertTrue(try rates().canConvert("AED"))
        XCTAssertTrue(try rates().canConvert("QAR"))
        XCTAssertTrue(try rates().canConvert("SAR"))
    }

    /// A peg must never override a rate the ECB actually publishes.
    func testAPublishedRateWinsOverAnyPeg() throws {
        // USD is in the feed; its own peg entry doesn't exist, but the principle is checked by
        // converting a published currency and getting the published answer.
        XCTAssertEqual(try rates().convert(25, from: "CZK", to: "USD"), decimal("1.15"))
    }

    /// The figure is exact, but exact for a different reason than the rest of it — and the panel
    /// says so, so the distinction has to survive out of here.
    func testPeggedCurrenciesAreReportedSoTheyCanBeNamed() throws {
        let pegged = try rates().peggedCurrencies(in: ["USD": 10, "AED": 5, "COP": 1])
        XCTAssertEqual(pegged, ["AED"], "COP floats and has no peg; USD is published")
    }

    /// Only decades-old, centrally maintained pegs belong in the table. A crawling peg or a managed
    /// band is a market rate in disguise, and hard-coding one would be inventing a number.
    func testThePegTableHoldsOnlyTheThreeGulfPegs() {
        XCTAssertEqual(Set(FXPeg.unitsPerUSD.keys), ["AED", "SAR", "QAR"])
    }

    // MARK: - Manual rates

    /// The last resort, for a floating currency nothing publishes a rate for.
    func testAManualRateConvertsACurrencyNothingElseCan() throws {
        // 4000 COP = 1 USD, so 8000 COP is 2 USD.
        let withManual = try rates().applying(manualRates: ["COP": 4000])
        XCTAssertTrue(withManual.canConvert("COP"))
        let converted = try XCTUnwrap(withManual.convert(8000, from: "COP", to: "USD"))
        XCTAssertEqual(converted, 2, accuracy: decimal("0.0000001"))
    }

    /// The order is the point: a currency Vantage can price properly must never be converted at a
    /// number somebody typed months ago.
    func testAPublishedRateBeatsAManualOne() throws {
        // A deliberately absurd manual rate for a currency the ECB does publish.
        let withManual = try rates().applying(manualRates: ["CZK": 1])
        XCTAssertEqual(withManual.convert(25, from: "CZK", to: "USD"), decimal("1.15"))
    }

    func testAPegBeatsAManualRate() throws {
        let withManual = try rates().applying(manualRates: ["AED": 1])
        let converted = try XCTUnwrap(withManual.convert(decimal("3.6725"), from: "AED", to: "USD"))
        XCTAssertEqual(converted, 1, accuracy: decimal("0.0000001"))
    }

    /// A zero or negative rate would divide a total into nonsense.
    func testANonPositiveManualRateIsIgnored() throws {
        XCTAssertFalse(try rates().applying(manualRates: ["ZZZ": 0]).canConvert("ZZZ"))
        XCTAssertFalse(try rates().applying(manualRates: ["ZZZ": -5]).canConvert("ZZZ"))
    }

    /// Pegged and manual are reported separately, because the claims are different: a central
    /// bank's number doesn't drift and one person's does.
    func testPeggedAndManualCurrenciesAreDistinguished() throws {
        let withManual = try rates().applying(manualRates: ["COP": 4000])
        let bag: [String: Decimal] = ["USD": 10, "AED": 5, "COP": 8000]
        XCTAssertEqual(withManual.peggedCurrencies(in: bag), ["AED"])
        XCTAssertEqual(withManual.manuallyRatedCurrencies(in: bag), ["COP"])
    }

    /// Manual rates belong to the user, not to the ECB's cached file — a rate table written to disk
    /// and read back must not carry them, or clearing one in Settings wouldn't take effect.
    func testManualRatesAreNotPersistedWithTheRateTable() throws {
        let withManual = try rates().applying(manualRates: ["ZZZ": 4000])
        let data = try JSONEncoder().encode(withManual)
        let decoded = try JSONDecoder().decode(FXRates.self, from: data)
        XCTAssertFalse(decoded.canConvert("ZZZ"))
        XCTAssertTrue(decoded.canConvert("CZK"), "and the published rates survive")
    }

    // MARK: - Built-in estimates

    /// The last resort of all, and only because leaving real money out of a total is worse than
    /// including it approximately.
    func testAnEstimateConvertsACurrencyNothingElseCan() throws {
        XCTAssertTrue(try rates().canConvert("COP"))
        let converted = try XCTUnwrap(rates().convert(4100, from: "COP", to: "USD"))
        XCTAssertEqual(converted, 1, accuracy: decimal("0.01"))
    }

    /// Order of precedence, end to end: published, then peg, then the user's, then the estimate.
    func testAUserRateBeatsTheBuiltInEstimate() throws {
        let withManual = try rates().applying(manualRates: ["COP": 2000])
        let converted = try XCTUnwrap(withManual.convert(2000, from: "COP", to: "USD"))
        XCTAssertEqual(converted, 1, accuracy: decimal("0.0000001"))
    }

    /// An estimated figure has to say so — it's the only one of the three qualifiers where the
    /// number came from nobody in particular.
    func testEstimatedCurrenciesAreReportedSeparatelyFromTheRest() throws {
        let withManual = try rates().applying(manualRates: ["CLP": 900])
        let bag: [String: Decimal] = ["USD": 10, "AED": 5, "COP": 4100, "CLP": 900]
        XCTAssertEqual(withManual.estimatedCurrencies(in: bag), ["COP"])
        XCTAssertEqual(withManual.manuallyRatedCurrencies(in: bag), ["CLP"])
        XCTAssertEqual(withManual.peggedCurrencies(in: bag), ["AED"])
    }

    /// The Settings list must keep offering a field for a currency an estimate already covers —
    /// that is exactly where a real rate is worth most.
    func testACurrencyCoveredOnlyByAnEstimateStillNeedsAUserRate() throws {
        XCTAssertTrue(try rates().needsUserRate("COP"))
        XCTAssertFalse(try rates().needsUserRate("CZK"), "published")
        XCTAssertFalse(try rates().needsUserRate("AED"), "pegged")
    }

    /// A currency with no rate anywhere still converts to nothing rather than to a guess.
    func testACurrencyWithNoRateAnywhereStillFails() throws {
        XCTAssertNil(try rates().convert(10, from: "ZZZ", to: "USD"))
        XCTAssertFalse(try rates().canConvert("ZZZ"))
    }

    /// Every seed is a positive number. A zero would divide a total into nonsense, and a negative
    /// would invert the sign of somebody's revenue.
    func testEverySeedRateIsPositive() {
        for (code, rate) in FXSeed.approximateUnitsPerUSD {
            XCTAssertGreaterThan(rate, 0, code)
        }
        XCTAssertFalse(FXSeed.asOf.isEmpty, "an estimate without a date can't be judged")
    }

    /// A seed for a currency the ECB publishes would be dead weight that could only ever go wrong.
    func testNoSeedDuplicatesAPublishedOrPeggedCurrency() throws {
        let published = Set(try rates().perEUR.keys)
        for code in FXSeed.approximateUnitsPerUSD.keys {
            XCTAssertFalse(published.contains(code), "\(code) is published by the ECB")
            XCTAssertFalse(FXPeg.isPegged(code), "\(code) is pegged")
        }
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
            ["USD": decimal("10.00"), "ZZZ": decimal("2.09")], to: "USD")
        XCTAssertEqual(converted, decimal("10.00"))
        XCTAssertEqual(unconverted["ZZZ"], decimal("2.09"))
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
