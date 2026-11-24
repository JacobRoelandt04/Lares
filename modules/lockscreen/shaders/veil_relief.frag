#version 440

// =============================================================================
// veil_relief.frag -- the lock veil "Sunlit relief": the surface itself as a
// low carved landscape of dune ridges, lit by a directional light.
//
// One analytic heightfield (no textures, no loops over octaves):
//   * dunes: an asymmetric cross-section in a warped phase (a long gentle
//     windward slope, a short steep slip face, a crisp crest between), the
//     crest lines wandering (warp noise) and swelling and fading (an
//     amplitude envelope noise);
//   * wind ripples across the wind, ~16 px, on the gentle faces only.
// The gradient is analytic (value noise with derivatives, chain rule), so the
// shading costs no extra height taps. Cast shadows are three soft taps of the
// dune layer along the light.
//
// THE MATERIAL. Shading is the shell's own: shadow = the surface toward
// shadowDeep, light = toward the bevel colour, laid as translucent layers over
// whatever is beneath (the held desktop) on a tint of the surface colour. At
// boot the tint is opaque. Presence raises the terrain out of flat, outward
// from `origin`; the tint deepens with it.
//
// THE SMOOTH HALF IS NOT HERE. The two noises that bend and swell the dune
// lines and every pulse are smooth over hundreds of px, so veil_relief.vert
// evaluates them at the vertices of a coarse grid and this shader reconstructs
// them between (see there for the pulses and their weights).
//
// Everything is a function of (pixel, time, uniforms): a resting host renders
// nothing. Feathering is inward only; the pixel size is not needed here (the
// field is smooth) but the output is dithered by 1/255 against banding.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 1) in vec4 vA;     // n1.value, n2.value, pulse height px, error tint
layout(location = 2) in vec4 vC;     // G.p of the first three, -
layout(location = 3) in vec4 vG1;    // grad n1, grad n2 (per px)
layout(location = 4) in vec4 vGp;    // pulse gradient
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    vec2  size;         // item px
    float time;         // veil seconds
    float presence;
    float opaque;       // 1 = boot
    vec2  origin;       // where the rise starts, item px

    vec4  terrain;      // amplitude px, wavelength px, wind angle rad, drift px/s
    vec4  detail;       // ripple amplitude px, warp turns, envelope depth, crest position 0..1
    vec4  rip;          // ripple wavelength px, slope where ripples fade, crest rim strength, -
    vec4  light;        // unit vector toward the light (x right, y down, z up), power
    vec4  sky;          // night 0..1, warmth 0..1, cstv-shadow strength, contrast gain
    vec4  grade;        // tint alpha over the desktop, shadow alpha, light alpha, vignette
    vec4  grade2;       // breath (tint follows height), dark 0/1, lift, sand grain 0..1

    vec4  cSurface;
    vec4  cShadow;
    vec4  cBevel;
    vec4  cNight;
    vec4  cWarm;
    vec4  cError;

    vec4  po;           // -, -, pulses alive (the vertex stage's), -

    // What the CPU knows once, so no pixel (no SIMD thread) computes it: the
    // transcendentals and divisions of uniforms cost a slot per thread as well.
    vec4  geoA;         // wind direction x, y, 1 / wavelength, 1 / ripple wavelength
    vec4  geoB;         // toward-the-light direction x, y (unit), tan(elevation), light phase per px
    vec4  geoC;         // 1 / crest position, 1 / (1 - crest position), sun glints 0..1, 1 / max(amplitude, 1)
    vec4  geoD;         // the entrance's front: radius px from the popup's edge, 1 / front width px, popup half extents x, y

    // the pulses (read by the vertex stage only): kinds key / fail / wake and their
    // 32 slots, vec4(x, y, age s, kind + 0.9 * (1 - weight))
    vec4  pk;           // key:  amplitude px, speed px/s, sigma px, life s
    vec4  pf;           // fail
    vec4  pw;           // wake: amplitude px, speed px/s, sigma px, life s
    vec4  p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5;
    vec4  p6; vec4 p7; vec4 p8; vec4 p9; vec4 p10; vec4 p11;
    vec4  p12; vec4 p13; vec4 p14; vec4 p15; vec4 p16; vec4 p17;
    vec4  p18; vec4 p19; vec4 p20; vec4 p21; vec4 p22; vec4 p23;
    vec4  p24; vec4 p25; vec4 p26; vec4 p27; vec4 p28; vec4 p29;
    vec4  p30; vec4 p31;
};


const float TAU = 6.2831853;

// The crest lines travel with the wind (the noises that bend and swell them
// slide across it, in the field pass), so the terrain morphs as it moves.
vec2 gPh;

// The dune's cross-section over one wavelength (s in 0..1, crest at c): a long
// gentle windward slope that meets a short steep slip face at a sharp crest.
float prof(float s, float c) {
    // one pow, the face chosen first (both would be evaluated side by side)
    bool g = s < c;
    float x = g ? s * geoC.x : (1.0 - s) * geoC.y;
    return pow(x, g ? 1.35 : 1.15);
}
// The same with its slope, the two faces joined over `w` (one pixel's worth of
// phase) so the crest is a crisp line and not a stair of aliased pixels. One pow
// serves both (x^1.35 = x * x^0.35, and the slope is that x^0.35); the other
// face is only computed inside the join.
float profd(float s, float c, float w, out float d) {
    bool g = s < c;
    float x = g ? s * geoC.x : (1.0 - s) * geoC.y;
    float t = pow(x, g ? 0.35 : 0.15);
    float v = x * t;
    d = g ? 1.35 * geoC.x * t : -1.15 * geoC.y * t;
    if (abs(s - c) <= w) {
        float xo = g ? (1.0 - s) * geoC.y : s * geoC.x;
        float to = pow(xo, g ? 0.15 : 0.35);
        float dw = g ? d : 1.35 * geoC.x * to;
        float ds = g ? -1.15 * geoC.y * to : d;
        d = mix(dw, ds, smoothstep(c - w, c + w, s));
    }
    return v;
}

vec4 over(vec4 acc, vec3 c, float a) {
    return vec4(c * a + acc.rgb * (1.0 - a), a + acc.a * (1.0 - a));
}

// A hash of a pixel / cell coordinate without a sine of a big argument (see lock_kawase_up.frag: `fract(sin(dot(p, ...)))` at 2880 x 1620 is a lattice of
// diagonal stripes on a GPU). Only fract() and a dot product.
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    vec2 wd = geoA.xy;
    gPh = wd * time * terrain.w;

    // ---- the rise: outward from the origin ---------------------------------
    // THE ENTRANCE: a front of sand sweeping out from the popup's edge. A point is flat
    // ground ahead of it and the finished dune behind it, and goes from one to the other
    // within the front's width (geoD.y): no faint phase, no uniform fade of the picture.
    float pr = clamp((geoD.x - length(max(abs(p - origin) - geoD.zw, 0.0))) * geoD.y, 0.0, 1.0);
    pr = pr * pr * (3.0 - 2.0 * pr);
    // the dune heaps up as the front passes and settles (0 at rest, so the finished picture is unchanged)
    float prH = pr + 0.3 * sin(3.14159265 * pr);

    // ---- the smooth fields, from the vertices (see veil_relief.vert): ----------
    // f = A + 0.5 (G . p - C), p from the item's centre like the vertex's
    vec2 pc = p - 0.5 * size;
    float n1x = vA.x + 0.5 * (dot(vG1.xy, pc) - vC.x);
    float n2x = vA.y + 0.5 * (dot(vG1.zw, pc) - vC.y);
    vec2 g1 = vG1.xy;
    vec2 g2 = vG1.zw;
    float hp = vA.z + 0.5 * (dot(vGp.xy, pc) - vC.z);
    vec2 gp = vGp.xy;
    float err = vA.w;

    // ---- terrain: dunes with a crisp crest, and the wind ripples on them -----
    float cc = detail.w;
    vec2 gph = wd * geoA.z + detail.y * g1;
    float ph = dot(p - gPh, wd) * geoA.z + detail.y * (n1x - 0.5);
    float fw = max(length(vec2(dFdx(ph), dFdy(ph))), 1e-6);
    float sfr = fract(ph);
    float A = mix(1.0 - detail.z, 1.0, n2x);
    vec2 gA = detail.z * g2;
    float dpr;
    float pf_ = profd(sfr, cc, fw, dpr);
    float amp = terrain.x * prH;
    float ht = A * pf_;
    vec2 gt = A * dpr * gph + pf_ * gA;
    float hD = amp * ht;
    vec2 gD = amp * gt;

    // wind ripples: small crests across the wind, only where the dune is gentle
    float steep = length(gD);
    float rfade = 1.0 - smoothstep(rip.y * 0.5, rip.y, steep);
    float rp = dot(p - gPh * 1.3, wd) * geoA.w + 2.5 * (n1x - 0.5);
    vec2 grp = wd * geoA.w + 2.5 * g1;
    float rfw = length(vec2(dFdx(rp), dFdy(rp)));
    rfade *= 1.0 - smoothstep(0.25, 0.5, rfw);
    // the second harmonic from the first by the double-angle identities -- only where there are ripples to
    // draw (a pixel on a steep face, or with ripples too fine to resolve, has none: sin, cos and their
    // algebra cost 0.5 ms of a frame, and a term that is multiplied by 0 adds 0)
    float ra = detail.x * pr * rfade;
    float rs = 0.0;
    float rd = 0.0;
    if (ra > 0.0) {
        float sn = sin(TAU * rp);
        float cs = cos(TAU * rp);
        float s2 = 2.0 * sn * cs;
        float c2 = 1.0 - 2.0 * sn * sn;
        rs = sn + 0.3 * (s2 * 0.6967067 + c2 * 0.7173561);
        rd = cs + 0.6 * (c2 * 0.6967067 - s2 * 0.7173561);
    }
    float h = hD + ra * rs + hp * pr;
    vec2 g = gD + ra * rd * TAU * grp + gp * pr;

    // ---- light ----------------------------------------------------------------
    vec3 L = light.xyz;
    vec2 Ld = geoB.xy;
    vec3 n = normalize(vec3(-g, 1.0));
    float s = (dot(n, L) - L.z) * sky.w * light.w;

    // cast shadows: soft taps along the light. The dunes are nearly one-
    // dimensional (a function of the phase), so a tap is the same cross-section
    // further along the phase, with this pixel's envelope -- no noise reads.
    float cstv = 0.0;
    if (sky.z > 0.001 && amp > 0.5) {
        float tanEl = geoB.z;
        float dph = geoB.w;
        float h0 = amp * A * pf_;
        float aA = amp * A;
        for (int i = 1; i <= 5; i++) {
            float dist = 60.0 * float(i) * float(i) * 0.6;
            // a tap can only shadow while the light's rise over that distance is
            // below the tallest the dune gets here (hs <= aA); past that it adds 0
            if (dist * tanEl >= aA)
                break;                                  // the taps lie farther and farther out: none that follows can shadow
            float hs = aA * prof(fract(ph + dph * dist), cc);
            float occ = (hs - (h0 + dist * tanEl)) / (10.0 + dist * 0.08);
            cstv = max(cstv, occ);
        }
        cstv = smoothstep(0.0, 1.0, cstv) * sky.z * light.w;
    }

    // shading eases in (no flat saturated bands); the slip face lightens toward
    // its foot, where the ground beside it fills the shadow
    float ex = 1.0 - exp(-2.2 * abs(s));
    float sh = clamp((s < 0.0 ? ex : 0.0) + cstv * 0.7, 0.0, 1.0);
    sh *= 1.0 - 0.45 * smoothstep(cc, 1.0, sfr) * (1.0 - cstv);
    // ambient: the troughs sit darker than the crests, so the gentle faces read as relief too
    sh = max(sh, 0.3 * (1.0 - pf_ * A) * pr);
    float hi = s > 0.0 ? ex : 0.0;

    // the crest line: a thin bright edge where the two faces meet
    float dpx = abs(sfr - cc) / fw;
    float rim = (1.0 - smoothstep(0.6, 2.4, dpx)) * smoothstep(0.02, 0.2, amp * geoC.w);
    rim *= (0.45 + 0.55 * smoothstep(-0.3, 0.5, dot(Ld, -wd))) * (1.0 - 0.7 * sh * (1.0 - hi));

    // ---- colour -------------------------------------------------------------------------
    float night = sky.x;
    float dark = grade2.y;
    vec3 base = cSurface.rgb;
    base = mix(base, cShadow.rgb, night * (dark > 0.5 ? 0.0 : 0.16));
    float vig = smoothstep(0.55, 1.25, length((qt_TexCoord0 - 0.5) * vec2(1.15, 1.6) * 2.0)) * grade.w;
    base = mix(base, cShadow.rgb, vig * 0.6);

    float hn = clamp(h * geoC.w, -1.0, 1.0);
    float tint = opaque > 0.5 ? 1.0 : clamp(grade.x * (1.0 + grade2.x * hn) * pr, 0.0, 1.0);
    tint = clamp(tint + vig * 0.3 * pr * (1.0 - opaque), 0.0, 1.0);

    vec3 shc = mix(cShadow.rgb, cNight.rgb * 0.5, night * (dark > 0.5 ? 0.22 : 0.30));
    shc = mix(shc, cError.rgb, clamp(err * 1.4, 0.0, 1.0) * 0.6);
    float shA = grade.y * sh;
    shA = clamp(shA + err * 0.42 * (1.0 - hi), 0.0, 1.0);

    vec3 hic = mix(cBevel.rgb, cWarm.rgb, sky.y * 0.2);
    hic = mix(hic, cNight.rgb, night * (dark > 0.5 ? 0.55 : 0.35));
    float hiA = grade.z * hi * (1.0 - 0.6 * err);
    hiA = max(hiA, rip.z * rim * (1.0 - 0.6 * err));

    // DETAIL, behind a switch each: sun glints on the lit faces (sparse points that twinkle
    // slowly, 3 px cells, only where the light lies on the slope), and the grain of the sand
    // (a static per-pixel tooth in the shading, so the terrain drifts under it)
    float grainN = 0.0;
    if (grade2.w > 0.0)
        grainN = hash21(floor(gl_FragCoord.xy)) - 0.5;
    if (geoC.z > 0.0 && hi > 0.01) {
        vec2 gcell = floor(p / 3.0);
        float gh = hash21(gcell);
        if (gh > 0.985) {
            float tw = 0.5 + 0.5 * sin(time * 1.3 + gh * 400.0);
            vec2 gd = p - (gcell + 0.5) * 3.0;
            float spot = 1.0 - smoothstep(0.3, 1.6, length(gd));
            hiA = max(hiA, geoC.z * smoothstep(0.01, 0.2, hi) * tw * spot * 0.9);
        }
    }
    shA *= 1.0 + grade2.w * 0.3 * grainN;
    hiA *= 1.0 + grade2.w * 0.2 * grainN;

    vec4 acc = vec4(base * tint, tint);
    acc = over(acc, shc, shA);
    acc = over(acc, hic, hiA);

    // dither
    // dither against banding: interleaved gradient noise (no transcendental)
    float dn = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) - 0.5;
    acc.rgb += dn * acc.a / 255.0;

    fragColor = acc * qt_Opacity;
}
