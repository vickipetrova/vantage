# Fixtures

Synthetic Summary Sales reports, hand-written from the format documented in
[`docs/REPORT_FORMAT.md`](../../docs/REPORT_FORMAT.md).

**Never put a real report here**, not even a redacted one. These files are committed to a public
repository. Every one of them should be small enough to read in full and obviously fake — app names
like "App One", round numbers, a handful of rows.

Each fixture exists to pin down one thing `ReportParser` has to get right:

| File | What it proves |
|---|---|
| _(added in Phase 3)_ | |

Fixtures are loaded by path relative to this directory, not through a resource bundle, so they can
be read and edited as plain files.
