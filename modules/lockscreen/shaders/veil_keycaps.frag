#version 440

// =============================================================================
// veil_keycaps.frag -- the lock veil "Keycaps": a field of raised keycaps in the material,
// softly lit. Slow waves press rows of them down and let them spring back; each key you
// type presses the caps outward from the field in a ring.
//
// ONE SHADER, NO ITEMS, in DEVICE pixels: the cell is floor(pixel / pitch) with an even
// integer pitch, so every cap's centre and every cell edge lie on whole pixels. A cap is a
// rounded square (signed distance, feathered INWARD only, the pixel size taken from a
// LINEAR coordinate) that STANDS PROUD of the ground, as the shell's raised buttons do:
// a drop shadow outside it falling down and to the right (the light is above-left) and an
// inner highlight along its lit edges. A pressed cap (dep -> 1) sinks: it shrinks a
// little, its shadow shortens and tightens, its highlight fades and its top darkens; a
// sprung one (dep < 0) stands higher. The gap between caps is the ground, carved dark;
// it takes the shadows of its own cap and of the three caps up and to the left of it
// (the only ones the shadow's direction can reach).
//
// THE ENTRANCE. presence is a front travelling out from `origin`, in a squarish metric
// (a keyboard's rectangle of presses, not a circle): before it the screen is untouched;
// as it passes a cap rises out of the surface -- it grows from a point to full size with a
// little overshoot while its shadow lengthens -- in about a fifth of the entrance.
// OVER THE DESKTOP the caps are a translucent tint of the surface and the gaps a
// translucent tint of the floor; at boot both are opaque.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 1) in vec4 vA;     // dep, err, ok, sheen at the vertex
layout(location = 2) in vec4 vGx;    // their d/dx
layout(location = 3) in vec4 vGy;    // their d/dy
layout(location = 0) out vec4 fragColor;

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

vec4 over(vec4 acc, vec3 c, float a) {
    return vec4(c * a + acc.rgb * (1.0 - a), a + acc.a * (1.0 - a));
}

float sdBox(vec2 q, float h, float r) {
    vec2 w = abs(q) - vec2(h - r);
    return length(max(w, 0.0)) + min(max(w.x, w.y), 0.0) - r;
}

// the squarish metric of the entrance's front
float met(vec2 v) {
    v = abs(v);
    v *= v;
    return sqrt(sqrt(v.x * v.x + v.y * v.y)) ;
}

// ---- the entrance, as a function of a cap's centre c (item px): (pr, ent). The caps rise in a front leaving the popup's outline.
// `presence` here is LINEAR time (VeilKeycaps undoes the lock's OutCubic, or the front would cross the screen in the first tenth);
// `grade2.z` is the farthest corner's distance in the metric. The clear: each cap goes down when the accepted ring has passed it by
// the trail (clearFront.z is already that much behind the ring).
vec2 entranceOf(vec2 c) {
    float pr = 1.0;
    float ent = 1.0;
    if (presence < 1.0) {
        float S = light.w;
        float rn = met(max(abs(c - rect.xy) - rect.zw, vec2(0.0))) / max(grade2.z, 1.0);   // from the popup's outline
        pr = clamp(presence * (1.0 + S) - S * rn, 0.0, 1.0);
    }
    if (clearFront.w > 0.0)
        pr = min(pr, 1.0 - clamp((clearFront.z - length(c - clearFront.xy) / po.y) / clearFront.w, 0.0, 1.0));
    if (pr < 1.0) {
        float xx = pr - 1.0;
        ent = max(1.0 + (grade2.y + 1.0) * xx * xx * xx + grade2.y * xx * xx, 0.0);
    }
    return vec2(pr, ent);
}

// The shadow the cap `off` cells away (-1 / 0 in each axis: the caps up and to the left, the only ones the shadow's direction can
// reach, and this one) throws on the ground at q (device px from THIS cap's centre), in THAT cap's own state: its depth, its rise,
// read from the same linear field at ITS centre. A shadow cast with THIS cap's state for every neighbour (one distance
// to a wrapped point serving all four) stops dead at the cell's edge where neighbours differ -- a wave's slope, the entrance's front,
// the clear -- in the middle of the margin between two keys, and goes on in the next cell as another height.
float shadowOf(vec2 off, vec2 q, float P, vec2 cc) {
    vec2 cn = cc + off * P / dscale;                                                  // that cap's centre, item px (cc: this cap's)
    vec2 dn = cn - qt_TexCoord0 * size;
    float depn = clamp(vA.x + vGx.x * dn.x + vGy.x * dn.y, -0.3, 1.0);
    float entn = entranceOf(cn).y;
    float hn = 0.5 * P * grid.y * entn * (1.0 - srcA.w * max(depn, 0.0));
    float z = clamp((1.0 - depn) * min(entn, 1.0), 0.0, 1.4);
    float sp = max(grid.w * (0.35 + 0.65 * z), 1.0);
    vec2 qs = q - off * P + light.xy * (srcA.z * z);                                  // light.xy is toward the light: the shadow goes the other way
    float ds = sdBox(qs, hn, grid.z * hn);
    float a = 1.0 - clamp(ds / sp, 0.0, 1.0);
    return a * a * (0.45 + 0.55 * min(z, 1.0));
}

void main() {
    vec2 pd = qt_TexCoord0 * size * dscale;
    float P = grid.x;
    vec2 cell = floor(pd / P);
    vec2 q = pd - (cell + 0.5) * P;
    float px = max(length(vec2(dFdx(pd.x), dFdy(pd.x))), 1e-3);   // before any branch: derivatives
    vec2 cc = (cell + 0.5) * P / dscale;                          // the cap's centre, item px

    // ---- the entrance: caps rise in a front leaving the popup's outline (entranceOf) ---------------
    vec2 pe = entranceOf(cc);
    float pr = pe.x;
    float ent = pe.y;

    // ---- this cap's state, and its neighbours' (linear in the cell offset) ---------------------
    vec2 dcen = cc - qt_TexCoord0 * size;
    vec4 f = vA + vGx * dcen.x + vGy * dcen.y;
    float dep = clamp(f.x, -0.3, 1.0);
    float full = 0.5 * P * grid.y;
    float hh = full * ent * (1.0 - srcA.w * max(dep, 0.0));
    float rr = grid.z * hh;
    float d0 = sdBox(q, hh, rr);                       // < 0 inside the cap
    float bw = light.z;

    float tintA = opaque > 0.5 ? 1.0 : grade.x;
    float gapA = opaque > 0.5 ? 1.0 : grade.y * smoothstep(0.0, 0.2, pr);
    vec2 Ld = light.xy;                                // toward the light
    vec2 Sd = -Ld;                                     // the shadow's way

    vec4 acc;
    float cover = clamp(-d0 / px, 0.0, 1.0);
    if (d0 < -(bw * 3.0) && hh > 4.0) {
        acc = vec4(0.0);                                // refined below: deep inside a cap
    } else {
        // the ground and the shadows falling on it
        vec3 gcol = mix(cFloor.rgb, cMid.rgb, 0.4);
        vec4 accG = vec4(gcol * gapA, gapA);
        // The shadow on the ground is the union of this cap's and of the three up and to the left of it, each in its own state
        // (shadowOf). Only the sign of the shadow's way picks the side the neighbours are on.
        vec2 nb = vec2(Sd.x >= 0.0 ? -1.0 : 1.0, Sd.y >= 0.0 ? -1.0 : 1.0);
        float shA = shadowOf(vec2(0.0), q, P, cc);
        shA = max(shA, shadowOf(vec2(nb.x, 0.0), q, P, cc));
        shA = max(shA, shadowOf(vec2(0.0, nb.y), q, P, cc));
        shA = max(shA, shadowOf(nb, q, P, cc));
        accG = over(accG, cShadow.rgb, clamp(shA * grade.z, 0.0, 1.0) * gapA);
        acc = accG;
    }

    if (cover > 0.0) {
        float err = clamp(f.y, 0.0, 1.0);
        float okt = clamp(f.z, 0.0, 1.0);
        float sheen = clamp(f.w, 0.0, 1.0);
        float dn_ = max(dep, 0.0);
        // the top plate: lit from above-left, a touch darker away from the light, darker pressed
        float tl = dot(q / max(hh, 1.0), Ld);
        vec3 body = cCap.rgb;
        body = mix(body, cBevel.rgb, 0.35 * max(tl, 0.0) * grade.w * (0.75 + 0.25 * (1.0 - dn_)));
        body = mix(body, cMid.rgb, 0.22 * max(-tl, 0.0) + 0.12 * dn_);
        body = mix(body, cBevel.rgb, sheen * 0.5 * grade.w);
        // DETAIL, dish: the cap top is concave, as a real keycap's is -- its inner edge on the light's
        // side lies in shadow, the far side catches the light
        float din0 = -d0;
        if (detail.x > 0.0 && din0 < 0.4 * hh) {
            float ring = 1.0 - smoothstep(0.0, 0.4 * hh, din0);
            body = mix(body, cMid.rgb, 0.4 * detail.x * ring * max(tl, 0.0));
            body = mix(body, cBevel.rgb, 0.5 * detail.x * ring * max(-tl, 0.0) * grade.w);
        }
        body = mix(body, cOk.rgb, okt * 0.45);
        body = mix(body, cError.rgb, err * 0.55);
        // DETAIL, legends: a few caps (one in five) carry a small engraved mark -- a dot, a dash, a
        // plus or a ring -- carved into the top: a shade on the light's side, a lit lip on the other
        vec2 g = q / max(hh, 1.0);
        if (detail.y > 0.0 && abs(g.x) < 0.5 && abs(g.y) < 0.5) {
            float h = fract(dot(cell, vec2(0.7548776662, 0.5698402910)));   // the R2 sequence: no transcendental
            if (h < 0.2) {
                float ty = floor(h * 20.0);                 // 0..3
                vec2 e1 = g;
                vec2 e2 = g - Sd * (2.0 / max(hh, 1.0));    // the lip: the mark shifted down-right
                float d1, d2;
                if (ty < 0.5) { d1 = length(e1) - 0.2; d2 = length(e2) - 0.2; }
                else if (ty < 1.5) { d1 = max(abs(e1.x) - 0.3, abs(e1.y) - 0.07); d2 = max(abs(e2.x) - 0.3, abs(e2.y) - 0.07); }
                else if (ty < 2.5) { d1 = min(max(abs(e1.x) - 0.3, abs(e1.y) - 0.07), max(abs(e1.x) - 0.07, abs(e1.y) - 0.3));
                                     d2 = min(max(abs(e2.x) - 0.3, abs(e2.y) - 0.07), max(abs(e2.x) - 0.07, abs(e2.y) - 0.3)); }
                else { d1 = abs(length(e1) - 0.22) - 0.06; d2 = abs(length(e2) - 0.22) - 0.06; }
                float c1 = clamp(-d1 * hh / px, 0.0, 1.0);
                float c2 = clamp(-d2 * hh / px, 0.0, 1.0) * (1.0 - c1);
                body = mix(body, cBevel.rgb, 0.8 * c2 * detail.y * grade.w);
                body = mix(body, cMid.rgb, 0.55 * c1 * detail.y * (1.0 - 0.5 * ent * 0.0));
            }
        }
        vec4 accS = vec4(body * tintA, tintA);
        // the rim (only within reach of the edge): its normal from the box's own distance field
        float din = -d0;
        if (din < bw * 1.8) {
            vec2 w = abs(q) - vec2(hh - rr);
            vec2 nn = max(w, vec2(0.0));
            vec2 n = (nn.x + nn.y) > 0.0 ? normalize(nn) : (w.x > w.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
            n *= sign(q + vec2(1e-4));
            float facing = dot(n, Ld);                      // > 0: the edge toward the light
            float hl = (1.0 - smoothstep(0.0, bw, din)) * smoothstep(-0.1, 0.8, facing) * (1.0 - 0.3 * dn_);
            accS = over(accS, cBevel.rgb, hl * grade.w * tintA);
            float sd = (1.0 - smoothstep(0.0, bw * 1.8, din)) * smoothstep(-0.1, 0.8, -facing) * 0.4;
            accS = over(accS, cMid.rgb, sd * tintA);
        }
        acc = mix(acc, accS, cover);
    }

    // dither against banding: interleaved gradient noise (no transcendental)
    float dn = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715)))) - 0.5;
    acc.rgb += dn * acc.a / 255.0;
    fragColor = acc * qt_Opacity;
}
