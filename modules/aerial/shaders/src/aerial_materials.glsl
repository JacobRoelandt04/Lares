// =============================================================================
// aerial_materials.glsl -- how each family paints a point of aerial's board (spliced into aerial_board.frag by tools/dev/board_gen).
//
// In:  Surf (see aerial_board.frag.in), the uniforms (view.w = family, frame.w = dark), the generated geometry (sceneTraces, sceneAo, MAT_*, PART_*, the card's
//      numbers, seg7's tables ...).
// Out: shadeSurface(Surf) and shadeGround(p, signedDistanceToBoard), PREMULTIPLIED rgba; pcbSd(q) (the PCB's outline) and cableFade(x).
//
// The palette (AerialStyle.qml fills it per family and per light / dark from Theme tokens):
//   family 0, Material     palA surface  palB bevel  palC deep shadow  palD groove floor  palE engraving ink  palF sunk part  palG well  palH metal
//   family 1, Blueprint      palA paper  palB ink  palC faint ink  palD grid  palE face wash
// The SECOND palette, the same slots for both families:
//   palI  the displays' window     palJ  their unlit segments     palK  the card's PCB (solder mask)     palL  gold (the fingers, the pads, the contacts)
//   palM  the label's paper (and the silk's white)     palN  the shield's tin     palO  the solder rim     palP  the displays' bezel
//   palQ  the MAIN coax's jacket     palR  the AUX coax's jacket     r3s2A  the smoked glass over the displays' window
// Tunables: tuneA.x bevel / ink line width px, tuneA.w paper grain (Blueprint; 0 reads as the default 0.018).
// The board's material maths is aerial's own; the toolkit's pieces (view-space helpers, box edges, Material's ink and carve, line coverage) are included below.
// =============================================================================

// @@INCLUDE board_prims.glsl
// @@INCLUDE board_edges.glsl
// @@INCLUDE board_eva.glsl
// @@INCLUDE board_ink.glsl

float gA = -9.0;       // the point's own decal field (the displays' ghost segments, the finger / ring / mouth marks): what sharedFields found
float gB = 0.0;

float sdBox(vec2 p, vec2 c, vec2 h) {
    vec2 d = abs(p - c) - h;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}
// positive inside a rectangle [x0, y0, x1, y1]
float rectSd(vec2 p, vec4 r) {
    return -sdBox(p, (r.xy + r.zw) * 0.5, (r.zw - r.xy) * 0.5);
}
// a vertical capsule: centre x, its lower end's y (the round end), radius, going on to +y without end
// THE SCREW'S TURN: a point of the board's (x, z) seen from the screw's own frame, the screw lifted `lift` mm. It turns SCREW_TURNS
// times over the lift, ANTICLOCKWISE seen from above (unscrewing), eased out so the spin comes to rest as the card takes over (the lift
// itself starts slowly: airplaneT's ease); one clock, the lift's, so taking the card down plays the turn back. Whole quarter turns: at
// both ends the slot is the old picture.
vec2 screwTurn(vec2 q, float lift) {
    float u = clamp(lift / SCREW_LIFT, 0.0, 1.0);
    // fract: a whole turn is the angle 0 exactly (the GPU's sin / cos of 2 pi is not the identity: the thread came out a level off at rest)
    float a = -6.2831853 * fract(SCREW_TURNS * (1.0 - (1.0 - u) * (1.0 - u)));
    float c = cos(a), sn = sin(a);
    return vec2(c * q.x + sn * q.y, c * q.y - sn * q.x);
}
float capSd(vec2 q, float x, float y0, float r) {
    return length(vec2(q.x - x, min(q.y - y0, 0.0))) - r;
}

// ---- the card's PCB outline (AerialGeometry PCB), card-local mm: positive OUTSIDE it ----
float pcbSd(vec2 q) {
    float d = sdBox(q, CARD_SIZE * 0.5, CARD_SIZE * 0.5);
    d = max(d, -sdBox(q, vec2(PCB_SHOULDER_X.x * 0.5 - 1.0, PCB_SHOULDER_Y + 3.0), vec2(PCB_SHOULDER_X.x * 0.5 + 1.0, 3.0)));
    d = max(d, -sdBox(q, vec2((PCB_SHOULDER_X.y + CARD_SIZE.x + 1.0) * 0.5, PCB_SHOULDER_Y + 3.0), vec2((CARD_SIZE.x + 1.0 - PCB_SHOULDER_X.y) * 0.5, 3.0)));
    d = max(d, -capSd(q, PCB_KEY0.x, PCB_KEY0.y + PCB_KEY0.z * 0.5, PCB_KEY0.z * 0.5));
    d = max(d, -capSd(q, PCB_KEY1.x, PCB_KEY1.y + PCB_KEY1.z * 0.5, PCB_KEY1.z * 0.5));
    d = max(d, -(length(q - PCB_NOTCH.xy) - PCB_NOTCH.z));
    return d;
}
// the plug's cable fades to nothing along its length (the plug's own frame)
float cableFade(float x) {
    return 1.0 - smoothstep(0.0, CABLE_FADE.y, x);
}

// ---- the board's own cut-outs (AerialGeometry CUTS): signed mm, negative INSIDE a cut (a hole through the board) ----
float sdRBox(vec2 p, vec2 c, vec2 h, float r) {
    vec2 d = abs(p - c) - h + r;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0) - r;
}
float boardCutSd(vec2 p) {
    float d = min(length(p - CUT_GROM0), length(p - CUT_GROM1)) - CUT_GROM_R.x;
    d = min(d, length(p - CUT_HOLE0) - CUT_RING.x);
    d = min(d, length(p - CUT_HOLE1) - CUT_RING.x);
    d = min(d, length(p - CUT_HOLE2) - CUT_RING.x);
    d = min(d, length(p - CUT_HOLE3) - CUT_RING.x);
    return d;
}
// the distance to the nearest mounting hole's centre (the copper ring round it)
float holeRadius(vec2 p) {
    return min(min(length(p - CUT_HOLE0), length(p - CUT_HOLE1)), min(length(p - CUT_HOLE2), length(p - CUT_HOLE3)));
}
bool onBoardRect(vec2 p) {
    return p.x > BOARD_RECT.x && p.x < BOARD_RECT.z && p.y > BOARD_RECT.y && p.y < BOARD_RECT.w;
}

// ---- the card's top face decals, card-local q ----
// distance to the nearest gold finger (negative inside one)
float fingerD(float x) {
    float d = 1e3;
    float u0 = clamp(floor((x - FING_G0.x) / FING_G0.y + 0.5), 0.0, FING_G0.z - 1.0);
    d = min(d, abs(x - (FING_G0.x + u0 * FING_G0.y)));
    float u1 = clamp(floor((x - FING_G1.x) / FING_G1.y + 0.5), 0.0, FING_G1.z - 1.0);
    d = min(d, abs(x - (FING_G1.x + u1 * FING_G1.y)));
    float u2 = clamp(floor((x - FING_G2.x) / FING_G2.y + 0.5), 0.0, FING_G2.z - 1.0);
    d = min(d, abs(x - (FING_G2.x + u2 * FING_G2.y)));
    float u3 = clamp(floor((x - FING_G3.x) / FING_G3.y + 0.5), 0.0, FING_G3.z - 1.0);
    d = min(d, abs(x - (FING_G3.x + u3 * FING_G3.y)));
    return d - FING_P.x * 0.5;
}
// the notch's copper ring: positive inside the ring's band, and the via dots (positive inside one)
float ringSd(vec2 q) {
    float r = length(q - PCB_NOTCH.xy);
    return min(r - PCB_NOTCH.z, PCB_NOTCH.w - r);
}
float viaSd(vec2 q) {
    vec2 c = q - PCB_NOTCH.xy;
    float r = length(c);
    float ang = atan(c.y, c.x);                                         // 0 .. pi on the card's side of the edge
    float step_ = 2.7 / max(PCB_VIA.x - 1.0, 1.0);
    float k = clamp(floor((ang - 0.2) / step_ + 0.5), 0.0, PCB_VIA.x - 1.0);
    float a = 0.2 + k * step_;
    vec2 v = vec2(cos(a), sin(a)) * (PCB_NOTCH.z + PCB_NOTCH.w) * 0.5;
    return PCB_VIA.y - length(c - v);
}
bool inTriangle(vec2 q, vec4 t) {
    float u = (q.y - t.z) / (t.w - t.z);
    return u > 0.0 && u < 1.0 && abs(q.x - (t.x + t.y) * 0.5) < u * (t.y - t.x) * 0.5;
}

// the jack's mouth on its +x face: the opening (positive inside), eight gold pins along its upper edge
float mouthSd(vec2 zy) {
    return rectSd(zy, vec4(JACK_MOUTH.x - JACK_MOUTH.y * 0.5, JACK_MOUTH.z, JACK_MOUTH.x + JACK_MOUTH.y * 0.5, JACK_MOUTH.w));
}
float pinSd(vec2 zy) {
    float pit = JACK_MOUTH.y * 0.118;
    float u = (zy.x - (JACK_MOUTH.x - 3.5 * pit)) / pit;
    float k = clamp(floor(u + 0.5), 0.0, 7.0);
    float dz = abs(zy.x - (JACK_MOUTH.x - 3.5 * pit + k * pit)) - pit * 0.2;
    float dy = max(JACK_MOUTH.w - (JACK_MOUTH.w - JACK_MOUTH.z) * 0.58 - zy.y, zy.y - (JACK_MOUTH.w - 0.45));
    return -max(dz, dy);
}

// a point of a cylinder part: distance to its rim in mm (positive inside) and the outward direction in xz
void cylEdge(Surf s, out float inPx, out vec2 od) {
    vec2 dv = s.pl.xz - (s.bmin.xz + s.bmax.xz) * 0.5;
    float rr = length(dv);
    inPx = (0.5 * (s.bmax.x - s.bmin.x) - rr) * 0.70710678 * s.pxPerMm;
    od = dv / max(rr, 1e-4);
}

// ---- the silkscreen (tools/aerial/make_silk.py): a signed-distance texture, mm, positive inside a mark, R Material / G Blueprint ----
// Read at an EXPLICIT level (silicon's reason: an implicit one comes from derivatives, undefined in the divergent flow every sample takes to get here, so the cached
// board and a live patch would pick different levels): the level the hardware would choose on the board's plane.
// The level keeps about 1.25 texels per device px (not silicon's sqrt(3), the most a pixel spans on the plane: this is a DISTANCE field, cut by the shader's own
// antialiasing, so a level finer than the pixel does not alias, and a coarser one only rounds the letters' corners -- at 1.25 mm tall they have none to spare).
const float SILK_K = 0.4;                // silicon's px per mm over this board's (3.5 / 8.8): the lettering's carve in silicon's pixels
const float SILK_STEP = 0.2 * SILK_K;    // mm toward the light the second read of the field is taken at
float silkTex(vec2 t) {
    float lod = max(0.0, log2(SILK_TEXELS_PER_MM / (pxMm() * 1.25)));
    vec3 c = textureLod(silk, t / SILK_TEX, lod).rgb;
    return ((view.w < 0.5 ? c.r : c.g) - 0.5) * 2.0 * SILK_RANGE;
}
// every mark at a board point: the fixed names and the courtyards where they lie, and inside the two unit labels' cells the variant `silkVar` picks from the atlas
float silkAll(vec2 p) {
    vec2 t = p - BOARD_RECT.xy;
    vec2 a = p - SILK_UNIT0;
    vec2 b = p - SILK_UNIT1;
    if (a.x > 0.0 && a.y > 0.0 && a.x < SILK_UNIT_W0 && a.y < SILK_CELL.y)
        t = silkCell0(silkVar.x) + a;
    else if (b.x > 0.0 && b.y > 0.0 && b.x < SILK_UNIT_W1 && b.y < SILK_CELL.y)
        t = silkCell1(silkVar.y) + b;
    return silkTex(t);
}
// a latch's emblem at a point of its face (the latch's own frame): the Wi-Fi fan / the Bluetooth rune, centred on the face
float emblemSd(Surf s, vec2 off) {
    vec2 c = s.pl.xz + off - (s.bmin.xz + s.bmax.xz) * 0.5;
    if (abs(c.x) > SILK_EMBLEM * 0.5 - 0.1 || abs(c.y) > SILK_EMBLEM * 0.5 - 0.1)
        return -SILK_RANGE;
    return silkTex((s.part == PART_DIPWIFI ? SILK_EMBLEM_WIFI : SILK_EMBLEM_BT) + vec2(SILK_EMBLEM * 0.5) + c);
}

// ---- the fields both families share ----
bool onDecals(Surf s) {
    return s.nl.y > 0.5;
}

// ---- family 0: Material ----
const float EVA_SIDE_K = 1.0;

// a decorative IC's top: pin ticks along its two long sides and a pin-1 dot (passives are plain boxes)
vec3 decoTop(Surf s, vec3 col, vec3 mark, float aa) {
    vec3 sz = s.bmax - s.bmin;
    if (sz.x < 2.5 || sz.z < 2.5)
        return col;
    bool alongX = sz.x >= sz.z;
    vec2 u = alongX ? vec2(s.pl.x - s.bmin.x, s.pl.z - s.bmin.z) : vec2(s.pl.z - s.bmin.z, s.pl.x - s.bmin.x);
    vec2 sd = alongX ? vec2(sz.x, sz.z) : vec2(sz.z, sz.x);
    float edge = min(u.y, sd.y - u.y);
    float tick = step(0.5, fract(u.x / 0.8)) * (1.0 - smoothstep(0.45, 0.45 + aa, edge)) * step(0.35, u.x) * step(u.x, sd.x - 0.35);
    float dot1 = 1.0 - smoothstep(0.22 - aa, 0.22 + aa, length(s.pl.xz - s.bmin.xz - vec2(0.7)));
    return mix(col, mark, max(tick * 0.55, dot1 * 0.8));
}

vec3 baseEva(Surf s, EvaInk e) {
    int m = s.mat;
    vec3 c = e.surf;
    if (m == MAT_SOCKET || m == MAT_FLASH || m == MAT_RTL || m == MAT_BTN_BASE || m == MAT_DIP_BODY || m == MAT_PLUG || m == MAT_CABLE)
        c = e.sunk;
    else if (m == MAT_PCB)
        c = mix(e.surf, palK.rgb, 0.88);
    else if (m == MAT_SHIELD)
        c = palN.rgb;
    else if (m == MAT_SHIELD_RIM)
        c = palO.rgb;
    else if (m == MAT_LABEL)
        c = palM.rgb;
    else if (m == MAT_MHF)
        c = mix(e.metal, palL.rgb, 0.45);
    else if (m == MAT_COAX_MAIN)
        c = palQ.rgb;
    else if (m == MAT_COAX_AUX)
        c = palR.rgb;
    else if (m == MAT_STANDOFF || m == MAT_SCREW || m == MAT_JACK || m == MAT_LEAD)
        c = e.metal;
    else if (m == MAT_DIP_LEVER || m == MAT_BTN_CAP)
        c = e.hi;
    else if (m == MAT_LED)
        c = mix(e.surf, e.hi, 0.8);
    else if (m == MAT_PAD)
        c = palL.rgb;
    else if (m == MAT_DISPLAY)
        c = palP.rgb;
    else if (m == MAT_LENS)
        c = mix(e.sunk, e.metal, 0.5);
    else if (m == MAT_DECO)
        c = mix(e.surf, e.shd, 0.26);          // a decorative part: flat, grey, close to the ground
    return c;
}

vec4 shadeEva(Surf s) {
    EvaInk e = evaInk();
    vec3 L = normalize(light.xyz);
    vec2 Ld = normalize(L.xz);
    bool top = s.nl.y > 0.5;
    float bw = max(tuneA.x, 0.6);
    float aa = aaMm();
    vec3 col = baseEva(s, e);
    vec2 q = s.pl.xz - CARD_ORG;            // card-local (meaningful for the card's parts)
    float xd = -9.0, xs = 0.0, xin = 0.12, xrm = 0.25;
    vec3 xfl = e.flr;

    if (top) {
        float dPx; vec2 od;
        topEdge(s, dPx, od);
        if (isCylPart(s.part))
            cylEdge(s, dPx, od);
        else if (s.mat == MAT_PCB) {
            float cutPx = -s.cutD * 0.70710678 * s.pxPerMm;
            if (cutPx < dPx) {
                dPx = cutPx;
                od = vec2(0.0);
            }
        }
        if (s.part == PART_BOARD) {
            float hPx = s.holeD * 0.70710678 * s.pxPerMm;       // the board's own cut-outs take the same bevel
            if (hPx < dPx) {
                dPx = hPx;
                od = vec2(0.0);
            }
        }
        float face = 0.5 + 0.5 * dot(od, Ld);
        float hl = 1.0 - smoothstep(0.0, bw, dPx);
        float hlk = s.mat == MAT_DECO ? 0.22 : 1.0;           // a decoration barely catches the light
        col = mix(col, e.hi, hlk * (hl * (e.dk ? 0.62 : 0.40) + hl * (e.dk ? 0.38 : 0.45) * face));
        if (s.part == PART_BOARD) {
            // the copper: a carved groove that carries the light, shaded from the wall on the light's side
            if (s.traceKind >= 0) {
                xd = -s.traceD;
                xs = (s.traceD - s.traceDl) / 0.45;
                xin = 0.30;
                xrm = 0.22;
            }
            col *= mix(1.0, 0.82, 1.0 - s.ao);
            float cs = 1.0 - min(s.ao2, s.ao);
            col = mix(col, e.shd, cs * (e.dk ? 0.55 : 0.42));
            // the corner holes: a thin plated ring, the board's own tone (silicon's corner marks: never a gold doughnut)
            float hr = holeRadius(s.p.xz);
            float ring = smoothstep(-aa, aa, min(CUT_RING.y - hr, hr - CUT_RING.x));
            col = mix(col, mix(e.metal, e.surf, 0.45), ring * 0.85);
            col = mix(col, e.shd, (1.0 - smoothstep(0.0, 0.16, abs(hr - CUT_RING.y))) * (e.dk ? 0.5 : 0.32));
            // the cables' grommets: a dark rubber ring round each hole
            float gr = min(length(s.p.xz - CUT_GROM0), length(s.p.xz - CUT_GROM1));
            col = mix(col, mix(e.ink, e.shd, 0.35), smoothstep(-aa, aa, CUT_GROM_R.y - gr) * 0.9);
            // the carved lettering and courtyards (sharedFields read the silkscreen here and 0.2 mm toward the light); a trace's groove wins where both are
            // THE CARVE'S WIDTHS ARE SILICON'S IN PIXELS, NOT IN MILLIMETRES (round 4): silicon's lettering has a 0.30 mm rim, a 0.16 mm shade and a light probe 0.2 mm away
            // on a board drawn at 3.5 px per mm -- about one pixel each. This board is drawn at 8.8 px per mm, so the same millimetres were a rim 2.7 px wide round strokes
            // of 1.4 px: the letters read as blurred ("low resolution"). SILK_K (3.5 / 8.8) scales the three.
            if (gA > -0.6 && gA > xd) {
                xd = gA;
                xs = (gB - gA) / SILK_STEP;
                xfl = mix(e.flr, e.ink, e.dk ? 0.94 : 0.56);        // (deeper than silicon's lettering: these names are how the parts are told apart)
                xin = 0.16 * SILK_K;
                xrm = 0.30 * SILK_K;
            }
        } else if (s.mat == MAT_PCB) {
            // the finger band, the fingers, the notch's copper ring and its vias, the fiducial, the silk
            float band = smoothstep(-aa, aa, q.y - FING_P.w);
            col = mix(col, mix(palO.rgb, e.surf, 0.35), band);
            float fing = smoothstep(-aa, aa, -fingerD(q.x)) * step(FING_P.y, q.y) * step(q.y, FING_P.z);
            col = mix(col, palL.rgb, fing);
            float rg = ringSd(q);
            col = mix(col, mix(palL.rgb, palK.rgb, 0.25), smoothstep(-aa, aa, rg) * step(0.0, q.y));
            col = mix(col, palK.rgb * 0.45, smoothstep(-aa, aa, viaSd(q)) * smoothstep(-aa, aa, rg));
            float fr = length(q - FIDUCIAL.xy);
            col = mix(col, palK.rgb * 0.45, 1.0 - smoothstep(FIDUCIAL.w - aa, FIDUCIAL.w + aa, fr));
            col = mix(col, palL.rgb, 1.0 - smoothstep(FIDUCIAL.z - aa, FIDUCIAL.z + aa, fr));
            float silk = 0.0;
            if (inTriangle(q, SILK_TRI)) silk = 1.0;
            silk = max(silk, 1.0 - smoothstep(SILK_DOT.z - aa, SILK_DOT.z + aa, length(q - SILK_DOT.xy)));
            silk = max(silk, step(0.0, rectSd(q, SILK_KEYE)));
            silk = max(silk, step(0.0, rectSd(q, SILK_KEYA)));
            col = mix(col, palM.rgb, silk * 0.9);
        } else if (s.mat == MAT_SHIELD) {
            float grain = vnoise(s.pl.xz * 9.0) - 0.5;
            col *= 1.0 + 0.05 * grain;
        } else if (s.mat == MAT_DIP_BODY) {
            // the levers' two tracks
            vec2 p = s.pl.xz;
            float hw = DIP_LEVER.y * 0.5 + 0.25;
            float t1 = rectSd(p, vec4(DIP_SLOT.x, DIP_SLOT.y - hw, DIP_SLOT.z, DIP_SLOT.y + hw));
            float t2 = rectSd(p, vec4(DIP_SLOT.x, DIP_SLOT.w - hw, DIP_SLOT.z, DIP_SLOT.w + hw));
            xd = max(t1, t2);
            xs = 0.0;
            xin = 0.22;
            xrm = 0.2;
            xfl = mix(e.shd, e.sunk, 0.35);
        } else if (s.mat == MAT_DIP_LEVER) {
            // THE LATCH'S FACE: its radio's emblem, engraved; lit in the radio's own hue while the radio is on (on is a colour), plain ink while it is off
            bool wf = s.part == PART_DIPWIFI;
            float on = clamp(wf ? parts.x : parts.y, 0.0, 1.0);
            vec3 hue = wf ? hueWifi.rgb : hueBt.rgb;
            col = mix(col, hue, on * (e.dk ? 0.16 : 0.10));
            float em = smoothstep(-aa, aa, gA);
            float lip = smoothstep(-aa, aa, gB) * (1.0 - em);
            col = mix(col, e.hi, lip * 0.5);
            col = mix(col, mix(mix(e.ink, e.shd, 0.25), hue, on), em * mix(0.62, 0.96, on));
        } else if (s.mat == MAT_SOCKET) {
            // the slot's lid: a lip along the mouth the card goes into and a seam down its middle
            float mz = s.pl.z - SOCKET_RECT.y;
            col = mix(col, e.shd, (1.0 - smoothstep(0.0, 0.5, mz)) * 0.45);
            col = mix(col, e.hi, (1.0 - smoothstep(0.0, 0.09, abs(mz - 0.75))) * 0.22);
            col = mix(col, e.shd, (1.0 - smoothstep(0.0, 0.08, abs(mz - (SOCKET_RECT.w - SOCKET_RECT.y) * 0.62))) * 0.30);
        } else if (s.part == PART_SCREW) {
            // the screw's head: turned metal (a faint conic sheen) and a cross slot
            vec2 q2 = s.pl.xz - SCREW_C.xy;
            float ang = atan(q2.y, q2.x);
            col *= 1.0 + 0.10 * cos(2.0 * ang - 0.9);       // the sheen is the light's: it does not turn with the head
            vec2 qs = screwTurn(q2, gScrewLift);
            float bar = max(min(0.20 - abs(qs.x), 1.15 - abs(qs.y)), min(0.20 - abs(qs.y), 1.15 - abs(qs.x)));
            float slot = smoothstep(-aa, aa, bar);
            col = mix(col, e.shd, slot * 0.82);
            col = mix(col, e.hi, (1.0 - smoothstep(0.0, 0.12, -bar)) * (1.0 - slot) * 0.35);
        } else if (s.mat == MAT_PAD) {
            // a gold test pad: a slightly darker border so the LED's foot reads on it
            float pe = min(min(s.pl.x - s.bmin.x, s.bmax.x - s.pl.x), min(s.pl.z - s.bmin.z, s.bmax.z - s.pl.z));
            col = mix(col * 0.82, col, smoothstep(0.12, 0.3, pe));
        } else if (s.mat == MAT_FLASH) {
            float p1 = 1.0 - smoothstep(0.30 - aa, 0.36 + aa, length(s.pl.xz - MEM_PIN1));
            col = mix(col, e.ink, p1 * 0.8);
            // the memory is a part you can pick: a gold band down its lid and a gold pin-1 dot (a decorative chip has neither)
            float bandD = max(abs(s.pl.z - (s.bmin.z + s.bmax.z) * 0.5) - 0.42, s.bmin.x + 1.5 - s.pl.x);
            col = mix(col, mix(palL.rgb, e.surf, 0.15), smoothstep(-aa, aa, -bandD) * 0.92);
            col = mix(col, palL.rgb, (1.0 - smoothstep(0.30 - aa, 0.36 + aa, length(s.pl.xz - MEM_PIN1))) * 0.95);
        } else if (s.mat == MAT_DECO) {
            col = decoTop(s, col, mix(e.surf, e.shd, 0.55), aa);
        } else if (s.mat == MAT_BTN_CAP) {
            col = mix(col, e.shd, (1.0 - smoothstep(0.0, 0.5, dPx)) * 0.25);
        } else if (s.mat == MAT_LENS) {
            col = mix(col, e.shd, (1.0 - smoothstep(0.0, 0.7, dPx)) * 0.2);
        } else if (s.mat == MAT_DISPLAY) {
            int di = segIndexOf(s.part);
            vec4 wr = segWindow(di);
            float dw = rectSd(s.pl.xz, wr);
            float inW = smoothstep(-aa, aa, dw);
            col = mix(col, palI.rgb * r3s2A.rgb, inW);
            col = mix(col, palJ.rgb * glassGhost(), smoothstep(-aa, aa, gA) * inW);
            col *= 1.0 + 0.04 * glassStreak(s.pl.xz) * inW;
        } else if (s.mat == MAT_RTL) {
            col = mix(col, e.ink, (1.0 - smoothstep(0.0, 0.5, length(s.pl.xz - vec2(s.bmin.x + 0.7, s.bmin.z + 0.7)) - 0.28)) * 0.7);
        }
    } else {
        // a side face: tone by orientation, darker toward the foot, the bevel carried over the top edge
        float dTop, dFoot, dVert, crease;
        sideEdges(s, dTop, dFoot, dVert, crease);
        float tone = s.n.z > 0.5 ? mix(1.0, e.dk ? 0.76 : 0.82, EVA_SIDE_K) : mix(1.0, e.dk ? 0.52 : 0.62, EVA_SIDE_K);
        if (isCylPart(s.part)) {
            tone = mix(1.0, e.dk ? 0.5 : 0.6, 0.5 - 0.5 * dot(s.n.xz, Ld));
            crease = 0.0;
        }
        if (s.part == PART_SCREWSHAFT) {
            // the thread: fine turns round the shaft (a helix: the stripes lean with the angle), darker in their roots
            vec2 nt = screwTurn(s.nl.xz, gScrewLift);
            float turn = fract(s.pl.y / 0.46 + atan(nt.y, nt.x) * 0.159155);
            col *= 0.86;
            col = mix(col, e.shd, (1.0 - smoothstep(0.0, 0.28, abs(turn - 0.5))) * 0.55);
        }
        float footH = (s.part == PART_BOARD ? 1.2 : 3.0) * 0.70710678 * s.pxPerMm;
        float foot = mix(e.dk ? 0.56 : 0.72, 1.0, smoothstep(0.0, footH, dFoot));
        col = col * tone * foot;
        float hl = 1.0 - smoothstep(0.0, bw, dTop);
        col = mix(col, e.hi * tone, hl * 0.5);
        float cr = (1.0 - smoothstep(0.0, bw, dVert)) * crease;
        col = mix(col, e.hi * tone, cr * 0.4);
        if (s.mat == MAT_JACK && s.nl.x > 0.5) {
            vec2 zy = vec2(s.pl.z, s.pl.y);
            float dm = mouthSd(zy);
            float inM = smoothstep(-aa, aa, dm);
            col = mix(col, palI.rgb, inM);
            col = mix(col, e.shd, (1.0 - smoothstep(0.0, 0.5, -dm)) * inM * 0.6);
            col = mix(col, palL.rgb, smoothstep(-aa, aa, pinSd(zy)) * inM);
        }
    }

    // ONE carved mark a pixel: evaCarve is a heavy function, called once
    if (xd > -8.0)
        col = evaCarve(e, col, xfl, xd, xs, xin, xrm, aa, 1.0);
    return vec4(col, 1.0);
}

// ---- family 1: Blueprint ----
// the nearest edge's ink: a silhouette edge (the box's side beyond it is hidden) takes the heavy line, a crease the light one
float edgeInkBp(Surf s, float wSil, float wIn) {
    bool top = s.nl.y > 0.5;
    if (top) {
        float dPx; vec2 od;
        if (isCylPart(s.part)) {
            cylEdge(s, dPx, od);
            return inkLine(abs(dPx), wIn);
        }
        topEdge(s, dPx, od);
        if (s.mat == MAT_PCB) {
            float cutPx = -s.cutD * 0.70710678 * s.pxPerMm;
            if (cutPx < dPx) {
                dPx = cutPx;
                od = vec2(0.0);
            }
        }
        if (s.part == PART_BOARD) {
            float hPx = s.holeD * 0.70710678 * s.pxPerMm;
            if (hPx < dPx) {
                dPx = hPx;
                od = vec2(0.0);
            }
        }
        float sil = dot(od, V_CAM.xz) > 0.0 ? 0.0 : 1.0;
        if (s.part == PART_BOARD)
            sil = 1.0;
        return inkLine(dPx, mix(wIn, wSil, sil));
    }
    float dTop, dFoot, dVert, crease;
    sideEdges(s, dTop, dFoot, dVert, crease);
    float lt = inkLine(dTop, wIn);
    float lf = inkLine(dFoot, wSil);
    float lv = inkLine(dVert, mix(wSil, wIn, crease));
    if (isCylPart(s.part))
        lv = 0.0;
    return max(lt, max(lf, lv));
}

vec4 shadeBlueprint(Surf s) {
    bool dk = frame.w > 0.5;
    vec3 L = normalize(light.xyz);
    bool top = s.nl.y > 0.5;
    float lw = max(tuneA.x, 0.6);
    float lwS = lw * 1.55;
    vec3 paper = palA.rgb, ink = palB.rgb, faint = palC.rgb, gridC = palD.rgb, wash = palE.rgb;
    float aa = aaMm();
    float ppm = s.pxPerMm * 0.70710678;
    vec3 col = paper;
    vec2 q = s.pl.xz - CARD_ORG;

    if (s.part == PART_BOARD && top) {
        float grain = (vnoise(s.p.xz * 3.1) - 0.5) * (tuneA.w > 0.0 ? tuneA.w : 0.018);
        col += vec3(grain);
        vec2 gq = s.p.xz;
        vec2 g5 = (0.5 - abs(fract(gq / 5.0) - 0.5)) * 5.0;
        col = mix(col, gridC, inkLine(min(g5.x, g5.y) * ppm * 1.0, 0.7) * 0.65);
        vec2 g25 = (0.5 - abs(fract(gq / 25.0) - 0.5)) * 25.0;
        col = mix(col, mix(gridC, faint, 0.55), inkLine(min(g25.x, g25.y) * ppm, 0.9) * 0.75);
        // shadows as a draftsman hatches them
        float hs = (1.0 - s.lit) * light.w;
        float hd = fract((s.p.x + s.p.z) / 1.35);
        col = mix(col, faint, hs * inkLine(abs(hd - 0.5) * 1.35 * ppm, 0.8) * 0.65);
        float hr = holeRadius(s.p.xz);
        col = mix(col, ink, inkLine(abs(hr - CUT_RING.y) * ppm, lw * 0.8) * 0.7 * (1.0 - step(CUT_RING.y + 1.0, hr)));
        // the lettering and the courtyards, inked
        col = mix(col, ink, smoothstep(-aa, aa, gA) * 0.92);
        float gr = min(length(s.p.xz - CUT_GROM0), length(s.p.xz - CUT_GROM1));
        col = mix(col, ink, inkLine(abs(gr - CUT_GROM_R.y) * ppm, lw) * 0.9);
        if (s.traceKind >= 0) {
            float lrd = floor(float(s.traceKind) * 0.25) / 1024.0;
            float wide = smoothstep(0.5, 0.95, s.traceHalf);
            col = mix(col, wash, inside(s.traceD, aa) * 0.75 * wide);
            float line = mix(inkLine(lrd * ppm, lw), inkLine(abs(s.traceD) * ppm, lw), wide);
            col = mix(col, ink, line * 0.95);
        }
    } else if (top) {
        col = mix(paper, wash, 0.28);
        float occ = 1.0 - min(s.ao, s.ao2);
        float ch = fract((s.p.x + s.p.z) / 1.35);
        col = mix(col, faint, sat(occ * 2.0) * inkLine(abs(ch - 0.5) * 1.35 * ppm, 0.8) * 0.65);
        if (s.mat == MAT_PCB) {
            // the card's board: a close diagonal hatch, the finger band bare, the fingers inked, the ring and the vias
            float hh = fract((s.pl.x + s.pl.z) / 0.8);
            col = mix(wash, faint, inkLine(abs(hh - 0.5) * 0.8 * ppm, 0.7) * 0.55);
            col = mix(col, paper, smoothstep(-aa, aa, q.y - FING_P.w));
            float fing = smoothstep(-aa, aa, -fingerD(q.x)) * step(FING_P.y, q.y) * step(q.y, FING_P.z);
            col = mix(col, ink, fing * 0.9);
            float rg = ringSd(q);
            col = mix(col, ink, inkLine(abs(PCB_NOTCH.w - length(q - PCB_NOTCH.xy)) * ppm, lw * 0.9) * 0.8 * step(0.0, q.y));
            col = mix(col, ink, smoothstep(-aa, aa, viaSd(q)) * smoothstep(-aa, aa, rg) * 0.9);
            float fr = length(q - FIDUCIAL.xy);
            col = mix(col, ink, inkLine(abs(fr - FIDUCIAL.w) * ppm, lw * 0.8) * 0.7);
            col = mix(col, ink, 1.0 - smoothstep(FIDUCIAL.z - aa, FIDUCIAL.z + aa, fr));
            float silk = 0.0;
            if (inTriangle(q, SILK_TRI)) silk = 1.0;
            silk = max(silk, 1.0 - smoothstep(SILK_DOT.z - aa, SILK_DOT.z + aa, length(q - SILK_DOT.xy)));
            silk = max(silk, step(0.0, rectSd(q, SILK_KEYE)));
            silk = max(silk, step(0.0, rectSd(q, SILK_KEYA)));
            col = mix(col, ink, silk * 0.85);
        } else if (s.mat == MAT_SHIELD || s.mat == MAT_SHIELD_RIM) {
            float bh = fract((s.pl.x - s.pl.z) / 0.9);
            col = mix(wash, ink, inkLine(abs(bh - 0.5) * 0.9 * ppm, 0.8) * (s.mat == MAT_SHIELD_RIM ? 0.85 : 0.35));
        } else if (s.mat == MAT_LABEL) {
            col = paper;
        } else if (s.mat == MAT_PAD || s.mat == MAT_MHF) {
            col = mix(wash, ink, 0.9);
        } else if (s.mat == MAT_DIP_BODY) {
            vec2 p = s.pl.xz;
            float hw = DIP_LEVER.y * 0.5 + 0.25;
            float t1 = rectSd(p, vec4(DIP_SLOT.x, DIP_SLOT.y - hw, DIP_SLOT.z, DIP_SLOT.y + hw));
            float t2 = rectSd(p, vec4(DIP_SLOT.x, DIP_SLOT.w - hw, DIP_SLOT.z, DIP_SLOT.w + hw));
            float dt = max(t1, t2);
            col = mix(col, ink, smoothstep(-aa, aa, dt) * 0.22);
            col = mix(col, ink, inkLine(abs(dt) * ppm, lw) * 0.9);
        } else if (s.mat == MAT_DIP_LEVER) {
            bool wf = s.part == PART_DIPWIFI;
            float on = clamp(wf ? parts.x : parts.y, 0.0, 1.0);
            vec3 hue = wf ? hueWifi.rgb : hueBt.rgb;
            col = mix(paper, hue, on * 0.14);
            col = mix(col, mix(ink, hue, on), smoothstep(-aa, aa, gA) * 0.95);
        } else if (s.part == PART_SCREW) {
            vec2 q2 = screwTurn(s.pl.xz - SCREW_C.xy, gScrewLift);
            float bar = max(min(0.20 - abs(q2.x), 1.15 - abs(q2.y)), min(0.20 - abs(q2.y), 1.15 - abs(q2.x)));
            col = mix(col, ink, inkLine(abs(bar) * ppm, lw) * 0.9);
        } else if (s.mat == MAT_FLASH) {
            col = mix(col, ink, (1.0 - smoothstep(0.30 - aa, 0.36 + aa, length(s.pl.xz - MEM_PIN1))) * 0.9);
            float bandD = max(abs(s.pl.z - (s.bmin.z + s.bmax.z) * 0.5) - 0.42, s.bmin.x + 1.5 - s.pl.x);
            col = mix(col, ink, smoothstep(-aa, aa, -bandD) * 0.85);
        } else if (s.mat == MAT_DECO) {
            col = decoTop(s, mix(wash, paper, 0.5), faint, aa);
        } else if (s.mat == MAT_DISPLAY) {
            int di = segIndexOf(s.part);
            vec4 wr = segWindow(di);
            float dw = rectSd(s.pl.xz, wr);
            float inW = smoothstep(-aa, aa, dw);
            col = mix(col, palI.rgb * r3s2A.rgb, inW);
            col = mix(col, palJ.rgb * glassGhost(), smoothstep(-aa, aa, gA) * inW);
            col = mix(col, ink, inkLine(abs(dw) * ppm, lw) * 0.9);
        } else if (s.mat == MAT_BTN_CAP || s.mat == MAT_LENS) {
            col = mix(wash, paper, 0.4);
        }
    } else {
        bool lit = s.n.z > 0.5;
        col = mix(paper, wash, lit ? 0.62 : 0.95);
        bool alongZ = abs(s.nl.x) > 0.5;
        float u = alongZ ? s.pl.z : s.pl.x;
        float pitch = lit ? 2.1 : 1.15;
        float hu = fract(u / pitch);
        col = mix(col, faint, inkLine(abs(hu - 0.5) * pitch * ppm, lit ? 0.7 : 0.8) * (lit ? 0.5 : 0.75));
        if (s.part == PART_SCREWSHAFT) {
            vec2 nt = screwTurn(s.nl.xz, gScrewLift);
            float turn = fract(s.pl.y / 0.46 + atan(nt.y, nt.x) * 0.159155);
            col = mix(mix(paper, wash, 0.7), ink, inkLine(abs(turn - 0.5) * 0.46 * s.pxPerMm * 0.8165, lw * 0.8) * 0.8);
        }
        if (s.mat == MAT_JACK && s.nl.x > 0.5) {
            vec2 zy = vec2(s.pl.z, s.pl.y);
            float dm = mouthSd(zy);
            float inM = smoothstep(-aa, aa, dm);
            col = mix(col, palI.rgb, inM);
            col = mix(col, ink, inkLine(abs(dm) * ppm, lw) * 0.9);
            col = mix(col, ink, smoothstep(-aa, aa, pinSd(zy)) * inM * 0.9);
        }
    }
    bool deco = s.mat == MAT_DECO;
    col = mix(col, deco ? faint : ink, edgeInkBp(s, deco ? lw : lwS, deco ? lw * 0.7 : lw) * (deco ? 0.5 : 1.0));
    return vec4(col, 1.0);
}

// The inside wall of a cut-out of the board, seen through the hole: `n` the wall's outward normal in xz (into the hole), `dep` mm below the top, and the family's tone for it.
vec4 holeWall(vec2 n, float dep) {
    float s = view.z;
    float dTop = dep * 0.70710678 * s;
    float foot = smoothstep(0.0, 2.4 * 0.70710678 * s, (BOARD_Y.y - BOARD_Y.x) - dep);
    float lit = smoothstep(-0.7, 0.7, n.y - n.x);                   // the walls the lamp reaches
    if (view.w < 0.5) {
        EvaInk e = evaInk();
        float tone = mix(e.dk ? 0.46 : 0.58, e.dk ? 0.78 : 0.84, lit);
        vec3 col = e.surf * tone * mix(e.dk ? 0.56 : 0.72, 1.0, foot);
        col = mix(col, e.hi * tone, (1.0 - smoothstep(0.0, max(tuneA.x, 0.6), dTop)) * 0.5);
        return vec4(col, 1.0);
    }
    vec3 paper = palA.rgb, ink = palB.rgb, wash = palE.rgb, faint = palC.rgb;
    vec3 col = mix(paper, wash, mix(0.95, 0.62, lit));
    col = mix(col, faint, 0.35 * (1.0 - foot));
    col = mix(col, ink, inkLine(dTop, max(tuneA.x, 0.6)) * 0.9);
    return vec4(col, 1.0);
}

void sharedFields(Surf s) {
    bool top = s.nl.y > 0.5;
    gA = -9.0;
    gB = 0.0;
    if (top && s.mat == MAT_DISPLAY) {
        gA = segFieldSd(segIndexOf(s.part), s.pl.xz, vec4(0.0), true);
    } else if (top && (s.part == PART_BOARD || s.mat == MAT_DIP_LEVER)) {
        // the silkscreen here and (Material) SILK_STEP mm toward the light, through ONE call site in a loop whose bound comes from a uniform
        vec2 Ld = normalize(normalize(light.xyz).xz);
        int nk = (quad.z > 0.5 && view.w < 0.5) ? 2 : 1;
        for (int k = 0; k < nk; k++) {
            vec2 off = k == 0 ? vec2(0.0) : Ld * SILK_STEP;
            float v = s.part == PART_BOARD ? silkAll(s.p.xz + off) : emblemSd(s, off);
            if (k == 0)
                gA = v;
            gB = v;
            if (gA < -0.6)
                break;
        }
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
    vec3 sc = dk ? vec3(0.0, 0.005, 0.02) : vec3(0.04, 0.06, 0.14);
    float a = footprintShadow(sd, 0.9, 4.2);
    a *= (dk ? 0.42 : 0.24) * itemEdgeFade(p);
    return vec4(sc, 1.0) * a;
}
