#!/bin/bash
# The app the way a user runs it: the bundled Twinfold.app, launched by macOS (not from this shell), saving
# space on files another app created. macOS tags every file with the app that made it
# (com.apple.provenance), and a clone always gets the cloning app's tag, so files from other apps are the
# real-world case. Uses a headless Chrome to make them; skips (and says so) if Chrome isn't installed.
# Needs dist/Twinfold.app (scripts/bundle.sh). Run on a real Mac before each release: CI machines can't
# reliably open apps through Launch Services.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app"
[ -d "$CHROME" ] || { echo "SKIP  user e2e: Google Chrome isn't installed"; exit 0; }
[ -d dist/Twinfold.app ] || { echo "run scripts/bundle.sh first"; exit 1; }

TMP=$(realpath "$(mktemp -d)")
trap 'pkill -f "user-data-dir=$TMP/" 2>/dev/null || true; rm -rf "$TMP"' EXIT
FIX=$TMP/files OUT=$TMP/out
mkdir -p "$FIX" "$OUT" "$TMP/support"
cc -O2 -o "$TMP/meta" scripts/tools/meta.c

# Three fresh Chrome profiles: Chrome writes the same files into each, tagged as Chrome's.
for i in 1 2 3; do
  open -n -g -a "$CHROME" --args --headless=new --disable-gpu --no-first-run --user-data-dir="$FIX/profile$i" \
    --print-to-pdf="$TMP/p$i.pdf" about:blank
done
for _ in $(seq 1 120); do [ -f "$TMP/p1.pdf" ] && [ -f "$TMP/p2.pdf" ] && [ -f "$TMP/p3.pdf" ] && break; sleep 0.5; done
sleep 3; pkill -f "user-data-dir=$TMP/" 2>/dev/null || true; sleep 1

FAILS=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got $2, expected $3)"; FAILS=$((FAILS + 1)); fi; }

TAGGED=$(xattr -px com.apple.provenance "$(find "$FIX/profile1" -name History | head -1)" 2>/dev/null | tr -d ' \n')
MINE=$(echo x > "$TMP/mine" && xattr -px com.apple.provenance "$TMP/mine" 2>/dev/null | tr -d ' \n')
check "the files carry another app's provenance tag" "$([ -n "$TAGGED" ] && [ "$TAGGED" != "$MINE" ] && echo yes)" yes

export TWINFOLD_SUPPORT_DIR=$TMP/support TWINFOLD_QUIET_SECONDS=0 META=$TMP/meta
.build/release/twinfold scan --json "$FIX" > "$TMP/scan.json" 2>/dev/null || "$(swift build --show-bin-path)/twinfold" scan --json "$FIX" > "$TMP/scan.json"
EXPECTED=$(python3 -I -c "import json,sys; g=json.load(open(sys.argv[1]))['groups']; print(sum(sum(len(c) for c in x['clusters'])-1 for x in g))" "$TMP/scan.json")
python3 -I scripts/tools/manifest.py record "$TMP/scan.json" "$TMP/manifest.jsonl" >/dev/null

open -n --env TWINFOLD_SUPPORT_DIR="$TMP/support" --env TWINFOLD_QUIET_SECONDS=0 \
  --env TWINFOLD_UPDATE_URL=http://127.0.0.1:9/none --env TWINFOLD_SAVE_AUTOPILOT="$OUT" --env TWINFOLD_ROOTS="$FIX" \
  dist/Twinfold.app
for _ in $(seq 1 900); do [ -f "$OUT/save.json" ] && break; sleep 0.2; done
if [ ! -f "$OUT/save.json" ]; then
  echo "FAIL  the app didn't finish saving within 3 minutes (running: $(pgrep -lf 'Twinfold.app/Contents/MacOS' | head -2 | tr '\n' ' '))"
  pkill -f "dist/Twinfold.app/Contents/MacOS/Twinfold" 2>/dev/null || true; exit 1
fi
field() { python3 -I -c "import json; print(json.load(open('$OUT/save.json'))['$1'])"; }
check "the app saved every duplicate Chrome made ($EXPECTED files)" "$(field foldedFiles)" "$EXPECTED"
check "nothing was left alone" "$(field problems)" 0
VERIFY=$(python3 -I scripts/tools/manifest.py verify "$TMP/manifest.jsonl" "$TMP/report.json" || true)
check "every file's contents and metadata unchanged (bar the provenance tag)" \
  "$(python3 -I -c "import json; r=json.load(open('$TMP/report.json')); print(r['unchanged']==r['files'] and not r['changed_by_twinfold'])")" True
mkdir -p .scratch/user-e2e && cp "$OUT"/done.png .scratch/user-e2e/ 2>/dev/null || true

echo
[ $FAILS -eq 0 ] && echo "user e2e: all checks passed" || { echo "user e2e: $FAILS failed"; exit 1; }
