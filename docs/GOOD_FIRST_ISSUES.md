# Good first issues

Drafts for the roadmap items, ready to open on GitHub once the repo is public. Each is written to be
picked up by someone who has never seen this codebase: what to build, where it goes, and how to know
it works.

Label everything here `good first issue` and `enhancement`. Delete this file once they're filed —
GitHub is where the discussion should live, not a document in the repo.

> **Updated for v0.2.** The old "sparkline in the dropdown" issue is gone: there is no dropdown any
> more, and charts shipped. The refunds issue shrank, because gross customer sales now exist. Read
> `CHANGELOG.md` before picking something up, in case it moved again.

---

## 1. Guided setup walkthrough

**Labels:** `good first issue`, `enhancement`

Settings is a form. If you already have an App Store Connect API key it takes a minute; if you
don't, it assumes knowledge it shouldn't — and v0.2 made this worse rather than better, because
there are now two keys with different roles and a consent step between them.

Replace the first run with a walkthrough:

- One value per step, each with a screenshot of where it lives in App Store Connect.
- An explicit "create the key with the **Sales and Reports** role, not Admin" step, with the reason.
- A check that the Paid Applications agreement is Active before asking for anything else — a missing
  agreement is an HTTP 403 that reads like a permissions problem and sends people to inspect the key,
  where there is nothing wrong to find.
- Credential errors that name *which* value looks wrong instead of reporting a bare status code.
- The reviews key offered **after** sales works, not beside it. Most people don't need it.

`Test connection` already exists and is the first piece of this.

**Where:** `Sources/Vantage/Settings/` — `SettingsView.swift` is SwiftUI and `SettingsModel.swift`
holds the behaviour, so a walkthrough is new views over the same model.
**Watch out for:** one unsettled fact. The role is written as "Sales and Reports" throughout this
repo, but Apple's `UserRole` enum has no such value — there is `SALES` plus a separate
`ACCESS_TO_REPORTS` permission. Check what App Store Connect's key-creation UI actually calls it
before putting it in a walkthrough, and fix the other documents if it's wrong.
**Done when:** someone who has never used the App Store Connect API can get from a fresh install to
numbers in the menu bar without leaving the app to look anything up.

---

## 2. A RevenueCat provider

**Labels:** `good first issue`, `enhancement`

Apple publishes daily reports the next morning, so Vantage is always showing yesterday. RevenueCat
reports near-real-time revenue for apps that use it, which would give a "today, so far" figure
alongside the authoritative one.

`SalesProvider` exists precisely for this — one protocol, one method, and the panel knows nothing
about where numbers come from. Add `RevenueCatProvider` beside `ASCClient`.

**Where:** new file in `Sources/VantageCore/`, conforming to `SalesProvider`.
**Watch out for:** today's figure and yesterday's report are different kinds of number. They must be
labelled differently, not silently added together — read the honesty section in the README before
designing the display. This also adds a network destination, so `SECURITY.md` has to change; see
`CONTRIBUTING.md` on what that costs.
**Done when:** both providers can be enabled at once and the panel makes clear which figure is which.

---

## 3. Weekly digest notification

**Labels:** `good first issue`, `enhancement`

The morning notification covers one day. A weekly one — "Last week: ≈ $840 · 612 downloads, ▲ 12%" —
is a different and arguably more useful rhythm.

**Where:** `Sources/VantageCore/Schedule.swift` for when it fires, `Sources/Vantage/Notifier.swift`
for the content, `Prefs` for the toggle.
**Watch out for:** the same de-duplication problem the daily one has. `Prefs.hasNotified(about:)` is
keyed on a report date; a weekly digest needs its own marker or a relaunch will re-announce it.
**Done when:** it fires once per week, survives a relaunch, and can be switched off separately from
the daily one.

---

## 4. Separate refunds out

**Labels:** `good first issue`, `enhancement`

Refunds are netted into the totals and never shown on their own — a day with 100 sales and 40
refunds looks identical to a day with 60 sales. The data is there: refund rows carry negative Units
with **positive** per-unit proceeds, and negative Customer Price.

v0.2 did half of this by adding gross customer sales, so the remaining work is a refunds figure and
somewhere to put it.

**Where:** `ReportParser` would track refunded units and amounts alongside the existing net figures;
`OverviewModel` exposes them; the headline card or the app rows show them.
**Watch out for:** don't change what the existing numbers mean. Net is what reconciles against App
Store Connect's Units column, and that's the point of it. Note also that the two sign conventions
differ — `units × proceeds` is correct for proceeds and *wrong* for customer price, which needs
`|units| × price`. `docs/REPORT_FORMAT.md` explains why, and `ReportParserTests` pins it.
**Done when:** gross, refunds and net are all visible, and net still equals what it does today.

---

## 5. Multiple vendor numbers

**Labels:** `good first issue`, `enhancement`

An account can have more than one vendor number — a legal entity change, or Apple Arcade and Apple
News content, each get their own. Today Vantage handles one.

**Where:** `KeychainStore` stores one set of values per key (four for sales, three for the optional
reviews key); it would need a set per vendor. `ReportStore` names cache files by date alone and
would need scoping, as would `ReviewStore`, `AnalyticsStore`, `AppIconStore` and `AppListingStore`.
**Watch out for:** cache filenames must not contain the vendor number — it's a credential. Use an
index or a hash, not the value. Every store validates its filename component as all-digits today;
whatever scheme replaces that needs the same treatment, and for the same reason.
**Done when:** the panel can show one vendor at a time with a switcher, or a combined total, without
either mode being able to mix two vendors' numbers into one figure.

---

## 6. CSV export

**Labels:** `good first issue`, `enhancement`

The cache is a folder of JSON files. Exporting them as a single CSV would let people put their own
history into a spreadsheet without writing a script.

`vantage-cli --json` covers the scripting case already, so this is specifically about the
double-click-into-Numbers path.

**Where:** a new file in `Sources/VantageCore/` for the encoding, plus a way to invoke it — a
`vantage-cli export` subcommand is the cheapest, and a Settings button reaches more people.
**Watch out for:** exported money must not be pre-converted, or the file inherits the ECB's coverage
gaps and its 24-hour-old rates. Export the per-currency figures as Apple reported them, and let the
spreadsheet do what it likes.
**Done when:** the CSV opens cleanly in Numbers and Excel, and the totals match the panel.

---

## 7. Verify the panel's backdrop below macOS 26

**Labels:** `good first issue`, `bug`

On macOS 26 the panel's background is `NSGlassEffectView`, the system glass. Below 26 it falls back
to an `NSVisualEffectView` with the `.popover` material — and **that path has never been seen**,
because it was written on a machine running 26.

**Where:** `PanelController.makeBackdrop`.
**Watch out for:** two specific things that were fixed the hard way on the modern path and may or
may not have equivalents on the old one. At `.popUpMenu` window level the window server drops
behind-window blur entirely, so a correctly configured effect view renders flat — the level is
`.statusBar` for that reason. And rounding an `NSVisualEffectView` with `masksToBounds` silently
discards the material, which is why it uses `maskImage`. On the fallback path the SwiftUI content is
a plain subview rather than a `contentView`, so it's worth checking whether square corners show
through the rounded ones.
**Done when:** screenshots on macOS 13 or 14, light and dark, showing the panel looks deliberate
rather than broken.
