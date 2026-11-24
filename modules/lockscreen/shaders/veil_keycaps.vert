#version 440
// =============================================================================
// veil_keycaps.vert -- the smooth half of the "Keycaps" veil, evaluated at the VERTICES of a
// coarse grid (a GridMesh, one per 16 item px); veil_keycaps.frag reconstructs it at each cap's
// centre (f = A + G . (cap centre - p)), so the ~1900 pixels of a cap agree and none
// recomputes it, and no texture is re-grabbed per tick (one frame per tick).
//
//   vA   dep (how far the cap is pressed down; negative = sprung up past rest),
//        err (fail tint), ok (accepted tint), sheen (wake's light)
//   vGx, vGy   their d/dx, d/dy   (forward differences, 1.5 px)
//
// WAVES: slow bands that press rows of caps down and let them spring back (a press, then
// a small overshoot behind it). PULSES (32 slots, nested guards by po.z):
//   1 key    a ring leaves the field: caps press as it reaches them and spring up behind it
//   2 fail   two brisk rings, the caps tinted toward the error colour
//   3 ok     one wide ring presses the caps in turn, tinted toward ok behind the front
//   4 wake   one broad soft ring, a sheen of light on the caps
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

    vec4  grid;         // pitch (device px, even), cap fill, corner radius (share of the half size), shadow width (device px)
    vec4  wave;         // k (rad / item px), omega (rad / s), amplitude (depth), plane wave angle
    vec4  srcA;         // radial source xy, shadow drop (device px), cap shrink when pressed
    vec4  light;        // toward-light x, y (unit), bevel width (device px), rise spread
    vec4  grade;        // cap alpha over the desktop, gap alpha, shadow gain, bevel gain
    vec4  grade2;       // dark 0/1, entrance overshoot, the farthest corner from the popup rect (metric px), -
    vec4  rect;         // the popup: centre xy, half extent xy (item px); the entrance's front leaves its outline
    vec4  detail;       // dish, legends, -, -
    vec4  clearFront;   // the clear: the accepted ring's centre xy (item px), seconds since it left less the trail, one cap's way down (s; 0: no clear)

    vec4  cCap;
    vec4  cFloor;
    vec4  cMid;
    vec4  cShadow;
    vec4  cBevel;
    vec4  cError;
    vec4  cOk;

    vec4  pk;           // key:  amplitude (depth), speed px/s, sigma px, life s
    vec4  pf;           // fail: amplitude, speed, sigma, life
    vec4  po;           // ok:   amplitude, front speed, pulses alive, tint strength
    vec4  pw;           // wake: amplitude, speed, sigma, life
    // GEN slots BEGIN
    vec4 p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5;
    vec4 p6; vec4 p7; vec4 p8; vec4 p9; vec4 p10; vec4 p11;
    vec4 p12; vec4 p13; vec4 p14; vec4 p15; vec4 p16; vec4 p17;
    vec4 p18; vec4 p19; vec4 p20; vec4 p21; vec4 p22; vec4 p23;
    vec4 p24; vec4 p25; vec4 p26; vec4 p27; vec4 p28; vec4 p29;
    vec4 p30; vec4 p31;
    // GEN slots END
};

float gauss(float u, float sg) { return exp(-u * u / (2.0 * sg * sg)); }

void pulseTerm(vec4 pu, vec2 c, inout float dep, inout float err, inout float okt, inout float sheen) {
    float kind = floor(pu.w);
    if (kind < 0.5) return;
    float wg = 1.0 - fract(pu.w) / 0.9;
    float age = pu.z;
    float r = length(c - pu.xy);
    if (kind < 1.5) {
        float u = r - pk.y * age;
        float env = wg * exp(-age / pk.w) * smoothstep(0.0, 0.05, age) / sqrt(1.0 + r / 1200.0);
        float lag = (u + 1.8 * pk.z) / (1.2 * pk.z);
        dep += pk.x * env * (gauss(u, pk.z) - 0.3 * exp(-0.5 * lag * lag));
    } else if (kind < 2.5) {
        for (int k = 0; k < 2; k++) {
            float a = age - 0.16 * float(k);
            if (a > 0.0) {
                float u = r - pf.y * a;
                float env = wg * exp(-a / pf.w) * smoothstep(0.0, 0.04, a) / sqrt(1.0 + r / 1200.0);
                float b = gauss(u, pf.z) * env * (k == 0 ? 1.0 : 0.7);
                dep += pf.x * b;
                err = max(err, b);
            }
        }
    } else if (kind < 3.5) {
        float u = r - po.y * age;
        float env = wg * exp(-age / 1.4) * smoothstep(0.0, 0.1, age);
        dep += po.x * env * gauss(u, 150.0);
        float e = wg * smoothstep(0.0, 0.4, age) * (1.0 - smoothstep(1.6, 4.6, age));
        okt = max(okt, e * smoothstep(60.0, -60.0, u));
    } else {
        float u = r - pw.y * age;
        float env = wg * exp(-age / pw.w) * smoothstep(0.0, 0.3, age) / sqrt(1.0 + r / 500.0);
        float b = gauss(u, pw.z) * env;
        dep += 0.5 * pw.x * b;
        sheen = max(sheen, b);
    }
}

// (dep, err, ok, sheen) at c (item px)
vec4 fieldAt(vec2 c) {
    float np = po.z;
    // slow bands of presses: mostly across the rows, one radial wave of another wavelength
    float ph = wave.y * time;
    vec2 pdir = vec2(cos(wave.w), sin(wave.w));
    float f1 = wave.x * dot(c, pdir) - ph;
    float f2 = wave.x * 0.8 * length(c - srcA.xy) - ph * 0.7 + 1.3;
    float a1 = 0.5 + 0.5 * sin(f1);
    float a2 = 0.5 + 0.5 * sin(f1 - 0.9);
    float a3 = 0.5 + 0.5 * sin(f2);
    float dep = wave.z * (smoothstep(0.62, 0.95, a1) - 0.18 * smoothstep(0.62, 0.95, a2)
                          + 0.55 * smoothstep(0.7, 0.97, a3));
    float err = 0.0, okt = 0.0, sheen = 0.0;
    // GEN chain:pulseTerm(%s, c, dep, err, okt, sheen) BEGIN
    if (np > 0.5) {
        pulseTerm(p0, c, dep, err, okt, sheen);
        if (np > 1.5) {
            pulseTerm(p1, c, dep, err, okt, sheen);
            if (np > 2.5) {
                pulseTerm(p2, c, dep, err, okt, sheen);
                if (np > 3.5) {
                    pulseTerm(p3, c, dep, err, okt, sheen);
                    if (np > 4.5) {
                        pulseTerm(p4, c, dep, err, okt, sheen);
                        if (np > 5.5) {
                            pulseTerm(p5, c, dep, err, okt, sheen);
                            if (np > 6.5) {
                                pulseTerm(p6, c, dep, err, okt, sheen);
                                if (np > 7.5) {
                                    pulseTerm(p7, c, dep, err, okt, sheen);
                                    if (np > 8.5) {
                                        pulseTerm(p8, c, dep, err, okt, sheen);
                                        if (np > 9.5) {
                                            pulseTerm(p9, c, dep, err, okt, sheen);
                                            if (np > 10.5) {
                                                pulseTerm(p10, c, dep, err, okt, sheen);
                                                if (np > 11.5) {
                                                    pulseTerm(p11, c, dep, err, okt, sheen);
                                                    if (np > 12.5) {
                                                        pulseTerm(p12, c, dep, err, okt, sheen);
                                                        if (np > 13.5) {
                                                            pulseTerm(p13, c, dep, err, okt, sheen);
                                                            if (np > 14.5) {
                                                                pulseTerm(p14, c, dep, err, okt, sheen);
                                                                if (np > 15.5) {
                                                                    pulseTerm(p15, c, dep, err, okt, sheen);
                                                                    if (np > 16.5) {
                                                                        pulseTerm(p16, c, dep, err, okt, sheen);
                                                                        if (np > 17.5) {
                                                                            pulseTerm(p17, c, dep, err, okt, sheen);
                                                                            if (np > 18.5) {
                                                                                pulseTerm(p18, c, dep, err, okt, sheen);
                                                                                if (np > 19.5) {
                                                                                    pulseTerm(p19, c, dep, err, okt, sheen);
                                                                                    if (np > 20.5) {
                                                                                        pulseTerm(p20, c, dep, err, okt, sheen);
                                                                                        if (np > 21.5) {
                                                                                            pulseTerm(p21, c, dep, err, okt, sheen);
                                                                                            if (np > 22.5) {
                                                                                                pulseTerm(p22, c, dep, err, okt, sheen);
                                                                                                if (np > 23.5) {
                                                                                                    pulseTerm(p23, c, dep, err, okt, sheen);
                                                                                                    if (np > 24.5) {
                                                                                                        pulseTerm(p24, c, dep, err, okt, sheen);
                                                                                                        if (np > 25.5) {
                                                                                                            pulseTerm(p25, c, dep, err, okt, sheen);
                                                                                                            if (np > 26.5) {
                                                                                                                pulseTerm(p26, c, dep, err, okt, sheen);
                                                                                                                if (np > 27.5) {
                                                                                                                    pulseTerm(p27, c, dep, err, okt, sheen);
                                                                                                                    if (np > 28.5) {
                                                                                                                        pulseTerm(p28, c, dep, err, okt, sheen);
                                                                                                                        if (np > 29.5) {
                                                                                                                            pulseTerm(p29, c, dep, err, okt, sheen);
                                                                                                                            if (np > 30.5) {
                                                                                                                                pulseTerm(p30, c, dep, err, okt, sheen);
                                                                                                                                if (np > 31.5) {
                                                                                                                                    pulseTerm(p31, c, dep, err, okt, sheen);
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
    // GEN chain:pulseTerm(%s, c, dep, err, okt, sheen) END
    return vec4(dep, clamp(err, 0.0, 1.0), clamp(po.w * okt, 0.0, 1.0), clamp(sheen, 0.0, 1.0));
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
