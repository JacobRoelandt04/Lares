// =============================================================================
// PresetFaceLayout.js -- where PresetFace draws everything (pure: numbers and names in, numbers and names out; a probe reads the same plan).
//
//   plan(face, width, height, style) -> {
//       screens: [{ key, label, x, y, w, h, tiles: [{ x, y, w, h, z, cls, tabs, activeTab, locked, top, icon, floating }] }],
//       more, moreX, moreY, moreW, moreH,          // "+N" when the width holds fewer screens than there are workspaces
//       special: [cls, ...], badgeX, badgeY, badgeW, badgeH, badgeIcon
//   }
//
// THE SCREENS share one scale: each is its monitor's aspect, as wide as the room for all of them allows, capped by `screenMaxWidth` and by the
// height (the face's height less the label under it); centred across. Below `screenMinWidth` the strip keeps as many as fit at that width and
// the last slot says "+N".
// THE TILES are the saved `at` / `size` (logical px, relative to the monitor) scaled into the screen's inside (`inset` px in from its carve),
// with every EDGE rounded (never the centre: CLAUDE.md, A BOX'S EDGES MUST BE WHOLE PIXELS) and a `tileGap` taken off the right and bottom
// so two tiles that meet show the seam. A group is one tile: its members share a box; the first seen of it gives the box, the shown tab the
// icon, any member the lock (`group.locked`: the group's, so every member says the same). Tiled first, floating over them, fullscreen over all.
// =============================================================================
.pragma library

var INSET = 2;

function _num(v, d) {
    var n = Number(v);
    return isFinite(n) ? n : d;
}

function _monitor(face, name) {
    var ms = (face && face.monitors) || [];
    for (var i = 0; i < ms.length; i++)
        if (ms[i].name === name)
            return ms[i];
    return ms.length > 0 ? ms[0] : { name: "", w: 1920, h: 1080 };
}

function _tiles(ws, mon, W, H, style) {
    var mw = Math.max(1, _num(mon.w, 1920)), mh = Math.max(1, _num(mon.h, 1080));
    var iw = W - 2 * INSET, ih = H - 2 * INSET;
    var sx = iw / mw, sy = ih / mh;
    var gap = _num(style.tileGap, 1);
    var out = [];
    var groups = {};
    var wins = (ws.windows || []).slice();
    // the drawing order: tiled, floating, fullscreen (a stable sort by rank)
    function rank(w) {
        return _num(w.fullscreen, 0) > 0 ? 2 : (w.floating ? 1 : 0);
    }
    wins = wins.map(function (w, i) { return { w: w, i: i }; })
        .sort(function (a, b) { return rank(a.w) - rank(b.w) || a.i - b.i; })
        .map(function (p) { return p.w; });
    for (var i = 0; i < wins.length; i++) {
        var w = wins[i];
        var g = w.group || null;
        if (g && g.id !== undefined && g.id !== null && groups[g.id] !== undefined) {
            if (g.locked === true)
                out[groups[g.id]].locked = true;
            if (g.active === true) {
                out[groups[g.id]].cls = String(w["class"] || "");
                out[groups[g.id]].activeTab = _num(g.index, 0);
            }
            continue;
        }
        var x0, y0, x1, y1;
        if (_num(w.fullscreen, 0) > 0) {
            x0 = INSET; y0 = INSET; x1 = W - INSET; y1 = H - INSET;
        } else {
            var at = w.at || [0, 0], sz = w.size || [mw, mh];
            x0 = INSET + Math.round(_num(at[0], 0) * sx);
            y0 = INSET + Math.round(_num(at[1], 0) * sy);
            x1 = INSET + Math.round((_num(at[0], 0) + _num(sz[0], mw)) * sx);
            y1 = INSET + Math.round((_num(at[1], 0) + _num(sz[1], mh)) * sy);
        }
        x0 = Math.max(INSET, Math.min(W - INSET - 2, x0));
        y0 = Math.max(INSET, Math.min(H - INSET - 2, y0));
        x1 = Math.max(x0 + 2, Math.min(W - INSET, x1));
        y1 = Math.max(y0 + 2, Math.min(H - INSET, y1));
        if (x1 - x0 > 4 && x1 < W - INSET)
            x1 -= gap;
        if (y1 - y0 > 4 && y1 < H - INSET)
            y1 -= gap;
        var tabs = g ? Math.max(1, _num(g.size, 1)) : 1;
        var top = tabs > 1 ? _num(style.tabStrip, 3) + 2 : 0;
        var tw = x1 - x0, th = y1 - y0;
        var icon = Math.floor(Math.min(_num(style.iconMax, 18), tw - 4, th - top - 4));
        if (icon < _num(style.iconMin, 8))
            icon = 0;
        var t = {
            x: x0, y: y0, w: tw, h: th,
            z: rank(w),
            cls: String(w["class"] || ""),
            tabs: tabs,
            activeTab: g ? _num(g.index, 0) : 0,
            locked: !!g && g.locked === true,
            top: top,
            icon: icon,
            floating: !!w.floating && _num(w.fullscreen, 0) <= 0
        };
        if (g && g.id !== undefined && g.id !== null)
            groups[g.id] = out.length;
        out.push(t);
    }
    return out;
}

function plan(face, width, height, style) {
    var res = { screens: [], more: 0, moreX: 0, moreY: 0, moreW: 0, moreH: 0, special: [], badgeX: 0, badgeY: 0, badgeW: 0, badgeH: 0, badgeIcon: 0 };
    if (!face || !face.workspaces || width <= 0 || height <= 0)
        return res;
    var gap = _num(style.screenGap, 6);
    var labelH = _num(style.labelGap, 2) + _num(style.labelSize, 9) + 2;
    var hs = Math.max(8, height - labelH);
    var normal = [], special = [];
    for (var i = 0; i < face.workspaces.length; i++) {
        var ws = face.workspaces[i];
        if (!ws || !ws.windows || ws.windows.length === 0)
            continue;
        (ws.special ? special : normal).push(ws);
    }
    for (var s = 0; s < special.length; s++)
        for (var k = 0; k < special[s].windows.length && res.special.length < 2; k++)
            res.special.push(String(special[s].windows[k]["class"] || ""));
    var badgeW = res.special.length > 0 ? Math.round(_num(style.badgeWidth, 26)) : 0;
    var avail = width - (badgeW > 0 ? badgeW + gap : 0);
    var n = normal.length;
    if (n === 0 && badgeW === 0)
        return res;
    // one aspect for the scale: the widest monitor a shown workspace is on (one scale for the strip)
    var aspect = 16 / 9;
    for (var j = 0; j < n; j++) {
        var m = _monitor(face, normal[j].monitor);
        aspect = Math.max(j === 0 ? 0 : aspect, Math.max(1, _num(m.w, 16)) / Math.max(1, _num(m.h, 9)));
    }
    var minW = _num(style.screenMinWidth, 46), maxW = _num(style.screenMaxWidth, 128);
    var shown = n, more = 0;
    var w = n > 0 ? Math.floor((avail - (n - 1) * gap) / n) : 0;
    if (n > 0 && w < minW) {
        // as many as fit at the least width, the last slot "+N"
        var fit = Math.max(1, Math.floor((avail + gap) / (minW + gap)));
        shown = Math.max(0, fit - 1);
        more = n - shown;
        w = minW;
    }
    w = Math.min(w, maxW, Math.floor(hs * aspect));
    var h = Math.max(4, Math.round(w / aspect));
    var slots = shown + (more > 0 ? 1 : 0);
    var total = slots * w + Math.max(0, slots - 1) * gap + (badgeW > 0 ? (slots > 0 ? gap : 0) + badgeW : 0);
    var x = Math.round((width - total) / 2);
    var y = Math.round((hs - h) / 2);
    for (var q = 0; q < shown; q++) {
        var wsq = normal[q];
        var mon = _monitor(face, wsq.monitor);
        // the screen keeps ITS monitor's aspect inside the slot (a narrower monitor stands centred in it)
        var a = Math.max(1, _num(mon.w, 16)) / Math.max(1, _num(mon.h, 9));
        var sw = Math.min(w, Math.round(h * a));
        res.screens.push({
            key: String(wsq.key),
            label: String(wsq.name !== undefined ? wsq.name : wsq.key),
            x: x + Math.round((w - sw) / 2), y: y, w: sw, h: h,
            tiles: _tiles(wsq, mon, sw, h, style)
        });
        x += w + gap;
    }
    if (more > 0) {
        res.more = more;
        res.moreX = x; res.moreY = y; res.moreW = w; res.moreH = h;
        x += w + gap;
    }
    if (badgeW > 0) {
        res.badgeX = x;
        res.badgeY = y;
        res.badgeW = badgeW;
        res.badgeH = n > 0 ? h : Math.min(hs, 40);
        res.badgeIcon = Math.max(0, Math.min(16, badgeW - 8, Math.floor((res.badgeH - 6 - (res.special.length - 1) * 3) / Math.max(1, res.special.length))));
    }
    return res;
}
