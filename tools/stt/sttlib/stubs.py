"""A stand-in decoder for tools/dev/dictation_probe.sh (registered only when LARES_STT_STUBS=1): the real chain -- the private PipeWire,
the helper, the shell, the input method, the field -- with words the probe can predict where no recording of a real "uh" exists.

`stub-speaker` writes what it hears in the audio it is given, frame by frame (32 ms):
  a frame carrying a 1 kHz tone      "uh," once per run of them (the probe's filler: a burst of speech with the tone on it)
  a frame carrying a 2 kHz tone      "MARK" once per run (the probe's marker: where the speech after a pause begins)
  any other loud frame               one word per 0.4 s of them, "w<k>" counted from the start of what it is given
so two decodes of one sentence agree on every word they share, as a real model's do. What it hears ends with a full stop unless it
ends in a filler (round 5: a pause after words with no end punctuation is an unfinished sentence, held thinkSilenceMs like a
filler's pause; policy_check's stand-ins do the same). The tones are found by their share of the
frame's energy (one DFT bin), which survives the PipeWire round trip (48 kHz and back): a run starts where the tone owns the frame
and holds while any of it is left.
"""
import math
import os

import numpy as np

RATE = 16000
FRAME = 512


_N = np.arange(FRAME)
_BASIS = {hz: np.exp(-2j * math.pi * hz * _N / RATE) for hz in (1000.0, 2000.0)}


def _share(frame, hz):
    """The share of the frame's energy at `hz` (1.0 for a pure tone there)."""
    p = abs(np.dot(frame, _BASIS[hz])) ** 2
    return p / (float(np.dot(frame, frame)) * FRAME / 2 + 1e-12)


class StubSpeaker:
    id, device, forceable, autolang = "stub-speaker", "CPU", False, True

    def decode(self, audio, lang):
        # round 8's probe: an exception that is no device's fault (a bug in the helper's own path): the file's existence arms it
        raise_file = os.environ.get("LARES_STT_STUB_RAISE_FILE", "")
        if raise_file and os.path.exists(raise_file):
            raise RuntimeError("stub decoder fault (LARES_STT_STUB_RAISE_FILE)")
        out, run, speech = [], None, 0
        for i in range(0, audio.size - FRAME + 1, FRAME):
            f = audio[i: i + FRAME].astype(np.float64)
            if float(np.sqrt(np.mean(f * f))) < 0.003:
                run = None
                continue
            # a run begins on a frame the tone owns (> 0.6: speech alone stays far below) and holds while it is there at all: a
            # frame the run's end only partly covers has its energy spread over the spectrum
            hold = 0.08 if run in ("uh,", "MARK") else 0.6
            kind = "uh," if _share(f, 1000.0) > (hold if run == "uh," else 0.6) else \
                "MARK" if _share(f, 2000.0) > (hold if run == "MARK" else 0.6) else None
            if kind:
                if run != kind:
                    out.append(kind)
                run = kind
                continue
            run = None
            speech += FRAME
            w = (speech - 1) // int(0.4 * RATE)
            word = "w%d" % w
            if not out or out[-1] != word:
                out.append(word)
        if out and out[-1] != "uh,":
            out[-1] += "."                # a sentence that ends (one that ends in "uh," is thinking)
        return " ".join(out)

    def scored(self, audio, lang):
        return self.decode(audio, lang), -1.0


class StubGpu(StubSpeaker):
    """The stand-in on a GPU that fails (round 8): the `fail_after`-th decode raises what OpenVINO's iGPU raised on the user's take of
    2026-11-13 (`[GPU] clWaitForEvents, error code: -14`), every one after it too -- sttlib/devguard.py must run the same audio on the
    CPU model and the take must go on."""
    device = "GPU+CPU"

    def __init__(self, fail_after=0):
        self.fail_after, self.calls = fail_after, 0

    def decode(self, audio, lang):
        self.calls += 1
        if self.calls > self.fail_after:
            raise RuntimeError("Exception from src/inference/src/cpp/infer_request.cpp:224:\n"
                               "Exception from src/plugins/intel_gpu/src/runtime/ocl/ocl_memory.cpp:593:\n"
                               "[GPU] clWaitForEvents, error code: -14 CL_EXEC_STATUS_ERROR_FOR_EVENTS_IN_WAIT_LIST")
        return super().decode(audio, lang)


STUBS = {"stub-speaker": StubSpeaker}
