#!/usr/bin/env python3
"""Write the gooey field's uniform block into both of its shaders.

    tools/dev/gooey_field_ubo.py            # rewrite, then: tools/dev/bake_shaders.sh gooey_field

The vertex and fragment shader of one ShaderEffect must declare the SAME std140
block, byte for byte in layout, or the members after the first difference read
garbage. The block is long (12 bodies x 5 vec4, 24 fillets x 3, 24 seams, 48
tiles, because QML arrays do not bind to uniform arrays in Qt 6.11), so it is
generated here and nowhere typed by hand. GooeyField.qml's ShaderEffect declares
a property of the same name for every member.

The block goes between `// @@UBO-BEGIN` and `// @@UBO-END` if present, otherwise
it replaces a line `//@@UBO@@` or the existing `layout(std140, ...) uniform buf {...};`.

The fragment shader's EVALUATION block is generated here too, between
`// @@EVAL-BEGIN` and `// @@EVAL-END`: one call per primitive on its own named
uniform, under guards NESTED by the counts. A loop over a local array of those
uniforms is a scratch-memory copy on iris (240 memory sends per fragment, before
any early-out), and FLAT guards let the compiler hoist the pulls out of them
again, so both shapes are generated rather than written by hand.

THE PACKED LANES (between `// @@PACK-BEGIN` and `// @@PACK-END` in the fragment
shader). The smooth group and the ripple add no member to the block. On iris the
GL block is laid out dword-packed and the fragment shader's first ~2 KiB (from
the counts on) are PUSHED; everything after is PULLED, 64 bytes per send
(measured: a push window of [64, 2044), the fillets' tail and the seams in six
pulls). A new member anywhere before the seams shifts that tail out of the window
(+2 sends for 26 floats), one after them is a pulled line of its own for every
branch that reads it (+6). But the fillet bleeds g0..g23 only ever carry x and
y: their z and w are free, and g0..g11 lie inside the push window. So the
group's two numbers and the ripple's twenty-two live in g0.zw..g11.zw, named by
#defines in the fragment shader and written by GooeyField through `packNames`
(generated below) -- a pushed read, no send (tools/dev/perf/gooey_shader_gate.sh).

The TINT block (between `// @@TINT-BEGIN` and `// @@TINT-END`) is the same shape
for the colour: each body's box distance, on its own named uniform under the same
nested guards, routed into the group of the tint that body carries or into the
untinted rest. Which bodies carry a tint (tintIdA/B/C) sits in the std140
PADDING after `showTiles` -- the same 16 bytes, so no member moves and the block
they share with the counts is pushed already. The colours and the reach are the
LAST members and only the vertex shader reads them: it hands them on as
varyings, so the fragment shader pulls no uniform it did not pull before
(tools/dev/perf/gooey_shader_gate.sh counts the sends), and a varying costs its
per-lane registers only where the colour is mixed, at the very end.

THE REEL PASS (gooey_field.frag, THE REEL PASS; ReelCast.qml). The same fragment source is baked a second time with REEL_PASS defined
(gooey_reel.frag.qsb, the `// QSB-VARIANT:` line in the source, tools/dev/bake_shaders.sh) and drawn by a second ShaderEffect over
the popups' content, with the SAME uniform block and the field's own vertex shader. Its evaluation (`// @@REELEVAL`: every body
into its class's distance, every fillet into the union's or the popups', the union's seams) and its lanes (`// @@REELPACK`: REEL_PACK
below, in the g<i>.zw the field's group and ripple use -- neither is compiled into the pass) are generated here, behind the #ifdef, and
ReelCast.qml's ShaderEffect gets the same property list as GooeyField's (`// @@PROPS`). Nothing of it reaches the field's pack: baked
without REEL_PASS the source is the same SPIR-V, and the pack the same bytes (cmp them after any change here).
"""
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
SHADERS = os.path.join(ROOT, "modules/bar/gooey/shaders")
FILES = [os.path.join(SHADERS, "gooey_field.vert"), os.path.join(SHADERS, "gooey_field.frag")]

BODIES, FILLETS, SEAMS, TILES = 12, 24, 24, 48
# THE SKY in the shadow: how many of the sky's fillets (first in the list, GooeyField) a shadow tile evaluates. Four are ever on the
# screen: both ends of the centre island and the inner ends of the left and right ones (an island's end AT a screen corner flares
# off-screen, where GooeyGeometry does not keep its fillet). Each costs ~72 instructions in the shadow's branch (gooey_shader_gate).
SKY_FILLETS = 4
# THE SHELL'S EDGE: the shadow's own tiles come FIRST in the same list (GooeyField, gooey_field.vert), so the
# list is twice the shape's budget. They are read by the vertex shader only, like the tints.
SHADOW_TILES = 48
ALL_TILES = TILES + SHADOW_TILES
EDGE_INKS = ["shadowColor", "borderColor", "shadowParam", "shadowShape"]
TINT_COLOURS = ["tintA", "tintB", "tintC"]
TINT_IDS = ["tintIdA", "tintIdB", "tintIdC"]
# THE AURA (gooey_field.frag, THE AURA): the coloured halo that can light up the shadow. Eleven vec4s right after the shadow's
# ink (the seams and everything the shape reads stay where they were; the tile list the vertex shader reads moves down): four palette colours (rgb; the w lanes
# carry the ink shown of group A and of the rest, the frame's wave count and group A's body mask), the three loops' rectangles, their
# middles (auraMid: group A's and the frame's; auraChainMid: the chain's, nothing and its body mask), and THE JOIN's lanes of group A and
# the chain (auraJoinA, auraJoinC: [s_a, +-share, U_a, U_b], their hue round their own loop, met with the frame's at the junctions; a plain
# loop is [0, 1, 0, its waves]). The aura's on/off, level and time ride the shadow's own free lanes (shadowShape.zw) and its reach
# shadowParam.x, in the block's pulled line the shadow tile reads anyway. Every lane reads 0 with the aura off.
AURA_VECS = ["auraC0", "auraC1", "auraC2", "auraC3", "auraRect", "auraFrame", "auraChain", "auraMid", "auraChainMid", "auraJoinA", "auraJoinC"]

# The packed lanes, g<i>.z and g<i>.w for i < len(PACK) (module docstring). Every
# value reads 0 when its feature is off, so a field whose lanes were never
# written draws the plain chain.
PACK = [
    # THE SMOOTH GROUP: a bit per body that blends, and the blend radius.
    ("smoothMask", "smoothK"),
    # THE RIPPLE: 0 off, else 1 + the moving face (0 top, 1 bottom, 2 left,
    # 3 right) of the body in slot 0; how far a crest can reach past the face;
    # the reflection orders evaluated; the deepest a trough may go.
    ("rippleMode", "rippleCrest"),
    ("rippleOrders", "rippleFloor"),
    # The three impact sources, reduced per frame (GooeyRipple.frame): where,
    # the envelope's radius, the amplitude, the carrier's phase.
    ("rippleSrc0q", "rippleSrc0r"), ("rippleSrc0a", "rippleSrc0p"),
    ("rippleSrc1q", "rippleSrc1r"), ("rippleSrc1a", "rippleSrc1p"),
    ("rippleSrc2q", "rippleSrc2r"), ("rippleSrc2a", "rippleSrc2p"),
    # The packets' 1/sigma and wavenumber, the source's smoothing a^2, and the
    # bulge: where, its amplitude now, and 1 / (2 w^2).
    ("rippleInvSigma", "rippleK"),
    ("rippleA2", "rippleBulgeAt"),
    ("rippleBulgeAmp", "rippleBulgeInv"),
]
# THE NECK (the launcher's confirm flourish, round 4): an explicit bridge between
# two group members, ALIASED onto lanes the ripple uses. The ripple and the neck
# are never on together (GooeyField drops the ripple while a neck is drawn), so
# the neck costs no uniform: 17 numbers on lanes that are already pushed. Every
# lane reads 0 with the neck off, which is the shader's "no neck" (neckB = 0).
#   neckB      1 + the slot of the body that is side B (the launcher); 0 = off
#   neckA      capU's wide end (inside the card's foot)      neckMu  its tip (the waist)
#   neckL      capL's wide end (inside the launcher's face)  neckMl  its tip (the waist)
#   neckRA, neckQU, neckRL, neckQL   the four radii (capU: wide, tip; capL: wide, tip)
#   neckKA, neckKB, neckKMid, neckKJoin   the blend radii (card, launcher, caps, join)
NECK = [
    ("neckB", "rippleCrest"),
    ("neckAx", "rippleOrders"), ("neckAy", "rippleFloor"),
    ("neckMux", "rippleSrc0q"), ("neckMuy", "rippleSrc0r"),
    ("neckLx", "rippleSrc0a"), ("neckLy", "rippleSrc0p"),
    ("neckMlx", "rippleSrc1q"), ("neckMly", "rippleSrc1r"),
    ("neckRA", "rippleSrc1a"), ("neckQU", "rippleSrc1p"),
    ("neckRL", "rippleSrc2q"), ("neckQL", "rippleSrc2r"),
    ("neckKA", "rippleSrc2a"), ("neckKB", "rippleSrc2p"),
    ("neckKMid", "rippleInvSigma"), ("neckKJoin", "rippleK"),
]
PUSHED_G = 12      # g0..g11 lie inside the fragment shader's push window (measured)
assert len(PACK) <= PUSHED_G

# THE REEL PASS's lanes, g<i>.z and g<i>.w (None: the field's own lane there, kept -- g0.w is smoothK, the halo's blend radius):
#   reelR, reelB    how many of the first bodies are the reel group, and how many after them its bars (the rest: the popups)
#   reelFM          how many of the first fillets are the union's own (the rest: the popups')
#   reelBlend       the radius of THE SHARE (the fillets' size: GooeyField.blendRadius)
#   reelInk0..3     the ink of the group's bodies, by slot (their content's fade)
REEL_PACK = [
    (None, None),
    ("reelR", "reelB"),
    ("reelFM", "reelBlend"),
    ("reelInk0", "reelInk1"),
    ("reelInk2", "reelInk3"),
]
REEL_GROUP = 4     # the strip and its three levels
# How much of the block the pass evaluates: the first REEL_BODIES bodies, REEL_FILLETS fillets and REEL_SEAMS seams (ReelCast sorts what
# is near the reel group into them and drops the rest). The pass's pipeline is compiled apart from the field's, and a shader's compile
# grows with what is unrolled into it: with the field's full 12 / 24 / 24 it was 6700 instructions and 2.3 s on a cold driver cache in
# a Wayland context -- one frame of that length the first time a reel lay over a popup. A strip, its three levels, two bars and two
# popups are 8 bodies; their joins near the strip a dozen fillets.
REEL_BODIES, REEL_FILLETS, REEL_SEAMS = 8, 12, 8


def names(prefix, n):
    return [f"{prefix}{i}" for i in range(n)]


def rows(prefix, n, per=8):
    out = []
    all_ = names(prefix, n)
    for i in range(0, n, per):
        out.append("    vec4  " + ", ".join(all_[i:i + per]) + ";")
    return out


def block():
    lines = [
        "// @@UBO-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
        "layout(std140, binding = 0) uniform buf {",
        "    mat4  qt_Matrix;",
        "    float qt_Opacity;",
        # In the 12 bytes of padding that std140 leaves before `fieldColor`: no member moves. How many of
        # the tile list's first tiles are SHADOW tiles (0: the shadow is off).
        "    float shadowTiles;",
        "    vec4  fieldColor;",
        "    float bodyCount;",
        "    float filletCount;",
        "    float seamCount;",
        "    float tileCount;",
        "    float showTiles;",
        # The padding after showTiles (b0 is aligned to 16 either way): the
        # bodies carrying tint A, B, C, or -1.
        "    float " + ", ".join(TINT_IDS) + ";",
    ]
    lines += rows("b", BODIES, 12)      # boxes x0 y0 x1 y1
    lines += rows("x", BODIES, 12)      # corner ellipse semi-axis along x: TL TR BR BL
    lines += rows("y", BODIES, 12)      # corner ellipse semi-axis along y
    lines += rows("u", BODIES, 12)      # corner ellipse centre inset from the corner, x
    lines += rows("v", BODIES, 12)      # corner ellipse centre inset from the corner, y
    lines += rows("f", FILLETS, 12)     # fillet: vertex x, y, signed rect extent x, y
    lines += rows("k", FILLETS, 12)     # fillet ellipse: centre x, y, semi-axes x, y
    lines += rows("g", FILLETS, 12)     # fillet bleed toward -sign: x, y
    lines += rows("s", SEAMS, 12)       # seam rect x0 y0 x1 y1
    # The shell's edge (shaders/gooey_field.frag, THE SHELL'S EDGE): the shadow colour (premultiplied, its
    # alpha the strength), the border colour, (offset x, offset y, the shadow's reach, the border's width)
    # and the shadow's shape (spread, softness, 0, 0). Four vec4s, 64 bytes, RIGHT AFTER THE SEAMS on a 64-byte
    # boundary: the fragment shader pulls them in the one memory read it spends on them, at the end, and holds
    # nothing for them while it evaluates the
    # field -- as three more varyings they cost registers the shader has not got (the SIMD16 compile
    # went from the scheduler's top-down mode to its last resort, "none", for 8 more live values).
    lines.append("    vec4  " + ", ".join(EDGE_INKS) + ";")
    # THE AURA, next to the ink it lies over (AURA_VECS): the shadow tile's pull of the ink and the aura's are neighbouring lines.
    lines.append("    vec4  " + ", ".join(AURA_VECS) + ";")
    lines += rows("t", ALL_TILES, 8)    # tile rect x0 y0 x1 y1 (the shadow's first, then the shape's)
    # Read by the vertex shader only (see the module docstring): the tint
    # colours A, B, C (premultiplied) and how far a tint reaches past a join.
    lines.append("    vec4  " + ", ".join(TINT_COLOURS) + ";")
    lines.append("    float tintReach;")
    lines += ["};", "// @@UBO-END"]
    return "\n".join(lines)


def nested(count, n, call, start=0):
    """`call(i)` for start <= i < n, each behind `count > i`, nested so nothing hoists."""
    out = []
    for i in range(start, n):
        pad = "    " + "    " * min(i - start, 1)
        out.append(f"{pad}if ({count} > {i}) {{")
        out.append(f"{pad}    {call(i)}")
    out.append("    " + "}" * (n - start))
    return out


def bit(i):
    """The smooth group's bit for body i, as the shader tests it (2^-i exact)."""
    return f"groupBit(smoothMask, {1.0 / (1 << i)!r})"


def pack_block():
    lines = ["// @@PACK-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)"]
    for i, (z, w) in enumerate(PACK):
        lines.append(f"#define {z} g{i}.z")
        lines.append(f"#define {w} g{i}.w")
    for k in range(3):
        n = f"rippleSrc{k}"
        lines.append(f"#define {n} vec4({n}q, {n}r, {n}a, {n}p)")
    for n, target in NECK:
        lines.append(f"#define {n} {target}")
    lines.append("#define neckA vec2(neckAx, neckAy)")
    lines.append("#define neckMu vec2(neckMux, neckMuy)")
    lines.append("#define neckL vec2(neckLx, neckLy)")
    lines.append("#define neckMl vec2(neckMlx, neckMly)")
    lines.append("// @@PACK-END")
    return "\n".join(lines)


def eval_block():
    # One chain for everything. Each body goes into the hard-min chain or the
    # smooth group by its bit (withGroup: one bodyDist per body, the choice a
    # uniform branch). With no group and no ripple every body takes the chain
    # exactly as withBody did, and the group's distance stays at 1e9, which the
    # final min leaves alone. The rippling body is always slot 0 and goes LAST,
    # so its crest-grown box can skip it against everything else
    # (gooey_field.frag, THE RIPPLE). A second, plain copy of the chain for the
    # idle case cost 2400 instructions and SIMD32 its register allocation.
    lines = ["// @@EVAL-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
             "    int nb = int(bodyCount + 0.5);",
             "    float ds = 1e9;",
             "    float dsB = 1e9;",
             "    vec4 gds = vec4(0.0);",
             "    bool rip = rippleMode > 0.5;",
             "    if (nb > 0 && !rip)",
             f"        d = withGroup(d, ds, dsB, gds, {bit(0)}, 1.0, p, b0, x0, y0, u0, v0);"]
    lines += nested("nb", BODIES,
                    lambda i: f"d = withGroup(d, ds, dsB, gds, {bit(i)}, {i + 1}.0, p, b{i}, x{i}, y{i}, u{i}, v{i});",
                    start=1)
    lines += ["    if (nb > 0 && rip)",
              f"        d = withRipple(d, ds, {bit(0)}, p, b0, x0, y0, u0, v0);",
              "    if (neckB > 0.5 && !rip)",
              "        ds = neckBridge(p, ds, dsB);",
              "    d = min(d, ds);"]
    # The SKY's flares are a SHADOW tile's alone, so they are evaluated in its branch (sky_block), not here: a value the shadow
    # keeps from before them (THE COVE's dBody) would otherwise be live across every fillet and seam of the shape's path
    # (SIMD16 fell from top-down scheduling to non-lifo for it).
    lines += ["", "    int nf = (d < deep || vTile < 0.0) ? 0 : int(filletCount + 0.5);"]
    lines += nested("nf", FILLETS, lambda i: f"if (d >= deep) d = withFillet(d, p, f{i}, k{i}, g{i});")
    lines += ["", "    int ns = (d < deep || vTile < 0.0) ? 0 : int(seamCount + 0.5);"]
    lines += nested("ns", SEAMS, lambda i: f"d = min(d, sdBox(p, s{i}.xy, s{i}.zw));")
    lines.append("// @@EVAL-END")
    return "\n".join(lines)


def reel_pack_block():
    lines = ["// @@REELPACK-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)"]
    for i, (z, w) in enumerate(REEL_PACK):
        if z:
            lines.append(f"#define {z} g{i}.z")
        if w:
            lines.append(f"#define {w} g{i}.w")
    lines.append("// @@REELPACK-END")
    return "\n".join(lines)


def reel_eval_block():
    """THE REEL PASS's evaluation: the field's shape again, by class (gooey_field.frag, THE CLASSES). Each primitive on its own named
    uniform under the nested guards, like the field's own (a loop over the uniforms is scratch memory on iris)."""
    lines = ["// @@REELEVAL-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
             "    int nb = int(bodyCount + 0.5);"]
    lines += nested("nb", REEL_BODIES,
                    lambda i: f"reelBody({i}.0, {'reelInk%d' % i if i < REEL_GROUP else '0.0'}, p, b{i}, x{i}, y{i}, u{i}, v{i}, dC, ink);")
    lines += ["    d = vTile < 0.0 ? smin(dC.x, dC.y, max(smoothK, 0.001)) : min(dC.x, dC.y);",
              "    dP = dC.z;",
              "    int nf = int(filletCount + 0.5);"]
    lines += nested("nf", REEL_FILLETS, lambda i: f"reelFillet({i}.0, p, f{i}, k{i}, g{i}, d, dP);")
    lines += ["    int ns = vTile < 0.0 ? 0 : int(seamCount + 0.5);"]
    lines += nested("ns", REEL_SEAMS, lambda i: f"d = min(d, sdBox(p, s{i}.xy, s{i}.zw));")
    lines.append("// @@REELEVAL-END")
    return "\n".join(lines)


def sky_block():
    # A SHADOW tile (vTile < 0) draws the union of the BODIES and the SKY's flares alone: a fillet between two
    # bodies only rounds a concave corner the surface is drawn with, and read as part of the shadow's shape it left
    # a dimple (a ball of lighter shadow) at the middle of every arc, where the distance to the arc's three nearest
    # points is the same and largest. A sky fillet IS the shape -- an island's flare into the screen's edge, with no
    # body on the other side for the bodies' smooth union to round -- and without it the shadow ran straight up the
    # island's side behind the flare (the user, feedback/general.md "Shadow tweaks"). It is taken EXACTLY (skyFillet:
    # the true distance to the drawn flare, a hard min): the shadow is one band of the same thickness all round the
    # outline (the user, 2026-10-23: "a gradient at the same thickness across the board"); a triangle under the arc,
    # smooth-unioned in, had made it wider under every flare, and withFillet's own bound drew a blob in the cove. GooeyField puts the sky's fillets first and their count in
    # filletCount's fraction (n + sky / 64: the shape's int(x + 0.5) reads n, a pushed lane, no member).
    # In the shadow's branch, d is already clamped at `deep`: a pixel two inside the bodies is left there, as before (the flares
    # were skipped at d < deep, and min'ed in and clamped otherwise -- the same value). THE COVE reads the bodies' smooth union
    # without the flares (gooey_field.frag, auraCoveRest): kept here, before they come in.
    lines = ["// @@SKY-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
             "        float dBody = d;",
             "        int nsk = d > deep ? int(fract(filletCount) * 64.0 + 0.5) : 0;"]
    for ln in nested("nsk", SKY_FILLETS, lambda i: f"d = min(d, skyFillet(p, f{i}, k{i}, g{i}));"):
        lines.append("    " + ln)
    lines += ["        d = max(d, deep);",
              "// @@SKY-END"]
    return "\n".join(lines)


def tint_block():
    lines = ["// @@TINT-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
             "    if (tintIdA > -0.5 && cov > 0.0) {",
             "        vec3 dT = vec3(1e9);",
             "        float dR = 1e9;"]
    for ln in nested("nb", BODIES, lambda i: f"tintRoute({i}.0, b{i}, p, dT, dR);"):
        lines.append("    " + ln)
    lines += ["        col = tintMix(col, dT, dR);",
              "    }",
              "// @@TINT-END"]
    return "\n".join(lines)


def aura_block():
    """THE AURA's routing: each body's box distance into its loop (group A's, the frame's, the chain's), on the body's own named
    uniform under the nested guards -- the tint's shape (a loop over uniforms spills); then THE COVE, the aura's own distance with the
    sky's flare ends blended into the rest (gooey_field.frag). Reached only by a shadow pixel while an aura plays."""
    lines = ["// @@AURA-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
             "        vec3 dAura = vec3(1e9);"]
    for ln in nested("nb", BODIES,
                     lambda i: f"auraRoute({1.0 / (1 << i)!r}, b{i}, p, dAura);"):
        lines.append("    " + ln)
    # THE COVE (gooey_field.frag): the aura's own distance, d with each of the sky's flares' ends smooth-unioned into the rest -- the
    # bodies' smooth union (dBody) -- under the same nested guards; the rest's gradient is taken here, in the uniform branch (a quad's
    # differences).
    lines += ["        float dA = d;",
              "        int nskA = int(fract(filletCount) * 64.0 + 0.5);",
              "        if (nskA > 0) {",
              "            vec3 rest = auraCoveRest(dBody);",
              "            dA = auraCoveEnds(dA, p, f0, k0, rest);"]
    for ln in nested("nskA", SKY_FILLETS, lambda i: f"dA = auraCoveEnds(dA, p, f{i}, k{i}, rest);", start=1):
        lines.append("        " + ln)
    lines += ["        }",
              "// @@AURA-END"]
    return "\n".join(lines)


def write_eval():
    fn = os.path.join(SHADERS, "gooey_field.frag")
    src = open(fn).read()
    new, n = re.subn(r"// @@EVAL-BEGIN.*?// @@EVAL-END", lambda m: eval_block(), src, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.frag: no @@EVAL markers")
        return 1
    new, n = re.subn(r"// @@SKY-BEGIN.*?// @@SKY-END", lambda m: sky_block(), new, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.frag: no @@SKY markers")
        return 1
    new, n = re.subn(r"// @@TINT-BEGIN.*?// @@TINT-END", lambda m: tint_block(), new, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.frag: no @@TINT markers")
        return 1
    new, n = re.subn(r" *// @@AURA-BEGIN.*?// @@AURA-END", lambda m: aura_block(), new, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.frag: no @@AURA markers")
        return 1
    new, n = re.subn(r"// @@PACK-BEGIN.*?// @@PACK-END", lambda m: pack_block(), new, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.frag: no @@PACK markers")
        return 1
    new, n = re.subn(r"// @@REELPACK-BEGIN.*?// @@REELPACK-END", lambda m: reel_pack_block(), new, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.frag: no @@REELPACK markers")
        return 1
    new, n = re.subn(r"// @@REELEVAL-BEGIN.*?// @@REELEVAL-END", lambda m: reel_eval_block(), new, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.frag: no @@REELEVAL markers")
        return 1
    if new != src:
        open(fn, "w").write(new)
        print("ok    gooey_field.frag: evaluation written")
    else:
        print("same  gooey_field.frag evaluation")
    return 0


def tile_blocks():
    """The vertex shader's two tile-dependent pieces: the mesh's row count and the array of tiles."""
    nm = names("t", ALL_TILES)
    body = (",\n" + " " * 26).join(", ".join(nm[i:i + 8]) for i in range(0, ALL_TILES, 8))
    # GLSL ES 1.00 has no array constructor: its variant (the bake compiles per target, tools/dev/bake_shaders.sh) writes the same tiles
    # one by one; every other variant keeps the constructor, so their text does not move
    ones = "\n".join("    " + " ".join(f"T[{j}] = {nm[j]};" for j in range(i, min(i + 8, ALL_TILES))) for i in range(0, ALL_TILES, 8))
    arr = "\n".join(["// @@TARR-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
                     "#if defined(QSHADER_GLSL_ES) && QSHADER_GLSL_VERSION < 300",
                     f"    vec4 T[{ALL_TILES}];",
                     ones,
                     "#else",
                     f"    vec4 T[{ALL_TILES}] = vec4[{ALL_TILES}](" + body + ");",
                     "#endif",
                     "// @@TARR-END"])
    rows_ = "\n".join(["// @@ROWS-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)",
                       f"const float ROWS = {4 * ALL_TILES - 1}.0;",
                       f"const int SHAPE_BASE = {SHADOW_TILES};",
                       "// @@ROWS-END"])
    return arr, rows_


def write_tiles():
    fn = os.path.join(SHADERS, "gooey_field.vert")
    src = open(fn).read()
    arr, rows_ = tile_blocks()
    new, n = re.subn(r" *// @@TARR-BEGIN.*?// @@TARR-END", lambda m: arr, src, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.vert: no @@TARR markers")
        return 1
    new, n = re.subn(r"// @@ROWS-BEGIN.*?// @@ROWS-END", lambda m: rows_, new, count=1, flags=re.S)
    if n != 1:
        print("FAIL  gooey_field.vert: no @@ROWS markers")
        return 1
    if new != src:
        open(fn, "w").write(new)
        print("ok    gooey_field.vert: tile array written")
    else:
        print("same  gooey_field.vert tile array")
    return 0


QML = os.path.join(ROOT, "modules/bar/gooey/GooeyField.qml")
REEL_QML = os.path.join(ROOT, "modules/bar/gooey/ReelCast.qml")


def props(reel=False):
    lines = ["        // @@PROPS-BEGIN (generated by tools/dev/gooey_field_ubo.py -- edit there)"]
    for prefix, n in (("b", BODIES), ("x", BODIES), ("y", BODIES), ("u", BODIES), ("v", BODIES),
                      ("f", FILLETS), ("k", FILLETS), ("g", FILLETS), ("s", SEAMS), ("t", ALL_TILES)):
        lines += [f"        property vector4d {name}" for name in names(prefix, n)]
    # No tint: every colour clear and no body carrying one (GooeyField._updateTints).
    lines += [f"        property real {name}: -1" for name in TINT_IDS]
    lines += [f'        property color {name}: "transparent"' for name in TINT_COLOURS]
    lines.append("        property real tintReach: 1")
    lines += [f"        property vector4d {name}" for name in AURA_VECS]
    # (THE REEL PASS binds the edge's ink to the field's own, in ReelCast.qml)
    if not reel:
        lines.append("        property real shadowTiles: 0")
        lines.append('        property color shadowColor: "transparent"')
        lines.append('        property color borderColor: "transparent"')
        lines.append("        property vector4d shadowParam")
        lines.append("        property vector4d shadowShape: Qt.vector4d(0, 1, 0, 0)")
    # The packed lanes' names, g<i>.z and g<i>.w (GooeyField._putG; ReelCast._writeG: THE REEL PASS's own, "" where it has none).
    if reel:
        lanes = [[z or "", w or ("smoothK" if i == 0 else "")] for i, (z, w) in enumerate(REEL_PACK)]
        lines.append("        readonly property var packNames: " + repr(lanes).replace("'", '"'))
        # what the pass's shader evaluates of the block (REEL_BODIES ...)
        lines.append(f"        readonly property int passBodies: {REEL_BODIES}")
        lines.append(f"        readonly property int passFillets: {REEL_FILLETS}")
        lines.append(f"        readonly property int passSeams: {REEL_SEAMS}")
    else:
        lines.append("        readonly property var packNames: " + repr([list(p) for p in PACK]).replace("'", '"'))
        lines.append("        readonly property var neckLanes: " + repr([list(p) for p in NECK]).replace("'", '"'))
    lines.append("        // @@PROPS-END")
    return "\n".join(lines)


def write_props():
    rc = 0
    for fn, reel in ((QML, False), (REEL_QML, True)):
        name = os.path.basename(fn)
        src = open(fn).read()
        new, n = re.subn(r" *// @@PROPS-BEGIN.*?// @@PROPS-END", lambda m: props(reel), src, count=1, flags=re.S)
        if n != 1:
            print(f"FAIL  {name}: no @@PROPS markers")
            rc = 1
            continue
        if new != src:
            open(fn, "w").write(new)
            print(f"ok    {name}: properties written")
        else:
            print(f"same  {name}")
    return rc


def main():
    text = block()
    rc = write_props()
    rc |= write_eval()
    rc |= write_tiles()
    for fn in FILES:
        src = open(fn).read()
        if "// @@UBO-BEGIN" in src:
            new = re.sub(r"// @@UBO-BEGIN.*?// @@UBO-END", lambda m: text, src, count=1, flags=re.S)
        elif "//@@UBO@@" in src:
            new = src.replace("//@@UBO@@", text, 1)
        else:
            new, n = re.subn(r"layout\(std140, binding = 0\) uniform buf \{.*?\n\};", lambda m: text, src, count=1, flags=re.S)
            if n != 1:
                print(f"FAIL  {os.path.basename(fn)}: no block to replace")
                rc = 1
                continue
        if new != src:
            open(fn, "w").write(new)
            print(f"ok    {os.path.basename(fn)}: block written")
        else:
            print(f"same  {os.path.basename(fn)}")
    return rc


if __name__ == "__main__":
    sys.exit(main())
