// =============================================================================
// holo_beam.glsl -- Integrated mode: the card is gone from its slot, and the CPU's graphics tile
// beams a see-through ghost of it to where it sat (spliced into silicon_holo.frag).
//
// A thin fan of light runs along the board from the tile (`anchor`) to the card's DIE (`target`: the die's centre at its own height, hovering
// with the ghost), widening toward the card; pulses of light travel down it at a tempo the iGPU's busy sets, and it fades out into the die as it
// fades in at the tile (so it does not end in a bright band and a hard cut at the card's middle). At its end the card hangs over its
// place as a FLAT hologram of the REAL card, all its parts included and its I/O bracket left out: every part is drawn on horizontal
// planes at the heights it really has -- outlines, faint fills, the edges that join a tall part's top to its footprint -- with the same scanlines
// and flicker as every hologram. The parts come from SceneGeometry.PARTS through HoloLayer (cardPcb ... r3hMlc2): one source, so the ghost follows
// the card.
// =============================================================================

float rectSd(vec2 xz, vec4 r, float rad) {      // r: x0 z0 x1 z1 (board mm); a rounded rectangle
    vec2 c = vec2(r.x + r.z, r.y + r.w) * 0.5;
    vec2 h = vec2(r.z - r.x, r.w - r.y) * 0.5;
    return sdBox2(xz - c, h - vec2(rad)) - rad;
}

// ---- the ghost's coordinates -----------------------------------------------------------------------------------------
// The view direction is (-1, -1, -1) / sqrt 3, so the ray over a pixel is at (g.x + y, g.y + y) in x and z when it is y mm up (g is where it meets the
// board's plane, y = 0): a horizontal plane at height y is `g + vec2(y)`, a shift and nothing more, and a vertical edge is found by arithmetic on g
// too (gEdgeAt). No ray is marched for the ghost.
const float G_FS = 0.70710678;          // an axis-aligned edge lying in a horizontal plane is foreshortened to this on the screen
const float G_V = 0.8164966;            // so is a vertical length
const float G_LINE = 0.156;             // a line's half width, screen mm (0.22 mm on the plane)
const float GHOST_PCB_R = 0.8;           // the PCB's corner radius in the ghost (the card's PCB is square: a hologram's corner is a little soft)
// the beam fades IN over [-BEAM_FAN_BACK, BEAM_RAMP] of its length around the tile (its core over [0, BEAM_CORE_RAMP]) and OUT the same way around the die:
// the same ramps mirrored about the middle of the beam (the end fades out the way it fades in)
const float BEAM_RAMP = 0.05;
const float BEAM_CORE_RAMP = 0.04;

// a row of identical cells (a box is a row of one): the first cell's rectangle, the step between cells, the counts, y0 y1 and the shape
struct GRow {
    vec4 r;
    vec2 pitch;
    vec2 n;
    vec3 yS;
    float skip;     // the cells the row leaves out (SceneGeometry ROW `skip`), a mask: the sum of 2^i over their indices
};
GRow gRow(vec4 a, vec4 b, vec4 c) {
    return GRow(a, b.xy, b.zw, c.xyz, c.w);
}
vec2 gCenter(GRow w) {
    return (w.r.xy + w.r.zw) * 0.5;
}
vec2 gHalf(GRow w) {
    return (w.r.zw - w.r.xy) * 0.5;
}
// the cell of a row nearest to xz (its index along x and z; a row runs along one of them)
vec2 gIndex(vec2 xz, GRow w) {
    return clamp(floor((xz - gCenter(w)) / max(w.pitch, vec2(0.001)) + 0.5), vec2(0.0), max(w.n - 1.0, vec2(0.0)));
}
// signed distance (board mm) in a horizontal plane to the row's nearest cell: a rounded rectangle, or the circle a cylinder's cell is
float gCellSd(vec2 xz, GRow w, vec2 idx, float rad) {
    vec2 l = xz - gCenter(w) - idx * w.pitch;
    vec2 h = gHalf(w);
    return w.yS.z > 0.5 ? length(l) - min(h.x, h.y) : sdBox2(l, h - vec2(rad)) - rad;
}
// a cell the row leaves out (no bit operations in GLSL 1.20: the mask is read with floor / mod / exp2)
bool gSkipped(GRow w, vec2 idx) {
    return w.skip > 0.5 && mod(floor(w.skip / exp2(idx.x + idx.y * max(w.n.x, 1.0))), 2.0) > 0.5;
}
// Where the nearest cell is one the row leaves out (the card's MLCCs behind its caps), its neighbours along the row are the nearest that are there.
// Only the outlines take the skip: a row with left-out cells has no vertical edges in the ghost (gEdgeRow / gSilRow draw every cell).
float gRowSd(vec2 xz, GRow w, float rad) {
    vec2 idx = gIndex(xz, w);
    if (!gSkipped(w, idx))
        return gCellSd(xz, w, idx, rad);
    vec2 ax = vec2(w.n.x > 1.5 ? 1.0 : 0.0, w.n.y > 1.5 ? 1.0 : 0.0);
    vec2 lo = max(idx - ax, vec2(0.0));
    vec2 hi = min(idx + ax, max(w.n - 1.0, vec2(0.0)));
    float d = 1e3;
    if (any(notEqual(lo, idx)) && !gSkipped(w, lo))
        d = min(d, gCellSd(xz, w, lo, rad));
    if (any(notEqual(hi, idx)) && !gSkipped(w, hi))
        d = min(d, gCellSd(xz, w, hi, rad));
    return d;
}
// A vertical edge at e = (x, z) from height yb to yt, as a line `hw` screen mm wide. The ray over the pixel is closest to it at height
// y = (e.x - g.x + e.y - g.y) / 2; (g.x - g.y) - (e.x - e.y) is 1.414 x the pixel's distance from the edge's line on the screen, and a length of
// the edge is 0.8165 x as long there (its ends are soft).
float gEdgeAt(vec2 g, vec2 e, float yb, float yt, float hw) {
    float y = 0.5 * ((e.x - g.x) + (e.y - g.y));
    float d = length(vec2(((g.x - g.y) - (e.x - e.y)) * G_FS, max(max(yb - y, y - yt), 0.0) * G_V));
    return strokeCov(d, hw);
}
// the same edge of every cell of a row (the corner is the FIRST cell's): the cell whose edge is nearest on the screen is the one drawn
float gEdgeRow(vec2 g, GRow w, vec2 corner, float yb, float yt, float hw) {
    float st = w.pitch.x - w.pitch.y;
    float k = abs(st) > 0.001 ? clamp(floor(((g.x - g.y) - (corner.x - corner.y)) / st + 0.5), 0.0, max(w.n.x, w.n.y) - 1.0) : 0.0;
    return gEdgeAt(g, corner + k * w.pitch, yb, yt, hw);
}
// a vertical cylinder's two outline edges (the ray grazes it at 1.414 x its radius from the axis in g.x - g.y), every cylinder of a row
float gSilRow(vec2 g, GRow w, float yb, float yt, float hw) {
    vec2 c0 = gCenter(w);
    float st = w.pitch.x - w.pitch.y;
    float k = abs(st) > 0.001 ? clamp(floor(((g.x - g.y) - (c0.x - c0.y)) / st + 0.5), 0.0, max(w.n.x, w.n.y) - 1.0) : 0.0;
    vec2 c = c0 + k * w.pitch;
    float y = 0.5 * ((c.x - g.x) + (c.y - g.y));
    float r = min(gHalf(w).x, gHalf(w).y);
    float d = length(vec2(abs(abs((g.x - g.y) - (c.x - c.y)) * G_FS - r), max(max(yb - y, y - yt), 0.0) * G_V));
    return strokeCov(d, hw);
}

// one mark of the ghost: a translucent fill, a soft halo and an outline, from a signed distance in board mm (negative inside)
vec4 gMark(float d, float fillA, float rimA, float haloA, vec3 body, vec3 rim) {
    float ds = d * G_FS;
    float inside = fillCov(ds);
    float outline = strokeCov(abs(ds), G_LINE);
    float halo = exp(-max(d, 0.0) / 1.2) * haloA * (1.0 - inside);
    vec4 acc = inkOver(vec4(0.0), body, inside * fillA);
    acc = inkOver(acc, body, halo);
    return inkOver(acc, rim, outline * rimA);
}

// a row of parts standing on the card: the footprint it stands on, the edges up to the top (the three that face the camera: a box's, or a
// cylinder's two sides) and the top face. `baseA` and `edgeA` are 0 for a part too low to need them.
vec4 gRowMarks(vec2 g, GRow w, float lift, float rad, float fillA, float rimA, float baseA, float edgeA, vec3 body, vec3 rim) {
    vec4 acc = vec4(0.0);
    if (w.n.x < 0.5)
        return acc;
    float yb = w.yS.x + lift;
    float yt = w.yS.y + lift;
    if (baseA > 0.0) {
        float dB = gRowSd(g + vec2(yb), w, rad);
        acc = over(gMark(dB, 0.0, baseA, 0.0, body, rim), acc);
        float e = w.yS.z > 0.5 ? gSilRow(g, w, yb, yt, G_LINE)
                  : max(gEdgeRow(g, w, w.r.zw, yb, yt, G_LINE), max(gEdgeRow(g, w, vec2(w.r.x, w.r.w), yb, yt, G_LINE), gEdgeRow(g, w, vec2(w.r.z, w.r.y), yb, yt, G_LINE)));
        acc = inkOver(acc, rim, e * edgeA);
    }
    return over(gMark(gRowSd(g + vec2(yt), w, rad), fillA, rimA, 0.0, body, rim), acc);
}

// the whole ghost card, premultiplied; `lift` is how far it hovers above its place
vec4 ghostCard(vec2 g, float lift, vec3 body, vec3 ink) {
    vec4 acc = vec4(0.0);
    // the PCB: the underside's outline, then the top face with a faint projection grid and the gold fingers
    float yU = cardH.x + lift;
    float yP = cardH.y + lift;
    acc = over(gMark(rectSd(g + vec2(yU), cardPcb, GHOST_PCB_R), 0.0, 0.40, 0.16, body, ink), acc);
    vec2 xzP = g + vec2(yP);
    float dPcb = rectSd(xzP, cardPcb, GHOST_PCB_R);
    vec4 top = gMark(dPcb, 0.13, 0.85, 0.16, body, ink);
    vec2 gq = abs(fract(xzP / 4.0) - 0.5) * 4.0;
    top = inkOver(top, ink, strokeCov(min(gq.x, gq.y) * G_FS, 0.05) * fillCov((dPcb + 0.6) * G_FS) * 0.10);
    float fz = abs(fract((xzP.y - r3hFing.y) / r3hTops.z) - 0.5) * r3hTops.z;
    float inBand = step(r3hFing.x, xzP.x) * step(xzP.x, r3hFing.z) * step(r3hFing.y, xzP.y) * step(xzP.y, r3hFing.w);
    top = inkOver(top, ink, strokeCov(fz * G_FS, r3hTops.w * 0.5 * G_FS) * inBand * 0.55);
    acc = over(top, acc);
    // the die's substrate and the heatsink's base, flat on the PCB
    acc = over(gMark(rectSd(g + vec2(cardH.z + lift), cardSub, 0.8), 0.06, 0.55, 0.16, body, ink), acc);
    acc = over(gMark(rectSd(g + vec2(r3hTops.y + lift), r3hSink, 0.4), 0.08, 0.55, 0.0, body, ink), acc);
    // the four GDDR chips
    vec2 xzM = g + vec2(r3hTops.x + lift);
    float dM = min(min(rectSd(xzM, cardM0, 0.5), rectSd(xzM, cardM1, 0.5)), min(rectSd(xzM, cardM2, 0.5), rectSd(xzM, cardM3, 0.5)));
    acc = over(gMark(dM, 0.14, 0.75, 0.16, body, ink), acc);
    // the VRM's MOSFETs and the MLCCs (flat), its chokes and the capacitors (tall), the heatsink's fins (the tallest): five rows, one after the other over what is
    // under them, through ONE call of gRowMarks in a loop whose bound comes from a uniform (r3hBeam.z, kept 0: the rows beyond the five) so the compiler cannot unroll
    // it -- Mesa inlines every call, and gRowMarks is some 280 lines of inlined source a copy: five copies are a third of the whole shader's compile
    int nr = 5 + int(r3hBeam.z);
    for (int i = 0; i < nr; i++) {
        GRow w = i == 0 ? gRow(r3hFet0, r3hFet1, r3hFet2)
               : (i == 1 ? gRow(r3hMlc0, r3hMlc1, r3hMlc2)
               : (i == 2 ? gRow(r3hChk0, r3hChk1, r3hChk2)
               : (i == 3 ? gRow(r3hCap0, r3hCap1, r3hCap2) : gRow(r3hFin0, r3hFin1, r3hFin2))));
        // corner radius, fill, rim, base, edge
        vec4 rowA = i == 0 ? vec4(0.2, 0.14, 0.50, 0.0) : (i == 1 ? vec4(0.1, 0.14, 0.45, 0.0) : (i == 2 ? vec4(0.3, 0.10, 0.65, 0.30) : (i == 3 ? vec4(0.0, 0.10, 0.65, 0.30) : vec4(0.0, 0.12, 0.80, 0.35))));
        float edgeA = i < 2 ? 0.0 : 0.45;
        acc = over(gRowMarks(g, w, lift, rowA.x, rowA.y, rowA.z, rowA.w, edgeA, body, ink), acc);
    }
    // the die, on top: a bright fill and outline and an inner line
    vec2 xzD = g + vec2(cardH.w + lift);
    float dDie = rectSd(xzD, cardDie, 0.5);
    vec4 die = gMark(dDie, 0.28, 1.0, 0.16, body, ink);
    die = inkOver(die, ink, strokeCov(abs(dDie + 1.6) * G_FS, G_LINE * 0.73) * 0.7);
    return over(die, acc);
}

// the fan of light: integrated through a slab of the board's airspace, in 16 steps. It fades in at the tile over the first few mm and out into the
// die the same way (BEAM_RAMP), so it has no end to see.
float fanLight(vec3 ro, vec3 rd, vec3 A, vec3 T, float arch, float pulsePh) {
    vec2 Dh = T.xz - A.xz;
    float Lh = length(Dh);
    vec2 D = Dh / Lh;
    vec2 N = vec2(-D.y, D.x);
    float yTop = 16.0 + arch;
    float tTop = (yTop - ro.y) / rd.y;
    float tBot = (0.0 - ro.y) / rd.y;
    vec3 pm = ro + rd * (0.5 * (tTop + tBot));
    float sm = dot(pm.xz - A.xz, D);
    float lm = dot(pm.xz - A.xz, N);
    // the samples of one ray lie within 18 mm of the slab's middle along the beam; the density ends at the die and begins 3 % of the length behind the tile
    if (sm < -BEAM_FAN_BACK * Lh - 18.0 || sm > Lh + 18.0 || abs(lm) > 58.0)
        return 0.0;
    // THE DATA STREAM. A slow swell of light runs down the core from the tile to the card at 2.4 mm/s: an 8-cell word (5 mm cells,
    // so it wraps without a jump) of smoothly blended levels, the core's own brightness varying by +-22 % about its rest and nothing with an edge (dashes of 6 mm/s, 1.45 x and
    // 0.45 x with hard-edged cells are too busy: the stream is subtle and serene). Read ONCE at the slab's middle, not per sample: the ray crosses the slab
    // slantwise, and a per-sample pattern smeared into stairs. A motion: `live` takes it out at halt like the pulses; 0 or halted, `strm` is exactly 1.
    float cw = sm / 5.0 - 8.0 * phD.w;
    float ci = floor(cw);
    float cf = cw - ci;
    cf = cf * cf * (3.0 - 2.0 * cf);
    float lvl = mix(hash11(mod(ci, 8.0)), hash11(mod(ci + 1.0, 8.0)), cf);
    float strm = 1.0 + fxOn.x * liveP.x * 0.44 * (lvl - 0.5);
    float dt = (tBot - tTop) / 16.0;
    float acc = 0.0;
    for (int i = 0; i < 16; i++) {
        vec3 p = ro + rd * (tTop + (float(i) + 0.5) * dt);
        float s = dot(p.xz - A.xz, D);
        float l = dot(p.xz - A.xz, N);
        float q = s / Lh;
        float qc = clamp(q, 0.0, 1.0);
        float yAxis = mix(A.y, T.y, qc) + arch * 4.0 * qc * (1.0 - qc);
        float W = BEAM_FAN_W0 + BEAM_FAN_W1 * qc;
        float H = r3hBeam.x + r3hBeam.y * qc;
        float dy = (p.y - yAxis) / H;
        float rl = l / W;
        float dens = exp(-2.3 * rl * rl) * exp(-2.6 * dy * dy);
        dens *= smoothstep(-BEAM_FAN_BACK, BEAM_RAMP, q) * (1.0 - smoothstep(1.0 - BEAM_RAMP, 1.0 + BEAM_FAN_BACK, q));
        dens *= 0.50 + 0.50 * (1.0 - qc);
        // pulses of light running down the axis (they are a motion: the idle ladder's `live` takes them out at halt)
        float pls = 0.0;
        for (int k = 0; k < 3; k++) {
            float u = (q - fract(pulsePh + float(k) / 3.0)) / 0.045;
            pls += exp(-u * u);
        }
        float lc = l / 0.9;
        float core = exp(-lc * lc) * exp(-3.0 * dy * dy) * smoothstep(0.0, BEAM_CORE_RAMP, q) * (1.0 - smoothstep(1.0 - BEAM_CORE_RAMP, 1.0, q));
        core *= strm;
        dens += core * (1.5 + 3.2 * pls * liveP.x);
        acc += dens * abs(dt);
    }
    return acc;
}

vec4 holoBeam(vec2 scr, vec2 px) {
    float hp = look.z;
    float energy = targetP.w;
    float presence = anchorP.w;
    float lift = r3hHover.x + r3hHover.y * sin(TAU * phB.x);           // the ghost hovers a little above its place
    vec3 A = anchorP.xyz;
    vec3 T = vec3(targetP.x, targetP.y + lift, targetP.z);             // the die's centre, at the height its top hovers at
    vec3 ro = rayOrigin(scr);
    vec3 rd = -CAM_C;
    Glitch g = glitchOf(vec2(scr.x, scr.y / PLANE_V), 0.0, presence);
    vec3 cm = colA.rgb;
    vec3 body = bodyOf(cm);
    vec3 ink = inkOf(cm);
    float sc = scanlines(scr.y / PLANE_V);
    // ---- the fan ----
    float acc = fanLight(ro, rd, A, T, quad.w, phC.w);
    float haze = 1.0 - exp(-acc * 0.10);
    vec4 beam = inkOver(vec4(0.0), body, haze * mix(0.80, 0.50, gDark) * (plane.w / 1.8));      // 1.8 = the default strength
    float lens = lensGlow(ro, rd, A, LENS_BEAM, 0.55, 0.8);
    beam = inkOver(beam, ink, lens * 0.55);
    // ---- the ghost of the card: the ground-plane point of this pixel's ray, and every part drawn from it ----
    vec4 ghost = vec4(0.0);
    vec2 gp = vec2(G_FS * scr.x - 1.22474487 * scr.y, -G_FS * scr.x - 1.22474487 * scr.y);
    // only where this pixel's ray passes through the box the ghost hangs in (r3hBox over r3hHover.z .. .w, lifted by the hover): at height y the ray is at
    // gp + y in x and z, so it is inside while y is in all three of its ranges
    if (max(max(r3hBox.x - gp.x, r3hBox.y - gp.y), r3hHover.z + lift) <= min(min(r3hBox.z - gp.x, r3hBox.w - gp.y), r3hHover.w + lift))
        ghost = ghostCard(gp, lift, body, ink);
    // the ghost shimmers a little, scans, flickers; the fan is light, so only the flicker touches it
    float gain = (0.80 + 0.45 * energy) * mix(0.40, 1.0, colA.a);
    ghost *= mix(1.0, sc, 0.7);
    ghost *= g.keep * flicker() * powerCurve(hp) * gain;
    beam *= flicker() * powerCurve(min(hp * 1.25, 1.0)) * presence * (0.85 + 0.3 * energy);
    return over(ghost, beam);
}
