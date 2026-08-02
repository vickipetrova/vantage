# Vantage

Your App Store portfolio in the macOS menu bar:

```
$142 · 89↓
```

Yesterday's proceeds and yesterday's downloads, across every app under your vendor number. Click for
the per-app breakdown, 7- and 30-day totals, and when the report was published.

<!-- HERO GIF: record the menu bar with the dropdown open, save it as assets/vantage.gif,
     and uncomment the line below.
<img src="assets/vantage.gif" alt="Vantage in the menu bar, with the dropdown open" width="420">
-->

The open-source alternative to the paid menu bar sales apps: your App Store Connect key never
touches anyone's server, and you can read every line that touches it.

> [!IMPORTANT]
> **Vantage shows yesterday, not today.** Apple publishes daily sales reports the following morning,
> generally by 8 a.m. Pacific. No API reports today's sales, so no honest app can show them —
> Vantage shows yesterday accurately and names the day it's showing, rather than inventing a
> "today" number. Near-real-time figures via RevenueCat are on the roadmap.

## Status

**Under construction.** Replace this section with install instructions at v0.1.0.

## How it works

Once a day, after Apple publishes, Vantage makes one request:

```
GET https://api.appstoreconnect.apple.com/v1/salesReports
    ?filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY
    &filter[vendorNumber]=…&filter[reportDate]=YYYY-MM-DD&filter[version]=1_0
Authorization: Bearer <a JWT signed locally with your .p8, valid 20 minutes>
```

The response is a gzipped tab-separated report. Vantage parses it, caches that day on disk — daily
reports are immutable, so a day is fetched exactly once, ever — and stops. Proceeds are converted to
your display currency using the European Central Bank's daily reference rates, which is the only
other request the app makes.

Your numbers are never sent anywhere. There is no server behind this app.

## Setup

You'll need an **App Store Connect API key with the Sales and Reports role** — not an Admin key;
Vantage neither needs nor wants one — and your **Vendor Number** (App Store Connect › Payments and
Financial Reports, top left).

Enter the Issuer ID, Key ID, `.p8` file and Vendor Number in Settings. They go straight into the
macOS Keychain. [SECURITY.md](SECURITY.md) documents exactly what that key can access and where it
lives.

## Roadmap

Deliberately small for v0.1. These are filed as
[good first issues](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22):

- A RevenueCat provider, for near-real-time revenue
- A weekly digest notification
- A sparkline of the last 30 days in the dropdown
- A refunds row
- Multiple vendor numbers in one menu
- CSV export

Out of scope: reviews and ratings, full charting, impressions from the Analytics API. See
[CONTRIBUTING.md](CONTRIBUTING.md).

## Other projects in this space

<!-- PHASE 6: verify each name, URL and description before publishing — do not ship a guessed link.
     The plan calls for a generous section covering Perch, Appstat and AC Widget. -->

Vantage's one distinguishing bet is that a sales app should be small enough to audit.

## Security

Vantage stores your API key in the macOS Keychain and sends it to exactly one place:
`api.appstoreconnect.apple.com`. One other request, carrying nothing that identifies you, fetches
exchange rates from `www.ecb.europa.eu`. No telemetry, no analytics, no update checks. See
[SECURITY.md](SECURITY.md).

## Trademark / Not affiliated

This is an unofficial, open-source side project. **It is not affiliated with, endorsed by, or
sponsored by Apple Inc.** "App Store", "App Store Connect" and "Apple" are trademarks of Apple Inc.,
used here nominatively. The MIT license below covers this source code only and conveys no rights to
Apple's trademarks or brand.

## License

MIT © Victoria Petrova. See [LICENSE](LICENSE).
