import XCTest
@testable import VantageCore

/// Analytics segments are TSV from a source Vantage doesn't control, so every shape has to fail
/// into "no data" rather than into a wrong number.
final class SegmentParserTests: XCTestCase {
    private func tsv(_ rows: [[String]]) -> String {
        rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
    }

    private let header = ["Date", "App Name", "Event", "Page Type", "Territory", "Counts"]

    private func row(_ date: String, _ event: String, _ counts: String) -> [String] {
        [date, "Vantage", event, "Product page", "USA", counts]
    }

    // MARK: - The happy path

    func testSumsImpressionsAndPageViewsPerDay() {
        let file = tsv([header,
                        row("2026-08-19", "Impression", "1000"),
                        row("2026-08-19", "Page view", "120"),
                        row("2026-08-18", "Impression", "800")])
        let result = SegmentParser.parse(file)

        XCTAssertEqual(result.days.count, 2)
        // Oldest first.
        XCTAssertEqual(result.days.first?.date, ReportDate(year: 2026, month: 8, day: 18))
        XCTAssertEqual(result.days.last?.impressions, 1000)
        XCTAssertEqual(result.days.last?.pageViews, 120)
        XCTAssertEqual(result.skippedRows, 0)
    }

    /// Apple splits one day across many rows — by territory, device, source. They all add up.
    func testRowsForOneDayAccumulate() {
        let file = tsv([header,
                        row("2026-08-19", "Impression", "600"),
                        row("2026-08-19", "Impression", "400")])
        XCTAssertEqual(SegmentParser.parse(file).days.first?.impressions, 1000)
    }

    /// Columns are matched by name, never by position — Apple reorders and adds them.
    func testColumnsAreFoundByNameNotPosition() {
        let reordered = ["Counts", "Event", "Territory", "Date"]
        let file = tsv([reordered, ["500", "Impression", "USA", "2026-08-19"]])
        XCTAssertEqual(SegmentParser.parse(file).days.first?.impressions, 500)
    }

    /// The same report has shipped "Page view" and "Page View" in different periods.
    func testEventNamesMatchRegardlessOfCaseAndSpacing() {
        for spelling in ["Page view", "page view", "PAGE VIEW", "Page_View", "pageview"] {
            let file = tsv([header, row("2026-08-19", spelling, "7")])
            XCTAssertEqual(SegmentParser.parse(file).days.first?.pageViews, 7, spelling)
        }
    }

    // MARK: - Degrading

    /// A file without the three load-bearing columns isn't the report we think it is. Guessing at
    /// positions is how a chart ends up plotting territory codes.
    func testAFileMissingItsKeyColumnsYieldsNothing() {
        let file = tsv([["Date", "Territory", "Device"], ["2026-08-19", "USA", "iPhone"]])
        let result = SegmentParser.parse(file)
        XCTAssertTrue(result.days.isEmpty)
        XCTAssertEqual(result.skippedRows, 1)
    }

    func testAMalformedRowCostsOneRowNotTheFile() {
        let file = tsv([header,
                        row("2026-08-19", "Impression", "1000"),
                        row("not-a-date", "Impression", "50"),
                        row("2026-08-19", "Impression", "not-a-number"),
                        ["2026-08-19"]])
        let result = SegmentParser.parse(file)
        XCTAssertEqual(result.days.first?.impressions, 1000)
        XCTAssertEqual(result.skippedRows, 3)
    }

    /// A renamed event must show as a gap *and* a note, never silently as zero.
    func testUnrecognisedEventsAreReportedRatherThanCountedOrDropped() {
        let file = tsv([header,
                        row("2026-08-19", "Impression", "100"),
                        row("2026-08-19", "Deep Link Open", "9")])
        let result = SegmentParser.parse(file)
        XCTAssertEqual(result.days.first?.impressions, 100, "and not 109")
        XCTAssertEqual(result.unknownEvents, ["Deep Link Open"])
    }

    func testAnEmptyFileIsNotAnError() {
        let result = SegmentParser.parse("")
        XCTAssertTrue(result.days.isEmpty)
        XCTAssertEqual(result.skippedRows, 0)
    }

    func testHeaderOnlyYieldsNoDays() {
        XCTAssertTrue(SegmentParser.parse(tsv([header])).days.isEmpty)
    }

    func testWindowsLineEndingsAreHandled() {
        let file = header.joined(separator: "\t") + "\r\n"
            + row("2026-08-19", "Impression", "42").joined(separator: "\t") + "\r\n"
        XCTAssertEqual(SegmentParser.parse(file).days.first?.impressions, 42)
    }

    /// Counts are parsed POSIX, so a machine in a comma-decimal locale doesn't read "1234" as 1.234
    /// — or, worse, silently truncate.
    func testCountsAreParsedIndependentlyOfTheMachinesLocale() {
        let file = tsv([header, row("2026-08-19", "Impression", "1234")])
        XCTAssertEqual(SegmentParser.parse(file).days.first?.impressions, 1234)
    }

    // MARK: - Conversion

    func testConversionIsAPercentageOfImpressions() {
        let day = EngagementDay(date: ReportDate(year: 2026, month: 8, day: 19),
                                impressions: 1000, pageViews: 125)
        XCTAssertEqual(day.conversion, Decimal(string: "12.5"))
    }

    /// A rate with no denominator is undefined, not zero — and drawing it as zero invents a bad day.
    func testConversionIsUndefinedWithoutImpressions() {
        let day = EngagementDay(date: ReportDate(year: 2026, month: 8, day: 19),
                                impressions: 0, pageViews: 0)
        XCTAssertNil(day.conversion)
    }
}
