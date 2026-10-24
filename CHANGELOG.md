# Changelog

## 0.3.0

- Saving is free and unlimited. Twinfold Pro ($12 once) adds Automatic: a daily or weekly run at 3 am via launchd, plus a menu bar item.
- History: every run is listed with what it saved and can be undone any time, not only right after.
- Folders you untick are remembered for future scans and automatic runs.
- New look: Liquid Glass panels on macOS 26 (frosted material on 14 and 15), History and Automatic in the top bar.
- Support links (GitHub Sponsors) in the app and README.

## 0.2.0

- Paid tier (replaced in 0.3.0): 5 GB free in the app, a license key removed the limit. License keys via Dodo Payments; scanning, the CLI and the source stay free and unlimited.
- Detail pane: click any folder or file to see every identical copy with its full path, where the copies live, and a now-vs-after picture of disk space.
- Live proof: re-reads the files on demand and shows they are all in place, identical (SHA-256) and how many times the data is stored on disk. The done screen proves one folded set this way.
- Wording no longer sounds like deleting: "Save", "stores that data only once", "without removing any files".
- Scans about 4x faster (bulk directory reads across threads).
- Plain wording: identical files that share space; a "How does this work?" explainer.
- Asks for confirmation before freeing; safety line next to the button; Undo is a real button.
- Headline shows what's selected out of what was found; rows explain copies that already share space.
- End-to-end tests for the command line and the app.
- Plainer results text ("files have an exact twin"), undo mentioned before you decide, rows read "2 identical · 1.8 GB each".
- Keeps the Mac awake while scanning or freeing; scans ignore leftover temporary files.
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
