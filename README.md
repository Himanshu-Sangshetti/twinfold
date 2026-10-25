<p align="center">
  <img src="docs/images/icon.png" width="96" alt="Twinfold icon">
</p>

<h1 align="center">Twinfold</h1>

<p align="center">
  Get disk space back on your Mac without removing any files.
  <br><a href="https://himanshu-sangshetti.github.io/twinfold/">Website</a> · <a href="https://github.com/Himanshu-Sangshetti/twinfold/releases/latest/download/Twinfold.zip">Download</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/simple-dark.png">
    <img src="docs/images/simple-light.png" width="720" alt="Twinfold: 11.7 GB is stored twice on your disk, with a Save button and the folders it's in">
  </picture>
</p>

Your Mac is full of identical files: the same `node_modules` in five projects, the same PyTorch in every
virtualenv, the same video saved to Downloads twice. Each copy takes its own space on disk.

Twinfold finds them and turns the copies into **clones**. Every file stays exactly where it is, with its
own name, dates and permissions, but the copies now share one set of blocks on disk. Edit one and only
that one changes; macOS handles it automatically.

On the Mac it was built on, Twinfold found **36 GB** to free, without deleting a single file. It scans a
home folder of 8.7 million files in about a minute, and you see exactly what will change before anything does:
by kind, by folder, and file by file, with anything you'd rather leave alone a click away. Click any file
to see every identical copy, the disk space now and after, and a live check that reads the files and
shows they are byte-for-byte identical and how many times the data is really stored. Every run is kept in
History, where you can undo it any time.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/files-dark.png">
    <img src="docs/images/files-light.png" width="720" alt="Every set of identical files, with where each copy lives">
  </picture>
</p>

## Install

**App:** [download Twinfold.zip](https://github.com/Himanshu-Sangshetti/twinfold/releases/latest/download/Twinfold.zip),
unzip, and drag Twinfold to Applications. The app isn't notarized by Apple yet, so the first time, macOS
will say it can't check it: open it once, then choose **Open Anyway** in System Settings, Privacy & Security.

**Command line:**

```sh
git clone https://github.com/Himanshu-Sangshetti/twinfold && cd twinfold
swift build -c release && cp .build/release/twinfold /usr/local/bin/
```

Requires macOS 14 or later. Works on any APFS volume, the default on every Mac since 2017.

**Updating:** when a new version is out, the app shows it with a Download button. Quit Twinfold (from the
menu bar if Automatic is on), then drag the new one into Applications and replace the old one. Your Pro
license, settings and History stay.

## Free, and Pro

**Free, unlimited:** scanning, saving any amount of space, the live check, History with undo for every run,
folders you leave alone remembered, the command line tool, and the source code.

**Twinfold Pro, $12 once** (no subscription, up to 3 Macs) adds **Automatic**: Twinfold checks your
folders once a day or week, when your Mac is idle and plugged in (or more than half charged), and stores new duplicates once, with a menu bar item showing what it saved.
Twinfold stays in the menu bar when you close its window and starts there when you log in (you can turn that
off). Every automatic run shows up in History and can be undone.

If Twinfold saved you space and you'd just like to say thanks, you can
[sponsor it on GitHub](https://github.com/sponsors/Himanshu-Sangshetti).

## Use

```sh
twinfold scan                 # how much space identical files could share (changes nothing)
twinfold reclaim              # fold them into clones and free the space
twinfold undo                 # give every folded file its own copy again
```

```
$ twinfold scan ~/.cache ~/.venvs

  3.9 GB can be freed, nothing deleted.
  1,137 identical files can share space, in 667 sets · 676,965 files checked in 21s
  (696 MB of identical files already share space)

  255 MB    telecom_4trials.json  ×6
            ~/.cache/tau2-synth/data/results/telecom_4trials.json
            ~/.cache/tau3-bench/data/results/telecom_4trials.json
            …
```

Pass folders to scan only those. `--min-size 1M` skips small files, `--json` prints machine-readable
output, and `--dry-run` shows what `reclaim` would do. See `twinfold help` for everything.

## Use with AI agents

Twinfold is also an [MCP](https://modelcontextprotocol.io) server, so Claude, Cursor or any agent can do it for you:
"find what's duplicated in my projects folder and save it". The agent can scan, list and explain sets, re-check
files on disk, save, see history and undo. Saving and undoing always take two steps: a dry run first, then an
explicit confirm, which agents are told to ask you for.

```sh
claude mcp add twinfold -- twinfold mcp          # Claude Code
```

For Claude Desktop or Cursor, add this to their MCP settings:

```json
{ "mcpServers": { "twinfold": { "command": "twinfold", "args": ["mcp"] } } }
```

## Is it safe?

Twinfold never deletes a file. For each copy it:

1. clones the twin next to it,
2. copies the copy's own permissions, owner, flags, ACL, extended attributes (tags, quarantine, comments)
   and dates (created, modified, Date Added) onto the clone,
3. checks all of that metadata matches exactly, and compares the clone with the copy **byte for byte**
   (hashes only pick candidates),
4. checks the copy hasn't changed and no app has it open for writing,
5. swaps the clone into place in one atomic rename.

If anything looks off at any step, that file is left exactly as it was. Every fold is written to a
journal, and Undo (in History, or `twinfold undo`) puts every file back the way it was.

How it was tested: a 42-check safety suite (`scripts/safety-e2e.py`, in CI) kills Twinfold mid-save, edits
and deletes files between scan and save and after saving, holds files open in other apps, and checks every
byte and metadata field before and after. And on a real Mac: 44,857 files saved (29 GB), all 201,219 files
in those sets re-read and compared before and after, undone, compared again, and saved again.

It stays away from things it shouldn't touch: iCloud Drive, Dropbox and other cloud folders (their files
may not be fully downloaded), Photos and Music libraries, `~/Library` (unless you ask), hard links,
locked files, files with a "deny" ACL, files changed in the last few minutes, files open for writing,
files owned by other users and system files.

## FAQ

**How is this different from a duplicate finder?** Duplicate finders delete the extra copies, which
breaks whatever expected them to be there. Twinfold keeps every file and still gets the space back.

**What happens when I edit a folded file?** Only that file changes. APFS writes the changed blocks
somewhere new, so the twins are never affected.

**Does Time Machine see the difference?** Time Machine backs files up by content, not by block, so your
backups stay complete. Folded files may be backed up once more because they look changed.

**Does deleting a file still free its space?** Only once every twin is gone. After sharing, deleting one copy
frees less than Finder shows, because the others still use that data.

**Why did the space come back after a while?** If you edit folded files, the edited parts take new
space. Run Twinfold again any time.

**Does the app connect to the internet?** Only for two things: once a day it asks GitHub whether a newer
version is out (nothing about you or your files is sent), and when you activate a Pro key it checks the key
with the store. Scanning and saving never leave your Mac.

**Similar tools:** [Hyperspace](https://hypercritical.co/hyperspace/) is a polished paid app that does
the same thing. [fclones](https://github.com/pkolaczk/fclones) can do it from the command line. Twinfold
is open source, so anyone can read exactly what it does, and every change can be undone.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). For security
issues, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
