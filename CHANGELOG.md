# Changelog

All notable changes to Vantage are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.2.0] — 2026-08-21

Vantage's dropdown is gone. The status item now opens a floating panel: an `NSMenu` row can't hold a
chart, can't take a text field and can't navigate, which made it the ceiling for everything below.

### Added

- **A floating panel** behind the status item, with a slim icon rail for sections. Left click opens
  it; right click keeps Refresh, Settings and Quit.
- **A range control** — yesterday, 7 days, 30 days — governing the headline figure, the comparison
  and the app rows. Remembered between launches.
- **A chart** of any single series over 30 days, with the selected range shaded. A day Vantage never
  fetched is drawn as a gap rather than a zero, the range always includes zero, and refund days keep
  their sign.
- **App detail**, reached by clicking an app row: that app's figures, its own chart, and its reviews.
- **App icons** beside each row, from Apple's public storefront lookup.
- **Customer reviews**, behind an optional second App Store Connect key with the App Manager role —
  the sales key stays on its minimal role. Filter by rating and by unanswered.
- **Replying to reviews**, off by default and behind an explicit consent step, because replying
  needs an Admin key in practice. Nothing is published without confirming the exact text; replacing
  an existing reply shows what will be overwritten, since Apple's endpoint is create-or-update and
  will never tell you.
- **Analytics** — App Store impressions, page views and the rate between them, which no sales report
  contains.
- **Settings**, rebuilt as three tabs of grouped forms with per-field state, instead of one 860pt
  column.

### Changed

- The menu bar title is unchanged, deliberately.
- Per-app rows are no longer capped at eight, and are ranked by converted proceeds — or by units when
  no rate table makes them comparable.
- The panel reads 60 days from disk while still fetching 30, so month-over-month comparison works.

### Fixed

- Range totals were selected by position in the cache rather than by date, so a gap made "Last 7
  days" reach back past the range and total days its own heading didn't cover.
- Proceeds in a currency the ECB doesn't publish rendered as a converted `≈ $0.00` when a rate table
  existed but didn't apply to any of them.
- Comparisons measured raw totals across windows of different cached lengths, so eight flat days
  read as a 600% rise.
- `Fmt.wrap` and the eight-row cap are gone with the menu that needed them.

### Security

- The network surface is now **five hosts**, all named in `SECURITY.md`. Two were added for app
  icons and one for analytics report files — the last is a pre-signed Amazon S3 URL, the only
  destination that isn't Apple's, fetched on a session that carries no credential and verified
  against Apple's checksum before parsing.
- Both places where a response body chooses the next URL — the artwork link and the reviews
  `links.next` — are checked for host as well as scheme. Refusing redirects does nothing about a URL
  the code elects to fetch.
- Apple IDs and resource IDs that become filenames or URL path components are **validated, not
  sanitized**. Stripping non-digits defeats a traversal while silently addressing a different real
  app.
- `docs/REVIEWS_API.md` previously claimed Apple's own documentation pages contradicted each other
  about who may reply to a review. They don't; the correction is recorded in that file.

First release, not yet tagged.

### Added

- **Menu bar title** — `$142 · 89↓`: yesterday's proceeds converted to your display currency, and
  yesterday's first-time downloads. Monospaced digits so the title doesn't shuffle as numbers
  change. The `≈` lives in the dropdown, not the title.
- **Dropdown** with yesterday's totals against the trailing 7-day average, a per-app breakdown
  sorted by proceeds, 7- and 30-day windows, and a freshness line naming the report's own date.
- **Authentication with no dependencies.** ES256 JWTs are minted and signed locally with CryptoKit
  from your `.p8`. Tokens live five minutes against Apple's twenty-minute ceiling and carry a
  `scope` claim naming the single request they were minted for.
- **Metrics to show** — the `↓` counts first-time downloads by default, with in-app purchases,
  subscriptions, re-downloads, updates and an "other" bucket toggleable. App Store Connect's own
  dashboard folds in-app purchases into its headline Units figure, so switching that on reconciles
  the two. Toggling recomputes from the cache; nothing is refetched.
- **Immutable daily cache.** One JSON file per report date in
  `~/Library/Application Support/Vantage/`. A published day is fetched exactly once, ever — which
  matters because Apple deletes daily reports after a year, making the cache the only copy.
- **Currency conversion** at the European Central Bank's daily reference rates, cached for 24 hours.
  Currencies the ECB doesn't publish are shown as an unconverted remainder rather than dropped from
  a total. Every converted figure is marked `≈`.
- **Morning notification** when a new daily report lands — once per report, never for a day Apple
  never published.
- **A scheduler that mostly sleeps.** Apple publishes by 8 a.m. Pacific, so Vantage polls hourly
  from 05:00 PT until the report lands and then does nothing until the next morning. It also
  refreshes on wake, since timers are unreliable across sleep.
- **Settings** — credentials with a per-field indicator of what the Keychain actually holds, display
  currency, notification and launch-at-login toggles, **Test connection**, and Forget credentials.
- **Honest failure states.** Every error names what happened and, where Apple's own text is useful,
  quotes it — with your vendor number redacted out of it first.
- `./build.sh` produces a universal (arm64 + x86_64) ad-hoc signed bundle with no Xcode project and
  no third-party dependencies; `--dmg` packages an installer image and `--dmg-only` repackages an
  already-signed one.
- **Tests.** `swift test` covers report parsing against synthetic fixtures, the Pacific report
  calendar including daylight-saving boundaries, gzip decoding against files from the system `gzip`,
  JWT construction, currency conversion, the cache, the backfill, the scheduler and error text.

### Fixed

Found by running against a real report and a real account, before first release:

- **In-app purchases were listed as separate apps.** An IAP row carries its *own* Apple Identifier
  and names its app only through `Parent Identifier`, which holds the app's SKU — so grouping on
  Apple Identifier put purchase products where apps should be, and the app that actually earned the
  money showed nothing. The synthetic fixtures had been too tidy to catch it: they gave in-app
  purchases the parent app's ID, which no real report does.
- **The per-app breakdown didn't sum to its own total.** Rows counted first-time downloads while the
  day above them counted whichever metrics were switched on, so enabling in-app purchases showed 9
  downloads over rows adding to 3.
- **A missing rate table rendered real revenue as `≈ $0.00`.** With the ECB unreachable and no
  cached rates, the largest currency was reported as an unconverted remainder, the converted total
  as zero, and every other currency was dropped silently — making a day that earned money
  indistinguishable from a day that earned none. It now shows the largest single currency in its own
  currency plus a count of the others, and no `≈`, because nothing was converted.
- **A wrong key took a minute to report itself.** Every one of the thirty backfill dates failed
  identically while the menu said "Loading…". Credential failures now stop the run at the first
  date; rate limits and network blips deliberately don't, since those are temporary and the days
  already fetched are worth keeping.
- **Apple's 401 text was shown verbatim** — boilerplate that names none of the four values the user
  has to check, trailing a URL that hit the length cap mid-path and read as a broken string. 401 now
  names Issuer ID, Key ID and `.p8`; trailing "Learn more…" clauses and bare URLs are stripped from
  any error text that is shown.
- **A 403 caused by an unsigned Paid Applications agreement was reported as a key-role problem.**
  The client had been discarding Apple's error body and rendering a guess. Surfacing Apple's own
  `detail` is what made it diagnosable; the agreement case now also says where to go.
- **⌘V didn't work in the credential fields.** An accessory app installs no menu bar, and AppKit
  dispatches shortcuts by matching main-menu items — with no Edit menu, `paste:` reached nothing.
  Nobody types an Issuer ID by hand.
- **Saving three of four credentials looked like a total failure.** The status line was replaced
  with the first missing value in red, which reads as "nothing saved" when the `.p8` had stored
  fine. Each credential now carries its own indicator sourced from the Keychain.
- **The file picker could fail silently.** A cancelled pick, an unreadable file, and a wrong file
  all returned without a word. A picker that appears to do nothing is indistinguishable from a
  broken button.
- **One long error stretched the dropdown across the screen.** `NSMenu` sizes to its widest item and
  never wraps; Apple's error strings are sentences.
- **Days cached before the per-product-type tally existed counted as zero**, flattening a month of
  history into a line. They now fall back to their recorded install count.
- **The bearer token could have followed a redirect to another host.** Both connections now refuse
  redirects outright, so "two network destinations" is enforced rather than merely documented.
- **The documented release procedure discarded its own notarization**, rebuilding the app after
  signing and stapling and wrapping an ad-hoc signed bundle in a notarized image. `build.sh` gained
  `--dmg-only` for that step.
- **A failed ad-hoc signature was swallowed** by `build.sh`, which on Apple Silicon produces an app
  that dies at launch with the real error discarded.
- Tagging a release no longer skips the test suite, and a tag that disagrees with the version in
  `build.sh` now fails the release build instead of shipping a mislabeled app.

### Known limitations

- **Notifications require a signed build.** macOS refuses notification registration for the ad-hoc
  signed bundle `./build.sh` produces. Everything else works normally.
- **Setup is a form, not a walkthrough.** It assumes you already know what an Issuer ID is. A guided
  first-run flow is the top roadmap item.
- **Yesterday, not today.** Apple publishes daily reports the next morning and offers no API for
  today's sales. This is a property of the data source, not a limitation Vantage can engineer away.
- **The ECB publishes about 29 currencies**, on TARGET working days only. Apple pays in more than
  that, and anything outside the list is shown unconverted.
- **`swift test` needs full Xcode**, because the tests use XCTest and the Command Line Tools don't
  ship that framework. Building the app doesn't.
