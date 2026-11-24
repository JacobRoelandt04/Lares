#!/usr/bin/env python3
"""The WORLD of tools/dev/aerial_integration_probe.sh: a fake NetworkManager + BlueZ (tools/aerial/fake_nm.py) on a private bus, a local
HTTP stub for the check URL, stub files the stub `iw` / `ping` read, and the Proton glue (the stub protonvpn changes its own state
file; this makes NetworkManager follow it the way the real CLI does: the killswitch dummy, then the tunnel).

  aerial_integration_world.py --dir <W> --root <repo or sandbox copy>

The QML probe drives it by APPENDING one JSON object per line to <W>/control.jsonl and reads the answers from <W>/answers.jsonl:
  {"n": 7, "fake": {op: ...}}          a control command of the fake (answered with its JSON; a BlueZ agent question answers when it is
                                       answered, in a thread)
  {"n": 8, "http": "online|portal|down"}   what the check URL says
  {"n": 9, "write": "stub/iw_station.txt", "text": "..."}   a file under <W> (never outside it); {"rm": "stub/pingfail"} removes one
  {"n": 10, "rss": true}               the helper's resident set (kB), found by the AERIAL_PROBE=<W> mark in its environment
It prints `READY` and writes <W>/ready.json {bus, port}. Nothing here reaches the machine's bus or the internet.
"""
import os, sys, json, time, threading, subprocess, socket, signal, http.server, urllib.parse

a = sys.argv[1:]
W = a[a.index("--dir") + 1]
ROOT = a[a.index("--root") + 1]
FAKE = os.path.join(ROOT, "tools", "aerial", "fake_nm.py")
FIX = os.path.join(ROOT, "modules", "aerial", "data", "fixtures")
MODE = {"check": "online"}


class Stub(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        if u.path == "/nm-check.txt":
            m = MODE["check"]
            if m == "online":
                return self.reply(200, b"NetworkManager is online\n", {"Content-Type": "text/plain"})
            if m == "portal":
                return self.reply(302, b"", {"Location": "http://127.0.0.1:%d/login" % self.server.server_port})
            return self.reply(500, b"nope", {})
        if u.path == "/login":
            return self.reply(200, b"<html>please log in</html>", {"Content-Type": "text/html"})
        self.reply(404, b"", {})

    def reply(self, code, body, headers):
        try:
            self.send_response(code)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


def under(rel):
    p = os.path.normpath(os.path.join(W, rel))
    if not p.startswith(os.path.join(W, "")):
        raise ValueError("outside the world: " + rel)
    return p


for d in ("fk", "stub", "leases", "rfkill/rfkill0"):
    os.makedirs(os.path.join(W, d), exist_ok=True)
open(os.path.join(W, "rfkill/rfkill0/type"), "w").write("bluetooth\n")
open(os.path.join(W, "rfkill/rfkill0/hard"), "w").write("0\n")
for f in ("control.jsonl", "answers.jsonl"):
    open(os.path.join(W, f), "w").close()

# the scenario: the capture's, the card's driver version and firmware added
with open(os.path.join(FIX, "scenario.json")) as f:
    scen = json.load(f)
for d in scen["devices"]:
    if d["iface"] == "wlp47s0":
        d["driverVersion"] = "7.3.4-arch1-2"
        d["firmware"] = "89.7f2a5b3e.0 ty-a0-gf-a0-89.ucode"
# NetworkManager's policy: after a DeactivateConnection it autoconnects another saved network (the test bed's fourth run showed it);
# the module's "disconnect" must use the device's Disconnect, which blocks that
scen.setdefault("policy", {})["autoconnect"] = True
json.dump(scen, open(os.path.join(W, "scenario.json"), "w"))

fake = subprocess.Popen([sys.executable, "-I", FAKE, "serve", "--dir", os.path.join(W, "fk"), "--scenario", os.path.join(W, "scenario.json")],
                        stdout=subprocess.PIPE, stderr=open(os.path.join(W, "fake.err"), "w"), text=True, start_new_session=True)
line = fake.stdout.readline()
if not line.startswith("READY "):
    sys.exit("the fake NetworkManager did not start: %r" % line)
BUS = line.split(" ", 1)[1].strip()
srv = Server(("127.0.0.1", 0), Stub)
threading.Thread(target=srv.serve_forever, daemon=True).start()
json.dump({"bus": BUS, "port": srv.server_port}, open(os.path.join(W, "ready.json"), "w"))
print("READY", flush=True)

LOCK = threading.Lock()


def answer(n, obj):
    with LOCK:
        with open(os.path.join(W, "answers.jsonl"), "a") as f:
            f.write(json.dumps({"n": n, "a": obj}) + "\n")


def ctl(msg):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(120)
    s.connect(os.path.join(W, "fk", "ctl.sock"))
    s.sendall(json.dumps(msg).encode() + b"\n")
    buf = b""
    while b"\n" not in buf:
        x = s.recv(65536)
        if not x:
            break
        buf += x
    s.close()
    return json.loads(buf.decode())


def helper_rss():
    for p in os.listdir("/proc"):
        if not p.isdigit():
            continue
        try:
            env = open("/proc/%s/environ" % p, "rb").read().split(b"\0")
            cmd = open("/proc/%s/cmdline" % p, "rb").read()
            if (b"AERIAL_PROBE=" + W.encode()) in env and b"aerial-helper" in cmd and b"python" in cmd:
                for l in open("/proc/%s/status" % p):
                    if l.startswith("VmRSS:"):
                        return int(l.split()[1])
        except Exception:
            pass
    return -1


def handle(m):
    n = m.get("n")
    try:
        if "fake" in m:
            if m["fake"].get("op") in ("bt_request", "bt_cancel"):
                threading.Thread(target=lambda: answer(n, ctl(m["fake"])), daemon=True).start()
                return
            return answer(n, ctl(m["fake"]))
        if "http" in m:
            MODE["check"] = m["http"]
            return answer(n, {"ok": True})
        if "write" in m:
            p = under(m["write"])
            os.makedirs(os.path.dirname(p), exist_ok=True)
            open(p, "w").write(m.get("text", ""))
            return answer(n, {"ok": True})
        if "rm" in m:
            try:
                os.unlink(under(m["rm"]))
            except FileNotFoundError:
                pass
            return answer(n, {"ok": True})
        if "rss" in m:
            return answer(n, {"kb": helper_rss()})
        answer(n, {"ok": False, "error": "unknown"})
    except Exception as e:
        answer(n, {"ok": False, "error": "%s: %s" % (type(e).__name__, e)})


stop = {"v": False}
signal.signal(signal.SIGTERM, lambda *_: stop.update(v=True))
signal.signal(signal.SIGINT, lambda *_: stop.update(v=True))
off = 0
proton_was = False
state_path = os.path.join(W, "stub", "state.json")
while not stop["v"]:
    time.sleep(0.03)
    try:
        with open(os.path.join(W, "control.jsonl"), "rb") as f:
            f.seek(off)
            data = f.read()
        if data and data.endswith(b"\n"):
            off += len(data)
            for ln in data.decode().splitlines():
                if ln.strip():
                    handle(json.loads(ln))
    except Exception as e:
        sys.stderr.write("control: %s\n" % e)
    # NetworkManager follows the stub protonvpn's state file
    try:
        now = bool(json.load(open(state_path)).get("connected"))
    except Exception:
        now = proton_was
    if now != proton_was:
        proton_was = now
        try:
            ctl({"op": "proton_up", "name": "NL#799", "device": "proton0"} if now else {"op": "proton_down"})
        except Exception as e:
            sys.stderr.write("proton glue: %s\n" % e)
try:
    ctl({"op": "quit"})
except Exception:
    pass
try:
    fake.wait(5)
except Exception:
    fake.kill()
