.pragma library
.import "../../common/components/GlyphOutline.js" as O
.import "NoteParts.js" as P

// =============================================================================
// NotePeelPose.js -- the note's flourish (feedback/notes.md "Bar icon flourish"): THE TOP SHEET IS PEELED OFF THE BLOCK.
// Pure functions of its clock (GlyphFlourish `t`, ms): `frame(t, life, look, px, ox, oy)` is the picture at run time t as
// { parts: [four SVG paths], shades: [their ink shares] } for PosedGlyph.
//
// The glyph is a square sheet whose bottom-right corner is folded up and over itself: the sheet with a square NOTCH at that
// corner, and in the notch the FLAP, the corner mirrored in the fold line (a 45 degree line: both its ends are the flap's
// sharp tips), a gap of ink apart. Everything here is that picture at another fold: `L` is the flap's leg (473 font units at
// rest), the notch is the flap's box plus the gap, the flap is the font's own flap scaled about the sheet's corner.
//
//   the peel     something pulls the folded corner up and to the left: the fold line travels across the sheet, slower and
//                slower as the paper tightens, until only an L of the sheet still lies flat (`peelL`)
//   the block    AT REST THERE IS NO BLOCK: the triangle the fold uncovers shows the bar, a single clean note. The moment the
//                peel starts the next sheet RISES IN from just behind (a little smaller, growing to full size from the far
//                corner, fading in over its first moments) and fills the uncovered triangle with paper -- in a paler ink
//                (`shade`), so it reads as a sheet further down and never as part of the one being peeled
//   the snap     the sheet lets go of the block, all at once: it leaves at full speed (the peel had all but stopped), its fold
//                springs most of the way open (`flyL`), and it flies in the pull's direction, up and to the left, against
//                gravity (an arc that flattens), turning a little and tipping BACK: it recedes, so it shrinks toward a point
//                and is gone
//   the new note the sheet underneath is the icon now: as the old one is about to vanish it darkens to the full ink and folds
//                its own corner over (a little too far, then back), and the run ends on the font's outline exactly
//
// The first frame is the font's outline too (the top sheet at its rest fold, the next sheet at no ink), so the swap with the
// plain glyph shows nothing at either end. One ink: the shades are shares of the glyph's colour, which the host keeps (a hover
// hue, the theme) -- nothing here knows a colour.
// =============================================================================

// The motion's numbers; times in ms of a `life` of 1250 (another life scales them). A caller may hand overrides (`look`).
var DEFAULTS = {
    peelMs: 470,      // the peel, to the snap
    peelL: 1290,      // the flap's leg at the snap, font units (the sheet's side is 1654; past 1300 the notch leaves the sheet)
    riseMs: 220,      // the next sheet's rise
    riseFrom: 0.92,   // its size when it starts, about the sheet's far (top-left) corner
    inkMs: 140,       // its fade in
    shade: 0.5,       // the next sheet's share of the ink while it is the sheet underneath
    flyMs: 540,       // the flight, from the snap
    flyX: -980,       // where the flying sheet's middle ends, font units from where it lay (left, up)
    flyY: 1100,
    sag: 330,         // how far gravity has pulled it back down by the end
    turn: 26,         // deg, counter-clockwise: the pulled corner leads
    tip: 58,          // deg it tips back about the fold's direction (foreshortened along the pull)
    far: 1.5,         // how far back it goes: its size is 1 / (1 + far * x), and the last third takes it to nothing
    flyL: 1010,       // the leg its fold springs back to
    springMs: 320,    // over this long
    darkAt: 800,      // the new note takes the full ink from here
    darkMs: 330,
    earAt: 850,       // and folds its corner from here to the end
    earBack: 1.9      // the fold's overshoot (OutBack's s)
};
var LIFE = 1250;

// the sheet's box, its bottom-right corner (the one that folds), its middle, the rest fold and the rest gap
var X1 = 1654, Y0 = -213, Y1 = 1441;
var REST_L = 473, REST_GAP = 118, NOTCH_R = 178;
var MID = [827, 614];

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}

// The sheet with its notch for a flap of leg L and a gap g: the font's own contour, its notch (segments 4..8) rebuilt.
// At L = 473, g = 118 every number is the font's. No fold (L + g under a unit): the plain square, its corner sharp.
function sheet(L, g) {
    const c = P.sheet[0];
    const n = L + g;
    const out = c.slice(0, 4);
    if (n < 1) {
        out.push(["L", X1, Y0]);
    } else {
        const r = Math.min(NOTCH_R, 0.35 * n);
        const nx = X1 - n, ny = Y0 + n;
        const q = r * 104 / NOTCH_R;
        out.push(["L", X1, ny]);
        out.push(["L", nx + r, ny]);
        out.push(["Q", nx + q, ny, nx + q / 2, ny - q / 2]);
        out.push(["Q", nx, ny - q, nx, ny - r * 177 / NOTCH_R]);
        out.push(["L", nx, Y0]);
    }
    for (let i = 9; i < c.length; ++i)
        out.push(c[i]);
    return [out];
}

// the font's flap scaled about the sheet's corner to a leg of L
function flapMap(L) {
    const f = L / REST_L;
    return function (x, y) {
        return [X1 + (x - X1) * f, Y0 + (y - Y0) * f];
    };
}

// the peel's progress: from a standstill, then slower and slower into the threshold (the paper tightens)
function _peel(x) {
    const t = O.clamp01(x);
    return 1 - Math.pow(1 - Math.pow(t, 1.6), 2.0);
}

// the flying sheet's map at x = 0..1 of its flight: turned and tipped about its middle, shrunk, carried along its arc
function _fly(x, l) {
    const go = O.outQuad(x);
    const a = l.turn * Math.PI / 180 * go;
    const tipc = Math.cos(l.tip * Math.PI / 180 * go);
    const k = (1 - O.smooth(0.6, 1, x)) / (1 + l.far * x);
    const dx = l.flyX * go, dy = l.flyY * go - l.sag * x * x;
    const ca = Math.cos(a), sa = Math.sin(a);
    // the pull's direction, up and to the left: what the tip foreshortens
    const ux = -Math.SQRT1_2, uy = Math.SQRT1_2;
    return function (px, py) {
        let x0 = px - MID[0], y0 = py - MID[1];
        const along = (x0 * ux + y0 * uy) * (tipc - 1);
        x0 += ux * along;
        y0 += uy * along;
        return [MID[0] + dx + (ca * x0 - sa * y0) * k, MID[1] + dy + (sa * x0 + ca * y0) * k];
    };
}

// what the run is doing at t, as numbers (a probe reads them; `frame` draws them)
//   topL       the top sheet's fold while it lies on the block (-1 once it flies)
//   fly        0..1 through the flight (-1 before the snap, 2 once it is gone)
//   flyL       the flying sheet's fold
//   under      the next sheet's ink share; underScale its size; underL, underGap its own fold
function state(t, life, look) {
    const l = _look(look);
    const s = Math.max(1, life) / LIFE;
    const x = t / s;
    const st = { topL: -1, fly: -1, flyL: 0, under: 0, underScale: 1, underL: 0, underGap: 0 };
    st.under = l.shade * O.smooth(0, l.inkMs, x);
    st.underScale = l.riseFrom + (1 - l.riseFrom) * O.outCubic(x / l.riseMs);
    if (x < l.peelMs) {
        st.topL = REST_L + (l.peelL - REST_L) * _peel(x / l.peelMs);
        return st;
    }
    const f = (x - l.peelMs) / l.flyMs;
    st.fly = f >= 1 ? 2 : f;
    st.flyL = l.flyL + (l.peelL - l.flyL) * (1 - O.outBack((x - l.peelMs) / l.springMs, 1.4));
    st.under = l.shade + (1 - l.shade) * O.smooth(l.darkAt, l.darkAt + l.darkMs, x);
    const e = O.outBack(O.seg(x, l.earAt, LIFE), l.earBack);
    st.underL = REST_L * e;
    st.underGap = REST_GAP * O.smooth(0, 0.6, e);
    return st;
}

// { parts: [the sheet underneath, its flap, the top sheet, its flap], shades: [..] } at run time t
function frame(t, life, look, px, ox, oy) {
    const l = _look(look);
    const st = state(t, life, l);
    const k = px / P.UNITS;
    const parts = ["", "", "", ""];
    if (st.fly < 0) {
        // on the block: the top sheet at its fold, and the next sheet where the fold uncovers it -- the triangle between the
        // corner and the fold line, cut from the rising sheet (scaled about the far corner, so its own corner travels in)
        const L = st.topL;
        if (st.under > 0) {
            const cx = (X1 - 0) * st.underScale, cy = Y1 + (Y0 - Y1) * st.underScale;
            // the fold line is (X1 - x) + (y - Y0) = L
            const fy = Y0 + L - (X1 - cx), fx = X1 + (cy - Y0) - L;
            if (fy > cy && fx < cx)
                parts[0] = O.emit([O.polygon([[cx, fy], [cx, cy], [fx, cy]])], O.same, k, ox, oy);
        }
        parts[2] = O.emit(sheet(L, REST_GAP), O.same, k, ox, oy);
        parts[3] = O.emit(P.flap, flapMap(L), k, ox, oy);
    } else {
        // the block's next sheet, whole, and its own fold once it starts
        parts[0] = O.emit(sheet(st.underL, st.underGap), O.same, k, ox, oy);
        if (st.underL >= 1)
            parts[1] = O.emit(P.flap, flapMap(st.underL), k, ox, oy);
        if (st.fly <= 1) {
            const fly = _fly(st.fly, l);
            const fm = flapMap(st.flyL);
            parts[2] = O.emit(sheet(st.flyL, REST_GAP), fly, k, ox, oy);
            parts[3] = O.emit(P.flap, function (x, y) {
                const p = fm(x, y);
                return fly(p[0], p[1]);
            }, k, ox, oy);
        }
    }
    return { parts: parts, shades: [st.under, st.under, 1, 1] };
}

// the font's outline as `frame` would emit it: what its first and last instants must be (a probe compares)
function rest(px, ox, oy) {
    const k = px / P.UNITS;
    return [O.emit(P.sheet, O.same, k, ox, oy), O.emit(P.flap, O.same, k, ox, oy)];
}
