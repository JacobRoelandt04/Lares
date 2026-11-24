#version 440
#extension GL_GOOGLE_include_directive : enable

// =============================================================================
// wiki_veil_links.frag -- wiki veil "Links": what a wiki is made of. One node
// per square of a grid, each wandering round its own place, some joined to the
// node on their right and the one below by an engraved line. A line that is
// stretched as two nodes drift apart thins and lets go; it comes back as they
// close again, so the graph is never the same twice and never jumps.
//
// A node is a small round well; a line is a groove between two centres. The
// nine squares round a pixel hold every node and line that can reach it (a node
// keeps inside its own square).
//
//   p0   square px, line half-width px, node radius px, depth px
//   p1   speed, wander (of a square, < 0.3), share of joined pairs, -
// =============================================================================

#include "wiki_veil.glsl"

vec2 node(vec2 c, vec2 off, float t) {
    vec2 h = hash22(c + off);
    float h2 = hash21(c * 1.31 + off + 17.0);
    float w = 0.10 + 0.12 * h2;
    return (c + 0.5 + p1.y * vec2(sin(TAU * h.x + w * t), cos(TAU * h.y + 0.77 * w * t))) * p0.x;
}

// x = squared distance to the segment a-b, yz = the vector from it
vec3 seg(vec2 p, vec2 a, vec2 b) {
    vec2 ab = b - a;
    vec2 v = p - a - ab * clamp(dot(p - a, ab) / dot(ab, ab), 0.0, 1.0);
    return vec3(dot(v, v), v);
}

void main() {
    float S = p0.x;
    vec2 P = veilCoord();
    vec2 off = floor(seed.xy * 97.0);
    vec2 c0 = floor(P / S);
    float t = time * p1.x;

    float nd = 1e9;
    vec2 nv = vec2(0.0);
    float lineDeep = 0.0;
    vec2 lineSlope = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 c = c0 + vec2(float(i), float(j));
            vec2 a = node(c, off, t);
            vec2 v = P - a;
            float d = dot(v, v);
            if (d < nd) {
                nd = d;
                nv = v;
            }
            vec2 lk = hash22(c * 1.93 + off + 41.0);
            for (int e = 0; e < 2; e++) {
                vec2 step_ = e == 0 ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
                float joined = e == 0 ? lk.x : lk.y;
                if (joined < p1.z) {
                    vec2 b = node(c + step_, off, t);
                    float hold = 1.0 - smoothstep(1.0 * S, 1.42 * S, length(b - a));
                    vec3 s = seg(P, a, b);
                    float sd = sqrt(s.x);
                    vec2 gr = veilGroove(sd, p0.y, p0.w) * hold;
                    if (gr.x > lineDeep) {
                        lineDeep = gr.x;
                        lineSlope = gr.y * s.yz / max(sd, 1e-4);
                    }
                }
            }
        }
    }
    float d = sqrt(nd);
    vec2 well = veilGroove(d, p0.z, p0.w * 1.7);
    float depth = lineDeep;
    vec2 slope = lineSlope;
    if (well.x > 0.0) {
        // the well takes the lines that run into it
        float k = smoothstep(p0.z, p0.z * 0.6, d);
        depth = max(well.x, lineDeep * (1.0 - k));
        slope = mix(lineSlope, well.y * nv / max(d, 1e-4), max(k, step(lineDeep, well.x)));
    }
    fragColor = veilShade(depth, slope);
}
