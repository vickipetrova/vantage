# Good first issues

Drafts for the roadmap items, ready to open on GitHub once the repo is public. Each is written to be
picked up by someone who has never seen this codebase: what to build, where it goes, and how to know
it works.

Label everything here `good first issue` and `enhancement`. Delete this file once they're filed —
GitHub is where the discussion should live, not a document in the repo.

---

## 1. Guided setup walkthrough

**Labels:** `good first issue`, `enhancement`

Settings is four fields and a Save button. If you already have an App Store Connect API key it takes
a minute; if you don't, it assumes knowledge it shouldn't.

Replace it with a first-run walkthrough:

- One value per step, each with a screenshot of where it lives in App Store Connect.
- An explicit "create the key with the **Sales and Reports** role, not Admin" step, with the reason.
- A check that the Paid Applications agreement is Active before asking for anything else — a missing
  agreement is an HTTP 403 that reads like a permissions problem and sends people to inspect the key,
  where there is nothing wrong to find.
- Credential errors that name *which* of the four values looks wrong instead of reporting a bare
  status code.

`Test connection` already exists in `SettingsWindow` and is the first piece of this.

**Where:** `Sources/Vantage/SettingsWindow.swift`, probably split into a new file per step.
**Done when:** someone who has never used the App Store Connect API can get from a fresh install to
numbers in the menu bar without leaving the app to look anything up.

---

## 2. A RevenueCat provider

**Labels:** `good first issue`, `enhancement`

Apple publishes daily reports the next morning, so Vantage is always showing yesterday. RevenueCat
reports near-real-time revenue for apps that use it, which would give a "today, so far" figure
alongside the authoritative one.

`SalesProvider` exists precisely for this — one protocol, one method, and `MenuController` knows
nothing about where numbers come from. Add `RevenueCatProvider` beside `ASCClient`.

**Where:** new file in `Sources/VantageCore/`, conforming to `SalesProvider`.
**Watch out for:** today's figure and yesterday's report are different kinds of number. They must be
labelled differently in the menu, not silently added together. Read the honesty section in the
README before designing the display.
**Done when:** both providers can be enabled at once and the menu makes clear which figure is which.

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

## 4. Sparkline in the dropdown

**Labels:** `good first issue`, `enhancement`

Thirty days of history are already cached. A 30-day sparkline above the per-app rows would show
shape — a launch spike, a slow decline — that a pair of totals can't.

**Where:** `Sources/Vantage/MenuController.swift`. Menu items can host custom `NSView`s, which is
also how you avoid macOS drawing informational rows dimmed.
**Watch out for:** it has to honour the selected metrics and the display currency like everything
else, and it must handle a negative day (refunds) without inverting the chart.
**Done when:** it renders from the cache with no extra requests, in light and dark mode.

---

## 5. A refunds row

**Labels:** `good first issue`, `enhancement`

Refunds are currently netted into the totals and never shown separately — a day with 100 sales and
40 refunds looks identical to a day with 60 sales. The data is already there: refund rows carry
negative Units with positive per-unit proceeds.

**Where:** `ReportParser` would need to track gross and refunded separately, alongside the existing
net figures; `MenuController` gets a row.
**Watch out for:** don't change what the existing numbers mean. Net is what reconciles against App
Store Connect's Units column, and that's the point of it.
**Done when:** the dropdown shows gross, refunds and net, and net still equals what it does today.

---

## 6. Multiple vendor numbers

**Labels:** `good first issue`, `enhancement`

An account can have more than one vendor number — a legal entity change, or Apple Arcade and Apple
News content, each get their own. Today Vantage handles one.

**Where:** `KeychainStore` currently stores one set of four values; it would need a set per vendor.
`ReportStore` names cache files by date alone and would need scoping.
**Watch out for:** cache filenames must not contain the vendor number — it's a credential. Use an
index or a hash, not the value.
**Done when:** the menu can show one vendor at a time with a switcher, or a combined total, without
either mode being able to mix two vendors' numbers into one figure.

---

## 7. CSV export

**Labels:** `good first issue`, `enhancement`

The cache is 30 JSON files. Exporting them as a single CSV would let people put their own history
into a spreadsheet without writing a script.

**Where:** a new file in `Sources/VantageCore/` for the encoding, a menu item to invoke it.
**Watch out for:** exported money must not be pre-converted, or the file inherits the ECB's coverage
gaps and its 24-hour-old rates. Export the per-currency figures as Apple reported them.
**Done when:** the CSV opens cleanly in Numbers and Excel, and the totals match the menu.
