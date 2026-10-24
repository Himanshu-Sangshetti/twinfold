# Contributing

Thanks for helping. Twinfold touches people's files, so the bar for safety is high and the code is kept small.

## Setup

```sh
git clone https://github.com/Himanshu-Sangshetti/twinfold && cd twinfold
swift build
scripts/test.sh          # unit tests (works with Xcode or just the Command Line Tools)
scripts/e2e.sh           # command line, end to end, on a generated folder
scripts/app-e2e.sh       # the app, end to end: scan, untick, free, undo
swift run TwinfoldApp    # runs the app
swift run twinfold scan ~/Downloads
```

## Layout

- `Sources/TwinfoldCore`: scanning, comparing and folding. All file system work lives here.
- `Sources/twinfold`: the command-line tool.
- `Sources/TwinfoldApp`: the SwiftUI app. `TWINFOLD_SNAPSHOT=<dir> swift run TwinfoldApp` renders every screen to PNGs.
- `scripts/bundle.sh`: builds `dist/Twinfold.app`.

## Rules for changes

- Anything that writes to a user's disk needs a test in `Tests/TwinfoldCoreTests`, including the failure path.
- Never delete or overwrite a user file except through the clone, compare, rename sequence in `Reclaimer.fold`.
- No dependencies unless there's no reasonable way around it.
- Keep the app calm: one primary action per screen, plain words.

Open an issue before large changes so we can agree on the approach.
