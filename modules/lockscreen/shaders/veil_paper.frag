#version 440
// =============================================================================
// veil_paper.frag -- PAPER LAYERS: a bed and four sheets of the shell's material, cut
// along the contours of one soft field, stacked with real shadows between them.
//
// Bottom to top: the bed (a deep wash over the desktop), then sheets 1..4. Each sheet is
// "inside" where its field d > 0; d comes from the vertex stage (veil_paper.vert) and is
// rebuilt per pixel as A + 0.5 (G.p - C), so sd = d / |G| is the distance to the edge in
// item px, and -G / |G| the edge's outward normal. A sheet is drawn as the shell draws
// a raised box: a soft drop shadow on what lies below (the light is above and to the
// left, so it falls down and to the right; the sheet's own shadow shifted by `drop` is
// the same field read at an offset), a bevel highlight along its edges that face the light
// and a hairline of shade along those that face away, and the plateau colour between,
// deeper toward the bottom. A ripple's slope shades a sheet's face and swells its edge.
//
// ENTRANCE (presence < 1): every sheet is also cut by a front -- a disc of radius R_j
// round the popup and its bar -- that sweeps outward and ends at the screen's corner;
// sheet j starts a little after j - 1, so the sheets are laid down one over the last,
// each with the edge, shadow and bevel of a sheet of paper, never a fade.
//
// Pixel size from a LINEAR coordinate (dFdx of p.x), never from a composed distance.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 1) in vec4 fA;
layout(location = 2) in vec4 fGx;
layout(location = 3) in vec4 fGy;
layout(location = 4) in vec4 fC;
layout(location = 5) in vec4 fH;
layout(location = 6) in vec4 fS;
layout(location = 0) out vec4 fragColor;

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


const vec2 LIGHT = vec2(-0.5145, -0.8575);   // toward the light, y down

float rbox(vec2 p, vec4 r4, float r, out vec2 n) {
    vec2 c = 0.5 * (r4.xy + r4.zw);
    vec2 h = 0.5 * (r4.zw - r4.xy);
    vec2 pc = p - c;
    vec2 q = abs(pc) - h + r;
    float d = min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
    vec2 s = vec2(pc.x < 0.0 ? -1.0 : 1.0, pc.y < 0.0 ? -1.0 : 1.0);
    vec2 g = (q.x > 0.0 || q.y > 0.0) ? normalize(max(q, 0.0)) : (q.x > q.y ? vec2(1.0, 0.0) : vec2(0.0, 1.0));
    n = g * s;
    return d;
}

float px;       // item px per device pixel

// The distance to a box, squared (a bound for the rounded one that lies inside it).
float boxD2(vec2 p, vec4 r4) {
    vec2 q = max(abs(p - 0.5 * (r4.xy + r4.zw)) - 0.5 * (r4.zw - r4.xy), 0.0);
    return dot(q, q);
}

// What a shadow of an edge (inside = sd > 0) is at a pixel: 1 at and under the edge,
// falling to 0 over `spread` outside it.
float shadowFall(float sd, float spread) {
    float x = -sd / max(spread, 1.0);
    float t = clamp((x + 0.3) / 1.3, 0.0, 1.0);
    float s = 1.0 - t * t * (3.0 - 2.0 * t);
    return s * s;
}

// One sheet over `pm` (premultiplied). sd: signed distance to its edge (inside positive),
// n: the edge's outward normal, shV: the shadow it casts, from the vertex stage (fragSh: work it
// out here from sd instead), slope: the ripple's slope along the light, col: its plateau,
void layer(inout vec4 pm, float sd, vec2 n, float shV, float slope, vec3 col, float alpha, bool fragSh) {
    float u = geo.y;
    float bw = max(look1.w * u, 1.0);
    float fh = clamp(slope * look2.y, -1.0, 1.0);
    // Deep inside it is the plain plateau (shaded by a ripple under it): most of the screen.
    if (sd > bw + px + 1.0) {
        col = mix(col, cHi.rgb, max(fh, 0.0));
        col = mix(col, cLo.rgb, max(-fh, 0.0) * 0.8);
        pm = pm * (1.0 - alpha) + vec4(col * alpha, alpha);
        return;
    }
    // The shadow on what lies below: the vertex stage's, or -- for the bed, whose entrance
    // front the vertex stage does not know -- worked out here from the edge.
    float sh = shV;
    if (fragSh) {
        float lf = 1.0 + look2.z * clamp(fxv.y, 0.0, 2.0);
        sh = look1.y * shadowFall(sd + dot(n, -LIGHT * look1.z * u * lf), look1.x * u * lf);
    }
    // Outside the edge by more than a pixel: the shadow alone (the sheet is not here).
    if (sd < -px - 1.0) {
        if (sd > -6.0 * u)
            sh += 0.5 * look1.y * shadowFall(sd, 5.0 * u);
        sh = min(sh, 0.95);
        pm = pm * (1.0 - sh) + vec4(cShc.rgb * sh, sh);
        return;
    }
    float cov = clamp(0.5 + sd / px, 0.0, 1.0);
    sh += 0.5 * look1.y * shadowFall(sd, 5.0 * u);              // contact
    sh = min(sh, 0.95) * (1.0 - cov);
    pm = pm * (1.0 - sh) + vec4(cShc.rgb * sh, sh);

    // the sheet: plateau, then the bevel on the edges that face the light and the hairline of shade
    // on the ones that face away, then the ripple's shading of its face
    float rim = 1.0 - smoothstep(0.0, bw, sd);
    float lit = dot(n, LIGHT);
    float hi = rim * max(lit, 0.0) * look2.x;
    float lo = (1.0 - smoothstep(0.0, 1.2 * px + 0.6 * u, sd)) * max(-lit, 0.0) * 0.55;
    col = mix(col, cHi.rgb, clamp(hi + max(fh, 0.0), 0.0, 1.0));
    col = mix(col, cLo.rgb, clamp(lo + max(-fh, 0.0) * 0.8, 0.0, 1.0));
    float a = mix(alpha, 1.0, clamp(hi + lo, 0.0, 1.0)) * cov;
    pm = pm * (1.0 - a) + vec4(col * a, a);
}


void main() {
    vec2 p = qt_TexCoord0 * size;
    px = max(length(vec2(dFdx(p.x), dFdy(p.x))), 1e-4);
    vec2 pr = p - 0.5 * size;

    // the sheets' fields, rebuilt between the vertices
    vec4 d = fA + 0.5 * (fGx * pr.x + fGy * pr.y - fC);
    vec4 ig = inversesqrt(max(fGx * fGx + fGy * fGy, vec4(geo.z * geo.z)));
    vec4 sd = d * ig;

    // the shell, and (while the veil is arriving) the fronts. Far from the popup and the bar
    // (past its shadow's reach) and at rest there is nothing of either here.
    float shReach = look1.x * geo.y * (1.0 + look2.z * 2.0) + look1.z * geo.y * 3.0 + 4.0;
    vec2 nS = vec2(0.0, 1.0);
    float dS = 1e4;
    if (prs.x < 0.9999 || min(boxD2(p, shell), boxD2(p, bar)) < shReach * shReach) {
        vec2 nS1, nS2;
        float dS1 = rbox(p, shell, rad.x, nS1);
        float dS2 = rbox(p, bar, rad.y, nS2);
        dS = min(dS1, dS2);
        nS = dS1 < dS2 ? nS1 : nS2;
    }

    // the bed is laid down by a front out of the shell; the sheets arrive by their levels (the
    // vertex stage), the lowest first -- the peel of an accepted password, played backwards
    float sdB = prs.x < 0.9999 ? frontBed.x - dS : 1e4;
    float aB = mix(alphas.x, 1.0, prs.y);
    float aS = mix(alphas.y, 1.0, prs.y);

    vec4 pm = vec4(0.0);
    if (prs.x < 0.9999)
        layer(pm, sdB, nS, 0.0, 0.0, colB.rgb, aB, true);
    else
        pm = vec4(colB.rgb * aB, aB);               // at rest the bed is the plain plateau under everything: what layer() makes of it

    // sheets 1..4, a loop so that one sheet's worth of registers is live at a time
    for (int j = 0; j < 4; j++) {
        vec2 nj = vec2(-fGx[j], -fGy[j]) * ig[j];
        vec3 cj = j == 0 ? col1.rgb : (j == 1 ? col2.rgb : (j == 2 ? col3.rgb : col4.rgb));
        layer(pm, sd[j], nj, fH[j], fS[j], cj, aS, false);
    }

    // the popup (and its bar) stands proud of the top sheet
    // (past shReach -- dS is 1e4 where the shell is not even looked for -- the shadow is exactly 0: nothing to work out)
    if (look2.w > 0.0 && dS < shReach) {
        float lf = 1.0 + look2.z * clamp(fxv.y, 0.0, 2.0);
        vec2 off = -LIGHT * look1.z * geo.y * lf;
        float sh = look2.w * look1.y * shadowFall(-dS + dot(nS, off), look1.x * geo.y * lf);
        sh *= step(0.0, dS);
        pm = pm * (1.0 - sh) + vec4(cShc.rgb * sh, sh);
    }
    fragColor = pm * qt_Opacity;
}
