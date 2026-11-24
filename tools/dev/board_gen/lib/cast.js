"use strict";
// cast.js -- the cast: the nearest hit (hT / hInfo / hMin / hMax, boxes, cylinders, rows), the camera ray's cheap tests, the shadow's accumulate.
//   hitBlock(rowFns, castText)       the GLSL machinery the cast calls (only the row functions the cast uses are emitted)
//   castBlocks(G, scene, opts, fmt)  { hit, prim, shad }: scenePrimary / sceneShadow written as unrolled literal calls for G.PARTS.
// What a scene supplies (scenes/<name>.js): groups (name -> id, in cast order), generalGroups (groups whose frame TURNS the ray: they take the
// general box tests; every other group takes the camera ray's tests), basePart (the part / group everything stands on: no cluster bound, no
// shadow), shadowWeight(group) (the GLSL expression a group's shadow is multiplied by), hitSign (the GLSL expression of the winner's face sign).

const { rowFunctions } = require("./rows.js");

// The cast's candidate tests (the nearest hit). A candidate that wins keeps only what a pixel needs of it: the distance hT, ONE number hInfo that names its part,
// its material and its group and the axis of the face the ray entered through (PK(), a float: GLSL 1.20 has no bit operations, and every part of it is a
// small integer a float holds exactly), and its box (hMin, hMax; a cylinder keeps its normal in hN, axis 3). scenePrimary unpacks hInfo ONCE, at its end, into
// hPart, hMat, hGroup and hN -- a hundred candidates used to write three ints and a normal of their own each, and every one of those writes is code.
// `rowFns` are the row functions (rowFunctions) a cast calls: the others are not emitted.
function hitBlock(rowFns, castText) {
    const used = rowFns.filter((fn) => castText.includes(fn.match(/^\w+ (\w+)\(/)[1] + "("));
    return `
// ---- the nearest hit ----------------------------------------------------------------------
float hT;
float hInfo;    // -1: nothing yet; else PK(part, mat, group) + the axis of the face the ray entered through (0 x, 1 y, 2 z, 3 a cylinder's: its normal is in hN)
vec3 hN;        // in the hit group's frame (groupNormal turns it to world); scenePrimary's end makes a box's of hInfo's axis
int hPart;
int hMat;
int hGroup;
vec3 hMin;
vec3 hMax;
#define PK(p, m, g) (((float(p) * 64.0 + float(m)) * 8.0 + float(g)) * 4.0)
void boxHit(vec3 ro, vec3 inv, vec3 mn, vec3 mx, float info) {
    vec3 t1 = (mn - ro) * inv;
    vec3 t2 = (mx - ro) * inv;
    vec3 tmin = min(t1, t2);
    vec3 tmax = max(t1, t2);
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (tn <= tf && tn > 0.0 && tn < hT) {
        hT = tn;
        hInfo = info + (tmin.x >= tmin.y && tmin.x >= tmin.z ? 0.0 : (tmin.y >= tmin.z ? 1.0 : 2.0));       // the face the ray entered through: the axis whose slab opened last
        hMin = mn;
        hMax = mx;
    }
}
// The camera's ray. scenePrimary is only ever asked for it (-CAM_C), and a group other than the package's only slides, so the ray runs toward -x -y -z in
// every such frame: inv is negative on all three axes, a slab opens at its FAR face (the box's max) and closes at its near one -- no min / max pair per axis --
// and the ray's origin is hundreds of mm up the ray, so nothing is behind it (the 'gone' groups put theirs so far off that tn > tf: no hit). The package's
// group turns the ray about y and takes the general tests above.
void boxHitC(vec3 ro, vec3 inv, vec3 mn, vec3 mx, float info) {
    vec3 tmin = (mx - ro) * inv;
    vec3 tmax = (mn - ro) * inv;
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (tn <= tf && tn < hT) {
        hT = tn;
        hInfo = info + (tmin.x >= tmin.y && tmin.x >= tmin.z ? 0.0 : (tmin.y >= tmin.z ? 1.0 : 2.0));
        hMin = mn;
        hMax = mx;
    }
}
// boxHitC for a part that may be cut away (cutouts.glsl): 'off' skips it INSIDE the hit's own condition -- a branch around the call would
// split the straight-line cast, and a shader compiles control flow dearly
void boxHitGC(vec3 ro, vec3 inv, vec3 mn, vec3 mx, float info, bool off) {
    vec3 tmin = (mx - ro) * inv;
    vec3 tmax = (mn - ro) * inv;
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (!off && tn <= tf && tn < hT) {
        hT = tn;
        hInfo = info + (tmin.x >= tmin.y && tmin.x >= tmin.z ? 0.0 : (tmin.y >= tmin.z ? 1.0 : 2.0));
        hMin = mn;
        hMax = mx;
    }
}
bool slabHit(vec3 ro, vec3 inv, vec3 mn, vec3 mx) {
    vec3 t1 = (mn - ro) * inv;
    vec3 t2 = (mx - ro) * inv;
    vec3 tmin = min(t1, t2);
    vec3 tmax = max(t1, t2);
    return max(max(tmin.x, tmin.y), tmin.z) <= min(min(tmax.x, tmax.y), tmax.z) && min(min(tmax.x, tmax.y), tmax.z) > 0.0;
}
// slabHit for the camera's ray (see boxHitC)
bool slabHitC(vec3 ro, vec3 inv, vec3 mn, vec3 mx) {
    vec3 tmin = (mx - ro) * inv;
    vec3 tmax = (mn - ro) * inv;
    return max(max(tmin.x, tmin.y), tmin.z) <= min(min(tmax.x, tmax.y), tmax.z);
}
bool anyHit(vec3 ro, vec3 inv, vec3 mn, vec3 mx) {
    vec3 t1 = (mn - ro) * inv;
    vec3 t2 = (mx - ro) * inv;
    vec3 tmin = min(t1, t2);
    vec3 tmax = max(t1, t2);
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    return tn <= tf && tf > 0.02;
}

// A vertical cylinder (axis y, flat lid) from y0 to y1 about (cx, cz): the nearest of its side and its lid. A part that sets
// shape "cylY" is drawn by this over its box (the box is its bound and the frame its materials measure edges in).
void cylYHit(vec3 ro, vec3 rd, float cx, float cz, float r, float y0, float y1, float info, vec3 bmin, vec3 bmax) {
    float best = hT;
    vec3 nrm = vec3(0.0, 1.0, 0.0);
    bool found = false;
    vec2 oc = ro.xz - vec2(cx, cz);
    float a = dot(rd.xz, rd.xz);
    float bq = dot(oc, rd.xz);
    float cq = dot(oc, oc) - r * r;
    float disc = bq * bq - a * cq;
    if (a > 1e-8 && disc > 0.0) {
        float t = (-bq - sqrt(disc)) / a;
        float y = ro.y + t * rd.y;
        if (t > 0.0 && t < best && y >= y0 && y <= y1) {
            best = t;
            found = true;
            vec2 q = (oc + t * rd.xz) / r;
            nrm = vec3(q.x, 0.0, q.y);
        }
    }
    if (rd.y < 0.0) {
        float t = (y1 - ro.y) / rd.y;
        vec2 q = oc + t * rd.xz;
        if (t > 0.0 && t < best && dot(q, q) <= r * r) {
            best = t;
            found = true;
            nrm = vec3(0.0, 1.0, 0.0);
        }
    }
    if (found) {
        hT = best; hN = nrm; hInfo = info + 3.0; hMin = bmin; hMax = bmax;
    }
}
// does anything of the cylinder lie between ro and (a long way along) rd
bool anyHitCylY(vec3 ro, vec3 rd, float cx, float cz, float r, float y0, float y1) {
    vec2 oc = ro.xz - vec2(cx, cz);
    float a = dot(rd.xz, rd.xz);
    float bq = dot(oc, rd.xz);
    float cq = dot(oc, oc) - r * r;
    float tn = -1e9, tf = 1e9;
    if (a < 1e-8) {
        if (cq > 0.0) return false;
    } else {
        float D = bq * bq - a * cq;
        if (D <= 0.0) return false;
        float sq = sqrt(D);
        tn = (-bq - sq) / a;
        tf = (-bq + sq) / a;
    }
    float t0 = (y0 - ro.y) / rd.y, t1 = (y1 - ro.y) / rd.y;
    tn = max(tn, min(t0, t1));
    tf = min(tf, max(t0, t1));
    return tn <= tf && tf > 0.02;
}

// A ROW: identical boxes ('n' cells at 'pitch' along ONE axis, the first at 'mn', each 'sz' big) as ONE primitive. The ray's footprint over the
// row's box names the cells it can touch (k0 .. k1); the first K it meets are tested, K fixed (rowCells: how many one ray can touch -- its path through the
// row's box is as long sideways as the box is high), straight-line code with no loop: a shader compiles control flow dearly and straight-line arithmetic cheaply.
// The Z functions take a row along z, the X functions one along x; the Cyl ones draw each cell as its inscribed cylinder.
void rowSpan(float lo, float hi, float sz, float pitch, float n, float step, out float k0, out float k1, out float ka) {
    k0 = max(ceil((lo - sz) / pitch), 0.0);
    k1 = min(floor(hi / pitch), n - 1.0);
    ka = step < 0.0 ? k1 : k0;                       // the end the ray enters at
}
// the ray's span in a box (tn, tf); false when it misses (or it is behind us)
bool rowBox(vec3 ro, vec3 inv, vec3 mn, vec3 mx, out float tn, out float tf) {
    vec3 t1 = (mn - ro) * inv;
    vec3 t2 = (mx - ro) * inv;
    vec3 tmin = min(t1, t2);
    vec3 tmax = max(t1, t2);
    tn = max(max(tmin.x, tmin.y), tmin.z);
    tf = min(min(tmax.x, tmax.y), tmax.z);
    return tn <= tf && tf > 0.0;
}
${used.join("\n")}
`;
}

function castBlocks(G, scene, opts, fmt) {

    // group bounds (early outs) and per-group calls
    const GROUP = scene.groups, general = (g) => scene.generalGroups.indexOf(g) >= 0, { f, v2, v3 } = fmt;
    const byGroup = {};
    G.PARTS.forEach((p, i) => { (byGroup[p.group] = byGroup[p.group] || []).push(Object.assign({ index: i }, p)); });
    const bounds = (list) => list.reduce((a, p) => ({
        min: [Math.min(a.min[0], p.min[0]), Math.min(a.min[1], p.min[1]), Math.min(a.min[2], p.min[2])],
        max: [Math.max(a.max[0], p.max[0]), Math.max(a.max[1], p.max[1]), Math.max(a.max[2], p.max[2])]
    }), { min: [1e9, 1e9, 1e9], max: [-1e9, -1e9, -1e9] });
    const pad = (b, e) => ({ min: b.min.map((v) => v - e), max: b.max.map((v) => v + e) });

    const matName = (p) => "MAT_" + Object.keys(G.MAT).find((k) => G.MAT[k] === p.mat);
    // a cylinder is the box's inscribed one (the box is its bound): axis y, radius half the box's x extent
    const cyl = (p) => `${f((p.min[0] + p.max[0]) / 2)}, ${f((p.min[2] + p.max[2]) / 2)}, ${f((p.max[0] - p.min[0]) / 2)}`;
    // a ROW (SceneGeometry.ROW) is one primitive over its grid of cells; a part is a box or a cylinder
    const rowAxis = (p) => (p.row.n[0] > 1 ? "X" : "Z");
    const rowArgs = (p) => {
        const r = p.row, x = r.n[0] > 1;
        return `${v3(p.min)}, ${v3(r.cell)}, ${f(x ? r.pitch[0] : r.pitch[1] || 1)}, ${f(x ? r.n[0] : r.n[1])}`;
    };
    // How many cells of a row ONE ray can touch: its path through the row's box is as long sideways, along the row, as the box is high (the camera's ray moves
    // as far along each axis as down; in the package's frame, which turns about y, up to sqrt 2 of that), and a path of length L meets at most
    // floor((L + cell) / pitch) + 1 cells. A row that names a bigger `k` (the heat sink's fins) keeps it.
    const rowCells = (p, g) => {
        const x = p.row.n[0] > 1, along = x ? p.row.cell[0] : p.row.cell[2], pitch = x ? p.row.pitch[0] : p.row.pitch[1];
        const k = Math.floor(((general(g) ? Math.SQRT2 : 1) * p.row.cell[1] + along) / pitch + 1e-6) + 1;
        return Math.min(Math.max(k, p.row.k > 2 ? p.row.k : 1), p.row.n[x ? 0 : 1]);
    };
    const hitCall = (p, g) => {
        const tail = `PK(${p.index}, ${matName(p)}, GRP_${g.toUpperCase()})`;
        const cam = !general(g);       // every group but the package's takes the camera ray's tests (boxHitC ...)
        if (p.row && p.row.skip !== undefined) {
            if (p.shape === "cylY" || p.cast || !cam)
                throw new Error(`${p.name}: a ROW with a skipped cell is a box row of the camera's groups that does not cast (the skip variants of the row functions are the hit's only)`);
            const sk = [].concat(p.row.skip);
            if (sk.length > 4)
                throw new Error(`${p.name}: a ROW skips at most four cells`);
            const m = sk.length;
            while (sk.length < 4)
                sk.push(-1);
            return `gridHit${rowAxis(p)}${rowCells(p, g)}CS${m}(o, d, inv, ${rowArgs(p)}, vec4(${sk.map(f).join(", ")}), ${tail});`;
        }
        if (p.row)
            return p.shape === "cylY" ? `gridHitCyl${rowAxis(p)}${rowCells(p, g)}(o, d, inv, ${rowArgs(p)}, ${tail});`
                                      : `gridHit${rowAxis(p)}${rowCells(p, g)}${cam ? "C" : ""}(o, d, inv, ${rowArgs(p)}, ${tail});`;
        if (p.cut) {
            if (!cam)
                throw new Error(`${p.name}: a part cut to an outline is not in the package's group (boxHitGC is the camera ray's)`);
            return `boxHitGC(o, inv, ${v3(p.min)}, ${v3(p.max)}, ${tail}, flagOf(${8 * Math.pow(2, G.PARTS.filter((q) => q.cut).findIndex((q) => q.name === p.name))}.0));`;
        }
        return p.shape === "cylY"
            ? `cylYHit(o, d, ${cyl(p)}, ${f(p.min[1])}, ${f(p.max[1])}, ${tail}, ${v3(p.min)}, ${v3(p.max)});`
            : `boxHit${cam ? "C" : ""}(o, inv, ${v3(p.min)}, ${v3(p.max)}, ${tail});`;
    };
    // The shadow is a straight-line accumulate (`r = max(r, test ? value : 0)`), not an early return per caster: a return is a jump out of however much code the
    // caster sits in, 35 of them kept every register of the cast live to the end of each, and the compiler pays for control flow by the jump. A lit pixel meets every
    // caster anyway; only a shadowed one used to stop early.
    const shadCall = (p, ret) => {
        const test = p.row ? `gridAny${p.shape === "cylY" ? "Cyl" : ""}${rowAxis(p)}${p.row.k || 2}(o, d, inv, ${rowArgs(p)})`
            : (p.shape === "cylY" ? `anyHitCylY(o, d, ${cyl(p)}, ${f(p.min[1])}, ${f(p.max[1])})` : `anyHit(o, inv, ${v3(p.min)}, ${v3(p.max)})`);
        return `r = max(r, ${test} ? ${ret} : 0.0);`;
    };
    // The parts of a group in order; the runs of parts that share a `cluster` are tested behind ONE bound (a ray that misses the cluster pays a
    // slab test, not its parts); a `cut` part carries its flag into its own hit (the shader found a pixel outside its outline and casts again without it)
    const emitRuns = (list, ind, call, slab) => {
        const out = [];
        const one = (p, pre) => `${pre}${call(p)}`;
        for (let i = 0; i < list.length;) {
            const cl = list[i].cluster;
            let j = i + 1;
            while (cl && j < list.length && list[j].cluster === cl)
                j++;
            const run = list.slice(i, j);
            if (cl && run.length > 1) {
                const rb = pad(bounds(run), 0.01);
                out.push(`${ind}if (${slab}(o, inv, ${v3(rb.min)}, ${v3(rb.max)})) {   // cluster ${cl}`);
                run.forEach((p) => out.push(one(p, ind + "    ")));
                out.push(`${ind}}`);
            } else {
                run.forEach((p) => out.push(one(p, ind)));
            }
            i = j;
        }
        return out;
    };
    const prim = ["", "// Every box the camera ray can hit; the nearest wins (hT ... hMax). The ray is the camera's: -CAM_C, the only one it is ever asked for (boxHitC).",
                  "void scenePrimary(vec3 ro, vec3 rd) {",
                  "    hT = 1e9; hInfo = -1.0; hN = vec3(0.0, 1.0, 0.0);",
                  "    vec3 o; vec3 d; vec3 inv;"];
    const shad = ["", "// 1 when anything that casts blocks the way from p toward the light l.", "float sceneShadow(vec3 p, vec3 l) {",
                  "    vec3 o; vec3 d; vec3 inv;", "    float r = 0.0;"];
    for (const g of Object.keys(GROUP)) {
        const all = byGroup[g] || [];
        const list = all.filter((p) => !(opts.glow && p.bake));         // the live glow casts what it lights, and what hides what it lights
        if (opts.glow && list.some((p) => p.cut))
            throw new Error(`${list.find((p) => p.cut).name}: a part cut to an outline must be baked -- the glow does not cut (cutouts.glsl is the board's)`);
        if (!list.length)
            continue;
        const gb = pad(bounds(list), 0.01);
        prim.push(`    groupRay(GRP_${g.toUpperCase()}, ro, rd, o, d);`, "    inv = 1.0 / d;");
        const casts = all.filter((p) => p.cast && p.name !== scene.basePart);
        if (list.length > 1 && g !== scene.basePart)
            prim.push(`    if (${general(g) ? "slabHit" : "slabHitC"}(o, inv, ${v3(gb.min)}, ${v3(gb.max)})) {`);
        else
            prim.push("    {");
        prim.push(...emitRuns(list, "        ", (p) => hitCall(p, g), general(g) ? "slabHit" : "slabHitC"));
        prim.push("    }");
        if (casts.length && !opts.glow) {
            shad.push(`    groupRay(GRP_${g.toUpperCase()}, p, l, o, d);`, "    inv = 1.0 / d;");
            const cb = pad(bounds(casts), 0.01);
            shad.push(`    if (slabHit(o, inv, ${v3(cb.min)}, ${v3(cb.max)})) {`);
            shad.push(...emitRuns(casts, "        ", (p) => shadCall(p, scene.shadowWeight(g)), "slabHit"));       // a lock that is still fading in casts a faint shadow, and so does a card that is dissolving (S2: its shadow was the whole box's to the last frame)
            shad.push("    }");
        }
    }
    // the winner's record, unpacked once: part, material and group; a box's normal from the axis of the face the ray entered through, signed against the ray of the
    // group's own frame (the package's is the camera's turned by -gPkgTurn)
    prim.push(`    if (hInfo < 0.0) {
        hPart = -1; hMat = -1; hGroup = -1;
    } else {
        float ax = fract(hInfo * 0.25) * 4.0;
        float rest = floor(hInfo * 0.25);
        float gr = fract(rest * 0.125) * 8.0;
        rest = floor(rest * 0.125);
        float mt = fract(rest * 0.015625) * 64.0;
        hGroup = int(gr);
        hMat = int(mt);
        hPart = int(floor(rest * 0.015625));
        if (ax < 2.5) {
            vec3 sg = ${scene.hitSign};
            hN = ax < 0.5 ? vec3(sg.x, 0.0, 0.0) : (ax < 1.5 ? vec3(0.0, sg.y, 0.0) : vec3(0.0, 0.0, sg.z));
        }
    }`);
    prim.push("}");
    shad.push("    return r;", "}");
    const hit = hitBlock([1, 2, 3].map((K) => rowFunctions(K)).flat(), prim.join("\n") + "\n" + shad.join("\n"));
    return { hit, prim: prim.join("\n"), shad: opts.glow ? null : shad.join("\n") };
}

module.exports = { hitBlock, castBlocks };
