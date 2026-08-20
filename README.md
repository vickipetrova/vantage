# Vantage

Your App Store portfolio in the macOS menu bar:

```
$142 · 89↓
```

Yesterday's proceeds and yesterday's first-time downloads, across every app under your vendor
number. Click for the per-app breakdown, 7- and 30-day totals, and which day's report you're
actually looking at.

<!-- HERO GIF: record the menu bar with the dropdown open, save it as assets/vantage.gif,
     and uncomment the line below.
<img src="assets/vantage.gif" alt="Vantage in the menu bar, with the dropdown open" width="420">
-->

The open-source alternative to the paid menu bar sales apps: your App Store Connect key never
touches anyone's server, and you can read every line that touches it.

> [!IMPORTANT]
> **Vantage shows yesterday, not today.** Apple publishes daily sales reports the following morning,
> generally by 8 a.m. Pacific. No API reports today's sales, so no honest app can show them. Vantage
> shows yesterday accurately and names the day it's showing rather than inventing a "today" number.
> Near-real-time figures via RevenueCat are on the roadmap.

## How it works

Once a day, after Apple publishes, Vantage makes one request per missing day:

```
GET https://api.appstoreconnect.apple.com/v1/salesReports
    ?filter[frequency]=DAILY&filter[reportType]=SALES&filter[reportSubType]=SUMMARY
    &filter[vendorNumber]=…&filter[reportDate]=YYYY-MM-DD&filter[version]=1_0
Authorization: Bearer <an ES256 JWT signed locally with your .p8, valid 5 minutes>
```

The response is a gzipped tab-separated report. Vantage decompresses it in-process, parses it, and
caches that day on disk. Daily reports are immutable once published, so **a day is fetched exactly
once, ever** — and Apple deletes them after a year, which makes that cache the only copy.

Proceeds arrive in whatever currencies Apple pays you in. They're converted to your display currency
at the European Central Bank's daily reference rates, in a request that carries nothing identifying.

The only other requests are for app icons, which the App Store Connect API doesn't provide — those
go to Apple's public storefront lookup and send nothing but the numeric Apple ID of an app you
publish — and, if you open Analytics, the report files themselves, which Apple serves as pre-signed
Amazon S3 links. See [SECURITY.md](SECURITY.md) for all five hosts and what each one carries.

Your numbers are never sent anywhere. There is no server behind this app.

> [!NOTE]
> **Report days are Pacific, not local.** A daily report covers 00:00–23:59 PT, and App Store
> Connect's own dashboard defaults to UTC — which is why the same nominal day can disagree between
> the two. Vantage always renders the report's own date so there's no ambiguity about which day
> you're looking at. If you're comparing figures, switch the dashboard to PT first.

## Setup

You need three things before Vantage can show anything.

**1. An Active Paid Applications agreement.** Apple gates sales reports on it, and no API key
configuration works around that — a missing agreement comes back as an HTTP 403 that reads like a
permissions problem. Check App Store Connect › **Business** › Agreements. Only **Active** (or
*Active (Pending User)*) is in effect; *Pending User Info* means Apple is still waiting on your tax
or banking details, and *Processing* means it's under review.

**2. An API key with the Sales and Reports role.** Users and Access › Integrations › App Store
Connect API. **Don't use an Admin key** — Vantage never needs one, and this is the one decision that
determines what the key could do if it leaked. Download the `.p8` when you create it; Apple only
lets you download it once.

**3. Your Vendor Number.** App Store Connect › Payments and Financial Reports › **Reports** — top
left, under your Legal Entity Name.

Then open Settings and enter all four values: **Issuer ID**, **Key ID**, the **`.p8` file**, and the
**Vendor Number**. The Issuer ID and Key ID are both on the Integrations page — the Issuer ID at the
top, the Key ID in the column beside your key's name. Press **Test connection** to confirm before
you close the window.

Everything goes into the macOS Keychain. See [SECURITY.md](SECURITY.md) for exactly what that key
can access and where it lives.

### Reviews (optional)

Customer reviews need a **second** App Store Connect key. Apple gates them behind a different role
than sales reports, and giving the sales key a bigger role so one extra feature works would widen
what a leaked key could do — so Vantage asks for a separate key with the **App Manager** role and
stores it separately. Add it under **Settings › Reviews key**; leave it blank and Vantage behaves
exactly as it did without it.

The same key powers **Analytics** — App Store impressions, page views and the rate between them,
which no sales report contains. Apple requires an Admin key to *start* generating an analytics
report and then takes 24 to 48 hours to produce the first one; Vantage says so rather than looking
broken. See [docs/ANALYTICS_API.md](docs/ANALYTICS_API.md).

Vantage's reviews key only reads unless you explicitly switch replying on, and replying needs an
Admin key in practice — a much bigger thing to hand an app. See
[docs/REVIEWS_API.md](docs/REVIEWS_API.md) for which roles Apple grants what, and for which of those
facts Apple actually publishes.

> [!NOTE]
> **Setup is a form, not a walkthrough.** It assumes you already know what an Issuer ID is. A guided
> first-run flow is the top item on the roadmap — see [Onboarding](#onboarding-is-not-there-yet).

## Install

### Build from source

```bash
git clone https://github.com/vickipetrova/vantage.git
cd vantage
./build.sh
cp -R build/Vantage.app /Applications/
open /Applications/Vantage.app
```

Building needs only the Xcode Command Line Tools — no Xcode project, no package manager beyond
SwiftPM, no third-party dependencies.

Running the test suite needs full Xcode, because Vantage's tests use XCTest and the Command Line
Tools don't ship that framework. `./build.sh` and the app itself are unaffected.

`swift run` won't work, and that's expected: it produces a bare binary with no `Info.plist`, so
there's no `LSUIElement`, no bundle identity for login items, and no notification registration.
`./build.sh && open build/Vantage.app` is the way to run it.

### DMG

Download the latest `Vantage.dmg` from [Releases](../../releases), open it, and drag Vantage into
Applications.

## Requirements

- **macOS 13+** (Ventura). Launch at login uses `SMAppService`, which is 13.0 and later.
- **An App Store Connect account with an Active Paid Applications agreement** and at least one app.
  Free apps are fine — they report units with no proceeds, and Vantage shows the downloads.

## Settings

| Setting | What it does | Default |
|---|---|---|
| Issuer ID / Key ID / `.p8` / Vendor Number | Credentials, stored in the Keychain | — |
| Currency | What proceeds are converted to | Your region's currency |
| Notify me when a new report lands | One notification per new daily report | on |
| Launch at Login | Delegates to `SMAppService` | off |

The dropdown's **Metrics to show** submenu decides what the `↓` counts:

| Metric | Product types | Default |
|---|---|---|
| First-time downloads | `1`, `1-B`, `1E`, `1EP`, `1EU`, `1F`, `1T`, `F1`, `F1-B` | on |
| In-app purchases | `IA1`, `IA1-M`, `FI1`, `IA9`, `IA9-M` | off |
| Subscriptions | `IAY`, `IAY-M` | off |
| Re-downloads | `3`, `3F` | off |
| Updates | `7`, `7F`, `7T`, `F7` | off |
| Other / unrecognized | anything Apple adds that isn't in its own table | off |

Only first-time downloads are on by default, because that's what a `↓` means and it matches Apple's
own **App and Bundle Units** definition. App Store Connect's dashboard adds in-app purchases into
its headline Units figure, so if the two disagree by a small number, switching in-app purchases on
usually reconciles them. Toggling recomputes from the cache — nothing is refetched.

> [!IMPORTANT]
> **Notifications need a signed build.** Recent macOS refuses notification registration for ad-hoc
> signed apps, which is what `./build.sh` produces. If you built from source, no notification will
> arrive. Everything else works normally. Signed releases are not subject to this.

## Onboarding is not there yet

The v0.1 Settings window is a form with four fields. If you already have an App Store Connect API
key it takes a minute; if you don't, it assumes knowledge it shouldn't — it doesn't explain what an
Issuer ID is, or walk you through creating a Sales and Reports key.

What it should be is a proper first-run walkthrough: one step per value, with a screenshot of where
each lives in App Store Connect, an explicit "this role, not that one" step, and credential errors
that name which of the four values looks wrong rather than reporting a bare 403. **Test connection**
is the first piece of that; the rest is tracked as a
[good first issue](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22).

## Roadmap

Deliberately small for v0.1. Not planned by me, but very welcome as contributions — these are filed
as [good first issues](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22):

- **A guided setup walkthrough**, replacing the four-field form — the biggest known gap
- A RevenueCat provider for near-real-time revenue, behind the existing `SalesProvider` protocol
- A weekly digest notification
- A sparkline of the last 30 days in the dropdown
- A refunds row, separating gross sales from net
- Multiple vendor numbers in one menu
- CSV export of the cached history

Out of scope: reviews and ratings, full charting, impressions from the Analytics API, and anything
that estimates *today's* sales. See [CONTRIBUTING.md](CONTRIBUTING.md).

## Other projects in this space

There are good ones, and they solve different problems. If Vantage isn't the shape you want, one of
these probably is:

- **[Perch](https://www.perchpost.app/)** — the closest commercial equivalent, and a well-made one:
  downloads, revenue, refunds, reviews and app status in the menu bar, talking directly to App Store
  Connect from your Mac. A one-time purchase.
- **[Appstat](https://appstat.io)** — a long-running native Mac client covering sales, analytics and
  more, with considerably more depth than a menu bar title.
- **[AC Widget](https://github.com/no-comment/AppStore-Connect-Widget)** — open source and the
  nearest neighbour in spirit: iOS home-screen widgets rather than a Mac menu bar, multiple
  accounts, currency selection, and day / 7-day / 30-day views. Its successor is
  [Trendly](https://gettrendly.app).

Vantage's one distinguishing bet is that a sales app should be small enough to audit in an
afternoon.

## Uninstall

```bash
rm -rf /Applications/Vantage.app
rm -rf ~/Library/Application\ Support/Vantage
defaults delete com.vickipetrova.vantage
```

Then remove the four Keychain items: open Keychain Access, search for `com.vickipetrova.vantage`,
and delete what it finds — or use **Forget credentials** in Settings before uninstalling, which does
the same thing. Revoking the key in App Store Connect works too, and is worth doing regardless.

If you turned on Launch at Login, switch it off first (or remove Vantage from System Settings ›
General › Login Items).

## Security

Vantage stores your API key in the macOS Keychain and sends it to exactly one place:
`api.appstoreconnect.apple.com`. One other request, carrying nothing that identifies you, fetches
exchange rates from `www.ecb.europa.eu`. Both connections refuse redirects, so those two
destinations are enforced rather than merely documented. No telemetry, no analytics, no update
checks. See [SECURITY.md](SECURITY.md).

## Trademark / Not affiliated

This is an unofficial, open-source side project. **It is not affiliated with, endorsed by, or
sponsored by Apple Inc.** "App Store", "App Store Connect" and "Apple" are trademarks of Apple Inc.,
used here nominatively. The MIT license below covers this source code only and conveys no rights to
Apple's trademarks or brand.

## License

MIT © Victoria Petrova. See [LICENSE](LICENSE).
