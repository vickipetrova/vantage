# Vantage

Your App Store portfolio in the macOS menu bar:

```
$142 · 89↓
```

Yesterday's proceeds and yesterday's first-time downloads, across every app under your vendor
number.

Click it and a panel opens with the rest: proceeds beside gross sales for a day, a week or a month,
a chart of any series over 30 days, a per-app breakdown you can click into, your customer reviews
with the App Store ratings beside them, and App Store impressions and page views. Every figure names
the day it's for and says when it last arrived.

There's also **`vantage-cli`**, a read-only companion that speaks
[MCP](https://modelcontextprotocol.io) — so Claude, ChatGPT or any other agent can answer questions
about your numbers without being able to touch your account.

<!-- HERO GIF: record the menu bar with the panel open, save it as assets/vantage.gif,
     and uncomment the line below.
<img src="assets/vantage.gif" alt="Vantage in the menu bar, with the panel open" width="420">
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

The ECB publishes 30 currencies and Apple pays in around 45. Three of the gap — **AED, SAR, QAR** —
are fixed against the US dollar by their central banks, so Vantage converts those at their peg and
says it did. The rest float, and Vantage will not invent a rate for them: those amounts are listed
in their own currency rather than folded into a total that would look complete and not be.

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

With replying on, the composer can **draft a reply** using Apple Intelligence on your Mac — nothing
is sent anywhere, and it costs nothing. You get Undo and Try again, and a draft is published only
after the same confirmation as anything you type — read each one before publishing, since it can
promise something you didn't intend. Drafting needs macOS 26, Apple silicon, and Apple Intelligence
switched on; elsewhere the button isn't shown.

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

## CLI and MCP — reading your numbers from a terminal, or from an AI

`build.sh` also produces `vantage-cli`, a read-only companion to the app.

```bash
mkdir -p ~/.local/bin
cp build/vantage-cli ~/.local/bin/

~/.local/bin/vantage-cli status
~/.local/bin/vantage-cli sales --range 7d
~/.local/bin/vantage-cli sales --from 2026-01-01 --to 2026-03-31
~/.local/bin/vantage-cli apps --range all
~/.local/bin/vantage-cli apps --json | jq '.[0]'
~/.local/bin/vantage-cli reviews --limit 5
```

A range can be any span Vantage has cached: `--range 90d`, `--days N`, `--range all`, or
`--from`/`--to`. The app fetches a year of history by default (Settings › General › Data), which is
as far back as Apple keeps daily reports — and keeps everything it fetches, so the reach grows from
there. `vantage-cli status` shows the oldest day cached.

`/usr/local/bin` works too and needs `sudo`. Either way, add the directory to your `PATH` if it
isn't already, and you can drop the prefix.

### Connecting it to an AI

It speaks [MCP](https://modelcontextprotocol.io), so Claude, ChatGPT and anything else that does can
ask about your App Store numbers directly. Five tools: `get_sales`, `get_apps`, `get_reviews`,
`get_analytics`, `get_status`.

**Claude Code** — one command:

```bash
claude mcp add vantage --scope user -- ~/.local/bin/vantage-cli mcp
claude mcp list        # vantage: … - ✔ Connected
```

**Claude Desktop** — add to
`~/Library/Application Support/Claude/claude_desktop_config.json`, keeping whatever is already
there, then **quit and reopen Claude Desktop**. It reads this file at launch and won't notice a
change while running.

```json
{
  "mcpServers": {
    "vantage": {
      "command": "/Users/YOU/.local/bin/vantage-cli",
      "args": ["mcp"]
    }
  }
}
```

> [!IMPORTANT]
> **Use the full path, not just `vantage-cli`.** Apps launched from the Dock don't inherit your
> shell's `PATH`, so a bare command works when you test it in a terminal and silently fails in
> Claude Desktop — usually as a server that never connects, with nothing obvious to point at.

An MCP server is a **local process the client starts on the same Mac**. If an assistant tells you it
timed out reaching your machine, that's a different mechanism entirely — this one has no network to
fail on, and either the client spawns the binary or it doesn't.

### What it can and can't do

**It reads the cache and nothing else.** No Keychain, no network, no writes — the binary holds no
credentials and cannot obtain any. An agent pointed at it can reason about your numbers and cannot
refresh them, publish a review reply, or reach App Store Connect at all. That isn't a rule applied
at the door; it's a consequence of the only thing it can do, which is read files the app already
wrote.

The corollary is that it only knows what the app has fetched. If a figure looks stale, `status` says
how current the cache is — and the app, not the CLI, is what refreshes it.

The other corollary is worth saying plainly: **an agent you connect will read your sales figures, app
names, reviews and ratings**, and what it does with them is between you and whoever runs it. Vantage
sends nothing anywhere; a tool you point at it might.

## Requirements

- **macOS 13+** (Ventura). Launch at login uses `SMAppService`, which is 13.0 and later.
- **An App Store Connect account with an Active Paid Applications agreement** and at least one app.
  Free apps are fine — they report units with no proceeds, and Vantage shows the downloads.
- **Drafting replies (optional)** needs macOS 26 on Apple silicon with Apple Intelligence on.

## Settings

| Setting | What it does | Default |
|---|---|---|
| Issuer ID / Key ID / `.p8` / Vendor Number | Sales credentials, stored in the Keychain | — |
| Reviews & Analytics key | A second, optional key — see [Reviews](#reviews-optional) | — |
| Enable replying to reviews | Off unless you switch it on; needs an Admin key | off |
| Currency | What money is converted to | Your region's currency, if it can be converted |
| Rates for currencies with no published rate | One field per currency the ECB doesn't cover | Vantage's estimate |
| Notify me when a new report lands | One notification per new daily report | on |
| Launch at Login | Delegates to `SMAppService` | off |

The panel's **Metrics** picker, beside the app list, decides what the `↓` counts:

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

## Currencies

Apple pays in around 45 currencies. The European Central Bank publishes rates for 30. Vantage
resolves a rate in four steps, and never lets a later one override an earlier one:

1. **The ECB's daily rate**, for the 30 it publishes.
2. **A central-bank peg**, for AED, SAR and QAR. These are fixed by policy, so the number isn't an
   approximation — it's the rate.
3. **A rate you set**, under Settings › General, for anything else.
4. **Vantage's own estimate**, so money in a currency nobody prices still lands in your totals
   rather than sitting outside them. These drift, which is why they're used last and why the field
   in Settings is pre-filled with one for you to correct.

A currency with no rate at any of the four is listed in its own currency rather than folded into a
total that would look complete and not be.

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

Not planned by me, but very welcome as contributions — these are filed as
[good first issues](../../issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22):

- **A guided setup walkthrough**, replacing the credentials form — the biggest known gap
- A RevenueCat provider for near-real-time revenue, behind the existing `SalesProvider` protocol
- A weekly digest notification
- A refunds row, separating refunds out rather than only netting them
- Multiple vendor numbers in one menu bar item
- CSV export of the cached history

**Out of scope: anything that estimates *today's* sales.** No API reports them, and a number nobody
can check is worse than no number. See [CONTRIBUTING.md](CONTRIBUTING.md).

v0.2 shipped several things this list previously called out of scope — the panel itself, per-app
detail, charts, customer reviews and replies, App Store ratings, and impressions from the Analytics
API. See [CHANGELOG.md](CHANGELOG.md).

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
rm -f  /usr/local/bin/vantage-cli
rm -rf ~/Library/Application\ Support/Vantage
defaults delete com.vickipetrova.vantage
```

Then remove the Keychain items — up to seven, if you added a reviews key: open Keychain Access,
search for `com.vickipetrova.vantage`, and delete what it finds — or use **Forget credentials** in Settings before uninstalling, which does
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
