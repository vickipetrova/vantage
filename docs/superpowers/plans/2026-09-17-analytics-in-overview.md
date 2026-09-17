# Analytics in the Overview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Impressions and page views move into Overview and app detail — two more series in the chart's existing picker, a line in the headline, a figure per app row — and the Analytics tab is deleted.

**Architecture:** Everything the screen shows is computed in `VantageCore` and handed to dumb SwiftUI views. Two small new Core types (`EngagementSummary`, `EngagementState`) carry the arithmetic and the "why is this empty" wording that the Analytics view holds today. `TrendSeries` gains two cases so the chart's existing `▾` picker covers them.

**Tech Stack:** Swift 5.9 package, macOS 13 floor, XCTest, SwiftUI/AppKit panel.

**Spec:** `docs/superpowers/specs/2026-09-17-analytics-in-overview-design.md`. Read it before starting any task.

## Global Constraints

- Branch: `analytics-in-overview`. Baseline: `swift test` passes 565 tests.
- `VantageCore` imports Foundation only. No AppKit, SwiftUI or FoundationModels there.
- Money is `Decimal`, never `Double` — and impressions, page views and conversion follow the same rule.
- The views are dumb: no arithmetic or wording in a `View`. If a view needs a number or a sentence, a Core type produces it.
- `PanelModel` stays `ObservableObject` (the `Observation` module is macOS 14; the floor is 13).
- SF Symbols 4 names only — anything newer doesn't exist on macOS 13.
- A day Apple hasn't finalised is a **gap**, never a zero.
- Don't touch analytics fetching, `AnalyticsStore`, the cache format, or the history import added in `bf7f4fd`.
- Never run `swiftc` by hand in the repo root. Use `swift build`, `swift test`, `./build.sh`.
- `swift test` needs full Xcode (installed: Xcode 26.0).
- Commit messages end with a `Co-Authored-By:` trailer naming the model that did the work.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `Sources/VantageCore/EngagementSummary.swift` | Create | Impressions, page views, conversion and coverage for a span |
| `Sources/VantageCore/EngagementState.swift` | Create | The one note Overview shows when engagement can't be shown |
| `Sources/VantageCore/Trend.swift` | Modify | `TrendSeries.impressions` / `.pageViews`; `series(…)` takes engagement days; delete `Trend.engagement` |
| `Sources/VantageCore/OverviewModel.swift` | Modify | `build(…)` takes engagement; `Headline` and `AppRow` gain their fields |
| `Sources/VantageCore/AppDetailModel.swift` | Modify | Passes one app's engagement through to its summary |
| `Sources/Vantage/Panel/PanelModel.swift` | Modify | Drops `engagementMetric`; exposes `engagementState` |
| `Sources/Vantage/Panel/OverviewView.swift` | Modify | Renders the engagement line, app-row impressions and the note |
| `Sources/Vantage/Panel/AppDetailView.swift` | Modify | Renders the engagement line |
| `Sources/Vantage/Panel/Cards.swift` | Modify | `HeadlineCard` shows the engagement line; `AppRowView` shows impressions |
| `Sources/Vantage/Panel/PanelRoute.swift` | Modify | Remove `.analytics` |
| `Sources/Vantage/Panel/AnalyticsView.swift` | Delete | Its states move into Core and Overview |
| `Tests/VantageCoreTests/EngagementSummaryTests.swift` | Create | |
| `Tests/VantageCoreTests/EngagementStateTests.swift` | Create | |
| `Tests/VantageCoreTests/TrendTests.swift` | Modify | The two new series |
| `Tests/VantageCoreTests/OverviewModelTests.swift` | Modify | Headline line, note, app rows, footnote |
| `Tests/VantageCoreTests/AppDetailModelTests.swift` | Modify | One app's engagement |
| `CLAUDE.md`, `README.md`, `CHANGELOG.md` | Modify | Docs |

---

### Task 1: `EngagementSummary`

**Files:**
- Create: `Sources/VantageCore/EngagementSummary.swift`
- Test: `Tests/VantageCoreTests/EngagementSummaryTests.swift`

**Interfaces:**
- Consumes: `EngagementDay` (`Sources/VantageCore/Analytics.swift`: `date: ReportDate`, `impressions: Decimal`, `pageViews: Decimal`), `ReportDate`, `OverviewModel.Span` (`title: String`, `length: Int`, `end: ReportDate?`)
- Produces:
  - `public struct EngagementSummary: Equatable, Sendable` with `let impressions: Decimal`, `let pageViews: Decimal`, `let conversion: Decimal?`, `let daysCovered: Int`, `var line: String`
  - `public static func EngagementSummary.build(days: [EngagementDay], from start: ReportDate, to end: ReportDate) -> EngagementSummary?`

- [ ] **Step 1: Write the failing tests**

Create `Tests/VantageCoreTests/EngagementSummaryTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter EngagementSummaryTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'EngagementSummary' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/VantageCore/EngagementSummary.swift`:

```swift
import Foundation

/// Engagement for the days the panel is showing: how many people saw the app, how many opened its
/// page, and what share that is.
///
/// Conversion is the one figure neither API returns and the reason the two numbers belong side by
/// side. It is `nil` rather than zero when nobody saw the app at all, because 0 ÷ 0 is not 0%.
///
/// `nil` from `build` means the span holds no engagement day — which is normal, not an error:
/// Apple finalises a day about two days later, and an `ONGOING` report request only produces days
/// from its own creation onwards.
public struct EngagementSummary: Equatable, Sendable {
    public let impressions: Decimal
    public let pageViews: Decimal
    /// Page views as a percentage of impressions. `nil` when there were no impressions.
    public let conversion: Decimal?
    /// How many days in the span actually had data.
    public let daysCovered: Int

    public init(impressions: Decimal, pageViews: Decimal, conversion: Decimal?, daysCovered: Int) {
        self.impressions = impressions
        self.pageViews = pageViews
        self.conversion = conversion
        self.daysCovered = daysCovered
    }

    /// - Parameter days: any order; only the span is used.
    public static func build(days: [EngagementDay],
                             from start: ReportDate,
                             to end: ReportDate) -> EngagementSummary? {
        let window = days.filter { $0.date >= start && $0.date <= end }
        guard !window.isEmpty else { return nil }

        let impressions = window.reduce(Decimal(0)) { $0 + $1.impressions }
        let pageViews = window.reduce(Decimal(0)) { $0 + $1.pageViews }
        return EngagementSummary(
            impressions: impressions,
            pageViews: pageViews,
            conversion: impressions > 0 ? pageViews / impressions * 100 : nil,
            daysCovered: window.count)
    }

    /// The headline's engagement line.
    public var line: String {
        var parts = ["\(Fmt.downloads(impressions)) impressions",
                     "\(Fmt.downloads(pageViews)) page views"]
        if let conversion {
            parts.append("\(Fmt.percent(conversion)) viewed")
        }
        return parts.joined(separator: " · ")
    }
}
```

- [ ] **Step 4: Check whether `Fmt.percent` exists**

Run: `grep -n "func percent" Sources/VantageCore/Format.swift`

If it prints nothing, add this to `Sources/VantageCore/Format.swift` inside `public enum Fmt`, and add the test below to `Tests/VantageCoreTests/FormatTests.swift`:

```swift
    /// One decimal place, trailing `.0` dropped: a conversion rate is read for its size, and
    /// "4.5%" carries every digit anyone acts on.
    public static func percent(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        let number = formatter.string(from: value as NSDecimalNumber) ?? "0"
        return number + "%"
    }
```

```swift
    func testPercentKeepsOneDecimalAndDropsATrailingZero() {
        XCTAssertEqual(Fmt.percent(4.5), "4.5%")
        XCTAssertEqual(Fmt.percent(12), "12%")
        XCTAssertEqual(Fmt.percent(0), "0%")
    }
```

If it already exists, check its output shape against `testTheLineReadsAsASentence` and adjust that test's expectation rather than adding a second formatter.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "EngagementSummaryTests|FormatTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: 0 failures.

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 0 failures.

```bash
git add Sources/VantageCore/EngagementSummary.swift Tests/VantageCoreTests/EngagementSummaryTests.swift Sources/VantageCore/Format.swift Tests/VantageCoreTests/FormatTests.swift
git commit -m "feat: engagement figures for the days on screen"
```

---

### Task 2: `EngagementState`

**Files:**
- Create: `Sources/VantageCore/EngagementState.swift`
- Test: `Tests/VantageCoreTests/EngagementStateTests.swift`

**Interfaces:**
- Consumes: `AnalyticsError` (`Sources/VantageCore/Analytics.swift`; has `errorDescription`, `isWaitingForApple`, `suggestsCheckingCredentials`, `stopsTheRun`)
- Produces:
  - `public struct EngagementNote: Equatable, Sendable` with `let title: String`, `let body: String`, `let offersSettings: Bool`
  - `public enum EngagementState { public static func note(hasKey: Bool, isLoading: Bool, hasDays: Bool, error: Error?) -> EngagementNote? }`

This is the wording `AnalyticsView` decides inside a view today (`AnalyticsView.swift:57-130`). Read that file before writing the implementation, and keep the sentences identical unless a test below says otherwise.

- [ ] **Step 1: Write the failing tests**

Create `Tests/VantageCoreTests/EngagementStateTests.swift`:

```swift
import XCTest
@testable import VantageCore

/// Why the Overview has no engagement figures to show — in one note, decided in Core.
///
/// These four situations look alike on screen and mean completely different things: "wait a day",
/// "add a key", "your key is wrong", and "nothing is wrong at all". Reading one as another is what
/// made the old Analytics tab report a hard failure as a normal wait for a month.
final class EngagementStateTests: XCTestCase {
    func testNothingToSayWhenThereAreDays() {
        XCTAssertNil(EngagementState.note(hasKey: true, isLoading: false, hasDays: true, error: nil))
    }

    /// A failed refresh with days already cached is the status bar's business, not a note under
    /// the chart — the figures on screen are still true.
    func testAnErrorWithDaysCachedSaysNothingHere() {
        XCTAssertNil(EngagementState.note(hasKey: true, isLoading: false, hasDays: true,
                                          error: AnalyticsError.badResponse))
    }

    func testNoKeyAsksForOneAndOffersSettings() {
        let note = EngagementState.note(hasKey: false, isLoading: false, hasDays: false, error: nil)
        XCTAssertEqual(note?.title, "Analytics needs a key")
        XCTAssertTrue(note?.offersSettings == true)
        XCTAssertTrue(note?.body.contains("Settings") == true)
    }

    func testLoadingSaysSo() {
        let note = EngagementState.note(hasKey: true, isLoading: true, hasDays: false, error: nil)
        XCTAssertEqual(note?.title, "Checking with App Store Connect…")
        XCTAssertFalse(note?.offersSettings == true)
    }

    /// The normal state for a day or two after analytics is switched on. Not an error, and the
    /// note must not offer the Settings button — that suggests the key is wrong when it isn't.
    func testWaitingForApplesFirstReportIsNotAnError() {
        let note = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                        error: AnalyticsError.notReadyYet)
        XCTAssertEqual(note?.title, "Apple is preparing your first report")
        XCTAssertTrue(note?.body.contains("24 to 48 hours") == true)
        XCTAssertFalse(note?.offersSettings == true)
    }

    func testNoErrorAndNoDaysIsAlsoAWait() {
        let note = EngagementState.note(hasKey: true, isLoading: false, hasDays: false, error: nil)
        XCTAssertEqual(note?.title, "Apple is preparing your first report")
    }

    func testAHardFailureSaysWhatWentWrong() {
        let note = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                        error: AnalyticsError.badResponse)
        XCTAssertEqual(note?.title, "Analytics couldn't load")
        XCTAssertEqual(note?.body, AnalyticsError.badResponse.errorDescription)
    }

    func testOnlyCredentialErrorsOfferSettings() {
        let credentials = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                               error: AnalyticsError.noKey)
        XCTAssertTrue(credentials?.offersSettings == true)

        let other = EngagementState.note(hasKey: true, isLoading: false, hasDays: false,
                                         error: AnalyticsError.badResponse)
        XCTAssertFalse(other?.offersSettings == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter EngagementStateTests 2>&1 | tail -5`
Expected: build failure, `cannot find 'EngagementState' in scope`.

If `AnalyticsError.noKey` doesn't report `suggestsCheckingCredentials == true`, adjust the last test to use whichever case does — run `grep -n "suggestsCheckingCredentials" -A12 Sources/VantageCore/Analytics.swift` to see.

- [ ] **Step 3: Write the implementation**

Create `Sources/VantageCore/EngagementState.swift`:

```swift
import Foundation

/// One note about why there are no engagement figures, and whether Settings is the fix.
public struct EngagementNote: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Offered only where it's the actual fix. A key button under "come back tomorrow" suggests
    /// something is wrong with the key, and under an HTTP 500 it invites replacing credentials
    /// that work.
    public let offersSettings: Bool

    public init(title: String, body: String, offersSettings: Bool) {
        self.title = title
        self.body = body
        self.offersSettings = offersSettings
    }
}

/// Turns the analytics situation into that note. In Core, not a view, so `swift test` covers the
/// difference between "wait a day" and "your key is wrong".
public enum EngagementState {
    /// `nil` when there is nothing to say — which includes a failed refresh over days that are
    /// already cached: those figures are still true, and the status bar carries the failure.
    public static func note(hasKey: Bool,
                            isLoading: Bool,
                            hasDays: Bool,
                            error: Error?) -> EngagementNote? {
        guard !hasDays else { return nil }

        guard hasKey else {
            return EngagementNote(
                title: "Analytics needs a key",
                body: "Analytics uses the same key as Reviews — there isn't a separate one. Add it "
                    + "under Settings › Reviews & Analytics. Apple requires an Admin key to start "
                    + "generating a report, and takes 24 to 48 hours to produce the first one.",
                offersSettings: true)
        }

        if isLoading {
            return EngagementNote(title: "Checking with App Store Connect…",
                                  body: "", offersSettings: false)
        }

        // Asked of the error itself, where a test can reach it. Deriving this from `!stopsTheRun`
        // answers a different question and reported every hard failure as a normal wait.
        let analytics = error as? AnalyticsError
        let isWaiting = analytics.map(\.isWaitingForApple) ?? (error == nil)
        if isWaiting {
            return EngagementNote(
                title: "Apple is preparing your first report",
                body: "Vantage has asked Apple to start generating analytics for your apps. Apple "
                    + "takes 24 to 48 hours to produce the first one, and there is nothing else to "
                    + "do — it will appear here on its own. This is not an error.",
                offersSettings: false)
        }

        return EngagementNote(
            title: "Analytics couldn't load",
            body: analytics?.errorDescription ?? "Couldn't load analytics.",
            offersSettings: analytics?.suggestsCheckingCredentials == true)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EngagementStateTests 2>&1 | grep -E "Executed|error|failed"`
Expected: `Executed 8 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add Sources/VantageCore/EngagementState.swift Tests/VantageCoreTests/EngagementStateTests.swift
git commit -m "feat: the engagement note, decided in Core rather than a view"
```

---

### Task 3: Impressions and page views as chart series

**Files:**
- Modify: `Sources/VantageCore/Trend.swift`
- Test: `Tests/VantageCoreTests/TrendTests.swift`

**Interfaces:**
- Consumes: `EngagementDay`, `TrendData`, `TrendPoint`
- Produces:
  - `TrendSeries.impressions` and `TrendSeries.pageViews`, with `rawValue` `"impressions"` / `"pageViews"`, both `isMoney == false`, both last in `displayOrder`
  - `Trend.series(days:series:length:endingAt:rates:displayCurrency:appleID:engagement:)` — the new parameter is `engagement: [EngagementDay] = []`, last, so existing call sites still compile
  - `Trend.engagement(days:metric:length:endingAt:)` is **deleted**

- [ ] **Step 1: Write the failing tests**

Append to `Tests/VantageCoreTests/TrendTests.swift`, inside the existing test class:

```swift
    // MARK: - Engagement series

    private func engagementDay(_ day: Int, impressions: Decimal, pageViews: Decimal) -> EngagementDay {
        EngagementDay(date: ReportDate(year: 2026, month: 9, day: day),
                      impressions: impressions, pageViews: pageViews)
    }

    func testImpressionsAndPageViewsDrawFromTheEngagementDays() {
        let engagement = [engagementDay(15, impressions: 100, pageViews: 10),
                          engagementDay(16, impressions: 300, pageViews: 20)]
        let end = ReportDate(year: 2026, month: 9, day: 16)

        let impressions = Trend.series(days: [], series: .impressions, length: 2, endingAt: end,
                                       rates: nil, displayCurrency: "USD", engagement: engagement)
        XCTAssertEqual(impressions.points.map(\.value), [100, 300])

        let pageViews = Trend.series(days: [], series: .pageViews, length: 2, endingAt: end,
                                     rates: nil, displayCurrency: "USD", engagement: engagement)
        XCTAssertEqual(pageViews.points.map(\.value), [10, 20])
    }

    /// Apple finalises a day about two days later. A day it hasn't produced is absent, and drawing
    /// it as zero invents a cliff.
    func testADayApplehasNotFinalisedIsAGapNotAZero() {
        let engagement = [engagementDay(16, impressions: 300, pageViews: 20)]
        let end = ReportDate(year: 2026, month: 9, day: 16)
        let data = Trend.series(days: [], series: .impressions, length: 3, endingAt: end,
                                rates: nil, displayCurrency: "USD", engagement: engagement)
        XCTAssertEqual(data.points.map(\.value), [nil, nil, 300])
    }

    /// Engagement isn't money, so it draws with no rate table — the chart must not report
    /// "Exchange rates unavailable" for a line that never needed them.
    func testEngagementDrawsWithoutARateTable() {
        let engagement = [engagementDay(16, impressions: 300, pageViews: 20)]
        let data = Trend.series(days: [], series: .impressions, length: 1,
                                endingAt: ReportDate(year: 2026, month: 9, day: 16),
                                rates: nil, displayCurrency: "USD", engagement: engagement)
        XCTAssertNil(data.unavailable)
    }

    func testTheNewSeriesAreOfferedLastAndRoundTripThroughStorage() {
        XCTAssertEqual(TrendSeries.displayOrder.suffix(2), [.impressions, .pageViews])
        XCTAssertEqual(TrendSeries(rawValue: TrendSeries.impressions.rawValue), .impressions)
        XCTAssertEqual(TrendSeries(rawValue: TrendSeries.pageViews.rawValue), .pageViews)
        XCTAssertEqual(TrendSeries.impressions.label, "Impressions")
        XCTAssertEqual(TrendSeries.pageViews.label, "Page views")
    }

    /// A stored choice from a build that didn't have these cases must still decode to something.
    func testAnUnknownStoredSeriesIsStillRejected() {
        XCTAssertNil(TrendSeries(rawValue: "impresions"))
        XCTAssertNil(TrendSeries(rawValue: "metric:nonsense"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TrendTests 2>&1 | tail -5`
Expected: build failure, `type 'TrendSeries' has no member 'impressions'`.

- [ ] **Step 3: Add the cases**

In `Sources/VantageCore/Trend.swift`, in `enum TrendSeries`:

```swift
    case metric(Metric)
    /// App Store engagement, from the analytics reports rather than the sales reports. Absent for
    /// days Apple hasn't finalised — about two days — and for days before the report request
    /// existed.
    case impressions
    case pageViews
```

`label`:

```swift
        case .impressions: return "Impressions"
        case .pageViews: return "Page views"
```

`displayOrder`:

```swift
    /// Everything offerable: money first, then units, then engagement.
    public static var displayOrder: [TrendSeries] {
        [.proceeds, .sales] + Metric.displayOrder.map(TrendSeries.metric) + [.impressions, .pageViews]
    }
```

`isMoney`:

```swift
        case .metric, .impressions, .pageViews: return false
```

`rawValue`:

```swift
        case .impressions: return "impressions"
        case .pageViews: return "pageViews"
```

`init?(rawValue:)`, before the `metric:` prefix check:

```swift
        if rawValue == "impressions" {
            self = .impressions
            return
        }
        if rawValue == "pageViews" {
            self = .pageViews
            return
        }
```

- [ ] **Step 4: Draw them in `Trend.series`**

Add the parameter to `series(…)`, last so existing call sites still compile:

```swift
    ///   - engagement: analytics days, used only by `.impressions` and `.pageViews`.
    public static func series(days: [DaySales],
                              series: TrendSeries,
                              length: Int,
                              endingAt end: ReportDate,
                              rates: FXRates?,
                              displayCurrency: String,
                              appleID: String? = nil,
                              engagement: [EngagementDay] = []) -> TrendData {
```

Immediately after the `isMoney` rates guard at the top of the function body, add:

```swift
        // Engagement comes from a different API with a different schedule, so it has its own
        // lookup. Everything below — gaps, the range including zero, the labels — is the same.
        if series == .impressions || series == .pageViews {
            let byDate = Dictionary(engagement.map { ($0.date, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let dates = end.lastDays(length).sorted()
            var values: [ReportDate: Decimal] = [:]
            for date in dates {
                guard let day = byDate[date] else { continue }  // Absent stays absent.
                values[date] = series == .impressions ? day.impressions : day.pageViews
            }
            return numeric(values: values, dates: dates, series: series,
                           displayCurrency: displayCurrency)
        }
```

Then extract the shared tail of `series(…)` — everything from `let present = values.values` to the closing `return TrendData(...)` — into:

```swift
    /// The drawn shape, once the values are known: range including zero, gaps preserved, labels.
    private static func numeric(values: [ReportDate: Decimal],
                                dates: [ReportDate],
                                series: TrendSeries,
                                displayCurrency: String) -> TrendData {
```

and have the sales path call it too, so both series types share one definition of a gap and one axis rule.

`label(_:for:displayCurrency:)` gains:

```swift
        case .metric, .impressions, .pageViews: return Fmt.downloads(value)
```

- [ ] **Step 5: Delete `Trend.engagement`**

Delete the whole `public static func engagement(days:metric:length:endingAt:)` function. Its only caller is `AnalyticsView`, which Task 6 deletes; `swift build` will fail until then, so check with:

Run: `swift test --filter TrendTests 2>&1 | grep -E "Executed|error" | head -5`

If the only errors are in `Sources/Vantage/Panel/AnalyticsView.swift`, that's expected at this point — the tests compile against `VantageCore`. If you prefer a green build at every commit, do Task 6's deletion of `AnalyticsView.swift` now and note it in your report.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter TrendTests 2>&1 | grep -E "Executed|error|failed"`
Expected: 0 failures.

- [ ] **Step 7: Commit**

```bash
git add Sources/VantageCore/Trend.swift Tests/VantageCoreTests/TrendTests.swift
git commit -m "feat: impressions and page views as chart series"
```

---

### Task 4: The headline line and app-row impressions

**Files:**
- Modify: `Sources/VantageCore/OverviewModel.swift`
- Modify: `Sources/VantageCore/AppDetailModel.swift`
- Test: `Tests/VantageCoreTests/OverviewModelTests.swift`
- Test: `Tests/VantageCoreTests/AppDetailModelTests.swift`

**Interfaces:**
- Consumes: `EngagementSummary.build(days:from:to:)` (Task 1)
- Produces:
  - `OverviewModel.build(…)` and `AppDetailModel.build(…)` gain `engagement: [String: [EngagementDay]] = [:]`, keyed by Apple ID, placed before `now:`
  - `OverviewModel.Headline` gains `public let engagement: EngagementSummary?` and `public let engagementNote: String?`
  - `OverviewModel.AppRow` gains `public let impressions: Decimal?`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/VantageCoreTests/OverviewModelTests.swift`, inside the existing class. Use the file's existing helpers for building `DaySales` — read the top of the file first and match them.

```swift
    // MARK: - Engagement

    private func engagementDay(_ day: Int, impressions: Decimal, pageViews: Decimal) -> EngagementDay {
        EngagementDay(date: ReportDate(year: 2026, month: 9, day: day),
                      impressions: impressions, pageViews: pageViews)
    }

    func testTheHeadlineCarriesEngagementForTheSpan() {
        let days = [day("2026-09-16", proceeds: ["USD": 10])]
        let engagement = ["1": [engagementDay(16, impressions: 1_000, pageViews: 45)],
                          "2": [engagementDay(16, impressions: 1_140, pageViews: 51)]]
        let model = OverviewModel.build(days: days, rates: nil, error: nil, metrics: [.installs],
                                        displayCurrency: "USD",
                                        span: OverviewModel.Span(title: "Yesterday", length: 1),
                                        engagement: engagement)

        XCTAssertEqual(model.headline?.engagement?.impressions, 2_140)
        XCTAssertEqual(model.headline?.engagement?.pageViews, 96)
        XCTAssertNil(model.headline?.engagementNote, "Figures and a note are mutually exclusive")
    }

    /// Apple finalises a day about two days after it, so the newest sales day usually has no
    /// analytics. Saying so beats a blank space or a zero.
    func testASpanWithNoEngagementSaysSoInsteadOfShowingZeros() {
        let days = [day("2026-09-16", proceeds: ["USD": 10])]
        let model = OverviewModel.build(days: days, rates: nil, error: nil, metrics: [.installs],
                                        displayCurrency: "USD",
                                        span: OverviewModel.Span(title: "Yesterday", length: 1),
                                        engagement: ["1": [engagementDay(1, impressions: 5, pageViews: 1)]])

        XCTAssertNil(model.headline?.engagement)
        XCTAssertEqual(model.headline?.engagementNote,
                       "Impressions not available yet for these days")
    }

    func testTheRetentionFootnoteAppearsOnlyWithEngagementFigures() {
        let days = [day("2026-09-16", proceeds: ["USD": 10])]
        let note = "Apple keeps analytics for 35 days — older days are Vantage's own copy."

        let withEngagement = OverviewModel.build(
            days: days, rates: nil, error: nil, metrics: [.installs], displayCurrency: "USD",
            span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: ["1": [engagementDay(16, impressions: 10, pageViews: 1)]])
        XCTAssertTrue(withEngagement.footnotes.contains(note))

        let without = OverviewModel.build(
            days: days, rates: nil, error: nil, metrics: [.installs], displayCurrency: "USD",
            span: OverviewModel.Span(title: "Yesterday", length: 1))
        XCTAssertFalse(without.footnotes.contains(note))
    }

    func testAppRowsCarryTheirOwnImpressions() {
        let days = [day("2026-09-16", proceeds: ["USD": 10])]   // must contain apps "1" and "2"
        let model = OverviewModel.build(
            days: days, rates: nil, error: nil, metrics: [.installs], displayCurrency: "USD",
            span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: ["1": [engagementDay(16, impressions: 340, pageViews: 12)]])

        XCTAssertEqual(model.apps.first { $0.appleID == "1" }?.impressions, 340)
        XCTAssertNil(model.apps.first { $0.appleID == "2" }?.impressions,
                     "An app with no analytics shows nothing, never 0")
    }
```

Adjust `day(...)` calls to whatever helper the file already has, and make sure the fixture has two apps with Apple IDs `"1"` and `"2"` — read the file and reuse its fixtures rather than inventing new ones.

Append to `Tests/VantageCoreTests/AppDetailModelTests.swift`:

```swift
    func testAnAppsHeadlineCarriesItsOwnEngagement() {
        let engagement = ["1": [EngagementDay(date: ReportDate(year: 2026, month: 9, day: 16),
                                              impressions: 340, pageViews: 12)],
                          "2": [EngagementDay(date: ReportDate(year: 2026, month: 9, day: 16),
                                              impressions: 999, pageViews: 99)]]
        let model = AppDetailModel.build(
            appleID: "1", days: days, rates: nil, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: engagement)

        XCTAssertEqual(model.summary.headline?.engagement?.impressions, 340,
                       "One app's figures, not the portfolio's")
    }

    func testAnAppWithNoEngagementGetsTheNote() {
        let model = AppDetailModel.build(
            appleID: "1", days: days, rates: nil, error: nil, metrics: [.installs],
            displayCurrency: "USD", span: OverviewModel.Span(title: "Yesterday", length: 1),
            engagement: [:])

        XCTAssertNil(model.summary.headline?.engagement)
        XCTAssertEqual(model.summary.headline?.engagementNote,
                       "Impressions not available yet for these days")
    }
```

Use the fixtures already in that file for `days`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "OverviewModelTests|AppDetailModelTests" 2>&1 | tail -5`
Expected: build failure, `extra argument 'engagement' in call`.

- [ ] **Step 3: Extend the model types**

In `Sources/VantageCore/OverviewModel.swift`, in `struct Headline`, after `assumedZeroNote`:

```swift
        /// Engagement for the same days, when Apple has produced any.
        public let engagement: EngagementSummary?
        /// Why there are none, when there are none. Exactly one of these two is non-nil.
        public let engagementNote: String?
```

In `struct AppRow`, after `unitsLabel`:

```swift
        /// This app's impressions for the span. `nil` — never `0` — when Apple has none.
        public let impressions: Decimal?
```

Update their initialisers if they're hand-written, and fix every construction site the compiler names.

- [ ] **Step 4: Fill them in `build`**

Add the parameter to both `build` overloads in `OverviewModel`, before `now:`:

```swift
                             engagement: [String: [EngagementDay]] = [:],
```

The convenience overload passes it straight through. In the main one, after `let window = days.filter { … }`:

```swift
        // Engagement covers the same days as the money above it. Summed across apps for the
        // portfolio; `AppDetailModel` hands in one app's entry and gets that app's figures.
        let engagementDays = engagement.values.flatMap { $0 }
        let engagementSummary = EngagementSummary.build(days: engagementDays, from: start, to: end)
```

In the `Headline(...)` construction:

```swift
            engagement: engagementSummary,
            engagementNote: engagementSummary == nil
                ? "Impressions not available yet for these days" : nil)
```

In the app-row loop:

```swift
        for app in aggregate(window, metrics: metrics) {
            let rowEngagement = EngagementSummary.build(days: engagement[app.appleID] ?? [],
                                                        from: start, to: end)
            apps.append(AppRow(appleID: app.appleID, title: app.title,
                               money: money(app.proceeds), units: app.units,
                               unitsLabel: Fmt.downloadsWithArrow(app.units),
                               impressions: rowEngagement?.impressions))
        }
```

With the footnotes, after the rates footnote:

```swift
        if engagementSummary != nil {
            footnotes.append("Apple keeps analytics for 35 days — older days are Vantage's own copy.")
        }
```

In `Sources/VantageCore/AppDetailModel.swift`, add `engagement: [String: [EngagementDay]] = [:]` to both `build` overloads before `now:`, and pass only this app's entry down:

```swift
        let summary = OverviewModel.build(days: narrow(days, to: appleID), rates: rates,
                                          error: error, metrics: metrics,
                                          displayCurrency: displayCurrency, span: span,
                                          engagement: engagement[appleID].map { [appleID: $0] } ?? [:],
                                          now: now)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "OverviewModelTests|AppDetailModelTests" 2>&1 | grep -E "Executed|error|failed"`
Expected: 0 failures.

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`

```bash
git add Sources/VantageCore/OverviewModel.swift Sources/VantageCore/AppDetailModel.swift Tests/VantageCoreTests/OverviewModelTests.swift Tests/VantageCoreTests/AppDetailModelTests.swift
git commit -m "feat: engagement in the headline and on each app row"
```

---

### Task 5: The panel shows it

**Files:**
- Modify: `Sources/Vantage/Panel/PanelModel.swift` (the analytics section, ~lines 320–360)
- Modify: `Sources/Vantage/Panel/OverviewView.swift`
- Modify: `Sources/Vantage/Panel/AppDetailView.swift`
- Modify: `Sources/Vantage/Panel/Cards.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–4
- Produces: `PanelModel.engagementState: EngagementNote?`; `HeadlineCard` and `AppRowView` render the new fields

No unit tests: the app target has none, and every figure and sentence is already covered in Core. Verified by eye in Task 7.

- [ ] **Step 1: Update `PanelModel`**

Delete `@Published private(set) var engagementMetric: EngagementMetric = .impressions` and its `func select(_ metric: EngagementMetric)`. Add:

```swift
    /// Why there are no engagement figures, or nil when there's nothing to say. Decided in Core —
    /// see `EngagementState`.
    var engagementState: EngagementNote? {
        EngagementState.note(hasKey: hasReviewsKey,
                             isLoading: isLoadingAnalytics,
                             hasDays: !portfolioEngagement.isEmpty,
                             error: analyticsError)
    }
```

- [ ] **Step 2: Pass engagement into the models**

In `OverviewView.swift`:

```swift
    private var overview: OverviewModel {
        OverviewModel.build(days: model.days, rates: model.rates, error: model.error,
                            metrics: model.metrics, displayCurrency: Prefs.displayCurrency,
                            span: model.span, engagement: model.engagement)
    }
```

In `AppDetailView.swift`:

```swift
    private var detail: AppDetailModel {
        AppDetailModel.build(appleID: appleID, days: model.days, rates: model.rates,
                             error: model.error, metrics: model.metrics,
                             displayCurrency: Prefs.displayCurrency, span: model.span,
                             engagement: model.engagement)
    }
```

In `Cards.swift`, find where `TrendCard` calls `Trend.series(...)` and add **one argument** to that
call, leaving its existing arguments exactly as they are:

```swift
                            engagement: appleID.map { model.engagement[$0] ?? [] }
                                ?? model.portfolioEngagement)
```

`appleID` is `TrendCard`'s existing optional property: nil on the Overview (portfolio) and set on an
app's page. `model.portfolioEngagement` already sums the apps day by day — check its definition in
`PanelModel` before relying on it.

- [ ] **Step 3: Render the headline line**

In `Cards.swift`, in `HeadlineCard`, under the existing units line:

```swift
            if let engagement = headline.engagement {
                Text(engagement.line)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if let note = headline.engagementNote {
                Text(note)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
```

In `AppRowView`, after the units column:

```swift
            if let impressions = row.impressions {
                Text("\(Fmt.downloads(impressions)) impressions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
```

Match the row's existing layout — read it and follow its `HStack`/frame conventions rather than bolting a column on.

- [ ] **Step 4: Show the note under the chart**

In `OverviewView.swift`, after `TrendCard(model: model)`:

```swift
                    if let note = model.engagementState {
                        EngagementNoteCard(note: note, onSettings: model.onSettings)
                    }
```

Add to `OverviewView.swift`:

```swift
/// Why the chart has no impressions to draw — the states the Analytics tab used to own.
private struct EngagementNoteCard: View {
    let note: EngagementNote
    let onSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(note.title)
                .font(.system(size: 13, weight: .semibold))
            if !note.body.isEmpty {
                Text(note.body)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if note.offersSettings {
                Button("Open Settings…") { onSettings?() }
                    .controlSize(.small)
            }
        }
        .card()
    }
}
```

- [ ] **Step 5: Build and check**

Run:
```bash
swift build 2>&1 | grep -E "error|warning" | head
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
```
Expected: no errors from the files you changed (errors in `AnalyticsView.swift` are expected until Task 6), 0 test failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Vantage/Panel/PanelModel.swift Sources/Vantage/Panel/OverviewView.swift Sources/Vantage/Panel/AppDetailView.swift Sources/Vantage/Panel/Cards.swift
git commit -m "feat: engagement figures on the Overview and app detail"
```

---

### Task 6: Delete the Analytics tab

**Files:**
- Delete: `Sources/Vantage/Panel/AnalyticsView.swift`
- Modify: `Sources/Vantage/Panel/PanelRoute.swift`
- Modify: `Sources/Vantage/Panel/PanelRootView.swift` (~line 49)
- Modify: `Sources/VantageCore/Analytics.swift` (remove `EngagementMetric`)

**Interfaces:**
- Consumes: Task 5's replacements for everything this deletes
- Produces: a two-item rail, `PanelRoute` without `.analytics`

- [ ] **Step 1: Delete the view and the route**

```bash
git rm Sources/Vantage/Panel/AnalyticsView.swift
```

In `PanelRoute.swift`: remove `case analytics`, remove it from `railOrder`, and remove its arms in `symbol`, `label` and `size` (it shares `size` with `.appDetail` and `.reviews` — leave those).

In `PanelRootView.swift`, remove the `case .analytics:` arm that builds `AnalyticsView`.

- [ ] **Step 2: Remove `EngagementMetric`**

In `Sources/VantageCore/Analytics.swift`, delete `public enum EngagementMetric` and its `value(in:)` helper. Check first that nothing still uses it:

Run: `grep -rn "EngagementMetric" Sources Tests`
Expected after the deletion: no matches. If a test uses it, that test belonged to `Trend.engagement` (deleted in Task 3) — delete it too, and say so in your report.

- [ ] **Step 3: Build and test**

Run:
```bash
swift build 2>&1 | grep -E "error|warning" | head
swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1
./build.sh 2>&1 | tail -2
```
Expected: no errors, no warnings from changed files, 0 test failures, build succeeds.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: one view for sales and engagement — the Analytics tab is gone"
```

---

### Task 7: Verify by eye, then document

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `CHANGELOG.md`

**Interfaces:** none.

- [ ] **Step 1: Build and run**

```bash
pkill -f "MacOS/Vantage" || true
./build.sh && open build/Vantage.app
```

Check, in light **and** dark appearance:
1. The rail has Overview and Reviews only.
2. Overview's headline shows `… impressions · … page views · …% viewed` for a span that has analytics (try 7D or 30D), and "Impressions not available yet for these days" for yesterday.
3. The chart's `▾` menu lists Impressions and Page views last; picking one redraws; the choice survives closing and reopening the panel.
4. App rows show impressions; an app with none shows nothing extra.
5. Clicking into an app shows that app's engagement line, not the portfolio's.
6. Days Apple hasn't finalised are gaps in the chart, not drops to zero.

Report anything that doesn't match rather than adjusting Core to fit the view.

- [ ] **Step 2: `CLAUDE.md`**

In the architecture table, replace the `AnalyticsView.swift` row (if present) and add:

```markdown
| `Sources/VantageCore/EngagementSummary.swift` | Impressions, page views and conversion for the days on screen |
| `Sources/VantageCore/EngagementState.swift` | Why there are no engagement figures, in one note |
```

In the Analytics section, add:

```markdown
- **Engagement lives on the Overview, not its own tab.** Impressions and page views are two more
  `TrendSeries` cases, and the headline's third line is `EngagementSummary`. The "no key", "Apple is
  preparing your first report" and error states are `EngagementState`, in Core, because deciding
  them in a view is what let a hard failure read as a normal wait for a month.
```

- [ ] **Step 3: `README.md`**

Wherever the Analytics section is described, replace it with:

```markdown
Impressions, page views and the share of impressions that became page views appear on the Overview
alongside sales, and per app when you click into one. The chart draws either of them: pick
**Impressions** or **Page views** from the series menu. Analytics needs the same key as Reviews.
```

- [ ] **Step 4: `CHANGELOG.md`**

Under `## [Unreleased]` → `### Added`:

```markdown
- **Engagement where you're already looking.** Impressions, page views and the share of impressions
  that became page views now sit on the Overview and on each app, with both available as chart
  series. The separate Analytics tab is gone, and so is its second metric picker.
- **The analytics history Apple still holds.** A one-time snapshot request per app fills in the days
  before Vantage started asking, rather than starting from the day you set it up.
```

- [ ] **Step 5: Final check and commit**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`

```bash
git add CLAUDE.md README.md CHANGELOG.md
git commit -m "docs: engagement on the Overview"
```
