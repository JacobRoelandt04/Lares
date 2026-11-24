#!/usr/bin/env python3
"""lockveil_paper_check.py -- the paper veil's cascade, measured: does every sheet stay inside the one beneath it,
`sheetMargin` px from its edge, at every sampled moment of a long run?

  lockveil_paper_check.py SWEEP.jsonl VERT [--step PX]

SWEEP.jsonl is tools/dev/qml/lockveil_render.qml's sweep: the REAL VeilPaper.qml's offsets, levels, ripples and
settings at each sampled veil time. VERT is the tree's veil_paper.vert: the field's seven waves and NORM are read
from it (never a copy here), and so is whether it holds a ripple's swell under the cap. Per sample the four sheets
are rebuilt on a grid of STEP px over the screen as the vertex stage builds them (the field, the ripples, the swell),
and for each sheet the least distance from any of its pixels to the outside of the sheet beneath (a Euclidean
distance transform) is its margin. The check:
  grad    the QML's _gradUnit (the field's steepest slope at pattern scale 1, which sizes the budget) is what the
          shader's waves give: max over directions e of NORM * sum(a_i k_i |cos(angle_i - e)|)
  clamp   the shader holds the swell under pk2.z (THE CASCADE's budget)
  margin  every pair's least margin over the run >= sheetMargin x unit - STEP (the grid's own error)
Ends in LOCKVEIL_PAPER_CHECK RESULT PASS|FAIL with each pair's least margin and when it happened.
"""
import json
import math
import re
import sys

import numpy as np
from scipy import ndimage


def waves(vert):
    src = open(vert).read()
    ws = []
    for i in range(7):
        m = re.search(r"const vec4 W%d = vec4\(([^)]*)\);" % i, src)
        if not m:
            raise SystemExit("LOCKVEIL_PAPER_CHECK RESULT FAIL (no W%d in %s)" % (i, vert))
        ws.append(tuple(float(v) for v in m.group(1).split(",")))
    m = re.search(r"const float NORM = ([0-9.]+);", src)
    if not m:
        raise SystemExit("LOCKVEIL_PAPER_CHECK RESULT FAIL (no NORM in %s)" % vert)
    clamp = "d += gm * cap * sy * si;" in src and "vec4 cap = vec4(max(pk2.z, 1e-3));" in src
    return ws, float(m.group(1)), clamp


def sup_grad(ws, norm):
    e = np.linspace(0, 2 * math.pi, 40000)
    s = sum((a * 2 * math.pi / lam) * np.abs(np.cos(ang - e)) for (ang, lam, a, _) in ws)
    return norm * float(s.max())


def build(st, ws, norm, clamp, step):
    u, ps = st["unit"], st["patternScale"]
    S = 170.0 * u
    xs = np.arange(step / 2, st["w"], step)
    ys = np.arange(step / 2, st["h"], step)
    X, Y = np.meshgrid(xs, ys)
    masks = []
    for j in range(4):
        ox, oy = st["off"][j]
        qx, qy = X - ox, Y - oy
        f = np.zeros_like(X); gx = np.zeros_like(X); gy = np.zeros_like(X)
        for (ang, lam, a, ph) in ws:
            k = 2 * math.pi / (lam * u * ps)
            dx, dy = math.cos(ang), math.sin(ang)
            arg = k * (dx * qx + dy * qy) + ph
            f += a * np.sin(arg)
            c = a * k * np.cos(arg)
            gx += c * dx; gy += c * dy
        d = (f * norm - st["lev"][j]) * S
        gm = np.maximum(np.hypot(gx, gy) * norm * S, 0.2)
        # the ripples (veil_paper.vert ripple()): sheet j is reached layerDelay x (3 - j) s after the top one
        H = np.zeros_like(X)
        for (kx, ky, age, w) in st.get("keys", []):
            if w <= 0:
                continue
            r = np.maximum(np.hypot(X - kx, Y - ky), 1.0)
            wd = max(st["keyWidth"] * u, 1.0)
            aj = age - st["layerDelay"] * (3 - j)
            if aj < 0:
                continue
            uu = (r - st["keySpeed"] * u * aj) / wd
            rad = w * st["keyHeight"] * u / (1.0 + r / (900.0 * u))
            H += rad * np.exp(-uu * uu) * np.sin(st["keyCycles"] * uu)
        if clamp and st.get("swellCap") is not None:
            cap = max(st["swellCap"] * u, 1e-3)
            sy = st["edgeSwell"] * H / cap
            d += gm * cap * sy / np.sqrt(1.0 + sy * sy)
        else:
            d += gm * st["edgeSwell"] * H
        masks.append(d > 0)
    return masks


def margins(masks, step):
    out = []
    for j in range(1, 4):
        inner = masks[j]
        if not inner.any():
            out.append(math.inf)
            continue
        # distance from each pixel of the lower sheet to its outside; an upper pixel OUTSIDE the lower sheet reads 0
        # (and the overlap is measured as the negative distance of that pixel into the outside)
        din = ndimage.distance_transform_edt(masks[j - 1]) * step
        dout = ndimage.distance_transform_edt(~masks[j - 1]) * step
        m_in = din[inner].min()
        out.append(m_in if m_in > 0 else -dout[inner].max())
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    sweep, vert = sys.argv[1], sys.argv[2]
    step = float(sys.argv[sys.argv.index("--step") + 1]) if "--step" in sys.argv else 3.0
    ws, norm, clamp = waves(vert)
    g = sup_grad(ws, norm)
    rows = [json.loads(l) for l in open(sweep) if l.strip()]
    if not rows:
        print("LOCKVEIL_PAPER_CHECK RESULT FAIL (an empty sweep)")
        return 1
    fail = []
    st0 = rows[0]
    if st0.get("gradUnit") is not None:
        ok = abs(st0["gradUnit"] - g) / g < 1e-4
        print("  grad    QML _gradUnit %.7f, the shader's waves give %.7f: %s" % (st0["gradUnit"], g, "ok" if ok else "FAIL"))
        if not ok:
            fail.append("grad")
    else:
        print("  grad    (no _gradUnit in this tree's VeilPaper: no budget)")
    if st0.get("swellCap") is not None:
        print("  clamp   veil_paper.vert holds the swell under the cap: %s" % ("ok" if clamp else "FAIL"))
        if not clamp:
            fail.append("clamp")
    margin = (st0.get("sheetMargin") if st0.get("sheetMargin") is not None else 12.0) * st0["unit"]
    need = margin - step
    print("  budget  gap bound %.1f px, sway %s px, margin %.1f px (the check allows the grid's %.1f)"
          % (st0["levelStep"] * st0["patternScale"] / g * 1, st0.get("sway"), margin, step))
    least = [(math.inf, None)] * 3
    for st in rows:
        ms = margins(build(st, ws, norm, clamp, step), step)
        for j in range(3):
            if ms[j] < least[j][0]:
                least[j] = (ms[j], st["t"])
    for j in range(3):
        m, t = least[j]
        ok = m >= need
        print("  margin  sheet %d over %d: least %.1f px at t=%.1f s: %s" % (j + 1, j, m, t if t is not None else -1, "ok" if ok else "FAIL (overlap)" if m < 0 else "FAIL"))
        if not ok:
            fail.append("margin%d" % (j + 1))
    summary = "%d sample(s) from t=%.0f to %.0f s; least margins %s px" % (
        len(rows), rows[0]["t"], rows[-1]["t"], ", ".join("%.1f" % m for m, _ in least))
    if fail:
        print("LOCKVEIL_PAPER_CHECK RESULT FAIL (%s; %s)" % (" ".join(fail), summary))
        return 1
    print("LOCKVEIL_PAPER_CHECK RESULT PASS (%s)" % summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
