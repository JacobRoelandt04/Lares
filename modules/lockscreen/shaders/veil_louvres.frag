#version 440

// =============================================================================
// veil_louvres.frag -- the lock veil "Louvres": the surface as rows of horizontal slats, like
// a kinetic facade or a venetian blind. A slow wave turns them so the light rolls across the
// screen in bands.
//
// ONE SHADER, NO ITEMS, in DEVICE pixels. The row is floor(pixel y / pitch) with an even
// integer pitch, so every slat's centre line lies on a whole pixel. A slat is a flat plate
// of the material turned about its long axis by an angle that varies ALONG it (the wave) and
// from row to row; seen from the front its extent is `fill * pitch * cos(angle)`, centred in
// its row, and the rest of the row is the gap between the slats: the carved ground.
//
// LIT BY THE SHELL'S LIGHT (above, a little to the left). The plate's normal is
// (0, -sin a, cos a); n . L against the face-on value says how much brighter or darker than
// the surface it is: tipped toward the light a slat takes the bevel's highlight, tipped away
// it sinks toward the border and the deep shadow. The slat is a little convex (`curv`), so
// its upper part is brighter than its lower; its top edge carries the raised material's
// inner highlight, its bottom edge a faint inner shade; the slat casts a drop shadow DOWN into
// the gap beneath it (the next slat's shade), falling off over `shadowWidth`.
//
// The slat's edges are feathered INWARD only (clamp(d / px, 0, 1)), the pixel size taken
// from a LINEAR coordinate (pd.y), never from a composed distance.
//
// THE ENTRANCE. `presence` is a front travelling out from `origin` (the popup's field): a
// slat the front has not reached lies edge-on -- an invisible line, nothing drawn, the
// desktop (or at boot the bare ground) untouched -- and as the front passes it turns, with a
// little overshoot, to the angle the wave has given it. A point goes from nothing to the
// finished slat in about a tenth of the entrance: no faint phase, no cross-fade.
//
// OVER THE DESKTOP the slats are a translucent tint of the surface (the blurred desktop
// glows through), the gaps a translucent tint of the floor; at boot both are opaque.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 1) in vec4 vA;     // w, kadd, fl, ok at the vertex
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
    vec2  origin;       // where the entrance starts, item px

    vec4  grid;         // pitch (device px, even), slat fill, curvature (rad across a slat), shadow width (device px)
    vec4  wave;         // k (rad / item px), omega (rad / s), tilt (rad), plane wave angle
    vec4  srcA;         // radial source xy, stagger (rad), the farthest corner from the popup rect (item px)
    vec4  light;        // toward-light x, y (unit), sin elevation, cos elevation
    vec4  grade;        // slat alpha over the desktop, gap alpha, shadow gain, bevel gain
    vec4  grade2;       // dark 0/1, bevel width (device px), rise spread, ok angle (rad)
    vec4  flut;         // flutter amplitude (rad), flutter omega, flutter phase per item px, entrance overshoot
    vec4  rect;         // the popup: centre xy, half extent xy (item px); the entrance's front leaves its outline
    vec4  detail;       // edge glint gain, gloss gain, -, -

    vec4  cSlat;
    vec4  cFloor;
    vec4  cMid;
    vec4  cShadow;
    vec4  cBevel;
    vec4  cError;

    vec4  pk;           // key:  amplitude (rad), speed px/s, sigma px, life s
    vec4  pf;           // fail: -, speed, sigma, life
    vec4  po;           // ok:   strength 0..1, front speed, pulses alive, the clear's progress 0..1
    vec4  pw;           // wake: amplitude (rad), speed, sigma, life
    // GEN slots BEGIN
    vec4 p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5;
    vec4 p6; vec4 p7; vec4 p8; vec4 p9; vec4 p10; vec4 p11;
    vec4 p12; vec4 p13; vec4 p14; vec4 p15; vec4 p16; vec4 p17;
    vec4 p18; vec4 p19; vec4 p20; vec4 p21; vec4 p22; vec4 p23;
    vec4 p24; vec4 p25; vec4 p26; vec4 p27; vec4 p28; vec4 p29;
    vec4 p30; vec4 p31;
    // GEN slots END
};

vec4 over(vec4 acc, vec3 c, float a) {
    return vec4(c * a + acc.rgb * (1.0 - a), a + acc.a * (1.0 - a));
}

void main() {
    // ---- the row, in device pixels ---------------------------------------------------
    vec2 pd = qt_TexCoord0 * size * dscale;
    float P = grid.x;
    float row = floor(pd.y / P);
    float q = pd.y - (row + 0.5) * P;                 // from the slat's centre line, device px
    float px = max(length(vec2(dFdx(pd.y), dFdy(pd.y))), 1e-3);   // before any branch: derivatives
    float ycItem = (row + 0.5) * P / dscale;

    // ---- the entrance: a front leaving the popup's outline -----------------------------------------
    // `presence` here is already LINEAR time (veil_louvres QML undoes the lock's OutCubic, or the
    // front would cross the screen in the first tenth); `srcA.w` is the farthest corner's distance
    float pr = 1.0;
    float ent = 1.0;
    vec2 cc = vec2(qt_TexCoord0.x * size.x, ycItem);
    if (presence < 1.0) {
        float S = grade2.z;
        float rn = length(max(abs(cc - rect.xy) - rect.zw, 0.0)) / max(srcA.w, 1.0);   // from the popup's outline
        pr = clamp(presence * (1.0 + S) - S * rn, 0.0, 1.0);
        float xx = pr - 1.0;
        ent = pr >= 1.0 ? 1.0 : 1.0 + (flut.w + 1.0) * xx * xx * xx + flut.w * xx * xx;
    }

    // ---- the clear: the slats turn edge-on again, from the bottom row up to the top one (the bar) ----------
    // Each row has its own stretch of the clear's progress (po.w): the bottom row starts at once, the top one
    // ends with it, and a row takes 0.4 of it to turn from where the wave and the ok had put it to edge-on,
    // its gap fading with it. The popup went up into the bar, and the blind follows it.
    float cl = 0.0;
    if (po.w > 0.0) {
        float rf = 1.0 - ycItem / size.y;
        cl = clamp((po.w - 0.6 * rf) / 0.4, 0.0, 1.0);
        cl = cl * cl * (3.0 - 2.0 * cl);
        pr = min(pr, 1.0 - cl);
    }

    // ---- this slat's angle ----------------------------------------------------------------
    vec4 f = vA + vGy * (ycItem - qt_TexCoord0.y * size.y);
    float ok = clamp(f.w, 0.0, 1.0);
    float fl = clamp(f.z, 0.0, 1.0);
    float th = (wave.z * f.x + f.y) * (1.0 - ok) + ok * grade2.w;
    // the fail's flutter: each slat on its own phase (golden-ratio spread), the wave running along it
    th += srcA.z * sin(0.6 * time + 0.9 * row);          // each slat a little out of step with its neighbour
    if (fl > 0.002)
        th += flut.x * fl * sin(flut.y * time + 6.2831853 * fract(row * 0.61803399) + flut.z * cc.x);
    th *= inversesqrt(1.0 + th * th * 0.4756);          // a smooth limit at 1.45 rad
    if (ent < 1.0)
        th = mix(1.5707963, th, ent);                   // edge-on until the front reaches it
    th = mix(th, 1.5707963, cl);                        // and edge-on again once the clear has been by
    float c = cos(th);
    float s = sin(th);

    // ---- the slat's extent --------------------------------------------------------------------
    float H = 0.5 * grid.y * P * abs(c);
    float d = H - abs(q);                              // px inward of the slat's edge
    float cover = clamp(d / px, 0.0, 1.0) * smoothstep(0.0, 0.35, H);

    float tintA = opaque > 0.5 ? 1.0 : grade.x;
    float gapA = opaque > 0.5 ? 1.0 : grade.y * smoothstep(0.0, 0.2, pr);
    float bw = grade2.y;

    // ---- the gap: the carved ground, shadowed by the slat above it ---------------------------
    // distance below the nearest slat edge above, along the gap (the two halves of it, wrapped)
    vec4 accG = vec4(0.0);
    if (cover < 1.0) {
    float qq = q >= -H ? q : q + P;
    float gb = max(qq - H, 0.0);
    float sw = max(grid.w * (0.45 + 0.55 * abs(c)), 1.0);
    float fall = 1.0 - clamp(gb / sw, 0.0, 1.0);
    fall *= fall;
    float open = smoothstep(0.0, 0.3, abs(c));
    vec3 gcol = mix(cFloor.rgb, cMid.rgb, 0.45);
    accG = vec4(gcol * gapA, gapA);
    accG = over(accG, cShadow.rgb, clamp(fall * grade.z * open, 0.0, 1.0) * max(gapA, 0.0));
    }

    vec4 acc = accG;
    if (cover > 0.0) {
        // ---- the slat: convex, lit by n . L -------------------------------------------------------
        float v = clamp(q / max(H, 1e-3), -1.0, 1.0);      // -1 top edge .. +1 bottom edge
        float a = -grid.z * v;                              // the normal tips up toward the top edge
        float cs = c - s * a;
        float sn = s + c * a;
        float nl = 0.8575 * light.z * sn + light.w * cs;    // n . L  (L = (.., -.8575 se, ce), n = (-sin, cos))
        float t = nl - light.w;                             // 0: as bright as face-on
        float lit = clamp(t * 2.2, 0.0, 1.0);
        float dim = clamp(-t * 1.6, 0.0, 1.0);
        vec3 body = cSlat.rgb;
        body = mix(body, cBevel.rgb, lit * (0.55 + 0.6 * grade2.x) * grade.w);
        body = mix(body, cMid.rgb, dim * (1.0 - 0.35 * grade2.x));
        body = mix(body, cShadow.rgb, clamp(dim * 1.4 - 0.55, 0.0, 1.0) * 0.6);
        body = mix(body, cError.rgb, fl * 0.5);
        vec4 accS = vec4(body * tintA, tintA);
        // the raised material's inner highlight along the top edge, a faint shade along the bottom
        float topD = q + H;
        float botD = H - q;
        float hl = (1.0 - smoothstep(0.0, bw, topD)) * (0.55 + 0.45 * (1.0 - dim));
        accS = over(accS, cBevel.rgb, hl * grade.w * tintA);
        // DETAIL, edge glint: a thin bright lip on the top edge that catches the light as the slat tips
        // toward it
        if (detail.x > 0.0) {
            float lip = (1.0 - smoothstep(0.0, 2.4 * dscale, topD)) * smoothstep(-0.3, 0.5, s);
            accS = over(accS, cBevel.rgb, clamp(lip * detail.x, 0.0, 1.0) * tintA);
        }
        // DETAIL, gloss: the soft streak of the light's mirror image running across the convex slat;
        // as the slat turns it slides from one edge to the other
        if (detail.y > 0.0) {
            float x = (th + a - 0.5 * asin(light.z)) / 0.17;
            accS = over(accS, cBevel.rgb, clamp(exp(-x * x) * 0.5 * detail.y, 0.0, 1.0) * tintA);
        }
        float sd = (1.0 - smoothstep(0.0, bw * 2.0, botD)) * 0.35;
        accS = over(accS, cMid.rgb, sd * tintA);
        acc = mix(accG, accS, cover);
    }

    // dither against banding: interleaved gradient noise (no transcendental)
    float dn = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) - 0.5;
    acc.rgb += dn * acc.a / 255.0;
    fragColor = acc * qt_Opacity;
}
