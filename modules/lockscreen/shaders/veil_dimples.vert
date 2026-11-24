#version 440
// =============================================================================
// veil_dimples.vert -- the per-cell half of the "Dimple field" veil, evaluated at the
// VERTICES of a coarse grid (a GridMesh, one vertex per 16 item px).
//
// The wells' depth is the sum of three travelling waves (wavelength 700 px) and the
// pulses (sigma 70-210 px): smooth over many grid steps. Each vertex evaluates the four
// smooth scalars that decide a well -- the wave sum w, the pulses' effect on the depth
// as dep = dep0 * kmul + kadd (the crest and the trough folded into the
// two coefficients), and the error tint err -- and their gradients (forward
// differences, 1.5 px), and the fragment shader reconstructs them at the CELL'S CENTRE:
// f = A + G . (cell centre - p), the interpolated value carried along the interpolated
// gradient. The linear interpolant is off by h^2/8 f'' (16 px steps, f'' ~ 1e-4: 4e-3 of
// the wave sum, which is a few thousandths of a depth), and the per-pixel cost is two
// multiply-adds a vector -- the Taylor-averaged reconstruction the relief veil uses cost
// 1.2 ms here for no visible gain. A texture would do the same job but a
// ShaderEffectSource that re-grabs every tick asks Qt for a SECOND frame per tick.
//
//   vA   w, kmul, kadd, err        vGx, vGy   their d/dx, d/dy
//
// PULSES (32 slots, `po.z` filled, nested guards):
//   1 key   a depth wave leaving the field
//   2 fail  two brisk waves, the wells tinted toward the error colour
//   4 wake  one broad gentle ripple
// The weight is how much of a pulse is still drawn -- the host fades the oldest out when
// more are alive than it draws, so none is cut.
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
    vec4  po;           // -, -, pulses alive, -
    vec4  pw;           // wake
    vec4 p0; vec4 p1; vec4 p2; vec4 p3; vec4 p4; vec4 p5;
    vec4 p6; vec4 p7; vec4 p8; vec4 p9; vec4 p10; vec4 p11;
    vec4 p12; vec4 p13; vec4 p14; vec4 p15; vec4 p16; vec4 p17;
    vec4 p18; vec4 p19; vec4 p20; vec4 p21; vec4 p22; vec4 p23;
    vec4 p24; vec4 p25; vec4 p26; vec4 p27; vec4 p28; vec4 p29;
    vec4 p30; vec4 p31;
};

// pulse: how far the wells here are pressed to full depth (the crest) or
// flattened (the trough behind it), so a ring shows on deep and shallow
// ground alike; the error tint
void pulseTerm(vec4 pu, vec2 c, inout float d, inout float dn_, inout float err) {
    float kind = floor(pu.w);
    if (kind < 0.5) return;
    float wg = 1.0 - fract(pu.w) / 0.9;
    float age = pu.z;
    float r = length(c - pu.xy);
    if (kind < 1.5) {
        float u = r - pk.y * age;
        float env = wg * exp(-age / pk.w) * smoothstep(0.0, 0.05, age) / sqrt(1.0 + r / 1200.0);
        d = max(d, pk.x * env * exp(-u * u / (2.0 * pk.z * pk.z)));
        float v = u + 1.6 * pk.z;
        dn_ = max(dn_, 0.85 * pk.x * env * exp(-v * v / (2.0 * pk.z * pk.z)));
    } else if (kind < 2.5) {
        for (int k = 0; k < 2; k++) {
            float a = age - 0.16 * float(k);
            if (a > 0.0) {
                float u = r - pf.y * a;
                float env = wg * exp(-a / pf.w) * smoothstep(0.0, 0.04, a) / sqrt(1.0 + r / 1200.0);
                float b = exp(-u * u / (2.0 * pf.z * pf.z)) * env;
                d = max(d, pf.x * b * (k == 0 ? 1.0 : 0.7));
                float v = u + 1.6 * pf.z;
                dn_ = max(dn_, 0.8 * pf.x * env * exp(-v * v / (2.0 * pf.z * pf.z)));
                err = max(err, b);
            }
        }
    } else {
        float u = r - pw.y * age;
        float env = wg * exp(-age / pw.w) * smoothstep(0.0, 0.3, age) / sqrt(1.0 + r / 500.0);
        d = max(d, pw.x * env * exp(-u * u / (2.0 * pw.z * pw.z)));
    }
}


// the four smooth scalars at c (item px): (w, kmul, kadd, err)
vec4 fieldAt(vec2 c) {
    float np = po.z;
    // One plane wave (broad diagonal bands sweeping across, its direction slowly
    // turning) and two radial waves of other wavelengths from drifting sources.
    float ph = wave.y * time;
    vec2 pdir = vec2(cos(wave.w), sin(wave.w));
    float w = sin(wave.x * dot(c, pdir) - ph)
            + 0.8 * sin(wave.x * 0.75 * length(c - srcA.xy) - ph * 0.8 + 1.9)
            + 0.6 * sin(wave.x * 1.35 * length(c - srcA.zw) - ph * 1.2 + 4.1);
    float dd = 0.0, dnn = 0.0, err = 0.0;
    if (np > 0.5) {
        pulseTerm(p0, c, dd, dnn, err);
        if (np > 1.5) {
            pulseTerm(p1, c, dd, dnn, err);
            if (np > 2.5) {
                pulseTerm(p2, c, dd, dnn, err);
                if (np > 3.5) {
                    pulseTerm(p3, c, dd, dnn, err);
                    if (np > 4.5) {
                        pulseTerm(p4, c, dd, dnn, err);
                        if (np > 5.5) {
                            pulseTerm(p5, c, dd, dnn, err);
                            if (np > 6.5) {
                                pulseTerm(p6, c, dd, dnn, err);
                                if (np > 7.5) {
                                    pulseTerm(p7, c, dd, dnn, err);
                                    if (np > 8.5) {
                                        pulseTerm(p8, c, dd, dnn, err);
                                        if (np > 9.5) {
                                            pulseTerm(p9, c, dd, dnn, err);
                                            if (np > 10.5) {
                                                pulseTerm(p10, c, dd, dnn, err);
                                                if (np > 11.5) {
                                                    pulseTerm(p11, c, dd, dnn, err);
                                                    if (np > 12.5) {
                                                        pulseTerm(p12, c, dd, dnn, err);
                                                        if (np > 13.5) {
                                                            pulseTerm(p13, c, dd, dnn, err);
                                                            if (np > 14.5) {
                                                                pulseTerm(p14, c, dd, dnn, err);
                                                                if (np > 15.5) {
                                                                    pulseTerm(p15, c, dd, dnn, err);
                                                                    if (np > 16.5) {
                                                                        pulseTerm(p16, c, dd, dnn, err);
                                                                        if (np > 17.5) {
                                                                            pulseTerm(p17, c, dd, dnn, err);
                                                                            if (np > 18.5) {
                                                                                pulseTerm(p18, c, dd, dnn, err);
                                                                                if (np > 19.5) {
                                                                                    pulseTerm(p19, c, dd, dnn, err);
                                                                                    if (np > 20.5) {
                                                                                        pulseTerm(p20, c, dd, dnn, err);
                                                                                        if (np > 21.5) {
                                                                                            pulseTerm(p21, c, dd, dnn, err);
                                                                                            if (np > 22.5) {
                                                                                                pulseTerm(p22, c, dd, dnn, err);
                                                                                                if (np > 23.5) {
                                                                                                    pulseTerm(p23, c, dd, dnn, err);
                                                                                                    if (np > 24.5) {
                                                                                                        pulseTerm(p24, c, dd, dnn, err);
                                                                                                        if (np > 25.5) {
                                                                                                            pulseTerm(p25, c, dd, dnn, err);
                                                                                                            if (np > 26.5) {
                                                                                                                pulseTerm(p26, c, dd, dnn, err);
                                                                                                                if (np > 27.5) {
                                                                                                                    pulseTerm(p27, c, dd, dnn, err);
                                                                                                                    if (np > 28.5) {
                                                                                                                        pulseTerm(p28, c, dd, dnn, err);
                                                                                                                        if (np > 29.5) {
                                                                                                                            pulseTerm(p29, c, dd, dnn, err);
                                                                                                                            if (np > 30.5) {
                                                                                                                                pulseTerm(p30, c, dd, dnn, err);
                                                                                                                                if (np > 31.5) {
                                                                                                                                    pulseTerm(p31, c, dd, dnn, err);
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
    dd = clamp(dd, 0.0, 1.0);
    dnn = clamp(dnn, 0.0, 1.0);
    // mix(mix(dep0, 1, dd), 0.03, dnn) = dep0 * kmul + kadd
    return vec4(w, (1.0 - dd) * (1.0 - dnn), dd * (1.0 - dnn) + 0.03 * dnn, clamp(err, 0.0, 1.0));
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
