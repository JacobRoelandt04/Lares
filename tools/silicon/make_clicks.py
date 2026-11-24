#!/usr/bin/env python3
"""make_clicks.py -- silicon's tactile sounds (v2: dry and small), synthesised from the parts they stand for.

    tools/silicon/make_clicks.py                 writes assets/sounds/silicon/*.wav (twelve files)
    tools/silicon/make_clicks.py --out DIR       writes them to DIR instead (the probe's re-synthesis)
    tools/silicon/make_clicks.py --plot DIR      also draws DIR/clicks_<sound>.png: every variant's waveform, its
                                                 level in dB and its spectrogram, to look at
    tools/silicon/make_clicks.py --report        prints each file's length, peak, rms, centroid, where it ends
                                                 and how much of it is below 700 Hz

Twelve files, 48 kHz mono 16-bit, peak -6 dBFS, silent at both ends: four sounds, three variants each
(`<sound>_a|b|c.wav`; the popup plays the one silicon.json / the mockup's Sounds tab picks):

                 a                     b                       c
    latch        a bright tick         a softer, lower click   a snap with a little crack on top
    dip          a tiny, high tick     a soft click            a snap
    plug         a short scrape, a     a longer, softer        a scrape too short to hear as one,
                 metal tick            scrape, a duller tick   a snap
    plug_out     a pop, then the       the same, softer and    a snap and almost no scrape
                 barrel's scrape       longer
                 dying away

    latch    the PCIe slot's plastic retention latch, one click both ways (<= 30 ms)
    dip      a DIP switch, one click both ways (<= 30 ms)
    plug     a barrel plug pushed into its jack: the scrape, then the contact closes (<= 60 ms)
    plug_out the same plug pulled out. NOT the same file at a lower level: the sound is directional (a scrape
             that ENDS in a click is a plug going in), so the way out is its own picture -- the contact lets
             go with a pop and the scrape dies away behind it (<= 60 ms)

WHY v2. The first set sounded "grand", "like it had a sound chamber attached" for what is a little click.
That was built in: two or three transients 6-15 ms apart (the ear hears the later ones as early
reflections), body modes at 240-1320 Hz that rang for 11-18 ms (a small box), a saturated thunk, scrape
peaks tuned to resonances, and zero-phase filters that spread energy BEFORE the click. v2 is the
opposite of each: ONE transient per sound (a plug has its scrape, which is friction, not an event), no
mode below 2 kHz, decays of 0.3-1.7 ms, no saturation, and every filter is causal (a cascade of
Butterworth sections run forward only, so nothing exists before the first sample of a part), with a
high-pass at 700 Hz over the whole so there is no thump and no DC. A latch or a switch is audible for
about 8 ms; a plug for the length of its scrape.

THE SAME BYTES EVERY RUN. Nothing here reads a clock or an entropy source: every noise burst comes from
a RandomState seeded by the CRC of the sound's own name (the legacy generator, whose stream numpy has
frozen for good), the filters are plain IEEE arithmetic in a fixed order, and the WAV container is
written by the `wave` module, which puts nothing in a header that varies. Synthesising
into a scratch directory twice and comparing both against the committed files shows it. (A numpy
whose RandomState or exp/sin rounds differently in the last bit can move a sample by one LSB: the
committed files are then stale, and the answer is to run this and listen again.)

HOW A SOUND IS MADE. Three kinds of part, each band-limited by its own causal filter:
`burst`  the contact's snap: noise under a sub-millisecond exponential, rising over ~40 us;
`ping`   a mode of the struck plastic or metal: a damped sine, 2.4 kHz and up, decaying in 0.3-1.7 ms;
`rub`    friction: noise under a slow envelope, chattering at the stick-slip rate.
The sum goes through the 700 Hz high-pass, gets a 2 ms fade at its very end (the last sample is exactly
zero; the sound is long over by then) and is scaled so the loudest sample is at PEAK_DBFS. A click this
short is perceived quieter than the old, longer ones at the same peak; the volume the user hears is the
shell's (`pw-play --volume`, silicon.json `sounds`), not the file's.
"""
import argparse
import math
import os
import sys
import wave
import zlib

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFAULT_OUT = os.path.join(ROOT, "assets/sounds/silicon")

SR = 48000
PEAK_DBFS = -6.0
# the largest sample magnitude: one below what 10^(-6/20) of full scale rounds to, so the MEASURED peak
# (20 log10(peak / 32768)) is at most -6.0 whichever way a checker rounds
PEAK_INT = int(math.floor(32768 * 10 ** (PEAK_DBFS / 20.0))) - 1
LEAD_MS = 1.0          # nothing happens before this: the first sample and the first millisecond are silence
FADE_OUT_MS = 2.0
HIGHPASS_HZ = 700.0
MAX_MS = 62.0

BASES = ("latch", "dip", "plug", "plug_out")
VARIANTS = ("a", "b", "c")


# ----------------------------------------------------------------------------------------------------------
# causal filters
# ----------------------------------------------------------------------------------------------------------
def _section(kind, fc, q):
    """RBJ biquad, high-pass or low-pass: (b0, b1, b2, a1, a2), normalised."""
    w0 = 2.0 * math.pi * fc / SR
    cw, alpha = math.cos(w0), math.sin(w0) / (2.0 * q)
    if kind == "hp":
        b = (0.5 * (1.0 + cw), -(1.0 + cw), 0.5 * (1.0 + cw))
    else:
        b = (0.5 * (1.0 - cw), 1.0 - cw, 0.5 * (1.0 - cw))
    a0 = 1.0 + alpha
    return (b[0] / a0, b[1] / a0, b[2] / a0, -2.0 * cw / a0, (1.0 - alpha) / a0)


def _run(x, sec):
    """One biquad, forward only (direct form I): the output at i depends on inputs up to i and no later."""
    b0, b1, b2, a1, a2 = sec
    y = np.zeros(len(x))
    x1 = x2 = y1 = y2 = 0.0
    for i, xi in enumerate(x.tolist()):
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        y[i] = yi
        x2, x1 = x1, xi
        y2, y1 = y1, yi
    return y


# Butterworth sections: the Q of each 2nd-order stage of an even-order filter
_Q = {2: (0.70710678,), 4: (0.54119610, 1.30656296)}


def band(x, lo=None, hi=None, hp_order=4, lp_order=2):
    """Causal band-pass: a Butterworth high-pass at `lo` Hz and low-pass at `hi` Hz (None = open)."""
    y = x
    if lo:
        for q in _Q[hp_order]:
            y = _run(y, _section("hp", lo, q))
    if hi:
        for q in _Q[lp_order]:
            y = _run(y, _section("lp", hi, q))
    return y


class Voice:
    """One sound under construction: a float buffer of `ms` and the parts that write into it. Times are in
    ms from the start of the file, frequencies in Hz, `amp` relative (the whole is scaled at the end)."""

    def __init__(self, name, ms):
        self.n = int(round(ms * SR / 1000.0))
        self.t = np.arange(self.n, dtype=np.float64) / SR
        self.x = np.zeros(self.n)
        self.rng = np.random.RandomState(zlib.crc32(name.encode("utf-8")) & 0x7FFFFFFF)

    def _since(self, at):
        s = self.t - at / 1000.0
        on = s >= 0.0
        return np.where(on, s, 0.0), on

    def burst(self, at, tau, lo, hi, amp, attack=0.04):
        """The contact's snap: noise under exp(-s/tau) ms, rising over `attack` ms, band-passed, scaled to peak at `amp`."""
        s, on = self._since(at)
        env = np.where(on, np.exp(-s / (tau / 1000.0)) * np.minimum(1.0, s / (attack / 1000.0)), 0.0)
        y = band(self.rng.standard_normal(self.n) * env, lo, hi)
        peak = np.max(np.abs(y))
        if peak > 0:
            self.x += amp * y / peak

    def ping(self, at, f, tau, amp, attack=0.05):
        """A mode of the struck part: a damped sine from `at`, time constant `tau` ms, rising over `attack` ms."""
        s, on = self._since(at)
        env = np.exp(-s / (tau / 1000.0)) * np.minimum(1.0, s / (attack / 1000.0))
        self.x += amp * np.where(on, env * np.sin(2.0 * np.pi * f * s), 0.0)

    def rub(self, at, dur, lo, hi, amp, shape, rate, depth):
        """Friction: band-limited noise under `shape(u)` (u runs 0..1 over `dur` ms), chattering at `rate` Hz
        (stick-slip, with a little wander so it is not a tone). No resonant peaks: a plain grain."""
        s, on = self._since(at)
        inside = on & (s <= dur / 1000.0)
        u = np.clip(s / (dur / 1000.0), 0.0, 1.0)
        e = np.where(inside, shape(u), 0.0)
        # 1.5 ms at both ends of the rub itself, so the band-pass sees no step
        e = e * np.clip(np.minimum(s / 0.0015, (dur / 1000.0 - s) / 0.0015), 0.0, 1.0)
        wander = _run(self.rng.standard_normal(self.n), _section("lp", 40.0, 0.70710678))
        wander = wander / max(np.max(np.abs(wander)), 1e-9)
        chatter = 1.0 - depth + depth * (0.5 + 0.5 * np.sin(2.0 * np.pi * rate * s + 2.0 * wander))
        y = band(self.rng.standard_normal(self.n), lo, hi) * e * chatter
        peak = np.max(np.abs(y))
        if peak > 0:
            self.x += amp * y / peak

    def finish(self):
        """The finished int16 samples: high-passed (no thump, no DC), the last 2 ms faded, the loudest sample at PEAK_INT."""
        x = band(self.x, HIGHPASS_HZ, None, 2)
        n_out = int(round(FADE_OUT_MS * SR / 1000.0))
        x[-n_out:] *= 0.5 * (1.0 + np.cos(np.pi * np.arange(1, n_out + 1) / n_out))
        x = x / np.max(np.abs(x))
        return np.round(x * PEAK_INT).astype("<i2")


# ----------------------------------------------------------------------------------------------------------
# the sounds: one transient each (a plug has its scrape, which is friction, not an event)
# ----------------------------------------------------------------------------------------------------------
def _tick(v, at, tau, lo, hi, pings):
    """A click: the snap of the contact and the ring of the plastic it struck. pings = ((Hz, tau ms, amp), ...)."""
    v.burst(at, tau, lo, hi, 1.0)
    for f, t, a in pings:
        v.ping(at, f, t, a)


def latch_a(v):     # a bright tick
    _tick(v, LEAD_MS, 0.30, 2800, 12000, ((4600, 0.9, 0.35), (7300, 0.5, 0.18)))


def latch_b(v):     # a softer, lower click
    v.burst(LEAD_MS, 0.70, 1800, 7000, 1.0, attack=0.12)
    v.ping(LEAD_MS, 3100, 1.4, 0.45, attack=0.10)


def latch_c(v):     # a snap with a little crack on top
    _tick(v, LEAD_MS, 0.45, 2200, 14000, ((2500, 1.1, 0.50), (6200, 0.9, 0.30), (9100, 0.4, 0.15)))


def dip_a(v):       # a tiny, high tick
    _tick(v, LEAD_MS, 0.22, 2500, 10000, ((5200, 0.6, 0.45), (7800, 0.35, 0.20)))


def dip_b(v):       # a soft click
    v.burst(LEAD_MS, 0.50, 2400, 9000, 1.0, attack=0.10)
    v.ping(LEAD_MS, 4300, 1.0, 0.50, attack=0.08)


def dip_c(v):       # a snap
    _tick(v, LEAD_MS, 0.35, 3000, 15000, ((3300, 1.3, 0.35), (5400, 0.9, 0.35), (8600, 0.5, 0.20)))


def plug_a(v):      # a short scrape, a metal tick
    v.rub(1.5, 21.0, 1800, 7000, 0.50, lambda u: u ** 1.4, rate=210, depth=0.50)
    _tick(v, 22.0, 0.45, 1500, 9000, ((2400, 1.4, 0.50), (4600, 0.8, 0.30)))


def plug_b(v):      # a longer, softer scrape, a duller tick
    v.rub(1.5, 36.0, 1200, 4500, 0.45, lambda u: u ** 1.2, rate=170, depth=0.45)
    v.burst(37.5, 0.90, 1200, 5000, 1.0, attack=0.12)
    v.ping(37.5, 2200, 1.7, 0.40, attack=0.10)


def plug_c(v):      # a scrape too short to hear as one, a snap
    v.rub(1.5, 9.5, 2000, 8000, 0.40, lambda u: u ** 1.2, rate=240, depth=0.45)
    _tick(v, 10.5, 0.35, 2000, 11000, ((3100, 1.0, 0.45), (6200, 1.0, 0.30)))


def plug_out_a(v):  # a pop, then the barrel's scrape dying away
    _tick(v, LEAD_MS + 0.2, 0.60, 1200, 6000, ((2300, 1.2, 0.45),))
    v.rub(3.0, 22.0, 1800, 7000, 0.26, lambda u: (1.0 - u) ** 1.3, rate=190, depth=0.50)


def plug_out_b(v):  # softer and longer
    v.burst(LEAD_MS + 0.2, 0.90, 1200, 5000, 1.0, attack=0.12)
    v.ping(LEAD_MS + 0.2, 2200, 1.6, 0.40, attack=0.10)
    v.rub(3.5, 34.0, 1200, 4500, 0.24, lambda u: (1.0 - u) ** 1.2, rate=160, depth=0.45)


def plug_out_c(v):  # a snap and almost no scrape
    _tick(v, LEAD_MS + 0.2, 0.35, 2000, 11000, ((3100, 1.0, 0.45), (6200, 1.0, 0.30)))
    v.rub(2.5, 9.0, 2000, 8000, 0.24, lambda u: (1.0 - u) ** 1.2, rate=240, depth=0.45)


# name -> (length in ms, builder). The length leaves the last 2 ms for the fade-out.
SOUNDS = {
    "latch_a": (20.0, latch_a), "latch_b": (22.0, latch_b), "latch_c": (22.0, latch_c),
    "dip_a": (16.0, dip_a), "dip_b": (18.0, dip_b), "dip_c": (18.0, dip_c),
    "plug_a": (36.0, plug_a), "plug_b": (52.0, plug_b), "plug_c": (28.0, plug_c),
    "plug_out_a": (36.0, plug_out_a), "plug_out_b": (48.0, plug_out_b), "plug_out_c": (24.0, plug_out_c),
}
assert sorted(SOUNDS) == sorted(b + "_" + v for b in BASES for v in VARIANTS)


def synth(name):
    ms, build = SOUNDS[name]
    v = Voice(name, ms)
    build(v)
    return v.finish()


def write_wav(path, pcm):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


# ----------------------------------------------------------------------------------------------------------
# what a reader can look at
# ----------------------------------------------------------------------------------------------------------
def envelope(x, step_ms=0.25):
    step = int(round(step_ms * SR / 1000.0))
    return np.array([np.max(np.abs(x[i:i + step])) for i in range(0, len(x) - step + 1, step)]), step_ms


def stats(pcm):
    x = pcm.astype(np.float64) / 32768.0
    peak = np.max(np.abs(x))
    rms = math.sqrt(np.mean(x ** 2))
    m = 1 << int(math.ceil(math.log2(len(x) * 8)))
    spec = np.abs(np.fft.rfft(x, m)) ** 2
    f = np.fft.rfftfreq(m, 1.0 / SR)
    env, step_ms = envelope(x)

    def ends(db):
        live = np.nonzero(env > peak * 10 ** (db / 20.0))[0]
        return float((live[-1] + 1) * step_ms) if len(live) else 0.0

    return {
        "ms": 1000.0 * len(x) / SR,
        "peak_db": 20 * math.log10(peak),
        "rms_db": 20 * math.log10(rms),
        "mean": float(np.mean(x)),
        "centroid_hz": float(np.sum(f * spec) / np.sum(spec)),
        "ends30_ms": ends(-30.0),
        "ends40_ms": ends(-40.0),
        "below700_db": 10 * math.log10(max(np.sum(spec[f < 700.0]) / np.sum(spec), 1e-12)),
    }


def report(files):
    print("%-11s %6s %7s %7s %9s %9s %9s %9s %9s" % ("sound", "ms", "peak dB", "rms dB", "mean", "centroid", "-30dB end", "-40dB end", "<700Hz"))
    for name, pcm in files.items():
        s = stats(pcm)
        print("%-11s %6.1f %7.2f %7.2f %9.1e %6.0f Hz %6.2f ms %6.2f ms %6.1f dB" % (
            name, s["ms"], s["peak_db"], s["rms_db"], s["mean"], s["centroid_hz"], s["ends30_ms"], s["ends40_ms"], s["below700_db"]))


def plot(files, outdir, xlim_ms=None):
    """One sheet per sound (its three variants, a row each): the waveform, the level in 0.25 ms steps, the spectrogram."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    os.makedirs(outdir, exist_ok=True)
    paths = []
    for base in BASES:
        names = [n for n in files if n.rsplit("_", 1)[0] == base]
        if not names:
            continue
        top = xlim_ms or max(1000.0 * len(files[n]) / SR for n in names)
        fig, axes = plt.subplots(len(names), 3, figsize=(15, 2.5 * len(names)), gridspec_kw={"width_ratios": [1.1, 1.1, 1.3]}, squeeze=False)
        for row, name in enumerate(names):
            x = files[name].astype(np.float64) / 32768.0
            t = 1000.0 * np.arange(len(x)) / SR
            ax = axes[row][0]
            ax.plot(t, x, lw=0.7, color="#1f4fd8")
            ax.set_ylim(-0.55, 0.55)
            ax.set_xlim(0, top)
            ax.set_ylabel("%s\namplitude" % name)
            ax.axhline(0, color="#999999", lw=0.4)
            ax.grid(alpha=0.25)
            ax = axes[row][1]
            env, step_ms = envelope(x)
            ax.plot((np.arange(len(env)) + 0.5) * step_ms, 20 * np.log10(np.maximum(env, 1e-6)), color="#d86a1f", lw=1.2)
            ax.axhline(PEAK_DBFS, color="#999999", lw=0.6, ls="--")
            ax.axhline(PEAK_DBFS - 40, color="#cc4444", lw=0.6, ls=":")
            ax.set_ylim(-90, 0)
            ax.set_xlim(0, top)
            ax.set_ylabel("level (dBFS, 0.25 ms)")
            ax.grid(alpha=0.25)
            ax = axes[row][2]
            win, hop = 48, 4
            w = np.hanning(win)
            frames = np.array([x[i:i + win] * w for i in range(0, len(x) - win, hop)])
            mag = np.abs(np.fft.rfft(frames, 256, axis=1)).T
            db = 20 * np.log10(np.maximum(mag, 1e-9))
            db -= db.max()
            ax.imshow(db, origin="lower", aspect="auto", cmap="magma", vmin=-70, vmax=0,
                      extent=[0, 1000.0 * (len(frames) * hop + win) / SR, 0, SR / 2000.0])
            ax.set_xlim(0, top)
            ax.set_ylim(0, 16)
            ax.set_ylabel("kHz")
            if row == 0:
                axes[row][0].set_title("waveform (ms)")
                axes[row][1].set_title("level (dashed: peak, dotted: -40 dB)")
                axes[row][2].set_title("spectrogram (1 ms window)")
        for ax in axes[-1]:
            ax.set_xlabel("ms")
        fig.tight_layout()
        path = os.path.join(outdir, "clicks_%s.png" % base)
        fig.savefig(path, dpi=70)
        plt.close(fig)
        paths.append(path)
    return paths


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", default=DEFAULT_OUT, help="where the .wav files are written (default: assets/sounds/silicon)")
    ap.add_argument("--plot", metavar="DIR", help="also draw DIR/clicks_<sound>.png")
    ap.add_argument("--plot-xlim", type=float, default=None, help="the sheets' time axis in ms (default: the longest file of a sheet)")
    ap.add_argument("--report", action="store_true", help="print each file's length, peak, rms, centroid and where it ends")
    args = ap.parse_args(argv)

    files = {name: synth(name) for name in SOUNDS}
    for name, pcm in files.items():
        if 1000.0 * len(pcm) / SR > MAX_MS:
            sys.exit("make_clicks: %s is longer than %.0f ms" % (name, MAX_MS))
    os.makedirs(args.out, exist_ok=True)
    for name, pcm in files.items():
        write_wav(os.path.join(args.out, name + ".wav"), pcm)
    if args.report:
        report(files)
    if args.plot:
        for p in plot(files, args.plot, args.plot_xlim):
            print("wrote", p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
