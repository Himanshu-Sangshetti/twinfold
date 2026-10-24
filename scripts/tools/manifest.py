#!/usr/bin/env python3
"""Fingerprints every file in a scan, then proves a save or undo changed none of them.

    manifest.py record SCAN.json MANIFEST.jsonl     # before: SHA-256 + full metadata of every file in every set
    manifest.py verify MANIFEST.jsonl [REPORT.json]  # after: re-reads every file and compares

A file counts as changed by Twinfold only if its bytes or metadata differ while its modification time is the same
(Twinfold never changes modification times). Files whose modification time moved were changed by another app
in between, and are listed separately. Needs scripts/tools/meta.c compiled to META (env) or ./meta.
"""
import hashlib, json, os, subprocess, sys
from concurrent.futures import ProcessPoolExecutor

META = os.environ.get("META", os.path.join(os.path.dirname(os.path.abspath(__file__)), "meta"))


def sha(path):
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(4 << 20), b""):
                h.update(chunk)
    except OSError as e:
        return f"error:{e.errno}"
    return h.hexdigest()


def meta_of(paths):
    out = subprocess.run([META, *paths], capture_output=True).stdout.decode("utf-8", "surrogateescape")
    return dict(r.split("\t", 1) for r in out.split("\0") if "\t" in r)


def phys_of(paths):
    out = subprocess.run([META, "-p", *paths], capture_output=True).stdout.decode("utf-8", "surrogateescape")
    return {l.rsplit("\t", 1)[0]: int(l.rsplit("\t", 1)[1]) for l in out.splitlines() if "\t" in l}


def fingerprint(batch):
    metas, physs = meta_of(batch), phys_of(batch)
    rows = []
    for p in batch:
        try:
            st = os.lstat(p)
            mtime = st.st_mtime_ns
        except OSError:
            rows.append({"path": p, "missing": True})
            continue
        rows.append({"path": p, "sha": sha(p), "mtime": mtime, "size": st.st_size, "inode": st.st_ino,
                     "meta": metas.get(p), "phys": physs.get(p)})
    return rows


def batches(paths, n=64):
    for i in range(0, len(paths), n):
        yield paths[i:i + n]


def run(paths):
    with ProcessPoolExecutor(max_workers=os.cpu_count()) as pool:
        for rows in pool.map(fingerprint, batches(paths)):
            yield from rows


def record(scan, out):
    groups = json.load(open(scan))["groups"]
    with open(out, "w") as f:
        for gi, g in enumerate(groups):
            for path in (p for cluster in g["clusters"] for p in cluster):
                f.write(json.dumps({"group": gi, "path": path}) + "\n")
    entries = [json.loads(l) for l in open(out)]
    group_of = {e["path"]: e["group"] for e in entries}
    with open(out, "w") as f:
        for row in run([e["path"] for e in entries]):
            row["group"] = group_of[row["path"]]
            f.write(json.dumps(row) + "\n")
    print(f"recorded {len(entries)} files in {len(groups)} sets")


def verify(manifest, report_path=None):
    before = {r["path"]: r for r in map(json.loads, open(manifest))}
    after = {r["path"]: r for r in run(list(before))}
    bug, by_app, missing, unreadable = [], [], [], []
    for p, b in before.items():
        a = after[p]
        if b.get("missing") or str(b.get("sha", "")).startswith("error"):
            unreadable.append(p)
            continue
        if a.get("missing"):
            missing.append(p)
            continue
        if a["mtime"] != b["mtime"]:
            by_app.append(p)
        elif a["sha"] != b["sha"] or a["meta"] != b["meta"] or a["size"] != b["size"]:
            bug.append({"path": p, "sha": a["sha"] == b["sha"], "before": b["meta"], "after": a["meta"]})
    groups = {}
    for p, a in after.items():
        if not a.get("missing") and a.get("phys") is not None:
            groups.setdefault(before[p]["group"], []).append(a)
    stored_before = sum(len({r["phys"] for r in rows}) for rows in
                        [[before[p] for p in before if before[p]["group"] == g and before[p].get("phys") is not None]
                         for g in groups])
    stored_after = sum(len({r["phys"] for r in rows}) for rows in groups.values())
    report = {"files": len(before), "unchanged": len(before) - len(bug) - len(by_app) - len(missing) - len(unreadable),
              "changed_by_twinfold": bug, "changed_by_other_apps": by_app, "missing": missing,
              "unreadable_before": unreadable, "stored_copies_before": stored_before, "stored_copies_after": stored_after}
    if report_path:
        json.dump(report, open(report_path, "w"), indent=1)
    print(json.dumps({k: (len(v) if isinstance(v, list) else v) for k, v in report.items()}))
    return 1 if bug else 0


if __name__ == "__main__":
    if sys.argv[1] == "record":
        record(sys.argv[2], sys.argv[3])
    else:
        sys.exit(verify(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None))
