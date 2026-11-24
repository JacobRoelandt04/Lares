#version 440

// =============================================================================
// veil_dimples.frag -- the lock veil "Dimple field": a pin-screen of tiny
// carved wells, lit exactly like small carved ShadowBoxes, their depths
// following slow travelling interference waves.
//
// ONE SHADER, NO ITEMS. The grid is computed in DEVICE pixels: the cell is
// floor(pixel / pitch) with an even integer pitch, so every well's centre and
// every cell edge lies on a whole pixel. The well is a disc (the pitch's
// `radius` fraction, shrinking a little as it shallows); its coverage is
// feathered INWARD only (clamp(d / px, 0, 1)) with the pixel size taken from a
// LINEAR coordinate's derivatives, never from a composed distance.
//
// LIT LIKE A CARVED SHADOWBOX. Inside the edge an inset shadow (the border
// colour deepening to shadowDeep at the edge, easing out over `shadowW` px);
// outside it a light bevel rim. Both are weighted by the wall's facing
// against the light (the shell's light comes from the top left): the wall
// toward the light is in shadow, the opposite wall catches it. A well's depth
// (0..1) scales its shadow, its radius and how dark and how transparent its
// floor is.
//
// OVER THE DESKTOP the plateau is a translucent tint of the surface and each
// floor is more transparent the deeper the well: the blurred desktop glows in
// the floors. At boot both are opaque.
//
// DEPTH (per cell) is not computed here: veil_dimples.vert evaluates the smooth fields
// (the waves, the pulses) at the vertices of a coarse grid and this shader
// reconstructs them at the cell's centre, so the 576 pixels of a cell agree and
// none recomputes them.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 1) in vec4 vA;     // w, kmul, kadd, err at the vertex
layout(location = 2) in vec4 vGx;    // their d/dx
layout(location = 3) in vec4 vGy;    // their d/dy
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    vec2  size;         // item px
    float dscale;       // device px per item px
    float time;
    float presence;
    float opaque;
    vec2  origin;

    vec4  grid;         // pitch (device px, even), radius fraction, min depth, shadow width px
    vec4  wave;         // k (rad / item px), omega (rad / s), contrast, plane wave angle
    vec4  srcA;         // radial source 0 xy, source 1 xy (item px)
    vec4  light;        // toward-light x, y (unit), bevel width px, -
    vec4  grade;        // plateau alpha, floor glow (transparency of a full-depth floor), shadow gain, bevel gain
    vec4  grade2;       // dark 0/1, rim glint 0..1, -, -
    vec4  front;        // the entrance's front: radius px from the popup's edge, 1 / front width px, popup half extents x, y

    vec4  cSurface;
    vec4  cFloor;       // panelSunk
    vec4  cMid;         // border
    vec4  cShadow;      // shadowDeep
    vec4  cBevel;
    vec4  cError;

    // the pulses (read by the vertex stage only): 32 slots, vec4(x, y, age s, kind + 0.9 * (1 - weight))
    vec4  pk;           // key:  amplitude, speed px/s, sigma px, life s
    vec4  pf;           // fail
    vec4  po;           // -, -, pulses alive (the vertex stage's), -
    vec4  pw;           // wake
    vec4 p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5;
    vec4 p6; vec4 p7; vec4 p8; vec4 p9; vec4 p10; vec4 p11;
    vec4 p12; vec4 p13; vec4 p14; vec4 p15; vec4 p16; vec4 p17;
    vec4 p18; vec4 p19; vec4 p20; vec4 p21; vec4 p22; vec4 p23;
    vec4 p24; vec4 p25; vec4 p26; vec4 p27; vec4 p28; vec4 p29;
    vec4 p30; vec4 p31;
};


vec4 over(vec4 acc, vec3 c, float a) {
    return vec4(c * a + acc.rgb * (1.0 - a), a + acc.a * (1.0 - a));
}

void main() {
    // ---- the grid, in device pixels -----------------------------------------
    vec2 pd = qt_TexCoord0 * size * dscale;
    float P = grid.x;
    vec2 cell = floor(pd / P);
    vec2 q = pd - (cell + 0.5) * P;

    // ---- the rise: wells press in from flat, outward from the origin -------------
    vec2 cc = (cell + 0.5) * P / dscale;               // the well's centre, item px
    // THE ENTRANCE: a front rolls out from the popup's edge and each cell snaps in as it
    // passes -- the pin drops, overshoots its well a little and settles -- going from the
    // desktop to the finished cell within the front's width: no faint phase, no lattice of
    // faint dots over the blur. The cell decides, so all its pixels agree.
    float pr = clamp((front.x - length(max(abs(cc - origin) - front.zw, 0.0))) * front.y, 0.0, 1.0);
    pr = pr * pr * (3.0 - 2.0 * pr);
    float drop = 1.0 + 0.3 * sin(3.14159265 * pr);    // 1 at rest and ahead of the front
    // the ground's own tint follows the front PER PIXEL: stepping it per cell lays a staircase of
    // 24 px columns over any hard edge of the desktop behind it (a blocky blur)
    float prp = clamp((front.x - length(max(abs(qt_TexCoord0 * size - origin) - front.zw, 0.0))) * front.y, 0.0, 1.0);
    prp = prp * prp * (3.0 - 2.0 * prp);

    float r = length(q);
    float px = max(length(vec2(dFdx(pd.x), dFdy(pd.x))), 1e-3);   // before any branch: derivatives
    float tintA = opaque > 0.5 ? 1.0 : grade.x * prp;
    vec3 plate = cSurface.rgb;
    float bw = light.z;

    vec4 acc;
    if (r > grid.y * 0.5 * P * 1.3 + bw) {
        // beyond the widest well and its bevel rim: the plain plateau, whatever the depth
        // (half the pixels of a cell), so the depth is not even looked up
        acc = vec4(plate * tintA, tintA);
    } else {
    // ---- this cell's depth: the smooth fields at the cell's centre -------------
    // (from the vertices, see veil_dimples.vert), then the same chain as ever
    vec2 dc = cc - qt_TexCoord0 * size;
    vec4 f = vA + vGx * dc.x + vGy * dc.y;
    float err = clamp(f.w, 0.0, 1.0);

    float dep = 0.5 + 0.5 * f.x / 2.4 * wave.z;
    dep = smoothstep(0.34, 0.72, dep);
    dep = mix(grid.z, 1.0, dep);
    dep = clamp(dep * f.y + f.z, 0.0, 1.0);          // the pulses: crest, trough
    dep *= pr;

    // ---- the well ---------------------------------------------------------------------
    float R = grid.y * 0.5 * P * (0.2 + 0.8 * sqrt(dep)) * drop;
    float d = R - r;                                   // px inward of the rim
    float cover = clamp(d / px, 0.0, 1.0) * smoothstep(0.0, 0.08, dep);

    if (d < -bw) {
        // beyond the bevel rim: the plain plateau (most pixels of a cell; the
        // rim is 0 and the well's cover is 0 out here, so nothing is skipped)
        acc = vec4(plate * tintA, tintA);
    } else {
        vec2 u = q / max(r, 1e-3);
        vec2 Ld = light.xy;
        float toL = dot(u, Ld);                            // > 0: the wall toward the light

        // plateau: surface + the bevel rim outside the edge on the lit side
        vec4 accP = vec4(plate * tintA, tintA);
        float out_ = -d;                                   // px outward of the rim
        float rim = (1.0 - smoothstep(0.0, bw, out_)) * step(0.0, out_) * smoothstep(-0.2, 0.9, -toL);
        accP = over(accP, cBevel.rgb, rim * grade.w * smoothstep(0.0, 0.08, dep) * tintA);

        // floor: sunk fill, deeper wells darker and more transparent
        vec3 fl = mix(cFloor.rgb, cMid.rgb, dep * 0.85);
        fl = mix(fl, cError.rgb, err * 0.55);
        float fA = opaque > 0.5 ? 1.0 : tintA * (1.0 - grade.y * dep);
        vec4 accF = vec4(fl * fA, fA);
        float sw = max(grid.w * (0.45 + 0.55 * dep), 0.5);
        float t = clamp(d / sw, 0.0, 1.0);
        float fall = (1.0 - t) * (1.0 - t);
        float facing = 0.28 + 0.72 * smoothstep(-0.25, 0.85, toL);
        vec3 shc = mix(cMid.rgb, cShadow.rgb, 0.35 + 0.65 * dep);
        shc = mix(shc, cError.rgb, clamp(err * 1.3, 0.0, 1.0) * 0.65);
        float shA = clamp(fall * facing * (0.35 + 0.65 * dep) * grade.z, 0.0, 1.0);
        accF = over(accF, shc, shA);
        // the wall away from the light catches it
        float lit = smoothstep(0.1, 0.9, -toL) * (1.0 - smoothstep(0.0, sw * 1.6, d)) * dep;
        accF = over(accF, cBevel.rgb, lit * grade.w * 0.5);


        acc = mix(accP, accF, cover);

        // DETAIL, behind a switch: a point of light on the lip of the wall away from the light,
        // where a polished dimple would catch it; deeper wells catch it harder
        if (grade2.y > 0.0) {
            vec2 dq = q + Ld * (R * 0.9);
            float sg = 0.14 * R + 0.6;
            float gl = exp(-dot(dq, dq) / (2.0 * sg * sg)) * smoothstep(0.15, 0.6, dep) * grade2.y;
            acc = over(acc, mix(cBevel.rgb, vec3(1.0), 0.55), gl * 0.75 * acc.a);
        }
    }
    }

    // dither against banding: interleaved gradient noise (no transcendental)
    float dn = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) - 0.5;
    acc.rgb += dn * acc.a / 255.0;
    fragColor = acc * qt_Opacity;
}
