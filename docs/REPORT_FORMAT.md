# The Sales report format

What Apple actually returns from `GET /v1/salesReports`, verified against current documentation on
2026-08-02. Everything here is a fact with a source, not a guess — `ReportParser` is the one file in
this repo where being subtly wrong produces a number that looks plausible and isn't.

Sources, all fetched 2026-08-02:

- [Generating tokens for API requests](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [GET /v1/salesReports](https://developer.apple.com/documentation/appstoreconnectapi/get-v1-salesreports)
- [Summary Sales Report](https://developer.apple.com/help/app-store-connect/reference/reporting/summary-sales-report/)
- [Product type identifiers](https://developer.apple.com/help/app-store-connect/reference/reporting/product-type-identifiers/)
- [Sales and Trends reports availability](https://developer.apple.com/help/app-store-connect/reference/reporting/sales-and-trends-reports-availability/)
- [Identifying rate limits](https://developer.apple.com/documentation/appstoreconnectapi/identifying-rate-limits)

## The request

```
GET https://api.appstoreconnect.apple.com/v1/salesReports
  ?filter[frequency]=DAILY
  &filter[reportType]=SALES
  &filter[reportSubType]=SUMMARY
  &filter[vendorNumber]=<vendor number>
  &filter[reportDate]=YYYY-MM-DD
  &filter[version]=1_0
```

`frequency`, `reportType`, `reportSubType` and `vendorNumber` are documented as required;
`reportDate` and `version` are not. The allowed-values table gives exactly one legal combination for
a daily sales summary: `SALES` / `SUMMARY` / `DAILY` / `1_0`.

Apple's parameter text says `reportDate` is needed "for all report frequencies except `DAILY`, which
doesn't require a date". Vantage sends it anyway and always will: the whole app is built on asking
for one specific, named day and caching the answer forever. Omitting it would mean accepting
whatever day Apple felt like returning.

### Auth

A fresh ES256 JWT per request batch, signed with the `.p8` private key.

Header: `{"alg": "ES256", "kid": "<Key ID>", "typ": "JWT"}`

Payload for a **team** key: `{"iss": "<Issuer ID>", "iat": <epoch>, "exp": <epoch>, "aud": "appstoreconnect-v1"}`

Individual keys are a different shape — no `iss`, and `"sub": "user"` instead. Vantage targets team
keys, because the Sales and Reports role the README tells you to create only exists on team keys.

Apple rejects any token whose lifetime (`exp - iat`) exceeds 20 minutes, except for a scoped
allowlist of long-lived resources that does not include `salesReports`. The optional `scope` claim
takes an array of request strings; Vantage sets it to the one request it makes, so a leaked token is
worth nothing but a sales report.

`P256.Signing.PrivateKey(pemRepresentation:)` (CryptoKit, macOS 11+) reads the `.p8` as-is. JWS
wants the raw `r‖s` signature — `signature.rawRepresentation`, not the DER encoding.

### Rate limits

Every response carries `X-Rate-Limit: user-hour-lim:3500;user-hour-rem:500;` over a rolling hour,
and 429 with `RATE_LIMIT_EXCEEDED` past the ceiling. A 30-day backfill is 30 requests, so this is
never close — but the header is free to read and worth backing off on.

## The response

**200** is a gzip file, not JSON. Errors are JSON (`ErrorResponse`). The documented statuses are
200, 400, 401, 403 and 429 — see [404](#the-404-problem) below, which is undocumented and central.

Don't negotiate the content type. `Accept: application/a-gzip` has a history of drawing a 406 from
this endpoint; send no `Accept` and sniff the body instead — `1f 8b` is the report, `{` is an error.

Decompressing without dependencies: Apple's Compression framework documents `zlib` as "the raw
`DEFLATE` format", so it will not eat a gzip container as-is. Strip the 10-byte gzip header (plus
whatever `FEXTRA`/`FNAME`/`FCOMMENT`/`FHCRC` the flag byte announces), inflate the remainder raw,
and check the trailing CRC32 and ISIZE. That is a page of code and it keeps the report inside the
process — the alternative, piping through `/usr/bin/gunzip`, puts a day of sales figures through a
subprocess's stdout for no gain.

Decompressed, it's a tab-separated file: one header line, then one row per
(app × product type × country × currency) combination for that day.

## Columns

In order, from the Summary Sales Report reference:

`Provider`, `Provider Country`, `SKU`, `Developer`, `Title`, `Version`, `Product Type Identifier`,
`Units`, `Developer Proceeds (per unit)`, `Begin Date`, `End Date`, `Customer Currency`,
`Country Code`, `Currency of Proceeds`, `Apple Identifier`, `Customer Price`, `Promo Code`,
`Parent Identifier`, `Subscription`, `Period`, `Category`, `CMB`, `Supported Platforms`, `Device`,
`Preserved Pricing`, `Proceeds Reason`, `Client`, `Order Type`.

**Parse by header name, never by column index**, and match tolerantly. Apple's own documentation
disagrees with itself about these names: the field reference calls the ninth column
`Developer Proceeds (per unit)` while the sample report immediately below it — and every real
report — writes `Developer Proceeds`. The same page is titled "Version 1_3" while the availability
table lists Summary Sales as version `1_0`. Header text is the only thing that has stayed stable,
and only approximately.

The five columns Vantage actually reads: `Title`, `Product Type Identifier`, `Units`,
`Developer Proceeds`, `Currency of Proceeds`, `Apple Identifier`.

### Units is not an integer

`Units` is `DECIMAL(18,2)`. Apple: "Negative values indicate refunds […] A value of 0 may indicate a
partial refund." Parse it as `Decimal`, round only for display. The same goes for money, everywhere.

### Refunds

Apple, verbatim: "Refunds have negative values for Units and Customer Price, and positive values for
Developer Proceeds." Their sample refund row is `1F`, Units `-50`, Developer Proceeds `.7`.

So `Units × Developer Proceeds` is correct arithmetic on its own — a refund subtracts, because the
units are negative and the per-unit proceeds are not. **Never take the absolute value of either.**

Downloads are counted **net**, negatives included, and the count is not floored at zero. A
refund-heavy day can therefore display a negative download count. That is deliberate: it's the
number App Store Connect's own Units column shows, so the two reconcile. A prettier figure that
disagreed with the source of truth would be the worse outcome.

## Product type identifiers

Verbatim from Apple's table:

| Code | Type | Description |
|---|---|---|
| `1` | Free or paid app | iOS, iPadOS, visionOS, watchOS |
| `1-B` | App Bundle | iOS, iPadOS, visionOS app bundle |
| `F1-B` | App Bundle | Mac app bundle |
| `1E` | Paid app | Custom iOS app |
| `1EP` | Paid app | Custom iPadOS app |
| `1EU` | Paid app | Custom universal app |
| `1F` | Free or paid app | Universal app, excluding tvOS |
| `1T` | Free or paid app | iPad apps |
| `3` | Re-download | App update (iOS, tvOS, visionOS, watchOS) |
| `3F` | Re-download | Universal app, excluding tvOS |
| `7` | Update | App update (iOS, tvOS, visionOS, watchOS) |
| `7F` | Update | Universal app, excluding tvOS |
| `7T` | Update | App update (iPadOS, visionOS) |
| `F1` | Free or paid app | Mac |
| `F7` | Update | App update (Mac) |
| `FI1` | In-App Purchase | Mac |
| `IA1` | In-App Purchase | In-App Purchase (iOS, iPadOS, visionOS) |
| `IA1-M` | In-App Purchase | In-App Purchase (Mac) |
| `IA3` | Restored In-App Purchase | Non consumable In-App Purchase |
| `IA9` | In-App Purchase | Non-renewing subscription (iOS, iPadOS, visionOS) |
| `IA9-M` | In-App Purchase | Subscription (Mac) |
| `IAY` | In-App Purchase | Auto-renewable subscription (iOS, iPadOS, visionOS) |
| `IAY-M` | In-App Purchase | Auto-renewable subscription (Mac) |

### How Vantage reads it

- **A download** is a first acquisition of an app: `1`, `1-B`, `1E`, `1EP`, `1EU`, `1F`, `1T`, `F1`,
  `F1-B`. Mac (`F1`, `F1-B`) is in that list deliberately — half this developer's portfolio is Mac
  apps, and a download counter that silently ignored them would be wrong in the least visible way.
- **Not a download:** updates (`7`, `7F`, `7T`, `F7`) and re-downloads (`3`, `3F`). A re-download is
  a customer who already owns the app installing it again; counting it would inflate the number
  against what App Store Connect reports.
- **Everything else counts toward proceeds only** — in-app purchases and subscriptions are revenue,
  not installs.
- **Unknown codes count toward proceeds, never toward downloads, and never crash.** This is not
  defensive theatre. Apple's own sample report on the Summary Sales Report page uses `1AY`, which
  does not appear anywhere in the table above; and their table types `3`/`3F` as "Re-download" while
  describing both as "App update". The list drifts and it is internally inconsistent today.

Rows that can't be parsed at all — wrong column count, unreadable decimal — are skipped and counted
in a debug tally. A malformed row loses one row, never the day.

## Time

**Report days are Pacific.** A daily report covers 00:00–23:59 Pacific Time, and downloaded reports
are always expressed in PT regardless of where you are. The App Store Connect *dashboard* defaults
to UTC, which is why its numbers can disagree with a downloaded report for the same nominal day.

Consequences Vantage lives with:

- "Yesterday" is computed in `America/Los_Angeles`, not in the user's locale. For a user in Europe,
  the day Vantage calls yesterday can be two calendar days back in local terms. **Always render the
  report's own date in the dropdown** rather than relying on the word "yesterday" to be unambiguous.
- Apple: "Daily reports are available the following day […] Reports are generally available by
  8 a.m. Pacific Time (PT)." Polling from 05:00 PT and retrying hourly, as the plan specifies, sits
  comfortably inside that.
- Daily, weekly and monthly reports are **deleted after one year** and are not regenerated. The disk
  cache isn't only a politeness to Apple's servers — past a year it's the only copy.

## The 404 problem

The endpoint's documented statuses are 200, 400, 401, 403, 429. In practice a date with no report
returns **404** with a JSON error body. That is not the interesting part.

The interesting part is that Apple only generates a Summary Sales report when there was **"at least
one app unit sold"**. So a 404 has two entirely different meanings:

1. The report isn't published yet (before ~08:00 PT the next day).
2. There genuinely were zero units on that day, and no report will ever exist.

They are indistinguishable by status code. Vantage resolves them by the clock:

- **Before 10:00 PT** on the day after the report date, a 404 is "not published yet". The dropdown
  says so, and the scheduler keeps retrying hourly.
- **From 10:00 PT onward**, a 404 is taken as a genuine zero-units day: it's cached as zero proceeds
  and zero downloads, and polling for that date stops. Apple publishes by 08:00 PT, so this allows
  two hours of slack.

That second rule is a guess, and it is allowed to be wrong. A day cached this way is stored as
**assumed zero, not observed zero**, and that distinction is load-bearing: **Refresh Now re-fetches
assumed-zero days.** A report that lands unusually late is one menu click away from correcting
itself. Days derived from an actual 200 are immutable and are never re-fetched, ever.

Vantage must never render a "not published yet" as `$0 · 0↓`, and never leave a real zero day
looking like a permanent loading state.

## Currency

`Currency of Proceeds` is the currency you're *paid* in for that storefront's region, and one day's
report routinely spans several. Totals are therefore per-currency first, converted second, and the
converted figure is always marked `≈`.

Rates come from the ECB's own daily feed
(`https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml`) rather than a JSON re-server like
frankfurter.app. Same data, one fewer party in the request path, and it holds the app's total
network surface to two hosts.

The ECB publishes daily reference rates against EUR for roughly 29 currencies, on TARGET working
days only — so the feed is stale over weekends and holidays by design (on 2026-08-02 the feed was
dated 2026-07-31). Currencies Apple pays in that the ECB doesn't publish (TWD, AED, SAR, VND, COP,
CLP, PEN, EGP, NGN, PKR, KZT and others) cannot be converted at all. They must be surfaced as
unconverted rather than quietly dropped from the total, because a total that silently omits a
currency is exactly the kind of plausible-looking wrong number this app exists to avoid.
