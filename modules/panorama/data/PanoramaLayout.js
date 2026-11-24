.pragma library
.import "PanoramaModel.js" as Model

// =============================================================================
// PanoramaLayout.js -- the canvas's geometry, pure (no Qt; tools/dev/panorama_layout_cases.js runs it under node).
//
// Everything is in compositor-LOGICAL integer px: a rect is { name, x, y, w, h } and a layout is a list of them. A layout is
// valid when no two rects overlap and every rect is reachable from the others through edges that TOUCH (share a segment of
// at least one px; a corner is no join: Hyprland would hand the cursor nowhere). The user's rule (decision 14): plain to-scale
// tiles; a drop lands on a place that touches, never on top of a neighbour, never floating free.
//
//   fitCanvas(rects, boxW, boxH, pad, maxScale)   { scale, ox, oy }: the layout fits the box, centred
//   dropByPointer(moving, others, px, py, origin) where a carried tile will attach, decided from the POINTER (never from the tile's
//                                                 own corner): the tile under it is cut by its two diagonals into four triangles, the
//                                                 triangle is the side, the pointer's place along that side (thirds) the alignment;
//                                                 outside every tile: the nearest one and its facing side
//   resolveDrop(moving, others, origin)           the nearest valid place (the fallback of dropByPointer: connected, overlaps nothing)
//   normalise(rects, anchorName)                  shifted so the anchor stands at 0,0
//   relationsOf(rects, internalName)              how each tile hangs on a neighbour: a tree rooted at the internal display
//   relayout(rects, relations, internalName)      every tile placed again from its relation at the rects' CURRENT sizes
//   relayoutOne(rects, name, anchorName)          one tile whose size changed dropped again where it stands (relayout called with a
//                                                 name as its second argument does this: the service's old call, until it moves on)
//   rectsOf(specs, outs)                          rects from resolved specs and the live outputs (PanoramaModel.rectOf)
//   scaleShown(choices, current, physical)        the scales the rail offers (a readable subset of PanoramaModel.scaleChoices)
// =============================================================================

var MIN_SHARE = 48;            // logical px of shared edge that makes two rects touch (a hair of overlap is no way to cross)

function _copy(r) {
    return { name: r.name, x: r.x, y: r.y, w: r.w, h: r.h };
}

function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h;
}

function touches(a, b) {
    var need = Math.min(MIN_SHARE, a.w, a.h, b.w, b.h);
    var shareY = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
    var shareX = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    if ((a.x + a.w === b.x || b.x + b.w === a.x) && shareY >= need) return true;
    if ((a.y + a.h === b.y || b.y + b.h === a.y) && shareX >= need) return true;
    return false;
}

function bounds(rects) {
    if (!rects.length) return { x: 0, y: 0, w: 0, h: 0 };
    var x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (var i = 0; i < rects.length; i++) {
        x0 = Math.min(x0, rects[i].x); y0 = Math.min(y0, rects[i].y);
        x1 = Math.max(x1, rects[i].x + rects[i].w); y1 = Math.max(y1, rects[i].y + rects[i].h);
    }
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
}

function connected(rects) {
    if (rects.length < 2) return true;
    var seen = [true], stack = [0], n = 1;
    for (var i = 1; i < rects.length; i++) seen.push(false);
    while (stack.length) {
        var c = stack.pop();
        for (var j = 0; j < rects.length; j++) {
            if (!seen[j] && touches(rects[c], rects[j])) { seen[j] = true; n++; stack.push(j); }
        }
    }
    return n === rects.length;
}

function valid(rects) {
    for (var i = 0; i < rects.length; i++)
        for (var j = i + 1; j < rects.length; j++)
            if (overlaps(rects[i], rects[j])) return false;
    return connected(rects);
}

function fitCanvas(rects, boxW, boxH, pad, maxScale) {
    var b = bounds(rects);
    var aw = Math.max(1, boxW - 2 * pad), ah = Math.max(1, boxH - 2 * pad);
    if (!(b.w > 0) || !(b.h > 0))
        return { scale: 1, ox: boxW / 2, oy: boxH / 2 };
    var s = Math.min(aw / b.w, ah / b.h, maxScale > 0 ? maxScale : Infinity);
    return { scale: s, ox: (boxW - b.w * s) / 2 - b.x * s, oy: (boxH - b.h * s) / 2 - b.y * s };
}

// The extents a moving rect `m` can be set against one `o` so that the two touch: the x or y of m at each contact, and the
// other axis free (clamped to keep a shared segment) plus every aligned variant.
function _candidates(m, others, all) {
    var out = [];
    function add(x, y) { out.push({ x: Math.round(x), y: Math.round(y) }); }
    for (var i = 0; i < others.length; i++) {
        var o = others[i];
        var cy = Math.max(o.y - m.h + MIN_SHARE, Math.min(o.y + o.h - MIN_SHARE, m.y));
        var cx = Math.max(o.x - m.w + MIN_SHARE, Math.min(o.x + o.w - MIN_SHARE, m.x));
        var ys = [cy, o.y, o.y + o.h - m.h, o.y + (o.h - m.h) / 2], xs = [cx, o.x, o.x + o.w - m.w, o.x + (o.w - m.w) / 2];
        if (all) {            // the free axis aligned to any edge on the layout
            for (var k = 0; k < others.length; k++) {
                ys.push(others[k].y, others[k].y + others[k].h - m.h);
                xs.push(others[k].x, others[k].x + others[k].w - m.w);
            }
        }
        for (var a = 0; a < ys.length; a++) {
            add(o.x + o.w, ys[a]);
            add(o.x - m.w, ys[a]);
        }
        for (var b = 0; b < xs.length; b++) {
            add(xs[b], o.y + o.h);
            add(xs[b], o.y - m.h);
        }
    }
    return out;
}

function _fits(m, x, y, others) {
    var r = { name: m.name, x: x, y: y, w: m.w, h: m.h };
    for (var i = 0; i < others.length; i++)
        if (overlaps(r, others[i])) return false;
    return true;
}

function _nearest(m, others, all, needConnected, limit) {
    var best = null, bd = Infinity, cands = _candidates(m, others, all);
    for (var i = 0; i < cands.length; i++) {
        var c = cands[i];
        var d = Math.sqrt((c.x - m.x) * (c.x - m.x) + (c.y - m.y) * (c.y - m.y));
        if (d >= bd || d > limit) continue;
        if (!_fits(m, c.x, c.y, others)) continue;
        if (needConnected) {
            var all2 = others.concat([{ name: m.name, x: c.x, y: c.y, w: m.w, h: m.h }]);
            if (!connected(all2)) continue;
        }
        best = c; bd = d;
    }
    return best ? { x: best.x, y: best.y, d: bd } : null;
}

// ---- the pointer decides ------------------------------------------------------------------------------------------------------------
// Where the moving rect `m` stands when it hangs on `o` at `side` ("left" | "top" | "right" | "bottom": the side of `o` it touches) and
// `align` ("start" | "centre" | "end" along that side).
function placeAt(m, o, side, align) {
    var horiz = side === "left" || side === "right";
    var len = horiz ? o.h : o.w, mine = horiz ? m.h : m.w, at = horiz ? o.y : o.x;
    var along = align === "start" ? at : align === "end" ? at + len - mine : at + Math.round((len - mine) / 2);
    if (side === "right") return { x: o.x + o.w, y: along };
    if (side === "left") return { x: o.x - m.w, y: along };
    if (side === "bottom") return { x: along, y: o.y + o.h };
    return { x: along, y: o.y - m.h };
}

// The triangle of `o` (cut by its two diagonals) the point (px, py) lies in, and where along that side it falls (0 .. 1).
function _sideOf(o, px, py) {
    var dx = (px - (o.x + o.w / 2)) / (o.w / 2), dy = (py - (o.y + o.h / 2)) / (o.h / 2);
    var horiz = Math.abs(dx) >= Math.abs(dy);
    var side = horiz ? (dx < 0 ? "left" : "right") : (dy < 0 ? "top" : "bottom");
    var t = horiz ? (py - o.y) / o.h : (px - o.x) / o.w;
    return { side: side, t: Math.max(0, Math.min(1, t)), score: Math.max(Math.abs(dx), Math.abs(dy)) };
}
function _alignOf(t) {
    return t < 1 / 3 ? "start" : t > 2 / 3 ? "end" : "centre";
}
function _dist2(o, px, py) {
    var dx = Math.max(o.x - px, 0, px - (o.x + o.w)), dy = Math.max(o.y - py, 0, py - (o.y + o.h));
    return dx * dx + dy * dy;
}

// -> { x, y, side, align, to, ok }: the place a tile of m's size takes when the pointer is at (px, py). The tile under the pointer (else the
// nearest) is the neighbour; the place is then checked against the rest (no overlap, the layout stays in one piece): the next best
// triangle / third is taken when it is not. `ok` false: nothing attaches by the pointer and the nearest valid place (or the origin) stands.
function dropByPointer(moving, others, px, py, origin) {
    if (!others.length)
        return { x: 0, y: 0, side: "", align: "", to: null, ok: true };
    var order = others.map(function (o, i) { return { o: o, d: _dist2(o, px, py), i: i }; });
    order.sort(function (a, b) { return a.d - b.d || a.i - b.i; });
    var sides = ["left", "top", "right", "bottom"], aligns = ["start", "centre", "end"];
    var tries = [];
    for (var k = 0; k < order.length; k++) {
        var o = order[k].o, s0 = _sideOf(o, px, py), al = _alignOf(s0.t);
        tries.push({ o: o, side: s0.side, align: al });
        for (var a = 0; a < 3; a++)
            if (aligns[a] !== al) tries.push({ o: o, side: s0.side, align: aligns[a] });
        for (var s = 0; s < 4; s++)
            if (sides[s] !== s0.side)
                for (var b = 0; b < 3; b++) tries.push({ o: o, side: sides[s], align: aligns[b] });
    }
    for (var i = 0; i < tries.length; i++) {
        var t = tries[i], p = placeAt(moving, t.o, t.side, t.align);
        if (!_fits(moving, p.x, p.y, others)) continue;
        if (!connected(others.concat([{ name: moving.name, x: p.x, y: p.y, w: moving.w, h: moving.h }]))) continue;
        return { x: p.x, y: p.y, side: t.side, align: t.align, to: t.o.name, ok: true };
    }
    var d = resolveDrop({ name: moving.name, x: Math.round(px - moving.w / 2), y: Math.round(py - moving.h / 2), w: moving.w, h: moving.h }, others, origin);
    return { x: d.x, y: d.y, side: "", align: "", to: null, ok: d.ok };
}

// On release: the nearest place that touches, overlaps nothing and keeps the layout connected. `origin` ({x, y}) is the
// fallback when no place does (the others fell apart without the tile and no single spot joins them).
function resolveDrop(moving, others, origin) {
    if (!others.length)
        return { x: 0, y: 0, ok: true };
    var best = _nearest(moving, others, true, true, Infinity);
    if (best) return { x: best.x, y: best.y, ok: true };
    if (origin) return { x: origin.x, y: origin.y, ok: false };
    return { x: Math.round(moving.x), y: Math.round(moving.y), ok: false };
}

function normalise(rects, anchorName) {
    if (!rects.length) return [];
    var a = rects[0];
    for (var i = 0; i < rects.length; i++)
        if (rects[i].name === anchorName) { a = rects[i]; break; }
    return rects.map(function (r) { var c = _copy(r); c.x -= a.x; c.y -= a.y; return c; });
}

// A tile changed size (a mode, a scale, a quarter turn): it is dropped again at the place it holds, which moves it only if it now
// overlaps or no longer touches, and the layout is shifted so the anchor stands at 0,0. -> a new list of rects.
function relayoutOne(rects, name, anchorName) {
    var me = null, others = [];
    for (var i = 0; i < rects.length; i++) {
        if (rects[i].name === name) me = _copy(rects[i]); else others.push(_copy(rects[i]));
    }
    if (me && others.length) {
        var d = resolveDrop(me, others, { x: me.x, y: me.y });
        me.x = d.x; me.y = d.y;
    }
    return normalise(me ? others.concat([me]) : others, anchorName);
}

// ---- relations: how a layout hangs together ------------------------------------------------------------------------------------------
// A tile that is not the internal display hangs on ONE neighbour (the tree is rooted at the internal display; each tile takes, among the
// tiles nearer the root it touches, the one it shares the longest edge with). A relation is { to, side, align, offset, frac }: `side` the side
// of `to` it stands on, `align` "centre" | "start" | "end" when it is flush so, else "free"; `offset` its start's distance from the
// neighbour's start along the shared edge (px), `frac` that as a share of the neighbour's side (what "free" keeps when sizes change).
function _shared(a, b) {
    var sy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y), sx = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
    if (a.x + a.w === b.x || b.x + b.w === a.x) return sy;
    if (a.y + a.h === b.y || b.y + b.h === a.y) return sx;
    return 0;
}
function _relation(r, p) {
    var side = r.x === p.x + p.w ? "right" : r.x + r.w === p.x ? "left" : r.y === p.y + p.h ? "bottom" : "top";
    var horiz = side === "left" || side === "right";
    var start = horiz ? r.y - p.y : r.x - p.x, len = horiz ? p.h : p.w, mine = horiz ? r.h : r.w;
    var align = start === Math.round((len - mine) / 2) ? "centre" : start === 0 ? "start" : start === len - mine ? "end" : "free";
    return { to: p.name, side: side, align: align, offset: start, frac: len > 0 ? start / len : 0 };
}
function relationsOf(rects, internalName) {
    var res = {};
    if (!rects.length) return res;
    var root = rects[0];
    for (var i = 0; i < rects.length; i++)
        if (rects[i].name === internalName) { root = rects[i]; break; }
    var seen = {};
    seen[root.name] = true;
    var left = rects.filter(function (r) { return r !== root; });
    while (left.length) {
        var take = [];
        for (var u = 0; u < left.length; u++) {
            var best = null, bl = 0;
            for (var v = 0; v < rects.length; v++) {
                if (!seen[rects[v].name]) continue;
                var l = _shared(left[u], rects[v]);
                if (l > bl) { bl = l; best = rects[v]; }
            }
            if (best) take.push({ r: left[u], p: best });
        }
        if (!take.length) break;                                   // a piece nothing touches: no relation (it keeps its place)
        for (var k = 0; k < take.length; k++) {
            res[take[k].r.name] = _relation(take[k].r, take[k].p);
            seen[take[k].r.name] = true;
            left = left.filter(function (r) { return r !== take[k].r; });
        }
    }
    return res;
}

// Every tile placed again from its relation, at the rects' CURRENT sizes: "centre" stays centred, "start" / "end" keep their flush edge, "free"
// keeps its share of the neighbour's side. The root (the internal display) stays; a tile that comes to overlap one already placed is set at
// the nearest valid place; the layout is normalised so the internal display stands at 0,0. Same order as `rects`.
// With a NAME as the second argument it is relayoutOne (the service's earlier call).
function relayout(rects, relations, internalName) {
    if (typeof relations === "string")
        return relayoutOne(rects, relations, internalName);
    var byName = {}, i;
    for (i = 0; i < rects.length; i++) byName[rects[i].name] = _copy(rects[i]);
    var root = byName[internalName] || (rects.length ? byName[rects[0].name] : null);
    if (!root) return [];
    var done = {}, placed = [root];
    done[root.name] = true;
    var rel = relations || {}, pending = rects.map(function (r) { return r.name; }).filter(function (n) { return n !== root.name; });
    for (var guard = 0; pending.length && guard < 64; guard++) {
        var next = [];
        for (i = 0; i < pending.length; i++) {
            var n = pending[i], r = byName[n], re = rel[n];
            if (!re || !done[re.to]) { next.push(n); continue; }
            var p = byName[re.to], horiz = re.side === "left" || re.side === "right";
            var len = horiz ? p.h : p.w, mine = horiz ? r.h : r.w, at = horiz ? p.y : p.x;
            var along = re.align === "centre" ? at + Math.round((len - mine) / 2) : re.align === "start" ? at
                      : re.align === "end" ? at + len - mine : at + Math.round((re.frac !== undefined ? re.frac : re.offset / Math.max(1, len)) * len);
            var pos = re.side === "right" ? { x: p.x + p.w, y: along } : re.side === "left" ? { x: p.x - r.w, y: along }
                    : re.side === "bottom" ? { x: along, y: p.y + p.h } : { x: along, y: p.y - r.h };
            r.x = pos.x; r.y = pos.y;
            if (!_fits(r, r.x, r.y, placed)) {
                var d = resolveDrop(r, placed, { x: r.x, y: r.y });
                r.x = d.x; r.y = d.y;
            }
            placed.push(r);
            done[n] = true;
        }
        if (next.length === pending.length) break;
        pending = next;
    }
    for (i = 0; i < pending.length; i++) {                             // no relation: it stays, set at the nearest valid place
        var q = byName[pending[i]];
        if (!_fits(q, q.x, q.y, placed)) { var dd = resolveDrop(q, placed, { x: q.x, y: q.y }); q.x = dd.x; q.y = dd.y; }
        placed.push(q);
    }
    return normalise(rects.map(function (r) { return byName[r.name]; }), root.name);
}

// Rects for the enabled, non-mirroring outputs of `specs` (by name; mirror is a name or ""), sizes from the live output's
// mode, the spec's scale and rotation (PanoramaModel.rectOf), so a rotated display stands on its end.
function rectsOf(specs, outs) {
    var res = [];
    for (var i = 0; i < outs.length; i++) {
        var o = outs[i], s = specs[o.name];
        if (!s || !s.enabled || s.mirror) continue;
        var r = Model.rectOf(s, o);
        res.push({ name: o.name, x: r.x, y: r.y, w: r.w, h: r.h });
    }
    return res;
}

// The scales worth a place on the rail: quarter steps (1.25, 1.5 ...), the display's physical match and the one in force;
// everything else PanoramaModel.scaleChoices allows (1.3333, 1.875 ...) stays reachable by the numbers the file holds.
function scaleShown(choices, current, physical) {
    var res = [];
    for (var i = 0; i < choices.length; i++) {
        var c = choices[i], q = c * 4;
        var near = function (v) { return typeof v === "number" && Math.abs(v - c) < 0.0005; };
        if (Math.abs(q - Math.round(q)) < 0.0005 || near(current) || near(physical))
            res.push(c);
    }
    return res;
}
