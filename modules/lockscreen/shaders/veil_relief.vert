#version 440
// =============================================================================
// veil_relief.vert -- the smooth half of the "Sunlit relief" veil, evaluated at the
// VERTICES of a coarse grid (a GridMesh, one vertex per 16 item px).
//
// The two value noises that bend and swell the dune lines (wavelengths ~900 and ~1650 px)
// and every pulse (sigma 40-200 px) are smooth over many grid steps, so each vertex
// computes them once and the fragment shader reconstructs the field between: it gets f,
// grad f and C = grad f . p_v (p measured from the item's centre, for precision) and
// takes f = A + 0.5 (G . p - C): the mean of the linear interpolant and of the blended
// first-order Taylor steps, exact for a quadratic field (error O(h^3)). A texture would
// do the same job but a ShaderEffectSource that re-grabs every tick asks Qt for a SECOND
// frame per tick.
//
//   vA   n1.value, n2.value, pulse height px, error tint
//   vC   G.p of the first three
//   vG1  grad n1 (per px), grad n2 (per px)
//   vGp  pulse gradient (px per px)
//
// PULSES (32 slots, vec4(x, y, age s, kind + 0.9 * (1 - weight))): `po.z` is how many are
// filled, tested in nested guards so the unused cost one compare. The weight is how much
// of a pulse is still drawn: the host fades the oldest one out when more are alive than it
// draws, so it leaves smoothly.
//   1 key   a pebble ring: crest, trough, gone, travelling out
//   2 fail  two brisk rings, tinted toward the error colour
//   4 wake  one broad slow swell
//
// The uniform block is the fragment shader's, member for member.
// =============================================================================
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
layout(location = 1) out vec4 vA;
layout(location = 2) out vec4 vC;
layout(location = 3) out vec4 vG1;
layout(location = 4) out vec4 vGp;

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

    vec4  po;           // -, -, pulses alive, -

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

float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// value noise, quintic, with its analytic gradient: (value, d/dx, d/dy)
vec3 vn3(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    vec2 du = 30.0 * f * f * (f - 1.0) * (f - 1.0);
    float a = hash(i);
    float b = hash(i + vec2(1.0, 0.0));
    float c = hash(i + vec2(0.0, 1.0));
    float d = hash(i + vec2(1.0, 1.0));
    float k = a - b - c + d;
    return vec3(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y,
                du.x * ((b - a) + k * u.y),
                du.y * ((c - a) + k * u.x));
}

// One pulse's contribution to the height (px), its gradient, the error tint
// and the flattening.
void pulseTerm(vec4 pu, vec2 p, inout float h, inout vec2 g, inout float err) {
    float kind = floor(pu.w);
    if (kind < 0.5) return;
    float wg = 1.0 - fract(pu.w) / 0.9;
    float age = pu.z;
    vec2 dv = p - pu.xy;
    float r = length(dv) + 0.001;
    vec2 rh = dv / r;
    if (kind < 1.5) {
        float sg = pk.z;
        float u = r - pk.y * age;
        float env = wg * exp(-age / pk.w) * smoothstep(0.0, 0.06, age) / sqrt(1.0 + r / 260.0);
        float gs = exp(-u * u / (2.0 * sg * sg));
        float kk = 1.5 / sg;
        float c = cos(u * kk);
        float s = sin(u * kk);
        h += pk.x * env * gs * c;
        g += pk.x * env * gs * (-u / (sg * sg) * c - kk * s) * rh;
    } else if (kind < 2.5) {
        float sg = pf.z;
        for (int k = 0; k < 2; k++) {
            float a = age - 0.17 * float(k);
            if (a > 0.0) {
                float u = r - pf.y * a;
                float env = wg * exp(-a / pf.w) * smoothstep(0.0, 0.05, a) / sqrt(1.0 + r / 320.0);
                float gs = exp(-u * u / (2.0 * sg * sg));
                float kk = 1.3 / sg;
                float c = cos(u * kk);
                float s = sin(u * kk);
                float amp = pf.x * (k == 0 ? 1.0 : 0.6);
                h += amp * env * gs * c;
                g += amp * env * gs * (-u / (sg * sg) * c - kk * s) * rh;
                float t = exp(-u * u / (2.0 * 2.4 * sg * sg)) * env;
                err = max(err, t);
            }
        }
    } else {
        float sg = pw.z;
        float u = r - pw.y * age;
        float env = wg * exp(-age / pw.w) * smoothstep(0.0, 0.3, age) / sqrt(1.0 + r / 400.0);
        float gs = exp(-u * u / (2.0 * sg * sg));
        h += pw.x * env * gs;
        g += pw.x * env * gs * (-u / (sg * sg)) * rh;
    }
}


void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
    vec2 p = qt_Vertex.xy;
    float np = po.z;
    vec2 wd = geoA.xy;
    vec2 gNz = vec2(-wd.y, wd.x) * time * terrain.w * 0.6 + wd * time * terrain.w * 0.25;
    vec3 n1 = vn3((p + gNz) / (terrain.y * 1.25) + vec2(3.1, 7.7));
    vec3 n2 = vn3((p + gNz) / (terrain.y * 2.3) + vec2(11.3, 2.9));
    vec2 g1 = n1.yz * (geoA.z * 0.8);
    vec2 g2 = n2.yz * (geoA.z / 2.3);

    float hp = 0.0;
    vec2 gp = vec2(0.0);
    float err = 0.0;
    if (np > 0.5) {
        pulseTerm(p0, p, hp, gp, err);
        if (np > 1.5) {
            pulseTerm(p1, p, hp, gp, err);
            if (np > 2.5) {
                pulseTerm(p2, p, hp, gp, err);
                if (np > 3.5) {
                    pulseTerm(p3, p, hp, gp, err);
                    if (np > 4.5) {
                        pulseTerm(p4, p, hp, gp, err);
                        if (np > 5.5) {
                            pulseTerm(p5, p, hp, gp, err);
                            if (np > 6.5) {
                                pulseTerm(p6, p, hp, gp, err);
                                if (np > 7.5) {
                                    pulseTerm(p7, p, hp, gp, err);
                                    if (np > 8.5) {
                                        pulseTerm(p8, p, hp, gp, err);
                                        if (np > 9.5) {
                                            pulseTerm(p9, p, hp, gp, err);
                                            if (np > 10.5) {
                                                pulseTerm(p10, p, hp, gp, err);
                                                if (np > 11.5) {
                                                    pulseTerm(p11, p, hp, gp, err);
                                                    if (np > 12.5) {
                                                        pulseTerm(p12, p, hp, gp, err);
                                                        if (np > 13.5) {
                                                            pulseTerm(p13, p, hp, gp, err);
                                                            if (np > 14.5) {
                                                                pulseTerm(p14, p, hp, gp, err);
                                                                if (np > 15.5) {
                                                                    pulseTerm(p15, p, hp, gp, err);
                                                                    if (np > 16.5) {
                                                                        pulseTerm(p16, p, hp, gp, err);
                                                                        if (np > 17.5) {
                                                                            pulseTerm(p17, p, hp, gp, err);
                                                                            if (np > 18.5) {
                                                                                pulseTerm(p18, p, hp, gp, err);
                                                                                if (np > 19.5) {
                                                                                    pulseTerm(p19, p, hp, gp, err);
                                                                                    if (np > 20.5) {
                                                                                        pulseTerm(p20, p, hp, gp, err);
                                                                                        if (np > 21.5) {
                                                                                            pulseTerm(p21, p, hp, gp, err);
                                                                                            if (np > 22.5) {
                                                                                                pulseTerm(p22, p, hp, gp, err);
                                                                                                if (np > 23.5) {
                                                                                                    pulseTerm(p23, p, hp, gp, err);
                                                                                                    if (np > 24.5) {
                                                                                                        pulseTerm(p24, p, hp, gp, err);
                                                                                                        if (np > 25.5) {
                                                                                                            pulseTerm(p25, p, hp, gp, err);
                                                                                                            if (np > 26.5) {
                                                                                                                pulseTerm(p26, p, hp, gp, err);
                                                                                                                if (np > 27.5) {
                                                                                                                    pulseTerm(p27, p, hp, gp, err);
                                                                                                                    if (np > 28.5) {
                                                                                                                        pulseTerm(p28, p, hp, gp, err);
                                                                                                                        if (np > 29.5) {
                                                                                                                            pulseTerm(p29, p, hp, gp, err);
                                                                                                                            if (np > 30.5) {
                                                                                                                                pulseTerm(p30, p, hp, gp, err);
                                                                                                                                if (np > 31.5) {
                                                                                                                                    pulseTerm(p31, p, hp, gp, err);
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
    vec2 pc = p - 0.5 * size;
    vA = vec4(n1.x, n2.x, hp, err);
    vC = vec4(dot(g1, pc), dot(g2, pc), dot(gp, pc), 0.0);
    vG1 = vec4(g1, g2);
    vGp = vec4(gp, 0.0, 0.0);
}
