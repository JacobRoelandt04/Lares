// =============================================================================
// board_materials.glsl -- how each family paints a point of the board (spliced into
// silicon_board.frag by tools/dev/silicon_shader_gen.js).
//
// In:  Surf (see silicon_board.frag.in), the uniforms (view.w = family, frame.w = dark),
//      the generated geometry (sceneTraces, sceneAo, inZone, MAT_*, PART_*, ZONE_*, ...), the
//      silkscreen sampler `silk` (a board-space SIGNED DISTANCE field, see SILK_RANGE).
// Out: shadeSurface(Surf) and shadeGround(p, signedDistanceToBoard), PREMULTIPLIED rgba.
//
// The palette (SiliconStyle.qml fills it per family and per light/dark):
//   family 0, Material     palA surface  palB bevel  palC deep shadow  palD groove floor
//                            palE engraving ink  palF sunk part  palG cell well  palH metal
//   family 1, Blueprint      palA paper  palB ink  palC faint ink  palD grid  palE face wash
//                            palF, palG, palH unused
// The SECOND palette (palI .. palP), the same slots for both families (SiliconStyle.qml fills it from the siliconDisplay* / siliconLock /
// siliconGold / siliconMemory / siliconRibbon* tokens of themes/eva.json, per family and per light / dark):
//   palI  the 7-segment displays' window     palJ  their unlit segments (faint, but not lost)     palP  their bezel
//   palK  the lock's amber (the theme's warn hue)     palL  gold: the card's fingers and the HDMI contacts
//   palM  the memory hue: the RAM's lit parts and its display's segments
//   palN  the display ribbon's film     palO  its conductors (muted -- the ribbon carries no light, it only fills the corner)
// and `r3s1Latch`: the display connector's flip-lock bar (a uniform of its own, SiliconStyle.latch)
//   r3s2A (a uniform of its own: SiliconStyle's slot 8)  the smoked glass over the displays' window: what it lets through, per family
// Tunables (SiliconStyle.qml's `tune` is tuneA; tuneB is unused):
//   tuneA x: bevel / ink line width px (Material: the bevel, Blueprint: the crease line)
//         w: paper grain (Blueprint; 0 reads as the default, 0.018)
// Everything else a family needs is a named constant at the head of its own section.
// =============================================================================

// @@INCLUDE board_prims.glsl

// ---- the DC jack's mouth with nothing plugged in: a dark bore, the centre pin in it, three small gold contacts on its wall ----
const float JACK_R = 2.6;            // the mouth's radius, mm
const float JACK_PIN = 0.8;          // the centre pin's radius
const float JACK_CONTACT_R = 2.2;    // where the three contacts stand (mm from the centre, 120 degrees apart, one straight up) and how big they are
const float JACK_CONTACT = 0.3;
// mm to the nearest contact's edge (negative inside one); q is mm from the mouth's centre, u along z and v up
float jackContacts(vec2 q) {
    // the three contacts' centres, the nearest by its squared distance (the angle of q, a sector, a turn by its sine and cosine and a distance to the first contact
    // would be ~100 instructions for what three squared distances say)
    vec2 a = q - vec2(0.0, JACK_CONTACT_R);
    vec2 b = q - vec2(-0.8660254 * JACK_CONTACT_R, -0.5 * JACK_CONTACT_R);
    vec2 c = q - vec2(0.8660254 * JACK_CONTACT_R, -0.5 * JACK_CONTACT_R);
    return sqrt(min(dot(a, a), min(dot(b, b), dot(c, c)))) - JACK_CONTACT;
}

// ---- the smoked glass over a display's window (seg7.glsl has the pane's texture and what it lets through) ----
// How the lamp meets the window's edge nearest to p: `m` is the distance to it (mm), the result the edge's outward normal against the lamp's direction
// (xz, unit): 1 where the edge faces the lamp, -1 where it turns away. `wr` is the window [x0, z0, x1, z1].
float glassFacing(vec2 p, vec4 wr, vec2 Ld, out float m) {
    float dl = p.x - wr.x, dr = wr.z - p.x, dt = p.y - wr.y, db = wr.w - p.y;
    m = min(min(dl, dr), min(dt, db));
    vec2 n = (dl <= dr && dl <= dt && dl <= db) ? vec2(-1.0, 0.0) : ((dr <= dt && dr <= db) ? vec2(1.0, 0.0) : (dt <= db ? vec2(0.0, -1.0) : vec2(0.0, 1.0)));
    return dot(n, Ld);
}
// Material's pane: glints on the dark window (its texture), a soft sheen from the lamp's corner, and a thin bevel along its edge -- brighter where the edge
// turns toward the lamp -- so it reads as a layer standing over the window. `inW` is the window's coverage, `hi` the bevel's light.
vec3 glassEva(vec3 col, vec2 p, vec4 wr, float inW, vec3 hi, bool dk, vec2 Ld) {
    col += (dk ? 0.020 : 0.034) * glassStreak(p) * inW;
    vec2 hs = max((wr.zw - wr.xy) * 0.5, vec2(1e-3));
    float sky = clamp(0.5 + 0.5 * dot((p - (wr.xy + wr.zw) * 0.5) / hs, Ld), 0.0, 1.0);
    col = mix(col, hi, inW * sky * sky * (dk ? 0.05 : 0.07));
    float m;
    float face = glassFacing(p, wr, Ld, m);
    float rim = (1.0 - smoothstep(0.0, max(0.2, 1.0 / pxMm()), m)) * inW;
    return mix(col, hi, rim * (0.20 + 0.50 * max(face, 0.0)));
}

// the silkscreen channel (0 Material, 1 Blueprint; 2 is empty) at a board point: mm, positive inside a glyph
// The field is mipmapped (make_silkscreen.py: 8 texels per mm) and read at an EXPLICIT level: an
// implicit one comes from derivatives, which are undefined in the divergent flow every sample takes
// to get here, so the cached board and the live patch would pick different levels -- the "CPU"
// label differs by 14 levels between the two. The level is the
// one the hardware would choose on the board's plane: 1 px across the screen's y is sqrt(3) /
// pxPerMm mm of it, the most a pixel spans.
const float SILK_TEXELS_PER_MM = 8.0;
float silkSd(vec2 p, int ch) {
    vec2 uv = (p - BOARD_RECT.xy) / (BOARD_RECT.zw - BOARD_RECT.xy);
    float lod = max(0.0, log2(SILK_TEXELS_PER_MM * 1.7320508 / pxMm()));
    vec3 t = textureLod(silk, uv, lod).rgb;
    float v = ch == 0 ? t.r : (ch == 1 ? t.g : t.b);
    return (v - 0.5) * 2.0 * SILK_RANGE;
}

// ---- the printed figures: the glyph atlas ---------------------------------------------------------------
// One character is a GLYPH_CELL mm cell of the atlas (GLYPH_TEXELS texels per mm), a signed distance with the silkscreen's encoding;
// `sc` scales it onto the board (the digits' ink is GLYPH_DIGIT_H tall in the atlas). Read at an explicit level, as the silkscreen is.
float glyphSample(vec2 atlasMm, float sc, int ch) {
    float lod = max(0.0, log2(GLYPH_TEXELS * 1.7320508 / (pxMm() * sc)));
    vec3 t = textureLod(glyphs, atlasMm / GLYPH_ATLAS, lod).rgb;
    return ((ch == 0 ? t.r : t.g) - 0.5) * 2.0 * SILK_RANGE * sc;
}
// one printed line of figures (TXT_LINEn: x of the right edge, z of the row's centre, digit height, pitch; `codes`: its four cell codes)
float figTextSd(vec2 p, vec4 L, vec4 codes, int ch) {
    float sc = L.z / GLYPH_DIGIT_H;
    float x0 = L.x - float(TXT_CELLS) * L.w;
    float fx = (p.x - x0) / L.w;
    int k = int(floor(fx));
    if (fx < 0.0 || k >= TXT_CELLS || abs(p.y - L.y) > 0.6 * L.z + 0.3)
        return -2.0;
    float code = k == 0 ? codes.x : (k == 1 ? codes.y : (k == 2 ? codes.z : codes.w));
    int g = int(floor(code + 0.5));
    if (g < 0 || g >= GLYPH_CHARS)
        return -2.0;                                                // a blank cell, or anything the atlas does not hold
    vec2 u = (p - vec2(x0 + (float(k) + 0.5) * L.w, L.y)) / sc + GLYPH_CELL * 0.5;
    if (u.x < 0.0 || u.x > GLYPH_CELL.x || u.y < 0.0 || u.y > GLYPH_CELL.y)
        return -2.0;
    return glyphSample(vec2(float(g) * GLYPH_CELL.x + u.x, u.y), sc, ch);
}
// the time display's printed label: one of the atlas's three texts, by `figT.x` (0: none)
float modeLabelSd(vec2 p, int ch) {
    int k = int(floor(figT.x + 0.5)) - 1;
    vec4 r = MODE_LABEL_RECT;
    if (k < 0 || p.x < r.x || p.x > r.z || p.y < r.y || p.y > r.w)
        return -2.0;
    return glyphSample(vec2(p.x - r.x, GLYPH_CELL.y + float(k) * MODE_LABEL_SIZE.y + (p.y - r.y)), 1.0, ch);
}
// are we on data: the rows of printed figures, the time label and the captions of the figures (printed in a deeper ink than the board's own lettering)
bool onFigures(vec2 p) {
    vec4 r = MODE_LABEL_RECT;
    return (p.x > TXT_LINE0.x - float(TXT_CELLS) * TXT_LINE0.w - 0.5 && p.x < TXT_LINE0.x + 0.5 && p.y > TXT_LINE0.y - 2.2 && p.y < TXT_LINE1.y + 2.2)
        || (p.x > r.x && p.x < r.z && p.y > r.y && p.y < r.w) || onDataLabel(p);
}
// every silkscreen mark at a board point (mm, positive inside), in the family's channel: the static lettering, the printed figures and
// the time label. The figures and the label change with the scene's facts, which re-renders the cached board (rare).
float silkAll(vec2 p, int ch) {
    float v = silkSd(p, ch);
    if (onFigures(p)) {
        // the two printed lines through ONE call (the line is chosen by z): a second copy of the glyph lookup is compile time on every call site
        v = max(v, figTextSd(p, TXT_LINE0, txtA, ch));
        v = max(v, figTextSd(p, TXT_LINE1, txtB, ch));
    }
    return max(v, modeLabelSd(p, ch));
}

vec3 tileHue(int mat) {
    bool dk = frame.w > 0.5;
    if (mat == MAT_TILE_COMPUTE) return dk ? vec3(0.349, 0.553, 0.937) : vec3(0.267, 0.502, 0.957);
    if (mat == MAT_TILE_GRAPHICS) return dk ? vec3(0.337, 0.718, 0.765) : vec3(0.0, 0.745, 0.769);
    if (mat == MAT_TILE_SOC) return dk ? vec3(0.878, 0.675, 0.180) : vec3(0.941, 0.667, 0.043);
    return dk ? vec3(0.812, 0.408, 0.882) : vec3(0.784, 0.220, 0.776);
}

bool isTile(int m) {
    return m == MAT_TILE_COMPUTE || m == MAT_TILE_GRAPHICS || m == MAT_TILE_SOC || m == MAT_TILE_IO;
}

// @@INCLUDE board_edges.glsl

// the via ring around the package (inside the zone, 4-fold symmetric): a 2 mm grid centred on the
// zone, so a quarter turn maps it onto itself. Returns the dot's radius in mm (and its cell offset).
float viaCell(vec2 tex, out vec2 g) {
    vec2 d = abs(tex - ZONE_C);
    float r = max(d.x, d.y);
    g = vec2(9.0);
    if (inZone(tex) && r > ZONE_COURTYARD + 1.2 && r < ZONE_HALF - 1.0 && min(d.x, d.y) > 2.2) {
        g = (fract((tex - ZONE_C) / 2.0) - 0.5) * 2.0;     // mm from the dot's centre
        return length(g);
    }
    return 9.0;
}

// the courtyard outline: a square ring around the package, inside the zone. Signed mm, + inside the line.
float courtyardSd(vec2 tex) {
    vec2 d = abs(tex - ZONE_C);
    float r = max(d.x, d.y);
    return inZone(tex) ? 0.35 - abs(r - ZONE_COURTYARD) : -9.0;
}

// ---- the fields both families read ------------------------------------------------------------------------------------
// The two families draw the same board and ask it the same things -- the cores' edges, the silkscreen, the display's segments, a RAM stick's painted
// capacitors, the jack's contacts -- and a function called from both is two copies of it in the shader (Mesa inlines every call, and a function the size of
// the silkscreen's lookup or the segments' field is hundreds of instructions of compile time a copy). They are asked ONCE, in sharedFields (before the family
// branch, in shadeSurface), and handed over in these two globals. A surface is of ONE material, so the fields never coexist and two floats hold them all (seven
// floats, each a register held through the family's whole shading, are the cold compile's cost of sharing them); each reader checks the material it reads for.
//   gA   a tile's top: mm inside the core under the point (> 0; at most 0 where there is none)        the board's top and the DIP switch's: the silkscreen's field here (mm, positive inside a mark)
//        a display's top: its unlit-segment field (mm, positive inside)       a RAM stick's top: the painted MLCC's signed distance (positive inside)       the jack's mouth: mm to the nearest contact's edge
//   gB   the board's top and the DIP switch's: the silkscreen's field 0.2 mm toward the light (Material's carved slope reads both; Blueprint's ink the first)
//        a RAM stick's top: 1 where the pad is in its metal end
float gA;
float gB;

// ---- family 0: Material -------------------------------------------------------------------
// The shell's one material. The board is a raised plateau of the popup's surface; its parts stand
// proud of it like the shell's raised buttons (drop shadow, a highlight inside the edge); traces,
// lettering and the battery's wells are carved into it (inset shadow inside, a light bevel outside).
// The light comes from the upper left (light.xyz), and only its DIRECTION is used: shadows are the
// soft ones the shell draws, never a hard cast edge.

const float EVA_SIDE_K = 1.0;            // how far a side face falls from the top's tone (0 flat .. 1 as drawn)
const float EVA_SHADOW_K = 1.0;          // strength of the contact and drop shadows on the board

// mm inside a rectangle [x0, z0, x1, z1] (negative outside)
float rectSd(vec2 p, vec4 r) {
    vec2 d = min(p - r.xy, r.zw - p);
    return min(d.x, d.y);
}
// the lock bar's hazard stripes: on its top face (frame: the bar's own, so they travel with it) diagonal bands of `a` and `b`; a side keeps `side`
vec3 barStripes(Surf s, vec3 a, vec3 b, vec3 side) {
    if (s.nl.y < 0.5)
        return side;
    float ph = fract((s.pl.x - s.pl.z) / 2.6);
    return mix(a, b, smoothstep(0.46, 0.54, abs(ph - 0.5) * 2.0));
}

// @@INCLUDE board_eva.glsl

// the MLCCs painted on a RAM stick's plate (C: the first pad's min x z, the pitch, the count; p: the point, board x z): positive inside a pad, and `ends` is 1 in the
// metal end of the pad (the same split as an MLCC box's top)
float ramCapPad(vec4 C, vec2 p, out float ends) {
    float k = clamp(floor((p.x - C.x) / C.z), 0.0, C.w - 1.0);
    vec2 q = p - vec2(C.x + k * C.z, C.y);
    ends = 1.0 - smoothstep(0.30, 0.36, min(q.x, RAM_CAP.x - q.x));
    return min(min(q.x, RAM_CAP.x - q.x), min(q.y, RAM_CAP.y - q.y));
}
// the card's carved details, card frame (mm): fingers along the slot edge, four mounting holes with their
// pads, a border line along the long edges and the far end. Positive inside a carved line or hole.
float evaCardSd(vec3 bmin, vec3 bmax, vec2 q) {
    vec2 a = q - bmin.xz, b = bmax.xz - q;
    float ex = min(a.x, b.x), ez = min(a.y, b.y);
    float hr = length(vec2(ex, ez) - vec2(3.0));
    float hole = 0.95 - hr;
    float ring = 0.11 - abs(hr - 1.7);
    float border = 0.11 - abs(min(b.x, ez) - 1.1);
    border = min(border, a.x - 7.2);                                 // not through the fingers
    return max(hole, max(ring, border));
}

// ---- the bracket, RAM, ribbon and small parts: the shapes and marks both families draw ----------------------------------------------------------
// A round part (a cylinder: the box is its bound): the caps and the lock's screws
bool cylPart(Surf s) {
    return s.mat == MAT_CAP || s.mat == MAT_SCREW;
}
// The HDMI type-A receptacle's shell in the bracket's plane, q: mm from its centre (u along z, v up). Negative inside: 14 mm wide, the long
// top edge flat, the two LOWER corners chamfered (the real shell's trapezoid), the plastic tongue inside it and its gold contacts.
float hdmiSd(vec2 q) {
    vec2 h = vec2(BRK_HDMI.z, BRK_HDMI.w) * 0.5;
    float d = max(abs(q.x) - h.x, abs(q.y) - h.y);
    float ch = (abs(q.x) - q.y - (h.x + h.y - BRK_HDMI_CHAMFER)) * 0.70710678;
    return max(d, ch);
}
const float HDMI_TONGUE_Y = -0.2;                // the tongue's mid line, mm from the shell's centre
// the 19 contacts: ten on the tongue's upper face (1 mm pitch), nine on its lower, the two rows interleaved at the real 0.5 mm; positive inside one
float hdmiContacts(vec2 q) {
    float xu = q.x + 4.5, xl = q.x + 4.0;
    float du = min(0.24 - abs(xu - floor(xu + 0.5)), min(q.y - (HDMI_TONGUE_Y + 0.55), (HDMI_TONGUE_Y + 1.1) - q.y));
    float dl = min(0.24 - abs(xl - floor(xl + 0.5)), min(q.y - (HDMI_TONGUE_Y - 1.1), (HDMI_TONGUE_Y - 0.55) - q.y));
    return max(min(du, 5.0 - abs(q.x)), min(dl, 4.5 - abs(q.x)));
}
// the vents: slots cut in the plate (mm inside one, negative outside); the plate's own u = z, v = y
float ventSd(vec2 q) {
    float k = clamp(floor((q.x - BRK_VENT.x) / BRK_VENT.y + 0.5), 0.0, BRK_VENT.z - 1.0);
    float zc = BRK_VENT.x + k * BRK_VENT.y;
    return min(BRK_VENT.w * 0.5 - abs(q.x - zc), min(q.y - BRK_VENT_Y.x, BRK_VENT_Y.y - q.y));
}
// the gold fingers (card frame x z): stripes across the slot's width, in a band along its edge; positive inside a finger
float fingerSd(vec2 p) {
    float fz = abs(fract((p.y - FINGERS_RECT.y) / FINGERS.x) - 0.5) * FINGERS.x;
    return min(FINGERS.y * 0.5 - fz, min(min(p.x - FINGERS_RECT.x, FINGERS_RECT.z - p.x), min(p.y - FINGERS_RECT.y, FINGERS_RECT.w - p.y)));
}
// Material: those parts' marks, on top of the part's tone. Every small carved mark (a pin-1 dimple, a choke's winding, a vent, the HDMI
// cavity, a screw's recess ...) is ONE carve at the end: each part's branch only says what the mark is (its signed distance, the same shifted toward
// the light, its floor); the carve itself is shadeEva's one call at the end.
vec3 evaStage2(Surf s, EvaInk e, vec3 col, bool top, vec2 Ld, vec3 L, inout float xd, inout float xs, inout vec3 xfl, inout float xin) {
    float aa = aaMm();
    vec2 pl = s.pl.xz;
    float cd = -9.0, cd1 = -9.0;                 // the mark: mm inside it, and the same one 0.2 mm toward the light
    vec3 cfl = e.flr;                            // its floor
    float cin = 0.12;                            // its inset shadow's width
    vec2 c = (s.bmin.xz + s.bmax.xz) * 0.5;
    // ---- the card's gold fingers ----
    if (s.mat == MAT_CARD_PCB && top) {
        float fd = fingerSd(pl);
        float inF = smoothstep(-aa, aa, fd);
        col = mix(col, palL.rgb, inF);
        col = mix(col, e.hi, inF * (1.0 - smoothstep(0.0, 0.3, fd)) * 0.45);
    }
    // ---- the bracket: the rounded outline's bevel (the plate and its tongue are cut to it), the vents, the HDMI port on the plate's outer face ----
    if (s.mat == MAT_BRACKET) {
        float bwMm = 2.4 * max(tuneA.x, 0.6) / (0.70710678 * s.pxPerMm);
        col = mix(col, e.hi, (1.0 - smoothstep(0.0, bwMm, -s.cutD)) * (top ? 0.3 : 0.4));
        if (!top && s.nl.x > 0.5 && s.part == PART_IOPLATE) {
            vec2 lf = normalize(vec2(L.z, L.y));
            vec2 q = vec2(s.pl.z, s.pl.y);
            vec2 q1 = q + lf * 0.2;
            vec2 qh = q - BRK_HDMI.xy;
            float dv = ventSd(q), dv1 = ventSd(q1);
            float ds = -hdmiSd(qh);                                  // mm inside the shell
            float ds1 = -hdmiSd(qh + lf * 0.2);
            col = mix(col, mix(e.metal, e.hi, 0.7), smoothstep(-aa, aa, ds));                          // the shell's metal lip
            float dc = ds - 0.4, dc1 = ds1 - 0.4;                    // the cavity: the shell's wall is 0.4 mm
            bool inVent = dv > dc;
            cd = inVent ? dv : dc;
            cd1 = inVent ? dv1 : dc1;
            cfl = inVent ? mix(e.shd, vec3(0.0), 0.7) : mix(e.shd, vec3(0.0), 0.55);
            cin = inVent ? 0.12 : 0.5;
        } else if (top && s.part == PART_IOLIP) {
            cd = BRK_NOTCH.z - length(pl - BRK_NOTCH.xy);
            cd1 = cd;
            cfl = mix(e.shd, vec3(0.0), 0.3);
        }
    }
    // ---- the display ribbon: the film's lit edge, the conductors as copper laid in it (quiet: the ribbon is there to fill the corner) ----
    if (s.mat == MAT_RIBBON) {
        col = mix(col, e.hi, (1.0 - smoothstep(0.0, 0.5, -s.cutD)) * 0.5);
        if (top) {
            float cdd = ribbonCondSd();
            float line = smoothstep(-aa, aa, cdd);
            float rim = smoothstep(-aa, aa, cdd + 0.12) - line;
            col = mix(col, col * 0.86, rim);
            col = mix(col, palO.rgb, line * 0.85);
        }
    }
    // ---- the RAM's outline: the stick's tooth in the notch (the end wall's metal hook) and the mouth of the socket where the stick goes in (the housing's front face is not
    // a face of its box: the plate under it shows there, in the housing's own side tone). Neither the stick nor the housing is bent sheet: their edges take the standard bevel
    // along the cut outline (shadeEva's top branch), not the sheet-metal rim the bracket has -- which would tint the whole SIDE face of a cut box toward the lamp's white
    // (its distance to the outline is 0 all over) and take the foot's darkening with it, so the housing and its end walls would not stand on the board ----
    if (s.mat == MAT_RAM_PCB || s.mat == MAT_SOCKET) {
        if (s.mat == MAT_RAM_PCB && top) {
            col = mix(col, mix(e.metal, e.hi, 0.45), smoothstep(-aa, aa, -gTooth) * smoothstep(-aa, aa, -s.cutD));
            col = mix(col, e.sunk * (e.dk ? 0.5 : 0.8), 1.0 - smoothstep(RAM_SOCK.x - 0.04, RAM_SOCK.x + 0.04, pl.y));
            // the MLCCs painted on the plate's empty board: a body with a metal end each
            float ends = gB;
            float cdp = gA;
            col = mix(col, mix(mix(col, e.shd, 0.55), mix(e.metal, e.hi, 0.5), ends), smoothstep(-aa, aa, cdp));
        }
        if (s.mat == MAT_SOCKET && top) {
            // the end walls' clips: a metal tab along the wall's top where the hook is, the housing's seam along its middle
            float wx = min(pl.x - s.bmin.x, s.bmax.x - pl.x);
            if (wx < RAM_SOCK.y && pl.y > RAM_SOCK.x)
                col = mix(col, e.metal, smoothstep(-aa, aa, min(min(pl.y - (RAM_SOCK.x + 0.5), (s.bmax.z - 0.3) - pl.y), min(wx - 0.35, RAM_SOCK.y - 0.35 - wx))) * 0.95);
        }
    }
    // ---- the display connector: the slot the ribbon enters (a dark opening on its front face) and the flip-lock bar's lip ----
    if (s.mat == MAT_CONNECTOR && !top && s.nl.z > 0.5) {
        vec2 lf = normalize(vec2(L.x, L.y));
        vec2 q = vec2(pl.x - (CONN_SLOT.x + CONN_SLOT.y) * 0.5, s.pl.y - (CONN_SLOT.z + CONN_SLOT.w) * 0.5);       // the face's own axes: x along it, y up
        vec2 hq = vec2(CONN_SLOT.y - CONN_SLOT.x, CONN_SLOT.w - CONN_SLOT.z) * 0.5;
        vec2 dq = hq - abs(q);
        cd = min(dq.x, dq.y);
        cd1 = min(hq.x - abs(q.x + lf.x * 0.2), hq.y - abs(q.y + lf.y * 0.2));
        cfl = mix(e.shd, vec3(0.0), 0.6);
        cin = 0.3;
    }
    // ---- the small marks: a chip's pin-1 dimple, a choke's winding, a MOSFET's tab, a cap's ring, the sockets' seam, the flip-lock bar's lip ----
    if (top) {
        if (s.mat == MAT_RAM_CHIP) {
            cd = 0.3 - length(pl - s.bmin.xz - vec2(0.8));
        } else if (s.mat == MAT_CHOKE || s.mat == MAT_CAP) {
            cd = 0.14 - abs(length(pl - c) - (s.bmax.x - s.bmin.x) * (s.mat == MAT_CAP ? 0.3 : 0.31));
        } else if (s.mat == MAT_MOSFET) {
            cd = 0.11 - abs((pl.x - s.bmin.x) - (s.bmax.x - s.bmin.x) * 0.72);
            cin = 0.1;
        } else if (s.mat == MAT_SOCKET) {
            // the seam along the housing's middle (not across the end walls)
            float wx = min(pl.x - s.bmin.x, s.bmax.x - pl.x);
            cd = wx > RAM_SOCK.y && pl.y < RAM_SOCK.x ? 0.14 - abs((pl.y - s.bmin.z) - 1.3) : -9.0;
            cin = 0.1;
        } else if (s.mat == MAT_LATCH_BAR) {
            cd = 0.12 - abs((pl.y - s.bmin.z) - (s.bmax.z - s.bmin.z) * 0.78);              // the lip along its front edge
            cin = 0.1;
        }
        if (s.mat != MAT_BRACKET)
            cd1 = cd;
        if (s.mat == MAT_MLCC)
            col = mix(col, e.metal, 1.0 - smoothstep(0.30, 0.36, min(pl.x - s.bmin.x, s.bmax.x - pl.x)));
    }
    if (cd > -0.7) {
        xd = cd; xs = (cd1 - cd) / 0.2; xfl = cfl; xin = cin;
    }
    return col;
}

vec4 shadeEva(Surf s) {
    EvaInk e = evaInk();
    vec3 L = normalize(light.xyz);
    vec2 Ld = normalize(L.xz);
    bool top = s.nl.y > 0.5;
    float bw = max(tuneA.x, 0.6);
    float aa = aaMm();
    // ONE carved mark a pixel (a letter, a via, a hole, a socket's slot, the HDMI cavity ...): each branch below only says what the mark is -- its
    // signed distance (positive inside), the slope toward the light, its floor, its inset and rim widths -- and evaCarve, a heavy function that a shader
    // compiles once for every call, is called once at the end. The marks never overlap (they belong to different parts, or different places of one).
    float xd = -9.0, xs = 0.0, xin = 0.12, xrm = 0.25;
    vec3 xfl = e.flr;

    // ---- the part's own colour ----
    vec3 base = e.surf;
    if (s.mat == MAT_SLOT || s.mat == MAT_JACK || s.mat == MAT_PLUG || s.mat == MAT_CABLE || s.mat == MAT_GDDR || s.mat == MAT_DIP_BODY)
        base = e.sunk;
    else if (s.mat == MAT_BASE_DIE)
        base = mix(e.surf, e.sunk, 0.8);
    else if (isTile(s.mat))
        base = mix(e.surf, tileHue(s.mat), e.dk ? 0.30 : 0.30);
    else if (s.mat == MAT_GPU_DIE)
        base = mix(e.surf, e.sunk, 0.7);
    else if (s.mat == MAT_TERMINAL || s.mat == MAT_LATCH)
        base = e.metal;
    else if (s.mat == MAT_CELL)
        base = e.well;
    else if (s.mat == MAT_DISPLAY)
        base = palP.rgb;
    else if (s.mat == MAT_LOCK_BAR)
        base = barStripes(s, palK.rgb, mix(palI.rgb, palK.rgb, 0.12), mix(e.surf, palK.rgb, 0.4));
    else if (s.mat == MAT_LOCK_BODY || s.mat == MAT_SCREW)
        base = e.metal;
    else if (s.mat == MAT_DIP_LEVER)
        base = e.hi;
    else if (s.mat == MAT_BRACKET || s.mat == MAT_HEATSINK)
        base = e.metal;
    else if (s.mat == MAT_CHOKE || s.mat == MAT_MOSFET || s.mat == MAT_MLCC || s.mat == MAT_SOCKET || s.mat == MAT_CONNECTOR || s.mat == MAT_RAM_CHIP)
        base = e.sunk;
    else if (s.mat == MAT_CAP)
        base = mix(e.metal, e.sunk, 0.5);
    else if (s.mat == MAT_RAM_PCB)
        base = mix(e.sunk, e.shd, e.dk ? 0.3 : 0.6);               // darker than the chips on it and the metal in its notches
    else if (s.mat == MAT_RIBBON)
        base = mix(e.surf, palN.rgb, 0.8);
    else if (s.mat == MAT_LATCH_BAR)
        base = r3s1Latch.rgb;                                      // dark plastic
    else if (s.mat == MAT_PACK_TRAY || s.mat == MAT_CARD_PCB || s.mat == MAT_GPU_SUBSTRATE || s.mat == MAT_SUBSTRATE)
        base = e.surf;

    vec3 col = base;

    if (top) {
        float dPx; vec2 od;
        topEdge(s, dPx, od);
        if (cylPart(s)) {                                          // a round part: the edge is the circle, not the box
            vec2 dv = s.pl.xz - (s.bmin.xz + s.bmax.xz) * 0.5;
            float rr = length(dv);
            dPx = (0.5 * (s.bmax.x - s.bmin.x) - rr) * 0.70710678 * s.pxPerMm;
            od = dv / max(rr, 1e-4);
        } else if (s.mat == MAT_RAM_PCB || s.mat == MAT_SOCKET) {  // a part cut to an outline: its edge is the OUTLINE's (the notches, the housing's inner corners), not the box's
            float cutPx = -s.cutD * 0.70710678 * s.pxPerMm;
            if (cutPx < dPx) {
                dPx = cutPx;
                od = vec2(0.0);                                    // the outline's direction is not known here: a neutral edge
            }
        }
        float face = 0.5 + 0.5 * dot(od, Ld);                      // 1 when this edge faces the light
        if (s.mat == MAT_CELL) {
            // a carved well: inset shadow inside every edge, strongest where the light's wall is
            float ins = exp(-dPx / (bw * 1.6)) * (0.45 + 0.55 * face);
            col = mix(col, e.shd, ins * (e.dk ? 0.8 : 0.55));
            // the charge limit disables the 4th cell: its well sinks toward the deep tone by the lock's fraction
            if (s.part == PART_CELL3)
                col = mix(col, mix(e.well, e.shd, 0.6), lockP.z * (e.dk ? 0.55 : 0.5));
        } else {
            float hl = 1.0 - smoothstep(0.0, bw, dPx);              // the bevel inside the edge
            if (isTile(s.mat)) {
                // the category hue lives in the tile's rim, as it does in a header's inset shadow
                col = mix(col, tileHue(s.mat), (1.0 - smoothstep(0.0, bw * 2.2, dPx)) * 0.45);
            }
            col = mix(col, e.hi, hl * (e.dk ? 0.62 : 0.40) + hl * (e.dk ? 0.38 : 0.45) * face);
        }
    } else {
        // a side face: tone by orientation, darker toward the foot, the bevel carried over the top edge
        float dTop, dFoot, dVert, crease;
        sideEdges(s, dTop, dFoot, dVert, crease);
        float tone = s.n.z > 0.5 ? mix(1.0, e.dk ? 0.76 : 0.82, EVA_SIDE_K) : mix(1.0, e.dk ? 0.52 : 0.62, EVA_SIDE_K);
        if (cylPart(s)) {                                          // a round side: the tone follows the normal round it
            tone = mix(1.0, e.dk ? 0.5 : 0.6, 0.5 - 0.5 * dot(s.n.xz, Ld));
            crease = 0.0;
        }
        float footH = (s.part == PART_BOARD ? 2.4 : 3.0) * 0.70710678 * s.pxPerMm;
        float foot = mix(e.dk ? 0.56 : 0.72, 1.0, smoothstep(0.0, footH, dFoot));
        col = col * tone * foot;
        float hl = 1.0 - smoothstep(0.0, bw, dTop);
        col = mix(col, e.hi * tone, hl * 0.5);
        float cr = (1.0 - smoothstep(0.0, bw, dVert)) * crease;
        col = mix(col, e.hi * tone, cr * 0.45);
    }

    // ---- the board's top: shadows, grooves, engraving, vias ----
    if (s.part == PART_BOARD && top) {
        // soft contact shadow of everything resting on the board, and the drop of it away from the light
        vec2 bc = (BOARD_RECT.xy + BOARD_RECT.zw) * 0.5;
        col *= (e.dk ? 1.07 : 1.012) + dot(s.p.xz - bc, Ld) * (e.dk ? 0.0014 : 0.0006);      // the plateau brightens toward the light
        float occ = 1.0 - min(s.ao, s.ao2);
        col = mix(col, mix(e.surf, e.shd, e.dk ? 0.9 : 0.85), sat(occ * 2.0 * EVA_SHADOW_K));

        // grooves: the wall on the far side of the opening is what the camera sees there
        float d0 = s.traceD;
        if (d0 < 1.4) {
            float dq = s.traceDq;
            float slope = (s.traceDl - d0) / 0.45;
            float op = inside(d0, aa);
            float fl = inside(dq, aa);
            float face = (1.0 - smoothstep(-0.7, 0.7, slope));
            // the lip: a light rim just outside the opening, brightest on the edges that face the light
            float rimM = (1.0 - smoothstep(0.0, 0.6, d0)) * (1.0 - op) * (0.35 + 0.65 * face);
            col = mix(col, e.hi, rimM * 1.0);
            // the floor, shaded from the wall on the light's side; the wall the camera sees is darker still
            float ins = exp(-max(-dq, 0.0) / 0.55) * (0.30 + 0.70 * (1.0 - face));
            vec3 floorC = mix(e.flr, e.shd, ins * (e.dk ? 0.85 : 0.75));
            vec3 wallC = mix(e.flr, e.shd, e.dk ? 0.92 : 0.78);
            col = mix(col, mix(wallC, floorC, fl), op);
        }

        if (inZone(s.p.xz)) {
            // vias: small carved holes around the package; the courtyard: a carved line
            vec2 g;
            float r = viaCell(s.p.xz, g);
            float cd = courtyardSd(s.p.xz);
            if (r < 1.2) {
                float slope = r > 1e-3 ? -dot(g / r, Ld) : 0.0;
                xd = 0.5 - r; xs = slope; xfl = e.flr; xin = 0.22; xrm = 0.28;
            } else if (cd > -0.6 && d0 > 0.6) {      // a stub runs over the courtyard's line: the line stops at the stub's lip
                float cd1 = courtyardSd(s.p.xz + Ld * 0.25);
                xd = cd; xs = (cd1 - cd) / 0.25; xfl = e.flr; xin = 0.14; xrm = 0.30;
            }
        }
    }

    // ---- the contact darkening of what other parts stand on: the card's PCB, a RAM stick, the battery's tray -- the board's own, toward the same shade ----
    if (top && s.part != PART_BOARD && s.ao < 1.0)
        col = mix(col, e.shd, sat((1.0 - min(s.ao, s.ao2)) * 2.0 * EVA_SHADOW_K) * (e.dk ? 0.9 : 0.85));

    // ---- carved details: the card's fingers, holes and border; sockets, slots and screws ----
    if (top && s.part != PART_BOARD) {
        // the light along the part's own axes: the package's frame is the world's turned by its
        // turn (a base die resting a quarter round must still be lit from the lamp's side); the
        // board, card and plug only translate
        vec2 Ll = s.group == GRP_PKG ? rotYDir(vec3(Ld.x, 0.0, Ld.y), -gPkgTurn).xz : Ld;
        float d0 = -9.0, d1 = -9.0;
        bool hit = false;
        if (s.mat == MAT_CARD_PCB) {
            d0 = evaCardSd(s.bmin, s.bmax, s.pl.xz);
            d1 = evaCardSd(s.bmin, s.bmax, s.pl.xz + Ll * 0.2);
            hit = true;
        } else if (s.mat == MAT_GPU_DIE || s.mat == MAT_BASE_DIE) {
            vec2 a = s.pl.xz - s.bmin.xz, b = s.bmax.xz - s.pl.xz;
            vec2 a1 = a + Ll * 0.2, b1 = b - Ll * 0.2;
            d0 = 0.12 - abs(min(min(a.x, a.y), min(b.x, b.y)) - 1.0);
            d1 = 0.12 - abs(min(min(a1.x, a1.y), min(b1.x, b1.y)) - 1.0);
            hit = s.mat == MAT_GPU_DIE;
        } else if (s.mat == MAT_GDDR) {
            d0 = 0.38 - length(s.pl.xz - s.bmin.xz - vec2(1.1));
            d1 = 0.38 - length(s.pl.xz + Ll * 0.2 - s.bmin.xz - vec2(1.1));
            hit = true;
        } else if (s.mat == MAT_DIP_BODY) {
            vec2 q = s.pl.xz - vec2((s.bmin.x + s.bmax.x) * 0.5, DIP_CZ);
            vec2 q1 = q + Ll * 0.2;
            vec2 hs = vec2((s.bmax.x - s.bmin.x) * 0.5 - 2.2, 3.4);
            d0 = min(hs.x - abs(q.x), hs.y - abs(q.y));
            d1 = min(hs.x - abs(q1.x), hs.y - abs(q1.y));
            hit = true;
        } else if (s.mat == MAT_SLOT) {
            float cx = s.pl.x - (s.bmin.x + s.bmax.x) * 0.5;
            d0 = 1.1 - abs(cx);
            d1 = 1.1 - abs(cx + Ll.x * 0.2);
            hit = true;
        } else if (s.mat == MAT_LATCH) {
            vec2 q = s.pl.xz - (s.bmin.xz + s.bmax.xz) * 0.5;
            d0 = 1.5 - length(q);
            d1 = 1.5 - length(q + Ll * 0.2);
            hit = true;
        } else if (s.mat == MAT_PACK_TRAY) {
            vec2 a = s.pl.xz - s.bmin.xz, b = s.bmax.xz - s.pl.xz;
            vec2 a1 = a + Ll * 0.2, b1 = b - Ll * 0.2;
            d0 = 0.11 - abs(min(min(a.x, a.y), min(b.x, b.y)) - 2.55);
            d1 = 0.11 - abs(min(min(a1.x, a1.y), min(b1.x, b1.y)) - 2.55);
            hit = true;
        }
        if (hit && d0 > -0.7) {
            xd = d0; xs = (d1 - d0) / 0.2; xfl = s.mat == MAT_SLOT ? e.shd : e.flr; xin = 0.18; xrm = 0.30;
        }
    }
    // ---- engraved lettering: the board's top outside the zone, and the DIP switch's top face (its 80 / 100 stand in the front margin of it) ----
    if (top && ((s.part == PART_BOARD && !inZone(s.p.xz)) || s.part == PART_DIPBODY)) {
        float sd0 = gA, sd1 = gB;                   // sharedFields: the field here and 0.2 mm toward the light
        if (sd0 > -0.6) {
            float inkK = onFigures(s.p.xz) ? (e.dk ? 0.95 : 0.80) : (e.dk ? 0.75 : 0.40);       // data in a deeper ink than the board's lettering
            if (s.part == PART_DIPBODY) {
                // the switch's legend is PRINTED, not engraved, in a dark ink (light) / a light one (dark): it has to read at 1x
                col = mix(col, e.dk ? e.ink : mix(palI.rgb, e.ink, 0.2), smoothstep(-aa, aa, sd0) * 0.95);
            } else {
                xd = sd0; xs = (sd1 - sd0) / 0.2; xfl = mix(e.flr, e.ink, inkK); xin = 0.16; xrm = 0.30;
            }
        }
    }
    // ---- a 7-segment display: the window sunk into the module's top face, the unlit segments faint in it, both seen through the smoked glass ----
    if (top && s.mat == MAT_DISPLAY) {
        int di = segIndexOf(s.part);
        vec4 wr = segWindow(di);
        float dw = rectSd(s.pl.xz, wr);
        float inW = smoothstep(-aa, aa, dw);
        col = mix(col, palI.rgb * r3s2A.rgb, inW);
        col = mix(col, palJ.rgb * glassGhost(), smoothstep(-aa, aa, gA) * inW);
        col = glassEva(col, s.pl.xz, wr, inW, e.hi, e.dk, Ld);
    }
    // ---- the lock's screws: a slot across the head ----
    if (top && s.mat == MAT_SCREW) {
        vec2 q = s.pl.xz - (s.bmin.xz + s.bmax.xz) * 0.5;
        float sl = 0.13 - abs(q.x + q.y * 0.6);
        col = mix(col, e.shd, smoothstep(-aa, aa, sl) * 0.75);
    }
    if (s.mat == MAT_JACK && !top && s.n.x > 0.5) {
        // the socket: a carved round mouth on the face the plug comes to; its bore is dark (the pin and the contacts in it are painted after the carve)
        vec2 q = vec2(s.pl.z - (s.bmin.z + s.bmax.z) * 0.5, s.pl.y - (s.bmin.y + s.bmax.y) * 0.5);
        float r = length(q);
        vec2 lf = normalize(vec2(L.z, L.y));                         // the light along the face's own axes (z, y)
        xd = JACK_R - r; xs = -dot(q / max(r, 1e-3), lf); xfl = mix(e.shd, vec3(0.0), 0.7); xin = 0.30; xrm = 0.30;
    }
    if (s.part == PART_PLUG) {
        // an engraved ring where the grip meets the barrel (the barrel is its own part)
        float x = s.pl.x - s.bmin.x - 1.2;
        xd = 0.16 - abs(x); xs = x > 0.0 ? -0.4 : 0.4; xfl = e.flr; xin = 0.12; xrm = 0.28;
    }
    if (s.part == PART_BOARD && top && !inZone(s.p.xz)) {
        // two mounting holes at the front corners
        vec2 h0 = vec2(BOARD_RECT.x + 5.0, BOARD_RECT.w - 5.0);
        vec2 h1 = vec2(BOARD_RECT.z - 5.0, BOARD_RECT.w - 5.0);
        vec2 dh0 = s.p.xz - h0, dh1 = s.p.xz - h1;
        float r0 = length(dh0), r1 = length(dh1);
        float rr = min(r0, r1);
        if (rr < 3.0) {
            vec2 dh = r0 < r1 ? dh0 : dh1;
            float sl = -dot(dh / max(rr, 1e-3), Ld);
            if (rr < 1.5) {
                xd = 1.05 - rr; xs = sl; xfl = mix(e.flr, e.shd, 0.4); xin = 0.22; xrm = 0.30;
            } else {
                xd = 0.12 - abs(rr - 1.9); xs = sl * 0.5; xfl = e.flr; xin = 0.10; xrm = 0.25;
            }
        }
    }

    // ---- cores: carved squares in the tile tops ----
    if (top && isTile(s.mat) && gA > 0.0)
        col = mix(col, e.shd, exp(-gA / 0.28) * (e.dk ? 0.30 : 0.14));
    col = evaStage2(s, e, col, top, Ld, L, xd, xs, xfl, xin);
    col = evaCarve(e, col, xfl, xd, xs, xin, xrm, aa, 0.9);
    // the DC jack's mouth with nothing plugged in: in the dark bore the centre pin stands up as a pale metal disc with the lamp's glint on it, and three small gold
    // contacts sit on the bore's wall (the plug covers all of it when it is in)
    if (s.mat == MAT_JACK && !top && s.n.x > 0.5) {
        vec2 q = vec2(s.pl.z - (s.bmin.z + s.bmax.z) * 0.5, s.pl.y - (s.bmin.y + s.bmax.y) * 0.5);
        float r = length(q);
        vec2 lf = normalize(vec2(L.z, L.y));
        float pin = smoothstep(-aa, aa, JACK_PIN - r);
        vec3 pc = mix(e.metal, e.hi, 0.25) * mix(0.72, 1.0, 0.5 + 0.5 * dot(q / max(r, 1e-3), lf));      // it stands deep in the bore: a little under the plug's metal, lighter toward the lamp
        col = mix(col, pc * (e.dk ? 0.85 : 1.0), pin);
        col = mix(col, e.hi, pin * (1.0 - smoothstep(0.0, 0.16, JACK_PIN - r)) * 0.4);                          // its edge catches the light
        col = mix(col, palL.rgb, smoothstep(-aa, aa, -gA) * smoothstep(-aa, aa, JACK_R - 0.15 - r));
    }
    // the HDMI port's tongue and its gold contacts lie IN the cavity the carve just made: painted after it
    if (s.mat == MAT_BRACKET && !top && s.nl.x > 0.5 && s.part == PART_IOPLATE) {
        vec2 qh = vec2(s.pl.z, s.pl.y) - BRK_HDMI.xy;
        float inCav = smoothstep(-aa, aa, -hdmiSd(qh) - 0.4);
        float tg = min(5.3 - abs(qh.x), 0.5 - abs(qh.y - HDMI_TONGUE_Y));
        col = mix(col, mix(e.sunk, e.hi, 0.35), smoothstep(-aa, aa, tg) * inCav);
        col = mix(col, palL.rgb, smoothstep(-aa, aa, hdmiContacts(qh)) * inCav);
    }
    return vec4(col, 1.0);
}

// ---- family 1: Blueprint ----------------------------------------------------------------------
// A technical drawing: white paper and blue ink (a cyanotype in dark mode: white lines on Prussian
// blue). Every edge is inked -- a silhouette heavier than a crease -- the shaded sides are hatched
// with vertical strokes (denser on the side turned from the light), the sheet carries a drafting
// grid with centre lines through the zone, and the traces are drawn as lines: a power trace as a
// double line, a signal as a single one. The light is coloured ink (glow_materials.glsl).

// @@INCLUDE board_ink.glsl
// Blueprint's smoked pane over a display's window, drawn: a fine hatch and the pane's outline a hair inside the window's frame, heavier on the edges
// that face the lamp. `k` is the screen px of a mm across a face, `lw` the crease weight in px.
vec3 glassBp(vec3 col, vec2 p, vec4 wr, float dw, float inW, float k, float lw, vec3 ink, vec3 faint, vec2 Ld) {
    col = mix(col, faint, glassHatch(p, pxMm()) * inW * 0.16);
    float m;
    float face = glassFacing(p, wr, Ld, m);
    return mix(col, ink, inkLine(abs(dw - 0.22) * k, lw * 0.8) * inW * (0.30 + 0.45 * max(face, 0.0)));
}

bool isSilhouette(Surf s, vec3 outLocal) {
    return dot(groupNormal(s.group, outLocal), V_CAM) <= 0.0;
}

// the inked edges of the hit face: heavy where the face meets the background or a farther surface,
// light at a crease with the other visible side or a contact line
float edgeInk(Surf s, float wSil, float wIn) {
    float k = 0.70710678 * s.pxPerMm;
    vec3 a = (s.pl - s.bmin) * k;
    vec3 b = (s.bmax - s.pl) * k;
    float ink = 0.0;
    if (s.nl.y > 0.5) {
        ink = max(ink, inkLine(a.x, isSilhouette(s, vec3(-1.0, 0.0, 0.0)) ? wSil : wIn));
        ink = max(ink, inkLine(b.x, isSilhouette(s, vec3(1.0, 0.0, 0.0)) ? wSil : wIn));
        ink = max(ink, inkLine(a.z, isSilhouette(s, vec3(0.0, 0.0, -1.0)) ? wSil : wIn));
        ink = max(ink, inkLine(b.z, isSilhouette(s, vec3(0.0, 0.0, 1.0)) ? wSil : wIn));
    } else {
        bool alongZ = abs(s.nl.x) > 0.5;
        float u0 = alongZ ? a.z : a.x;
        float u1 = alongZ ? b.z : b.x;
        vec3 o0 = alongZ ? vec3(0.0, 0.0, -1.0) : vec3(-1.0, 0.0, 0.0);
        vec3 o1 = -o0;
        ink = max(ink, inkLine(u0, isSilhouette(s, o0) ? wSil : wIn));
        ink = max(ink, inkLine(u1, isSilhouette(s, o1) ? wSil : wIn));
        ink = max(ink, inkLine(b.y, wIn));                                  // the top edge: a crease
        bool floating = s.group == GRP_CARD || s.group == GRP_PLUG || s.part == PART_BOARD;
        ink = max(ink, inkLine(a.y, floating ? wSil : wIn));                // the foot
    }
    return ink;
}

// Blueprint: those parts' marks (coloured ink and washes over the drawing). As in Material, each part's branch only says which line to ink
// (the distance to it, its weight); the one inkLine is at the end.
vec3 bpStage2(Surf s, vec3 col, bool top, vec3 paper, vec3 ink, vec3 faint, vec3 wash, float lw) {
    float aa = aaMm();
    float k = 0.70710678 * s.pxPerMm;
    vec2 pl = s.pl.xz;
    vec2 c = (s.bmin.xz + s.bmax.xz) * 0.5;
    float ld = 1e3;                 // mm to the line this pixel inks
    float lwt = lw;                 // its weight, px
    float la = 0.9;                 // and its strength
    if (s.mat == MAT_CARD_PCB && top) {
        float fd = fingerSd(pl);
        col = mix(col, mix(wash, palL.rgb, 0.85), inside(-fd, aa));
        ld = abs(fd);
        lwt = lw * 0.8;
        la = 0.7;
    }
    if (s.mat == MAT_BRACKET) {
        ld = abs(s.nl.x) > 0.5 ? abs(s.cutD) : 1e3;     // the outline is inked on the plate's two broad faces; the faces that ARE the outline (the rim on top, the ends) have a distance of 0 all over and would fill with ink: the hatch shades them
        lwt = lw * 0.9;
        la = 0.95;
        if (!top && s.nl.x > 0.5 && s.part == PART_IOPLATE) {
            vec2 q = vec2(s.pl.z, s.pl.y);
            float dv = ventSd(q);
            vec2 qh = q - BRK_HDMI.xy;
            float ds = -hdmiSd(qh);
            float dc = ds - 0.4;
            col = mix(col, faint, inside(-dv, aa) * 0.6);
            col = mix(col, mix(ink, faint, 0.25), inside(-dc, aa) * 0.85);
            float tg = min(5.3 - abs(qh.x), 0.5 - abs(qh.y - HDMI_TONGUE_Y));
            col = mix(col, wash, smoothstep(-aa, aa, tg) * smoothstep(-aa, aa, dc));
            col = mix(col, palL.rgb, smoothstep(-aa, aa, hdmiContacts(qh)) * smoothstep(-aa, aa, dc));
            ld = min(ld, min(abs(dv), abs(ds)));
            lwt = lw;
        } else if (top && s.part == PART_IOLIP) {
            col = mix(col, paper, inside(length(pl - BRK_NOTCH.xy) - BRK_NOTCH.z, aa) * 0.9);       // the screw notch is a hole in the hatched sheet: the paper shows through
            ld = min(ld, abs(length(pl - BRK_NOTCH.xy) - BRK_NOTCH.z));
        }
    }
    if (s.mat == MAT_RIBBON) {
        // the film: a pale amber wash hatched with fine diagonal strokes (the cells' idiom), the conductors in ink along it
        col = mix(wash, palN.rgb, 0.45);
        float hd = fract((pl.x + pl.y) / 1.1);
        col = mix(col, faint, inkLine(abs(hd - 0.5) * 1.1 * k, 0.8) * 0.75);
        if (top) {
            float cdc = ribbonCondLine();                           // each conductor one inked line along the strip, like a signal trace
            col = mix(col, ink, inkLine(cdc * k, lw * 0.9) * 0.85 * step(cdc, 1.0));
        }
        ld = abs(s.cutD);
        lwt = lw * 1.55;
        la = 0.95;
    }
    // the RAM: the plate's and the socket's outlines inked along their cut edges, the tooth in the notch filled, the mouth of the socket dark
    if (s.mat == MAT_RAM_PCB || s.mat == MAT_SOCKET) {
        ld = top ? abs(s.cutD) : 1e3;                    // as the bracket's: the outline is inked on the broad faces only
        lwt = lw;
        la = 0.9;
        if (s.mat == MAT_RAM_PCB && top) {
            col = mix(col, ink, smoothstep(-aa, aa, -gTooth) * smoothstep(-aa, aa, -s.cutD) * 0.85);
            col = mix(col, faint, (1.0 - smoothstep(RAM_SOCK.x - 0.04, RAM_SOCK.x + 0.04, pl.y)) * 0.8);
            // the MLCCs painted on the plate's empty board: a wash pad, inked, its metal ends filled
            float ends = gB;
            float cdp = gA;
            col = mix(col, wash, smoothstep(-aa, aa, cdp));
            col = mix(col, ink, ends * smoothstep(-aa, aa, cdp) * 0.7);
            col = mix(col, ink, inkLine(abs(cdp) * k, 0.7) * 0.85 * step(-0.2, cdp));
        }
        if (s.mat == MAT_SOCKET && top) {
            float wx = min(pl.x - s.bmin.x, s.bmax.x - pl.x);
            if (wx < RAM_SOCK.y && pl.y > RAM_SOCK.x)
                col = mix(col, ink, smoothstep(-aa, aa, min(min(pl.y - (RAM_SOCK.x + 0.5), (s.bmax.z - 0.3) - pl.y), min(wx - 0.35, RAM_SOCK.y - 0.35 - wx))) * 0.8);
        }
    }
    // the display connector: the slot filled in ink on its front face, the flip-lock bar an ink-filled strip with a lip line along its front
    if (s.mat == MAT_CONNECTOR && !top && s.nl.z > 0.5) {
        vec2 q = vec2(pl.x - (CONN_SLOT.x + CONN_SLOT.y) * 0.5, s.pl.y - (CONN_SLOT.z + CONN_SLOT.w) * 0.5);
        vec2 hq = vec2(CONN_SLOT.y - CONN_SLOT.x, CONN_SLOT.w - CONN_SLOT.z) * 0.5;
        col = mix(col, palI.rgb, smoothstep(-aa, aa, min(hq.x - abs(q.x), hq.y - abs(q.y))) * 0.92);
    }
    if (s.mat == MAT_LATCH_BAR) {
        if (top) {
            // line shading, not a flat ink: the bar's top a wash hatched in the latch's own ink (its sides keep the family's vertical hatch)
            float lh = fract((s.pl.x + s.pl.z) / 0.8);
            col = mix(wash, r3s1Latch.rgb, inkLine(abs(lh - 0.5) * 0.8 * s.pxPerMm * 0.70710678, 0.9) * 0.9);
        }
        if (top) {
            ld = abs((pl.y - s.bmin.z) - (s.bmax.z - s.bmin.z) * 0.78);
            lwt = 0.7;
            la = 0.55;
        }
    }
    if (top) {
        if (s.mat == MAT_RAM_CHIP) {
            ld = abs(length(pl - s.bmin.xz - vec2(0.8)) - 0.3);
            lwt = 0.7;
        } else if (s.mat == MAT_CHOKE || s.mat == MAT_CAP) {
            ld = abs(length(pl - c) - (s.bmax.x - s.bmin.x) * (s.mat == MAT_CAP ? 0.3 : 0.31));
            lwt = 0.7;
            la = 0.85;
        } else if (s.mat == MAT_MOSFET) {
            ld = abs((pl.x - s.bmin.x) - (s.bmax.x - s.bmin.x) * 0.72);
            lwt = 0.7;
            la = 0.8;
        } else if (s.mat == MAT_SOCKET) {
            // the housing's seam (not across the end walls): the nearer of it and the outline's line
            float wx = min(pl.x - s.bmin.x, s.bmax.x - pl.x);
            if (wx > RAM_SOCK.y && pl.y < RAM_SOCK.x && abs((pl.y - s.bmin.z) - 1.3) < ld) {
                ld = abs((pl.y - s.bmin.z) - 1.3);
                lwt = 0.7;
                la = 0.7;
            }
        } else if (s.mat == MAT_MLCC) {
            col = mix(col, ink, (1.0 - smoothstep(0.30, 0.36, min(pl.x - s.bmin.x, s.bmax.x - pl.x))) * 0.7);
        }
    }
    if (ld < 1e2)
        col = mix(col, ink, inkLine(ld * k, lwt) * la);
    return col;
}

vec4 shadeBlueprint(Surf s) {
    bool dk = frame.w > 0.5;
    vec3 L = normalize(light.xyz);
    bool top = s.nl.y > 0.5;
    float lw = max(tuneA.x, 0.6);                    // the crease weight, px
    float lwS = lw * 1.55;                           // the silhouette weight
    vec3 paper = palA.rgb, ink = palB.rgb, faint = palC.rgb, gridC = palD.rgb, wash = palE.rgb;
    float aa = aaMm();
    vec3 col = paper;
    // the lettering: the board's top outside the zone and the DIP switch's top face (its 80 / 100): ONE lookup
    float letter = -9.0;
    if (top && ((s.part == PART_BOARD && !inZone(s.p.xz)) || s.part == PART_DIPBODY))
        letter = gA;                                // sharedFields: the lettering's field here

    if (s.part == PART_BOARD && top) {
        // the sheet: faint grain, the drafting grid (centred on the zone, so its quarter turn keeps it)
        float grain = (vnoise(s.p.xz * 3.1) - 0.5) * (tuneA.w > 0.0 ? tuneA.w : 0.018);   // world space: the same grain under the board and the patch
        col += vec3(grain);
        vec2 gq = s.p.xz - ZONE_C;
        vec2 g5 = (0.5 - abs(fract(gq / 5.0) - 0.5)) * 5.0;          // mm from the nearest 5 mm line
        float minor = inkLine(min(g5.x, g5.y) * s.pxPerMm, 0.7);
        vec2 g25 = (0.5 - abs(fract(gq / 25.0) - 0.5)) * 25.0;
        float major = inkLine(min(g25.x, g25.y) * s.pxPerMm, 0.9);
        col = mix(col, gridC, minor * 0.65);
        col = mix(col, mix(gridC, faint, 0.55), major * 0.75);
        // the centre lines through the zone: dash, gap, dot -- along both axes alike
        vec2 cl = abs(gq);
        float onX = inkLine(cl.y * s.pxPerMm, 0.8);                  // the line along x (z = zone centre)
        float onZ = inkLine(cl.x * s.pxPerMm, 0.8);
        float along = max(cl.x, cl.y);                               // distance from the centre along the line
        float ph = mod(along, 14.0);
        float dash = (ph < 8.0 || (ph > 9.6 && ph < 10.6)) ? 1.0 : 0.0;
        float cline = max(onX * step(cl.y, cl.x), onZ * step(cl.x, cl.y)) * dash;
        col = mix(col, faint, cline * 0.9);
        // shadows, as a draftsman hatches them: diagonal strokes where the light does not reach
        float hs = (1.0 - s.lit) * light.w;
        float hd = fract((s.p.x + s.p.z) / 1.35);
        col = mix(col, faint, hs * inkLine(abs(hd - 0.5) * 1.35 * s.pxPerMm * 0.70710678, 0.8) * 0.65);
        // traces
        float d0 = s.traceD;
        if (s.traceKind >= 0) {
            // a thin trace is drawn as ONE centre line, a wide one as two edge lines over a wash; a trace that narrows
            // along itself (a stub's body fanning into lanes) goes from the one to the other by its own width here
            // (the generator packs the nearest stretch's own centre-line distance into the kind, see silicon_shader_gen.js: a thin trace's one line is drawn ON
            // its centre line -- a contour of the union's depth would run round the body of a wide trace beside it at a T)
            float lrd = floor(float(s.traceKind) * 0.25) / 1024.0;
            float wide = smoothstep(0.5, 0.95, s.traceHalf);
            float fillM = inside(d0, aa);
            col = mix(col, wash, fillM * 0.75 * wide);
            float line = mix(inkLine(lrd * s.pxPerMm * 0.70710678, lw), inkLine(abs(d0) * s.pxPerMm * 0.70710678, lw), wide);
            col = mix(col, ink, line * 0.95);
        }
        // the courtyard (the lettering is drawn below, the one lookup for the board and the DIP switch's top)
        if (inZone(s.p.xz)) {
            vec2 cq = abs(s.p.xz - ZONE_C);
            col = mix(col, ink, inkLine(abs(max(cq.x, cq.y) - ZONE_COURTYARD) * s.pxPerMm * 0.70710678, lw * 1.2) * 0.95 * (1.0 - inside(d0, aa)));      // a stub runs over the line
        }
        vec2 g;
        float r = viaCell(s.p.xz, g);
        if (r < 1.2)
            col = mix(col, ink, inkLine(abs(r - 0.42) * s.pxPerMm * 0.70710678, lw * 0.85) * 0.8);
    } else if (top) {
        // a part's top: a light wash so it stands off the sheet
        col = mix(paper, wash, 0.28);
        // what stands on this surface (the card's PCB, a RAM stick, the battery's tray) shades it round its foot, as a draftsman does: the SAME diagonal strokes the sheet's cast
        // shadows are hatched with (pitch, angle, weight, ink), their coverage following the occlusion. A colour wash (a fill) is not this family's
        // shading.
        float occ = 1.0 - min(s.ao, s.ao2);
        float ch = fract((s.p.x + s.p.z) / 1.35);
        col = mix(col, faint, sat(occ * 2.0) * inkLine(abs(ch - 0.5) * 1.35 * s.pxPerMm * 0.70710678, 0.8) * 0.65);
        col = mix(col, ink, inside(-letter, aa) * (s.part == PART_DIPBODY ? 1.0 : 0.0));
        // The I/O bracket is ONE bent sheet of metal: the plate's thin top edge (the rim) is so narrow that its two inked edges fill it, and it read as solid ink; the
        // flange bent over it is wide enough to show its wash, and the two halves of one sheet would sit in opposite tones (dark rim / light flange by day, the reverse
        // by night). Every top face of the sheet takes the ink the rim takes, so rim and flange are one piece.
        if (s.mat == MAT_BRACKET) {
            // line shading, not a flat ink: the sheet's tops are a wash under a close diagonal hatch (the rim is narrow enough for its two inked edges to close it)
            float bh = fract((s.pl.x + s.pl.z) / 0.9);
            col = mix(wash, ink, inkLine(abs(bh - 0.5) * 0.9 * s.pxPerMm * 0.70710678, 0.9) * 0.9);
        }
        if (s.mat == MAT_LOCK_BAR) {
            // the lock bar: the hazard stripes drawn in the amber ink
            float ph = fract((s.pl.x - s.pl.z) / 2.6);
            col = mix(wash, palK.rgb, (1.0 - smoothstep(0.46, 0.54, abs(ph - 0.5) * 2.0)) * 0.9);
        }
        if (s.mat == MAT_CELL && s.part == PART_CELL3) {
            // the charge limit disables the 4th cell: hatched in ink by the lock's fraction
            float h1 = fract((s.pl.x + s.pl.z) / 1.4);
            col = mix(col, ink, inkLine(abs(h1 - 0.5) * 1.4 * s.pxPerMm * 0.70710678, 0.8) * lockP.z * 0.6);
        }
        if (s.mat == MAT_DISPLAY) {
            // a 7-segment display: the window filled in the deep ink, the unlit segments in it, an inked frame round it, the smoked pane drawn over it
            int di = segIndexOf(s.part);
            vec4 wr = segWindow(di);
            float dw = rectSd(s.pl.xz, wr);
            float inW = smoothstep(-aa, aa, dw);
            col = mix(col, palI.rgb * r3s2A.rgb, inW);
            col = mix(col, palJ.rgb * glassGhost(), smoothstep(-aa, aa, gA) * inW);
            col = glassBp(col, s.pl.xz, wr, dw, inW, s.pxPerMm * 0.70710678, lw, ink, faint, normalize(L.xz));
            col = mix(col, ink, inkLine(abs(dw) * s.pxPerMm * 0.70710678, lw) * 0.9);
        }
    } else {
        // a side: washed and hatched with vertical strokes, closer where it turns from the light
        bool lit = s.n.z > 0.5;
        col = mix(paper, wash, lit ? 0.62 : 0.95);
        bool alongZ = abs(s.nl.x) > 0.5;
        float u = alongZ ? s.pl.z : s.pl.x;
        float pitch = lit ? 2.1 : 1.15;
        float hu = fract(u / pitch);
        float stroke = inkLine(abs(hu - 0.5) * pitch * s.pxPerMm * 0.70710678, lit ? 0.7 : 0.8);
        col = mix(col, faint, stroke * (lit ? 0.5 : 0.75));
    }

    if (s.part == PART_BOARD && top)
        col = mix(col, ink, inside(-letter, aa));

    // the parts' own marks
    if (top && isTile(s.mat) && gA > 0.0) {
        float dd = gA;
        col = mix(col, ink, inkLine(abs(dd) * s.pxPerMm * 0.70710678, 0.8) * 0.8);
        col = mix(col, wash, inside(-dd, aa) * 0.4);
    }
    if (top && s.mat == MAT_GPU_DIE) {
        vec2 q = (s.pl.xz - (s.bmin.xz + s.bmax.xz) * 0.5);
        float dgl = min(abs(q.x - q.y), abs(q.x + q.y)) * 0.70710678;
        col = mix(col, ink, inkLine(dgl * s.pxPerMm * 0.70710678, 0.7) * 0.7);          // an X: a die
    }
    if (top && s.mat == MAT_GDDR) {
        vec2 q = s.pl.xz - s.bmin.xz;
        col = mix(col, ink, inkLine(abs(length(q - vec2(1.2)) - 0.45) * s.pxPerMm * 0.70710678, 0.7) * 0.9);   // pin 1
    }
    if (top && s.mat == MAT_CELL) {
        float hd = fract((s.pl.x + s.pl.z) / 2.2);
        col = mix(col, faint, inkLine(abs(hd - 0.5) * 2.2 * s.pxPerMm * 0.70710678, 0.7) * 0.45);
    }
    if (top && s.mat == MAT_JACK) {
        vec2 q = s.pl.xz - (s.bmin.xz + s.bmax.xz) * 0.5;
        col = mix(col, ink, inkLine(abs(length(q) - 2.4) * s.pxPerMm * 0.70710678, 0.8) * 0.8);
    }
    if (s.mat == MAT_JACK && !top && s.nl.x > 0.5) {
        // the DC jack's mouth with nothing plugged in: a dark bore ringed in ink, the centre pin a paler disc in it, three small gold contacts on its wall
        vec2 q = vec2(s.pl.z - (s.bmin.z + s.bmax.z) * 0.5, s.pl.y - (s.bmin.y + s.bmax.y) * 0.5);
        float r = length(q);
        col = mix(col, palI.rgb, inside(r - JACK_R, aa));
        col = mix(col, mix(palI.rgb, ink, 0.6), inside(r - JACK_PIN, aa));
        col = mix(col, palL.rgb, smoothstep(-aa, aa, -gA) * inside(r - (JACK_R - 0.15), aa));
        col = mix(col, ink, inkLine(abs(r - JACK_R) * s.pxPerMm * 0.70710678, lw) * 0.9);
    }

    col = bpStage2(s, col, top, paper, ink, faint, wash, lw);
    // the sheet-metal bracket is thin (its rim and its side faces are under a millimetre), so two silhouette-weight lines would fill them with ink: its edges are creases
    float e = edgeInk(s, s.mat == MAT_BRACKET ? lw * 0.8 : lwS, s.mat == MAT_BRACKET ? lw * 0.8 : lw);
    col = mix(col, ink, e);
    return vec4(col, 1.0);
}

// Every field the two families share, asked once (see the globals above).
void sharedFields(Surf s) {
    bool top = s.nl.y > 0.5;
    vec2 pl = s.pl.xz;
    gA = -9.0;
    gB = 0.0;
    if (top && isTile(s.mat)) {
        // the carved core under the point: mm to its edge (the cores' rects are the generated coreRectOf's: picked, not folded into the arithmetic, which keeps this
        // bit for bit what each family computes on its own)
        vec2 q = pl - ZONE_C;
        int c = coreAt(q);
        if (c >= 0) {
            vec4 cr = coreRectOf(c);
            gA = min(min(q.x - cr.x, cr.z - q.x), min(q.y - cr.y, cr.w - q.y));
        }
    } else if (top && ((s.part == PART_BOARD && !inZone(s.p.xz)) || s.part == PART_DIPBODY)) {
        // the lettering: the field here and, for Material, 0.2 mm toward the light, through ONE call of the (big) lookup in a loop whose bound comes from a uniform
        vec2 Ld = normalize(normalize(light.xyz).xz);
        int ch = view.w < 0.5 ? 0 : 1;
        int nk = (quad.z > 0.5 && view.w < 0.5) ? 2 : 1;
        for (int k = 0; k < nk; k++) {
            float v = silkAll(k == 0 ? s.p.xz : s.p.xz + Ld * 0.2, ch);
            if (k == 0) {
                gA = v;
                gB = v;
            } else {
                gB = v;
            }
            if (gA < -0.6)
                break;
        }
    } else if (top && s.mat == MAT_DISPLAY) {
        gA = segFieldSd(segIndexOf(s.part), pl, vec4(0.0), true);
    } else if (top && s.mat == MAT_RAM_PCB) {
        gA = ramCapPad(s.part == PART_RAMPCBA ? RAM_CAPA : RAM_CAPB, pl, gB);
    } else if (s.mat == MAT_JACK && !top && s.nl.x > 0.5) {
        gA = jackContacts(vec2(s.pl.z - (s.bmin.z + s.bmax.z) * 0.5, s.pl.y - (s.bmin.y + s.bmax.y) * 0.5));
    }
}

vec4 shadeSurface(Surf s) {
    sharedFields(s);
    return view.w < 0.5 ? shadeEva(s) : shadeBlueprint(s);
}

// p: board space on the ground plane; sd: signed mm from the board's (shadow-offset) outline.
vec4 shadeGround(vec2 p, float sd) {
    bool dk = frame.w > 0.5;
    if (view.w < 0.5) {
        float a = footprintShadow(sd, 2.2, 9.0) * (dk ? 0.92 : 0.88) * itemEdgeFade(p);
        return vec4(palC.rgb, 1.0) * a;
    }
    // the sheet lying on the surface: a tight dark contact and a short soft fall, in a blue-black
    // that is the same in both modes (the ink's colour is a light one in dark mode)
    vec3 sc = dk ? vec3(0.0, 0.005, 0.02) : vec3(0.04, 0.06, 0.14);
    float a = footprintShadow(sd, 0.9, 4.2);
    a *= (dk ? 0.42 : 0.24) * itemEdgeFade(p);
    return vec4(sc, 1.0) * a;
}
