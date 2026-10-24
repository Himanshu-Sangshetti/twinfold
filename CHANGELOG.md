# Changelog

## Unreleased

- Scans about 4x faster (bulk directory reads across threads).
- Plain wording: identical files that share space; a "How does this work?" explainer.
- Asks for confirmation before freeing; safety line next to the button; Undo is a real button.
- Headline shows what's selected out of what was found; rows explain copies that already share space.
- End-to-end tests for the command line and the app.
- Results screen shows where the space is: a breakdown by kind, a folder tree and every duplicate set with each copy's location.
- Untick folders or sets to leave them alone; the Free button follows the selection.
- The last scan is kept, so results are still there after relaunching.
- Paths are resolved through symlinks before comparing, so unticked folders are always respected.

## 0.1.0

First release.

- `twinfold scan`, `reclaim` and `undo` commands.
- Mac app with scan, free and undo.
- Byte-for-byte verification before every fold; original metadata kept; journal for undo.
- Skips cloud folders, Photos and Music libraries, ~/Library, hard links, locked and system files.
