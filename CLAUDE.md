# CLAUDE.md

Notes for Claude Code sessions working in this repo.

## Build and run

```bash
swift test                        # VantageCore — run this before anything else
./build.sh                        # -> build/Vantage.app (universal, ad-hoc signed)
./build.sh --dmg                  # also -> build/Vantage.dmg
open build/Vantage.app
pkill -f "MacOS/Vantage"          # stop it (menu bar app; there's no window to close)
```

There is no Xcode project. `Package.swift` defines the targets; `build.sh` runs
`swift build -c release --arch arm64 --arch x86_64`, copies the universal binary into a hand-written
`.app` bundle, writes `Info.plist`, and ad-hoc signs it.

## Architecture

Two targets, one seam:

| File | Responsibility |
|---|---|
| `Sources/VantageCore/ReportDate.swift` | A day in Apple's Pacific reporting calendar, and the publication schedule |
| `Sources/VantageCore/SalesProvider.swift` | `DaySales`/`AppSales` models, the `SalesProvider` protocol, `SalesError` |
| `Sources/VantageCore/ASCClient.swift` | JWT minting, the one salesReports request, gunzip |
| `Sources/VantageCore/ReportParser.swift` | TSV → `DaySales` |
| `Sources/VantageCore/ReportStore.swift` | Disk cache of immutable daily summaries |
| `Sources/VantageCore/FX.swift` | ECB rates fetch and conversion |
| `Sources/VantageCore/KeychainStore.swift` | Credential storage |
| `Sources/VantageCore/Format.swift` | Currency, unit counts, dates |
| `Sources/Vantage/main.swift` | `AppDelegate`: provider → store → menu, and the poll scheduler |
| `Sources/Vantage/MenuController.swift` | Status item: menu bar title and dropdown |
| `Sources/Vantage/SettingsWindow.swift` | Credentials and preferences, programmatic AppKit |
| `Sources/Vantage/Notifier.swift` | The morning notification |

`VantageCore` imports **Foundation only** — no AppKit. That's what makes `swift test` able to cover
every number the app displays without a window server. Keep it that way: if a formatting helper
needs `NSColor`, it belongs in the app target.

`MenuController` renders `DaySales` and nothing else. No App Store Connect strings in it — that's
what lets a second `SalesProvider` (RevenueCat, eventually) be one new file.

## Hard rules

1. **Never print, log, or commit any credential** — the `.p8` contents, Issuer ID, Key ID, Vendor
   Number, or a minted JWT. Not in debug output, not in error messages, not in a URL that gets
   logged, not in CI. `.github/workflows/build.yml` greps for this and also fails if a `.p8` or a
   `.gz` is ever tracked.
2. **Zero third-party dependencies.** Foundation, AppKit, CryptoKit, Compression, Security,
   UserNotifications, ServiceManagement. Nothing else, ever. Apple ships an OpenAPI SDK for this
   API; one endpoint does not justify it.
3. **Money is `Decimal`.** Never `Double`, not even briefly, not even for a sort key.
4. **All TSV parsing degrades gracefully.** A malformed row is skipped and counted in
   `DaySales.skippedRows`. Never crash, never throw away the day. Product type identifiers you
   don't recognize count toward proceeds and never toward downloads.
5. **Two network destinations:** `api.appstoreconnect.apple.com` and `www.ecb.europa.eu`. No
   telemetry, no analytics, no update checks.
6. **`build.sh` signs ad-hoc only.** It must never handle a Developer ID, an app-specific password,
   or notarization credentials. Releasing is a manual maintainer step — see `docs/RELEASING.md`.

## The report format

`docs/REPORT_FORMAT.md` is the verified reference: columns, product type identifiers, the Pacific
day boundary, the ambiguous 404, and refund sign conventions. **Read it before touching
`ReportParser`.** It is written from Apple's current documentation with sources, and it records
several places where Apple's own docs contradict each other.

The three facts that catch people out:

- **Report days are Pacific**, and the report has no time zone of its own. "Yesterday" means
  yesterday in `America/Los_Angeles`, which for a European user is sometimes two local days back.
- **A 404 is ambiguous.** Apple only generates a report when at least one unit sold, so a missing
  report means either "not published yet" or "genuinely zero". Resolved by the clock: before 10:00
  PT it's pending, after that it's cached as `.assumedZero` — and Refresh Now re-fetches
  `.assumedZero` days, which is the escape hatch when a report lands late. `.observed` days are
  immutable and never re-fetched.
- **Refunds are negative Units with positive per-unit proceeds.** `Units × Developer Proceeds` is
  therefore already correct. Never take an absolute value; never floor downloads at zero.

## Why gunzip in-process

Apple returns a gzip file, and the Compression framework's `zlib` is documented as "the raw
`DEFLATE` format" — it will not eat a gzip container. So `ASCClient` strips the 10-byte gzip header
(plus whatever `FEXTRA`/`FNAME`/`FCOMMENT`/`FHCRC` the flag byte announces), inflates raw, and
checks the CRC32 and ISIZE trailer.

The alternative is piping through `/usr/bin/gunzip`. That's less code and it puts a day of sales
figures through a subprocess's stdout, where it can land in a crash log or be read by anything
watching the process tree. Not worth it for the page of code saved.

## Known gap: onboarding

`SettingsWindow` is a four-field form, and it is the weakest part of v0.1. It assumes the user
already knows what an Issuer ID is and where to find it, and gives no feedback on whether the
credentials work until a fetch either succeeds or doesn't.

Planned replacement, tracked as a `good first issue` and described in the README: a step-by-step
first-run walkthrough with one value per step, a screenshot of where each lives in App Store
Connect, an explicit "Sales and Reports role, not Admin" step, and a **Test connection** button that
makes one real request and reports the result immediately. Credential errors should name the value
that looks wrong instead of the generic "App Store Connect rejected the key".

Two things that are easy to break here and were fixed the hard way:

- **⌘V needs `MainMenu.install()`.** An accessory app has no menu bar of its own, and AppKit
  dispatches keyboard shortcuts by matching main-menu items — with no Edit menu, `paste:` reaches
  nothing and the fields silently refuse to paste. Nobody types an Issuer ID by hand.
- **The `.p8` is never displayed**, only reported as present or absent, so it can't end up in a
  screenshot attached to a bug report.

## Known constraint: notifications

macOS refuses notification registration for ad-hoc signed bundles — `requestAuthorization` returns
`UNErrorDomain` code 1, "Notifications are not allowed for this application", and the app never
appears in System Settings › Notifications. **The morning notification therefore cannot be verified
from a `./build.sh` build**; the menu shows "Notifications blocked" instead. Signed, notarized
releases are not affected.

The scheduling logic around it is still testable — it's in `VantageCore` and driven by an injected
`now`, so tests can put the clock at 05:00 PT and assert what fires.

## Testing without real credentials

Everything except the network round trip runs offline:

- **`ReportParser`** is pure. Feed it the fixture TSVs in `Tests/Fixtures/` — multi-app
  multi-currency, updates and re-downloads to exclude, unknown product types, malformed rows, a
  refund day, and a zero-sales day.
- **The 404 rule** is `ReportDate.mayStillArrive(now:)`. Pass an instant, assert pending vs zero.
- **`FX`** takes a rate table; conversion, rounding and the missing-currency path need no network.

**Never commit a real report or real credentials as a fixture.** Fixtures are hand-written,
synthetic, and small enough to read. CI fails if a `.p8` or `.gz` is tracked.

## Releasing

Bump `VERSION` in `build.sh`, add the entry to `CHANGELOG.md`, tag `vX.Y.Z`. See
`docs/RELEASING.md` for the manual signing and notarization steps.
