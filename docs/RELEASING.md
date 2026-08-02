# Releasing

Vantage's `build.sh` deliberately knows nothing about signing identities or Apple credentials — it
only ad-hoc signs. Producing a release that opens without a Gatekeeper warning is a manual step on
the maintainer's Mac, documented here.

It matters more here than for most apps: **ad-hoc signed builds can't register for notifications**,
so the morning notification — the point of the app for most people — only works in a properly signed
release. Build-from-source users see a "Notifications blocked" row explaining why.

## 1. Prepare

- Bump `VERSION` in `build.sh`.
- Add the release section to `CHANGELOG.md`.
- `swift test` passes.
- Commit, then tag and push:

```bash
git tag v0.1.0
git push origin main --tags
```

## 2. CI builds a draft

`.github/workflows/release.yml` runs on any `v*` tag: it runs the tests, builds the app and DMG on a
`macos-latest` runner, and opens a **draft** GitHub Release with `Vantage.dmg` attached.

That asset is ad-hoc signed — CI never sees a Developer ID, by design. It is fine for testing and
wrong to publish. Replace it with a properly signed one below.

## 3. Sign and notarize locally

One-time setup on your Mac:

1. A **Developer ID Application** certificate in your Keychain (Xcode › Settings › Accounts ›
   Manage Certificates). An *Apple Development* certificate is not enough for distribution.
2. A notarytool credential profile, using an
   [app-specific password](https://support.apple.com/en-us/102654) — not your Apple ID password:

```bash
xcrun notarytool store-credentials "vantage" \
  --apple-id you@example.com \
  --team-id YOURTEAMID \
  --password xxxx-xxxx-xxxx-xxxx
```

Then, per release:

```bash
./build.sh --dmg

SIGN_ID="Developer ID Application: Your Name (YOURTEAMID)"

# Sign and notarize the .app first, so a copy dragged out of the DMG carries its own ticket.
xattr -cr build/Vantage.app
codesign --force --options runtime --timestamp --sign "$SIGN_ID" build/Vantage.app
ditto -c -k --keepParent build/Vantage.app build/app-notarize.zip
xcrun notarytool submit build/app-notarize.zip --keychain-profile "vantage" --wait
xcrun stapler staple build/Vantage.app
rm build/app-notarize.zip

# Repackage the DMG around the now-signed app, then sign and notarize the image itself —
# that's the check a downloader actually hits.
./build.sh --dmg
codesign --force --timestamp --sign "$SIGN_ID" build/Vantage.dmg
xcrun notarytool submit build/Vantage.dmg --keychain-profile "vantage" --wait
xcrun stapler staple build/Vantage.dmg
```

> [!WARNING]
> The second `./build.sh --dmg` rebuilds the app bundle from scratch, discarding the signature and
> stapled ticket applied above. Re-run the `codesign`/`notarytool`/`stapler` steps for the `.app`
> after it, or package the DMG by hand from the already-signed bundle.

Verify before publishing:

```bash
spctl -a -t open --context context:primary-signature -v build/Vantage.dmg   # expect: accepted
xcrun stapler validate build/Vantage.dmg                                     # expect: validated
```

Then install the notarized build and confirm the notification actually fires — that's the one
behaviour the ad-hoc build can't demonstrate, so it can only be checked here.

## 4. Publish

Replace the draft release's asset with the notarized `build/Vantage.dmg`, paste the CHANGELOG
section as the release notes, and publish.
