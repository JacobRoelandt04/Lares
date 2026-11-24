// =============================================================================
// glow_materials.glsl -- how each family's LIGHT looks (spliced into silicon_glow.frag by
// tools/dev/silicon_shader_gen.js).
//
// In:  Glow (silicon_glow.frag.in), the uniforms. Out: shadeGlow(Glow), PREMULTIPLIED rgba --
//      a tint laid over the still board, never an additive blow-out on a light ground (on a dark
//      one a little additive part is what makes a glow read as light, see lightPx).
// Tunables (GlowLayer's defaults; the scene does not route a family's own values to this shader):
//   `lockP.z` (how far the charge limit's lock has dimmed the 4th cell) dims that cell's light; the lit 7-segment segments are
//   this shader's too (the board draws the module, its window and the unlit segments: seg7.glsl is the one font);
//   glowA x: overall strength, y: trace light base level, z: pulse spacing mm, w: pulse width mm;
//   glowB z: the pulse trains' amplitude 0..1 (the idle ladder eases it to 0
//   on the way to halt: a halted frame has no streak frozen on a trace; x, y and w are free). `view.w` is the family, `frame.w` is 1 in dark
//   mode; everything a family needs beyond these is a constant in its own function below. The battery event's own numbers (its speed, its
//   reach, the trains' envelope) are not tunables: they are constants the generator bakes from tools/dev/silicon_event_walk.js (PULSE: EVT_*).
// =============================================================================

const vec3 WHITE = vec3(1.0);

float sqr(float x) { return x * x; }
float softRect(vec2 q, vec4 r, float soft) {
    // 1 deep inside the rect, falling to 0 at its edge over `soft` mm: no hard edge to alias
    vec2 d = min(q - r.xy, r.zw - q);
    return smoothstep(0.0, soft, min(d.x, d.y));
}

// mm inside the rect (negative outside): the distance field of a rectangle's edge
float rectIn(vec2 q, vec4 r) {
    vec2 d = min(q - r.xy, r.zw - q);
    return min(d.x, d.y);
}

vec4 tint(vec3 c, float a) {
    a = clamp(a, 0.0, 1.0);
    return vec4(c * a, a);
}

// A point of light: colour c at coverage a, with a `hot` part that reads as emission: toward white
// on a light ground (still a tint), partly additive on a dark one.
vec4 lightPx(vec3 c, float a, float hot) {
    a = clamp(a, 0.0, 1.0);
    hot = clamp(hot, 0.0, 1.0);
    if (frame.w > 0.5)
        return vec4(c * a + c * hot * 0.40 * a, a);
    return vec4(mix(c, WHITE, hot * 0.55) * a, a);
}

// `over` composited onto `under` (both premultiplied)
vec4 over(vec4 top, vec4 under) {
    return top + under * (1.0 - top.a);
}

// A 7-segment display's lit field: the segments' signed distance, the window's mask and the lit colour are the SAME in both families, so they are asked ONCE, here,
// before the family's own look (the font, segFieldSd, and the lookups -- segIndexOf, segFig, segWindow, segLit -- are one copy in the shader, not one a family).
float gDispSd;
float gDispWin;
vec3 gDispLit;
void displayField(Glow g) {
    gDispSd = -2.0;
    gDispWin = 0.0;
    gDispLit = vec3(0.0);
    if (g.mat == MAT_DISPLAY && g.nl.y > 0.5) {
        int di = segIndexOf(g.part);
        float aaS = 0.7 / (view.z * max(quad.w, 1.0));
        gDispSd = segFieldSd(di, g.pl.xz, segFig(di), false);
        gDispWin = smoothstep(-aaS, aaS, rectIn(g.pl.xz, segWindow(di)));
        gDispLit = segLit(di);
    }
}

// ---- the display's path: the picture's way from the GPU that makes it to the ribbon's connector ----------------------------------
// The iGPU makes it in Integrated, Smart and Hybrid (it runs out along the zone's +z stub and cpuFront, in the CPU's colour: the iGPU is in the
// CPU package); in dGPU-only the dGPU does (its colour: out of the slot along both slot lanes, back along cpuOut from its end to the T, down the edge by
// dispDown, into cpuFront: the flow's `disp`, traceLevel below). `memP.y` says which. The ribbon carries no light.
// the RAM chip under a point: its unit (2 GB a chip), from the cell's own corner. They fill in reading order: stick A's four left to right, then stick B's near
// row, then its far row (a row is five cells with the middle one left out)
float ramUnit(Glow g) {
    bool a = g.part == PART_RAMCHIPSA;
    float k = floor((g.bmin.x - (a ? RAM_ROWX.x : RAM_ROWX.y)) / RAM_ROWX.z + 0.5);       // the cell's index in its row
    return (k > RAM_ROWX.w ? k - 1.0 : k) + (a ? 0.0 : (g.part == PART_RAMCHIPSB0 ? 4.0 : 8.0));
}

// A pulse train along a coordinate: 0..1, a Gaussian pulse every `spacing` mm of it, `phase` mm along (glowA.z spacing, glowA.w width).
float pulseTrain(float s, float phase) {
    float spacing = glowA.z > 0.0 ? glowA.z : 26.0;
    float width = glowA.w > 0.0 ? glowA.w : 5.0;
    float x = fract((s - phase) / spacing) * spacing - spacing * 0.5;
    return exp(-x * x / (width * width));
}

// The battery event's pulse (below): its strength at distance d from the pack, 1 at the pack falling to 0 at EVT_MAXD (a smoothstep: it leaves strong and ends softly).
float evtFade(float d) {
    return 1.0 - smoothstep(0.0, EVT_MAXD, d);
}

// The passive trains' ONE envelope of the event's age: the event is not drowned out by the already passive waves, because the trains fade to transparent while the event's waves do
// their animation, and after the event pulse has concluded everything returns to normal. 1: the trains run as always, 0: gone. They fade out over
// EVT_DIM_IN s as the event starts, are away while the pulse is strong (its strength, at the distance it has run, over EVT_DIM_AT), and come back as it fades -- fully
// back when it has reached 0, at the age EVT_MAXD / EVT_SPEED, which is the event's end (the director's `eventS` runs at least that long).
// A function of the age alone and smooth both ways: a smoothstep of the age times a smoothstep of the pulse's own fade, whose slope is 0 where it starts and where it
// ends. What it multiplies is the trains only (traceLevel's `pulse`): the traces' steady light stays. A power-on sweep or any other light is not its business.
float evtTrains(float age) {
    if (age < 0.0)
        return 1.0;
    return 1.0 - smoothstep(0.0, EVT_DIM_IN, age) * smoothstep(0.0, EVT_DIM_AT, evtFade(age * EVT_SPEED));
}

// The light a trace carries here: its level (the base glow plus a pulse train at the family's tempo, the power-on sweep) and its colour. `head` is the
// sweep's bright front. THE FLOW (SceneGeometry.js): the generated field gives every trace point its coordinates along its route, `tF` (x: the route's,
// y: the dGPU-only display path's; read here as the global sceneTraces just set: the Glow's trace is that same point), and each trace its constants
// (traceFlowA / B, traceDisp). A pulse is one pulse
// through every joint because both sides of a joint carry the same coordinate there; where nobody listens a route's light fades along it (kind 1: the
// dGPU's lanes while it sleeps; kind 2: the display lane, always); a colour changes by a blend over mm of the coordinate, never at a line.
// `trains` is the battery event's envelope for the trains (evtTrains: 1 at rest), shadeGlow's one answer for the pixel.
float traceLevel(Glow g, float trains, out vec3 c, out float head) {
    float spacing = glowA.z > 0.0 ? glowA.z : 26.0;
    vec4 fa = traceFlowA(g.traceId);
    int ch = int(fa.x + 0.5);
    float pulse = glowB.z * trains;                              // 1: the pulse trains run; 0: the traces carry their steady light only
    float s = tF.x;
    float d = g.traceFrom + g.traceArc;                          // the power-on sweep's distance: mm from the pack along the network
    if (g.traceId <= TRACE_STUB_NZ)                              // a stub is stored courtyard -> zone edge, the sweep comes the other way
        d = g.traceFrom - g.traceArc;
    c = colCpu.rgb;
    float lv = glowA.y;
    if (ch == 0) {
        // power into the package: a pulse train toward it at the profile's tempo (the host integrates the phase)
        lv += 0.85 * pulse * pulseTrain(s, phases.x * spacing);
    } else if (ch == 1) {
        // the package's own traffic, out along every route it drives. The same train on every route (the CPU's tempo); the dGPU-only display path
        // takes over its share of the copper (dg) with its own train; a route nobody listens to fades.
        vec2 fb = traceFlowB(g.traceId);
        vec2 dp = traceDisp(g.traceId);
        float dg = memP.y * smoothstep(dp.x, dp.y, s);
        float fade = 1.0 - smoothstep(fa.z, fa.w, s);
        float env = fa.y < 0.5 ? 1.0 : (fa.y < 1.5 ? mix(fade, 1.0, live.y) : fade);
        vec3 cc = mix(colCpu.rgb, colGpu.rgb, live.y * smoothstep(fb.x, fb.y, s));              // nearing the awake card the light takes its hue
        float lb = glowA.y * (fa.y > 1.5 ? 1.0 : env);                                      // the steady light (the display lane keeps it, its pulses fade)
        float lp = 0.85 * pulse * pulseTrain(s, phases.x * spacing) * (1.0 - dg) * env;      // the CPU's pulses
        float ld = 0.85 * pulse * pulseTrain(tF.y, phases.y * spacing) * dg;                 // the display path's pulses (dGPU-only)
        // the light's colour is its three parts', each by its own level: the display path's steady light is the dGPU's hue too, in dGPU-only
        c = (mix(cc, colGpu.rgb, dg) * lb + cc * lp + colGpu.rgb * ld) / max(lb + lp + ld, 1e-4);
        lv = lb + lp + ld;
    } else if (ch == 3) {
        // the card's power: in step with the dGPU's tempo, there while it is awake
        c = colGpu.rgb;
        lv = (lv + 0.85 * pulse * pulseTrain(s, phases.y * spacing)) * live.y;
    } else {
        // charging: the flow runs from the jack into the pack
        c = colCharge.rgb;
        lv = (lv + 0.9 * pulse * pulseTrain(s, phases.z)) * step(0.0, live.w);
    }
    // the power-on sweep: lit as far as the front has travelled, a bright head at the front
    float reach = power.x * 220.0;
    float sweep = 1.0 - smoothstep(reach - 6.0, reach, d);
    head = exp(-sqr((d - reach) / 4.0)) * (1.0 - smoothstep(0.85, 1.0, power.x));
    return lv * sweep;
}

// ---- the battery event: ONE pulse that runs along the traces ---------------------------------------------------------------
// It leaves the pack's traces at the event (`power.y`: its age, s) and runs at EVT_SPEED mm/s along every trace -- into every branch, through the parts
// the traces join, round every loop -- and falls with the distance it has run until it is gone (EVT_MAXD; evtFade). Its walks are DATA (the generator: evtAt): per trace
// the waves on it (evtAt), at distance c + dir * arc from the pack, ahead of `from` only. Where two waves meet they add and saturate (a loop's lap that coincides with another
// must not double the light, and a max would have a kink where two cross). `w` is the pulse's half width mm.
float evtLevel(Glow g, float w) {
    float r = power.y * EVT_SPEED;
    float m = 0.0;
    int i0 = evtFirst(g.traceId);
    int n = i0 + evtCount(g.traceId);
    for (int k = i0; k < n; k++) {
        vec3 e = evtAt(k);
        float d = e.x + e.y * g.traceArc;
        m += step(0.0, e.y * (g.traceArc - e.z)) * exp(-sqr((d - r) / w)) * evtFade(d);
    }
    return (1.0 - exp(-1.5 * m)) * 1.287;       // the waves ADD where they overlap (a max has a kink where two cross), saturating smoothly: one wave reads 1
}

// ---- family 0: Material -- soft luminous light inside the grooves and wells ---------------
// The shell's idiom: a category's colour lives in the INSET SHADOW of a carved box and sweeps with
// progress. A lit well is a pale fill of the colour with a deeper coloured shadow along its edge and a
// bright core; a lit groove is the same in section.
vec3 deepOf(vec3 c) {
    return c * (frame.w > 0.5 ? 0.62 : 0.50);
}

vec4 glowEva(Glow g, float strength, float on, float evt, float trains) {
    bool dk = frame.w > 0.5;
    float pxmm = 0.70710678 * g.pxPerMm;
    vec4 out_ = vec4(0.0);
    // ---- the cores: a carved well each, filled with light by its load ----
    if (g.core >= 0) {
        vec2 q = g.pl.xz - ZONE_C;
        float dd = rectIn(q, g.coreRect);                            // mm inside the core
        float lv = 0.20 + 0.80 * g.load;
        float inner = smoothstep(0.0, 0.55, dd);
        float edge = exp(-max(dd, 0.0) * pxmm / 2.0) * step(0.0, dd);
        float spill = exp(-max(-dd, 0.0) / 0.6) * (1.0 - step(0.0, dd));
        vec4 fill = lightPx(colCpu.rgb, (0.28 + 0.34 * inner) * lv * on * strength * step(0.0, dd), inner * lv * 0.55);
        vec4 rim = tint(deepOf(colCpu.rgb), edge * 0.55 * lv * on * strength);
        vec4 halo = tint(colCpu.rgb, spill * 0.30 * lv * on * strength);
        out_ = over(rim, over(fill, halo));
    }
    // ---- the graphics tile, by the iGPU's busy ----
    if (g.group == GRP_PKG && g.mat == MAT_TILE_GRAPHICS && g.nl.y > 0.5) {
        vec2 q = g.pl.xz - ZONE_C;
        float k = softRect(q, PKG_TILES_GRAPHICS, 2.2);
        float busy = 0.10 + 0.75 * live.x;
        float edge = exp(-g.edgePx / 2.4);
        vec4 fill = lightPx(vec3(0.0, 0.745, 0.769), k * busy * 0.55 * on * strength, k * live.x * 0.5);
        vec4 rim = tint(deepOf(vec3(0.0, 0.745, 0.769)), edge * busy * 0.45 * on * strength);
        out_ = over(rim, fill);
    }
    // ---- the GPU die while the card is awake ----
    if (g.mat == MAT_GPU_DIE && g.nl.y > 0.5) {
        float k = softRect(g.pl.xz, vec4(g.bmin.x, g.bmin.z, g.bmax.x, g.bmax.z), 2.5);
        float edge = exp(-g.edgePx / 2.4);
        float aw = live.y * (1.0 - parts.y);
        vec4 fill = lightPx(colGpu.rgb, k * aw * 0.6 * on * strength, k * aw * 0.6);
        vec4 rim = tint(deepOf(colGpu.rgb), edge * aw * 0.5 * on * strength);
        out_ = over(rim, fill);
    }
    // ---- the cells: wells filling with light along the row, the colour in the inset shadow ----
    if (g.cell >= 0) {
        // each cell fills over its own stretch of the charge (20 / 50 / 80 / 100 %: SceneGeometry.CELL_STOPS)
        vec4 cr = cellRect(g.cell);
        float f = cellFill(g.cell, live.z);
        float edgeX = mix(cr.x, cr.z, f);
        float lit = (1.0 - smoothstep(edgeX - 0.5, edgeX + 0.5, g.p.x)) * smoothstep(0.0, 0.02, f);
        float inner = smoothstep(0.0, 5.0, g.edgePx);
        float rim = exp(-g.edgePx / 3.2);
        float front = exp(-sqr((g.p.x - edgeX) / 1.2)) * step(f, 0.995) * step(0.005, f);
        // the charge limit disables the 4th cell, even with charge in it: its light dims and greys by the lock's fraction
        float dimK = g.cell == 3 ? lockP.z : 0.0;
        float onC = on * (1.0 - 0.7 * dimK);
        vec3 cc = mix(colCharge.rgb, vec3(dot(colCharge.rgb, vec3(0.34, 0.5, 0.16))), 0.55 * dimK);
        vec4 fill = lightPx(cc, (0.30 + 0.28 * inner) * lit * onC * strength, (inner * 0.55 + front) * lit);
        vec4 shade = tint(deepOf(cc), rim * 0.62 * lit * onC * strength);
        vec4 meniscus = lightPx(cc, front * 0.55 * onC * strength, front);
        out_ = over(meniscus, over(shade, fill));
    }
    // ---- a 7-segment display: the lit segments in the window, seen through the smoked glass (darker, a little more saturated, the pane's texture in
    // them, a smaller halo round them) ----
    if (g.mat == MAT_DISPLAY && g.nl.y > 0.5) {
        float aaS = 0.7 / (view.z * max(quad.w, 1.0));
        float sd = gDispSd;
        float win = gDispWin;
        vec3 c = glassLit(gDispLit, g.pl.xz);
        float halo = exp(-max(-sd, 0.0) / 0.28) * (1.0 - smoothstep(-aaS, aaS, sd)) * win * (dk ? 0.09 : 0.045);
        out_ = over(lightPx(c, smoothstep(-aaS, aaS, sd) * win * on * strength, 0.10), tint(c, halo * on * strength));
    }
    // ---- the RAM's chips: the usage, filling the way the cells do (2 GB a chip, the fill sweeping from the socket end) ----
    if (g.mat == MAT_RAM_CHIP && g.nl.y > 0.5) {
        vec3 c = palM.rgb;
        float cf = clamp(memP.x * RAM_UNITS - ramUnit(g), 0.0, 1.0);
        float t = (g.pl.x - g.bmin.x) / (g.bmax.x - g.bmin.x);                 // a chip fills along the row, from its left end
        float lit = (1.0 - smoothstep(cf - 0.05, cf + 0.05, t)) * smoothstep(0.0, 0.02, cf);
        float inner = smoothstep(0.0, 3.0, g.edgePx);
        float rim = exp(-g.edgePx / 2.4);
        float front = exp(-sqr((t - cf) / 0.09)) * step(cf, 0.995) * step(0.005, cf);
        vec4 fill = lightPx(c, (0.30 + 0.28 * inner) * lit * on * strength, (inner * 0.55 + front) * lit);
        vec4 shade = tint(deepOf(c), rim * 0.55 * lit * on * strength);
        out_ = over(lightPx(c, front * 0.5 * on * strength, front), over(shade, fill));
    }
    // ---- light along the traces, inside the grooves ----
    if (g.traceId >= 0 && g.traceD < 1.2 && g.core < 0) {
        vec3 c;
        float head;
        float lv = traceLevel(g, trains, c, head);
        float hw = max(g.traceHalf, 0.2);                            // the groove's half width here (the generator's)
        // The light lies in the OPENING the camera looks into and is centred on the groove: this pixel's point
        // on the board's top is what the opening's distance field measures (a floor point shifted by the groove's
        // depth along the view puts the light's peak outside a 0.8 mm groove: misaligned pulses).
        // The depth is the board shader's business (GROOVE_DEPTH shades the wall and the floor under the light).
        float depthIn = max(-g.traceD, 0.0);                         // mm inside the opening's edge
        float op = 1.0 - smoothstep(-0.17, 0.17, g.traceD);          // soft: this shader takes one sample a pixel
        // 1 on the centre line, falling to 0 toward the edge; a point DEEPER than the nearest trace's centre line lies in a union of traces (a T's
        // body, a fillet) and counts as centre: a wide stem running into a thin lane dipped the light to the edge's at the T
        float cc = 1.0 - smoothstep(0.0, hw, max(hw - depthIn, 0.0));
        float edge = exp(-depthIn * pxmm / 1.4);
        float lvl = (lv + head * 1.1) * (dk ? 1.0 : 1.25);
        float spill = exp(-max(g.traceD, 0.0) / 0.9) * (1.0 - op) * (dk ? 0.34 : 0.20);
        vec4 fill = lightPx(c, op * (0.45 + 0.50 * cc) * lvl * strength, op * cc * min(lvl, 1.0) * 0.9);
        vec4 shade = tint(deepOf(c), op * edge * 0.40 * lvl * strength);
        vec4 halo = lightPx(c, spill * lvl * strength, 0.0);
        out_ = over(shade, over(fill, halo));
        if (evt > 0.0) {
            // the event's pulse: a luminous band in the groove, in the event's colour
            float ev = evt * strength;
            out_ = over(over(tint(deepOf(colEvent.rgb), op * edge * 0.40 * ev), lightPx(colEvent.rgb, op * (0.45 + 0.50 * cc) * ev * 0.9, op * cc * ev * 0.9)), out_);
        }
    }
    return out_;
}

// ---- family 1: Blueprint -- coloured ink, a highlighter over the drawing ----------------------
// The marker's wash is flat and edge-crisp; the drawing's own ink shows through it.
vec4 glowBlueprint(Glow g, float strength, float on, float evt, float trains) {
    bool dk = frame.w > 0.5;
    float pxmm = 0.70710678 * g.pxPerMm;
    vec4 out_ = vec4(0.0);
    float wash = dk ? 0.52 : 0.46;
    if (g.core >= 0) {
        vec2 q = g.pl.xz - ZONE_C;
        float dd = rectIn(q, g.coreRect);
        float k = smoothstep(0.0, 0.12, dd);
        float lv = 0.18 + 0.82 * g.load;
        float hatch = 1.0 - smoothstep(0.2, 0.9, abs(fract((q.x + q.y) * 2.4) - 0.5) * 2.0);
        out_ = tint(colCpu.rgb, k * (wash * 0.6 + hatch * 0.22) * lv * on * strength);
    }
    if (g.group == GRP_PKG && g.mat == MAT_TILE_GRAPHICS && g.nl.y > 0.5) {
        vec2 q = g.pl.xz - ZONE_C;
        float k = softRect(q, PKG_TILES_GRAPHICS, 0.5);
        out_ = tint(vec3(0.0, 0.745, 0.769), k * (0.10 + 0.5 * live.x) * on * strength);
    }
    if (g.mat == MAT_GPU_DIE && g.nl.y > 0.5) {
        float k = softRect(g.pl.xz, vec4(g.bmin.x, g.bmin.z, g.bmax.x, g.bmax.z), 0.5);
        out_ = tint(colGpu.rgb, k * live.y * wash * (1.0 - parts.y) * on * strength);
    }
    if (g.cell >= 0) {
        vec4 cr = cellRect(g.cell);
        float f = cellFill(g.cell, live.z);
        float edgeX = mix(cr.x, cr.z, f);
        float lit = (1.0 - smoothstep(edgeX - 0.25, edgeX + 0.25, g.p.x)) * smoothstep(0.0, 0.02, f);
        float inCell = smoothstep(0.0, 1.0, g.edgePx);
        float hatch = 1.0 - smoothstep(0.2, 0.9, abs(fract((g.p.x - g.p.z) / 1.6) - 0.5) * 2.0);
        float front = exp(-sqr((g.p.x - edgeX) / 0.5)) * step(f, 0.995) * step(0.005, f);
        float dimK = g.cell == 3 ? lockP.z : 0.0;               // the lock fades the 4th cell's ink (the board hatches it over)
        out_ = tint(colCharge.rgb, inCell * (lit * (wash * 0.9 + hatch * 0.16) + front * 0.5) * on * strength * (1.0 - 0.6 * dimK));
    }
    // a 7-segment display: the lit segments are coloured INK on the dark window, solid, never a lamp -- seen through the drawn pane: the ink a
    // little darker and more saturated, the pane's hatch crossing it in the window's own colour
    if (g.mat == MAT_DISPLAY && g.nl.y > 0.5) {
        float aaS = 0.7 / (view.z * max(quad.w, 1.0));
        float sd = gDispSd;
        float win = gDispWin;
        vec3 c = mix(glassLit(gDispLit, g.pl.xz), palI.rgb, glassHatch(g.pl.xz, view.z * max(quad.w, 1.0)) * 0.24);
        out_ = tint(c, smoothstep(-aaS, aaS, sd) * win * on);
    }
    if (g.mat == MAT_RAM_CHIP && g.nl.y > 0.5) {
        float cf = clamp(memP.x * RAM_UNITS - ramUnit(g), 0.0, 1.0);
        float t = (g.pl.x - g.bmin.x) / (g.bmax.x - g.bmin.x);
        float lit = 1.0 - smoothstep(cf - 0.03, cf + 0.03, t);
        float inCell = smoothstep(0.0, 1.0, g.edgePx);
        float hatch = 1.0 - smoothstep(0.2, 0.9, abs(fract((g.p.x - g.p.z) / 1.6) - 0.5) * 2.0);
        out_ = tint(palM.rgb, inCell * lit * (wash * 0.9 + hatch * 0.16) * on * strength);
    }
    // the highlighter: a stroke a little wider than the line it marks
    if (g.traceId >= 0 && g.traceD < 1.6 && g.core < 0) {
        vec3 c;
        float head;
        float lv = traceLevel(g, trains, c, head);
        float band = 1.0 - smoothstep(0.55, 0.85, g.traceD);
        out_ = tint(c, band * min(lv + head, 1.2) * wash * 1.05 * strength);
        if (evt > 0.0) {
            // the event's pulse: the marker stroked over the line, a solid band (a dash along the line would be a seam the pulse itself never makes)
            out_ = over(tint(colEvent.rgb, band * evt * wash * 1.6 * strength), out_);
        }
    }
    return out_;
}

vec4 shadeGlow(Glow g) {
    float strength = glowA.x > 0.0 ? glowA.x : 1.0;
    displayField(g);
    float on = clamp(power.x * 1.4 - 0.25, 0.0, 1.0);                // chips light after the traces
    vec4 out_;
    // the event's pulse is asked ONCE for both families (one copy of the walk's loop): on a trace, while an event runs
    float evt = (power.y >= 0.0 && g.traceId >= 0 && g.core < 0) ? evtLevel(g, view.w < 0.5 ? 4.2 : 3.0) : 0.0;
    float trains = g.traceId >= 0 ? evtTrains(power.y) : 1.0;         // and the trains' envelope of the same age (only a trace carries trains): one answer, for both families
    if (view.w < 0.5)
        out_ = glowEva(g, strength, on, evt, trains);
    else
        out_ = glowBlueprint(g, strength, on, evt, trains);
    return out_;
}
