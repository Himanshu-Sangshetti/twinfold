#!/usr/bin/env python3 -I
"""End-to-end test of `twinfold mcp`: drives the server over JSON-RPC like an agent would, on a temp fixture."""
import hashlib, json, os, subprocess, sys, tempfile

repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
subprocess.run(["swift", "build", "--product", "twinfold"], cwd=repo, check=True, capture_output=True)
binary = os.path.join(subprocess.run(["swift", "build", "--show-bin-path"], cwd=repo, capture_output=True,
                                     text=True, check=True).stdout.strip(), "twinfold")
tmp = os.path.realpath(tempfile.mkdtemp(prefix="twinfold-mcp."))
fix = os.path.join(tmp, "fixture")
data = os.urandom(5_000_000)
for rel in ["a/model.bin", "b/model.bin", "c/model.bin"]:
    os.makedirs(os.path.dirname(os.path.join(fix, rel)), exist_ok=True)
    open(os.path.join(fix, rel), "wb").write(data)
def hashes():
    return {r: hashlib.sha256(open(os.path.join(fix, r), "rb").read()).hexdigest() for r in ["a/model.bin", "b/model.bin", "c/model.bin"]}
before = hashes()

env = dict(os.environ, TWINFOLD_SUPPORT_DIR=os.path.join(tmp, "support"))
server = subprocess.Popen([binary, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
next_id = 0
def rpc(method, params=None):
    global next_id
    next_id += 1
    server.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next_id, "method": method, "params": params or {}}) + "\n")
    server.stdin.flush()
    return json.loads(server.stdout.readline())
def tool(name, **args):
    r = rpc("tools/call", {"name": name, "arguments": args})["result"]
    return r["content"][0]["text"], r.get("isError", False)

fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS  " if ok else "FAIL  ") + name + ("" if ok else f"  ({detail})"))
    fails += 0 if ok else 1

init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e", "version": "1"}})
check("initialize names the server", init["result"]["serverInfo"]["name"] == "twinfold", init)
server.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); server.stdin.flush()
names = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
check("tools/list has all 7 tools", names == ["scan", "list_sets", "show_set", "check_set", "save", "history", "undo"], names)
text, err = tool("list_sets")
check("tools before a scan ask for a scan", err and "scan first" in text, text)
text, _ = tool("scan", paths=[fix], min_size="1K")
check("scan reports 10 MB to save and changes nothing", text.startswith("10.0 MB could be saved") and hashes() == before, text)
text, _ = tool("list_sets", query="model")
check("list_sets finds the set with id 0", "[0] model.bin: 3×" in text, text)
text, _ = tool("show_set", id=0)
check("show_set lists all 3 paths", text.count("model.bin") >= 4 and "stored 3 times" in text, text)
text, _ = tool("check_set", id=0)
check("check_set reads the files live", "All 3 files are in place" in text and "Stored 3 separate times" in text, text)
text, _ = tool("save")
check("save without confirm is a dry run", text.startswith("Dry run") and hashes() == before, text)
text, _ = tool("save", confirm=True)
check("save with confirm shares storage and keeps contents", text.startswith("Saved") and hashes() == before, text)
run_id = text.rsplit("run id ", 1)[-1].rstrip(".")
text, _ = tool("scan", paths=[fix], min_size="1K")
check("after save nothing is left to save", text.startswith("0 bytes could be saved"), text)
text, _ = tool("history")
check("history lists the run", run_id in text and "2 files" in text, text)
text, _ = tool("undo", run=run_id)
check("undo without confirm only describes it", "confirm: true" in text, text)
text, _ = tool("undo", run=run_id, confirm=True)
check("undo with confirm restores separate copies", text.startswith("2 files have their own copy again") and hashes() == before, text)
text, _ = tool("scan", paths=[fix], min_size="1K")
check("after undo the 10 MB is separate again", text.startswith("10.0 MB could be saved"), text)

server.stdin.close(); server.wait(timeout=10)
subprocess.run(["rm", "-rf", tmp])
print(f"\nmcp e2e: {'all checks passed' if fails == 0 else f'{fails} failed'}")
sys.exit(1 if fails else 0)
