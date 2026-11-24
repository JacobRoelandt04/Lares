#version 440

// =============================================================================
// weather_glyph.frag
//
// A weather condition glyph CARVED into the surface. Every part of it (a sun's
// crown and its disc, a cloud, a drop, a flake, a bolt, a star) is a shape
// pressed into the panel in ShadowBox's language -- a light bevel rim OUTSIDE
// the edge, an inset shadow INSIDE it, a flat body -- and the body is the
// part's OWN colour (a white cloud, a yellow sun, a blue drop: the
// references), with the inset starting from that colour darkened by the
// theme's glyph shade, so the carve reads as depth on a white cloud and on an
// amber bolt alike.
//
// Analytic signed distances, no textures, no layers: one quad per glyph.
//
// PARTS. Up to eight, as named vec4 pairs (QML arrays do not bind to uniform
// arrays, and a local array indexed by a loop counter is scratch memory on
// iris -- see tools/dev/gooey_field_ubo.py for the precedent):
//
//   paN = (type, cx, cy, s)        pbN = (p1, p2, p3, colour)
//
//   type  0 DISC      centre, r = s
//         1 CAPSULE   a = (cx, cy), b = (p1, p2), r = s
//         2 CLOUD     centre of the bounding box, width = s (height 0.63 s):
//                     a stadium base, a left lump, a dome and a right bump, ONE
//                     silhouette; p1 picks the model (0 the front cloud, 1 the
//                     grey one behind)
//         3 CROWN     centre, tip radius s, valley radius p1, p2 points: the
//                     serrated star a sun's disc sits on
//         4 MOON      centre, r = s, phase p1 (0..1, 0.5 = full): the LIT part
//         5 DROP      centre of the round end, width s, angle p1 (deg, 0 = apex up)
//         6 FLAKE     centre, arm length s, side-branch length p1 (share of s, 0 = none),
//                     arm radius p2 (the composition floors it in device pixels)
//         7 BOLT      centre, height s: a seven-vertex zigzag
//         8 CURL      a = (cx, cy), b = (p1, p2), r = s, signed R = p3: a capsule
//                     that ends in a 270-degree hook (centre above b for R < 0)
//         9 STAR      centre, tip radius s: five points
//        10 CRESCENT  centre, r = s, p1 = +1 opening up-right / -1 up-left
//        11 ARROW     centre, half-length s, angle p1 (deg clockwise, 0 = pointing up):
//                     a notched dart
//
//   colour 0 sun disc  1 sun crown  2 moon  3 star  4 cloud  5 back cloud
//          6 drop      7 flake      8 hail  9 bolt 10 fog   11 wind
//
// Coordinates are the unit square (y down) that the item's `size` scales; the
// effect item is that square grown by `margin` px on every side so the bevel,
// which lies outside a part's edge, has room at the square's border.
//
// BANDS ARE MEASURED IN DEVICE PIXELS. Every part's distance is a distance in
// unit-square units with a unit gradient -- exact for the discs, capsules,
// polygons, folds and the cloud's interior; the moon's terminator ellipse is
// normalised by its own analytic gradient; only the cloud's smooth-union
// fillets dip to 0.74 in the notch where two lumps meet, which widens the rim
// there by a fraction of a pixel -- so ONE scale turns all of them into device
// pixels: the screen-space derivative of the unit-square coordinate itself,
// taken once per fragment in main(). `bevelWidth` and `shadowWidth` then mean
// device pixels under any scale or rotation the item is drawn at.
//
// The derivative is of a LINEAR function on purpose. Measuring each part's own
// composed distance instead would make the band depend on how the driver's
// 2x2 derivative quads pair the pixels: across a fold, a medial axis or a
// min() of two shapes the finite difference is not the gradient, and a glyph
// moved by one pixel would differ from itself on 24-68 rim pixels by up to
// 181 levels -- the rims would shimmer while the strip scrolls. A linear
// coordinate's difference is the same in every quad, so a glyph is the same
// picture wherever it sits.
//
// THE CARVE, per part, from depth (device px, positive inside):
//
//   depth <= -bevelWidth - 0.5      nothing at all (exact zero -- the glyph
//                                   sits over a card or a moving backdrop)
//   -bevelWidth - 0.5 < depth < 0   bevelColor at alpha bevelAlpha * ease(1 - u),
//                                   u = (-depth - 0.5) / bevelWidth
//   0 <= depth < inset              mix(body, shadowStart, edgeAlpha * (1 - ease(depth/inset))^falloff)
//   depth >= inset                  body
//
//   inset       = min(shadowWidth, max(1, thickness * partShadowShare))
//   body        = mix(panelSunk, colour, bodyTint)
//   shadowStart = mix(colour * shade, colour, shadowTint)
//
// The shade MULTIPLIES the colour rather than being mixed into it: a grey
// mixed into a yellow is a dull olive, a yellow darkened by the same grey is a
// deeper gold, and a white cloud's edge is the shade itself. `shade` is the
// theme's `weatherGlyphShade`, one per mode, so the carve is the same depth to
// the eye on the light card and on the dark one (Theme.shadowDeep is near
// black in dark mode, and a white cloud carved toward it reads as a blur).
//
// `thickness` is the part's own inscribed half-width in device pixels (a drop's
// round end, a flake's arm, a bolt's stroke): the inset is capped by a share of
// it, so a 2 px arm keeps its colour instead of being all shadow while a cloud
// carves the glyph's full depth.
//
// The rim band starts half a device pixel OUT from the edge, where the seam's
// antialiasing feather ends: a one-pixel rim measured from the edge itself
// shares half its pixel with the seam and comes and goes with the sub-pixel
// phase (measured). Parts composite FRONT OVER BACK (slot 0 is the
// back): a cloud in front of a sun carves its own rim over the sun's body,
// which is the gap that keeps the two apart at 24 px, and the same rim across
// a bolt is what puts the bolt BEHIND the cloud it comes out of. A front part
// is opaque from its edge in (bevelAlpha 1), so nothing behind it -- body or
// rim -- shows through it. Everything is
// premultiplied, as every shader in the repo: Qt hands colour uniforms over
// that way, so a mix of two of them is already premultiplied.
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

    vec4  bevelColor;
    vec4  shade;
    vec4  panelSunk;
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

// CSS cubic-bezier easing: solve x for t by Newton, then read y. Same solver
// as shadow_box.frag, so the curves match to the same tolerance.
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

// ---- primitives (negative inside) -------------------------------------------

float sdDisc(vec2 p, vec2 c, float r) {
    return length(p - c) - r;
}

float sdSeg(vec2 p, vec2 a, vec2 b, float r) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-8), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Polynomial smooth minimum: one silhouette out of several shapes.
float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

vec2 rot(vec2 v, float a) {
    float c = cos(a);
    float s = sin(a);
    return vec2(c * v.x - s * v.y, s * v.x + c * v.y);
}

// ---- the cloud ----------------------------------------------------------------
//
// Fitted to the references' cloud (set3, measured column by column): a stadium
// base with a flat bottom, a left lump, the big dome LEFT of centre and a
// smaller bump to its right. Unit width, bounding box [-0.5, 0.5] x
// [-0.315, 0.315]. The grey cloud BEHIND is a second model on the same box and
// the same four shapes (`cloudBack`): a round left dome, the tallest dome right
// of centre and a low right end, so the cloud peeking out behind the white one
// is a different cloud and not the front one again.
//
// Outside, the smooth union of the four distances is the shape, fillets and
// all. Inside, `min()` of the four is NOT the distance to the silhouette -- it
// is the depth inside whichever shape the point is deepest in, and where two
// shapes' HIDDEN edges cross (the base's top edge through the dome's belly)
// that depth is ~0 and the inset draws a dark spot in the middle of the cloud.
// The interior depth is therefore the distance to the nearest UNCOVERED piece
// of boundary: each arc's nearest point counts only if no other shape covers
// it, the base's bottom edge always counts, and the four crossings where one
// uncovered arc hands over to the next stand in for the arcs' ends (a point
// whose nearest arc points are all covered is nearest to one of those). The
// crossings are each model's own circle intersections, computed off line.
struct CloudModel {
    vec2 ba; vec2 bb; float br;     // the base: a stadium from ba to bb
    vec2 l; float lr;               // the left lump
    vec2 m; float mr;               // the dome
    vec2 r; float rr;               // the right bump
    vec2 xLM; vec2 xMR;             // lump meets dome, dome meets bump
    vec2 xLB; vec2 xRB;             // lump meets the base's left end, bump the right
};
const CloudModel cloudFront = CloudModel(
    vec2(-0.35, 0.165), vec2(0.35, 0.165), 0.15,
    vec2(-0.29, 0.115), 0.185,
    vec2(-0.05, -0.07), 0.245,
    vec2(0.205, 0.035), 0.195,
    vec2(-0.2950, -0.0699), vec2(0.1786, -0.1582),
    vec2(-0.4709, 0.0762), vec2(0.3997, 0.0235));
const CloudModel cloudBack = CloudModel(
    vec2(-0.355, 0.17), vec2(0.355, 0.17), 0.145,
    vec2(-0.22, -0.02), 0.21,
    vec2(0.10, -0.10), 0.215,
    vec2(0.33, 0.08), 0.15,
    vec2(-0.0956, -0.1892), vec2(0.3128, -0.0690),
    vec2(-0.4210, 0.0409), vec2(0.4792, 0.0952));

// Whether a point lies strictly inside any cloud shape other than `self`
// (0 lump, 1 dome, 2 bump, 3 base).
bool cloudCovered(CloudModel k, vec2 q, int self) {
    const float eps = -1e-4;
    if (self != 0 && sdDisc(q, k.l, k.lr) < eps) return true;
    if (self != 1 && sdDisc(q, k.m, k.mr) < eps) return true;
    if (self != 2 && sdDisc(q, k.r, k.rr) < eps) return true;
    return self != 3 && sdSeg(q, k.ba, k.bb, k.br) < eps;
}

float cloudArc(CloudModel k, vec2 q, vec2 c, float r, int self, float d) {
    vec2 n = q - c;
    float l = max(length(n), 1e-6);
    return cloudCovered(k, c + n * (r / l), self) ? 1e9 : abs(d);
}

// Called with one of the two CONSTANT models (partDist), never a model chosen
// at run time: inlined, each call folds its model into immediates. A model
// picked per fragment keeps all 22 of its numbers in registers through the part
// loop and costs the shader its SIMD16 variant (measured).
float sdCloud(vec2 p, vec2 c, float s, CloudModel k) {
    vec2 q = (p - c) / s;
    float dL = sdDisc(q, k.l, k.lr);
    float dM = sdDisc(q, k.m, k.mr);
    float dR = sdDisc(q, k.r, k.rr);
    float dB = sdSeg(q, k.ba, k.bb, k.br);
    float kk = 0.03;
    float dOut = smin(smin(smin(dL, dM, kk), dR, kk), dB, kk);
    // Outside every shape (which includes the fillet slivers the smooth union
    // adds): the silhouette distance.
    if (min(min(dL, dM), min(dR, dB)) >= 0.0) return dOut * s;
    float best = cloudArc(k, q, k.l, k.lr, 0, dL);
    best = min(best, cloudArc(k, q, k.m, k.mr, 1, dM));
    best = min(best, cloudArc(k, q, k.r, k.rr, 2, dR));
    // The base's own nearest boundary point, when nothing covers it.
    vec2 ba = k.bb - k.ba;
    vec2 ax = k.ba + ba * clamp(dot(q - k.ba, ba) / dot(ba, ba), 0.0, 1.0);
    vec2 an = q - ax;
    if (!cloudCovered(k, ax + an * (k.br / max(length(an), 1e-6)), 3))
        best = min(best, abs(dB));
    // The flat bottom, which nothing covers.
    vec2 bottom = vec2(clamp(q.x, k.ba.x, k.bb.x), k.ba.y + k.br);
    best = min(best, length(q - bottom));
    best = min(best, length(q - k.xLM));
    best = min(best, length(q - k.xMR));
    best = min(best, length(q - k.xLB));
    best = min(best, length(q - k.xRB));
    return -best * s;
}

// ---- the sun's crown ------------------------------------------------------------
//
// A regular star of `n` rounded points, tip radius R, valley radius rv. The
// plane folds onto one half-sector (the tip on the fold's axis), where the
// edge is one segment from the tip to the valley; the origin's side of it is
// inside. The fold is continuous (n is a whole number), so the distance is.
float sdCrown(vec2 p, vec2 c, float R, float rv, float n) {
    vec2 q = p - c;
    float an = 3.14159265 / max(n, 3.0);
    float a = atan(q.x, -q.y);                   // 0 = straight up, y down
    float bn = mod(a + an, 2.0 * an) - an;
    vec2 f = length(q) * vec2(cos(bn), abs(sin(bn)));
    float rnd = 0.04 * R;
    vec2 A = vec2(R - rnd, 0.0);
    vec2 B = (rv - rnd) * vec2(cos(an), sin(an));
    vec2 e = B - A;
    vec2 w = f - A;
    vec2 h = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    float side = e.x * w.y - e.y * w.x;
    return (side > 0.0 ? -length(h) : length(h)) - rnd;
}

// ---- moons ------------------------------------------------------------------------

// The lit part of a disc at a phase. The terminator is the classic one: a
// half-disc on the lit side plus an ellipse whose x semi-axis is
// r * cos(2 pi phase), so a crescent is the half-disc MINUS the ellipse and a
// gibbous moon is the half-disc PLUS it. Waxing (phase < 0.5) is lit on the
// right.
float sdMoon(vec2 p, vec2 c, float r, float phase) {
    vec2 q = p - c;
    if (phase > 0.5) q.x = -q.x;
    float cs = cos(6.2831853 * phase);          // +1 new, -1 full
    float dd = sdDisc(q, vec2(0.0), r);
    float a = max(abs(cs) * r, 1e-4);
    // The ellipse's implicit function over the length of its gradient: a
    // first-order distance, unit-gradient at the terminator, where the band is
    // drawn (the plain (|q/axes| - 1) * min(axes) runs at a/r of the true
    // distance on the terminator's ends and thins the rim there).
    vec2 ax = vec2(a, r);
    float k0 = length(q / ax);
    float k1 = max(length(q / (ax * ax)), 1e-6);
    float de = k0 * (k0 - 1.0) / k1;
    if (cs > 0.0) return max(dd, max(-q.x, -de));   // crescent
    return max(dd, min(-q.x, de));                  // gibbous (full at cs = -1)
}

// The references' fat crescent: the disc minus one offset by (0.50, -0.26) r
// with radius 0.93 r (set3, measured), opening up-right; `side` -1 mirrors it
// to open up-left, which is how it peeks out from behind a cloud's top-right.
float sdCrescent(vec2 p, vec2 c, float r, float side) {
    vec2 q = p - c;
    q.x *= side < 0.0 ? -1.0 : 1.0;
    return max(length(q) - r, -(length(q - r * vec2(0.50, -0.26)) - 0.93 * r));
}

// A five-pointed star, one point up, tips rounded. The fold by the star's
// mirror lines is exact (the standard construction, y flipped for screen).
float sdStar(vec2 p, vec2 c, float r) {
    const vec2 k1 = vec2(0.809016994375, -0.587785252292);
    const vec2 k2 = vec2(-0.809016994375, -0.587785252292);
    float rnd = 0.12 * r;
    float rr = r - rnd;
    vec2 q = p - c;
    q.y = -q.y;
    q.x = abs(q.x);
    q -= 2.0 * max(dot(k1, q), 0.0) * k1;
    q -= 2.0 * max(dot(k2, q), 0.0) * k2;
    q.x = abs(q.x);
    q.y -= rr;
    vec2 ba = 0.46 * vec2(-k1.y, k1.x) - vec2(0.0, 1.0);
    float h = clamp(dot(q, ba) / dot(ba, ba), 0.0, rr);
    float d = length(q - ba * h);
    return (q.y * ba.x - q.x * ba.y < 0.0 ? -d : d) - rnd;
}

// ---- precipitation -------------------------------------------------------------------

// The convex hull of a circle (radius r1 at the origin) and a point (0, h),
// h > r1 -- a teardrop with the apex at +y. The caller flips y so the apex
// points up on screen, and dilates by the corner rounding.
float sdTeardrop(vec2 p, float r1, float h) {
    p.x = abs(p.x);
    float b = r1 / h;
    float a = sqrt(max(1.0 - b * b, 1e-6));
    float k = dot(p, vec2(-b, a));
    if (k < 0.0) return length(p) - r1;
    if (k > a * h) return length(p - vec2(0.0, h));
    return dot(p, vec2(a, b)) - r1;
}

// Width s, the apex 0.95 s above the round end's centre (set3's drops are
// about 1.5 times as tall as wide).
float sdDrop(vec2 p, vec2 c, float s, float angleDeg) {
    vec2 q = rot(p - c, -radians(angleDeg));
    float rho = 0.10 * s;
    float r1 = 0.5 * s - rho;
    float h = 0.95 * s - rho;
    return sdTeardrop(vec2(q.x, -q.y), r1, h) - rho;
}

// Six arms, one straight up; with `branch` > 0 each arm carries a pair of
// side branches leaning out toward its tip (the references' dendrite). The
// plane folds onto one half-arm; the fold is continuous, so the distance is.
float sdFlake(vec2 p, vec2 c, float len, float branch, float armR) {
    vec2 q = p - c;
    const float seg = 1.04719755;               // 60 degrees
    float a = atan(q.x, -q.y);
    a = abs(mod(a + 0.5 * seg, seg) - 0.5 * seg);
    vec2 f = length(q) * vec2(cos(a), sin(a));
    float rr = max(armR, 1e-4);
    float d = sdSeg(f, vec2(0.0), vec2(len - rr, 0.0), rr);
    if (branch > 0.0) {
        vec2 b0 = vec2(0.52 * len, 0.0);
        d = min(d, sdSeg(f, b0, b0 + branch * len * vec2(0.5, 0.8660254), 0.85 * rr));
    }
    return d;
}

// One edge of the polygon distance: nearest-distance and the crossing-count
// sign, as in the standard exact polygon SDF, unrolled over fixed vertices.
void polyEdge(vec2 p, vec2 vi, vec2 vj, inout float d2, inout float s) {
    vec2 e = vj - vi;
    vec2 w = p - vi;
    vec2 b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
    d2 = min(d2, dot(b, b));
    bvec3 cnd = bvec3(p.y >= vi.y, p.y < vj.y, e.x * w.y > e.y * w.x);
    if (all(cnd) || all(not(cnd))) s = -s;
}

// The references' zigzag: a slanted top bar, a step, and a long point down
// and to the left. Unit height, centred on its bounding box.
float sdBolt(vec2 p, vec2 c, float scale) {
    vec2 q = (p - c) / scale + vec2(0.06, 0.0);
    const vec2 v0 = vec2( 0.08, -0.50);
    const vec2 v1 = vec2( 0.40, -0.50);
    const vec2 v2 = vec2( 0.13, -0.07);
    const vec2 v3 = vec2( 0.38, -0.07);
    const vec2 v4 = vec2(-0.30,  0.50);
    const vec2 v5 = vec2(-0.05,  0.05);
    const vec2 v6 = vec2(-0.29,  0.05);
    const float rnd = 0.03;
    float d2 = dot(q - v0, q - v0);
    float s = 1.0;
    polyEdge(q, v0, v6, d2, s);
    polyEdge(q, v1, v0, d2, s);
    polyEdge(q, v2, v1, d2, s);
    polyEdge(q, v3, v2, d2, s);
    polyEdge(q, v4, v3, d2, s);
    polyEdge(q, v5, v4, d2, s);
    polyEdge(q, v6, v5, d2, s);
    return (s * sqrt(d2) - rnd) * scale;
}

// ---- wind -----------------------------------------------------------------------

// A ring segment of half-aperture `ap` (sc = sin, cos of it) centred on +y,
// radius ra, stroke radius rb.
float sdArc(vec2 p, vec2 sc, float ra, float rb) {
    p.x = abs(p.x);
    return ((sc.y * p.x > sc.x * p.y) ? length(p - sc * ra) : abs(length(p) - ra)) - rb;
}

// A capsule a -> b that continues into a 270-degree hook at b. The hook's
// centre sits straight above b (R < 0) or below it (R > 0) at |R|, so the arc
// leaves b along the line's own direction and curls back over its end.
float sdCurl(vec2 p, vec2 a, vec2 b, float r, float R) {
    float d = sdSeg(p, a, b, r);
    float ar = max(abs(R), 1e-4);
    vec2 cc = b + vec2(0.0, R);
    vec2 m = normalize(vec2(1.0, R < 0.0 ? -1.0 : 1.0));
    vec2 xa = vec2(m.y, -m.x);
    vec2 q = vec2(dot(p - cc, xa), dot(p - cc, m));
    return min(d, sdArc(q, vec2(0.70710678, -0.70710678), ar, r));
}

// A notched dart pointing up at angle 0, turned clockwise by `angleDeg`:
// the tip, two swept-back barbs, the notch between them.
float sdArrow(vec2 p, vec2 c, float s, float angleDeg) {
    vec2 q = rot(p - c, -radians(angleDeg)) / s;
    const vec2 v0 = vec2( 0.00, -1.00);
    const vec2 v1 = vec2( 0.74,  0.86);
    const vec2 v2 = vec2( 0.00,  0.44);
    const vec2 v3 = vec2(-0.74,  0.86);
    const float rnd = 0.08;
    float d2 = dot(q - v0, q - v0);
    float sg = 1.0;
    polyEdge(q, v0, v3, d2, sg);
    polyEdge(q, v1, v0, d2, sg);
    polyEdge(q, v2, v1, d2, sg);
    polyEdge(q, v3, v2, d2, sg);
    return (sg * sqrt(d2) - rnd) * s;
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

    // Rim outside the edge: bevelColor, full from the seam feather's outer
    // edge and fading to nothing over bevelWidth beyond it, alpha-blended so
    // whatever the glyph sits on shows through it.
    float u = clamp((-depth - 0.5) / max(bevelWidth, 1e-3), 0.0, 1.0);
    vec4 bevel = bevelColor * (bevelAlpha * ease(1.0 - u, bevelEasing));

    // Inset inside the edge: from the shade-and-colour start to the body,
    // ShadowBox's strength curve.
    vec4 body = mix(panelSunk, colour, bodyTint);
    vec4 start = mix(vec4(colour.rgb * shade.rgb, colour.a), colour, shadowTint);
    float fs = ease(clamp(depth / max(inset, 1e-3), 0.0, 1.0), shadowEasing);
    float strength = edgeAlpha * pow(max(0.0, 1.0 - fs), falloff);
    vec4 inner = depth >= inset ? body : mix(body, start, strength);

    // The rim/inset seam at depth 0 is a real edge in the design; antialias
    // it over one device pixel rather than step it.
    return mix(bevel, inner, smoothstep(-0.5, 0.5, depth));
}

float partDist(vec4 a, vec4 b, vec2 p) {
    float t = a.x;
    vec2 c = a.yz;
    float s = a.w;
    if (t < 0.5) return sdDisc(p, c, s);
    if (t < 1.5) return sdSeg(p, c, b.xy, s);
    if (t < 2.5) return b.x > 0.5 ? sdCloud(p, c, s, cloudBack) : sdCloud(p, c, s, cloudFront);
    if (t < 3.5) return sdCrown(p, c, s, b.x, b.y);
    if (t < 4.5) return sdMoon(p, c, s, b.x);
    if (t < 5.5) return sdDrop(p, c, s, b.x);
    if (t < 6.5) return sdFlake(p, c, s, b.x, b.y);
    if (t < 7.5) return sdBolt(p, c, s);
    if (t < 8.5) return sdCurl(p, c, b.xy, s, b.z);
    if (t < 9.5) return sdStar(p, c, s);
    if (t < 10.5) return sdCrescent(p, c, s, b.x);
    return sdArrow(p, c, s, b.x);
}

// The part's inscribed half-width in unit-square units: what caps its inset.
float partThickness(vec4 a, vec4 b) {
    float t = a.x;
    float s = a.w;
    if (t < 1.5) return s;                      // disc, capsule
    if (t < 2.5) return 0.15 * s;               // cloud: the base's radius
    if (t < 3.5) return 0.6 * (s - b.x);        // crown: the points
    if (t < 4.5) return 0.35 * s;               // moon
    if (t < 5.5) return 0.4 * s;                // drop: the round end
    if (t < 6.5) return b.y;                    // flake: an arm
    if (t < 7.5) return 0.1 * s;                // bolt: the stroke
    if (t < 8.5) return s;                      // curl
    if (t < 9.5) return 0.3 * s;                // star
    if (t < 10.5) return 0.3 * s;               // crescent
    return 0.3 * s;                             // arrow
}

// The part's carve at this fragment; `px` is unit-square units per device
// pixel (main()), the same for every part and every fragment of the glyph.
vec4 part(vec4 a, vec4 b, vec2 p, float px) {
    float d = partDist(a, b, p);
    float inset = min(shadowWidth, max(1.0, partThickness(a, b) / px * partShadowShare));
    return carve(-d / px, inset, b.w);
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
    // A loop rather than unrolled slots: the shader carries ONE copy of every
    // shape and of the carve.
    // clamped in float, then converted: GLSL 1.20 and ES 1.00 have no integer clamp (NVIDIA refuses the 100 es variant, C7011), and for
    // every finite partCount this is the old clamp(int(partCount + 0.5), 0, 8) exactly
    int n = int(clamp(partCount + 0.5, 0.0, 8.0));
    vec4 acc = vec4(0.0);
    for (int i = 0; i < n; i++)
        acc = over(acc, part(slotA(i), slotB(i), p, px));
    fragColor = acc * qt_Opacity;
}
