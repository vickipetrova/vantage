# Security

Vantage asks you for an App Store Connect API key. That is a real credential, and handing one to a
menu bar app off the internet is a reasonable thing to be nervous about. This document is the whole
story of what happens to it, so you can check the claims against the source.

## What the key can do

An App Store Connect API key's power comes from the **role** you give it when you create it, not
from the app that holds it. Vantage needs exactly one thing: read-only access to Sales and Trends
reports.

**Create the key with the Sales and Reports role. Nothing else.**

Such a key can download sales reports for your vendor number. It cannot see your bank details or
tax forms, cannot change app metadata, cannot submit or remove a build, cannot manage users, and
cannot touch pricing or availability.

An **Admin** key can do all of those. Vantage would never use those abilities and asks you not to
create one — if you already have an Admin key lying around, don't reuse it here. Make a second key
with the Sales and Reports role and give Vantage that one.

Keys are revocable. If you ever want Vantage to stop having access, revoke the key in App Store
Connect (Users and Access › Integrations) — that works whether or not you still have the app
installed, and it does not affect your other keys.

## Where it's stored

Four values, entered once in Settings: Issuer ID, Key ID, the contents of the `.p8` private key
file, and your Vendor Number.

All four go into the **macOS Keychain**, under the service `com.vickipetrova.vantage`, through
`Security.framework` in-process (`SecItemAdd` / `SecItemCopyMatching`) — not by shelling out to
`/usr/bin/security`, so no credential ever crosses a pipe or lands in a subprocess's output.

The `.p8` file you picked is read once, at the moment you choose it, and is not copied anywhere.
Vantage does not keep the file path, does not re-read the file later, and does not need the file to
exist afterward — you can move it back to your password manager and delete the download.

Nothing else stores credentials. Not `UserDefaults`, not the on-disk report cache, not a log file,
not a crash report, not an error message shown in the menu. **Settings › Forget credentials**
removes all four from the Keychain.

## Where it goes

Two hosts. That is the entire network surface of this application.

```
GET https://api.appstoreconnect.apple.com/v1/salesReports    (your reports)
GET https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml   (currency rates)
```

The App Store Connect request carries a freshly minted ES256 JWT, signed locally with your private
key, valid for **20 minutes at most** — that ceiling is Apple's, and Vantage stays well under it.
The token is minted per request batch, held in memory, and dropped. It is never written to disk.

The ECB request carries nothing. No token, no identifier, no app names, no numbers — it is a
request for a public XML file of exchange rates, identical for every user in the world.

There is no telemetry, no analytics, no crash reporting, no update check, and no third-party
service of any kind. There is no server operated by this project. **Your sales figures are never
sent anywhere** — they travel from Apple to your Mac and stop there.

## What it stores on disk

`~/Library/Application Support/Vantage/` holds one JSON file per day: the parsed totals for that
date. Daily reports are immutable once published, so a cached day is never re-fetched.

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

CI fails the build if anything in `Sources/` prints or logs a credential. That grep is a backstop
for mistakes, not the reason the guarantee holds — the reason is that nothing in the source does it.

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
