#!/usr/bin/env python3
"""Drives the REAL tools/launcher/answers.py over its pipe: every case of launcher_answers_cases.tsv in one process, the
app-name fixture (all []), ids, ping, a pending currency reply and its update against a local server, a stale id,
a stale cache, an offline start, malformed lines, EOF.  Prints timings and ends with one LAUNCHER_ANSWERS RESULT line.
Usage: launcher_answers_probe.py <answers.py> (the runner gives a copy for an ARM)."""
import sys, os, json, time, subprocess, threading, tempfile, shutil, statistics, http.server, socketserver, queue

HERE = os.path.dirname(os.path.abspath(__file__))
ANSWERS = os.path.abspath(sys.argv[1])
FIX = os.path.join(HERE, "fixtures")
NOW = "2026-11-19T12:00:00Z"
fails = []


def fail(msg):
    fails.append(msg)
    print("FAIL " + msg, flush=True)


class Server:
    def __init__(self, delay):
        self.delay, self.hits = delay, 0
        outer = self
        body = open(os.path.join(FIX, "launcher_ecb_daily.xml"), "rb").read()

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                outer.hits += 1
                outer.ua = self.headers.get("User-Agent", "")
                time.sleep(outer.delay)
                self.send_response(200)
                self.send_header("Content-Type", "text/xml")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass
        self.httpd = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.port}/eurofxref-daily.xml"
        self.ua = ""

    def stop(self):
        self.httpd.shutdown()


class Child:
    def __init__(self, cache, url, extra=None, args=()):
        env = dict(os.environ)
        env.update({"LARES_ANSWERS_NOW": NOW, "LARES_ANSWERS_TZ": "Europe/Brussels", "XDG_CACHE_HOME": cache,
                    "LARES_ECB_URL": url, "LARES_HOME_CURRENCY": "EUR", "TZ": "Europe/Brussels"})
        env.update(extra or {})
        self.t0 = time.time()
        self.p = subprocess.Popen([sys.executable, "-I", ANSWERS] + list(args), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=env)
        self.q = queue.Queue()
        self.stdout_lines = []
        threading.Thread(target=self._rd, daemon=True).start()
        self.err = []
        threading.Thread(target=lambda: [self.err.append(l) for l in self.p.stderr], daemon=True).start()

    def _rd(self):
        for line in self.p.stdout:
            self.stdout_lines.append(line)
            try:
                self.q.put((time.time(), json.loads(line)))
            except ValueError:
                self.q.put((time.time(), {"__garbage__": line}))

    def send_raw(self, b):
        self.p.stdin.write(b)
        self.p.stdin.flush()

    def send(self, obj):
        self.send_raw((json.dumps(obj, ensure_ascii=False) + "\n").encode())

    def get(self, timeout=5):
        try:
            return self.q.get(timeout=timeout)
        except queue.Empty:
            return None

    def ask(self, i, q, timeout=5):
        self.send({"id": i, "q": q})
        r = self.get(timeout)
        return r

    def close(self):
        try:
            self.p.stdin.close()
        except Exception:
            pass
        try:
            return self.p.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.p.kill()
            return None


def structural(q, rep):
    """The contract's shape on every reply."""
    if "answers" not in rep:
        return f"{q!r}: no answers key"
    ans = rep["answers"]
    if len(ans) > 3:
        return f"{q!r}: more than 3 answers"
    kinds = {"math", "currency", "base", "time", "unit", "date", "zone", "colour", "percent", "ratio", "resolution"}
    for a in ans:
        for k in ("kind", "value", "copy", "expr", "detail", "alts", "pending"):
            if k not in a:
                return f"{q!r}: missing {k}"
        if a["kind"] not in kinds:
            return f"{q!r}: kind {a['kind']}"
        if " " in a["copy"]:
            return f"{q!r}: grouped copy {a['copy']!r}"
        if len(a["alts"]) > 3:
            return f"{q!r}: {len(a['alts'])} alts"
        for al in a["alts"]:
            if not all(k in al for k in ("label", "value", "copy")) or " " in al["copy"]:
                return f"{q!r}: bad alt {al}"
        if ("swatch" in a) != (a["kind"] == "colour"):
            return f"{q!r}: swatch on {a['kind']}"
        if a["kind"] != "currency" and a["pending"]:
            return f"{q!r}: pending outside currency"
    return None


def load_cases():
    out = []
    for n, line in enumerate(open(os.path.join(HERE, "launcher_answers_cases.tsv"), encoding="utf-8"), 1):
        if line.startswith("#") or not line.strip():
            continue
        c = line.rstrip("\n").split("\t")
        if len(c) != 4:
            fail(f"cases line {n}: {len(c)} columns")
            continue
        out.append((n, c[0], c[1], c[2].replace("\\u202f", " "), c[3]))
    return out


def main():
    tmp = tempfile.mkdtemp(prefix="lans-")
    try:
        run(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("LAUNCHER_ANSWERS RESULT " + ("PASS" if not fails else f"FAIL ({len(fails)} failed; first: {fails[0][:150]})"))
    sys.exit(0 if not fails else 1)


def run(tmp):
    # ---- A: protocol, pending / update, stale id, stale cache (a 2 s freshness so the test can age the rates)
    cache = os.path.join(tmp, "cacheA")
    srv = Server(0.5)
    c = Child(cache, srv.url, {"LARES_ECB_STALE_S": "2"})
    c.send({"id": 1, "cmd": "ping"})
    r = c.get()
    start_ms = (r[0] - c.t0) * 1000 if r else None
    if not r or r[1] != {"id": 1, "pong": True}:
        fail(f"ping: {r}")
    print(f"start to first reply: {start_ms:.0f} ms (process start included)", flush=True)
    # stale id: a currency query (pending), then a newer plain one; the update of the old id must not come
    t, rep = c.ask(2, "100 usd in eur")
    a = rep["answers"][0] if rep.get("answers") else {}
    if not (rep.get("id") == 2 and a.get("pending") is True and a.get("value") == "…"):
        fail(f"first currency reply should be pending with no cache: {rep}")
    t, rep = c.ask(3, "2+2")
    if rep.get("id") != 3 or rep["answers"][0]["value"] != "4":
        fail(f"newer plain query: {rep}")
    extra = c.get(1.5)
    if extra is not None:
        fail(f"an update for a stale id arrived: {extra[1]}")
    if not os.path.exists(os.path.join(cache, "lares", "launcher", "ecb-rates.json")):
        fail("no cache file after the fetch")
    if srv.hits != 1 or "lares-launcher/0.1" not in srv.ua:
        fail(f"fetch count {srv.hits}, user agent {srv.ua!r}")
    # fresh: no pending, no second fetch
    t, rep = c.ask(4, "100 usd in eur")
    a = rep["answers"][0]
    if a["pending"] or a["value"] != "90.98 EUR" or srv.hits != 1:
        fail(f"fresh rates answer: {a} hits={srv.hits}")
    if "ECB 2026-11-19" not in a["detail"]:
        fail(f"detail names no ECB date: {a['detail']!r}")
    # aged: pending WITH the cached value, then the same id again with the fresh one
    time.sleep(2.3)
    t, rep = c.ask(5, "100 usd in eur")
    a = rep["answers"][0]
    if not (a["pending"] and a["value"] == "90.98 EUR"):
        fail(f"aged rates should answer pending with the cached value: {a}")
    u = c.get(5)
    if not u or u[1].get("id") != 5 or u[1]["answers"][0]["pending"] or u[1]["answers"][0]["value"] != "90.98 EUR":
        fail(f"update for the aged query: {u}")
    elif u[0] - t < 0.3:
        fail("the update came before the fetch could have ended")
    if srv.hits != 2:
        fail(f"fetches after ageing: {srv.hits}")
    # junk lines never break the pipe or reach stdout as text
    c.send_raw(b"not json\n")
    c.send_raw(b"[1,2]\n")
    c.send_raw(b'{"id": 9}\n')
    c.send_raw(b'{"id": 10, "q": 5}\n')
    r9, r10 = c.get(), c.get()
    if not r9 or r9[1].get("id") != 9 or r9[1].get("answers") != []:
        fail(f"request with no q: {r9}")
    if not r10 or r10[1].get("answers") != []:
        fail(f"request with a non-string q: {r10}")
    c.send({"id": 11, "cmd": "ping"})
    r = c.get()
    if not r or r[1] != {"id": 11, "pong": True}:
        fail(f"ping after junk: {r}")
    if any("__garbage__" in x[1] for x in [r9, r10] if x):
        fail("garbage on stdout")
    code = c.close()
    if code != 0:
        fail(f"EOF did not end the child cleanly: {code}")
    srv.stop()

    # ---- C: offline, no cache
    c = Child(os.path.join(tmp, "cacheC"), "file:///nonexistent/ecb.xml")
    t, rep = c.ask(1, "100 usd in eur")
    a = rep["answers"][0]
    if not a["pending"]:
        fail(f"offline first reply should be pending: {a}")
    u = c.get(5)
    if not u or u[1]["id"] != 1 or u[1]["answers"][0]["pending"] or "unavailable" not in u[1]["answers"][0]["value"]:
        fail(f"offline update: {u}")
    t, rep = c.ask(2, "100 usd in eur")
    if rep["answers"][0]["pending"] or "unavailable" not in rep["answers"][0]["value"]:
        fail(f"offline second query: {rep}")
    if not c.err:
        fail("offline fetch said nothing on stderr")
    c.close()

    # ---- B: every case in one process, the cache A left behind is fresh
    cases = load_cases()
    c = Child(os.path.join(tmp, "cacheA"), "file:///nonexistent/ecb.xml")
    c.send({"id": 99, "cmd": "ping"})
    c.get()
    lat = []
    nid = 100
    ok = 0
    for n, q, kind, val, cp in cases:
        nid += 1
        t0 = time.time()
        r = c.ask(nid, q)
        dt_ms = (time.time() - t0) * 1000
        if r is None:
            fail(f"case line {n} {q!r}: no reply")
            continue
        rep = r[1]
        if rep.get("id") != nid:
            fail(f"case line {n} {q!r}: id {rep.get('id')} for {nid}")
            continue
        lat.append(dt_ms)
        bad = structural(q, rep)
        if bad:
            fail(f"case line {n}: {bad}")
            continue
        ans = rep["answers"]
        if kind == "none":
            if ans:
                fail(f"case line {n} {q!r}: expected no answer, got {ans[0]['kind']} {ans[0]['value']!r}")
                continue
        else:
            if not ans:
                fail(f"case line {n} {q!r}: expected {kind} {val!r}, got no answer")
                continue
            a = ans[0]
            if a["kind"] != kind or (val != "-" and a["value"] != val) or (cp != "-" and a["copy"] != cp):
                fail(f"case line {n} {q!r}: expected {kind} {val!r} {cp!r}, got {a['kind']} {a['value']!r} {a['copy']!r}")
                continue
            if a["pending"]:
                fail(f"case line {n} {q!r}: pending with fresh rates")
                continue
        ok += 1
    print(f"cases: {ok}/{len(cases)} ok", flush=True)
    # app names: every line answers []
    names = [l.rstrip("\n") for l in open(os.path.join(FIX, "launcher_app_names.txt"), encoding="utf-8") if l.strip()]
    napp = 0
    for nm in names:
        nid += 1
        r = c.ask(nid, nm)
        if r is None or r[1].get("answers") != []:
            fail(f"app name {nm!r} answered: {r[1] if r else None}")
        napp += 1
    print(f"app names: {napp} checked", flush=True)
    # odd input
    for q in ("", " ", "x" * 5000, "(" * 3000 + "1" + ")" * 3000, "9" * 5000 + "!", "2^" * 400 + "2", "\u0000", "😀 + 1"):
        nid += 1
        r = c.ask(nid, q)
        if r is None or r[1].get("answers") != []:
            fail(f"odd input {q[:20]!r}...: {r[1] if r else 'no reply'}")
    # timing: the plain queries again, warm
    qs = [q for (_, q, k, _, _) in cases if k not in ("none", "currency")]
    warm = []
    for q in qs:
        nid += 1
        t0 = time.time()
        r = c.ask(nid, q)
        warm.append((time.time() - t0) * 1000)
    warm.sort()
    med, p95, mx = statistics.median(warm), warm[int(len(warm) * 0.95)], warm[-1]
    first = max(lat[:20])
    print(f"per query warm ({len(warm)} answered queries, pipe round trip): median {med:.2f} ms, p95 {p95:.2f} ms, max {mx:.2f} ms; "
          f"slowest of the first 20 (cold regex / tables) {first:.1f} ms", flush=True)
    if med > 5:
        fail(f"median {med:.2f} ms over 5 ms")
    if p95 > 20:
        fail(f"p95 {p95:.2f} ms over 20 ms")
    if mx > 60:
        fail(f"slowest query {mx:.1f} ms over 60 ms")
    if start_ms is not None and start_ms > 250:
        fail(f"start {start_ms:.0f} ms over 250 ms (budget 150 ms of the child itself)")
    bad = [l for l in c.stdout_lines if not l.endswith(b"\n")]
    if bad:
        fail("stdout line without newline")
    c.close()
    if c.err:
        fail(f"stderr on a clean run: {c.err[:1]}")

    # ---- D: the options (launcher.jsonc "answers"), on the rates A left
    def one(args, q):
        ch = Child(os.path.join(tmp, "cacheA"), "file:///nonexistent/ecb.xml", args=args)
        r = ch.ask(1, q)
        ch.close()
        a = r[1]["answers"] if r else None
        return (a[0]["value"], [x["label"] for x in a[0]["alts"]]) if a else a
    for args, q, want in (
            ((), "20 eur", ("USD", ["GBP", "JPY"])),
            (("--home-currency", "USD"), "20 usd", ("EUR", ["GBP", "JPY"])),
            (("--home-currency", "USD"), "20 gbp", ("USD", ["EUR", "JPY"])),
            (("--home-currency", "EUR", "--currencies", "jpy,chf"), "20 eur", ("JPY", ["CHF"])),
            (("--currencies", ""), "20 gbp", ("EUR", []))):
        got = one(args, q)
        if not got or not got[0].endswith(" " + want[0]) or got[1] != want[1]:
            fail(f"options {args} {q!r}: wanted {want}, got {got}")
    for kinds, q, answered in (("math,unit", "5 ft in cm", True), ("math", "5 ft in cm", False), ("currency", "2+2", False), ("nonsense", "2+2", False), ("", "2+2", False)):
        got = one(("--kinds", kinds), q)
        if bool(got) != answered:
            fail(f"options --kinds {kinds!r} {q!r}: {got}")


main()
