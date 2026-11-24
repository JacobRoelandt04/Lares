#version 440

// =============================================================================
// bridge_body.frag -- a phone's body, traced per pixel from one quad (BodyLayer.qml; the vinyl's manner).
//
// The body is a slab: a rounded rectangle extruded through its thickness, the edge between a face and the frame
// rounded, the frame's keys standing a hair proud of it. That is one signed distance, and a ray from a pinhole camera
// is walked along it. Everything in BODY space: the origin at the body's centre, x to the right as the front is seen,
// y down, z out of the front glass. The pose arrives as the body's three axes (QML owns every motion).
//
// WHAT IT DRAWS
//   the frame      satin metal. What each wall carries -- keys, triggers, vents, the antenna's lines, every hole -- is
//                  the frame's own texture (colour, normal, roughness: tools/bridge/make_decor.py), read by where the
//                  ray meets the wall; what stands proud of it (the rocker, the power key, the slider) is in the
//                  distance too, so it shows on the silhouette
//   the front      a black glass border round the display; INSIDE the display's outline it is a HOLE: only what the
//                  glass mirrors is drawn (premultiplied, alpha near 0), so the QML face lying under this item shows
//                  through with the display's rounded corners and the glare over it. No texture of the face is taken.
//   the back       glass over the decor (four textures in the body's own millimetres): read where the eye's ray, bent
//                  into the glass, meets what lies at the decor's own depth -- so a lens sinks, a screw sits down in
//                  its well and the whole reads as glass as the phone turns -- and lit as what it is: mirror metal,
//                  paint, or a GROOVED surface (brushed, turned, ruled), whose light is the mean of its two flanks'
//                  and so smears across the grooves. Where a pixel can hold them the ruled lines themselves are
//                  drawn, each flank its own light; where it cannot, what is left is the sheen.
//   the shadow     the silhouette's, cast on the popup's surface
//
// THE EDGE. A shape whose edge lies on a pixel boundary must cover the pixel inside wholly and the one outside not at
// all, or a body at rest has a soft rim and the display's edge shows the surface under it. So the ray walks the
// surface drawn HALF A PIXEL INSIDE the body: a ray that reaches it is covered; one that passes within a pixel of it
// is covered by what is left of that pixel (1 - nearest / px) and shaded at its nearest point. That is a box filter's
// coverage, with one walk.
//
// GLSL 1.20 runs this too (an offscreen context): no bit operations, no integer %, no textureLod, no arrays.
// =============================================================================

// QSB-NO-100ES: the body has a vertex shader of its own (bridge_body.vert), so on an OpenGL ES context the pair links at
// GLSL ES 3.00; an ES 1.00 variant could only be reached by dropping that vertex shader, and would then draw nothing
// (its uniform struct is named by a SPIR-V id Qt cannot match). Without the variant that mistake is "No shader found".

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// The uniform block, the SAME in both stages (a ShaderEffect's two stages share one buffer: a member in one and not the
// other shifts every later one, with no error; tools/dev/shader_ubo_match.py holds them to it). BodyLayer.qml names each.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 view;      // stage width, height (px), device px per stage px, the camera's distance (px)
    vec4 bodyA;     // centre x, y (stage px), half width, half height
    vec4 bodyB;     // half thickness, the outline's corner radius, the rounded edge's radius, how far a key stands proud
    vec4 dispA;     // the display's half width, half height, corner radius; the body's lift towards the viewer
    vec4 backA;     // the frame's rim round each glass (px), how wide the seam between rim and glass is (px), px per mm, how deep the decor's deepest lies (mm)
    vec4 backB;     // the fan's centre as the back is seen (px from the centre), the earpiece slit's half width and height (px)
    vec4 patA;      // the back's ringed window as the back is seen: centre x, y, half width, half height (px from the centre)
    vec4 patB;      // its corner radius, the rings' pitch, the plate's seam x, the plate's head y (px)
    vec4 patC;      // the plate's lines' pitch (px), how strongly the ruled lines show, how far a groove tips the light, how wide the lenses' collars are (px; 0: none)
    vec4 patD;      // the two main lenses as the back is seen: x, the first's y, the second's y, their radius (px from the centre)
    vec4 frameA;    // the frame's atlas: the end walls' share of its width, a strip's share of its height, a row's step, half a texel of its height
    vec4 axX;       // the body's own axes in the stage's space (x right, y down, z to the viewer)
    vec4 axY;
    vec4 axZ;
    vec4 keyA;      // what stands proud of the frame: y0, y1 (px from the centre), side (+1 right, -1 left), kind + its half extent across the frame in mm / 10 (1 a bar, 4 the slider, 5 a pill, 6 round)
    vec4 keyB;
    vec4 keyC;
    vec4 keyD;
    vec4 pressA;    // how far keys A..D are pressed, 0..1
    vec4 lightA;    // the key light: the direction TO it (xyz), its strength
    vec4 lightB;    // the fill light
    vec4 stripA;    // the strip light the glass mirrors: its middle (a direction), its strength
    vec4 stripB;    // its long axis, its half length (as a sine)
    vec4 skyC;      // what a reflection sees above (rgb) and how much of the room it takes (a)
    vec4 groundC;   // ... below (rgb); how soft the horizon is (a)
    vec4 shadowA;   // the cast shadow: colour, strength
    vec4 shadowB;   // where the body's middle throws its shadow at rest: x, y (px); its softness (px); how high that middle stands over the surface at rest (px)
    vec4 frameC;    // the frame's metal (rgb), its roughness
    vec4 backC;     // the back's ground (rgb) where no decor is drawn; how bright the two side lights are
    vec4 bezelC;    // the glass border round the display (rgb), the glass's reflectivity
    vec4 accentC;   // spare (0); the field's stripes' pitch (px); how much of a ring's inward step its corner radius gives up (1: plain offsets); the busy light, 0..1
    vec4 tune;      // the display's glare, the strip's sharpness, how much of the room the frame's metal mirrors, the decor's presence (0 = none drawn)
    vec4 filmA;     // the film printed under the glass: how high it stands over the plate (px), how dark its shadow on the plate is, how much longer the shadow runs in a ruled line's valley
    vec4 platA;     // what stands proud of the back, in the body's space: the plateau's centre x, y, half width, half height (px; 0: a flat back)
    vec4 platB;     // its corner radius, its height, its top edge's radius, how much further each lens stands (px)
    vec4 ringA;     // a lens: x, y, radius, its top edge's radius (px; radius 0: none)
    vec4 ringB;
    vec4 ringC;
};

// What lies under the back glass (tools/bridge/make_decor.py), all opaque: the colour; the normal (rg) and the depth
// (b); the grooves' direction as a double angle times their strength (rg) and where the fine lines are ruled (b); the
// roughness (r), what lights up (g) and metal or not (b). And the frame's four walls: the colour; the normal (rg) and
// the roughness (b).
layout(binding = 1) uniform sampler2D decorAlbedo;
layout(binding = 2) uniform sampler2D decorRelief;
layout(binding = 3) uniform sampler2D decorGrain;
layout(binding = 4) uniform sampler2D decorSurface;
layout(binding = 5) uniform sampler2D frameAlbedo;
layout(binding = 6) uniform sampler2D frameRelief;
// Where the printed film lies (r): the line art, the wordmark, the pill, the mark. It stands a little over the plate
// and casts a shadow on it. And where the back is BARE (g): no glass lies over the decor there.
layout(binding = 7) uniform sampler2D decorFilm;

const float PI = 3.14159265;

// ---- distances ---------------------------------------------------------------------------------------------------

float sdRound(vec2 p, vec2 b, float r) {
    vec2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// How far one key stands out at a point of its side wall, 0..1: its footprint along the frame (y) and across it (z),
// softened by `e`. A bar has square ends, a pill and the slider round ones, the round key is a disc.
float keyBump(vec3 q, vec4 k, float e) {
    float kind = floor(k.w + 0.001);
    if (kind < 0.5)
        return 0.0;
    float hz = fract(k.w) * 10.0 * backA.z;
    float hl = 0.5 * (k.y - k.x);
    vec2 p = vec2(q.y - 0.5 * (k.x + k.y), q.z);
    float d;
    if (kind < 1.5) {
        vec2 w = abs(p) - vec2(hl, hz);
        d = max(w.x, w.y);
    } else if (kind > 5.5) {
        d = length(p) - hl;
    } else {
        d = sdRound(p, vec2(hl, hz), min(hl, hz));
    }
    float proud = (kind > 3.5 && kind < 4.5) ? 0.6 : 1.0;
    return (1.0 - smoothstep(-e, e, d)) * proud * step(0.0, q.x * k.z);
}

// How far the frame stands out here: the keys, less what each is pressed.
float keysProud(vec3 q, float e) {
    float b = keyBump(q, keyA, e) * (1.0 - 0.85 * pressA.x);
    b += keyBump(q, keyB, e) * (1.0 - 0.85 * pressA.y);
    b += keyBump(q, keyC, e) * (1.0 - 0.85 * pressA.z);
    b += keyBump(q, keyD, e) * (1.0 - 0.85 * pressA.w);
    return b * bodyB.w;
}

// A lens standing on the plateau: a cylinder up to `top` behind the back's plane, its top edge rounded.
float sdRing(vec2 p, float down, vec4 ring, float top) {
    if (ring.z <= 0.0)
        return 1.0e6;
    vec2 w = vec2(length(p - ring.xy) - ring.z, down - top) + ring.w;
    return length(max(w, 0.0)) + min(max(w.x, w.y), 0.0) - ring.w;
}

// The body: the outline extruded, the edge between each face and the frame rounded. Unit gradient where it is walked.
float sdBody(vec3 q) {
    float proud = 0.0;
    if (abs(q.x) > bodyA.z - 4.0)
        proud = keysProud(q, 0.7);
    vec2 w = vec2(sdRound(q.xy, bodyA.zw, bodyB.y) - proud, abs(q.z) - bodyB.x) + bodyB.z;
    float body = length(max(w, 0.0)) + min(max(w.x, w.y), 0.0) - bodyB.z;
    // what stands proud of the back: a plateau (a rounded slab, its top edge rounded), and the lenses on it
    if (platB.y > 0.0 && q.z < 0.0) {
        float down = -bodyB.x - q.z;                        // how far behind the back's plane
        vec2 pw = vec2(sdRound(q.xy - platA.xy, platA.zw, platB.x), down - platB.y) + platB.z;
        body = min(body, length(max(pw, 0.0)) + min(max(pw.x, pw.y), 0.0) - platB.z);
        float top = platB.y + platB.w;
        body = min(body, sdRing(q.xy, down, ringA, top));
        body = min(body, sdRing(q.xy, down, ringB, top));
        body = min(body, sdRing(q.xy, down, ringC, top));
    }
    return body;
}

vec3 bodyNormal(vec3 q, float h) {
    vec2 k = vec2(1.0, -1.0);
    return normalize(k.xyy * sdBody(q + k.xyy * h) + k.yyx * sdBody(q + k.yyx * h)
                   + k.yxy * sdBody(q + k.yxy * h) + k.xxx * sdBody(q + k.xxx * h));
}

// ---- light -------------------------------------------------------------------------------------------------------

vec3 toWorld(vec3 v) {
    return axX.xyz * v.x + axY.xyz * v.y + axZ.xyz * v.z;
}

// Two tall soft lights, one to each side of the viewer and out of every mirror's sight while the phone rests: a face
// turning past one catches it as a band that runs across the face -- as it leaves its rest, and as it comes home.
float sideLight(vec3 r, float blur) {
    float wide = clamp(blur * 2.5, 0.0, 1.0);
    float toSide = dot(normalize(vec2(abs(r.x), r.z) + 1.0e-5), vec2(0.5299, 0.8480));
    return pow(max(toSide, 0.0), mix(420.0, 8.0, wide)) * (1.0 - smoothstep(0.45, 0.85, abs(r.y))) * backC.a * mix(1.0, 0.10, wide);
}

// What a mirror sees in direction `r` (the stage's space: y DOWN): the popup's surface above, its shadow below, one
// long soft light across the top, the key lamp's own broad glow and the two side lights. `blur` widens everything for
// a rough surface.
vec3 room(vec3 r, float blur) {
    float up = -r.y;
    float soft = max(groundC.a, 0.02) + blur;
    vec3 c = mix(groundC.rgb, skyC.rgb, smoothstep(-soft, soft, up + 0.15 * r.z)) * skyC.a;
    // the viewer's own side of the room is the dimmer one, darkest a little below the eye: a mirror turned straight at
    // it is darker than one that leans to the light, and a flat mirror runs from light at its head to dark at its foot
    // -- which is what tells polished metal from paint
    float keen = 1.0 - clamp(blur * 2.2, 0.0, 1.0);
    c *= 1.0 - 0.62 * smoothstep(0.76, 1.0, dot(r, vec3(0.10, 0.34, 0.935))) * keen;
    vec3 mid = normalize(stripA.xyz);
    vec3 axis = normalize(stripB.xyz);
    vec3 nearest = normalize(mid + axis * clamp(dot(r, axis), -stripB.w, stripB.w));
    float sharp = mix(tune.y, 6.0, clamp(blur * 2.5, 0.0, 1.0));
    c += vec3(pow(max(dot(r, nearest), 0.0), sharp)) * stripA.w * (1.0 - 0.55 * clamp(blur * 2.0, 0.0, 1.0));
    c += vec3(pow(max(dot(r, normalize(lightA.xyz)), 0.0), 5.0)) * lightA.w * mix(0.16, 0.40, keen);
    c += vec3(sideLight(r, blur));
    return c;
}

float ggx(float nh, float a) {
    float a2 = a * a;
    float d = nh * nh * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

// The two lamps' highlight on a surface of roughness `a`, seen from `v` (all in the stage's space).
float lamps(vec3 n, vec3 v, float a) {
    vec3 l0 = normalize(lightA.xyz);
    vec3 l1 = normalize(lightB.xyz);
    float s0 = ggx(max(dot(n, normalize(l0 + v)), 0.0), a) * max(dot(n, l0), 0.0) * lightA.w;
    float s1 = ggx(max(dot(n, normalize(l1 + v)), 0.0), a) * max(dot(n, l1), 0.0) * lightB.w;
    return (s0 + s1) * 0.25;
}

float lambert(vec3 n) {
    return max(dot(n, normalize(lightA.xyz)), 0.0) * lightA.w + max(dot(n, normalize(lightB.xyz)), 0.0) * lightB.w;
}

float fresnel(float nv, float f0) {
    return f0 + (1.0 - f0) * pow(1.0 - clamp(nv, 0.0, 1.0), 5.0);
}

// A bright light must not clip to a flat white patch: the last third of the range is eased in.
vec3 knee(vec3 c) {
    vec3 x = max(c, 0.0);
    return mix(x, 1.0 - 0.34 * exp(-(x - 0.66) / 0.34), step(0.66, x));
}

// ---- materials ---------------------------------------------------------------------------------------------------

// Glass over a dark ground: the border round the display. rgb only; it is opaque.
vec3 glassOver(vec3 base, vec3 n, vec3 v, vec3 r) {
    float f = fresnel(dot(n, v), 0.045) * bezelC.a;
    return base * (0.35 + 0.65 * lambert(n)) + room(r, 0.0) * f + vec3(lamps(n, v, 0.06)) * f * 6.0;
}

// The frame's metal, in the open air.
vec3 metal(vec3 tint, float rough, vec3 n, vec3 v, vec3 r) {
    float f = fresnel(dot(n, v), 0.0);
    // not a perfect mirror: satin metal keeps some of its own brightness whatever room it stands in (a silver frame
    // in a dark popup is still silver)
    vec3 mirror = room(r, rough) * mix(tint, vec3(1.0), f * 0.6);
    return mirror * tune.z + tint * (0.21 + 0.27 * lambert(n)) + tint * lamps(n, v, max(rough, 0.05)) * 1.6;
}

// What lies under the back glass, lit: `c` its colour, `m` how much of it is metal.
vec3 under(vec3 c, vec3 n, vec3 v, vec3 rw, float rough, float m) {
    vec3 r = reflect(rw, n);
    float f = fresnel(dot(n, v), 0.0);
    float top = max(c.r, max(c.g, c.b));
    // black gloss (lens glass, the fan's housing): a coated mirror, tinted by what little colour it has
    float coat = (1.0 - m) * (1.0 - smoothstep(0.03, 0.12, top)) * (1.0 - smoothstep(0.06, 0.20, rough));
    vec3 f0 = mix(vec3(0.045 + 0.075 * coat), c, m);
    vec3 spec = room(r, rough) * mix(f0, vec3(1.0), f * 0.7)
              + mix(f0, vec3(1.0), 0.30) * lamps(n, v, max(rough, 0.05)) * mix(1.5, 2.2, coat);
    spec *= mix(vec3(1.0), 0.45 + 1.1 * c / max(top, 0.004), coat * 0.8);
    vec3 diff = c * (0.52 + 0.48 * lambert(n)) * (1.0 - 0.80 * m);
    return diff + spec;
}

// The ringed window at `p` (px from its centre): x how deep the point lies inside it (positive inwards), yz which way
// is OUT from there (unit). The rings are the window's outline stepped inwards, but a ring's corner gives up only a
// share `accentC.z` of each step (a plain offset gives up all of it, and its corners turn sharp a few rings in; the
// phone's stay round to the middle): ring d is the box drawn in by d with the corner radius r0 - k d.
vec3 ringAt(vec2 p) {
    float r0 = patB.x;
    float k = accentC.z;
    float m = 1.0 - k;
    vec2 a = abs(p) - patA.zw + r0;
    vec2 sg = vec2(p.x < 0.0 ? -1.0 : 1.0, p.y < 0.0 ? -1.0 : 1.0);
    float ds = r0 - max(a.x, a.y);
    vec2 an = a + m * ds;
    if (an.x > 0.0 && an.y > 0.0) {
        float qa = 2.0 * m * m - k * k;
        float qb = 2.0 * m * (a.x + a.y) + 2.0 * r0 * k;
        float qc = dot(a, a) - r0 * r0;
        float d = (-qb + sqrt(max(qb * qb - 4.0 * qa * qc, 0.0))) / (2.0 * qa);
        return vec3(d, normalize(max(a + m * d, 1.0e-4)) * sg);
    }
    return vec3(ds, a.x > a.y ? vec2(sg.x, 0.0) : vec2(0.0, sg.y));
}

// One family of ruled lines as a wave across them, -1..1: with `turn` 0 the surface's height (a ridge, then a valley),
// with a quarter turn its slope (one flank, then the other). Squared off where a pixel can hold the two apart.
float ruled(float phase, float pitch, float px, float turn) {
    return clamp(sin((phase / pitch + turn) * 2.0 * PI) * max(0.32 * pitch / px, 1.0), -1.0, 1.0);
}

vec3 hue(float h) {
    return clamp(abs(fract(h + vec3(0.0, 0.6667, 0.3333)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

// ---- the faces ---------------------------------------------------------------------------------------------------

// The back, under its glass. `q` the point on the glass (body space), `d` the ray there, `nw` the glass's own normal;
// `px` how wide a device pixel is on the glass (stage px).
vec3 backFace(vec3 q, vec3 d, vec3 rw, vec3 nw, vec3 vw, vec3 rfl, float px) {
    vec2 bq = vec2(-q.x, q.y);                              // as the back is seen: x to the right
    vec2 size = 2.0 * bodyA.zw;
    vec2 uv = bq / size + 0.5;
    // the eye's direction as the back is seen, and the ray's run under the glass per unit of depth; the depth is read
    // twice (where the ray enters, and where that first guess lands), so a deep thing's edge does not shear
    vec3 eb = vec3(d.x, -d.y, d.z);
    vec2 run = -eb.xy / max(eb.z, 0.28) * 0.66 * backA.w * backA.z / size;
    float deep = texture(decorRelief, uv).b;
    deep = 0.5 * (deep + texture(decorRelief, uv + run * deep).b);
    uv += run * deep;
    bq = (uv - 0.5) * size;
    vec3 c = texture(decorAlbedo, uv).rgb;
    vec4 rel = texture(decorRelief, uv);
    vec4 grn = texture(decorGrain, uv);
    vec4 srf = texture(decorSurface, uv);
    vec4 flm = texture(decorFilm, uv);
    float rough = clamp(srf.r, 0.03, 1.0);
    float glows = srf.g;
    vec2 nxy = rel.rg * 2.0 - 1.0;
    float nz = sqrt(max(1.0 - dot(nxy, nxy), 0.04));

    // the ruled lines: the plate's (turning at its seam), the window's rings, the field's stripes. Each is a wave
    // across the lines: `wave` its height (the valley is the dark line), `slope` which of its two flanks a point lies
    // on; `up` is the way the wave runs. What a pixel cannot hold is drawn COARSER, not left out (lines are what these
    // surfaces are): every other line, then every fourth, each passing into the next as the pixel grows; past that
    // only the two flanks' mean is left, the sheen (`show`). The texture says how strongly a surface's lines show.
    float pitch = max(patC.x, 1.0e-3);
    vec2 up = vec2(bq.x < patB.z ? -0.70710678 : 0.70710678, -0.70710678);
    float phase = (abs(bq.x - patB.z) - bq.y) * 0.70710678;
    if (bq.y < patB.w) {
        vec2 wp = bq - patA.xy;
        if (sdRound(wp, patA.zw, patB.x) < 0.0) {
            vec3 rg = ringAt(wp);
            pitch = max(patB.y, 1.0e-3);
            phase = -rg.x;
            up = rg.yz;
        } else {
            pitch = max(accentC.y, 1.0e-3);
            phase = (bq.x - bq.y) * 0.70710678;
            up = vec2(0.70710678, -0.70710678);
        }
    }
    float coarse = max(log2(2.3 * max(px, 1.0e-3) / pitch), 0.0);
    float octave = min(floor(coarse), 2.0);
    float p0 = pitch * exp2(octave);
    float next = smoothstep(0.5, 1.0, coarse - octave) * step(octave, 1.5);
    float wave = mix(ruled(phase, p0, px, 0.0), ruled(phase, 2.0 * p0, px, 0.0), next);
    float slope = mix(ruled(phase, p0, px, 0.25), ruled(phase, 2.0 * p0, px, 0.25), next);
    float show = clamp(grn.b * 4.0, 0.0, 1.0) * (1.0 - smoothstep(2.3, 3.0, coarse));
    c *= 1.0 + 2.0 * patC.y * grn.b * wave * show;

    // the printed film's shadow on the plate under it: the film stands a little over the plate, so the light the
    // pointer leads (the strip) throws its outline onto the plate, away from the light -- and further in a ruled
    // line's valley, which lies lower (where a pixel cannot hold the lines: by their mean). One more read of the
    // film's mask, towards the light; what is itself under film is not shaded twice.
    if (filmA.y > 0.0) {
        vec3 ls = normalize(stripA.xyz);
        vec3 lb = vec3(dot(ls, axX.xyz), dot(ls, axY.xyz), dot(ls, axZ.xyz));
        float valley = mix(0.5, 0.5 - 0.5 * wave, show);
        vec2 thrown = vec2(-lb.x, lb.y) / max(-lb.z, 0.35) * filmA.x * (1.0 + filmA.z * valley) / size;
        float there = texture(decorFilm, uv + thrown).r;
        c *= 1.0 - filmA.y * there * (1.0 - flm.r) * step(0.0, -lb.z);
    }

    // the grooves: which way they run (a double angle: a direction has no "which side"), and so which way their two
    // flanks lean. Flank A is the one that leans the way the ruled wave runs (`up`), so a ring's two halves, or the
    // two sides of the plate's seam, are each other's mirror and never each other's negative.
    vec2 av = grn.rg * 2.0 - 1.0;
    float al = length(av);
    float strength = min(al, 1.0) * step(0.03, al);
    vec2 dn = al > 0.03 ? av / al : vec2(1.0, 0.0);
    float ct = sqrt(max(0.5 * (1.0 + dn.x), 0.0));
    float st = sqrt(max(0.5 * (1.0 - dn.x), 0.0)) * (dn.y < 0.0 ? -1.0 : 1.0);
    vec2 lean = vec2(-st, ct) * (dot(vec2(-st, ct), up) < 0.0 ? -1.0 : 1.0) * patC.z * strength;

    // a main lens's collar (the bright ring that joins its box to the glass) lies under the glass's black print: seen
    // from straight above the print covers it; the eye finds it only by looking in under the print from the side, and
    // then on the side nearer the eye. How much of it shows is the collar's depth times the slant of the sight line.
    float metalness = srf.b;
    if (patC.w > 0.0) {
        vec2 l0 = bq - vec2(patD.x, patD.y);
        vec2 l1 = bq - vec2(patD.x, patD.z);
        vec2 ld = dot(l0, l0) < dot(l1, l1) ? l0 : l1;
        float lr = max(length(ld), 1.0e-3);
        float band = clamp((lr - patD.w) / px + 0.5, 0.0, 1.0) * clamp((patD.w + patC.w - lr) / px + 0.5, 0.0, 1.0);
        vec2 slant = -eb.xy / max(eb.z, 0.28) * 0.66;
        float seen = clamp((dot(-ld / lr, slant) * 0.9 * backA.z - 0.12 * backA.z) / patC.w, 0.0, 1.0);
        float veil = band * (1.0 - seen);
        c = mix(c, vec3(0.016, 0.017, 0.020), veil);
        rough = mix(rough, 0.08, veil);
        metalness *= 1.0 - veil;
    }

    vec3 na = toWorld(normalize(vec3(-(nxy.x + lean.x), nxy.y + lean.y, -nz)));
    vec3 nb = toWorld(normalize(vec3(-(nxy.x - lean.x), nxy.y - lean.y, -nz)));
    vec3 la = under(c, na, vw, rw, rough, metalness);
    vec3 lb = under(c, nb, vw, rw, rough, metalness);
    // (where the wave climbs the way it runs, the surface faces back down it: flank B)
    vec3 lit = mix(0.5 * (la + lb), mix(la, lb, 0.5 + 0.5 * slope), show);

    // what lights up while the phone is busy: the fan's ring round its hues, the emblem and the mark in one
    vec2 fromFan = bq - backB.xy;
    vec3 glow = hue(atan(fromFan.y, fromFan.x) / (2.0 * PI) + 0.62) * glows;
    lit = mix(lit, lit * 0.35 + glow * 1.15, glows * accentC.a);

    // the glass itself, over all of it
    // (not where the texture says the surface is BARE: a metal shell has no glass over it)
    float fg = fresnel(dot(nw, vw), 0.05) * bezelC.a * (1.0 - flm.g);
    return lit * (1.0 - 0.5 * fg) + room(rfl, 0.0) * fg + vec3(lamps(nw, vw, 0.06)) * fg * 6.0;
}

// A wall of the frame, the rounded edge it turns into a face by, and the rim round each glass: the frame's texture,
// read by where the ray met it (on a face: the wall's edge row, so the antenna's lines run on to the glass). `px` how
// wide a device pixel is there (stage px).
vec3 wallAt(vec3 q, vec3 n, vec3 rw, vec3 vw, float px) {
    float ends = step(bodyA.w - abs(q.y), bodyA.z - abs(q.x));      // 1: the top or the bottom wall is the nearer
    float along = mix(q.y / (2.0 * bodyA.w), q.x / (2.0 * bodyA.z), ends) + 0.5;
    float row = mix(q.x > 0.0 ? 0.0 : 1.0, q.y < 0.0 ? 2.0 : 3.0, ends);
    float across = clamp(0.5 - q.z / (2.0 * bodyB.x), 0.0, 1.0);
    vec2 uv = vec2(along * mix(1.0, frameA.x, ends), row * frameA.z + frameA.w + across * (frameA.y - 2.0 * frameA.w));
    vec3 tint = texture(frameAlbedo, uv).rgb;
    vec3 fr = texture(frameRelief, uv).rgb;
    vec2 nt = fr.rg * 2.0 - 1.0;
    vec3 tangent = mix(vec3(0.0, 1.0, 0.0), vec3(1.0, 0.0, 0.0), ends);
    vec3 nn = normalize(n + tangent * nt.x - vec3(0.0, 0.0, 1.0) * nt.y);
    float rough = clamp(fr.b, 0.04, 1.0);

    // the round key's ring of turned ridges (sixteen of them): each ridge is two flanks leaning along the radius. Where
    // a pixel can hold them they are drawn (every other one, and every fourth, where it cannot hold them all); what is
    // left unseen is their sheen, a pair of spokes that follow the lamp.
    vec4 rk = floor(keyA.w + 0.001) > 5.5 ? keyA : (floor(keyB.w + 0.001) > 5.5 ? keyB : (floor(keyC.w + 0.001) > 5.5 ? keyC : keyD));
    if (floor(rk.w + 0.001) > 5.5 && ends < 0.5 && q.x * rk.z > 0.0) {
        vec2 kp = vec2(q.y - 0.5 * (rk.x + rk.y), q.z);
        float hl = 0.5 * (rk.y - rk.x);
        float kr = length(kp);
        float ring = clamp((kr - 0.42 * hl) / px + 0.5, 0.0, 1.0) * clamp((0.86 * hl - kr) / px + 0.5, 0.0, 1.0);
        if (ring > 0.0) {
            float pitch = 0.44 * hl / 16.0;
            pitch *= exp2(clamp(ceil(log2(2.2 * px / pitch)), 0.0, 2.0));
            float held = pitch / max(px, 1.0e-3);
            float show = ring * clamp((held - 1.3) / 1.2, 0.0, 1.0);
            float wave = clamp(sin((kr - 0.42 * hl) / pitch * 2.0 * PI) * max(0.32 * held, 1.0), -1.0, 1.0);
            vec3 lean = vec3(0.0, kp.x, kp.y) / max(kr, 1.0e-3) * 0.34;
            vec3 na = toWorld(normalize(nn + lean));
            vec3 nb = toWorld(normalize(nn - lean));
            vec3 la = metal(tint, rough, na, vw, reflect(rw, na));
            vec3 lb = metal(tint, rough, nb, vw, reflect(rw, nb));
            vec3 flat0 = metal(tint, rough, toWorld(nn), vw, reflect(rw, toWorld(nn)));
            return mix(flat0, mix(0.5 * (la + lb), mix(lb, la, 0.5 + 0.5 * wave), show), ring);
        }
    }
    vec3 nw = toWorld(nn);
    return metal(tint, rough, nw, vw, reflect(rw, nw));
}

// ---- the cast shadow ---------------------------------------------------------------------------------------------

// THE SHADOW IS THE BODY'S OWN SILHOUETTE AS THE LIGHT THROWS IT, IN EVERY POSE. The light comes from the viewer's side,
// a little above: a point `h` px over the surface throws its shadow `h * k` px down (k: the rest offset over the rest
// height, so the middle's shadow lies where `shadowB.xy` says at rest), and the body's middle stands `shadowB.w + lift`
// over it (lifted, the shadow falls further away, softer and fainter). The slab is a box, a disk (the outline's corners)
// and a ball (the rounded edge) added together, so the thrown shape is convex and its SUPPORT h(n) is exact in every
// direction: the sum of each part's; its signed distance is the largest `p.n - h(n)` over the directions n (the shape is
// symmetric: |p.n|), found by a coarse pass and a refinement (below) -- a box's corners, a turned phone's slanted outline, a
// phone seen edge-on, all alike. (An
// upright rounded box of the pose's extents, what it was, stood out round a turned and tilted phone like a card behind it.)
// one direction's bound: |q.n| less the thrown body's support in n (the box, the outline's corners' disk, the edge's ball)
float shadowTry(vec2 q, vec2 n, vec2 gx, vec2 gy, vec2 gz, vec3 e, float disk, float re) {
    vec3 a = vec3(dot(gx, n), dot(gy, n), dot(gz, n));
    return abs(dot(q, n)) - (dot(e, abs(a)) + disk * length(a.xy) + re * length(a));
}

float shadowDist(vec2 p) {
    vec2 k = shadowB.xy / max(shadowB.w, 1.0);
    float hc = shadowB.w + dispA.w;
    vec2 q = p - bodyA.xy - k * hc;
    // the body's axes thrown onto the surface
    vec2 gx = axX.xy + k * axX.z;
    vec2 gy = axY.xy + k * axY.z;
    vec2 gz = axZ.xy + k * axZ.z;
    float rc = min(bodyB.y, min(bodyA.z, bodyA.w));
    float re = min(bodyB.z, min(rc, bodyB.x));
    vec3 e = vec3(bodyA.z - rc, bodyA.w - rc, bodyB.x - re);
    float disk = rc - re;
    // the coarse pass: the best of twelve directions over a half turn
    float best = -1.0e6;
    float ang = 0.0;
    for (int i = 0; i < 12; i++) {
        float t = float(i) * (PI / 12.0);
        float v = shadowTry(q, vec2(cos(t), sin(t)), gx, gy, gz, e, disk, re);
        if (v > best) {
            best = v;
            ang = t;
        }
    }
    // THE REFINEMENT: the best direction is then walked to the true one, the step halved each round (7.5 degrees down to under a
    // tenth). Twelve fixed directions alone drew a slanted edge whose normal fell between two of them as a bent pair of facets, and
    // as the phone turned the shape jumped from facet to facet (the user, 2026-11-21: "some sort of stepping").
    float step = PI / 24.0;
    for (int k = 0; k < 7; k++) {
        float va = shadowTry(q, vec2(cos(ang - step), sin(ang - step)), gx, gy, gz, e, disk, re);
        float vb = shadowTry(q, vec2(cos(ang + step), sin(ang + step)), gx, gy, gz, e, disk, re);
        if (va > best && va >= vb) {
            best = va;
            ang -= step;
        } else if (vb > best) {
            best = vb;
            ang += step;
        }
        step *= 0.5;
    }
    return best;
}

// ---- main --------------------------------------------------------------------------------------------------------

void main() {
    vec2 p = qt_TexCoord0 * view.xy;
    float px = 1.0 / max(view.z, 0.25);            // one device pixel, in stage px
    float D = view.w;

    // the shadow on the surface, under everything
    float sd = shadowDist(p);
    float grow = (shadowB.w + dispA.w) / max(shadowB.w, 1.0);
    float soft = shadowB.z * grow;
    float sa = shadowA.a / grow * (1.0 - smoothstep(-0.35 * soft, soft, sd));
    vec4 under0 = vec4(shadowA.rgb * sa, sa);

    // the ray, in body space
    vec3 cam = vec3(bodyA.xy, D);
    vec3 centre = vec3(bodyA.xy, dispA.w - bodyB.x);
    vec3 rw = normalize(vec3(p, 0.0) - cam);
    vec3 oc = cam - centre;
    vec3 o = vec3(dot(oc, axX.xyz), dot(oc, axY.xyz), dot(oc, axZ.xyz));
    vec3 d = vec3(dot(rw, axX.xyz), dot(rw, axY.xyz), dot(rw, axZ.xyz));
    d += vec3(1.0e-6) * (1.0 - step(1.0e-6, abs(d)));

    // its stretch through the body's box
    vec3 box = vec3(bodyA.z, bodyA.w, bodyB.x + platB.y + platB.w) + vec3(bodyB.w + 2.0 * px);
    vec3 t0 = (-box - o) / d;
    vec3 t1 = (box - o) / d;
    vec3 tlo = min(t0, t1);
    vec3 thi = max(t0, t1);
    float tn = max(max(tlo.x, tlo.y), tlo.z);
    float tf = min(min(thi.x, thi.y), thi.z);
    if (tn > tf) {
        fragColor = under0 * qt_Opacity;
        return;
    }

    // the walk, along the surface half a pixel inside the body
    float tt = tn;
    float nearest = 1.0e6;
    vec3 q = o + d * tt;
    vec3 qn = q;
    float cover = 0.0;
    for (int i = 0; i < 44; i++) {
        float ds = sdBody(q) + 0.5 * px;
        if (ds < nearest) {
            nearest = ds;
            qn = q;
        }
        if (ds < 0.02 * px) {
            cover = 1.0;
            break;
        }
        tt += max(ds, 0.25 * px);
        if (tt > tf)
            break;
        q = o + d * tt;
    }
    if (cover < 0.5)
        cover = clamp(1.0 - nearest / px, 0.0, 1.0);
    if (cover <= 0.0) {
        fragColor = under0 * qt_Opacity;
        return;
    }
    q = qn;

    vec3 n = bodyNormal(q, 0.5 * px);
    vec3 nw = toWorld(n);
    vec3 vw = -rw;
    vec3 rfl = reflect(rw, nw);
    float grazing = max(abs(dot(n, d)), 0.12);

    vec4 col;
    if (abs(n.z) > 0.92) {
        // a face. The walk stopped half a pixel inside it; what is drawn ON the face (the display's outline, the
        // decor) is read where the ray meets the face itself, or everything on it sits a fraction of a pixel off
        // towards the picture's edges (the camera is a pinhole), and the display's straight edges are no longer
        // whole pixels.
        float plane = sign(n.z) * bodyB.x;
        if (platB.y > 0.0 && n.z < 0.0) {
            // the back of a body with a plateau has three levels: the back itself, the plateau's top, a lens's top
            float down = -bodyB.x - q.z;
            plane -= down > platB.y + 0.5 * platB.w ? platB.y + platB.w : (down > 0.5 * platB.y ? platB.y : 0.0);
        }
        q = o + d * ((plane - o.z) / d.z);
        // glass inside the frame's rim, and the dark seam the glass sits in
        float rimD = sdRound(q.xy, bodyA.zw - backA.x, max(bodyB.y - backA.x, 0.0));
        float glass = clamp(0.5 - rimD * grazing / px, 0.0, 1.0);
        float foot = px / grazing;
        float seam = clamp(1.0 - abs(rimD) / max(backA.y, foot), 0.0, 1.0) * min(backA.y / foot, 1.0);
        vec3 rim = knee(wallAt(q, n, rw, vw, foot));
        if (n.z > 0.0) {
            // the front: the border, and the hole the QML face shows through
            float dd = sdRound(q.xy, dispA.xy, dispA.z);
            float hole = clamp(0.5 - dd * grazing / px, 0.0, 1.0);
            vec3 border = knee(glassOver(bezelC.rgb, nw, vw, rfl));
            // the earpiece: a slit under the glass's top edge
            vec2 sl = abs(vec2(q.x, q.y + bodyA.w - backA.x - 0.5 * backB.w - backA.y)) - vec2(backB.z, 0.5 * backB.w);
            float slit = clamp(0.5 - max(sl.x, sl.y) / foot, 0.0, 1.0) * min(backB.w / foot, 1.0);
            border *= 1.0 - 0.9 * slit;
            float f = fresnel(dot(nw, vw), 0.045) * bezelC.a * tune.x;
            // (a side light's band shows on the display too: the glass is the same glass)
            vec3 glare = (room(rfl, 0.0) * 0.55 + vec3(lamps(nw, vw, 0.06)) * 6.0 + vec3(sideLight(rfl, 0.0)) * 1.2) * f;
            vec4 open = vec4(min(glare, vec3(1.0)), clamp(f * 0.6, 0.0, 1.0));
            // seen nearly edge-on, glass is a mirror: the display closes to what it reflects (and a face that is a
            // sliver a pixel or two wide need not sit on its glass to the pixel)
            float edgeOn = 1.0 - smoothstep(0.05, 0.20, abs(d.z));
            open = mix(open, vec4(knee(room(rfl, 0.0) * 0.9 + vec3(lamps(nw, vw, 0.06)) * 3.0), 1.0), edgeOn);
            vec4 inside = mix(vec4(border, 1.0), open, hole);
            inside.rgb *= 1.0 - 0.8 * seam * (1.0 - hole);
            col = mix(vec4(rim * (1.0 - 0.8 * seam), 1.0), inside, glass);
        } else {
            vec3 back = tune.w > 0.5 ? backFace(q, d, rw, nw, vw, rfl, foot)
                                     : backC.rgb * (0.42 + 0.62 * lambert(nw)) + room(rfl, 0.0) * fresnel(dot(nw, vw), 0.05) * bezelC.a;
            col = vec4(mix(rim, knee(back), glass) * (1.0 - 0.8 * seam), 1.0);
        }
    } else if (platB.y > 0.0 && q.z < -bodyB.x - 0.5 * px) {
        // the plateau's own wall, or a lens's: the shell's metal, a little brighter than satin where it turns
        col = vec4(knee(metal(frameC.rgb, frameC.a, nw, vw, rfl)), 1.0);
    } else {
        col = vec4(knee(wallAt(q, n, rw, vw, px / grazing)), 1.0);
    }

    // `col` is premultiplied (opaque, or the hole's glare). The shadow lies on the surface AROUND the body: it shows
    // only in the part of an edge pixel the body leaves, never through the hole.
    fragColor = (col * cover + under0 * (1.0 - cover)) * qt_Opacity;
}
