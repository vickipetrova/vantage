# Analytics in the Overview — design

Status: approved in discussion, 2026-09-17. Branch: `analytics-in-overview`.

## Goal

One view for everything. Impressions and page views stop being their own tab and become part of the
Overview and app detail: two more series in the chart's existing picker, a line in the headline, and
a figure on each app row. The Analytics tab is removed.

## Why

- The tab's segmented Impressions/Page views control is a second picker doing the job the chart's
  `▾` picker already does everywhere else.
- Engagement and sales answer one question together — how many people saw the app, how many opened
  its page, how many bought — and that question can't be asked across two tabs.
- The conversion rate (page views ÷ impressions) is the one figure neither API returns, and it only
  makes sense with both numbers side by side.

## Scope

- In: Overview and app detail show engagement figures and can chart them; the Analytics tab, its
  view file, its route and its metric picker are deleted; the states that tab owned move into
  Overview.
- Out: changes to analytics fetching, the request lifecycle, the cache format, or `AnalyticsStore`.
  Historical backfill via `ONE_TIME_SNAPSHOT` is separate work, specified on its own.

## 1. What the user sees

### Overview

```
┌──────────────────────────────────────────────────────┐
│ 1D  7D  30D  Custom            ‹  10–16 Sep  ›       │
├──────────────────────────────────────────────────────┤
│ £412.30                                              │
│ 38 downloads · last 7 days                           │
│ 2,140 impressions · 96 page views · 4.5% viewed      │
│ ↑ 12% vs the 7 days before                           │
├──────────────────────────────────────────────────────┤
│ ▾ Proceeds                                     chart │
│   (Proceeds · Sales · Downloads · Updates ·          │
│    Impressions · Page views)                         │
├──────────────────────────────────────────────────────┤
│ Apps                                    ▾ Downloads  │
│ PhotoMagic    £180.00    12    340 impressions       │
│ LensKit       £121.40     9    210 impressions       │
└──────────────────────────────────────────────────────┘
```

- **Headline, third line:** impressions, page views, and the share of impressions that became page
  views, for the selected days.
- **Chart picker:** the existing `▾` menu gains Impressions and Page views, last, after the sales
  series. Same control on Overview and app detail, which already share it.
- **App rows:** each row gains that app's impressions for the selected days, after the unit count.
  One line per row, as now. An app with no analytics for the span shows nothing extra — never `0`.

### When the span has no analytics

Apple finalises a day's analytics about two days after it, and a report request only produces days
from its own creation onwards. When the selected days have none, the third line is replaced by:

> Impressions not available yet for these days

Sales figures are unaffected. Choosing Impressions in the chart for days with no data draws the
chart's existing gap treatment, never a line at zero.

### The states the Analytics tab owned

They move to a note under the Overview chart, shown only when they apply:

| Situation | Note |
|---|---|
| No reviews key | "Analytics needs a key", the existing explanation, and an **Open Settings…** button |
| Waiting for Apple's first report | "Apple is preparing your first report", with the 24–48 hour explanation. Not an error |
| A hard failure | the existing `AnalyticsError` message; the Settings button only when the error suggests credentials |
| Any engagement figure shown | the footnote that Apple keeps instances 35 days and older days are Vantage's own copy |

## 2. Core changes

### `Trend.swift`

- `TrendSeries` gains `.impressions` and `.pageViews`: labels "Impressions" and "Page views",
  `isMoney == false`, and `displayOrder` places them after the sales series.
- `Trend.series(days:series:…)` gains an `engagement: [EngagementDay]` parameter and draws the two
  new cases from it. Days absent from the engagement data stay gaps.
- `Trend.engagement(days:metric:length:endingAt:)` is deleted — it did this job for the old tab.

### `EngagementSummary` (new)

Given engagement days and the selected span: impressions, page views, the conversion percentage, and
the days actually covered. Returns nil when the span holds no engagement day, which is what makes
the headline show the note instead. All figures `Decimal`.

### `EngagementState` (new)

Turns no key / loading / waiting for Apple / error / fine into the single note Overview shows under
the chart, and whether to offer the Settings button. This is what `AnalyticsView` decided inside a
view; in Core, `swift test` covers it.

### `OverviewModel`

- `build(…)` takes `engagement: [String: [EngagementDay]]`, keyed by Apple ID, as `PanelModel`
  already holds it.
- `Headline` gains `engagement: EngagementSummary?` and `engagementNote: String?`. Exactly one is
  set.
- `AppRow` gains `impressions: Decimal?`.
- The 35-day footnote joins `footnotes` whenever an engagement figure is shown.

### `AppDetailModel`

Takes that app's engagement days and gains the same headline line.

### Deleted

`Sources/Vantage/Panel/AnalyticsView.swift`; `PanelRoute.analytics` and its rail entry;
`PanelModel.engagementMetric` and its `select(_:)`; `EngagementMetric`.

### Unchanged

Analytics fetching, the request lifecycle, `AnalyticsStore` and its merging, the cache format, and
the reviews-key requirement. Only the display changes.

## 3. Testing

New and extended tests in `VantageCoreTests`, all offline:

- **`EngagementSummaryTests`** — sums cover the span only; conversion is page views ÷ impressions as
  a percentage; zero impressions yields no conversion rather than a division by zero; a span with no
  engagement days returns nil; a partly covered span reports the days it used.
- **`TrendTests`** — the new series draw from engagement days; unfinalised days are gaps, not zeros;
  the new cases come last in `displayOrder` and need no rate table.
- **`OverviewModelTests`** — the headline carries the engagement line or the note, never both; app
  rows carry impressions only where they exist; the 35-day footnote appears only alongside
  engagement figures.
- **`EngagementStateTests`** — each situation produces the right note, and only the no-key and
  credential-ish errors offer the Settings button.
- **`AppDetailModelTests`** — one app's engagement line, and an app with none.
- **Prefs** — a saved `trendSeries` of Impressions survives a round trip; an unknown stored value
  still falls back to Downloads.

Verified by eye (per `CLAUDE.md`), light and dark:

1. The rail has Overview and Reviews only, and nothing links to a removed route.
2. The headline shows engagement figures for a span that has them, and the note for one that
   doesn't.
3. The chart's `▾` menu lists Impressions and Page views, redraws on selection, and the choice
   survives closing and reopening the panel.
4. App rows show impressions; an app with none shows nothing extra.
5. With the reviews key removed, Overview shows the "Analytics needs a key" note and its button, and
   no engagement figures.

The "Apple is preparing your first report" state can't be reproduced on an account past it;
`EngagementStateTests` covers its wording instead.
