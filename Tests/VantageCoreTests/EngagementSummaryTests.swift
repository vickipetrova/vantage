import XCTest
@testable import VantageCore

/// What the Overview headline says about engagement, for the days on screen.
final class EngagementSummaryTests: XCTestCase {
    private func day(_ day: Int, impressions: Decimal, pageViews: Decimal) -> EngagementDay {
        EngagementDay(date: ReportDate(year: 2026, month: 9, day: day),
                      impressions: impressions, pageViews: pageViews)
    }

    private let start = ReportDate(year: 2026, month: 9, day: 14)
    private let end = ReportDate(year: 2026, month: 9, day: 16)

    func testTotalsCoverTheSpanOnly() {
        let days = [day(13, impressions: 999, pageViews: 999),   // before
                    day(14, impressions: 100, pageViews: 10),
                    day(16, impressions: 300, pageViews: 20),
                    day(17, impressions: 999, pageViews: 999)]   // after
        let summary = EngagementSummary.build(days: days, from: start, to: end)

        XCTAssertEqual(summary?.impressions, 400)
        XCTAssertEqual(summary?.pageViews, 30)
    }

    func testConversionIsPageViewsOverImpressions() {
        let summary = EngagementSummary.build(days: [day(15, impressions: 200, pageViews: 10)],
                                              from: start, to: end)
        XCTAssertEqual(summary?.conversion, 5)
    }

    /// A day with impressions nobody opened is a real day. Dividing by zero is not.
    func testNoImpressionsMeansNoConversionRatherThanZeroDivision() {
        let summary = EngagementSummary.build(days: [day(15, impressions: 0, pageViews: 0)],
                                              from: start, to: end)
        XCTAssertNotNil(summary, "A zero day is data, not absence")
        XCTAssertNil(summary?.conversion)
    }

    /// Nil is what makes the headline say "not available yet" instead of showing zeros.
    func testASpanWithNoEngagementDaysHasNoSummary() {
        let days = [day(1, impressions: 100, pageViews: 10)]
        XCTAssertNil(EngagementSummary.build(days: days, from: start, to: end))
        XCTAssertNil(EngagementSummary.build(days: [], from: start, to: end))
    }

    /// Apple finalises a day about two days after it, so a span is often partly covered. The
    /// figures are still true — of the days they cover.
    func testAPartlyCoveredSpanReportsHowManyDaysItUsed() {
        let summary = EngagementSummary.build(days: [day(14, impressions: 100, pageViews: 10)],
                                              from: start, to: end)
        XCTAssertEqual(summary?.daysCovered, 1)
    }

    /// The portfolio hands in every app's days flattened together — there is no per-app dimension
    /// left by then. Counting entries would call three apps over three days nine days covered,
    /// which is a number that can exceed the span it describes.
    func testDaysCoveredCountsDatesRatherThanAppDays() {
        let threeAppsOverTwoDays = [day(15, impressions: 100, pageViews: 10),
                                    day(15, impressions: 200, pageViews: 20),
                                    day(15, impressions: 300, pageViews: 30),
                                    day(16, impressions: 100, pageViews: 10),
                                    day(16, impressions: 200, pageViews: 20),
                                    day(16, impressions: 300, pageViews: 30)]
        let summary = EngagementSummary.build(days: threeAppsOverTwoDays, from: start, to: end)

        XCTAssertEqual(summary?.daysCovered, 2)
        XCTAssertEqual(summary?.impressions, 1_200, "Every row still counts toward the totals")
    }

    func testTheLineReadsAsASentence() {
        let days = [day(14, impressions: 1_000, pageViews: 45),
                    day(15, impressions: 1_140, pageViews: 51)]
        let summary = EngagementSummary.build(days: days, from: start, to: end)
        XCTAssertEqual(summary?.line, "2,140 impressions · 96 page views · 4.5% viewed")
    }

    func testTheLineOmitsConversionWhenThereIsNone() {
        let summary = EngagementSummary.build(days: [day(15, impressions: 0, pageViews: 0)],
                                              from: start, to: end)
        XCTAssertEqual(summary?.line, "0 impressions · 0 page views")
    }

    // MARK: - Tiles

    /// The headline draws one tile per figure. Deciding how many there are is Core's job, not the
    /// view's — a view that decided it would be a calculation nothing can cover.
    func testTilesCarryEachFigureWithItsOwnLabel() {
        let days = [day(14, impressions: 1_000, pageViews: 45),
                    day(15, impressions: 1_140, pageViews: 51)]
        let summary = EngagementSummary.build(days: days, from: start, to: end)

        XCTAssertEqual(summary?.tiles, [EngagementTile(label: "Impressions", value: "2,140"),
                                        EngagementTile(label: "Page views", value: "96"),
                                        EngagementTile(label: "Viewed", value: "4.5%")])
    }

    /// Without impressions the rate is undefined, so the tile is absent rather than showing a dash
    /// or a zero. Two tiles is a complete answer; "0.0% viewed" is a false one.
    func testThereIsNoConversionTileWhenNobodySawTheApp() {
        let summary = EngagementSummary.build(days: [day(15, impressions: 0, pageViews: 0)],
                                              from: start, to: end)

        XCTAssertEqual(summary?.tiles, [EngagementTile(label: "Impressions", value: "0"),
                                        EngagementTile(label: "Page views", value: "0")])
    }

    /// The tiles and the line are two renderings of one set of figures — the line survives as the
    /// row's accessibility label, and the two drifting apart would make VoiceOver lie.
    func testTilesAndLineAgreeOnEveryFigure() {
        let days = [day(14, impressions: 1_000, pageViews: 45),
                    day(15, impressions: 1_140, pageViews: 51)]
        guard let summary = EngagementSummary.build(days: days, from: start, to: end) else {
            return XCTFail("Expected a summary")
        }

        for tile in summary.tiles {
            XCTAssertTrue(summary.line.contains(tile.value),
                          "\(tile.value) is in the tiles but not the spoken line")
        }
    }
}
