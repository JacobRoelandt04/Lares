#!/usr/bin/env python3
"""dictation_probe_helper.py -- a stand-in for the speech helper (tools/stt/lares_stt.py) that speaks its protocol and misbehaves on cue,
for tools/dev/dictation_probe_take.sh: the shell's side of a take (DictationService) against every way a helper has been seen to fail,
with no model, no audio and no PipeWire.

The shell starts it as it starts the real one (`setpriv --pdeathsig TERM -- <python> -I <script>`). Each process appends one line to
$DT_HELPERLOG per thing it does ("<pid> up", "<pid> op <json>", "<pid> term") so the probe counts starts and sees which process got
which op. At each `start` it reads $DT_CTL (JSON: take number -> scenario, "default" for the rest):

  normal      capture, listening, running, then the words (hyp "w0", hyp "w0 w1", seg "W0 w1.", hyp "w2", seg "W2."), 80 ms apart;
              `stop` -> `ended`
  slow        the same words 400 ms apart (time for the probe to move the caret between the two sentences)
  stall       capture, listening, running, two stderr lines, then the MAIN LOOP stops (take 9 of 2026-11-09: no word, no `ended`);
              `trace` is still answered from the stdin reader, as the real helper's is
  hang        nothing at all for the start (a main loop already stuck: no `capture`)
  slowload    capture, listening, then `running` only 3 s later; ops are answered meanwhile (a `ping` gets its `pong`); a `cancel`
              ends the take at once
  latewake    as slowload, but the main loop is busy for 3 s and reads its queue only after it: the cancel comes too late and `running`
              goes out for a take the shell has ended (the late `running` of the stuck-state report)
  crash       (round 8) capture, listening, running, hyp "w0", then what the real helper's `fail` says when its main loop raises: `error`
              what "crash" and `ended` reason "error" -- the helper itself lives on (lares_stt.py: a take ends with a stated reason)
  gpufail     (round 8) the words of `normal`, with the real helper's `fallback` event after the first hypothesis (a GPU decode raised,
              the CPU took over: sttlib/devguard.py); nothing is lost and the take goes on
  die         (round 8) capture, listening, running, then the PROCESS ends: a stderr line ("CUDA error: out of memory") and exit code 139
              (what a native library's segfault looks like to the shell: the toast and the take log must say why)
  silent      (round 8) capture, listening, running, hyp "w0", then EVERYTHING stops -- words, beats, answers to `stop` (a process whose
              threads are all away): only the shell's listening watchdog (`beatMs`) can end the take
  loopstuck   (round 8) as `stall`, but the helper's own beat thread goes on saying how long ago its main loop turned: the watchdog's
              `loopStuckMs` ends the take
Every scenario but `hang` / `silent` beats once per $DT_BEAT_S (0.4 s) while a take runs: {"ev":"beat","take","loopMs","phase"}, the
main loop's last turn (`last_turn`) as the real helper's `beats()` reads it.
SIGTERM is answered 300 ms late (the window in which a keep-warm restart's start would reach the old process).
"""
import json
import os
import queue
import signal
import sys
import threading
import time

PID = os.getpid()
_lock = threading.Lock()
_main_stuck = threading.Event()
# the beat thread's view (lares_stt.py `beats`): the live take, when the main loop last turned, whether the thread is silent (`silent`)
_beat = {"take": None, "last_turn": time.monotonic(), "off": False}


def emit(ev):
    with _lock:
        sys.stdout.write(json.dumps(ev) + "\n")
        sys.stdout.flush()


def log(what):
    p = os.environ.get("DT_HELPERLOG", "")
    if p:
        with open(p, "a", encoding="utf-8") as f:
            f.write("%d %s\n" % (PID, what))


def _term(signum, frame):
    log("term")
    time.sleep(0.3)
    os._exit(0)


def reader(q):
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except ValueError:
            continue
        log("op " + json.dumps(cmd, separators=(",", ":")))
        if cmd.get("op") == "trace":
            # the real helper's shape (lares_stt.trace): every thread's frames and the main loop's state
            emit({"ev": "trace", "why": cmd.get("why", ""), "loop": "the main loop last turned 9.9 s ago; take stuck",
                  "threads": ["MainThread: dictation_probe_helper.py:%d stuck_decode" % 1, "reader: dictation_probe_helper.py:1 reader"]})
            continue
        q.put(cmd)
    q.put({"op": "quit"})


def scenario(take):
    try:
        ctl = json.load(open(os.environ.get("DT_CTL", ""), encoding="utf-8"))
    except (OSError, ValueError):
        ctl = {}
    return ctl.get(str(take), ctl.get("default", "normal"))


def beats():
    period = float(os.environ.get("DT_BEAT_S", "0.4"))
    while True:
        time.sleep(period)
        if _beat["take"] is None or _beat["off"]:
            continue
        emit({"ev": "beat", "take": _beat["take"], "loopMs": int((time.monotonic() - _beat["last_turn"]) * 1000), "phase": "step"})


def stuck_decode():
    _main_stuck.set()
    while True:
        time.sleep(3600)


def main():
    signal.signal(signal.SIGTERM, _term)
    log("up")
    emit({"ev": "ready", "v": 3})
    q = queue.Queue()
    threading.Thread(target=reader, args=(q,), name="reader", daemon=True).start()
    threading.Thread(target=beats, name="beat", daemon=True).start()
    take, kind, plan, t0, ended = None, None, [], 0.0, True
    while True:
        try:
            cmd = q.get(timeout=0.02)
        except queue.Empty:
            cmd = None
        now = time.monotonic()
        _beat["last_turn"] = now
        if cmd is not None:
            op = cmd.get("op")
            if op == "quit":
                return 0
            if op == "ping":
                emit({"ev": "pong", "n": cmd.get("n")})
            elif op == "start":
                take, kind, t0, ended = cmd.get("take"), scenario(cmd.get("take")), now, False
                _beat["take"], _beat["off"] = take, kind == "hang"
                if kind == "hang":
                    stuck_decode()
                emit({"ev": "capture", "take": take, "ms": 1})
                if kind in ("normal", "slow", "gpufail"):
                    k = 5.0 if kind == "slow" else 1.0
                    plan = [(0.05, {"ev": "listening"}), (0.10, {"ev": "running", "device": "CPU"}),
                            (0.12 + 0.08 * k, {"ev": "hyp", "seg": 1, "rev": 1, "stable": "", "text": "w0"}),
                            (0.12 + 0.09 * k, {"ev": "fallback", "from": "GPU+CPU", "to": "CPU", "why": "the iGPU stopped responding",
                                               "detail": "RuntimeError: [GPU] clWaitForEvents, error code: -14"} if kind == "gpufail" else None),
                            (0.12 + 0.16 * k, {"ev": "hyp", "seg": 1, "rev": 2, "stable": "w0", "text": "w0 w1"}),
                            (0.12 + 0.24 * k, {"ev": "seg", "seg": 1, "text": "W0 w1.", "raw": "W0 w1.", "rules": []}),
                            (0.12 + 0.32 * k, {"ev": "hyp", "seg": 2, "rev": 1, "stable": "", "text": "w2"}),
                            (0.12 + 0.36 * k, {"ev": "hyp", "seg": 2, "rev": 2, "stable": "w2", "text": "w2 w3"}),
                            (0.12 + 0.40 * k, {"ev": "seg", "seg": 2, "text": "W2.", "raw": "W2.", "rules": []})]
                elif kind == "crash":
                    plan = [(0.05, {"ev": "listening"}), (0.10, {"ev": "running", "device": "CPU"}),
                            (0.25, {"ev": "hyp", "seg": 1, "rev": 1, "stable": "", "text": "w0"}), (0.40, "crash")]
                elif kind == "die":
                    plan = [(0.05, {"ev": "listening"}), (0.10, {"ev": "running", "device": "GPU+CPU"}), (0.30, "die")]
                elif kind == "silent":
                    plan = [(0.05, {"ev": "listening"}), (0.10, {"ev": "running", "device": "CPU"}),
                            (0.25, {"ev": "hyp", "seg": 1, "rev": 1, "stable": "", "text": "w0"}), (0.40, "silent")]
                elif kind in ("stall", "loopstuck"):
                    # the stall in the same turn as `running`: no stop can come between them
                    plan = [(0.05, {"ev": "listening"}),
                            (0.10, {"ev": "running", "device": "GPU+CPU" if kind == "loopstuck" else "CPU"}), (0.10, "stall")]
                elif kind in ("slowload", "latewake"):
                    plan = [(0.05, {"ev": "listening"}), (0.10, "busy" if kind == "latewake" else None),
                            (3.0, {"ev": "running", "device": "CPU"})]
            elif op == "cancel" and cmd.get("take") == take and not ended:
                emit({"ev": "ended", "take": take, "reason": "cancel", "segs": 0})
                ended, plan = True, []
            elif op == "stop" and cmd.get("take") == take and not ended:
                # what was planned for the words goes out first (the last sentence finished), then the end
                for _, ev in plan:
                    if isinstance(ev, dict):
                        emit(dict(ev, take=take))
                emit({"ev": "ended", "take": take, "reason": "stop", "segs": 2})
                ended, plan = True, []
        while plan and now - t0 >= plan[0][0]:
            _, ev = plan.pop(0)
            if ev == "crash":
                emit({"ev": "error", "take": take, "what": "crash", "message": "RuntimeError: the decoder did not return",
                      "detail": "decoders.py:232 run | RuntimeError"})
                emit({"ev": "ended", "take": take, "reason": "error", "segs": 0})
                ended, plan = True, []
            elif ev == "die":
                sys.stderr.write("fake helper: CUDA error: out of memory\n")
                sys.stderr.flush()
                os._exit(139)
            elif ev == "silent":
                _beat["off"] = True
                while True:                     # every thread away: no word, no beat, no answer (the stop included)
                    time.sleep(3600)
            elif ev == "stall":
                sys.stderr.write("fake helper: decoding seg 1\n")
                sys.stderr.write("fake helper: the decoder did not return\n")
                sys.stderr.flush()
                stuck_decode()
            elif ev == "busy":
                time.sleep(3.0)                 # the main loop away: the queue waits, and so does the cancel
                now = time.monotonic()
            elif ev is not None:
                emit(dict(ev, take=take))


if __name__ == "__main__":
    sys.exit(main())
