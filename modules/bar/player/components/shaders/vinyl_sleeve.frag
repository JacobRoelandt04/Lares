#version 440

// =============================================================================
// vinyl_sleeve.frag
//
// The record's sleeve: the album cover as a piece of printed card that has
// been pulled in and out of a shelf for thirty years. One quad, one texture,
// everything else procedural.
//
// What makes card read as card rather than as a picture with a border:
//
//   ring wear      the record inside presses a circle into the front. It is
//                  the single most recognisable mark on a sleeve, and it is
//                  drawn as a HEIGHT, not as a dark ring: an emboss the light
//                  catches on one side and loses on the other.
//   edge split     along the edges the print splits and the white core of the
//                  board shows through, patchily, worst at the corners where
//                  the board is also chewed away -- so the silhouette itself
//                  is eaten there, not just recoloured.
//   opening        one edge (the left by default, because the record has to
//                  come out toward the middle of the popup) has no fold: it is
//                  a lip, with the inner card visible as a thin dark line.
//   scratches      long shallow scuffs across the print, and a paper grain
//                  under everything.
//
// The lighting is one height field: ring + grain + scratches, differentiated
// on the fly, lit by the same key light the record uses so the two objects
// agree about where the room is. That is the whole point of doing it here
// instead of stacking translucent PNGs -- the wear responds to the sleeve's
// own rotation, which is what sells the sweep as a physical object.
//
// None of that wear is uniform. A sleeve is handled by its edges -- pushed
// into a shelf, pulled back out by a corner -- so the grain, the scuffs and
// the abrasion are all multiplied by `wearMask`, which is flat and quiet
// across the middle of the print and climbs steeply over the last part of the
// way out, with the diagonals worn hardest of all.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    vec2  res;              // item size in px
    float seed;             // decorrelates two sleeves on screen at once
    float coverInset;       // px of card visible around the print

    // Wear
    float edgeWear;         // how far the split runs in, in px
    float cornerWear;       // extra radius eaten out of each corner, px
    float ringWear;         // depth of the record's impression
    float ringRadius;       // as a fraction of the sleeve's half-width
    float scratches;        // count/strength of the long scuffs
    float grain;            // paper texture
    float fade;             // how far the print has faded toward the card
    float ringInk;          // how much the ring also takes the ink off
    float wearBias;         // 0 = wear spread evenly, 1 = wear only at the rim
    float wearShape;        // how abruptly the wear climbs toward the rim

    // Colours
    vec4  cardColor;        // the board's core, seen where the print is gone
    vec4  cardEdgeColor;    // the cut edge of the board, at the opening
    vec4  printTint;        // multiplies the cover

    // Light, in the same view space the record uses.
    vec4  lightDir;         // xyz, w intensity
    float gloss;            // how much the print still shines
    float ambient;

    float hasCover;         // 0 = no album art bound
    float openingSide;      // 0 = left, 1 = right
};

layout(binding = 1) uniform sampler2D coverTex;

float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + vec2(1, 0));
    float c = hash21(i + vec2(0, 1)), d = hash21(i + vec2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; ++i) {
        v += a * vnoise(p);
        p *= 2.03;
        a *= 0.5;
    }
    return v;
}

// How worn this point of the front is, 0..1. A sleeve is not weathered evenly:
// it is handled by its edges and pulled out of a shelf by a corner, so the rim
// takes nearly all of it and the middle of the print stays close to new. A
// linear ramp from the centre reads as a vignette, which is why this is shaped
// instead -- `rim` is quiet across the middle and climbs steeply over the last
// part of the way out, and `diag` lifts the two diagonals so a corner wears
// like a piece of rim twice over. `wearBias` is how much of that shaping to
// apply: at 0 the mask is flat 1 and the sleeve wears evenly.
float wearMask(vec2 pPx, vec2 halfPx) {
    vec2 e = abs(pPx) / max(halfPx, vec2(1.0));
    float s = max(wearShape, 0.5);
    float rim = pow(clamp(max(e.x, e.y), 0.0, 1.0), s);
    float diag = pow(clamp(0.5 * (e.x + e.y), 0.0, 1.0), s * 0.7);
    return mix(1.0, clamp(max(rim, diag), 0.0, 1.0), clamp(wearBias, 0.0, 1.0));
}

// Rounded-box distance, negative inside. Corners are eaten by wear, so the
// radius is per-corner.
float boxDist(vec2 p, vec2 half_, float r) {
    vec2 d = abs(p) - half_ + vec2(r);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - r;
}

// The height field the sleeve is lit by, in px units.
float sleeveHeight(vec2 pPx, vec2 halfPx, float ringR) {
    float h = 0.0;
    // The record's impression: a narrow crease where the rim has pressed, and
    // a wide shallow dish inside it. The crease has to be NARROW -- a metre of
    // gentle slope has no normal to catch the light, and the ring is the one
    // mark that must read at any size.
    float r = length(pPx) / max(ringR, 1.0);
    float ring = exp(-pow(abs(r - 1.0) * 26.0, 2.0));
    float dish = (1.0 - smoothstep(0.55, 1.02, r)) * 0.25;
    h -= (ring * 1.0 + dish) * ringWear;
    // Paper grain and the long scuffs, both pushed toward the rim: at the
    // centre of the print they are a fraction of their edge strength, which is
    // what stops the whole front reading as one evenly-noisy texture.
    float w = wearMask(pPx, halfPx);
    h += (fbm(pPx * 0.55 + seed * 13.0) - 0.5) * grain * 1.6 * w;
    // Long scuffs: thin, nearly horizontal, and sparse.
    float sc = fbm(vec2(pPx.x * 0.035 + seed, pPx.y * 2.6));
    h += smoothstep(0.70, 0.95, sc) * scratches * 1.8 * w;
    return h;
}

void main() {
    vec2 pxUV = qt_TexCoord0;
    vec2 halfPx = res * 0.5;
    vec2 pPx = (pxUV - 0.5) * res;                  // px from the centre, +y down

    // ---- silhouette: a board whose corners have been chewed ---------------
    float wearN = fbm(pPx * 0.05 + seed * 7.0);
    float cornerR = cornerWear * (0.6 + 0.8 * wearN);
    float d = boxDist(pPx, halfPx, cornerR);
    // A ragged edge: the cut wanders by a fraction of the wear depth.
    d += (wearN - 0.5) * edgeWear * 0.55;
    float aa = max(fwidth(d), 0.75);
    float cov = 1.0 - smoothstep(-aa, aa, d);
    if (cov <= 0.001) {
        fragColor = vec4(0.0);
        return;
    }

    // ---- the print --------------------------------------------------------
    // The cover is inset by `coverInset`, so a rim of card always shows: that
    // rim is what the split eats into.
    vec2 printHalf = halfPx - vec2(coverInset);
    vec2 uv = (pPx / max(printHalf, vec2(1.0))) * 0.5 + 0.5;
    vec3 print = printTint.rgb;
    if (hasCover > 0.5 && all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
        print = texture(coverTex, uv).rgb * printTint.rgb;
    }
    // Sun-faded toward the card's own colour, worst near the edges.
    float edgeT = clamp(-d / max(edgeWear * 3.0, 1.0), 0.0, 1.0);
    print = mix(print, cardColor.rgb, fade * (1.0 - edgeT) * 0.9);

    // ---- where the print has gone ------------------------------------------
    // Patchy, not a uniform band: the split follows the board's own fibres.
    float splitN = fbm(pPx * 0.11 + seed * 3.0);
    float splitEdge = edgeWear * (0.35 + 1.1 * splitN);
    // 0 deep inside the board, 1 within `splitEdge` of the cut.
    float split = smoothstep(-splitEdge, -splitEdge * 0.15, d);
    // Outside the print's own rectangle there is never any print.
    float outsidePrint = max(step(printHalf.x, abs(pPx.x)), step(printHalf.y, abs(pPx.y)));
    float bare = clamp(max(split, outsidePrint), 0.0, 1.0);
    vec3 albedo = mix(print, cardColor.rgb, bare);

    // Abrasion: where the board has been rubbed the ink is thinned rather than
    // gone. Same field AND same mask as the height, so a scuff that catches the
    // light is the one that has lost its colour, and both live near an edge.
    float rub = smoothstep(0.70, 0.95, fbm(vec2(pPx.x * 0.035 + seed, pPx.y * 2.6)))
              * wearMask(pPx, halfPx);
    float ringRub = exp(-pow(abs(length(pPx) / max(ringRadius * min(halfPx.x, halfPx.y), 1.0) - 1.0) * 26.0, 2.0));
    albedo = mix(albedo, cardColor.rgb, clamp(rub * 0.30 + ringRub * ringInk, 0.0, 1.0) * (1.0 - bare));

    // ---- the opening -------------------------------------------------------
    // One edge is a lip, not a fold: a thin line of the board's cut edge, with
    // a soft shadow just inside it where the card lifts away from the record.
    float sideX = (openingSide > 0.5) ? (halfPx.x - pPx.x) : (pPx.x + halfPx.x);
    float lip = 1.0 - smoothstep(1.0, 3.5, sideX);
    float lipShadow = (1.0 - smoothstep(2.0, 14.0, sideX)) * 0.35;
    albedo = mix(albedo, cardEdgeColor.rgb, lip);
    albedo *= (1.0 - lipShadow * (1.0 - lip));

    // ---- lighting from the height field ------------------------------------
    float ringR = ringRadius * min(halfPx.x, halfPx.y);
    float e = 1.25;
    float h0 = sleeveHeight(pPx, halfPx, ringR);
    float hx = sleeveHeight(pPx + vec2(e, 0.0), halfPx, ringR);
    float hy = sleeveHeight(pPx + vec2(0.0, e), halfPx, ringR);
    // +y is DOWN in texture space, so the y derivative is negated to put the
    // normal in the same view space the record's light lives in.
    vec3 n = normalize(vec3(-(hx - h0) / e, (hy - h0) / e, 1.0));

    vec3 L = normalize(lightDir.xyz);
    float lam = max(dot(n, L), 0.0);
    vec3 V = vec3(0.0, 0.0, 1.0);
    vec3 H = normalize(L + V);
    float spec = pow(max(dot(n, H), 0.0), 28.0) * gloss * (1.0 - bare * 0.7);

    vec3 col = albedo * (ambient + lam * lightDir.w) + vec3(spec);

    fragColor = vec4(clamp(col, 0.0, 2.0) * cov, cov) * qt_Opacity;
}
