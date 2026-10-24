#!/usr/bin/env bash
# End-to-end test for Twinfold: builds the CLI, creates a ~380 MB fixture in a fresh temp dir,
# and exercises scan / reclaim / copy-on-write / undo against real APFS clones.
# macOS + APFS only. Never touches anything outside the temp dir: journals go to a temp support dir too.
set -euo pipefail

[[ "$(uname)" == "Darwin" ]] || { echo "e2e.sh needs macOS (APFS clones)"; exit 1; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
START=$SECONDS
WORK="$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/twinfold-e2e.XXXXXX")")"
export TWINFOLD_SUPPORT_DIR="$WORK/support"
export TWINFOLD_QUIET_SECONDS=0
JOURNAL_DIR="$TWINFOLD_SUPPORT_DIR/journal"
FIX="$WORK/fixture"
NEW_JOURNALS=()

cleanup() {
  set +e
  for j in "${NEW_JOURNALS[@]:-}"; do [[ -n "$j" && -f "$j" ]] && rm -f "$j"; done
  if [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == *twinfold-e2e.* ]]; then
    chflags -R nouchg "$WORK" 2>/dev/null
    for m in "$FIX" "$WORK/vol" "$WORK/vol2"; do mount | grep -q " on $m " && hdiutil detach -quiet -force "$m"; done
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

RESULTS=()
FAILS=0
record() { RESULTS+=("$1|$2|$3"); [[ "$1" == FAIL ]] && FAILS=$((FAILS + 1)); return 0; }
# check NAME CMD...: run CMD, record PASS/FAIL with its last output line
check() {
  local name="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  local last; last="$(printf '%s\n' "$out" | tail -n 1)"
  if [[ $rc -eq 0 ]]; then record PASS "$name" "$last"; else record FAIL "$name" "$(printf '%s\n' "$out" | tail -n 12 | tr '\n' ' ')"; fi
  return 0
}
note() { echo "==> $*"; }

# ---------------------------------------------------------------- python helper
mkdir -p "$WORK/h"
cat > "$WORK/h/tool.py" <<'PY'
import ctypes, hashlib, json, os, plistlib, stat, sys

MB = 1024 * 1024
libc = ctypes.CDLL(None, use_errno=True)
XATTR_NOFOLLOW = 1

def xattrs(path):
    p = path.encode()
    n = libc.listxattr(p, None, 0, XATTR_NOFOLLOW)
    if n <= 0:
        return {}
    buf = ctypes.create_string_buffer(n)
    libc.listxattr(p, buf, n, XATTR_NOFOLLOW)
    out = {}
    for name in buf.raw[:n].split(b"\0"):
        if not name:
            continue
        m = libc.getxattr(p, name, None, 0, 0, XATTR_NOFOLLOW)
        v = ctypes.create_string_buffer(max(m, 1))
        libc.getxattr(p, name, v, m, 0, XATTR_NOFOLLOW)
        out[name.decode()] = v.raw[:m].hex()
    return out

def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

def gen(fix):
    w = lambda p, data: (os.makedirs(os.path.dirname(p), exist_ok=True), open(p, "wb").write(data))
    rnd = os.urandom
    def lines(kind, size):
        base = {"js": "// padding line to make this module larger than the 64K minimum size\n",
                "py": "# padding line to make this module larger than the 64K minimum size\n"}[kind]
        return (base * (size // len(base) + 1))[:size]
    js = ("'use strict';\nmodule.exports = function () { return 'twinfold-ok'; };\n" + lines("js", 70000)).encode()
    py = ("def hello():\n    return 'twinfold-ok'\n" + lines("py", 70000)).encode()
    blob, data, photo = rnd(60 * MB), rnd(40 * MB), rnd(20 * MB)
    t1, t2, t3, t4 = rnd(2 * MB), rnd(2 * MB), rnd(2 * MB), rnd(2 * MB)
    small = rnd(60000)
    m1 = bytearray(rnd(5 * MB)); m2 = bytearray(m1); m2[len(m2) // 2] ^= 0xFF

    for i in (1, 2, 3):
        w(f"{fix}/projects/p{i}/node_modules/pkg/index.js", js)
        w(f"{fix}/projects/p{i}/data/blob.bin", blob)
        w(f"{fix}/py/c{i}/site-packages/mypkg/__init__.py", py)
        w(f"{fix}/py/c{i}/site-packages/mypkg/data.bin", data)
        w(f"{fix}/small/s{i}.bin", small)
    for i in (1, 2, 3, 4):
        w(f"{fix}/photos/IMG_{i}.jpg", photo)
    os.utime(f"{fix}/photos/IMG_1.jpg", (1577836800, 1577836800))   # 2020-01-01
    os.utime(f"{fix}/photos/IMG_2.jpg", (1623715200, 1623715200))   # 2021-06-15
    os.utime(f"{fix}/photos/IMG_3.jpg", (1650000000, 1650000000))
    os.chmod(f"{fix}/photos/IMG_3.jpg", 0o600)
    tag = plistlib.dumps(["Red\n6"], fmt=plistlib.FMT_BINARY).hex()
    os.system(f"xattr -w com.example.tag hello '{fix}/photos/IMG_4.jpg'")
    os.system(f"xattr -wx com.apple.metadata:_kMDItemUserTags {tag} '{fix}/photos/IMG_4.jpg'")
    os.utime(f"{fix}/photos/IMG_4.jpg", (1680000000, 1680000000))
    os.symlink(f"{fix}/photos/IMG_1.jpg", f"{fix}/photos/link.jpg")

    # T1: two normal copies + a locked one
    w(f"{fix}/traps/t1_a.bin", t1); w(f"{fix}/traps/t1_b.bin", t1); w(f"{fix}/traps/t1_locked.bin", t1)
    os.system(f"chflags uchg '{fix}/traps/t1_locked.bin'")
    # T2: two normal copies + one inside a Photos library
    w(f"{fix}/traps/t2_a.bin", t2); w(f"{fix}/traps/t2_b.bin", t2); w(f"{fix}/Lib.photoslibrary/t2_lib.bin", t2)
    # T3: two normal copies + one in the folder passed to --exclude
    w(f"{fix}/traps/t3_a.bin", t3); w(f"{fix}/traps/t3_b.bin", t3); w(f"{fix}/excluded/t3_x.bin", t3)
    # T4: hard-linked pair + a separate copy
    w(f"{fix}/traps/hl_a.bin", t4); os.link(f"{fix}/traps/hl_a.bin", f"{fix}/traps/hl_b.bin"); w(f"{fix}/traps/hl_c.bin", t4)
    # same size, different middle
    w(f"{fix}/samesize/m1.bin", bytes(m1)); w(f"{fix}/samesize/m2.bin", bytes(m2))

    js_n, py_n = len(js), len(py)
    expected = 2 * js_n + 2 * len(blob) + 2 * py_n + 2 * len(data) + 3 * len(photo) + 3 * len(t1)  # T1,T2,T3 each fold 1
    excluded_expected = expected   # the excluded copy is left out, but t3_a/t3_b still fold into each other
    traps_always = [f"{fix}/traps/t1_locked.bin", f"{fix}/traps/hl_a.bin", f"{fix}/traps/hl_b.bin",
                    f"{fix}/traps/hl_c.bin", f"{fix}/photos/link.jpg", f"{fix}/Lib.photoslibrary/t2_lib.bin",
                    f"{fix}/samesize/m1.bin", f"{fix}/samesize/m2.bin"] + [f"{fix}/small/s{i}.bin" for i in (1, 2, 3)]
    traps_excluded = [f"{fix}/excluded/t3_x.bin"]
    json.dump({
        "expected_with_exclude": excluded_expected,
        "expected_no_exclude": expected + len(t3),
        "t3_size": len(t3),
        "folds": 14,  # js 2 + blob 2 + py 2 + data 2 + photos 3 + T1/T2/T3 1 each
        "traps": traps_always, "traps_excluded": traps_excluded,
        "strict": traps_always + traps_excluded + [f"{fix}/traps/t4"],
        "projects": [f"{fix}/projects/p{i}" for i in (1, 2, 3)],
        "pycopies": [f"{fix}/py/c{i}/site-packages" for i in (1, 2, 3)],
        "cow_victim": f"{fix}/projects/p2/data/blob.bin",
        "cow_twins": [f"{fix}/projects/p1/data/blob.bin", f"{fix}/projects/p3/data/blob.bin"],
        "exclude_dir": f"{fix}/excluded",
    }, open(sys.argv[3], "w"))

def snap(fix, out):
    res = {}
    for d, dirs, files in os.walk(fix):
        for n in files:
            p = os.path.join(d, n)
            st = os.lstat(p)
            e = {"inode": st.st_ino, "mtime": st.st_mtime_ns, "mode": stat.S_IMODE(st.st_mode),
                 "flags": st.st_flags, "nlink": st.st_nlink, "size": st.st_size, "xattrs": xattrs(p)}
            if stat.S_ISLNK(st.st_mode):
                e["link"] = os.readlink(p)
            else:
                e["sha"] = sha(p)
            res[p] = e
    json.dump(res, open(out, "w"))
    print(f"{len(res)} files recorded")

def cmp(a, b, mode, meta_path):
    A, B = json.load(open(a)), json.load(open(b))
    strict = set(json.load(open(meta_path))["strict"]) if mode == "traps" else set()
    bad, changed_inodes = [], 0
    if set(A) != set(B):
        bad.append(f"file set differs: -{sorted(set(A)-set(B))[:3]} +{sorted(set(B)-set(A))[:3]}")
    for p in A:
        if p not in B:
            continue
        x, y = A[p], B[p]
        keys = ["sha", "size", "mtime", "mode", "xattrs", "flags", "link"]
        if mode == "all" or p in strict:
            keys += ["inode", "nlink"]
        for k in keys:
            if x.get(k) != y.get(k):
                bad.append(f"{os.path.basename(p)}: {k} {str(x.get(k))[:60]} -> {str(y.get(k))[:60]}")
        if x["inode"] != y["inode"]:
            changed_inodes += 1
    if bad:
        print("; ".join(bad[:8])); sys.exit(1)
    print(f"{len(A)} files identical ({mode}); {changed_inodes} inodes changed")

def inodes_changed(a, b):
    A, B = json.load(open(a)), json.load(open(b))
    n = sum(1 for p in A if p in B and A[p]["inode"] != B[p]["inode"])
    print(n)

def scanchk(scan, meta_path, expect_key, allow_excluded):
    s, m = json.load(open(scan)), json.load(open(meta_path))
    expect = m[expect_key] if isinstance(expect_key, str) and expect_key in m else int(expect_key)
    got = s["reclaimableBytes"]
    ok = abs(got - expect) <= 0.01 * expect if expect else got == 0
    files = {f for g in s["groups"] for c in g["clusters"] for f in c}
    traps = set(m["traps"]) | (set() if allow_excluded else set(m["traps_excluded"]))
    hit = sorted(files & traps)
    if not ok or hit:
        print(f"reclaimableBytes={got} expected~{expect}; trap files in groups: {hit}"); sys.exit(1)
    print(f"reclaimableBytes={got} (expected {expect}), no trap files in groups")

def cow(meta_path, before):
    m = json.load(open(meta_path))
    B = json.load(open(before))
    v = m["cow_victim"]
    with open(v, "ab") as f:
        f.write(b"copy-on-write test")
    twins_ok = all(sha(t) == B[t]["sha"] for t in m["cow_twins"])
    victim_changed = sha(v) != B[v]["sha"]
    # restore the victim to its original content and mtime
    os.truncate(v, B[v]["size"])
    os.utime(v, ns=(B[v]["mtime"], B[v]["mtime"]))
    if not twins_ok or not victim_changed:
        print(f"twins unchanged={twins_ok} victim changed={victim_changed}"); sys.exit(1)
    print("victim changed, twins untouched")

def meta(key):
    v = json.load(open(sys.argv[3]))[key]
    print(v if not isinstance(v, list) else "\n".join(v))

cmd = sys.argv[1]
if cmd == "gen": gen(sys.argv[2])
elif cmd == "snap": snap(sys.argv[2], sys.argv[3])
elif cmd == "cmp": cmp(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
elif cmd == "inodes": inodes_changed(sys.argv[2], sys.argv[3])
elif cmd == "scanchk": scanchk(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5] == "yes")
elif cmd == "cow": cow(sys.argv[2], sys.argv[3])
elif cmd == "meta": meta(sys.argv[3])
PY
T() { python3 "$WORK/h/tool.py" "$@"; }
META="$WORK/meta.json"
free_kb() { df -k "$FIX" | awk 'NR==2 {print $4}'; }

# ---------------------------------------------------------------- 1. build
note "building release CLI"
(cd "$REPO" && swift build -c release --product twinfold 2>&1 | tail -n 3)
TF="$REPO/.build/release/twinfold"
[[ -x "$TF" ]] || { echo "build failed: $TF missing"; exit 1; }

# ---------------------------------------------------------------- 2. fixture
note "creating fixture in $FIX"
mkdir -p "$FIX"
# The fixture gets its own APFS volume, so free-space checks aren't thrown off by other apps writing to the boot disk.
hdiutil create -quiet -size 2g -fs APFS -volname twinfold-e2e-fixture -type SPARSE "$WORK/fixture.sparseimage"
hdiutil attach -quiet -nobrowse -mountpoint "$FIX" "$WORK/fixture.sparseimage"
T gen "$FIX" "$META"
sync; sleep 2
EXPECTED="$(python3 -c "import json;print(json.load(open('$META'))['expected_with_exclude'])")"
EXCL="$(python3 -c "import json;print(json.load(open('$META'))['exclude_dir'])")"
FOLDS="$(python3 -c "import json;print(json.load(open('$META'))['folds'])")"

# ---------------------------------------------------------------- 3. before state
T snap "$FIX" "$WORK/before.json"
FREE0="$(free_kb)"

# ---------------------------------------------------------------- 4. scan
note "scan"
"$TF" scan --json --exclude "$EXCL" "$FIX" > "$WORK/scan1.json"
check "scan: reclaimable within 1% of design, no trap in groups" T scanchk "$WORK/scan1.json" "$META" expected_with_exclude no

# ---------------------------------------------------------------- 5. dry run
note "dry run"
JBEFORE="$(ls "$JOURNAL_DIR" 2>/dev/null | sort || true)"
"$TF" reclaim --dry-run --exclude "$EXCL" "$FIX" > /dev/null
T snap "$FIX" "$WORK/dry.json" > /dev/null
check "dry-run: hashes, mtimes, inodes unchanged" T cmp "$WORK/before.json" "$WORK/dry.json" all "$META"
JAFTER="$(ls "$JOURNAL_DIR" 2>/dev/null | sort || true)"
if [[ "$JBEFORE" == "$JAFTER" ]]; then record PASS "dry-run: no journal written" ""; else record FAIL "dry-run: no journal written" "journal dir changed"; fi

# ---------------------------------------------------------------- 6. reclaim
note "reclaim"
sync; sleep 1
FREE1="$(free_kb)"
"$TF" reclaim --yes --exclude "$EXCL" "$FIX" > "$WORK/reclaim.out" 2>&1 || record FAIL "reclaim exits 0" "$(tail -n 5 "$WORK/reclaim.out")"
sync; sleep 2
FREE2="$(free_kb)"
JAFTER="$(ls "$JOURNAL_DIR" 2>/dev/null | sort || true)"
JOURNAL=""
while IFS= read -r f; do
  [[ -n "$f" ]] && ! grep -qxF "$f" <<<"$JBEFORE" && { JOURNAL="$JOURNAL_DIR/$f"; NEW_JOURNALS+=("$JOURNAL"); }
done <<<"$JAFTER"
T snap "$FIX" "$WORK/after.json" > /dev/null

check "reclaim: sha/size/mtime/mode/xattrs/flags identical, traps untouched (same inode)" T cmp "$WORK/before.json" "$WORK/after.json" traps "$META"
N="$(T inodes "$WORK/before.json" "$WORK/after.json" | tail -n 1)"
if [[ "$N" == "$FOLDS" ]]; then record PASS "reclaim: exactly $FOLDS files folded (inode changed)" ""; else record FAIL "reclaim: exactly $FOLDS files folded (inode changed)" "inodes changed: $N"; fi
GAIN=$(( (FREE2 - FREE1) * 1024 ))
if (( GAIN * 100 >= EXPECTED * 90 )); then record PASS "reclaim: free space grew >= 90% of expected" "gained $((GAIN/1048576)) MB of $((EXPECTED/1048576)) MB"
else record FAIL "reclaim: free space grew >= 90% of expected" "gained $((GAIN/1048576)) MB of expected $((EXPECTED/1048576)) MB (df before $FREE1 KB, after $FREE2 KB)"; fi

# locked / hardlink / symlink explicit checks
LOCKED="$FIX/traps/t1_locked.bin"
if ls -lO "$LOCKED" | grep -q uchg; then record PASS "trap: locked file still locked" ""; else record FAIL "trap: locked file still locked" "uchg flag gone"; fi
if [[ "$(stat -f %i "$FIX/traps/hl_a.bin")" == "$(stat -f %i "$FIX/traps/hl_b.bin")" && "$(stat -f %l "$FIX/traps/hl_a.bin")" == 2 ]]; then
  record PASS "trap: hard-linked pair still linked" ""; else record FAIL "trap: hard-linked pair still linked" "inode/link count differ"; fi
if [[ -L "$FIX/photos/link.jpg" && "$(readlink "$FIX/photos/link.jpg")" == "$FIX/photos/IMG_1.jpg" ]]; then
  record PASS "trap: symlink intact" ""; else record FAIL "trap: symlink intact" "symlink changed"; fi

# the folded modules still work
if command -v node >/dev/null 2>&1; then
  ok=1; for p in $(python3 -c "import json;print(' '.join(json.load(open('$META'))['projects']))"); do
    [[ "$(node -e "console.log(require('$p/node_modules/pkg')())" 2>&1)" == "twinfold-ok" ]] || ok=0
  done
  if (( ok )); then record PASS "node: require() works in every project" ""; else record FAIL "node: require() works in every project" "require failed"; fi
else
  echo "NOTICE: node not found, skipping node require() checks"; record PASS "node: require() (skipped, node missing)" ""
fi
ok=1; for p in $(python3 -c "import json;print(' '.join(json.load(open('$META'))['pycopies']))"); do
  [[ "$(PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$p" python3 -c "import mypkg;print(mypkg.hello())" 2>&1)" == "twinfold-ok" ]] || ok=0
done
if (( ok )); then record PASS "python: import mypkg works from every copy" ""; else record FAIL "python: import mypkg works from every copy" "import failed"; fi

"$TF" scan --json --exclude "$EXCL" "$FIX" > "$WORK/scan2.json"
check "rescan: 0 reclaimable outside excluded folder" T scanchk "$WORK/scan2.json" "$META" 0 no
"$TF" scan --json "$FIX" > "$WORK/scan2b.json"
check "rescan without --exclude: only the excluded copy (t3) reclaimable" T scanchk "$WORK/scan2b.json" "$META" t3_size yes

# ---------------------------------------------------------------- 7. copy on write
note "copy-on-write"
check "copy-on-write: appending to a folded copy leaves its twins unchanged" T cow "$META" "$WORK/before.json"

# ---------------------------------------------------------------- 8. undo
note "undo"
if [[ -z "$JOURNAL" ]]; then
  record FAIL "undo: journal found" "no new journal file in $JOURNAL_DIR"
else
  grep -F -q "undo" "$WORK/reclaim.out" && record PASS "reclaim prints the undo command" "" || record FAIL "reclaim prints the undo command" "$(tail -n 3 "$WORK/reclaim.out")"
  "$TF" undo --yes "$JOURNAL" > "$WORK/undo.out" 2>&1 || record FAIL "undo exits 0" "$(tail -n 3 "$WORK/undo.out")"
  T snap "$FIX" "$WORK/undone.json" > /dev/null
  check "undo: contents, mtimes, modes, xattrs identical to before" T cmp "$WORK/before.json" "$WORK/undone.json" traps "$META"
  "$TF" scan --json --exclude "$EXCL" "$FIX" > "$WORK/scan3.json"
  check "undo: space reclaimable again" T scanchk "$WORK/scan3.json" "$META" expected_with_exclude no
  rm -f "$JOURNAL"
  if [[ ! -e "$JOURNAL" ]]; then record PASS "journal file removed" ""; else record FAIL "journal file removed" "$JOURNAL"; fi
fi

# ---------------------------------------------------------------- 8b. two volumes
# Clones can't cross volumes: identical files on different volumes must never be paired.
note "two volumes"
VOL="$WORK/vol"
mkdir -p "$VOL" "$WORK/xv"
if hdiutil create -quiet -size 64m -fs APFS -volname twinfold-e2e -type SPARSE "$WORK/xv.sparseimage" &&
   hdiutil attach -quiet -nobrowse -mountpoint "$VOL" "$WORK/xv.sparseimage"; then
  head -c 2000000 /dev/urandom > "$WORK/xv/same.bin"
  cp "$WORK/xv/same.bin" "$VOL/same.bin"
  cp "$WORK/xv/same.bin" "$VOL/same-2.bin"
  "$TF" scan --json --min-size 1K "$WORK/xv" "$VOL" > "$WORK/xv.json"
  XGROUPS=$(python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(";".join(",".join(sorted(p.rsplit("/",2)[-2]+"/"+p.rsplit("/",1)[-1] for c in g["clusters"] for p in c)) for g in r["groups"]))' "$WORK/xv.json")
  if [[ "$XGROUPS" == "vol/same-2.bin,vol/same.bin" ]]; then
    record PASS "two volumes: only same-volume twins are paired" ""
  else
    record FAIL "two volumes: only same-volume twins are paired" "$XGROUPS"
  fi
  "$TF" reclaim --yes --min-size 1K "$WORK/xv" "$VOL" > "$WORK/xv.out" 2>&1
  if cmp -s "$WORK/xv/same.bin" "$VOL/same.bin" && cmp -s "$VOL/same.bin" "$VOL/same-2.bin" &&
     [[ "$("$TF" scan --json --min-size 1K "$WORK/xv" "$VOL" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["reclaimableBytes"])')" == 0 ]]; then
    record PASS "two volumes: fold within the second volume works, contents intact" ""
  else
    record FAIL "two volumes: fold within the second volume works, contents intact" "$(tail -n 3 "$WORK/xv.out")"
  fi
  hdiutil detach -quiet "$VOL" || hdiutil detach -quiet -force "$VOL"
  [[ "$(ls "$JOURNAL_DIR" | wc -l | tr -d ' ')" -ge 1 ]] && record PASS "journals go to the test's own support folder" "" ||
    record FAIL "journals go to the test's own support folder" "$(ls "$JOURNAL_DIR")"
else
  record FAIL "two volumes: create and attach a test APFS image" ""
fi

# ---------------------------------------------------------------- 8c. undo with little free space
# Undo un-shares data. On a nearly full disk it must stop before filling it, keep the rest, and finish later.
note "undo on a nearly full disk"
VOL2="$WORK/vol2"
mkdir -p "$VOL2"
if hdiutil create -quiet -size 100m -fs APFS -volname twinfold-e2e-full -type SPARSE "$WORK/full.sparseimage" &&
   hdiutil attach -quiet -nobrowse -mountpoint "$VOL2" "$WORK/full.sparseimage"; then
  head -c 12000000 /dev/urandom > "$VOL2/a.bin"; cp "$VOL2/a.bin" "$VOL2/b.bin"; cp "$VOL2/a.bin" "$VOL2/c.bin"
  "$TF" reclaim --yes --min-size 1K "$VOL2" > /dev/null 2>&1
  J2=$(ls -t "$JOURNAL_DIR"/*.jsonl | head -1)
  # Leave room for one 12 MB copy plus the 2 MB reserve, not two.
  FREE=$(df -k "$VOL2" | awk 'NR==2 {print $4 * 1024}')
  dd if=/dev/zero of="$VOL2/filler" bs=1m count=$(( (FREE - 23000000) / 1048576 )) 2>/dev/null
  TWINFOLD_UNDO_RESERVE=2MB "$TF" undo --yes "$J2" > "$WORK/undo2.out" 2>&1
  if grep -q "Stopped to keep free space" "$WORK/undo2.out" && [[ "$(wc -l < "$J2" | tr -d ' ')" == 1 ]] && cmp -s "$VOL2/a.bin" "$VOL2/c.bin"; then
    record PASS "undo on a full disk: stops in time, keeps the rest in the journal" ""
  else
    record FAIL "undo on a full disk: stops in time, keeps the rest in the journal" "$(tr '\n' ' ' < "$WORK/undo2.out")"
  fi
  rm -f "$VOL2/filler"
  TWINFOLD_UNDO_RESERVE=2MB "$TF" undo --yes "$J2" > "$WORK/undo3.out" 2>&1
  if [[ ! -e "$J2" ]] && cmp -s "$VOL2/a.bin" "$VOL2/b.bin" && cmp -s "$VOL2/a.bin" "$VOL2/c.bin" &&
     [[ "$("$TF" scan --json --min-size 1K "$VOL2" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["reclaimableBytes"])')" == 24000000 ]]; then
    record PASS "undo on a full disk: finishes after space is freed" ""
  else
    record FAIL "undo on a full disk: finishes after space is freed" "$(tr '\n' ' ' < "$WORK/undo3.out")"
  fi
  hdiutil detach -quiet "$VOL2" || hdiutil detach -quiet -force "$VOL2"
else
  record FAIL "undo on a full disk: create and attach a test APFS image" ""
fi

# ---------------------------------------------------------------- 9. report
echo
printf '%-6s  %-78s  %s\n' RESULT CHECK DETAIL
printf '%-6s  %-78s  %s\n' ------ ---------------------------------------------------------------------------- ------
for r in "${RESULTS[@]}"; do
  IFS='|' read -r s n d <<<"$r"
  printf '%-6s  %-78s  %s\n' "$s" "$n" "$d"
done
echo
echo "$FAILS failed, $((${#RESULTS[@]} - FAILS)) passed, $((SECONDS - START))s"
(( FAILS == 0 ))
