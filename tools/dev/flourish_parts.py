#!/usr/bin/env python3
"""flourish_parts.py -- writes the outlines the bar glyphs' flourishes pose (GlyphOutline.js / PosedGlyph), read from the
installed "Symbols Nerd Font" with fontTools, in font units (y up, the pen on the baseline), as the PARTS each flourish moves:

  modules/notifications/parts/BellParts.js
      bell        md-bell F009A:        body (the shell, the crown's loop, the lip), clapper (the dome under the lip)
      bellSleep   md-bell_sleep F00A0:  body (the shell with its Z cut out), clapper
  modules/bar/system_update/components/ArchiveParts.js
      lid         fa-box_archive F187:  the lid (the rounded bar on top)
      body                              the box with its label slot cut out
  modules/notes/parts/NoteParts.js
      sheet       fa-sticky_note F249:  the square sheet with its bottom-right corner notched out
      flap                              the corner folded over (the triangle in the notch)
  modules/bar/llm/parts/SparkleParts.js
      star        md-star_four_points F0AE2: the one contour
  modules/bar/audio/parts/AudioParts.js    (the audio pill: AudioPose.js)
      speaker     md-volume_low / _medium / _high F057F F0580 F057E:  the cone, then each wave it has, inner first
      mic         md-microphone F036C:  the capsule, the cradle with its stand
      phones      md-headphones F02CB, md-headset F02CE: one part (the pose bends the one outline: cups, band)
      whole       every other output device's glyph (dock, phone, speaker box, car, hdmi, bluetooth): one part
  modules/aerial/bar/parts/NetParts.js    (the networking pill: NetPose.js)
      fan         md-wifi_strength_outline / _1.._4 and their _alert twins:  the fan with its fill (one part; the alerts' "!" a second)
      lan         md-lan_connect F0318:  the upper box, the wire, the lower box
      plane       fa-plane F072;  rune  md-bluetooth F00AF, md-bluetooth_connect F00B1 (the rune; the two dots a second part)
  The pill poses REBUILD some of these while they move (NetPose.js: the rune as the five straight pieces of its one line, the
  wire as a band about its middle line; AudioPose.js: the capsule's seat and middle, the headphones' cups), so build_audio /
  build_net refuse a font whose numbers are not the ones those are built on.
  modules/bridge/bar/BridgeParts.js        (the bridge button: BridgePose.js)
      whole       md-bridge F0618:      the font's outline and its five windows
      left, right                       the same ink cut at mid span into two leaves (the drawbridge's): each one closed
                                        outline with two windows, the middle window a notch in its tip
  modules/shell/parts/SwatchParts.js       (the theme button: SwatchPose.js)
      back, mid   md-palette_swatch F08B5:  the two cards behind, each the sliver that shows
      front                             the card in front with its rivet's hole;  rivet  the rivet's middle
  modules/silicon/bar/SiliconGpuParts.js   (silicon's GPU mode glyph: SiliconGpuPose.js)
      feather     md-feather F06D3:     the one outline (Integrated)
      bulbGlass, bulbBase  md-lightbulb F0335:  the glass, the cap under it (Smart)
      layersTop, layersLower  md-layers F0328:  the slab on top, the one under it (Hybrid)
      fireFlame, fireTongue  md-fire F0238:  the flame, the tongue cut out of it (dGPU-only)

The font's contours ARE the parts (each glyph is drawn as separate contours already), so nothing is cut: `check()` proves the
parts are exactly the glyph's contours (same count, same points) and that every hole is wound against its outline.

  python3 tools/dev/flourish_parts.py            write the files
  python3 tools/dev/flourish_parts.py --check    compare only (exit 1 when stale)
"""
import os
import sys

from fontTools.ttLib import TTFont
from fontTools.pens.recordingPen import RecordingPen
from fontTools.pens.areaPen import AreaPen

FONT = "/usr/share/fonts/TTF/SymbolsNerdFont-Regular.ttf"
ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
BELL_OUT = os.path.join(ROOT, "modules/notifications/parts/BellParts.js")
ARCHIVE_OUT = os.path.join(ROOT, "modules/bar/system_update/components/ArchiveParts.js")
NOTE_OUT = os.path.join(ROOT, "modules/notes/parts/NoteParts.js")
SPARKLE_OUT = os.path.join(ROOT, "modules/bar/llm/parts/SparkleParts.js")
# The note's notch as NotePeelPose.js rebuilds it for any fold (segments 4..8 of the sheet: the right edge down to the notch,
# the notch's top, its rounded inner corner, its left side down to the foot) and the flap's three corners: the pose is the
# font's outline at rest only while these stand.
NOTE_NOTCH = [("L", 1654, 378), ("L", 1241, 378), ("Q", 1167, 378, 1115, 326), ("Q", 1063, 274, 1063, 201), ("L", 1063, -213)]
NOTE_FLAP_BBOX = (1182, -213, 1654, 260)
NOTE_SHEET_BBOX = (0, -213, 1654, 1441)
AUDIO_OUT = os.path.join(ROOT, "modules/bar/audio/parts/AudioParts.js")
NET_OUT = os.path.join(ROOT, "modules/aerial/bar/parts/NetParts.js")
# ---- the bridge button's bridge (BridgePose.js) ----
BRIDGE_OUT = os.path.join(ROOT, "modules/bridge/bar/BridgeParts.js")
BRIDGE = 0xF0618
# What BridgePose.js builds on (md-bridge, a suspension bridge, symmetric about x = 940): the deck (y 316 .. 484) runs through two
# towers (x 172 .. 344 and its mirror, y 144 .. 1084); the hanging cable leaves each tower's shoulder (y 852 its underside, 960
# its top) and is 656 .. 740 at mid span; four suspenders leave five windows between cable and deck. The pose cuts the bridge at
# mid span into two LEAVES, each one closed outline of the font's own points (the middle window becomes a notch in each leaf's
# tip), and turns each about its hinge on the deck, a little out from the tower (x = 420: the deck's two edges are straight there,
# so a point on each changes no ink and lets the leaf bend at it). Every other number below is a point the font draws: the pose is
# the font's bridge at rest only while they stand.
BRIDGE_BBOX = (0, 144, 1880, 1084)
BRIDGE_MID = 940
BRIDGE_HINGE = 420
BRIDGE_LEFT = [("M", 0, 316), ("L", 0, 484), ("L", 172, 484), ("L", 172, 1084), ("L", 344, 1084), ("L", 344, 960),
               ("Q", 460, 856, 614, 798), ("Q", 767, 740, 940, 740), ("L", 940, 656), ("L", 856, 660), ("L", 856, 484),
               ("L", 940, 484), ("L", 940, 316), ("L", 420, 316), ("L", 344, 316), ("L", 344, 144), ("L", 172, 144), ("L", 172, 316)]
# The raised leaf with nothing over its deck: the tower, the pier, the road and the deck's two edges, the hinge's point on each.
BRIDGE_BARE = [("M", 0, 316), ("L", 0, 484), ("L", 172, 484), ("L", 172, 1084), ("L", 344, 1084), ("L", 344, 484), ("L", 420, 484),
               ("L", 940, 484), ("L", 940, 316), ("L", 420, 316), ("L", 344, 316), ("L", 344, 144), ("L", 172, 144), ("L", 172, 316)]
# ---- the theme button's swatch (SwatchPose.js) ----
THEME_OUT = os.path.join(ROOT, "modules/shell/parts/SwatchParts.js")
# md-palette_swatch: the filled swatch, in both modes (the outlined twin, md-palette_swatch_outline F135C, was dark mode's until
# the user took the filled one for both: feedback/general.md "Last flourishes", the second review)
SWATCHES = (0xF08B5,)
# What SwatchPose.js builds on, per glyph: the rivet's middle (the fan turns about it), and the two slivers' segment kinds in the
# font's order -- the back card's starts on its bottom edge where the corner ends, runs to the cut, up the cut, down its left edge
# and round its corner; the middle card's starts on its left edge, rounds its corner, runs along the bottom to the cut and up
# it. The pose rebuilds each sliver as a whole card cut by the card in front, in exactly this order: it is the font's outline at
# rest only while these stand.
SWATCH_RIVET = {0xF08B5: (563, 998)}
SWATCH_BACK_OPS, SWATCH_MID_OPS = "MLLLQQ", "MQQLL"
# ---- silicon's GPU mode glyphs (SiliconGpuPose.js) ----
GPU_OUT = os.path.join(ROOT, "modules/silicon/bar/SiliconGpuParts.js")
GPU_FEATHER, GPU_BULB, GPU_LAYERS, GPU_FIRE = 0xF06D3, 0xF0335, 0xF0328, 0xF0238
# What SiliconGpuPose.js builds on: each part's ink box. The feather's quill runs corner to corner of its box (it rocks and bows
# about the box's middle); the glass stands on y = 102 with its round top about (596, 870) and the cap hangs 172 under it; the
# two slabs are straight-edged, the upper one's middle at (768, 830); the flame stands on its box's foot with its tip at
# (766, 1382), and the tongue is a hole in it.
GPU_BOXES = {"feather": (0, -238, 1704, 1466), "bulbGlass": (0, 102, 1192, 1466), "bulbBase": (340, -238, 852, -70),
             "layersTop": (0, 234, 1536, 1426), "layersLower": (0, -198, 1536, 506),
             "fireFlame": (-6, -166, 1218, 1382), "fireTongue": (470, 70, 894, 706)}
GPU_FEATHER_ENDS = ((0, -238), (1704, 1466))
GPU_FIRE_TIP = (766, 1382)

# The audio pill's glyphs (AudioGlyphs.qml's default table; the bar asks for the unmuted ones only).
SPEAKERS = (0xF057F, 0xF0580, 0xF057E)
MIC = 0xF036C
PHONES = (0xF02CB, 0xF02CE)
AUDIO_WHOLE = (0xF02CF, 0xF011C, 0xF04C3, 0xF010B, 0xF0841, 0xF00AF)
# What AudioPose.js builds on: the capsule's ink box (its seat at y = 400, its middle at 596, 912) and the stem's foot; the
# headphones' cups (their inner top corners 256 either side of x = 768 and 940 under the band's top, the band straight for 172
# above them).
MIC_CAPSULE_BBOX = (340, 400, 852, 1424)
MIC_FOOT = -196
PHONES_CUP_TOP = 940
# The networking pill's (AerialBarButton.qml).
WIFI = (0xF092F, 0xF091F, 0xF0922, 0xF0925, 0xF0928)
WIFI_ALERT = (0xF092B, 0xF0920, 0xF0923, 0xF0926, 0xF0929)
LAN, PLANE, BT, BT_CONNECT = 0xF0318, 0xF072, 0xF00AF, 0xF00B1
# What NetPose.js builds on. The rune's outline and its two holes (md-bluetooth; md-bluetooth_connect's stands BT_CONNECT_SHIFT
# right): the five pieces of its line (NetPose.js RUNE) are these corners, within the font's own 4 units of slack. The wire: an
# L 172 thick about the line down x = 258 from y = 530 to y = 16 and right to x = 768.
BT_OUTLINE = [(1084, 982), (596, 1466), (512, 1466), (512, 822), (120, 1210), (0, 1090), (476, 614), (0, 138), (120, 18), (512, 410),
              (512, -238), (596, -238), (1084, 246), (716, 614)]
BT_HOLES = [[(840, 246), (680, 86), (680, 410)], [(680, 1142), (840, 982), (680, 822)]]
BT_CONNECT_SHIFT = 172
LAN_WIRE = [(172, 530), (172, 102), (172, -70), (768, -70), (768, 102), (344, 102), (344, 530)]
PLANE_BBOX = (0, -331, 2127, 1559)


def expand(rec):
    """a recording pen's value -> contours of ('M',x,y) ('L',x,y) ('Q',cx,cy,x,y) with every implied TrueType point explicit"""
    cs, cur = [], None
    for op, pts in rec:
        if op == "moveTo":
            cur = [("M",) + tuple(pts[0])]
        elif op == "lineTo":
            cur.append(("L",) + tuple(pts[0]))
        elif op == "qCurveTo":
            ctrl, end = pts[:-1], pts[-1]
            for i, c in enumerate(ctrl):
                on = ((c[0] + ctrl[i + 1][0]) / 2, (c[1] + ctrl[i + 1][1]) / 2) if i < len(ctrl) - 1 else end
                cur.append(("Q", c[0], c[1], on[0], on[1]))
        elif op == "closePath":
            cs.append(cur)
            cur = None
    return cs


def area(contour):
    pen = AreaPen()
    for s in contour:
        if s[0] == "M":
            pen.moveTo(s[1:3])
        elif s[0] == "L":
            pen.lineTo(s[1:3])
        else:
            pen.qCurveTo(s[1:3], s[3:5])
    pen.closePath()
    return pen.value


def glyph(cp):
    f = TTFont(FONT)
    cm, gs = f.getBestCmap(), f.getGlyphSet()
    pen = RecordingPen()
    gs[cm[cp]].draw(pen)
    return expand(pen.value), gs[cm[cp]].width, f["head"].unitsPerEm


def bbox(c):
    xs = [v for s in c for v in s[1::2]]
    ys = [v for s in c for v in s[2::2]]
    return min(xs), min(ys), max(xs), max(ys)


def build():
    out = {}
    # ---- the bell: the clapper is the contour wholly below the lip (y < -26), the body the rest ----
    for name, cp in (("bell", 0xF009A), ("bellSleep", 0xF00A0)):
        cs, adv, upm = glyph(cp)
        clapper = [c for c in cs if bbox(c)[3] < -26]
        body = [c for c in cs if bbox(c)[3] >= -26]
        if len(clapper) != 1 or len(body) + 1 != len(cs):
            raise SystemExit("%s: expected one clapper under the lip, got %d" % (name, len(clapper)))
        out[name] = {"adv": adv, "body": body, "clapper": clapper, "all": cs, "upm": upm}
    # ---- the archive: the lid is the contour wholly above the box's top (y >= 1087), the body the rest (box + slot) ----
    cs, adv, upm = glyph(0xF187)
    lid = [c for c in cs if bbox(c)[1] >= 1000]
    body = [c for c in cs if bbox(c)[1] < 1000]
    if len(lid) != 1 or len(body) != 2:
        raise SystemExit("archive: expected a lid and a box with its slot, got %d / %d" % (len(lid), len(body)))
    out["archive"] = {"adv": adv, "lid": lid, "body": body, "all": cs, "upm": upm}
    # ---- the note: the sheet is the larger contour, the flap the triangle in its notch ----
    cs, adv, upm = glyph(0xF249)
    if len(cs) != 2:
        raise SystemExit("note: expected the sheet and its flap, got %d contours" % len(cs))
    sheet, flap = sorted(cs, key=lambda c: -abs(area(c)))
    out["note"] = {"adv": adv, "sheet": [sheet], "flap": [flap], "all": cs, "upm": upm}
    # ---- the sparkle: one contour, eight corners ----
    cs, adv, upm = glyph(0xF0AE2)
    if len(cs) != 1 or len(cs[0]) != 8:
        raise SystemExit("sparkle: expected one contour of eight corners, got %d" % len(cs))
    out["sparkle"] = {"adv": adv, "star": cs, "all": cs, "upm": upm}
    out["audio"] = build_audio()
    out["net"] = build_net()
    out["theme"] = build_theme()
    out["gpu"] = build_gpu()
    out["bridge"] = build_bridge()
    return out


def entry(kind, cs, adv, parts):
    """one glyph of a pill: its kind (which pose moves it), its parts in the pose's order, its ink box"""
    if sum(len(p) for p in parts) != len(cs):
        raise SystemExit("%s: the parts do not hold every contour (%d of %d)" % (kind, sum(len(p) for p in parts), len(cs)))
    bs = [bbox(c) for c in cs]
    box = (min(b[0] for b in bs), min(b[1] for b in bs), max(b[2] for b in bs), max(b[3] for b in bs))
    return {"kind": kind, "adv": adv, "parts": parts, "all": cs, "box": box}


def build_audio():
    g = {}
    for cp in SPEAKERS:
        cs, adv, upm = glyph(cp)
        # the cone starts at the pen; a wave stands right of it, the inner one first
        cone = [c for c in cs if bbox(c)[0] == 0]
        waves = sorted((c for c in cs if bbox(c)[0] > 0), key=lambda c: bbox(c)[2])
        if len(cone) != 1 or bbox(cone[0])[2] != 768:
            raise SystemExit("speaker %X: expected one cone 768 wide at the pen" % cp)
        g[cp] = entry("speaker", cs, adv, [cone] + [[w] for w in waves])
    cs, adv, upm = glyph(MIC)
    capsule = [c for c in cs if bbox(c)[1] >= 400]
    cradle = [c for c in cs if bbox(c)[1] < 400]
    if len(capsule) != 1 or len(cradle) != 1:
        raise SystemExit("mic: expected a capsule over a cradle, got %d / %d" % (len(capsule), len(cradle)))
    if tuple(bbox(capsule[0])) != MIC_CAPSULE_BBOX or bbox(cradle[0])[1] != MIC_FOOT:
        raise SystemExit("mic: the capsule or the stem's foot is not where AudioPose.js tosses and squashes them")
    g[MIC] = entry("mic", cs, adv, [capsule, cradle])
    for cp in PHONES:
        cs, adv, upm = glyph(cp)
        # one outline; the cups' inner top corners where the pose bends it from
        top = bbox(cs[0])[3]
        pts = set(tuple(s[-2:]) for s in cs[0])
        want = {(512, top - PHONES_CUP_TOP), (1024, top - PHONES_CUP_TOP), (172, top - PHONES_CUP_TOP + 172), (1364, top - PHONES_CUP_TOP + 172)}
        if len(cs) != 1 or adv != 1536 or not want <= pts:
            raise SystemExit("phones %X: the cups are not where AudioPose.js bends the band from" % cp)
        g[cp] = entry("phones", cs, adv, [cs])
    for cp in AUDIO_WHOLE:
        cs, adv, upm = glyph(cp)
        g[cp] = entry("whole", cs, adv, [cs])
    return {"glyphs": g, "upm": upm}


def build_net():
    g = {}
    for cp in WIFI:
        cs, adv, upm = glyph(cp)
        g[cp] = entry("fan", cs, adv, [cs])
    for cp in WIFI_ALERT:
        cs, adv, upm = glyph(cp)
        # the "!" is the two boxes right of the fan (its bar over its dot)
        bang = [c for c in cs if bbox(c)[0] >= 1700]
        fan = [c for c in cs if bbox(c)[0] < 1700]
        if len(bang) != 2 or len(fan) != 1:
            raise SystemExit("wifi alert %X: expected a fan and a two-box mark, got %d / %d" % (cp, len(fan), len(bang)))
        g[cp] = entry("fan", cs, adv, [fan, bang])
    cs, adv, upm = glyph(LAN)
    upper = [c for c in cs if bbox(c)[1] >= 698]
    lower = [c for c in cs if bbox(c)[0] >= 856]
    wire = [c for c in cs if bbox(c)[1] < 698 and bbox(c)[0] < 856]
    if len(upper) != 2 or len(lower) != 2 or len(wire) != 1:
        raise SystemExit("lan: expected two boxes (each with its window) and a wire, got %d / %d / %d" % (len(upper), len(lower), len(wire)))
    if [tuple(s[-2:]) for s in wire[0]] != LAN_WIRE:
        raise SystemExit("lan: the wire is not the L NetPose.js rebuilds")
    g[LAN] = entry("lan", cs, adv, [upper, wire, lower])
    cs, adv, upm = glyph(PLANE)
    if len(cs) != 1 or tuple(bbox(cs[0])) != PLANE_BBOX:
        raise SystemExit("plane: not the one outline NetPose.js stretches (its tail at the pen, its heading along y = 614)")
    g[PLANE] = entry("plane", cs, adv, [cs])

    def rune_is(cs, shift):
        """the rune's two holes then its outline, straight edges, at the corners NetPose.js cuts its pieces from"""
        got = [[(s[-2] - shift, s[-1]) for s in c] for c in cs]
        return all(s[0] in "ML" for c in cs for s in c) and got == BT_HOLES + [BT_OUTLINE]

    cs, adv, upm = glyph(BT)
    if not rune_is(cs, 0):
        raise SystemExit("bluetooth: the rune is not the outline NetPose.js cuts its five pieces from")
    g[BT] = entry("rune", cs, adv, [cs])
    cs, adv, upm = glyph(BT_CONNECT)
    # the two dots are the diamonds either side (four straight edges each, 340 wide)
    dots = [c for c in cs if len(c) == 4 and bbox(c)[2] - bbox(c)[0] == 340]
    rune = [c for c in cs if c not in dots]
    if len(dots) != 2 or len(rune) != 3:
        raise SystemExit("bluetooth connect: expected a rune and two dots, got %d / %d" % (len(rune), len(dots)))
    if not rune_is(rune, BT_CONNECT_SHIFT):
        raise SystemExit("bluetooth connect: the rune is not md-bluetooth's, %d right" % BT_CONNECT_SHIFT)
    g[BT_CONNECT] = entry("rune", cs, adv, [rune, dots])
    return {"glyphs": g, "upm": upm}


def build_theme():
    g = {}
    for cp in SWATCHES:
        cs, adv, upm = glyph(cp)
        # the card in front is the large rounded box with what lies inside it (its rivet's hole); the two slivers stand left of
        # it, the back card's furthest left
        big = max(cs, key=lambda c: abs(area(c)))
        bb = bbox(big)
        inside = [c for c in cs if c is not big and bbox(c)[0] > bb[0] and bbox(c)[2] < bb[2] and bbox(c)[1] > bb[1] and bbox(c)[3] < bb[3]]
        slivers = sorted((c for c in cs if c is not big and c not in inside), key=lambda c: bbox(c)[0])
        if len(slivers) != 2:
            raise SystemExit("swatch %X: expected two slivers left of the front card, got %d" % (cp, len(slivers)))
        rivet = [c for c in inside if len(c) == 9 and bbox(c)[2] - bbox(c)[0] == 168]
        if len(rivet) != 1:
            raise SystemExit("swatch %X: expected one rivet in the front card, got %d" % (cp, len(rivet)))
        rb = bbox(rivet[0])
        # the front card's contours in the font's own order
        front = [c for c in cs if c is big or c in inside]
        g[cp] = {"adv": adv, "back": [slivers[0]], "mid": [slivers[1]], "front": front, "all": cs,
                 "rivet": ((rb[0] + rb[2]) / 2, (rb[1] + rb[3]) / 2)}
    return {"glyphs": g, "upm": upm}


def build_gpu():
    g = {}
    cs, adv, upm = glyph(GPU_FEATHER)
    if len(cs) != 1:
        raise SystemExit("gpu feather: expected one outline, got %d" % len(cs))
    g["feather"] = cs
    cs, adv, upm = glyph(GPU_BULB)
    glass = [c for c in cs if bbox(c)[1] >= 0]
    base = [c for c in cs if bbox(c)[3] < 0]
    if len(glass) != 1 or len(base) != 1 or len(cs) != 2:
        raise SystemExit("gpu lightbulb: expected a glass over its cap, got %d / %d" % (len(glass), len(base)))
    g["bulbGlass"], g["bulbBase"] = glass, base
    cs, adv, upm = glyph(GPU_LAYERS)
    top = [c for c in cs if bbox(c)[3] > 1000]
    lower = [c for c in cs if bbox(c)[3] <= 1000]
    if len(top) != 1 or len(lower) != 1 or len(cs) != 2:
        raise SystemExit("gpu layers: expected two slabs, got %d / %d" % (len(top), len(lower)))
    g["layersTop"], g["layersLower"] = top, lower
    cs, adv, upm = glyph(GPU_FIRE)
    if len(cs) != 2:
        raise SystemExit("gpu fire: expected a flame and its tongue, got %d contours" % len(cs))
    flame, tongue = sorted(cs, key=lambda c: -abs(area(c)))
    g["fireFlame"], g["fireTongue"] = [flame], [tongue]
    return {"parts": g, "upm": upm}


def mirror(c):
    """a contour mirrored about the bridge's middle line, wound as it was (the order reversed)"""
    pts = []                                               # the on-curve / control points as one closed list
    for sg in c:
        if sg[0] == "Q":
            pts.append(("c", BRIDGE_MID * 2 - sg[1], sg[2]))
        pts.append(("p", BRIDGE_MID * 2 - sg[-2], sg[-1]))
    pts.reverse()
    k = next(i for i, q in enumerate(pts) if q[0] == "p" and pts[i - 1][0] == "p")      # start after a straight step
    pts = pts[k:] + pts[:k]
    out = [("M", pts[0][1], pts[0][2])]
    i = 1
    while i < len(pts):
        if pts[i][0] == "c":
            end = pts[(i + 1) % len(pts)]
            out.append(("Q", pts[i][1], pts[i][2], end[1], end[2]))
            i += 2
        else:
            out.append(("L", pts[i][1], pts[i][2]))
            i += 1
    return out


def build_bridge():
    cs, adv, upm = glyph(BRIDGE)
    if len(cs) != 6:
        raise SystemExit("bridge: expected the outline and five windows, got %d contours" % len(cs))
    outline = max(cs, key=lambda c: abs(area(c)))
    holes = [c for c in cs if c is not outline]
    lefts = [c for c in holes if bbox(c)[2] <= BRIDGE_MID]                # the two windows of the left leaf
    leaf = list(BRIDGE_LEFT)
    # the hinge's point on the deck's top edge: the foot of the window beside the tower, from its inner corner back to its outer one
    lefts = [c + [("L", BRIDGE_HINGE, 484)] if c[0] == ("M", 512, 484) and c[-1] == ("L", 344, 484) else c for c in lefts]
    left = [leaf] + lefts
    right = [mirror(c) for c in left]
    return {"adv": adv, "whole": [outline] + holes, "left": left, "right": right, "bareLeft": [list(BRIDGE_BARE)], "bareRight": [mirror(BRIDGE_BARE)], "all": cs, "upm": upm, "outline": outline, "holes": holes}


def check_bridge(p):
    pts = lambda c: set((sg[-2], sg[-1]) for sg in c) | set((sg[1], sg[2]) for sg in c if sg[0] == "Q")
    font = set()
    for c in p["all"]:
        font |= pts(c)
    box = tuple(bbox(p["outline"])) == BRIDGE_BBOX
    # every point of the leaf is the font's own, or lies on the cut (x = 940) where the font's deck, window and cable pass
    hinge = {(BRIDGE_HINGE, 316), (BRIDGE_HINGE, 484)}
    hinged = hinge <= (pts(p["left"][0]) | pts(p["left"][1]) | pts(p["left"][2])) and {(344, 316), (344, 484)} <= font
    own = all(q in font or q[0] == BRIDGE_MID or q in hinge for q in pts(BRIDGE_LEFT) | pts(BRIDGE_BARE))
    cut = {(940, 316), (940, 484), (940, 656), (940, 740)} <= pts(BRIDGE_LEFT) and (940, 656) in font and (940, 740) in font
    sym = all((BRIDGE_MID * 2 - x, y) in font for x, y in font)
    wound = all((area(p[k][0]) > 0) == (area(p["outline"]) > 0) for k in ("left", "right", "bareLeft", "bareRight")) \
        and all((area(h) > 0) != (area(p["outline"]) > 0) for h in p["left"][1:] + p["right"][1:])
    # the two leaves are the bridge: their ink is the font's (the middle window's two halves are the notches)
    whole = sum(area(c) for c in p["all"])
    halves = sum(area(c) for c in p["left"]) + sum(area(c) for c in p["right"])
    same = abs(whole - halves) < 1.0
    print("bridge    contours %d  box: %s  the leaf's points are the font's: %s  cut at mid span: %s  hinged: %s  symmetric: %s  wound: %s  two leaves = the bridge: %s (%.0f / %.0f)"
          % (len(p["all"]), box, own, cut, hinged, sym, wound, same, whole, halves))
    return box and own and cut and hinged and sym and wound and same



def check_gpu(table):
    g = table["parts"]
    boxes = all(tuple(bbox(g[k][0])) == GPU_BOXES[k] for k in GPU_BOXES)
    quill = set(tuple(s[-2:]) for s in g["feather"][0])
    ends = all(e in quill for e in GPU_FEATHER_ENDS)
    straight = all(s[0] in "ML" and len(c) == 6 for k in ("layersTop", "layersLower") for c in g[k] for s in c)
    tip = GPU_FIRE_TIP in set(tuple(s[-2:]) for s in g["fireFlame"][0])
    hole = (area(g["fireFlame"][0]) > 0) != (area(g["fireTongue"][0]) > 0)
    print("gpu       parts %d  the boxes the pose builds on: %s  the quill's ends: %s  the slabs straight, six corners: %s  "
          "the flame's tip: %s  the tongue wound against the flame: %s" % (len(g), boxes, ends, straight, tip, hole))
    return boxes and ends and straight and tip and hole


def winding(contours, x, y):
    """the winding number of the contours' polygons (their on-curve points) about (x, y)"""
    w = 0
    for c in contours:
        pts = [s[-2:] for s in c]
        for (x0, y0), (x1, y1) in zip(pts, pts[1:] + pts[:1]):
            if (y0 <= y) != (y1 <= y):
                if x0 + (y - y0) * (x1 - x0) / (y1 - y0) > x:
                    w += 1 if y1 > y0 else -1
    return w


def check_theme(table):
    ok = True
    for cp, e in sorted(table["glyphs"].items()):
        n = len(e["back"]) + len(e["mid"]) + len(e["front"])
        ops = "".join(s[0] for s in e["back"][0]), "".join(s[0] for s in e["mid"][0])
        shape = ops == (SWATCH_BACK_OPS, SWATCH_MID_OPS)
        rivet = tuple(e["rivet"]) == SWATCH_RIVET[cp]
        alike = len({area(c) > 0 for c in (e["back"][0], e["mid"][0], max(e["front"], key=lambda c: abs(area(c))))}) == 1
        # the front card under the winding rule: its rivet is a hole
        rx, ry = e["rivet"]
        hole = winding(e["front"], rx, ry) == 0
        print("swatch %X contours %d  slivers as the pose rebuilds them: %s  rivet %s: %s  wound alike: %s  the rivet a hole: %s"
              % (cp, n, shape, e["rivet"], rivet, alike, hole))
        ok &= n == len(e["all"]) and shape and rivet and alike and hole
    return ok


def check(parts):
    ok = True
    for name in ("bell", "bellSleep"):
        p = parts[name]
        n = len(p["body"]) + len(p["clapper"])
        ok &= n == len(p["all"])
        # the body's outline and its Z (bell-sleep) are wound against each other: a hole
        signs = [area(c) > 0 for c in p["body"]]
        hole = len(signs) == 1 or signs[0] != signs[1]
        print("%-9s contours %d  body %d clapper %d  hole wound against the outline: %s" % (name, n, len(p["body"]), len(p["clapper"]), hole))
        ok &= hole
    a = parts["archive"]
    signs = [area(c) > 0 for c in a["body"]]
    print("archive   contours %d  lid 1 body %d  slot wound against the box: %s" % (len(a["all"]), len(a["body"]), signs[0] != signs[1]))
    ok &= signs[0] != signs[1]
    n = parts["note"]
    notch = [tuple(s) for s in n["sheet"][0][4:9]] == NOTE_NOTCH
    boxes = tuple(bbox(n["flap"][0])) == NOTE_FLAP_BBOX and tuple(bbox(n["sheet"][0])) == NOTE_SHEET_BBOX
    same = (area(n["sheet"][0]) > 0) == (area(n["flap"][0]) > 0)
    print("note      contours %d  the notch where the pose rebuilds it: %s  the sheet's and the flap's boxes: %s  wound alike: %s"
          % (len(n["all"]), notch, boxes, same))
    ok &= notch and boxes and same
    st = parts["sparkle"]["star"][0]
    lines = all(s[0] in "ML" for s in st)
    print("sparkle   corners %d  straight edges: %s" % (len(st), lines))
    ok &= lines
    for name in ("audio", "net"):
        n = 0
        for cp, e in sorted(parts[name]["glyphs"].items()):
            # every part is drawn as ONE path under the winding rule: a contour inside another must be wound against it (a hole
            # in an outline, an island in a hole), so its sign follows how deep it is nested (by ink box).
            for p in e["parts"]:
                def depth(c):
                    b = bbox(c)
                    return sum(1 for o in p if o is not c and bbox(o)[0] <= b[0] and bbox(o)[1] <= b[1]
                               and bbox(o)[2] >= b[2] and bbox(o)[3] >= b[3] and bbox(o) != b)
                outer = [area(c) > 0 for c in p if depth(c) == 0]
                good = len(set(outer)) == 1 and all((area(c) > 0) == (outer[0] if depth(c) % 2 == 0 else not outer[0]) for c in p)
                if not good:
                    print("%s %X: a nested contour is not wound against the one around it" % (name, cp))
                ok &= good
            n += 1
        print("%-9s glyphs %d  every part holds whole contours, holes wound against their outlines" % (name, n))
    ok &= check_theme(parts["theme"])
    ok &= check_gpu(parts["gpu"])
    ok &= check_bridge(parts["bridge"])
    return ok


def fmt(v):
    s = ("%.2f" % v).rstrip("0").rstrip(".")
    return s if s != "-0" else "0"


def contour_js(c):
    return "[" + ",".join('["%s",%s]' % (s[0], ",".join(fmt(v) for v in s[1:])) for s in c) + "]"


def block(name, cs):
    return "var %s = [\n%s\n];\n" % (name, ",\n".join("  " + contour_js(c) for c in cs))


HEAD = [".pragma library", "",
        "// GENERATED by tools/dev/flourish_parts.py from the installed \"Symbols Nerd Font\" -- do not edit. %s",
        "// in font units (%d per em, y up, the pen on the baseline), as the parts its flourish moves (GlyphOutline.js segments:",
        "// [\"M\",x,y] [\"L\",x,y] [\"Q\",cx,cy,x,y]).", ""]


def emit_bell(parts):
    upm = parts["bell"]["upm"]
    L = list(HEAD)
    L[2] = HEAD[2] % "The bell's two glyphs (md-bell F009A, md-bell_sleep F00A0)"
    L[3] = HEAD[3] % upm
    L.append(block("bellBody", parts["bell"]["body"]))
    L.append(block("bellClapper", parts["bell"]["clapper"]))
    L.append(block("sleepBody", parts["bellSleep"]["body"]))
    L.append(block("sleepClapper", parts["bellSleep"]["clapper"]))
    L.append("var UNITS = %d;" % upm)
    return "\n".join(L) + "\n"


def emit_archive(parts):
    a = parts["archive"]
    L = list(HEAD)
    L[2] = HEAD[2] % "The archive box (fa-box_archive F187)"
    L[3] = HEAD[3] % a["upm"]
    L.append(block("lid", a["lid"]))
    L.append(block("body", a["body"]))
    L.append("var UNITS = %d;" % a["upm"])
    return "\n".join(L) + "\n"


def emit_note(parts):
    n = parts["note"]
    L = list(HEAD)
    L[2] = HEAD[2] % "The note (fa-sticky_note F249)"
    L[3] = HEAD[3] % n["upm"]
    L.append(block("sheet", n["sheet"]))
    L.append(block("flap", n["flap"]))
    L.append("var UNITS = %d;" % n["upm"])
    return "\n".join(L) + "\n"


def emit_sparkle(parts):
    s = parts["sparkle"]
    L = list(HEAD)
    L[2] = HEAD[2] % "The sparkle (md-star_four_points F0AE2)"
    L[3] = HEAD[3] % s["upm"]
    L.append(block("star", s["star"]))
    L.append("var UNITS = %d;" % s["upm"])
    return "\n".join(L) + "\n"


def emit_pill(what, title, table):
    L = list(HEAD)
    L[2] = HEAD[2] % title
    L[3] = HEAD[3] % table["upm"]
    L.insert(5, "// G[<the glyph's codepoint, hex>] = { kind (which pose moves it), adv (its advance), box (its ink: x0, y0, x1, y1),")
    L.insert(6, "// parts (each a list of contours, in the pose's order) }.")
    L.append("var G = {")
    rows = []
    for cp, e in sorted(table["glyphs"].items()):
        parts = ",\n".join("      [" + ", ".join(contour_js(c) for c in p) + "]" for p in e["parts"])
        rows.append('  "%x": { kind: "%s", adv: %s, box: [%s], parts: [\n%s\n  ] }' % (
            cp, e["kind"], fmt(e["adv"]), ",".join(fmt(v) for v in e["box"]), parts))
    L.append(",\n".join(rows))
    L.append("};\n")
    L.append("var UNITS = %d;" % table["upm"])
    return "\n".join(L) + "\n"


def emit_theme(table):
    L = list(HEAD)
    L[2] = HEAD[2] % "The theme button's swatch (md-palette_swatch F08B5)"
    L[3] = HEAD[3] % table["upm"]
    L.insert(5, "// G[<the glyph's codepoint, hex>] = { adv (its advance), rivet (the rivet's middle: what the fan turns about), back, mid (the")
    L.insert(6, "// two cards behind: the sliver of each that shows), front (the card in front, with its rivet's hole) }.")
    L.append("var G = {")
    rows = []
    for cp, e in sorted(table["glyphs"].items()):
        body = ",\n".join("    %s: [\n%s\n    ]" % (k, ",\n".join("      " + contour_js(c) for c in e[k])) for k in ("back", "mid", "front"))
        rows.append('  "%x": { adv: %s, rivet: [%s],\n%s\n  }' % (cp, fmt(e["adv"]), ",".join(fmt(v) for v in e["rivet"]), body))
    L.append(",\n".join(rows))
    L.append("};\n")
    L.append("var UNITS = %d;" % table["upm"])
    return "\n".join(L) + "\n"


def emit_gpu(table):
    L = list(HEAD)
    L[2] = HEAD[2] % "Silicon's GPU mode glyphs (md-feather F06D3, md-lightbulb F0335, md-layers F0328, md-fire F0238)"
    L[3] = HEAD[3] % table["upm"]
    for k in ("feather", "bulbGlass", "bulbBase", "layersTop", "layersLower", "fireFlame", "fireTongue"):
        L.append(block(k, table["parts"][k]))
    L.append("var UNITS = %d;" % table["upm"])
    return "\n".join(L) + "\n"


def emit_bridge(p):
    L = list(HEAD)
    L[2] = HEAD[2] % "The bridge button's bridge (md-bridge F0618)"
    L[3] = HEAD[3] % p["upm"]
    L.append("// `whole`: the font's outline and its five windows. `left` / `right`: the same ink cut at mid span (x = 940) into two leaves,")
    L.append("// each one closed outline with its two windows; the middle window is a notch in each leaf's tip. A point on the deck's edges at")
    L.append("// x = 420 (and its mirror) is where a leaf hinges: they are straight there, so it changes no ink. `bareLeft` / `bareRight`: a leaf")
    L.append("// with nothing over its deck (the raised one, its cable folded flat).")
    L.append(block("whole", p["whole"]))
    L.append(block("left", p["left"]))
    L.append(block("right", p["right"]))
    L.append(block("bareLeft", p["bareLeft"]))
    L.append(block("bareRight", p["bareRight"]))
    L.append("var UNITS = %d;" % p["upm"])
    return "\n".join(L) + "\n"


if __name__ == "__main__":
    parts = build()
    ok = check(parts)
    files = ((BELL_OUT, emit_bell(parts)), (ARCHIVE_OUT, emit_archive(parts)),
             (AUDIO_OUT, emit_pill("audio", "The audio pill's glyphs (AudioGlyphs.qml: the speaker's levels, the microphone, the other output devices)", parts["audio"])),
             (NET_OUT, emit_pill("net", "The networking pill's glyphs (AerialBarButton.qml: the Wi-Fi fan's levels and alerts, the wire, the plane, Bluetooth)", parts["net"])),
             (NOTE_OUT, emit_note(parts)), (SPARKLE_OUT, emit_sparkle(parts)),
             (THEME_OUT, emit_theme(parts["theme"])), (GPU_OUT, emit_gpu(parts["gpu"])),
             (BRIDGE_OUT, emit_bridge(parts["bridge"])))
    if "--check" in sys.argv:
        stale = [p for p, t in files if not os.path.exists(p) or open(p).read() != t]
        print("FLOURISH_PARTS RESULT %s%s" % ("PASS" if ok and not stale else "FAIL", (" stale: " + " ".join(stale)) if stale else ""))
        sys.exit(0 if ok and not stale else 1)
    for p, t in files:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(t)
        print("wrote", p)
    print("FLOURISH_PARTS RESULT %s" % ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)
