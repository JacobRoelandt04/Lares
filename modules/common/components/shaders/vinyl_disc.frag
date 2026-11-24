#version 440

// =============================================================================
// vinyl_disc.frag
//
// A 12" record, ray-traced per pixel from one quad. No 3D engine, no meshes,
// no render-to-texture: a record is a disc, and a disc is two parallel planes
// and a cylinder, all three of which a fragment shader can intersect exactly.
//
// Why not QtQuick3D: the one thing the record needs that a PrincipledMaterial
// does not give is an ANISOTROPIC highlight whose tangent runs along the
// grooves -- i.e. azimuthally -- which is a custom BRDF either way. Doing it
// here instead buys a hole that is really a hole (with an inner wall visible
// when the record tilts), grooves that fade to their own roughness instead of
// aliasing, a silhouette resolved by re-tracing rather than by a rasteriser's
// coverage rules, and one draw call.
//
// Geometry, in DISC space (origin at the record's centre, +z out of the front
// face, r measured from the spindle):
//
//   r < holeR                       the spindle hole: the inner cylinder wall,
//                                   or nothing at all
//   holeR .. labelR                 the paper label -- album art, matte
//   labelR .. grooveInnerR          lead-out land: smooth, mirror-ish
//   grooveInnerR .. grooveOuterR    the modulated area: grooves
//   grooveOuterR .. 1               the outer land, smooth again
//
// The camera is a pinhole at (camCenter, camZ) in VIEW space looking down -z;
// the item's plane is z = 0, so anything at z = 0 is drawn 1:1 with its pixel
// size and the perspective only shows up when the record moves in z or tilts.
// `camCenter` is where that axis pierces the item -- the record's own centre,
// so a record placed off-centre in a big item still grows about itself rather
// than sliding toward the middle of the canvas.
//
// The record's orientation arrives as a basis (its own x, y and normal, in
// view space) rather than as angles, so the whole animation -- swivel, spin,
// the 1260-degree flip about a wandering axis -- stays in QML where it can be
// eased, and the shader never has to know which of those is happening.
//
// Shading is one dielectric layer over a dark body:
//
//   albedo      the vinyl colour, or the label texture inside labelR
//   spec        anisotropic GGX, tangent ALONG the groove (azimuthal), so the
//               highlight stretches RADIALLY and reads as the two opposed
//               arcs a record has under a lamp
//   env         a procedural sky/ground gradient sampled by the reflection,
//               which is what makes the black read as glossy rather than flat
//   fresnel     two of them, because there are two materials. Lacquer's is
//               Schlick with F0 = 0.05 and climbs to 1 at grazing, which is
//               the record's hard rim light; the label's is held down by the
//               paper's own roughness, so it takes the same room from the same
//               angles, only softer and dimmer. That difference is the whole
//               of what makes one read as vinyl and the other as printed card
//
// The diffuse term is normalised so a white albedo facing the key light reads
// white. With a ceiling of 0.55 the album art on the label would come back
// darker than the file (#ffffff arrives as #96979a) and no vinyl colour could
// be white however light it was set.
//
// Grooves perturb the normal by the derivative of a sine in r. The fine sine
// and the lands both stop being drawn at their own Nyquist limit -- half the
// pitch, not most of it -- because everything drawn past that limit is moire
// and nothing else, and the radial roughness is raised in its place, so a
// record that is far away or steeply tilted loses its rings but keeps its
// sheen instead of shimmering.
//
// Two things a disc traced from exact geometry gets wrong without help:
//
//   coverage    the outline, the spindle hole (two pixels across at popup
//               size) and the rim's own band are all sub-pixel, and a coverage
//               taken from the hit point's derivative is worthless at them --
//               half the pixels in a 2x2 quad missed the record entirely, so
//               the derivative reads whatever the miss left behind. The
//               boundary is resolved instead by tracing the same geometry at
//               `edgeSamples` extra positions inside the pixel and counting
//               hits, and only for the pixels a boundary is actually near.
//   corners     traced sharp, the rim and the hole's wall meet the faces at an
//               exact right angle, and under this lighting that seam is black:
//               the "void between the two sides" a flipping record would show. The
//               normal is rolled halfway toward the neighbour across the last
//               `edgeBevel` px, which is all the light needs to wrap a corner
//               without tracing a torus for two pixels of geometry.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    // ---- the item ----
    vec2  res;              // item size in px; the quad spans it exactly
    float camZ;             // eye distance in px. Large = flat, small = wide
    float edgeSamples;      // sub-samples spent on a boundary pixel; 0 = none
    // WHERE THE CAMERA'S AXIS PIERCES THE ITEM, in view-space px from the
    // item's own centre (+x right, +y up). The pinhole sits directly above
    // THIS point, not above the middle of the item.
    //
    // It matters because the item is the whole card and the record is a slot
    // in it. With the axis at the item's centre, a record placed off-centre is
    // seen OFF-AXIS: it slides toward the middle as it rises (the lift in mini
    // would drift left), and every surface of it reflects the room from a
    // rotated view direction, so the same pose grows a different sheen at 118 px
    // than at 503 px -- not because of the size, but because the small one sits
    // 157 px off an axis only 193 px away. Putting the axis on the record's own
    // centre -- the pin it turns on -- avoids both, and costs only that things
    // FAR from the pin (the sleeve leaving stage right) are seen more steeply,
    // which is what a camera over the turntable would really do.
    //
    // Anything at z = 0 is drawn at its own place whatever this is, so a
    // centred record renders the same as with the axis fixed at the item's
    // centre.
    vec2  camCenter;

    // WHICH PART OF THE ITEM THIS QUAD ACTUALLY IS: (x, y, w, h) in the item's
    // own pixels. The disc's item is the whole card, because the record's
    // shadow may only ever be cut by the container's own edge -- but the record
    // and its shadow together cover a fraction of that card: 64 % of it in
    // `player` and 15 % in `mini`, where a 92 px record sits in a 456x142 box.
    // Everything outside is a ray that provably misses both, so VinylDisc
    // sizes this quad to what can actually be painted and hands over where it
    // put it; the fragment's position in the ITEM is recovered here. Measured,
    // at 16 records a frame: tracing the whole card costs player 169 ms/s of
    // GPU and mini 25.4, against 120 and 18.1 for the sized quad.
    vec4  quad;

    // ---- where the record is ----
    // Columns 0,1,2 of `basis` are the record's own x, y and normal axes in
    // view space, unit length and orthogonal. Column 3 is unused. The spin
    // about the normal is baked in here, which is why the label rotates for
    // free and no separate angle is needed.
    mat4  basis;
    vec4  discPos;          // centre in view space (px), .w unused

    // ---- proportions (px) ----
    float radius;
    float thickness;
    float holeR;
    float labelR;
    float grooveInnerR;
    float grooveOuterR;

    // ---- grooves ----
    float groovePitch;      // px between rings at the item's own scale
    float grooveDepth;      // normal perturbation, 0..1-ish
    float grooveRough;      // radial roughness added where grooves live
    float trackCount;       // smooth lands between tracks: the visible rings
    float trackWidth;       // width of a land, as a fraction of its spacing

    // ---- material ----
    vec4  vinylColor;       // body albedo. Near-black by default, tintable
    vec4  labelTint;        // multiplies the label texture
    float roughAlong;       // GGX alpha along the groove (small = sharp arcs)
    float roughAcross;      // GGX alpha across it (large = radial smear)
    float labelRough;       // paper: isotropic and matte
    float labelReflect;     // the paper's own share of the room, so the label
                            // catches the same sheen the lacquer does
    float labelSpec;        // and the direct lights' own lobe on it. Small on
                            // purpose: paper's lobe is so broad that gain on
                            // it lands as a flat veil over the artwork rather
                            // than as a highlight. The label's sheen is
                            // labelReflect, above.
    float reflectivity;     // strength of the environment term
    float specStrength;     // strength of the two lights
    float specKnee;         // soft ceiling on the sheen: 1/specKnee is the most
                            // it can reach. Without it, the angle where every
                            // point of the record reflects the strip at once
                            // turns the whole disc into a white plate.
    float diffuseGain;      // per-light diffuse weight
    float ambientDiffuse;   // the light that reaches everything. Together with
                            // diffuseGain these are set so a white albedo,
                            // flat on under the default rig, reads 1.0.
    float paleSheen;        // how much a PALE body damps its own sheen. Zero
                            // below 0.30 luma, so the near-black default is
                            // untouched; a white record would otherwise clip
                            // its arcs flat and read as brushed aluminium.
    float highlightKnee;    // where the output starts to bend toward 1 instead
                            // of hitting it. 1.0 = a hard clip.
    float edgeBevel;        // px of shaded roll at the rim and the hole
    float edgeAmbient;      // irradiance floor on the cut edge
    float edgeLift;         // how far the cut edge is lifted toward white

    // ---- lights and environment, all in view space ----
    vec4  light0;           // xyz direction TOWARD the light, w intensity
    vec4  light1;
    vec4  lightColor0;
    vec4  lightColor1;
    vec4  skyColor;         // env above the horizon
    vec4  groundColor;      // env below it
    float envHorizon;       // softness of the horizon in the env gradient

    // The strip light: the thing that makes a record look like a record.
    // A directional lamp on circular grooves puts a straight RADIAL bar of
    // light across the disc; the two curved sheens a record actually shows
    // come from a long source -- a window, a strip light, a room. It is
    // shaded by the representative-point trick: for each pixel, the point of
    // the strip nearest the reflected direction is used as that pixel's light,
    // which bends the highlight into the arc.
    vec4  stripCenter;      // xyz unit direction to the strip's middle, w half-length
    vec4  stripAxis;        // xyz unit direction along the strip, w intensity
    vec4  stripColor;

    // ---- wear ----
    float dust;             // speckle density on the vinyl
    float scuff;            // fine circular scuffing
    float labelWear;        // grain and edge wear on the paper

    // ---- the shadow the record casts on the surface behind it ----
    float shadowZ;          // plane the shadow lands on, view-space z
    float shadowStrength;   // 0 = no shadow
    float shadowSoftness;   // px of blur per px of height above the plane
    vec4  shadowColor;

    // ---- the turntable's pin, seen as a shadow on the label ----
    float pinShadow;        // 0 = no pin at all, nothing drawn
    float pinRadius;        // the pin's own radius, px
    float pinHeight;        // length of pin standing proud of the label, px
    float pinPenumbra;      // penumbra px at the shadow's TIP, per px of that
                            // length. The penumbra is not one number for the
                            // whole shadow: it grows ALONG it, because what
                            // sets it is how far the point casting the shadow
                            // is from the surface catching it, and the pin's
                            // base is ON the record while its tip is a whole
                            // protrusion above it.
    float pinPenumbraBase;  // and what is left at the root, where the pin
                            // meets the record. A contact: nearly sharp.
    float pinShadowFade;    // how much the shadow also drains toward its tip.
                            // The same light is spread over more record there,
                            // so the far end is fainter as well as softer.

    // ---- misc ----
    float labelHasTex;      // 0 = no album art bound; use labelTint flat
};

layout(binding = 1) uniform sampler2D labelTex;

const float PI = 3.14159265359;

// -----------------------------------------------------------------------------
// small helpers
// -----------------------------------------------------------------------------
float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }

// Schlick's fifth power is written as `pow(x, 5.0)` throughout and left that
// way ON PURPOSE. Hand-expanding it to x*x*x*x*x is the obvious micro-fix and
// it buys EXACTLY NOTHING here -- Mesa already lowers a constant integer
// exponent to multiplies, and the shader compiled to the same 2552
// instructions and 21757 cycles either way -- while the two spellings do not
// round identically, which moved a dozen pixels of the spindle hole's rim by
// up to 38 levels through the near-singular denominator of the anisotropic
// GGX. Measured, both halves.

// EVERY DIRECTION THIS SHADER IS GIVEN IS ALREADY UNIT LENGTH, and none of them
// is normalised again here. `light0`, `light1` and `stripCenter` are built by
// Lighting.dirOf, which returns (cos a * r, sin a * r, e) with r = sqrt(1 - e^2)
// -- unit by construction; `stripAxis` is (cos t, sin t, 0); and the three
// columns of `basis` are an orthonormal frame VinylDisc builds by rotating one.
// Re-normalising them per pixel would cost ten inverse square roots per
// fragment for a value that cannot have changed since the uniform was written. Anything
// derived from them here (the radial and tangential directions, the face
// normal) is a unit combination of an orthonormal pair and is unit for the same
// reason. VinylDisc.qml normalises what it sends so this stays true.

// A soft shoulder on the way out: the same idea as the specular knee, one level
// further out. Below `highlightKnee` nothing happens at all -- the near-black
// default never comes near it, so the record everybody actually sees is
// untouched -- and above it the response bends toward 1.0 instead of arriving
// at it, so a pale record's arcs and the brightest part of a label's artwork
// keep their shape instead of becoming one flat plate. Without it, a white
// record's whole face sits at the ceiling and the sheen has nowhere to go.
vec3 shoulder(vec3 c) {
    float knee = clamp(highlightKnee, 0.05, 1.0);
    float span = max(1.0 - knee, 1e-3);
    vec3 e = max(c - vec3(knee), vec3(0.0));
    return c - e + e / (1.0 + e / span);
}

// Fresnel with the surface's roughness in it (Fdez-Aguera). A rough surface's
// grazing reflectance never climbs to 1, which is exactly the difference
// between lacquer's hard rim light and paper's soft one -- the same reason the
// label needs its own fresnel rather than the body's.
float fresRough(float ndv, float f0, float rough, float p5) {  // p5 = (1-ndv)^5
    float f90 = max(f0, 1.0 - rough);
    return f0 + (f90 - f0) * p5;
}

// The turntable's pin, seen as a shadow on the record's label.
//
// The pin is a small cylinder standing up through the spindle hole; `pinHeight`
// is the length of it that stands proud of the label, and the shadow grows and
// softens with that length. A stage sends the pin minus however far the record
// has risen up it, so the shadow is longest with the record down on the platter
// and gone by the time it has cleared the pin -- which is the whole point of
// the pin being there: without it a record that grows is indistinguishable from
// a record that is merely being scaled.
//
// The shadow is that length projected along the key light. The tip's disc lands
// at `tip`; every cross-section below it lands somewhere on the way there, so
// the union is a capsule from the spindle to that point -- and the parameter
// along that capsule is also HOW FAR UP THE PIN the slice that landed there
// came from. That is the whole of the penumbra: the slice at the record's own
// surface is a contact and is nearly sharp, the slice at the tip is a whole
// protrusion away and is soft in proportion. A shadow of one softness
// everywhere is the shadow of a cut-out lying on the label, which reads as
// wrong.
//
// It follows that the shadow is SHORTER AND HARDER while the record is still
// coming down -- little of the pin is above it yet -- and grows longer and
// softer along its length as the record settles. Nothing has to switch: the
// stage sends the protrusion and both properties fall out of it.
//
// pin_top.frag casts the same capsule the other way, from the whole pin onto
// the platter. One projection, two surfaces.
//
// AND IT CASTS ON WHICHEVER FACE IS UP. The pin stands out of the platter
// toward the camera whatever the record is doing, so the face it shadows is
// the one being LOOKED AT -- which after a flip is the record's other one.
// Casting it on "the A-side" only would leave the record without its spindle
// shadow for the whole of the second half of an album: the two faces at the
// same pose would differ over the label and nowhere else.
// The frame is therefore the VISIBLE FACE's own -- axisV and axisN mirrored
// with it, which for a flat flipped record is exactly the view frame again --
// so the same light lays the same capsule in the same screen place on both.
float pinShade(vec3 pLocal, float front, float isEdge,
               vec3 axisU, vec3 axisV, vec3 axisN) {
    if (pinShadow <= 0.001 || isEdge > 0.5) return 1.0;
    float face = front > 0.5 ? 1.0 : -1.0;
    vec3 L = light0.xyz;
    vec3 Ld = vec3(dot(L, axisU), face * dot(L, axisV), face * dot(L, axisN));
    vec2 pFace = vec2(pLocal.x, face * pLocal.y);
    // The light has gone behind the record: there is nothing left to occlude.
    // It DRAINS on the way there rather than stopping: as the key goes grazing
    // the shadow runs off to infinity and spreads its darkness over all of it,
    // so a hard cutoff would pop a long shadow out of existence in one frame of
    // a tilt. The record's own shadow on the platter fades the same way, from
    // the same reasoning.
    if (Ld.z < 0.10) return 1.0;
    float graze = smoothstep(0.10, 0.28, Ld.z);
    vec2 tip = -Ld.xy / Ld.z * max(pinHeight, 0.0);
    float len2 = dot(tip, tip);
    float t = len2 > 1e-6 ? clamp(dot(pFace, tip) / len2, 0.0, 1.0) : 0.0;
    float sd = length(pFace - tip * t) - max(pinRadius, 0.5);
    float pen = max(pinPenumbraBase + pinPenumbra * max(pinHeight, 0.0) * t, 0.25);
    float a = (1.0 - smoothstep(-pen, pen, sd))
            * clamp(pinShadow, 0.0, 1.0) * graze
            * (1.0 - clamp(pinShadowFade, 0.0, 1.0) * t);
    return 1.0 - a;
}

// GGX, anisotropic. t and b are the tangent (along the groove) and bitangent
// (radial) in view space; at and ab are the corresponding roughness alphas.
float ggxAniso(vec3 n, vec3 h, vec3 t, vec3 b, float at, float ab) {
    float th = dot(t, h) / max(at, 1e-4);
    float bh = dot(b, h) / max(ab, 1e-4);
    float nh = dot(n, h);
    float d = th * th + bh * bh + nh * nh;
    return 1.0 / (PI * max(at, 1e-4) * max(ab, 1e-4) * d * d);
}

float smithG(float ndv, float ndl, float a) {
    // Schlick-GGX, one k for both directions. The record is smooth enough
    // that the exact G barely shows; this keeps it cheap and stable.
    float k = a * 0.5;
    float gv = ndv / (ndv * (1.0 - k) + k);
    float gl = ndl / (ndl * (1.0 - k) + k);
    return gv * gl;
}

vec3 envSample(vec3 dir) {
    // A studio in two colours: a bright half above the horizon, a dark half
    // below, with a soft transition. The record's blackness is entirely this
    // gradient bent by the surface normal, so the horizon's softness is what
    // decides whether the disc reads as lacquer or as rubber.
    float t = smoothstep(-envHorizon, envHorizon, dir.y);
    return mix(groundColor.rgb, skyColor.rgb, t);
}

// -----------------------------------------------------------------------------
// shading of one point on the record
//   pLocal  hit position in disc space (xy on the face, z along the normal)
//   nView   shading normal in view space
//   viewDir unit vector from the hit TOWARD the eye
//   front   1 on the A-side, 0 on the B-side, 0.5-ish on the edge
// -----------------------------------------------------------------------------
vec3 shadeSurface(vec3 pLocal, vec3 nView, vec3 viewDir, float isEdge, float front,
                  vec3 axisU, vec3 axisV, vec3 axisN) {
    float r = length(pLocal.xy);
    vec2 rd2 = r > 1e-5 ? pLocal.xy / r : vec2(1.0, 0.0);

    // Radial and tangential directions, lifted into view space. Unit without
    // being normalised: rd2 is unit and axisU/axisV are orthonormal.
    vec3 radial = rd2.x * axisU + rd2.y * axisV;
    vec3 tangent = -rd2.y * axisU + rd2.x * axisV;

    // ---- which band are we in ----
    float inLabel = 1.0 - smoothstep(labelR - 1.0, labelR + 1.0, r);
    float inGrooves = smoothstep(grooveInnerR - 1.5, grooveInnerR + 1.5, r)
                    * (1.0 - smoothstep(grooveOuterR - 1.5, grooveOuterR + 1.5, r));
    inLabel *= 1.0 - isEdge;
    inGrooves *= 1.0 - isEdge;

    // ---- grooves: perturb the normal by dh/dr of a sine in r ----
    // The pitch is measured in item pixels, so the same record at a different
    // size keeps the same number of rings rather than the same ring width.
    //
    // A real LP's groove pitch is far under a pixel at any size this thing is
    // drawn at, so the rings are NOT what the eye reads on a record: what it
    // reads is the smooth LAND between two tracks, which has no groove in it
    // at all and therefore reflects like a mirror next to the matte, scattering
    // modulated area. Both are here -- the fine sine for when the record is
    // large or the camera is close, and the lands, which stay visible however
    // small it gets.
    float pitch = max(groovePitch, 0.25);
    float fw = max(fwidth(r), 1e-4);
    // Nyquist, not a guess: a sine of pitch P stops being a sine and starts
    // being moire the moment the pixel footprint passes P/2. The fade
    // therefore begins at a quarter of the pitch and is COMPLETE at half of
    // it. A fade running from 0.35 to 0.9 of the pitch would still draw the
    // sine at up to 1.8x its own sampling limit, which is where beating rings
    // come from.
    float grooveAA = 1.0 - smoothstep(pitch * 0.25, pitch * 0.5, fw);
    float phase = 2.0 * PI * r / pitch;
    float dhdr = grooveDepth * cos(phase) * grooveAA;

    // The lands: `trackCount` evenly spaced smooth rings across the modulated
    // band, each `trackWidth` of the spacing wide, antialiased against their
    // own footprint so they neither shimmer nor disappear.
    float bandSpan = max(grooveOuterR - grooveInnerR, 1e-3);
    float trackPos = (r - grooveInnerR) / bandSpan * max(trackCount, 1.0);
    float landD = abs(fract(trackPos) - 0.5) * 2.0;          // 1 at a land's centre
    float landW = clamp(1.0 - trackWidth, 0.0, 0.999);
    float landFP = fwidth(trackPos);
    float landAA = max(landFP * 2.0, 1e-3);
    float land = smoothstep(landW - landAA, landW + landAA, landD);
    // Once a whole land-and-groove pair falls inside one pixel there is no ring
    // left to draw, only its average -- and drawing one anyway is the other
    // half of the moire. `trackWidth` IS that average, by definition, so the
    // rings dissolve into the right grey instead of beating against the grid.
    land = mix(land, clamp(trackWidth, 0.0, 1.0), smoothstep(0.25, 0.5, landFP));
    land *= inGrooves;

    vec3 nSurf = normalize(nView - radial * dhdr * inGrooves * (1.0 - land));

    // ---- the bevel at the record's two hard corners -----------------------
    // A pressed record's rim rolls into both of its faces and its spindle hole
    // is punched with a lip; neither is a knife edge. Traced sharp they are,
    // and the right angle where the wall meets the face is black under this
    // lighting -- the void a flipping record would show at its hole and along
    // its rim. So the corner is SHADED round rather than traced round: the normal
    // is rolled halfway toward the neighbouring surface over the last
    // `edgeBevel` px, which is exactly what the light needs to wrap it. Halfway
    // and not the whole way, because a quarter-round's normal at the join is
    // the bisector of the two it joins.
    float halfT = thickness * 0.5;
    float bev = clamp(edgeBevel, 0.0, halfT * 0.95);
    if (bev > 1e-3) {
        if (isEdge > 0.5) {
            float k = smoothstep(0.0, 1.0, clamp((abs(pLocal.z) - (halfT - bev)) / bev, 0.0, 1.0));
            vec3 faceN = axisN * (pLocal.z >= 0.0 ? 1.0 : -1.0);
            nSurf = normalize(mix(nSurf, faceN, 0.5 * k));
        } else {
            float kOut = smoothstep(0.0, 1.0, clamp((r - (radius - bev)) / bev, 0.0, 1.0));
            float kIn = smoothstep(0.0, 1.0, clamp(((holeR + bev) - r) / bev, 0.0, 1.0));
            nSurf = normalize(mix(nSurf, radial, 0.5 * kOut));
            nSurf = normalize(mix(nSurf, -radial, 0.5 * kIn));
        }
    }

    // Scuffing: fine circular scratches. They raise the ROUGHNESS along the
    // groove rather than bending the normal -- a bent normal at this scale
    // sparkles under the sheen, which reads as noise, not as wear.
    // Coherent, not per-pixel: a scratch is an arc, so the hash is constant
    // along a band of radius and varies slowly with angle.
    float ang = atan(pLocal.y, pLocal.x);
    // Never on the cut edge: there r barely changes, so the band index runs at
    // the pixel rate and the field degenerates into white noise.
    float scuffN = hash21(vec2(floor(ang * 6.0), floor(r * 0.45)))
                 * scuff * (1.0 - inLabel) * (1.0 - isEdge);

    // ---- albedo ----
    // Grooves scatter, lands do not: the modulated area is rougher across the
    // grooves, and a land drops back to the lacquer's own roughness. The
    // scattering also lifts the modulated area's albedo a little, so the rings
    // stay readable when no highlight happens to be crossing them.
    vec3 albedo = vinylColor.rgb * (1.0 + 0.55 * grooveRough * inGrooves * (1.0 - land));
    float roughR = roughAcross + grooveRough * inGrooves * (1.0 - land);

    if (inLabel > 0.001) {
        vec2 uv = pLocal.xy / max(labelR, 1e-3);
        uv = vec2(uv.x, -uv.y) * 0.5 + 0.5;      // disc +y is up, texture +y is down
        vec3 paper = labelTint.rgb;
        if (labelHasTex > 0.5) {
            paper = texture(labelTex, clamp(uv, 0.0, 1.0)).rgb * labelTint.rgb;
        }
        // Kept in the sleeve, so only lightly worn: a little grain, and a
        // darker ring where the paper meets the lacquer.
        float grain = (hash21(pLocal.xy * 3.7) - 0.5) * labelWear * 0.35;
        float edgeWear = smoothstep(labelR * 0.86, labelR, r) * labelWear * 0.30;
        paper = clamp(paper * (1.0 + grain) * (1.0 - edgeWear), 0.0, 1.0);
        albedo = mix(albedo, paper, inLabel);
    }

    // Dust: sparse specks, everywhere but the label -- and never on the cut
    // edge, where the radius barely changes so the cell index runs at the pixel
    // rate and the whole field collapses into white noise. That noise, seen
    // along the rim of a record mid-flip, reads as a void with static in it
    // rather than as an edge.
    //
    // One cell, one grain, but four hashes: whether there is a grain here, where
    // in its cell it sits, how big it is and how bright. The size is squared, so
    // the field is mostly fine grit with the occasional larger fleck. A grid of
    // identical squares is invisible while the record spins and unmistakable the
    // moment it stops, which is the only time anybody looks at it.
    float onFace = (1.0 - inLabel) * (1.0 - isEdge);
    float dustCell = max(2.5, fw * 3.0);
    vec2 dq = pLocal.xy / dustCell;
    vec2 dcell = floor(dq);
    vec2 dfrac = fract(dq) - 0.5;
    float dHere = hash21(dcell + 17.0);
    float dWhere = hash21(dcell + 71.3);
    float dSize = hash21(dcell + 129.7);
    float dBright = hash21(dcell + 233.1);
    vec2 dCentre = (vec2(dWhere, fract(dWhere * 97.13)) - 0.5) * 0.62;
    float dRad = mix(0.07, 0.30, dSize * dSize);
    float dOff = length(dfrac - dCentre) / dRad;
    // A grain's edge is never harder than the pixel it is drawn in.
    float dAA = clamp(fw / max(dustCell * dRad, 1e-3), 0.06, 1.0);
    float speck = (1.0 - smoothstep(1.0 - dAA, 1.0 + dAA, dOff))
                * step(1.0 - dust * 0.30, dHere)
                * (0.40 + 0.60 * dBright);
    albedo += speck * 0.22 * onFace * clamp(dustCell / max(fw, 1e-3) * 0.15, 0.0, 1.0);

    // A cut record edge never reaches #000000. It is a fresh, matte surface
    // rather than a pressed one, and every bounce inside the spindle hole lands
    // back on it -- left at the body's own near-black, the hole reads as a hole
    // punched through the screen. Lifted TOWARD WHITE rather than by a constant,
    // so a white record's edge stays white.
    albedo = mix(albedo, mix(albedo, vec3(1.0), clamp(edgeLift, 0.0, 1.0)), isEdge);

    // ---- roughness per band ----
    float aAlong = mix(roughAlong * mix(1.0, 0.55, land) + scuffN * 0.03, labelRough, inLabel);
    float aAcross = mix(roughR, labelRough, inLabel);
    if (isEdge > 0.5) { aAlong = 0.45; aAcross = 0.45; }

    float ndv = max(dot(nSurf, viewDir), 1e-4);

    // How much sheen this body is allowed. A pale record is pale because its
    // pigment scatters, and that scattering happens in the first micrometres of
    // the surface, where it breaks up the specular lobe: a white record's arcs
    // really are softer than a black one's. Without this, the same full sheen
    // laid over a now-bright diffuse body clips flat and the record reads as
    // brushed aluminium. The ramp starts at 0.30 luma, so the near-black default
    // gets exactly 1.0 and is untouched.
    float paleness = smoothstep(0.30, 1.0, luma(vinylColor.rgb));
    float bodySheen = 1.0 - clamp(paleSheen, 0.0, 1.0) * paleness;
    float specScale = mix(specStrength * bodySheen, labelSpec, inLabel);

    // The pin's shadow occludes the KEY light and only the key light, because
    // it is that light's shadow: it takes the key's diffuse and its highlight
    // together and leaves the ambient and the room's reflection alone, which is
    // what a soft contact shadow looks like.
    float keyShade = pinShade(pLocal, front, isEdge, axisU, axisV, axisN);

    // ---- two lights ----
    vec3 spec = vec3(0.0);
    vec3 diff = vec3(0.0);
    for (int i = 0; i < 2; ++i) {
        vec3 L = i == 0 ? light0.xyz : light1.xyz;
        float inten = i == 0 ? light0.w : light1.w;
        vec3 lc = i == 0 ? lightColor0.rgb : lightColor1.rgb;
        float ndl = dot(nSurf, L);
        if (ndl <= 0.0 || inten <= 0.0) continue;
        vec3 h = normalize(L + viewDir);
        float d = ggxAniso(nSurf, h, tangent, radial, aAlong, aAcross);
        float g = smithG(ndv, ndl, 0.5 * (aAlong + aAcross));
        float f = 0.05 + 0.95 * pow(1.0 - max(dot(h, viewDir), 0.0), 5.0);
        float sh = (i == 0) ? keyShade : 1.0;
        spec += lc * inten * d * g * f * specScale * sh;
        diff += lc * inten * ndl * diffuseGain * sh;
    }

    // ---- the strip light ----
    vec3 refl0 = reflect(-viewDir, nSurf);
    if (stripAxis.w > 0.0) {
        vec3 sc = stripCenter.xyz;
        vec3 sa = stripAxis.xyz;
        float t = clamp(dot(refl0 - sc, sa), -stripCenter.w, stripCenter.w);
        vec3 Ls = normalize(sc + sa * t);
        float ndl = dot(nSurf, Ls);
        if (ndl > 0.0) {
            vec3 h = normalize(Ls + viewDir);
            float d = ggxAniso(nSurf, h, tangent, radial, aAlong, aAcross);
            float g = smithG(ndv, ndl, 0.5 * (aAlong + aAcross));
            float f = 0.05 + 0.95 * pow(1.0 - max(dot(h, viewDir), 0.0), 5.0);
            spec += stripColor.rgb * stripAxis.w * d * g * f * specScale;
        }
    }

    // ---- environment ----
    vec3 refl = refl0;
    vec3 env = envSample(refl);
    // A rough surface sees a blurrier, flatter environment; approximate that
    // by pulling the sample toward the normal's own direction.
    float blur = clamp(0.5 * (aAlong + aAcross) * 2.5, 0.0, 1.0);
    env = mix(env, envSample(nSurf), blur);

    // Two fresnels, because there are two materials. Lacquer's climbs all the
    // way to 1 at grazing and gives the rim its hard bright line; paper's is
    // held down by its own roughness, so the label picks up the SAME room from
    // the SAME angles, only softer and dimmer. That is the whole difference
    // between a sheen that says vinyl and one that says printed card.
    // One fifth power, two fresnels: they differ in their f0 and their
    // ceiling, not in the Schlick term, so that term is raised to the fifth
    // once.
    float f5 = pow(1.0 - ndv, 5.0);
    float fresBody = 0.05 + 0.95 * f5;
    float fresPaper = fresRough(ndv, 0.045, labelRough, f5);
    float envK = mix(reflectivity * bodySheen * fresBody, labelReflect * fresPaper, inLabel);

    // A soft knee on the specular: the sheen is far brighter than the display
    // can hold, and letting it clip flat turns the arc into a white plate with
    // no shape in it. This keeps the shape and only compresses the top.
    spec = spec / (1.0 + spec * specKnee);

    // The light that reaches this point. `ambientDiffuse` and `diffuseGain` are
    // set so the sum is 1.0 for a surface facing the key light under the default
    // rig -- a white albedo then reads white, which is what a paper label with
    // #ffffff in the artwork and a white vinyl both need. `edgeAmbient` is the
    // floor the cut edge keeps: it is never lit, but it is never black either.
    float irr = ambientDiffuse + edgeAmbient * isEdge;

    vec3 col = albedo * (irr + diff) + env * envK + spec;
    return shoulder(col);
}

// -----------------------------------------------------------------------------
// One ray against the record, in DISC space: two capped planes and two
// cylinders (the rim, and the spindle hole's inner wall). Returns the nearest
// hit. It is a function rather than inline code because the silhouette is
// resolved by running it again a few times per boundary pixel -- which is the
// only honest way to antialias a hole two pixels across.
// -----------------------------------------------------------------------------
bool traceDisc(vec3 o, vec3 d, float half_,
               out vec3 hitP, out float hitT, out float hitEdge, out float hitFront) {
    float bestT = 1e30;
    hitP = vec3(0.0); hitT = 0.0; hitEdge = 0.0; hitFront = 1.0;
    bool hit = false;

    // --- the two faces -------------------------------------------------------
    if (abs(d.z) > 1e-6) {
        for (int s = 0; s < 2; ++s) {
            float zf = (s == 0 ? half_ : -half_);
            float t = (zf - o.z) / d.z;
            if (t <= 0.0 || t >= bestT) continue;
            vec3 p = o + t * d;
            float r = length(p.xy);
            if (r > radius || r < holeR) continue;
            bestT = t; hitP = p; hitEdge = 0.0;
            hitFront = (s == 0) ? 1.0 : 0.0;
            hit = true;
        }
    }

    // --- the rim, and the wall of the spindle hole ---------------------------
    // Both are cylinders about the disc's own z axis; the rim is entered from
    // outside (near root), the hole is seen from inside (far root).
    float a = dot(d.xy, d.xy);
    if (a > 1e-9) {
        float b = dot(o.xy, d.xy);
        for (int c = 0; c < 2; ++c) {
            float cr = (c == 0 ? radius : holeR);
            float cc = dot(o.xy, o.xy) - cr * cr;
            float disc = b * b - a * cc;
            if (disc < 0.0) continue;
            float sq = sqrt(disc);
            float t = (c == 0 ? (-b - sq) / a : (-b + sq) / a);
            if (t <= 0.0 || t >= bestT) continue;
            vec3 p = o + t * d;
            if (abs(p.z) > half_) continue;
            bestT = t; hitP = p; hitEdge = 1.0;
            hitFront = p.z >= 0.0 ? 1.0 : 0.0;
            hit = true;
        }
    }

    hitT = bestT;
    return hit;
}

// Sub-pixel sample positions for the boundary, an 8-rook pattern: every sample
// has its own row AND its own column, so a near-horizontal or near-vertical
// edge resolves into as many levels as a diagonal one. Ordered so that any
// prefix of it is still balanced, because `edgeSamples` may ask for four.
//
// GLSL ES 1.00 has no array initialiser, and it is the variant NVIDIA's ES
// context compiles (a ShaderEffect without its own vertex shader links at
// the version Qt Quick's default vertex shader has: 100 es,
// tools/dev/bake_shaders.sh), so that variant fills the same table at the
// top of main(); every other variant keeps the constant (bake per target).
// One list of the eight, so the two can never differ.
#define SUB0 vec2(-0.4375,  0.0625)
#define SUB1 vec2( 0.1875, -0.3125)
#define SUB2 vec2(-0.1875,  0.3125)
#define SUB3 vec2( 0.4375, -0.0625)
#define SUB4 vec2(-0.3125, -0.1875)
#define SUB5 vec2( 0.0625,  0.4375)
#define SUB6 vec2(-0.0625, -0.4375)
#define SUB7 vec2( 0.3125,  0.1875)
#if defined(QSHADER_GLSL_ES) && QSHADER_GLSL_VERSION < 300
vec2 SUBS[8];
#else
const vec2 SUBS[8] = vec2[8](SUB0, SUB1, SUB2, SUB3, SUB4, SUB5, SUB6, SUB7);
#endif

void main() {
#if defined(QSHADER_GLSL_ES) && QSHADER_GLSL_VERSION < 300
    SUBS[0] = SUB0; SUBS[1] = SUB1; SUBS[2] = SUB2; SUBS[3] = SUB3;
    SUBS[4] = SUB4; SUBS[5] = SUB5; SUBS[6] = SUB6; SUBS[7] = SUB7;
#endif
    vec2 fragPx = quad.xy + qt_TexCoord0 * quad.zw;
    // View space: origin at the item's centre, +x right, +y UP, +z toward eye.
    vec3 ro = vec3(camCenter, camZ);
    vec3 screenPt = vec3(fragPx.x - res.x * 0.5, res.y * 0.5 - fragPx.y, 0.0);
    vec3 rd = normalize(screenPt - ro);

    // The one normalise that is KEPT, and it is not for correctness -- these
    // three arrive unit like everything else. It is for BIT-EXACTNESS: the
    // record's traced hit point is the input to the dust and scuff hashes and
    // to the label's texture derivative, and both of those turn a last-bit
    // difference into a whole speck moving or a mip level flipping. Measured:
    // taking these three out and normalising in QML instead (same value to
    // seven figures) moves 9442 pixels of the player render, 52 of them once
    // the wear is switched off. Three inverse square roots is what it costs to
    // be able to say the geometry did not move at all.
    vec3 axisU = normalize(basis[0].xyz);
    vec3 axisV = normalize(basis[1].xyz);
    vec3 axisN = normalize(basis[2].xyz);
    vec3 C = discPos.xyz;

    float half_ = thickness * 0.5;

    // --- ray into disc space -------------------------------------------------
    vec3 rel = ro - C;
    vec3 o = vec3(dot(rel, axisU), dot(rel, axisV), dot(rel, axisN));
    vec3 d = vec3(dot(rd, axisU), dot(rd, axisV), dot(rd, axisN));

    // --- can this ray reach the record at all? -------------------------------
    // The record lives inside a sphere about its own centre, and the distance
    // from that centre to this ray is one dot product away: |o|^2 minus the
    // square of the distance along the ray to the closest approach. A ray
    // further out than that sphere provably misses the record AND cannot be
    // near its silhouette, so it needs neither the trace nor the sub-samples --
    // and at the geometry this ships in, that is most of the quad: the disc's
    // item is the whole card, so the record covers 43 % of it in `player` and
    // 10 % in `mini`.
    //
    // The margin is in the same view-space pixels as `radius`, and one screen
    // pixel maps to at most one of them for a record at or above the item's
    // plane -- so 4 px covers the sub-samples' own half-pixel spread eight
    // times over. Nothing is cut: outside this sphere the trace would miss
    // anyway.
    float rBound = radius + half_ + 4.0;
    float tca = -dot(o, d);
    float perp2 = dot(o, o) - tca * tca;
    bool nearRecord = tca > 0.0 && perp2 < rBound * rBound;

    vec3 bestP = vec3(0.0);
    float bestT = 1e30, bestIsEdge = 0.0, bestFront = 1.0;
    bool hit = nearRecord && traceDisc(o, d, half_, bestP, bestT, bestIsEdge, bestFront);

    // --- how much of this pixel the record actually covers -------------------
    // Coverage from `fwidth` of the hit point's radius is meaningless at a
    // silhouette: half the pixels of the 2x2 quad miss the record, so their
    // radius is zero and the derivative is the whole disc. Measured, that puts
    // the rim's alpha at 255 in one pixel and 0 in the next -- no antialiasing
    // at all.
    //
    // So the boundary is found from a field that exists whether the ray hits or
    // not: the radius at which it crosses the record's own mid-plane. Its
    // derivative IS the footprint. Where that says a boundary is within reach,
    // the same geometry is traced again at `edgeSamples` sub-positions and the
    // hits counted; everywhere else the pixel is fully in or fully out and
    // costs one trace. Shading still happens once.
    float dzSafe = abs(d.z) < 1e-3 ? (d.z < 0.0 ? -1e-3 : 1e-3) : d.z;
    vec3 pMid = o - (o.z / dzSafe) * d;
    float rMid = length(pMid.xy);
    float fpx = max(length(vec2(dFdx(rMid), dFdy(rMid))), 1e-3);
    // How far the true silhouette can sit from that mid-plane radius once the
    // record is tilted: its own rim band, foreshortened. Capped, because at
    // grazing incidence the expression runs away and the `abs(d.z)` test below
    // has already taken over.
    float band = min(thickness * sqrt(max(1.0 - d.z * d.z, 0.0)) / max(abs(d.z), 1e-3), radius);
    // `abs(d.z) < 0.06` is the record seen EDGE-ON, where the mid-plane radius
    // is meaningless (the ray is parallel to the record's own plane) and every
    // pixel has to be resolved by sub-sampling. Without the bounding test in
    // front of it that clause would fire on the WHOLE CARD, so the seven
    // passes through edge-on that the half-album flip makes -- and every
    // swivel -- would cost eight extra traces on every pixel of a 536x527 quad
    // instead of on the ones the record is actually near. Measured: the sub-sample block is
    // 52 % of this shader's instructions.
    bool nearSil = nearRecord
                && (abs(d.z) < 0.06
                 || abs(rMid - radius) < 2.5 * fpx + band
                 || abs(rMid - holeR) < 2.5 * fpx + band);

    float cov = hit ? 1.0 : 0.0;
    int nSub = int(clamp(edgeSamples, 0.0, 8.0));
    if (nearSil && nSub > 0) {
        cov = 0.0;
        float wSub = 1.0 / float(nSub);
        // NO ANALYTIC SILHOUETTE FOR THE FLAT POSE, AND NO HIT PREDICATE: the
        // first draws a different record, the second is slower.
        //
        // An analytic silhouette: a record lying flat on the platter is a solid
        // of revolution about the view axis, so a pixel's coverage is a
        // distance to a circle rather than a count of hits, and eight traces
        // are eight ways of rediscovering it. Gated on a `flatPose` UNIFORM so
        // the whole subgroup takes the branch together, it
        // measures **13.0 % faster** at the playing pose (12.78 -> 11.12 ms/s,
        // three reps).
        //
        // It is the GEOMETRY that defeats it. A flat record is still a THICK
        // one seen by a pinhole camera a finite distance away, so its outline
        // is not one circle: the outermost point is the near face's rim, the
        // innermost is the far face's hole wall, and the two are separated by
        // the foreshortened band. Measuring both against the mid-plane moves
        // 4645 px of the pin sheet at 232/255; measuring them against the near
        // and far faces properly still moves 3628 at 229. The footprint is
        // wrong too -- `fpx` is the derivative of the MID-plane radius, not of
        // the face the coverage would be taken against -- and the spindle hole
        // is two pixels across in some states, which is the case the
        // sub-samples exist for in the first place.
        //
        // So it is faster and it does not draw the same record, and the record
        // is what is being drawn. The prize is small besides: the disc is 39.4
        // gpu ms/s of a 1000 ms/s budget and this block is 22.3 % of it in
        // `player` and 37.0 % in `mini`, so the whole saving is under 1 % of
        // the GPU.
        //
        // THE FULL TRACE, EIGHT TIMES, AND UNROLLED, IS THE FAST WAY.
        // Coverage is only a count, so the obvious saving is a cheap
        // does-it-hit predicate here and one real trace afterwards for the
        // pixel's shading point -- 2552 instructions down to 1573, a 38 %
        // smaller program. MEASURED IT IS SLOWER: the predicate's early
        // returns stop Mesa unrolling this loop, and a rolled loop with
        // divergent exits costs 8.7 % more GPU time at the flat pose and 29.2 %
        // more at edge-on, where every pixel of the quad runs it. Straight-line
        // code that the whole subgroup walks together beats a third less of it
        // walked at eight different speeds. The instruction count is the wrong
        // number to optimise; GPU time per second is the right one.
        for (int i = 0; i < 8; ++i) {
            if (i >= nSub) break;
            vec3 rd2 = normalize(vec3(screenPt.xy + SUBS[i], 0.0) - ro);
            vec3 d2 = vec3(dot(rd2, axisU), dot(rd2, axisV), dot(rd2, axisN));
            vec3 p2; float t2, e2, f2;
            if (traceDisc(o, d2, half_, p2, t2, e2, f2)) {
                cov += wSub;
                // If the pixel's own centre missed, shade the first sub-sample
                // that did not: a partly covered pixel must still be given the
                // colour of the thing covering it.
                if (!hit) { hit = true; bestP = p2; bestT = t2; bestIsEdge = e2; bestFront = f2; }
            }
        }
    }

    vec4 outCol = vec4(0.0);

    if (hit && cov > 0.0) {
        vec3 pLocal = bestP;
        vec3 nLocal;
        if (bestIsEdge > 0.5) {
            float rr = max(length(pLocal.xy), 1e-4);
            // The rim faces out; the hole's wall faces in.
            float sgn = (rr > (radius + holeR) * 0.5) ? 1.0 : -1.0;
            nLocal = vec3(pLocal.xy / rr * sgn, 0.0);
        } else {
            nLocal = vec3(0.0, 0.0, bestFront > 0.5 ? 1.0 : -1.0);
        }
        vec3 nView = nLocal.x * axisU + nLocal.y * axisV + nLocal.z * axisN;
        vec3 hitView = ro + bestT * rd;
        vec3 viewDir = normalize(ro - hitView);

        vec3 col = shadeSurface(pLocal, nView, viewDir, bestIsEdge, bestFront,
                                axisU, axisV, axisN);

        outCol = vec4(clamp(col, 0.0, 4.0) * cov, cov);
    }

    // --- the shadow the record casts on the surface behind it ----------------
    // A real projection, not a blurred copy of the silhouette: from the point
    // the view ray meets the surface plane, walk back along the light and ask
    // whether that line crosses the record's own plane inside its radius. The
    // shadow is then automatically the ellipse a tilted disc casts, it shears
    // with the light, and it collapses to a line when the record turns edge-on
    // to the lamp -- which is exactly when a real one disappears.
    if (shadowStrength > 0.001) {
        float denom = rd.z;
        if (abs(denom) > 1e-6) {
            float ts = (shadowZ - ro.z) / denom;
            if (ts > 0.0 && (!hit || ts > bestT)) {
                vec3 ps = ro + ts * rd;
                vec3 L = light0.xyz;
                float dn = dot(L, axisN);
                // Edge-on to the light: no shadow rather than an infinite one.
                float dnFade = smoothstep(0.06, 0.30, abs(dn));
                if (dnFade > 0.001) {
                    float s = dot(C - ps, axisN) / dn;
                    if (s > 0.0) {
                        vec3 q = ps + s * L;
                        vec2 lc2 = vec2(dot(q - C, axisU), dot(q - C, axisV));
                        float sr = length(lc2);
                        // Height above the plane blurs the edge and drains it:
                        // a record on the platter has a tight dark contact
                        // shadow, one held up has a wide faint one.
                        float height = max(C.z - shadowZ, 0.0);
                        float blur = radius * (0.04 + height * shadowSoftness);
                        float sa = (1.0 - smoothstep(radius - blur, radius + blur, sr))
                                 * shadowStrength * dnFade
                                 / (1.0 + height * shadowSoftness * 2.5);
                        sa = clamp(sa, 0.0, 1.0);
                        vec4 sh = vec4(shadowColor.rgb, 1.0) * sa;
                        // The record itself is composited over its own shadow.
                        outCol = outCol + sh * (1.0 - outCol.a);
                    }
                }
            }
        }
    }

    fragColor = outCol * qt_Opacity;
}
