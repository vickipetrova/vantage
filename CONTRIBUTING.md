# Contributing

Thanks for looking. Vantage does one thing — show yesterday's App Store proceeds and downloads in
the menu bar — and the goal is to keep it small enough that one person can read the whole thing in
an afternoon and be satisfied that it does nothing else with their API key.

## Building

macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). Nothing else.

```bash
swift test          # VantageCore
./build.sh          # -> build/Vantage.app
./build.sh --dmg    # also -> build/Vantage.dmg
open build/Vantage.app
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
- **A third network destination.** No analytics, no telemetry, no update checks, no crash reporting.
  The two we have refuse redirects; keep it that way.
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
5. **Keep `MenuController` provider-agnostic.** It renders `DaySales`. App Store Connect specifics
   belong in `ASCClient`.
6. **Match the surrounding style.** Comments explain *why*, not *what*.
7. **Fixtures are synthetic.** Hand-written, small enough to read, derived from Apple's documented
   format — never from a real report, even redacted. But *do* check new parsing against a real one
   locally before opening the PR: every parser bug found so far was invisible to fixtures that were
   tidier than reality.

`CLAUDE.md` has the architecture map; `docs/REPORT_FORMAT.md` has the verified report reference with
sources. Both are useful whether or not you use Claude Code.

## Testing

Run `swift test`, and then run the app. "Builds clean" isn't testing.

Anything touching `ReportParser`, `FX` or `Format` needs a test. Fixtures live in `Tests/Fixtures/`
and are **synthetic** — hand-written, small enough to read, and derived from Apple's documented
format rather than from anyone's real report. **Never commit a real report or real credentials**,
even redacted; CI fails if a `.p8` or `.gz` is tracked.

For anything visual, attach a screenshot of the menu bar title and the open dropdown, and say which
macOS version and which Mac.

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
