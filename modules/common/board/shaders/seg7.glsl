// =============================================================================
// seg7.glsl -- the 7-segment font and the displays' cell layout, shared by the board (the module, its
// window and the UNLIT segments) and the glow (the LIT ones): one signed-distance field, so a lit segment
// lies exactly on its ghost. Spliced into both silicon_board.frag and silicon_glow.frag by
// tools/dev/silicon_shader_gen.js.
//
// In:  the generated SEG_* constants and segCell0 / segCells / segHasColon (SceneGeometry.SEG7), and the glass's tint (the uniform r3s2A).
// Out: segFieldSd(display, p, fig, ghost) -- mm, positive inside a segment, a colon dot or a point; and the smoked glass over the window (glassStreak,
//      glassHatch, glassLit: the pane's texture, Blueprint's hatch, and a lit colour seen through it).
//
// A cell CODE (what the scene packs a figure into: Figures.js) is a float:
//     0-9 a digit   10 the minus sign   11 blank   12 `d`   13 `h`     (the contract's alphabet)
//     + 16 when the decimal point after the cell is lit      + 32 when the colon after it is lit (cell 1 of a colon display)
// No bit operations and no integer `%` (the shader is also baked for GLSL 1.20, which has neither).
// =============================================================================

// segments: a 1 top, b 2 top right, c 4 bottom right, d 8 bottom, e 16 bottom left, f 32 top left, g 64 middle
int seg7Bits(int ch) {
    if (ch == 0) return 63;
    if (ch == 1) return 6;
    if (ch == 2) return 91;
    if (ch == 3) return 79;
    if (ch == 4) return 102;
    if (ch == 5) return 109;
    if (ch == 6) return 125;
    if (ch == 7) return 7;
    if (ch == 8) return 127;
    if (ch == 9) return 111;
    if (ch == 10) return 64;       // -
    if (ch == 12) return 94;       // d: b c d e g
    if (ch == 13) return 116;      // h: c e f g
    if (ch == 14) return 127;      // every segment: the unlit display's ghost
    return 0;
}
bool hasSeg(int bits, int b) {
    return mod(floor(float(bits) / float(b) + 0.001), 2.0) > 0.5;
}
// a cell code's parts
int codeChar(float code) {
    return int(mod(floor(code + 0.5), 16.0));
}
bool codeDp(float code) {
    return mod(floor((floor(code + 0.5) + 0.25) / 16.0), 2.0) > 0.5;
}
bool codeColon(float code) {
    return floor((floor(code + 0.5) + 0.25) / 32.0) > 0.5;
}

// a horizontal / vertical bar with hexagonal ends: half length hl, half thickness ht, centre c
float sdSegH(vec2 q, vec2 c, float hl, float ht) {
    vec2 a = abs(q - c);
    return -max(a.y - ht, (a.x + a.y - hl) * 0.70710678);
}
float sdSegV(vec2 q, vec2 c, float hl, float ht) {
    vec2 a = abs(q - c);
    return -max(a.x - ht, (a.x + a.y - hl) * 0.70710678);
}
// One digit; q: mm from the digit cell's top-left (x along the board's +x, y along +z: the digit's top is -z).
// Seven hexagonal bars with 45 degree ends, as a real 7-segment part's segments are, and CLEAR SPACE between them: two segments that
// meet at a joint face each other with parallel 45 degree edges SEG_GAP apart, so the gap is the same all round the digit and no two segments touch.
// The layout follows from that one rule. At a corner the two bars' tips both stand `a` in from the cell's edge (half a stroke plus the gap's share of
// the diagonal); at the middle line the vertical bars' tips stand one share short of it and the middle bar's own tip wedges in between them.
float seg7Sd(vec2 q, int bits) {
    float W = SEG_CELL.x, H = SEG_CELL.y, ht = SEG_STROKE * 0.5;
    float gd = SEG_GAP * 0.70710678;             // the gap's share of a diagonal step
    float a = ht + gd;                           // a corner tip's distance from the cell's edge
    float hl = W * 0.5 - a;                      // a horizontal bar's half length, tip to centre
    float yb = H * 0.5 - gd;                     // the upper vertical bars' lower tips (the lower bars' upper tips stand at H - yb)
    float vh = (yb - a) * 0.5;                   // a vertical bar's half length
    float vc = (a + yb) * 0.5;                   // the upper vertical bars' centre (the lower ones': H - vc)
    float m = -1e3;
    if (hasSeg(bits, 1)) m = max(m, sdSegH(q, vec2(W * 0.5, ht), hl, ht));
    if (hasSeg(bits, 64)) m = max(m, sdSegH(q, vec2(W * 0.5, H * 0.5), hl, ht));
    if (hasSeg(bits, 8)) m = max(m, sdSegH(q, vec2(W * 0.5, H - ht), hl, ht));
    if (hasSeg(bits, 2)) m = max(m, sdSegV(q, vec2(W - ht, vc), vh, ht));
    if (hasSeg(bits, 4)) m = max(m, sdSegV(q, vec2(W - ht, H - vc), vh, ht));
    if (hasSeg(bits, 16)) m = max(m, sdSegV(q, vec2(ht, H - vc), vh, ht));
    if (hasSeg(bits, 32)) m = max(m, sdSegV(q, vec2(ht, vc), vh, ht));
    return m;
}

// ---- the smoked glass over a display's window --------------------------------------------------------------------------
// ONE static pane, the same function in the board (the window and the unlit segments seen through it, its texture and sheen; Blueprint draws it as a hatch)
// and in the glow (the lit segments seen through it). It depends on the board point alone, so it never moves and the cached board keeps it. r3s2A.rgb is
// what the glass lets through (the family's tint: Theme.siliconEvaGlass / siliconBlueprintGlass); the numbers below are its character.
const float GLASS_SAT = 1.14;                // the glass leaves a lit colour a little more saturated than it found it
const float GLASS_GRAIN = 0.09;              // how much of a lit segment's light the pane's texture takes or gives
float glassHash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
// the pane's texture, -1 .. 1: fine streaks along the board's diagonal (hairlines that stand upright on screen, ~0.24 mm apart across, ~1.7 mm long)
float glassStreak(vec2 p) {
    vec2 q = vec2((p.x + p.y) * 0.70710678 / 1.7, (p.x - p.y) * 0.70710678 / 0.24);
    vec2 i = floor(q);
    vec2 f = fract(q);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(glassHash(i), glassHash(i + vec2(1.0, 0.0)), f.x), mix(glassHash(i + vec2(0.0, 1.0)), glassHash(i + vec2(1.0, 1.0)), f.x), f.y) * 2.0 - 1.0;
}
// Blueprint's drawn pane: fine hatch lines of constant x + z (level hairlines on screen, the drafting convention for a tinted cover); the coverage 0..1 of the
// nearest line at the board point p, for `pxPerMm` device pixels per mm
float glassHatch(vec2 p, float pxPerMm) {
    const float pitch = 1.4;                                     // mm of x + z between two lines: ~2 px at the popup's 1x, ~6 px at 3x
    float pp = pitch * 0.40824829 * pxPerMm;                     // the pitch in px along the screen's y
    float d = abs(fract((p.x + p.y) / pitch) - 0.5) * pp;        // px from the nearest line
    return (1.0 - smoothstep(0.3, 0.95, d)) * mix(0.35, 1.0, smoothstep(2.0, 3.6, pp));       // a hatch that is a hair across is a speckle: it eases off as the picture shrinks
}
// what the glass lets through of the UNLIT segments: half as much dimming as the window gets, so a display with few digits still reads as a seven-segment one
vec3 glassGhost() {
    return mix(r3s2A.rgb, vec3(1.0), 0.5);
}
// a lit colour seen through the glass: a little more saturated, then what the glass lets through, the pane's texture in it
vec3 glassLit(vec3 c, vec2 p) {
    c = mix(vec3(dot(c, vec3(0.299, 0.587, 0.114))), c, GLASS_SAT);
    return c * r3s2A.rgb * (1.0 + GLASS_GRAIN * glassStreak(p));
}

// The ink of the CPU's three displays: the profile's colour a tad brighter than the hologram, the traces and the bar glyph keep it. The lit segment's luminance goes up by CPU_INK_LIFT (a fraction of itself), by mixing towards white (so the hue stays
// the profile's), the mix capped so that a colour already near white is not washed out.
const float CPU_INK_LIFT = 0.17;
const float CPU_INK_MAX = 0.2;
vec3 cpuInk(vec3 c) {
    float L = dot(c, vec3(0.299, 0.587, 0.114));
    return mix(c, vec3(1.0), min(CPU_INK_LIFT * L / max(1.0 - L, 0.05), CPU_INK_MAX));
}

// The display `i` at the board point p (mm): the unlit segments (`ghost`: every segment of every cell and the colon's two
// dots) or the lit ones (`fig` is the display's four cell codes, right-aligned in its cells). Positive inside a shape.
// Cell k's slot is SEG_PITCH wide and holds the digit at its left and the decimal point in the gap at its right; a colon
// display opens SEG_COLON_GAP between its 2nd and 3rd slot, where the colon stands.
float segFieldSd(int i, vec2 p, vec4 fig, bool ghost) {
    vec2 c0 = segCell0(i);
    float u = p.x - c0.x;
    float v = p.y - c0.y;
    int n = segCells(i);
    bool colon = segHasColon(i);
    float pitch = SEG_PITCH;
    float best = -2.0;
    if (colon && u >= 2.0 * pitch && u < 2.0 * pitch + SEG_COLON_GAP) {
        // the colon: two dots, centred between the 2nd digit's right edge and the 3rd digit's left edge
        float cx = 2.0 * pitch + SEG_COLON_GAP * 0.5 - (pitch - SEG_CELL.x) * 0.5;
        float lit = ghost ? 1.0 : (fig.y >= 31.5 ? 1.0 : 0.0);
        float d1 = 0.42 - length(vec2(u - cx, v - SEG_CELL.y * 0.32));
        float d2 = 0.42 - length(vec2(u - cx, v - SEG_CELL.y * 0.68));
        return lit > 0.5 ? max(d1, d2) : -2.0;
    }
    float us = (colon && u >= 2.0 * pitch + SEG_COLON_GAP) ? u - SEG_COLON_GAP : u;
    int k = int(floor(us / pitch));
    if (us < 0.0 || k < 0 || k >= n)
        return best;
    float ux = us - float(k) * pitch;
    float code = k == 0 ? fig.x : (k == 1 ? fig.y : (k == 2 ? fig.z : fig.w));
    int bits = ghost ? 127 : seg7Bits(codeChar(code));
    best = seg7Sd(vec2(ux, v), bits);
    if (!ghost && codeDp(code))
        best = max(best, 0.50 - length(vec2(ux - SEG_CELL.x - (pitch - SEG_CELL.x) * 0.5, v - SEG_CELL.y + 0.50)));
    return best;
}
