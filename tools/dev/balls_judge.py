#!/usr/bin/env python3
"""balls_judge.py -- reads what tools/dev/qml/balls_probe.qml wrote (BALLS F lines + f<n>.png) and judges the balls.

  balls_judge.py <mode> <log> <outdir>      prints BALLS lines and "BALLS RESULT PASS|FAIL"

A frame's picture is read at the rects the probe printed for it, grown by MARGIN px (a grab lands a frame after its request).
The ball is the accent colour (#4480F4 and its mixes): ink = pixels within 90 of it (sum of |dr|+|dg|+|db|).
"""
import json, re, sys
from PIL import Image

ACC = (0x44, 0x80, 0xF4)     # replaced by the accent the probe printed
GROOVE = (0xDC, 0xDF, 0xE6)  # and the groove (Theme.headerBox)
MARGIN = 10
BAND_X0 = 60

def flat(img):
    """the grab composited on a plain ground: a transparent grab un-premultiplies a fading glow into a saturated hue (CLAUDE.md, "A grabToImage OF A TRANSPARENT ITEM LIES")"""
    img = img.convert("RGBA")
    bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
    bg.alpha_composite(img)
    return bg.convert("RGB")

def ink(img, x, y, w, h):
    x0, y0 = max(0, int(x) - MARGIN), max(0, int(y) - MARGIN)
    x1, y1 = min(img.width, int(x + w) + MARGIN), min(img.height, int(y + h) + MARGIN)
    if x1 <= x0 or y1 <= y0:
        return 0
    px = flat(img.crop((x0, y0, x1, y1))).load()
    n = 0
    for j in range(y1 - y0):
        for i in range(x1 - x0):
            r, g, b = px[i, j]
            if abs(r - ACC[0]) + abs(g - ACC[1]) + abs(b - ACC[2]) < 90:
                n += 1
    return n

def groove_in(img, x, y, w, h):
    """pixels of the groove's colour in the rect: a slider is SHOWN once its groove is (the popup's own ground is ink too)"""
    x0, y0 = max(0, int(x)), max(0, int(y))
    x1, y1 = min(img.width, int(x + w)), min(img.height, int(y + h))
    if x1 <= x0 or y1 <= y0:
        return 0
    px = img.crop((x0, y0, x1, y1)).convert("RGBA").load()
    n = 0
    for j in range(y1 - y0):
        for i in range(x1 - x0):
            r, g, b, a = px[i, j]
            if a > 200 and abs(r - GROOVE[0]) + abs(g - GROOVE[1]) + abs(b - GROOVE[2]) < 6:
                n += 1
    return n

def frames(log):
    out = []
    for line in open(log, errors="replace"):
        m = re.search(r"BALLS F (\d+) (\S+) (\{.*\})\s*$", line)
        if m:
            out.append((int(m.group(1)), m.group(2), json.loads(m.group(3))))
    return out

def main():
    mode, log, outdir = sys.argv[1:4]
    fs = frames(log)
    fails = []
    def say(s):
        print("BALLS " + s)
    if not fs:
        print("BALLS RESULT FAIL (no frames: %s)" % log)
        return 1
    global ACC, GROOVE
    h = fs[0][2].get("accent", "#4480f4").lstrip("#")[-6:]
    ACC = (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    h = fs[0][2].get("groove", "#dcdfe6").lstrip("#")[-6:]
    GROOVE = (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))
    rows = []
    for n, tag, info in fs:
        try:
            img = Image.open("%s/f%04d.png" % (outdir, n))
        except Exception:
            continue
        rows.append((n, tag, info, img))
    if mode in ("slider", "popup"):
        # per frame: the sliders effectively shown (opacity > .5, width > 50) and the ball ink at each
        seen = {}
        verdict = []
        for n, tag, info, img in rows:
            ss = [s for s in info.get("sliders", []) if s["o"] > 0.5 and s["w"] > 50 and s["h"] > 5]
            # a slider is SHOWN in a frame once its groove is in the picture
            ss = [s for s in ss if groove_in(img, s["x"], s["y"], s["w"], s["h"]) > 150]
            # a ball whose centre is within 120 px of the stage's edge or past it may be cut off and is not judged (-1)
            inks = []
            for s in ss:
                b = s.get("ball")
                if not b:
                    inks.append(0)
                elif not (120 <= b["x"] + b["w"] / 2 < img.width - 120 and 0 <= b["y"] + b["h"] / 2 < img.height):
                    inks.append(-1)
                else:
                    # the slider's whole BAND across the stage (a row only slides sideways): how many frames a grab lags its request depends on the load,
                    # so a rect grown by a fixed motion is not where the ball is on a busy machine (frames 164-165 of a loaded run). Left of BAND_X0 is
                    # the device rail's column, whose ball must not stand in for a slider's
                    inks.append(ink(img, BAND_X0, s["y"], img.width - BAND_X0, s["h"]))
            verdict.append((n, tag, len(ss), inks))
        bad = []
        for n, tag, k, inks in verdict:
            if k and any(i < 20 for i in inks if i >= 0):
                bad.append((n, tag, inks))
        for n, tag, k, inks in verdict[:60]:
            say("frame %d %s sliders=%d ink=%s" % (n, tag, k, inks))
        # the device rail (a SlotRail of the sinks / sources tabs): its ball is in every frame that has its groove
        rbad = []
        for n, tag, info, img in rows:
            for r in info.get("rails", []):
                if r["o"] > 0.5 and r["h"] > 20 and groove_in(img, r["x"], r["y"], r["w"], r["h"]) > 60 and ink(img, r["x"], r["y"], r["w"], r["h"]) < 10:
                    rbad.append(n)
        if any(info.get("rails") for _, _, info, _ in rows):
            say("%s: %d frames show a device rail without its ball" % (mode, len(rbad)))
            if rbad:
                fails.append("%d frames with a rail and no ball (first at frame %d)" % (len(rbad), rbad[0]))
        late = len(bad)
        say("%s: %d frames show a slider without its ball" % (mode, late))
        if late:
            fails.append("%d frames with a slider and no ball (first at frame %d)" % (late, bad[0][0]))
        if not any(k for _, _, k, _ in verdict):
            fails.append("no slider was ever shown")
    elif mode == "menu":
        # the open: the first frame with the rails' groove shows the ball (seated, round); the pick: the ball changes shape on the way
        first_rows = None
        recs = []
        for n, tag, info, img in rows:
            r = info.get("rail")
            if not r or r["w"] < 1:
                recs.append((n, tag, None))
                continue
            fi = flat(img)
            crop = fi.crop((int(r["x"]) - 4, int(r["y"]), int(r["x"]) + int(r["w"]) + 4, int(r["y"] + r["h"])))
            p = crop.load()
            xs, ys = [], []
            groove = 0
            for j in range(crop.height):
                for i in range(crop.width):
                    rr, g, b = p[i, j]
                    if abs(rr - ACC[0]) + abs(g - ACC[1]) + abs(b - ACC[2]) < 20:
                        xs.append(i); ys.append(j)
                    elif abs(rr - 255) + abs(g - 255) + abs(b - 255) > 12:
                        groove += 1
            recs.append((n, tag, (len(xs), (max(xs) - min(xs) + 1) if xs else 0, (max(ys) - min(ys) + 1) if ys else 0, groove, info.get("moving"))))
        shown = [x for x in recs if x[2] and x[2][3] > 30]
        for n, tag, v in recs[:70]:
            say("frame %d %s %s" % (n, tag, v))
        if not shown:
            fails.append("the menu's rail was never drawn")
        else:
            n0 = shown[0][0]
            bad = [x for x in shown if x[1] == "open" and x[2][0] < 10]
            say("menu: groove first in frame %d; %d open frames with the groove and no ball" % (n0, len(bad)))
            if bad:
                fails.append("%d frames show the groove without the ball (first %d)" % (len(bad), bad[0][0]))
            rest = [x for x in shown if x[1] == "open" and x[2][0] >= 10]
            sq = max((abs(x[2][1] - x[2][2]) for x in rest), default=0)
            say("menu: max |h-w| in the open frames = %d" % sq)
            if sq > 1:
                fails.append("the opening seats the ball with a squish (|h-w| %d)" % sq)
            pick = [x for x in shown if x[1] == "pick" and x[2][0] >= 10]
            ps = max((abs(x[2][1] - x[2][2]) for x in pick), default=0)
            say("menu: max |h-w| on the pick = %d" % ps)
            if ps < 2:
                fails.append("the pick does not squish the ball")
    elif mode == "rail":
        # the ball's bounding box in the rail's column per frame: round at rest (w == h), not round on the way
        shapes = []
        for n, tag, info, img in rows:
            r = info.get("rail")
            if not r:
                continue
            px = flat(img.crop((int(r["x"]) - 6, int(r["y"]), int(r["x"]) + int(r["w"]) + 6, int(r["y"] + r["h"]))))
            p = px.load()
            xs, ys = [], []
            for j in range(px.height):
                for i in range(px.width):
                    rr, g, b = p[i, j]
                    if abs(rr - ACC[0]) + abs(g - ACC[1]) + abs(b - ACC[2]) < 20:
                        xs.append(i); ys.append(j)
            if xs:
                shapes.append((n, max(xs) - min(xs) + 1, max(ys) - min(ys) + 1, (min(ys) + max(ys)) / 2, info.get("moving")))
            else:
                shapes.append((n, 0, 0, 0, info.get("moving")))
        for s in shapes:
            say("frame %d w=%d h=%d cy=%.1f moving=%s" % s)
        mov = [s for s in shapes if s[1] and s[4]]
        rest = [s for s in shapes if s[1] and not s[4]]
        stretch = max((abs(s[2] - s[1]) for s in mov), default=0)
        say("rail: max |h-w| while moving = %d, at rest = %d" % (stretch, max((abs(s[2] - s[1]) for s in rest[-5:]), default=0)))
        if stretch < 2:
            fails.append("the ball is round all the way: no squish (max |h-w| %d)" % stretch)
        if rest and max(abs(s[2] - s[1]) for s in rest[-5:]) > 1:
            fails.append("the ball is not round at rest")
    print("BALLS RESULT " + ("PASS" if not fails else "FAIL (%s)" % "; ".join(fails)))
    return 0 if not fails else 1

sys.exit(main())
