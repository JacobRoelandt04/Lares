.pragma library
.import "../../common/components/GlyphSignal.js" as S
.import "../../common/components/GlyphOutline.js" as O

// =============================================================================
// StocksPose.js -- the stocks button's flourish: a RIPPLE runs along the sparkline and an ARROW leaves its tip. Pure functions of
// the flourish's clock (ms, GlyphFlourish `t`); conventions of SwatchPose.js: `DEFAULTS`, `_look(look)`, a life DERIVED from the
// numbers (`life(mode, style, look)`), and every motion exactly 0 / null at t <= 0 and t >= life.
//
//   mode   "gain" | "loss" | "closed": the face's state when the play STARTED (the host holds it for the play)
//   style  "both" | "ripple" | "arrow"
//
// A gain's lump bulges UP (negative dy, screen space) as it travels left to right along the line, a loss's dips DOWN. The front
// starts fully left of the line and ends fully right of it (`reach` = the lump's whole width), so the line is the unwarped line
// at both ends. As the front reaches the line's last point an arrow (a small triangle, no tail) is thrown off the tip -- up on a
// gain, down on a loss -- fading in fast and out. A CLOSED face (nothing is going up or down) gets a neutral S: a lump up
// followed by one down (`trail` behind), zero net, which carries on through the three dots (`look.dotX`, px from the line's
// left end): each hops up as the front passes it. A closed face has no arrow, whatever the style.
//
// `dy(x, w, t, mode, style, look)` the displacement of the line at x (px from its left end, 0..w); `dotHop(xDot, w, t, mode,
// style, look)` a dot's; `arrow(t, mode, style, look)` { dy (from its start, px), alpha } or null; `life(...)` ms.
// =============================================================================

var DEFAULTS = {
    w: 22,           // the line's width, px
    dotX: null,      // the closed face's dots, px from the line's left end (null: no dots)
    travelMs: 560,   // the front's trip over the LIVE line (a closed face's is longer by the same speed)
    amp: 2,          // the lump's height, px
    half: 5,         // the lump's half width, px: its sigma is half / 2 and it ends at twice `half`
    trail: 8,        // the closed S's second lump this far behind the first, px
    hop: 2,          // a dot's hop, px
    arrowMs: 320,    // the arrow's flight
    arrowTravel: 5,  // how far it goes from where it starts, px
    arrowStart: 2.5, // where it starts, px from the tip, along its way
    arrowSize: 4,    // its width, px (its height is 0.9 of it)
    arrowAlpha: 0.6  // the ink's alpha at the most
};

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined && look[k] !== null ? look[k] : DEFAULTS[k];
    if (look && look.dotX === null)
        l.dotX = null;
    return l;
}
function _sigma(l) {
    return l.half / 2;
}
// the lump's whole half width: the front starts this far left of the line and ends this far right of what it must cross
function _reach(l) {
    return 4 * _sigma(l);
}
function _trail(mode, l) {
    return mode === "closed" ? l.trail : 0;
}
function _tip(mode, l) {
    return mode === "closed" && l.dotX && l.dotX.length > 0 ? Math.max(l.w, l.dotX[l.dotX.length - 1]) : l.w;
}
function _range(mode, l) {
    return _tip(mode, l) + 2 * _reach(l) + _trail(mode, l);
}
// the front's trip, ms: the live line's takes travelMs, the closed face's longer in proportion (one speed)
function _travel(mode, l) {
    return l.travelMs * _range(mode, l) / (l.w + 2 * _reach(l));
}
function _ease(u) {
    return O.inOutQuad(O.clamp01(u));
}
// inverse of inOutQuad
function _unease(p) {
    p = O.clamp01(p);
    return p < 0.5 ? Math.sqrt(p / 2) : 1 - Math.sqrt((1 - p) / 2);
}
function _style(mode, style) {
    return mode === "closed" ? "ripple" : style;
}
function _hasRipple(mode, style) {
    return _style(mode, style) !== "arrow";
}
function _hasArrow(mode, style) {
    return mode !== "closed" && style !== "ripple";
}
// when the arrow starts: as the front reaches the line's last point (0 for an arrow alone)
function _arrowAt(mode, style, l) {
    if (!_hasRipple(mode, style))
        return 0;
    return _travel(mode, l) * _unease((l.w + _reach(l)) / _range(mode, l));
}

// how long a play takes, ms
function life(mode, style, look) {
    const l = _look(look);
    let end = _hasRipple(mode, style) ? _travel(mode, l) : 0;
    if (_hasArrow(mode, style))
        end = Math.max(end, _arrowAt(mode, style, l) + l.arrowMs);
    return end;
}

// the front's place (px from the line's left end) at t
function front(t, mode, style, look) {
    const l = _look(look);
    const r = _reach(l);
    return -r + _range(mode, l) * _ease(t / _travel(mode, l));
}

// the lump at distance d from its middle, 0 beyond its end, and 0 at the end (so it joins)
function _bell(d, l) {
    const u = Math.abs(d) / _sigma(l);
    if (u >= 4)
        return 0;
    const c = S.lump(4);
    return (S.lump(u) - c) / (1 - c);
}
// the wave at x: the first lump, minus the second one `trail` behind (a closed face's S)
function _wave(x, f, mode, l) {
    let v = _bell(x - f, l);
    if (mode === "closed")
        v -= _bell(x - (f - l.trail), l);
    return v;
}

function dy(x, w, t, mode, style, look) {
    const l = _look(look);
    const life0 = life(mode, style, look);
    if (t <= 0 || t >= life0 || !_hasRipple(mode, style))
        return 0;
    const tr = _travel(mode, l);
    if (t >= tr)
        return 0;
    const v = _wave(x, front(t, mode, style, look), mode, l);
    return (mode === "loss" ? 1 : -1) * l.amp * v;
}

// a dot of the closed face: it hops up as the front passes it
function dotHop(xDot, w, t, mode, style, look) {
    const l = _look(look);
    if (mode !== "closed" || t <= 0 || t >= life(mode, style, look))
        return 0;
    const v = _bell(xDot - front(t, mode, style, look), l);
    return -l.hop * v;
}

// the arrow thrown off the tip: { dy: px from where it starts (negative up), alpha, size } or null
function arrow(t, mode, style, look) {
    const l = _look(look);
    if (!_hasArrow(mode, style))
        return null;
    const t0 = _arrowAt(mode, style, l);
    const u = (t - t0) / l.arrowMs;
    if (u <= 0 || u >= 1)
        return null;
    const dir = mode === "loss" ? 1 : -1;
    const a = l.arrowAlpha * Math.min(1, u / 0.15) * (1 - O.inQuad(u));
    return { dy: dir * (l.arrowStart + l.arrowTravel * O.outCubic(u)), alpha: a, size: l.arrowSize, up: dir < 0 };
}

// everything a probe reads at t
function state(t, mode, style, look) {
    const l = _look(look);
    const life0 = life(mode, style, look);
    return {
        life: life0,
        front: front(t, mode, style, look),
        arrow: arrow(t, mode, style, look),
        hops: l.dotX ? l.dotX.map(x => dotHop(x, l.w, t, mode, style, look)) : []
    };
}
