# Security

Vantage asks you for an App Store Connect API key. That is a real credential, and handing one to a
menu bar app off the internet is a reasonable thing to be nervous about. This document is the whole
story of what happens to it, so you can check the claims against the source.

## What the keys can do

An App Store Connect API key's power comes from the **role** you give it when you create it, not
from the app that holds it.

Vantage can hold **two keys, stored separately**, and neither is ever used for the other's work:

| Key | Required? | Role | What it's for |
|---|---|---|---|
| Sales | Yes | **Sales and Reports** | Downloading your daily sales reports |
| Reviews | No | **App Manager** | Reading customer reviews |

**Create the sales key with the Sales and Reports role. Nothing else.**

Such a key can download sales reports for your vendor number. It cannot see your bank details or
tax forms, cannot change app metadata, cannot submit or remove a build, cannot manage users, and
cannot touch pricing or availability.

An **Admin** key can do all of those. Vantage would never use those abilities and asks you not to
create one — if you already have an Admin key lying around, don't reuse it here. Make a second key
with the Sales and Reports role and give Vantage that one.

### Why reviews need a second key

Apple gates customer reviews behind a different role than sales reports, and no single role covers
both without being far more powerful than either needs. Giving the sales key a bigger role so that
one extra feature works would widen what a leaked key could do with your account — so Vantage asks
for a second key instead, and stores it as its own Keychain items.

**The reviews key is optional.** Leave it blank and Vantage does exactly what v0.1 did; the Reviews
section says so and offers nothing else. Removing it later (**Settings › Remove reviews key**)
deletes the cached review text along with it, and leaves sales working.

Vantage's reviews key **only reads**. It never publishes, edits or deletes a reply — the API can do
all three, and a later version may, but that will be off by default and behind its own explicit
consent step, because replying requires an Admin key in practice. See `docs/REVIEWS_API.md`, which
records the contradiction between two of Apple's own documentation pages on this point.

Keys are revocable. If you ever want Vantage to stop having access, revoke the key in App Store
Connect (Users and Access › Integrations) — that works whether or not you still have the app
installed, and it does not affect your other keys.

## Where they're stored

Four values for the sales key, entered once in Settings: Issuer ID, Key ID, the contents of the
`.p8` private key file, and your Vendor Number. Three more if you add a reviews key: Issuer ID,
Key ID and its own `.p8`. There is no vendor number for reviews — those endpoints don't take one.

All of them go into the **macOS Keychain**, under the service `com.vickipetrova.vantage`, through
`Security.framework` in-process (`SecItemAdd` / `SecItemCopyMatching`) — not by shelling out to
`/usr/bin/security`, so no credential ever crosses a pipe or lands in a subprocess's output.

The `.p8` file you picked is read once, at the moment you choose it, and is not copied anywhere.
Vantage does not keep the file path, does not re-read the file later, and does not need the file to
exist afterward — you can move it back to your password manager and delete the download.

Nothing else stores credentials. Not `UserDefaults`, not the on-disk report cache, not a log file,
not a crash report, not an error message shown in the panel. **Settings › Forget credentials**
removes every value from the Keychain, both keys; **Remove reviews key** removes only the second.

## Where it goes

Four hosts. That is the entire network surface of this application.

```
GET https://api.appstoreconnect.apple.com/v1/salesReports          (your reports)
GET https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml  (currency rates)
GET https://api.appstoreconnect.apple.com/v1/apps/…/customerReviews (reviews, if you added a key)
GET https://itunes.apple.com/lookup?id=…&entity=software           (app icons)
GET https://*.mzstatic.com/…                                       (the icon image itself)
```

The first two carry the app's whole purpose. The last two exist only to draw an app's icon beside
its row, and they were added in v0.2 — v0.1 really did talk to two hosts and nothing else.

**Why a third and fourth host for something so small:** the App Store Connect API has no icon. There
is no artwork field on `/v1/apps/{id}`, and no endpoint that returns one. The public storefront
lookup is the only source, and it answers on `itunes.apple.com` with a URL pointing at
`*.mzstatic.com`.

**What those two requests reveal:** the numeric Apple ID of an app you publish, to Apple,
unauthenticated. No token, no vendor number, no app names, no sales figures, no cookies. It is byte
for byte the request the App Store website makes when anyone anywhere looks at your app's page, and
it carries nothing that identifies you as the caller. Icons are cached on disk after the first fetch,
so it happens once per app rather than once per refresh.

Every connection **refuses redirects outright**. Without that, a 302 from any of them could send the
next request — and, for App Store Connect, your bearer token with it — somewhere this document
doesn't mention. Refusing redirects is what makes "four destinations" something the code enforces
rather than a description of how it currently happens to behave.

The icon lookup is the only place where a response body chooses the next URL Vantage fetches, so
that URL must be `https` before it is requested at all, and a redirect from it fails the icon rather
than being followed. A missing icon is a blank tile; it is never a reason to follow a stranger.

The App Store Connect request carries a freshly minted ES256 JWT, signed locally with your private
key. Apple rejects tokens for this endpoint that live longer than 20 minutes; Vantage issues them
for **five**. Each token also carries a `scope` claim naming the single request it was minted for,
so a token that somehow escaped could fetch one sales report for one date and nothing else. Tokens
are held in memory for the request and dropped — never written to disk.

The ECB request carries nothing. No token, no identifier, no app names, no numbers — it is a
request for a public XML file of exchange rates, identical for every user in the world.

There is no telemetry, no analytics, no crash reporting, no update check, and no third-party
service of any kind — the icon lookup is Apple's own public storefront API, not a service operated
by anyone else. There is no server operated by this project. **Your sales figures are never
sent anywhere** — they travel from Apple to your Mac and stop there.

## What it stores on disk

`~/Library/Application Support/Vantage/` holds one JSON file per day: the parsed totals for that
date. Daily reports are immutable once published, so a cached day is never re-fetched. Alongside it,
`icons/` holds one image per app — public store artwork, nothing derived from your account — and
`reviews/` holds one file per app of the review text shown in the panel. Removing the reviews key
deletes `reviews/`.

Those files contain your own sales numbers — app names, unit counts and proceeds. They're readable
by anything running as your user, exactly like any other app's Application Support folder. They
contain no credentials. Delete the folder any time; Vantage will refetch what it can (Apple keeps
daily reports for one year).

`UserDefaults` (`com.vickipetrova.vantage`) holds preferences only: display currency, notification
toggle, and a marker for which day was last notified about.

## Reading this yourself

The parts worth auditing, in the order they matter:

| File | What to check |
|---|---|
| `Sources/VantageCore/KeychainStore.swift` | Every read and write of a credential |
| `Sources/VantageCore/ASCClient.swift` | JWT construction, the one request, and that the key is used and dropped |
| `Sources/VantageCore/FX.swift` | The ECB request carries no identifying data |
| `Sources/VantageCore/NoRedirects.swift` | Nine lines, and the reason "four destinations" is enforceable |
| `Sources/VantageCore/AppIcons.swift` | The two unauthenticated requests, and that they carry no credential |
| `Sources/VantageCore/ASCToken.swift` | One JWT implementation for both keys, and the `scope` claim that limits each token to one request |
| `Sources/VantageCore/ASCReviewsClient.swift` | That the reviews key is read-only and never used for sales |

Two habits in the source worth knowing about, because they're the kind of thing that gets undone by
accident:

- **`Credentials` is opaque to string interpolation.** Its `description` and `debugDescription` both
  return `Credentials(redacted)`, so writing it into a log line produces nothing useful rather than
  everything.
- **Apple's error text is scrubbed before it reaches the menu.** Error bodies are rendered to
  explain failures, and Apple quotes request parameters back — one of which is your vendor number.
  It's replaced with `<vendor number>` before the string can escape, and anything in the menu can
  end up in a screenshot attached to an issue.

CI fails the build if anything in `Sources/` prints or logs a credential, and fails if a `.p8` or a
compressed report is ever tracked in git. Those checks are backstops for mistakes, not the reason
the guarantees hold — the reason is that nothing in the source does it.

## Reporting a problem

For anything non-sensitive, [open an issue](../../issues). For a vulnerability, use GitHub's private
vulnerability reporting on this repository (Security › Report a vulnerability).

**Never include your `.p8` contents, your Issuer ID, your Key ID, or a screenshot showing them.** If
you think a key has been exposed, revoke it in App Store Connect immediately and create a new one —
revocation is instant and free.

## Scope note

Vantage is unofficial and not affiliated with Apple. It reads a documented, public API with a
read-only key you control and can revoke. It cannot spend money, change anything in your App Store
Connect account, or affect your apps.

It is also a side project maintained by one person, audited by whoever reads the source. Keeping it
small enough to read in an afternoon is the security model.
