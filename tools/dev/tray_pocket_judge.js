// tools/dev/tray_pocket_judge.js -- the judge of tools/dev/tray_pocket_probe.sh: replays what the real engine handed its
// field on every frame of each leg (tools/dev/qml/tray_pocket_record.qml's TPFRAME lines) through a GooeyGeometry.js, with no
// Qt, and judges THE POCKET between the tray's label, its strip and the bar.
//
//   node tools/dev/tray_pocket_judge.js <record.log> <GooeyGeometry.js> <tag>      (TP_TRACE=1: one line per frame)
//
// Per leg, per frame: the label (the strip's child), its strip (the primary) and the bar the strip hangs from, as the
// geometry DRAWS them. A frame is IN THE CHANNEL when the label overlaps the bar along it by more than a pixel, stands
// beside its strip (within half a pixel), and its gap to the bar's face is inside the pocket's reach, a pixel clear of
// either end of it (2 * blendRadius: GooeyGeometry's default; at its far end the zip has not left the cap, at its near end
// the contact join takes over). On every such frame:
//   - the pocket must be drawn (a fillet keyed `pocket|`): `pocket dropped` lists the frames that lost it;
//   - the COVER of the channel -- the share of the rectangle between the strip's edge, the bar's face, the label's top and
//     the nearer of the two far ends that the field covers, sampled at 4 x 4 per px with gooey_field.frag's own distance --
//     moves only as fast as the motion moves the pocket: the zip's front is z(u) of the channel, u the gap's share of the
//     reach, and z's steepest slope is 1.35, so from one frame to the next the cover may change by at most
//     1.5 |du| + |d len| / len + SLACK (0.06). More is a shape that POPPED: `hole flickered` (a pocket lost or found in one
//     frame moves the cover by the zip's whole share, up to 1).
// Prints TRAYPOCKET <tag> <leg> frames=<n> channel=<n> pocket=<n> dropped=<list> coverStep=<worst excess @ frame>, then
// TRAYPOCKET <tag> PASS|FAIL (...).
const fs = require("fs");

const [logPath, geoPath, tag] = process.argv.slice(2);
if (!logPath || !geoPath) {
    console.log("usage: node tools/dev/tray_pocket_judge.js <record.log> <GooeyGeometry.js> <tag>");
    console.log("TRAYPOCKET " + (tag || "-") + " FAIL (usage)");
    process.exit(2);
}
const TRACE = process.env.TP_TRACE === "1";
const SLACK = Number(process.env.TP_SLACK || 0.06);

const G = (() => {
    const src = fs.readFileSync(geoPath, "utf8").replace(/^\.pragma library.*$/m, "");
    return new Function(src + "\nreturn { fieldShape };")();
})();

// ---- the recording ------------------------------------------------------------------------------------------------
let params = null;
const legs = {};
for (const line of fs.readFileSync(logPath, "utf8").split("\n")) {
    const p = line.indexOf("TPPARAMS ");
    const f = line.indexOf("TPFRAME ");
    if (p >= 0)
        params = JSON.parse(line.slice(p + 9));
    else if (f >= 0) {
        const fr = JSON.parse(line.slice(f + 8));
        (legs[fr.leg] = legs[fr.leg] || []).push(fr);
    }
}
if (!params || Object.keys(legs).length === 0) {
    console.log("TRAYPOCKET " + tag + " FAIL (no params or no frames in " + logPath + ")");
    process.exit(1);
}
const P = Object.assign({}, params, { clip: { x0: 0, y0: 0, x1: params.width, y1: params.height } });
const reach = 2 * params.blendRadius;

// ---- gooey_field.frag's distance, point for point -------------------------------------------------------------------
function sdBox(px, py, x0, y0, x1, y1) {
    const qx = Math.abs(px - 0.5 * (x0 + x1)) - 0.5 * (x1 - x0), qy = Math.abs(py - 0.5 * (y0 + y1)) - 0.5 * (y1 - y0);
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0);
}
function sdEllipse(px, py, rx, ry) {
    const k0 = Math.hypot(px / rx, py / ry), k1 = Math.hypot(px / (rx * rx), py / (ry * ry));
    return k0 < 1e-4 ? -Math.min(rx, ry) : k0 * (k0 - 1) / k1;
}
const SIGN4 = [[-1, -1], [1, -1], [1, 1], [-1, 1]];
// `out` here is a field cut to what lies near the channel (nearOf): only the shapes that can cover a sample there.
function fieldD(out, px, py) {
    const TINY = 0.05;
    let d = 1e9;
    for (const b of out.bodies) {
        if (b.solid === false) continue;
        const sb = sdBox(px, py, b.x0, b.y0, b.x1, b.y1);
        if (sb >= d) continue;
        let bd = sb;
        const cx = px - 0.5 * (b.x0 + b.x1), cy = py - 0.5 * (b.y0 + b.y1);
        for (let k = 0; k < 4; k++) {
            if (Math.min(b.ex[k], b.ey[k]) < TINY || Math.min(b.ix[k], b.iy[k]) < TINY) continue;
            const qx = SIGN4[k][0] * cx - (0.5 * (b.x1 - b.x0) - b.ix[k]);
            const qy = SIGN4[k][1] * cy - (0.5 * (b.y1 - b.y0) - b.iy[k]);
            if (qx > 0 && qy > 0) bd = Math.max(bd, sdEllipse(qx, qy, b.ex[k], b.ey[k]));
        }
        d = Math.min(d, bd);
    }
    for (const f of out.fillets) {
        if (Math.abs(f.ex) < TINY || Math.abs(f.ey) < TINY) continue;
        const bx = f.vx - Math.sign(f.ex) * f.bx, by = f.vy - Math.sign(f.ey) * f.by;
        const dr = sdBox(px, py, Math.min(bx, f.vx + f.ex), Math.min(by, f.vy + f.ey), Math.max(bx, f.vx + f.ex), Math.max(by, f.vy + f.ey));
        if (dr < d) d = Math.min(d, Math.max(dr, -sdEllipse(px - f.kx, py - f.ky, Math.max(f.krx, TINY), Math.max(f.kry, TINY))));
    }
    for (const q of out.seams)
        d = Math.min(d, sdBox(px, py, q.x0, q.y0, q.x1, q.y1));
    return d;
}
// What the shader draws (the first maxFillets fillets, maxSeams seams) and lies within a pixel of the rectangle.
function nearOf(out, r) {
    const hit = (x0, y0, x1, y1) => Math.max(x0, x1) > r.x0 - 1 && Math.min(x0, x1) < r.x1 + 1 && Math.max(y0, y1) > r.y0 - 1 && Math.min(y0, y1) < r.y1 + 1;
    return {
        bodies: out.bodies.filter(b => b.solid !== false && hit(b.x0, b.y0, b.x1, b.y1)),
        fillets: out.fillets.slice(0, P.maxFillets || 24).filter(f => hit(f.vx - Math.sign(f.ex) * f.bx, f.vy - Math.sign(f.ey) * f.by, f.vx + f.ex, f.vy + f.ey)),
        seams: out.seams.slice(0, P.maxSeams || 24).filter(q => hit(q.x0, q.y0, q.x1, q.y1))
    };
}

// ---- the channel ----------------------------------------------------------------------------------------------------
// The label, its strip and the bar, from the source bodies (relations) and the output (where they are drawn).
function roles(src, out) {
    const child = src.find(b => b.parent && src.some(p => p.id === b.parent));
    if (!child)
        return null;
    const strip = src.find(b => b.id === child.parent);
    const bar = strip && src.find(b => b.id === strip.host);
    const drawn = id => out.bodies.find(b => b.id === id);
    const L = drawn(child.id), S = strip && drawn(strip.id), B = bar && drawn(bar.id);
    return L && S && B && L.solid && S.solid && B.solid ? { L: L, S: S, B: B } : null;
}
// The channel's rectangle (a top bar, the label beside its strip: the tray's own layout; any other is not judged).
function channelOf(r) {
    const { L, S, B } = r;
    if (!(Math.abs(L.x0 - S.x1) <= 0.5 || Math.abs(L.x1 - S.x0) <= 0.5))
        return null;
    const right = Math.abs(L.x0 - S.x1) <= 0.5;
    const g = L.y0 - B.y1;
    const x0 = right ? S.x1 : Math.max(L.x0, B.x0), x1 = right ? Math.min(L.x1, B.x1) : S.x0;
    if (!(x1 - x0 > 1))
        return null;
    return { g: g, x0: x0, x1: x1, y0: B.y1, y1: L.y0, inside: g > 1 && g < reach - 1 };
}
// The share of the channel's rectangle the field covers.
function coverOf(out, ch) {
    const near = nearOf(out, ch);
    let n = 0, all = 0;
    const s = 4;
    for (let y = Math.floor(ch.y0 * s) + 0.5; y < ch.y1 * s; y++)
        for (let x = Math.floor(ch.x0 * s) + 0.5; x < ch.x1 * s; x++) {
            all++;
            if (fieldD(near, x / s, y / s) <= 0)
                n++;
        }
    return all > 0 ? n / all : 0;
}

// ---- replay and judge ------------------------------------------------------------------------------------------------
const bad = [];
let judged = 0;
for (const leg of Object.keys(legs)) {
    const frames = legs[leg];
    let state = {}, lastT = null;
    const rows = [];
    for (let i = 0; i < frames.length; i++) {
        const fr = frames[i];
        const dt = lastT === null ? 0 : Math.max(0, Math.min(100, fr.t - lastT));
        lastT = fr.t;
        const src = JSON.parse(JSON.stringify(fr.bodies));
        let out;
        try {
            out = G.fieldShape(JSON.parse(JSON.stringify(src)), P, state, dt);
        } catch (e) {
            bad.push(leg + ": the geometry threw at frame " + i + ": " + e);
            break;
        }
        state = out.state;
        const r = roles(src, out);
        const ch = r ? channelOf(r) : null;
        const pocket = out.fillets.slice(0, P.maxFillets || 24).some(f => String(f.key).indexOf("pocket|") === 0);
        const row = { i: i, t: fr.t, ch: ch, pocket: pocket, cover: ch && ch.inside ? coverOf(out, ch) : null };
        rows.push(row);
        if (TRACE)
            console.log("  " + leg + " #" + i + " t=" + fr.t + (ch ? " g=" + ch.g.toFixed(3) + " x=" + ch.x0.toFixed(2) + ".." + ch.x1.toFixed(2)
                + (ch.inside ? " IN" : "") : " -") + " pocket=" + (pocket ? 1 : 0) + (row.cover !== null ? " cover=" + row.cover.toFixed(3) : "")
                + " fillets=" + out.fillets.length + (out.droppedFillets ? " DROPPED " + out.droppedFillets : ""));
    }
    const inCh = rows.filter(x => x.ch && x.ch.inside);
    judged += inCh.length;
    const lost = inCh.filter(x => !x.pocket).map(x => x.i);
    // the cover's step between two channel frames against what the motion allows
    let worst = { v: -Infinity, i: -1, step: 0 };
    const span = reach - 0.5;
    for (let k = 1; k < rows.length; k++) {
        const a = rows[k - 1], b = rows[k];
        if (a.cover === null || b.cover === null)
            continue;
        const la = a.ch.x1 - a.ch.x0, lb = b.ch.x1 - b.ch.x0;
        const allow = 1.5 * Math.abs(b.ch.g - a.ch.g) / span + Math.abs(lb - la) / Math.max(1, Math.min(la, lb)) + SLACK;
        const step = Math.abs(b.cover - a.cover);
        if (step - allow > worst.v)
            worst = { v: step - allow, i: b.i, step: step };
    }
    console.log("TRAYPOCKET " + tag + " " + leg + " frames=" + rows.length + " channel=" + inCh.length + " pocket="
        + inCh.filter(x => x.pocket).length + " dropped=" + (lost.length ? lost.join(",") : "-")
        + " coverStep=" + (worst.i >= 0 ? worst.v.toFixed(3) + " @" + worst.i + " (step " + worst.step.toFixed(3) + ")" : "-"));
    if (lost.length)
        bad.push(leg + ": pocket dropped on " + lost.length + " of " + inCh.length + " channel frames (" + lost.slice(0, 12).join(",") + ")");
    if (worst.v > 0)
        bad.push(leg + ": hole flickered (the channel's cover jumped " + worst.step.toFixed(2) + " at frame " + worst.i
            + ", " + worst.v.toFixed(2) + " past what the motion moves)");
}
if (judged === 0)
    bad.push("no frame stood in the channel: nothing was judged");
console.log("TRAYPOCKET " + tag + " " + (bad.length ? "FAIL (" + bad.join("; ") + ")" : "PASS (" + judged + " channel frames)"));
process.exit(bad.length ? 1 : 0);
