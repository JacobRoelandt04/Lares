.pragma library
.import "../../../common/components/GlyphOutline.js" as O
.import "ArchiveParts.js" as P

// =============================================================================
// ArchivePose.js -- the archive box's flourish (feedback/system_update.md "The bar icon flourish"): the lid comes off while two
// papers rise out of the box, staggered in place and in time. Snappy, playful, bouncy. Pure functions of the clock's u (0..1).
//
//   state(u, look)                     where every part stands at u: { lid: {dx, dy, rot}, a: {f, rot}, b: {f, rot} }
//   compose(st, look, px, ox, oy)      that state as SVG paths: [paper a, paper b, box, lid] (back to front)
//
// THE MOTION, in shares of the clock:
//   0    - 0.18   the lid is TOSSED: up a long way (`rise`, ~6 px at 16 px), tipping (`tip`) and drifting (`drift`), and it
//                  overshoots its height a little (OutBack): that is the snap
//   0.04 - 0.24   paper a shoots up out of the box, left of the middle, leaning left; overshoots and settles (`aRise`)
//   0.13 - 0.32   paper b, right of the middle, later and lower, leaning right (`bRise`)
//   ...    0.55   the lid floats (a bob, a wobble), the papers sway
//   0.50 - 0.72   the papers drop back in, a first then b, gathering speed
//   0.55 - 0.76   the lid falls (gravity: InQuad), squaring up as it comes
//   0.76 - 1      it bounces twice on the box and is still
// The papers are never drawn below the rim: what is inside the box is behind its front, so a paper is cut where it enters it
// (60 font units under the rim, inside the box's ink: two antialiased edges meeting on one line would leave a light seam). A
// paper is a sheet: a rounded rectangle with `lines` lines of text cut out of it. At u = 0 and u = 1 nothing has moved and
// no paper shows: the font's own outline, so the swap with the plain glyph shows nothing.
//
// `compose` takes any state, so a sequence of held poses (the per-step storyboard, tools/dev/qml/glyph_flourish_strip.qml) is
// drawn by the same code as the flourish. `st.box` (optional: {dx, dy, rot} about the box's foot) moves the whole glyph.
// =============================================================================

var DEFAULTS = {
    rise: 820,        // the lid's toss, font units (2048 an em: 6.4 px at 16 px)
    tip: -11,         // deg, the lid's tip at the top of the toss (clockwise: its right end down)
    drift: 80,        // font units right
    bob: 36,          // the float's bob, font units
    wobble: 3,        // deg
    bounce: 130,      // the first bounce's height, font units
    bounce2: 36,
    aRise: 700,       // paper a: how far it shows above the rim, font units
    aTip: -8,
    bRise: 480,       // paper b
    bTip: 10,
    lines: 1          // lines of text cut out of each paper (0, 1, 2)
};

var TOP = 969;                       // the box's rim
var LID_MID = [945, 1264];
var FOOT = [945, -213];
var PAPER_A = { cx: 640, w: 460, h: 1000 };
var PAPER_B = { cx: 1300, w: 430, h: 900 };
var HIDE = 80;                       // a paper at rest stands this far under the rim
var CUT = TOP - 60;                  // where a paper is cut: inside the box's ink

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}

// a paper's rise share (0 hidden .. 1 risen, more while it overshoots): up with a spring, a sway, down with gravity
function _paper(u, up0, up1, down0, down1, phase) {
    if (u <= up0 || u >= down1)
        return 0;
    if (u < up1)
        return O.outBack(O.seg(u, up0, up1), 2.2);
    if (u < down0)
        return 1 + 0.06 * Math.sin(2 * Math.PI * (O.seg(u, up1, down0) + phase)) * Math.sin(Math.PI * O.seg(u, up1, down0));
    return 1 - O.inQuad(O.seg(u, down0, down1));
}

function state(u, look) {
    const l = _look(look);
    const lid = { dx: 0, dy: 0, rot: 0 };
    if (u > 0 && u < 1) {
        if (u < 0.18) {
            const e = O.outBack(O.seg(u, 0, 0.18), 1.4);
            lid.dy = l.rise * e;
            lid.rot = l.tip * e;
            lid.dx = l.drift * O.outCubic(O.seg(u, 0, 0.18));
        } else if (u < 0.55) {
            const f = O.seg(u, 0.18, 0.55);
            lid.dy = l.rise + l.bob * Math.sin(2 * Math.PI * 1.5 * f);
            lid.rot = l.tip + l.wobble * Math.sin(2 * Math.PI * f);
            lid.dx = l.drift;
        } else if (u < 0.76) {
            const f = O.seg(u, 0.55, 0.76);
            lid.dy = l.rise * (1 - O.inQuad(f));
            lid.rot = l.tip * (1 - O.smooth(0, 1, f));
            lid.dx = l.drift * (1 - O.smooth(0, 1, f));
        } else if (u < 0.92) {
            const f = O.seg(u, 0.76, 0.92);
            lid.dy = l.bounce * 4 * f * (1 - f);
        } else {
            const f = O.seg(u, 0.92, 1);
            lid.dy = l.bounce2 * 4 * f * (1 - f);
        }
    }
    const fa = _paper(u, 0.04, 0.24, 0.50, 0.68, 0);
    const fb = _paper(u, 0.13, 0.32, 0.55, 0.72, 0.35);
    return {
        lid: lid,
        a: { f: fa, rot: l.aTip * Math.min(1, fa) },
        b: { f: fb, rot: l.bTip * Math.min(1, fb) }
    };
}

// one paper at rise share f (its top `rise` above the rim at f = 1), leaning `rot` deg about where it meets the rim, cut
// at CUT: [sheet, its text lines (holes)] as polygons, the empty ones dropped
function _sheet(p, f, rise, rot, lines) {
    const top = TOP - HIDE + (rise + HIDE) * f;
    if (top <= CUT + 1)
        return [];
    const a = rot * Math.PI / 180;
    const lean = function (q) {
        return O.turn(q[0], q[1], p.cx, TOP, a);
    };
    const out = [];
    const sheet = O.clipAbove(O.roundRect(p.cx - p.w / 2, top - p.h, p.cx + p.w / 2, top, 70, false).map(lean), CUT);
    if (sheet.length >= 3)
        out.push(O.polygon(sheet));
    for (let i = 0; i < lines; ++i) {
        const y1 = top - 200 - 190 * i;
        const hole = O.clipAbove(O.roundRect(p.cx - p.w / 2 + 110, y1 - 90, p.cx + p.w / 2 - 110, y1, 40, true).map(lean), CUT);
        if (hole.length >= 3)
            out.push(O.polygon(hole));
    }
    return out;
}

function compose(st, look, px, ox, oy) {
    const l = _look(look);
    const k = px / P.UNITS;
    const box = st.box || { dx: 0, dy: 0, rot: 0 };
    const ba = (box.rot || 0) * Math.PI / 180;
    const whole = function (q) {
        const r = O.turn(q[0], q[1], FOOT[0], FOOT[1], ba);
        return [r[0] + (box.dx || 0), r[1] + (box.dy || 0)];
    };
    const flat = function (x, y) {
        return whole([x, y]);
    };
    const lr = st.lid.rot * Math.PI / 180;
    const lid = function (x, y) {
        const r = O.turn(x, y, LID_MID[0], LID_MID[1], lr);
        return whole([r[0] + st.lid.dx, r[1] + st.lid.dy]);
    };
    return [O.emit(_sheet(PAPER_A, st.a.f, l.aRise, st.a.rot, l.lines), flat, k, ox, oy),
            O.emit(_sheet(PAPER_B, st.b.f, l.bRise, st.b.rot, l.lines), flat, k, ox, oy),
            O.emit(P.body, flat, k, ox, oy),
            O.emit(P.lid, lid, k, ox, oy)];
}

function path(u, look, px, ox, oy) {
    return compose(state(u, look), look, px, ox, oy);
}
