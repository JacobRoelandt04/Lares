#version 440

// =============================================================================
// net_glyph.frag
//
// A piece of network HARDWARE: an RJ45 jack, an SMA antenna connector, a
// keyswitch, an access point, a breaker, a bluetooth module.
//
// TWO SHADING MODELS, chosen by `shadeMode`, over the same shapes.
//
//   0  CARVED   ShadowBox's language: a light bevel rim OUTSIDE the edge, an
//               inset shadow INSIDE it, a flat body. This is what the rest of
//               the shell is made of, and it is kept so a sheet can show the
//               two side by side -- but it is NOT what these icons use. Every
//               part of a socket is small, and giving each one its own inset
//               puts a dark rim inside every contact, every arc and every
//               lens: the set comes out muddy.
//
//   1  LIFTED   The object stands ON the plate instead of being cut into it.
//               One light direction for the whole set; each part casts a soft
//               contact shadow on whatever is behind it (so a comb of contacts
//               really sits IN its cavity and a lever really sits ON its
//               body), takes a bright rim only on the edges that FACE the
//               light, a gentle shade on the ones that face away, and a body
//               that brightens toward the light. No inset anywhere.
//
// The edge terms are computed by OFFSET SILHOUETTE, never from a normal: the
// sample point is displaced a fixed distance in UNIT-SQUARE units and the
// shape is asked whether it is still inside. That is position-independent, so
// the picture is the same wherever the glyph sits -- a normal taken from the
// derivative of a composed distance is not (see BANDS).
//
// This is weather_glyph.frag's engine with network shapes: the uniform block,
// the CSS-bezier easing, `over`, the by-name slot accessors and `main` are the
// same code for the same reasons, and the same two rules hold.
//
// WHY THE LAMPS ARE NOT IN HERE. A lit lamp is one small DISC part in its own
// instance, drawn OVER a socket rather than inside it, for two reasons. The
// bevel is alpha-blended over whatever is behind, so a lamp under the socket's
// rim would be dimmed by it. And an activity lamp blinks: a uniform that
// changes several times a second would re-upload this whole block and repaint
// every pixel the socket covers, where an 8 px lamp quad repaints 64
// (CLAUDE.md, the weather backdrop's lesson). The socket draws the dead lens;
// SocketLamp draws the light.
//
// PARTS. Up to eight, as named vec4 pairs (QML arrays do not bind to uniform
// arrays, and a local array indexed by a loop counter is scratch memory on
// iris):
//
//   paN = (type, cx, cy, s)        pbN = (p1, p2, p3, colour)
//
//   type  0 BOX       centre, half-width p1, half-height p2, corner r = s,
//                     rotation p3 (turns, clockwise)
//         1 KEYSTONE  an RJ45 face: a box (half-width p1, half-height p2,
//                     corner r = s) with the latch tab standing off its TOP
//                     edge, tab half-width p3, protruding tabRise * p2
//         2 COMB      n = p3 teeth of half-width s and half-length p1 on a
//                     pitch p2, centred on (cx, cy) -- ONE part, folded
//                     analytically, because eight contacts at a 3 px pitch
//                     cannot be eight slots
//         3 DISC      centre, r = s
//         4 RING      centre, radius s, half-thickness p1
//         5 ARC       centre, radius s, half-thickness p1, half-aperture p2
//                     (turns) about +y, rotated p3 (turns)
//         6 HEXNUT    centre, inradius s, corner rounding p1: the SMA nut
//         7 MEANDER   a printed serpentine: trace half-width s, block
//                     half-width p1, half-height p2, p3 legs
//         8 CAPSULE   a = (cx, cy), b = (p1, p2), r = s
//         9 SCREW     centre, r = s, a slot of half-width p1 cut across it,
//                     rotation p2 (turns)
//        10 SHACKLE   a padlock's shackle: a half ring of radius s opening
//                     DOWNWARD from `centre`, half-thickness p1, with two legs
//                     of length p2 hanging off its ends. p3 unhooks the right
//                     leg, which is the whole of open-versus-shut.
//
// Slot 0 is the BACK; a cavity drawn after its shell sits inside it.
//
// COLOURS by index, the theme's `net*` tokens:
//   0 shell  1 shellDark  2 contact  3 lampOff  4 pcb  5 trace
//   6 brass  7 bezel      8 legend   9 plate   10 lampLink 11 lampAct
//
// BANDS. The bevel and the inset are measured in DEVICE pixels, taken from the
// screen-space derivative of the shader's own LINEAR coordinate -- never from
// a derivative of the composed distance, which is not linear across a 2x2
// derivative quad and re-rasterises the whole glyph when the item moves one
// pixel (measured on the weather glyphs: 166 levels of difference on a (1,1)
// shift). Every distance below is unit-gradient for the same reason.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    float size;             // the glyph's square, item px
    float margin;           // the effect overflows the square by this on every side, item px
    float partCount;

    float bevelWidth;       // device px
    float shadowWidth;      // device px
    float partShadowShare;  // inset cap, share of a part's inscribed half-width
    float bevelAlpha;
    float edgeAlpha;
    float falloff;
    float shadowTint;       // 0 = the colour times the shade, 1 = the colour (no inset)
    float bodyTint;         // 0 = panelSunk, 1 = the colour
    float tabRise;          // KEYSTONE: the latch tab's protrusion, share of p2

    // ---- LIFTED (shadeMode 1). Distances are UNIT-SQUARE units, so every
    // term is a property of the object and scales with it.
    float shadeMode;        // 0 carved, 1 lifted
    float lightX;           // the light's direction, unit square, y DOWN
    float lightY;
    float dropDist;         // how far a part's shadow falls
    float dropSoft;         // its penumbra
    float dropAlpha;
    float rimWidth;         // the lit edge
    float rimAlpha;
    float shadeWidth;       // the edge facing away
    float shadeAlpha;
    float gradStrength;     // how much the body brightens toward the light
    float glossStart;       // the specular band, along the light axis
    float glossEnd;
    float glossAlpha;
    float outlineWidth;     // a contour just inside the edge
    float outlineAlpha;

    vec4  bevelColor;
    vec4  shade;
    vec4  panelSunk;
    vec4  dropColor;
    vec4  rimColor;
    vec4  shadeColor;
    vec4  outlineColor;
    vec4  col0;
    vec4  col1;
    vec4  col2;
    vec4  col3;
    vec4  col4;
    vec4  col5;
    vec4  col6;
    vec4  col7;
    vec4  col8;
    vec4  col9;
    vec4  col10;
    vec4  col11;
    vec4  bevelEasing;      // CSS cubic-bezier x1, y1, x2, y2
    vec4  shadowEasing;

    vec4  pa0; vec4 pa1; vec4 pa2; vec4 pa3; vec4 pa4; vec4 pa5; vec4 pa6; vec4 pa7;
    vec4  pb0; vec4 pb1; vec4 pb2; vec4 pb3; vec4 pb4; vec4 pb5; vec4 pb6; vec4 pb7;
};

const float TAU = 6.28318530718;

// CSS cubic-bezier easing: solve x for t by Newton, then read y. Same solver
// as shadow_box.frag and weather_glyph.frag, so the curves match.
float ease(float x, vec4 e) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;
    float t = x;
    for (int i = 0; i < 8; i++) {
        float mt = 1.0 - t;
        float bx  = 3.0 * mt * mt * t * e.x + 3.0 * mt * t * t * e.z + t * t * t;
        float dbx = 3.0 * mt * mt * e.x + 6.0 * mt * t * (e.z - e.x) + 3.0 * t * t * (1.0 - e.z);
        if (abs(dbx) < 1e-6) break;
        float dt = (bx - x) / dbx;
        t -= dt;
        if (abs(dt) < 1e-5) break;
    }
    t = clamp(t, 0.0, 1.0);
    float mt = 1.0 - t;
    return 3.0 * mt * mt * t * e.y + 3.0 * mt * t * t * e.w + t * t * t;
}

// ---- primitives (negative inside, unit gradient) ----------------------------

vec2 rot(vec2 v, float turns) {
    float a = turns * TAU;
    float c = cos(a);
    float s = sin(a);
    return vec2(c * v.x + s * v.y, -s * v.x + c * v.y);
}

float sdBox(vec2 p, vec2 h, float r) {
    r = min(r, min(h.x, h.y));
    vec2 q = abs(p) - h + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

float sdSeg(vec2 p, vec2 a, vec2 b, float r) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// An RJ45 face: the body, with the latch tab standing off its top edge. The
// tab's box is centred ON that edge, so half of it is inside the body and the
// union is watertight -- two antialiased shapes that merely MEET on a line do
// not sum to one (CLAUDE.md).
float sdKeystone(vec2 p, vec2 c, vec2 h, float r, float tabHw) {
    vec2 q = p - c;
    float body = sdBox(q, h, r);
    float rise = max(tabRise, 0.0) * h.y;
    float tab = sdBox(q + vec2(0.0, h.y), vec2(max(tabHw, 1e-4), rise), min(r, tabHw * 0.8));
    return min(body, tab);
}

// n teeth on a pitch, centred: fold x onto the NEAREST tooth and measure that
// one. Exact while the pitch exceeds two tooth widths, which a comb of
// contacts always does, and bounded by the count -- a plain mod() would repeat
// the comb across the whole glyph.
float sdComb(vec2 p, vec2 c, float toothHw, float halfLen, float pitch, float n) {
    vec2 q = p - c;
    float cnt = max(1.0, floor(n + 0.5));
    float span = (cnt - 1.0) * 0.5;
    float k = clamp(floor(q.x / max(pitch, 1e-4) + span + 0.5), 0.0, cnt - 1.0);
    float xr = q.x - (k - span) * pitch;
    return sdBox(vec2(xr, q.y), vec2(toothHw, halfLen), min(toothHw, halfLen) * 0.85);
}

float sdRing(vec2 p, vec2 c, float r, float hw) {
    return abs(length(p - c) - r) - hw;
}

// An annulus sector, symmetric about +y before rotation.
float sdArc(vec2 p, vec2 c, float r, float hw, float apTurns, float rotTurns) {
    vec2 q = rot(p - c, rotTurns);
    q.x = abs(q.x);
    float ap = clamp(apTurns, 0.0, 0.5) * TAU;
    vec2 sc = vec2(sin(ap), cos(ap));
    float d = (sc.y * q.x > sc.x * q.y) ? length(q - sc * r) : abs(length(q) - r);
    return d - hw;
}

// Flat-top hexagon of inradius r, corners rounded by `round`.
float sdHexnut(vec2 p, vec2 c, float r, float round) {
    const vec3 k = vec3(-0.866025404, 0.5, 0.577350269);
    float ri = max(r - round, 1e-4);
    vec2 q = abs(p - c);
    q -= 2.0 * min(dot(k.xy, q), 0.0) * k.xy;
    q -= vec2(clamp(q.x, -k.z * ri, k.z * ri), ri);
    return length(q) * sign(q.y) - round;
}

// A printed serpentine: `cnt` vertical legs joined alternately at top and
// bottom. The nearest leg and the two joins that touch it are the only
// candidates a fragment can be closest to, so this is exact without walking
// the whole trace.
float sdMeander(vec2 p, vec2 c, float hw, float halfW, float halfH, float n) {
    vec2 q = p - c;
    float cnt = max(2.0, floor(n + 0.5));
    float pitch = 2.0 * halfW / (cnt - 1.0);
    float span = (cnt - 1.0) * 0.5;
    float k = clamp(floor(q.x / max(pitch, 1e-4) + span + 0.5), 0.0, cnt - 1.0);
    float xk = (k - span) * pitch;
    float d = sdSeg(q, vec2(xk, -halfH), vec2(xk, halfH), hw);
    for (int t = 0; t < 2; t++) {
        float j = k - 1.0 + float(t);
        if (j < 0.0 || j > cnt - 2.0) continue;
        float y = (mod(j, 2.0) < 0.5) ? -halfH : halfH;
        float x0 = (j - span) * pitch;
        d = min(d, sdSeg(q, vec2(x0, y), vec2(x0 + pitch, y), hw));
    }
    return d;
}

// A slotted screw head: the slot is CUT out of the head, so the plate shows
// through it and the cut takes its own bevel.
// A padlock's shackle. The arc is the upper half of a ring; past its ends the
// nearest point IS an end, so folding x and measuring to one endpoint covers
// both. The right leg shortens as it unhooks.
float sdShackle(vec2 p, vec2 c, float r, float hw, float legL, float openF) {
    vec2 q = p - c;
    vec2 a = vec2(abs(q.x), q.y);
    float ring = (q.y <= 0.0) ? abs(length(q) - r) - hw
                              : length(a - vec2(r, 0.0)) - hw;
    float legL2 = sdSeg(q, vec2(-r, 0.0), vec2(-r, legL), hw);
    float legR = sdSeg(q, vec2(r, 0.0), vec2(r, legL * (1.0 - 0.80 * clamp(openF, 0.0, 1.0))), hw);
    return min(ring, min(legL2, legR));
}

float sdScrew(vec2 p, vec2 c, float r, float slotHw, float rotTurns) {
    vec2 q = p - c;
    float head = length(q) - r;
    float slot = sdBox(rot(q, rotTurns), vec2(r * 1.3, max(slotHw, 1e-4)), max(slotHw, 1e-4) * 0.5);
    return max(head, -slot);
}

// ---- the carve --------------------------------------------------------------

vec4 colourOf(float i) {
    if (i < 0.5) return col0;
    if (i < 1.5) return col1;
    if (i < 2.5) return col2;
    if (i < 3.5) return col3;
    if (i < 4.5) return col4;
    if (i < 5.5) return col5;
    if (i < 6.5) return col6;
    if (i < 7.5) return col7;
    if (i < 8.5) return col8;
    if (i < 9.5) return col9;
    if (i < 10.5) return col10;
    return col11;
}

// One part's colour and coverage at `depth` device pixels inside its edge,
// premultiplied, with an inset `inset` device pixels deep.
vec4 carve(float depth, float inset, float colourIndex) {
    if (depth <= -bevelWidth - 0.5) return vec4(0.0);
    vec4 colour = colourOf(colourIndex);

    // Rim outside the edge: alpha-blended, so whatever the socket sits on
    // shows through it.
    float u = clamp((-depth - 0.5) / max(bevelWidth, 1e-3), 0.0, 1.0);
    vec4 bevel = bevelColor * (bevelAlpha * ease(1.0 - u, bevelEasing));

    vec4 body = mix(panelSunk, colour, bodyTint);
    vec4 start = mix(vec4(colour.rgb * shade.rgb, colour.a), colour, shadowTint);
    float fs = ease(clamp(depth / max(inset, 1e-3), 0.0, 1.0), shadowEasing);
    float strength = edgeAlpha * pow(max(0.0, 1.0 - fs), falloff);
    vec4 inner = depth >= inset ? body : mix(body, start, strength);

    return mix(bevel, inner, smoothstep(-0.5, 0.5, depth));
}

float partDist(vec4 a, vec4 b, vec2 p) {
    float t = a.x;
    vec2 c = a.yz;
    float s = a.w;
    if (t < 0.5) return sdBox(rot(p - c, b.z), vec2(b.x, b.y), s);
    if (t < 1.5) return sdKeystone(p, c, vec2(b.x, b.y), s, b.z);
    if (t < 2.5) return sdComb(p, c, s, b.x, b.y, b.z);
    if (t < 3.5) return length(p - c) - s;
    if (t < 4.5) return sdRing(p, c, s, b.x);
    if (t < 5.5) return sdArc(p, c, s, b.x, b.y, b.z);
    if (t < 6.5) return sdHexnut(p, c, s, b.x);
    if (t < 7.5) return sdMeander(p, c, s, b.x, b.y, b.z);
    if (t < 8.5) return sdSeg(p, c, b.xy, s);
    if (t < 9.5) return sdScrew(p, c, s, b.x, b.y);
    return sdShackle(p, c, s, b.x, b.y, b.z);
}

// The part's inscribed half-width in unit-square units: what caps its inset,
// so a 2 px contact keeps its gold instead of being all shadow while a metal
// face carves the full depth.
float partThickness(vec4 a, vec4 b) {
    float t = a.x;
    float s = a.w;
    if (t < 0.5) return min(b.x, b.y);          // box
    if (t < 1.5) return min(b.x, b.y);          // keystone
    if (t < 2.5) return s;                      // comb: one tooth
    if (t < 3.5) return s;                      // disc
    if (t < 4.5) return b.x;                    // ring
    if (t < 5.5) return b.x;                    // arc
    if (t < 6.5) return s;                      // hexnut
    if (t < 7.5) return s;                      // meander: the trace
    if (t < 8.5) return s;                      // capsule
    if (t < 9.5) return s;                      // screw
    return b.x;                                 // shackle: the bar
}

// The part's carve at this fragment; `px` is unit-square units per device
// pixel (main()), the same for every part and every fragment of the glyph.
vec4 part(vec4 a, vec4 b, vec2 p, float px) {
    float d = partDist(a, b, p);
    float inset = min(shadowWidth, max(1.0, partThickness(a, b) / px * partShadowShare));
    return carve(-d / px, inset, b.w);
}

// ---- the lifted model -------------------------------------------------------

vec2 lightDir() {
    vec2 l = vec2(lightX, lightY);
    float m = length(l);
    return m < 1e-5 ? vec2(-0.7071, -0.7071) : l / m;
}

// The shadow this part throws on whatever is already drawn. The union is
// sampled displaced TOWARD the light, so the shadow lands away from it, and
// the penumbra is a unit-square width -- a shadow belongs to the object, not
// to the screen, so it must grow with the socket rather than stay N pixels.
vec4 partShadow(vec4 a, vec4 b, vec2 p) {
    if (dropAlpha <= 0.0 || dropDist <= 0.0)
        return vec4(0.0);
    float d = partDist(a, b, p + lightDir() * dropDist);
    float f = 1.0 - smoothstep(-max(dropSoft, 1e-4), max(dropSoft, 1e-4), d);
    return dropColor * (f * dropAlpha);
}

// The part's own face: a body that brightens toward the light, a rim on the
// edges that face it, a shade on the ones that do not, an optional specular
// band and an optional contour. Every edge term is an OFFSET SILHOUETTE -- ask
// the shape whether a point a fixed distance toward (or away from) the light
// is still inside it -- so nothing here depends on where the glyph sits.
vec4 lift(vec4 a, vec4 b, vec2 p, float px) {
    float d = partDist(a, b, p);
    float cov = clamp(0.5 - d / px, 0.0, 1.0);
    if (cov <= 0.0)
        return vec4(0.0);

    vec2 L = lightDir();
    vec4 colour = colourOf(b.w);

    // Position along the light axis across the glyph square: 1 at the lit
    // corner, 0 at the far one.
    float t = clamp(0.5 - dot(p - vec2(0.5), L), 0.0, 1.0);
    // Brighten by MULTIPLYING, never by mixing toward white: a gold mixed with
    // white is a pale cream, a gold multiplied up is a brighter gold.
    vec3 body = colour.rgb * mix(1.0 - gradStrength, 1.0 + gradStrength, t);

    if (glossAlpha > 0.0) {
        float g = smoothstep(glossStart, glossEnd, t) * glossAlpha;
        body = mix(body, body * 1.35 + vec3(0.06), g);
    }

    if (rimAlpha > 0.0 && rimWidth > 0.0) {
        float dl = partDist(a, b, p + L * rimWidth);
        float f = clamp(dl / rimWidth, 0.0, 1.0) * rimAlpha;
        body = mix(body, rimColor.rgb, f);
    }
    if (shadeAlpha > 0.0 && shadeWidth > 0.0) {
        float ds = partDist(a, b, p - L * shadeWidth);
        float f = clamp(ds / shadeWidth, 0.0, 1.0) * shadeAlpha;
        body = mix(body, shadeColor.rgb, f);
    }
    if (outlineAlpha > 0.0 && outlineWidth > 0.0) {
        float f = (1.0 - smoothstep(0.0, outlineWidth, -d)) * outlineAlpha;
        body = mix(body, outlineColor.rgb, f);
    }

    return vec4(body, 1.0) * (cov * colour.a);
}

vec4 over(vec4 back, vec4 front) {
    return front + back * (1.0 - front.a);
}

// The slot's uniforms, by name: an if-chain, never an array, so nothing is
// copied to scratch (CLAUDE.md, the gooey field's lesson).
vec4 slotA(int i) {
    if (i == 0) return pa0;
    if (i == 1) return pa1;
    if (i == 2) return pa2;
    if (i == 3) return pa3;
    if (i == 4) return pa4;
    if (i == 5) return pa5;
    if (i == 6) return pa6;
    return pa7;
}
vec4 slotB(int i) {
    if (i == 0) return pb0;
    if (i == 1) return pb1;
    if (i == 2) return pb2;
    if (i == 3) return pb3;
    if (i == 4) return pb4;
    if (i == 5) return pb5;
    if (i == 6) return pb6;
    return pb7;
}

void main() {
    vec2 p = (qt_TexCoord0 * (size + 2.0 * margin) - margin) / max(size, 1e-3);
    // Unit-square units per device pixel: p is affine in screen space, so this
    // is exact and identical in every derivative quad (see BANDS above).
    float px = max(length(vec2(dFdx(p.x), dFdy(p.x))), 1e-6);
    // clamped in float, then converted: GLSL 1.20 and ES 1.00 have no integer clamp (NVIDIA refuses the 100 es variant, C7011), and for
    // every finite partCount this is the old clamp(int(partCount + 0.5), 0, 8) exactly
    int n = int(clamp(partCount + 0.5, 0.0, 8.0));
    vec4 acc = vec4(0.0);
    if (shadeMode < 0.5) {
        for (int i = 0; i < n; i++)
            acc = over(acc, part(slotA(i), slotB(i), p, px));
    } else {
        // Each part lays its shadow on everything already drawn, then its own
        // face over that: the comb really sits IN the cavity, the lever ON the
        // body, and the outermost part shadows the plate.
        for (int i = 0; i < n; i++) {
            vec4 a = slotA(i);
            vec4 b = slotB(i);
            acc = over(acc, partShadow(a, b, p));
            acc = over(acc, lift(a, b, p, px));
        }
    }
    fragColor = acc * qt_Opacity;
}
