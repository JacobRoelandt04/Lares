#!/usr/bin/env python3
"""lares-stt -- the dictation helper: microphone in, live hypotheses out, one JSON object per line (research section 8.6).

A supervised child of the shell (modules/dictation/DictationService.qml starts it under `setpriv --pdeathsig TERM --` with the
private venv's interpreter). It owns the capture (pw-record on the node the shell names), the VAD, the model, the language choice
and the revision policy (sttlib/policy.py); it knows nothing of Wayland or of where the text goes.

shell -> helper     {"op":"start","take":7,"lang":"auto|en|nl","prior":"en","node":"<node.name>","device":"auto|cuda|gpu|cpu",
                     "power":"ac|battery","model":"auto|<id>","tidy":false,"policy":{...},"text":{...},"source":"mic|window"}
                    {"op":"window","take":7,"pid":1234,"title":"...","watch":true,"cwd":false}
                    {"op":"stop","take":7}   {"op":"cancel","take":7}   {"op":"unload"}   {"op":"quit"}
                    {"op":"ping","n":3}      the main loop answers {"ev":"pong","n":3} (round 6: the shell's watchdog)
                    {"op":"trace","why":"stop"}   answered by the STDIN READER, not the main loop (which may be what is stuck):
                                             {"ev":"trace","threads":[...],"loop":"..."} -- every thread's stack and how long ago
                                             the main loop last turned
helper -> shell     ready, capture, listening, device, loading, loaded, running, lang, hyp, think, seg, stats, ended, error, beat,
                    fallback (round 8, below) (the
                    research's table; `hyp` carries the whole utterance, `stable` is a prefix of `text` and never shrinks within a
                    `seg`, `seg` is final and carries `raw`, what the model wrote, beside `text` and `rules`, the names of the text rules
                    that changed it; `device` says where the take runs and why; `think` says a pause after a filler keeps the
                    sentence open). `text` is shell.jsonc's `dictation.text` verbatim, for the policy's text rules (sttlib/policy.py).
                    Round 5's two takes add: `speech` (an utterance opened: someone is speaking), `sources` (a window take's
                    linked streams, each time the set changes, the first picture too) and `context` (the cwd of a terminal
                    window, asked by `window`'s "cwd").

THE TWO SOURCES (round 5). "mic" (the default): pw-record on the node the shell names. "window" (fn+Ctrl+F10): a stereo pw-record
that nothing links (`node.autoconnect = false`); the shell's `window` op names the focused window's pid, and a StreamWatch
(sttlib/sources.py) links that window's output streams into it as they come and go. A window take has no no-audio stop (a paused
video sends nothing), and a capture that falls silent with a sentence open is fed the silence the wall clock says it was (up to
thinkSilenceMs + 0.5 s), so a sentence a video paused in is written at the pause, not at the next word. `window`'s "cwd" (a voice
ask) answers `context`: the directory of the shell under a terminal window (sources.terminal_cwd), "" for anything else.

THE ORDER OF A TAKE (round 5: "nothing said after the press is lost").
  ready       at once: nothing heavy is imported before it (the capture module is the standard library's), so a helper the shell
              starts answers in ~50 ms -- the shell keeps one running, light, whenever dictation is on
  capture     the take's `start` arrived and pw-record is started, before anything else (ms: since the start)
  listening   pw-record's first samples (ms: since the start)
  device, loading, loaded   on the take's LOADER THREAD, while the capture runs: numpy, onnxruntime, OpenVINO, the VAD, the
              models (a cold iGPU load ~5 s; the tidy model's ~3.5 s on the CPU beside it)
  running     the policy runs: words can appear (ms: since the start; the live model and its device). The audio heard since the
              press is decoded at once, on the clock of the press, so a sentence said while the models loaded is written whole.
A `stop` while the models load ends the capture at once; what it heard is decoded when they are up, then `ended`. A `cancel` ends
the take at once (the load carries on: its models are kept). No samples for `noAudioMs` after the start ends the take with error
"audio" (no source, a dead node) -- never a silent take.
The models stay loaded until `unload` or `quit`; the shell decides how long it keeps the helper warm.

A TAKE NEVER ENDS IN SILENCE (round 8: the user's take of 2026-11-13, the iGPU raised `[GPU] clWaitForEvents, error code: -14` inside a
decode, the main loop died with the exception and the process lived on, answering nothing).
  fallback    a decode on a GPU (the iGPU's OpenVINO, CUDA) raised: sttlib/devguard.py loaded the model on the CPU and decoded the SAME
              audio again, so the take goes on and nothing said is lost. {"ev":"fallback","take","model","from":"GPU+CPU","to":"CPU",
              "why":"the iGPU stopped responding","detail":"<the exception's first line>"}. The GPU stays out until the helper is
              started again (`gpu_failed`: the shell restarts it at rest), the next take's `device` event says so.
  error       {"ev":"error","what":"crash","message":"<plain cause>","detail":"<the traceback's tail>"} -- any other exception of the
              main loop (the take is ended with `ended` reason "error"; the helper itself lives on and the shell starts it again)
  beat        {"ev":"beat","take","loopMs","phase"} once a second from its own thread while a take is live: how long ago the main loop
              last turned (`loopMs`) and what it is doing (`phase`: "step" | "load" | "idle"). A main loop stuck inside a native call
              (take 13: 13.6 s inside OpenVINO's infer) shows as a loopMs that grows; the shell ends such a take and starts the helper
              again (DictationService `beatMs`, `loopStuckMs`).
"""
import faulthandler
import json
import os
import traceback

# numpy's BLAS (the mel features) starts one thread per core and spins them: 19 cores busy for a decode measured with 8 ONNX threads.
# The pool is sized when numpy loads, so before any import that loads it; the decoders size their own ONNX threads.
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "4")
import queue
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

# NOTHING HEAVY AT IMPORT: `ready` goes out before numpy, onnxruntime or OpenVINO are read (the loader thread reads them).
from sttlib.audio import RATE, PwRecord  # noqa: E402
from sttlib.devguard import Guarded, plain_cause  # noqa: E402

V = 3
# THE BENCH'S PICK (research sections 11.3 and 11.5): what `auto` means, per device class of the take (decoders.device_class).
# Parakeet hears every take live and writes its English finals (on the iGPU a 10 s sentence re-heard in ~0.13 s, the final ~0.85 s
# after the pause). A Dutch sentence's final comes from Canary told the language -- Parakeet cannot be told one (a Flemish take could
# come out German), and Canary's Dutch is better (bench: 7.5 % against 8.2 %) while its English, on sentence fragments, is worse
# (11.2 % against 9.1 %). `when`: "forced" -- only in a take whose language is forced (Shift+fn+F10), since Canary on the CPU costs
# ~2-3 s a final. On the NVIDIA card Parakeet does the rest too: there it reads FLEURS at 7.8 % en / 8.0 % nl with the final 0.79 s
# after the pause, and Canary has no working card build (decoders MODELS), so a forced-Dutch take's Canary runs as on the iGPU.
# "<live>+<final>" in the config asks for one final model for every language by name.
PICK = {
    "cuda": {"live": "parakeet-tdt-0.6b-v3", "final": {"nl": "canary-1b-v2"}, "when": "forced"},
    "igpu": {"live": "parakeet-tdt-0.6b-v3", "final": {"nl": "canary-1b-v2"}, "when": "forced"},
    "cpu": {"live": "parakeet-tdt-0.6b-v3", "final": {"nl": "canary-1b-v2"}, "when": "forced"},
}
# THE LANGUAGE TEST (sttlib/lang.py; bench section 4): a live model that hears the language itself is read by the function-word
# test after 3 s of speech (59 of 60 FLEURS clips, ~60 ms); a model that must be told (Canary alone) scores both languages after
# 1.5 s (56 of 60, ~1 s of CPU).
LID_SPEECH_MS = {"self-fw": 3000, "score": 1500}
NO_AUDIO_MS = int(os.environ.get("LARES_STT_NO_AUDIO_MS", "2000"))

_out_lock = threading.Lock()


def emit(ev):
    with _out_lock:
        sys.stdout.write(json.dumps(ev, ensure_ascii=False, separators=(",", ":")) + "\n")
        sys.stdout.flush()


# THE TRACE (round 6): the main loop's last turn (monotonic) and the helper, for `trace`; `phase` (round 8): what the loop is at, for `beat`
_loop = {"at": 0.0, "h": None, "phase": "idle"}
BEAT_S = float(os.environ.get("LARES_STT_BEAT_S", "1.0"))


def beats():
    """THE BEAT (round 8): once a second while a take is live, from a thread of its own -- the shell's proof that the main loop turns."""
    while True:
        time.sleep(BEAT_S)
        h = _loop["h"]
        if h is None or h.take is None:
            continue
        emit({"ev": "beat", "take": h.take, "loopMs": int((time.monotonic() - _loop["at"]) * 1000), "phase": _loop["phase"]})


def trace(why):
    """Every thread's innermost frames and the main loop's state: what a stalled helper was doing (the shell asked: `trace`)."""
    import traceback

    names = {t.ident: t.name for t in threading.enumerate()}
    out = []
    for ident, frame in sys._current_frames().items():
        if ident == threading.get_ident():
            continue                  # this reader, answering
        st = traceback.extract_stack(frame)[-6:]
        out.append("%s: %s" % (names.get(ident, ident), " <- ".join("%s:%d %s" % (Path(f.filename).name, f.lineno, f.name)
                                                                 for f in reversed(st))))
    h = _loop["h"]
    loop = "the main loop last turned %.1f s ago" % (time.monotonic() - _loop["at"]) if _loop["at"] else "the main loop never turned"
    if h is not None:
        loop += "; take %s, models %s, capture %s, loader %s" % (
            h.take, "up" if h.eng is not None else "not up", "open" if h.rec is not None else "closed",
            "running" if h.loader is not None and h.loader.is_alive() else "idle")
    emit({"ev": "trace", "why": why, "threads": out, "loop": loop})


def stdin_reader(q):
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except ValueError:
            emit({"ev": "error", "what": "protocol", "message": "not JSON: " + line[:80]})
            continue
        if isinstance(cmd, dict) and cmd.get("op") == "trace":
            trace(str(cmd.get("why") or ""))          # here, not in the queue: the main loop may be what is stuck
            continue
        q.put(cmd)
    q.put({"op": "quit"})          # the shell closed our stdin: it is gone


def _since(t0):
    return int((time.monotonic() - t0) * 1000)


class Helper:
    def __init__(self, q):
        self.q = q                        # the main loop's queue: the loader thread says `_loaded` through it
        self.loaded = {}                  # model id -> decoder, kept until `unload`
        self.tidiers = {}                 # (tidy id, device) -> tidier
        self.cuda_failed = ""             # a CUDA load failed in this process: later takes do not try again (why)
        self.gpu_failed = ""              # a GPU decode failed in this process (devguard): later takes run on the CPU until it is restarted
        self.dec = None
        self.fins = {}
        self.vad = None                   # the VAD session, made by the first take's loader
        self.eng = None                   # the take's policy, from `running` on
        self.rec = None
        self.take = None
        self.cmd = None
        self.t0 = 0.0                     # when the take's `start` arrived (monotonic): the clock the audio is heard on
        self.heard = False                # `listening` said
        self.ending = None                # a `stop` that came while the models loaded: done once they are up
        self.loader = None
        self.source = "mic"               # the take's: "mic" | "window"
        self.watch = None                 # a window take's StreamWatch (from its `window` op on)
        self.fed_until = 0.0              # a window take: the wall time the engine has heard up to (real audio or its silence)
        self.padded = 0.0                 # ... and the seconds of silence fed since the last real audio
        self.was_open = False             # the engine had an utterance open after the last feed (`speech`)

    @staticmethod
    def _spec(cmd, cls):
        """(live id, {lang: final id}): the asked model(s), else the pick for the take's device class; only what is on disk."""
        from sttlib import decoders

        have = decoders.present()
        m = cmd.get("model") or "auto"
        if m != "auto" and all(x in decoders.MODELS for x in m.split("+")):
            ids = m.split("+")
            live, finals = ids[0], ({"en": ids[1], "nl": ids[1]} if len(ids) > 1 else {})
        else:
            p = PICK.get(cls, PICK["igpu"])
            live = p["live"]
            forced = cmd.get("lang") in ("en", "nl")
            # "always" holds where the final model really runs on the card (its CUDA files are there); else as "forced"
            finals = {lg: f for lg, f in p["final"].items()
                      if (p["when"] == "always" and decoders.resolve_device(f, cls) == "CUDA") or (forced and lg == cmd.get("lang"))}
        if live not in have:
            live = next((p["live"] for p in PICK.values() if p["live"] in have), have[0] if have else None)
        if live is None:
            raise RuntimeError("no model in " + str(decoders.MODELS_DIR) + ": run tools/stt/setup.sh")
        return live, {lg: f for lg, f in finals.items() if f in have and f != live}

    def _get(self, mid, cls, power):
        from sttlib import decoders

        dev = decoders.resolve_device(mid, cls)
        d = self.loaded.get(mid)
        if d is not None and d.device.startswith(dev):
            return d
        emit({"ev": "loading", "model": mid, "device": dev})
        t0 = time.perf_counter()
        self.loaded.pop(mid, None)
        d = Guarded(decoders.load(mid, cls, power), self._say_fallback, lambda: self._load_cpu(mid, power), self._gpu_out)
        self.loaded[mid] = d
        emit({"ev": "loaded", "model": mid, "device": d.device, "ms": int((time.perf_counter() - t0) * 1000)})
        return d

    def _say_fallback(self, ev):
        emit(dict(ev, take=self.take))

    def _gpu_out(self, why):
        self.gpu_failed = why

    def _load_cpu(self, mid, power):
        """The model on the CPU, for a decoder whose GPU failed in the middle of a take: the main loop is busy meanwhile (`phase`)."""
        from sttlib import decoders

        _loop["phase"] = "load"
        t0 = time.perf_counter()
        d = decoders.load(mid, "cpu", power)
        emit({"ev": "loaded", "model": mid, "device": d.device, "ms": int((time.perf_counter() - t0) * 1000), "fallback": True})
        return d

    def _models(self, cmd, cls):
        power = cmd.get("power", "ac")
        live, finals = self._spec(cmd, cls)
        self.dec = self._get(live, cls, power)
        self.fins = {lg: self._get(f, cls, power) for lg, f in finals.items()}
        # models no longer asked for are let go: one pick resident at a time
        for mid in [m for m in self.loaded if m != live and m not in finals.values()]:
            del self.loaded[mid]

    def _tidier(self, cmd, cls, take):
        if not cmd.get("tidy"):
            return None
        from sttlib import decoders, tidy as tidylib

        tid = os.environ.get("LARES_STT_TIDY_MODEL") or tidylib.TIDY_PICK
        dev = "CUDA" if cls == "cuda" else "CPU"
        key = (tid, dev)
        if key not in self.tidiers:
            emit({"ev": "loading", "model": tid, "device": dev})
            t0 = time.perf_counter()
            try:
                self.tidiers = {key: tidylib.load(tid, dev, decoders.threads_for(cmd.get("power", "ac")))}
            except Exception as e:  # noqa: BLE001 -- no tidy pass is a take as heard, never a failed take
                emit({"ev": "error", "take": take, "what": "tidy", "message": str(e)[:200]})
                return None
            emit({"ev": "loaded", "model": tid, "device": self.tidiers[key].device, "ms": int((time.perf_counter() - t0) * 1000)})
        return self.tidiers[key]

    # ---- the take ------------------------------------------------------------------------------------------------------------------
    def start(self, cmd):
        if self.take is not None:
            if self.eng is None:
                self._end("cancel")
            else:
                self.stop("stop")
        self.take, self.cmd = cmd.get("take", 0), cmd
        self.t0 = time.monotonic()
        self.heard, self.ending, self.eng = False, None, None
        self.source = "window" if cmd.get("source") == "window" else "mic"
        self.padded, self.was_open = 0.0, False
        # THE CAPTURE FIRST: what is said while the models load is buffered by pw-record's reader, not lost
        self.rec = PwRecord(cmd.get("node", ""), window=self.source == "window")
        emit({"ev": "capture", "take": self.take, "ms": _since(self.t0)})
        self.loader = threading.Thread(target=self._load, args=(cmd, self.take, self.loader), daemon=True)
        self.loader.start()

    def _load(self, cmd, take, prev):
        """THE LOADER THREAD: the device and the models while the capture runs; ends by queueing `_loaded` for the main loop."""
        if prev is not None:
            prev.join()                   # a cancelled take's load: its models are this one's
        try:
            from sttlib import decoders
            from sttlib.vad import StreamingVad

            if self.vad is None:
                self.vad = StreamingVad(decoders.MODELS_DIR / "silero-vad")
            # THE DEVICE, from one cheap fact read now (decoders.dgpu_fact): the card on the bus -> CUDA, else the iGPU
            fact = decoders.dgpu_fact()
            cls, why = decoders.device_class(cmd.get("device", "auto"), fact)
            if cls == "cuda" and self.cuda_failed:
                cls, why = "igpu", "CUDA failed earlier in this helper: " + self.cuda_failed
            if cls in ("cuda", "igpu") and self.gpu_failed:
                cls, why = "cpu", self.gpu_failed + " earlier in this helper: the CPU until it starts again"
            emit({"ev": "device", "take": take, "class": cls, "why": why, "dgpu": fact})
            # the tidy model on the CPU loads BESIDE the live model (~3.5 s against ~4.6 s on the iGPU: `running` comes at the longer of
            # the two, not their sum); on the card it loads after, on the class the live model's load settled on
            side, box = None, {}
            if cls != "cuda" and cmd.get("tidy"):
                side = threading.Thread(target=lambda: box.setdefault("t", self._tidier(cmd, cls, take)), daemon=True)
                side.start()
            try:
                self._models(cmd, cls)
            except Exception as e:  # noqa: BLE001
                if cls != "cuda":
                    raise
                self.cuda_failed = str(e)[:200]
                cls = "igpu"
                emit({"ev": "device", "take": take, "class": cls, "why": "CUDA failed: " + self.cuda_failed, "dgpu": fact,
                      "fallback": True})
                self._models(cmd, cls)
            if side is not None:
                side.join()
                res = ("ok", box.get("t"))
            else:
                res = ("ok", self._tidier(cmd, cls, take))
        except Exception as e:  # noqa: BLE001 -- every failure is an `error` line, the take ends
            res = ("error", str(e))
        self.q.put({"op": "_loaded", "take": take, "res": res})

    def _run(self, take, res):
        """The models are up: the policy starts on the clock of the press and hears everything the capture holds."""
        if take != self.take:
            return                        # a cancelled take's load (its models are kept)
        if res[0] == "error":
            emit({"ev": "error", "take": take, "what": "model", "message": res[1]})
            self._end("error")
            return
        from sttlib import lang as langlib
        from sttlib.policy import Engine

        method = "self-fw" if self.dec.autolang else "score"
        det = langlib.detector(method, self.dec)
        cmd = self.cmd
        pol = cmd.get("policy") if isinstance(cmd.get("policy"), dict) else {}
        cfg = {"lidSpeechMs": LID_SPEECH_MS[method]}
        cfg.update({k: v for k, v in pol.items() if isinstance(v, (int, float))})
        # the final text's rules take shell.jsonc's `dictation.text` verbatim (a missing object: their defaults; sttlib/textrules.py)
        self.eng = Engine(self.dec, self.vad, emit, cfg, det, final_decoders=self.fins, tidier=res[1],
                          text=cmd.get("text") if isinstance(cmd.get("text"), dict) else None)
        self.eng.start(take, cmd.get("lang", "auto"), cmd.get("prior", "en"), self.t0)
        emit({"ev": "running", "take": take, "ms": _since(self.t0), "device": self.dec.device, "model": self.dec.id})
        # what was said since the press, on the clock it was said on: its first decode is due at once
        if self.rec is not None:
            self._feed(self.rec.read(), self.t0)
        self.fed_until = time.monotonic()
        if self.ending:
            self.stop(self.ending)

    def _feed(self, a, now):
        """Audio into the engine; `speech` when an utterance opens (the voice ask's auto-end waits while someone speaks)."""
        if not a.size:
            return
        self.eng.feed(a, now)
        if self.eng.open and not self.was_open:
            emit({"ev": "speech", "take": self.take})
        self.was_open = self.eng.open

    def window(self, cmd):
        """The focused window at the press (the shell read it after the start): a window take links its streams; an ask's cwd."""
        if cmd.get("take") != self.take or self.take is None:
            return
        from sttlib import sources

        pid = int(cmd.get("pid") or 0)
        if cmd.get("watch") and self.source == "window" and self.rec is not None and self.watch is None:
            self.watch = sources.StreamWatch(pid, self.rec.pid, emit, self.take)
        if cmd.get("cwd"):
            cwd, why = sources.terminal_cwd(pid, str(cmd.get("title") or ""))
            emit({"ev": "context", "take": self.take, "cwd": cwd, "why": why})

    def _end(self, reason):
        if self.watch is not None:
            self.watch.stop()
            self.watch = None
        if self.rec is not None:
            self.rec.close()
            self.rec = None
        if self.eng is not None and self.eng.take is not None:
            if reason == "cancel":
                self.eng.cancel()
            else:
                self.eng.stop(time.monotonic(), reason)
        elif self.take is not None:
            emit({"ev": "ended", "take": self.take, "reason": reason, "segs": 0})
        self.eng = None
        self.take = None
        self.ending = None

    def abort(self):
        """The take is over whatever state it is in (never raises): the capture closed, `ended` said once, nothing left standing."""
        try:
            if self.watch is not None:
                self.watch.stop()
        except Exception:  # noqa: BLE001
            pass
        try:
            if self.rec is not None:
                self.rec.close()
        except Exception:  # noqa: BLE001
            pass
        if self.take is not None:
            emit({"ev": "ended", "take": self.take, "reason": "error", "segs": getattr(self.eng, "segs", 0) if self.eng else 0})
        self.watch = self.rec = self.eng = self.take = self.ending = None

    def fail(self, e):
        """AN EXCEPTION THE MAIN LOOP DID NOT EXPECT (round 8): said (`error`, what "crash": the exception's own words, the traceback's
        tail), the take ended with what it had written, the helper goes on. Never a loop that died quietly."""
        tb = traceback.format_exc()
        try:
            sys.stderr.write(tb)
            sys.stderr.flush()
        except Exception:  # noqa: BLE001
            pass
        first = (str(e).strip().splitlines() or [""])[0][:140]
        ev = {"ev": "error", "what": "crash", "message": ("%s: %s" % (type(e).__name__, first)).rstrip(": "),
              "detail": " | ".join(tb.strip().splitlines()[-4:])[:400]}
        if self.take is not None:
            ev["take"] = self.take
        emit(ev)
        try:
            self._end("error")
        except Exception:  # noqa: BLE001 -- the end itself failed (a final decode on a broken device): the words shown stay the shell's
            self.abort()

    def stop(self, reason="stop"):
        if self.take is None:
            return
        if self.rec is not None:
            self.rec.close()              # what pw-record already captured is part of the take; nothing after the stop is
        if self.eng is None:
            self.ending = reason          # the models are loading: decoded and ended once they are up (`_run`)
            return
        if self.rec is not None:
            self._feed(self.rec.read(), time.monotonic())
        self._end(reason)

    def step(self):
        """One turn of the loop: the capture's first word, new audio through the VAD, a decode when due. False: nothing to do."""
        if self.take is None or self.rec is None:
            return False
        now = time.monotonic()
        if not self.heard and self.rec.first_at is not None:
            self.heard = True
            emit({"ev": "listening", "take": self.take, "ms": int((self.rec.first_at - self.t0) * 1000)})
        elif not self.heard and self.ending is None and self.source == "mic" and (now - self.t0) * 1000 > NO_AUDIO_MS:
            emit({"ev": "error", "take": self.take, "what": "audio",
                  "message": "no microphone signal" + (": " + self.rec.error if self.rec.error else "")})
            self._end("error")
            return True
        if self.eng is None:
            return False                  # the models are loading: the audio waits in the capture
        a = self.rec.read()
        if a.size:
            self._feed(a, now)
            self.fed_until, self.padded = now, 0.0
        elif self.source == "window" and self.eng.open and now - self.fed_until > 0.4:
            # THE GAP: a paused video's node idles and the capture gets nothing, not silence -- the engine hears the silence the
            # wall clock says it was, so the open sentence ends at the pause (bounded: a held pause's whole wait and a little)
            cap = (float(self.eng.cfg["thinkSilenceMs"]) + 500.0) / 1000.0
            n = int(min(now - self.fed_until, max(0.0, cap - self.padded)) * RATE)
            if n > 0:
                import numpy as np

                self._feed(np.zeros(n, dtype=np.float32), now)
                self.padded += n / RATE
            self.fed_until = now
        return self.eng.tick(now) or bool(a.size)


def _name_process():
    """The process's name is `lares-stt`, not `python`: what cardwire logs and lists when the helper opens the NVIDIA card (in Smart mode
    every app starts blocked, and silicon's popup offers the switch by this name), and what `ps` and silicon's list of the card's
    users show while a take runs there."""
    try:
        import ctypes

        ctypes.CDLL("libc.so.6").prctl(15, b"lares-stt", 0, 0, 0)       # PR_SET_NAME
    except OSError:
        pass


def dispatch(h, cmd):
    """One command of the shell. True: the helper is asked to quit."""
    op = cmd.get("op")
    if op == "quit":
        try:
            h.stop("stop")
        except Exception:  # noqa: BLE001 -- going away: a final decode that fails is no reason to stay
            pass
        return True
    if op == "hello":
        emit({"ev": "ready", "v": V})
    elif op == "ping":
        emit({"ev": "pong", "n": cmd.get("n")})
    elif op == "_loaded":
        h._run(cmd.get("take"), cmd.get("res"))
    elif op == "start":
        h.start(cmd)
    elif op == "window":
        h.window(cmd)
    elif op in ("stop", "cancel"):
        if cmd.get("take") == h.take:
            if op == "cancel":
                h._end("cancel")
            else:
                h.stop("stop")
    elif op == "unload":
        if h.take is None and (h.loader is None or not h.loader.is_alive()):
            h.loaded, h.tidiers, h.dec, h.fins = {}, {}, None, {}
    return False


def main():
    _name_process()
    # a fatal signal (a native library's abort, a segfault) prints every thread's Python stack on stderr, which the shell keeps
    faulthandler.enable()
    emit({"ev": "ready", "v": V})
    q = queue.Queue()
    threading.Thread(target=stdin_reader, args=(q,), daemon=True).start()
    h = Helper(q)
    _loop["h"] = h
    threading.Thread(target=beats, daemon=True, name="beat").start()
    while True:
        _loop["at"] = time.monotonic()
        _loop["phase"] = "idle"
        # idle: block (no wakeups at all); a take that runs: poll; a take whose models load: look at the capture now and then
        wait = None if h.take is None else (0.0 if h.eng is not None else 0.05)
        try:
            cmd = q.get(timeout=wait)
        except queue.Empty:
            cmd = None
        _loop["at"] = time.monotonic()           # a loop that slept for minutes is not stuck: the beat reads from here
        _loop["phase"] = "step"
        # EVERY TURN IS GUARDED (round 8): an exception ends the take with a stated reason, never the loop
        try:
            if cmd is not None:
                if dispatch(h, cmd):
                    return 0
                continue
            if not h.step() and h.eng is not None:
                time.sleep(0.02)
        except Exception as e:  # noqa: BLE001
            h.fail(e)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
