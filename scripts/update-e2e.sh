#!/bin/bash
# Update & Restart, the way a user sees it: an installed Twinfold finds a newer release, replaces itself
# with it and reopens; a download that doesn't match its published checksum is refused and nothing changes.
# Needs dist/Twinfold.app (scripts/bundle.sh). Serves the "release" from a local stand-in for GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d dist/Twinfold.app ] || { echo "run scripts/bundle.sh first"; exit 1; }

TMP=$(realpath "$(mktemp -d)")
APPS=$TMP/Applications OUT=$TMP/out FEED=$TMP/feed
cleanup() { pkill -f "$APPS/Twinfold.app/Contents/MacOS/Twinfold" 2>/dev/null || true; kill ${SERVER:-} 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT
mkdir -p "$APPS" "$OUT" "$FEED/dist" "$TMP/support" "$TMP/new"
OLD=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" dist/Twinfold.app/Contents/Info.plist)

# The "new release": the same app numbered 9.9.9, signed and zipped like the release workflow does.
ditto dist/Twinfold.app "$TMP/new/Twinfold.app"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString 9.9.9" "$TMP/new/Twinfold.app/Contents/Info.plist"
codesign --force --deep --sign - "$TMP/new/Twinfold.app" 2>/dev/null
(cd "$TMP/new" && ditto -c -k . "$FEED/dist/Twinfold-9.9.9.zip")
(cd "$FEED" && shasum -a 256 dist/Twinfold-9.9.9.zip > checksums.txt)
echo "0000000000000000000000000000000000000000000000000000000000000000  dist/Twinfold-9.9.9.zip" > "$FEED/bad-checksums.txt"

python3 -I -u -m http.server 0 --bind 127.0.0.1 --directory "$FEED" > "$TMP/server.log" 2>&1 &
SERVER=$!; disown $SERVER
PORT=
for _ in $(seq 1 300); do PORT=$(grep -oE 'port [0-9]+' "$TMP/server.log" | grep -oE '[0-9]+' || true); [ -n "$PORT" ] && break; sleep 0.1; done
[ -n "$PORT" ] || { echo "stand-in server didn't start"; exit 1; }
feed() { python3 -I -c "import json,sys; print(json.dumps({'tag_name':'v9.9.9','assets':[
  {'name':'Twinfold-9.9.9.zip','browser_download_url':sys.argv[1]+'/dist/Twinfold-9.9.9.zip'},
  {'name':'checksums.txt','browser_download_url':sys.argv[1]+'/'+sys.argv[2]}]}))" "http://127.0.0.1:$PORT" "$1"; }
feed checksums.txt > "$FEED/good.json"
feed bad-checksums.txt > "$FEED/bad.json"

FAILS=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got $2, expected $3)"; FAILS=$((FAILS + 1)); fi; }
version() { /usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APPS/Twinfold.app/Contents/Info.plist"; }
launch() {
  open -n --env TWINFOLD_SUPPORT_DIR="$TMP/support" --env TWINFOLD_UPDATE_URL="http://127.0.0.1:$PORT/$1" \
    --env TWINFOLD_UPDATE_AUTOPILOT="$OUT" "$APPS/Twinfold.app" || true
  for _ in $(seq 1 600); do [ -f "$OUT/update.json" ] && return 0; sleep 0.2; done
  echo "FAIL  the app didn't report within 2 minutes"; exit 1
}
echo '{"license":{"activatedAt":"2026-10-25T14:20:00Z","email":"buyer@example.com","instanceID":"lki_x","key":"K"}}' > "$TMP/support/entitlement.json"
LICENSE_BEFORE=$(shasum "$TMP/support/entitlement.json" | cut -c1-40)

# A download that doesn't match its checksum: refused, the installed app untouched.
ditto dist/Twinfold.app "$APPS/Twinfold.app"
launch bad.json
check "a download that fails its checksum is refused" \
  "$(python3 -I -c "import json; print(json.load(open('$OUT/update.json'))['error'])")" \
  "The download didn't match the published checksum, so it wasn't installed."
check "and the installed app is left as it was" "$(version)" "$OLD"

# The real thing: Update & Restart.
rm -f "$OUT/update.json"
open -n --env TWINFOLD_SUPPORT_DIR="$TMP/support" --env TWINFOLD_UPDATE_URL="http://127.0.0.1:$PORT/good.json" \
  --env TWINFOLD_UPDATE_AUTOPILOT="$OUT" "$APPS/Twinfold.app"
for _ in $(seq 1 300); do [ "$(version)" = 9.9.9 ] && break; sleep 0.2; done
check "Update & Restart puts the new version in place" "$(version)" 9.9.9
REOPENED=no
for _ in $(seq 1 100); do pgrep -f "$APPS/Twinfold.app/Contents/MacOS/Twinfold" >/dev/null && { REOPENED=yes; break; }; sleep 0.2; done
check "and reopens it" "$REOPENED" yes
check "the new app's signature is valid" "$(codesign --verify --deep --strict "$APPS/Twinfold.app" 2>/dev/null && echo ok)" ok
check "no old copy left behind" "$(ls -A "$APPS" | grep -c previous || true)" 0
check "the Pro license is untouched" "$(shasum "$TMP/support/entitlement.json" | cut -c1-40)" "$LICENSE_BEFORE"

echo
[ $FAILS -eq 0 ] && echo "update e2e: all checks passed" || { echo "update e2e: $FAILS failed"; exit 1; }
