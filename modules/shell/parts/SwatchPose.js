.pragma library
.import "../../common/components/GlyphOutline.js" as O
.import "SwatchParts.js" as P

// =============================================================================
// SwatchPose.js -- the theme button's flourish (feedback/themectl.md "Icon overhaul + flourish"): THE SWATCH BOOK IS FLIPPED.
// Pure functions of its clock (GlyphFlourish `t`, ms): `frame(key, t, life, look, px, ox, oy)` is { parts: [the back card, the
// middle card, the card in front] } as SVG paths for PosedGlyph. `key` is the glyph its outline is filed under in SwatchParts.js
// ("f08b5": md-palette_swatch, the filled swatch the button shows in both modes).
//
// The glyph is a swatch book: three colour cards held by one rivet and fanned out, the card in front whole, of each card behind
// only the sliver left of the card over it, an even gap of bar between two cards. THE MODEL here is that drawing rule, so the
// fan can be any fan: each card behind is a WHOLE card (the font's own corner and two edges, carried on round to the reach of
// the card in front), turned about the rivet, and what shows of it is what lies beyond THE CUT -- the line the font cuts it
// along, which belongs to the card over it and turns with that card. A card turned under the one over it is beyond no cut: it
// shows nothing, and the book is shut. At rest every number is the font's.
//
//   it leans     the book leans back against the turn (`windDeg`), and the fan opens a hair as it does
//   it flips     it lets go: one full turn clockwise, the card in front leading. Each card behind does what the one over it
//                did a moment later (`lagMs`, twice that for the last) and cannot pass it, so the book snaps SHUT the instant
//                it starts and turns as one card -- about the icon's middle (`about`: a card is as long as the icon, and
//                about its own rivet it would swing out over the neighbour), a little up in the air (`hop`) and a little
//                pulled in (`pull`), as a thing does that is tossed
//   it lands     the card in front lands a little too far and comes back (`spinBack`); the cards behind are still on their
//                way and come out from under it one after the other, tick, tick, the fan wider than it rests for a moment
//                because the front card is already on its way back, and everything settles
//
// The swatch stays the font's swatch in every frame: a card behind is never drawn over the card in front (that would fill its
// rivet's hole in and close the gap between two cards), and no ink changes. Every motion is zero at the run's first instant
// and its last, and the picture is the font's outline, segment for segment, at both: the full turn is counted off once it is
// past its half, the run ends only when the last card has landed (`_total`), and a cut's corners are snapped to a millionth
// of a font unit (an intersection is the font's point give or take 1e-13, which is enough to tip a rounding tie in the path's
// third decimal).
// =============================================================================

// The motion's numbers; times in ms of a run of LIFE (another life scales them). A caller may hand overrides (`look`).
var DEFAULTS = {
    windMs: 140,      // the lean back
    windDeg: 16,      // how far (counter-clockwise, against the turn)
    spinMs: 520,      // the turn, from the lean's end, for the card in front
    spinBack: 1.5,    // the turn's overshoot (OutBack's s: 1.5 lands 8 % of the way too far, 30 degrees)
    lagMs: 60,        // how much later the middle card does what the front one did; the back card twice that
    restMs: 20,       // a moment at rest before the run ends
    about: 1,         // what the book turns about: 0 its rivet (it swings out over its neighbour), 1 the icon's middle
    hop: 130,         // how high the book rises while it turns, font units (2048 to the glyph's size)
    pull: 0.08,       // how far it pulls in while it turns (a share of its size)
    pop: 0.04         // and the swell as it lands
};

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}
// the run's length in its own ms: the last card has landed and rested (so the run's last instant is the rest picture whatever
// the numbers are)
function _total(l) {
    return l.windMs + l.spinMs + 2 * l.lagMs + l.restMs;
}
// how long a play takes with the default numbers, ms (the host's clock length)
var LIFE = _total(DEFAULTS);

// ---- the glyph as a fan of whole cards ----------------------------------------------------------------------------------------

function _unit(ax, ay, bx, by) {
    const dx = bx - ax, dy = by - ay, n = Math.sqrt(dx * dx + dy * dy);
    return [dx / n, dy / n];
}
function _end(sg) {
    return [sg[sg.length - 2], sg[sg.length - 1]];
}

// A card behind, whole. `s0` where its left edge meets its bottom-left corner, `q` that corner (the font's two curves, s0 to
// c1), `c1` where the corner meets the bottom edge, `b1` / `b2` the font's cut (where it crosses the bottom edge and the left
// edge). The card runs `right` font units right of the rivet and `top` above it along its own edges, like the card in front.
// `fromBottom`: the contour starts at c1 (the back sliver's order in the font); else at s0 (the middle one's).
function _card(s0, q, c1, b1, b2, rivet, top, right, fromBottom) {
    const ul = _unit(s0[0], s0[1], b2[0], b2[1]);
    const ub = _unit(c1[0], c1[1], b1[0], b1[1]);
    // the sharp corner the font rounded: where the two edges' lines meet
    const den = ul[0] * ub[1] - ul[1] * ub[0];
    const a = ((c1[0] - s0[0]) * ub[1] - (c1[1] - s0[1]) * ub[0]) / den;
    const bl = [s0[0] + ul[0] * a, s0[1] + ul[1] * a];
    const r = Math.abs(a);
    const w = (rivet[0] - bl[0]) * ub[0] + (rivet[1] - bl[1]) * ub[1] + right;
    const h = (rivet[0] - bl[0]) * ul[0] + (rivet[1] - bl[1]) * ul[1] + top;
    const br = [bl[0] + ub[0] * w, bl[1] + ub[1] * w];
    const tr = [br[0] + ul[0] * h, br[1] + ul[1] * h];
    const tl = [bl[0] + ul[0] * h, bl[1] + ul[1] * h];
    const far = [
        ["L", br[0] - ub[0] * r, br[1] - ub[1] * r], ["Q", br[0], br[1], br[0] + ul[0] * r, br[1] + ul[1] * r],
        ["L", tr[0] - ul[0] * r, tr[1] - ul[1] * r], ["Q", tr[0], tr[1], tr[0] - ub[0] * r, tr[1] - ub[1] * r],
        ["L", tl[0] + ub[0] * r, tl[1] + ub[1] * r], ["Q", tl[0], tl[1], tl[0] - ul[0] * r, tl[1] - ul[1] * r]
    ];
    const card = fromBottom ? [["M", c1[0], c1[1]]].concat(far, [["L", s0[0], s0[1]]], q)
                            : [["M", s0[0], s0[1]]].concat(q, far, [["L", s0[0], s0[1]]]);
    // which side of the cut (b1 -> b2) the sliver lies on: a fact of the drawing, the same however the cards are turned
    const side = (s0[0] - b1[0]) * (b2[1] - b1[1]) - (s0[1] - b1[1]) * (b2[0] - b1[0]) < 0 ? -1 : 1;
    return { card: card, cut: [b1, b2], side: side, up: ul };
}

var _geo = {};
// { rivet, mid: [x, y] (the icon's middle), front: contours, midCard, backCard: { card (whole), cut (the font's two points),
// side (which side of the cut shows), up (its left edge's direction) }, spreadMid, spreadBack }
function geo(key) {
    if (_geo[key])
        return _geo[key];
    const g = P.G[key];
    const m = g.mid[0], b = g.back[0];
    // the card in front's own axes: its left edge runs along the middle card's cut
    const fl = _unit(m[3][1], m[3][2], m[4][1], m[4][2]);
    const fr = [fl[1], -fl[0]];
    let top = 0, right = 0, x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
    const all = g.front.concat(g.mid, g.back);
    for (let i = 0; i < all.length; ++i) {
        for (let j = 0; j < all[i].length; ++j) {
            const p = _end(all[i][j]);
            x0 = Math.min(x0, p[0]);
            x1 = Math.max(x1, p[0]);
            y0 = Math.min(y0, p[1]);
            y1 = Math.max(y1, p[1]);
            if (i < g.front.length) {
                top = Math.max(top, (p[0] - g.rivet[0]) * fl[0] + (p[1] - g.rivet[1]) * fl[1]);
                right = Math.max(right, (p[0] - g.rivet[0]) * fr[0] + (p[1] - g.rivet[1]) * fr[1]);
            }
        }
    }
    const mc = _card([m[0][1], m[0][2]], [m[1], m[2]], _end(m[2]), [m[3][1], m[3][2]], [m[4][1], m[4][2]], g.rivet, top, right, false);
    const bc = _card([b[3][1], b[3][2]], [b[4], b[5]], [b[0][1], b[0][2]], [b[1][1], b[1][2]], [b[2][1], b[2][2]], g.rivet, top, right, true);
    const between = function (u, v) {
        return Math.atan2(u[0] * v[1] - u[1] * v[0], u[0] * v[0] + u[1] * v[1]) * 180 / Math.PI;
    };
    _geo[key] = {
        rivet: g.rivet,
        mid: [(x0 + x1) / 2, (y0 + y1) / 2],
        front: g.front,
        midCard: mc,
        backCard: bc,
        // the rest spread, degrees: how far each card lies counter-clockwise of the one behind it
        spreadMid: between(mc.up, fl),
        spreadBack: between(bc.up, mc.up)
    };
    return _geo[key];
}

// ---- the cut -------------------------------------------------------------------------------------------------------------------

function _snap(v) {
    return Math.round(v * 1e6) / 1e6;
}

// The part of contour `c` on one side of the line a -> b (`sgn`: 1 its right, -1 its left; Sutherland-Hodgman against one
// line, the curves kept as curves where the line leaves them whole and as chords where it cuts one). The contour comes out in
// its own order from its own start, so a card the line cuts where the font cut it comes out as the font's sliver, segment for
// segment; a card wholly beyond the line comes out as nothing.
function cut(c, a, b, sgn) {
    const nx = b[1] - a[1], ny = a[0] - b[0];
    const side = function (x, y) {
        return sgn * ((x - a[0]) * nx + (y - a[1]) * ny);
    };
    const out = [];
    let px = c[0][1], py = c[0][2], pd = side(px, py);
    if (pd >= 0)
        out.push(["M", px, py]);
    const line = function (x, y) {
        const d = side(x, y);
        if ((pd >= 0) !== (d >= 0)) {
            const f = pd / (pd - d);
            out.push(["L", _snap(px + (x - px) * f), _snap(py + (y - py) * f)]);
        }
        if (d >= 0)
            out.push(["L", x, y]);
        px = x;
        py = y;
        pd = d;
    };
    for (let i = 1; i < c.length; ++i) {
        const sg = c[i];
        if (sg[0] === "L") {
            line(sg[1], sg[2]);
            continue;
        }
        const dc = side(sg[1], sg[2]), de = side(sg[3], sg[4]);
        if (pd >= 0 && dc >= 0 && de >= 0) {
            out.push(sg);
            px = sg[3];
            py = sg[4];
            pd = de;
        } else if (pd < 0 && dc < 0 && de < 0) {
            px = sg[3];
            py = sg[4];
            pd = de;
        } else {
            const sx = px, sy = py;
            for (let n = 1; n <= 6; ++n) {
                const u = n / 6, v = 1 - u;
                line(v * v * sx + 2 * v * u * sg[1] + u * u * sg[3], v * v * sy + 2 * v * u * sg[2] + u * u * sg[4]);
            }
        }
    }
    if (out.length < 3)
        return [];
    // the contour closes by itself: a last line back onto the start says nothing
    const last = out[out.length - 1];
    if (last[0] === "L" && Math.abs(last[1] - out[0][1]) < 1e-9 && Math.abs(last[2] - out[0][2]) < 1e-9)
        out.pop();
    if (out[0][0] !== "M")
        out[0] = ["M", out[0][out[0].length - 2], out[0][out[0].length - 1]];
    return out;
}

// ---- the motion ----------------------------------------------------------------------------------------------------------------

// one card's turn at run time x (ms of LIFE): the lean back, then the full turn the other way, past it and back; degrees,
// counter-clockwise (the turn is clockwise: negative)
function _turn(x, l) {
    const wind = O.inOutQuad(x / l.windMs);
    const go = O.outBack((x - l.windMs) / l.spinMs, l.spinBack);
    return l.windDeg * wind - (360 + l.windDeg) * go;
}

// 0 at both ends exactly, 1 in the middle
function _bump(u) {
    return u <= 0 || u >= 1 ? 0 : Math.sin(Math.PI * u);
}

// what the run is doing at t, as numbers (a probe reads them; `frame` draws them)
//   front, mid, back   each card's turn about the rivet, degrees counter-clockwise, the full turn counted off past its half
//   openMid, openBack  how far each card behind lies from the one over it, as a share of its rest spread: 0 under it (the book
//                      is shut), 1 at rest, over 1 fanned wider
//   about              the turn's middle on the way from the rivet to the icon's middle (0..1)
//   hop, size          how high the book is (font units) and its size
function state(key, t, life, look) {
    const l = _look(look);
    const g = geo(key);
    const x = t / Math.max(1, life) * _total(l);
    const end = l.windMs + l.spinMs;
    const f = _turn(x, l);
    // a card behind does what the one over it did a moment ago, and never passes it: it is stopped under it
    const m = Math.min(_turn(x - l.lagMs, l), f + g.spreadMid);
    const b = Math.min(_turn(x - 2 * l.lagMs, l), m + g.spreadBack);
    const off = function (d) {
        return d < -180 ? d + 360 : d;
    };
    const air = _bump(O.seg(x, l.windMs, end));
    return {
        front: off(f),
        mid: off(m),
        back: off(b),
        openMid: 1 + (f - m) / g.spreadMid,
        openBack: 1 + (m - b) / g.spreadBack,
        about: l.about,
        hop: l.hop * _bump(O.seg(x, l.windMs, l.windMs + l.spinMs * 0.62)),
        size: 1 - l.pull * air + l.pop * _bump(O.seg(x, end - l.spinMs * 0.4, end + l.lagMs))
    };
}

// a card's map: turned `deg` about the rivet at the book's size; the rivet itself rides the front card's turn about the turn's
// middle (the rivet, or a point on the way to the icon's middle) and the hop
function _map(g, deg, st) {
    const a = deg * Math.PI / 180;
    const c = Math.cos(a) * st.size, s = Math.sin(a) * st.size;
    const rx = g.rivet[0], ry = g.rivet[1];
    const cx = rx + (g.mid[0] - rx) * st.about, cy = ry + (g.mid[1] - ry) * st.about;
    const p = O.turn(rx, ry, cx, cy, st.front * Math.PI / 180);
    const tx = cx + (p[0] - cx) * st.size, ty = cy + (p[1] - cy) * st.size + st.hop;
    return function (x, y) {
        const dx = x - rx, dy = y - ry;
        return [tx + c * dx - s * dy, ty + s * dx + c * dy];
    };
}

function _through(c, fn) {
    const out = [];
    for (let i = 0; i < c.length; ++i) {
        const sg = c[i], n = [sg[0]];
        for (let m = 1; m < sg.length; m += 2) {
            const p = fn(sg[m], sg[m + 1]);
            n.push(p[0], p[1]);
        }
        out.push(n);
    }
    return out;
}

// the fan's three outlines in font units at state `st`: [the back card's sliver, the middle card's, the front card's contours]
function fan(key, st) {
    const g = geo(key);
    const mf = _map(g, st.front, st), mm = _map(g, st.mid, st), mb = _map(g, st.back, st);
    const at = function (fn, p) {
        return fn(p[0], p[1]);
    };
    const fa = at(mf, g.midCard.cut[0]), fb = at(mf, g.midCard.cut[1]);
    const mid = cut(_through(g.midCard.card, mm), fa, fb, g.midCard.side);
    // the back card is cut by the middle one, and by the front one where that reaches further
    let back = cut(_through(g.backCard.card, mb), at(mm, g.backCard.cut[0]), at(mm, g.backCard.cut[1]), g.backCard.side);
    if (back.length)
        back = cut(back, fa, fb, g.midCard.side);
    return [back.length ? [back] : [], mid.length ? [mid] : [], g.front.map(c => _through(c, mf))];
}

// { parts: [the back card, the middle card, the card in front] } at run time t
function frame(key, t, life, look, px, ox, oy) {
    const f = fan(key, state(key, t, life, look));
    const k = px / P.UNITS;
    return { parts: f.map(cs => cs.length ? O.emit(cs, O.same, k, ox, oy) : "") };
}

// the font's outline as `frame` would emit it: what its first and last instants must be (a probe compares)
function rest(key, px, ox, oy) {
    const g = P.G[key], k = px / P.UNITS;
    return [O.emit(g.back, O.same, k, ox, oy), O.emit(g.mid, O.same, k, ox, oy), O.emit(g.front, O.same, k, ox, oy)];
}
