# Contributing

Thanks for looking. Vantage shows your App Store numbers in the menu bar — proceeds, sales,
downloads, reviews, ratings and impressions — and the goal is to keep it small enough that one
person can read the whole thing in an afternoon and be satisfied that it does nothing else with
their API key.

That constraint has survived a lot of features being added to it. It is the reason for most of the
rules below, and the reason a few obvious-looking conveniences aren't here.

## Building

macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

```bash
swift test          # VantageCore
./build.sh          # -> build/Vantage.app and build/vantage-cli
./build.sh --dmg    # also -> build/Vantage.dmg
open build/Vantage.app
./build/vantage-cli status
```

Building needs only the Command Line Tools. **Running the tests needs full Xcode** — the tests use
XCTest and the Command Line Tools don't ship that framework. If `swift test` can't find XCTest,
that's why, and it isn't a problem with your checkout.

`swift run` won't work: it produces a bare binary with no `Info.plist`, so no `LSUIElement`, no
login-item identity and no notification registration. Always test through `./build.sh`.

Build from the latest `main` so you're not fixing something that already changed.

## What's welcome

Bug fixes. Compatibility fixes across macOS versions and architectures. Anything on the
[Roadmap](README.md#roadmap) — those are filed as `good first issue` and are genuinely up for grabs,
especially a second `SalesProvider`.

Report-format corrections are the most valuable contribution here. If Vantage's numbers disagree
with what App Store Connect shows you, that is a bug worth reporting even if you can't fix it —
say what disagreed and by how much, and **redact your actual figures if you'd rather not publish
them**; the shape of the discrepancy is usually enough.

## What won't be merged

- **New dependencies.** Foundation, AppKit, CryptoKit, Compression, Security, UserNotifications,
  ServiceManagement. The zero-dependency build is a feature, not an accident — including Apple's own
  App Store Connect OpenAPI SDK, which is a lot of generated surface for one endpoint.
- **Anything that logs, caches to disk, or transmits a credential.** See below.
- **A sixth network destination.** `SECURITY.md` names all five and what each one carries; every
  session refuses redirects, and the two places a *response body* chooses the next URL check its
  host as well as its scheme. A new destination means changing a document users read to decide
  whether to trust this app, so it needs a reason worth writing down — not a convenience.
- **Telemetry of any kind.** No analytics, no crash reporting, no update checks, no phone-home. The
  "App Store Analytics" section reads *your* numbers from Apple; it is not the other direction.
- **`Double` anywhere near money.**
- **An Xcode project.** It would make `build.sh` a lie.
- **Estimated or extrapolated "today" figures.** Apple doesn't publish today's sales. Guessing at
  them and presenting the guess as a number is the exact thing this app exists not to do.

## Ground rules for code

1. **Never print, log, or commit a credential** — `.p8` contents, Issuer ID, Key ID, Vendor Number,
   or a minted JWT. CI greps for it, but the grep is a backstop, not the rule.
2. **Parse defensively.** A malformed row is skipped and counted, never fatal. An unrecognized
   product type identifier counts toward proceeds and never toward downloads. Apple's own table is
   incomplete and internally inconsistent — see `docs/REPORT_FORMAT.md`.
3. **Money is `Decimal`**, from the TSV all the way to the formatter.
4. **Keep `VantageCore` free of AppKit.** It's what lets `swift test` cover every number the app
   shows.
5. **Keep the panel provider-agnostic.** `PanelModel` is handed `[DaySales]` and a rate table.
   App Store Connect specifics belong in `ASCClient` and its siblings — that separation is what
   would make a second `SalesProvider` one new file.
6. **SwiftUI views compute nothing.** Every figure on screen is built by a `VantageCore` type —
   `Money`, `OverviewModel`, `Trend`, `Freshness` — so `swift test` covers it. A calculation that
   creeps into a `View` is a calculation nothing can test, and this app has already shipped two
   silent wrong numbers that lived in views.
7. **macOS 13.0 is the floor**, and the compiler enforces it. Check any API you're unsure of against
   the SDK's own `.swiftinterface` rather than from memory; `CLAUDE.md` lists what's been ruled out.
8. **`vantage-cli` stays read-only.** It goes through `CacheQuery`, which opens cache files and
   nothing else. No Keychain, no `URLSession`, no writes — an AI agent calls it without asking
   anyone, and holding no credentials is the entire reason that's safe.
9. **Match the surrounding style.** Comments explain *why*, not *what*.
10. **Fixtures are synthetic.** Hand-written, small enough to read, derived from Apple's documented
   format — never from a real report, even redacted. But *do* check new parsing against a real one
   locally before opening the PR: every parser bug found so far was invisible to fixtures that were
   tidier than reality.

`CLAUDE.md` has the architecture map; `docs/REPORT_FORMAT.md` has the verified report reference with
sources. Both are useful whether or not you use Claude Code.

## Testing

Run `swift test`, and then run the app. "Builds clean" isn't testing.

**Anything that parses or computes needs a test** — `ReportParser`, `SegmentParser`, the API
decoders, `Money`, `OverviewModel`, `Trend`, `FX`, `Format`. That's the whole point of `VantageCore`
importing nothing but Foundation. Fixtures live in `Tests/Fixtures/`
and are **synthetic** — hand-written, small enough to read, and derived from Apple's documented
format rather than from anyone's real report. **Never commit a real report or real credentials**,
even redacted; CI fails if a `.p8` or `.gz` is tracked.

Review fixtures use **invented** reviewer nicknames and text. Real ones are other people's data and
this repository is public; there's no CI check for it, so this is on review.

For anything visual, attach screenshots of the menu bar title and the open panel **in both light and
dark mode**, and say which macOS version and which Mac. The panel's backdrop takes a different code
path below macOS 26, and that path can't be seen on a machine running it.

## Pull requests

One change per PR. If you're planning something large, open an issue first — I'd rather talk about
the shape before you spend a weekend on it.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/): `feat`, `fix`, `docs`, `chore`,
`refactor`, `perf`. Branches: `type/kebab-case-description`.

## Conduct

Be decent. Critique code, not people; assume the other person is trying to help. That's the whole
policy.

## License

MIT. By contributing you agree your contributions are licensed under it.
