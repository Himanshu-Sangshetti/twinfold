#!/bin/sh
# Runs the test suite. With only the Command Line Tools installed (no Xcode),
# Swift Testing lives outside the default search paths, so point at it.
set -e
cd "$(dirname "$0")/.."
export TWINFOLD_QUIET_SECONDS=0  # fixtures are brand new; the quiet period has its own test
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$CLT/Frameworks/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test -Xswiftc -F"$CLT/Frameworks" -Xlinker -F"$CLT/Frameworks" \
    -Xlinker -rpath -Xlinker "$CLT/Frameworks" -Xlinker -rpath -Xlinker "$CLT/usr/lib" "$@"
fi
exec swift test "$@"
