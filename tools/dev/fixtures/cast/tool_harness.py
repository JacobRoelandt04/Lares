#!/usr/bin/env python3
"""The checks of tools/dev/cast_tool_probe.sh: lares-cast (TOOLDIR) against stub fluxcast / xrandr / nmcli / ffmpeg (STUBS) in a fake world.
Prints `CT ok|FAIL <name>` per check and `CT RESULT PASS|FAIL`. Kills only the pids it started or recorded from its own stubs."""
import json, os, re, shutil, signal, subprocess, sys, tempfile, time

TOOLDIR, STUBS = os.environ["TOOLDIR"], os.environ["STUBS"]
TOOL = os.path.join(TOOLDIR, "lares-cast")
fails = 0
started = []


def check(name, ok, detail=""):
    global fails
    print("CT %s %s%s" % ("ok  " if ok else "FAIL", name, "" if ok else "  -- " + str(detail)[:300]), flush=True)
    if not ok:
        fails += 1


def world(**files):
    w = tempfile.mkdtemp(prefix="lrcast.")
    os.makedirs(w + "/bin"); os.makedirs(w + "/real"); os.makedirs(w + "/tmp"); os.makedirs(w + "/home"); os.makedirs(w + "/net"); os.makedirs(w + "/run")
    for n in ("fluxcast", "xrandr", "nmcli", "iw"):
        shutil.copy(os.path.join(STUBS, n), w + "/bin/" + n)
    shutil.copy(os.path.join(STUBS, "ffmpeg"), w + "/real/ffmpeg")
    shutil.copy(os.path.join(STUBS, "scan.txt"), w + "/scan.txt")
    for k, v in files.items():
        open(os.path.join(w, k.replace("__", ".")), "w").write(v)
    return w


def envof(w, **extra):
    e = {"PATH": w + "/bin:" + w + "/real:/usr/bin:/bin", "HOME": w + "/home", "TMPDIR": w + "/tmp", "CAST_WORLD": w,
         "LARES_CAST_POLL": "0.1", "LARES_CAST_WIFI_WAIT": "3", "LARES_CAST_STOP_WAIT": "5", "LANG": "C",
         "XDG_RUNTIME_DIR": w + "/run", "XDG_STATE_HOME": w + "/state", "LARES_CAST_SYSNET": w + "/net", "LARES_CAST_LINK_GRACE": "0.3", "LARES_CAST_GROUP_WAIT": "1", "LARES_CAST_BEAT": "0.2"}
    e.update(extra)
    return e


def spawn(args, w, **extra):
    p = subprocess.Popen([sys.executable, TOOL] + args, env=envof(w, **extra), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    started.append(p)
    return p


def events(text):
    out = []
    for l in text.splitlines():
        if l.strip():
            try:
                out.append(json.loads(l))
            except ValueError:
                out.append({"event": "BADJSON", "line": l})
    return out


def finish(p, timeout=25):
    try:
        o, e = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        p.kill(); o, e = p.communicate()
        return None, o, e
    return p.returncode, o, e


def read_until(p, pred, timeout=12):
    """Read stdout lines until pred(list of events so far); returns (ok, events)."""
    evs, end = [], time.time() + timeout
    import select
    while time.time() < end:
        r, _, _ = select.select([p.stdout], [], [], 0.2)
        if r:
            l = p.stdout.readline()
            if not l:
                break
            try:
                evs.append(json.loads(l))
            except ValueError:
                evs.append({"event": "BADJSON", "line": l})
            if pred(evs):
                return True, evs
        elif p.poll() is not None:
            break
    return False, evs


def states(evs):
    return [e["state"] for e in evs if e.get("event") == "state"]


def calls(w):
    try:
        return open(w + "/calls.log").read().splitlines()
    except OSError:
        return []


def alive(pid):
    try:
        st = open("/proc/%d/stat" % pid).read().rsplit(")", 1)[1].split()[0]
        return st != "Z"
    except OSError:
        return False


def recorded_pids(w):
    out = []
    try:
        for l in open(w + "/pids"):
            out += [int(x) for x in l.split()]
    except OSError:
        pass
    return out


def reap(w):
    for pid in recorded_pids(w):
        if alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    shutil.rmtree(w, ignore_errors=True)


def ffargv(w):
    try:
        return open(w + "/ffmpeg.argv").read().splitlines()
    except OSError:
        return []


DEV = ["--device", "wfd:02:AE:00:00:0A:01", "--monitor", "LARES-CAST-1"]
ORDER = ["scanning", "connecting", "negotiating", "streaming", "stopping", "ended"]

# ---- (a) success: the real line sequence, live (PYTHONUNBUFFERED), a stop by TERM
w = world(script="ok")
p = spawn(["start"] + DEV + ["--res", "1920x1080", "--fps", "30"], w)
ok, evs = read_until(p, lambda e: len([x for x in e if x.get("event") == "stats"]) >= 2)
check("a: figures arrive live while the stream runs", ok, evs)
p.send_signal(signal.SIGTERM)
rc, o, e = finish(p)
evs += events(o)
st = states(evs)
check("a: states run in order, none twice", st == [s for s in ORDER if s in st] and len(st) == len(set(st)) and st[:4] == ORDER[:4], st)
check("a: mode 1920x1080 30", {"event": "mode", "width": 1920, "height": 1080, "fps": 30} in evs, evs)
check("a: TERM is a clean stop: stopping, ended 0, exit 0, no failed", st[-2:] == ["stopping", "ended"] and evs[-1] == {"event": "ended", "code": 0} and rc == 0
      and not [x for x in evs if x.get("event") in ("failed", "error")], (rc, evs[-4:], e))
c = calls(w)
check("a: fluxcast argv", len(c) == 1 and all(t in c[0] for t in ("--protocol wfd", "--monitor LARES-CAST-1", "--wfd-peer 02:AE:00:00:0A:01", "--output-res 1920x1080", "--fps 30", "--bitrate 8M")), c)
reap(w)

# ---- (b) activation timeout, then success after Wi-Fi is back
w = world(script="timeout,ok", nmcli__down="2")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 20)
p.send_signal(signal.SIGTERM)
rc, o, e = finish(p)
evs += events(o)
c = calls(w)
check("b: one retry event, no failed, two fluxcast runs", [x for x in evs if x.get("event") == "retry"] == [{"event": "retry", "n": 1}]
      and not [x for x in evs if x.get("event") == "failed"] and len(c) == 2, (c, evs))
polls = int(c[1].split("polls=")[1].split()[0]) if len(c) == 2 else -1
check("b: the retry waits for the Wi-Fi device to be connected again", polls >= 3, c)
check("b: the new attempt starts from scanning again after the retry", states(evs).count("scanning") == 2, states(evs))
reap(w)

# ---- (c) twice a timeout: ONE retry, then failed
w = world(script="timeout,timeout,ok", nmcli__down="1")
p = spawn(["start"] + DEV, w)
rc, o, e = finish(p)
evs = events(o); c = calls(w)
f = [x for x in evs if x.get("event") == "failed"]
check("c: twice a timeout makes one retry only and fails", len(c) == 2 and len([x for x in evs if x.get("event") == "retry"]) == 1 and len(f) == 1
      and f[0]["reason"] == "activation" and "Timed out waiting" in f[0]["detail"] and rc == 1 and evs[-1] == {"event": "ended", "code": 1}, (rc, c, evs))
reap(w)
w = world(script="timeout,ok", nmcli__down="999")
p = spawn(["start"] + DEV, w, LARES_CAST_WIFI_WAIT="1")
rc, o, e = finish(p)
evs = events(o)
check("c: a Wi-Fi that does not come back in time is no retry", len(calls(w)) == 1 and not [x for x in evs if x.get("event") == "retry"]
      and [x for x in evs if x.get("event") == "failed"], (calls(w), evs))
reap(w)

# ---- (d) the ffmpeg 9 bug
w = world(script="ok")
p = spawn(["start"] + DEV, w, LARES_CAST_SHIM="0")
rc, o, e = finish(p)
evs = events(o); f = [x for x in evs if x.get("event") == "failed"]
check("d: without the shim fluxcast's capture dies at once (reason capture)", f and f[0]["reason"] == "capture" and "wf-recorder exited immediately" in f[0]["detail"], (evs, e))
reap(w)
w = world(script="ok")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
p.send_signal(signal.SIGTERM); finish(p)
argv = ffargv(w)
check("d: with the shim (fluxcast 0.3.0) it streams", ok, evs)
asked = open(w + "/sender.argv").read().splitlines()[1:] if os.path.exists(w + "/sender.argv") else []
i = asked.index("-thread_queue_size") if "-thread_queue_size" in asked else 0
check("d: the real ffmpeg got the argv with the thread_queue_size pair gone and the rest intact, its progress asked for", i > 0 and argv[:1] == ["-progress"] and argv[1].endswith("/progress")
      and argv[2:] == asked[:i] + asked[i + 2:], argv)
check("d: the private shim dir is gone after the stop", os.listdir(w + "/tmp") == [], os.listdir(w + "/tmp"))
reap(w)
w = world(script="ok", version="0.3.1")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
p.send_signal(signal.SIGTERM); finish(p)
check("d: a fixed fluxcast (0.3.1) streams, its sender's progress asked for", ok and ffargv(w)[:1] == ["-progress"] and ffargv(w)[-2:-1] == ["rtp_mpegts"], (evs, ffargv(w)))
reap(w)

# ---- (e) TERM leaves no child
for name, flags, wait in (("INT ends it", "", "5"), ("deaf to INT: KILL of the group", "ignoreint", "1")):
    w = world(script="ok", flags=flags)
    p = spawn(["start"] + DEV, w, LARES_CAST_STOP_WAIT=wait)
    ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
    t0 = time.time()
    p.send_signal(signal.SIGTERM)
    rc, o, e = finish(p, 20)
    evs += events(o)
    time.sleep(0.3)
    pids = recorded_pids(w)
    check("e: (%s) the tool ends with ended, and no recorded child lives" % name,
          rc == 0 and evs[-1].get("event") == "ended" and pids and not [x for x in pids if alive(x)], (rc, pids, [x for x in pids if alive(x)], evs[-2:]))
    reap(w)
w = world(script="hang")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: "connecting" in states(e), 12)
p.send_signal(signal.SIGINT)
rc, o, e = finish(p)
evs += events(o)
check("e: a stop before the stream is clean (no failed), no child left", rc == 0 and evs[-1] == {"event": "ended", "code": 0}
      and not [x for x in evs if x.get("event") == "failed"] and not [x for x in recorded_pids(w) if alive(x)], (rc, evs))
reap(w)

# ---- (f) a monitor that is not there / a bad device
w = world(script="ok")
p = spawn(["start", "--device", "wfd:02:AE:00:00:0A:01", "--monitor", "NOPE-9"], w)
rc, o, e = finish(p)
evs = events(o)
check("f: an unknown --monitor is refused (reason monitor, exit 2) and fluxcast never runs", rc == 2 and evs and evs[0].get("reason") == "monitor" and evs[0].get("event") == "error" and calls(w) == [], (rc, evs, calls(w)))
p = spawn(["start", "--device", "tv", "--monitor", "LARES-CAST-1"], w)
rc, o, e = finish(p)
check("f: a device id that is not wfd:<mac> is refused", rc == 2 and events(o)[0].get("reason") == "device", (rc, o))
reap(w)

# a just-created output shows in xrandr only on its 5th look: the tool waits for it (poll 100 ms, up to 3 s) and then streams
w = world(script="ok", xr_after="5")
p = spawn(["start"] + DEV, w, LARES_CAST_MONITOR_WAIT="3")
rc, o, e = finish(p, 6)
evs = events(o)
check("f: an output xrandr lists only on its 5th look is waited for, then streamed", len(calls(w)) == 1 and not [x for x in evs if x.get("event") in ("error", "failed")]
      and any(x.get("state") == "negotiating" for x in evs), (rc, evs[:3], calls(w)))
reap(w)
w = world(script="ok", xr_after="999")
p = spawn(["start"] + DEV, w, LARES_CAST_MONITOR_WAIT="0.5")
rc, o, e = finish(p)
evs = events(o)
check("f: an output that never shows is refused after the wait (reason monitor)", rc == 2 and evs and evs[0].get("reason") == "monitor" and calls(w) == [], (rc, evs))
reap(w)

# ---- (g) scan
w = world(script="ok")
p = spawn(["scan", "--seconds", "3", "--json"], w, LARES_CAST_PY=os.path.join(STUBS, "upnp_no"))
rc, o, e = finish(p)
d = events(o)[0] if o.strip() else {}
dev = d.get("devices", [])
check("g: three peers parsed with id, name, capable", len(dev) == 3 and dev[0] == {"id": "wfd:02:AE:00:00:0A:01", "index": 0, "mac": "02:AE:00:00:0A:01", "name": "[TV] Living Room OLED 65",
      "protocol": "wfd", "capable": True, "note": ""}, (rc, d))
check("g: the two note lines (not advertising, already running its own group) land in the note, capable false", len(dev) == 3 and dev[1]["capable"] is False
      and "not advertising Wi-Fi Display" in dev[1]["note"] and "already running its own group" in dev[1]["note"] and dev[1]["name"] == "Pixel 9", dev[1:2])
check("g: a peer with no name, and a PIN-only note", len(dev) == 3 and dev[2]["name"] == "" and dev[2]["capable"] is True and "pairs by PIN only" in dev[2]["note"], dev[2:])
check("g: version, shim, protocols (no upnpclient: wfd only)", d.get("fluxcast") == "0.3.0" and d.get("shim") is True and d.get("protocols") == ["wfd"], d)
p = spawn(["scan", "--json"], w, LARES_CAST_PY=os.path.join(STUBS, "upnp_yes"))
rc, o, e = finish(p)
check("g: upnpclient importable adds dlna", events(o)[0].get("protocols") == ["wfd", "dlna"], o)
open(w + "/scan.fail", "w").write("NetworkManager has no Wi-Fi Direct device")
p = spawn(["scan", "--json"], w)
rc, o, e = finish(p)
ev = events(o)
check("g: a scan the tool fails is an error event and exit 1", rc == 1 and ev[0].get("event") == "error" and ev[0].get("reason") == "scan" and "no Wi-Fi Direct" in ev[0].get("detail", ""), (rc, o))
reap(w)

# ---- (i) the link dies under a stream that was up: fluxcast sleeps for ever (2026-11-22: the shell said "Casting" for minutes)
w = world(script="linkdies,ok", nmcli__down="1")
p = spawn(["start"] + DEV, w, LARES_CAST_STALL="60")          # the netdev's going is what is noticed, not the stall
ok, evs = read_until(p, lambda e: len([x for x in e if x.get("state") == "streaming"]) == 2, 25)
check("i: a link that dies is noticed and made again once: streaming, retry, streaming", ok and [x for x in evs if x.get("event") == "retry"] == [{"event": "retry", "n": 1}]
      and len(calls(w)) == 2, (calls(w), evs))
p.send_signal(signal.SIGTERM); finish(p)
check("i: no recorded child of the dead run lives", not [x for x in recorded_pids(w) if alive(x)], recorded_pids(w))
t = open(w + "/state/lares/cast/cast.log").read() if os.path.exists(w + "/state/lares/cast/cast.log") else ""
check("i: the transcript is kept (fluxcast's lines, the link watch, the events)", "flux  [FluxCast WFD] P2P link is activated" in t and "link watch: the Wi-Fi Direct link went down" in t and "event " in t, t[:200])
reap(w)
w = world(script="linkdies,linkdies,ok")
p = spawn(["start"] + DEV, w)
rc, o, e = finish(p, 25)
evs = events(o); f = [x for x in evs if x.get("event") == "failed"]
check("i: a link that dies twice in a row is the end (reason link), never a loop", rc == 1 and len(calls(w)) == 2 and len(f) == 1 and f[0]["reason"] == "link", (rc, calls(w), evs[-3:]))
reap(w)
w = world(script="stalls")
p = spawn(["start"] + DEV, w, LARES_CAST_STALL="1.5")
rc, o, e = finish(p, 20)
f = [x for x in events(o) if x.get("event") == "failed"]
check("i: nothing sent while the link stands is the TV's end (peer-gone), no retry", rc == 1 and f and f[0]["reason"] == "peer-gone" and len(calls(w)) == 1, (rc, events(o)[-3:]))
reap(w)
w = world(script="teardown")
p = spawn(["start"] + DEV, w, LARES_CAST_STALL="60")
t0 = time.time()
rc, o, e = finish(p, 30)
f = [x for x in events(o) if x.get("event") == "failed"]
check("i: the TV's teardown ends the cast in seconds, not after the stall", rc == 1 and f and f[0]["reason"] == "peer-gone" and time.time() - t0 < 15, (rc, time.time() - t0, events(o)[-3:]))
reap(w)

# ---- (j) the hold: the Wi-Fi profile is locked to its access point for the cast, and never reconnected while a group is up
def nm(w):
    try:
        return open(w + "/nm.log").read().splitlines()
    except OSError:
        return []


def bss(w):
    try:
        return open(w + "/bssid").read()
    except OSError:
        return None


REC = "/run/lares/cast-wifi.json"
w = world(script="ok")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
L = nm(w)
check("j: held before fluxcast runs: modify --temporary, then one up, on the access point in force", len(L) == 2 and "--temporary" in L[0] and "02:AE:00:00:0A:03" in L[0] and L[1].startswith("up bssid=02:AE:00:00:0A:03")
      and {"event": "hold", "ok": True, "why": ""} in evs and os.path.exists(w + REC), (L, evs))
p.send_signal(signal.SIGTERM)
rc, o, e = finish(p)
L = nm(w)
check("j: given back after the stop: the lock off, one reconnect, no record", bss(w) == "" and len(L) == 4 and L[3].startswith("up bssid= ") and not os.path.exists(w + REC), (L, bss(w)))
check("j: no reconnect ever ran while a group was up", L and all(l.endswith("[groups: ]") for l in L if l.startswith("up ")), L)
check("j: no change was written to disk (every modify is --temporary)", all("--temporary" in l for l in L if l.startswith("modify")), L)
reap(w)
w = world(script="timeout,ok")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 20)
check("j: a retry keeps the hold (one modify, one up)", len(nm(w)) == 2, nm(w))
p.send_signal(signal.SIGTERM); finish(p); reap(w)
w = world(script="ok", ownbssid="AA:BB:CC:DD:EE:FF")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
p.send_signal(signal.SIGTERM); finish(p)
check("j: the user's own lock is neither taken nor given back", ok and nm(w) == [], nm(w))
reap(w)
w = world(script="ok"); open(w + "/nm.refuse", "w").close()
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
p.send_signal(signal.SIGTERM); finish(p)
h = [x for x in evs if x.get("event") == "hold"]
check("j: a profile that cannot be changed is said, and the cast goes on", ok and h and h[0]["ok"] is False and "cannot be changed" in h[0]["why"] and not os.path.exists(w + REC), (evs, nm(w)))
reap(w)
w = world(script="ok"); os.makedirs(w + "/net/p2p-wlan0-9")
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
check("j: with a group up already nothing is reconnected", ok and not [l for l in nm(w) if l.startswith("up ")], nm(w))
p.send_signal(signal.SIGTERM); finish(p); reap(w)
w = world(script="ok", bssid="02:AE:00:00:0A:03"); os.makedirs(w + "/run/lares")
open(w + REC, "w").write(json.dumps({"pid": 4194303, "uuid": "U-1", "device": "wlan0", "bssid": "02:AE:00:00:0A:03"}))
p = spawn(["restore"], w); rc, o, e = finish(p)
check("j: restore gives back what a dead cast held", rc == 0 and bss(w) == "" and not os.path.exists(w + REC), (rc, nm(w), e))
n0 = len(nm(w)); p = spawn(["restore"], w); rc, o, e = finish(p)
check("j: restore with no record asks nothing", rc == 0 and len(nm(w)) == n0, nm(w))
p = spawn(["start"] + DEV, w)
read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
n0 = len(nm(w)); q = spawn(["restore"], w); finish(q)
check("j: restore leaves a live cast's hold alone", len(nm(w)) == n0 and os.path.exists(w + REC), nm(w))
p.send_signal(signal.SIGTERM); finish(p); reap(w)
# A RESTART KEEPS THE HOLD (SIGUSR1): no give-back, so no reconnect of the station right before the next pairing (2026-11-23: the
# card's firmware asserted in both recasts, 11 s after "hold given back")
w = world(script="ok")
p = spawn(["start"] + DEV, w)
read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
n0 = len(nm(w))
p.send_signal(signal.SIGUSR1)
rc, o, e = finish(p)
check("j: a restart's stop keeps the hold: no modify, no reconnect, the record stays", rc == 0 and len(nm(w)) == n0 and os.path.exists(w + REC) and bss(w) == "02:AE:00:00:0A:03", (rc, nm(w)[n0:], bss(w)))
q = spawn(["restore"], w); finish(q)
check("j: a plain restore leaves a hold handed over a moment ago", len(nm(w)) == n0 and os.path.exists(w + REC), nm(w)[n0:])
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
rec = json.load(open(w + REC))
check("j: the next start takes the hold over: nothing asked of NetworkManager, the record is its own", ok and len(nm(w)) == n0 and rec.get("pid") == p.pid
      and {"event": "hold", "ok": True, "why": ""} in evs, (nm(w)[n0:], rec, p.pid))
q = spawn(["restore"], w); finish(q)
check("j: ... and no sweep takes it from the live cast", len(nm(w)) == n0 and os.path.exists(w + REC), nm(w)[n0:])
p.send_signal(signal.SIGTERM); finish(p)
check("j: its own stop gives it back", bss(w) == "" and not os.path.exists(w + REC), (nm(w)[n0:], bss(w)))
reap(w)
# a hold handed over that no start took: `restore --now` gives it back (the shell, when the cast has ended for good)
w = world(script="ok")
p = spawn(["start"] + DEV, w)
read_until(p, lambda e: any(x.get("event") == "stats" for x in e), 12)
p.send_signal(signal.SIGUSR1); finish(p)
q = spawn(["restore", "--now"], w); rc, o, e = finish(q)
check("j: restore --now gives back a handed-over hold nobody took", rc == 0 and bss(w) == "" and not os.path.exists(w + REC), (rc, nm(w), e))
reap(w)

# ---- (k) the figures: one set a beat while it streams, from the sender's own progress, the interface, an echo and the radio
KEYS = {"event", "age", "reconnects", "fps", "dropped", "repeated", "behindMs", "kbps", "rttMs", "signalDbm", "linkMbps"}


def stats(evs):
    return [x for x in evs if x.get("event") == "stats"]


def log_of(w):
    try:
        return open(w + "/state/lares/cast/cast.log").read()
    except OSError:
        return ""


w = world(script="ok")                                        # 30 fps, 2 dropped and 4 repeated a second, 1 MB a second on the interface
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: len(stats(e)) >= 22, 20)
st = stats(evs)
p.send_signal(signal.SIGTERM)
rc, o, e = finish(p)
last = st[-1] if st else {}
check("k: none before the stream is up", st and [x.get("state") for x in evs[:evs.index(st[0])]].count("streaming") == 1, evs[:8])
check("k: the sender's figures: frames a second, dropped, repeated, how far behind", 28 <= last.get("fps", 0) <= 32 and last.get("dropped", 0) >= 6 and last.get("repeated", 0) >= 14
      and 0 <= last.get("behindMs", -1) <= 60, last)
check("k: what was handed to the Wi-Fi card, in kbit/s", 7000 <= last.get("kbps", 0) <= 9000, last)
check("k: the round trip of an echo to the address the stream goes to", 0 < last.get("rttMs", 0) < 50, last)
check("k: the radio's own figures (iw station dump, the group's interface)", last.get("signalDbm") == -52 and last.get("linkMbps") == 866.7
      and open(w + "/iw.log").read().splitlines()[0] == "dev p2p-wlan0-0 station dump" if os.path.exists(w + "/iw.log") else False, (last, log_of(w)[-300:]))
check("k: every figure is in ONE set, no key of it unknown to the contract", set(last) == KEYS, sorted(last))
check("k: the radio is asked less often than the beat", 0 < len(open(w + "/iw.log").read().splitlines()) <= 1 + len(st) // 5, open(w + "/iw.log").read().splitlines())
ages = [x["age"] for x in st]
check("k: the age counts seconds of streaming and never goes back", ages == sorted(ages) and 3 <= ages[-1] <= 6 and last.get("reconnects") == 0, ages)
t = log_of(w)
m = re.search(r"average held (\d+) s, reconnects 0, ([\d.]+) fps, dropped (\d+), repeated (\d+), behind at most (\d+) ms, sent ([\d.]+) MB \(([\d.]+) Mbit/s\), "
              r"round trip ([\d.]+) ms \(at most ([\d.]+), (\d+) of (\d+) unanswered\), signal -52 dBm \(worst -52\)\n", t)
check("k: the transcript has the cast's averages in one line", m and 28 <= float(m.group(2)) <= 32 and int(m.group(3)) - last["dropped"] in (0, 1, 2) and 7 <= float(m.group(7)) <= 9
      and int(m.group(10)) <= 1, [l for l in t.splitlines() if "average" in l])
check("k: the transcript has a set now and then, not a line a beat", '"event":"stats"' not in t and 0 < t.count(" stats {") <= 1 + len(st) // 10, t.count(" stats {"))
SEAM = os.environ.get("CT_SEAM", "")
if SEAM:
    with open(SEAM, "w") as f:                                # the tool's real lines, for CastParse.js (cast_parse_cases.js --lines)
        f.write("".join(json.dumps(x, separators=(",", ":")) + "\n" for x in evs + events(o)))
reap(w)

w = world(script="linkdies,ok", nmcli__down="2")              # the link dies and is made again: one cast
p = spawn(["start"] + DEV, w, LARES_CAST_STALL="60")
ok, evs = read_until(p, lambda e: any(x.get("event") == "retry" for x in e) and len(stats(e[[y.get("event") for y in e].index("retry"):])) >= 8, 25)
p.send_signal(signal.SIGTERM)
rc, o, e = finish(p)
names = [x.get("event") for x in evs]
il, ir = names.index("lost") if "lost" in names else -1, names.index("retry") if "retry" in names else -1
check("k: a stream that was up is said lost at once, before the Wi-Fi is back (then the retry)", 0 < il < ir, names)
a, b = stats(evs[:ir]), stats(evs[ir:])
check("k: no figures between the lost link and the next stream", not stats(evs[il:ir]) and ok, names)
check("k: the totals run over the reconnect and never go back", a and b and b[0]["dropped"] >= a[-1]["dropped"] and b[0]["repeated"] >= a[-1]["repeated"]
      and b[-1]["repeated"] > a[-1]["repeated"] and [x["age"] for x in a + b] == sorted(x["age"] for x in a + b), (a[-1:], b[:1], b[-1:]))
check("k: the reconnect is counted", a and b and a[-1]["reconnects"] == 0 and b[-1]["reconnects"] == 1, (a[-1:], b[-1:]))
check("k: a live figure is not carried over a dead link", b and b[0].get("fps", 0) is None and b[0].get("kbps", 0) is None, b[:1])
reap(w)

w = world(script="ok", ff__script="15 0 0 0.5")               # an encoder that cannot keep up: half the frames, the stream's clock at half the wall's
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: len(stats(e)) >= 14, 20)
p.send_signal(signal.SIGTERM); finish(p)
bh = [x["behindMs"] for x in stats(evs) if x.get("behindMs") is not None]
check("k: an encoder that cannot keep up is further behind at every look, and its frame rate says so", len(bh) >= 10 and bh == sorted(bh) and bh[-1] - bh[0] >= 800
      and 13 <= stats(evs)[-1].get("fps", 0) <= 17, (bh, stats(evs)[-1:]))
reap(w)

w = world(script="ok"); open(w + "/iw.fail", "w").close()
p = spawn(["start"] + DEV, w)
ok, evs = read_until(p, lambda e: len(stats(e)) >= 8, 20)
p.send_signal(signal.SIGTERM); finish(p)
check("k: a figure with no source has no key (the radio says nothing), the others stay", ok and not {"signalDbm", "linkMbps"} & set(stats(evs)[-1]) and "fps" in stats(evs)[-1], stats(evs)[-1:])
reap(w)

# a TV that answers no echo: ten tries, then it is left alone (a fake socket: nothing leaves the machine)
import importlib.machinery, importlib.util
sys.dont_write_bytecode = True
ld = importlib.machinery.SourceFileLoader("lares_cast", TOOL)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("lares_cast", ld))
ld.exec_module(mod)


class Deaf:
    sends = 0
    def send(self, b): Deaf.sends += 1
    def recv(self, n): raise BlockingIOError()
    def fileno(self): return -1
    def close(self): pass


fig = mod.Figures("")
fig.tv, fig.sock = "192.0.2.1", Deaf()
for k in range(40):
    fig.ask_echo(float(k))
check("k: a TV that never answers an echo is left alone after ten, and has no round trip", Deaf.sends == 10 and fig.deaf and fig.sock is None, (Deaf.sends, fig.deaf))

# the REAL ffmpeg in the recorder's and the sender's place (320x180, RTP to loopback): its own progress through the tool's own reader
w = world(script="ok", flags="realff")
p = spawn(["start"] + DEV, w, PATH=w + "/bin:/usr/bin:/bin", LARES_CAST_BEAT="1")
ok, evs = read_until(p, lambda e: len(stats(e)) >= 5, 25)
p.send_signal(signal.SIGTERM)
rc, o, e = finish(p)
last = stats(evs)[-1] if stats(evs) else {}
check("k: the real ffmpeg's progress reads as 30 fps, nothing dropped, not behind", ok and 28.5 <= last.get("fps", 0) <= 31.5 and last.get("dropped") == 0 and last.get("behindMs", 999) < 200, (last, e[-200:]))
time.sleep(0.3)
check("k: a stop leaves no real ffmpeg behind", not [x for x in recorded_pids(w) if alive(x)], recorded_pids(w))
reap(w)

# ---- (h) doctor
w = world(doctor__json='{"checks":[{"name":"wf-recorder","ok":true}]}')
p = spawn(["doctor", "--json"], w)
rc, o, e = finish(p)
d = events(o)[0] if o.strip() else {}
check("h: doctor passes the checks through and adds shim, ffmpeg, p2p", d.get("checks") == {"checks": [{"name": "wf-recorder", "ok": True}]} and d.get("shim") is True
      and d.get("ffmpeg") == "n9.1" and d.get("p2p") is True and d.get("fluxcast") == "0.3.0", (rc, d, e))
reap(w)

for p in started:
    if p.poll() is None:
        p.kill()
print("CT RESULT " + ("FAIL (%d)" % fails if fails else "PASS"))
sys.exit(1 if fails else 0)
