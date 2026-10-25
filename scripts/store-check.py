#!/usr/bin/env python3
"""Checks the live store matches what the app expects, so a sale can't go out without a key again.

    DODO_API_KEY=... python3 -I scripts/store-check.py [--test]

Reads only (GET requests). Checks:
  - the product the app sells (Store.productID in Licensing.swift) exists, is one-time, and costs Store.price
  - it has a License Key entitlement: never expires, 3 activations (what the app and site promise)
  - every successful payment for it has a license key (catches buyers left without one)
  - the public activation endpoint answers 404 for an unknown key (what the app's error handling expects)
The API key is read from the environment and never printed.
"""
import json, os, re, sys, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
mode = "test" if "--test" in sys.argv else "live"
base = f"https://{mode}.dodopayments.com"
src = open(os.path.join(ROOT, "Sources/TwinfoldCore/Licensing.swift")).read()
product = re.search(rf'\.{mode}: "(pdt_\w+)"', src).group(1)
price_cents = int(float(re.search(r'price = "\$([\d.]+)"', src).group(1)) * 100)
key = os.environ.get("DODO_API_KEY")
if not key:
    sys.exit("Set DODO_API_KEY (Dodo dashboard → Developer → API keys) and run again.")

fails = 0
def check(name, ok, detail=""):
    global fails
    print(("PASS  " if ok else "FAIL  ") + name + (f" ({detail})" if detail and not ok else ""))
    fails += 0 if ok else 1

def get(path):
    req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {key}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)

def items(path):
    out, page = [], 0
    while True:
        sep = "&" if "?" in path else "?"
        batch = get(f"{path}{sep}page_size=100&page_number={page}").get("items", [])
        out += batch
        if len(batch) < 100:
            return out
        page += 1

print(f"{mode} store, product {product}")
p = get(f"/products/{product}")
check("product is one-time, not a subscription", p.get("is_recurring") is False)
price = (p.get("price") or {}).get("price")
check(f"price is {price_cents / 100:.2f}", price == price_cents, f"store has {price}")
lk = [e for e in p.get("entitlements", []) if e.get("integration_type") == "license_key"]
check("has a License Key entitlement (keys are emailed after payment)", len(lk) == 1, f"{len(lk)} found")
if lk:
    cfg = lk[0].get("integration_config") or {}
    check("license keys allow 3 activations", cfg.get("activations_limit") == 3, f"config {cfg}")
    check("license keys never expire", not cfg.get("duration_count") and not cfg.get("expires_at"), f"config {cfg}")

try:
    all_pays = items("/payments?status=succeeded")
    if any("product_cart" not in x for x in all_pays):
        raise LookupError("payments don't list their products, so this check can't tell which are Twinfold's")
    pays = [x for x in all_pays if any(c.get("product_id") == product for c in x["product_cart"] or [])]
    keys = items(f"/license_keys?product_id={product}")
    customers_with_keys = {k.get("customer_id") for k in keys}
    missing = [x.get("payment_id") for x in pays if (x.get("customer") or {}).get("customer_id") not in customers_with_keys]
    check(f"every paid order has a key ({len(pays)} paid, {len(keys)} keys)", not missing, f"no key for {missing}")
except urllib.error.HTTPError as e:
    check("list payments and keys", False, f"HTTP {e.code}")
except LookupError as e:
    check("every paid order has a key", False, str(e))

req = urllib.request.Request(base + "/licenses/activate", method="POST",
                             data=json.dumps({"license_key": "store-check-unknown", "name": "store-check"}).encode(),
                             headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=30); code = 200
except urllib.error.HTTPError as e:
    code = e.code
check("unknown keys are rejected with 404", code == 404, f"got {code}")

print("store check: all passed" if not fails else f"store check: {fails} failed")
sys.exit(1 if fails else 0)
