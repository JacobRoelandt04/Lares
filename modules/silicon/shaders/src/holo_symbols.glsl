// =============================================================================
// holo_symbols.glsl -- the CPU's three symbols as 2D art on the hologram plane (spliced into
// silicon_holo.frag).
//
//   0 LEAF (Quiet)  1 SCALES (Balanced)  2 SHOCK (Performance)
//
// Each is drawn in the plane's own millimetres (the symbol centred on the origin, about +-19 mm),
// returning a Sig: a signed distance to its silhouette plus separate layers for thin strokes, the
// brightest strokes, the body and sparks. holoCpu() dresses a Sig with the hologram treatment: the
// body is translucent, the outline bright, the rim glows, and the whole thing is sampled three times
// for the chromatic split. Each has a small idle motion whose tempo is the scene clock's (the host
// speeds it with the load: phB / phC arrive already integrated).
// =============================================================================

struct Sig {
    float d;       // signed distance to the silhouette, mm (< 0 inside)
    float ink;     // 0..1 thin strokes (barbs, veins, chains, arcs)
    float core;    // 0..1 the brightest strokes (rachis, midrib, beam, bolt core)
    float fill;    // 0..1 body weight inside
    float spark;   // 0..1 sparks
};

// ---- LEAF -------------------------------------------------------------------------------------
// A leaf on a short stem: a smooth outline round at the base and drawn out to a point, a midrib, and
// veins that leave it toward the tip. Sap travels out along the veins.
float leafW(float t) {
    float tc = clamp(t, 0.0, 1.0);
    return 9.4 * pow(max(sin(PI * pow(tc, 0.78)), 0.0), 0.92);
}

Sig symLeaf(vec2 p, float sway, float bob, float sap) {
    vec2 foot = vec2(-6.0, -17.0);
    vec2 pp = rot(p - foot, -sway) + foot - vec2(0.0, bob);
    vec2 f = rot(pp - vec2(0.3, -1.2), -1.22);
    const float RC = 95.0;
    vec2 q = f - vec2(0.0, -RC);
    float s = RC * atan(q.x, q.y);
    float o = length(q) - RC;
    float t = (s + 19.0) / 38.0;
    float w = leafW(t) * (o > 0.0 ? 1.05 : 0.95);
    float dw = (leafW(t + 0.01) - leafW(t)) / (0.01 * 38.0) * (o > 0.0 ? 1.05 : 0.95);
    float dv = (abs(o) - w) * inversesqrt(1.0 + dw * dw);
    float dCap = max(s - 19.0, -19.0 - s);
    float d = length(max(vec2(dv, dCap), 0.0)) + min(max(dv, dCap), 0.0);
    // veins: level sets of a coordinate that sweeps toward the tip as it leaves the rib
    float cv = s - (0.92 * abs(o) + 0.018 * o * o) + 13.0;
    float vsp = 5.2;
    float kk = floor(cv / vsp + 0.5);
    float vd = abs(cv - kk * vsp) * 0.74;
    float vein = strokeCov(vd, 0.15);
    vein *= 1.0 - smoothstep(-2.6, -1.0, d);
    vein *= smoothstep(0.5, 1.3, abs(o));
    vein *= step(-0.5, kk) * step(kk, 5.5);
    float ph = fract(sap + hash11(kk * 1.7) * 0.8);
    float pulse = exp(-pow((abs(o) - ph * (w + 3.0)) / 1.7, 2.0));
    vein *= 0.72 + 0.95 * pulse;
    // the midrib and the stem
    float mw = mix(0.50, 0.24, smoothstep(-19.0, 14.0, s));
    float dm = max(abs(o) - mw, max(s - 16.5, -25.0 - s));
    float rib = fillCov(dm);
    float sapS = fract(sap) * 46.0 - 26.0;
    rib *= 0.78 + 0.5 * exp(-pow((s - sapS) / 3.0, 2.0));
    float fill = 0.55 + 0.45 * (1.0 - clamp(abs(o) / max(w, 0.3), 0.0, 1.0));
    return Sig(d, vein * 0.95, rib, fill, 0.0);
}

// A horizontal circle in the plane's own millimetres: the iso camera foreshortens it to 0.577 of its width on the screen, and the plane's up axis is stretched 1 / 0.8165
// on the screen, so 0.577 / 0.8165 of its width up the plane's v axis.
const float ISO_V = 0.70710678;
// the distance (first order: (k - 1) / |grad k|, exact on the axes) to the ellipse of semi axes `e` about the origin; < 0 inside
float sdEllipse(vec2 p, vec2 e) {
    float k = max(length(p / e), 1e-4);
    return (k - 1.0) * k / max(length(p / (e * e)), 1e-4);
}
// the silhouette of a drum standing on a horizontal circle of radius `r`, its bottom ellipse centred at height `yb` and `h` tall: the ellipse swept up a vertical segment
// (the distance to the segment's nearest point, then to the ellipse about it)
float sdDrum(vec2 p, float yb, float r, float h) {
    return sdEllipse(p - vec2(0.0, clamp(p.y, yb, yb + h)), vec2(r, ISO_V * r));
}

// ---- SCALES -----------------------------------------------------------------------------------
// A balance: foot, post, a beam that sways about its pivot, chains and two pans that hang from the
// beam's ends and swing a little behind it.
Sig symScales(vec2 p, float sway, float lag) {
    p.y += 0.6;
    const vec2 PIV = vec2(0.0, 12.5);
    const float ARM = 13.0;
    float ca = cos(sway), sa = sin(sway);
    vec2 e1 = PIV + ARM * vec2(-ca, -sa);
    vec2 e2 = PIV + ARM * vec2(ca, sa);
    float b1 = -0.55 * sway + 0.07 * sin(lag);
    float b2 = -0.55 * sway + 0.07 * sin(lag + 1.7);
    const float HANG = 14.0;
    vec2 c1 = e1 + HANG * vec2(sin(b1), -cos(b1));
    vec2 c2 = e2 + HANG * vec2(sin(b2), -cos(b2));
    float d = 1e3;
    // foot and post. With the plinth (fxPlinth) the foot is two round drums standing on the dial's centre, drawn as the iso camera sees a horizontal circle (below),
    // not two frontal slabs: base and dial then share one perspective
    bool plinth = fxOn.y > 0.5;
    float dCollar = 1e3;
    if (plinth) {
        d = min(d, sdDrum(p, -17.4, 6.4, 1.5));
        dCollar = sdDrum(p, -15.9, 3.4, 1.5);
        d = min(d, dCollar);
    } else {
        d = min(d, sdBox2(p - vec2(0.0, -17.8), vec2(8.0, 0.9)) - 0.3);
        d = min(d, sdBox2(p - vec2(0.0, -15.4), vec2(4.2, 1.2)) - 0.3);
    }
    d = min(d, sdBox2(p - vec2(0.0, -2.4), vec2(0.65, 12.4)));
    // beam
    float dBeam = sdSeg(p, e1, e2);
    d = min(d, dBeam - 0.55);
    d = min(d, length(p - e1) - 1.25);
    d = min(d, length(p - e2) - 1.25);
    // pans: the lower half of an ellipse under a rim bar, hanging in their own frames
    vec2 q1 = rot(p - c1, -b1);
    vec2 q2 = rot(p - c2, -b2);
    float bowl1 = max((length(q1 * vec2(1.0, 1.4)) - 6.3) / 1.25, q1.y);
    float bowl2 = max((length(q2 * vec2(1.0, 1.4)) - 6.3) / 1.25, q2.y);
    float rim1 = sdBox2(q1, vec2(7.0, 0.38));
    float rim2 = sdBox2(q2, vec2(7.0, 0.38));
    d = min(d, min(min(bowl1, rim1), min(bowl2, rim2)));
    // chains: two to each pan's rim ends
    vec2 r1a = c1 + rot(vec2(-6.6, 0.0), b1);
    vec2 r1b = c1 + rot(vec2(6.6, 0.0), b1);
    vec2 r2a = c2 + rot(vec2(-6.6, 0.0), b2);
    vec2 r2b = c2 + rot(vec2(6.6, 0.0), b2);
    float dch = min(min(sdSeg(p, e1, r1a), sdSeg(p, e1, r1b)), min(sdSeg(p, e2, r2a), sdSeg(p, e2, r2b)));
    float chains = strokeCov(dch, 0.17);
    // the pivot: a ring and a finial above it
    float ring = strokeCov(abs(length(p - PIV) - 2.0), 0.20);
    float fin = fillCov(length(p - vec2(0.0, 16.6)) - 0.95);
    float fin2 = strokeCov(abs(sdSeg(p, vec2(0.0, 14.5), vec2(0.0, 16.0))), 0.18);
    // the bright strokes: the beam's centre line and the post's
    float coreBeam = strokeCov(dBeam, 0.17);
    float corePost = strokeCov(abs(p.x), 0.17) * step(-14.0, p.y) * step(p.y, 10.5);
    float core = max(coreBeam, corePost);
    float fill = 0.55 + 0.45 * fillCov(min(bowl1, bowl2));
    float spark = 0.0;
    float ink = max(chains, max(ring, fin2)) * 0.85;
    if (plinth) {
        // A HORIZONTAL BASE. A round plinth lying flat under the foot, seen as the board's iso camera sees a horizontal circle:
        // the screen ellipse is 0.577 as tall as wide (the lens rings of the board and of every hologram's foot are the same ellipse), and the plane's own up axis is
        // stretched 1 / 0.8165 on the screen, so in the plane's millimetres it is 0.7071 as tall -- ISO_V below. A rim, an inner ring and a dial of 36 ticks that turns once in
        // 25 s (phD.z); a small bead keeps the time on the rim, once in 8 s. Its far half is fainter than the near one. Drawn in `ink` and `spark` only (not the chromatic ghosts'
        // outline). The drums' own rims are the front arcs of their top faces.
        const float PR = 11.5;
        vec2 P = vec2(p.x / PR, (p.y + 17.4) / (ISO_V * PR));
        float r = max(length(P), 1e-3);
        float kk = max(length(vec2(P.x, P.y / ISO_V)) / (PR * r), 1e-3);        // |grad r| in mm: the distance to the rim is (r - 1) / kk
        float near = 0.45 + 0.55 * (1.0 - smoothstep(-0.15, 0.15, P.y));
        float dr = (r - 1.0) / kk;
        float pl = strokeCov(abs(dr), 0.17) * 0.9;
        pl = max(pl, strokeCov(abs((r - 0.70) / kk), 0.12) * 0.5);
        float tk = fract(atan(P.y, P.x) * (36.0 / TAU) - 36.0 * phD.z);
        float band = smoothstep(0.80, 0.84, r) * (1.0 - smoothstep(0.93, 0.97, r));
        pl = max(pl, band * (1.0 - smoothstep(0.10, 0.20, abs(tk - 0.5))) * 0.8);
        pl = max(pl, fillCov(dr) * 0.14);
        ink = max(ink, pl * near * (1.0 + 0.5 * gDark));
        float rim1 = strokeCov(abs(sdEllipse(p - vec2(0.0, -15.9), vec2(6.4, ISO_V * 6.4))), 0.15) * step(p.y, -15.9);       // the front arc of the big drum's top face
        float rim2 = strokeCov(abs(sdEllipse(p - vec2(0.0, -14.4), vec2(3.4, ISO_V * 3.4))), 0.15) * step(p.y, -14.4);       // and of the collar's
        float out2 = strokeCov(abs(dCollar), 0.17);                         // the collar's own outline (it stands inside the big drum's: not part of the union's)
        ink = max(ink, max(max(rim1, rim2), out2) * 0.85);
        float ba = TAU * 3.0 * phD.z;
        vec2 bp = vec2(cos(ba) * PR, -17.4 + sin(ba) * ISO_V * PR);
        spark = fillCov(length(p - bp) - 0.5) * (0.55 + 0.45 * (1.0 - smoothstep(-0.6, 0.0, sin(ba))));
    }
    return Sig(d, ink, max(core, fin) * 0.8, fill, spark);
}

// ---- SHOCK ------------------------------------------------------------------------------------
// A lightning bolt with an inner outline, light running down it, thin jagged arcs that wander
// around it and a few sparks that orbit.
void polySeg(vec2 p, vec2 a, vec2 b, inout float d, inout float sg) {
    vec2 e = b - a;
    vec2 w = p - a;
    vec2 q = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    d = min(d, dot(q, q));
    bvec3 c = bvec3(p.y >= a.y, p.y < b.y, e.x * w.y > e.y * w.x);
    if (all(c) || all(not(c)))
        sg = -sg;
}
float sdBolt(vec2 p) {
    const vec2 V0 = vec2(2.5, 19.0);
    const vec2 V1 = vec2(-10.5, -1.0);
    const vec2 V2 = vec2(-1.0, -1.0);
    const vec2 V3 = vec2(-4.0, -19.0);
    const vec2 V4 = vec2(11.0, 4.5);
    const vec2 V5 = vec2(1.5, 4.5);
    float d = dot(p - V0, p - V0);
    float sg = 1.0;
    polySeg(p, V0, V5, d, sg);
    polySeg(p, V1, V0, d, sg);
    polySeg(p, V2, V1, d, sg);
    polySeg(p, V3, V2, d, sg);
    polySeg(p, V4, V3, d, sg);
    polySeg(p, V5, V4, d, sg);
    return sg * sqrt(d);
}

// a zigzag arc from a to b: five straight pieces whose joints wander (smoothly: nothing jumps)
float nodeOff(float k, float amp, float seed, float ph) {
    if (k < 0.5 || k > 4.5)
        return 0.0;
    // a sum of two harmonics of the phase: periodic in ph, so nothing jumps when it wraps
    return amp * (0.62 * sin(TAU * (ph + hash11(k + seed))) + 0.38 * sin(TAU * (2.0 * ph + hash11(k * 3.1 + seed))));
}
float arcStroke(vec2 p, vec2 a, vec2 b, float amp, float seed, float ph, float hw) {
    vec2 ab = b - a;
    float L = length(ab);
    vec2 dir = ab / L;
    vec2 nrm = vec2(-dir.y, dir.x);
    vec2 w = p - a;
    float along = dot(w, dir);
    float t = clamp(along / L, 0.0, 0.9999);
    float k = floor(t * 5.0);
    float u = t * 5.0 - k;
    float o0 = nodeOff(k, amp, seed, ph);
    float o1 = nodeOff(k + 1.0, amp, seed, ph);
    float line = mix(o0, o1, u);
    float slope = (o1 - o0) / (L / 5.0);
    float off = (dot(w, nrm) - line) * inversesqrt(1.0 + slope * slope);
    float ovr = max(max(-along, along - L), 0.0);
    float dist = length(vec2(off, ovr));
    return strokeCov(dist, hw);
}

Sig symShock(vec2 p, float bob, float pulse, float crackle, float orbit) {
    p.y -= bob;
    float d = sdBolt(p) - 0.7;
    // the inner outline, and the light running down the body
    float inner = strokeCov(abs(d + 1.7), 0.17);
    float run = exp(-pow((p.y - (19.0 - fract(pulse) * 40.0)) / 3.6, 2.0));
    float fill = (0.65 + 0.55 * run) * smoothstep(0.0, -3.5, d) + 0.35;
    // arcs: leave the bolt's corners and the tip, wander, thin
    float ph = crackle;
    float en = targetP.w;                                    // the load: more arcs, wilder, brighter
    float wild = 0.80 + 0.70 * en;
    float a0 = arcStroke(p, vec2(-9.5, -1.0), vec2(-19.0, 8.0), 2.0 * wild, 1.3, ph, 0.20);
    float a1 = arcStroke(p, vec2(10.5, 4.5), vec2(19.5, -4.0), 2.0 * wild, 5.1, ph, 0.20);
    float a2 = arcStroke(p, vec2(-4.0, -18.5), vec2(-14.0, -19.0), 1.6 * wild, 9.7, ph, 0.18);
    float a3 = arcStroke(p, vec2(2.5, 18.5), vec2(11.0, 22.0), 1.6 * wild, 3.3, ph, 0.18);
    float a4 = arcStroke(p, vec2(-1.0, -1.0), vec2(6.0, -9.0), 1.4 * wild, 7.7, ph, 0.16);
    float a5 = arcStroke(p, vec2(9.0, 4.5), vec2(13.5, 14.0), 1.4 * wild, 11.9, ph, 0.16);
    float a6 = arcStroke(p, vec2(-4.5, -12.0), vec2(-15.0, -10.5), 1.4 * wild, 13.3, ph, 0.16);
    // each arc breathes in and out at its own slow pace (below 3 Hz)
    float l0 = 0.30 + 0.70 * (0.5 + 0.5 * sin(TAU * (crackle) + 0.0));
    float l1 = 0.30 + 0.70 * (0.5 + 0.5 * sin(TAU * (crackle) + 2.1));
    float l2 = 0.30 + 0.70 * (0.5 + 0.5 * sin(TAU * (crackle) + 4.2));
    float l3 = 0.30 + 0.70 * (0.5 + 0.5 * sin(TAU * (crackle) + 1.0));
    float l4 = 0.30 + 0.70 * (0.5 + 0.5 * sin(TAU * (crackle) + 3.1));
    float l5 = 0.30 + 0.70 * (0.5 + 0.5 * sin(TAU * (crackle) + 5.3));
    float l6 = 0.30 + 0.70 * (0.5 + 0.5 * sin(TAU * (crackle) + 0.7));
    float arcs = max(max(max(a0 * l0, a1 * l1), max(a2 * l2, a3 * l3)), max(a4 * l4, max(a5 * l5, a6 * l6)));
    arcs *= 0.65 + 0.55 * en;
    // AN OSCILLOSCOPE TRACE. Behind the bolt, a thin line wanders across the plane like a scope's trace (two slow sines; phD.y turns 0.11 times a second, so
    // the faster of them is 0.22 Hz), with a fainter line a hair below it, as a phosphor leaves its echo. It is the load's: a livelier trace the busier the CPU. It is
    // hidden where the bolt is (it is BEHIND it), fades out toward the plane's sides, and is faint all through: the bolt and its arcs are the figure, this is the quiet
    // ground under it. `live` takes it out at halt like every event.
    float te = fxOn.z * liveP.x;
    float trace = 0.0;
    if (te > 0.0) {
        float amp = 0.9 + 0.9 * en;
        float a1 = TAU * (p.x / 11.0 - phD.y), a2 = TAU * (p.x / 5.3 - 2.0 * phD.y + 0.21);
        float yy = 1.0 + amp * (0.65 * sin(a1) + 0.35 * sin(a2));
        float sl = amp * TAU * (0.65 / 11.0 * cos(a1) + 0.35 / 5.3 * cos(a2));
        float dtr = (p.y - yy) * inversesqrt(1.0 + sl * sl);
        trace = max(strokeCov(abs(dtr), 0.16), 0.4 * strokeCov(abs(dtr + 1.1), 0.16));
        trace *= (1.0 - smoothstep(17.0, 25.0, abs(p.x))) * smoothstep(-0.2, 1.2, d) * te * 0.5 * (1.0 + 0.6 * gDark);
    }
    // sparks orbiting the bolt
    float sp = 0.0;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float ang = TAU * (orbit + fi * 0.1667);
        vec2 c = vec2(cos(ang) * (13.0 + 1.6 * fi), sin(ang) * (16.0 + 0.8 * fi));
        float br = 0.40 + 0.60 * (0.5 + 0.5 * sin(TAU * (orbit * 2.0) + fi * 1.7));
        sp = max(sp, fillCov(length(p - c) - 0.38) * br);
    }
    float core = inner * 0.9;
    return Sig(d, max(arcs * 0.9, trace), core, fill, sp);
}

Sig symbolSig(int sym, vec2 p) {
    if (sym == 0)
        return symLeaf(p, 0.07 * sin(TAU * phB.y), 0.8 * sin(TAU * phB.x), phB.z);
    if (sym == 1)
        return symScales(p, 0.10 * sin(TAU * phB.y), TAU * phB.y - 1.1);
    return symShock(p, 0.8 * sin(TAU * phB.x), phB.w, phC.x, phC.y);
}

// ---- the treatment ------------------------------------------------------------------------------
// One chromatic sample of a symbol, premultiplied. `sc` is the scanline modulation (1 = none): the
// translucent body and the glow carry all of it, the strokes carry a share, so fine lines stay legible.
vec4 shadeSig(Sig g, vec3 body, vec3 rim, float sc) {
    float inside = fillCov(g.d);
    float outline = strokeCov(abs(g.d), 0.26);
    float halo = exp(-max(g.d, 0.0) / 1.5) * 0.30 * (1.0 - inside);
    float rimGlow = exp(-max(-g.d, 0.0) / 2.0) * 0.16 * inside;
    float st = mix(1.0, sc, 0.5);
    vec4 acc = vec4(0.0);
    acc = inkOver(acc, body, inside * g.fill * 0.15 * sc);
    acc = inkOver(acc, body, (halo + rimGlow) * sc);
    acc = inkOver(acc, body, g.ink * 0.62 * st);
    acc = inkOver(acc, rim, outline * 0.95 * st);
    acc = inkOver(acc, rim, g.core * 0.92 * st);
    acc = inkOver(acc, mix(rim, vec3(1.0), 0.5 * gDark), g.spark);
    return acc;
}
float rimAmount(Sig g) {
    return max(strokeCov(abs(g.d), 0.26), g.core);
}

vec4 holoCpu(vec2 scr) {
    float hp = look.z;
    float energy = targetP.w;
    vec3 A = anchorP.xyz;
    vec2 uv = vec2(scr.x - dot(A, CAM_R), (scr.y - dot(A, CAM_U)) / PLANE_V);    // mm across, mm up from the anchor
    Glitch g = glitchOf(uv, look.x, anchorP.w);
    float split = 0.34 + 2.0 * g.amp + 1.4 * (1.0 - hp);
    vec2 q = g.uv;
    q.x += 0.035 * sin(q.y * 1.3 + TAU * phB.x * 2.0);                          // a faint shimmer
    vec2 p = vec2(q.x, q.y - (plane.y + plane.z * 0.5 + 1.0));
    int sym = int((g.next > 0.5 ? look2.x : look.w) + 0.5);
    vec3 cm = mix(colA.rgb, colB.rgb, g.colMix);
    vec3 body = bodyOf(cm);
    vec3 ink = inkOf(cm);
    vec3 rim = mix(ink, inkOf(colT.rgb), look.y);
    Sig s0 = symbolSig(sym, p);
    Sig sP = symbolSig(sym, p + vec2(split, 0.0));
    Sig sM = symbolSig(sym, p - vec2(split, 0.0));
    float sc = scanlines(uv.y);
    vec4 img = shadeSig(s0, body, rim, sc);
    // the split: two ghosts of the outline in neighbouring hues, under the image
    float gP = rimAmount(sP) * 0.34;
    float gM = rimAmount(sM) * 0.34;
    vec4 ghosts = inkOver(vec4(0.0), hueRot(ink, 0.95), gP);
    ghosts = inkOver(ghosts, hueRot(ink, -0.95), gM);
    img = over(img, ghosts);
    float gain = (0.90 + 0.20 * energy) * mix(0.40, 1.0, colA.a);
    img *= g.keep * flicker() * powerCurve(hp) * gain;
    // the projector: a cone from the anchor up through the plane, and the lens on the package
    vec3 ro = rayOrigin(scr);
    vec3 rd = -CAM_C;
    float haze = 1.0 - exp(-coneHaze(ro, rd, A, plane.y + plane.z, 2.2, 0.36) * 0.017);
    float lens = lensGlow(ro, rd, A, LENS_CPU, 0.55, 0.8);
    vec4 beam = inkOver(vec4(0.0), body, haze * mix(0.85, 0.55, gDark) * plane.w);
    beam = inkOver(beam, ink, lens * 0.55);
    beam *= flicker() * powerCurve(min(hp * 1.25, 1.0)) * anchorP.w;
    // the plane's corner brackets
    vec4 brk = inkOver(vec4(0.0), ink, cornerBrackets(vec2(uv.x, uv.y - plane.y - plane.z * 0.5)) * look2.y);
    brk *= powerCurve(hp) * anchorP.w;
    return over(img, over(brk, beam));
}
