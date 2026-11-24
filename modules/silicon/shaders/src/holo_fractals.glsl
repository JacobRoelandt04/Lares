// =============================================================================
// holo_fractals.glsl -- the GPU die's holograms: three fractals ray-marched in a volume above the
// die (spliced into silicon_holo.frag).
//
//   0 SIERPINSKI TETRAHEDRON (Smart)   1 MENGER SPONGE (Hybrid)   2 MANDELBULB (dGPU-only)
//
// Each is a distance estimate in its own units, spun slowly about the vertical (a fixed tilt, so the
// spin shows depth). The picture is not a lit solid: the view ray is walked through the whole volume
// and collects light from every surface it passes within a hair of -- a THIN SHELL integrated along
// the ray. That is what makes it a hologram: front and back surfaces both show (see-through), a ray
// grazing a face stays in its shell longest and so the silhouettes and edges burn brighter (the
// Fresnel rim, for free), and nothing needs a normal. Steps are adaptive (small near a surface, long
// in the open), capped at 64; pixels outside the volume's bounding sphere do nothing at all.
// =============================================================================

const float FR_RB = 18.5;                // the volume's bounding sphere, mm
int gLevels;                             // how many levels / iterations the fractal is built to (set from the pixel size)

float deSierp(vec3 p) {                  // canonical frame: vertices (+-1, +-1, +-1), circumradius sqrt(3)
    float sc = 1.0;
    for (int i = 0; i < 5; i++) {
        if (i >= gLevels)
            break;
        vec3 c = vec3(1.0, 1.0, 1.0);
        float m = dot(p, c);
        float m2 = dot(p, vec3(-1.0, -1.0, 1.0));
        if (m2 > m) {
            m = m2;
            c = vec3(-1.0, -1.0, 1.0);
        }
        m2 = dot(p, vec3(1.0, -1.0, -1.0));
        if (m2 > m) {
            m = m2;
            c = vec3(1.0, -1.0, -1.0);
        }
        m2 = dot(p, vec3(-1.0, 1.0, -1.0));
        if (m2 > m) {
            m = m2;
            c = vec3(-1.0, 1.0, -1.0);
        }
        p = 2.0 * p - c;
        sc *= 2.0;
    }
    float dd = max(max(-(p.x + p.y + p.z), p.x + p.y - p.z), max(-p.x + p.y + p.z, p.x - p.y + p.z));
    return (dd - 1.0) / SQ3 / sc;
}

float deMenger(vec3 p) {                 // a cube of half size 1, three levels of holes
    vec3 q = abs(p) - vec3(1.0);
    float d = length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
    float s = 1.0;
    for (int m = 0; m < 3; m++) {
        if (m >= gLevels)
            break;
        vec3 a = mod(p * s, 2.0) - 1.0;
        s *= 3.0;
        vec3 r = abs(1.0 - 3.0 * abs(a));
        float da = max(r.x, r.y);
        float db = max(r.y, r.z);
        float dc = max(r.z, r.x);
        float c = (min(da, min(db, dc)) - 1.0) / s;
        d = max(d, c);
    }
    return d;
}

float deBulb(vec3 p, float pw) {         // the Mandelbulb, its pole along y
    vec3 z = p;
    float dr = 1.0;
    float r = 0.0;
    for (int i = 0; i < 6; i++) {
        if (i >= gLevels)
            break;
        r = length(z);
        if (r > 2.0)
            break;
        float theta = acos(clamp(z.y / r, -1.0, 1.0));
        float phi = atan(z.z, z.x);
        dr = pow(r, pw - 1.0) * pw * dr + 1.0;
        float zr = pow(r, pw);
        theta *= pw;
        phi *= pw;
        z = zr * vec3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi)) + p;
    }
    return 0.5 * log(r) * r / dr;
}

float mapFrac(int sym, vec3 p, float pw) {
    if (sym == 0)
        return deSierp(p);
    if (sym == 1)
        return deMenger(p);
    return deBulb(p, pw);
}

vec3 rotX(vec3 v, float a) {
    float c = cos(a), s = sin(a);
    return vec3(v.x, c * v.y - s * v.z, s * v.y + c * v.z);
}
vec3 rotY(vec3 v, float a) {
    float c = cos(a), s = sin(a);
    return vec3(c * v.x + s * v.z, v.y, -s * v.x + c * v.z);
}
// the upright frame (the apex along +y) -> the canonical tetrahedron frame
vec3 tetraFrame(vec3 v) {
    return v.x * vec3(0.70710678, -0.70710678, 0.0) + v.y * vec3(0.57735027) + v.z * vec3(-0.40824829, -0.40824829, 0.81649658);
}

// Sphere-trace along o + d t for up to `len` units: the distance of the first surface, or -1; `hmin`
// is the ray's nearest approach to the fractal (the halo around the silhouette).
float traceFrac(int sym, vec3 o, vec3 d, float len, float pw, float eps, float relax, out float hmin) {
    float t = 0.0;
    float h = 1e3;
    hmin = 1e3;
    for (int i = 0; i < 56; i++) {
        h = mapFrac(sym, o + d * t, pw);
        hmin = min(hmin, h);
        if (h < eps)
            return t;
        t += h * relax;
        if (t > len)
            return -1.0;
    }
    // out of steps right next to a surface (a grazing ray): that is a silhouette pixel, not a miss
    return h < eps * 8.0 ? t : -1.0;
}

// The surface normal by four taps; `edge` is how far the gradient falls short of a unit vector (the
// two faces of an edge cancel inside one tap spacing): 0 on a face, up to 1 on a sharp edge.
vec3 fracNormal(int sym, vec3 p, float pw, float e, out float edge) {
    vec2 k = vec2(1.0, -1.0);
    vec3 g = k.xyy * mapFrac(sym, p + k.xyy * e, pw) + k.yyx * mapFrac(sym, p + k.yyx * e, pw)
           + k.yxy * mapFrac(sym, p + k.yxy * e, pw) + k.xxx * mapFrac(sym, p + k.xxx * e, pw);
    edge = sym == 2 ? 0.0 : clamp(1.0 - length(g) / (4.0 * e), 0.0, 1.0);
    return normalize(g);
}

// horizontal slice lines at constant world height: they wrap round the form, so the 3D shows
float contour(float y, float spacing) {
    return pow(1.0 - abs(2.0 * fract(y / spacing - phA.x) - 1.0), 3.5);
}

// One sample of the fractal at a screen point: premultiplied, ink-coloured. `px` seeds nothing;
// the front and the back surface of the volume are found by two sphere traces (the second from the
// far side), shaded by Fresnel and the slice lines, and stacked: that is the see-through.
vec4 fractalSample(vec2 scr, vec2 px, int sym, vec3 ink) {
    vec3 ro = rayOrigin(scr);
    vec3 rd = -CAM_C;
    vec3 C = anchorP.xyz + vec3(0.0, plane.y + plane.z * 0.5, 0.0);
    vec3 oc = ro - C;
    float b = dot(oc, rd);
    float disc = b * b - (dot(oc, oc) - FR_RB * FR_RB);
    if (disc <= 0.0)
        return vec4(0.0);
    float sq = sqrt(disc);
    float tn = -b - sq;
    float tf = -b + sq;
    float scl = sym == 2 ? 14.0 : 10.2;                   // mm per fractal unit
    float spin = TAU * phC.z;
    vec3 o = rotY(oc + rd * tn, -spin) / scl;
    vec3 d = rotY(rd, -spin);
    if (sym == 0) {
        o = tetraFrame(o);
        d = tetraFrame(d);
    }
    float len = (tf - tn) / scl;
    // build only the levels that are still wider than ~5 device px
    float pxU = 1.0 / (view.z * max(quad.z, 1.0) * scl);
    if (sym == 0)
        gLevels = int(clamp(floor(log2(1.732 / (6.0 * pxU))), 2.0, 5.0));
    else if (sym == 1)
        gLevels = int(clamp(floor(log(2.0 / (6.0 * pxU)) / 1.0986), 1.0, 3.0));
    else
        gLevels = pxU > 0.02 ? 4 : 5;
    float pw = 8.0 + 0.9 * sin(TAU * phC.z * 2.0);       // the bulb breathes, slowly
    float eps = (0.0012 + 0.35 / (view.z * max(quad.z, 1.0))) / scl;
    float relax = sym == 2 ? 0.65 : 0.9;
    float hm1;
    float t1 = traceFrac(sym, o, d, len, pw, eps, relax, hm1);
    float rho = sqrt(max(dot(oc, oc) - b * b, 0.0)) / FR_RB;                 // 0 at the centre, 1 at the sphere's edge
    float halo = exp(-hm1 * scl / 1.3) * (1.0 - smoothstep(0.70, 0.98, rho));
    vec4 acc = inkOver(vec4(0.0), ink, halo * 0.30);
    float cs = sym == 2 ? 2.0 : 1.4;                       // slice spacing, mm
    if (t1 >= 0.0) {
        float e1;
        vec3 n1 = fracNormal(sym, o + d * t1, pw, eps * 2.5, e1);
        float f1 = pow(1.0 - abs(dot(n1, d)), sym == 2 ? 1.3 : 1.7);
        float y1 = ro.y + rd.y * (tn + t1 * scl) - C.y;
        // a top light fixed in the view, so the form reads: the normal back in the world frame
        vec3 nw = sym == 0 ? vec3(dot(n1, vec3(0.70710678, -0.70710678, 0.0)), dot(n1, vec3(0.57735027)), dot(n1, vec3(-0.40824829, -0.40824829, 0.81649658))) : n1;
        nw = rotY(nw, spin);
        float lam = 0.5 + 0.5 * nw.y;
        // the surface behind it, from the far side
        float hm2;
        float e2;
        vec3 o2 = o + d * len;
        float t2 = traceFrac(sym, o2, -d, len, pw, eps, relax, hm2);
        if (t2 >= 0.0) {
            vec3 n2 = fracNormal(sym, o2 - d * t2, pw, eps * 2.5, e2);
            float f2 = pow(1.0 - abs(dot(n2, d)), 1.7);
            float y2 = ro.y + rd.y * (tn + (len - t2) * scl) - C.y;
            float a2 = (0.06 + 0.40 * f2 + 0.14 * contour(y2, cs) + 0.30 * smoothstep(0.08, 0.35, e2)) * 0.75;
            acc = inkOver(acc, hueRot(ink, -0.30) * 0.9, a2);
        }
        float lamK = sym == 2 ? 0.60 : 0.40;                       // the bulb's smooth form needs more light to read
        float a1 = (0.10 + 0.62 * f1 + (sym == 2 ? 0.34 : 0.24) * contour(y1, cs) + 0.55 * smoothstep(0.08, 0.35, e1)) * (1.0 - lamK * 0.5 + lamK * lam);
        acc = inkOver(acc, hueRot(ink, 0.22), a1);
    }
    return acc;
}

// THE ARMILLARY. Three thin rings turn about the volume's centre (HoloLayer hands over their screen frames: X, Y in silicon_holo.frag.in): the
// equator, which carries a dial of 48 ticks, a hoop that wobbles about the vertical (it precesses once in 25 s), and a meridian ring that turns about it. Each
// carries a bead (a small moon). A ring is seen as the ellipse x^2 + y^2 = 1 in its own frame (HoloLayer._ring says how x and y come from the pixel; the minor axis never
// reaches 0, so a ring turning through edge-on stays one smooth thin ellipse): the half nearer the viewer is drawn IN FRONT of the fractal and the far half BEHIND it, so
// the form sits inside the rings. Returns the coverages (line behind, line in front, bead behind, bead in front).
// Everything that does not depend on the pixel is worked out once a frame by HoloLayer: X the ring's major axis (unit) and its minor axis over the (floored) minor length,
// Y: 1/R, the near half's eased sign, the bead's near weight, the turn; `bp` the bead's screen place.
vec4 orbRing(vec2 q, vec4 X, vec4 Y, vec2 bp, float ticks) {
    float x = dot(q, X.xy) * Y.x;
    float y = dot(q, X.zw) * Y.x;
    float r = max(length(vec2(x, y)), 1e-3);
    float d = (r - 1.0) / max(length(x * X.xy + y * X.zw) * Y.x / r, 1e-3);     // mm to the ring (the gradient of r, normalised)
    // That first-order distance fails at the tips of a thin ellipse, where the curve turns sharply -- it reads pixels up to 0.15 R past
    // each tip as ON the line (the reach grows as 1 / b^2), so the ring would lengthen by a fifth just before edge-on and shrink back. The ellipse
    // lies inside its box (R along the major axis, R b along the minor, b = 1 / |X.zw|), so no pixel is nearer to it than to that box: the
    // distance is at least the box's.
    float db = length(vec2(max(abs(x) - 1.0, 0.0), max(abs(y) - 1.0, 0.0) / length(X.zw))) / Y.x;
    d = max(abs(d), db);
    float fw = smoothstep(-0.12, 0.12, -y * Y.y);                              // 1 on the near half (sin a < 0, y = Y.y sin a: Y.y is 0 at edge-on, where the halves blend)
    float line = strokeCov(d, 0.19) * 0.55;
    if (ticks > 0.5) {
        float tk = fract((atan(y, x) - TAU * Y.w) * (48.0 / TAU));
        line = max(line, (1.0 - smoothstep(0.55, 1.1, d)) * (1.0 - smoothstep(0.10, 0.22, abs(tk - 0.5))) * 0.55);
    }
    float bl = length(q - bp);
    float bead = fillCov(bl - 0.75) * 0.95 + exp(-bl * bl / 2.2) * 0.35;
    return vec4(line * (1.0 - fw), line * fw, bead * (1.0 - Y.z), bead * Y.z);
}

vec4 holoGpu(vec2 scr, vec2 px) {
    float hp = look.z;
    float energy = targetP.w;
    vec3 A = anchorP.xyz;
    vec2 uv = vec2(scr.x - dot(A, CAM_R), (scr.y - dot(A, CAM_U)) / PLANE_V);
    Glitch g = glitchOf(uv, look.x, anchorP.w);
    vec2 scrG = scr + vec2(g.uv.x - uv.x, (g.uv.y - uv.y) * PLANE_V);
    int sym = int((g.next > 0.5 ? look2.x : look.w) + 0.5);
    vec3 cm = mix(colA.rgb, colB.rgb, g.colMix);
    vec3 body = bodyOf(cm);
    vec3 ink = inkOf(cm);
    vec4 img = fractalSample(scrG, px, sym, ink);
    // the chromatic split costs two more marches: only while the picture is breaking up or powering on
    float split = 0.34 + 2.0 * g.amp + 1.4 * (1.0 - hp);
    if (g.amp > 0.02 || hp < 0.98) {
        vec4 gp = fractalSample(scrG + vec2(split, 0.0), px, sym, hueRot(ink, 0.95));
        vec4 gm = fractalSample(scrG - vec2(split, 0.0), px, sym, hueRot(ink, -0.95));
        img = over(img, (gp + gm) * 0.22);
    }
    if (fxOn.w > 0.5) {
        vec3 Cc = A + vec3(0.0, plane.y + plane.z * 0.5, 0.0);
        vec2 q = scr - vec2(dot(Cc, CAM_R), dot(Cc, CAM_U));
        vec4 orb = max(orbRing(q, orbX0, orbY0, orbB.xy, 1.0), max(orbRing(q, orbX1, orbY1, orbB.zw, 0.0), orbRing(q, orbX2, orbY2, orbC.xy, 0.0)));
        vec3 bc = mix(ink, vec3(1.0), 0.45 * gDark);
        img = over(inkOver(inkOver(vec4(0.0), ink, orb.y), bc, orb.w), over(img, inkOver(inkOver(vec4(0.0), ink, orb.x * 0.8), bc, orb.z * 0.8)));
    }
    float gain = (0.90 + 0.20 * energy) * mix(0.40, 1.0, colA.a);
    img *= g.keep * flicker() * powerCurve(hp) * gain;
    // the projector: a cone from the die up into the volume, the lens on the die, a ring where the volume begins
    vec3 ro = rayOrigin(scr);
    vec3 rd = -CAM_C;
    float hTop = plane.y + plane.z * 0.5 + 4.0;
    float haze = 1.0 - exp(-coneHaze(ro, rd, A, hTop, 1.8, 0.40) * 0.017);
    float lens = lensGlow(ro, rd, A, LENS_GPU, 0.55, 0.8);
    float ring = lensGlow(ro, rd, A + vec3(0.0, plane.y - 1.0, 0.0), LENS_GPU_RING, 0.0, 0.7);
    vec4 beam = inkOver(vec4(0.0), body, haze * mix(0.85, 0.55, gDark) * plane.w);
    beam = inkOver(beam, ink, lens * 0.55 + ring * 0.35);
    beam *= flicker() * powerCurve(min(hp * 1.25, 1.0)) * anchorP.w;
    vec4 brk = inkOver(vec4(0.0), ink, cornerBrackets(vec2(uv.x, uv.y - plane.y - plane.z * 0.5)) * look2.y);
    brk *= powerCurve(hp) * anchorP.w;
    return over(img, over(brk, beam));
}
