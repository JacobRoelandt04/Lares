#!/usr/bin/env python3
"""make_glyph_parts.py -- writes SiliconGlyphParts.js: the outlines of the bar icon's three glyphs (md-leaf F032A,
md-scale_balance F05D1, md-lightning_bolt F140B of "Symbols Nerd Font"), read from the installed font with fontTools, in font
units (y up), as the PARTS the flourish moves (SiliconGlyphPose.js):

  leaf    one contour, subdivided (every quad into SUB, every line into LINE_SEG) so that a smooth field can bend it
  scales  base (post, foot, the two flares, a filler that hides inside the beam), beam (bar, bulb, the pivot's hole),
          pan0 / pan1 (each: its two strings, the bowl, the hole between them, and an ear that slots into the beam)
  bolt    the six corners

The parts are cut where the font's own outline already changes direction (the strings leave the beam at y = 1084, the flares
meet the post), every number below is read off that outline, and `check()` proves that the union of the parts at rest covers
exactly the glyph's area (the pieces' areas sum to the glyph's, the overlaps being inside the beam).

  tests: python3 modules/silicon/bar/make_glyph_parts.py [--check]    (writes the file; --check only compares it)
"""
import sys, os
from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.areaPen import AreaPen

FONT = "/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf"
CP = {"leaf": 0xF032A, "scales": 0xF05D1, "bolt": 0xF140B}
SUB, LINE_SEG = 6, 5
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "SiliconGlyphParts.js")


def expand(rec):
    """a recording pen's value -> contours of ('M',x,y) ('L',x,y) ('Q',cx,cy,x,y) with every implied TrueType point explicit"""
    cs, cur, last = [], None, None
    for op, pts in rec:
        if op == "moveTo":
            cur = [("M",) + pts[0]]; last = pts[0]
        elif op == "lineTo":
            cur.append(("L",) + pts[0]); last = pts[0]
        elif op == "qCurveTo":
            ctrl, end = pts[:-1], pts[-1]
            for i, c in enumerate(ctrl):
                if i < len(ctrl) - 1:
                    n = ctrl[i + 1]; on = ((c[0] + n[0]) / 2, (c[1] + n[1]) / 2)
                else:
                    on = end
                cur.append(("Q", c[0], c[1], on[0], on[1])); last = on
        elif op == "closePath":
            cs.append(cur); cur = None
    return cs


def subdivide(contour):
    out, p = [], None
    for seg in contour:
        if seg[0] == "M":
            out.append(seg); p = (seg[1], seg[2])
        elif seg[0] == "L":
            e = (seg[1], seg[2])
            for i in range(1, LINE_SEG + 1):
                t = i / LINE_SEG
                out.append(("L", p[0] + (e[0] - p[0]) * t, p[1] + (e[1] - p[1]) * t))
            p = e
        else:
            c, e = (seg[1], seg[2]), (seg[3], seg[4]); a = p
            for i in range(SUB):
                t0, t1 = i / SUB, (i + 1) / SUB
                def q(t): return ((1-t)**2*a[0] + 2*(1-t)*t*c[0] + t*t*e[0], (1-t)**2*a[1] + 2*(1-t)*t*c[1] + t*t*e[1])
                p1 = q(t1)
                # the control point of the sub-curve [t0, t1] of a quadratic: the blossom B(t0, t1)
                cx = a[0]*(1-t0)*(1-t1) + c[0]*((1-t0)*t1 + t0*(1-t1)) + e[0]*t0*t1
                cy = a[1]*(1-t0)*(1-t1) + c[1]*((1-t0)*t1 + t0*(1-t1)) + e[1]*t0*t1
                out.append(("Q", cx, cy, p1[0], p1[1]))
            p = e
    return out


def poly_area(contour):
    pen = AreaPen()
    for seg in contour:
        if seg[0] == "M": pen.moveTo((seg[1], seg[2]))
        elif seg[0] == "L": pen.lineTo((seg[1], seg[2]))
        else: pen.qCurveTo((seg[1], seg[2]), (seg[3], seg[4]))
    pen.closePath()
    return pen.value


def build():
    f = TTFont(FONT); cm = f.getBestCmap(); gs = f.getGlyphSet()
    g = {}
    for k, cp in CP.items():
        pen = RecordingPen(); gs[cm[cp]].draw(pen)
        g[k] = (expand(pen.value), gs[cm[cp]].width)
    parts = {}
    # ---- leaf: one contour, subdivided ----
    parts["leaf"] = {"adv": g["leaf"][1], "contours": [subdivide(c) for c in g["leaf"][0]]}
    # ---- bolt ----
    parts["bolt"] = {"adv": g["bolt"][1], "contours": g["bolt"][0]}
    # ---- scales ----
    sc, adv = g["scales"]
    big, ring, holeL, holeR = sc            # the outline, the pivot's circle, the two triangles inside the pans
    # the outline in order: see the dump -- indices of the segments we cut at
    segs = big
    def find(x, y, kind=None):
        for i, s in enumerate(segs):
            if s[-2] == x and s[-1] == y: return i
        raise SystemExit("anchor (%s,%s) not in the outline" % (x, y))
    BEAM_Y, EAR_Y, FILL_Y = 1084, 1130, 1168
    # --- the beam: the outline above y = 1084, closed by the straight line along the bar's foot; the pivot ring stays in it
    i_top0 = find(622, 1252)                                  # the left end of the bar's top, after the bulb's arc
    # outline from (862,1424): arc to (622,1252), bar to (94,1252), down to (94,1084), along to (262,1084) ...
    beam = [("M", 862, 1424)] + [s for s in segs[1:i_top0 + 1]]
    beam += [("L", 94, 1252), ("L", 94, BEAM_Y)]
    # ... then the foot of the bar, straight across to the right end, and up the right side to the bulb
    beam += [("L", 1630, BEAM_Y), ("L", 1630, 1252)]
    # the right half of the top: from (1630,1252) to (1102,1252), then the bulb's arc back to (862,1424)
    j = find(1102, 1252)
    beam += [s for s in segs[j:]]
    # the pivot's ring is a hole in the bar (kept as it is)
    parts["scales_beam"] = [beam, ring]
    # --- the base: post and foot, the two flares, a filler that lies inside the bar
    i_a = find(622, 1084)           # (622,1084) is where the left pan's string ends and the flare begins
    i_fl = i_a + 1                  # Q (665,972) (778,928)
    base = [("M", 622, BEAM_Y), segs[i_fl]]
    k = i_fl + 1
    while not (segs[k][-2] == 946 and segs[k][-1] == 928):
        base.append(segs[k]); k += 1
    base.append(segs[k])            # to (946,928)
    base.append(segs[k + 1])        # the right flare, Q to (1102,1084)
    base += [("L", 1102, FILL_Y), ("L", 946, FILL_Y), ("L", 946, BEAM_Y), ("L", 778, BEAM_Y), ("L", 778, FILL_Y), ("L", 622, FILL_Y)]
    parts["scales_base"] = [base]
    # --- the pans: each string pair + bowl + the hole, with an ear (to y = EAR_Y) that slots into the bar
    def lerp_x(p, q, y): return p[0] + (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1])
    # left pan: outline from (262,1084) down (10,484) ... (606,484), up to (354,1084)
    iL = find(10, 484)
    pan0 = [("M", lerp_x((262, 1084), (10, 484), EAR_Y), EAR_Y)]
    pan0 += [segs[iL]]
    m = iL + 1
    while not (segs[m][-2] == 606 and segs[m][-1] == 484):
        pan0.append(segs[m]); m += 1
    pan0.append(segs[m])
    pan0.append(("L", lerp_x((354, 1084), (606, 484), EAR_Y), EAR_Y))
    # right pan: (1370,1084) down to (1118,484) ... (1714,484) up to (1462,1084)
    iR = find(1118, 484)
    pan1 = [("M", lerp_x((1370, 1084), (1118, 484), EAR_Y), EAR_Y), segs[iR]]
    m = iR + 1
    while not (segs[m][-2] == 1714 and segs[m][-1] == 484):
        pan1.append(segs[m]); m += 1
    pan1.append(segs[m])
    pan1.append(("L", lerp_x((1462, 1084), (1714, 484), EAR_Y), EAR_Y))
    parts["scales_pan0"] = [pan0, holeL]
    parts["scales_pan1"] = [pan1, holeR]
    parts["scales"] = {"adv": adv}
    return g, parts


def area(cs):
    # signed areas: outer positive-or-negative by orientation; use abs of the sum with holes carried by their own sign
    return sum(poly_area(c) for c in cs)


def check(g, parts):
    whole = area(g["scales"][0])
    base, beam = area(parts["scales_base"]), area(parts["scales_beam"])
    p0, p1 = area(parts["scales_pan0"]), area(parts["scales_pan1"])
    # overlaps: the base's filler lies in the bar (x 622..778, 946..1102, y 1084..1168) and the pans' ears (y 1084..1130)
    filler = ((778 - 622) + (1102 - 946)) * (1168 - 1084)
    parts_sum = base + beam + p0 + p1
    # the ears: two trapezoids, 92 wide at the bar's foot and (the strings converge upwards) 53.3 wide at EAR_Y, 46 tall
    ears = 2 * (92 + 92 - 2 * 46 * 252 / 600) / 2 * 46
    diff = abs(parts_sum) - abs(whole) - filler - ears
    print("area glyph %.0f  parts %.0f  filler %d  ears %.0f  unexplained %.1f" % (whole, parts_sum, filler, ears, diff))
    return abs(diff) < 5


def fmt(v): 
    s = ("%.2f" % v).rstrip("0").rstrip(".")
    return s if s != "-0" else "0"


def contour_js(c):
    return "[" + ",".join('["%s",%s]' % (s[0], ",".join(fmt(v) for v in s[1:])) for s in c) + "]"


def emit(parts):
    L = ['.pragma library', '',
         '// GENERATED by make_glyph_parts.py from the installed "Symbols Nerd Font" -- do not edit. The outlines of the bar icon\'s',
         '// three glyphs in font units (2048 per em, y up) as the parts SiliconGlyphPose.js moves. A contour is a list of',
         '// ["M",x,y] ["L",x,y] ["Q",cx,cy,x,y] segments.', '']
    def block(name, adv, cs):
        L.append("var %s = {adv: %s, contours: [" % (name, adv))
        L.append(",\n".join("  " + contour_js(c) for c in cs))
        L.append("]};\n")
    block("leaf", parts["leaf"]["adv"], parts["leaf"]["contours"])
    block("bolt", parts["bolt"]["adv"], parts["bolt"]["contours"])
    adv = parts["scales"]["adv"]
    for name in ("scales_base", "scales_beam", "scales_pan0", "scales_pan1"):
        block(name, adv, parts[name])
    L.append("var UNITS = 2048;")
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    g, parts = build()
    ok = check(g, parts)
    text = emit(parts)
    if "--check" in sys.argv:
        cur = open(OUT).read() if os.path.exists(OUT) else ""
        print("up to date" if cur == text else "STALE"); sys.exit(0 if cur == text and ok else 1)
    open(OUT, "w").write(text)
    print("wrote", OUT, "ok" if ok else "AREA CHECK FAILED")
