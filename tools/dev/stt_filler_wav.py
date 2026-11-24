#!/usr/bin/env python3
"""stt_filler_wav.py -- the dictation probe's filler recording (tools/dev/dictation_probe.sh, step F), built from two FLEURS clips:

    [clip 1's speech] [a FILLER: half a second of speech with a 1 kHz tone on it] [2.0 s of silence -- thinking]
    [a MARK: 0.3 s of speech with a 2 kHz tone on it] [clip 2's speech]

The probe's stand-in decoder (tools/stt/sttlib/stubs.py) hears the 1 kHz frames as "uh," and the 2 kHz ones as "MARK"; the VAD hears
all of it as speech. So the filler is the last thing said before the pause, and "MARK" the first thing after it: one sentence holds
both when the pause after the filler is thinking, two when it ends the sentence.

    stt_filler_wav.py OUT.wav CLIP1.wav CLIP2.wav       prints `ok <OUT> <seconds>`
"""
import sys

import numpy as np
import soundfile

RATE = 16000


def speech_of(path):
    a, rate = soundfile.read(path, dtype="float32", always_2d=True)
    a = a.mean(axis=1)
    if rate != RATE:
        raise SystemExit("FAIL %s is %d Hz, not 16 kHz" % (path, rate))
    loud = np.flatnonzero(np.abs(a) > 0.02 * np.abs(a).max())
    return a[max(0, loud[0] - 800): loud[-1] + 800]


def toned(snippet, hz):
    t = np.arange(snippet.size) / RATE
    rms = float(np.sqrt(np.mean(snippet ** 2)))
    tone = np.sin(2 * np.pi * hz * t) * rms * 1.6          # louder than the speech under it: the frame's energy is the tone's
    ramp = np.minimum(1.0, np.minimum(t / 0.02, (t[-1] - t) / 0.02))
    return ((snippet + tone) * ramp).astype(np.float32)


def main(argv):
    if len(argv) != 3:
        print(__doc__)
        return 2
    out, c1, c2 = argv
    a, b = speech_of(c1), speech_of(c2)
    # both bursts from the middle of clip 2, where it is loud: the VAD hears them as speech with the tone on them
    mid = b.size // 2
    filler = toned(b[mid: mid + RATE // 2], 1000.0)
    mark = toned(b[mid - int(0.4 * RATE): mid - int(0.1 * RATE)], 2000.0)
    x = np.concatenate([a, np.zeros(RATE // 10, np.float32), filler, np.zeros(2 * RATE, np.float32), mark, b,
                        np.zeros(RATE // 2, np.float32)])
    x = x * (0.5 / float(np.abs(x).max()))                 # a speaking level: FLEURS clips peak far lower
    soundfile.write(out, x.astype(np.float32), RATE, subtype="FLOAT")
    print("ok %s %.1f" % (out, x.size / RATE))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
