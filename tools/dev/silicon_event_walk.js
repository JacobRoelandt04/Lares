"use strict";
// =============================================================================
// silicon_event_walk.js -- the battery event's pulse as DATA (round 4, W2): the walks of one pulse over the trace graph, and (round 5, E1) the numbers of its
// whole life, in ONE place: PULSE.
//
//   const W = require("./silicon_event_walk.js"); W.walk(G, { maxDist })  ->  { entries: [ [ {c, dir, from} ... ] per trace id ], nodes, ... }
//   W.PULSE                                                                 ->  { speed, maxD, walkShare, walkTo, seconds, dimIn, dimAt }: what the glow, the gates and the film read
//
// The event leaves the pack's traces and runs at one speed along EVERY trace: into every branch at a split, through the parts the traces join (the
// package, the slot: they hand it on to their other traces), round every loop, so it can come back to itself; a trace that ends at nothing ends it. Its
// strength falls with the distance it has run (the glow's `evtFade`), and the walk stops where that is below a visible level -- which is what keeps a loop
// from running for ever.
//
// A WALK is a wave on one trace: it enters at arc `from` going `dir` (+1 toward the trace's end, -1 toward its start) at distance D0 from the pack, so the
// light at arc `a` of that trace is the pulse at distance  c + dir * a  with  c = D0 - dir * from,  for the arcs ahead of `from` only. The generator bakes
// the entries per trace; the glow takes the strongest pulse over them. No walk goes back the way it came (non-backtracking: at a node it leaves by every
// OTHER member). Two parts of one trace within TOL mm in one node are one place.
// The graph: a trace end that lies on another trace (to within its half width + 0.1) is one place with that
// trace's point; the package (the four stubs' courtyard ends), the slot (the card's power lane, the four lanes, the two lanes out) and the pack's (-)
// terminal (the rail's two starts) are parts that join the traces on them, at no extra distance (the flow's own rule: the package hands a pulse on at P0).
// =============================================================================

// Two waves within MERGE mm of one place (same trace, way and entry) are ONE wave: the parallel lanes of the fork would otherwise multiply a lap into thousands of walks no eye
// could tell apart. The merge is also the error at a joint -- the wave the merged-away route would have brought is where the kept one is, up to MERGE off -- so it must be
// well under the pulse's width where the pulse is strong: 4 mm (round 4) left a pulse jumping by up to 3.2 mm where two routes met (the pcie lanes' lengths differ by 3 mm),
// a step the seam gate sees once the pulse is slow and long enough to be strong there. 2 mm leaves 0.22 mm at worst and costs a quarter more waves (332 against 267 at 216 mm of
// walk, measured; 1 mm is no better: the lanes' lengths differ by 2.8 mm and more, so nothing nearer than that is a different wave).
const MERGE = 2.0;
const TOL = 1.0;                                       // mm: members of one trace within this of each other in one node are one place

// THE PULSE'S NUMBERS (round 5, E1: "too fast, both in speed and how long it is displayed"). One place: the generator bakes them into the glow as constants
// (EVT_SPEED, EVT_MAXD, EVT_DIM_IN, EVT_DIM_AT), the walk below stops at `walkTo`, and the event ages
// the trains gate and the film read them from here -- never a copy.
const PULSE = {
    speed: 55,          // mm/s the pulse runs along the copper (round 4: 160)
    maxD: 220,          // mm of run at which it is gone: its strength is 1 at the pack and falls to 0 here by a smoothstep (glow_materials.glsl evtFade)
    // The walks stop where the strength is under 3 %: 1 - smoothstep(0, 1, 0.9) = 0.028, invisible. A wave that starts beyond it is not walked; one that began before it
    // runs out its trace (and its strength there is under the same 3 %). The smoothstep's flat tail would otherwise cost a third of the table for light nobody sees.
    walkShare: 0.9,
    // the passive trains' ONE envelope of the event's age (glow_materials.glsl evtTrains): they fade out over `dimIn` s as the event starts, stay away while the
    // pulse is strong, and return as the pulse fades -- fully back when its strength has reached 0 (age maxD / speed), which is the end of the event
    dimIn: 0.4,         // s the trains take to fade out at the event's start
    dimAt: 0.3          // the pulse's strength below which the trains begin to return (fully away above it): about what it has left at the end of its first lap over the network (133 mm: 0.35)
};
PULSE.walkTo = PULSE.maxD * PULSE.walkShare;           // mm: how far the walk goes
PULSE.seconds = PULSE.maxD / PULSE.speed;              // s: the pulse is gone, the trains are back: the event's length

function prepare(G) {
    const T = G.TRACES;
    T.forEach((t, id) => {
        t.id = id;
        t.cum = [0];
        for (let i = 0; i + 1 < t.pts.length; i++)
            t.cum.push(t.cum[i] + Math.hypot(t.pts[i + 1][0] - t.pts[i][0], t.pts[i + 1][1] - t.pts[i][1]));
        t.len = t.cum[t.cum.length - 1];
    });
    return T;
}

function nearest(t, p) {
    let best = { d: 1e9, s: 0 };
    for (let i = 0; i + 1 < t.pts.length; i++) {
        const a = t.pts[i], b = t.pts[i + 1], abx = b[0] - a[0], abz = b[1] - a[1], l2 = Math.max(abx * abx + abz * abz, 1e-12);
        const u = Math.max(0, Math.min(1, ((p[0] - a[0]) * abx + (p[1] - a[1]) * abz) / l2));
        const d = Math.hypot(p[0] - a[0] - abx * u, p[1] - a[1] - abz * u);
        if (d < best.d) best = { d, s: t.cum[i] + u * Math.sqrt(l2) };
    }
    return best;
}

const hwAt = (t, i) => (t.pts[i].length > 2 ? t.pts[i][2] : t.width) / 2;

// the nodes: [{ members: [{ t, a }] }], each trace at most once per node (its members within TOL merged)
function graph(G) {
    const T = prepare(G);
    const byName = {};
    T.forEach((t) => { byName[t.name] = t; });
    // raw members and the union-find over them
    const mem = [];                                    // { t, a }
    const key = (t, a) => {
        for (let i = 0; i < mem.length; i++)
            if (mem[i].t === t && Math.abs(mem[i].a - a) < 1e-6) return i;
        mem.push({ t, a });
        return mem.length - 1;
    };
    const par = [];
    const find = (i) => { while (par[i] !== i) { par[i] = par[par[i]]; i = par[i]; } return i; };
    const uni = (i, j) => { par[find(i)] = find(j); };
    const add = (t, a) => { const i = key(t, a); while (par.length < mem.length) par.push(par.length); return i; };
    for (const a of T) {
        if (a.len < 0.5) continue;
        for (const end of [0, 1]) {
            const e = end ? a.pts[a.pts.length - 1] : a.pts[0];
            const hwE = hwAt(a, end ? a.pts.length - 1 : 0);
            for (const b of T) {
                if (b === a || b.len < 0.001) continue;
                const q = nearest(b, e);
                if (q.d <= hwE + 0.1) uni(add(a, end ? a.len : 0), add(b, q.s));
            }
        }
    }
    // the parts that join traces
    const part = (list) => {
        const ids = list.map(([n, end]) => add(byName[n], end ? byName[n].len : 0));
        for (let i = 1; i < ids.length; i++) uni(ids[0], ids[i]);
    };
    part([["stubPx", 0], ["stubNx", 0], ["stubPz", 0], ["stubNz", 0]]);                                                           // the package
    part([["packSlot", 1], ["pcie0", 1], ["pcie1", 1], ["pcie2", 1], ["pcie3", 1], ["slotOut0", 0], ["slotOut1", 0]]);            // the slot
    part([["packCpu", 0], ["packSlot", 0]]);                                                                                      // the pack's (-) terminal
    // clusters -> nodes, one member per trace
    const groups = {};
    mem.forEach((m, i) => { (groups[find(i)] = groups[find(i)] || []).push(m); });
    const nodes = [];
    for (const k of Object.keys(groups)) {
        const per = {};
        groups[k].forEach((m) => { (per[m.t.id] = per[m.t.id] || []).push(m); });
        const members = [];
        for (const id of Object.keys(per)) {
            const t = T[id], arcs = per[id].map((m) => m.a);
            let a = arcs.reduce((x, y) => x + y, 0) / arcs.length;
            if (Math.max(...arcs) - Math.min(...arcs) > TOL * 2) a = arcs[0];
            if (a < TOL) a = 0;
            else if (a > t.len - TOL) a = t.len;
            members.push({ t, a });
        }
        if (members.length > 1) nodes.push({ members });
    }
    return { T, nodes, byName };
}

// the battery's traces: the wave leaves at D = 0 where each begins (the visible start of the rail's two, the jack's trace at its pack end)
const SOURCES = [["packCpu", 0, 1], ["packSlot", 0, 1], ["jackPack", 1, -1]];      // [name, end, dir]

function walk(G, opt) {
    const maxDist = (opt && opt.maxDist) || PULSE.walkTo;
    const gr = graph(G);
    const T = gr.T;
    const at = T.map(() => []);                        // per trace: node members on it { a, node }
    gr.nodes.forEach((n, ni) => n.members.forEach((m) => at[m.t.id].push({ a: m.a, node: ni })));
    const entries = T.map(() => []);
    const seen = new Set();
    let count = 0;
    const MAXW = 20000;
    const stack = [];
    const push = (t, a0, dir, D0, node) => { stack.push({ t, a0, dir, D0, node }); };
    for (const [n, end, dir] of SOURCES) {
        const t = gr.byName[n];
        push(t, end ? t.len : 0, dir, 0, -1);
    }
    while (stack.length) {
        const w = stack.pop();
        if (w.D0 > maxDist) continue;
        const { t, a0, dir, D0 } = w;
        const eEnd = dir > 0 ? t.len : 0;
        if (Math.abs(eEnd - a0) < 1e-9) continue;       // a wave entering at the very end it would leave by
        const c = D0 - dir * a0;
        // a wave within MERGE mm of one already walked on this trace (same way, same entry place) is that wave: the pulse is MERGE wide at the least, and
        // the parallel lanes of the fork would otherwise multiply a lap into thousands of walks no eye could tell apart
        const k = `${t.id}|${dir}|${Math.round(c / MERGE)}|${Math.round(a0)}`;
        if (seen.has(k)) continue;
        seen.add(k);
        if (++count > MAXW) throw new Error("too many walks");
        entries[t.id].push({ c, dir, from: a0 });
        // every node this wave passes (ahead of a0, up to the end), and the one at the end
        for (const m of at[t.id]) {
            const ahead = dir * (m.a - a0);
            if (ahead < -1e-9 || (ahead < 1e-9 && m.node === w.node)) continue;       // behind us, or the node it entered by
            const Dn = D0 + Math.abs(m.a - a0);
            if (Dn > maxDist) continue;
            for (const o of gr.nodes[m.node].members) {
                if (o.t === t) continue;
                if (o.t.len < 0.001) continue;
                const dirs = o.a <= 0 ? [1] : (o.a >= o.t.len ? [-1] : [1, -1]);
                for (const d of dirs) push(o.t, o.a, d, Dn, m.node);
            }
        }
    }
    // A trace of NO LENGTH (the front T's stem: the +z stub's round end on the zone's edge, 2.2 wide) has no ends, so it is a member of no node and no wave runs on it; but
    // its disc is the nearest copper to the pixels at the T, and the pulse passing the T would leave a hole in it a millimetre wide (alpha 0.64 -> 0 -> 0.64 in 0.5 mm, found
    // when the pulse got strong there: round 5). It carries what the trace it lies on carries at that place: one wave at each distance the pulse is there.
    for (const z of T) {
        if (z.len >= 0.001) continue;
        let host = null;
        for (const h of T) {
            if (h === z || h.len < 0.001) continue;
            const q = nearest(h, z.pts[0]);
            if (q.d <= hwAt(z, 0) + 0.1) { host = { t: h, a: q.s }; break; }
        }
        if (!host) continue;
        const ds = entries[host.t.id].filter((e) => e.dir * (host.a - e.from) >= -1e-6).map((e) => e.c + e.dir * host.a).sort((x, y) => x - y);
        let last = -1e9;
        for (const d of ds)
            if (d - last > MERGE) { entries[z.id].push({ c: d, dir: 1, from: 0 }); last = d; }
    }
    return { entries, nodes: gr.nodes, count, graph: gr };
}

module.exports = { walk, graph, SOURCES, TOL, MERGE, PULSE };
