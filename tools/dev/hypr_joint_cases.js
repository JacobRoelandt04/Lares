#!/usr/bin/env node
// What `hyprctl -j getoption` says about Hyprland's window corners, and the joint the bars draw for them, table-tested under node.
// HyprJoint.js is a `.pragma library` file with no Qt in it: the loader strips the pragma and evals the rest (the shell_layout_cases.js
// pattern). GooeyGeometry.js is loaded too: the joint's numbers are facts about HOW THE FIELD DRAWS A JOINT. (Restored in round 8 from the
// pre-cleanup tests/hypr_joint_cases.js; the pictures are tools/dev/shell_joint_probe.sh's.)
//
//   node tools/dev/hypr_joint_cases.js          must end HYPR-JOINT RESULT PASS
//   node tools/dev/hypr_joint_cases.js --arms   the clean run passes AND every ARM below fails -> HYPR-JOINT ARMS PASS
//
// What it holds: the answers `hyprctl -j getoption` gives for the options the joint is made of, recorded from the real thing; the outline
// radius they make (rounding + border; 0 for a window with no rounding, whose corners are square), the fallbacks and the overrides; THE
// OVERLAP (0.34 x sqrt(outer): 1.4 px at the user's 14 + 3, never the flat 2.5 that laid the ring over the border); the blendRadius the
// frame asks of the field (`blendFor`); the field's own answer to "how big a circle is a joint of blendRadius k on a side bar t px thick"
// (k, down to a 2 px bar: BAR_PRESENCE), which blendFor relies on; the ring on whole compositor px; THE DEVICE EDGE.
//
// ARMs, each patching ONE rule in the loaded COPY and each must turn it red:
//   ARM=noborder     the window's outline is the rounding alone
//   ARM=nopresence   a bar's joints come in over a popup's 8 px (the outlet's joint is 27/32 of a popup's again)
//   ARM=noring       the shell's own ring is left out of the joint
//   ARM=nosnap       the ring is drawn at its configured width (3.75 glass px at a frame of 1.25, behind a reserve of 4)
//   ARM=lastnumber   a CSS list's LAST number is the value
//   ARM=overridelost ShellConfig's override is ignored
//   ARM=offcenter    the default rounding is not 14 (the look of a mock run moves)
//   ARM=nooverlap    THE OVERLAP is 0: the seam of two antialiased arcs
//   ARM=flatoverlap  THE OVERLAP is the old flat 2.5 px (the ring over the window's border: the user's round-8 item)
//   ARM=thinborder   the overlap is not capped by the border (a 1 px border all but hidden under the ring at every corner)
//   ARM=roundborder  a window with no rounding is given a joint of its border's width (a round bite out of a square corner)
//   ARM=hugeok       a number out of range is a corner
//   ARM=norounding   THE DEVICE EDGE takes Hyprland's window edge where the reserve puts it (53.75) and not where Hyprland draws it (54)
//   ARM=roundedge    ... rounds the border's EDGE (55.5 -> 56 at 1.5) and not the surface's and the border's thickness apart (60 - 5 = 55)
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const SRC = path.join(__dirname, "..", "..", "modules", "shell", "HyprJoint.js");
const GEO = path.join(__dirname, "..", "..", "modules", "bar", "gooey", "GooeyGeometry.js");
const ARMS = {
    noborder: [SRC, "outer: rounding_ > 0 ? rounding_ + border_ : 0,", "outer: rounding_,"],
    roundborder: [SRC, "outer: rounding_ > 0 ? rounding_ + border_ : 0,", "outer: rounding_ + border_,"],
    nopresence: [GEO, "return body.mobile ? PRESENCE : BAR_PRESENCE;", "return PRESENCE;"],
    noring: [SRC, "return (o + overlapFor(o, border)) / k + w;", "return (o + overlapFor(o, border)) / k;"],
    nosnap: [SRC, "return Math.max(1, Math.round(w * kk)) / kk;", "return w;"],
    lastnumber: [SRC, "const first = o[kind].trim().split(/\\s+/)[0];", "const first = o[kind].trim().split(/\\s+/).pop();"],
    overridelost: [SRC, "const orr = ov(o.rounding), ob = ov(o.border);", "const orr = null, ob = null;"],
    offcenter: [SRC, "var DEFAULT_ROUNDING = 14;", "var DEFAULT_ROUNDING = 13;"],
    nooverlap: [SRC, "const v = OVERLAP_K * Math.sqrt(o);", "const v = 0;"],
    flatoverlap: [SRC, "const v = OVERLAP_K * Math.sqrt(o);", "const v = 2.5;"],
    thinborder: [SRC, "return b !== null && b >= 0 ? Math.min(v, OVERLAP_BORDER * b) : v;", "return v;"],
    hugeok: [SRC, "return n !== null && n >= 0 && n <= MAX_PX ? n : d;", "return n !== null ? n : d;"],
    norounding: [SRC, "const dev = far ? Math.round(size * d) - (Math.round((size - n - b) * d) + bd) : Math.round((n + b) * d) - bd;", "const dev = far ? size * d - (size - n) * d : n * d;"],
    roundedge: [SRC, "const dev = far ? Math.round(size * d) - (Math.round((size - n - b) * d) + bd) : Math.round((n + b) * d) - bd;", "const dev = far ? Math.round(size * d) - Math.round((size - n) * d) : Math.round(n * d);"]
};

function load(file, exports, arm) {
    let src = fs.readFileSync(file, "utf8").replace(/^\.pragma.*$/m, "");
    if (arm && ARMS[arm] && file === ARMS[arm][0]) {
        const [, a, b] = ARMS[arm];
        if (src.split(a).length !== 2) { console.log("ARM " + arm + ": anchor not unique"); process.exit(2); }
        src = src.replace(a, b);
    }
    const ctx = {};
    vm.createContext(ctx);
    vm.runInContext(src + "\nthis.X = { " + exports + " };", ctx);
    return ctx.X;
}

// What the real hyprctl 0.56.2 answered (the user's Hyprland, read only, 2026-10-21).
const REC = {
    rounding: '{"option": "decoration:rounding", "int": 14, "set": true }',
    border: '{"option": "general:border_size", "int": 3, "set": true }',
    gaps: '{"option": "general:gaps_out", "css": "6 6 6 6", "set": true }',
    power: '{"option": "decoration:rounding_power", "float": 2.000000, "set": false }'
};

// How the field draws a bar joint, in a frame drawn `k` times larger: an island 40 thick over the left outlet bar (6 / k thick) over the bottom bar -- the
// shell's corner -- at blendRadius `blend`: the fillet's circle in the frame's px (the field's own `krx`).
function drawnJoint(G, blend, slim) {
    const params = { blendRadius: blend, attachDistance: 12, snapDistance: 50, stickiness: 0.75, stretchMax: 60, sideStretch: 1, settleMs: 160, flushSnap: 3 };
    const H = 1296, W = 2304;
    const bodies = [
        { id: "bar:topL", x0: 0, y0: 0, x1: 800, y1: 40, r: 20, mobile: false, square: [true, true, false, false], skyBox: { x0: -4096, y0: -4096, x1: 6976, y1: 0 } },
        { id: "bar:left", x0: 0, y0: 40, x1: slim, y1: H - slim, r: 20, mobile: false, square: [true, false, false, true] },
        { id: "bar:bottom", x0: 0, y0: H - slim, x1: W, y1: H, r: 20, mobile: false, square: [true, true, true, true] }
    ];
    const r = G.fieldShape(bodies, params, {}, 16);
    const f = r.fillets.filter(x => /topL\|bar:left/.test(x.key));
    return f.length === 1 ? [f[0].krx, f[0].kry] : null;
}

// A popup hanging from the main bar: the fillet it makes with the bar (the idle reel's, the clock's ...), the circle of blendRadius `blend`.
function popupJoint(G, blend, corner) {
    const params = { blendRadius: blend, attachDistance: 12, snapDistance: 50, stickiness: 0.75, stretchMax: 60, sideStretch: 1, settleMs: 160, flushSnap: 3 };
    const bodies = [
        { id: "bar:topL", x0: 0, y0: 0, x1: 800, y1: 40, r: 20, mobile: false, square: [true, true, false, false], skyBox: { x0: -4096, y0: -4096, x1: 6976, y1: 0 } },
        { id: "slotA", x0: 200, y0: 40, x1: 500, y1: 300, rx: corner, ry: corner, mobile: true, stick: null, parent: "", host: "bar:topL", wallJoin: "" }
    ];
    const f = G.fieldShape(bodies, params, {}, 16).fillets.filter(x => /topL\|slotA/.test(x.key));
    return f.length === 2 ? [f[0].krx, f[0].kry] : null;
}

function run(arm) {
    const J = load(SRC, "parseOption, read, blendFor, overlapFor, ringWidth, edgeFix, DEFAULT_ROUNDING, DEFAULT_BORDER, DEFAULT_POWER, MAX_PX", arm);
    const G = load(GEO, "fieldShape", arm);
    let n = 0, bad = 0;
    function ok(name, cond, extra) {
        n++;
        if (!cond) { bad++; console.log("FAIL " + name + (extra ? "  " + extra : "")); }
    }
    function eq(name, got, want) {
        ok(name, JSON.stringify(got) === JSON.stringify(want), "got " + JSON.stringify(got) + " want " + JSON.stringify(want));
    }
    const near = (a, b, t) => Math.abs(a - b) <= t;

    // ---- one answer ----
    eq("parse: the recorded rounding", J.parseOption(REC.rounding), { value: 14, kind: "int" });
    eq("parse: the recorded border_size", J.parseOption(REC.border), { value: 3, kind: "int" });
    eq("parse: the recorded rounding_power", J.parseOption(REC.power), { value: 2, kind: "float" });
    eq("parse: a CSS list (gaps_out) is read by its FIRST number, whatever the form",
        ["8", "8 4", "8 4 2", "8 4 2 1", "  8   4"].map(s => J.parseOption('{"option":"general:gaps_out","css":"' + s + '"}').value), [8, 8, 8, 8, 8]);
    eq("parse: the recorded gaps_out", J.parseOption(REC.gaps), { value: 6, kind: "css" });
    eq("parse: a custom value that is one number", J.parseOption('{"custom": "6"}'), { value: 6, kind: "custom" });
    eq("parse: nothing, an error, a word, a list that is no number", [J.parseOption(""), J.parseOption("no such option"), J.parseOption("{}"),
        J.parseOption('{"css": "abc 6"}'), J.parseOption(null), J.parseOption(undefined), J.parseOption('{"int": "x"}')], [null, null, null, null, null, null, null]);

    // ---- the numbers ----
    const rec = J.read(REC.rounding, REC.border, REC.power, null);
    eq("the user's Hyprland (14, border 3): the window's outline is 17", [rec.rounding, rec.border, rec.outer, rec.read], [14, 3, 17, true]);
    eq("the rounding power is read (informational)", rec.power, 2);
    eq("the shell's defaults, asked of nothing, are the user's 14 and 3", J.read(null, null, null, null), { rounding: 14, border: 3, power: 2, outer: 17, read: false });
    eq("the defaults are the constants", [J.DEFAULT_ROUNDING, J.DEFAULT_BORDER, J.DEFAULT_POWER], [14, 3, 2]);
    eq("only one number answered: the other is the default, and `read` says Hyprland spoke", [J.read('{"int": 12}', null, null, null).read, J.read('{"int": 12}', null, null, null).outer], [true, 15]);
    eq("a number out of range is no corner (the default stands)", [J.read('{"int": 9999}', REC.border, null, null).rounding, J.read('{"int": -3}', REC.border, null, null).rounding], [14, 14]);
    eq("a rounding power out of range or not a number is 2", [J.read(null, null, '{"float": 0}', null).power, J.read(null, null, '{"float": 99}', null).power, J.read(null, null, "x", null).power], [2, 2, 2]);
    eq("an override wins over Hyprland's number, the other is Hyprland's", J.read(REC.rounding, REC.border, REC.power, { rounding: 10, border: null }).outer, 13);
    eq("both overridden: Hyprland is not needed", J.read(null, null, null, { rounding: 12, border: 2 }).outer, 14);
    eq("an override of 0 is a corner of 0 (null is what asks)", J.read(REC.rounding, REC.border, null, { rounding: 0 }).rounding, 0);
    eq("an override that is no number, or out of range, asks Hyprland",
        [J.read(REC.rounding, REC.border, null, { rounding: "x" }).rounding, J.read(REC.rounding, REC.border, null, { rounding: 500 }).rounding, J.read(REC.rounding, REC.border, null, { border: -1 }).border], [14, 14, 3]);
    eq("a bad override block is none", [J.read(REC.rounding, REC.border, null, 5).outer, J.read(REC.rounding, REC.border, null, "x").outer, J.read(REC.rounding, REC.border, null, undefined).outer], [17, 17, 17]);

    // ---- the blendRadius the frame asks of the field ----
    const OV = 0.34 * Math.sqrt(17);
    ok("THE OVERLAP at the user's 14 + 3 is 0.34 x sqrt(17) = 1.40 px: enough to close the arcs' seam, and (sqrt 2 - 1) x it = 0.58 px of the window's "
       + "3 px border under the ring at the arc's middle (2.5 took 1.04)", near(J.overlapFor(17), OV, 1e-9) && near(OV, 1.4019, 1e-3) && (Math.SQRT2 - 1) * J.overlapFor(17) < 0.6);
    {
        let mono = true, bounded = true;
        for (let o = 1; o <= 67; o++) {
            if (!(J.overlapFor(o + 1) > J.overlapFor(o))) mono = false;
            // under a pixel of the border at the arc's middle up to a radius of 34, never 2.5 again below a radius of 54
            if ((o <= 34 && (Math.SQRT2 - 1) * J.overlapFor(o) >= 1) || (o < 54 && J.overlapFor(o) >= 2.5)) bounded = false;
        }
        ok("the overlap grows with the radius, by its root (the seam's shallow ends are 1 / sqrt(radius) from the straights)", mono && near(J.overlapFor(68) / J.overlapFor(17), 2, 1e-9));
        ok("... and stays small: under a pixel of the border at the arc's middle, under the old 2.5 for every corner Hyprland is likely to draw", bounded);
    }
    eq("the overlap is never over half the window's border: 0.5 for a 1 px border, 1 for 2; the user's 3 is not capped; no border, no overlap",
        [J.overlapFor(17, 1), J.overlapFor(17, 2), near(J.overlapFor(17, 3), OV, 1e-9), J.overlapFor(17, 0), near(J.blendFor(15, 1, 3, 1), 15 + 0.5 + 3, 1e-9)], [0.5, 1, true, 0, true]);
    eq("no corner, no overlap (a square corner has no arc to leave a seam on); a bad radius is none", [J.overlapFor(0), J.overlapFor(-4), J.overlapFor("x"), J.overlapFor(undefined)], [0, 0, 0, 0]);
    ok("Hyprland at 14 + 3 behind the shell's 3 px ring in a frame of 1: blendRadius 21.40 -- the window's outline, the ring and THE OVERLAP", near(J.blendFor(rec.outer, 1, 3), 20 + OV, 1e-9));
    ok("... with the ring off the window's side is the joint itself, and the overlap: 18.40", near(J.blendFor(rec.outer, 1, 0), 17 + OV, 1e-9));
    ok("THE OVERLAP is in compositor px: a frame of 1.25 asks 1 / 1.25 of it", near(J.blendFor(23, 1.25, 0) - 23 / 1.25, J.overlapFor(23) / 1.25, 1e-9));
    eq("an unrounded Hyprland is a joint no smaller than the ring", [J.blendFor(0, 1, 0), J.blendFor(-50, 1, 0), J.blendFor(0, 1, 3)], [0, 0, 3]);
    eq("rounding 0 is a SQUARE corner whatever the border: no outline to nest, the joint is the ring's", [J.read('{"int": 0}', REC.border, null, null).outer, J.blendFor(J.read('{"int": 0}', REC.border, null, null).outer, 1, 3)], [0, 3]);
    ok("a frame scale that is no number is 1", [J.blendFor(17, 0, 3), J.blendFor(17, -2, 3), J.blendFor(17, NaN, 3)].every(v => near(v, 20 + OV, 1e-9)));
    ok("a ring that is no number or negative is no ring", [J.blendFor(17, 1, undefined), J.blendFor(17, 1, -2), J.blendFor(17, 1, "x"), J.blendFor(17, 1, null)].every(v => near(v, 17 + OV, 1e-9)));
    ok("the ring is drawn in the frame's px, the window's outline is not: a frame of 1.25 (the user's external screen) asks (17 + 1.40) / 1.25 + 3.2 = 17.92", near(J.blendFor(17, 1.25, 3), (17 + OV) / 1.25 + 3.2, 1e-9));

    // ---- the ring on whole compositor px (round 3 post-review, GEO item 1) ----
    eq("a 3 px ring in a frame of 1 stays 3, in 1.25 is 4 glass px (3.2 frame px), in 1.5 is 5 (4.5 rounds up)", [J.ringWidth(3, 1), J.ringWidth(3, 1.25) * 1.25, J.ringWidth(3, 1.5) * 1.5], [3, 4, 5]);
    eq("a ring that is no number, zero or negative is none", [J.ringWidth(0, 1.25), J.ringWidth(-2, 1.25), J.ringWidth("x", 1.25), J.ringWidth(undefined, 1.25), J.ringWidth(null, 1)], [0, 0, 0, 0, 0]);
    eq("a ring thinner than a glass px is one (it is never rounded away)", [J.ringWidth(0.2, 1) * 1, J.ringWidth(0.1, 2) * 2], [1, 1]);
    {
        let allWhole = true, allNear = true;
        for (const k of [0.75, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5])
            for (const w of [1, 2, 3, 4, 5.5]) {
                const g = J.ringWidth(w, k) * k;
                if (Math.abs(g - Math.round(g)) > 1e-9) allWhole = false;
                if (Math.abs(g - w * k) > 0.5 + 1e-9) allNear = false;
            }
        ok("at every scale the ring is a whole number of compositor px (the reserve's ceil is then exactly where it ends) ...", allWhole);
        ok("... and never more than half a px from the configured width", allNear);
    }

    // ---- what the field draws of a joint: the circle of blendRadius, whatever the outlet's thickness (ENGGEO item 1) ----
    for (const [k, t] of [[20, 6], [30, 6], [20, 4.8], [20, 3], [26, 7.5], [20, 12], [16.2, 4.8], [20, 2]]) {
        const d = drawnJoint(G, k, t);
        ok("the field draws a joint of blendRadius " + k + " on a side bar " + t + " thick as a CIRCLE of blendRadius " + k,
            !!d && near(d[0], k, 1e-3) && near(d[1], k, 1e-3), JSON.stringify(d));
    }
    {
        const d1 = drawnJoint(G, 20, 1), d0 = drawnJoint(G, 20, 0.5);
        ok("a bar eased away by the bars toggle still lets its joint go over its last 2 px (1 px: " + (d1 ? d1[0].toFixed(2) : "none") + ", 0.5 px: " + (d0 ? d0[0].toFixed(2) : "none") + ")",
            !!d1 && !!d0 && d1[0] < 20 - 1 && d0[0] < d1[0]);
    }
    // ... and it is the popup's: the fillet a popup makes with the bar it hangs from is the same circle (the user: "the same rounding")
    for (const k of [20, 21.4, 17, 16.6]) {
        const p = popupJoint(G, k, k), s = drawnJoint(G, k, 6);
        ok("the idle reel's popup on the main bar and the left outlet bar's joint are ONE circle (blendRadius " + k + ", a popup whose own corner is as round)", !!p && !!s && near(p[0], s[0], 1e-6) && near(p[1], s[1], 1e-6),
            JSON.stringify([p, s]));
    }
    // ... so, at every scale of the frame, the joint asked for is the window's outline PLUS the ring PLUS THE OVERLAP ON THE GLASS (the frame's px x its scale), for any Hyprland
    for (const k of [0.75, 1, 1.25, 1.5, 1.75, 2]) {
        for (const outer of [10, 13, 17, 23]) {
            for (const ring of [0, 3]) {
                const blend = J.blendFor(outer, k, ring);
                const d = drawnJoint(G, blend, 6 / k);
                const want = Math.max(0, outer) + J.overlapFor(outer) + J.ringWidth(ring, k) * k;
                ok("scale " + k + ", a window outline of " + outer + " behind a ring of " + ring + ": the joint drawn on the glass is " + want.toFixed(3) + " (blendRadius " + blend.toFixed(3) + " in the frame's px)",
                    !!d && near(d[0] * k, want, 2e-3) && near(d[1] * k, want, 2e-3), d ? (d[0] * k).toFixed(4) : "none");
            }
        }
    }

    // ---- THE DEVICE EDGE (polish wave, 2026-10-26): each edge's face drawn where Hyprland starts the window's border ----
    {
        // the user's laptop: 2880 x 1620 at Hyprland 1.25 (2304 x 1296 compositor px), the shell's global scale 1.25 (a frame of 1), a 3 px ring
        const ring = J.ringWidth(3, 1);
        const f = J.edgeFix({ top: 43, right: 9, bottom: 9, left: 9 }, { top: 40, right: 6, bottom: 6, left: 6 }, ring, 1, 1.25, 2304, 1296, 3);
        ok("the user's laptop: the top bar's face drawn 0.2 px lower (the ring to 54 device px, where Hyprland starts the border it says is at 53.75), the outlets' "
           + "0.2 px thinner (to 11, not 11.25)", near(f.top, 0.2, 1e-9) && near(f.left, -0.2, 1e-9) && near(f.right, -0.2, 1e-9) && near(f.bottom, -0.2, 1e-9), JSON.stringify(f));
        // the nested env's 1920 x 1080 at Hyprland 1.5, the shell's 1.25 (a frame of 1.25 / 1.5): the border measured from 55 at the top, 13 at the sides
        const k = 1.25 / 1.5, r2 = J.ringWidth(3, k), slim = 6 / k;
        const g = J.edgeFix({ top: 37, right: 9, bottom: 9, left: 9 }, { top: 40, right: slim, bottom: slim, left: slim }, r2, k, 1.5, 1920, 1080, 3);
        const dev = e => ((e === "top" ? 40 : slim) + r2 + g[e]) * 1.25;
        ok("Hyprland 1.5, the shell 1.25: the ring to 55 device px at the top and 13 at every side (measured: round(60) - round(4.5), round(18) - 5)",
           near(dev("top"), 55, 1e-9) && near(dev("left"), 13, 1e-9) && near(dev("right"), 13, 1e-9) && near(dev("bottom"), 13, 1e-9), JSON.stringify(g));
    }
    {
        // every frame at Hyprland's scale 1: nothing moves (the ring is on whole compositor px and the reserve is exactly it)
        let still = true, where = "";
        for (const k of [0.75, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5])
            for (const w of [0, 1, 3, 5.5]) {
                const ring = J.ringWidth(w, k), slim = 6 / k;
                const res = { top: Math.ceil((40 + ring) * k - 1e-6), right: Math.ceil((slim + ring) * k - 1e-6) };
                res.bottom = res.left = res.right;
                const f = J.edgeFix(res, { top: 40, right: slim, bottom: slim, left: slim }, ring, k, 1, 2560, 1440, 3);
                if (f.top !== 0 || f.right !== 0 || f.bottom !== 0 || f.left !== 0) { still = false; where = k + "/" + w + " " + JSON.stringify(f); }
            }
        ok("at Hyprland's scale 1 every edge's fix is exactly 0, at every frame scale and ring (the field as it was)", still, where);
    }
    {
        // any Hyprland scale and shell scale: the face plus the ring, on the glass, IS Hyprland's rounded edge, on all four sides
        let exact = true, where = "";
        for (const dpr of [1.25, 1.5, 1.6, 1.75, 2])
            for (const cfg of [1, 1.25, 1.5])
                for (const [w, hb] of [[0, 0], [3, 1], [3, 2], [3, 3], [2, 4]]) {
                    const k = cfg / dpr, g = cfg, ring = J.ringWidth(w, k), slim = 6 / k;
                    const W = 3440 / dpr, H = 1440 / dpr;
                    const res = { top: Math.ceil((40 + ring) * k - 1e-6), right: Math.ceil((slim + ring) * k - 1e-6) };
                    res.bottom = res.left = res.right;
                    const thick = { top: 40, right: slim, bottom: slim, left: slim };
                    const f = J.edgeFix(res, thick, ring, k, dpr, W, H, hb);
                    for (const e of ["top", "right", "bottom", "left"]) {
                        // Hyprland: the surface's box rounded, the border's thickness rounded (renderBorder)
                        const far = e === "right" || e === "bottom", size = e === "right" ? W : H, bd = Math.round(hb * dpr);
                        const hypr = far ? Math.round(size * dpr) - (Math.round((size - res[e] - hb) * dpr) + bd) : Math.round((res[e] + hb) * dpr) - bd;
                        const drawn = (thick[e] + ring + f[e]) * g;
                        if (!near(drawn, hypr, 1e-6)) { exact = false; where = dpr + "/" + cfg + "/" + w + "/" + hb + " " + e + " drawn " + drawn + " hyprland " + hypr; }
                    }
                }
        ok("at Hyprland's scales 1.25 .. 2 and the shell's 1 .. 1.5 the ring ends on the device px Hyprland draws the window's border from, on every edge", exact, where);
    }
    eq("no reserve on an edge, no fix there (an outlet the shell does not show)",
       J.edgeFix({ top: 43, right: 0, bottom: 0, left: 0 }, { top: 40, right: 6, bottom: 6, left: 6 }, 3, 1, 1.25, 2304, 1296, 3).right, 0);
    eq("a reserve that is not the bars' own (12 px away) is no edge to meet",
       J.edgeFix({ top: 55, right: 9, bottom: 9, left: 9 }, { top: 40, right: 6, bottom: 6, left: 6 }, 3, 1, 1.25, 2304, 1296, 3).top, 0);

    return { n, bad };
}

const arms = process.argv.includes("--arms");
const clean = run(null);
if (!arms) {
    console.log("HYPR-JOINT RESULT " + (clean.bad ? "FAIL" : "PASS") + " (" + (clean.n - clean.bad) + "/" + clean.n + ")");
    process.exit(clean.bad ? 1 : 0);
}
let allRed = clean.bad === 0;
if (!allRed) console.log("the clean run is not green");
const realLog = console.log;
for (const a of Object.keys(ARMS)) {
    const lines = [];
    console.log = (s) => lines.push(s);
    const r = run(a);
    console.log = realLog;
    const red = r.bad > 0;
    console.log("ARM " + a + ": " + (red ? "red on " + lines[0].slice(0, 90) : "STAYED GREEN"));
    if (!red) allRed = false;
}
console.log("HYPR-JOINT ARMS " + (allRed ? "PASS" : "FAIL"));
process.exit(allRed ? 0 : 1);
