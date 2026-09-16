Screenshots and the hero GIF for the README live here. Blur or fake the figures before recording.

## App icon

- `Vantage.icon` — the source, an Icon Composer document: the dawn gradient as the fill, the tower
  as one glass layer, with Dark and Tinted colours. Open it in Icon Composer (inside Xcode) to edit.
- `AppIcon/Assets.car` and `AppIcon/Vantage.icns` — compiled from it by `scripts/make-icon.sh`.
  `build.sh` copies these into the bundle. **Rerun the script and commit both after changing the
  icon** — they're committed so that building needs only the Command Line Tools, not Xcode.

The menu bar glyph is drawn in code (`Sources/Vantage/TowerGlyph.swift`) from the same tower.
