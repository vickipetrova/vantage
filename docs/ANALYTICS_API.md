# The Analytics Reports API

Verified against Apple's documentation on 2026-08-21. Read this before touching `SegmentParser`,
`AnalyticsDecoder` or `ASCAnalyticsClient`.

Nothing about this API is one request. To see a single number you ask Apple to start generating a
report, wait a day or two, then walk four levels down.

## The lifecycle

```
1. GET  /v1/apps/{id}/analyticsReportRequests           does one already exist?
2. POST /v1/analyticsReportRequests                     if not, start one   (Admin only)
3. GET  /v1/analyticsReportRequests/{id}/reports        which reports did it produce?
4. GET  /v1/analyticsReports/{id}/instances             which days are available?
5. GET  /v1/analyticsReportInstances/{id}/segments      the files for one day
6. GET  <pre-signed S3 URL>                             the gzipped TSV itself
```

### 1–2. The request

`POST` body — note there is **no `reportType`**; a request produces every report for its access
type, and you filter later:

```json
{"data":{"type":"analyticsReportRequests",
         "attributes":{"accessType":"ONGOING"},
         "relationships":{"app":{"data":{"type":"apps","id":"…"}}}}}
```

`accessType` is `ONGOING` (keeps producing daily, weekly and monthly reports) or
`ONE_TIME_SNAPSHOT` (historical data, generated once and then stopped). Vantage uses `ONGOING`.

**Creating a request needs an Admin key.** Once one exists, a lesser role can read the results —
which is why `ASCAnalyticsClient` checks for an existing request before trying to create one, and
why a 403 here gets its own error rather than the generic one.

**The token for this POST must carry no `scope` claim.** Verified against the live API on
2026-09-16: a scoped write is answered `405 METHOD_NOT_ALLOWED` — the status for a bad path, which
is why this reads as a wrong endpoint and isn't one. Apple's scope claim accepts `GET` entries only.
`ASCToken.mint` therefore sets scope on GET and omits it otherwise; see the table in its doc comment
and `ASCTokenTests.testWriteTokensCarryNoScopeBecauseAppleRefusesThem`.

This shipped wrong and cost a month of analytics. The create POST 405'd on every single refresh, so
no report request ever existed; the client then returned `notReadyYet` and the panel rendered
"Apple is preparing your first report — this is not an error", indefinitely.

**The first report arrives 24–48 hours after the request.** That is not a failure and the UI must
not present it as one. A request nobody reads eventually gets `stoppedDueToInactivity`.

**A stopped request must be deleted before a new one can be created.** Apple will not restart one,
and `POST`ing over it is answered `409 STATE_ERROR — You already have such an entity`. The original
code filtered the stopped request out and fell straight through to create, so it hit that 409 on
every refresh, mapped it to `notReadyYet`, and the panel said "Apple is preparing your first report"
with no way back — a second dead end with the same symptom as the scope bug above. The decision now
lives in `AnalyticsRequestDecision.decide`, where it is tested: `use`, `restart`, or `create`.

Deleting is safe for history. `AnalyticsStore` is Vantage's own archive and is never touched by it;
that is what merging rather than mirroring buys.

### 3. Reports

`filter[category]` takes `APP_STORE_ENGAGEMENT`, `COMMERCE`, `APP_USAGE`, `FRAMEWORK_USAGE`,
`PERFORMANCE`. Note it is `COMMERCE`, not `APP_STORE_COMMERCE`.

One category holds several reports, so Vantage matches on the report **name** — impressions and page
views live only in *App Store Discovery and Engagement*. Apple ships Standard and Detailed variants;
Standard omits the uniquely-identifiable fields and carries both figures, so Standard is enough.

### 4. Instances

`filter[granularity]` is `DAILY`, `WEEKLY` or `MONTHLY`; `filter[processingDate]` is `YYYY-MM-DD`.

**`processingDate` is the day Apple processed the data, not the day the data describes.** The rows
inside carry their own `Date` column, and that is the one that matters.

**Instances are retained for 35 days.** Past that the data exists only in Vantage's own cache, which
is why `AnalyticsStore` merges rather than replaces.

### 5–6. Segments, and the fifth host

An instance is split into segments — download all of them to get the whole day.

```
{"url": "https://…s3.…amazonaws.com/…?X-Amz-Signature=…",
 "checksum": "…", "sizeInBytes": 1048576}
```

Three facts that shape the code:

- **The URL is a pre-signed AWS S3 URL, valid for five minutes.** Not an Apple host. This is the
  only destination in the whole application that isn't Apple's or the ECB's, and it cannot be named
  in advance — the bucket and region vary. `AnalyticsDecoder.isPermittedSegmentHost` therefore pins
  the tightest constraint that is still honest: `https`, and a host under `.amazonaws.com`. The
  leading dot matters; without it `evilamazonaws.com` passes.
- **Five minutes is short.** Listing segments far ahead of downloading them guarantees some expire,
  which is why the client interleaves the two rather than gathering all URLs first.
- **The download carries no credential.** It goes out on a second `URLSession` configured with no
  additional headers at all, so there is no path by which an `Authorization` header could reach a
  host outside Apple's estate.

`checksum` is MD5 of the compressed bytes. Weak as a hash, but it is what Apple offers and it catches
the failure that actually happens — a truncated download.

## The report format

Segments are **gzipped TSV**, so `Gunzip` and the match-columns-by-normalized-name discipline from
`ReportParser` both carry over unchanged.

*App Store Discovery and Engagement* rows carry `Date`, `App Name`, `App Apple Identifier`, `Event`,
`Page Type`, `Page Title`, `Source Type`, `Engagement Type`, `Device`, `Platform Version`,
`Territory`, `Counts` and `Unique Counts`. Vantage needs three of them: `Date`, `Event`, `Counts`.

One day arrives as many rows — split by territory, device, source — which all add up.

Traps, all with tests:

- **CRLF.** Swift treats `\r\n` as a **single** `Character`, so `split(separator: "\n")` never
  matches it and a CRLF file comes back as one enormous line. Line endings are normalized before
  splitting, exactly as `ReportParser` does. The first version of `SegmentParser` got this wrong and
  had dead `\r`-stripping code that would have hidden it indefinitely.
- **Event names have shifted case and spacing** between reporting periods, so they're matched
  normalized. An event the parser doesn't recognise is **reported**, never folded into a figure it
  might not belong to.
- **Counts are parsed POSIX**, so a machine in a comma-decimal locale doesn't read `1234` as `1.234`.
- **A file missing `Date`, `Event` or `Counts` yields nothing** rather than falling back to column
  positions. Guessing at positions is how a chart ends up plotting territory codes.

## What this costs

One refresh is, per app: one request list, possibly one create, one report list, one instance list,
then one segments call and one download **per instance**.

How many instances is **not fixed**. `AnalyticsStore.instancesNeeded` sizes each refresh to the gap
since that app was last fetched: `openingInstances` (7) on a cold cache, otherwise the days missed
plus `revisionOverlap` (3), capped at `retentionInstances` (35). It was a fixed 7, and that quietly
meant a fortnight away left days 8–14 missing **forever** — every later refresh asked for the newest
seven again and nothing went back for the rest, while Apple still held them the whole time. History
accumulates in `AnalyticsStore` between refreshes, so a short absence still costs nothing.

The overlap is not optional: Apple revises a day as late events land and a day isn't final until two
days after it, so a refresh that took only genuinely new days would keep the first provisional
figures forever.

Rate limits are the same 3,500-per-hour rolling window as everything else on this API.

Analytics is fetched on **every refresh** — launch, wake and the poll timer included — and also on
opening the panel, opening the Analytics section, and Refresh Now.

Background fetching is deliberate, and the reason is retention rather than convenience: Apple keeps
daily instances for 35 days, so a history nobody collects is *lost*, not merely late. An app sitting
in the menu bar therefore keeps itself current without anyone opening anything.

What makes that affordable is `AnalyticsStore.maxAge` (6 hours), not restraint about when to ask.
`Schedule.nextPoll` fires hourly only while chasing a report that's due and otherwise once at the
next morning window, but the staleness gate is the real limit: **one to four fetches a day however
often the timer fires**, which suits data that only moves daily. Opening the panel twenty times
costs nothing extra for the same reason.

Only Refresh Now passes `force` — an explicit click means now, a timer doesn't get to say that.
