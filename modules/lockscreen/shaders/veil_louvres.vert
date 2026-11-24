#version 440
// =============================================================================
// veil_louvres.vert -- the smooth half of the "Louvres" veil, evaluated at the VERTICES of a
// coarse grid (a GridMesh, one vertex per 16 item px); veil_louvres.frag reconstructs it at
// each slat's centre line (f = A + Gy * (slat centre y - vertex y): a slat's angle is a
// function of x along it and of its row, so only the vertical offset to the row's centre
// needs the gradient). A texture that re-grabs per tick would ask Qt for a second frame per
// tick; the vertices cost nothing per pixel.
//
//   vA   w (the slow wave, -1..1), kadd (pulses' turn, radians), fl (flutter / fail), ok
//   vGx, vGy   their d/dx, d/dy   (forward differences, 1.5 px)
//
// PULSES (32 slots, nested guards by `po.z`):
//   1 key    a turning wave out of the field: a slat tilts one way as the ring reaches it
//            and swings back the other as it passes (a signed packet, S-shaped)
//   2 fail   two brisk fronts; behind each the slats flutter (fl is the amplitude, the
//            fragment shader gives each slat its own phase) and take the error tint
//   3 ok     a front after which every slat lies at one angle (ok)
//   4 wake   one broad gentle turn
// The weight in the kind's fraction (kind + 0.9 * (1 - weight)) is how much of a pulse is
// still drawn; the host fades the oldest out when more are alive than it draws.
//
// The uniform block is the fragment shader's, member for member.
// =============================================================================
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
layout(location = 1) out vec4 vA;
layout(location = 2) out vec4 vGx;
layout(location = 3) out vec4 vGy;

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
    vec4  po;           // ok:   strength 0..1, front speed, pulses alive, -
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

// an S-shaped packet: u > 0 is behind the front; peak +1 a sigma behind it, -1 a sigma ahead
float packet(float u, float sg) {
    float x = u / sg;
    return x * exp(0.5 * (1.0 - x * x));
}

void pulseTerm(vec4 pu, vec2 c, inout float kadd, inout float fl, inout float okf) {
    float kind = floor(pu.w);
    if (kind < 0.5) return;
    float wg = 1.0 - fract(pu.w) / 0.9;
    float age = pu.z;
    float r = length(c - pu.xy);
    if (kind < 1.5) {
        float u = r - pk.y * age;
        float env = wg * exp(-age / pk.w) * smoothstep(0.0, 0.05, age) / sqrt(1.0 + r / 1200.0);
        kadd += pk.x * env * packet(-u, pk.z);
    } else if (kind < 2.5) {
        for (int k = 0; k < 2; k++) {
            float a = age - 0.16 * float(k);
            if (a > 0.0) {
                float u = r - pf.y * a;
                float env = wg * exp(-a / pf.w) * smoothstep(0.0, 0.04, a) / sqrt(1.0 + r / 1200.0);
                float sh = u > 0.0 ? exp(-u * u / (0.5 * pf.z * pf.z)) : exp(u / (2.5 * pf.z));
                fl = max(fl, env * sh * (k == 0 ? 1.0 : 0.7));
            }
        }
    } else if (kind < 3.5) {
        float e = wg * smoothstep(0.0, 0.5, age) * (1.0 - smoothstep(1.6, 4.6, age));
        float front = smoothstep(-90.0, 90.0, po.y * age - r);
        okf = max(okf, e * front);
        // the front swings the slats a little past their angle as it goes by
        kadd += 0.35 * e * exp(-pow(po.y * age - r, 2.0) / (2.0 * 70.0 * 70.0));
    } else {
        float u = r - pw.y * age;
        float env = wg * exp(-age / pw.w) * smoothstep(0.0, 0.3, age) / sqrt(1.0 + r / 500.0);
        kadd += pw.x * env * packet(-u, pw.z);
    }
}

// (w, kadd, fl, ok) at c (item px)
vec4 fieldAt(vec2 c) {
    float np = po.z;
    // a plane wave (broad diagonal bands, the direction slowly turning) and a radial one
    // from a drifting source: the light rolls across the slats in bands
    float ph = wave.y * time;
    vec2 pdir = vec2(cos(wave.w), sin(wave.w));
    float w = (sin(wave.x * dot(c, pdir) - ph)
            + 0.45 * sin(wave.x * 0.7 * length(c - srcA.xy) - ph * 0.8 + 1.9)) / 1.45;
    float kadd = 0.0, fl = 0.0, okf = 0.0;
    // GEN chain:pulseTerm(%s, c, kadd, fl, okf) BEGIN
    if (np > 0.5) {
        pulseTerm(p0, c, kadd, fl, okf);
        if (np > 1.5) {
            pulseTerm(p1, c, kadd, fl, okf);
            if (np > 2.5) {
                pulseTerm(p2, c, kadd, fl, okf);
                if (np > 3.5) {
                    pulseTerm(p3, c, kadd, fl, okf);
                    if (np > 4.5) {
                        pulseTerm(p4, c, kadd, fl, okf);
                        if (np > 5.5) {
                            pulseTerm(p5, c, kadd, fl, okf);
                            if (np > 6.5) {
                                pulseTerm(p6, c, kadd, fl, okf);
                                if (np > 7.5) {
                                    pulseTerm(p7, c, kadd, fl, okf);
                                    if (np > 8.5) {
                                        pulseTerm(p8, c, kadd, fl, okf);
                                        if (np > 9.5) {
                                            pulseTerm(p9, c, kadd, fl, okf);
                                            if (np > 10.5) {
                                                pulseTerm(p10, c, kadd, fl, okf);
                                                if (np > 11.5) {
                                                    pulseTerm(p11, c, kadd, fl, okf);
                                                    if (np > 12.5) {
                                                        pulseTerm(p12, c, kadd, fl, okf);
                                                        if (np > 13.5) {
                                                            pulseTerm(p13, c, kadd, fl, okf);
                                                            if (np > 14.5) {
                                                                pulseTerm(p14, c, kadd, fl, okf);
                                                                if (np > 15.5) {
                                                                    pulseTerm(p15, c, kadd, fl, okf);
                                                                    if (np > 16.5) {
                                                                        pulseTerm(p16, c, kadd, fl, okf);
                                                                        if (np > 17.5) {
                                                                            pulseTerm(p17, c, kadd, fl, okf);
                                                                            if (np > 18.5) {
                                                                                pulseTerm(p18, c, kadd, fl, okf);
                                                                                if (np > 19.5) {
                                                                                    pulseTerm(p19, c, kadd, fl, okf);
                                                                                    if (np > 20.5) {
                                                                                        pulseTerm(p20, c, kadd, fl, okf);
                                                                                        if (np > 21.5) {
                                                                                            pulseTerm(p21, c, kadd, fl, okf);
                                                                                            if (np > 22.5) {
                                                                                                pulseTerm(p22, c, kadd, fl, okf);
                                                                                                if (np > 23.5) {
                                                                                                    pulseTerm(p23, c, kadd, fl, okf);
                                                                                                    if (np > 24.5) {
                                                                                                        pulseTerm(p24, c, kadd, fl, okf);
                                                                                                        if (np > 25.5) {
                                                                                                            pulseTerm(p25, c, kadd, fl, okf);
                                                                                                            if (np > 26.5) {
                                                                                                                pulseTerm(p26, c, kadd, fl, okf);
                                                                                                                if (np > 27.5) {
                                                                                                                    pulseTerm(p27, c, kadd, fl, okf);
                                                                                                                    if (np > 28.5) {
                                                                                                                        pulseTerm(p28, c, kadd, fl, okf);
                                                                                                                        if (np > 29.5) {
                                                                                                                            pulseTerm(p29, c, kadd, fl, okf);
                                                                                                                            if (np > 30.5) {
                                                                                                                                pulseTerm(p30, c, kadd, fl, okf);
                                                                                                                                if (np > 31.5) {
                                                                                                                                    pulseTerm(p31, c, kadd, fl, okf);
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
    // GEN chain:pulseTerm(%s, c, kadd, fl, okf) END
    return vec4(w, kadd, clamp(fl, 0.0, 1.0), clamp(po.x * okf, 0.0, 1.0));
}

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
    vec2 p = qt_Vertex.xy;
    const float e = 1.5;
    vec4 f0 = fieldAt(p);
    vA = f0;
    vGx = (fieldAt(p + vec2(e, 0.0)) - f0) / e;
    vGy = (fieldAt(p + vec2(0.0, e)) - f0) / e;
}
