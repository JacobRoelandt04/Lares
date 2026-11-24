#!/usr/bin/env python3
"""bridge_cast_cases.py -- castlib (tools/bridge/castlib) against hand-written bytes: the stream headers, the control messages, Annex-B
-> AVCC, the AVCDecoderConfigurationRecord of a real SPS/PPS, the FLV tags, and a round trip of a real encode through ffprobe / ffmpeg.

  python3 tools/dev/bridge_cast_cases.py        BRIDGE_CAST_CASES RESULT PASS | FAIL
  ARM=<name> python3 tools/dev/bridge_cast_cases.py     one fault in a COPY of tools/bridge; its own check must FAIL
  ARM=all ...                                            every arm: BRIDGE_CAST_CASES ARMS RESULT PASS | FAIL

The second half runs the REAL tools/bridge/lares-cast against the fake phone (tools/dev/stubs/bridge: the stub adb, which answers `wm size` /
`wm density` and execs fake_scrcpy_server.py for the server, which records the parameters it was started with): --new-display's argv
(the dpi worked out from the phone's own screen, an explicit dpi passed through, no max_size, vd_destroy_content=false), the `flow` events
(on at the first frame, off after 1.5 s with none, on again; off at the start when no frame ever comes) and every event in the bridge trace.
No phone, no real adb, nothing of the user's: a private HOME / state / cache and PATH with the stub first.

The third half is --record on the same fake phone: an mp4 ffprobe reads (the picture, its size, the phone's own times, the part gone) after
a quit, after a TERM, with --audio (h264 + aac), across a desktop's resize (both sizes, decoded clean), a second recording to a name already
taken (`-2`), a live player beside it, a phone that gives no picture (`empty`, nothing left), a remux that fails (the part kept and named),
and a SIGKILL mid-cast (the part is a stream ffprobe reads).

ARMs (the check that must fail):
  nodpi       the virtual display's dpi ignores its width against the phone's          -> "dpi from the phone's own screen"
  noflowoff   no `flow` off event is ever emitted                                       -> "flow goes off"
  norecord    the recorder is never fed                                                 -> "record: the file holds the phone's picture"
  noremux     the cast's end never finishes the file                                    -> "record: the end remuxes the part into PATH"
  zerots      the file takes the live player's all-zero times                           -> "record: the file keeps the phone's own times"
"""
import json
import os
import re
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.realpath(__file__))
STUBS = os.path.join(HERE, "stubs", "bridge")
ARMS = {
    "nodpi": ("castlib/wm.py", "int(density * width / float(screen_width) + 0.5)", "int(density)", "dpi from the phone's own screen"),
    "noflowoff": ("lares-cast", '                emit(event="flow", on=False)', "                pass", "flow goes off"),
    "goingaway": ("castlib/lock.py", 'int(f[1]) == 1 and int(f[3]) == 0', 'int(f[1]) == 1', "going away is not locked"),
    "anydisplay": ("castlib/lock.py", 'if len(f) < 4 or int(f[0]) != 0:', 'if len(f) < 4:', "another display's keyguard event is ignored"),
    "oldevents": ("castlib/lock.py", 'if self.since is not None and t < self.since:', 'if False:', "an event from before the read is ignored"),
    "locknoanswer": ("castlib/lock.py", '    if "==trust" not in text and "==window" not in text:\n        return None', '    if False:\n        return None',
                     "a phone that does not answer says no lock"),
    "resizebytes": ("castlib/proto.py", 'struct.pack(">BHH", CT_RESIZE_DISPLAY', 'struct.pack(">BII", CT_RESIZE_DISPLAY', "resize display bytes"),
    "flexalways": ("lares-cast", '            if a.flex:\n                args.append("flex_display=true")', '            if True:\n                args.append("flex_display=true")',
                   "no flex_display without --flex"),
    "nowake": ("lares-cast", '        elif m.get("wake"):', '        elif m.get("wakeX"):', "wake is KEYCODE_WAKEUP down and up"),
    "resizenoflex": ("lares-cast", 'if self.a.flex and self.a.new_display and isinstance(r, dict):', 'if isinstance(r, dict):', "resize is ignored without --flex"),
    "nobackoff": ("lares-cast", 'LOCK_BACKOFF_S = (1, 2, 4)', 'LOCK_BACKOFF_S = (0.05, 0.05, 0.05)', "the follower restarts with backoff"),
    "nopdeathsig": ("lares-cast", '                                 preexec_fn=lambda: pdeathsig(signal.SIGKILL))\n        except OSError:\n            return',
                    '                                 )\n        except OSError:\n            return', "the follower dies with the cast"),
    "sysexit": ("lares-cast", '    leave(code)\n', '    sys.exit(code)\n', "a busy cast exits 0 on quit"),
    "norecord": ("lares-cast", '        if self.recorder:\n            self.recorder.put(item)\n', '', "record: the file holds the phone's picture"),
    "noremux": ("lares-cast", '            emit(event="record", **rec.finish())\n', '            pass\n', "record: the end remuxes the part into PATH"),
    "zerots": ("lares-cast", '    def ts_mode(self):\n        return "pts"\n', '    def ts_mode(self):\n        return "zero"\n', "record: the file keeps the phone's own times"),
}
ARM = os.environ.get("ARM", "")


def arm_all():
    rc = 0
    for name, (_, _, _, needle) in ARMS.items():
        p = subprocess.run([sys.executable, "-B", os.path.abspath(__file__)], env=dict(os.environ, ARM=name), capture_output=True, text=True)
        out = p.stdout + p.stderr
        if "anchor is gone" in out:
            print("ARM %s: NOT PROVEN (its anchor is gone)" % name)
            rc = 1
        elif p.returncode != 0 and any(l.startswith("FAIL") and needle in l for l in out.splitlines()):
            print("ARM %s: FAILED AS IT MUST ('%s')" % (name, needle))
        else:
            print("ARM %s: %s" % (name, "FAILED, BUT NOT ON '%s'" % needle if p.returncode else "STAYED GREEN"))
            rc = 1
    print("BRIDGE_CAST_CASES ARMS RESULT %s" % ("PASS" if rc == 0 else "FAIL"))
    sys.exit(rc)


if ARM == "all":
    arm_all()
# the tool under test: the working tree's, or (ARM) a copy with one fault in it
TREE = os.path.join(HERE, "..", "..")
if ARM:
    ARMDIR = tempfile.mkdtemp(prefix="bridge_cast_arm.")
    for d in ("bridge", "lib"):
        shutil.copytree(os.path.join(TREE, "tools", d), os.path.join(ARMDIR, "tools", d), ignore=shutil.ignore_patterns("__pycache__"))
    rel, a_, b_, _needle = ARMS[ARM]
    path = os.path.join(ARMDIR, "tools", "bridge", rel)
    src = open(path).read()
    if src.count(a_) != 1:
        print("ARM %s: anchor is gone in %s" % (ARM, rel))
        print("BRIDGE_CAST_CASES RESULT FAIL (arm)")
        sys.exit(1)
    open(path, "w").write(src.replace(a_, b_))
    BRIDGE = os.path.join(ARMDIR, "tools", "bridge")
else:
    ARMDIR = ""
    BRIDGE = os.path.join(HERE, "..", "bridge")
sys.dont_write_bytecode = True
sys.path.insert(0, BRIDGE)
from castlib import flv, proto, wm  # noqa: E402
from castlib import lock as clock  # noqa: E402

fails, n = [], 0


def check(name, got, want):
    global n
    n += 1
    ok = got == want
    print("%s %s" % ("ok  " if ok else "FAIL", name) + ("" if ok else "\n   got  %r\n   want %r" % (got, want)))
    if not ok:
        fails.append(name)


def truth(name, cond, seen=""):
    """A check of a condition: the evidence is printed only when it fails."""
    global n
    n += 1
    print("%s %s" % ("ok  " if cond else "FAIL", name) + ("" if cond else "\n   seen %r" % (seen,)))
    if not cond:
        fails.append(name)


def split_aus(annexb):
    """An x264 stream made with aud=1 -> access units (each starts with an AUD NAL, type 9)."""
    pos, i = [], 0
    while True:
        i = annexb.find(b"\x00\x00\x00\x01", i)
        if i < 0:
            break
        if annexb[i + 4] & 0x1F == 9:
            pos.append(i)
        i += 4
    return [annexb[a:b] for a, b in zip(pos, pos[1:] + [len(annexb)])]


class Run:
    """One lares-cast against the fake phone, in a private world (HOME, state, cache, PATH with the stub adb first)."""

    def __init__(self, root, name, args, wm_world=None, pause=False, jar="/etc/hostname", serial="S1", phone=None, drain=True, bins=None):
        self.w = os.path.join(root, name)
        os.makedirs(os.path.join(self.w, "bin"))
        os.symlink(os.path.join(STUBS, "bin", "adb"), os.path.join(self.w, "bin", "adb"))
        for b, text in (bins or {}).items():         # a stand-in program of this run's own (first on PATH)
            with open(os.path.join(self.w, "bin", b), "w") as f:
                f.write(text)
            os.chmod(os.path.join(self.w, "bin", b), 0o755)
        s = socket.socket()
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
        s.close()
        world = {"adb": {"wm": {serial: wm_world or {"physical": "1216x2688", "physicalDensity": 480}}}}
        if phone is not None:
            world["adb"]["phone"] = phone
        json.dump(world, open(os.path.join(self.w, "world.json"), "w"))
        if pause:
            open(os.path.join(self.w, "pause"), "w").close()
        env = {"PATH": os.path.join(self.w, "bin") + ":" + os.environ["PATH"], "HOME": os.path.join(self.w, "home"), "LANG": "C.UTF-8",
               "BRIDGE_WORLD": os.path.join(self.w, "world.json"), "BRIDGE_STUB_LOG": os.path.join(self.w, "adb.log"),
               "BRIDGE_CAST_PORT": str(port), "BRIDGE_CAST_LOG": os.path.join(self.w, "fake.log"), "BRIDGE_CAST_DIR": self.w,
               "BRIDGE_CAST_FWD": os.path.join(self.w, "forwards"), "LARES_CAST_JAR": jar,
               "BRIDGE_PHONE_EVENTS": os.path.join(self.w, "events"),
               "LARES_BRIDGE_STATE": os.path.join(self.w, "state"), "LARES_BRIDGE_RUNTIME": os.path.join(self.w, "rt")}
        self.ev, self.t0 = [], time.time()
        self.p = subprocess.Popen([sys.executable, "-B", os.path.join(BRIDGE, "lares-cast"), serial] + args, stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env, start_new_session=True)
        if drain:
            threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                e = json.loads(line)
                e["_t"] = time.time() - self.t0
                self.ev.append(e)
            except ValueError:
                pass

    def wait(self, pred, timeout=12):
        end = time.time() + timeout
        while time.time() < end:
            for e in list(self.ev):
                if pred(e):
                    return e
            time.sleep(0.05)
        return None

    def events(self, *args):
        """Append a line to the fake phone's events log (and the world's lock, so a re-read agrees)."""
        subprocess.run([sys.executable, os.path.join(STUBS, "phone_events.py"), "--file", os.path.join(self.w, "events"), "--world",
                        os.path.join(self.w, "world.json")] + list(args), check=True)

    def control(self):
        """The control messages the fake phone received, as hex."""
        try:
            return [l.split()[2] for l in open(os.path.join(self.w, "fake.log")) if l.startswith("C ")]
        except OSError:
            return []

    def fake_events(self):
        try:
            return [l.split(" ", 2)[2].strip() for l in open(os.path.join(self.w, "fake.log")) if l.startswith("E ")]
        except OSError:
            return []

    def followers(self):
        """The pids of this cast's `adb logcat` children."""
        out = []
        for d in os.listdir("/proc"):
            if not d.isdigit():
                continue
            try:
                ppid = int(open("/proc/%s/stat" % d).read().rsplit(")", 1)[1].split()[1])
                cmd = open("/proc/%s/cmdline" % d).read()
            except (OSError, IndexError, ValueError):
                continue
            if ppid == self.p.pid and "logcat" in cmd:
                out.append(int(d))
        return out

    def params(self):
        for line in open(os.path.join(self.w, "fake.log")):
            if line.startswith("P "):
                return json.loads(line.split(" ", 2)[2])
        return None

    def trace(self):
        out = []
        try:
            for line in open(os.path.join(self.w, "state-cache", "trace.jsonl")):
                r = json.loads(line)
                if r.get("kind") == "cast":
                    out.append(r)
        except OSError:
            pass
        return out

    def stop(self, wait=8):
        try:
            self.p.stdin.write(b'{"quit":true}\n')
            self.p.stdin.flush()
            self.p.stdin.close()
        except (OSError, ValueError):
            pass
        try:
            self.p.wait(timeout=wait)
        except subprocess.TimeoutExpired:
            os.killpg(self.p.pid, 9)
        time.sleep(0.2)
        return self.p.returncode


def is_ev(name, **kw):
    return lambda e: e.get("event") == name and all(e.get(k) == v for k, v in kw.items())


def cast_tool():
    root = tempfile.mkdtemp(prefix="bridge_cast_cases.")
    try:
        # pure: the phone's own figures
        out = "Physical size: 1216x2688\nOverride size: 1080x2400\nPhysical density: 480\nOverride density: 420\n"
        check("wm: the phone's figures, override over physical", wm.parse_wm(out), (1080, 2400, 420))
        check("wm: physical only", wm.parse_wm("Physical size: 1216x2688\nPhysical density: 480\n"), (1216, 2688, 480))
        check("wm: nothing says nothing", wm.parse_wm(""), (None, None, None))
        check("dpi from the phone's own screen: 540 of 1216 px at 480", wm.dpi_for(540, 1216, 480), 213)
        check("dpi: the same layout at the override's figures", wm.dpi_for(540, 1080, 420), 210)
        check("dpi: clamped to 640 and to 120", (wm.dpi_for(5000, 1000, 480), wm.dpi_for(100, 3000, 160)), (640, 120))
        check("dpi: unknown figures give none", (wm.dpi_for(540, None, 480), wm.dpi_for(540, 1216, None)), (None, None))
        check("new-display parse", (wm.parse_new_display("540x1200"), wm.parse_new_display("540x1200/300")), ((540, 1200, None), (540, 1200, 300)))
        check("new-display rejects words", _raises(lambda: wm.parse_new_display("big")), True)
        # a virtual display, dpi worked out; max_size dropped; flow on, off, on; a client; the trace
        r = Run(root, "vd", ["--new-display", "540x1200", "--max-size", "1600"])
        ready = r.wait(is_ev("ready"))
        check("cast: ready with the virtual display's own size", ready and (ready["width"], ready["height"]), (540, 1200))
        pr = r.params() or {}
        check("new-display argv: new_display=WxH/dpi with the dpi from the phone's own screen", pr.get("new_display"), "540x1200/213")
        check("new-display argv: vd_destroy_content=false", pr.get("vd_destroy_content"), "false")
        check("new-display argv: no max_size with a new display", "max_size" in pr, False)
        check("new-display argv: the rest is as before", [pr.get(k) for k in ("video_codec", "control", "tunnel_forward", "cleanup")], ["h264", "true", "true", "true"])
        check("the phone was asked its size and density once", open(os.path.join(r.w, "adb.log")).read().count("shell wm size; wm density"), 1)
        check("flow: on at the first frame", bool(r.wait(is_ev("flow", on=True), 6)), True)
        check("flow: no off event while frames come", any(e.get("event") == "flow" and e["on"] is False for e in r.ev), False)
        c = socket.create_connection(("127.0.0.1", int(ready["url"].rsplit(":", 1)[1])), timeout=3)
        check("client: connected event", bool(r.wait(is_ev("client", connected=True), 4)), True)
        check("the client gets an FLV stream", c.recv(3), b"FLV")
        c.close()
        open(os.path.join(r.w, "pause"), "w").close()
        tp = time.time() - r.t0
        off = r.wait(is_ev("flow", on=False), 6)
        truth("flow goes off after 1.5 s with no frame from the phone", bool(off) and 1.2 <= off["_t"] - tp <= 3.2, (off or {}).get("_t", 0) - tp)
        os.unlink(os.path.join(r.w, "pause"))
        check("flow: on again when frames come back", bool(r.wait(lambda e: e.get("event") == "flow" and e["on"] is True and e["_t"] > off["_t"], 6)), True)
        check("flow events alternate on, off, on", [e["on"] for e in r.ev if e.get("event") == "flow"], [True, False, True])
        rc = r.stop()
        check("quit on stdin: exit 0 and an `ended` event", (rc, bool(r.wait(is_ev("ended", reason="stopped"), 1))), (0, True))
        tr = r.trace()
        names = [t["event"] for t in tr]
        truth("trace: every event of the cast is in the bridge trace (kind cast)", all(k in names for k in ("ready", "flow", "client", "ended")), names)
        truth("trace: the fields are the event's", any(t["event"] == "ready" and t.get("width") == 540 and t.get("url", "").startswith("tcp://127.0.0.1:") for t in tr), tr[:3])
        check("trace: the stdout events and the trace agree in number", len([t for t in tr if t["event"] != "dpi"]), len(r.ev))
        truth("trace: the dpi decision is told too", any(t["event"] == "dpi" and t.get("dpi") == 213 and t.get("density") == 480 for t in tr), tr)
        # the override wins
        r = Run(root, "ovr", ["--new-display", "540x1200"], wm_world={"physical": "1216x2688", "override": "1080x2400", "physicalDensity": 480, "overrideDensity": 420})
        r.wait(is_ev("ready"))
        check("new-display: the phone's override figures win (dpi 210)", (r.params() or {}).get("new_display"), "540x1200/210")
        r.stop()
        # an explicit dpi passes through, and the phone is not asked
        r = Run(root, "dpi", ["--new-display", "540x1200/300"])
        r.wait(is_ev("ready"))
        check("new-display: an explicit dpi is passed as given", (r.params() or {}).get("new_display"), "540x1200/300")
        check("...and the phone is not asked its size", "wm size" in open(os.path.join(r.w, "adb.log")).read(), False)
        r.stop()
        # the main display: as before
        r = Run(root, "main", ["--max-size", "1600", "--bit-rate", "6M", "--max-fps", "60"])
        r.wait(is_ev("ready"))
        pr = r.params() or {}
        check("main display: max_size / bit rate / fps as before, no new_display, no vd_destroy_content",
              (pr.get("max_size"), pr.get("video_bit_rate"), pr.get("max_fps"), "new_display" in pr, "vd_destroy_content" in pr), ("1600", "6000000", "60", False, False))
        r.stop()
        # a phone that gives no picture from the start: no `on`, an `off` after 1.5 s
        r = Run(root, "dark", [], pause=True)
        r.wait(is_ev("ready"))
        off = r.wait(is_ev("flow", on=False), 6)
        truth("flow: a phone with no picture says off 1.5 s after ready, and never on", bool(off) and 1.2 <= off["_t"] - r.ev[[e.get("event") for e in r.ev].index("ready")]["_t"] <= 3.2
              and not any(e.get("event") == "flow" and e["on"] for e in r.ev), r.ev)
        r.stop()
        # an error is an event and a trace line too
        r = Run(root, "nojar", [], jar="/nonexistent/scrcpy-server")
        try:
            r.p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            pass
        time.sleep(0.3)
        check("error: an event, exit 1", (r.p.returncode, bool(r.wait(is_ev("error"), 1))), (1, True))
        truth("error: in the trace", any(t["event"] == "error" and "jar" in t["reason"] for t in r.trace()), r.trace())
    finally:
        shutil.rmtree(root, ignore_errors=True)


def cast_lock_tool():
    """The real lares-cast against the fake phone: --flex, wake, resize, the `lock` events and their follower, the clean exit."""
    root = tempfile.mkdtemp(prefix="bridge_cast_cases.")
    try:
        # --flex: only with a new display
        r = Run(root, "flex", ["--new-display", "656x1296", "--flex"])
        r.wait(is_ev("ready"))
        check("--flex: the server is started with flex_display=true", (r.params() or {}).get("flex_display"), "true")
        # wake: KEYCODE_WAKEUP down and up
        r.p.stdin.write(b'{"wake":true}\n')
        r.p.stdin.flush()
        time.sleep(0.6)
        down, up = (bytes([0, 0]) + struct.pack(">III", 224, 0, 0)).hex(), (bytes([0, 1]) + struct.pack(">III", 224, 0, 0)).hex()
        truth("wake is KEYCODE_WAKEUP down and up", [m for m in r.control() if m.startswith("00")] == [down, up], r.control())
        # resize: the virtual display's new size, a new session packet, the encoder restarted at it
        r.p.stdin.write(b'{"resize":{"w":544,"h":1104}}\n')
        r.p.stdin.flush()
        sz = r.wait(is_ev("size", width=544, height=1104), 8)
        truth("resize with --flex: RESIZE_DISPLAY (type 21) reaches the phone", "15" "0220" "0450" in r.control(), r.control())
        truth("...and the phone re-encodes at the new size: a size event", bool(sz), r.ev)
        truth("...and it logged the resize", "resize 544x1104" in r.fake_events(), r.fake_events())
        for bad in (b'{"resize":{"w":0,"h":10}}\n', b'{"resize":{"w":"x"}}\n', b'{"resize":3}\n'):
            r.p.stdin.write(bad)
        r.p.stdin.flush()
        time.sleep(0.4)
        check("resize: a size out of range or malformed sends nothing and does not end the cast", ([m for m in r.control() if m.startswith("15")], r.p.poll()),
              (["15" "0220" "0450"], None))
        r.stop()
        r = Run(root, "noflex", ["--new-display", "656x1296"])
        r.wait(is_ev("ready"))
        check("no flex_display without --flex", "flex_display" in (r.params() or {}), False)
        r.p.stdin.write(b'{"resize":{"w":544,"h":1104}}\n')
        r.p.stdin.flush()
        time.sleep(0.8)
        check("resize is ignored without --flex: nothing reaches the phone, no new size", ([m for m in r.control() if m.startswith("15")], any(e.get("event") == "size" for e in r.ev)),
              ([], False))
        r.stop()
        r = Run(root, "mainflex", ["--flex", "--max-size", "1600"])
        r.wait(is_ev("ready"))
        check("--flex on the main display does nothing (it needs --new-display)", "flex_display" in (r.params() or {}), False)
        r.stop()
        # the lock: the first read, then the events log
        r = Run(root, "lock", [], phone={"locked": True, "awake": False, "pin": "1"})
        r.wait(is_ev("ready"))
        first = r.wait(is_ev("lock"), 6)
        check("lock: the first event is the phone's own answer after `ready`", (first or {}).get("keyguard"), True)
        locks = lambda: [(e["keyguard"], e["awake"]) for e in r.ev if e.get("event") == "lock"]
        check("lock: ...asleep", locks(), [(True, False)])
        for _ in range(40):
            if " logcat " in open(os.path.join(r.w, "adb.log")).read():
                break
            time.sleep(0.05)
        truth("the follower runs: adb logcat -b events -v epoch -T <the phone's clock> -s the two tags", any(
            re.fullmatch(r"adb -s S1 logcat -b events -v epoch -T \d\d-\d\d \d\d:\d\d:\d\d\.000 -s wm_set_keyguard_shown power_screen_state", l.strip())
            for l in open(os.path.join(r.w, "adb.log"))), open(os.path.join(r.w, "adb.log")).read())
        time.sleep(0.5)
        r.events("screen", "on")
        r.wait(lambda e: e.get("event") == "lock" and e["awake"], 6)
        r.events("keyguard", "1", "0", "1")                   # the way out: shown, going away
        r.wait(lambda e: e.get("event") == "lock" and not e["keyguard"], 6)
        r.events("raw", "%.3f 1 1 I wm_set_keyguard_shown: [7,1,0,0,0,setKeyguardShown]" % time.time())     # the virtual display
        r.events("screen", "on")                              # no change
        r.events("keyguard", "1", "1", "0")                   # locked again, on the always-on display
        r.wait(lambda e: e.get("event") == "lock" and e["keyguard"] and e["_t"] > 1, 6)
        time.sleep(0.5)
        check("lock: events only at CHANGES of the pair, going away unlocked, another display ignored, the AOD lock locked",
              locks(), [(True, False), (True, True), (False, True), (True, True)])
        truth("lock events are in the trace too", sum(1 for t in r.trace() if t["event"] == "lock") == 4, r.trace())
        # the follower ends (adbd restarted): started again after 1 s, then 2 s, and the lock read again
        gaps, prev = [], None
        for k in range(2):
            fol = r.followers()
            if not fol:
                break
            t0 = time.time()
            os.kill(fol[0], 9)
            n0 = open(os.path.join(r.w, "adb.log")).read().count(" logcat ")
            end = time.time() + 6
            while time.time() < end and open(os.path.join(r.w, "adb.log")).read().count(" logcat ") == n0:
                time.sleep(0.03)
            gaps.append(time.time() - t0)
            time.sleep(0.4)
        truth("the follower restarts with backoff: 1 s, then 2 s", len(gaps) == 2 and 0.8 <= gaps[0] <= 1.9 and 1.8 <= gaps[1] <= 3.2, gaps)
        # a change while no follower ran is told by the read that starts the next one
        fol = r.followers()
        w = json.load(open(os.path.join(r.w, "world.json")))
        w["adb"]["phone"]["locked"], w["adb"]["phone"]["awake"] = False, False
        json.dump(w, open(os.path.join(r.w, "world.json"), "w"))
        if fol:
            os.kill(fol[0], 9)
        told = r.wait(lambda e: e.get("event") == "lock" and not e["keyguard"] and not e["awake"], 8)
        truth("a change made while the follower was gone is told by the re-read", bool(told), locks())
        time.sleep(0.8)
        r.events("screen", "on")
        truth("...and the new follower delivers events", bool(r.wait(lambda e: e.get("event") == "lock" and e["awake"] and e["_t"] > (told or {"_t": 99})["_t"], 6)), locks())
        pid = r.p.pid
        fol = r.followers()
        os.kill(pid, 9)
        time.sleep(1.0)
        truth("the follower dies with the cast (a SIGKILLed cast leaves no logcat)", bool(fol) and not any(os.path.exists("/proc/%d" % f) and
              "logcat" in open("/proc/%d/cmdline" % f).read() for f in fol), fol)
        for f in fol:
            try:
                os.kill(f, 9)
            except OSError:
                pass
        try:
            os.killpg(pid, 9)
        except OSError:
            pass
        # a phone that does not answer about its lock says nothing
        r = Run(root, "nolock", [])
        r.wait(is_ev("ready"))
        time.sleep(2.0)
        check("a phone that does not answer about its lock says no lock event, and the cast is fine", (any(e.get("event") == "lock" for e in r.ev), r.p.poll()), (False, None))
        r.stop()
        # the clean exit: a quit while a thread is mid-write of a lock event, with the reader draining (a storm of events) and with nobody
        # reading (a thread blocked in write holds stdout's lock: the interpreter's own shutdown dies of it, "could not acquire lock for
        # <stdout>", exit -6 as on the real phone); exit 0 both times
        codes = []
        for k, drain in enumerate((True, False)):
            r = Run(root, "storm%d" % k, [], phone={"locked": True, "awake": True, "pin": "1"}, drain=drain)
            r.wait(is_ev("lock"), 6) if drain else time.sleep(1.0)
            stop = threading.Event()

            def storm(r=r, stop=stop):
                i = 0
                with open(os.path.join(r.w, "events"), "a") as fh:
                    while not stop.is_set():
                        i += 1
                        fh.write("%15.3f 1 1 I power_screen_state: [%d,0,0,0]\n" % (time.time(), i % 2))
                        fh.flush()
                        time.sleep(0.0003)
            th = threading.Thread(target=storm, daemon=True)
            th.start()
            time.sleep(1.0 if drain else 4.0)
            codes.append(r.stop(12))
            stop.set()
            th.join(1)
        check("a cast quit while it is busy writing exits 0, with the reader draining and with nobody reading (a busy cast exits 0 on quit)", codes, [0, 0])
    finally:
        shutil.rmtree(root, ignore_errors=True)


def probe_media(path):
    """ffprobe of a file: {codec_type: (codec_name, width, height, frames read, duration s)}, {} when it reads nothing."""
    p = subprocess.run(["ffprobe", "-v", "error", "-count_frames", "-show_streams", "-of", "json", path], capture_output=True, text=True)
    try:
        st = json.loads(p.stdout).get("streams", [])
    except ValueError:
        return {}
    return {s["codec_type"]: (s.get("codec_name"), s.get("width"), s.get("height"), int(s.get("nb_read_frames") or 0), float(s.get("duration") or 0))
            for s in st}


def record_events(r):
    return [e for e in r.ev if e.get("event") == "record"]


def cast_record_tool():
    """--record: the real lares-cast against the fake phone writes a file beside the live stream."""
    root = tempfile.mkdtemp(prefix="bridge_cast_cases.")
    try:
        rd = os.path.join(root, "Videos")
        out = os.path.join(rd, "phone-1.mp4")
        # a Mirror: quit after ~3 s; a player connected meanwhile still gets its stream
        r = Run(root, "rec", ["--max-size", "1600", "--record", out])
        ready = r.wait(is_ev("ready"))
        time.sleep(1.0)
        c = socket.create_connection(("127.0.0.1", int(ready["url"].rsplit(":", 1)[1])), timeout=3)
        c.settimeout(3)
        got = b""
        try:
            while len(got) < 20000:
                b = c.recv(65536)
                if not b:
                    break
                got += b
        except OSError:
            pass
        c.close()
        truth("record: a live player beside the file gets its own FLV stream", got[:3] == b"FLV" and len(got) >= 20000, len(got))
        truth("record: while it runs the file grows as PATH.part.flv (streamable FLV), PATH not yet there",
              os.path.getsize(out + ".part.flv") > 1000 and not os.path.exists(out) if os.path.exists(out + ".part.flv") else False, os.listdir(rd) if os.path.isdir(rd) else None)
        time.sleep(1.5)
        rc = r.stop(30)
        ev = record_events(r)
        m = probe_media(out)
        v = m.get("video") or (None, 0, 0, 0, 0)
        check("record: the end remuxes the part into PATH (a `record` event with PATH, exit 0, the part gone)",
              (rc, [e.get("path") for e in ev], os.path.exists(out + ".part.flv")), (0, [out], False))
        truth("record: the file holds the phone's picture (an mp4 ffprobe reads: h264 at the stream's size, frames)",
              v[0] == "h264" and (v[1], v[2]) == (192, 384) and v[3] > 30, m)
        truth("record: the file keeps the phone's own times (its duration is the time it ran, though the live player's are all zero)",
              1.8 <= v[4] <= 5.0, m)
        names = [e["event"] for e in r.ev]
        truth("record: `record` comes after `ended`", "ended" in names and "record" in names and names.index("record") > names.index("ended"), names)
        # the same name again (a restarted cast): -2, the first file left alone
        r = Run(root, "rec2", ["--record", out])
        r.wait(is_ev("ready"))
        time.sleep(1.5)
        r.stop(30)
        out2 = os.path.join(rd, "phone-1-2.mp4")
        check("record: a name already taken becomes <stem>-2 and the first file is left alone", ([e.get("path") for e in record_events(r)], v[3] == probe_media(out).get("video", (0,) * 5)[3]),
              ([out2], True))
        # TERM (the shell going: setpriv's pdeathsig) finishes the file too
        out3 = os.path.join(rd, "term.mp4")
        r = Run(root, "term", ["--record", out3])
        r.wait(is_ev("ready"))
        time.sleep(1.5)
        os.kill(r.p.pid, 15)
        try:
            r.p.wait(timeout=30)
        except subprocess.TimeoutExpired:
            os.killpg(r.p.pid, 9)
        time.sleep(0.2)
        check("record: TERM leaves the mp4 (the end remuxes the part into PATH on a TERM too)",
              ([e.get("path") for e in record_events(r)], (probe_media(out3).get("video") or (None,))[0], os.path.exists(out3 + ".part.flv")), ([out3], "h264", False))
        # with sound: both streams
        out4 = os.path.join(rd, "av.mp4")
        r = Run(root, "recav", ["--audio", "--record", out4])
        r.wait(is_ev("ready"))
        time.sleep(2.5)
        r.stop(30)
        m = probe_media(out4)
        truth("record --audio: the mp4 holds h264 and aac, both with frames", (m.get("video") or (None,))[0] == "h264" and (m.get("audio") or (None,))[0] == "aac"
              and m["video"][3] > 30 and m["audio"][3] > 30, m)
        dec = subprocess.run(["ffmpeg", "-v", "error", "-i", out4, "-f", "null", "-"], capture_output=True, text=True)
        check("record --audio: ffmpeg decodes it clean", dec.stderr.strip(), "")
        # a desktop resized mid-recording: the new sequence header is written again, both sizes are in the file and decode clean
        out5 = os.path.join(rd, "desk.mp4")
        r = Run(root, "recdesk", ["--new-display", "320x640", "--flex", "--record", out5])
        r.wait(is_ev("ready"))
        time.sleep(1.5)
        r.p.stdin.write(b'{"resize":{"w":480,"h":800}}\n')
        r.p.stdin.flush()
        r.wait(is_ev("size", width=480, height=800), 8)
        time.sleep(1.5)
        r.stop(30)
        fr = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "frame=width,height", "-of", "csv=p=0", out5], capture_output=True, text=True)
        sizes = [l.strip() for l in fr.stdout.splitlines() if l.strip()]
        truth("record: a desktop resized mid-recording keeps both sizes in the file", "320,640" in sizes and "480,800" in sizes and sizes.index("480,800") > sizes.index("320,640"),
              sorted(set(sizes)))
        dec = subprocess.run(["ffmpeg", "-v", "error", "-i", out5, "-f", "null", "-"], capture_output=True, text=True)
        check("record: ...and decodes clean across the change", dec.stderr.strip(), "")
        # no picture ever came: nothing is kept, and the event says so
        out6 = os.path.join(rd, "dark.mp4")
        r = Run(root, "recdark", ["--record", out6], pause=True)
        r.wait(is_ev("ready"))
        time.sleep(1.0)
        r.stop(30)
        check("record: a phone that gave no picture leaves nothing (`record` {empty})", ([e.get("empty") for e in record_events(r)], sorted(f for f in os.listdir(rd) if f.startswith("dark"))),
              ([True], []))
        # a remux that fails: the part is kept and named (an ffmpeg that refuses `-c copy`; the fake phone's encoder is the real one)
        out7 = os.path.join(rd, "noremux.mp4")
        stub = "#!/bin/sh\nfor a in \"$@\"; do [ \"$a\" = copy ] && { echo 'boom: no muxer' >&2; exit 1; }; done\nexec /usr/bin/ffmpeg \"$@\"\n"
        r = Run(root, "recfail", ["--record", out7], bins={"ffmpeg": stub})
        r.wait(is_ev("ready"))
        time.sleep(1.5)
        r.stop(30)
        ev = record_events(r)
        truth("record: a remux that fails says why and names the part it kept (which ffprobe reads)", len(ev) == 1 and "boom" in ev[0].get("error", "")
              and ev[0].get("kept") == out7 + ".part.flv" and not os.path.exists(out7) and (probe_media(out7 + ".part.flv").get("video") or (None,))[0] == "h264", ev)
        # SIGKILL mid-cast: the part is a playable stream
        out8 = os.path.join(rd, "killed.mp4")
        r = Run(root, "reckill", ["--record", out8])
        r.wait(is_ev("ready"))
        time.sleep(2.0)
        os.kill(r.p.pid, 9)
        time.sleep(0.5)
        try:
            os.killpg(r.p.pid, 9)
        except OSError:
            pass
        m = probe_media(out8 + ".part.flv")
        truth("record: a SIGKILLed cast leaves PATH.part.flv, a stream ffprobe reads (h264, frames), and no PATH",
              (m.get("video") or (None,))[0] == "h264" and m["video"][3] > 20 and not os.path.exists(out8), m)
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    # ---- stream headers
    check("session packet parse", proto.parse_session(bytes.fromhex("80000001" "00000438" "00000870")), (1080, 2160, True))
    check("session packet build", proto.build_session(1080, 2160), bytes.fromhex("80000000" "00000438" "00000870"))
    check("media header config+key", proto.parse_media_header(bytes.fromhex("6000000000000000" "0000002a")), (True, True, 0, 42))
    check("media header pts", proto.parse_media_header(bytes.fromhex("2000000000012345" "00000010")), (False, True, 0x12345, 16))
    check("media header build", proto.build_media_header(0x12345, 16, key=True), bytes.fromhex("2000000000012345" "00000010"))
    check("session is bit 63", (proto.is_session(0x80), proto.is_session(0x60)), (True, False))
    # ---- control messages
    check("keycode down", proto.keycode(0, 4), bytes.fromhex("00" "00" "00000004" "00000000" "00000000"))
    check("keycode up", proto.keycode(1, 187), bytes.fromhex("00" "01" "000000bb" "00000000" "00000000"))
    check("keycode length", len(proto.keycode(0, 4)), 14)
    t = proto.touch("down", 100, 200, 1080, 2160)
    check("touch down bytes", t, bytes.fromhex("02" "00" "fffffffffffffffe" "00000064" "000000c8" "0438" "0870" "ffff" "00000000" "00000000"))
    check("touch length", len(t), 32)
    check("touch up pressure 0", proto.touch("up", 1, 2, 3, 4)[22:24], b"\0\0")
    check("touch move action", proto.touch("move", 1, 2, 3, 4)[1], 2)
    check("scroll down one notch", proto.scroll(10, 20, 1080, 2160, 0, -1),
          bytes.fromhex("03" "0000000a" "00000014" "0438" "0870" "0000" "f800" "00000000"))
    check("scroll length", len(proto.scroll(0, 0, 1, 1, 0, 0)), 21)
    check("scroll +16 saturates", proto.scroll(0, 0, 1, 1, 0, 16)[15:17], bytes.fromhex("7fff"))
    check("scroll -16", proto.scroll(0, 0, 1, 1, 0, -16)[15:17], bytes.fromhex("8000"))
    check("scroll clamp 99", proto.scroll(0, 0, 1, 1, 99, 0)[13:15], bytes.fromhex("7fff"))
    check("scroll 8 notches", proto.scroll(0, 0, 1, 1, 8, 0)[13:15], bytes.fromhex("4000"))
    check("text", proto.text("héj"), [bytes.fromhex("01" "00000004") + "héj".encode()])
    long = proto.text("é" * 200)
    check("text split: every part <= 300 bytes, whole characters", [len(m) - 5 <= 300 and m[5:].decode() == "é" * ((len(m) - 5) // 2) for m in long],
          [True] * len(long))
    check("text split: all of it", "".join(m[5:].decode() for m in long), "é" * 200)
    check("back_or_screen_on", proto.back_or_screen_on(1), bytes.fromhex("0401"))
    check("display power", (proto.display_power(True), proto.display_power(False)), (bytes.fromhex("0a01"), bytes.fromhex("0a00")))
    check("reset video", proto.reset_video(), bytes([17]))
    check("key table", [proto.KEYCODES[k] for k in ("back", "home", "recents", "power", "enter", "backspace", "del", "tab", "escape", "up", "down", "left", "right")],
          [4, 3, 187, 26, 66, 67, 112, 61, 111, 19, 20, 21, 22])
    check("resize display bytes (type 21, u16 width, u16 height, big-endian)", proto.resize_display(656, 1296), bytes.fromhex("15" "0290" "0510"))
    rec2 = bytes([1, 0x64, 0, 0x1F, 0xFF, 0xE1, 0, 3, 0x67, 0xAA, 0xBB, 1, 0, 2, 0x68, 0xCC])
    check("avcc params: the record's SPS and PPS as length-prefixed NAL units", proto.avcc_params(rec2), bytes.fromhex("00000003" "67aabb" "00000002" "68cc"))
    check("wakeup is Android's KEYCODE_WAKEUP", proto.KEYCODES["wakeup"], 224)
    # ---- the phone's lock: the events log and the first read
    ev = lambda tag, body, t="1763700000.250": "         %s  1234  1300 I %s: [%s]" % (t, tag, body)
    check("lock event: shown, not going away = the keyguard is up", clock.parse_event(ev("wm_set_keyguard_shown", "0,1,0,0,0,setKeyguardShown")), (1763700000.25, "keyguard", True))
    check("lock event: going away is not locked (the way out of the keyguard)", clock.parse_event(ev("wm_set_keyguard_shown", "0,1,0,1,0,keyguardGoingAway"))[2:], (False,))
    check("lock event: not shown = unlocked", clock.parse_event(ev("wm_set_keyguard_shown", "0,0,0,1,0,setKeyguardShown"))[2:], (False,))
    check("lock event: locked on the always-on display is locked", clock.parse_event(ev("wm_set_keyguard_shown", "0,1,1,0,0,setKeyguardShown"))[2:], (True,))
    check("another display's keyguard event is ignored (the virtual display)", clock.parse_event(ev("wm_set_keyguard_shown", "7,1,0,0,0,x")), None)
    check("screen state: first field 1 is awake, 0 asleep", [clock.parse_event(ev("power_screen_state", b))[1:] for b in ("1,0,0,0", "0,2,0,0")],
          [("awake", True), ("awake", False)])
    check("lock event: the log's header, other tags and garbage say nothing",
          [clock.parse_event(x) for x in ("--------- beginning of events", ev("am_proc_start", "1,2"), "", "x y z", ev("wm_set_keyguard_shown", "0,1"))], [None] * 5)
    tr = clock.Tracker(True, False, since=1763700000.0)
    seq = [tr.feed(ev("wm_set_keyguard_shown", "0,1,0,0,0,x")), tr.feed(ev("power_screen_state", "1,0,0,0")), tr.feed(ev("power_screen_state", "1,0,0,0")),
           tr.feed(ev("wm_set_keyguard_shown", "0,1,0,1,0,keyguardGoingAway")), tr.feed(ev("wm_set_keyguard_shown", "0,0,0,1,0,x"))]
    check("lock tracker: only a CHANGE of the pair is told", seq, [None, (True, True), None, (False, True), None])
    tr = clock.Tracker(False, True, since=1763700100.0)
    check("an event from before the read is ignored", tr.feed(ev("wm_set_keyguard_shown", "0,1,0,0,0,x", "1763700000.250")), None)
    rd = clock.parse_read("==now\n11-21 10:00:00.000\n==epoch\n1763700000.123456789\n" + open(os.path.join(HERE, "fixtures", "bridge", "lockstate_locked_dozing.txt")).read())
    check("lock read: the phone's clock, its epoch and its lock", rd, {"keyguard": True, "awake": False, "now": "11-21 10:00:00.000", "epoch": 1763700000.123456789})
    check("lock read: no clock is told as no clock (the follower is then not started)", clock.parse_read(open(os.path.join(HERE, "fixtures", "bridge", "lockstate_unlocked_awake.txt")).read())["now"], "")
    check("a phone that does not answer says no lock", (clock.parse_read(""), clock.parse_read("error: device offline")), (None, None))
    # ---- device messages
    check("device msg clipboard", proto.device_msg_need(bytes.fromhex("00" "00000003") + b"abc"), 8)
    check("device msg clipboard, short", proto.device_msg_need(bytes.fromhex("00" "00")), None)
    check("device msg ack", proto.device_msg_need(bytes([1])), 9)
    check("device msg uhid output", proto.device_msg_need(bytes.fromhex("02" "0001" "0003") + b"xyz"), 8)
    check("device msg unknown", proto.device_msg_need(bytes([99])), -1)
    # ---- Annex-B
    check("split annexb", proto.split_annexb(b"\0\0\0\1\x67\xaa\0\0\1\x68\xbb\0\0\0\1\x65\xcc\0"), [b"\x67\xaa", b"\x68\xbb", b"\x65\xcc"])
    check("annexb -> avcc", proto.annexb_to_avcc(b"\0\0\0\1\x65\xaa\xbb\0\0\1\x41\xcc"), bytes.fromhex("00000003" "65aabb" "00000002" "41cc"))
    # ---- FLV bytes
    check("flv header av", flv.header(True, True), bytes.fromhex("464c5601" "05" "00000009" "00000000"))
    check("flv header v", flv.header(True, False), bytes.fromhex("464c5601" "01" "00000009" "00000000"))
    check("flv avc frame", flv.avc_frame(0x01020304, True, b"\xaa\xbb"),
          bytes.fromhex("09" "000007" "020304" "01" "000000" "17" "01" "000000" "aabb" "00000012"))
    check("flv delta frame", flv.avc_frame(0, False, b"")[11], 0x27)
    check("flv aac seq", flv.aac_sequence(0, b"\x11\x90"), bytes.fromhex("08" "000004" "000000" "00" "000000" "af" "00" "1190" "0000000f"))
    check("flv aac frame", flv.aac_frame(5, b"\x01"), bytes.fromhex("08" "000003" "000005" "00" "000000" "af" "01" "01" "0000000e"))
    # ---- a real encode
    with tempfile.TemporaryDirectory() as d:
        h264 = os.path.join(d, "t.h264")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc=size=320x640:rate=30", "-frames:v", "60", "-c:v", "libx264",
                        "-preset", "ultrafast", "-tune", "zerolatency", "-x264-params", "aud=1:keyint=30", "-bsf:v", "h264_mp4toannexb",
                        "-f", "h264", h264], check=True)
        aus = split_aus(open(h264, "rb").read())
        check("encode: 60 access units", len(aus), 60)
        nals0 = proto.split_annexb(aus[0])
        types0 = [x[0] & 0x1F for x in nals0]
        check("encode: first AU holds SPS and PPS and an IDR", 7 in types0 and 8 in types0 and 5 in types0, True)
        cfg = b"".join(b"\0\0\0\1" + x for x in nals0 if x[0] & 0x1F in (7, 8))
        rec = proto.avc_config(cfg)
        sps = [x for x in nals0 if x[0] & 0x1F == 7][0]
        pps = [x for x in nals0 if x[0] & 0x1F == 8][0]
        want = bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]) + struct.pack(">H", len(sps)) + sps + b"\x01" + struct.pack(">H", len(pps)) + pps
        check("avc config record", rec, want)
        check("avc config rejects no SPS", (lambda: proto.avc_config(b"\0\0\0\1\x65\x00"))
              and _raises(lambda: proto.avc_config(b"\0\0\0\1\x65\x00")), True)
        out = flv.header(True, False) + flv.metadata(320, 640) + flv.avc_sequence(0, rec)
        for i, au in enumerate(aus):
            key = any(x[0] & 0x1F == 5 for x in proto.split_annexb(au))
            out += flv.avc_frame(i * 33, key, proto.annexb_to_avcc(au))
        path = os.path.join(d, "t.flv")
        open(path, "wb").write(out)
        pr = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-show_packets", "-of", "json", path],
                                       capture_output=True, text=True).stdout)
        st = pr["streams"][0]
        check("ffprobe: h264 320x640", (st["codec_name"], st["width"], st["height"]), ("h264", 320, 640))
        pk = [float(p["pts_time"]) for p in pr["packets"]]
        check("ffprobe: 60 packets, monotonic timestamps", (len(pk), pk == sorted(pk) and len(set(pk)) == len(pk)), (60, True))
        check("ffprobe: key frames at 0 and 30", [i for i, p in enumerate(pr["packets"]) if "K" in p["flags"]][:2], [0, 30])
        dec = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "null", "-"], capture_output=True, text=True)
        check("ffmpeg decodes it clean", dec.stderr.strip(), "")
        # audio: AAC seq header + frames in the same container
        aac = os.path.join(d, "a.adts")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1", "-ac", "2",
                        "-c:a", "aac", "-f", "adts", aac], check=True)
        b = open(aac, "rb").read()
        frames, i = [], 0
        while i + 7 <= len(b):
            ln = ((b[i + 3] & 3) << 11) | (b[i + 4] << 3) | (b[i + 5] >> 5)
            frames.append(b[i + 7:i + ln])
            i += ln
        asc = bytes([0x11, 0x90])
        out2 = flv.header(True, True) + flv.avc_sequence(0, rec) + flv.aac_sequence(0, asc)
        for k, f in enumerate(frames):
            out2 += flv.aac_frame(int(k * 1024 / 48), f)
        for k, au in enumerate(aus[:30]):
            out2 += flv.avc_frame(k * 33, k == 0, proto.annexb_to_avcc(au))
        p2 = os.path.join(d, "av.flv")
        open(p2, "wb").write(out2)
        pr2 = json.loads(subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", p2], capture_output=True, text=True).stdout)
        auds = [s for s in pr2["streams"] if s["codec_type"] == "audio"]
        check("ffprobe: aac stereo 48000", [(s["codec_name"], s["channels"], s["sample_rate"]) for s in auds], [("aac", 2, "48000")])
    cast_tool()
    cast_lock_tool()
    cast_record_tool()
    print("BRIDGE_CAST_CASES RESULT %s (%d checks%s)" % ("FAIL" if fails else "PASS", n, ", failed: " + ", ".join(fails) if fails else ""))
    return 1 if fails else 0


def _raises(f):
    try:
        f()
    except ValueError:
        return True
    return False


if __name__ == "__main__":
    sys.exit(main())
