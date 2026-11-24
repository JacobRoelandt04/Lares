#!/usr/bin/env python3
"""make_sounds.py -- aerial's mechanical sounds, synthesised (no downloaded audio): the card's screw, the M.2 card springing up and seating,
the DIP switch, a hologram docking (a soft magnetic thunk) and being pulled off (a pop).

    tools/aerial/make_sounds.py                 writes assets/sounds/aerial/*.wav (six files)
    tools/aerial/make_sounds.py --out DIR       writes them to DIR instead (the probe's re-synthesis)
    tools/aerial/make_sounds.py --report        prints each file's length, peak and where it ends

    screw     one turn of the ratchet: two small ticks over a grain of friction (the popup plays it once per turn of the screw's lift)
    card_up   the card springing up off its slot: a short stick-slip rub, then a spring's ring
    card_seat the card seating: a firm click with a short low knock under it
    dip       a DIP switch, one click both ways (silicon's `dip_a` family, own take)
    thunk     a hologram docks on the label: a soft magnetic thunk (low, round, no ring above 1.2 kHz)
    pop       a hologram pulled off: a small suction pop that rises

Same recipe as tools/silicon/make_clicks.py (its `Voice`: burst / ping / rub, causal filters, seeded by the sound's own name, 48 kHz mono 16-bit,
peak -6 dBFS, silent at both ends), and the same bytes every run. The volume the user hears is the shell's (`pw-play --volume`, AerialSounds).
"""
import argparse
import importlib.util
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
spec = importlib.util.spec_from_file_location("make_clicks", os.path.join(ROOT, "tools/silicon/make_clicks.py"))
mc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mc)

DEFAULT_OUT = os.path.join(ROOT, "assets/sounds/aerial")
LEAD = mc.LEAD_MS


class Voice(mc.Voice):
    """make_clicks' voice with a high-pass of its own (the thunk lives below silicon's 700 Hz)."""
    hp = 700.0

    def finish(self):
        x = mc.band(self.x, self.hp, None, 2)
        n_out = int(round(mc.FADE_OUT_MS * mc.SR / 1000.0))
        x[-n_out:] *= 0.5 * (1.0 + np.cos(np.pi * np.arange(1, n_out + 1) / n_out))
        x = x / np.max(np.abs(x))
        return np.round(x * mc.PEAK_INT).astype("<i2")


def screw(v):
    for at in (LEAD, LEAD + 9.0):
        v.burst(at, 0.35, 2000, 9000, 0.9, attack=0.05)
        v.ping(at, 3900, 0.8, 0.30)
    v.rub(LEAD + 1.0, 14.0, 1800, 6500, 0.22, lambda u: np.sin(np.pi * u), rate=260, depth=0.6)


def card_up(v):
    v.rub(LEAD, 22.0, 1500, 6000, 0.45, lambda u: u ** 1.5, rate=200, depth=0.5)
    v.burst(23.0, 0.5, 1800, 8000, 1.0, attack=0.08)
    v.ping(23.0, 2700, 3.0, 0.45)
    v.ping(23.0, 4100, 2.2, 0.25)


def card_seat(v):
    v.burst(LEAD, 0.55, 1800, 9000, 1.0, attack=0.06)
    v.ping(LEAD, 3300, 1.2, 0.45)
    v.ping(LEAD + 0.4, 950, 6.0, 0.55)


def dip(v):
    v.burst(LEAD, 0.30, 2500, 11000, 1.0)
    v.ping(LEAD, 4800, 0.7, 0.40)
    v.ping(LEAD, 7400, 0.4, 0.20)


def thunk(v):
    Voice.hp = 90.0
    v.burst(LEAD, 2.2, 90, 1100, 1.0, attack=0.30)
    v.ping(LEAD, 190, 14.0, 0.9, attack=0.4)
    v.ping(LEAD + 0.2, 360, 7.0, 0.35, attack=0.4)


def pop(v):
    v.burst(LEAD, 1.0, 900, 5000, 1.0, attack=0.15)
    s, on = v._since(LEAD)
    f = 700.0 + 1500.0 * np.clip(s / 0.012, 0.0, 1.0)
    ph = 2 * np.pi * np.cumsum(f) / mc.SR
    v.x += 0.8 * np.where(on, np.exp(-s / 0.006) * np.minimum(1.0, s / 0.0003) * np.sin(ph), 0.0)


SOUNDS = {"screw": (34.0, screw, 700.0), "card_up": (60.0, card_up, 700.0), "card_seat": (40.0, card_seat, 500.0),
          "dip": (18.0, dip, 700.0), "thunk": (70.0, thunk, 90.0), "pop": (34.0, pop, 500.0)}


def synth(name):
    ms, build, hp = SOUNDS[name]
    v = Voice(name, ms)
    Voice.hp = hp
    build(v)
    Voice.hp = hp
    return v.finish()


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--report", action="store_true")
    args = ap.parse_args(argv)
    files = {n: synth(n) for n in SOUNDS}
    os.makedirs(args.out, exist_ok=True)
    for n, pcm in files.items():
        mc.write_wav(os.path.join(args.out, n + ".wav"), pcm)
    if args.report:
        for n, pcm in files.items():
            s = mc.stats(pcm)
            print("%-10s %5.1f ms  peak %6.2f dB  rms %6.2f dB  centroid %5.0f Hz  ends(-40dB) %5.2f ms" % (n, s["ms"], s["peak_db"], s["rms_db"], s["centroid_hz"], s["ends40_ms"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
