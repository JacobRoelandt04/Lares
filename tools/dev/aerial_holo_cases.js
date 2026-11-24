// aerial_holo_cases.js -- the pure half of the cloud's proof (node): CloudPlace.js's placement on the popup's real camera (round 3: THE SIGNAL FAN).
//   node tools/dev/aerial_holo_cases.js            AERIAL_HOLO_CASES RESULT PASS|FAIL
//   ARM=norelax   the solver is skipped (every tag stands on its seed): no-overlap must FAIL
//   ARM=noseed    the seed ignores the key (an angle from the list's order): same-place-any-order must FAIL
//   ARM=nobudget  no stranger is ever made a dot: capacity-no-overlap must FAIL
//   ARM=wrongarc  every network stands on the first arc: band-to-arc must FAIL
var fs = require("fs"), path = require("path");
var L = require("./aerial_node_load.js");
var ARM = process.env.ARM || "";
var src = fs.readFileSync(path.join(__dirname, "../../modules/aerial/scene/CloudPlace.js"), "utf8").replace(/^\.pragma library/m, "");
function arm(a, b) {
    if (src.indexOf(a) < 0) { console.log("AH arm-anchor FAIL the anchor is gone: " + a); process.exit(1); }
    src = src.replace(a, b);
}
if (ARM === "norelax")
    arm("var left = same ? 0 : _relax(names, opt, 90);", "var left = 0;");
if (ARM === "noseed")
    arm("var S = opt.span * Math.PI / 180, u = rnd(e.h0, 0) * 2 - 1;", "var S = opt.span * Math.PI / 180, u = ((opt._n = (opt._n || 0) + 1) % 9) / 4.5 - 1;");
if (ARM === "nobudget")
    arm("round < 40 && left > 0", "round < 0 && left > 0");
if (ARM === "wrongarc")
    arm("arc: band >= 2 ? \"fringe\" : band, signal: n.signal | 0,", "arc: 0, signal: n.signal | 0,");
var P = new Function(src + "\nreturn { hash, rnd, itemsOfWifi, itemsOfBt, itemsOfClients, hotspotItem, place, empty, rectOf, overlaps, sizeOf, keysOf, zonePoly, labelPoint, labelPx, centreOf, inPoly, distToPoly, pulseRadius, pulsePhase, glint, ROW, GAP, TW_MAX, PULSE_TRAVEL, FADE_MS };")();
var fails = [];
function check(n, ok, why) { console.log("AH " + n + " " + (ok ? "PASS" : "FAIL") + (why ? " " + why : "")); if (!ok) fails.push(n); }

// the popup's real fan
var W = 760, F = L.Cam.cloud(L.G, W), O = L.proj(L.G.ANCHORS.cloud), SPAN = F.span * Math.PI / 180;
function measure(it) { return 6.1 * String(it.ssid || "Hidden network").length + 1; }
var AVOID = [{ x0: O[0] + 70, x1: O[0] + 110, y0: O[1] - 70, y1: O[1] - 40, bt: true }];
function opt(extra) {
    var o = { ox: O[0], oy: O[1], rBt: F.rBt, r: F.r, rFringe: F.rFringe, span: F.span, measure: measure, bounds: { x0: 8, y0: 8, x1: W - 8, y1: 1e5 }, avoid: AVOID };
    for (var k in (extra || {})) o[k] = extra[k];
    return o;
}
var NAMES = ["Home-5G", "eduroam", "Cafe-Free", "Saved-Network-123456", "homenet-ABC12", "homenet-ABC12_5Ghz", "homenet-ABC12-AP", "AndroidAP_4821", "ZyXEL-AX", "Tesla Service", "SFR_WiFi",
             "Starlink", "REDMAGIC 10S Pro", "Chromecast-71", "DIRECT-roku-381", "Hotel Lobby", "Library", "Printer-HP", "VOO-884321", "iPhone van Tom", "WiFi-Repeater", "FRITZ!Box 7590",
             "Orange-2F1A", "KPN Fon", "Ziggo4829", "TP-Link_88C0", "NETGEAR42", "bbox-3D0E", "Livebox-9A2C", "UPC1234567", "Guest", "linksys", "dlink-6C10", "H369A1B2C3"];
function net(i, band, o) {
    var n = { key: NAMES[i % NAMES.length] + (i >= NAMES.length ? "#" + i : ""), ssid: NAMES[i % NAMES.length], hidden: false, security: i % 4 ? "wpa2" : "open", signalBand: band, signal: 96 - band * 22 - (i * 7) % 13,
              known: i % 6 === 0, bands: i % 2 ? ["2.4", "5"] : ["5"], bestBand: "5", connected: false, state: "idle" };
    for (var k in (o || {})) n[k] = o[k];
    return n;
}
function wifi(list) { return { present: true, radioOn: true, networks: list }; }
function live(st) { return Object.keys(st.entries).map(function (k) { return st.entries[k]; }).filter(function (e) { return !e.gone; }); }
function named(st) { return live(st).filter(function (e) { return e.form !== "dot"; }); }
function worstOverlap(list, gap) {
    var bad = [];
    for (var i = 0; i < list.length; i++)
        for (var j = i + 1; j < list.length; j++)
            if (P.overlaps(P.rectOf(list[i]), P.rectOf(list[j]), gap))
                bad.push(list[i].key + " x " + list[j].key);
    return bad;
}

// ---- a home, a crowd ----
var home = [net(0, 1, { known: true }), net(1, 2, { known: true }), net(2, 1), net(3, 3, { known: true })];
var crowd = [];
for (var i = 0; i < 34; i++) crowd.push(net(i, [0, 1, 2, 3, 1, 0, 2][i % 7]));
crowd.push({ key: "hidden:aa", ssid: "", hidden: true, security: "wpa2", signalBand: 1, signal: 60, known: false, bands: ["2.4"], bestBand: "2.4", connected: false });
var BT = { present: true, powered: true, devices: [
    { address: "AA:01", name: "Earbuds", kind: "earbuds", connected: true, paired: true }, { address: "AA:02", name: "Pixel 8", kind: "phone", connected: false, paired: true },
    { address: "AA:03", name: "MX Master 3S", kind: "mouse", connected: false, paired: true }, { address: "AA:04", name: "Pixel 9", kind: "phone", connected: false, paired: false },
    { address: "AA:05", name: "LE-Bose QC", kind: "headset", connected: false, paired: false }, { address: "AA:06", name: "blocked", kind: "generic", connected: false, paired: true, blocked: true }] };
function itemsOf(nets, bt, hs) {
    var it = P.itemsOfWifi(wifi(nets));
    if (hs) it.push(P.hotspotItem({ ssid: "laptop-share" }));
    return it.concat(P.itemsOfBt(bt || null));
}
var stHome = P.place(P.empty(), itemsOf(home, BT, true), 1000, opt());
var stCrowd = P.place(P.empty(), itemsOf(crowd, BT, true), 1000, opt());

// 1. every band on its arc -- band 0 the first, 1 the second, 2 and 3 the fringe; Bluetooth on the near field -- where the arc has room (a home); in a crowd a name may
//    stand FURTHER OUT than its band's arc (the overflow), never nearer, and of two names of one band the one that overflowed is never the stronger
function onArc(e) {
    var r = Math.hypot(e.x - O[0], e.y - O[1]), arcs = [F.r[0], F.r[1], F.rFringe], best = 0;
    if (e.kind === "bt" || e.kind === "hotspot")
        return -1;
    arcs.forEach(function (a, i) { if (Math.abs(r - a) < Math.abs(r - arcs[best])) best = i; });
    return best;
}
(function () {
    var bad = [];
    named(stHome).forEach(function (e) {
        var r = Math.hypot(e.x - O[0], e.y - O[1]);
        var want = e.kind === "bt" ? F.rBt : e.kind === "hotspot" ? F.r[0] : e.band >= 2 ? F.rFringe : F.r[e.band];
        if (Math.abs(r - want) > 16 + 6.5)
            bad.push(e.key + " r=" + r.toFixed(0) + " want " + want);
    });
    var nets = named(stCrowd).filter(function (e) { return e.kind === "net"; });
    nets.forEach(function (e) {
        if (onArc(e) < Math.min(2, e.band))
            bad.push(e.key + " stands nearer than its band " + e.band);
    });
    nets.forEach(function (a) {
        nets.forEach(function (b) {
            if (a.band === b.band && onArc(a) > Math.min(2, a.band) && onArc(b) === Math.min(2, b.band) && a.signal > b.signal)
                bad.push(a.key + " (" + a.signal + ") overflowed while the weaker " + b.key + " (" + b.signal + ") stayed");
        });
    });
    check("band-to-arc", bad.length === 0, bad.slice(0, 3).join("; "));
})();
// 1b. THE SPREAD: a crowd's names stand on both sides of the fan about evenly (hashed angles once left one side bare), and an inner arc's names keep nearer the
//     vertical than the fringe's (the fan widens as it rises)
(function () {
    var nets = named(stCrowd).filter(function (e) { return e.kind === "net"; }), l = 0, r = 0, in0 = 0, inF = 0;
    nets.forEach(function (e) {
        var th = Math.atan2(e.x - O[0], O[1] - e.y);
        if (th < 0) l++; else r++;
        if (onArc(e) === 0) in0 = Math.max(in0, Math.abs(th));
        if (onArc(e) === 2) inF = Math.max(inF, Math.abs(th));
    });
    check("spread-both-sides", nets.length >= 8 && Math.abs(l - r) <= Math.max(2, nets.length * 0.25) && in0 < inF, "left " + l + " right " + r + " widest first " + in0.toFixed(2) + " fringe " + inF.toFixed(2));
})();
// 2. nothing over anything: no two names, no name over a dot, in a home and in a crowd
check("no-overlap-home", worstOverlap(named(stHome), 0).length === 0, worstOverlap(named(stHome), 0).slice(0, 3).join("; "));
check("no-overlap-crowd", worstOverlap(named(stCrowd), 0).length === 0, worstOverlap(named(stCrowd), 0).slice(0, 3).join("; "));
(function () {
    var dots = live(stCrowd).filter(function (e) { return e.form === "dot"; }), nm = named(stCrowd), bad = 0;
    dots.forEach(function (d) { nm.forEach(function (n) { if (P.overlaps(P.rectOf(d), P.rectOf(n), 0)) bad++; }); });
    check("no-dot-under-a-name", bad === 0, bad + " dots under names");
})();
// 3. inside the popup and inside the fan
(function () {
    var bad = [];
    live(stCrowd).concat(live(stHome)).forEach(function (e) {
        var r = P.rectOf(e), th = Math.atan2(e.x - O[0], O[1] - e.y);
        if (r.x0 < 8 - 0.01 || r.x1 > W - 8 + 0.01 || r.y0 < 8 - 0.01)
            bad.push(e.key + " out of the popup");
        if (Math.abs(th) > SPAN * 1.05 + 1e-6)
            bad.push(e.key + " out of the fan");
    });
    check("inside-popup-and-fan", bad.length === 0, bad.slice(0, 3).join("; "));
})();
// 4. a place is the key's own: the same from any order of the facts, at every open; a second read of the same facts changes nothing (the same state object)
(function () {
    var it = itemsOf(crowd, BT, true), rev = it.slice().reverse();
    var a = P.place(P.empty(), it, 1000, opt()), b = P.place(P.empty(), rev, 5000, opt()), bad = 0;
    for (var k in a.entries)
        if (!b.entries[k] || Math.abs(a.entries[k].x - b.entries[k].x) > 0.01 || Math.abs(a.entries[k].y - b.entries[k].y) > 0.01 || a.entries[k].form !== b.entries[k].form)
            bad++;
    check("same-place-any-order", bad === 0, bad + " of " + Object.keys(a.entries).length + " differ");
    check("same-facts-same-state", P.place(a, it, 2000, opt()) === a);
})();
// 5. an arrival re-spaces ITS OWN arc (the spread keeps a row even) and nothing else: the names of the other arcs and the near field stand where they stood
(function () {
    var before = P.place(P.empty(), itemsOf(home.concat([net(7, 0), net(8, 1), net(12, 0)]), BT, true), 1000, opt());
    var after = P.place(before, itemsOf(home.concat([net(7, 0), net(8, 1), net(12, 0), net(13, 0)]), BT, true), 2000, opt());
    var moved = 0, n = 0, who = [];
    function count(st, arc) {
        var c = [];
        for (var q in st.entries)
            if (!st.entries[q].gone && st.entries[q].form !== "dot" && String(st.entries[q].arc) === String(arc)) c.push(q);
        return c.sort().join("|");              // WHO stands on the arc (one in and one out is a change too)
    }
    for (var k in before.entries) {
        n++;
        // (an arc whose names changed -- the arrival's own, and one that took its overflow -- is re-spaced: that is the spread)
        if (count(before, before.entries[k].arc) !== count(after, before.entries[k].arc) || String(before.entries[k].arc) !== String(after.entries[k].arc))
            continue;
        if (Math.hypot(before.entries[k].x - after.entries[k].x, before.entries[k].y - after.entries[k].y) > 0.5) {
            moved++;
            who.push(k + ":" + before.entries[k].arc + ":" + before.entries[k].form + " " + Math.hypot(before.entries[k].x - after.entries[k].x, before.entries[k].y - after.entries[k].y).toFixed(1));
        }
    }
    check("arrival-moves-few", after.entries[net(13, 0).key] && moved === 0, moved + " of " + n + " moved on arcs whose names did not change " + who.join(", "));
    // a leaver stays for its fade where it stood, then goes
    var gone = P.place(after, itemsOf(home, BT, true), 3000, opt()), g = gone.entries[net(13, 0).key];
    check("leaver-fades-in-place", !!g && g.gone === true && Math.abs(g.x - after.entries[g.key].x) < 0.01, "");
    var later = P.place(gone, itemsOf(home, BT, true), 3000 + P.FADE_MS + 10, opt());
    check("leaver-pruned", !later.entries[net(13, 0).key]);
})();
// 6. THE LABEL BUDGET: an arc that cannot hold its names makes the weakest strangers dots, saved networks keep theirs, and still nothing overlaps
(function () {
    var many = [];
    for (var i = 0; i < 30; i++) many.push(net(i, 0, { known: i < 4, signal: 95 - i }));
    var st = P.place(P.empty(), itemsOf(many, null, false), 1000, opt()), nm = named(st), dots = live(st).filter(function (e) { return e.form === "dot"; });
    var bad = worstOverlap(nm, 0);
    check("capacity-no-overlap", bad.length === 0, bad.length + " overlaps, " + nm.length + " names");
    check("capacity-demotes-strangers", dots.length > 0 && dots.every(function (d) { return !d.known; }) && many.slice(0, 4).every(function (n) { return st.entries[n.key].form === "named"; }),
          dots.length + " dots, " + nm.length + " names");
    check("capacity-keeps-some-names", nm.length >= 5, nm.length + " names on one arc");
    // a stranger made a dot stays one while the facts stand (no flapping from scan to scan)
    var again = P.place(st, itemsOf(many.slice(0, 29), null, false), 2000, opt()), flips = 0;
    dots.forEach(function (d) { if (again.entries[d.key] && !again.entries[d.key].gone && again.entries[d.key].form !== "dot") flips++; });
    check("demoted-does-not-flap", flips === 0, flips + " came back as names");
})();
// 7. kept-off areas: the near field keeps off its avoid rect (the screw / the cables), nothing takes the own hotspot's reserved spot, and the hotspot stands at the fan's lower left
(function () {
    var es = live(stCrowd), hs = stCrowd.entries.hotspot, bad = [];
    es.forEach(function (e) {
        if (e.kind === "bt" && P.overlaps(P.rectOf(e), AVOID[0], 0)) bad.push(e.key + " on the kept-off rect");
        if (e !== hs && e.form !== "dot" && P.overlaps(P.rectOf(e), P.rectOf(hs), 0)) bad.push(e.key + " on the hotspot's spot");
    });
    var th = Math.atan2(hs.x - O[0], O[1] - hs.y);
    check("kept-off-and-reserved", bad.length === 0 && Math.abs(th + SPAN) < 0.02, bad.slice(0, 3).join("; ") + " hotspot th=" + th.toFixed(2));
})();
// 8. the near field: connected and blocked devices are not in the air; paired ones on the inner row, strangers on the outer one, both about the fan's middle (the near
//    field keeps to the narrow foot of the fan)
(function () {
    var st = P.place(P.empty(), P.itemsOfBt(BT), 1000, opt({ avoid: [] }));
    var bt = live(st), keys = bt.map(function (e) { return e.key; }).sort().join(",");
    var th = function (e) { return Math.abs(Math.atan2(e.x - O[0], O[1] - e.y)); }, rad = function (e) { return Math.hypot(e.x - O[0], e.y - O[1]); };
    var paired = bt.filter(function (e) { return e.paired; }), strange = bt.filter(function (e) { return !e.paired; });
    check("near-field-who", keys === "AA:02,AA:03,AA:04,AA:05", keys);
    var mean = function (l) { return l.reduce(function (a, e) { return a + th(e); }, 0) / l.length; };
    check("near-field-where", paired.every(function (e) { return rad(e) < F.rBt && th(e) < SPAN * 0.56; }) && strange.every(function (e) { return rad(e) > F.rBt && th(e) < SPAN * 0.56; }),
          "paired " + paired.map(function (e) { return th(e).toFixed(2); }) + " strangers " + strange.map(function (e) { return th(e).toFixed(2); }));
    check("near-field-off", P.itemsOfBt({ present: true, powered: false, devices: BT.devices }).length === 0);
    // a busy search: the strangers that find no room are dots, the paired devices keep their names, nothing overlaps
    var many = BT.devices.slice(0, 3);
    for (var i = 0; i < 12; i++) many.push({ address: "CC:" + i, name: "LE-Device " + i, kind: "generic", connected: false, paired: false, rssi: -50 - i * 3 });
    var busy = P.place(P.empty(), P.itemsOfBt({ present: true, powered: true, devices: many }).concat([P.hotspotItem({ ssid: "laptop-share" })]), 1000, opt());
    var nm = named(busy);
    check("near-field-budget", worstOverlap(nm, 0).length === 0 && busy.entries["AA:02"].form === "named" && busy.entries["AA:03"].form === "named" && live(busy).some(function (e) { return e.form === "dot"; }),
          nm.length + " names, " + worstOverlap(nm, 0).length + " overlaps");
})();
// 9. the label's zones: card-local mm <-> item px is one map and its inverse
(function () {
    var map = L.Cam.labelMap(L.G, L.cam, 0), Z = L.G.LABEL_BT, poly = P.zonePoly(L.G, map, Z), c = P.centreOf(poly), back = P.labelPoint(L.G, map, c[0], c[1]);
    var fwd = P.labelPx(L.G, map, back[0], back[1]);
    check("label-map-round-trip", Math.abs(back[0] - (Z.x0 + Z.x1) / 2) < 1e-6 && Math.abs(back[1] - (Z.y0 + Z.y1) / 2) < 1e-6 && Math.hypot(fwd[0] - c[0], fwd[1] - c[1]) < 1e-6, back.map(function (v) { return v.toFixed(3); }).join(","));
    var wz = P.zonePoly(L.G, map, L.G.LABEL_ZONE), wc = P.centreOf(wz);
    check("label-zones-apart", P.inPoly(wz, wc[0], wc[1]) && !P.inPoly(poly, wc[0], wc[1]) && P.distToPoly(poly, c[0], c[1]) === 0);
})();
// 10. the pulse: the front runs out monotonically and is gone after its share of the period; a tag glints as the front reaches it and not before
(function () {
    var rEnd = F.rFringe + 22, prev = -1, mono = true;
    for (var ph = 0.01; ph < P.PULSE_TRAVEL; ph += 0.02) { var r = P.pulseRadius(ph, rEnd); if (r <= prev) mono = false; prev = r; }
    check("pulse-front", mono && P.pulseRadius(P.PULSE_TRAVEL + 0.01, rEnd) < 0 && Math.abs(P.pulseRadius(P.PULSE_TRAVEL - 1e-9, rEnd) - rEnd) < 0.5);
    var at = 0;
    for (var p2 = 0; p2 < 1; p2 += 0.001) if (P.pulseRadius(p2, rEnd) >= F.r[0]) { at = p2; break; }
    check("glint-as-the-front-passes", P.glint(at - 0.02, rEnd, F.r[0], 30) === 0 && P.glint(at, rEnd, F.r[0], 30) > 0.9 && P.glint(at + 0.2, rEnd, F.r[0], 30) === 0,
          [P.glint(at - 0.02, rEnd, F.r[0], 30), P.glint(at, rEnd, F.r[0], 30), P.glint(at + 0.2, rEnd, F.r[0], 30)].join(" "));
})();

console.log("AERIAL_HOLO_CASES RESULT " + (fails.length ? "FAIL (" + fails.join(", ") + ")" : "PASS"));
process.exit(fails.length ? 1 : 0);
