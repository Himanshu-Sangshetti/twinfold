#!/usr/bin/env python3
"""Safety suite: tries hard to make Twinfold lose or change data, and proves it doesn't.

Runs on its own throwaway APFS disk image. For every scenario it records each file's SHA-256 and full metadata
(mode, owner, group, flags, created/modified/added dates, ACL, every extended attribute) before, and checks
them after. "Folded" is proven by the files' data sitting at the same physical place on disk.

    python3 -I scripts/safety-e2e.py
"""
import hashlib, json, os, random, shutil, signal, subprocess, sys, tempfile, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.realpath(tempfile.mkdtemp(prefix="twinfold-safety."))
VOL = os.path.join(WORK, "vol")
SUPPORT = os.path.join(WORK, "support")
ENV = dict(os.environ, TWINFOLD_SUPPORT_DIR=SUPPORT, TWINFOLD_QUIET_SECONDS="0")
results = []


def sh(*cmd, env=ENV, check=True):
    p = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if check and p.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} failed: {p.stdout}{p.stderr}")
    return p.stdout


def check(name, ok, detail=""):
    results.append((bool(ok), name, detail))
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def meta(*paths):
    out = sh(META, *paths)
    return dict(rec.split("\t", 1) for rec in out.split("\0") if rec)


def phys(path):
    subprocess.run(["sync"])
    return int(sh(META, "-p", path).split("\t")[1])


def shared(a, b):
    return phys(a) == phys(b)


def write(path, data, old=True):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    if old:  # look like a file that has sat there a while
        t = time.time() - 86400 * 30
        os.utime(path, (t, t))


def twin(src, dst):
    """A separate, unshared copy, as a person's second download would be."""
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    st = os.stat(src)
    os.utime(dst, (st.st_atime, st.st_mtime))


def snapshot(root):
    """SHA-256 and metadata of every file under root."""
    files = {}
    for d, _, names in os.walk(root):
        for n in names:
            p = os.path.join(d, n)
            if not os.path.islink(p) and not n.startswith(".twinfold-"):
                files[p] = sha(p)
    return files


def reclaim(path, env=ENV):
    """Saves under path; returns {file: reason} for every file it did not fold."""
    out = sh(TF, "reclaim", "--yes", "--json", "--min-size", "64K", path, env=env)
    try:
        return {r["path"]: r.get("reason") for r in json.loads(out) if r.get("outcome") != "folded"}
    except ValueError:
        return {}


def rand(n):
    return random.randbytes(n)


def setup():
    sh("hdiutil", "create", "-quiet", "-size", "3g", "-fs", "APFS", "-type", "SPARSE", "-volname", "TFSafety",
       os.path.join(WORK, "img"))
    os.makedirs(VOL)
    sh("hdiutil", "attach", "-quiet", "-nobrowse", "-mountpoint", VOL, os.path.join(WORK, "img.sparseimage"))


def cleanup():
    subprocess.run(["chflags", "-R", "nouchg", WORK], capture_output=True)
    subprocess.run(["chmod", "-R", "u+w", WORK], capture_output=True)
    subprocess.run(["hdiutil", "detach", "-quiet", "-force", VOL], capture_output=True)
    shutil.rmtree(WORK, ignore_errors=True)


# ---------------------------------------------------------------- scenarios

def metadata_is_kept():
    d = f"{VOL}/meta"
    keeper, copy = f"{d}/a/report.pdf", f"{d}/b/report.pdf"
    write(keeper, rand(3_000_000))
    twin(keeper, copy)
    os.chmod(copy, 0o640)
    sh("xattr", "-w", "com.apple.metadata:_kMDItemUserTags", "Red\n6", copy)
    sh("xattr", "-w", "com.apple.metadata:kMDItemFinderComment", "signed copy", copy)
    sh("xattr", "-w", "com.apple.quarantine", "0081;5f000000;Safari;", copy)
    sh("xattr", "-wx", "com.apple.ResourceFork", "00010203", copy)
    sh("xattr", "-w", "user.custom", "keep me", copy)
    sh("chmod", "+a", "everyone allow read,readattr", copy)
    sh("chflags", "hidden", copy)
    if 12 in os.getgroups():
        os.chown(copy, -1, 12)  # the "everyone" group, different from the keeper's
    t = time.time() - 86400 * 900
    os.utime(copy, (t, t))  # also moves the creation date back
    before, keeper_before, h = meta(copy)[copy], meta(keeper)[keeper], sha(copy)
    left = reclaim(d)
    check("metadata: copy now shares storage with its twin", shared(keeper, copy), str(left))
    after = meta(copy)[copy]
    check("metadata: mode, group, flags, ACL, dates, tags, comment, quarantine, resource fork kept",
          after == before, f"\n  before {before}\n  after  {after}")
    check("metadata: the twin that stays is untouched", meta(keeper)[keeper] == keeper_before)
    check("metadata: contents identical", sha(copy) == h)


def protected_files_are_left_alone():
    d = f"{VOL}/protected"
    src = f"{d}/src.bin"
    write(src, rand(500_000))
    twin(src, f"{d}/hard.bin")
    os.link(f"{d}/hard.bin", f"{d}/hard-link.bin")
    twin(src, f"{d}/locked.bin")
    sh("chflags", "uchg", f"{d}/locked.bin")
    # Disk images mount with permissions ignored, so this one lives on the boot disk.
    ro = os.path.join(WORK, "boot-disk")
    write(f"{ro}/keeper.bin", rand(500_000))
    twin(f"{ro}/keeper.bin", f"{ro}/readonly/in-locked-folder.bin")
    os.chmod(f"{ro}/readonly", 0o555)
    os.symlink(f"{d}/locked.bin", f"{d}/link-to-locked")
    snap = snapshot(d)
    reclaim(d)
    check("hard-linked file is not folded (both names keep one shared inode)",
          not shared(src, f"{d}/hard.bin") and os.stat(f"{d}/hard.bin").st_nlink == 2)
    check("locked (uchg) file is not folded", not shared(src, f"{d}/locked.bin"))
    ro_before = sha(f"{ro}/readonly/in-locked-folder.bin")
    reclaim(ro)
    check("file in a read-only folder is not folded and is intact",
          not shared(f"{ro}/keeper.bin", f"{ro}/readonly/in-locked-folder.bin")
          and sha(f"{ro}/readonly/in-locked-folder.bin") == ro_before)
    check("symlink is still a symlink", os.path.islink(f"{d}/link-to-locked"))
    check("protected: every file byte for byte the same", snapshot(d) == snap)
    os.chmod(f"{ro}/readonly", 0o755)
    dd = f"{ro}/deny-delete.bin"
    twin(f"{ro}/keeper.bin", dd)
    sh("chmod", "+a", "everyone deny delete", dd)
    h, inode, m = sha(dd), os.stat(dd).st_ino, meta(dd)[dd]
    reclaim(ro)
    check("file with a 'deny delete' ACL is never replaced (same file, bytes, ACL)",
          os.stat(dd).st_ino == inode and sha(dd) == h and meta(dd)[dd] == m)
    sh("chmod", "-N", dd)


def files_in_use_are_left_alone():
    d = f"{VOL}/inuse"
    src = f"{d}/a.db"
    write(src, rand(800_000))
    twin(src, f"{d}/writing.db")
    twin(src, f"{d}/reading.db")
    # One program holds writing.db open for writing and writes to it after the fold would have happened.
    writer = subprocess.Popen([sys.executable, "-I", "-c", (
        "import sys,time\n"
        "f=open(sys.argv[1],'r+b'); print('open',flush=True); time.sleep(6)\n"
        "f.seek(1000); f.write(b'WRITTEN-LATER'); f.close()"), f"{d}/writing.db"], stdout=subprocess.PIPE, text=True)
    reader = subprocess.Popen([sys.executable, "-I", "-c", (
        "import sys,time\n"
        "f=open(sys.argv[1],'rb'); print('open',flush=True); time.sleep(6)"), f"{d}/reading.db"], stdout=subprocess.PIPE, text=True)
    writer.stdout.readline(); reader.stdout.readline()
    reclaim(d)
    writer.wait(); reader.wait()
    check("file open for writing in another app is not folded", not shared(src, f"{d}/writing.db"))
    with open(f"{d}/writing.db", "rb") as f:
        f.seek(1000)
        check("that app's later write is in the file (nothing lost)", f.read(13) == b"WRITTEN-LATER")
    check("file only open for reading is folded", shared(src, f"{d}/reading.db"))
    check("reading file's contents identical", sha(f"{d}/reading.db") == sha(src))


def recent_files_wait():
    d = f"{VOL}/recent"
    write(f"{d}/a.mov", rand(400_000), old=False)
    twin(f"{d}/a.mov", f"{d}/b.mov")
    os.utime(f"{d}/b.mov", None)  # just modified
    env = dict(ENV)
    env.pop("TWINFOLD_QUIET_SECONDS")
    reclaim(d, env=env)
    check("file changed in the last 5 minutes is not folded by default", not shared(f"{d}/a.mov", f"{d}/b.mov"))


def changes_after_scan_win():
    """The app and agents save from an earlier scan. Anything that changed since must be left as the person left it."""
    d = f"{VOL}/racing"
    for name in ["edited", "keeper-edited", "deleted", "fine"]:
        write(f"{d}/{name}/one.bin", rand(300_000))
        twin(f"{d}/{name}/one.bin", f"{d}/{name}/two.bin")
    mcp = subprocess.Popen([TF, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=ENV)

    def call(i, name, args):
        mcp.stdin.write(json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                                    "params": {"name": name, "arguments": args}}) + "\n")
        mcp.stdin.flush()
        return json.loads(mcp.stdout.readline())["result"]["content"][0]["text"]

    call(1, "scan", {"paths": [d]})
    # Between the scan and Save: one copy is edited, one keeper is edited, one copy is deleted.
    for p in [f"{d}/edited/two.bin", f"{d}/keeper-edited/one.bin"]:
        with open(p, "r+b") as f:
            f.seek(5); f.write(b"NEW")
    os.remove(f"{d}/deleted/two.bin")
    edited, keeper_edited = sha(f"{d}/edited/two.bin"), sha(f"{d}/keeper-edited/one.bin")
    call(2, "save", {"confirm": True})
    mcp.stdin.close(); mcp.wait()
    check("copy edited after the scan keeps the edit", sha(f"{d}/edited/two.bin") == edited)
    check("twin edited after the scan keeps the edit", sha(f"{d}/keeper-edited/one.bin") == keeper_edited)
    check("edited files were not folded", not shared(f"{d}/edited/one.bin", f"{d}/edited/two.bin")
          and not shared(f"{d}/keeper-edited/one.bin", f"{d}/keeper-edited/two.bin"))
    check("file deleted after the scan stays deleted (not recreated)", not os.path.exists(f"{d}/deleted/two.bin"))
    check("unchanged pair is folded", shared(f"{d}/fine/one.bin", f"{d}/fine/two.bin"))


def edits_and_deletes_after_folding():
    """What people do next: edit one copy, delete one, delete the original."""
    d = f"{VOL}/after"
    base = rand(2_000_000)
    for n in ["a", "b", "c", "d"]:
        write(f"{d}/{n}.psd", base)
    reclaim(d)
    check("four copies share storage", all(shared(f"{d}/a.psd", f"{d}/{n}.psd") for n in "bcd"))
    h = hashlib.sha256(base).hexdigest()
    sh("dd", "if=/dev/urandom", f"of={d}/b.psd", "bs=4096", "seek=10", "count=3", "conv=notrunc")
    with open(f"{d}/c.psd", "ab") as f:
        f.write(b"appended")
    check("editing one copy in place leaves the others unchanged", sha(f"{d}/a.psd") == h and sha(f"{d}/d.psd") == h)
    check("the edited copy has the edit", sha(f"{d}/b.psd") != h and os.path.getsize(f"{d}/c.psd") == len(base) + 8)
    os.remove(f"{d}/a.psd")  # the one the others were cloned from
    check("deleting the original keeps the copies whole", sha(f"{d}/d.psd") == h)
    os.remove(f"{d}/d.psd")
    check("deleting more copies never touches the rest", sha(f"{d}/b.psd") != h and os.path.getsize(f"{d}/c.psd") == len(base) + 8)


def odd_names_and_sizes():
    d = f"{VOL}/odd"
    names = ["résumé final 📄.pdf", "line\nbreak.txt", "  spaces  .bin", "x" * 240 + ".bin", "コピー.mov", "-dash.bin"]
    data = rand(200_000)
    for n in names:
        write(f"{d}/one/{n}", data)
        write(f"{d}/two/{n}", data)
    write(f"{d}/one/empty", b""); write(f"{d}/two/empty", b"")
    write(f"{d}/one/small", b"s" * 1000); write(f"{d}/two/small", b"s" * 1000)
    big = rand(300_000_000)
    write(f"{d}/one/big.mkv", big); write(f"{d}/two/big.mkv", big)
    snap = snapshot(d)
    reclaim(d)
    check("unicode, emoji, newline, long and dash names fold", all(shared(f"{d}/one/{n}", f"{d}/two/{n}") for n in names))
    check("300 MB file folds", shared(f"{d}/one/big.mkv", f"{d}/two/big.mkv"))
    check("files under the minimum size are not touched", not shared(f"{d}/one/small", f"{d}/two/small"))
    check("odd names: every file byte for byte the same", snapshot(d) == snap)


def crash_mid_save():
    d = f"{VOL}/crash"
    for i in range(300):
        data = rand(400_000)
        write(f"{d}/one/{i}.bin", data)
        write(f"{d}/two/{i}.bin", data)
    snap, before = snapshot(d), {p: meta(p)[p] for p in snapshot(d)}
    jd = f"{SUPPORT}/journal"
    journal_lines_before = sum(open(os.path.join(jd, j)).read().count("\n") for j in os.listdir(jd)) if os.path.isdir(jd) else 0
    p = subprocess.Popen([TF, "reclaim", "--yes", d], env=ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    journal_dir = f"{SUPPORT}/journal"
    deadline = time.time() + 30
    while time.time() < deadline:
        lines = sum(open(os.path.join(journal_dir, j)).read().count("\n") for j in os.listdir(journal_dir)) \
            if os.path.isdir(journal_dir) else 0
        if lines - journal_lines_before >= 40:
            break
        time.sleep(0.005)
    p.send_signal(signal.SIGKILL); p.wait()
    folded = sum(shared(f"{d}/one/{i}.bin", f"{d}/two/{i}.bin") for i in range(300))
    check("crash: killed partway (some folded, some not)", 0 < folded < 300, f"{folded} folded")
    now = snapshot(d)
    check("crash: every file present and byte for byte the same", now == snap,
          str([p for p in set(now) | set(snap) if now.get(p) != snap.get(p)][:3]))
    check("crash: every file's metadata the same", {q: meta(q)[q] for q in snap} == before)
    reclaim(d)
    leftovers = [n for n in os.listdir(f"{d}/two") + os.listdir(f"{d}/one") if n.startswith(".twinfold-")]
    check("crash: next run cleans up and finishes", not leftovers and
          all(shared(f"{d}/one/{i}.bin", f"{d}/two/{i}.bin") for i in range(300)), f"leftovers {leftovers}")


def undo_restores_everything():
    files = snapshot(VOL)
    metas = {p: meta(p)[p] for p in files}
    for j in sorted(os.listdir(f"{SUPPORT}/journal")):
        sh(TF, "undo", f"{SUPPORT}/journal/{j}")
    check("undo: every file byte for byte the same", snapshot(VOL) == files)
    check("undo: every file's metadata the same", {p: meta(p)[p] for p in files} == metas)
    d = f"{VOL}/odd"
    check("undo: copies have their own storage again", not shared(f"{d}/one/big.mkv", f"{d}/two/big.mkv"))
    remaining = [n for n in os.listdir(f"{SUPPORT}/journal") if os.path.getsize(f"{SUPPORT}/journal/{n}") > 0]
    check("undo: history has nothing left to undo", not remaining, str(remaining))


def nothing_left_behind():
    stray = [os.path.join(dp, n) for dp, _, ns in os.walk(VOL) for n in ns if n.startswith(".twinfold-")]
    check("no temporary files left anywhere", not stray, str(stray[:3]))


if __name__ == "__main__":
    try:
        sh("swift", "build", "-c", "release", "--product", "twinfold", env=os.environ)
        TF = os.path.join(REPO, ".build/release/twinfold")
        META = os.path.join(WORK, "meta")
        sh("clang", "-O2", os.path.join(REPO, "scripts/tools/meta.c"), "-o", META)
        setup()
        random.seed(7)
        for scenario in [metadata_is_kept, protected_files_are_left_alone, files_in_use_are_left_alone,
                         recent_files_wait, changes_after_scan_win, edits_and_deletes_after_folding,
                         odd_names_and_sizes, crash_mid_save, undo_restores_everything, nothing_left_behind]:
            print(f"== {scenario.__name__}")
            try:
                scenario()
            except Exception as e:
                check(f"{scenario.__name__} ran", False, repr(e))
    finally:
        cleanup()
    failed = [r for r in results if not r[0]]
    print(f"\n{len(results) - len(failed)}/{len(results)} safety checks passed")
    sys.exit(1 if failed else 0)
