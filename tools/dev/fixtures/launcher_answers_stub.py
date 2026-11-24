#!/usr/bin/env python3
"""Stand-in for tools/launcher/answers.py: canned replies per the answers-child contract
(docs R13-PLAN "Contract: the answers child"). JSON lines on stdin / stdout, exits on EOF.

Queries it knows (case-insensitive, trimmed): the table CANNED below, one per kind. Special cases:
  "100 usd in eur"  -> a pending answer now, the final one STUB_DELAY_MS later (default 350) with the SAME id
  "slow"            -> a reply after STUB_SLOW_MS (default 600) -- a reply that goes stale when typing goes on
  "qzxslow"         -> an EMPTY reply after STUB_SLOW_MS (no answer, and the list under it matches no app)
  "boom"            -> exits 3 (a dying child: the service restarts it)
  anything else     -> {"answers": []}
STUB_LOG, when set, gets one line per request ("ask <id> <q>") so a probe can count the asks.
"""
import json, os, sys, threading, time

def a(kind, value, copy, expr, detail="", alts=None, swatch=None, pending=False):
    d = {"kind": kind, "value": value, "copy": copy, "expr": expr, "detail": detail, "alts": alts or [], "pending": pending}
    if swatch:
        d["swatch"] = swatch
    return d

CANNED = {
    "2+2": [a("math", "4", "4", "2 + 2")],
    "12345678901234567890 * 98765432109876543210 * 3": [a("math", "3 657 407 405 904 076 579 056 349 062 138 774 570 038 700", "3657407405904076579056349062138774570038700", "12345678901234567890 × 98765432109876543210 × 3", "a very long figure that must elide in its slot")],
    "0xff": [a("base", "255", "255", "0xFF", "hex → decimal", [{"label": "bin", "value": "0b1111 1111", "copy": "0b11111111"}, {"label": "oct", "value": "0o377", "copy": "0o377"}])],
    "9:30 + 1h45": [a("time", "11:15", "11:15", "09:30 + 1 h 45 min", "")],
    "5 mi in km": [a("unit", "8.047 km", "8.047", "5 mi → km", "1 mi = 1.609 km")],
    "days until 2027-01-01": [a("date", "43 days", "43", "until Fri 1 Jan 2027", "Thursday 19 Nov 2026 → Friday 1 Jan 2027")],
    "time in tokyo": [a("zone", "Fri 02:15", "02:15", "Tokyo (JST, UTC+9)", "17 h ahead of Brussels")],
    "#4480f4": [a("colour", "#4480F4", "#4480f4", "#4480f4", "", [{"label": "rgb", "value": "rgb(68 128 244)", "copy": "rgb(68, 128, 244)"}, {"label": "hsl", "value": "hsl(220 89% 61%)", "copy": "hsl(220, 89%, 61%)"}], "#4480f4")],
    "15% of 80": [a("percent", "12", "12", "15 % of 80")],
    "16:9 to 1080": [a("ratio", "1920 × 1080", "1920x1080", "16 : 9 at 1080 high")],
    "4k": [a("resolution", "3840 × 2160", "3840x2160", "4K UHD", "16 : 9 · 8.3 MP", [{"label": "w×h", "value": "3840 x 2160", "copy": "3840 x 2160"}, {"label": "ratio", "value": "16:9", "copy": "16:9"}, {"label": "mp", "value": "8.3 MP", "copy": "8.3"}])],
}
FINAL = a("currency", "92.31 EUR", "92.31", "100 USD → EUR", "ECB 2026-11-18 · 1 USD = 0.9231 EUR")
PENDING = a("currency", "92.31 EUR", "92.31", "100 USD → EUR", "fetching rates ...", pending=True)

lock = threading.Lock()
def out(obj):
    with lock:
        sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
        sys.stdout.flush()

def log(s):
    p = os.environ.get("STUB_LOG")
    if p:
        with open(p, "a") as f:
            f.write(s + "\n")

def later(ms, obj):
    def run():
        time.sleep(ms / 1000.0)
        out(obj)
    threading.Thread(target=run, daemon=True).start()

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        req = json.loads(raw)
    except ValueError:
        sys.stderr.write("stub: bad json\n")
        continue
    rid = req.get("id")
    if req.get("cmd") == "ping":
        out({"id": rid, "pong": True})
        continue
    q = str(req.get("q", "")).strip().lower()
    log("ask %s %s" % (rid, q))
    if q == "boom":
        sys.exit(3)
    if q == "100 usd in eur":
        out({"id": rid, "answers": [PENDING]})
        later(int(os.environ.get("STUB_DELAY_MS", "350")), {"id": rid, "answers": [FINAL]})
    elif q == "qzxslow":
        later(int(os.environ.get("STUB_SLOW_MS", "600")), {"id": rid, "answers": []})
    elif q == "slow":
        later(int(os.environ.get("STUB_SLOW_MS", "600")), {"id": rid, "answers": [a("math", "slow", "slow", "slow")]})
    else:
        out({"id": rid, "answers": CANNED.get(q, [])})
