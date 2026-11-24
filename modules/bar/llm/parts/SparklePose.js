.pragma library
.import "../../../common/components/GlyphOutline.js" as O
.import "SparkleParts.js" as P

// =============================================================================
// SparklePose.js -- the chat star's flourish (feedback/llm.md "Bar glyph flourish"): THE SPARK KINDLES. Pure functions of its
// clock (GlyphFlourish `t`, ms): `frame(t, life, look, px, ox, oy)` is { parts: [the star, a spark, a second spark] } as SVG
// paths for PosedGlyph.
//
// The glyph is one four-pointed star. It does what a spark does when it catches, in three beats:
//
//   it gathers   the star winds back a little against its turn and pulls in (`windDeg`, `windScale`): a breath in
//   it flares    it lets go: a quarter turn forward, past it and back (the star has four points, so a quarter turn lands on
//                itself), while its points draw out long and thin and its waist pulls in (`flare`), and it swells for an
//                instant (`pop`)
//   it throws    two small stars -- the star's own shape -- are flung out of it along the diagonals, one up to the right and a
//                smaller one down to the left, later: for a moment the icon is the three-star cluster everyone draws for
//                this, made out of the one star. Each turns the other way as it goes, hangs, and winks out where it stands
//
// No shimmer (nothing glints, no ink changes) and no second object: only the star and smaller stars. Every motion is zero at
// the run's first instant and its last, and the star is the font's outline, corner for corner, at both: the quarter turn is
// counted off once it is past its half (the same shape, the corners renamed), so the last frame's path is the first's.
// =============================================================================

// The motion's numbers; times in ms of a `life` of LIFE (another life scales them). A caller may hand overrides (`look`).
var DEFAULTS = {
    windMs: 150,      // the gathering
    windDeg: 14,      // how far it winds back (clockwise)
    windScale: 0.8,   // how far it pulls in
    spinMs: 400,      // the flare: the quarter turn, from the wind's end
    spinBack: 2.4,    // the turn's overshoot (OutBack's s)
    flare: 0.42,      // how far the waist pulls in at the flare's height (a share of its radius)
    reach: 0.1,       // how far the points draw out
    pop: 0.14,        // the swell
    aAt: 200,         // the first spark: when it leaves, where it stands (font units from the star's middle), its size (a share
    aX: 800,          // of the star's), how long it travels, and when it starts to wink out
    aY: 740,
    aSize: 0.42,
    bAt: 290,         // the second, smaller, the other way
    bX: -760,
    bY: -700,
    bSize: 0.3,
    outMs: 230,       // a spark's travel
    hangMs: 330,      // from its leaving to the start of its wink
    winkMs: 190,      // the wink
    sparkTurn: 135    // deg a spark turns against the star over its life
};
var LIFE = 880;
var MID = [940, 614];

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}

// what the run is doing at t, as numbers (a probe reads them; `frame` draws them)
//   deg      the star's turn, counter-clockwise, the quarter turn counted off past its half (so it ends at 0)
//   size     its size; waist, reach: the flare (shares)
//   a, b     the sparks: { on, x, y, size, deg }
function state(t, life, look) {
    const l = _look(look);
    const x = t / (Math.max(1, life) / LIFE);
    const st = { deg: 0, size: 1, waist: 0, reach: 0, a: null, b: null };
    const wind = O.inOutQuad(x / l.windMs);
    const go = O.outBack((x - l.windMs) / l.spinMs, l.spinBack);
    const bump = Math.sin(Math.PI * O.seg(x, l.windMs, l.windMs + l.spinMs * 0.8));
    let deg = -l.windDeg * wind + (90 + l.windDeg) * go;
    if (deg > 45)
        deg -= 90;
    st.deg = deg;
    st.size = 1 - (1 - l.windScale) * wind * (1 - O.outCubic((x - l.windMs) / (l.spinMs * 0.45))) + l.pop * bump;
    st.waist = l.flare * bump;
    st.reach = l.reach * bump;
    const spark = function (at, sx, sy, size) {
        const age = x - at;
        if (age <= 0 || age >= l.hangMs + l.winkMs)
            return null;
        const out = O.outCubic(age / l.outMs);
        const grow = O.outBack(age / l.outMs, 1.8) * (1 - O.inQuad((age - l.hangMs) / l.winkMs));
        return { x: sx * out, y: sy * out, size: size * grow, deg: -l.sparkTurn * age / (l.hangMs + l.winkMs) };
    };
    st.a = spark(l.aAt, l.aX, l.aY, l.aSize);
    st.b = spark(l.bAt, l.bX, l.bY, l.bSize);
    return st;
}

// the star's eight corners take turns: a point, a waist corner, a point, ... (the font's order, from the top point)
function _star(st) {
    const a = st.deg * Math.PI / 180;
    const c = Math.cos(a), s = Math.sin(a);
    return function (x, y) {
        const dx = x - MID[0], dy = y - MID[1];
        // a point lies on an axis through the middle, a waist corner on a diagonal
        const point = Math.abs(dx) < 1 || Math.abs(dy) < 1;
        const f = st.size * (point ? 1 + st.reach : 1 - st.waist);
        return [MID[0] + (c * dx - s * dy) * f, MID[1] + (s * dx + c * dy) * f];
    };
}

function _spark(sp) {
    const a = sp.deg * Math.PI / 180;
    const c = Math.cos(a), s = Math.sin(a);
    return function (x, y) {
        const dx = x - MID[0], dy = y - MID[1];
        return [MID[0] + sp.x + (c * dx - s * dy) * sp.size, MID[1] + sp.y + (s * dx + c * dy) * sp.size];
    };
}

// { parts: [the star, the first spark, the second] } at run time t
function frame(t, life, look, px, ox, oy) {
    const st = state(t, life, look);
    const k = px / P.UNITS;
    return {
        parts: [O.emit(P.star, _star(st), k, ox, oy),
                st.a && st.a.size > 0.004 ? O.emit(P.star, _spark(st.a), k, ox, oy) : "",
                st.b && st.b.size > 0.004 ? O.emit(P.star, _spark(st.b), k, ox, oy) : ""]
    };
}

// the font's outline as `frame` would emit it: what its first and last instants must be (a probe compares)
function rest(px, ox, oy) {
    return O.emit(P.star, O.same, px / P.UNITS, ox, oy);
}
