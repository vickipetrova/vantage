#!/usr/bin/env bash
# Compiles assets/Vantage.icon into the two files build.sh copies into the app bundle:
#
#   assets/AppIcon/Assets.car     the layered icon — light, dark, clear and tinted on macOS 26
#   assets/AppIcon/Vantage.icns   a flat fallback for macOS 13–15, generated from the same design
#
# Run this only when the icon changes, then commit both outputs. It needs full Xcode (actool);
# build.sh deliberately doesn't, so it copies the committed results instead of compiling here.
set -euo pipefail
cd "$(dirname "$0")/.."

ICON="assets/Vantage.icon"
OUT="assets/AppIcon"
MIN_MACOS="13.0"   # keep in step with build.sh

command -v xcrun >/dev/null && xcrun --find actool >/dev/null 2>&1 || {
  echo "error: actool not found — this script needs full Xcode, not just the Command Line Tools." >&2
  exit 1
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

xcrun actool "$ICON" \
  --compile "$WORK" \
  --app-icon Vantage \
  --include-all-app-icons \
  --enable-on-demand-resources NO \
  --platform macosx --target-device mac \
  --minimum-deployment-target "$MIN_MACOS" \
  --output-partial-info-plist "$WORK/partial.plist" \
  --output-format human-readable-text --errors --warnings --notices

mkdir -p "$OUT"
cp "$WORK/Assets.car" "$OUT/Assets.car"
cp "$WORK/Vantage.icns" "$OUT/Vantage.icns"
echo "Wrote $OUT/Assets.car and $OUT/Vantage.icns"
