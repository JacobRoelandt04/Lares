.pragma library
.import "../../common/components/GlyphOutline.js" as O

// =============================================================================
// PanoramaPanes.js -- the panorama button's glyph, as one pose: ONE MONITOR of a constant size whose SCREEN is divided by vertical
// gaps into the displays in use (one, two, three; a "+" cut into the last column past three; a mirror mark cut into the first while
// the displays mirror; docs/contracts/panorama.md section 6), with WINDOWS tiled on every screen that carries no mark. Pure functions
// of its state and of the flourish's clock; `frame(...)` is { parts: [pane 1, pane 2, pane 3, stand], shades: [] } as SVG paths for
// PosedGlyph.
//
// There is NO font outline behind it: the glyph is drawn by this file in font units (2048 per em, y up, the pen on the baseline), in
// the box of md-monitor F0379 (advance 1880, ink -238 .. 1466), which the button names as its text so the item keeps that glyph's size
// and place. Everything is a filled shape, never an outline.
//
// THE INK'S BOX IS CONSTANT (`INK`: the one monitor's, x 50 .. 1830, y -25 .. 1253, what the single display always drew). One display
// is that monitor exactly; two and three are its screen cut into columns by gaps of GAP (120 units: 1.05 px at 18 px, 1.32 device px
// at 1.25), the stand one and the same under all of them. The count is a width: pane i has presence p_i (count - i through an OutBack)
// and is p_i * w wide with a gap p_i * g before it, so the columns always sum to the screen's width exactly (n w + (n - 1) g, with
// n the sum of the p_i): a pane comes in by its gap opening inside the box, never by the outline moving, and an overshoot of the
// spring only moves a gap. Heights never change. Nothing is ever drawn outside INK (a probe samples every frame).
//
// THE "+" (`plus`, 0 .. 1): a cross cut out of the last column (negative space), PLUS units across at full size. THE MIRROR MARK
// (`mirror`, 0 .. 1): the two triangles pointing at an axis, cut out of the FIRST column's middle, sized to fit it (it is the display
// that is being shown on the others); its hue is the button's `hueOn`. A hole is only ever cut inside its pane (a hole over a gap
// would be ink under the winding fill).
//
// THE WINDOWS (at rest): each is a tile of ink inside a ring cut out of its screen, the screen's frame and the walls between the rings
// one thickness (`bar`). A screen as wide as the monitor holds a master and a stack of two; a narrower one the stack alone, over its
// whole width (a vertical split of a half or a third of 18 px is bars under a pixel). Both are ONE arrangement, continuous in the
// screen's width: the master's column narrows to nothing as the screen does, so a display that comes or goes moves the windows with
// the gap and nothing is swapped. A RING NEVER OVERLAPS ANOTHER HOLE (two holes over each other are ink under the winding fill; a probe
// holds every sample to it): the stack's lower window is dealt before the one over it, and a mark comes into a screen only once its
// rings have closed (the first MARK_AT of the mark's own ease; the mark itself grows over the rest).
//
// THE FLOURISH: THE DEAL (also the preset's beat). What stands on the screens goes and comes back: the rings close and the screens
// are solid, a beat, then the windows are dealt in again, screen by screen from the left, each dropping in from just above the
// screen's top edge (clipped to the screen, so it comes out of the edge), growing as it comes, its ring around it. A mark says
// something (more than three; mirroring), so it never goes: it dips to 1 - MARK_DIP of its size and springs back. The run is the rest
// picture at both ends (`frame` returns the rest parts at t <= 0 and t >= life).
// =============================================================================

var UNITS = 2048;
// the ink's box (font units): the one monitor. A frame is never outside it.
var INK = { x0: 50, x1: 1830, y0: -25, y1: 1253 };
var X0 = INK.x0, X1 = INK.x1;
// the stand: a bar under the screen and the gap between (the bar is half the screen's width, centred)
var FOOT = 120, NECK = 90;
var SY0 = INK.y0 + FOOT + NECK, SY1 = INK.y1;
// the gap between panes; the "+" and the mirror mark's sizes
var GAP = 120, PLUS = 300, MIRROR_W = 1150, MIRROR_H = 380;
// a screen's windows: the frame's thickness at no width and what the whole monitor's width adds (120 in all, GAP); the master's share
// of a screen's inside, and the screen's widths between which its column comes (two displays' screens have none, one's has it whole)
var BAR = 75, BAR_WIDE = 45, MASTER = 0.55, MASTER_FROM = 880, MASTER_FULL = 1700;
// the share of a mark's ease the rings take to close, and how far a mark dips in the deal
var MARK_AT = 0.4, MARK_DIP = 0.4;
// how far a tile's top stays below the screen's edge it comes out of: its ring ends ON that edge, and the curve renderer loses a contour
// that lies on another's edge (the tile was a bare notch until it had come clear of the top)
var TOUCH = 4;

var DEFAULTS = {
    meltMs: 340,        // the rings closing
    holdMs: 60,         // the screens solid, before the first tile
    paneStagger: 110,   // ms between one pane's deal and the next
    tileStagger: 80,    // ms between one tile and the next in a pane
    flightMs: 300,      // one tile's drop
    spring: 1.1         // the panes' OutBack, and a mark's
};

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}
// the instant the first tile is dealt
function _dealAt(l) {
    return l.meltMs + l.holdMs;
}
// the run's length, from its parts: the rings close, a beat, and the last tile lands (a lone screen's third, or the third screen's second)
function _total(l) {
    return _dealAt(l) + Math.max(2 * l.tileStagger, 2 * l.paneStagger + l.tileStagger) + l.flightMs;
}
var LIFE = _total(DEFAULTS);

// the panes' presence at a count: [p1, p2, p3]
function presence(count, look) {
    const l = _look(look);
    const p = [];
    for (let i = 0; i < 3; ++i)
        p.push(O.outBack(O.clamp01(count - i), l.spring));
    return p;
}

// What is drawn, as numbers (a probe reads them): the panes' rects { x0, y0, x1, y1, r, p } (font units; p the presence).
function layout(s, look) {
    const p = presence(Math.max(1, s.count), look);
    const n = Math.max(1, p[0] + p[1] + p[2]);
    const w = (X1 - X0 - GAP * (n - 1)) / n;
    const panes = [];
    let x = X0;
    for (let i = 0; i < 3; ++i) {
        const gap = i === 0 ? 0 : GAP * p[i];
        const wi = w * p[i];
        panes.push({ x0: x + gap, x1: x + gap + wi, y0: SY0, y1: SY1, r: Math.max(0, Math.min(110, wi / 4, (SY1 - SY0) / 4)), p: p[i] });
        x += gap + wi;
    }
    return { panes: panes, plus: Math.min(1, Math.max(0, s.plus)), mirror: Math.min(1, Math.max(0, s.mirror)), w: w };
}

// the window slots of a screen (their rings' outer edges), in the order they are dealt: { r: [x0, y0, x1, y1], k: its place in the deal }.
// The master (a wide screen's), the stack's lower window, the one over it (header: one arrangement, continuous in the width)
function slots(c) {
    const w = c.x1 - c.x0, b = BAR + BAR_WIDE * w / (X1 - X0);
    const x0 = c.x0 + b, x1 = c.x1 - b, y0 = c.y0 + b, y1 = c.y1 - b;
    const m = O.smooth(MASTER_FROM, MASTER_FULL, w), mw = (x1 - x0 - b) * MASTER;
    const sx = x0 + (mw + b) * m, my = (y0 + y1) / 2;
    const out = [{ r: [sx, y0, x1, my - b / 2], k: m }, { r: [sx, my + b / 2, x1, y1], k: m + 1 }];
    if (m > 0)
        out.unshift({ r: [x0, y0, x0 + mw * m, y1], k: 0 });
    return out;
}

function _box(r, hole) {
    return O.polygon(O.roundRect(r[0], r[1], r[2], r[3], Math.min(40, (r[2] - r[0]) / 4, (r[3] - r[1]) / 4), hole));
}
function _clip(r, c) {
    const a = [Math.max(r[0], c.x0), Math.max(r[1], c.y0), Math.min(r[2], c.x1), Math.min(r[3], c.y1)];
    // under 12 units (a tenth of a pixel at 18 px) is nothing yet: a tile comes into being at that size, never as a speck
    return a[2] - a[0] > 12 && a[3] - a[1] > 12 ? a : null;
}

// the "+" as ONE reverse-wound contour (a hole), centred in c
function _plusHole(c, f) {
    const size = PLUS * f;
    if (size < 8)
        return [];
    const a = size / 2, t = size * 0.2, x = (c.x0 + c.x1) / 2, y = (c.y0 + c.y1) / 2;
    return [O.polygon([[x - t, y + a], [x + t, y + a], [x + t, y + t], [x + a, y + t], [x + a, y - t], [x + t, y - t], [x + t, y - a],
                       [x - t, y - a], [x - t, y - t], [x - a, y - t], [x - a, y + t], [x - t, y + t]].reverse())];
}

// the mirror mark as holes (the axis bar and the two triangles, ▶|◀), centred in c, scaled to fit the pane and by `f`
function _mirrorHole(c, f) {
    const k = Math.min(1, 0.8 * (c.x1 - c.x0) / MIRROR_W) * f;
    if (k * MIRROR_H < 8)
        return [];
    const hh = MIRROR_H * k / 2, tw = 420 * k, gap = 80 * k, bw = 150 * k;
    const x = (c.x0 + c.x1) / 2, y = (c.y0 + c.y1) / 2;
    const lx = x - bw / 2 - gap, rx = x + bw / 2 + gap;
    return [O.polygon([[x - bw / 2, y + hh], [x + bw / 2, y + hh], [x + bw / 2, y - hh], [x - bw / 2, y - hh]].reverse()),
            O.polygon([[lx - tw, y + hh], [lx, y], [lx - tw, y - hh]].reverse()),
            O.polygon([[rx + tw, y - hh], [rx, y], [rx + tw, y + hh]].reverse())];
}

// pane i's windows at the run's clock x (ms; 0 the rest), their rings open by `open`: [{ hole, tile }], one per window that shows (its
// ring is open and has come into the screen); `tile` is null while only its ring has
function windows(c, i, x, open, l) {
    const out = [];
    const t0 = _dealAt(l), dealt = x >= t0;
    const share = dealt ? open : open * (1 - O.smooth(0, l.meltMs, x));
    for (const sl of slots(c)) {
        const s = sl.r;
        const w = s[2] - s[0], h = s[3] - s[1];
        const inset = Math.min(GAP, 0.25 * Math.min(w, h)), ring = inset * share;
        const ts = t0 + l.paneStagger * i + l.tileStagger * sl.k;
        const u = dealt ? O.outCubic(O.seg(x, ts, ts + l.flightMs)) : 1;
        if (ring < 1 || u <= 0)
            continue;
        const sc = 0.55 + 0.45 * u;
        const hw = (w / 2 - inset) * sc, hh = (h / 2 - inset) * sc;
        // it starts just above the screen's top edge (its ring too, so nothing shows at the first instant) and comes down to its slot
        const cy1 = (s[1] + s[3]) / 2, cy0 = c.y1 + (h / 2 - inset) * 0.55 + inset;
        const cx = (s[0] + s[2]) / 2, cy = cy1 + (cy0 - cy1) * (1 - u);
        const hole = _clip([cx - hw - ring, cy - hh - ring, cx + hw + ring, cy + hh + ring], c);
        if (hole)
            out.push({ hole: hole, tile: _clip([cx - hw, cy - hh, cx + hw, Math.min(cy + hh, c.y1 - TOUCH)], c) });
    }
    return out;
}

// a mark's size at the run's clock: whole at both ends, dipped while the screens are clear (it is never gone: a mark is a fact)
function _dip(x, l) {
    const t0 = _dealAt(l);
    return 1 - MARK_DIP * (O.smooth(0, l.meltMs, x) - O.outBack(O.seg(x, t0, t0 + l.flightMs), l.spring));
}

// What is on the screens at the run's clock x, as numbers (a probe reads them): per pane { pane, mark (0 .. 1, its size), kind ("+",
// "mirror" or ""), windows: [{ hole, tile }] }
function screens(s, x, look) {
    const l = _look(look);
    const L = layout(s, look);
    return L.panes.map((c, i) => {
        const m = i === 2 ? L.plus : (i === 0 ? L.mirror : 0);
        return {
            pane: c,
            kind: m > 0 ? (i === 2 ? "+" : "mirror") : "",
            mark: O.seg(m, MARK_AT, 1) * _dip(x, l),
            windows: windows(c, i, x, 1 - O.seg(m, 0, MARK_AT), l)
        };
    });
}

// the stand: ONE foot under every count
function _stand() {
    const mid = (X0 + X1) / 2, fw = (X1 - X0) * 0.25;
    return [O.polygon(O.roundRect(mid - fw, INK.y0, mid + fw, INK.y0 + FOOT, 40, false))];
}

// a pane's contours: the screen rounded (a hole needs an outer to cut), its mark's holes, and its windows (a ring's hole, the tile in it)
function _pane(p) {
    const c = p.pane;
    if (c.x1 - c.x0 < 1)
        return [];
    const cs = [O.polygon(O.roundRect(c.x0, c.y0, c.x1, c.y1, c.r, false))];
    if (p.mark > 0)
        cs.push.apply(cs, p.kind === "+" ? _plusHole(c, p.mark) : _mirrorHole(c, p.mark));
    for (const w of p.windows) {
        cs.push(_box(w.hole, true));
        if (w.tile)
            cs.push(_box(w.tile, false));
    }
    return cs;
}

// { parts: [pane 1, pane 2, pane 3, stand], shades: [] } for the state `s` and the flourish's clock (`t` null / <= 0 / >= life: the
// rest picture, returned as such)
function frame(s, t, life, look, px, ox, oy) {
    const k = px / UNITS;
    const l = _look(look);
    const run = t !== null && t !== undefined && t > 0 && t < life;
    const x = run ? t * _total(l) / Math.max(1, life) : 0;
    const parts = screens(s, x, look).map(p => O.emit(_pane(p), O.same, k, ox, oy));
    parts.push(O.emit(_stand(), O.same, k, ox, oy));
    return { parts: parts, shades: [] };
}

// the picture at both ends of a run (a probe compares)
function rest(s, px, ox, oy) {
    return frame(s, 0, 1, null, px, ox, oy);
}
