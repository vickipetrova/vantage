#!/bin/bash
# Builds build/Vantage.app (and optionally build/Vantage.dmg with: ./build.sh --dmg).
# Requires the Xcode Command Line Tools (xcode-select --install). No Xcode project, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Vantage"
VERSION="0.2.0"
BUNDLE_ID="com.vickipetrova.vantage"
MIN_MACOS="13.0"

APP="build/$APP_NAME.app"
BIN="$APP/Contents/MacOS/$APP_NAME"

MODE="${1:-}"

# --dmg-only packages the DMG around the bundle that is already in build/, without rebuilding it.
# Releasing signs and staples the .app first; rebuilding at that point would throw both away and
# wrap an ad-hoc signed app in a notarized image. See docs/RELEASING.md.
if [[ "$MODE" == "--dmg-only" ]]; then
  [[ -d "$APP" ]] || { echo "No $APP to package. Run ./build.sh first." >&2; exit 1; }
else

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building universal binary (arm64 + x86_64)…"
# Universal so it runs natively on Apple Silicon and Intel without Rosetta. Two --arch flags make
# SwiftPM emit one binary containing both slices, so there's no lipo step to get wrong. The
# deployment target comes from Package.swift; keep it pinned there, or the binary gets stamped with
# the build machine's OS and refuses to launch on older systems despite LSMinimumSystemVersion.
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME"
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
cp "$BIN_PATH/$APP_NAME" "$BIN"

# The read-only CLI, for humans and for agents over MCP. Built alongside because it shares
# VantageCore — a separate build would let the two drift.
echo "Building vantage-cli…"
swift build -c release --arch arm64 --arch x86_64 --product vantage-cli
cp "$BIN_PATH/vantage-cli" "build/vantage-cli"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><false/></dict>
</dict>
</plist>
PLIST

# Ad-hoc signing only — this repo never handles a Developer ID or notarization credentials.
# Signing and notarizing a release is a manual maintainer step: see docs/RELEASING.md.
# xattr first: extended attributes (quarantine, Finder info) make codesign refuse the bundle.
xattr -cr "$APP"
# Not swallowed: on Apple Silicon an unsigned bundle dies at launch, and hiding the reason here
# turns a one-line error into an app that simply doesn't start.
codesign --force --sign - "$APP"

echo "Built $APP"

fi

if [[ "$MODE" == "--dmg" || "$MODE" == "--dmg-only" ]]; then
  echo "Packaging DMG…"
  DMG="build/$APP_NAME.dmg"
  STAGE="build/dmg-stage"
  rm -rf "$STAGE" "$DMG"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"

  # Build straight from the folder rather than laying out a mounted read-write image: macOS's
  # fseventsd creates a hidden .fseventsd on any writable volume, and deleting it does not stick
  # (the deletion is itself an event, which recreates it). No mount, no stray hidden folders.
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  echo "Built $DMG"
fi

echo
echo "Run:      open $APP"
echo "Install:  cp -R $APP /Applications/"
echo "CLI:      build/vantage-cli status      (install: cp build/vantage-cli /usr/local/bin/)"
