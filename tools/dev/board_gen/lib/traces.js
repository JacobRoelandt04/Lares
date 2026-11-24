"use strict";
// traces.js -- the copper: every trace's signed distance, kind and arc length as unrolled literal calls (sceneTraces), the smooth union of a blend group, and
// (opts.flow, the glow) the flow coordinates along each route. A trace is G.TRACES[i] = { name, kind: "stub"|"power"|"signal", pts, width, blend, zone, ... }; the
// scene supplies flowTables(G) (what a route's coordinates mean) and traceTailLines(G) (the constants that sit after the field: where particles start).

function traceBlock(G, scene, opts, fmt) {
    const { f, v2, v3 } = fmt;
    // traces: the nearest one's signed distance (- inside), kind, and its arc position from where
    // current enters (`from`), so a glow or a particle can run along it
    const kinds = { stub: 0, power: 1, signal: 2 };
    const flow = !!opts.flow;      // the glow: the field also carries the flow coordinate (SceneGeometry.js: THE FLOW), the board's and the particles' do not
    const wOf = (t, pt) => (pt.length > 2 ? pt[2] : t.width);      // the trace's FULL width at a vertex
    const CULL = 3.0;          // mm: a stretch of copper farther than this from p cannot change what any caller reads
    // the stretch's own field and the nearest single stretch (the board's and the particles' seg), ...
    // The board's kind (opts.packHalf) also carries the distance from the point to the nearest stretch's own centre line, in 1024ths of a mm, times 4, added to
    // the kind (0, 1, 2: -1 stays "no trace"): the Blueprint draws a thin trace as one line ON that centre line (a contour of the union's depth, which is how it was
    // drawn, runs round the body of a wide trace beside it at a T) and reads it back with floor(kind / 4) / 1024. A step of 1/1024 mm is under a level of the
    // line's coverage, so the cached board and the live patch -- whose positions differ in the last float bits -- still agree to the level.
    // Every stretch only KEEPS its distance (tLr); the conversion is made once, at the end of sceneTraces: in the stretch it was ~5 instructions a copy of ninety.
    const segPlain = [
        "void seg(vec2 p, vec2 a, vec2 b, float hw0, float hw1, float cum, int kind, int id, inout vec3 dl) {",
        "    vec2 ab = b - a;",
        "    float l2 = max(dot(ab, ab), 1e-6);",
        "    float t = clamp(dot(p - a, ab) / l2, 0.0, 1.0);",
        "    float hw = mix(hw0, hw1, t);                     // a stretch may narrow along itself",
        "    vec2 r = p - a - ab * t;",
        "    float lr = length(r);",
        "    float dd = lr - hw;",
        "    if (dd < dl.x) dl = vec3(dd, lr > 1e-5 ? r / lr : vec2(0.0, 1.0));",
        opts.packHalf ? "    if (dd < tNear) { tNear = dd; tKind = kind; tLr = lr; tId = id; tArc = cum + t * sqrt(l2); tHalf = hw; }"
                      : "    if (dd < tNear) { tNear = dd; tKind = kind; tId = id; tArc = cum + t * sqrt(l2); tHalf = hw; }",
        "}"];
    // ... and the glow's: the same, plus the flow coordinates `tF` of the nearest stretch (f0 at its start, f1 at its end, baked from SceneGeometry: x the
    // route's coordinate `s`, y the dGPU-only display path's `g`). `ext`
    // lets the coordinate run on past a trace's ENDS (x: before the first stretch's start, y: after the last one's end): the pulse slides over a cap
    // and out with the copper's own coverage instead of sitting flat on it (the arc `tArc` runs on too). segS is the stretch at a T: it blends its
    // coordinate with the one it displaces (or that displaces it) over FLOW_SOFT mm of distance difference, so the coordinate -- and the light -- is one
    // continuous field across the junction and the line where the nearest trace switches cannot be seen.
    const segFlow = [
        "float tCl;                 // the distance to the nearest centre line (the glow's tHalf is the half width OF THAT trace: at a T the point on the thin lane's centre line is the lane's, not the stem's)",
        "vec2 tF;                   // the flow coordinates at p (mm along its route, x; along the dGPU-only display path, y; SceneGeometry.js: THE FLOW), of the nearest stretch, blended at a T",
        "const float FLOW_SOFT = 0.8;",
        "void segF(vec2 p, vec2 a, vec2 b, float hw0, float hw1, float cum, int kind, int id, vec2 f0, vec2 f1, vec2 ext, inout vec3 dl) {",
        "    vec2 ab = b - a;",
        "    float l2 = max(dot(ab, ab), 1e-6);",
        "    float tu = dot(p - a, ab) / l2;",
        "    float t = clamp(tu, 0.0, 1.0);",
        "    float hw = mix(hw0, hw1, t);                     // a stretch may narrow along itself",
        "    vec2 r = p - a - ab * t;",
        "    float lr = length(r);",
        "    float dd = lr - hw;",
        "    if (dd < dl.x) dl = vec3(dd, lr > 1e-5 ? r / lr : vec2(0.0, 1.0));",
        "    if (lr < tCl) { tCl = lr; tHalf = hw; }",
        "    if (dd < tNear) {",
        "        float te = clamp(tu, -ext.x * 1e3, 1.0 + ext.y * 1e3);",
        "        tNear = dd; tKind = kind; tId = id; tArc = cum + te * sqrt(l2); tF = mix(f0, f1, te);",
        "    }",
        "}",
        "void segS(vec2 p, vec2 a, vec2 b, float hw0, float hw1, float cum, int kind, int id, vec2 f0, vec2 f1, vec2 ext, inout vec3 dl) {",
        "    vec2 ab = b - a;",
        "    float l2 = max(dot(ab, ab), 1e-6);",
        "    float tu = dot(p - a, ab) / l2;",
        "    float t = clamp(tu, 0.0, 1.0);",
        "    float hw = mix(hw0, hw1, t);",
        "    vec2 r = p - a - ab * t;",
        "    float lr = length(r);",
        "    float dd = lr - hw;",
        "    if (dd < dl.x) dl = vec3(dd, lr > 1e-5 ? r / lr : vec2(0.0, 1.0));",
        "    if (lr < tCl) { tCl = lr; tHalf = hw; }",
        "    if (dd < tNear + FLOW_SOFT) {",
        "        float te = clamp(tu, -ext.x * 1e3, 1.0 + ext.y * 1e3);",
        "        vec2 fv = mix(f0, f1, te);",
        "        float w = clamp(0.5 + 0.5 * (tNear - dd) / FLOW_SOFT, 0.0, 1.0);     // 1/2 where the two are equally near, 1 where this one is FLOW_SOFT nearer, 0 where it is that much farther",
        "        tF = tNear < 1e8 ? mix(tF, fv, w) : fv;",
        "        if (dd < tNear) { tNear = dd; tKind = kind; tId = id; tArc = cum + te * sqrt(l2); }",
        "    }",
        "}"];
    // The board's blend members (opts.packHalf). A member keeps ONE record of its nearest stretch -- (distance, the offset r from the stretch's closest point, its
    // length, and the half width there) -- and the two things that were done in every stretch are done once, after the member's last: the group's nearest-stretch
    // bookkeeping (tNear, tKind, tLr, tHalf) and the unit gradient r / |r| that blendUnion reads (a reciprocal, two products and a select a stretch, 71 stretches). Strictly nearer
    // wins at both levels, in the order of the stretches and then of the members, so the winner is the first stretch of the nearest distance, exactly as when every stretch asked.
    const segBoard = [
        "void segB(vec2 p, vec2 a, vec2 b, float hw0, float hw1, inout vec4 dl, inout float dh) {",
        "    vec2 ab = b - a;",
        "    float l2 = max(dot(ab, ab), 1e-6);",
        "    float t = clamp(dot(p - a, ab) / l2, 0.0, 1.0);",
        "    float hw = mix(hw0, hw1, t);                     // a stretch may narrow along itself",
        "    vec2 r = p - a - ab * t;",
        "    float lr = length(r);",
        "    float dd = lr - hw;",
        "    if (dd < dl.x) { dl = vec4(dd, r, lr); dh = hw; }",
        "}"];
    const tr = ["", "// ---- traces: nearest signed distance (mm, < 0 inside), its kind, its arc length from `from`, its half width there ----",
                "float tD; int tKind; int tId; float tArc; float tHalf;" + (opts.packHalf ? " float tLr;" : ""),
                "float tNear;      // the nearest SINGLE stretch's distance: it names the trace (tKind, tId, tArc, tHalf); tD may be a blend of several",
                "// dl is a trace's own field: x the signed distance, yz its gradient direction (away from the copper's centre line)",
                ...(flow ? segFlow : segPlain),
                ...(opts.packHalf ? segBoard : []),
                "// The smooth union of two traces' fields over k mm (a polynomial smooth minimum; BLEND_K, or a group's own: the T's fillets reach further):",
                "// traces that come closer",
                "// than that melt into one body, and where they are farther apart nothing changes. A fillet belongs in a CROTCH,",
                "// where the two contours face one another; where they run the same way (lanes that start on top of one another,",
                "// or one landing in another) a plain smooth minimum would swell the body, so the fillet scales with how far",
                "// apart the two gradients point: 0 when they agree, 1 when they oppose.",
                "vec3 blendUnion(vec3 A, vec3 B, float k) {",
                "    float h = max(k - abs(A.x - B.x), 0.0) / k;",
                "    float opp = 0.5 * (1.0 - dot(A.yz, B.yz));",
                "    return vec3(min(A.x, B.x) - h * h * k * 0.25 * opp, A.x < B.x ? A.yz : B.yz);",
                "}",
                "// a trace's start's distance from the pack mm (the power-on sweep's; the pulse trains run on the flow: segFlow)",
                "float traceFromPack(int id) {",
                ...G.TRACES.map((t, id) => `    if (id == ${id}) return ${f(t.fromPack)};`),
                "    return 0.0;",
                "}",
                ...(flow ? scene.flowTables(G) : []),
                "// p: board space.",
                "// Inside the zone only its four stubs, outside only the rest: a trace that leaves the zone starts FLAT on its",
                "// edge, at the stub's own width, and narrows along itself (a union of two round caps there left a blob in Material and",
                "// an extra outline in Blueprint at every joint). Traces of one blend group (a fan of lanes, lanes that merge)",
                "// melt where they come close. A stretch farther than CULL from p is not looked at: it could not be read.",
                "void sceneTraces(vec2 p) {",
                `    tD = 1e9; tNear = 1e9; tKind = -1; tId = -1; tArc = 0.0; tHalf = 0.0;${flow ? " tF = vec2(0.0); tCl = 1e9;" : ""}`,
                "    bool z = inZone(p);"];
    const groups = [];                     // [{ name|null, traces: [id...], zone }], in the order of first appearance
    G.TRACES.forEach((t, id) => {
        const key = t.blend || ("#" + id);
        let g = groups.find((q) => q.key === key);
        if (!g) {
            g = { key, blend: !!t.blend, zone: !!t.zone, ids: [] };
            groups.push(g);
        }
        g.ids.push(id);
    });
    // a chunk of up to 4 consecutive stretches shares one bounding box (the stretches' ends and widest half width + CULL)
    const chunkCode = (t, id, i0, i1, dl, ind, member) => {
        let hwMax = 0, x0 = 1e9, x1 = -1e9, z0 = 1e9, z1 = -1e9, cum = 0;
        for (let i = 0; i < i0; i++)
            cum += Math.hypot(t.pts[i + 1][0] - t.pts[i][0], t.pts[i + 1][1] - t.pts[i][1]);
        const lines = [];
        for (let i = i0; i < i1; i++) {
            const a = t.pts[i], b = t.pts[i + 1];
            const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
            const w0 = wOf(t, a) / 2, w1 = wOf(t, b) / 2;
            hwMax = Math.max(hwMax, w0, w1);
            x0 = Math.min(x0, a[0], b[0]); x1 = Math.max(x1, a[0], b[0]);
            z0 = Math.min(z0, a[1], b[1]); z1 = Math.max(z1, a[1], b[1]);
            if (flow)
                lines.push(`${(t.soft || []).indexOf(i) >= 0 ? "segS" : "segF"}(p, ${v2(a[0], a[1])}, ${v2(b[0], b[1])}, ${f(w0)}, ${f(w1)}, ${f(cum)}, ${kinds[t.kind]}, ${id}, ${v2(t.s[i], t.g ? t.g[i] : 0)}, ${v2(t.s[i + 1], t.g ? t.g[i + 1] : 0)}, ${v2(i === 0 ? 1 : 0, i + 2 === t.pts.length ? 1 : 0)}, ${dl});`);
            else if (member)
                lines.push(`segB(p, ${v2(a[0], a[1])}, ${v2(b[0], b[1])}, ${f(w0)}, ${f(w1)}, ${dl}, dh);`);
            else
                lines.push(`seg(p, ${v2(a[0], a[1])}, ${v2(b[0], b[1])}, ${f(w0)}, ${f(w1)}, ${f(cum)}, ${kinds[t.kind]}, ${id}, ${dl});`);
            cum += len;
        }
        const m = hwMax + CULL;
        const out = [`${ind}if (p.x > ${f(x0 - m)} && p.x < ${f(x1 + m)} && p.y > ${f(z0 - m)} && p.y < ${f(z1 + m)}) {`];
        for (const l of lines)
            out.push(ind + "    " + l);
        out.push(ind + "}");
        return out;
    };
    const traceCode = (id, dl, ind, member) => {
        const t = G.TRACES[id], out = [];
        for (let i = 0; i + 1 < t.pts.length; i += 4)
            out.push(...chunkCode(t, id, i, Math.min(i + 4, t.pts.length - 1), dl, ind, member));
        return out;
    };
    for (const g of groups) {
        const t0 = G.TRACES[g.ids[0]];
        const names = g.ids.map((id) => G.TRACES[id].name).join(", ");
        tr.push(`    ${g.zone ? "if (z) {" : "if (!z) {"} // ${g.blend ? "blend group: " : ""}${names} (${t0.kind}, from ${t0.from}${g.ids.length === 1 ? ", " + f(t0.length) + " mm" : ""})`);
        if (g.blend) {
            tr.push("        vec3 dg = vec3(1e9, 0.0, 1.0);");
            for (const id of g.ids) {
                const k = t0.blendK ? f(t0.blendK) : "BLEND_K";
                if (opts.packHalf) {
                    tr.push(`        { // ${G.TRACES[id].name}, ${f(G.TRACES[id].length)} mm`, "            vec4 dl = vec4(1e9, 0.0, 1.0, 1.0);", "            float dh = 0.0;");
                    tr.push(...traceCode(id, "dl", "            ", true));
                    tr.push(`            if (dl.x < tNear) { tNear = dl.x; tKind = ${kinds[G.TRACES[id].kind]}; tLr = dl.w; tHalf = dh; }`,
                            `            dg = blendUnion(dg, vec3(dl.x, dl.w > 1e-5 ? dl.yz / dl.w : vec2(0.0, 1.0)), ${k});`, "        }");
                    continue;
                }
                tr.push(`        { // ${G.TRACES[id].name}, ${f(G.TRACES[id].length)} mm`, "            vec3 dl = vec3(1e9, 0.0, 1.0);");
                tr.push(...traceCode(id, "dl", "            "));
                tr.push(`            dg = blendUnion(dg, dl, ${k});`, "        }");
            }
            tr.push("        tD = min(tD, dg.x);");
        } else {
            tr.push("        vec3 dl = vec3(1e9, 0.0, 1.0);");
            tr.push(...traceCode(g.ids[0], "dl", "        "));
            tr.push("        tD = min(tD, dl.x);");
        }
        tr.push("    }");
    }
    if (opts.packHalf)
        tr.push("    if (tKind >= 0)",
                "        tKind += 4 * int(min(tLr, 0.98) * 1024.0);      // the nearest stretch's own centre-line distance, packed ONCE (every stretch only keeps it: tLr)");
    tr.push("}");
    tr.push("", ...scene.traceTailLines(G));
    return tr.join("\n");
}

module.exports = { traceBlock };
