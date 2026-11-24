.pragma library
.import "../../common/components/GlyphOutline.js" as O
.import "BridgeParts.js" as P

// =============================================================================
// BridgePose.js -- the bridge button's bridge as a DRAWBRIDGE (docs/contracts/bridge.md, the bar glyph). md-bridge is a
// suspension bridge: a deck through two towers, a cable hanging between the towers' shoulders, four suspenders. Pure functions:
// `frame(upL, upR, px, ox, oy)` is { parts, shades } for PosedGlyph, each leaf's lift as a share of the raised angle (0 the
// bridge down: the font's own glyph; 1 raised; a little under 0 or over 1 while it bounces or bows).
//
// THE TWO LEAVES. The font's ink cut at mid span (BridgeParts.js `left`, `right`: every point the font's own, the middle window
// a notch in each tip). A leaf is moved by ONE continuous map of its outline, so nothing is redrawn and nothing pops:
//
//   the tower, its pier, the road outside it     never move
//   the deck                                     stays flat to the HINGE, a little out from the tower, and turns about it: it
//                                                bends in one mitred point on each edge
//   everything over the deck                     the cable, its suspenders and the windows FOLD DOWN onto the deck as the leaf
//                                                comes up (`_foldOf`): their height over it shrinks to nothing, and a leaf
//                                                they lie flat on is drawn without them (`bareLeft`, `bareRight`: contours
//                                                that have shrunk onto an edge take that edge's antialiasing away)
//
// RAISED IS FOUR STROKES: a tower and a bare leaf, a leaf and a tower. At the bar's size a stroke is a pixel and a half: the raised
// pose of rounds 6 to 9 kept the cable as a chain from the tower to the leaf's tip, with the suspenders closing between, and that
// triangle's inside is under a pixel (the user, 2026-11-22: "the vertical cables melt into each other"). Every gap that is left is
// over a pixel at 15 px: tower to leaf (the hinge stands out from the tower so that it is), leaf to leaf. (glyph_flourish_probe
// bridge_raised counts them along the rows.) The left tower is this computer, the right one the phone.
//
// THE FOLD IS THE STATE'S, NEVER THE FLOURISH'S: `heldL` / `heldR` are the leaves' lifts without it, so a raised bridge that dips
// stays a tower and a bare leaf, and one that is down keeps most of its cable at the top of its salute.
//
// THE REST IS RETURNED, NOT COMPUTED: with both leaves at 0 `frame` returns the font's whole outline (`rest`), path for path;
// two leaves that meet on a line would not sum to it (two antialiased edges on one seam).
//
// WHAT PLAYS ON THE FLOURISH CLOCK (`bow`): the bridge salutes -- down, both leaves swing up about a quarter turn, drop back
// under their own weight and BOUNCE on the pier, twice, smaller each time (a ball's arcs: each hop's time goes as the root of
// its height); raised, they dip and are hauled back up against their stop, and bounce off it the same way. It never reaches
// the other state and never passes through the rest (a leaf does not swing through its pier). At 15 px the salute must read:
// round 6b's 16-degree lift was "barely visible" (the user, 2026-11-21). And `settle`: a weight comes on (the cable is plugged
// in): the deck sags at mid span and springs back.
// =============================================================================

var DEFAULTS = {
    raisedDeg: 52,    // a raised leaf's angle
    foldFrom: 0.4,    // the lift at which the cable begins to fold down onto the leaf ...
    foldTo: 0.9,      // ... and the one at which it lies on it
    bowMs: 1000,      // the salute's length
    bowDown: 0.58,    // the salute of a bridge that is down: how far the leaves lift, as a share of the raised angle
    bowUp: 0.32,      // ... of a raised one: how far they dip (their tips stay apart)
    bowRise: 0.27,    // the share of the salute the lift takes; the drop back takes as long as a fall from that height does
    bowHops: [0.2, 0.06], // the bounces on the stop, each a share of the lift's height
    settleMs: 620,    // a weight coming on
    settleSag: 0.17,  // how far the deck sags then (a share of the raised angle, downwards)
    jump: 0.16,       // the WHOLE glyph hops with the salute, this share of the glyph's size at the top (on the salute's own curve)
    sink: 0.07        // ... and sinks with the cable's sag, this share at the deepest
};

function look(over) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = over && over[k] !== undefined ? (Array.isArray(DEFAULTS[k]) ? over[k] : Number(over[k])) : DEFAULTS[k];
    return l;
}

// the font's numbers (tools/dev/flourish_parts.py holds them to the font)
var MID = 940;
var EDGE = 344;                        // the left tower's inner edge
var DECK_TOP = 484, DECK_FOOT = 316;
var CABLE_TOP = 960;                   // the cable's top at the tower
var HINGE_X = 420, HINGE_Y = 400;      // the left leaf's hinge on the deck's middle line; the right one's is its mirror
var LIFE = DEFAULTS.bowMs;

// how far the superstructure has come down onto a leaf whose lift is `up` with the state's own at `held` (undefined: the same)
function _foldOf(up, held, l) {
    return O.smooth(l.foldFrom, l.foldTo, Math.max(up, held === undefined ? up : held));
}

// the left leaf's map at lift `up` (share of the raised angle), its superstructure folded by `fold` (0 the font's, 1 flat on the
// deck); the right leaf's is its mirror
function _leaf(up, fold, l) {
    const a = up * l.raisedDeg * Math.PI / 180;
    // the two edges meet in a point each where the deck bends (a mitre), at rest the hinge's own place on them
    const mitre = (DECK_TOP - HINGE_Y) * Math.tan(a / 2);
    return function (x, y) {
        // the tower, its pier, the road outside it and the deck to the hinge; the cable's two points on the tower's edge come down it
        if (x < EDGE || (x === EDGE && y > CABLE_TOP) || (x < HINGE_X && y <= DECK_TOP))
            return [x, y];
        if (x === HINGE_X)
            return [y > HINGE_Y ? x - mitre : x + mitre, y];
        if (y <= DECK_TOP)
            return O.turn(x, y, HINGE_X, HINGE_Y, a);
        const d = x < HINGE_X ? [x, DECK_TOP] : O.turn(x, DECK_TOP, HINGE_X, HINGE_Y, a);
        return [d[0], d[1] + (y - DECK_TOP) * (1 - fold)];
    };
}
function _mirrored(fn) {
    return function (x, y) {
        const p = fn(2 * MID - x, y);
        return [2 * MID - p[0], p[1]];
    };
}

// where a leaf's tip stands (the deck's top at mid span), font units: what a probe measures the gap by
function tip(up, over, right) {
    const p = _leaf(up, 0, look(over))(MID, DECK_TOP);
    return right ? [2 * MID - p[0], p[1]] : p;
}

// the font's outline, as `frame` returns it with both leaves down
function rest(px, ox, oy) {
    return O.emit(P.whole, O.same, px / P.UNITS, ox, oy);
}

// { parts, shades }: the two leaves at their lifts (`heldL` / `heldR`: without the flourish); both at 0, the font's own outline
function frame(upL, upR, over, px, ox, oy, heldL, heldR) {
    if (upL === 0 && upR === 0)
        return { parts: [rest(px, ox, oy)], shades: [] };
    const l = look(over);
    const k = px / P.UNITS;
    const fL = _foldOf(upL, heldL, l), fR = _foldOf(upR, heldR, l);
    return { parts: [O.emit(fL >= 1 ? P.bareLeft : P.left, _leaf(upL, fL, l), k, ox, oy),
                     O.emit(fR >= 1 ? P.bareRight : P.right, _mirrored(_leaf(upR, fR, l)), k, ox, oy)], shades: [] };
}

// ---- what plays on the flourish clock: an offset to a leaf's lift, 0 at both ends of the run -------------------------

// The salute's shape at x (0..1 of the run), 0..1: a lift that slows to its top, a fall from it under gravity, then a hop per
// `hops` entry (its height a share of the lift's), each a parabola as long as a ball's from that height. Never under 0.
function hop(x, l) {
    const rise = l.bowRise;
    if (x <= 0 || x >= 1)
        return 0;
    if (x < rise)
        return O.outCubic(x / rise);
    // the fall from the top takes as long as the lift (one unit of gravity's time), each hop 2 sqrt(h) of that
    const unit = rise;
    let at = rise + unit;
    if (x < at) {
        const u = (x - rise) / unit;
        return 1 - u * u;
    }
    for (let i = 0; i < l.bowHops.length; i++) {
        const h = l.bowHops[i], half = unit * Math.sqrt(h);
        if (x < at + 2 * half) {
            const u = (x - at - half) / half;
            return h * (1 - u * u);
        }
        at += 2 * half;
    }
    return 0;
}

// The salute at t of `life`: `raised` says which way (a bridge that is down lifts, a raised one dips).
function bow(t, life, raised, over) {
    if (t <= 0 || t >= life)
        return 0;
    const l = look(over);
    const amount = hop(t / life, l);
    return raised ? -l.bowUp * amount : l.bowDown * amount;
}

// The whole glyph's hop at t of `life`, a share of the glyph's size, up positive (the user, 2026-11-21: the whole glyph bounces too):
// the salute's own curve (it leaves the bar as the leaves go up and lands as they land, bouncing with them), whichever way the leaves
// go; with the cable's weight it sinks with the deck and springs back.
function jump(t, life, cable, over) {
    if (t <= 0 || t >= life)
        return 0;
    const l = look(over);
    if (cable)
        return settle(t, life, over) / l.settleSag * l.sink;
    return l.jump * hop(t / life, l);
}

// A weight coming on at t of `life`: the deck sags and springs back (both leaves, downwards).
function settle(t, life, over) {
    if (t <= 0 || t >= life)
        return 0;
    const l = look(over);
    const x = t / life;
    return -l.settleSag * Math.sin(Math.PI * 3 * x) * (1 - x) * (1 - x) * O.outCubic(x / 0.12);
}
