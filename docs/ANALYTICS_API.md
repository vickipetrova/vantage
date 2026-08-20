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

**The first report arrives 24–48 hours after the request.** That is not a failure and the UI must
not present it as one. A request nobody reads eventually gets `stoppedDueToInactivity`, which the
decoder surfaces so a frozen chart can explain itself.

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
then one segments call and one download **per instance**. `ASCAnalyticsClient.instanceLimit` caps
that at the newest 7 days; history accumulates in `AnalyticsStore` between refreshes, so a small
number still builds a long chart.

Rate limits are the same 3,500-per-hour rolling window as everything else on this API. Analytics is
fetched only when its section is opened, never from the poll timer.
