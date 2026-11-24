#version 440
// =============================================================================
// veil_paper.vert -- PAPER LAYERS: the sheets' smooth fields, evaluated at the vertices.
//
// Every sheet's edge is a contour of ONE smooth field (a sum of seven plane waves), cut at
// a level of its own; the sheets drift over each other at different speeds, so the stack
// slides apart slowly. The field and its gradient are exact (a sum of sines), a key's
// ripple is a damped packet with its own gradient, and one vertex to every few pixels
// is enough: the fragment shader rebuilds d from A, grad d and C = grad d . p_v
// (d = A + 0.5 (G.p - C), exact for a quadratic field -- veil_gooey.vert).
// Per sheet the vertex also hands over the ripple's height H and its slope: the sheet's
// face is shaded by it and its edge swells with it.
// =============================================================================
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
layout(location = 1) out vec4 fA;
layout(location = 2) out vec4 fGx;
layout(location = 3) out vec4 fGy;
layout(location = 4) out vec4 fC;
layout(location = 5) out vec4 fH;
layout(location = 6) out vec4 fS;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  size;         // the item, item px
    vec4  off01;        // sheets 1, 2: where the field is sampled from, item px (drift + rattle)
    vec4  off23;        // sheets 3, 4
    vec4  lev;          // sheets 1..4: the level each is cut at, field units
    vec4  geo;          // px per field unit, unit (size.y / 1620), smallest gradient, edge swell
    vec4  pk;           // ripple: speed px/s at 1620 high, width px, height px, cycles
    vec4  pk2;          // ripple: seconds between one sheet and the next; pattern scale; the most a swell moves an edge, px
    vec4  shell;        // the popup: x0 y0 x1 y1
    vec4  bar;          // the bar:   x0 y0 x1 y1
    vec4  rad;          // popup radius, bar radius
    vec4  prs;          // presence, opaque, front feather px, 0
    vec4  frontBed;     // the bed's entrance front: radius px out of the shell (x)
    vec4  look1;        // shadow spread px, shadow strength, shadow drop px, bevel width px
    vec4  look2;        // bevel strength, face shading gain, lift gain, popup shadow
    vec4  alphas;       // bed alpha, sheet alpha
    vec4  colB;         // the plateau colour of the bed and of sheets 1..4 (deeper toward the bed, error-tinted on a fail)
    vec4  col1;
    vec4  col2;
    vec4  col3;
    vec4  col4;
    vec4  fxv;          // fail envelope, wake lift
    vec4  cSurf;
    vec4  cDeep;
    vec4  cHi;
    vec4  cLo;
    vec4  cErr;
    vec4  cShc;         // the shadow's colour (a little error-tinted on a fail)
    float pulCount;
    vec4  pul0;         // x y age weight
    vec4  pul1;
    vec4  pul2;
    vec4  pul3;
    vec4  pul4;
    vec4  pul5;
    vec4  pul6;
    vec4  pul7;
    vec4  pul8;
    vec4  pul9;
    vec4  pul10;
    vec4  pul11;
    vec4  pul12;
    vec4  pul13;
    vec4  pul14;
    vec4  pul15;
};


const float TAU = 6.2831853;
const vec2 LIGHT = vec2(-0.5145, -0.8575);   // toward the light, y down

// The plane waves: direction angle, wavelength px at 1620 high, amplitude, phase.
const vec4 W0 = vec4(0.30, 1180.0, 1.00, 0.4);
const vec4 W1 = vec4(1.55, 840.0, 0.80, 2.1);
const vec4 W2 = vec4(2.65, 650.0, 0.55, 4.3);
const vec4 W3 = vec4(3.95, 520.0, 0.36, 1.2);
const vec4 W4 = vec4(5.10, 410.0, 0.22, 5.6);
const vec4 W5 = vec4(0.95, 330.0, 0.12, 3.3);
const vec4 W6 = vec4(2.05, 270.0, 0.07, 0.9);
const float NORM = 0.967;       // 1 / sqrt(sum a^2 / 2): the field's spread is about 1

void wave(vec2 q, vec4 w, inout float f, inout vec2 g) {
    float k = TAU / (w.y * geo.y * pk2.y);
    vec2 dir = vec2(cos(w.x), sin(w.x));
    float a = k * dot(dir, q) + w.w;
    f += w.z * sin(a);
    g += (w.z * k * cos(a)) * dir;
}
void field(vec2 q, out float f, out vec2 g) {
    f = 0.0; g = vec2(0.0);
    wave(q, W0, f, g); wave(q, W1, f, g); wave(q, W2, f, g); wave(q, W3, f, g);
    wave(q, W4, f, g); wave(q, W5, f, g); wave(q, W6, f, g);
    f *= NORM; g *= NORM;
}

// One key's ripple through the stack: a damped packet travelling out of (x, y), reaching
// the top sheet (4) first and each lower one `pk2.x` seconds later. pu = (x, y, age, weight).
void ripple(vec2 p, vec4 pu, inout vec4 H, inout vec4 Hx, inout vec4 Hy) {
    if (pu.w <= 0.0) return;
    vec2 q = p - pu.xy;
    float r = max(length(q), 1.0);
    float wd = max(pk.y * geo.y, 1.0);
    vec4 age = vec4(pu.z) - pk2.x * vec4(3.0, 2.0, 1.0, 0.0);
    vec4 on = step(0.0, age);
    vec4 u = (vec4(r) - pk.x * geo.y * max(age, 0.0)) / wd;
    vec4 e = exp(-u * u) * on;
    vec4 sn = sin(pk.w * u);
    vec4 cs = cos(pk.w * u);
    float rad = pu.w * pk.z * geo.y / (1.0 + r / (900.0 * geo.y));
    H += rad * e * sn;
    vec4 dr = rad * e * (-2.0 * u * sn + pk.w * cs) / wd;
    Hx += dr * (q.x / r);
    Hy += dr * (q.y / r);
}

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
    vec2 p = qt_MultiTexCoord0 * size;
    vec2 pr = p - 0.5 * size;

    float f0, f1, f2, f3;
    vec2 g0, g1, g2, g3;
    field(p - off01.xy, f0, g0);
    field(p - off01.zw, f1, g1);
    field(p - off23.xy, f2, g2);
    field(p - off23.zw, f3, g3);
    vec4 F = vec4(f0, f1, f2, f3);
    vec4 Gx = vec4(g0.x, g1.x, g2.x, g3.x);
    vec4 Gy = vec4(g0.y, g1.y, g2.y, g3.y);
    float S = geo.x;
    vec4 d = (F - lev) * S;
    Gx *= S;
    Gy *= S;

    vec4 H = vec4(0.0), Hx = vec4(0.0), Hy = vec4(0.0);
    ripple(p, pul0, H, Hx, Hy);
    ripple(p, pul1, H, Hx, Hy);
    ripple(p, pul2, H, Hx, Hy);
    ripple(p, pul3, H, Hx, Hy);
    ripple(p, pul4, H, Hx, Hy);
    ripple(p, pul5, H, Hx, Hy);
    ripple(p, pul6, H, Hx, Hy);
    ripple(p, pul7, H, Hx, Hy);
    ripple(p, pul8, H, Hx, Hy);
    ripple(p, pul9, H, Hx, Hy);
    ripple(p, pul10, H, Hx, Hy);
    ripple(p, pul11, H, Hx, Hy);
    ripple(p, pul12, H, Hx, Hy);
    ripple(p, pul13, H, Hx, Hy);
    ripple(p, pul14, H, Hx, Hy);
    ripple(p, pul15, H, Hx, Hy);
    // the edge swells with the ripple's height (geo.w of it), the gradient scaled by the field's own, and held
    // under pk2.z px by a soft clamp, y / sqrt(1 + y^2) of the push in caps: two neighbouring sheets can never
    // swell toward each other by more than two caps (THE CASCADE's budget, VeilPaper.qml)
    vec4 gm = max(sqrt(Gx * Gx + Gy * Gy), vec4(geo.z));
    vec4 cap = vec4(max(pk2.z, 1e-3));
    vec4 sy = geo.w * H / cap;
    vec4 si = inversesqrt(vec4(1.0) + sy * sy);
    d += gm * cap * sy * si;
    vec4 dsw = gm * geo.w * si * si * si;    // the clamped push's slope in H
    Gx += dsw * Hx;
    Gy += dsw * Hy;

    // The shadow each sheet casts, evaluated here: it is as smooth as the field (a few tens of px
    // across), so the fragment shader only interpolates it. The sheet's own edge shifted by `drop`
    // (down and to the right: the light is above and to the left), wider and further when a ripple
    // (or a wake) lifts the sheet.
    vec4 ig = inversesqrt(max(Gx * Gx + Gy * Gy, vec4(geo.z * geo.z)));
    vec4 lf = vec4(1.0) + look2.z * clamp(H + vec4(fxv.y), 0.0, 2.0);
    vec4 sps = max(look1.x * geo.y * lf, vec4(1.0));
    vec4 dn = (-Gx * ig) * (-LIGHT.x * look1.z * geo.y) * lf + (-Gy * ig) * (-LIGHT.y * look1.z * geo.y) * lf;
    vec4 xx = -(d * ig + dn) / sps;
    vec4 tt = clamp((xx + 0.3) / 1.3, 0.0, 1.0);
    vec4 sf = vec4(1.0) - tt * tt * (3.0 - 2.0 * tt);
    fH = min(look1.y * sf * sf, vec4(0.95));

    fA = clamp(d, -4000.0, 4000.0);
    fGx = Gx;
    fGy = Gy;
    fC = Gx * pr.x + Gy * pr.y;
    fS = -(Hx * LIGHT.x + Hy * LIGHT.y);     // the ripple's slope along the light: what shades a face
}
