#!/bin/bash
# End-to-end test of the Mac app: the real window runs scan -> untick a folder -> free -> undo on a generated
# fixture (see Snapshot.autopilot), and this script checks the files on disk between steps.
# Screens are saved to .scratch/app-e2e for review.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build --product TwinfoldApp >/dev/null
swift build --product twinfold >/dev/null
BIN=$(swift build --show-bin-path)

TMP=$(realpath "$(mktemp -d)")
trap 'rm -rf "$TMP"' EXIT
FIX=$TMP/fixture OUT=$TMP/out
export TWINFOLD_SUPPORT_DIR=$TMP/support
mkdir -p "$FIX" "$OUT"

# 0keep holds the originals (sorts first, so it is kept); A holds 2 copies of an 80 MB file, B one copy of 40 MB.
python3 -I - "$FIX" <<'EOF'
import os, sys
root = sys.argv[1]
def put(rel, data):
    p = os.path.join(root, rel); os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "wb").write(data)
f1, f2 = os.urandom(80_000_000), os.urandom(40_000_000)
for rel in ["0keep/f1.bin", "A/p1/f1.bin", "A/p2/f1.bin"]: put(rel, f1)
for rel in ["0keep/f2.bin", "B/f2.bin"]: put(rel, f2)
EOF
hashes() { (cd "$FIX" && find . -type f -exec shasum -a 256 {} + | sort); }
reclaimable() { "$BIN/twinfold" scan --json "$FIX" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["reclaimableBytes"])'; }
field() { python3 -I -c "import json; print(json.load(open('$OUT/$1.json'))['$2'])"; }
waitfor() { for _ in $(seq 1 600); do [ -f "$OUT/$1" ] && return 0; sleep 0.2; done; echo "timed out waiting for $1"; exit 1; }

BEFORE=$(hashes)
FAILS=0
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got $2, expected $3)"; FAILS=$((FAILS + 1)); fi; }
atleast() { if [ "$2" -ge "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (got $2, expected >= $3)"; FAILS=$((FAILS + 1)); fi; }

TWINFOLD_AUTOPILOT=$OUT TWINFOLD_ROOTS=$FIX "$BIN/TwinfoldApp" >/dev/null 2>&1 &
APP=$!

waitfor 3-freed.json
check "app scan finds 200 MB" "$(field 1-scanned reclaimable)" 200000000
check "unticking folder A leaves 40 MB selected" "$(field 2-unticked selected)" 40000000
check "app reports no problems" "$(field 3-freed problems)" 0
atleast "app measured at least 36 MB freed" "$(field 3-freed freed)" 36000000
check "every file's contents unchanged after freeing" "$(hashes)" "$BEFORE"
check "done screen proof: example set now stored once" "$(field 3-freed proofStored)" 1
check "done screen proof: every copy identical" "$(field 3-freed proofIdentical)" 1
check "done screen proof: no copy missing" "$(field 3-freed proofMissing)" 0
check "unticked folder A was left alone (still 160 MB to share)" "$(reclaimable)" 160000000

check "unticked folder is remembered for next time" "$(python3 -I -c "import json; print(json.load(open('$TWINFOLD_SUPPORT_DIR/settings.json'))['leaveAlone'])")" "['$FIX/A']"
touch "$OUT/continue"
wait $APP
check "undo finished and shows History" "$(field 4-undone phase)" history
check "undo says what it restored" "$(field 4-undone message)" "1 file has its own copy again."
check "removing a left-alone folder in Automatic settings forgets it" "$(field 5-settings leaveAlone)" 0
check "and ticks it again in the results" "$(field 5-settings stillUnticked)" 0
check "every file's contents unchanged after undo" "$(hashes)" "$BEFORE"
check "after undo all 200 MB is separate again" "$(reclaimable)" 200000000

# Automatic mode: launchd runs the app binary with --auto; it should save everything except folders left alone.
python3 -I -c "import json,sys; json.dump({'watched':[sys.argv[1]],'leaveAlone':[sys.argv[1]+'/A'],'automatic':'weekly','lastAutoSaved':0}, open(sys.argv[2],'w'))" "$FIX" "$TWINFOLD_SUPPORT_DIR/settings.json"
TWINFOLD_FORCE_AUTO=1 "$BIN/TwinfoldApp" --auto
check "automatic run left folder A alone (160 MB still separate)" "$(reclaimable)" 160000000
check "automatic run kept every file's contents" "$(hashes)" "$BEFORE"
check "automatic run recorded what it saved" "$(python3 -I -c "import json; print(json.load(open('$TWINFOLD_SUPPORT_DIR/settings.json'))['lastAutoSaved'])")" 40000000
check "automatic run shows up in History (a journal)" "$(ls "$TWINFOLD_SUPPORT_DIR/journal" | wc -l | tr -d ' ')" 1

mkdir -p .scratch/app-e2e && cp "$OUT"/*.png .scratch/app-e2e/
echo
[ $FAILS -eq 0 ] && echo "app e2e: all checks passed" || { echo "app e2e: $FAILS failed"; exit 1; }
