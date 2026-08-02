---
name: Bug report
about: A number is wrong, or something in the menu bar or dropdown misbehaves
title: ''
labels: bug
assignees: ''
---

**What happened**

<!-- What the menu bar or dropdown showed, and what you expected instead. A screenshot of the menu
     bar and the open dropdown helps a lot.

     NEVER paste your Issuer ID, Key ID, .p8 contents, or Vendor Number into an issue. Crop or blur
     anything in a screenshot you don't want public — including sales figures, if you'd rather not
     publish them. The shape of a discrepancy is usually enough to debug it. -->

**Steps to reproduce**

1.
2.

**Environment**

- Vantage version: <!-- from the DMG filename, or the git commit you built -->
- macOS version: <!-- Apple menu > About This Mac -->
- Mac: <!-- Apple Silicon or Intel -->
- Installed from: <!-- signed DMG release, or built from source with ./build.sh -->
- Display currency:
- Do your apps sell in more than one proceeds currency? <!-- yes / no / not sure -->

**If a number is wrong**

<!-- Which report date, and what App Store Connect's own Sales and Trends page shows for that same
     date. Two things worth checking first, because they explain most disagreements:

     1. Set the App Store Connect dashboard's time zone to Pacific (PT). It defaults to UTC, and
        downloaded reports are always PT — so the same nominal day covers different transactions.
     2. Compare against the Units column, not the dashboard's estimated totals. Vantage counts net
        units the same way, refunds included. -->
