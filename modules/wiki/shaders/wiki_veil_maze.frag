#version 440
#extension GL_GOOGLE_include_directive : enable

// =============================================================================
// wiki_veil_maze.frag -- wiki veil "Maze": the one-line maze (a diagonal wall in
// every square, this way or that), engraved, with walls that swing. Every wall
// is a stick through its square's centre whose ends stay ON the square's edge;
// now and then one turns a quarter, its ends sliding from two corners to the
// other two, and a passage closes as another opens.
//
// Each wall has its own period and phase (a hash of its square), so the turns
// are spread: about (squares in view) / `p1.y` of them a second, `p0.w` seconds
// each. The nearest of the nine sticks round a pixel decides it, so walls that
// meet at a corner join with round ends.
//
//   p0   square px, wall half-width px, wall depth px, swing seconds
//   p1   speed, mean seconds between one wall's turns, -, -
// =============================================================================

#include "wiki_veil.glsl"

void main() {
    float S = p0.x;
    vec2 P = veilCoord();
    vec2 off = floor(seed.xy * 97.0);
    vec2 c0 = floor(P / S);
    float t = time * p1.x;

    float best = 1e9;
    vec2 bv = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 c = c0 + vec2(float(i), float(j));
            vec2 h = hash22(c + off);
            float h3 = hash21(c * 1.37 + off + 11.0);
            float cyc = p1.y * (0.6 + 0.8 * h.y);
            float x = t / cyc + h.x * 9.0;
            float u = clamp(fract(x) * cyc / p0.w, 0.0, 1.0);
            float e = u * u * (3.0 - 2.0 * u);
            float sgn = h3 < 0.5 ? 1.0 : -1.0;
            float ang = 0.785398 + 1.570796 * (floor(h3 * 4.0) + sgn * (floor(x) + e));
            vec2 dir = vec2(cos(ang), sin(ang));
            float L = 0.5 * S / max(abs(dir.x), abs(dir.y));
            vec2 q = P - (c + 0.5) * S;
            vec2 v = q - dir * clamp(dot(q, dir), -L, L);
            float dd = dot(v, v);
            if (dd < best) {
                best = dd;
                bv = v;
            }
        }
    }
    float d = sqrt(best);
    vec2 gr = veilGroove(d, p0.y, p0.z);
    fragColor = veilShade(gr.x, gr.y * bv / max(d, 1e-4));
}
