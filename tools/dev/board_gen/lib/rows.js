"use strict";
// rows.js -- the row functions for K candidate cells: identical boxes (a row of pins, fins, chips) as ONE primitive, straight-line GLSL.
// Scene-free: a scene's cast names the ones it calls (cast.js `hitBlock` emits only those).

// The row functions for K candidate cells (see the comment in the geometry block): K fixed, straight-line code. Two flavours:
//   general   (the package's rows, whose ray is turned about y; the shadow's, whose ray goes toward the light; the cylinders'): the ray may run either way along the
//             row and a slab is entered at either of its two faces
//   camera    (gridHit<ax><K>C, every other group's hits): the ray of scenePrimary is the camera's own, toward -x -y -z in a frame that only slides, so a slab is entered
//             at its FAR face with no min / max pair per axis, nothing lies behind the ray's origin (it is hundreds of mm up the ray) and the ray runs toward -row along
//             the row. The cells of a row share their box's slabs on the two axes the row does not run along: those are computed ONCE for all K cells, and only the
//             cell's own slab on the row's axis is. Every number is formed by the very expression the cell's own box test would have formed, so the picture is bit
//             for bit what it was.
function rowFunctions(K) {
    const j = (i) => (i === 0 ? "ka" : `ka + ${i}.0 * st`);
    const zc = (i) => `mn + vec3(0.0, 0.0, clamp(${j(i)}, k0, k1) * pz)`, xc = (i) => `mn + vec3(clamp(${j(i)}, k0, k1) * px, 0.0, 0.0)`;
    const idx = [...Array(K).keys()];
    const pre = (ax) => `    float tn; float tf;
    if (!rowBox(ro, inv, mn, mn + vec3(${ax === "Z" ? "sz.x, sz.y, (n - 1.0) * pz + sz.z" : "(n - 1.0) * px + sz.x, sz.y, sz.z"}), tn, tf)@@HITT@@)
        return@@RET@@;
    float ${ax === "Z" ? "za" : "xa"} = ro.${ax === "Z" ? "z" : "x"} + rd.${ax === "Z" ? "z" : "x"} * max(tn, 0.0) - mn.${ax === "Z" ? "z" : "x"};
    float ${ax === "Z" ? "zb" : "xb"} = ro.${ax === "Z" ? "z" : "x"} + rd.${ax === "Z" ? "z" : "x"} * tf - mn.${ax === "Z" ? "z" : "x"};
    float k0; float k1; float ka;
    float st = rd.${ax === "Z" ? "z" : "x"} < 0.0 ? -1.0 : 1.0;
    rowSpan(min(${ax === "Z" ? "za, zb" : "xa, xb"}), max(${ax === "Z" ? "za, zb" : "xa, xb"}), sz.${ax === "Z" ? "z" : "x"}, p${ax === "Z" ? "z" : "x"}, n, st, k0, k1, ka);
`;
    const out = [];
    for (const ax of ["Z", "X"]) {
        const pn = ax === "Z" ? "pz" : "px", c = ax === "Z" ? zc : xc;
        out.push(`void gridHit${ax}${K}(vec3 ro, vec3 rd, vec3 inv, vec3 mn, vec3 sz, float ${pn}, float n, float info) {\n` + pre(ax).replace("@@HITT@@", " || tn >= hT").replace("@@RET@@", "")
                 + idx.map((i) => `    boxHit(ro, inv, ${c(i)}, ${c(i)} + sz, info);\n`).join("") + "}");
        out.push(`bool gridAny${ax}${K}(vec3 ro, vec3 rd, vec3 inv, vec3 mn, vec3 sz, float ${pn}, float n) {\n` + pre(ax).replace("@@HITT@@", "").replace("@@RET@@", " false")
                 + `    return ${idx.map((i) => `anyHit(ro, inv, ${c(i)}, ${c(i)} + sz)`).join(" || ")};\n}`);
    }
    // cylinders in a row along z
    const cyl = (i) => `mn + vec3(0.0, 0.0, clamp(${j(i)}, k0, k1) * pz)`;
    out.push(`void gridHitCylZ${K}(vec3 ro, vec3 rd, vec3 inv, vec3 mn, vec3 sz, float pz, float n, float info) {\n` + pre("Z").replace("@@HITT@@", " || tn >= hT").replace("@@RET@@", "")
             + idx.map((i) => `    { vec3 c = ${cyl(i)}; cylYHit(ro, rd, c.x + sz.x * 0.5, c.z + sz.z * 0.5, sz.x * 0.5, mn.y, mn.y + sz.y, info, c, c + sz); }\n`).join("") + "}");
    out.push(`bool gridAnyCylZ${K}(vec3 ro, vec3 rd, vec3 inv, vec3 mn, vec3 sz, float pz, float n) {\n` + pre("Z").replace("@@HITT@@", "").replace("@@RET@@", " false")
             + `    return ${idx.map((i) => `anyHitCylY(ro, rd, (${cyl(i)}).x + sz.x * 0.5, (${cyl(i)}).z + sz.z * 0.5, sz.x * 0.5, mn.y, mn.y + sz.y)`).join(" || ")};\n}`);
    // the camera ray's flavour: boxes only; `skipM` cells left out (the gap in the middle of a stick's chips, the cells hidden behind a tall part), a skipped
    // one's hit switched off INSIDE its own condition (a vec4 of indices, the first M of them read)
    for (const ax of ["Z", "X"]) {
        const x = ax === "X", v = x ? "x" : "z", pn = "p" + v;
        const shared = x ? `    float ya = (mn.y + sz.y - ro.y) * inv.y;
    float yb = (mn.y - ro.y) * inv.y;
    float za = (mn.z + sz.z - ro.z) * inv.z;
    float zb = (mn.z - ro.z) * inv.z;
    float sa = max(ya, za);
    float sb = min(yb, zb);
` : `    float xa = (mn.x + sz.x - ro.x) * inv.x;
    float xb = (mn.x - ro.x) * inv.x;
    float ya = (mn.y + sz.y - ro.y) * inv.y;
    float yb = (mn.y - ro.y) * inv.y;
    float sa = max(xa, ya);
    float sb = min(xb, yb);
`;
        const cell = (i, skipM) => `    {
        float ci = clamp(${j(i)}, k0, k1);
        float cv = mn.${v} + ci * ${pn};
        float ${v}a = (cv + sz.${v} - ro.${v}) * inv.${v};
        float ${v}b = (cv - ro.${v}) * inv.${v};
        float tnc = ${x ? "max(xa, sa)" : "max(sa, za)"};
        if (${skipM ? `!(ci < 0.0 || ${["x", "y", "z", "w"].slice(0, skipM).map((c) => `abs(ci - skip.${c}) < 0.5`).join(" || ")}) && ` : ""}tnc <= ${x ? "min(xb, sb)" : "min(sb, zb)"} && tnc < hT) {
            hT = tnc;
            hInfo = info + (xa >= ya && xa >= za ? 0.0 : (ya >= za ? 1.0 : 2.0));
            hMin = ${x ? "vec3(cv, mn.y, mn.z)" : "vec3(mn.x, mn.y, cv)"};
            hMax = ${x ? "vec3(cv + sz.x, mn.y + sz.y, mn.z + sz.z)" : "vec3(mn.x + sz.x, mn.y + sz.y, cv + sz.z)"};
        }
    }
`;
        const head = (skipM) => `    vec3 tmin = (mn + vec3(${x ? "(n - 1.0) * px + sz.x, sz.y, sz.z" : "sz.x, sz.y, (n - 1.0) * pz + sz.z"}) - ro) * inv;
    vec3 tmax = (mn - ro) * inv;
    float tn = max(max(tmin.x, tmin.y), tmin.z);
    float tf = min(min(tmax.x, tmax.y), tmax.z);
    if (!(tn <= tf) || tn >= hT)
        return;
    float k0; float k1; float ka;
    float st = rd.${v} < 0.0 ? -1.0 : 1.0;
    rowSpan(ro.${v} + rd.${v} * tf - mn.${v}, ro.${v} + rd.${v} * tn - mn.${v}, sz.${v}, ${pn}, n, st, k0, k1, ka);
` + shared;
        out.push(`void gridHit${ax}${K}C(vec3 ro, vec3 rd, vec3 inv, vec3 mn, vec3 sz, float ${pn}, float n, float info) {\n` + head(0) + idx.map((i) => cell(i, 0)).join("") + "}");
        for (let m = 1; m <= 4; m++)
            out.push(`void gridHit${ax}${K}CS${m}(vec3 ro, vec3 rd, vec3 inv, vec3 mn, vec3 sz, float ${pn}, float n, vec4 skip, float info) {\n` + head(m) + idx.map((i) => cell(i, m)).join("") + "}");
    }
    return out;
}

module.exports = { rowFunctions };
