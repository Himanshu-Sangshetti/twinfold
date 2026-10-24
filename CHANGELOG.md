# Changelog

## 0.5.0

- Simple by default: after a scan you see the number, one Save button, a line saying every file is checked byte for byte and can be undone, and the top folders with checkboxes. "See exactly what changes" opens the full review.
- Agent native: `twinfold mcp` is an MCP server for Claude Code, Claude Desktop and Cursor (scan, list and explain sets, check files on disk, save, history, undo; saving and undoing need an explicit confirm).
- Save dialog: "Try one set first".
- Files tab: search and sort.
- Keyboard and VoiceOver: arrow keys move through lists, labels on checkboxes and icon buttons, Esc closes sheets.
- Start screen says scanning only reads files and nothing changes until you press Save.
- Homebrew cask and formula (packaging/homebrew), and a landing page in docs/.

## 0.4.0

- Undo is safer: it skips files deleted since, stops before the disk gets too full, keeps the rest, and finishes when you undo that run again. History shows what each undo did.
- Start screen animation: two identical files folding into one block on disk.
- Automatic: choose the watched folders, see and remove folders that are always left alone, and get a notification when an overnight run saved space.
- Folder detail uses the same duplicate count as the list and names the exact folders (for example each project's node_modules) where the identical files are; it's cached, so big scans stay smooth.
- Done screen says how many files were compared byte for byte and how much free space undo would need.
- Tests: identical files on two different volumes are never paired; undo on a nearly full disk; the CLI test no longer writes to the real History folder.

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
