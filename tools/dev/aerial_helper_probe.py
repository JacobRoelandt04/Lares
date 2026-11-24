#!/usr/bin/env python3
"""The REAL tools/aerial/aerial-helper against a FAKE WORLD. Run by tools/dev/aerial_helper_probe.sh (never by hand: the runner
builds the world's PATH, env and the armed tree). Env: W (work dir), TREE (the tree whose tools/aerial is under test), ROOT.

The world: tools/aerial/fake_nm.py (a private dbus-daemon, a fake NetworkManager and a fake BlueZ AgentManager), a stub `protonvpn`
replaying the captured outputs, stub `ping` / `iw`, and a local HTTP server standing for the check URL and Cloudflare's speed
endpoints. Nothing here reaches the machine's bus or the internet. Prints `  ok <check>` / `  FAIL <check>: <why>` and, last,
`AERIAL_HELPER RESULT PASS|FAIL`.
"""
import os, sys, json, time, threading, subprocess, socket, signal, re, importlib.machinery, importlib.util, http.server, urllib.parse

W = os.environ["W"]
TREE = os.environ["TREE"]
ROOT = os.environ["ROOT"]
FIX = os.path.join(ROOT, "modules", "aerial", "data", "fixtures")
HELPER = os.path.join(TREE, "tools", "aerial", "aerial-helper")
FAKE = os.path.join(ROOT, "tools", "aerial", "fake_nm.py")
STUBDIR = os.environ["AERIAL_STUB_DIR"]
FAILS = []
INFO = []


def check(name, ok, why=""):
    if ok:
        print("  ok " + name, flush=True)
    else:
        FAILS.append(name)
        print("  FAIL %s%s" % (name, (": " + str(why)) if why else ""), flush=True)
    return ok


def info(text):
    INFO.append(text)
    print("  info " + text, flush=True)


# ---- the HTTP stub ---------------------------------------------------------------------------------------------------------------
class Stub(http.server.BaseHTTPRequestHandler):
    mode = {"check": "online", "delay_ms": 30, "server_ms": 25.0}
    requests = []
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urllib.parse.urlsplit(self.path)
        Stub.requests.append(("GET", u.path))
        if u.path == "/nm-check.txt":
            m = Stub.mode["check"]
            if m == "online":
                return self.reply(200, b"NetworkManager is online\n", {"Content-Type": "text/plain"})
            if m == "portal":
                return self.reply(302, b"", {"Location": "http://127.0.0.1:%d/login" % self.server.server_port})
            return self.reply(500, b"nope", {})
        if u.path == "/login":
            return self.reply(200, b"<html>please log in</html>", {"Content-Type": "text/html"})
        if u.path == "/__down":
            if Stub.mode.get("flaky"):
                Stub.mode["nflaky"] = Stub.mode.get("nflaky", 0) + 1
                if Stub.mode["nflaky"] % 4 == 0:
                    return self.reply(429, b"rate limited", {})
            n = int(urllib.parse.parse_qs(u.query).get("bytes", ["0"])[0])
            time.sleep(Stub.mode["delay_ms"] / 1000.0)
            return self.reply(200, b"\0" * n, {"Server-Timing": "cfL4;desc=\"?proto=TCP&rtt=1000\", cfSpeedWorker;dur=%s" % Stub.mode["server_ms"],
                                               "cf-ray": "8f3a2b1c4d5e6f70-BRU"})
        self.reply(404, b"", {})

    def do_POST(self):
        u = urllib.parse.urlsplit(self.path)
        Stub.requests.append(("POST", u.path))
        n = int(self.headers.get("Content-Length", "0"))
        got = 0
        while got < n:
            chunk = self.rfile.read(min(65536, n - got))
            if not chunk:
                break
            got += len(chunk)
        self.reply(200, b"", {"cf-ray": "8f3a2b1c4d5e6f70-BRU", "Server-Timing": "cfSpeedWorker;dur=1.0"})

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


# ---- the fake NetworkManager ------------------------------------------------------------------------------------------------------
class Fake:
    def __init__(self):
        self.dir = os.path.join(W, "fk")
        self.proc = subprocess.Popen([sys.executable, "-I", FAKE, "serve", "--dir", self.dir], stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(W, "fake.err"), "w"), text=True, start_new_session=True,
                                     env=dict(os.environ, FAKE_NM_PROBE=W))
        line = self.proc.stdout.readline()
        if not line.startswith("READY "):
            raise SystemExit("the fake NetworkManager did not start: %r (see %s)" % (line, os.path.join(W, "fake.err")))
        self.addr = line.split(" ", 1)[1].strip()

    def ctl(self, **msg):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(30)
        s.connect(os.path.join(self.dir, "ctl.sock"))
        s.sendall(json.dumps(msg).encode() + b"\n")
        buf = b""
        while b"\n" not in buf:
            x = s.recv(65536)
            if not x:
                break
            buf += x
        s.close()
        return json.loads(buf.decode())

    def ctl_async(self, **msg):
        """A control call whose answer takes a while (a BlueZ agent question): returns a list that fills with the answer."""
        out = []

        def run():
            try:
                out.append(self.ctl(**msg))
            except Exception as e:
                out.append({"ok": False, "error": "ctl: %s" % e})
        threading.Thread(target=run, daemon=True).start()
        return out

    def state(self):
        return self.ctl(op="state")["state"]

    def stop(self):
        try:
            self.ctl(op="quit")
        except Exception:
            pass
        try:
            self.proc.wait(5)
        except Exception:
            os.killpg(self.proc.pid, signal.SIGKILL)


# ---- the helper -----------------------------------------------------------------------------------------------------------------
class Helper:
    def __init__(self, fake, args=(), env=None, name="helper"):
        e = dict(os.environ)
        e.update(env or {})
        self.lines = []
        self.raw = []
        self.t0 = time.time()
        self.proc = subprocess.Popen([sys.executable, "-I", HELPER, "--bus-address", fake.addr] + list(args), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=open(os.path.join(W, name + ".err"), "w"), env=e,
                                     start_new_session=True)
        self.nid = 0
        self.lock = threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for raw in self.proc.stdout:
            now = time.time()
            try:
                obj = json.loads(raw.decode("utf-8"))
            except Exception:
                obj = {"t": "?garbage", "raw": raw[:80]}
            with self.lock:
                self.lines.append((now, obj))
                self.raw.append(raw.decode("utf-8", "replace"))

    def mark(self):
        with self.lock:
            return len(self.lines)

    def snapshot(self, since=0):
        with self.lock:
            return list(self.lines[since:])

    def evs(self, t, since=0):
        return [o for _, o in self.snapshot(since) if o.get("t") == t]

    def last(self, t, since=0):
        e = self.evs(t, since)
        return e[-1] if e else None

    def wait(self, pred, timeout=8.0, since=0):
        end = time.time() + timeout
        seen = since
        while time.time() < end:
            with self.lock:
                chunk = self.lines[seen:]
                seen = len(self.lines)
            for _, o in chunk:
                try:
                    if pred(o):
                        return o
                except Exception:
                    pass
            time.sleep(0.02)
        return None

    def send(self, cmd, **args):
        self.nid += 1
        msg = dict(args, id=self.nid, cmd=cmd)
        self.proc.stdin.write((json.dumps(msg) + "\n").encode())
        self.proc.stdin.flush()
        return self.nid

    def call(self, cmd, timeout=10.0, **args):
        i = self.send(cmd, **args)
        r = self.wait(lambda o: o.get("t") == "reply" and o.get("id") == i, timeout)
        return r

    def rss_kb(self):
        try:
            for l in open("/proc/%d/status" % self.proc.pid):
                if l.startswith("VmRSS:"):
                    return int(l.split()[1])
        except Exception:
            pass
        return -1

    def close(self):
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(5)
        except Exception:
            os.killpg(self.proc.pid, signal.SIGKILL)

    def alive(self):
        return self.proc.poll() is None


def load_helper_module():
    loader = importlib.machinery.SourceFileLoader("aerial_helper_mod", HELPER)
    spec = importlib.util.spec_from_loader("aerial_helper_mod", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def profile(h, id_):
    p = h.last("profiles")
    for x in (p or {}).get("v", []):
        if x["id"] == id_:
            return x
    return None


def uuid_of(h, id_):
    p = profile(h, id_)
    return p["uuid"] if p else None


def main():
    t_start = time.time()
    srv = Server(("127.0.0.1", 0), Stub)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = "http://127.0.0.1:%d" % port
    fake = Fake()
    cat_src = os.path.join(FIX, "serverlist_subset.json")
    try:
        run(fake, srv, port, base, cat_src)
    finally:
        fake.stop()
        srv.shutdown()
    print("AERIAL_HELPER RESULT %s" % ("PASS" if not FAILS else "FAIL (%d: %s)" % (len(FAILS), "; ".join(FAILS[:4]))), flush=True)
    return 0 if not FAILS else 1


SECRETS = ["fake-home-psk-1", "fake-cafe-psk", "fake-psk-07", "fake-printer-psk", "fake-hidden-psk", "fake-eap-pass", "fake-hotspot-psk",
           "fake-spot-psk", "fake-corp-eap", "fake-sae-psk", "wrong-psk-9"]


def keyring_cases(fake):
    """A helper of its own on a session bus (the private one) with a fake Secret Service whose `Locked` a case flips."""
    log = os.path.join(STUBDIR, "argv.log")
    world = os.path.join(W, "keyring.json")

    def locked(v):
        with open(world + ".new", "w") as f:
            json.dump({"keyring": {"locked": v}}, f)
        os.replace(world + ".new", world)

    def argvs(since):
        return [json.loads(l) for l in open(log)][since:]
    env = {"DBUS_SESSION_BUS_ADDRESS": fake.addr, "AERIAL_KEYRING_POLL_MS": "200"}
    h = Helper(fake, env=env, name="helperkr")
    h.wait(lambda o: o.get("t") == "hello", 5)
    r = h.call("proton", action="status")
    check("keyring: with no Secret Service on the bus the CLI is run as before", r and r["ok"] and h.last("keyring") is None, (r, h.last("keyring")))
    locked(True)
    svc = subprocess.Popen([sys.executable, "-I", os.path.join(ROOT, "tools/dev/stubs/bridge/fake_secretservice.py")], stdout=subprocess.PIPE, text=True,
                           start_new_session=True, env=dict(os.environ, DBUS_SESSION_BUS_ADDRESS=fake.addr, BRIDGE_PRIVATE_BUS="1", BRIDGE_WORLD=world))
    try:
        up = svc.stdout.readline().strip()
        check("keyring: the fake Secret Service is up", up == "secret-stub ready", up)
        m, n0 = h.mark(), len(argvs(0))
        r = h.call("proton", action="status")
        r2 = h.call("proton", action="config")
        time.sleep(0.9)
        ev = h.evs("keyring", m)
        check("keyring: locked, the shell's own reads run no CLI", argvs(n0) == [] and r and not r["ok"] and r2 and not r2["ok"], (argvs(n0), r, r2))
        check("keyring: the refusal's words are not a sign-in's", r and not re.search(r"sign|log ?in|logged|credential|authenticat", r["error"] or "", re.I), r)
        check("keyring: locked is said once however many reads are refused, and not taken back while it is", [e["locked"] for e in ev] == [True], ev)
        locked(False)
        e = h.wait(lambda o: o.get("t") == "keyring" and o["locked"] is False, 3, m)
        check("keyring: opened with no signal (as PAM does it), the helper says so by itself", e is not None, h.evs("keyring", m))
        check("keyring: the helper itself runs nothing then: the service asks", argvs(n0) == [], argvs(n0))
        r = h.call("proton", action="status")
        check("keyring: open, a read runs the CLI", r and r["ok"] and argvs(n0) == [["status"]], (r, argvs(n0)))
        time.sleep(0.7)
        check("keyring: an open keyring is not looked at again", len(h.evs("keyring", m)) == 2, h.evs("keyring", m))
        locked(True)
        m, n0 = h.mark(), len(argvs(0))
        r = h.call("proton", action="connect", args={"country": "NL"})
        check("keyring: locked, a connect the user clicked runs the CLI", r and r["ok"] and argvs(n0) == [["connect", "--country", "NL"]], (r, argvs(n0)))
        r = h.call("proton", action="disconnect")
        check("keyring: locked, so does a disconnect", r and r["ok"] and argvs(n0)[-1:] == [["disconnect"]], (r, argvs(n0)))
        r = h.call("proton", action="status")
        e = h.wait(lambda o: o.get("t") == "keyring" and o["locked"] is True, 3, m)
        check("keyring: locked again later, a read is refused and said again", r and not r["ok"] and e is not None, (r, e))
        os.kill(svc.pid, signal.SIGSTOP)
        t0 = time.time()
        r = h.call("proton", action="status", timeout=6)
        check("keyring: a service that does not answer is taken as locked, and nothing hangs", r and not r["ok"] and time.time() - t0 < 4.5, (r, time.time() - t0))
        os.kill(svc.pid, signal.SIGCONT)
    finally:
        os.killpg(svc.pid, signal.SIGKILL)
        svc.wait()
        h.close()


def run(fake, srv, port, base, cat_src):
    mod = load_helper_module()
    # -- the pure parsers, on the capture --------------------------------------------------------------------------------------
    iw = open(os.path.join(FIX, "iw_link.txt")).read()
    r = mod.parse_iw_link(iw)
    check("iw link of the capture: Wi-Fi 6, -58 dBm, rx 103.2 / tx 344.1", r["standard"] == "Wi-Fi 6" and r["dbm"] == -58 and
          r["rxMbps"] == 103.2 and r["txMbps"] == 344.1, r)
    check("iw link on 6 GHz is Wi-Fi 6E", mod.parse_iw_link(iw.replace("freq: 5220.0", "freq: 6115.0"))["standard"] == "Wi-Fi 6E")
    vht = re.sub(r"HE-MCS \d+ HE-NSS \d+ HE-GI \d+ HE-DCM \d+", "VHT-MCS 7 VHT-NSS 2 short GI", iw)
    ht = re.sub(r"HE-MCS \d+ HE-NSS \d+ HE-GI \d+ HE-DCM \d+", "MCS 15", iw)
    check("iw link: VHT is Wi-Fi 5, HT is Wi-Fi 4", mod.parse_iw_link(vht)["standard"] == "Wi-Fi 5" and mod.parse_iw_link(ht)["standard"] == "Wi-Fi 4")
    check("iw link: not connected gives no standard", mod.parse_iw_link("Not connected.\n")["standard"] == "")
    st = mod.parse_proton_status(open(os.path.join(FIX, "proton_status_securecore.txt")).read())
    check("proton status of a Secure Core server: name, city, via", st["server"] == {"name": "IS-BE#3", "city": "Brussels", "country": "",
                                                                                     "via": "Iceland"} and st["load"] == 63, st)
    st = mod.parse_proton_status(open(os.path.join(FIX, "proton_status_connected.txt")).read())
    check("proton status of the capture: NL#799 in Amsterdam, Netherlands, 48 %, wireguard",
          st["state"] == "connected" and st["server"]["name"] == "NL#799" and st["server"]["city"] == "Amsterdam" and
          st["server"]["country"] == "Netherlands" and st["load"] == 48 and st["protocol"] == "wireguard", st)
    cfg = mod.parse_proton_config(open(os.path.join(FIX, "proton_config.txt")).read())
    check("proton config table of the capture", cfg.get("netshield") == "malware-only" and cfg.get("kill-switch") == "off" and
          cfg.get("ipv6") == "on" and len(cfg) == 8, cfg)

    # -- start ------------------------------------------------------------------------------------------------------------------
    t0 = time.time()
    h = Helper(fake, ["--check-url", base + "/nm-check.txt"], env={"AERIAL_AGENT_TIMEOUT_MS": "1500", "AERIAL_PAD_RETRY_MS": "120"})
    first = h.wait(lambda o: True, 5)
    check("the first line is hello with v 1 and a pid", first and first.get("t") == "hello" and first.get("v") == 1 and first.get("pid") == h.proc.pid, first)
    w = h.wait(lambda o: o.get("t") == "wifi" and len(o.get("aps", [])) >= 10 and o.get("device") and o["device"].get("ip4"), 10)
    info("start to the first full wifi snapshot: %d ms" % int((time.time() - t0) * 1000))
    check("wifi snapshot arrives with the device, its addresses and the access points", w is not None)
    if w is None:
        h.close()
        return
    time.sleep(1.0)
    w = h.last("wifi")
    aps = w["aps"]
    ssids = sorted(a["ssid"] for a in aps)
    check("wifi: 10 access points, one hidden with an empty SSID", len(aps) == 10 and sum(1 for a in aps if a["ssid"] == "") == 1, ssids)
    home = [a for a in aps if a["ssid"] == "HomeNet-AP"]
    check("wifi: one SSID on two bands is two APs (2437 and 5220 MHz)", sorted(a["freq"] for a in home) == [2437, 5220], home)
    check("wifi: ssidHex is the SSID's bytes, flags are raw", home[0]["ssidHex"] == b"HomeNet-AP".hex() and home[0]["rsnFlags"] == 0x588, home[0])
    check("wifi: the device carries iface, MACs, driver, address, gateway, DNS", w["device"]["iface"] == "wlp47s0" and
          w["device"]["driver"] == "iwlwifi" and w["device"]["permHwAddress"] == "02:AE:00:00:00:06" and
          w["device"]["ip4"]["gateway"] == "192.0.2.1" and w["device"]["ip4"]["dns"] == ["198.51.100.5", "198.51.100.6"], w["device"])
    check("wifi: the active AP is the connected HomeNet-AP's BSSID", w["activeAp"] in [a["bssid"] for a in home], w["activeAp"])
    dv = h.last("devices")["v"]
    ifs = {d["iface"]: d for d in dv}
    check("devices: wifi, a wired jack without carrier, virtual ones included",
          {"wlp47s0", "enp46s0", "lo", "docker0", "p2p-dev-wlp47s0"} <= set(ifs) and ifs["enp46s0"]["carrier"] is False and
          ifs["enp46s0"]["state"] == "unavailable" and ifs["enp46s0"]["type"] == "ethernet" and ifs["wlp47s0"]["state"] == "activated", ifs.get("enp46s0"))
    pf = h.last("profiles")["v"]
    ids = [p["id"] for p in pf]
    check("profiles: all 19, the doubles included", len(pf) == 19 and "Saved-A" in ids and "Saved-A 1" in ids and "HomeNet-AP 1" in ids, ids)
    ed = profile(h, "eduroam")
    check("profiles: eduroam is eap with method, phase2, identity, anonymous identity and no password",
          ed and ed["security"] == "eap" and ed["eap"]["method"] == "peap" and ed["eap"]["phase2"] == "mschapv2" and
          ed["eap"]["identity"] == "student@university.example" and "password" not in ed["eap"], ed)
    hs = profile(h, "Hotspot")
    check("profiles: the hotspot profile is mode ap, shared", hs and hs["mode"] == "ap" and hs["ip4method"] == "shared", hs)
    nm = h.last("nm")
    check("nm: running, version, state 70, primary connection", nm and nm["running"] and nm["version"] == "1.58.1" and nm["state"] == 70 and
          nm["primary"] == "HomeNet-AP 1", nm)
    act = h.last("active")["v"]
    check("active: the Wi-Fi profile is activated and default", any(a["id"] == "HomeNet-AP 1" and a["state"] == "activated" and a["default4"] for a in act), act)
    info("helper RSS after start: %d kB" % h.rss_kb())

    # -- scan -------------------------------------------------------------------------------------------------------------------
    m = h.mark()
    r = h.call("scan")
    check("scan: the reply is ok", r and r["ok"], r)
    wsc = h.wait(lambda o: o.get("t") == "wifi" and o.get("scanning") is True, 3, m)
    check("scan: scanning turns true", wsc is not None)
    late = h.wait(lambda o: o.get("t") == "wifi" and any(a["ssid"] == "Late-Arrival" for a in o["aps"]), 5, m)
    check("scan: an access point that appears is in the next snapshot, with a lastScan that moved", late is not None and
          late["lastScanMs"] >= w["lastScanMs"])
    done = h.wait(lambda o: o.get("t") == "wifi" and o.get("scanning") is False and any(a["ssid"] == "Late-Arrival" for a in o["aps"]), 5, m)
    check("scan: scanning turns false when the scan landed", done is not None)
    time.sleep(0.4)
    info("wifi events during one scan: %d" % len(h.evs("wifi", m)))

    # -- cadence: a burst of arrivals and leavers -----------------------------------------------------------------------------
    m = h.mark()
    for i in range(12):
        fake.ctl(op="ap_add", ap={"ssid": "Burst-%d" % i, "bssid": "02:AE:00:00:02:%02X" % i, "freq": 2412, "strength": 40 + i, "security": "wpa2"})
    for i in range(12):
        fake.ctl(op="ap_strength", bssid="02:AE:00:00:02:%02X" % i, strength=20 + i)
    for i in range(12):
        fake.ctl(op="ap_remove", bssid="02:AE:00:00:02:%02X" % i)
    time.sleep(0.6)
    burst = h.snapshot(m)
    wifi_ts = [t for t, o in burst if o.get("t") == "wifi"]
    gaps = [b - a for a, b in zip(wifi_ts, wifi_ts[1:])]
    check("a burst of 36 changes gives wifi snapshots at least 100 ms apart", wifi_ts and min(gaps or [1]) >= 0.09, "min gap %.0f ms over %d snapshots" %
          (1000 * min(gaps or [0]), len(wifi_ts)))
    check("a burst of 36 changes is a handful of snapshots, not 36", 1 <= len(wifi_ts) <= 12, len(wifi_ts))
    last = h.last("wifi")
    check("the burst's leavers are gone from the last snapshot", not any(a["ssid"].startswith("Burst-") for a in last["aps"]))
    fake.ctl(op="ap_add", ap={"ssidHex": "43616ffff6", "ssid": "x", "bssid": "02:AE:00:00:03:01", "freq": 2412, "strength": 30, "security": "open"})
    odd = h.wait(lambda o: o.get("t") == "wifi" and any(a["ssidHex"] == "43616ffff6" for a in o["aps"]), 4)
    a = [x for x in odd["aps"] if x["ssidHex"] == "43616ffff6"][0] if odd else {}
    check("an SSID that is not UTF-8 is decoded with replacement and keeps its hex", odd and a["ssid"] == "Cao��" or (odd and "�" in a["ssid"]), a)
    fake.ctl(op="ap_remove", bssid="02:AE:00:00:03:01")

    # -- activate / add / deactivate / delete ----------------------------------------------------------------------------------
    n_prof = len(h.last("profiles")["v"])
    m = h.mark()
    cafe = uuid_of(h, "Cafe-WiFi")
    r = h.call("activate", uuid=cafe)
    check("activate: the reply is ok", r and r["ok"], r)
    got = h.wait(lambda o: o.get("t") == "active" and any(a["id"] == "Cafe-WiFi" and a["state"] == "activated" for a in o["v"]), 5, m)
    check("activate a saved profile: it reaches activated", got is not None)
    w = h.wait(lambda o: o.get("t") == "wifi" and o["device"]["state"] == "activated" and
               any(a["bssid"] == o["activeAp"] and a["ssid"] == "Cafe-WiFi" for a in o["aps"]), 4, m)
    check("activate: the Wi-Fi snapshot's activeAp is that network's AP", w is not None)
    fs = fake.state()
    check("activate: it used the saved profile (no second profile)", len(fs["profiles"]) == n_prof, (len(fs["profiles"]), n_prof))
    prog = h.wait(lambda o: o.get("t") == "devices" and any(d["iface"] == "wlp47s0" and d["state"] in ("prepare", "config", "ip-config") for d in o["v"]), 1, m)
    check("activate: the device's progress states reach the stream", prog is not None)

    m = h.mark()
    r = h.call("add_activate", ssid="Cafe-WiFi", security="wpa2", psk="fake-cafe-psk")
    check("add_activate on a known SSID makes no second profile", r and r["ok"] and r["data"].get("reused") is True and
          len(fake.state()["profiles"]) == n_prof, r)
    m = h.mark()
    r = h.call("add_activate", ssid="DIRECT-99-Printer", security="wpa2", psk="fake-printer-psk")
    got = h.wait(lambda o: o.get("t") == "active" and any(a["id"] == "DIRECT-99-Printer" and a["state"] == "activated" for a in o["v"]), 5, m)
    fs = fake.state()
    pr = [p for p in fs["profiles"] if p["id"] == "DIRECT-99-Printer"]
    check("add_activate a new network: profile made with its psk, activated", r and r["ok"] and r["data"]["reused"] is False and got and
          len(pr) == 1 and pr[0]["psk"] == "fake-printer-psk", (r, pr))
    m = h.mark()
    r = h.call("add_activate", ssid="Neighbour-B", security="wpa2", psk="wrong-psk-9")
    bad = h.wait(lambda o: o.get("t") == "devices" and any(d["iface"] == "wlp47s0" and d["state"] == "failed" and d["stateReason"] == "no-secrets"
                                                             for d in o["v"]), 5, m)
    check("a wrong psk ends failed with the reason no-secrets", bad is not None, h.last("devices", m))
    m = h.mark()
    r = h.call("add_activate", ssid="Hidden-Lab", security="wpa2", psk="fake-hidden-psk", hidden=True)
    got = h.wait(lambda o: o.get("t") == "active" and any(a["id"] == "Hidden-Lab" and a["state"] == "activated" for a in o["v"]), 5, m)
    check("add_activate a hidden network: hidden profile, activated", r and r["ok"] and got and fake.state()["hidden"].get("Hidden-Lab") is True, r)
    fake.ctl(op="ap_add", ap={"ssid": "Corp-EAP", "bssid": "02:AE:00:00:04:01", "freq": 5200, "strength": 60, "security": "eap", "eapPassword": "fake-corp-eap"})
    h.wait(lambda o: o.get("t") == "wifi" and any(a["ssid"] == "Corp-EAP" for a in o["aps"]), 4)
    m = h.mark()
    r = h.call("add_activate", ssid="Corp-EAP", security="eap", eap={"method": "peap", "phase2": "mschapv2", "identity": "u@corp.example",
                                                                       "anonymousIdentity": "anon@corp.example", "password": "fake-corp-eap",
                                                                       "caCert": "/etc/ssl/corp-ca.pem", "domain": "radius.corp.example"})
    got = h.wait(lambda o: o.get("t") == "active" and any(a["id"] == "Corp-EAP" and a["state"] == "activated" for a in o["v"]), 5, m)
    time.sleep(0.4)
    pe = profile(h, "Corp-EAP")
    check("add_activate an EAP network: method, phase2, identities, CA path and server domain land in the profile",
          r and r["ok"] and got and pe and pe["eap"]["method"] == "peap" and pe["eap"]["phase2"] == "mschapv2" and
          pe["eap"]["caCert"] == "/etc/ssl/corp-ca.pem" and pe["eap"]["domain"] == "radius.corp.example" and
          pe["eap"]["anonymousIdentity"] == "anon@corp.example", (r, pe))
    check("add_activate an EAP network: the password reached NetworkManager, not the profile line",
          fake.state()["eapPasswords"].get("Corp-EAP") == "fake-corp-eap")

    m = h.mark()
    r = h.call("deactivate", uuid=uuid_of(h, "Corp-EAP"))
    gone = h.wait(lambda o: o.get("t") == "active" and not any(a["id"] == "Corp-EAP" for a in o["v"]), 4, m)
    check("deactivate: the connection leaves the active list", r and r["ok"] and gone is not None, r)
    r = h.call("deactivate", uuid=uuid_of(h, "Corp-EAP"))
    check("deactivate of something not active is a failed reply with a reason", r and not r["ok"] and r["error"], r)
    n = len(h.last("profiles")["v"])
    m = h.mark()
    r = h.call("delete", uuid=uuid_of(h, "Spare-Router"))
    gone = h.wait(lambda o: o.get("t") == "profiles" and len(o["v"]) == n - 1 and not any(p["id"] == "Spare-Router" for p in o["v"]), 4, m)
    check("delete: the profile leaves the profiles snapshot", r and r["ok"] and gone is not None, r)

    # -- update / secrets ------------------------------------------------------------------------------------------------------
    fa = uuid_of(h, "Saved-A")
    m = h.mark()
    r = h.call("update", uuid=fa, patch={"ipv4": {"method": "manual", "address": "192.0.2.50", "prefix": 24, "gateway": "192.0.2.1", "dns": ["198.51.100.9"]},
                                          "ipv6": {"method": "disabled"}, "mac": "random", "metered": "yes", "autoconnect": False, "priority": 5,
                                          "band": "a", "bssid": "02:ae:00:00:01:01"})
    up = h.wait(lambda o: o.get("t") == "profiles" and any(p["id"] == "Saved-A" and p["ip4method"] == "manual" and p["macPolicy"] == "random" and
                                                          p["metered"] == "yes" and p["autoconnect"] is False and p["priority"] == 5 and
                                                          p["band"] == "a" and p["bssid"] == "02:AE:00:00:01:01" for p in o["v"]), 4, m)
    check("update: the patch lands (ipv4 manual, mac, metered, autoconnect, priority, band, bssid) and a profiles snapshot says so",
          r and r["ok"] and up is not None, (r, profile(h, "Saved-A")))
    fs = fake.state()
    fp = [p for p in fs["profiles"] if p["uuid"] == fa][0]
    import socket as _s, struct
    want = struct.unpack("=I", _s.inet_aton("198.51.100.9"))[0]
    check("update: the DNS goes out as ipv4.dns uint32s, and the saved psk is kept through the update", fp["ipv4dns"] == [want] and fp["psk"] == "fake-psk-07", fp)
    m = h.mark()
    r = h.call("update", uuid=fa, patch={"ipv4": {"method": "auto"}, "mac": "default", "band": "", "bssid": ""})
    h.wait(lambda o: o.get("t") == "profiles" and any(p["id"] == "Saved-A" and p["ip4method"] == "auto" and p["band"] == "" for p in o["v"]), 4, m)
    p2 = profile(h, "Saved-A")
    check("update: back to automatic clears band, bssid and the MAC policy", r and r["ok"] and p2["ip4method"] == "auto" and p2["bssid"] == "" and
          p2["macPolicy"] == "default", p2)
    r = h.call("update", uuid=fa, patch={"ipv4": {"method": "manual"}})
    check("update: a patch that cannot be built is a failed reply, not a dead loop", r and not r["ok"] and "bad patch" in (r["error"] or ""), r)
    m = h.mark()
    r = h.call("secrets", uuid=fa)
    check("secrets: the reply carries the psk", r and r["ok"] and r["data"] == {"psk": "fake-psk-07"}, r)
    r = h.call("secrets", uuid="00000000-0000-0000-0000-000000000000")
    check("secrets: an unknown profile is a failed reply", r and not r["ok"], r)

    # -- radio, hotspot, stats, iw ----------------------------------------------------------------------------------------------
    m = h.mark()
    r = h.call("wifi_enabled", on=False)
    off = h.wait(lambda o: o.get("t") == "wifi" and o.get("radioOn") is False and not o["aps"], 4, m)
    check("wifi_enabled off: radioOn false, no access points", r and r["ok"] and off is not None, r)
    nmo = h.last("nm")
    check("wifi_enabled off: nm says wirelessEnabled false", nmo["wirelessEnabled"] is False)
    lk = h.call("pad", pad="link")
    pl = h.wait(lambda o: o.get("t") == "pad" and o.get("id") == "link" and o.get("state") in ("fail", "warn", "ok"), 3, m)
    check("pad link with the radio off is a fail that says why", pl and pl["state"] == "fail" and "unavailable" in pl["detail"], pl)
    m = h.mark()
    r = h.call("wifi_enabled", on=True)
    on = h.wait(lambda o: o.get("t") == "wifi" and o.get("radioOn") is True and len(o["aps"]) >= 8, 5, m)
    check("wifi_enabled on: the access points come back", r and r["ok"] and on is not None)

    hsu = uuid_of(h, "Hotspot")
    m = h.mark()
    r = h.call("hotspot", on=True, uuid=hsu)
    got = h.wait(lambda o: o.get("t") == "active" and any(a["uuid"] == hsu and a["state"] == "activated" for a in o["v"]), 5, m)
    time.sleep(0.3)
    d = [x for x in h.last("devices")["v"] if x["iface"] == "wlp47s0"][0]
    check("hotspot on with the AP profile: activated, shared address 10.42.0.1", r and r["ok"] and got and d["ip4"]["addresses"][0]["address"] == "10.42.0.1", (r, d["ip4"]))
    m = h.mark()
    r = h.call("hotspot", on=False)
    gone = h.wait(lambda o: o.get("t") == "active" and not any(a["uuid"] == hsu for a in o["v"]), 4, m)
    check("hotspot off: the AP connection is deactivated", r and r["ok"] and gone is not None, r)
    fake.ctl(op="dnsmasq", on=False)
    m = h.mark()
    r = h.call("hotspot", on=True, uuid=hsu)
    bad = h.wait(lambda o: o.get("t") == "devices" and any(x["iface"] == "wlp47s0" and x["state"] == "failed" and x["stateReason"] == "shared-start-failed"
                                                             for x in o["v"]), 5, m)
    check("hotspot without dnsmasq fails with the reason shared-start-failed", bad is not None, h.last("devices", m))
    fake.ctl(op="dnsmasq", on=True)
    time.sleep(0.5)
    n = len(h.last("profiles")["v"])
    m = h.mark()
    r = h.call("hotspot", on=True, ssid="New-Spot", psk="fake-spot-psk", band="a")
    h.wait(lambda o: o.get("t") == "profiles" and len(o["v"]) == n + 1, 4, m)
    ns = [p for p in h.last("profiles")["v"] if p["ssid"] == "New-Spot"]
    check("hotspot on with ssid / psk / band and no profile creates the AP profile", r and r["ok"] and r["data"].get("created") and len(ns) == 1 and
          ns[0]["mode"] == "ap" and ns[0]["band"] == "a", (r, ns))
    h.call("hotspot", on=False)
    time.sleep(0.4)

    # reconnect the home network for the rest
    h.call("activate", uuid=uuid_of(h, "HomeNet-AP 1"))
    h.wait(lambda o: o.get("t") == "active" and any(a["id"] == "HomeNet-AP 1" and a["state"] == "activated" for a in o["v"]), 5, h.mark() - 0)
    time.sleep(0.6)

    m = h.mark()
    r = h.call("stats", iface="wlp47s0", ms=200)
    s1 = h.wait(lambda o: o.get("t") == "stats", 3, m)
    s2 = h.wait(lambda o: o.get("t") == "stats" and s1 and o["rx"] > s1["rx"], 3, m)
    check("stats: rx and tx counters arrive and grow at the asked rate", r and r["ok"] and s1 and s2 and s2["tx"] >= s1["tx"] and s1["iface"] == "wlp47s0", (r, s1, s2))
    r = h.call("stats", iface="wlp47s0", ms=0)
    time.sleep(0.5)
    m = h.mark()
    time.sleep(0.8)
    check("stats with ms 0 stops them", r and r["ok"] and not h.evs("stats", m))
    r = h.call("stats", iface="nope0", ms=200)
    check("stats of an unknown device is a failed reply", r and not r["ok"], r)

    m = h.mark()
    r = h.call("iw_link", iface="wlp47s0")
    ln = h.last("link", m)
    check("iw_link: the link event has standard, dBm and rates from one `iw` call", r and r["ok"] and ln and ln["standard"] == "Wi-Fi 6" and ln["dbm"] == -58 and
          ln["rxMbps"] == 103.2 and ln["txMbps"] == 344.1 and ln["iface"] == "wlp47s0", (r, ln))
    iwlog = open(os.path.join(STUBDIR, "iw.log")).read().splitlines()
    check("iw_link ran `iw dev wlp47s0 link` exactly once", iwlog.count("dev wlp47s0 link") == 1, iwlog)
    r = h.call("iw_link", iface="wl p;rm -rf")
    check("iw_link refuses an interface name that is not one", r and not r["ok"], r)

    # -- BlueZ agent -------------------------------------------------------------------------------------------------------------
    r = h.call("agent", on=True)
    fs = fake.state()
    regs = [x for x in fs["log"] if x[0] in ("bt_register", "bt_default")]
    check("agent on: RegisterAgent (KeyboardDisplay) and RequestDefaultAgent reached BlueZ", r and r["ok"] and regs and regs[0][0] == "bt_register" and
          regs[0][2] == "KeyboardDisplay" and any(x[0] == "bt_default" for x in regs), (r, regs))
    dev = "AA:BB:CC:00:11:22"
    m = h.mark()
    out = fake.ctl_async(op="bt_request", kind="confirm", device=dev, passkey=123456)
    q = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "confirm", 4, m)
    check("agent: a confirmation question arrives with the device and the 6-digit code", q and q["code"] == "123456" and q["device"] == dev, q)
    if q:
        r = h.call("agent_reply", rid=q["rid"], accept=True)
        t0 = time.time()
        while not out and time.time() - t0 < 4:
            time.sleep(0.02)
        check("agent: Yes is answered to BlueZ as a plain return", r and r["ok"] and out and out[0]["ok"] is True, (r, out))
    m = h.mark()
    out = fake.ctl_async(op="bt_request", kind="pin", device=dev)
    q = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "pin", 4, m)
    if q:
        h.call("agent_reply", rid=q["rid"], accept=True, value="0000")
        t0 = time.time()
        while not out and time.time() - t0 < 4:
            time.sleep(0.02)
    check("agent: a PIN question is answered with the typed PIN", q and out and out[0].get("value") == "0000", (q, out))
    m = h.mark()
    out = fake.ctl_async(op="bt_request", kind="passkey", device=dev)
    q = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "passkey", 4, m)
    if q:
        h.call("agent_reply", rid=q["rid"], accept=True, value="424242")
        t0 = time.time()
        while not out and time.time() - t0 < 4:
            time.sleep(0.02)
    check("agent: a passkey question is answered with the typed passkey as a number", q and out and out[0].get("value") == 424242, (q, out))
    m = h.mark()
    out = fake.ctl_async(op="bt_request", kind="confirm", device=dev, passkey=111111)
    q = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "confirm", 4, m)
    if q:
        h.call("agent_reply", rid=q["rid"], accept=False)
        t0 = time.time()
        while not out and time.time() - t0 < 4:
            time.sleep(0.02)
    check("agent: No is answered with org.bluez.Error.Rejected", q and out and out[0].get("error") == "org.bluez.Error.Rejected", (q, out))
    m = h.mark()
    out = fake.ctl_async(op="bt_request", kind="confirm", device=dev, passkey=222222)
    q = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "confirm", 4, m)
    t0 = time.time()
    while not out and time.time() - t0 < 5:
        time.sleep(0.05)
    cn = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "cancel", 1, m)
    check("agent: a question nobody answers is rejected after the timeout (1.5 s here) and the shell is told", q and out and
          out[0].get("error") == "org.bluez.Error.Rejected" and cn is not None, (q, out))
    r = h.call("agent_reply", rid=q["rid"] if q else 999, accept=True)
    check("agent_reply for a question that is gone is a failed reply", r and not r["ok"], r)
    m = h.mark()
    out = fake.ctl_async(op="bt_request", kind="confirm", device=dev, passkey=333333)
    q = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "confirm", 4, m)
    fake.ctl(op="bt_cancel")
    cn = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "cancel" and q and o["rid"] == q["rid"], 3, m)
    t0 = time.time()
    while not out and time.time() - t0 < 3:
        time.sleep(0.05)
    check("agent: BlueZ's Cancel drops the question and tells the shell", cn is not None and out and out[0].get("error") == "org.bluez.Error.Canceled", (cn, out))
    m = h.mark()
    out = fake.ctl_async(op="bt_request", kind="display", device=dev, passkey=654321)
    d_ = h.wait(lambda o: o.get("t") == "agent" and o["kind"] == "display", 3, m)
    check("agent: a displayed passkey is a line for the shell and needs no answer", d_ and d_["code"] == "654321", d_)
    r = h.call("agent", on=False)
    fs = fake.state()
    check("agent off: UnregisterAgent reached BlueZ", r and r["ok"] and fs["agent"] is None and any(x[0] == "bt_unregister" for x in fs["log"]), (r, fs["agent"]))

    # -- ProtonVPN ---------------------------------------------------------------------------------------------------------------
    m = h.mark()
    r = h.call("proton", action="connect", args={"country": "NL"})
    pe = h.last("proton", m)
    check("proton connect: ok, and the line says connected to NL#799 in Amsterdam", r and r["ok"] and pe and pe["state"] == "connected" and
          pe["server"]["name"] == "NL#799" and pe["server"]["city"] == "Amsterdam", (r, pe))
    argv = [json.loads(l) for l in open(os.path.join(STUBDIR, "argv.log"))]
    check("proton connect --country NL was the argv", ["connect", "--country", "NL"] in argv, argv)
    m = h.mark()
    r = h.call("proton", action="status")
    pe = h.last("proton", m)
    check("proton status: the four lines are parsed (state, server, load, protocol)", r and r["ok"] and pe and pe["state"] == "connected" and pe["load"] == 48 and
          pe["protocol"] == "wireguard" and pe["server"]["country"] == "Netherlands", (r, pe))
    m = h.mark()
    r = h.call("proton", action="connect", args={"securecore": True, "country": "BE"})
    r2 = h.call("proton", action="status")
    pe = h.last("proton", m)
    check("proton status with the CLI's stderr panic still reads the Secure Core server", r2 and r2["ok"] and pe and pe["server"]["via"] == "Iceland", (r2, pe))
    m = h.mark()
    r = h.call("proton", action="disconnect")
    check("proton disconnect that exits 1 is a success (the exit status is not a fact)", r and r["ok"] and h.last("proton", m)["state"] == "disconnected", r)
    r = h.call("proton", action="connect", args={"country": "--evil"})
    check("proton refuses an argument that is a flag", r and not r["ok"], r)
    r = h.call("proton", action="connect", args={"city": "Bruss; rm -rf /"})
    check("proton refuses an argument with shell characters", r and not r["ok"], r)
    m = h.mark()
    r = h.call("proton", action="config")
    pc = h.last("proton_config", m)
    check("proton config: the table is an event", r and r["ok"] and pc and pc["kill-switch"] == "off" and pc["netshield"] == "malware-only", pc)
    r = h.call("proton", action="set", args={"key": "kill-switch", "value": "standard"})
    m = h.mark()
    h.call("proton", action="config")
    pc = h.last("proton_config", m)
    check("proton set kill-switch standard: ok and the next config says standard", r and r["ok"] and pc and pc["kill-switch"] == "standard", (r, pc))
    r = h.call("proton", action="set", args={"key": "sudo", "value": "x"})
    check("proton set refuses a setting that is not one", r and not r["ok"], r)
    ids = [h.send("proton", action="status") for _ in range(3)]
    reps = []
    for i in ids:
        reps.append(h.wait(lambda o, i=i: o.get("t") == "reply" and o.get("id") == i, 6))
    order = [id(x) for x in reps]
    t_reps = [t for t, o in h.snapshot() if o.get("t") == "reply" and o.get("id") in ids]
    check("proton: three commands at once run one at a time, in order", all(reps) and t_reps == sorted(t_reps) and t_reps[1] - t_reps[0] > 0.04, t_reps)
    open(os.path.join(STUBDIR, "hang"), "w").close()
    r = h.call("proton", action="status", args={"timeoutS": 1}, timeout=6)
    time.sleep(0.3)
    pid = int(open(os.path.join(STUBDIR, "hang.pid")).read())
    gone = not os.path.exists("/proc/%d" % pid) or open("/proc/%d/stat" % pid).read().split()[2] == "Z"
    check("proton: a command that hangs is a timeout reply and its process is killed", r and not r["ok"] and "timed out" in (r["error"] or "") and gone, (r, gone))
    os.unlink(os.path.join(STUBDIR, "hang"))

    # -- the keyring: Proton's sign-in is in it, and the CLI opens it on every command --------------------------------------------
    keyring_cases(fake)

    # -- the tunnel as NetworkManager sees it -------------------------------------------------------------------------------------
    m = h.mark()
    fake.ctl(op="proton_up", name="NL#1")
    up = h.wait(lambda o: o.get("t") == "active" and any(a["proton"] for a in o["v"]), 5, m)
    time.sleep(0.5)
    seq = [o for _, o in h.snapshot(m) if o.get("t") == "active"]
    ks_first = [i for i, o in enumerate(seq) if any(a["killswitch"] for a in o["v"])]
    pr_first = [i for i, o in enumerate(seq) if any(a["proton"] for a in o["v"])]
    check("vpn: the killswitch dummy is in the active list before the tunnel, flagged killswitch", ks_first and pr_first and ks_first[0] <= pr_first[0], (ks_first, pr_first))
    prim = [(o["primary"], o["primaryReal"]) for _, o in h.snapshot(m) if o.get("t") == "nm"]
    check("vpn: while the dummy is the primary connection, primaryReal still names the real link",
          any(p[0].startswith("pvpn-killswitch") and p[1] and not p[1].startswith("pvpn") for p in prim), prim)
    lastact = h.last("active", m)["v"]
    check("vpn: with the tunnel up the wireguard ProtonVPN connection is flagged proton, the IPv6 guard stays", any(a["proton"] and a["id"] == "ProtonVPN NL#1" and a["devices"] == ["proton0"]
          for a in lastact) and any(a["id"] == "pvpn-killswitch-ipv6" for a in lastact) and not any(a["id"] == "pvpn-killswitch" for a in lastact), lastact)
    m = h.mark()
    fake.ctl(op="proton_down")
    h.wait(lambda o: o.get("t") == "active" and not any(a["proton"] or a["killswitch"] for a in o["v"]), 4, m)
    check("vpn: when the tunnel goes, no proton or killswitch connection is left", h.last("active", m) and not any(a["proton"] or a["killswitch"] for a in h.last("active", m)["v"]))
    ds = {d["iface"] for d in h.last("devices")["v"]}
    check("vpn: and the virtual devices are gone", "proton0" not in ds and "pvpnksintrf0" not in ds, ds)

    # -- the catalogue -----------------------------------------------------------------------------------------------------------
    m = h.mark()
    t0 = time.time()
    r = h.call("catalog", path=cat_src, timeout=10)
    ce = h.last("catalog", m)
    check("catalog: the subset digests to an event with tier 2 and 3 countries", r and r["ok"] and ce and ce["tier"] == 2 and
          [c["code"] for c in ce["countries"]] == ["BE", "IS", "NL"], (r, ce and [c["code"] for c in ce["countries"]]))
    if ce:
        nl = [c for c in ce["countries"] if c["code"] == "NL"][0]
        be = [c for c in ce["countries"] if c["code"] == "BE"][0]
        allnl = [s["name"] for c in nl["cities"] for s in c["servers"]]
        check("catalog: only servers with Tier <= MaxTier (the Tier 3 one is out)", "NL#999" not in allnl and nl["servers"] == len(allnl) == 7, allnl)
        check("catalog: names from the ISO table, country centroid is the mean of its cities", nl["name"] == "Netherlands" and
              abs(nl["lat"] - (52.37 + 51.92) / 2) < 0.01 and abs(nl["lon"] - (4.89 + 4.48) / 2) < 0.01, nl)
        check("catalog: Secure Core servers group under their EXIT country and carry the feature", "securecore" in be["features"] and
              any("securecore" in s["features"] and s["name"] == "IS-BE#1" for c in be["cities"] for s in c["servers"]), be["features"])
        check("catalog: minLoad and feature names (p2p, streaming ...) per country", be["minLoad"] == 63 and "p2p" in be["features"] and "streaming" in be["features"], be)
        check("catalog: each city has coordinates and servers sorted by load", all(c["lat"] and c["lon"] for c in nl["cities"]) and
              [s["load"] for s in nl["cities"][0]["servers"]] == sorted(s["load"] for s in nl["cities"][0]["servers"]), nl["cities"][0])
        check("catalog: the first read is not from the cache", ce["cached"] is False)
    cf = os.path.join(os.environ["XDG_CACHE_HOME"], "lares", "aerial", "catalog.json")
    check("catalog: cached at $XDG_CACHE_HOME/lares/aerial/catalog.json", os.path.isfile(cf), cf)
    m = h.mark()
    r = h.call("catalog", path=cat_src)
    ce2 = h.last("catalog", m)
    check("catalog: the second ask is answered from the cache (same mtime and size)", ce2 and ce2["cached"] is True and ce2["countries"] == ce["countries"])
    cp = os.path.join(W, "serverlist_copy.json")
    open(cp, "wb").write(open(cat_src, "rb").read())
    h.call("catalog", path=cp)
    os.utime(cp, (time.time() + 5, time.time() + 5))
    m = h.mark()
    h.call("catalog", path=cp)
    ce3 = h.last("catalog", m)
    check("catalog: a source whose mtime moved is digested again", ce3 and ce3["cached"] is False)
    r = h.call("catalog", path="/nonexistent/serverlist.json")
    check("catalog: a missing file is a failed reply", r and not r["ok"], r)

    # -- pads -------------------------------------------------------------------------------------------------------------------
    Stub.requests.clear()
    m = h.mark()
    r = h.call("pad", pad="all", timeout=15)
    pads = {o["id"]: o for o in h.evs("pad", m) if o["state"] != "testing"}
    check("pad all: link, addr, gateway, dns, net all ok, in order", r and r["ok"] and [x["id"] for x in r["data"]["results"]] == ["link", "addr", "gateway", "dns", "net"] and
          all(p["state"] == "ok" for p in pads.values()) and len(pads) == 5, (r, pads))
    check("pad gateway pinged the gateway once with -c1 -W1", open(os.path.join(STUBDIR, "ping.log")).read().splitlines()[-1] == "-c1 -W1 192.0.2.1")
    check("pad net: the check URL was asked once and the portal event says no portal", Stub.requests.count(("GET", "/nm-check.txt")) == 1 and
          h.last("portal", m) == {"t": "portal", "present": False, "url": ""} or (h.last("portal", m) or {}).get("present") is False, h.last("portal", m))
    Stub.mode["check"] = "portal"
    Stub.requests.clear()
    m = h.mark()
    r = h.call("pad", pad="net", timeout=10)
    pn = [o for o in h.evs("pad", m) if o["id"] == "net" and o["state"] != "testing"]
    po = h.last("portal", m)
    check("a 302 is a portal (pad net warns, portal carries the Location)", pn and pn[0]["state"] == "warn" and po and po["present"] is True and
          po["url"].endswith("/login"), (pn, po))
    check("a 302 is a portal and is not followed", ("GET", "/login") not in Stub.requests and Stub.requests.count(("GET", "/nm-check.txt")) == 1, Stub.requests)
    Stub.mode["check"] = "broken"
    m = h.mark()
    r = h.call("pad", pad="net", timeout=10)
    pn = [o for o in h.evs("pad", m) if o["id"] == "net" and o["state"] != "testing"]
    check("pad net: a 500 is a fail", pn and pn[0]["state"] == "fail", pn)
    Stub.mode["check"] = "online"
    open(os.path.join(STUBDIR, "pingfail"), "w").close()
    m = h.mark()
    nping0 = len(open(os.path.join(STUBDIR, "ping.log")).read().splitlines())
    r = h.call("pad", pad="all", timeout=15)
    seen = [(o["id"], o["state"]) for o in h.evs("pad", m) if o["state"] != "testing"]
    check("pad all stops at the first fail (gateway): dns and net never ran", seen[-1] == ("gateway", "fail") and not any(i in ("dns", "net") for i, _ in seen) and
          r and r["ok"] and len(r["data"]["results"]) == 3, seen)
    gw = [o for o in h.evs("pad", m) if o["id"] == "gateway"]
    check("pad gateway: a gateway that never answers is ONE fail, after 3 tries", [o["state"] for o in gw] == ["testing", "fail"] and
          len(open(os.path.join(STUBDIR, "ping.log")).read().splitlines()) - nping0 == 3, (gw, nping0))
    os.unlink(os.path.join(STUBDIR, "pingfail"))
    # one lost ping, then a working gateway: a plain ok, and no fail event at all (the glyph must not go red)
    open(os.path.join(STUBDIR, "pingfailn"), "w").write("1")
    m = h.mark()
    nping = len(open(os.path.join(STUBDIR, "ping.log")).read().splitlines())
    r = h.call("pad", pad="gateway", timeout=15)
    gw = [(o["state"]) for o in h.evs("pad", m) if o["id"] == "gateway"]
    check("pad gateway: one lost ping then an answer is ok, and no fail event ever", gw == ["testing", "ok"] and r and r["data"]["results"][0]["state"] == "ok" and
          len(open(os.path.join(STUBDIR, "ping.log")).read().splitlines()) - nping == 2, (gw, r))
    open(os.path.join(STUBDIR, "pingfailn"), "w").write("2")
    m = h.mark()
    r = h.call("pad", pad="gateway", timeout=15)
    gw = [(o["state"]) for o in h.evs("pad", m) if o["id"] == "gateway"]
    check("pad gateway: two lost pings then an answer is still ok", gw == ["testing", "ok"], gw)
    r = h.call("pad", pad="dns", host="no-such-host.invalid", timeout=10)
    pd = [o for o in h.evs("pad") if o["id"] == "dns" and o["state"] == "fail"]
    check("pad dns: a name that does not resolve is a fail", pd, h.evs("pad")[-2:])

    # -- the speed test ----------------------------------------------------------------------------------------------------------
    Stub.mode.update(delay_ms=30, server_ms=25.0)
    m = h.mark()
    cap = 30 * 1000 * 1000
    r = h.call("speed", action="run", capBytes=cap, base=base, timeout=90)
    sp = h.evs("speed", m)
    phases = []
    for e in sp:
        if not phases or phases[-1] != e["phase"]:
            phases.append(e["phase"])
    res = sp[-1]["result"] if sp and sp[-1]["phase"] == "done" else None
    check("speed: the phases are latency, down, up, done", phases == ["latency", "down", "up", "done"], phases)
    check("speed: a result with down, up, latency, jitter, colo and bytes", res and res["downMbps"] > 0 and res["upMbps"] > 0 and res["jitterMs"] >= 0 and res["colo"] == "BRU" and
          res["bytes"] > 0, res)
    check("speed: the test never passes capBytes (down + up together)", res and res["bytes"] <= cap, (res and res["bytes"], cap))
    check("speed: latency is the first byte's time less the server's own (Server-Timing)", res and 0 <= res["latencyMs"] < 22, res and res["latencyMs"])
    check("speed: 20 latency requests, then sizes that grow", sum(1 for q in Stub.requests if q[1] == "/__down") >= 20 and ("POST", "/__up") in Stub.requests)
    check("speed: live progress lines carry liveMbps", any(e["phase"] in ("down", "up") and e["liveMbps"] > 0 for e in sp))
    check("speed: the reply carries the result", r and r["ok"] and r["data"] and r["data"]["colo"] == "BRU", r)
    Stub.mode.update(delay_ms=250)
    m = h.mark()
    i = h.send("speed", action="run", capBytes=cap, base=base)
    h.wait(lambda o: o.get("t") == "speed" and o["phase"] == "latency", 3, m)
    time.sleep(0.5)
    rc = h.call("speed", action="cancel")
    cn = h.wait(lambda o: o.get("t") == "speed" and o["phase"] == "cancelled", 4, m)
    rr = h.wait(lambda o: o.get("t") == "reply" and o.get("id") == i, 4, m)
    check("speed: a cancel stops the run, says cancelled and the run's reply is a failure", cn is not None and rc and rc["ok"] and rr and not rr["ok"], (cn, rr))
    Stub.mode.update(delay_ms=10)
    r = h.call("speed", action="run", capBytes=2000000, base=base, timeout=60)
    check("speed: a new run is allowed after a cancel", r and r["ok"], r)
    r = h.call("speed", action="run", capBytes=1000000, base="http://127.0.0.1:1")
    check("speed: a base that does not answer is phase failed, not a hang", r and not r["ok"] and any(e["phase"] == "failed" for e in h.evs("speed")), r)
    fe = [e for e in h.evs("speed") if e["phase"] == "failed"]
    check("speed: a failure says WHY (curl's own words) and the reply says the same, never the generic line",
          fe and fe[-1].get("error", "").startswith("latency: ") and "onnect" in fe[-1]["error"] and r["error"] == fe[-1]["error"], (fe[-1:], r))
    Stub.mode.update(flaky=True, nflaky=0, delay_ms=10)
    r = h.call("speed", action="run", capBytes=4000000, base=base, timeout=90)
    check("speed: a request the server refuses now and then (HTTP 429) does not fail the test", r and r["ok"] and r["data"]["downMbps"] > 0, r)
    Stub.mode.update(flaky=False)

    # -- a stuck NetworkManager does not stall the stream --------------------------------------------------------------------
    fake.ctl(op="hang", method="scan", on=True)
    t0 = time.time()
    h.send("scan")
    time.sleep(0.15)
    m = h.mark()
    t1 = time.time()
    r = h.call("iw_link", iface="wlp47s0", timeout=6)
    dt = time.time() - t1
    check("a stuck RequestScan does not stall the loop: another command is answered at once", r and r["ok"] and dt < 1.5, "answered after %.2f s" % dt)
    fake.ctl(op="hang", method="scan", on=False)

    # -- robustness ----------------------------------------------------------------------------------------------------------------
    h.proc.stdin.write(b"this is not json\n")
    h.proc.stdin.flush()
    r = h.call("stats", iface="wlp47s0", ms="abc")
    check("a command that raises is a failed reply and a log line", r and not r["ok"], r)
    r = h.call("nosuchcommand")
    check("an unknown command is a failed reply", r and not r["ok"] and r["error"] == "unknown command", r)
    r = h.call("activate", uuid="nope")
    check("the loop goes on after all of that", r and not r["ok"] and h.alive(), r)
    check("a line that is not JSON is a log line", any(o.get("t") == "log" and "not a JSON" in o["text"] for _, o in h.snapshot()))
    info("helper RSS at the end: %d kB" % h.rss_kb())

    # -- no secret outside the secrets reply ----------------------------------------------------------------------------------
    sec_ids = {o["id"] for _, o in h.snapshot() if o.get("t") == "reply" and isinstance(o.get("data"), dict) and "psk" in o["data"]}
    leaks = []
    for raw in h.raw:
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if o.get("t") == "reply" and o.get("id") in sec_ids:
            continue
        for s in SECRETS:
            if s in raw:
                leaks.append((o.get("t"), s))
    check("no secret outside the secrets reply", not leaks, leaks[:3])
    check("not a line of stderr carried a secret either", not any(s in open(os.path.join(W, "helper.err")).read() for s in SECRETS))

    # -- NetworkManager leaves the bus and comes back -----------------------------------------------------------------------------
    m = h.mark()
    fake.ctl(op="nm_name", on=False)
    gone = h.wait(lambda o: o.get("t") == "nm" and o.get("running") is False, 4, m)
    check("NetworkManager leaving the bus: nm says running false and the snapshots empty", gone is not None and h.wait(
        lambda o: o.get("t") == "devices" and o["v"] == [], 3, m) is not None)
    r = h.call("scan")
    check("a command while NetworkManager is away is a failed reply, not a hang", r and not r["ok"], r)
    m = h.mark()
    fake.ctl(op="nm_name", on=True)
    back = h.wait(lambda o: o.get("t") == "wifi" and len(o["aps"]) >= 8 and o["device"] and o["device"].get("ip4"), 8, m)
    check("NetworkManager back: the helper reads the world again by itself", back is not None and h.last("nm", m)["running"] is True)

    # -- exit ----------------------------------------------------------------------------------------------------------------------
    t0 = time.time()
    h.close()
    check("stdin EOF ends the helper (within a second), status 0", not h.alive() and h.proc.returncode == 0 and time.time() - t0 < 2, h.proc.returncode)
    h2 = Helper(fake, name="helper2")
    h2.wait(lambda o: o.get("t") == "hello", 5)
    r = h2.call("quit")
    time.sleep(0.5)
    check("quit answers and ends the helper", r and r["ok"] and not h2.alive(), r)
    h2.close()
    h3 = Helper(fake, name="helper3")
    h3.wait(lambda o: o.get("t") == "hello", 5)
    h3.proc.send_signal(signal.SIGTERM)
    try:
        h3.proc.wait(3)
    except Exception:
        pass
    check("SIGTERM ends the helper", not h3.alive())
    h3.close()


if __name__ == "__main__":
    sys.exit(main())
