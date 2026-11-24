#version 440
#extension GL_GOOGLE_include_directive : enable

// =============================================================================
// wiki_veil_contours.frag -- wiki veil "Contours": the map of a country that is
// not there. A slow terrain (four plane waves over a warped ground, all from the
// article's seed) is drawn the way a survey sheet draws one: engraved contour
// lines, every `p1.w`-th one heavier, over a faint hill shading.
//
// The terrain and its gradient are ANALYTIC (the warp's Jacobian by the chain
// rule), so a line's distance is (T - level) / |grad T| with no screen
// derivative in it: nothing re-rasters when the picture slides. Where the
// terrain is flat that distance means nothing (a summit, a saddle: a line there
// would be a blot that pops in and out), so lines DISSOLVE as the slope goes.
//
//   p0   wavelength px, line spacing px, line half-width px, line depth px
//   p1   speed, warp px, hill shading, heavier line every n
// =============================================================================

#include "wiki_veil.glsl"

void main() {
    vec2 P = veilCoord() + (seed.xy - 0.5) * 3000.0;
    float k0 = TAU / p0.x;
    float t = time * p1.x;

    // the warped ground W(P) and its Jacobian's rows
    vec2 a = k0 * 0.55 * vec2(cos(TAU * seed.z), sin(TAU * seed.z));
    vec2 b = k0 * 0.47 * vec2(cos(TAU * seed.w + 1.3), sin(TAU * seed.w + 1.3));
    float sa = dot(a, P) + 0.031 * t + 1.7;
    float sb = dot(b, P) - 0.027 * t;
    vec2 W = P + p1.y * vec2(sin(sa), sin(sb));
    vec2 dWx = vec2(1.0, 0.0) + p1.y * cos(sa) * a;
    vec2 dWy = vec2(0.0, 1.0) + p1.y * cos(sb) * b;

    // the terrain: each wave's amplitude is 1 / its frequency, so each carries the same slope
    float T = 0.0;
    vec2 gW = vec2(0.0);
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float m = 0.62 * pow(1.37, fi);
        float ang = TAU * fract(seed.x + fi * 0.381966 + seed.y * fi * 0.17);
        vec2 k = k0 * m * vec2(cos(ang), sin(ang));
        float w = (0.05 + 0.02 * fi) * (mod(fi, 2.0) < 0.5 ? 1.0 : -1.0);
        float ph = dot(k, W) + TAU * hash11(seed.z * 91.0 + fi * 7.3) + w * t;
        T += sin(ph) / m;
        gW += cos(ph) / m * k;
    }
    vec2 g = gW.x * dWx + gW.y * dWy;
    float gn = k0 * 1.41421;                    // the slope's rms
    float gl = max(length(g), 1e-5);

    float lvl = p0.y * gn;                      // the height between two lines
    float f = T / lvl;
    float n = floor(f + 0.5);
    float d = (f - n) * lvl / gl;               // px to the nearest line, + uphill
    float heavy = 1.0 - step(0.5, mod(n, p1.w));
    float flatness = smoothstep(0.22, 0.6, gl / gn);
    vec2 gr = veilGroove(d, p0.z * (1.0 + 0.45 * heavy), p0.w * (1.0 + 0.35 * heavy)) * flatness;

    fragColor = veilShade(gr.x, gr.y * g / gl + p1.z * g / gn);
}
