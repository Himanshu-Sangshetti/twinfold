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
export TWINFOLD_QUIET_SECONDS=0
export TWINFOLD_UPDATE_URL=http://127.0.0.1:9/no-update-checks-in-tests
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
check "\"try one set first\" offers just the biggest set (2 copies of the 80 MB file)" "$(field 1-scanned trial)" 160000000
check "unticking folder A leaves 40 MB selected" "$(field 2-unticked selected)" 40000000
check "app reports no problems" "$(field 3-freed problems)" 0
atleast "app measured at least 36 MB freed" "$(field 3-freed freed)" 36000000
check "every file's contents unchanged after freeing" "$(hashes)" "$BEFORE"
check "done screen proof: example set now stored once" "$(field 3-freed proofStored)" 1
check "done screen proof: every copy identical" "$(field 3-freed proofIdentical)" 1
check "done screen proof: no copy missing" "$(field 3-freed proofMissing)" 0
check "done screen counts the 1 file compared and shared" "$(field 3-freed foldedFiles)" 1
check "done screen states undo needs 40 MB free" "$(field 3-freed foldedBytes)" 40000000
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

# Pro: the license gate, with no bypass. A stand-in for Dodo's /licenses/activate answers like the real one.
PRODUCT=$(grep -oE '\.live: "pdt_[A-Za-z0-9]+"' Sources/TwinfoldCore/Licensing.swift | grep -oE 'pdt_[A-Za-z0-9]+')
python3 -I - "$PRODUCT" "$TMP/port" <<'EOF' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
product, portfile = sys.argv[1], sys.argv[2]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        key = body["license_key"]
        code, out = {"OFF-KEY": (403, {}), "FULL-KEY": (422, {}),
                     "OTHER-PRODUCT": (201, {"id": "lki_x", "product": {"product_id": "pdt_other"}, "customer": {"email": "a@b.c"}}),
                     "GOOD-KEY": (201, {"id": "lki_good", "product": {"product_id": product}, "customer": {"email": "buyer@example.com"}})
                     }.get(key, (404, {}))
        self.send_response(code); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(json.dumps(out).encode())
s = HTTPServer(("127.0.0.1", 0), H)
open(portfile, "w").write(str(s.server_address[1]))
s.serve_forever()
EOF
STORE=$!; disown $STORE
trap 'kill $STORE 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do [ -s "$TMP/port" ] && break; sleep 0.1; done
rm -f "$TWINFOLD_SUPPORT_DIR/entitlement.json"

python3 -I -c "import json,sys; json.dump({'watched':[sys.argv[1]],'leaveAlone':[],'automatic':'off','lastAutoSaved':0}, open(sys.argv[2],'w'))" "$FIX" "$TWINFOLD_SUPPORT_DIR/settings.json"
BEFORE_LOCKED=$(reclaimable)
"$BIN/TwinfoldApp" --auto
check "without a license, an automatic run saves nothing" "$(reclaimable)" "$BEFORE_LOCKED"

TWINFOLD_PRO_AUTOPILOT=$OUT TWINFOLD_STORE_URL="http://127.0.0.1:$(cat "$TMP/port")" \
  TWINFOLD_PRO_KEYS="TYPO-KEY,OFF-KEY,FULL-KEY,OTHER-PRODUCT, GOOD-KEY " "$BIN/TwinfoldApp" >"$TMP/pro.log" 2>&1 || { echo "Pro run crashed:"; grep -m1 reason "$TMP/pro.log" || true; }
pro() { python3 -I -c "import json; d=json.load(open('$OUT/pro.json')); v=d['$1']; print(v[${2:-0}] if isinstance(v, list) else v)"; }
check "Pro starts locked" "$(pro unlockedAtStart)" False
check "Automatic can't be switched on while locked" "$(pro automaticWhileLocked)" off
check "unknown key: says it wasn't found" "$(pro errors 0)" "That key wasn't found. Check it was pasted in full."
check "refunded key: says it was turned off" "$(pro errors 1)" "That key has been turned off, for example after a refund."
check "key on 3 Macs: says the limit" "$(pro errors 2)" "That key is already in use on 3 Macs."
check "another product's key: refused" "$(pro errors 3)" "That key is for a different product."
check "a good key pasted with spaces activates" "$(pro errors 4)" ""
check "Pro unlocks" "$(pro unlocked)" True
check "license remembered on disk" "$(pro savedToDisk)" True
check "license shows the buyer's email" "$(pro email)" buyer@example.com
check "Automatic switches on once unlocked" "$(pro automatic)" weekly
check "closing the window keeps Twinfold running with Automatic on" "$(python3 -I -c "import json; print(json.load(open('$OUT/alive-after-close.json'))['visibleWindows'])" 2>/dev/null || echo app-quit)" 0
"$BIN/TwinfoldApp" --auto
check "with the license, an automatic run (no test bypass) saves the 160 MB set" "$(reclaimable)" 0

# The open app picks things up by itself: the update notice, and a 3 am run done by another process.
LIVE=$TMP/live FEED=$TMP/feed
mkdir -p "$LIVE" "$FEED" "$FIX/C"
cp "$FIX/0keep/f2.bin" "$FIX/C/f2.bin"
echo '{"tag_name":"v9.9.9"}' > "$FEED/newer.json"
grep -o 'static let version = "[^"]*"' Sources/TwinfoldCore/Licensing.swift | sed 's/.*"\(.*\)"/{"tag_name":"v\1"}/' > "$FEED/same.json"
python3 -I -u -m http.server 0 --bind 127.0.0.1 --directory "$FEED" > "$TMP/feed.log" 2>&1 &
FEEDPID=$!; disown $FEEDPID
trap 'kill $STORE $FEEDPID 2>/dev/null; rm -rf "$TMP"' EXIT
FEEDPORT=
for _ in $(seq 1 50); do FEEDPORT=$(grep -oE 'port [0-9]+' "$TMP/feed.log" | grep -oE '[0-9]+' || true); [ -n "$FEEDPORT" ] && break; sleep 0.1; done
live() { python3 -I -c "import json; print(json.load(open('$LIVE/live.json'))['$1'])"; }
until_file() { for _ in $(seq 1 300); do [ -f "$1" ] && return 0; sleep 0.2; done; echo "timed out waiting for $1"; exit 1; }

TWINFOLD_LIVE_AUTOPILOT=$LIVE TWINFOLD_UPDATE_URL="http://127.0.0.1:$FEEDPORT/newer.json" "$BIN/TwinfoldApp" >/dev/null 2>&1 &
APP=$!
until_file "$LIVE/ready"
"$BIN/TwinfoldApp" --auto
touch "$LIVE/go"; wait $APP || true
check "the open app shows when a newer version is out" "$(live update)" 9.9.9
check "the open app shows the 3 am run (done by another process) without reopening" "$(live savedAfter)" 40000000
cp "$LIVE/update-banner.png" "$OUT/" 2>/dev/null || true

rm -f "$LIVE"/*; touch "$LIVE/go"
TWINFOLD_LIVE_AUTOPILOT=$LIVE TWINFOLD_UPDATE_URL="http://127.0.0.1:$FEEDPORT/same.json" "$BIN/TwinfoldApp" >/dev/null 2>&1 || true
check "no update notice when this is the latest version" "$(live update)" ""

# Started at login (--menubar) with Automatic on: menu bar only, no window, no Dock icon.
rm -f "$LIVE"/*
TWINFOLD_LAUNCH_PROBE=$LIVE "$BIN/TwinfoldApp" --menubar >/dev/null 2>&1 || true
check "login start opens no window" "$(python3 -I -c "import json; print(json.load(open('$LIVE/launch.json'))['visibleWindows'])")" 0
check "login start shows no Dock icon" "$(python3 -I -c "import json; print(json.load(open('$LIVE/launch.json'))['inDock'])")" False
python3 -I -c "import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['openAtLogin']=False; json.dump(d, open(p,'w'))" "$TWINFOLD_SUPPORT_DIR/settings.json"
rm -f "$LIVE"/*
TWINFOLD_LAUNCH_PROBE=$LIVE "$BIN/TwinfoldApp" --menubar >/dev/null 2>&1 || true
check "with 'keep in menu bar' off, it opens as a normal window" "$(python3 -I -c "import json; print(json.load(open('$LIVE/launch.json'))['visibleWindows'])")" 1

# Two saves at once (the 3 am run while the app saves): one waits for the other; every file stays intact.
TWO=$TMP/two; mkdir -p "$TWO"
python3 -I -c "import os,sys; d=os.urandom(30_000_000); [open(os.path.join(sys.argv[1], f'c{i}.bin'),'wb').write(d) for i in range(6)]" "$TWO"
TWO_BEFORE=$(cd "$TWO" && shasum -a 256 * | sort)
"$BIN/twinfold" reclaim -y "$TWO" > "$TMP/r1.log" 2>&1 & R1=$!
"$BIN/twinfold" reclaim -y "$TWO" > "$TMP/r2.log" 2>&1 & R2=$!
wait $R1; S1=$?; wait $R2; S2=$?
check "two saves at the same time both finish cleanly" "$S1$S2" 00
check "every file intact after two saves at once" "$(cd "$TWO" && shasum -a 256 * | sort)" "$TWO_BEFORE"
check "no temp files left behind" "$(ls -A "$TWO" | grep -c twinfold || true)" 0
check "all copies share storage afterwards" "$("$BIN/twinfold" scan --json "$TWO" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["reclaimableBytes"])')" 0

# The lock itself: while another process holds it, a save waits and changes nothing; then it finishes.
HELD=$TMP/held; mkdir -p "$HELD"
python3 -I -c "import os,sys; d=os.urandom(20_000_000); [open(os.path.join(sys.argv[1], f'h{i}.bin'),'wb').write(d) for i in range(3)]" "$HELD"
python3 -I -c "import fcntl,sys,time,os; f=open(os.path.join(sys.argv[1],'run.lock'),'a'); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2],'w').close(); time.sleep(4)" "$TWINFOLD_SUPPORT_DIR" "$TMP/locked" &
HOLDER=$!
until_file "$TMP/locked"
"$BIN/twinfold" reclaim -y "$HELD" > "$TMP/held.log" 2>&1 & SAVER=$!
sleep 2
check "a save waits while another Twinfold holds the lock (nothing shared yet)" "$("$BIN/twinfold" scan --json "$HELD" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["reclaimableBytes"])')" 40000000
check "and hasn't touched the folder (no temp files)" "$(ls -A "$HELD" | grep -c twinfold || true)" 0
wait $HOLDER; wait $SAVER
check "once the lock is free, the save finishes" "$("$BIN/twinfold" scan --json "$HELD" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["reclaimableBytes"])')" 0

mkdir -p .scratch/app-e2e && cp "$OUT"/*.png .scratch/app-e2e/
echo
[ $FAILS -eq 0 ] && echo "app e2e: all checks passed" || { echo "app e2e: $FAILS failed"; exit 1; }
