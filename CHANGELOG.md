# Changelog

## 0.7.1

- **Saving now works on files made by other apps.** macOS tags every file with the app that created it (`com.apple.provenance`), and a clone always gets the cloning app's tag; nothing can set it. The safety check counted that as a difference, so the downloaded app left almost every file alone. Twinfold now ignores only that tag; contents, permissions, dates, Finder tags, quarantine and every other attribute are still checked exactly.
- Files left alone are reported with the real reason (in use, changed recently, locked, …) in the app and the command line, instead of "changed while we worked".
- **Update & Restart:** when a new version is out, Twinfold downloads it, checks it against the published SHA-256 and its signature, replaces itself and reopens. Your license, settings and History stay. Anything off and nothing changes.
- Automatic is only set up from the Applications folder (opened straight from Downloads, macOS runs a temporary copy that's gone after a restart); a banner explains how to move it.
- Scans leave apps (`.app`) and the Music and TV media folders alone, so macOS doesn't ask about app management or the media library.
- The license key field always shows the pasted key, and has a Paste button.
- Choose when Automatic runs (3 am by default). A run missed while the Mac was asleep happens as soon as it wakes.
- With Automatic on, Twinfold now lives in the menu bar: closing the window keeps it running there (no Dock icon), and it starts there, without a window, when you log in. A switch in Automatic turns this off. With Automatic off, closing the window quits as before.
- The app notices when a newer version is out (one request to GitHub a day) and shows how to update; your license and settings carry over.
- The open app now picks up overnight runs by itself, and only one save or undo runs at a time across the app, the overnight run and the command line, so they never get in each other's way.
- After an update or a move, the 3 am schedule and the login item point at the new copy of the app.
- An idle window no longer uses CPU (the start animation plays three times, then rests).
- New end-to-end checks for all of the above, for Pro activation (every error, no test bypass) and for upgrading from 0.7.0; releases now run every test suite and check the version and download before publishing.

## 0.7.0

Safety release. Tested on a real Mac: 44,857 files saved (29 GB), every one of 201,219 files re-read byte for byte with identical metadata, undone, verified again, and saved again.

- The replacement file is checked in full (contents, permissions, owner, flags, ACL, every extended attribute, created, modified and Date Added) right before it takes the original's place.
- Keeps the quarantine attribute and Finder's Date Added exactly (Downloads keeps its order).
- Leaves alone files open for writing in another app, files changed in the last 5 minutes, files with a "deny" ACL and files with a document id.
- Undo puts files that already shared storage before (Finder duplicates, earlier clones) back to sharing, so it never uses more space than Save freed. A file it can't restore right now stays in History.
- A crash or power cut mid-save leaves every file intact; the next run removes the temporary clone.
- New 42-check safety suite (scripts/safety-e2e.py) in CI.
- The download includes READ-ME-FIRST.txt on opening an app that isn't notarized.

## 0.6.0

- New type: Instrument Serif for the big numbers and headlines, Geist Mono for file paths (both bundled, SIL Open Font License).
- A free-space bar shows what saving does to your disk ("Free space 38.4 GB → 50.1 GB"), on the results and done screens.
- Warmer paper background in light mode, deeper green-black in dark mode; serif titles in the detail pane, History and Automatic.
- Landing page uses the same fonts.

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
