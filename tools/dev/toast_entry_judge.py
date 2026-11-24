#!/usr/bin/env python3
"""THE ARRIVAL CHECK (docs/notifications.md, "The arrival"): an arriving toast is never cut by its own reveal.

  toast_entry_judge.py <dir> [--scenario a,b] [--no-place]

<dir> holds what tools/dev/qml/toast_handover_probe.qml writes with ENTRY=1: per scenario `<sc>_<n>.png` (the stage, one per
frame), `<sc>_rest.png` (the settled stack) and `<sc>.card` (`<n|rest> x0 y0 x1 y1 presence cover under qx qy bx0 by0 bx1 by1` per frame, or
`<n> none` before the card exists; device px on the stage, `cover` the top of the opaque row that lies over the card's place, 1e9
when none, `under` 1 when the card paints below that row, `qx qy` the card's place in the lane content's own frame: the lane's box
travels while it opens, so the card's place on the stage is not its place; `bx0 by0 bx1 by1` the lane's box on the stage: with the
bar at the bottom the picture's alpha goes on through the bar's face, the box does not).

A toast arrives AT ITS PLACE: it fades in there while its room opens, and what hides it is only what really covers that place --
the host's box (its edge) and the row that moves away over it. So at every frame:

  place   the card stands where it rests in the content (0.5 px; --no-place leaves it out: with the bar at the bottom the engine
          lays the content out from the box's top, and a row arriving under a leaving one is carried up by that one's closing room);
  ink     the rows of the card that its box and its neighbour leave in view all carry the card's ink, the SAME share of the card's
          own at rest (the share is the fade: presence). A row that has none while the rows above it do is a row a clip cut.
          What is in view: the pixels inside the box (the box's rect and the picture's alpha, 3 px off the rim) above the row that covers the place
          (less 8 px: the neighbour's one-frame lag between the grab and the state read); a row counts when 40 of its columns are
          in view and the card at rest has ink there (>= 8 levels over the box's ground), the same columns in both pictures;
  order   the card paints under the row that covers it (a neighbour that moves away uncovers it; it never paints over it).

A frame whose card is barely there (share < 0.08) or whose box has not reached the card yet says nothing.
A picture goes with the state read one tick LATER (the animations advance between the tick that asks for the grab and the frame it
draws: a grab of frame k shows state k + 1; measured on the old tree's heir, whose picture at k = 6 already has the ink the state of k = 7
says is there).
Prints `ENTRY ok|FAIL <scenario> frames <n> judged <m> worst cut <rows> at <frame> place <px> order <n>` per scenario and the
verdict; exit status 1 on a FAIL.
"""
import os
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path).convert("RGBA")).astype(np.float64)


def read_card(path):
    rows = {}
    for line in open(path):
        w = line.split()
        if len(w) < 4 or w[0] != "HANDOVER":
            continue
        # HANDOVER card <scenario> <tag> ...
        tag = w[3]
        if w[4] == "none":
            rows[tag] = None
        else:
            v = [float(x) for x in w[4:17]]
            rows[tag] = v
    return rows


VERBOSE = bool(os.environ.get("ENTRY_VERBOSE"))
ERODE = 3          # px kept off the box's edge and its antialiased rim
MIN_COLS = 40      # columns of a row that must lie inside the box for the row to say anything
CUT_ROWS = 2       # rows of the card in view that carry none of its ink: a clip (the card at rest never has one)
MIN_INK = 8.0      # levels over the ground a row of the card must have AT REST to be read


def erode(m, r):
    """m with every pixel within r px (a square) of a False one turned False; the image's own edge counts as False."""
    out = m
    for ax in (0, 1):
        o = out.copy()
        for s in range(1, r + 1):
            if ax == 0:
                o[s:, :] &= out[:-s, :]
                o[:-s, :] &= out[s:, :]
                o[:s, :] = False
                o[-s:, :] = False
            else:
                o[:, s:] &= out[:, :-s]
                o[:, :-s] &= out[:, s:]
                o[:, :s] = False
                o[:, -s:] = False
        out = o
    return out


def judge(d, sc, place=True, margin_cover=8.0):
    cards = read_card(os.path.join(d, sc + ".card"))
    rest_png = os.path.join(d, sc + "_rest.png")
    if "rest" not in cards or cards["rest"] is None or not os.path.exists(rest_png):
        return False, "ENTRY FAIL %s: no rest frame" % sc
    rest = load(rest_png)
    rx0, ry0, rx1, ry1, _, _, _, rqx, rqy, _, _, _, _ = cards["rest"]
    H, W = int(round(ry1 - ry0)), int(round(rx1 - rx0))
    RX, RY = int(round(rx0)), int(round(ry0))
    gx, gy = RX - 6, RY + H // 2
    ground = rest[gy, gx, :3]
    if rest[gy, gx, 3] < 250:
        return False, "ENTRY FAIL %s: the ground beside the card at rest is not the box (alpha %d)" % (sc, rest[gy, gx, 3])
    diff_rest = np.abs(rest[RY:RY + H, RX:RX + W, :3] - ground).max(axis=2)
    if (diff_rest.mean(axis=1) >= MIN_INK).sum() < 4:
        return False, "ENTRY FAIL %s: the card at rest has no ink to read" % sc
    frames = sorted(int(k) for k in cards if k != "rest")
    judged, worst, worst_at, place_worst, order_bad = 0, 0, -1, 0.0, 0
    for k in frames:
        # a grab asked for in the tick of frame k shows the NEXT tick's state (the animations advance after the driver's handler and
        # before the frame is drawn): the picture of k goes with the state read at k + 1
        c = cards.get(str(k + 1)) or cards[str(k)]
        png = os.path.join(d, "%s_%03d.png" % (sc, k))
        if c is None or not os.path.exists(png):
            continue
        x0, y0, x1, y1, pres, cover, under, qx, qy, bx0, by0, bx1, by1 = c
        if pres < 0.08:
            continue            # nothing of it is there to judge (an heir waits at presence 0 while the row it replaces fades)
        if place:
            place_worst = max(place_worst, abs(qx - rqx), abs(qy - rqy))
        img = load(png)
        fx, fy = int(round(x0)), int(round(y0))
        if fx < 0 or fy < 0 or fy + H > img.shape[0] or fx + W > img.shape[1]:
            continue
        # what of the card the box leaves in view: pixels inside the box, off its rim, above the row that covers the place
        inside = erode(img[:, :, 3] >= 128, ERODE)[fy:fy + H, fx:fx + W]
        rows_ok = (np.arange(fy, fy + H) < cover - margin_cover) & (np.arange(fy, fy + H) >= by0 + ERODE) & (np.arange(fy, fy + H) < by1 - ERODE)
        cols_ok = (np.arange(fx, fx + W) >= bx0 + ERODE) & (np.arange(fx, fx + W) < bx1 - ERODE)
        inside = inside & rows_ok[:, None] & cols_ok[None, :]
        cnt = inside.sum(axis=1)
        diff = np.abs(img[fy:fy + H, fx:fx + W, :3] - ground).max(axis=2)
        safe = np.maximum(cnt, 1)
        ink = (diff * inside).sum(axis=1) / safe
        ink_rest = (diff_rest * inside).sum(axis=1) / safe
        want = (cnt >= MIN_COLS) & (ink_rest >= MIN_INK)
        if want.sum() < 4:
            continue
        # a card on a fractional place (the content rides the box's easing) has its rows a fraction of a pixel off the rest's, so a
        # one-pixel line splits between two rows: a row's ink is the most of the three rows about it
        near = np.maximum(ink, np.maximum(np.concatenate(([0.0], ink[:-1])), np.concatenate((ink[1:], [0.0]))))
        r = (ink / np.maximum(ink_rest, 1e-6))[want]
        # the share of the card that shows: the most the rows reach, over a few rows so one noisy row is not it
        share = float((np.convolve(r, np.ones(3) / 3.0, mode="valid") if len(r) >= 3 else r).max())
        if share < 0.08:
            continue
        judged += 1
        cut = int(np.sum((near / np.maximum(ink_rest, 1e-6))[want] < 0.5 * share))
        if VERBOSE:
            print("  %s %3d pres %.2f share %.2f rows %d cut %d" % (sc, k, pres, share, int(want.sum()), cut))
        if cut > worst:
            worst, worst_at = cut, k
        if under == 0 and cover < 1e8:
            order_bad += 1
    ok = worst < CUT_ROWS and place_worst <= 0.5 and order_bad == 0
    msg = "ENTRY %s %s frames %d judged %d worst cut %d at %d place %.2f order %d" % (
        "ok  " if ok else "FAIL", sc, len(frames), judged, worst, worst_at, place_worst, order_bad)
    if judged == 0:
        return False, "ENTRY FAIL %s: nothing to judge (%d frames, box never reached the card?)" % (sc, len(frames))
    return ok, msg


def main(argv):
    d = argv[0]
    only = None
    if "--scenario" in argv:
        only = argv[argv.index("--scenario") + 1].split(",")
    scs = sorted(f[:-5] for f in os.listdir(d) if f.endswith(".card"))
    if only:
        scs = [s for s in scs if s in only]
    if not scs:
        print("ENTRY FAIL no scenario to judge in %s" % d)
        return 1
    bad = 0
    for sc in scs:
        ok, msg = judge(d, sc, place="--no-place" not in argv)
        print(msg)
        bad += 0 if ok else 1
    print("ENTRY RESULT %s" % ("PASS" if bad == 0 else "FAIL (%d)" % bad))
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
