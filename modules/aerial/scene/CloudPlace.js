.pragma library

// =============================================================================
// CloudPlace.js -- where everything in aerial's air stands: THE SIGNAL FAN (round 3, the user's pick). Pure: no Qt, runs under node (tools/dev/aerial_holo_cases.js).
//
// The cloud is a standing Wi-Fi glyph on the card's label: its ORIGIN is the label's centre (AerialGeometry ANCHORS.cloud, projected), and from it arcs fan up, `span`
// degrees either side of the vertical (AerialCamera.cloud: the radii in item px):
//
//   rBt       THE NEAR FIELD: Bluetooth devices that are NOT connected (the connected ones are on the label). Paired ones about the middle on the inner row, strangers
//             toward the ends on the outer one.
//   r[0]      Wi-Fi, the strongest band (signalBand 0)
//   r[1]      Wi-Fi, the next (signalBand 1)
//   rFringe   the weak two bands: dots, and the names of SAVED networks that are weak today
//
// So "nearer the card = stronger" holds for everything. An arc is a BAND of two rows (ROW px inside and outside its radius; which row is the key's own bit), so two names
// may pass each other at the top of an arc and the fan reads as a cloud, not as text on a ruled line.
//
// A PLACE IS THE KEY'S OWN: the angle is seeded from a hash of the key (the same place at every open), then one solver pushes plates apart ALONG their arcs until none
// overlaps another, a kept-off rect (the globe, the screw, the cables, the own hotspot's reserved spot) or the popup's edge. It is STICKY: an entry that stays on its arc
// starts from where it stood, so an arrival moves only the neighbours it lands on. THE LABEL BUDGET: when an arc cannot hold its names, the weakest STRANGERS become dots
// where they stand (a saved network keeps its name); nothing is ever placed over something else.
//
//   itemsOfWifi(wifi) / itemsOfClients(hotspot) / itemsOfBt(bt) / hotspotItem(hotspot)   the facts -> items
//   place(state, items, nowMs, opt) -> state     opt: { ox, oy, rBt, r: [r0, r1], rFringe, span (deg), bounds: { x0, y0, x1, y1 }, avoid: [{ x0, y0, x1, y1, bt }], measure(item) -> px }
//                                                state.entries[key] = the item + { arc, R, th, x, y (the plate's centre, item px), w, h, form: "named" | "dot", gone, goneAt }
//   zonePoly(G, map, rect)   a rect of the label (card-local mm: G.LABEL_ZONE, G.LABEL_BT, G.LABEL) as an item-px polygon under the scene's label map
//   centreOf / inPoly / distToPoly, labelPoint(G, map, x, y) -> card-local mm (the map's inverse)
// =============================================================================

var FADE_MS = 420;                                  // a leaver is kept this long for its fade
var ROW = 11;                                       // px: an arc's two rows stand this far inside and outside its radius
var TAG_H = 18, TW_MAX = 150, GAP = 5;              // a name plate's height, the widest name drawn (longer ones are cut in the middle), the air between two plates
var DOT = 8;                                        // a dot's box (the dot itself is 5 px)
var MID = 25;                                       // px outside an arc's radius: the air between two arcs, where a dot that found no room on its line stands

function hash(s) {
    var h = 0x811c9dc5;
    s = String(s);
    for (var i = 0; i < s.length; i++) {
        h ^= s.charCodeAt(i);
        h = Math.imul(h, 0x01000193) >>> 0;
    }
    return h >>> 0;
}
// the i-th number in [0, 1) of a key's own sequence
function rnd(h, i) {
    var a = (h + Math.imul(i + 1, 0x9E3779B9)) >>> 0;
    a = Math.imul(a ^ (a >>> 15), a | 1);
    a ^= a + Math.imul(a ^ (a >>> 7), a | 61);
    return ((a ^ (a >>> 14)) >>> 0) / 4294967296;
}

// ---- the facts -> items ---------------------------------------------------------------------
// named: saved networks in range, and strangers in the two strongest bands; dots: strangers in the two weakest, and hidden access points
function formOf(net) {
    if (net.hidden && !net.ssid)
        return "dot";
    if (net.known)
        return "named";
    return net.signalBand <= 1 ? "named" : "dot";
}
function secured(net) {
    return net.security !== "open" && net.security !== "owe";
}
// what the cloud shows of a Wi-Fi fact: the connected network and the own hotspot are NOT in it (docked on the label / its own tag)
function itemsOfWifi(wifi) {
    var out = [];
    var nets = (wifi && wifi.networks) || [];
    var activeKey = wifi && wifi.active ? wifi.active.key : "";
    for (var i = 0; i < nets.length; i++) {
        var n = nets[i];
        if (n.connected || n.ownHotspot || n.key === activeKey)
            continue;
        var band = Math.max(0, Math.min(3, n.signalBand | 0));
        out.push({
            key: n.key, kind: "net", ssid: n.ssid || "", sec: n.security || "", want: formOf(n), hidden: !!(n.hidden && !n.ssid), band: band, arc: band >= 2 ? "fringe" : band, signal: n.signal | 0,
            secured: secured(n), known: !!n.known, publicNet: !n.known && !secured(n) || n.trusted === false && n.known && !secured(n),
            bands: n.bands || [], bestBand: n.bestBand || (n.bands && n.bands[0]) || "5", state: n.state || "idle", failReason: n.failReason || ""
        });
    }
    return out;
}
function bandOfDbm(dbm) {
    return dbm >= -55 ? 0 : dbm >= -67 ? 1 : dbm >= -78 ? 2 : 3;
}
// while the own hotspot is up the cloud holds its clients
function itemsOfClients(hotspot) {
    var out = [], cl = (hotspot && hotspot.clients) || [];
    for (var i = 0; i < cl.length; i++) {
        var c = cl[i], band = bandOfDbm(c.dbm === undefined ? -60 : c.dbm);
        out.push({ key: "client:" + c.mac, kind: "client", sec: "", ssid: c.name || c.ip || c.mac, want: "named", hidden: false, band: band, arc: band >= 2 ? "fringe" : band, signal: 60,
                   secured: false, known: true, publicNet: false, bands: ["5"], bestBand: "5", state: "connected", failReason: "" });
    }
    return out;
}
// the own hotspot while it is down: one tag at a reserved spot (the fan's lower left end of the first arc); nothing else may take it
function hotspotItem(hotspot) {
    return { key: "hotspot", kind: "hotspot", sec: "", ssid: hotspot && hotspot.ssid ? String(hotspot.ssid) : "Hotspot", want: "named", hidden: false, band: 0, arc: 0, pinned: true, signal: 100,
             secured: false, known: true, publicNet: false, bands: [], bestBand: "5", state: "idle", failReason: "" };
}
var KIND_GLYPH = {
    earbuds: 0xF184F, headset: 0xF02CE, speaker: 0xF04C3, phone: 0xF011C, computer: 0xF0322, mouse: 0xF037D, keyboard: 0xF030C, gamepad: 0xF0297, watch: 0xF0589, generic: 0xF00AF
};
function glyphOf(kind) {
    return String.fromCodePoint(KIND_GLYPH[kind] || KIND_GLYPH.generic);
}
// THE NEAR FIELD: every device that is not connected and not blocked. `paired` ones stand at full strength about the fan's middle, strangers (heard by a search) smaller toward its ends.
function itemsOfBt(bt) {
    var out = [], ds = (bt && bt.devices) || [];
    if (bt && (bt.present === false || bt.powered === false))
        return out;
    for (var i = 0; i < ds.length; i++) {
        var d = ds[i];
        if (d.blocked || d.connected)
            continue;
        out.push({ key: d.address, kind: "bt", sec: "", dev: d.kind || "generic", ssid: d.name || d.address, want: "named", hidden: false, band: 0, arc: "bt",
                   signal: d.rssi ? Math.max(1, Math.min(100, Math.round(2 * (d.rssi + 100)))) : 40,
                   battery: d.battery === undefined ? -1 : d.battery, paired: !!d.paired, pairing: !!d.pairing, secured: false, known: !!d.paired, publicNet: false, bands: [], bestBand: "5",
                   state: "idle", failReason: "" });
    }
    return out;
}

// ---- boxes ----------------------------------------------------------------------------------
// the plate of an entry: w x h px (named: its dot, name and lock mark; a device: its glyph over its name)
function sizeOf(e, textW) {
    if (e.form === "dot")
        return [DOT, DOT];
    var tw = Math.min(TW_MAX, Math.max(8, Math.ceil(textW)));
    // a device is one row as a network is: its kind's glyph where a network has its node (a stranger's is smaller)
    if (e.kind === "bt")
        return [7 + (e.paired ? 14 : 12) + 4 + Math.min(tw, e.paired ? 110 : 90) + 8, TAG_H];
    var lock = e.kind === "net" && (e.secured || e.publicNet) ? 13 : 0;
    return [7 + (e.kind === "hotspot" || e.kind === "client" ? 13 : 7) + 5 + tw + lock + 8, TAG_H];
}
function rectOf(e) {
    return { x0: e.x - e.w / 2, x1: e.x + e.w / 2, y0: e.y - e.h / 2, y1: e.y + e.h / 2 };
}
// how far two rects reach into each other on each axis with `gap` px of air between them: null when they are clear
function _pen(a, b, gap) {
    var px = Math.min(a.x1, b.x1) - Math.max(a.x0, b.x0) + gap, py = Math.min(a.y1, b.y1) - Math.max(a.y0, b.y0) + gap;
    return px > 0 && py > 0 ? [px, py] : null;
}
function overlaps(a, b, gap) {
    return _pen(a, b, gap === undefined ? 0 : gap) !== null;
}

// ---- the solver -----------------------------------------------------------------------------
function _radiusOf(e, opt) {
    var base = e.arc === "bt" ? opt.rBt : e.arc === "fringe" ? opt.rFringe : opt.r[e.arc] || opt.r[0];
    if (e.pinned)
        return base;
    // the near field's two rows: the paired devices inside, the strangers outside (a stranger passes a paired one at the top of the arc)
    if (e.arc === "bt")
        return base + (e.form === "dot" ? 0 : e.paired ? -10 : 20);
    // a dot never rides a row of names: the fringe's scatter a little round its line (a cloud's edge, not beads on a string), a stranger the budget made a dot stands in
    // the air between its arc and the next (place() tries base + MID, then base - MID)
    if (e.form === "dot")
        return base + (e.arc === "fringe" ? (rnd(e.h0, 2) * 2 - 1) * ROW : 0);
    // the row is the spread's (THE SPREAD, below: neighbours alternate rows, a brick bond); the key's own bit until it has one
    return base + ((e.row !== undefined ? e.row === 1 : (e.h0 & 1) === 1) ? ROW : -ROW);
}
// the angle a key is born at (rad from the vertical, + to the right)
function _seed(e, opt) {
    var S = opt.span * Math.PI / 180, u = rnd(e.h0, 0) * 2 - 1;
    if (e.pinned)
        return -S;
    if (e.arc === "bt") {
        if (e.paired)
            return u * S * 0.42;
        return (u < 0 ? -1 : 1) * S * (0.55 + 0.42 * Math.abs(u));      // strangers: out toward the ends
    }
    return u * S * 0.94;
}
// THE SPREAD (the orchestrator's change after the first whole-popup render: hashed angles left a crowd's names bunched on one side of the fan and half its air empty).
// The names of one arc are laid as a BRICK BOND, centred on the vertical: in the keys' own order (their hash, so the same set of networks gives the same picture at every
// open) they alternate between the arc's inner and outer row, and each row is spaced evenly about the fan's middle -- one name stands straight over the card, two
// either side of it, a full arc from end to end. So the cloud is symmetric and grows from its middle. The near field's two rows (paired / strangers) are each spread
// the same way. The solver (_relax) then only parts what still touches: a kept-off rect, the popup's edge, a name of the next arc.
var SPREAD_GAP_MAX = 30;                            // px of air between two neighbours of a row when the row has room to spare
// THE FAN WIDENS AS IT RISES: each arc's names keep to a share of the fan's half angle -- narrow just over the card, wide at the fringe -- so the cloud is a plume standing
// on the label and an inner arc's ends never come down beside the near field's devices. (The dots and the drawn guides keep the whole span.)
var SPAN_SHARE = { bt: 0.52, "0": 0.60, "1": 0.78, fringe: 0.96 };
function _spanOf(arc, opt) {
    return opt.span * Math.PI / 180 * (SPAN_SHARE[String(arc)] || 0.96);
}
// what an arc's two rows can hold, px of names with their least gaps
function _roomOf(arc, opt) {
    var base = arc === "fringe" ? opt.rFringe : opt.r[Number(arc)] || opt.r[0];
    return 2 * _spanOf(arc, opt) * 2 * base;
}
// THE OVERFLOW: an arc that cannot hold its names hands its WEAKEST ones to the next arc out (0 -> 1 -> the fringe), so the cloud fills from the card outward and a strong
// network is never made a dot while a weaker one keeps its name. The signal band (the service's, with hysteresis) still decides the arc wherever there is room.
function _overflow(names, opt) {
    var order = ["0", "1"];
    for (var a = 0; a < order.length; a++) {
        var arc = order[a], list = names.filter(function (e) { return e.kind === "net" && !e.pinned && !e.moved && String(e.arc) === arc; });
        var tot = 0;
        list.forEach(function (e) { tot += e.w + GAP; });
        // weakest first out
        list.sort(function (x, y) { return x.signal !== y.signal ? x.signal - y.signal : (x.key < y.key ? 1 : -1); });
        var room = _roomOf(arc, opt) * 0.92;
        for (var i = 0; i < list.length && tot > room; i++) {
            tot -= list[i].w + GAP;
            list[i].arc = a === 0 ? 1 : "fringe";
        }
    }
}
function _spreadRow(row, R, opt, shift, arc) {
    var S = _spanOf(arc, opt), n = row.length, i, tot = 0;
    if (!n)
        return 0;
    for (i = 0; i < n; i++)
        tot += row[i].w;
    var room = 2 * S * R;
    var gap = n > 1 ? Math.max(GAP, Math.min(SPREAD_GAP_MAX, (room - tot) / (n - 1))) : 0;
    var len = tot + gap * (n - 1), at = -len / 2 + shift;
    for (i = 0; i < n; i++) {
        row[i].th = Math.max(-S, Math.min(S, (at + row[i].w / 2) / R));
        at += row[i].w + gap;
    }
    return (tot / n + gap) / 2;                     // half a step: what the other row is shifted by to sit in the gaps
}
function _spread(names, opt) {
    var byArc = {}, k, i;
    for (i = 0; i < names.length; i++) {
        var e = names[i];
        if (e.pinned || e.moved)
            continue;
        k = String(e.arc);
        (byArc[k] = byArc[k] || []).push(e);
    }
    for (k in byArc) {
        var list = byArc[k], inner = [], outer = [];
        list.sort(function (a, b) { return a.h0 !== b.h0 ? a.h0 - b.h0 : (a.key < b.key ? -1 : 1); });
        if (k === "bt") {
            list.forEach(function (d) { (d.paired ? inner : outer).push(d); });
        } else {
            list.forEach(function (d, j) {
                d.row = j % 2;
                (d.row ? outer : inner).push(d);
            });
        }
        var base = k === "bt" ? opt.rBt : k === "fringe" ? opt.rFringe : opt.r[Number(k)] || opt.r[0];
        var rIn = k === "bt" ? base - 10 : base - ROW, rOut = k === "bt" ? base + 20 : base + ROW;
        var half = _spreadRow(inner, rIn, opt, 0, k);
        // the outer row sits in the inner row's gaps: shifted half a step when the two rows would otherwise stand in columns
        // (the near field's two rows stand a whole plate apart: each is centred by itself)
        _spreadRow(outer, rOut, opt, k !== "bt" && inner.length === outer.length ? half : 0, k);
        list.forEach(function (d) {
            d.R = _radiusOf(d, opt);
            _put(d, opt);
        });
    }
}
function _put(e, opt) {
    e.x = opt.ox + e.R * Math.sin(e.th);
    e.y = opt.oy - e.R * Math.cos(e.th);
}
// One relaxation: every overlapping pair moves apart ALONG their arcs by what it takes to clear the smaller penetration, a kept-off rect and the popup's edge push one way.
// It is handed the NAMES only (the dots are placed after them, in the room they leave). Returns the number of overlaps it still saw: what the label budget answers.
function _relax(list, opt, iters) {
    var S = opt.span * Math.PI / 180, B = opt.bounds, av = opt.avoid || [], left = 0;
    for (var it = 0; it < iters; it++) {
        left = 0;
        for (var i = 0; i < list.length; i++) {
            var a = list[i], ra = rectOf(a);
            for (var j = i + 1; j < list.length; j++) {
                var b = list[j];
                if (a.pinned && b.pinned)
                    continue;
                var p = _pen(ra, rectOf(b), GAP);
                if (!p)
                    continue;
                left++;
                // the two centres along the arc: who is to the right. Equal angles: the key's hash decides (a pair born on one spot still parts, the same way every time)
                var dir = a.th !== b.th ? (a.th > b.th ? 1 : -1) : (a.h0 > b.h0 ? 1 : -1);
                var ta = Math.max(0.2, Math.abs(Math.cos((a.th + b.th) / 2))), tb = Math.max(0.2, Math.abs(Math.sin((a.th + b.th) / 2)));
                var ds = Math.min(p[0] / ta, p[1] / tb) * 0.55 + 0.4;
                var wa = a.pinned ? 0 : (b.pinned ? 1 : 0.5), wb = b.pinned ? 0 : (a.pinned ? 1 : 0.5);
                a.th += dir * ds * wa / a.R;
                b.th -= dir * ds * wb / b.R;
                _put(a, opt);
                _put(b, opt);
                ra = rectOf(a);
            }
        }
        for (var k = 0; k < list.length; k++) {
            var e = list[k];
            if (e.pinned)
                continue;
            for (var q = 0; q < av.length; q++) {
                var A = av[q];
                if (A.bt && e.arc !== "bt")
                    continue;
                var pp = _pen(rectOf(e), A, GAP);
                if (!pp)
                    continue;
                left++;
                var ac = Math.atan2((A.x0 + A.x1) / 2 - opt.ox, opt.oy - (A.y0 + A.y1) / 2);
                var d2 = e.th !== ac ? (e.th > ac ? 1 : -1) : ((e.h0 & 2) ? 1 : -1);
                e.th += d2 * (Math.min(pp[0], pp[1]) * 0.6 + 0.5) / e.R;
                _put(e, opt);
            }
            e.th = Math.max(-S, Math.min(S, e.th));
            _put(e, opt);
            // the popup's side edges: back toward the middle
            if (B) {
                var over = Math.max(B.x0 - (e.x - e.w / 2), 0) - Math.max((e.x + e.w / 2) - B.x1, 0);
                if (over !== 0) {
                    e.th += over / (e.R * Math.max(0.25, Math.cos(e.th)));
                    _put(e, opt);
                }
            }
        }
        if (left === 0)
            break;
    }
    return left;
}
// does `e` still stand on anything it must not (another entry of `list`, a kept-off rect)
function _blocked(e, list, opt) {
    var r = rectOf(e), av = opt.avoid || [];
    for (var i = 0; i < list.length; i++)
        if (list[i] !== e && _pen(r, rectOf(list[i]), GAP - 1.5))
            return true;
    for (var q = 0; q < av.length; q++)
        if (!(av[q].bt && e.arc !== "bt") && _pen(r, av[q], GAP - 1.5))
            return true;
    return false;
}
// may the budget make this name a dot: a stranger (a saved network, a paired device, the own hotspot and a hotspot's client keep their names)
function _yields(e) {
    return e.form === "named" && !e.known && !e.pinned && e.kind !== "client" && !(e.kind === "bt" && e.paired);
}
// a dot's box clear of every name, every kept-off rect, the popup's edge and the dots already placed
function _dotFree(d, names, taken, opt) {
    var r = rectOf(d), av = opt.avoid || [], B = opt.bounds, i;
    if (B && (r.x0 < B.x0 || r.x1 > B.x1 || r.y0 < B.y0))
        return false;
    for (i = 0; i < names.length; i++)
        if (_pen(r, rectOf(names[i]), 2))
            return false;
    for (i = 0; i < av.length; i++)
        if (!(av[i].bt && d.arc !== "bt") && _pen(r, av[i], 2))
            return false;
    for (i = 0; i < taken.length; i++)
        if (_pen(r, rectOf(taken[i]), 3))
            return false;
    return true;
}

function empty() {
    return { entries: {}, serial: 0, sig: "" };
}
// what a placement is a function of: who is there, on which arc, how large, and the fan itself. The same signature = the same places (the solver is not asked again:
// a read of the same facts must not move a tag by the fraction a second relaxation would find).
function _sig(list, opt) {
    var parts = list.map(function (e) { return [e.key, e.arc, e.kind, Math.round(e.textW), e.want, e.known ? 1 : 0, e.paired ? 1 : 0, e.secured ? 1 : 0, e.publicNet ? 1 : 0].join("~"); });
    var av = (opt.avoid || []).map(function (a) { return [Math.round(a.x0), Math.round(a.y0), Math.round(a.x1), Math.round(a.y1), a.bt ? 1 : 0].join(","); });
    var B = opt.bounds || {};
    return parts.join("|") + "#" + [opt.ox.toFixed(2), opt.oy.toFixed(2), opt.rBt, opt.r.join(","), opt.rFringe, opt.span, B.x0, B.y0, B.x1].join(",") + "#" + av.join(";");
}
// items: what the facts hold now. Returns a NEW state when anything changed (the same object otherwise, so a binding on it fires nothing).
function place(state, items, nowMs, opt) {
    var prev = state.entries, entries = {}, list = [], changed = false, k;
    var measure = opt.measure || function (it) { return 6.1 * String(it.ssid).length; };
    for (var i = 0; i < items.length; i++) {
        var it = items[i], old = prev[it.key], e = {};
        for (k in it)
            e[k] = it[k];
        e.h0 = hash(it.key);
        e.gone = false;
        e.goneAt = 0;
        // a stranger the budget made a dot stays one while it stands on that arc (a name that comes and goes with every scan would flap); the next open asks again
        e.demoted = !!(old && !old.gone && old.demoted && old.arc === it.arc && !it.known && it.want === "named" && old.kind === it.kind);
        e.form = e.demoted ? "dot" : it.want;
        e.textW = measure(it);
        var sz = sizeOf(e, e.textW);
        e.w = sz[0];
        e.h = sz[1];
        e.R = _radiusOf(e, opt);
        // sticky: an entry that stays on its arc starts from where it stood
        e.th = old && !old.gone && old.arc === e.arc && !e.pinned ? old.th : _seed(e, opt);
        e.wasDot = old && !old.gone && old.form === "dot" && e.form === "dot" && old.arc === e.arc ? [old.R, old.th] : null;
        _put(e, opt);
        entries[e.key] = e;
        list.push(e);
    }
    // a stable order for the solver: by key (the facts' order may change between two reads)
    list.sort(function (a, b) { return a.key < b.key ? -1 : a.key > b.key ? 1 : 0; });
    var sig = _sig(list, opt), same = sig === state.sig;
    if (same) {
        // the same facts on the same fan: every entry stands where it stood
        list.forEach(function (e) {
            var o = prev[e.key];
            e.form = o.form; e.demoted = o.demoted; e.w = o.w; e.h = o.h; e.R = o.R; e.th = o.th; e.x = o.x; e.y = o.y;
            e.arc = o.arc; e.row = o.row;           // (the overflow's arc and the spread's row are part of where it stood)
        });
    }
    // THE NAMES FIRST (the solver), then every dot takes the free spot of its arc nearest its own (a dot never costs a name its room, and never stands under one)
    var names = same ? [] : list.filter(function (e) { return e.form !== "dot"; });
    if (!same) {
        _overflow(names, opt);
        _spread(names, opt);
    }
    var left = same ? 0 : _relax(names, opt, 90);
    // THE LABEL BUDGET: while something still stands on something, the weakest stranger among the blocked names becomes a dot where it stands; then the saved ones' turn never comes
    // unless the facts hold more saved names than the air (they keep their names: an overlap of two saved names is the lesser fault)
    for (var round = 0; round < 40 && left > 0; round++) {
        // who stands on something, and on which arcs: the weakest stranger among the blocked goes first; where only names that keep their names are blocked (two paired
        // devices squeezed by a stranger beside them), the weakest stranger of those arcs makes the room
        var worst = null, arcs = {}, any = false;
        for (var a = 0; a < names.length; a++) {
            var c = names[a];
            if (!_blocked(c, names, opt))
                continue;
            arcs[c.arc] = true;
            any = true;
            if (_yields(c) && (!worst || c.signal < worst.signal || (c.signal === worst.signal && c.key > worst.key)))
                worst = c;
        }
        if (!any)
            break;
        if (!worst) {
            for (var b = 0; b < names.length; b++) {
                var d = names[b];
                if (arcs[d.arc] && _yields(d) && (!worst || d.signal < worst.signal || (d.signal === worst.signal && d.key > worst.key)))
                    worst = d;
            }
        }
        if (!worst)
            break;
        worst.form = "dot";
        worst.demoted = true;
        worst.w = DOT;
        worst.h = DOT;
        worst.th = _seed(worst, opt);               // (where it was pushed to as a name is not its own place)
        names.splice(names.indexOf(worst), 1);
        _spread(names, opt);
        left = _relax(names, opt, 60);
    }
    // THE DOTS: each on its arc's own line (between the two rows of names), at the free angle nearest its own; where the line has no room, in the air just outside or
    // inside the arc. In key order, so the same facts give the same picture.
    var S = opt.span * Math.PI / 180, taken = [];
    for (var di = 0; di < list.length && !same; di++) {
        var dot = list[di];
        if (dot.form !== "dot")
            continue;
        var base = _radiusOf(dot, opt), th0 = Math.max(-S, Math.min(S, dot.th)), found = false;
        var radii = dot.arc === "bt" ? [base, base + 20, base - 10] : dot.arc === "fringe" ? [base, base + MID, base - MID] : [base + MID, base - MID, base];
        // sticky: a dot that still has its old spot keeps it (the ring it found too)
        if (dot.wasDot) {
            dot.R = dot.wasDot[0];
            dot.th = dot.wasDot[1];
            _put(dot, opt);
            found = _dotFree(dot, names, taken, opt);
            if (!found)
                th0 = Math.max(-S, Math.min(S, dot.wasDot[1]));
        }
        for (var ri = 0; ri < radii.length && !found; ri++) {
            for (var step = 0; step <= 140 && !found; step++) {
                var th = th0 + (step % 2 ? 1 : -1) * Math.ceil(step / 2) * 0.016;
                if (th < -S * 1.04 || th > S * 1.04)
                    continue;
                dot.R = radii[ri];
                dot.th = th;
                _put(dot, opt);
                if (_dotFree(dot, names, taken, opt))
                    found = true;
            }
        }
        if (!found) {
            dot.R = base;
            dot.th = th0;
            _put(dot, opt);
        }
        taken.push(dot);
    }
    // the leavers stay for their fade, where they stood
    for (k in prev) {
        if (entries[k])
            continue;
        var g = prev[k];
        if (g.gone) {
            if (nowMs - g.goneAt < FADE_MS)
                entries[k] = g;
            else
                changed = true;
        } else {
            var cp = {};
            for (var f in g)
                cp[f] = g[f];
            cp.gone = true;
            cp.goneAt = nowMs;
            entries[k] = cp;
            changed = true;
        }
    }
    if (!changed) {
        for (k in entries) {
            var n = entries[k], o = prev[k];
            if (!o || o.gone !== n.gone || o.form !== n.form || o.arc !== n.arc || Math.abs(o.x - n.x) > 0.05 || Math.abs(o.y - n.y) > 0.05 || o.ssid !== n.ssid || o.w !== n.w
                || o.signal !== n.signal || o.state !== n.state || o.secured !== n.secured || o.publicNet !== n.publicNet || o.known !== n.known || o.paired !== n.paired
                || o.pairing !== n.pairing || o.bestBand !== n.bestBand || o.dev !== n.dev) {
                changed = true;
                break;
            }
        }
    }
    return changed ? { entries: entries, serial: state.serial + 1, sig: sig } : state;
}
function keysOf(state) {
    return Object.keys(state.entries).sort();
}

// ---- the label's zones ----------------------------------------------------------------------
// a rect of the label in card-local mm ({ x0, x1, y0, y1 }: G.LABEL_ZONE, G.LABEL_BT, G.LABEL itself) -> its four corners in item px under the scene's label map
function zonePoly(G, map, rect) {
    var Z = rect || G.LABEL_ZONE, L = G.LABEL, out = [];
    [[Z.x0, Z.y0], [Z.x1, Z.y0], [Z.x1, Z.y1], [Z.x0, Z.y1]].forEach(function (p) {
        var lx = p[0] - L.x0, ly = p[1] - L.y0;
        out.push([map.a * lx + map.b * ly + map.tx, map.c * lx + map.d * ly + map.ty]);
    });
    return out;
}
// item px -> card-local mm on the label's plane (the map's inverse); mmToPx the other way
function labelPoint(G, map, x, y) {
    var det = map.a * map.d - map.b * map.c, dx = x - map.tx, dy = y - map.ty;
    if (Math.abs(det) < 1e-9)
        return [0, 0];
    return [(map.d * dx - map.b * dy) / det + G.LABEL.x0, (-map.c * dx + map.a * dy) / det + G.LABEL.y0];
}
function labelPx(G, map, lx, ly) {
    var u = lx - G.LABEL.x0, v = ly - G.LABEL.y0;
    return [map.a * u + map.b * v + map.tx, map.c * u + map.d * v + map.ty];
}
function centreOf(poly) {
    var x = 0, y = 0;
    poly.forEach(function (p) { x += p[0]; y += p[1]; });
    return [x / poly.length, y / poly.length];
}
function inPoly(poly, x, y) {
    var pos = false, neg = false;
    for (var i = 0; i < poly.length; i++) {
        var a = poly[i], b = poly[(i + 1) % poly.length];
        var cr = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
        if (cr > 0) pos = true; else if (cr < 0) neg = true;
        if (pos && neg) return false;
    }
    return true;
}
function distToPoly(poly, x, y) {
    if (inPoly(poly, x, y))
        return 0;
    var best = 1e9;
    for (var i = 0; i < poly.length; i++) {
        var a = poly[i], b = poly[(i + 1) % poly.length];
        var dx = b[0] - a[0], dy = b[1] - a[1], t = Math.max(0, Math.min(1, ((x - a[0]) * dx + (y - a[1]) * dy) / (dx * dx + dy * dy || 1)));
        best = Math.min(best, Math.hypot(x - a[0] - t * dx, y - a[1] - t * dy));
    }
    return best;
}
// the padded bounding rect of projected points (a kept-off area for the solver)
function boundsOf(pts, pad) {
    var x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9, p = pad || 0;
    pts.forEach(function (q) { x0 = Math.min(x0, q[0]); y0 = Math.min(y0, q[1]); x1 = Math.max(x1, q[0]); y1 = Math.max(y1, q[1]); });
    return { x0: x0 - p, y0: y0 - p, x1: x1 + p, y1: y1 + p };
}

// ---- the pulse ------------------------------------------------------------------------------
// THE PULSE'S CLOCK, shared by the field's shader (which is handed `phase`) and the tags' glint: a wavefront leaves the origin every PERIOD seconds, takes TRAVEL of the period
// to reach `rEnd`, slowing a little as it goes (the same curve in cloud.frag: keep the two in step).
var PULSE_PERIOD = 2.6, PULSE_TRAVEL = 0.82;
function pulsePhase(time, period) {
    var p = period > 0 ? period : PULSE_PERIOD, t = time / p;
    return t - Math.floor(t);
}
// the wavefront's radius at a phase (px), -1 while none is in flight
function pulseRadius(phase, rEnd) {
    var u = phase / PULSE_TRAVEL;
    if (u >= 1)
        return -1;
    return rEnd * (1 - Math.pow(1 - u, 1.35));
}
// a tag's glint 0..1 at radius r: full as the front reaches it, gone `tail` px behind it
function glint(phase, rEnd, r, tail) {
    var rp = pulseRadius(phase, rEnd);
    if (rp < 0 || rp < r)
        return 0;
    return Math.max(0, 1 - (rp - r) / (tail > 0 ? tail : 26));
}
