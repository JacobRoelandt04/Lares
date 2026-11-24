#version 440
// =============================================================================
// veil_gooey.frag -- the GOOEY TIDE veil: the bar's own material as blobs.
//
// One field: nine blobs, sixteen "buds" (a key's answer) and the shell (the popup and
// the bar it hangs from), all joined by the classic quadratic smooth-min, exactly
// as the bar's popups are. Where each blob IS (its slow path, the pulses' pushes,
// the welling up) is worked out once per frame in VeilGooey.qml. The blobs' field is
// the smooth half: veil_gooey.vert evaluates it once per vertex of a ~10 px GridMesh
// and this shader rebuilds it per pixel (exact for a quadratic field), then adds the
// sharp half at full resolution: the shell (the popup's and bar's corners) and the
// buds, which merge into the shell. Not a texture: a ShaderEffectSource re-grabbed
// every tick asks Qt for a second frame (CLAUDE.md).
// The material is drawn RAISED as the shell draws a raised box: a soft drop
// shadow outside the edge, a bevel highlight inside it, plateau colour between.
// Around it the ground is the desktop dimmed and tinted toward the material
// (translucent over the held desktop, opaque at boot).
//
// NO ARRAYS. Every bud is one call on its own uniform; the chain carries the
// distance and its gradient (the smin weights, exact for the quadratic form) so
// the lighting has a normal without dFdx. A bud whose bound is a whole merge
// radius behind the running distance is skipped: smin returns that distance
// exactly there.
// Pixel size for coverage comes from a LINEAR coordinate (dFdx of p.x), never
// from the composed distance (CLAUDE.md: a quad's difference of a smooth union
// re-rasterises when the item moves a pixel).
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 1) in vec4 fieldV;      // the blobs' field at the vertices: d, grad d, grad d . p (veil_gooey.vert)
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  size;         // the item, item px
    vec4  stone;        // the popup: x0 y0 x1 y1
    vec4  bar;          // the bar:   x0 y0 x1 y1
    float unit;         // size.y / 1620
    float presence;
    float pourFeather;  // the entrance front's soft edge, px at 1620 high
    float opaqueMode;
    float stoneR;
    float barR;
    float joinK;        // popup <-> bar fillet
    float smoothK;      // blob <-> blob merge radius
    float stoneBlend;   // blob <-> shell merge radius, as a fraction of smoothK
    float failTint;
    float budCount;     // buds drawn: the first budCount of bud0..bud15
    float budPad;       // how far from the shell's boxes a bud reaches, merge radius included (0 = none)
    vec4  light1;       // shadowW, shadowA, bevelW, bevelA
    vec4  light2;       // lightBias, pillow, shadowDrop
    vec4  ground1;      // alpha over the desktop, vignette, haloReach, haloStrength
    vec4  cMat;
    vec4  cBevel;
    vec4  cShadow;
    vec4  cGround;
    vec4  cEdge;
    vec4  cErr;
    vec4  b0;           // blobs: cx cy r stretch
    vec4  b1;
    vec4  b2;
    vec4  b3;
    vec4  b4;
    vec4  b5;
    vec4  b6;
    vec4  b7;
    vec4  b8;
    vec4  t0;           // blobs: cos, sin of the tilt
    vec4  t1;
    vec4  t2;
    vec4  t3;
    vec4  t4;
    vec4  t5;
    vec4  t6;
    vec4  t7;
    vec4  t8;
    vec4  bud0;         // cx cy r (r 0 = not drawn)
    vec4  bud1;
    vec4  bud2;
    vec4  bud3;
    vec4  bud4;
    vec4  bud5;
    vec4  bud6;
    vec4  bud7;
    vec4  bud8;
    vec4  bud9;
    vec4  bud10;
    vec4  bud11;
    vec4  bud12;
    vec4  bud13;
    vec4  bud14;
    vec4  bud15;
    vec4  sheen;        // DETAIL: the glint's direction (xy), strength, rim width in px at 1620 high (strength 0 = off)
    float shellInset;   // the shell's boxes drawn in by this many px: it joins the union out of nothing (VeilGooey `_attach`)
};

const vec2 LIGHT = vec2(-0.5145, -0.8575);   // toward the light, y down

// ---- the field: distance and outward gradient -------------------------------
void smn(inout float d, inout vec2 n, float e, vec2 ne, float k) {
    float h = max(k - abs(d - e), 0.0) / k;
    float wa = d < e ? 1.0 - 0.5 * h : 0.5 * h;
    n = mix(ne, n, wa);                      // a convex mix; normalised once, at the end
    d = min(d, e) - h * h * k * 0.25;
}

void rbox(vec2 p, vec4 r4, float r, out float d, out vec2 n) {
    vec2 c = 0.5 * (r4.xy + r4.zw);
    vec2 h = 0.5 * (r4.zw - r4.xy);
    vec2 pc = p - c;
    vec2 q = abs(pc) - h + r;
    d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    vec2 s = vec2(pc.x < 0.0 ? -1.0 : 1.0, pc.y < 0.0 ? -1.0 : 1.0);
    vec2 g = (q.x > 0.0 || q.y > 0.0) ? normalize(max(q, 0.0)) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
    n = g * s;
}

// A bud (a key's answer). One that is not drawn (r < 1) or whose edge is a whole merge
// radius beyond the running distance changes nothing there -- smn returns d and n
// exactly -- and is skipped before its sqrt is taken.
void circ(inout float d, inout vec2 n, vec2 p, vec4 bud, float k) {
    if (bud.z > 0.5) {
        vec2 q = p - bud.xy;
        float l2 = dot(q, q);
        // The bud's neck can be no wider than the bud: a smooth union of a vanishing circle with
        // the shell still swells the shell by k / 4, and dropping the circle (r < 0.5) would
        // snap that swelling away in one frame. With k <= 3 r the swelling goes to nothing with r.
        float kb = min(k, 3.0 * bud.z);
        float reach = bud.z + d + kb;
        if (reach > 0.0 && l2 < reach * reach) {
            float l = max(sqrt(l2), 1e-3);
            smn(d, n, l - bud.z, q / l, kb);
        }
    }
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    float px = max(length(vec2(dFdx(p.x), dFdy(p.x))), 1e-4);

    // ---- the field: the blobs from the vertex stage (veil_gooey.vert); the shell and the buds here ----
    // Each vertex carries d, grad d and C = grad d . p_v. The linear interpolant of d and the
    // barycentric blend of the vertices' first-order Taylor steps (A + G.p - C) are each off
    // by O(h^2) in opposite directions; their mean is exact for a quadratic field (O(h^3)).
    vec2 pr = p - 0.5 * size;
    float d = fieldV.x + 0.5 * (dot(fieldV.yz, pr) - fieldV.w);
    vec2 n = fieldV.yz;

    // The shell: popup and bar, one body with a small fillet between them.
    float kS = max(smoothK * stoneBlend, 0.5);
    // Far from the shell (and from every bud, which reach `budPad` out of it) the shell changes nothing: its distance is
    // at least the boxes' (a rounded corner only raises it, the fillet lowers it by at
    // most joinK / 4), and one a whole merge radius beyond the running distance leaves
    // smn's d and n exactly as they were. Beyond 110 u the material's shading has already
    // faded to the plain one (`away`), so the box distance does for that too.
    // (the boxes drawn in by shellInset, as the shell is below: with no shell the entrance pours out of their centre lines)
    vec2 qa = max(abs(p - 0.5 * (stone.xy + stone.zw)) - max(0.5 * (stone.zw - stone.xy) - shellInset, 0.0), 0.0);
    vec2 qb = max(abs(p - 0.5 * (bar.xy + bar.zw)) - max(0.5 * (bar.zw - bar.xy) - shellInset, 0.0), 0.0);
    float lbShell = sqrt(min(dot(qa, qa), dot(qb, qb)));
    float dShell = lbShell;
    float ds = 1e5; vec2 ns = vec2(0.0, 1.0);
    if (lbShell < budPad || lbShell - 0.25 * joinK < d + kS) {
        float db; vec2 nb;
        rbox(p, stone, stoneR, ds, ns);
        rbox(p, bar, barR, db, nb);
        ds += shellInset;
        db += shellInset;
        dShell = min(ds, db);
        smn(ds, ns, db, nb, max(joinK, 0.5));
        // Nested by the count: a flat run of guarded calls is flattened by the compiler.
        if (budCount > 0.5) {
            circ(ds, ns, p, bud0, kS);
            if (budCount > 1.5) {
                circ(ds, ns, p, bud1, kS);
                if (budCount > 2.5) {
                    circ(ds, ns, p, bud2, kS);
                    if (budCount > 3.5) {
                        circ(ds, ns, p, bud3, kS);
                        if (budCount > 4.5) {
                            circ(ds, ns, p, bud4, kS);
                            if (budCount > 5.5) {
                                circ(ds, ns, p, bud5, kS);
                                if (budCount > 6.5) {
                                    circ(ds, ns, p, bud6, kS);
                                    if (budCount > 7.5) {
                                        circ(ds, ns, p, bud7, kS);
                                        if (budCount > 8.5) {
                                            circ(ds, ns, p, bud8, kS);
                                            if (budCount > 9.5) {
                                                circ(ds, ns, p, bud9, kS);
                                                if (budCount > 10.5) {
                                                    circ(ds, ns, p, bud10, kS);
                                                    if (budCount > 11.5) {
                                                        circ(ds, ns, p, bud11, kS);
                                                        if (budCount > 12.5) {
                                                            circ(ds, ns, p, bud12, kS);
                                                            if (budCount > 13.5) {
                                                                circ(ds, ns, p, bud13, kS);
                                                                if (budCount > 14.5) {
                                                                    circ(ds, ns, p, bud14, kS);
                                                                    if (budCount > 15.5) {
                                                                        circ(ds, ns, p, bud15, kS);
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    if (ds < 1e4)
        smn(d, n, ds, ns, kS);
    n = normalize(n + vec2(1e-6));

    // ---- the ground: the desktop dimmed and tinted toward the material ----
    vec2 uv = p / size;
    float vg = smoothstep(0.30, 1.05, length((uv - 0.5) * vec2(1.35, 1.0) * 2.0));
    vec3 gcol = mix(cGround.rgb, cEdge.rgb, ground1.y * vg);
    float gA = mix(ground1.x, 1.0, opaqueMode);
    float halo = d < ground1.z * unit * 7.0 ? ground1.w * exp(-max(d, 0.0) / max(ground1.z * unit, 1.0)) : 0.0;
    gcol = mix(gcol, mix(cGround.rgb, cMat.rgb, 0.85), halo);
    gA = mix(gA, min(1.0, gA + 0.22), halo);
    gcol = mix(gcol, cErr.rgb, failTint * 0.10);
    vec4 pm = vec4(gcol * gA, gA);

    // ---- drop shadow (raised: it falls outside the edge, a little downward) ----
    float sw = light1.x * unit;
    float sd = d - n.y * light2.z * unit;
    float sh = sd < sw * 2.6 ? light1.y * exp(-max(sd, 0.0) / max(sw * 0.42, 1.0)) * (1.0 - smoothstep(sw * 1.2, sw * 2.6, sd)) : 0.0;
    pm = pm * (1.0 - sh) + vec4(cShadow.rgb * sh, sh);

    // ---- the material ----
    float cov = clamp(0.5 - d / px, 0.0, 1.0);
    if (cov > 0.0) {
        float away = smoothstep(0.0, 110.0 * unit, dShell);
        float bw = max(light1.z, 0.5);
        float depth = -d;
        float bev = 1.0 - smoothstep(0.0, bw, depth);
        float ndl = clamp(dot(n, LIGHT) * 0.5 + 0.5, 0.0, 1.0);
        float lit = mix(1.0, ndl, light2.x);
        vec3 col = cMat.rgb;
        col = mix(col, cBevel.rgb, light1.w * bev * bev * lit);
        // DETAIL, the sheen: a glint that slides round every blob's rim as the light turns slowly,
        // brightest where the surface faces it, gone a rim's width inside the edge, and not on the
        // shell (the popup is flat above). Behind a switch: strength 0 skips it.
        if (sheen.z > 0.0) {
            float facing = max(dot(n, sheen.xy), 0.0);
            float glint = facing * facing * facing * facing * exp(-depth / max(sheen.w * unit, 1.0));
            // toward white on a light material, toward the bevel's own tone on a dark one
            vec3 gl = mix(cBevel.rgb, vec3(1.0), smoothstep(0.5, 0.9, dot(cMat.rgb, vec3(0.3333))));
            col = mix(col, gl, sheen.z * glint * away);
        }
        float inner = 1.0 - smoothstep(0.0, 80.0 * unit, depth);
        // The shading fades toward the shell: the popup is drawn flat above, and the
        // material that meets it must be the same colour there.
        col = mix(col, cShadow.rgb, light2.y * inner * (1.0 - ndl) * away);
        col = mix(col, cErr.rgb, failTint * 0.5 * away);
        pm = pm * (1.0 - cov) + vec4(col, 1.0) * cov;
    }
    // ---- the entrance: a front pours out of the shell; behind it the veil is whole, ahead of
    // it the desktop is untouched. A point goes from one to the other across the feather, and
    // the material's own colour rides the front as a band. At boot (opaqueMode) there is no
    // desktop to pour over: the ground is whole from the first frame and only the blobs swell in
    // (VeilGooey). ----
    if (presence < 0.9999 && opaqueMode < 0.5) {
        float fe = max(pourFeather * unit, 1.0);
        float fr = presence * (length(size) + fe);
        float rv = 1.0 - smoothstep(fr - fe, fr, lbShell);
        float band = exp(-pow((lbShell - fr + 0.5 * fe) / (0.3 * fe), 2.0)) * (1.0 - opaqueMode * 0.5);
        pm = mix(pm, vec4(cMat.rgb, 1.0), 0.55 * band * rv);
        pm *= rv;
    }
    fragColor = pm * qt_Opacity;
}
