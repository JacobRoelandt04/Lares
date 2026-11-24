.pragma library
.import "SiliconGlyphParts.js" as P
.import "../../common/components/GlyphOutline.js" as O

// =============================================================================
// SiliconGlyphPose.js -- the bar icon's three glyphs as DEFORMABLE outlines. Pure functions of the flourish's
// one clock: `path(kind, u, strength, px, ox, oy)` is the list of SVG paths, one per part (px units, y down), of the glyph at flourish progress u.
//
//   leaf    ONE outline, bent: every point turns about the stem's foot by an angle that grows toward the tip (s^1.5, s = how
//           far along the blade it stands) and arrives late with s (a wave running up the blade), so the blade bends and
//           the foot stays put. A turn keeps every distance to the foot: the leaf does not shrink as it bends.
//   scales  FIVE parts: the base (post, foot, flares) never moves; the beam tips about the pivot; each pan is carried by the
//           beam's end (its string's apex) and swings about that apex at a share of the beam's angle, a little late -- it hangs.
//           The pans' ears slot into the bar and the base's filler lies in it, so no gap opens at a joint while it tips.
//           The fifth is A WEIGHT, the reason the scales tip (feedback/silicon.md "Flourish adjusments": "one object get
//           launched from one scale to the other"): it swells in the left pan, which sinks under it; that pan flicks it up
//           and over the pivot on one parabola; it lands in the right pan, which drops hard with one overshoot and STANDS
//           tipped; then the weight melts into the bowl and the beam comes back level. Nothing of it is there at either end.
//   bolt    THE CHARGE RUNS THROUGH (the same feedback: "a similar effect as bluetooth ... flow out downwards to come back
//           from above with might and power"): the bolt's ink runs off downward and out through the lower tip; a new
//           charge comes in at the upper tip behind it, gathering speed, and lands; the landing swells the whole bolt once
//           and bobs it down, a spring that is spent by the end.
//           AN END IS ALWAYS A POINT (the review: "the ends of the shape always being a point ... the line dynamically thins
//           out the closer it gets", as the weather's graph lines do at their box's edge): the bolt is a stroke about a
//           SPINE that zigzags as it does (upper tip, the upper wedge's middle, the lower wedge's middle, lower tip), as wide
//           at each height as the outline is there. Over the last `taper` before an end the stroke narrows toward the spine
//           to nothing -- the running-off ink's tail and the charge's head alike -- so an end is a point ON the spine that
//           slides down it, never a cut. Every level of the outline is one stretch, so a stream is ONE polygon.
//
// EVERY MOTION IS ZERO AT u = 0 AND AT u = 1, and there the pose is the font's own outline: the swap with the plain glyph
// (SiliconBarGlyph) is seamless. Angles are counter-clockwise in font space (y up): a positive beam angle is the LEFT pan down.
// =============================================================================

const RAD = Math.PI / 180;

// ramp in over the first 12 %, out linearly by 1: the ends are rest
function env(u, decay) {
    return O.smooth(0, 0.12, u) * (1 - u) * Math.exp(-decay * u);
}

// ---- the motions (exported so a probe can read the numbers) ----
// SPEED: the leaf gently waves in the wind; the scales are heavy, so their story takes its time; the bolt is quick and hits hard.
// `time` is how many times the flourish's `ms` the glyph's clock runs. The leaf sways 1.7x as long over a few wide swings.
// SCALES, shares of its clock: the weight swells by `load` (the beam `sink` degrees left-down), the flick ends at `flick`
// (`kick` degrees left-up) and lets the weight go at `go`; it lands at `land` and the beam drops to `tip` degrees right-down
// on a spring (first peak `peak` after the landing, overshooting by `over`); the weight melts from `melt0` to `melt1` and the
// beam comes back from `back` on. The pans swing `hang` of the beam's angle, `late` behind it.
// BOLT: every end narrows to a point over `taper` font units of height; the ink's end runs the bolt's height by `drainEnd` (gathering: InQuad), the charge's head from `strike0` to `hit` (InCubic:
// it lands at its fastest); the ink is `thin` narrower and `sag` font units lower as the last of it leaves; the charge comes
// in `drop` units high and lands `fat` wider and `bob` units low; swell and bob ring `cycles` times, damped by `decay`.
const LEAF = { amp: 15, cycles: 1.5, decay: 2.2, lag: 0.22, bx: 240, by: -100, tx: 1704, ty: 1424, time: 1.7 };
var SCALES = { time: 2.0, px: 862, py: 1168, a0x: 308, a1x: 1416, ay: 1084, hang: 0.3, late: 0.05,
                 load: 0.13, sink: 6, flick: 0.21, kick: 7, go: 0.185, land: 0.46, tip: 14, peak: 0.085, over: 0.22,
                 melt0: 0.70, melt1: 0.80, back: 0.74, backOver: 1.2,
                 r: 140, seat: 484, apex: 1790 };
var BOLT = { time: 1.25, cx: 512, cy: 614, taper: 560, top: 1554, foot: -326, drainEnd: 0.40, strike0: 0.25, hit: 0.56,
               thin: 0.22, fat: 0.2, sag: 40, drop: 70, bob: 100, cycles: 2, decay: 3.2 };

// how long glyph `kind`'s flourish runs, in times the flourish's `ms`
function time(kind) {
    return kind === 0 ? LEAF.time : (kind === 1 ? SCALES.time : BOLT.time);
}

function leafAngle(s, u, strength) {
    return strength * LEAF.amp * RAD * Math.pow(s, 1.5) * env(u, LEAF.decay)
        * Math.sin(2 * Math.PI * LEAF.cycles * (u - LEAF.lag * s));
}
// the beam's angle, radians: sinks left under the swelling weight, flicks it off, rocks empty, drops right under the landing
// (a spring with one overshoot), stands, and comes back as the weight melts
function beamAngle(u, strength) {
    const S = SCALES, A = strength * RAD;
    if (u <= 0 || u >= 1)
        return 0;
    if (u < S.load)
        return A * S.sink * O.smooth(0, S.load, u);
    if (u < S.flick)
        return A * (S.sink - (S.sink + S.kick) * O.smooth(S.load, S.flick, u));
    if (u < S.land) {
        const w = O.seg(u, S.flick, S.land);
        return -A * S.kick * (1 - w) * (1 - w) * Math.cos(1.5 * Math.PI * w);
    }
    const tau = u - S.land, om = Math.PI / S.peak, d = -Math.log(S.over) * om / Math.PI;
    const spring = 1 - Math.exp(-d * tau) * (Math.cos(om * tau) + d / om * Math.sin(om * tau));
    return -A * S.tip * spring * (1 - O.outBack(O.seg(u, S.back, 1), S.backOver));
}
// a pan's swing about its string's apex: a share of the beam's angle, late (and on time at the end: rest)
function panAngle(u, strength) {
    return SCALES.hang * beamAngle(u - SCALES.late * (1 - u), strength);
}
// the weight's radius, font units
function weightR(u) {
    const S = SCALES;
    if (u <= 0 || u >= S.melt1)
        return 0;
    return S.r * (u < S.load ? O.outBack(O.seg(u, 0, S.load * 0.8), 2.2) : 1 - O.inQuad(O.seg(u, S.melt0, S.melt1)));
}
// where pan `ax`'s point (x, y) stands at u: carried by the beam's end, swung about the apex
function _panAt(ax, u, strength) {
    const S = SCALES;
    const a = O.turn(ax, S.ay, S.px, S.py, beamAngle(u, strength)), ps = panAngle(u, strength);
    return function (x, y) {
        const r = O.turn(x, y, ax, S.ay, ps);
        return [r[0] + a[0] - ax, r[1] + a[1] - S.ay];
    };
}
// the weight's centre: seated in the left pan, one parabola over the pivot, seated in the right pan
function weightAt(u, strength) {
    const S = SCALES, r = weightR(u);
    if (u <= S.go)
        return _panAt(S.a0x, u, strength)(S.a0x, S.seat + r);
    if (u >= S.land)
        return _panAt(S.a1x, u, strength)(S.a1x, S.seat + r);
    const p0 = _panAt(S.a0x, S.go, strength)(S.a0x, S.seat + S.r), p1 = _panAt(S.a1x, S.land, strength)(S.a1x, S.seat + S.r);
    const s = O.seg(u, S.go, S.land), h = S.apex - (p0[1] + p1[1]) / 2;
    return [p0[0] + (p1[0] - p0[0]) * s, p0[1] + (p1[1] - p0[1]) * s + 4 * h * s * (1 - s)];
}
// a disc as one contour of eight quadratic arcs
function _disc(cx, cy, r) {
    const c = [["M", cx + r, cy]], n = 8, k = r / Math.cos(Math.PI / n);
    for (let i = 1; i <= n; ++i) {
        const am = (2 * i - 1) * Math.PI / n, a = 2 * i * Math.PI / n;
        c.push(["Q", cx + k * Math.cos(am), cy + k * Math.sin(am), cx + r * Math.cos(a), cy + r * Math.sin(a)]);
    }
    return c;
}

// ---- the bolt ----
// The outline by height (the font's six corners: (596, 1554) the upper tip, (0, 358) and (428, 358) the left step,
// (596, 870) and (1024, 870) the right step, (428, -326) the lower tip). `below`: the side of a step's own height.
function _boltLeft(y, below) {
    return y > 358 || (y === 358 && !below) ? (y - 358) * 596 / 1196 : 428;
}
function _boltRight(y, below) {
    return y > 870 || (y === 870 && !below) ? 596 : 428 + (y + 326) * 596 / 1196;
}
// the spine: the upper tip, the middle of the upper wedge at the right step, of the lower wedge at the left step, the lower tip
const BOLT_SPINE = [[1554, 596], [870, 425.5], [358, 598.5], [-326, 428]];
function _boltSpine(y) {
    for (let i = 1; i < BOLT_SPINE.length; ++i) {
        const a = BOLT_SPINE[i - 1], b = BOLT_SPINE[i];
        if (y >= b[0])
            return a[1] + (b[1] - a[1]) * (a[0] - y) / (a[0] - b[0]);
    }
    return BOLT_SPINE[BOLT_SPINE.length - 1][1];
}
// The stroke between the depths `a` and `b` under the upper tip, narrowed toward the spine to a point at each over `taper`
// (an end `taper` clear of the bolt narrows nothing): one polygon, [] when nothing is left. Sampled at the outline's own
// corners (a step twice: its two sides) and through each narrowing.
function boltStroke(a, b) {
    const B = BOLT, T = B.taper, d0 = Math.max(0, a), d1 = Math.min(B.top - B.foot, b);
    if (d1 - d0 < 1e-6)
        return [];
    const ds = [d0, d1, B.top - 870, B.top - 358];
    for (let i = 1; i <= 6; ++i) {
        ds.push(a + T * i / 6);
        ds.push(b - T * i / 6);
    }
    ds.sort(function (m, n) { return m - n; });
    const left = [], right = [];
    let last = -1e9;
    for (let i = 0; i < ds.length; ++i) {
        const d = ds[i];
        if (d < d0 || d > d1 || d - last < 1e-6)
            continue;
        last = d;
        const y = B.top - d, c = _boltSpine(y), f = O.clamp01(Math.min((d - a) / T, (b - d) / T));
        const step = y === 870 || y === 358;
        for (let side = 0; side < (step ? 2 : 1); ++side) {
            left.push([c + (_boltLeft(y, side === 1) - c) * f, y]);
            right.push([c + (_boltRight(y, side === 1) - c) * f, y]);
        }
    }
    const out = [];
    const put = function (q) {
        const l = out.length > 0 ? out[out.length - 1] : null;
        if (!l || Math.abs(l[0] - q[0]) > 1e-6 || Math.abs(l[1] - q[1]) > 1e-6)
            out.push(q);
    };
    left.forEach(put);
    right.reverse().forEach(put);
    return out.length >= 3 ? out : [];
}
// The bolt at u. `a`: the depth of the running-off ink's tail (what lies below it is left), `b`: of the charge's head (what
// lies above it is in) -- each the POINT of its stream, so `a` sets off `taper` above the bolt and `b` lands `taper` under
// it: whole at both ends of the run; each with its own figure { sx, sy, dy } about the bolt's middle.
function boltState(u, strength) {
    const B = BOLT, span = B.top - B.foot + B.taper;
    const dr = O.inQuad(O.seg(u, 0, B.drainEnd)), st = O.inCubic(O.seg(u, B.strike0, B.hit));
    const r = { a: -B.taper + span * dr, b: span * st,
                ink: { sx: 1 - B.thin * dr, sy: 1, dy: -B.sag * dr },
                charge: { sx: 1 + strength * B.fat * st, sy: 1 + strength * B.fat * 0.5 * st, dy: B.drop * (1 - st) - strength * B.bob * st } };
    if (u >= B.hit) {
        const v = O.seg(u, B.hit, 1), ring = Math.exp(-B.decay * v) * Math.cos(2 * Math.PI * B.cycles * v) * (1 - v);
        r.charge = { sx: 1 + strength * B.fat * ring, sy: 1 + strength * B.fat * 0.5 * ring, dy: -strength * B.bob * ring };
    }
    return r;
}
// the bolt's ink at u: the contours of its one path (font units), the two streams never touching
function boltParts(u, strength) {
    const st = boltState(u, strength), cs = [];
    const add = function (pts, f) {
        if (pts.length > 0)
            cs.push(O.polygon(pts.map(function (q) { return [BOLT.cx + (q[0] - BOLT.cx) * f.sx, BOLT.cy + (q[1] - BOLT.cy) * f.sy + f.dy]; })));
    };
    add(boltStroke(st.a, 1e9), st.ink);
    add(boltStroke(-1e9, st.b), st.charge);
    return cs;
}

// ---- the paths: one SVG string per part (the curve renderer resolves overlapping or touching contours of ONE path wrongly --
// a grey seam down the scales -- so each part is a ShapePath of its own; the overlaps lie inside the beam). The leaf is one
// part, the bolt one (its two streams), the scales five (the last the weight,
// "" while there is none). `rest` is the font's own outline, what `path` returns at either end. ----
function rest(kind, px, ox, oy) {
    const k = px / P.UNITS;
    if (kind === 0)
        return [O.emit(P.leaf.contours, O.same, k, ox, oy)];
    if (kind === 1)
        return [O.emit(P.scales_base.contours, O.same, k, ox, oy), O.emit(P.scales_beam.contours, O.same, k, ox, oy),
                O.emit(P.scales_pan0.contours, O.same, k, ox, oy), O.emit(P.scales_pan1.contours, O.same, k, ox, oy), ""];
    return [O.emit(P.bolt.contours, O.same, k, ox, oy)];
}
function path(kind, u, strength, px, ox, oy) {
    // the ends are RETURNED, not computed: a turn by nothing is the font's point give or take a rounding
    if (u <= 0 || u >= 1)
        return rest(kind, px, ox, oy);
    const k = px / P.UNITS;
    if (kind === 0) {
        const bx = LEAF.bx, by = LEAF.by, dx = LEAF.tx - bx, dy = LEAF.ty - by, len = Math.sqrt(dx * dx + dy * dy);
        const ux = dx / len, uy = dy / len;
        return [O.emit(P.leaf.contours, function (x, y) {
            const s = Math.max(0, Math.min(1, ((x - bx) * ux + (y - by) * uy) / len));
            return s <= 0 ? [x, y] : O.turn(x, y, bx, by, leafAngle(s, u, strength));
        }, k, ox, oy)];
    }
    if (kind === 1) {
        const S = SCALES, th = beamAngle(u, strength);
        const beam = function (x, y) { return O.turn(x, y, S.px, S.py, th); };
        const r = weightR(u), w = weightAt(u, strength);
        return [O.emit(P.scales_base.contours, O.same, k, ox, oy), O.emit(P.scales_beam.contours, beam, k, ox, oy),
                O.emit(P.scales_pan0.contours, _panAt(S.a0x, u, strength), k, ox, oy),
                O.emit(P.scales_pan1.contours, _panAt(S.a1x, u, strength), k, ox, oy),
                r > 0 ? O.emit([_disc(w[0], w[1], r)], O.same, k, ox, oy) : ""];
    }
    return [O.emit(boltParts(u, strength), O.same, k, ox, oy)];
}
