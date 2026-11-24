#!/usr/bin/env python3
"""stt_helper_probe.py -- the REAL speech helper (tools/stt/lares_stt.py) with its stand-in decoder (LARES_STT_STUBS=1) and a fake `pw-record`
that plays a FLEURS clip, against the faults of round 8 (the user's takes of 2026-11-13): no model, no PipeWire, no desktop, seconds of CPU.
Run by tools/dev/stt_helper_probe.sh, which builds the work dir and says what each ARM breaks.

  H1  a take with a GPU decoder that raises (`[GPU] clWaitForEvents, error code: -14`, after its first good decode): the helper says
      `fallback` once with the cause in plain words, runs the SAME audio on the CPU model, and the take ends `stop` with the sentences a
      take with no fault wrote (nothing lost); the next take's `device` event says the CPU and why
  H2  an exception of the helper's own (a CPU decoder raising: no device's fault): `error` what "crash" and `ended` reason "error" --
      the loop never dies quietly -- and the helper takes the next take
  H3  a take beats: `beat` events with the main loop's age while it runs, none after it ended
Prints `SHP ok|FAIL <check>: <detail>` and `SHP RESULT PASS|FAIL`.
"""
import json
import os
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

W = Path(os.environ["SHP_DIR"])
PY = os.environ["SHP_PYTHON"]
HELPER = os.environ["SHP_HELPER"]
bad = 0


def say(ok, what, detail):
    global bad
    bad += not ok
    print("SHP %s %s: %s" % ("ok" if ok else "FAIL", what, detail), flush=True)


env = dict(os.environ, PATH=str(W / "bin") + ":" + os.environ["PATH"], LARES_STT_STUBS="1", LARES_STT_PCI_ROOT=str(W / "pci"),
           LARES_STT_STUB_GPUFAIL_FILE=str(W / "gpufail"), LARES_STT_STUB_RAISE_FILE=str(W / "raise"), LARES_FAKE_PW=str(W / "clip.raw"),
           LARES_STT_BEAT_S="0.3", PYTHONUNBUFFERED="1")
p = subprocess.Popen([PY, "-I", HELPER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(W / "helper.err", "w"), env=env,
                     text=True, bufsize=1)
q = queue.Queue()


def reader():
    for line in p.stdout:
        try:
            q.put((time.monotonic(), json.loads(line)))
        except ValueError:
            pass
    q.put((time.monotonic(), {"ev": "eof"}))


threading.Thread(target=reader, daemon=True).start()


def send(o):
    p.stdin.write(json.dumps(o) + "\n")
    p.stdin.flush()


def take(n, stop_after, wait_end=40.0, flag=None):
    """One take of the clip: its events up to `ended`, `stop` sent `stop_after` s after `running` (the clip plays meanwhile)."""
    send({"op": "start", "take": n, "lang": "en", "prior": "en", "node": "", "source": "mic", "device": "auto", "power": "ac",
          "model": "stub-speaker", "tidy": False, "policy": {"endSilenceMs": 500, "hopMs": 400, "thinkSilenceMs": 1500}, "text": None})
    evs, t_run, sent = [], None, False
    dl = time.monotonic() + wait_end
    while time.monotonic() < dl:
        try:
            t, e = q.get(timeout=0.2)
        except queue.Empty:
            if t_run and not sent and time.monotonic() - t_run > stop_after:
                send({"op": "stop", "take": n})
                sent = True
            continue
        if e.get("take") not in (None, n) and e.get("ev") != "eof":
            continue
        evs.append(e)
        if e["ev"] == "running":
            t_run = t
        if e["ev"] == "eof":
            break
        if e["ev"] == "ended":
            return evs
        if t_run and not sent and time.monotonic() - t_run > stop_after:
            send({"op": "stop", "take": n})
            sent = True
    return evs


def texts(evs):
    return [e["text"] for e in evs if e["ev"] == "seg" and e.get("text")]


def first(evs, ev):
    return next((e for e in evs if e["ev"] == ev), None)


# the helper is up: `ready`
t, e = q.get(timeout=15)
say(e.get("ev") == "ready", "boot", "the helper says ready")

# H3 + the control: a take with no fault
ctl = take(1, 12.0)
ctl_texts = texts(ctl)
beats = [e for e in ctl if e["ev"] == "beat"]
end = first(ctl, "ended")
say(bool(ctl_texts) and end and end["reason"] == "stop", "control take", "sentences %r, ended %r" % (ctl_texts, end))
say(len(beats) >= 3 and max(b["loopMs"] for b in beats) < 2500 and all(b["phase"] in ("step", "idle", "load") for b in beats),
    "H3 beats", "%d beats while the take ran, the loop's age at most %s ms" % (len(beats), max([b["loopMs"] for b in beats] or [-1])))
time.sleep(1.0)
quiet = []
while not q.empty():
    quiet.append(q.get()[1])
say(not any(e["ev"] == "beat" for e in quiet), "H3 quiet after the take", "no beat once the take ended (%d late lines)" % len(quiet))

# H1: the GPU decoder raises after its first good decode
send({"op": "unload"})                  # the control's decoder is let go: the next load meets the GPU stand-in
time.sleep(0.5)
(W / "gpufail").write_text("1\n")
g = take(2, 12.0)
fb = [e for e in g if e["ev"] == "fallback"]
end = first(g, "ended")
say(len(fb) == 1 and fb[0]["why"] == "the iGPU stopped responding" and fb[0]["to"] == "CPU" and "clWaitForEvents" in fb[0]["detail"],
    "H1 fallback said", json.dumps(fb)[:260])
say(texts(g) == ctl_texts and end and end["reason"] == "stop", "H1 nothing lost", "sentences %r against the control's %r; ended %r"
    % (texts(g), ctl_texts, end and end["reason"]))
g3 = take(3, 12.0)
dev = first(g3, "device")
say(dev is not None and dev["class"] == "cpu" and "earlier in this helper" in dev["why"] and not [e for e in g3 if e["ev"] == "fallback"]
    and texts(g3) == ctl_texts, "H1 the GPU rests", "next take's device %r; sentences as the control's: %s" % (dev, texts(g3) == ctl_texts))

# H2: a fault of the helper's own
(W / "raise").write_text("x\n")
r = take(4, 12.0)
err = first(r, "error")
end = first(r, "ended")
say(err is not None and err.get("what") == "crash" and "RuntimeError" in err.get("message", "") and end is not None and end["reason"] == "error",
    "H2 crash said, take ended", "error %r, ended %r" % (err, end and end["reason"]))
(W / "raise").unlink()
r2 = take(5, 12.0)
say(texts(r2) == ctl_texts and (first(r2, "ended") or {}).get("reason") == "stop", "H2 the helper lives on",
    "the next take wrote %r" % texts(r2))

send({"op": "quit"})
try:
    p.wait(timeout=10)
except subprocess.TimeoutExpired:
    p.kill()
print("SHP RESULT", "PASS" if not bad else "FAIL", flush=True)
sys.exit(1 if bad else 0)
