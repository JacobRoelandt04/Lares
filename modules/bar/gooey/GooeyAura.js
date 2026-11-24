.pragma library

// =============================================================================
// GooeyAura.js -- the pure part of THE AURA (GooeyEngine.playAura; gooey_field.frag, THE AURA): the palettes, the groups' words, the
// envelope. No Qt in here.
//
//   paletteOf(name, accent)   four { r, g, b } (0 .. 1) round a cycle, or null for a word that is no palette
//   PALETTES                  the words
//   modeOf(word)              the group word -> the shader's mode (0 all, 1 the island group alone, 2 the rest), -1 unknown
//   groupShare(mode)          the ink a mode shows of each group: [the island group's, the rest's] (0 [1, 1], 1 [1, 0], 2 [0, 1])
//   ease(x)                   a hand-over's ease: smoothstep of x clamped to 0 .. 1
//   level(clock, attack, life, release)   the envelope, 0 .. 1, of a clock in ms (smoothstep in, hold, smoothstep out)
//   clockOfLevel(level, attack)           the clock on the way in at which the envelope is `level` (a play that replaces a play)
//   sameColors(a, b)                      two palettes ({ r, g, b } each) the same, to the byte
//   mixColors(a, b, f)                    palette a eased into palette b, f 0 .. 1 (a smoothstep of it): a palette handed over
//   cycles(perimeter, wavelength)         whole waves round a perimeter (at least 1), so the palette closes on itself
//   groups(bodies, islandIds, screen)     a layout's bodies into the loops: { a, c: the indices of the island group and of the chain, chain: the chain's id,
//                                         ref: { a, b, c } (b the frame's: the rest), each ref a loop's rectangle and middle ({ x0, y0, x1, y1, cx, cy };
//                                         null with no body of any area), join: { a, c } each loop's JOIN with the frame (joinOf) }
//   perimeterOf(ref)                      the length round a loop's rectangle
//   perimAt(x, y, ref)                    where a point stands round a loop, 0 .. 1 (gooey_field.frag auraPerim, its twin)
//   joinOf(loop, frame, ref, refFrame, screen)   THE JOIN (below): a loop's free arc between two junctions with the frame, or null
//   joinVec(join, cycles, cyclesFrame, extra)    the shader's auraJoin lane for it: [s_a, +-share, U_a, U_b] (a plain loop: [0, 1, 0, cycles])
//   extraWaves(join, cyclesFrame, wavelength)    whole waves to add round a joined loop's free arc, counted as the loop comes
// =============================================================================

// The words are fixed hues except `accent`, the theme's own family. #rrggbb.
var FIXED = {
    // iOS's colours: blue, violet, pink, orange
    siri: ["#3A7BFF", "#A25BFF", "#FF5BAE", "#FF9A3C"],
    ok: ["#44C145", "#00BEC4", "#7DE08A", "#2FA37A"],
    warn: ["#F0AA0B", "#FF6D12", "#FFD34C", "#F0642F"],
    error: ["#EC0000", "#F14C4C", "#FF6D12", "#C838C6"],
    cool: ["#4480F4", "#00BEC4", "#8A6CF0", "#4D91F8"]
};
var PALETTES = ["accent"].concat(Object.keys(FIXED));

function _hex(h) {
    return { r: parseInt(h.slice(1, 3), 16) / 255, g: parseInt(h.slice(3, 5), 16) / 255, b: parseInt(h.slice(5, 7), 16) / 255 };
}

function _hsl(c) {
    var mx = Math.max(c.r, c.g, c.b), mn = Math.min(c.r, c.g, c.b), l = (mx + mn) / 2, h = 0, s = 0;
    if (mx !== mn) {
        var d = mx - mn;
        s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
        if (mx === c.r)
            h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0);
        else if (mx === c.g)
            h = (c.b - c.r) / d + 2;
        else
            h = (c.r - c.g) / d + 4;
        h /= 6;
    }
    return { h: h, s: s, l: l };
}

function _rgb(h, s, l) {
    h = h - Math.floor(h);
    var q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q;
    function f(t) {
        t = t - Math.floor(t);
        if (t < 1 / 6)
            return p + (q - p) * 6 * t;
        if (t < 1 / 2)
            return q;
        if (t < 2 / 3)
            return p + (q - p) * (2 / 3 - t) * 6;
        return p;
    }
    return { r: f(h + 1 / 3), g: f(h), b: f(h - 1 / 3) };
}

// `accent` is { r, g, b } (the theme's accent). The family: the accent and three neighbours on the wheel, each made at least as vivid
// as 0.7 and no darker than 0.55 / lighter than 0.68, so a dim theme accent still lights a halo.
function paletteOf(name, accent) {
    var w = String(name || "").toLowerCase();
    if (w === "accent") {
        var a = _hsl(accent || { r: 0.27, g: 0.5, b: 0.96 });
        var s = Math.max(a.s, 0.7), l = Math.min(0.68, Math.max(0.55, a.l));
        return [0, -0.07, 0.09, 0.17].map(function (dh) { return _rgb(a.h + dh, s, l); });
    }
    return FIXED.hasOwnProperty(w) ? FIXED[w].map(_hex) : null;
}

function modeOf(word) {
    var w = String(word || "all").toLowerCase();
    if (w === "" || w === "all" || w === "both")
        return 0;
    if (w === "island" || w === "islands" || w === "centre" || w === "center" || w === "c")
        return 1;
    if (w === "side" || w === "sides" || w === "slim" || w === "frame")
        return 2;
    return -1;
}

function _smooth(x) {
    x = Math.max(0, Math.min(1, x));
    return x * x * (3 - 2 * x);
}

function ease(x) {
    return _smooth(x);
}

// One frozen array per mode: a settled group hands the field the same object on every frame, so its handler does not run again.
var GROUP_SHARES = [Object.freeze([1, 1]), Object.freeze([1, 0]), Object.freeze([0, 1])];

function groupShare(mode) {
    return GROUP_SHARES[mode === 1 || mode === 2 ? mode : 0];
}

function level(clock, attack, life, release) {
    if (clock <= 0)
        return 0;
    if (clock < attack)
        return _smooth(clock / attack);
    if (clock < attack + life)
        return 1;
    return _smooth(1 - (clock - attack - life) / release);
}

// The inverse of the way in: smooth(x) = y  =>  x = 0.5 - sin(asin(1 - 2y) / 3).
function clockOfLevel(lv, attack) {
    var y = Math.max(0, Math.min(1, lv));
    return attack * (0.5 - Math.sin(Math.asin(1 - 2 * y) / 3));
}

function _byte(v) {
    return Math.round(255 * v);
}

function sameColors(a, b) {
    if (!a || !b || a.length !== b.length)
        return false;
    for (var i = 0; i < a.length; i++)
        if (_byte(a[i].r) !== _byte(b[i].r) || _byte(a[i].g) !== _byte(b[i].g) || _byte(a[i].b) !== _byte(b[i].b))
            return false;
    return true;
}

function mixColors(a, b, f) {
    if (!a || !b || a.length !== b.length)
        return b;
    var s = _smooth(f);
    return b.map(function (c, i) {
        return { r: a[i].r + (c.r - a[i].r) * s, g: a[i].g + (c.g - a[i].g) * s, b: a[i].b + (c.b - a[i].b) * s };
    });
}

function cycles(perimeter, wavelength) {
    return Math.max(1, Math.round(perimeter / wavelength));
}

// Px^2 of popup at which a loop's middle has gone from its rectangle's centre to its popups': the middle is the coordinate's only singular point
// (gooey_field.frag, COORDINATE), so it stands deep in a popup that is big enough to have a halo near it, and it moves there
// continuously as one opens.
var POPUP_AREA = 40000;

function _area(b) {
    return (b.x1 - b.x0) * (b.y1 - b.y0);
}

// The rectangle round a loop's bodies and its middle. `popups`: the middle follows the area's centre of its popups (the frame's stays the rectangle's: what
// hangs in its loop is small, and a halo never comes near the screen's middle).
function _ref(list, popups) {
    var r = null;
    var pops = { a: 0, x: 0, y: 0 };
    for (var i = 0; i < list.length; i++) {
        var b = list[i];
        var area = _area(b);
        if (!(area > 0))
            continue;
        if (!r)
            r = { x0: b.x0, y0: b.y0, x1: b.x1, y1: b.y1, cx: 0, cy: 0 };
        r.x0 = Math.min(r.x0, b.x0);
        r.y0 = Math.min(r.y0, b.y0);
        r.x1 = Math.max(r.x1, b.x1);
        r.y1 = Math.max(r.y1, b.y1);
        if (b.mobile) {
            pops.a += area;
            pops.x += area * (b.x0 + b.x1) / 2;
            pops.y += area * (b.y0 + b.y1) / 2;
        }
    }
    if (!r)
        return null;
    var k = popups && pops.a > 0 ? _smooth(pops.a / POPUP_AREA) : 0;
    r.cx = (1 - k) * (r.x0 + r.x1) / 2 + (k > 0 ? k * pops.x / pops.a : 0);
    r.cy = (1 - k) * (r.y0 + r.y1) / 2 + (k > 0 ? k * pops.y / pops.a : 0);
    return r;
}

// A body hangs from its root: a secondary has no bar of its own, and the stack hung from a popup's foot is that popup's (`parent`). The island group is the
// island's bars and every chain whose root hangs from one (`host`); of the chains left, the one with the most area is the third loop.
function groups(bodies, islandIds, screen) {
    var isle = {}, byId = {};
    for (var i = 0; i < islandIds.length; i++)
        isle["bar:" + islandIds[i]] = true;
    for (var j = 0; j < bodies.length; j++)
        byId[bodies[j].id] = bodies[j];
    function rootOf(b) {
        for (var n = 0; n < bodies.length && b.parent && byId[b.parent]; n++)
            b = byId[b.parent];
        return b;
    }
    var a = [], rest = [], areas = {};
    var chain = "", most = 0;
    for (var k = 0; k < bodies.length; k++) {
        var b = bodies[k], root = rootOf(b);
        if (isle[root.id] === true || isle[root.host] === true) {
            a.push(k);
            continue;
        }
        rest.push(k);
        if (!b.mobile)
            continue;
        areas[root.id] = (areas[root.id] || 0) + Math.max(0, _area(b));
        if (areas[root.id] > most) {
            most = areas[root.id];
            chain = root.id;
        }
    }
    var c = [], inB = [];
    for (var m = 0; m < rest.length; m++) {
        if (chain !== "" && bodies[rest[m]].mobile && rootOf(bodies[rest[m]]).id === chain)
            c.push(rest[m]);
        else
            inB.push(bodies[rest[m]]);
    }
    var listA = a.map(function (x) { return bodies[x]; }), listC = c.map(function (x) { return bodies[x]; });
    var ref = { a: _ref(listA, true), b: _ref(inB, false), c: _ref(listC, true) };
    return { a: a, c: c, chain: chain, ref: ref,
             join: { a: joinOf(listA, inB, ref.a, ref.b, screen), c: joinOf(listC, inB, ref.c, ref.b, screen) } };
}

function perimeterOf(ref) {
    return ref ? 2 * (ref.x1 - ref.x0 + ref.y1 - ref.y0) : 0;
}

// ---- THE JOIN (gooey_field.frag, THE JOIN) ------------------------------------------------------------------------------------------
// Each loop's hue runs round its own rectangle, and where two loops meet the pixel's colour hands over from one to the other over 20 px.
// Where a loop's bodies TOUCH the frame's -- the chain's popup hanging from a slim bar or an island of the frame (the OSD on the right bar,
// a toast stack under an island), the island group's continuous bar on the side bars -- the two hues are unrelated, and the hand-over
// draws a seam out of each junction (the user, round 5: "the aura around it, especially in the corners, has some visible seams"). So
// a joined loop takes the FRAME's hue at its two junctions and runs between them round its FREE arc (the part of its outline that
// touches neither the frame nor the screen's edge), the way the outline of the whole surface does: down the bar, round the popup, back
// on the bar. Its waves flow on from the bar's (U rises from the junction the frame's coordinate comes from), a whole number of its
// own may be added round the arc, and the arc it rests on (hidden under the bars) closes the loop.

// The shader's auraAlong: a point ON a rectangle's outline (b from its centre, h its half size), 0 .. 1 clockwise from the top-left
// corner. The same comparisons in the same order, so a corner falls on the same face.
function _along(bx, by, hx, hy) {
    var dT = by + hy, dR = hx - bx, dB = hy - by, dL = bx + hx;
    var m = Math.min(Math.min(dT, dR), Math.min(dB, dL));
    var s;
    if (m === dT)
        s = bx + hx;
    else if (m === dR)
        s = 2 * hx + dT;
    else if (m === dB)
        s = 2 * hx + 2 * hy + dR;
    else
        s = 4 * hx + 2 * hy + dB;
    return s / (4 * (hx + hy));
}

// The shader's auraPerim (header, COORDINATE): outside the rectangle its nearest point on the outline, inside it the point where the
// ray from the loop's middle through p leaves it.
function perimAt(px, py, r) {
    var hx = Math.max(0.5 * (r.x1 - r.x0), 0.5), hy = Math.max(0.5 * (r.y1 - r.y0), 0.5);
    var mx = r.x0 + hx, my = r.y0 + hy;
    var qx = px - mx, qy = py - my;
    if (Math.abs(qx) < hx && Math.abs(qy) < hy) {
        var ox = r.cx - mx, oy = r.cy - my;
        var vx = qx - ox, vy = qy - oy;
        var ex = (hx - ox * Math.sign(vx)) / Math.max(Math.abs(vx), 0.001);
        var ey = (hy - oy * Math.sign(vy)) / Math.max(Math.abs(vy), 0.001);
        var t = Math.min(ex, ey);
        qx = ox + vx * t;
        qy = oy + vy * t;
    }
    return _along(Math.max(-hx, Math.min(hx, qx)), Math.max(-hy, Math.min(hy, qy)), hx, hy);
}

function _fract(x) {
    return x - Math.floor(x);
}

// Px within which two faces touch (the engine lays a popup flush on its bar; a child's inset is its parent's, the same loop).
var TOUCH = 1.5;

// The faces of box x another box covers from outside (or overlaps): [{ x0, y0, x1, y1 }] segments ON x's outline, each at least TOUCH long.
function _covered(x, b) {
    var out = [];
    function seg(x0, y0, x1, y1) {
        if (Math.max(x1 - x0, y1 - y0) > TOUCH)
            out.push({ x0: x0, y0: y0, x1: x1, y1: y1 });
    }
    var lx = Math.max(x.x0, b.x0), hx = Math.min(x.x1, b.x1), ly = Math.max(x.y0, b.y0), hy = Math.min(x.y1, b.y1);
    if (hx > lx) {
        if (b.y0 < x.y0 && b.y1 >= x.y0 - TOUCH)
            seg(lx, x.y0, hx, x.y0);
        if (b.y1 > x.y1 && b.y0 <= x.y1 + TOUCH)
            seg(lx, x.y1, hx, x.y1);
    }
    if (hy > ly) {
        if (b.x0 < x.x0 && b.x1 >= x.x0 - TOUCH)
            seg(x.x0, ly, x.x0, hy);
        if (b.x1 > x.x1 && b.x0 <= x.x1 + TOUCH)
            seg(x.x1, ly, x.x1, hy);
    }
    return out;
}

// The faces of box x on the screen's edge or beyond it (the sky: no hue to meet there, and nothing drawn past it).
function _onEdge(x, W, H) {
    var out = [];
    if (x.y0 <= 0.5)
        out.push({ x0: x.x0, y0: x.y0, x1: x.x1, y1: x.y0 });
    if (x.x1 >= W - 0.5)
        out.push({ x0: x.x1, y0: x.y0, x1: x.x1, y1: x.y1 });
    if (x.y1 >= H - 0.5)
        out.push({ x0: x.x0, y0: x.y1, x1: x.x1, y1: x.y1 });
    if (x.x0 <= 0.5)
        out.push({ x0: x.x0, y0: x.y0, x1: x.x0, y1: x.y1 });
    return out;
}

// A loop's join with the frame: null when it touches the frame nowhere (the island group of three islands: its only rest is the screen's
// edge), else the longest FREE arc of its rectangle's outline whose two ends are junctions with the frame:
//   { sa: where the arc starts round the loop (0 .. 1), sdf: its share of the loop, signed by the way round it runs from sa (+ clockwise),
//     fa: the frame's coordinate at that start (0 .. 1), dfr: how far the frame's coordinate runs from there to the other end (the short
//     way: the stretch of the frame the loop hides), len: the arc's length (px) }
// The arc starts at the junction the frame's coordinate comes FROM, so the hue rises the way the frame's does and the waves flow on.
function joinOf(loop, frame, ref, refFrame, screen) {
    if (!ref || !refFrame || !loop || loop.length === 0)
        return null;
    var W = screen && screen.w > 0 ? screen.w : 1e9, H = screen && screen.h > 0 ? screen.h : 1e9;
    var arcs = [];
    function add(sg, kind) {
        var s0 = perimAt(sg.x0, sg.y0, ref), s1 = perimAt(sg.x1, sg.y1, ref);
        var p0 = { x: sg.x0, y: sg.y0 }, p1 = { x: sg.x1, y: sg.y1 };
        // a segment of the outline is the short way round between its ends
        if (_fract(s1 - s0) <= 0.5)
            arcs.push({ s: s0, len: _fract(s1 - s0), k0: kind, k1: kind, p0: p0, p1: p1 });
        else
            arcs.push({ s: s1, len: _fract(s0 - s1), k0: kind, k1: kind, p0: p1, p1: p0 });
    }
    for (var i = 0; i < loop.length; i++) {
        var x = loop[i];
        if (!(_area(x) > 0))
            continue;
        for (var j = 0; j < frame.length; j++) {
            if (!(_area(frame[j]) > 0))
                continue;
            var cv = _covered(x, frame[j]);
            for (var n = 0; n < cv.length; n++)
                add(cv[n], "frame");
        }
        var ed = _onEdge(x, W, H);
        for (var e = 0; e < ed.length; e++)
            add(ed[e], "sky");
    }
    var hasFrame = false;
    for (var q = 0; q < arcs.length; q++)
        hasFrame = hasFrame || arcs[q].k0 === "frame";
    if (!hasFrame)
        return null;
    // the arcs' union round the circle: sorted by start, each merged into the one before it when they meet (a corner popup's two faces)
    arcs.sort(function (u, v) { return u.s - v.s; });
    var EPS = 1e-6;
    var un = [];
    for (var k = 0; k < arcs.length; k++) {
        var A = arcs[k], L = un.length ? un[un.length - 1] : null;
        if (L && A.s <= L.s + L.len + EPS) {
            if (A.s + A.len > L.s + L.len) {
                L.len = A.s + A.len - L.s;
                L.k1 = A.k1;
                L.p1 = A.p1;
            }
        } else {
            un.push({ s: A.s, len: A.len, k0: A.k0, k1: A.k1, p0: A.p0, p1: A.p1 });
        }
    }
    // the last one may run over 1 into the first
    if (un.length > 1) {
        var Z = un[un.length - 1], F = un[0];
        if (Z.s + Z.len >= F.s + 1 - EPS) {
            var end = Math.max(Z.s + Z.len, F.s + 1 + F.len);
            Z.len = end - Z.s;
            Z.k1 = end === F.s + 1 + F.len ? F.k1 : Z.k1;
            Z.p1 = end === F.s + 1 + F.len ? F.p1 : Z.p1;
            un.shift();
        }
    }
    // an end the frame and the screen's edge share is a junction (a bar's end at the screen's corner: the continuous bar on a side bar)
    for (var w = 0; w < un.length; w++) {
        var Uw = un[w];
        for (var r = 0; r < arcs.length; r++) {
            if (arcs[r].k0 !== "frame")
                continue;
            if (Math.abs(_fract(arcs[r].s + arcs[r].len - (Uw.s + Uw.len) + 0.5) - 0.5) <= 1e-4) {
                Uw.k1 = "frame";
                Uw.p1 = arcs[r].p1;
            }
            if (Math.abs(_fract(arcs[r].s - Uw.s + 0.5) - 0.5) <= 1e-4) {
                Uw.k0 = "frame";
                Uw.p0 = arcs[r].p0;
            }
        }
    }
    // the free arcs: from each union arc's end to the next one's start, clockwise
    var best = null;
    for (var m = 0; m < un.length; m++) {
        var U0 = un[m], U1 = un[(m + 1) % un.length];
        var f0 = _fract(U0.s + U0.len), f1 = U1.s;
        var share = un.length === 1 ? 1 - U0.len : _fract(f1 - f0);
        if (share <= EPS || U0.k1 !== "frame" || U1.k0 !== "frame")
            continue;
        if (!best || share > best.share)
            best = { f0: f0, f1: f1, share: share, e0: U0.p1, e1: U1.p0 };
    }
    if (!best)
        return null;
    var g0 = perimAt(best.e0.x, best.e0.y, refFrame), g1 = perimAt(best.e1.x, best.e1.y, refFrame);
    var len = best.share * perimeterOf(ref);
    if (_fract(g1 - g0) <= 0.5)
        return { sa: best.f0, sdf: best.share, fa: g0, dfr: _fract(g1 - g0), len: len };
    return { sa: best.f1, sdf: -best.share, fa: g1, dfr: _fract(g0 - g1), len: len };
}

// The shader's lane: [s_a, signed share, U_a, U_b] in hue cycles -- the frame's hue at each junction (its coordinate times its waves), and
// `extra` whole waves of the loop's own round the arc. A loop with no join is its own plain loop: [0, 1, 0, cycles].
function joinVec(join, cycles, cyclesFrame, extra) {
    if (!join)
        return [0, 1, 0, cycles];
    var ua = join.fa * cyclesFrame;
    return [join.sa, join.sdf, ua, ua + join.dfr * cyclesFrame + Math.max(0, Math.round(extra || 0))];
}

// The whole waves a joined loop adds round its free arc, so it carries about one wave to every `wavelength` px of it (the frame's own
// stretch counted in): counted once, as the loop comes, and kept while the aura plays (a count that changes is a jump of every hue).
function extraWaves(join, cyclesFrame, wavelength) {
    if (!join)
        return 0;
    return Math.max(0, Math.round(join.len / Math.max(1, wavelength) - join.dfr * cyclesFrame));
}
