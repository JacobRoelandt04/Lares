.pragma library
.import "SiliconGpuParts.js" as P
.import "../../common/components/GlyphOutline.js" as O
.import "../../common/components/GlyphSignal.js" as S

// =============================================================================
// SiliconGpuPose.js -- the GPU mode's four glyphs as DEFORMABLE outlines (feedback/silicon.md "GPU mode icon redesign"). Pure
// functions of the flourish's clock (GlyphFlourish `t`, ms): `pose(mode, t, life, strength, look, px, ox, oy)` is
// { parts, shades } for PosedGlyph, SVG paths in px.
//
// The set is the cousin of the CPU profile's (leaf, scales, bolt), a glyph per mode that says what the MODE is, not what the
// hardware looks like, and each does what its object does:
//
//   0 Integrated  FEATHER    a gust takes it: held by the foot of its quill, the free end is blown over, bowing more the further
//                            from the foot, and shivers while the wind lasts (a wave running out along the quill); let go, it
//                            whips back past its rest and vibrates down. The foot never moves
//   1 Smart       LIGHTBULB  the idea: the glass dips on its cap, pops up past its size and rings down; three short rays grow out
//                            round it and draw back. The cap follows the glass, a little late
//   2 Hybrid      LAYERS     the stack opens: the upper slab lifts and tilts, hangs, drops, lands past its rest and springs back;
//                            the lower slab rises a hair as the weight leaves it and gives under the landing
//   3 dGPU-only   FIRE       it flares: the flame squats, licks up (its tip stretching most) and sways from its foot, the wave
//                            running up it; the tongue inside moves out of step; two embers leave the tip, rise and go out
//
// EVERY MOTION IS ZERO AT THE RUN'S FIRST INSTANT AND AT ITS LAST, and there `pose` RETURNS the font's own parts (`rest`), so the
// swap with the plain glyph (PosedGlyph) shows nothing but the motion. Nothing flashes or hides: what is thrown (rays, embers)
// grows from nothing and goes by size and by shade. What is thrown never lies over the glyph's ink (the glyph is drawn under an
// opacity while its card idles, and two parts that overlap would darken each other).
//
// `strength` scales every amplitude (1: a hover or a mode's arrival; the card waking plays a little harder). Times are ms of
// each glyph's own `life`; another life scales them. Angles are counter-clockwise in font space (y up).
// =============================================================================

const RAD = Math.PI / 180;

// the glyph of each mode, in silicon's step order
var KINDS = ["feather", "bulb", "layers", "fire"];

// The motions' numbers (exported so a probe and the mockup can read them). A caller may hand overrides: look = { fire: { swayDeg: 12 } }.
var DEFAULTS = {
    feather: {
        life: 1350,
        gustMs: 150,      // the gust arrives: how long the tip takes to be blown over
        holdMs: 330,      // how long it blows
        bendDeg: 13,      // how far the tip is turned about the foot (clockwise: the wind comes from the left)
        curve: 1.6,       // how the turn grows along the quill (1: a stiff rod on a hinge; more: the foot stiff, the tip limp)
        surge: 0.14,      // the wind is not even: the bend breathes by this share while it blows
        back: 0.6,        // let go, it whips past its rest by about this share of the bend
        ringMs: 200,      // the vibration after: its period and decay
        decayMs: 320,
        flutterDeg: 3.2,  // the shiver in the wind: the tip's turn,
        flutterMs: 82,    // its period,
        flutterWaves: 0.7,// how many of its waves lie along the quill (it runs from the foot out),
        flutterOutMs: 260 // and how long it outlives the gust
    },
    bulb: {
        life: 900,
        dipMs: 130,       // the dip
        dip: 0.09,        // how far the glass squashes (a share of its height)
        pop: 0.11,        // how far it stretches at the pop's height
        hop: 110,         // how far it leaves the cap
        ringMs: 300,      // the ring down: its period and decay
        decayMs: 170,
        baseLag: 35,      // the cap follows this late, this much of the way
        baseShare: 0.8,
        rayAt: 190,       // the rays: when they start, how long they live
        rayMs: 430,
        rayGap: 150,      // where they start, off the glass
        rayOut: 40,       // how far they travel as they live
        rayLen: 300,      // their length at its height (the one straight up ends inside the pill)
        rayW: 180         // and their width
    },
    layers: {
        life: 855,
        riseMs: 230,      // the lift
        rise: 300,
        tiltDeg: 7,       // how far the slab tilts in the air
        fallMs: 170,      // the drop
        sink: 88,         // how far past its rest it lands (at this the drop's speed runs straight into the spring's)
        ringMs: 240,
        decayMs: 130,
        lowerUp: 40,      // the lower slab: up as the weight leaves, and under the landing this much of the upper's way, late
        lowerShare: 0.75,
        lowerLag: 30
    },
    fire: {
        life: 990,
        gatherMs: 140,    // the squat
        squat: 0.07,
        stretch: 0.13,    // how far the tip is drawn up at the lick's height (the foot not at all)
        ringMs: 380,
        decayMs: 210,
        swayDeg: 9,       // the tip's sway about the foot
        cycles: 2.25,
        damp: 1.6,
        lag: 0.16,        // how late the tip is (a share of a cycle): the wave runs up the flame
        tonguePhase: 0.9, // the tongue inside: this far out of step (radians), drawn up this much more
        tongueStretch: 1.3,
        emberGap: 110,    // the embers: how far over the tip they are born,
        aAt: 330,         // and each one's start, life, drift, rise and size
        aMs: 520,
        aDx: 150,
        aDy: 430,
        aR: 92,
        bAt: 450,
        bMs: 460,
        bDx: -170,
        bDy: 330,
        bR: 70
    }
};

// what the pose turns and scales about (SiliconGpuParts.js; tools/dev/flourish_parts.py holds the font to these)
var FEATHER = { cx: 852, cy: 614, half: 1205, fx: 0, fy: -238 };   // the box's middle; half the quill, corner to corner; its foot
var BULB = { cx: 596, foot: 102, cy: 870, r: 596 };       // the glass stands on y = foot; its round top about (cx, cy)
var LAYERS = { cx: 768, cy: 830 };                        // the upper slab's middle
var FIRE = { bx: 606, by: -166, h: 1548, tipX: 766, tipY: 1382 };

function kindOf(mode) {
    return KINDS[mode] || KINDS[2];
}

// how long mode's flourish runs, in times the flourish's `ms` (900: the bulb's own)
function time(mode) {
    return DEFAULTS[kindOf(mode)].life / 900;
}

function _look(kind, look) {
    const d = DEFAULTS[kind], o = look && look[kind], l = {};
    for (const k in d)
        l[k] = o && o[k] !== undefined ? Number(o[k]) : d[k];
    return l;
}

// pressed down and let go: 0 -> -1 over `pressMs`, then up past rest (about +1) and ringing down to 0 by `life`
function press(x, pressMs, life, ringMs, decayMs) {
    if (x <= 0 || x >= life)
        return 0;
    return x < pressMs ? -O.inOutQuad(x / pressMs) : S.sprung(x - pressMs, life - pressMs, -1, 1, ringMs, decayMs);
}

// ---- what a run is doing at x (ms on the glyph's own clock), as numbers: a probe reads them, `pose` draws them ----

// bend: the tip's turn about the foot (radians, counter-clockwise); flutter: the shiver's size at the tip (radians) and its
// phase at the foot (radians)
function featherState(x, l, f) {
    const rel = l.gustMs + l.holdMs;
    let e;
    if (x < l.gustMs)
        e = O.inOutQuad(x / l.gustMs);
    else if (x < rel)
        e = 1 - l.surge * Math.sin(Math.PI * (x - l.gustMs) / l.holdMs);
    else
        e = -S.sprung(x - rel, l.life - rel, -1, l.back, l.ringMs, l.decayMs);
    return {
        bend: -f * l.bendDeg * RAD * e,
        flutter: f * l.flutterDeg * RAD * O.smooth(0, l.gustMs, x) * (1 - O.smooth(rel, rel + l.flutterOutMs, x)),
        phase: 2 * Math.PI * x / l.flutterMs
    };
}

// sy, sx: the glass's scale about its foot; hop, baseHop (font units); ray: null or { r0, len, w, shade }
function bulbState(x, l, f) {
    const e = press(x, l.dipMs, l.life, l.ringMs, l.decayMs);
    const eb = press(x - l.baseLag, l.dipMs, l.life - l.baseLag, l.ringMs, l.decayMs);
    const sy = 1 + f * (e < 0 ? l.dip : l.pop) * e;
    const st = { sy: sy, sx: 1 - 0.5 * (sy - 1), hop: f * l.hop * Math.max(0, e), baseHop: f * l.hop * l.baseShare * Math.max(0, eb), ray: null };
    const r = (x - l.rayAt) / l.rayMs;
    if (r > 0 && r < 1) {
        const grow = O.outCubic(r / 0.35) * (1 - O.inQuad(O.seg(r, 0.5, 1)));
        st.ray = { r0: l.rayGap + l.rayOut * O.outCubic(r), len: f * l.rayLen * grow, w: l.rayW * Math.min(1, 2 * grow), shade: 1 - O.inQuad(O.seg(r, 0.75, 1)) };
    }
    return st;
}

// top, low: the slabs' way up (font units); tilt (radians)
function layersState(x, l, f) {
    const land = l.riseMs + l.fallMs;
    if (x < land) {
        const air = Math.sin(Math.PI * x / land);
        return {
            top: f * l.rise * (x < l.riseMs ? O.outCubic(x / l.riseMs) : 1 - O.inQuad((x - l.riseMs) / l.fallMs)),
            tilt: f * l.tiltDeg * RAD * air,
            low: f * l.lowerUp * air
        };
    }
    return {
        top: -f * l.sink * S.thump(x - land, l.life - land, l.ringMs, l.decayMs),
        tilt: 0,
        low: -f * l.sink * l.lowerShare * S.thump(x - land - l.lowerLag, l.life - land - l.lowerLag, l.ringMs, l.decayMs)
    };
}

// e: the press (-1 squat .. about +1 the lick's height); env, v: the sway's size and clock
function fireState(x, l) {
    const v = O.seg(x, l.gatherMs, l.life);
    return { e: press(x, l.gatherMs, l.life, l.ringMs, l.decayMs), v: v, env: O.smooth(0, 0.1, v) * Math.pow(1 - v, l.damp) };
}

// ---- the maps: [x, y] -> [x, y] in font units ----

// Every point is turned about the quill's foot, by more the further along the quill it is: the foot stands, the tip goes furthest.
function _featherMap(st, l) {
    const c = FEATHER;
    return function (x, y) {
        // 0 at the quill's foot .. 1 at the tip, along the quill (it runs up the box's diagonal)
        const u = O.clamp01(0.5 + 0.5 * ((x - c.cx) + (y - c.cy)) * Math.SQRT1_2 / c.half);
        const w = Math.pow(u, l.curve);
        return O.turn(x, y, c.fx, c.fy, w * (st.bend + st.flutter * Math.sin(st.phase - 2 * Math.PI * l.flutterWaves * u)));
    };
}

function _glassMap(st) {
    return function (x, y) {
        return [BULB.cx + (x - BULB.cx) * st.sx, BULB.foot + (y - BULB.foot) * st.sy + st.hop];
    };
}

// The flame's map: drawn up from its foot (the tip most: `sk` times the stretch), narrower as it is taller, then turned about
// the foot by a sway that grows toward the tip and arrives late there; `phase` puts the tongue out of step.
function _fireMap(st, l, f, phase, sk) {
    const c = FIRE;
    return function (x, y) {
        const s = O.clamp01((y - c.by) / c.h);
        const fy = 1 + f * (st.e < 0 ? l.squat * st.e : l.stretch * sk * st.e * s);
        const fx = 1 - 0.4 * (fy - 1);
        const a = f * l.swayDeg * RAD * Math.pow(s, 1.5) * st.env * Math.sin(2 * Math.PI * l.cycles * (st.v - l.lag * s) + phase);
        return O.turn(c.bx + (x - c.bx) * fx, c.by + (y - c.by) * fy, c.bx, c.by, a);
    };
}

function _poly(pts, k, ox, oy) {
    return O.emit([O.polygon(pts)], O.same, k, ox, oy);
}

// a ray: a dart from r0 out by `len` along `deg` about (cx, cy), `w` wide a little behind its head, pointed at both ends
function _ray(cx, cy, deg, r0, len, w) {
    const a = deg * RAD, c = Math.cos(a), s = Math.sin(a), m = r0 + 0.6 * len, h = 0.5 * w;
    return [[cx + r0 * c, cy + r0 * s], [cx + m * c - h * s, cy + m * s + h * c],
            [cx + (r0 + len) * c, cy + (r0 + len) * s], [cx + m * c + h * s, cy + m * s - h * c]];
}

function _disc(cx, cy, r) {
    const pts = [];
    for (let i = 0; i < 10; ++i)
        pts.push([cx + r * Math.cos(-i * Math.PI / 5), cy + r * Math.sin(-i * Math.PI / 5)]);
    return pts;
}

// An ember at run time x: born `emberGap` over where the tip stood when it left, it drifts and rises (fast, then slowing),
// swells in its first sixth and shrinks away. null while there is none; else { x, y, r, shade }.
function ember(x, l, f, at, ms, dx, dy, r) {
    const a = (x - at) / ms;
    if (a <= 0 || a >= 1)
        return null;
    const tip = _fireMap(fireState(at, l), l, f, 0, 1)(FIRE.tipX, FIRE.tipY);
    return {
        x: tip[0] + f * dx * O.outQuad(a) + 30 * Math.sin(2.4 * Math.PI * a),
        y: tip[1] + l.emberGap + f * dy * O.outCubic(a),
        r: r * Math.min(1, a * 6) * (1 - O.inQuad(a)),
        shade: 1 - O.inCubic(a)
    };
}

// ---- the parts ----

// the font's own outline: what the run's first and last instants are
function rest(mode, px, ox, oy) {
    const k = px / P.UNITS, kind = kindOf(mode);
    const e = function (cs) { return O.emit(cs, O.same, k, ox, oy); };
    if (kind === "feather")
        return { parts: [e(P.feather)], shades: [] };
    if (kind === "bulb")
        return { parts: [e(P.bulbGlass), e(P.bulbBase)], shades: [] };
    if (kind === "layers")
        return { parts: [e(P.layersTop), e(P.layersLower)], shades: [] };
    return { parts: [e(P.fireFlame) + e(P.fireTongue)], shades: [] };
}

// { parts, shades } of mode's glyph at run time t of `life`
function pose(mode, t, life, strength, look, px, ox, oy) {
    if (!(t > 0) || t >= life)
        return rest(mode, px, ox, oy);
    const kind = kindOf(mode), l = _look(kind, look);
    const x = t * l.life / Math.max(1, life);
    const k = px / P.UNITS, f = strength === undefined ? 1 : strength;
    if (kind === "feather")
        return { parts: [O.emit(P.feather, _featherMap(featherState(x, l, f), l), k, ox, oy)], shades: [] };
    if (kind === "bulb") {
        const st = bulbState(x, l, f), glass = _glassMap(st);
        let rays = "";
        if (st.ray && st.ray.len > 8) {
            const c = glass(BULB.cx, BULB.cy), r0 = BULB.r + st.ray.r0;
            rays = _poly(_ray(c[0], c[1], 90, r0, st.ray.len, st.ray.w), k, ox, oy)
                + _poly(_ray(c[0], c[1], 38, r0, st.ray.len, st.ray.w), k, ox, oy)
                + _poly(_ray(c[0], c[1], 142, r0, st.ray.len, st.ray.w), k, ox, oy);
        }
        return {
            parts: [O.emit(P.bulbGlass, glass, k, ox, oy), O.emit(P.bulbBase, function (bx, by) { return [bx, by + st.baseHop]; }, k, ox, oy), rays],
            shades: [1, 1, st.ray ? st.ray.shade : 0]
        };
    }
    if (kind === "layers") {
        const st = layersState(x, l, f);
        return {
            parts: [O.emit(P.layersTop, function (sx, sy) {
                        const r = O.turn(sx, sy, LAYERS.cx, LAYERS.cy, st.tilt);
                        return [r[0], r[1] + st.top];
                    }, k, ox, oy),
                    O.emit(P.layersLower, function (sx, sy) { return [sx, sy + st.low]; }, k, ox, oy)],
            shades: []
        };
    }
    const st = fireState(x, l);
    const a = ember(x, l, f, l.aAt, l.aMs, l.aDx, l.aDy, l.aR), b = ember(x, l, f, l.bAt, l.bMs, l.bDx, l.bDy, l.bR);
    return {
        parts: [O.emit(P.fireFlame, _fireMap(st, l, f, 0, 1), k, ox, oy) + O.emit(P.fireTongue, _fireMap(st, l, f, l.tonguePhase, l.tongueStretch), k, ox, oy),
                a && a.r > 4 ? _poly(_disc(a.x, a.y, a.r), k, ox, oy) : "",
                b && b.r > 4 ? _poly(_disc(b.x, b.y, b.r), k, ox, oy) : ""],
        shades: [1, a ? a.shade : 0, b ? b.shade : 0]
    };
}
