# CLAUDE.md

Notes for Claude Code sessions working in this repo.

## Build and run

```bash
swift test                        # VantageCore — run this before anything else
./build.sh                        # -> build/Vantage.app (universal, ad-hoc signed)
./build.sh --dmg                  # also -> build/Vantage.dmg
./build.sh --dmg-only             # DMG around the existing bundle, no rebuild (release step)
open build/Vantage.app
pkill -f "MacOS/Vantage"          # stop it (menu bar app; there's no window to close)
```

There is no Xcode project. `Package.swift` defines the targets; `build.sh` runs
`swift build -c release --arch arm64 --arch x86_64`, copies the universal binary into a hand-written
`.app` bundle, writes `Info.plist`, and ad-hoc signs it.

**The app icon** is `assets/Vantage.icon` (Icon Composer), compiled by `scripts/make-icon.sh` into
`assets/AppIcon/Assets.car` (light, dark, clear, tinted on macOS 26) and `Vantage.icns` (the flat
fallback for 13–15). Both outputs are committed and `build.sh` only copies them — `actool` needs
full Xcode, and building must not. Change the `.icon`, rerun the script, commit all three.

Never run `swiftc` by hand in the repo root — it drops `.o`/`.d`/`.dia`/`.swiftdeps` files beside
`Package.swift`, and a hundred of them were once committed that way. `.gitignore` and CI both refuse
them now.

`swift test` needs full Xcode — the Command Line Tools don't ship XCTest. Building doesn't.

`swift run` produces a bare binary with no `Info.plist`, so no `LSUIElement`, no login-item identity
and no notification registration. Always test through `./build.sh && open build/Vantage.app`.

## Architecture

Two targets, one seam. **`VantageCore` imports Foundation only** — no AppKit. That's what lets
`swift test` cover every number the app displays without a window server. If a helper needs
`NSColor`, it belongs in the app target.

| File | Responsibility |
|---|---|
| `Sources/VantageCore/ReportDate.swift` | A day in Apple's Pacific reporting calendar, and the publication schedule |
| `Sources/VantageCore/SalesProvider.swift` | `DaySales`/`AppSales` models, the `SalesProvider` protocol, `SalesError`, error-body scrubbing |
| `Sources/VantageCore/ASCClient.swift` | JWT minting, the one salesReports request |
| `Sources/VantageCore/Gunzip.swift` | gzip container → raw DEFLATE, with CRC32 and ISIZE verified |
| `Sources/VantageCore/ReportParser.swift` | TSV → `DaySales` |
| `Sources/VantageCore/ReportStore.swift` | Disk cache of immutable daily summaries |
| `Sources/VantageCore/Backfill.swift` | Fetches missing days, newest first |
| `Sources/VantageCore/Schedule.swift` | When to poll, and when a report deserves a notification |
| `Sources/VantageCore/Metric.swift` | Which product types count as what |
| `Sources/VantageCore/FX.swift` | ECB rates fetch, parse, conversion, and the hard USD pegs |
| `Sources/VantageCore/KeychainStore.swift` | Credential storage — one Keychain item, and the in-memory copy |
| `Sources/VantageCore/ASCToken.swift` | The ES256 JWT, shared by both clients |
| `Sources/VantageCore/Review.swift` | Review models, and JSON:API → `CustomerReview` |
| `Sources/VantageCore/ReviewsProvider.swift` | The reviews seam, and `ReviewsError` |
| `Sources/VantageCore/ASCReviewsClient.swift` | Reads reviews. Read-only, by type |
| `Sources/VantageCore/ReviewStore.swift` | TTL cache of reviews — **not** an archive |
| `Sources/VantageCore/Prefs.swift` | UserDefaults-backed preferences |
| `Sources/VantageCore/CredentialShape.swift` | What a typed credential looks like — advisory, never blocking |
| `Sources/VantageCore/Setup.swift` | The setup steps, their copy, and the state machine over them |
| `Sources/VantageCore/SetupGate.swift` | Which window opens at launch |
| `Sources/VantageCore/MenuBarTitle.swift` | What the status item shows per style — an icon never hides an error |
| `Sources/VantageCore/Format.swift` | Currency, unit counts, dates and spans |
| `Sources/VantageCore/Money.swift` | Per-currency proceeds → one printable figure, honestly |
| `Sources/VantageCore/OverviewModel.swift` | Everything the Overview section shows, per range |
| `Sources/VantageCore/Trend.swift` | Chart series: gaps, normalization, negatives |
| `Sources/VantageCore/TimeWindow.swift` | Which days the panel shows — stepping, panning, custom ranges, clamping |
| `Sources/VantageCore/AppDetailModel.swift` | One app's slice, narrowed then handed to `OverviewModel` |
| `Sources/VantageCore/ReplyDraft.swift` | Where confirm-before-send is enforced, as a state machine |
| `Sources/VantageCore/ReplyPrompt.swift` | The words sent to the on-device model — review text only ever in the prompt |
| `Sources/VantageCore/DraftCleanup.swift` | Model output → text the composer may show, or why not |
| `Sources/VantageCore/ReplyDrafting.swift` | The `ReplyDrafter` seam, its errors, and running a draft |
| `Sources/VantageIntelligence/AppleIntelligenceDrafter.swift` | The only `import FoundationModels` (and `NaturalLanguage`) |
| `Sources/VantageCore/ASCReviewsWriter.swift` | The only type that can publish a reply |
| `Sources/VantageCore/Analytics.swift` | Analytics models, JSON:API decoding, the S3 host check |
| `Sources/VantageCore/ASCAnalyticsClient.swift` | The four-step analytics lifecycle |
| `Sources/VantageCore/SegmentParser.swift` | Gzipped TSV → `EngagementDay` |
| `Sources/VantageCore/AnalyticsStore.swift` | Merging archive, and how many instances a refresh needs |
| `Sources/VantageCore/EngagementSummary.swift` | Impressions, page views and conversion for the days on screen |
| `Sources/VantageCore/EngagementState.swift` | Why there are no engagement figures, in one note |
| `Sources/VantageCore/AppIcons.swift` | App icons from Apple's public storefront lookup |
| `Sources/VantageCore/CacheQuery.swift` | Read-only answers about the cache, for the CLI and MCP |
| `Sources/VantageCore/QueryRange.swift` | Any span of days the CLI and MCP ask for — parsed strictly, resolved against the cache |
| `Sources/VantageCore/CacheRetention.swift` | What's cached, and deleting the older part of it — only when the user asks |
| `Sources/VantageCore/NoRedirects.swift` | Refuses every redirect, on every host |
| `Sources/VantageCLI/main.swift` | `vantage-cli` — subcommands over `CacheQuery` |
| `Sources/VantageCLI/MCPServer.swift` | MCP over stdio, newline-delimited JSON-RPC |
| `Sources/Vantage/main.swift` | `AppDelegate`: provider → store → panel, rates, poll timer, wake |
| `Sources/Vantage/StatusItemController.swift` | Status item: the title, and left/right click |
| `Sources/Vantage/TowerGlyph.swift` | The menu bar tower, drawn as a template image |
| `Sources/Vantage/Panel/PanelWindow.swift` | The non-activating `NSPanel` |
| `Sources/Vantage/Panel/PanelController.swift` | Anchoring, dismissal, size animation, backdrop |
| `Sources/Vantage/Panel/PanelModel.swift` | What the panel renders; the views read only this |
| `Sources/Vantage/Panel/OverviewView.swift` | The Overview section |
| `Sources/Vantage/Panel/TrendChart.swift` | The chart, drawn with `Path` |
| `Sources/Vantage/Panel/TimeControls.swift` | 1D/7D/30D/Custom, the ‹ date › stepper, the inline custom range |
| `Sources/Vantage/Panel/ChartPanSurface.swift` | Drag and two-finger swipe on the chart, as whole days |
| `Sources/Vantage/Panel/ReviewsView.swift` | Reviews, portfolio-wide or per app |
| `Sources/Vantage/Panel/ReplyComposer.swift` | The composer and the confirmation sheet |
| `Sources/Vantage/Settings/SettingsWindow.swift` | Credentials and preferences, programmatic AppKit |
| `Sources/Vantage/Settings/PrivateKeyFile.swift` | Picking and reading a `.p8` — shared by both windows |
| `Sources/Vantage/Setup/SetupWindow.swift` | The wizard's window — titled, and it takes focus |
| `Sources/Vantage/Setup/SetupView.swift` | One step at a time |
| `Sources/Vantage/Setup/SetupModel.swift` | The wizard's Keychain writes, picker, and one real request |
| `Sources/Vantage/MainMenu.swift` | The Edit menu — without it ⌘V doesn't work anywhere |
| `Sources/Vantage/Notifier.swift` | The morning notification |
| `Sources/Vantage/LaunchAtLogin.swift` | `SMAppService` proxy |

`PanelModel` is handed `[DaySales]` and a rate table; the SwiftUI views read it and compute nothing.
No App Store Connect strings in either — that's what makes a second `SalesProvider` (RevenueCat,
eventually) one new file.

**The views are dumb on purpose.** Every figure on screen is built by a `VantageCore` type —
`Money`, `OverviewModel`, `Trend` — so `swift test` covers it. A calculation that creeps into a
`View` is a calculation nothing can test; put it in Core and pass the result in.

## Hard rules

1. **Never print, log, or commit any credential** — `.p8` contents, Issuer ID, Key ID, Vendor
   Number, or a minted JWT. `Credentials` is deliberately opaque to string interpolation. CI greps
   for it and also fails if a `.p8` or `.gz` is ever tracked.
2. **Zero third-party dependencies.** Foundation, AppKit, CryptoKit, Compression, Security,
   UserNotifications, ServiceManagement, FoundationModels, NaturalLanguage. Apple ships an OpenAPI
   SDK for this API; one endpoint does not justify it.
3. **Money is `Decimal`.** Never `Double`, not even briefly, not even for a sort key.
4. **All TSV parsing degrades gracefully.** A malformed row is skipped and counted in
   `DaySales.skippedRows`. Unknown product types count toward proceeds, never toward downloads.
5. **Five network destinations**, enforced by `NoRedirects` rather than merely documented:
   App Store Connect, the ECB, `itunes.apple.com` and `*.mzstatic.com` for app icons, and
   `*.amazonaws.com` for analytics report files. Adding a sixth means changing `SECURITY.md`, which
   states all five and what each carries.

   **`*.amazonaws.com` is the only one that isn't Apple's**, and the only one that can't be named
   exactly — Apple serves analytics segments as pre-signed S3 URLs whose bucket and region vary. It
   is fetched on a session with no additional headers at all, so no token can reach it, and the
   bytes are checksummed before parsing.

   **Two places take a URL from a response body and then fetch it**: the icon lookup's
   `artworkUrl*`, and the reviews API's `links.next`. Both are checked for `https` **and** an
   expected host before being requested — redirect refusal does nothing about a URL the code elects
   to fetch, so without those checks "four destinations" would be a description of current behaviour
   rather than a guarantee. `links.next` is the stricter of the two: it carries a bearer token, so
   it's an exact host match.
6. **`build.sh` signs ad-hoc only.** It must never handle a Developer ID or notarization
   credentials. Releasing is a manual maintainer step — see `docs/RELEASING.md`.

## The CLI

`vantage-cli` is a third target, built by `build.sh` beside the app. It exists for people at a
terminal and for AI agents over MCP (`vantage-cli mcp`).

**It must stay read-only.** It links `VantageCore` and goes through `CacheQuery`, which opens cache
files and nothing else. Do not give it Keychain access, a `URLSession`, or a write path — an agent
calls it without asking anyone, and "holds no credentials" is the whole reason that's safe. An
earlier `status` read `KeychainStore.hasReviewsKey` and hung the binary on a GUI keychain prompt,
which is what that mistake looks like when you make it.

The target is `VantageCLI` producing a product named `vantage-cli`, **not** `vantage`: macOS
filesystems are case-insensitive by default, so a `vantage` binary and the app's `Vantage` binary
are the same path and the link step collides.

**Ranges are any span of the cache**, through `QueryRange`: `--range 90d`, `--days N`, `--range all`,
`--from`/`--to`. `CacheQuery` reads every cached day, not a window. Parsing refuses anything it
doesn't recognise — it used to read an unknown range as 30 days, which answers a question nobody
asked. `CacheRetention` deletes files and must never be reachable from this target.

MCP's stdio transport is newline-delimited JSON-RPC, so **nothing may be written to stdout that
isn't a message.** A stray `print` corrupts the stream and the client drops the connection.
Diagnostics go to stderr.

## Two keys

Vantage holds a **sales key** (required, Sales and Reports role) and an optional **reviews key**
(App Manager). They are separate types, and each client is constructed with its own credentials
closure — so neither can be used for the other's work by accident.

They are **no longer separate Keychain items**. Everything lives in one item, because a Keychain ACL
is granted per item: seven items meant seven password prompts every launch, and "Always Allow" only
ever answered the item it was asked about. The separation that remains is type and wiring, not
storage — `SECURITY.md` says so in those words rather than claiming more, and anything that assumed
storage isolation needs re-reading before it is trusted.

Two things in `KeychainStore` that are load-bearing:

- **The legacy sweep runs on every load, not once.** That is what recovers a migration where the
  user dismissed some of the seven prompts: only the values actually read are deleted, and the rest
  are absorbed on a later launch. A missing Keychain item is answered without consulting an ACL, so
  once the sweep has nothing to find it prompts for nothing.
- **`Prefs.rememberCredentials` decides whether the vault is cached in memory** (default on). Off
  means read-on-demand, which is what `SECURITY.md` promised unconditionally before the setting
  existed. Switching it off must drop what is already held — `forgetCachedCredentials()` — or the
  setting appears to do nothing until the next launch.

Note that "Always Allow" cannot stick for a build from source: `build.sh` ad-hoc signs, so the
bundle's designated requirement is the **hash of the binary** and every rebuild invalidates every
grant. Signed, notarized releases keep theirs. Same root cause as the notifications gap below.

`docs/REVIEWS_API.md` is the verified reference. The short version: **App Manager can read reviews
and cannot answer them** — Apple's role matrix, its help pages and the `UserRole` enum all agree on
that. Replying is Account Holder, Admin or Customer Support, and for an API key that means Admin in
practice. **Read it before touching `ReviewDecoder` or `ASCReviewsClient`.**

That file also carries a correction worth knowing about: it previously claimed Apple's pages
*contradicted* each other on this point, and three other documents cited that as a reason to trust
it. The claim came from a summarised read that conflated the "View ratings and reviews" row with the
"Respond to customer reviews" row. **Check Apple's raw pages, not a summary of them, before writing
"Apple's docs disagree" anywhere.**

Reviews are **per app** — there is no portfolio endpoint — so a portfolio view is one request per
app. That's why they're fetched when the section is opened and never from the poll timer.

## Reply drafts

The composer's **Draft** button uses Apple's on-device model through `FoundationModels`. No network
request, no key.

- **`VantageIntelligence` is the only target that imports `FoundationModels`**, inside
  `#if canImport`, `@available(macOS 26, *)`. It's weak-linked, so 13–15 launch. `VantageCore`
  stays Foundation-only, and `VantageCLI` must never depend on `VantageIntelligence`.
- **A review is untrusted text.** It goes in the prompt, never the instructions — the model obeys
  instructions over prompts. `DraftCleanup` rejects links, emails and phone numbers as the backstop
  against a review that talks the model into advertising something.
- **The review's language is detected in code, never left to the instruction alone.**
  `AppleIntelligenceDrafter` runs `NLLanguageRecognizer` — on-device, like the model — over the
  review's title and body and appends a line naming the language ("The review is written in German.
  Write the reply in German."). It's there because "reply in the same language as the review" on its
  own came back in English for German and Japanese reviews in evaluation. The recognizer reads
  `request.languageSample`, never `instructions`, so review text still never reaches the
  instructions — and not `request.prompt` either, whose English labels made a title-only
  "とても便利" or a one-word "Bien" read as English.
- **A draft is just text in the editor.** `ReplyDraft.assist` sits beside `stage` and has no
  transition that touches it, so drafts reach the App Store by the same two steps as typing.
- **A draft can still break a rule the instructions state.** The live evaluation produced a draft
  promising a refund despite an explicit `DO NOT promise... refunds` line — the model is random, so
  no cleanup check catches every such sentence. The publish confirmation, not `DraftCleanup`, is the
  real safeguard: nothing reaches the App Store without the user reading it first.
- **Prompt changes are measured, not eyeballed.**
  `VANTAGE_LIVE_AI=1 swift test --filter LiveDraftEvalTests` runs thirteen synthetic reviews
  through the real model. CI skips it: GitHub's macOS runners are VMs and report `deviceNotEligible`.
- **Don't use the `apple.intelligence` SF Symbol.** It "may only be used to refer to Apple
  Intelligence", and whether a feature built on it qualifies is unanswered. `sparkles` it is.

## Analytics

`docs/ANALYTICS_API.md` is the reference. The short version: nothing about that API is one request —
create a report request (**Admin only**), wait 24–48 hours, list reports, list instances, list
segments, download each from a pre-signed S3 URL that expires in **five minutes**.

Three things that bite:

- **`processingDate` is not the date the data describes.** The rows carry their own `Date` column.
- **An `ONGOING` request only produces days from its own creation onwards.** Verified against the
  live API on 2026-09-17: a three-day-old request had exactly one daily instance, and the panel
  showed three days. Everything older is reachable only through a **`ONE_TIME_SNAPSHOT`** request,
  which Apple accepts alongside the ongoing one for the same app. `PanelModel.importHistory` asks
  for one per app on first refresh, imports `AnalyticsStore.historyInstanceCap` instances per
  refresh until none are left, then marks the app done and never reads it again. A snapshot takes
  the same 24–48 hours to generate, so the first answer is an empty list, and every failure here is
  silent — the daily analytics carry on unchanged.
- **Instances are kept 35 days.** `AnalyticsStore` merges rather than replaces, so older days exist
  only in Vantage's copy. Each refresh asks for as many instances as the gap since the last one
  needs (`AnalyticsStore.instancesNeeded`), capped at those 35 — a fixed count silently abandons
  every day older than the cap, which is what a hardcoded 7 did here.
- **Analytics fetches in the background**, from every `refresh(userInitiated:)` — launch, wake and
  poll timer included — and from panel-open and Refresh Now. That reverses the original
  section-open-only rule on purpose: Apple deletes instances after 35 days, so uncollected history
  is gone rather than late. `AnalyticsStore.maxAge`, not caller restraint, is what caps the cost.
- **A `stoppedDueToInactivity` request must be deleted, not written over.** Apple answers a `POST`
  over one with `409`, so the naive "filter it out and create" loops forever on
  "Apple is preparing your first report". See `AnalyticsRequestDecision`.
- **Swift treats `\r\n` as one `Character`**, so `split(separator: "\n")` never matches it.
  Normalize line endings first, as `ReportParser` does. `SegmentParser` shipped with this wrong and
  a test caught it.
- **Engagement lives on the Overview, not its own tab.** Impressions and page views are two more
  `TrendSeries` cases, and the headline's third line is `EngagementSummary`. The "no key", "Apple is
  preparing your first report" and error states are `EngagementState`, in Core, because deciding
  them in a view is what let a hard failure read as a normal wait for a month.

## The report format

`docs/REPORT_FORMAT.md` is the verified reference, written from Apple's current documentation with
sources, and it records several places where Apple's own docs contradict each other. **Read it
before touching `ReportParser`.**

The traps that cost real time here, all of which have tests:

- **Report days are Pacific.** "Yesterday" means yesterday in `America/Los_Angeles`, which for a
  European user is sometimes two local days back. App Store Connect's dashboard defaults to UTC, so
  it disagrees with the reports it's derived from.
- **A 404 is ambiguous.** Apple only generates a report when at least one unit sold, so a missing
  report means either "not published yet" or "genuinely zero". Resolved by the clock: before 10:00
  PT it's pending; after, it's cached as `.assumedZero`. **Refresh Now re-fetches `.assumedZero`
  days** within `Backfill.lateReportWindowDays` (30) — that's the escape hatch for a late report,
  and re-asking about a whole year of zeros would make one click hundreds of requests. `.observed`
  days are immutable and never re-fetched, by anything.
- **History is a setting, a year by default** (`Prefs.historyDays`), because Apple deletes daily
  reports after a year and a day never fetched is a day the CLI can never answer about. Near that
  edge a 404 may mean *deleted* rather than *zero*, so past `ReportDate.zeroTrustedWithinDays` (330)
  a 404 is left uncached instead of frozen as a zero. Nothing deletes cached days except the button
  in Settings.
- **Refunds are negative Units with positive per-unit proceeds**, so `Units × Developer Proceeds` is
  already correct. Never take an absolute value; never floor downloads at zero.
- **In-app purchases carry their own Apple Identifier** and name their app only through
  `Parent Identifier`, which holds the app's *SKU*. Grouping on Apple Identifier alone lists every
  purchase product as though it were an app while the app that earned the money reads as zero.
- **Free-app rows have a blank Currency of Proceeds.** Bucketing those under `""` puts a nameless
  currency in the menu.
- **The column is `Developer Proceeds`.** Apple's field reference calls it "Developer Proceeds (per
  unit)"; no real report does. Columns are matched by normalized name, never by position.

## Why gunzip in-process

Apple returns a gzip file, and the Compression framework's `zlib` is documented as "the raw
`DEFLATE` format" — it will not eat a gzip container. So `Gunzip` strips the 10-byte header (plus
whatever `FEXTRA`/`FNAME`/`FCOMMENT`/`FHCRC` the flag byte announces), inflates raw, and checks the
CRC32 and ISIZE trailer.

The alternative is piping through `/usr/bin/gunzip`, which is less code and puts a day of sales
figures through a subprocess's stdout, where it can land in a crash log or be read by anything
watching the process tree. Not worth the lines saved.

## Onboarding

First launch opens a wizard, not the Settings form. `SetupGate` decides between three outcomes —
credentials (normal launch), the wizard, or Settings for someone who has done this before — and
`AppDelegate` does what it says. `Prefs.setupCompleted` is written by exactly three things:
pressing Skip, reaching the last screen, and launching with credentials already in the Keychain.
That third one is the migration, and it is why an upgrading user never meets a walkthrough for
something they finished a year ago.

It is keyed on an explicit action, never on having *seen* the window. The iOS "has seen
onboarding" convention would be wrong here: closing the wizard halfway would set it, and the next
launch would show a dead menu bar icon and no prompt, in an app that can do nothing without
credentials. Abandoning the wizard must reopen it.

**Validation warns and never blocks.** `CredentialShape` catches the mistake people actually make
— a Key ID pasted into the Issuer ID field — and says so, with Continue still enabled.
`Note.isAdvisory` is `true` for every case and a test asserts it over adversarial input, because a
wizard that hard-blocks on this file's guesses about Apple's formats is an app nobody can set up
the day Apple changes one.

**Nothing reaches the Keychain until the save step**, so a wizard closed at step three leaves no
trace.

**A failed test doesn't always point back at a field.** `SalesError.likelyStep` maps a failure to
the setup step most likely at fault, for the wizard's failure screen — but not every `403`: Apple's
agreement-refusal 403 isn't fixed by remaking a key, an unsigned Paid Apps Agreement is unaffected
by the key's role, so `likelyStep` returns `nil` for it and `errorDescription` already says where
to go instead ("Sign it in App Store Connect › Business (Account Holder only)"). Sending that user
to recreate a key would revoke a working one and fail again for the same reason.
`SetupModel.canFixFromFailure` mirrors the same answer for the view: true only when the failure
names a field worth returning to, so the failure screen offers "Go back and fix it" beside "Try
again" only then — otherwise "Try again" stands alone, because `retryFromFailure()` is a
deliberate no-op with no target step.

**The panel's empty state asks the same question the launch path does.** `panelModel.onSettings`
calls `AppDelegate.openSetupOrSettings()`, which asks `SetupGate.destination` again — so someone
who never finished setup gets the wizard back, not the form. `StatusItemController.onSettings`
still opens Settings directly from a right-click: asking for Settings by name is an explicit
request, not a request for help.

Three things here that were fixed the hard way and are easy to undo:

- **⌘V needs `MainMenu.install()`.** An accessory app has no menu bar of its own, and AppKit
  dispatches keyboard shortcuts by matching main-menu items — with no Edit menu, `paste:` reaches
  nothing and the fields silently refuse to paste. Nobody types an Issuer ID by hand, in either
  window.
- **Every path out of the file picker reports something.** Cancelled, unreadable, wrong file. A
  picker that appears to do nothing is indistinguishable from a broken button. `PrivateKeyFile` is
  shared by both windows so there is one copy of those three messages.
- **The wake observer is registered exactly once, in `applicationDidFinishLaunching`, above the
  setup-gate switch.** `NSWorkspace`'s notification center doesn't deduplicate additions, and a
  version of this registered `didWake` again on every `refresh(userInitiated:)` call — the count
  doubled on every sleep/wake cycle, unbounded, by copy-paste from a launch path that already had
  one. It has to stay above the switch: two of the switch's branches return early to open a window
  instead of fetching, and a first-launch user who sets up credentials there would otherwise get no
  wake refresh for the rest of the session.

The two App Store Connect deep links in `SetupLinks` are the one part that rots without warning.
A link that 404s is worse than no link — it teaches the user the instructions are wrong — so if
either moves, delete it and let the step name the page in prose.

## The panel

`PanelWindow` is a **non-activating** `NSPanel`, not an `NSPopover`. A popover in an `LSUIElement`
app can't hold first responder for typing without `NSApp.activate(ignoringOtherApps:)`, which makes
Vantage frontmost just to read a number — unacceptable, and fatal for the review reply composer
planned in v0.2. `.nonactivatingPanel` plus `canBecomeKey` takes keyboard without activating. The
cost is that anchoring, click-outside dismissal and Esc are hand-written in `PanelController`.

**Moving through time.** The panel holds the whole cache in memory and one `TimeWindow`, shared
by Overview and App detail. Opening the panel resets it to Latest (`PanelModel.resetTime`); the
preset is remembered, the position isn't. Custom dates are an inline row, **not a popover** — a
popover is its own window, and the click-outside monitor would close the panel on the first click
into a date field. Chart panning is an AppKit overlay because SwiftUI on macOS 13 can't read a
horizontal scroll.

Two things there that were found the hard way:

- **`window.level` must not be `.popUpMenu`.** At that level the window server stops applying
  behind-window backdrop filters, so an `NSVisualEffectView` configured perfectly correctly renders
  as a flat opaque panel — every property reads right in the debugger and only the pixels are wrong.
  `.statusBar` is both correct semantically and below that threshold.
- **Round an `NSVisualEffectView` with `maskImage`, never `masksToBounds`.** Behind-window blur is
  composited outside the layer tree; a layer mask clips the view and silently discards the material.

On macOS 26 the backdrop is `NSGlassEffectView` (`.regular`) — the system glass widgets and menus
use, and nothing in the legacy material list resembles it. Below 26 it falls back to
`NSVisualEffectView`/`.popover`. **The fallback path can't be seen on a 26 machine; check it on an
older Mac before tagging.**

## Known constraint: notifications

macOS refuses notification registration for ad-hoc signed bundles — `requestAuthorization` returns
`UNErrorDomain` code 1, and the app never appears in System Settings › Notifications. `./build.sh`
produces exactly such a bundle, so **the morning notification cannot be verified from a build from
source.** Signed, notarized releases are unaffected.

The scheduling around it is still testable: it lives in `Schedule` and takes an injected `now`.

## Testing error states without real credentials

Everything except the network round trip runs offline, and the parts that don't can be exercised
without touching the Keychain. **`ASCClient.init` takes a credentials closure** — pass one that
returns a deliberately wrong `Credentials` and no real key is ever read.

For a live check, copy the repo to a scratch directory, patch the copy, and build a throwaway
bundle from it. Point `ReportStore` and `FX` at a temporary directory in the same patch so the real
cache is untouched — and note that `NSTemporaryDirectory()` is the per-user folder under
`/var/folders/…`, not `/tmp`.

- **Wrong key** — expect `!`, and a message naming Issuer ID, Key ID and `.p8`. The backfill stops
  at the first date rather than failing thirty times.
- **Rates unavailable** — patch `FX.endpoint` to a host that doesn't resolve *and* delete the cached
  `fx-rates.json`, or it will quietly serve yesterday's rates and prove nothing. Expect the largest
  single currency in its own currency, `+ n other currencies`, and no `≈`.
- **Corrupt cache** — overwrite a `~/Library/Application Support/Vantage/<date>.json` with junk.
  It should be refetched into a valid day, not reported as an error.
- **No credentials** — Settings opens by itself at launch.

**Reading the UI without screenshots no longer works.** The v0.1 recipe below queried the status
item's attached menu — but the status item has no menu attached except during a right click (see
`StatusItemController.showMenu`), so `menu bar item 1` isn't there to query, and an accessory app's
panel doesn't appear in System Events' window list either.

```bash
# v0.1 only. Returns "Can't get menu bar 0 of process Vantage" against v0.2.
osascript -e 'tell application "System Events" to tell process "Vantage" \
  to get name of every menu item of menu 1 of menu bar item 1 of menu bar (count of menu bars)'
```

So panel changes are verified by eye. Build, open, look — in both light and dark. What *is* still
automatable is everything in `VantageCore`, which is why the Overview's arithmetic lives there
rather than in the view that displays it.

## Specs and plans

**`docs/superpowers/` is not committed.** The whole directory is in `.gitignore` and the files are
kept locally. Specs and plans are working materials: imperative, dated, written against a codebase
that then moves. Merged to `main` they become furniture — plausible, specific, stale, and sitting in
a directory that looks like documentation, where the next reader, human or agent, takes them for a
description of the present.

What survives from one is **rewritten into `CLAUDE.md` or `docs/` in its own words**, next to what it
describes, where it gets updated when that changes. That's what `REPORT_FORMAT.md` and
`REVIEWS_API.md` are, and why neither reads like a plan. A design worth keeping is worth a paragraph
here; nothing in this repo should ever point at a path under `docs/superpowers/`, because for anyone
who clones it, that path doesn't exist.

Write specs and plans where the skill puts them. Don't `git add` them, and don't remove the
`.gitignore` entry to "fix" them not showing up in `git status`.

## Releasing

Bump `VERSION` in `build.sh`, add the entry to `CHANGELOG.md`, tag `vX.Y.Z`. CI fails the release if
the tag and `VERSION` disagree. See `docs/RELEASING.md` for the manual signing and notarization
steps — and use `--dmg-only` there, never `--dmg`, or the rebuild discards the signature you just
stapled on.
