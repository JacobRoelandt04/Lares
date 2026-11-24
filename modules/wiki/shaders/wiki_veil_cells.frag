#version 440
#extension GL_GOOGLE_include_directive : enable

// =============================================================================
// wiki_veil_cells.frag -- wiki veil "Cells": the floor cut into plateaus by
// seams, like dried clay, a leaf under the lens or a pavement of cut stones. One
// point per square of a grid (jittered, drifting on its own slow orbit); a
// pixel belongs to the nearest point and stands at a height that falls over a
// rounded shoulder to the seam it shares with the next nearest. Each plateau
// leans a little its own way (`p1.z`), so the stones catch the light apart.
//
// The seam's distance is exact (the distance to the bisector between the two
// points, the second pass looking round the nearest point's own square), so a
// seam is the same width all along and the shoulders mitre at a corner.
//
//   p0   square px, shoulder px, half seam px, plateau height px
//   p1   speed, drift (of a square), lean, -
// =============================================================================

#include "wiki_veil.glsl"

vec2 point(vec2 c, vec2 off, float t) {
    vec2 h = hash22(c + off);
    float h2 = hash21(c * 1.31 + off + 17.0);
    float w = 0.12 + 0.14 * h2;
    return 0.5 + 0.2 * (h * 2.0 - 1.0) + p1.y * vec2(sin(TAU * h.x + w * t), cos(TAU * h.y + 0.83 * w * t));
}

void main() {
    float S = p0.x;
    vec2 x = veilCoord() / S;
    vec2 off = floor(seed.xy * 97.0);
    float t = time * p1.x;
    vec2 n = floor(x);
    vec2 f = x - n;

    vec2 mg = vec2(0.0);
    vec2 mr = vec2(0.0);
    float md = 64.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 g = vec2(float(i), float(j));
            vec2 r = g + point(n + g, off, t) - f;
            float d = dot(r, r);
            if (d < md) {
                md = d;
                mr = r;
                mg = g;
            }
        }
    }
    md = 64.0;
    vec2 en = vec2(1.0, 0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 g = mg + vec2(float(i), float(j));
            vec2 r = g + point(n + g, off, t) - f;
            vec2 dr = r - mr;
            float l2 = dot(dr, dr);
            if (l2 > 1e-5) {
                vec2 e = dr / sqrt(l2);
                float d = dot(0.5 * (mr + r), e);
                if (d < md) {
                    md = d;
                    en = e;
                }
            }
        }
    }

    float u = clamp((md * S - p0.z) / p0.y, 0.0, 1.0);
    float top = u * u * (3.0 - 2.0 * u);
    vec2 lean = p1.z * (hash22((n + mg) * 2.17 + off + 5.0) * 2.0 - 1.0);
    // the height falls toward the seam: its gradient points away from it
    vec2 slope = -p0.w * 6.0 * u * (1.0 - u) / p0.y * en + lean * top;
    // a seam is wide: its even shade at a groove's strength would rule the picture
    fragColor = veilShade(0.6 * (1.0 - top), slope);
}
