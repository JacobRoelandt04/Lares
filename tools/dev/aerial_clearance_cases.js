"use strict";
// aerial_clearance_cases.js -- aerial's board laid out with room between its things (round 5: a decoupling cap stood on a trace, a display's courtyard ran over a mounting
// hole's ring, a chip crowded a hole). Everything is computed from AerialGeometry.js, in board mm, edge to edge:
//
//   a DECORATION (a grey chip, a row of passives)   clear of every trace, hole ring, grommet, cut-out, courtyard, part, other decoration, printed name and the board's edge;
//                                                   never under the card
//   a COURTYARD (the outline round a control)        clear of the hole rings, the cut-out, the other courtyards, every part that is not its own, the board's edge
//   a TRACE                                          clear of the hole rings and the cut-out; it enters only the courtyard of a part it ends at
//   a printed NAME                                   clear of the hole rings and the cut-out (make_silk.py --check holds it clear of parts, courtyards and traces)
//   the CUT-OUT and the HOLES                        on the board, clear of every part and of the card
//
//   node tools/dev/aerial_clearance_cases.js [path/to/AerialGeometry.js]     ends in AERIAL_CLEARANCE RESULT PASS|FAIL (every breach on its own line)
//   ARM=capontrace   the slot's decoupling caps stand where round 4 had them (the last one on the DATA display's trace) -- must FAIL (decoCapsB / usageLine)
//   ARM=chipathole   the regulator stands where round 4 had it, in the back corner's hole ring -- must FAIL (decoQfn1 / hole)
//   ARM=bigyard      the displays' courtyards are 2.2 mm wide (one runs over the front hole's ring) -- must FAIL (courtyard / hole)
// And the ROUTES (round 6: the pulse trains jumped at the joints): a trace that starts on another carries that one's coordinate at the junction, so the train runs on.
//   ARM=nolink       every trace's coordinate starts at 0 again -- must FAIL (route ... joins ...)
const fs = require("fs");
const path = require("path");
const file = process.argv[2] || path.join(__dirname, "..", "..", "modules/aerial/scene/AerialGeometry.js");
let src = fs.readFileSync(file, "utf8").replace(/^\.pragma.*$/m, "");
const ARMS = {
    capontrace: ['{ name: "decoCapsB", x: -13.2,', '{ name: "decoCapsB", x: -11.6,'],
    chipathole: ['{ name: "decoQfn1", x: -26.9, z: -21.8,', '{ name: "decoQfn1", x: -29.2, z: -24.2,'],
    nolink: ["    out.forEach(function (t, i) { linkRoute(t, out.slice(0, i)); });", ""],
    bigyard: ["        out.push({ r: _pad(d.body, 0.8).concat([0.8]) });", "        out.push({ r: _pad(d.body, 2.2).concat([0.8]) });"]
};
if (process.env.ARM) {
    const arm = ARMS[process.env.ARM];
    if (!arm || src.split(arm[0]).length !== 2) {
        console.log("AERIAL_CLEARANCE RESULT FAIL (arm " + process.env.ARM + ": its anchor is gone)");
        process.exit(2);
    }
    src = src.replace(arm[0], arm[1]);
}
const G = new Function(src + ";return { linkRoute: linkRoute, BOARD: BOARD, CARD: CARD, SOCKET: SOCKET, DIP: DIP, MEM: MEM, BTN: BTN, BEACON: BEACON, JACK: JACK, PADS: PADS, LENS: LENS, SEG7: SEG7, CUTS: CUTS, DECO: DECO, TRACES: TRACES, COURTYARDS: COURTYARDS, SILK_AVOID: SILK_AVOID, LABELS: LABELS };")();

// ---- shapes: a rect [x0, z0, x1, z1], a disc [x, z, r]; distances are edge to edge, negative = overlapping ----
function ptRect(p, r) {
    const dx = Math.max(r[0] - p[0], 0, p[0] - r[2]), dz = Math.max(r[1] - p[1], 0, p[1] - r[3]);
    if (dx > 0 || dz > 0)
        return Math.hypot(dx, dz);
    return -Math.min(p[0] - r[0], r[2] - p[0], p[1] - r[1], r[3] - p[1]);
}
function rectRect(a, b) {
    const dx = Math.max(a[0] - b[2], b[0] - a[2]), dz = Math.max(a[1] - b[3], b[1] - a[3]);
    if (dx > 0 || dz > 0)
        return Math.hypot(Math.max(dx, 0), Math.max(dz, 0));
    return Math.max(dx, dz);
}
function discRect(c, r) { return ptRect([c[0], c[1]], r) - c[2]; }
function discDisc(a, b) { return Math.hypot(a[0] - b[0], a[1] - b[1]) - a[2] - b[2]; }
function inside(a, b) { return a[0] >= b[0] && a[1] >= b[1] && a[2] <= b[2] && a[3] <= b[3]; }
// a polyline with a half width as a chain of discs every 0.1 mm
function chain(pts, hw) {
    const out = [];
    for (let i = 0; i + 1 < pts.length; i++) {
        const a = pts[i], b = pts[i + 1], n = Math.max(1, Math.ceil(Math.hypot(b[0] - a[0], b[1] - a[1]) / 0.1));
        for (let k = 0; k <= n; k++)
            out.push([a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n, hw]);
    }
    return out;
}
function minOver(discs, fn) { let m = 1e9; for (const d of discs) m = Math.min(m, fn(d)); return m; }
// (round 6: no cut-out any more; a cut-out a later round adds is checked as before)

// ---- the board's things ----
const board = [G.BOARD.x0, G.BOARD.z0, G.BOARD.x1, G.BOARD.z1];
const card = [G.CARD.x0, G.CARD.z0, G.CARD.x0 + G.CARD.w, G.CARD.z0 + G.CARD.h];
const decos = G.DECO.map((d) => ({
    name: d.name,
    r: d.row ? [d.x, d.z, d.x + (d.row.n[0] - 1) * d.row.pitch[0] + d.cell[0], d.z + (d.row.n[1] - 1) * d.row.pitch[1] + d.cell[2]] : [d.x, d.z, d.x + d.w, d.z + d.d]
}));
const parts = [
    { name: "socket", r: [G.SOCKET.x0, G.SOCKET.z0, G.SOCKET.x1, G.SOCKET.z1] },
    { name: "dip", r: [G.DIP.x0, G.DIP.z0, G.DIP.x1, G.DIP.z1] },
    { name: "mem", r: [G.MEM.x0, G.MEM.z0 - 0.8, G.MEM.x1, G.MEM.z1 + 0.8] },
    { name: "btn", r: [G.BTN.x0, G.BTN.z0, G.BTN.x1, G.BTN.z1] },
    { name: "jack", r: [G.JACK.x0, G.JACK.z0, G.JACK.x1, G.JACK.z1] },
    { name: "beacon", r: [G.BEACON.x - G.BEACON.r, G.BEACON.z - G.BEACON.r, G.BEACON.x + G.BEACON.r, G.BEACON.z + G.BEACON.r], disc: [G.BEACON.x, G.BEACON.z, G.BEACON.r] },
    { name: "lens", r: [G.LENS.x - G.LENS.base, G.LENS.z - G.LENS.base, G.LENS.x + G.LENS.base, G.LENS.z + G.LENS.base], disc: [G.LENS.x, G.LENS.z, G.LENS.base] }
].concat(G.SEG7.map((d) => ({ name: d.name, r: d.body })))
 .concat(G.PADS.zs.map((z, i) => ({ name: "pad." + G.PADS.names[i], r: [G.PADS.x - G.PADS.w / 2, z - G.PADS.d / 2, G.PADS.x + G.PADS.w / 2, z + G.PADS.d / 2] })));
const yards = G.COURTYARDS.map((c, i) => c.r ? { name: "courtyard#" + i, r: c.r.slice(0, 4) } : { name: "courtyard#" + i, r: [c.c[0] - c.c[2], c.c[1] - c.c[2], c.c[0] + c.c[2], c.c[1] + c.c[2]], disc: c.c });
yards.forEach((y) => { const own = parts.filter((p) => inside(p.r, y.r)); y.own = own.map((p) => p.name); if (own.length) y.name = "courtyard(" + own[0].name + ")"; });
const holes = G.CUTS.holes.map((h, i) => ({ name: "hole#" + i, d: [h[0], h[1], G.CUTS.ringR] }))
    .concat(G.CUTS.grommets.map((h, i) => ({ name: "grommet#" + i, d: [h[0], h[1], G.CUTS.grommetRing] })));
// the cut-out as discs: round 4's straight slot, or the arc with its keyhole
const S = G.CUTS.slot;
let cut = [];
if (!S) {
    cut = [];
} else if (S.R !== undefined) {
    const pts = [];
    for (let a = S.a0; a <= S.a1 + 1e-6; a += 0.5)
        pts.push([S.cx + S.R * Math.cos(a * Math.PI / 180), S.cz + S.R * Math.sin(a * Math.PI / 180)]);
    cut = chain(pts, S.r);
    const e = pts[pts.length - 1];
    cut.push([e[0], e[1], S.keyR]);
} else {
    cut = chain([[S.x0, S.z], [S.x1, S.z]], S.r);
}
const traces = G.TRACES.map((t) => ({ name: t.name, discs: chain(t.pts, t.width / 2), ends: [t.pts[0], t.pts[t.pts.length - 1]] }));
const names = G.SILK_AVOID.map((r, i) => ({ name: "name '" + G.LABELS[i].text + "'", r: r }));

function isPad(y) { return y.own.length > 0 && y.own[0].indexOf("pad.") === 0; }

// ---- the rules ----
const bad = [];
function need(what, gap, min) {
    if (gap < min - 1e-6)
        bad.push(what + ": " + (gap < 0 ? "overlap by " + (-gap).toFixed(2) : gap.toFixed(2)) + " mm (needs " + min + ")");
}
decos.forEach((d) => {
    traces.forEach((t) => need(d.name + " / trace " + t.name, minOver(t.discs, (c) => discRect(c, d.r)), 0.5));
    holes.forEach((h) => need(d.name + " / " + h.name, discRect(h.d, d.r), 0.8));
    need(d.name + " / the cut-out", minOver(cut, (c) => discRect(c, d.r)), 0.8);
    yards.forEach((y) => need(d.name + " / " + y.name, y.disc ? discRect(y.disc, d.r) : rectRect(d.r, y.r), 0.4));
    parts.forEach((p) => need(d.name + " / " + p.name, rectRect(d.r, p.r), 0.5));
    need(d.name + " / under the card", rectRect(d.r, card), 0.4);
    decos.forEach((o) => { if (o.name < d.name) need(d.name + " / " + o.name, rectRect(d.r, o.r), 0.5); });
    names.forEach((n) => need(d.name + " / " + n.name, rectRect(d.r, n.r), 0.3));
    need(d.name + " / the board's edge", Math.min(d.r[0] - board[0], d.r[1] - board[1], board[2] - d.r[2], board[3] - d.r[3]), 0.8);
});
yards.forEach((y, i) => {
    holes.forEach((h) => need(y.name + " / " + h.name, y.disc ? discDisc(y.disc, h.d) : discRect(h.d, y.r), 0.5));
    need(y.name + " / the cut-out", minOver(cut, (c) => y.disc ? discDisc(y.disc, c) : discRect(c, y.r)), 0.5);
    // (the five test pads are ONE row on one trace: their courtyards stand side by side by design)
    yards.forEach((o, j) => { if (j < i && !inside(o.r, y.r) && !inside(y.r, o.r) && !(isPad(y) && isPad(o))) need(y.name + " / " + o.name, rectRect(y.r, o.r), 0.4); });
    parts.forEach((p) => { if (y.own.indexOf(p.name) < 0) need(y.name + " / " + p.name, rectRect(y.r, p.r), 0.3); });
    // (the jack and the lens stand on the board's edge by design: their courtyards may run to it)
    if (y.own.indexOf("jack") < 0)
        need(y.name + " / the board's edge", Math.min(y.r[0] - board[0], y.r[1] - board[1], board[2] - y.r[2], board[3] - y.r[3]), 0.4);
});
traces.forEach((t) => {
    holes.forEach((h) => need("trace " + t.name + " / " + h.name, minOver(t.discs, (c) => discDisc(c, h.d)), 0.6));
    need("trace " + t.name + " / the cut-out", minOver(t.discs, (c) => minOver(cut, (k) => discDisc(c, k))), 0.6);
    yards.forEach((y) => {
        // a trace may enter the courtyard of a part it SERVES: one it ends at, or runs through (the pads' line)
        const serves = t.ends.some((e) => ptRect(e, y.r) <= 0.9) || parts.some((p) => y.own.indexOf(p.name) >= 0 && minOver(t.discs, (c) => discRect(c, p.r)) < 0);
        if (!serves)
            need("trace " + t.name + " / " + y.name + " (it serves another part)", minOver(t.discs, (c) => discRect(c, y.r)), 0.3);
    });
});
names.forEach((n) => {
    holes.forEach((h) => need(n.name + " / " + h.name, discRect(h.d, n.r), 0.4));
    need(n.name + " / the cut-out", minOver(cut, (c) => discRect(c, n.r)), 0.4);
});
holes.concat(cut.length ? [{ name: "the cut-out", discs: cut }] : []).forEach((h) => {
    const ds = h.discs || [h.d];
    parts.forEach((p) => need(h.name + " / " + p.name, minOver(ds, (c) => p.disc ? discDisc(c, p.disc) : discRect(c, p.r)), 0.6));
    if (h.name.indexOf("grommet") < 0) {
        need(h.name + " / the card", minOver(ds, (c) => discRect(c, card)), 0.6);
        need(h.name + " / the board's edge", minOver(ds, (c) => Math.min(c[0] - c[2] - board[0], c[1] - c[2] - board[1], board[2] - c[0] - c[2], board[3] - c[1] - c[2])), 0.5);
    }
});
// the routes: where a trace's first vertex lies on an earlier one, the two coordinates agree there (0.01 mm)
G.TRACES.forEach((t, i) => {
    const p = t.pts[0];
    for (let k = 0; k < i; k++) {
        const q = G.TRACES[k];
        for (let j = 0; j + 1 < q.pts.length; j++) {
            const a = q.pts[j], b = q.pts[j + 1], dx = b[0] - a[0], dz = b[1] - a[1], l2 = dx * dx + dz * dz;
            const u = l2 > 0 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dz) / l2)) : 0;
            if (Math.hypot(a[0] + dx * u - p[0], a[1] + dz * u - p[1]) < 0.05) {
                const sq = q.s[j] + u * Math.sqrt(l2);
                if (Math.abs(sq - t.s[0]) > 0.01)
                    bad.push("route " + t.name + " joins " + q.name + " at s " + sq.toFixed(2) + " but starts its own train at " + t.s[0].toFixed(2));
            }
        }
    }
});
bad.forEach((b) => console.log("  BREACH " + b));
console.log("AERIAL_CLEARANCE RESULT " + (bad.length ? "FAIL (" + bad.length + " breach(es))" : "PASS (" + decos.length + " decorations, " + yards.length + " courtyards, " + traces.length + " traces, " + names.length + " names, " + holes.length + " holes" + (cut.length ? " and the cut-out" : "") + ")"));
process.exit(bad.length ? 1 : 0);
