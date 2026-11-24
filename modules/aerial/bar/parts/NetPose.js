.pragma library
.import "../../../common/components/GlyphOutline.js" as O
.import "../../../common/components/GlyphSignal.js" as S
.import "NetParts.js" as P

// =============================================================================
// NetPose.js -- the networking pill's flourishes (feedback/general.md "Last flourishes"): each GIVES ITS SIGNAL ONCE, the
// family of GlyphSignal.js. Pure functions of the flourish's clock: `pose(text, t, life, live, look, px, ox, oy)` is the glyph
// `text` posed at t ms -- { parts: SVG paths (PosedGlyph's parts), shades: each part's share of the ink } -- and `path(...)`
// its parts alone; no parts for a glyph with no outline here. `life(text, live)` is how long that glyph's play runs (the
// host's GlyphFlourish.ms).
//
//   fan     the Wi-Fi fan PINGS: it kicks out from its tip (the whole fan, its fill with it: the level it shows is the same
//           share of the fan in every frame) and throws one arc off its rim, which rises and thins to nothing. The arc is
//           OUTSIDE the fan, so it is never a bar. With the radio off the fan kicks smaller and nothing is thrown. An alert's
//           "!" rides the fan and hops as the kick reaches it.
//   lan     the wire PASSES DATA: the upper box pops as it sends, and the wire THICKENS LOCALLY -- a bulge that runs down it
//           and round its corner to the lower box, three in a row -- and the lower box pops as each arrives. With no link
//           the upper box pops once, one bulge sets off and dies in the wire, and nothing arrives.
//   plane   a CARTOON TAKE-OFF RUN: it pulls back and bunches up (shorter, fatter), then shoots forward stretched long and
//           thin with its nose up, WIND streaming off behind its tail, bobs about and springs back into shape. The plane IS
//           airplane mode, so it always goes whole.
//   rune    Bluetooth's rune is ONE LINE bent round four sharp corners (the upper left arm down through the middle, round
//           the lower right, up the spine, round the upper right, down through the middle to the lower left), and that line
//           is PULLED ROUND: its upper-left end runs off along the line, so the rune EMPTIES in the order it is drawn, and
//           the line comes in again behind it and FILLS it the same way. The ends are cut square; no corner is ever
//           rounded. A connected rune's two dots stay where they are (they are the state) and pop once as the line lands.
//           Switched off it plays the SAME (feedback/general.md "Last flourishes", the second review): the rune is one shape
//           on or off, and its ink -- the on hue or the muted one -- is what says which.
//
// `live` is the half being ON. Every motion is zero at t = 0 and at t = life: there the pose IS the font's outline (`_rest`,
// the parts as checked in), to the digit. The rune and the wire are REBUILT while they move (the rune as the five straight
// pieces of its line, the wire as a band about its middle line): tools/dev/flourish_parts.py holds the font to the numbers
// they are built on.
// =============================================================================

var DEFAULTS = {
    // ---- the fan ----
    kick: 0.11,           // the fan's growth from its tip at the kick's peak
    kickPeriodMs: 260,
    kickDecayMs: 140,
    arcLagMs: 70,
    arcMs: 360,           // the thrown arc's flight
    arcFrom: 250,         // font units above the rim where its middle starts: clear of the fan at its kick's peak
    arcTravel: 340,
    arcWidth: 150,        // its thickness at its thickest (the fan's own rim is 172)
    arcHalfDeg: 33,       // the fan's own half angle is 38.7
    bangHop: 130,         // the "!"'s hop, font units
    bangLagMs: 110,
    bangMs: 170,
    off: 0.6,             // an off half's share of the kick
    // ---- the wire ----
    pop: 0.2,             // a box's growth as it sends or takes
    popHop: 50,
    popMs: 190,
    popAgain: 0.5,        // the later pops' share of the first
    pulses: 3,            // the bulges down the wire
    pulseGapMs: 130,
    pulseLagMs: 60,       // the first sets off this long after the upper box starts its pop
    pulseMs: 250,         // one bulge's run from above the wire's top to past its end
    pulseAmp: 0.85,       // how much thicker the wire is at a bulge's middle (a share of its own thickness)
    pulseHalf: 125,       // the bulge's half length, font units
    // ---- the plane ----
    windMs: 250,          // the pull back before the run
    back: 110,            // ... how far, font units
    bunch: 0.13,          // ... and how much shorter the plane is at its peak
    launchMs: 140,        // when the run starts
    dart: 230,            // how far it shoots forward
    stretch: 0.2,         // ... and how much longer it is then
    dartPeriodMs: 430,
    dartDecayMs: 170,
    thin: 0.55,           // how much of a stretch along comes off across (so it keeps its bulk)
    pitchDeg: 5,          // nose up as it goes
    bob: 50,              // it moves about: up and down this far ...
    bobPeriodMs: 210,
    streakMs: 300,        // one streak of wind
    streakLagMs: 55,      // each this long after the one before
    streakDrift: 110,     // how far it falls behind
    streakWidth: 150,
    // ---- the rune ----
    runeGap: 0.82,        // the room between the line running off and the line coming in, as a share of the line's length
    dotPop: 0.24          // the connected dots' growth as the line lands
};
// the fan's rim is an arc about its tip (the tip's y; its x is the fan's middle: the alerts' fans stand 4 units left)
var TIP_Y = -176;
var RIM = 1584;
// the plane's heading runs along y = 614; what it is stretched about stands three fifths along it from its tail
var AXIS_Y = 614;
var PLANE_MID = 1300;
// the wind's three streaks: how far over the heading each runs, where its head starts (the tail is at the pen: the outer
// two start beside the tail, behind the wings, the middle one behind it) and how long it gets
var STREAKS = [[610, 500, 940], [0, -50, 480], [-610, 420, 820]];
// the wire is a band 172 thick about an L: down x = 258 from y = 530 to the corner at y = 16, then right to x = 768
var WIRE = { x: 258, top: 530, y: 16, end: 768, h: 86 };

// one play's length, ms (the host's GlyphFlourish.ms): by what the glyph does
function life(text, live) {
    const g = P.G[S.key(text)];
    if (!g || g.kind === "fan")
        return 600;
    if (g.kind === "lan")
        return live ? 760 : 520;
    // the plane, and the rune (the same play on or off)
    return 780;
}

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}

function has(text) {
    return P.G[S.key(text)] !== undefined;
}

// the fan's tip in a glyph (the lowest point of its first contour)
function _tip(g) {
    const c = g.parts[0][0];
    for (let i = 0; i < c.length; ++i) {
        const n = c[i].length;
        if (c[i][n - 1] === TIP_Y)
            return [c[i][n - 2], TIP_Y];
    }
    return [(g.box[0] + g.box[2]) / 2, TIP_Y];
}

// the thrown arc's flight share at t
function arcShare(t, look) {
    const l = _look(look);
    return O.clamp01((t - l.arcLagMs) / l.arcMs);
}

function _fan(g, t, life, live, l, k, ox, oy) {
    const a = live ? 1 : l.off;
    const tip = _tip(g);
    const s = 1 + a * l.kick * S.thump(t, life, l.kickPeriodMs, l.kickDecayMs);
    const grow = S.scaled(tip[0], tip[1], s, s);
    const out = [O.emit(g.parts[0], grow, k, ox, oy)];
    if (g.parts.length > 1) {
        const hop = a * l.bangHop * S.bump((t - l.bangLagMs) / l.bangMs);
        out.push(O.emit(g.parts[1], function (x, y) {
            const q = grow(x, y);
            return [q[0], q[1] + hop];
        }, k, ox, oy));
    }
    if (live) {
        const w = S.wave(arcShare(t, l), tip[0], tip[1], Math.PI / 2, RIM + l.arcFrom, l.arcTravel, l.arcHalfDeg * Math.PI / 180, l.arcWidth);
        if (w)
            out.push(O.emit([w], O.same, k, ox, oy));
    }
    return out;
}

// the ink box of one part
function _box(part) {
    let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
    for (let i = 0; i < part.length; ++i)
        for (let j = 0; j < part[i].length; ++j) {
            const sg = part[i][j], n = sg.length;
            x0 = Math.min(x0, sg[n - 2]);
            x1 = Math.max(x1, sg[n - 2]);
            y0 = Math.min(y0, sg[n - 1]);
            y1 = Math.max(y1, sg[n - 1]);
        }
    return [x0, y0, x1, y1];
}

// ---- the wire ----------------------------------------------------------------------------------------------------------
// when bulge `i` sets off, and when its middle reaches the wire's end (the lower box takes it)
function pulseStart(i, look) {
    const l = _look(look);
    return l.pulseLagMs + l.pulseGapMs * i;
}
function pulseLands(i, look) {
    const l = _look(look);
    const len = WIRE.top - WIRE.y + WIRE.end - WIRE.x, run = len + 6 * l.pulseHalf;
    return pulseStart(i, l) + l.pulseMs * (len + 3 * l.pulseHalf) / run;
}
// The wire's half thickness at `s` along its middle line (0 at its top) at t: 86, and more where a bulge is. A bulge comes in
// from above the top and leaves past the end, so the wire is plain at both ends of every run; with no link the one bulge
// loses its size on the way and is gone before the corner.
function wireHalf(s, t, live, look) {
    const l = _look(look);
    const len = WIRE.top - WIRE.y + WIRE.end - WIRE.x, run = len + 6 * l.pulseHalf;
    let a = 0;
    for (let i = 0; i < (live ? l.pulses : 1); ++i) {
        const x = (t - pulseStart(i, l)) / l.pulseMs;
        if (x <= 0 || x >= 1)
            continue;
        a += (live ? 1 : 1 - O.smooth(0.12, 0.34, x)) * S.lump((s - (-3 * l.pulseHalf + run * x)) / l.pulseHalf);
    }
    return WIRE.h * (1 + l.pulseAmp * a);
}
// the wire as one contour about its middle line, wound like the font's (down its outer side, back up its inner)
function _wire(t, live, l) {
    const lenV = WIRE.top - WIRE.y, len = lenV + WIRE.end - WIRE.x, step = 32;
    const h = s => wireHalf(s, t, live, l);
    const hc = h(lenV), outer = [], inner = [];
    for (let s = 0; s < lenV; s += step)
        outer.push([WIRE.x - h(s), WIRE.top - s]);
    outer.push([WIRE.x - hc, WIRE.y - hc]);
    for (let s = lenV + step; s < len; s += step)
        outer.push([WIRE.x + s - lenV, WIRE.y - h(s)]);
    outer.push([WIRE.end, WIRE.y - h(len)]);
    inner.push([WIRE.end, WIRE.y + h(len)]);
    for (let s = len - step; s > lenV + hc; s -= step)
        inner.push([WIRE.x + s - lenV, WIRE.y + h(s)]);
    inner.push([WIRE.x + hc, WIRE.y + hc]);
    for (let s = lenV - hc - 1; s > 0; s -= step)
        inner.push([WIRE.x + h(s), WIRE.top - s]);
    inner.push([WIRE.x + h(0), WIRE.top]);
    return O.polygon(outer.concat(inner));
}

function _lan(g, t, life, live, l, k, ox, oy) {
    // the upper box pops as each bulge sets off, the lower as each lands (the first whole, the rest smaller)
    let up = 0, down = 0;
    for (let i = 0; i < (live ? l.pulses : 1); ++i) {
        const a = i === 0 ? 1 : l.popAgain;
        up = Math.max(up, a * S.bump((t - l.pulseGapMs * i) / l.popMs));
        if (live)
            down = Math.max(down, a * S.bump((t - pulseLands(i, l)) / l.popMs));
    }
    const box = (part, p) => {
        const b = _box(part);
        const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
        const s = 1 + l.pop * p, dy = l.popHop * p;
        return O.emit(part, function (x, y) {
            return [cx + (x - cx) * s, cy + (y - cy) * s + dy];
        }, k, ox, oy);
    };
    return { parts: [box(g.parts[0], up), O.emit([_wire(t, live, l)], O.same, k, ox, oy), box(g.parts[2], down)], shades: [] };
}

// ---- the plane ---------------------------------------------------------------------------------------------------------
// how far the plane has shot forward at t, as a share of `dart` (the kick of its run: out, back past rest, still by `life`)
function dash(t, life, look) {
    const l = _look(look);
    return S.thump(t - l.launchMs, life - l.launchMs, l.dartPeriodMs, l.dartDecayMs);
}
// streak `i`'s flight share at t
function streakShare(t, i, look) {
    const l = _look(look);
    return O.clamp01((t - l.launchMs - 30 - l.streakLagMs * i) / l.streakMs);
}

function _plane(g, t, life, l, k, ox, oy) {
    const pull = S.bump(t / l.windMs), go = dash(t, life, l);
    const sx = 1 - l.bunch * pull + l.stretch * go;
    const sy = 1 - l.thin * (sx - 1);
    const dx = -l.back * pull + l.dart * go;
    const run = O.clamp01((t - l.launchMs) / (life - l.launchMs));
    const dy = l.bob * Math.sin(2 * Math.PI * (t - l.launchMs) / l.bobPeriodMs) * S.bump(run);
    const th = l.pitchDeg * Math.PI / 180 * go;
    const out = [O.emit(g.parts[0], function (x, y) {
        const q = O.turn(PLANE_MID + (x - PLANE_MID) * sx, AXIS_Y + (y - AXIS_Y) * sy, PLANE_MID, AXIS_Y, th);
        return [q[0] + dx, q[1] + dy];
    }, k, ox, oy)];
    // the wind: behind the tail (the tail is at the pen), each streak drawn out fast, falling behind and thinning to nothing
    const wind = [];
    for (let i = 0; i < STREAKS.length; ++i) {
        const x = streakShare(t, i, l);
        if (x <= 0 || x >= 1)
            continue;
        const head = STREAKS[i][1] - l.streakDrift * O.outCubic(x);
        const c = S.streak(head, head - STREAKS[i][2] * Math.min(1, x * 4) * (1 - 0.5 * x), AXIS_Y + STREAKS[i][0],
                           l.streakWidth * Math.min(1, x * 5) * (1 - x * x));
        if (c)
            wind.push(c);
    }
    if (wind.length > 0)
        out.push(O.emit(wind, O.same, k, ox, oy));
    return { parts: out, shades: [] };
}

// ---- the rune ----------------------------------------------------------------------------------------------------------
// The rune as its line's five straight pieces, in the order the line is drawn (font units of md-bluetooth; the rune of
// md-bluetooth_connect stands 172 right of it). Each is the font's own ink along one stretch of the line, corner to corner
// with both corners WHOLE (so two pieces overlap in every corner and the five together are the glyph); `at` is a point of
// the piece's middle line and `dir` its heading.
//
// THE LINE'S MEASURE runs through each piece from its first ink to its last along its own heading (`s0`, `len`: worked out
// below), one piece after the other. A cut at `s` is in ONE piece, square across that piece's heading; the pieces before it
// are whole on one side of the cut and gone on the other. Because a piece's corner lies inside its neighbour, the cut that
// leaves a piece at its far end and the cut that enters the next at its near end show the same picture: nothing jumps at a
// corner, no cut is ever anything but one straight edge, and no corner is ever rounded.
var R2 = Math.SQRT1_2;
var RUNE = [
    { pts: [[0, 1090], [964, 126], [1084, 246], [120, 1210]], at: [60, 1150], dir: [R2, -R2] },
    { pts: [[962, 368], [512, -82], [512, -238], [596, -238], [1084, 246]], at: [962, 246], dir: [-R2, -R2] },
    { pts: [[512, -238], [596, -238], [680, -155], [680, 1383], [596, 1466], [512, 1466]], at: [596, -120], dir: [0, 1] },
    { pts: [[1084, 982], [596, 1466], [512, 1466], [512, 1310], [962, 860]], at: [596, 1348], dir: [R2, -R2] },
    { pts: [[0, 138], [120, 18], [1084, 982], [964, 1102]], at: [962, 982], dir: [-R2, -R2] }
];
// the line's whole measure
var RUNE_LEN = (function () {
    let s = 0;
    for (let i = 0; i < RUNE.length; ++i) {
        const p = RUNE[i];
        let lo = 1e9, hi = -1e9;
        for (let j = 0; j < p.pts.length; ++j) {
            const d = (p.pts[j][0] - p.at[0]) * p.dir[0] + (p.pts[j][1] - p.at[1]) * p.dir[1];
            lo = Math.min(lo, d);
            hi = Math.max(hi, d);
        }
        // `at` moved to the piece's first ink, so a cut `x` into the piece is at at + dir x
        p.at = [p.at[0] + p.dir[0] * lo, p.at[1] + p.dir[1] * lo];
        p.s0 = s;
        p.len = hi - lo;
        s += p.len;
    }
    return s;
})();
// which path each piece is drawn in: the three that cross in the middle each alone, the two bows (which touch nothing of each
// other) together -- four paths (PosedGlyph), none with touching contours
var RUNE_PATH = [0, 3, 1, 3, 2];

// The part of a convex polygon where (p - c) . d >= 0 (`keep` 1) or <= 0 (`keep` -1); [] when nothing is left.
function _cut(pts, cx, cy, dx, dy, keep) {
    const out = [];
    for (let i = 0; i < pts.length; ++i) {
        const a = pts[i], b = pts[(i + 1) % pts.length];
        const da = keep * ((a[0] - cx) * dx + (a[1] - cy) * dy), db = keep * ((b[0] - cx) * dx + (b[1] - cy) * dy);
        if (da >= 0)
            out.push(a);
        if ((da >= 0) !== (db >= 0)) {
            const f = da / (da - db);
            out.push([a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f]);
        }
    }
    return out.length >= 3 ? out : [];
}

// Where the line's two ends are at t, along its measure: [a, b]. The line that runs off is what lies past `a`; the line coming
// in is what lies before `b` (b < a: the room between them).
function runeEnds(t, life, look) {
    const l = _look(look);
    const u = O.clamp01(t / life);
    const gap = l.runeGap * RUNE_LEN;
    const a = (RUNE_LEN + gap) * O.inOutQuad(u);
    return [a, a - gap];
}

// the rune's ink past `a` and before `b`, as the contours of each of the four paths (font units, `shift` right)
function _runeCut(a, b, shift) {
    const paths = [[], [], [], []];
    for (let i = 0; i < RUNE.length; ++i) {
        const p = RUNE[i];
        const put = pts => {
            if (pts.length > 0)
                paths[RUNE_PATH[i]].push(O.polygon(pts.map(q => [q[0] + shift, q[1]])));
        };
        const cut = (s, keep) => _cut(p.pts, p.at[0] + p.dir[0] * (s - p.s0), p.at[1] + p.dir[1] * (s - p.s0), p.dir[0], p.dir[1], keep);
        // what is left of the line running off: this piece whole while the end is before it, nothing once it is past it
        if (a < p.s0 + p.len)
            put(a <= p.s0 ? p.pts : cut(a, 1));
        // ... and of the line coming in
        if (b > p.s0)
            put(b >= p.s0 + p.len ? p.pts : cut(b, -1));
    }
    return paths;
}

function _rune(g, t, life, l, k, ox, oy) {
    // where this glyph's rune stands: its outline is the last contour, its left end at the pen in md-bluetooth
    const shift = _box([g.parts[0][g.parts[0].length - 1]])[0];
    const e = runeEnds(t, life, l);
    const paths = _runeCut(e[0], e[1], shift);
    if (g.parts.length > 1) {
        // the dots: where they are, popped once as the line lands
        const s = 1 + l.dotPop * S.bump(O.seg(t / life, 0.7, 1));
        for (let i = 0; i < g.parts[1].length; ++i) {
            const b = _box([g.parts[1][i]]);
            const cx = (b[0] + b[2]) / 2, cy = (b[1] + b[3]) / 2;
            paths[3].push(g.parts[1][i].map(sg => [sg[0], cx + (sg[1] - cx) * s, cy + (sg[2] - cy) * s]));
        }
    }
    return { parts: paths.map(cs => O.emit(cs, O.same, k, ox, oy)), shades: [] };
}

// the font's outline, untouched: what every pose is at its first and last instant
function _rest(g, k, ox, oy) {
    return { parts: g.parts.map(p => O.emit(p, O.same, k, ox, oy)), shades: [] };
}

function pose(text, t, life, live, look, px, ox, oy) {
    const g = P.G[S.key(text)];
    if (!g)
        return { parts: [], shades: [] };
    const l = _look(look);
    const k = px / P.UNITS;
    if (t <= 0 || t >= life)
        return _rest(g, k, ox, oy);
    if (g.kind === "fan")
        return { parts: _fan(g, t, life, live, l, k, ox, oy), shades: [] };
    if (g.kind === "lan")
        return _lan(g, t, life, live, l, k, ox, oy);
    if (g.kind === "plane")
        return _plane(g, t, life, l, k, ox, oy);
    return _rune(g, t, life, l, k, ox, oy);
}

function path(text, t, life, live, look, px, ox, oy) {
    return pose(text, t, life, live, look, px, ox, oy).parts;
}
