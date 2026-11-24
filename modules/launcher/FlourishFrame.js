.pragma library

// =============================================================================
// FlourishFrame.js -- one frame of the confirm flourish's RESULT as numbers:
// everything ConfirmFlourish hands the engine in a frame, and the
// engine-side clocks it depends on, so that PoseRecorder can record it and play
// it back (the audio player's methodology: record what was produced, never
// re-derive it).
//
//   body      bodyOn, box, the four corners' radii (x, y), feather
//   face      what FlourishFace draws at the pose: icon size / position, title
//             position and alpha, the morph's m, the well's box and the three
//             presence fades
//   neck      neckOn and the capsule geometry (FlourishPose.neck)
//   host      hostOn: the launcher's held close is alive; its clock t and its
//             content's opacity
//   engine    cutOn (the content cut at the bar's face), groupOn / groupK (the
//             merge group and its eased k), fxOn / fxT (the ripple's and the
//             droplets' clock: seconds since the contact)
//   readout   el (nominal ms), pt, ph (phase index), rel, gap, trv -- nothing
//             draws from these
//   moment    pg: WHERE in the run the frame is, in terms no tune value
//             can change -- pg = the phase's index + the fraction of it gone (a monotone
//             coordinate that passes from one phase into the next without a jump, so a
//             scrub between two frames lands on a real moment).
//             A walk-through with a changed parameter re-poses the moment (not the numbers).
//   serial    LAST: PoseRecorder writes the properties in this order, so the
//             write of `serial` is the signal that a whole frame has landed.
//
// A flag that is off keeps the numbers it had last ("held"): a scrub between two
// frames interpolates every number, and a neck interpolated from nothing to its
// first shape would flash a half-grown one. A flag counts as on only when it is
// 1 (>= FLAG), so between a frame with a part and the next without it the part
// is off: it goes at most one frame early, and a step lands on a frame exactly.
// =============================================================================

var PHASES = ["idle", "lift", "rise", "fall", "sink", "settle"];

var KEYS = ["el", "pt", "ph", "rel", "gap", "trv", "bodyOn", "bx0", "by0", "bx1", "by1", "r0a", "r0b", "r1a", "r1b", "r2a", "r2b", "r3a", "r3b", "feather", "ip", "icx", "icy", "tix", "tiy", "m", "titleA", "wx0", "wy0", "wx1", "wy1", "wellA", "marksA", "bandA", "neckOn", "nax", "nay", "nmux", "nmuy", "nlx", "nly", "nmlx", "nmly", "nrA", "nqU", "nrL", "nqL", "nkA", "nkB", "nkMid", "nkJoin", "hostOn", "hostT", "hostC", "hrel", "cutOn", "groupOn", "groupK", "fxOn", "fxT", "pg", "serial"];

var FLAG = 0.999;

function _n(v, d) {
    return typeof v === "number" && isFinite(v) ? v : d;
}

// s: { el, pt, ph, rel, gap, trv, pose, bodyOn, neck | null, host: { t, c } | null,
// cut, groupOn, groupK, fxOn, fxT, serial }; prev: the last packed frame (the held numbers).
function pack(s, prev) {
    const o = {};
    const P = prev || {};
    const hold = (k, v) => {
        o[k] = _n(v, _n(P[k], 0));
    };
    hold("el", s.el);
    hold("pt", s.pt);
    hold("ph", s.ph);
    o.rel = s.rel ? 1 : 0;
    hold("gap", s.gap);
    hold("trv", s.trv);
    const p = s.pose;
    o.bodyOn = s.bodyOn ? 1 : 0;
    const b = p ? p.box : null;
    hold("bx0", b ? b.x0 : undefined);
    hold("by0", b ? b.y0 : undefined);
    hold("bx1", b ? b.x1 : undefined);
    hold("by1", b ? b.y1 : undefined);
    const r = p ? p.radii : null;
    for (let i = 0; i < 4; i++) {
        hold("r" + i + "a", r ? (Array.isArray(r[i]) ? r[i][0] : r[i]) : undefined);
        hold("r" + i + "b", r ? (Array.isArray(r[i]) ? r[i][1] : r[i]) : undefined);
    }
    hold("feather", p ? p.feather : undefined);
    hold("ip", p ? p.ip : undefined);
    hold("icx", p ? p.icon.x : undefined);
    hold("icy", p ? p.icon.y : undefined);
    hold("tix", p ? p.title.x : undefined);
    hold("tiy", p ? p.title.y : undefined);
    hold("m", p ? p.m : undefined);
    hold("titleA", p ? p.titleA : undefined);
    const w = p ? (p.wellBox || p.box) : null;
    hold("wx0", w ? w.x0 : undefined);
    hold("wy0", w ? w.y0 : undefined);
    hold("wx1", w ? w.x1 : undefined);
    hold("wy1", w ? w.y1 : undefined);
    hold("wellA", p ? p.wellA : undefined);
    hold("marksA", p ? p.marksA : undefined);
    hold("bandA", p ? p.bandA : undefined);
    const n = s.neck;
    o.neckOn = n ? 1 : 0;
    hold("nax", n ? n.a.x : undefined);
    hold("nay", n ? n.a.y : undefined);
    hold("nmux", n ? n.mu.x : undefined);
    hold("nmuy", n ? n.mu.y : undefined);
    hold("nlx", n ? n.l.x : undefined);
    hold("nly", n ? n.l.y : undefined);
    hold("nmlx", n ? n.ml.x : undefined);
    hold("nmly", n ? n.ml.y : undefined);
    hold("nrA", n ? n.rA : undefined);
    hold("nqU", n ? n.qU : undefined);
    hold("nrL", n ? n.rL : undefined);
    hold("nqL", n ? n.qL : undefined);
    hold("nkA", n ? n.kA : undefined);
    hold("nkB", n ? n.kB : undefined);
    hold("nkMid", n ? n.kMid : undefined);
    hold("nkJoin", n ? n.kJoin : undefined);
    o.hostOn = s.host ? 1 : 0;
    hold("hostT", s.host ? s.host.t : undefined);
    hold("hostC", s.host ? s.host.c : undefined);
    o.hrel = s.hrel ? 1 : 0;
    o.cutOn = s.cut ? 1 : 0;
    o.groupOn = s.groupOn ? 1 : 0;
    hold("groupK", s.groupK);
    o.fxOn = s.fxOn ? 1 : 0;
    hold("fxT", s.fxOn ? s.fxT : undefined);
    hold("pg", s.pg);
    o.serial = _n(s.serial, 0);
    return o;
}

// f: an object with the KEYS as properties (the frame item, written by the recorder).
function unpack(f) {
    const on = k => f[k] >= FLAG;
    const radii = [];
    for (let i = 0; i < 4; i++)
        radii.push([f["r" + i + "a"], f["r" + i + "b"]]);
    const box = { x0: f.bx0, y0: f.by0, x1: f.bx1, y1: f.by1 };
    // The well's box is the card's own unless the lift says otherwise (the pose
    // leaves it out then: FlourishFace reads `wellBox || box`).
    const wellBox = f.wx0 === f.bx0 && f.wy0 === f.by0 && f.wx1 === f.bx1 && f.wy1 === f.by1 ? undefined : { x0: f.wx0, y0: f.wy0, x1: f.wx1, y1: f.wy1 };
    const pose = {
        box: box,
        radii: radii,
        ip: f.ip,
        icon: { x: f.icx, y: f.icy },
        title: { x: f.tix, y: f.tiy },
        m: f.m,
        feather: f.feather,
        titleA: f.titleA,
        wellA: f.wellA,
        marksA: f.marksA,
        bandA: f.bandA
    };
    if (wellBox)
        pose.wellBox = wellBox;
    return {
        ph: Math.round(f.ph),
        phase: PHASES[Math.max(0, Math.min(PHASES.length - 1, Math.round(f.ph)))],
        bodyOn: on("bodyOn"),
        pose: pose,
        neck: on("neckOn") ? {
            a: { x: f.nax, y: f.nay },
            mu: { x: f.nmux, y: f.nmuy },
            l: { x: f.nlx, y: f.nly },
            ml: { x: f.nmlx, y: f.nmly },
            rA: f.nrA,
            qU: f.nqU,
            rL: f.nrL,
            qL: f.nqL,
            kA: f.nkA,
            kB: f.nkB,
            kMid: f.nkMid,
            kJoin: f.nkJoin
        } : null,
        hostOn: on("hostOn"),
        hostT: f.hostT,
        hostC: f.hostC,
        cutOn: on("cutOn"),
        groupOn: on("groupOn"),
        groupK: f.groupK,
        fxOn: on("fxOn"),
        fxT: f.fxT,
        pg: f.pg
    };
}
