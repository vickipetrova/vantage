## What this changes

<!-- One or two sentences. If it fixes an issue, "Fixes #123". -->

## How you tested it

<!-- "Builds clean" is not testing. Say what you actually saw in the menu bar. For anything visual,
     attach a screenshot of the menu bar title and the open dropdown. If you changed parsing, say
     what you fed it. -->

## Checklist

- [ ] `swift test` passes, and anything touching parsing, money or dates has a test
- [ ] `./build.sh` succeeds and the app runs
- [ ] No new dependencies (Foundation, AppKit, CryptoKit, Compression, Security,
      UserNotifications, ServiceManagement only)
- [ ] Nothing logs, prints, stores to disk, or commits a credential — `.p8` contents, Issuer ID,
      Key ID, Vendor Number, or a minted JWT
- [ ] No third network destination
- [ ] Money is `Decimal` end to end
- [ ] New parsing skips a malformed row and counts it, rather than crashing or dropping the day
- [ ] Any new fixture is synthetic, not a real report
- [ ] One change per PR
