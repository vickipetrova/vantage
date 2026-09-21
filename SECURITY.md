# Security

Vantage asks you for an App Store Connect API key. That is a real credential, and handing one to a
menu bar app off the internet is a reasonable thing to be nervous about. This document is the whole
story of what happens to it, so you can check the claims against the source.

## What the keys can do

An App Store Connect API key's power comes from the **role** you give it when you create it, not
from the app that holds it.

Vantage can hold **two keys**, and neither is ever used for the other's work:

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
for a second key instead.

The two keys are kept apart by *type and wiring* rather than by storage: `credentials()` and
`reviewsKey()` return different types built from disjoint fields, and each client is constructed
with a closure that reads only its own. Until recently they also lived in separate Keychain items,
and this document said so — that is no longer true, and the reason is below.

**The reviews key is optional.** Leave it blank and Vantage does exactly what v0.1 did; the Reviews
section says so and offers nothing else. Removing it later (**Settings › Remove reviews key**)
deletes the cached review text along with it, and leaves sales working.

**Replying is off by default and stays off until you switch it on.** Left alone, the reviews key
only ever reads: the type that can publish (`ASCReviewsWriter`) is not constructed at all unless
you've enabled replies *and* a key exists, so there is no code path that could publish by accident.

If you do switch it on, two things are true and stated in Settings before you do:

- **It needs an Admin key**, not the App Manager key reading requires. An Admin key can change
  pricing, submit and remove builds, manage users and read your financial reports. Vantage would use
  it for one thing, but that isn't the same as it being unable to do the rest.
- **Nothing is ever published without you confirming the exact text first.** That isn't a dialog
  somebody could skip — the draft type has no transition from "editing" to "sending", so publishing
  without a confirmation is not something the code can express. Replacing an existing reply shows
  what will be overwritten, because Apple's endpoint is create-or-update with no distinction and
  will never tell you.

See `docs/REVIEWS_API.md` for who may reply at all, and for which of these facts Apple actually
publishes versus which are community-tested.

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

### One item, and what that costs

They are stored as **one Keychain item**, holding a small JSON object, rather than one item per
value.

A Keychain ACL is granted **per item**. macOS asks once per item, and "Always Allow" adds the app to
that one item's trusted list and no other. Seven items therefore meant seven password prompts at
every launch, and answering all seven only ever answered the seven it had asked about. One item is
one question.

The honest cost: **the two keys are no longer separated in storage.** A read returns the whole
vault, so the reviews key sits in the same item as the sales key and any code reading one has the
other in hand. What protects them from each other now is type and wiring, not the Keychain — see
above. If you are auditing this on the assumption that the sales key and reviews key are
independently stored, that assumption no longer holds.

Upgrading migrates the seven old items into one. That launch still asks seven times, because there
is no way to read seven items with fewer than seven authorisations. An old item is deleted only
after the new one has been written *and* read back identical, and only if that specific value was
successfully read — a prompt you dismiss leaves its item untouched for a later launch rather than
being deleted on the strength of a value Vantage never saw.

The `.p8` file you picked is read once, at the moment you choose it, and is not copied anywhere.
Vantage does not keep the file path, does not re-read the file later, and does not need the file to
exist afterward — you can move it back to your password manager and delete the download.

Nothing else stores credentials. Not `UserDefaults`, not the on-disk report cache, not a log file,
not a crash report, not an error message shown in the panel. **Settings › Forget credentials**
removes every value from the Keychain, both keys; **Remove reviews key** removes only the second.

## Where it goes

Five hosts. That is the entire network surface of this application.

```
GET https://api.appstoreconnect.apple.com/v1/salesReports          (your reports)
GET https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml  (currency rates)
GET https://api.appstoreconnect.apple.com/v1/apps/…/customerReviews (reviews, if you added a key)
POST/DELETE …/v1/customerReviewResponses…                          (only if you enable replying)
GET https://itunes.apple.com/lookup?id=…&entity=software           (app icons)
GET https://*.mzstatic.com/…                                       (the icon image itself)
GET https://*.amazonaws.com/…                                      (analytics report files)
```

The first two carry the app's whole purpose. Two more exist only to draw an app's icon beside its
row, and the fifth only if you added a reviews key — v0.1 really did talk to two hosts and nothing
else.

**Drafting a reply adds no host.** The composer's Draft button runs Apple's on-device model on your
Mac: the review's rating, title and text go to it, and nothing leaves the machine. Vantage uses
`SystemLanguageModel` only, never Private Cloud Compute. Detecting the review's language, so the
reply comes back in it, also runs on-device — `NLLanguageRecognizer`, not a request anywhere. A
draft is ordinary text in the editor and is published only through the same confirmation as a typed
reply.

**Why a third and fourth host for something so small:** the App Store Connect API has no icon. There
is no artwork field on `/v1/apps/{id}`, and no endpoint that returns one. The public storefront
lookup is the only source, and it answers on `itunes.apple.com` with a URL pointing at
`*.mzstatic.com`.

### The one host that isn't Apple's

Analytics report files are handed over as **pre-signed AWS S3 URLs**, because that is how Apple
serves them. It is the only destination in this application that isn't Apple or the European Central
Bank, and it is the only one that **cannot be named in advance** — the bucket and the region vary,
so the tightest honest constraint is `https` on a host under `.amazonaws.com`, and that is what the
code enforces.

What protects you there:

- **The download carries no credential.** It goes out on a separate `URLSession` configured with no
  additional headers at all, so there is no path by which your bearer token could reach a host
  outside Apple's estate. The URL is pre-signed; it needs nothing from us.
- **The URL comes from Apple**, over an authenticated connection to `api.appstoreconnect.apple.com`,
  and expires five minutes after Apple issues it.
- **The bytes are checked** against the MD5 Apple published for them before anything is parsed.
- **It only ever happens if you added a reviews key.** No key, no analytics, and nothing is ever
  requested from this host.

**It does happen in the background, and that is deliberate.** Engagement figures live on the
Overview now rather than behind a section you had to open, and Vantage fetches them from every
refresh — launch, waking from sleep, the poll timer — as well as when you open the panel or click
Refresh Now. A first run also imports whatever history Apple still holds for each app, which is
more of these downloads than a normal day's.

The reason is retention, not convenience: Apple deletes a day's analytics after 35 days, so a day
nobody collects is *gone* rather than merely late. What keeps the cost down is the six-hour
staleness gate in `AnalyticsStore`, which settles at one to four fetches a day however often the
timer fires — not restraint about when to ask. None of that changes what leaves your machine: the
download still carries no credential, and the bytes are still checked before they're parsed.

`docs/ANALYTICS_API.md` explains the whole lifecycle and why it looks like this.

**What the icon requests reveal:** the numeric Apple ID of an app you publish, to Apple,
unauthenticated. No token, no vendor number, no app names, no sales figures, no cookies. It is byte
for byte the request the App Store website makes when anyone anywhere looks at your app's page, and
it carries nothing that identifies you as the caller. Icons are cached on disk after the first fetch,
so it happens once per app rather than once per refresh.

Every connection **refuses redirects outright**. Without that, a 302 from any of them could send the
next request — and, for App Store Connect, your bearer token with it — somewhere this document
doesn't mention. Refusing redirects is what makes "four destinations" something the code enforces
rather than a description of how it currently happens to behave.

**Two places take a URL out of a response body and then fetch it**: the icon lookup's artwork URL,
and the reviews API's `links.next` pagination link. Refusing redirects does nothing about either —
these aren't redirects, they're fresh requests the code chooses to make from a URL something else
supplied. Both are therefore checked against an expected host before being requested, which is what
makes the list above a guarantee rather than a description:

- **artwork** must be `https` on `itunes.apple.com` or `*.mzstatic.com`. It carries no credential.
- **`links.next`** must be `https` on `api.appstoreconnect.apple.com`, matched exactly — that one
  carries a bearer token, so it gets the stricter check.

A missing icon is a blank tile; it is never a reason to follow a stranger.

The App Store Connect request carries a freshly minted ES256 JWT, signed locally with your private
key. Apple rejects tokens for this endpoint that live longer than 20 minutes; Vantage issues them
for **five**. Every **GET** token also carries a `scope` claim naming the single request it was
minted for, so a token that somehow escaped could fetch one sales report for one date and nothing
else. Apple enforces that claim — a scoped token used against any other request is refused with
`403 FORBIDDEN.REQUEST_DOES_NOT_MATCH_SCOPE`.

**Write tokens carry no scope claim, because Apple accepts none.** A `POST`, `PATCH` or `DELETE`
whose token is scoped is answered `405 METHOD_NOT_ALLOWED`; a verbless entry or an empty array is
`400 ENTITY_INVALID`; a `GET` entry is `403`. Only an unscoped token is accepted, so the two writes
Vantage can make — creating an analytics report request (ongoing, and one historical snapshot per
app), and publishing a review reply — are
limited by the `aud` claim and the five-minute lifetime rather than by scope. Tokens are held in
memory for the request and dropped — never written to disk.

**Credentials themselves are held in memory by default, and you can turn that off.**
*Settings › App Store Connect › Keychain* controls it:

- **On** (default) — the vault is read once per launch and kept until you quit. One password prompt
  per launch at most.
- **Off** — every request reads the Keychain again, so a key never outlives the request that used
  it. This is what Vantage did unconditionally before the setting existed. More private, more
  prompts.

Switching it off drops what is already held immediately rather than at the next launch. Either way
nothing is written to disk, and nothing is logged.

Three currencies Apple pays in — **AED, SAR and QAR** — are converted from a **hard-coded peg**
rather than a fetched rate, because their central banks fix them against the US dollar and the ECB
doesn't publish them. That is a number in the source, not a request: it adds no host and sends
nothing. It also means that if one of those pegs is ever broken, Vantage's figure for it becomes
wrong until the table is updated — so the panel names them wherever they're used, and the table
lives in `FX.swift` with its dates rather than buried. Nothing else is hard-coded; a floating
currency the ECB doesn't publish stays unconverted and is shown separately.

The ECB request carries nothing. No token, no identifier, no app names, no numbers — it is a
request for a public XML file of exchange rates, identical for every user in the world.

There is no telemetry, no analytics, no crash reporting, no update check, and no third-party
service of any kind — the icon lookup is Apple's own public storefront API, not a service operated
by anyone else. There is no server operated by this project. **Your sales figures are never
sent anywhere** — they travel from Apple to your Mac and stop there.

## What it stores on disk

`~/Library/Application Support/Vantage/` holds one JSON file per day: the parsed totals for that
date. Daily reports are immutable once published, so a cached day is never re-fetched. Alongside it,
`icons/` holds one image per app — public store artwork, nothing derived from your account —
`reviews/` holds one file per app of the review text shown in the panel, `listings/` holds each
app's public App Store rating and rating count, and `analytics/` holds the impression and page-view
counts. Removing the reviews key deletes both `reviews/` and `analytics/`,
because that key is the only reason either was readable.

`analytics/` is the only cache Vantage cannot rebuild: Apple keeps analytics report instances for 35
days and no longer, so anything older there exists in that file and nowhere else.

Those files contain your own sales numbers — app names, unit counts and proceeds. They're readable
by anything running as your user, exactly like any other app's Application Support folder. They
contain no credentials. Delete the folder any time; Vantage will refetch what it can (Apple keeps
daily reports for one year).

`UserDefaults` (`com.vickipetrova.vantage`) holds preferences only, and no credential: display
currency, which metrics count as downloads, the chart series, the Overview range, the notification
toggle, a marker for which day was last notified about — and **`repliesEnabled`**, the switch that
decides whether Vantage may publish a review reply at all. That last one is listed here because it
is the only preference with a security consequence; it defaults to off, and turning it on is the
consent step described above.

## The command-line tool

`vantage-cli` is built from this repository alongside the app, and exists so you — or an AI agent
over MCP — can read your numbers without opening the panel.

**It is read-only by construction, not by policy.** It links `VantageCore` and calls exactly one
type, `CacheQuery`, which opens files under `~/Library/Application Support/Vantage` and does nothing
else. There is no code path in it that reads the Keychain, opens a socket, or writes anything.

That matters most for the MCP case, because an AI agent will call it without asking you first. The
worst it can do is describe data you already have. It cannot refresh, cannot publish a review reply,
and cannot reach App Store Connect — and because it holds no credentials, there is nothing in it to
leak if the agent's output goes somewhere you didn't expect.

One thing to be aware of rather than reassured about: **an agent you point at it will read your
sales figures, app names, customer reviews and ratings**, and whatever that agent does with them is
between you and its operator. Vantage sends nothing anywhere; a tool you connect to it might.

An earlier version of `status` reported whether a reviews key was configured. That was removed: it
made an unsigned binary raise a keychain prompt, and a tool that promises to hold no credentials has
no business asking about one.

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
| `Sources/VantageCore/ASCReviewsWriter.swift` | The only code that can publish, and that it isn't built unless you asked for it |
| `Sources/VantageCore/CacheQuery.swift` | That the CLI and MCP server read files and do nothing else |
| `Sources/VantageCore/ReplyDraft.swift` | That publishing without confirming is un-expressible, not merely discouraged |
| `Sources/VantageCore/Analytics.swift` | The S3 host check — the one destination that isn't Apple's |
| `Sources/VantageCore/ASCAnalyticsClient.swift` | That the download session carries no credential, and that bytes are checksummed |

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
