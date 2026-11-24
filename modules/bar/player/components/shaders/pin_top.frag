#version 440

// =============================================================================
// pin_top.frag
//
// The turntable's spindle, seen from where the camera actually is: straight
// down the record's axis. From there a spindle is not a rod -- it is a small
// CIRCLE of turned metal at the middle of the platter, with the pin's own
// shadow lying away from it across the mat. This shader draws exactly those
// two things and nothing else.
//
// Why it is a shader and not a rounded Rectangle with a gradient: a spindle is
// machined, and machined metal is anisotropic -- its microscopic scratches run
// AROUND the axis it was turned on, so the highlight is not a blob but two
// opposed arcs lying along the light's own azimuth. That is the same BRDF the
// record's grooves already use (vinyl_disc.frag), at a hundredth of the radius,
// and a linear gradient cannot produce it at any size.
//
// THE SHADOW IS THE SAME PROJECTION THE RECORD USES. `pinShade()` in
// vinyl_disc.frag casts the protruding pin onto the record's face; this casts
// the whole pin onto the platter. Both walk the same capsule -- from the
// spindle to where the tip's shadow lands, `-L.xy / L.z * height` -- and both
// widen the penumbra ALONG that capsule, because the penumbra of a shadow is
// set by how far the casting point is from the surface catching it, and the
// pin's base is ON the platter while its tip is a whole pin length above it.
// A shadow of one softness everywhere is a shadow of a cut-out, not of a rod.
//
// Everything is in pixels from the ITEM'S CENTRE, which is the spindle's axis,
// with +y UP (view space, like the record's) rather than down.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;

    vec2  res;              // item size in px; the spindle's axis is its centre

    // ---- the pin ----
    float pinR;             // the cap's radius, px
    float pinH;             // how far the cap stands above the platter, px
    float capDome;          // cap height as a fraction of its radius. 0 is a
                            // flat disc, 1 a hemisphere. The dome is what makes
                            // the circle read as the END OF A ROD rather than
                            // as a sticker: it gives one bright side, one dark
                            // side and a rolled rim, from one number.

    // ---- the turning marks ----
    //
    // As a BRDF only. The marks themselves are tens across the radius of a face
    // that is drawn three pixels wide here, so band-limiting them -- which a
    // shader has to do -- fades them to their own mean, which is nothing:
    // an amplitude knob for them is worth 0.67 of a level at radius 26 and 0.00
    // at the radius the spindle ships at. What survives that
    // minification, and is the whole of what says "machined", is the ANISOTROPY
    // they leave behind: 23 levels of 255 on a 6 px cap.
    float brushAlong;       // GGX alpha ALONG the marks (around the circle).
                            // Small: that is the sharp direction, and what
                            // makes the highlight two arcs instead of a blob.
    float brushAcross;      // and across them (radially). Large: smeared.

    // ---- how much light it gets ----
    //
    // The cap is shaded as ONE 0..1 TONE along a three-stop ramp -- shadeColor
    // below, metalColor at rest, litColor above -- and everything the light
    // does moves that tone. It is not a physical metal's reflectance times its
    // own colour, and it must not be: a reflectance squares its colour, so on
    // a dark palette the plateau would come out DARKER than the mat the spindle
    // stands on and the pin would read as a hole punched in the platter. A ramp between
    // three fixed tones cannot do that whatever the palette is -- which is what
    // lets those three tones be CHROME's rather than the shell's, and the pin
    // therefore look like the same machined part in both modes.
    float metalSpec;        // how far the highlight pushes the tone up
    float envStrength;      // how far the room swings it, sky against ground
    float neutral;          // where the tone sits with no room and no lamp:
                            // 0.5 is the middle of the ramp, the metal itself
    float shade;            // how far the record hanging over the pin pulls the
                            // tone DOWN. Not a cast shadow with an outline: a
                            // record above the spindle occludes the whole upper
                            // half of the room, and what that looks like on a
                            // small cap is that it goes flat and dark. Driven
                            // from the gap between the record and the cap, so it
                            // dies the moment the pin comes back out through the
                            // hole.

    // ---- the pin's own shadow on the platter ----
    float castShadow;       // 0 draws none. The copy of this drawn IN FRONT of
                            // the record sets 0: its shadow is under the
                            // record, not on it.
    float shadowStrength;
    float penBase;          // penumbra px at the shadow's ROOT, where the pin
                            // meets the platter. Small: that contact is sharp.
    float penGrow;          // penumbra px per px of pin height, at the TIP
    float shadowFade;       // how much the shadow also drains toward its tip.
                            // A penumbra spreads the same light over more
                            // platter, so the far end is not only softer but
                            // fainter.

    // ---- the room ----
    vec4  lightDir;         // xyz toward the key light in view space (x right,
                            // y up, z toward the eye), w unused
    // The chrome ramp, low to high. Fixed colours from the host, NOT theme
    // tokens: chrome is chrome in either mode. Only `shadowColor` follows the
    // palette, because that one lands on the platter and not on the pin.
    vec4  metalColor;       // the metal itself, at rest
    vec4  litColor;         // what a mirror facing the room's sky shows
    vec4  shadeColor;       // and facing its floor
    vec4  shadowColor;      // the shadow it lays on the platter
};

const float PI = 3.14159265359;

// A soft shoulder on the way to the top of the ramp, the same one the record's
// sheen has. Without it the room alone puts the cap's lit half within a
// fifteenth of the ceiling and the highlight -- the whole of what says the
// metal was TURNED rather than moulded -- is clipped flat against it: the
// second angular harmonic falls from 0.040 of the mean to 0.014, which is
// the same number an isotropic cap gives.
float shoulder(float t, float knee) {
    float e = max(t - knee, 0.0);
    return min(t, knee) + e / (1.0 + e / max(1.0 - knee, 1e-3));
}

// Anisotropic GGX. Identical to the record's, deliberately: the same law with
// a different tangent is what makes the pin and the record read as metal and
// lacquer in one room instead of as two unrelated drawings.
float ggxAniso(vec3 n, vec3 h, vec3 t, vec3 b, float at, float ab) {
    float th = dot(t, h) / max(at, 1e-4);
    float bh = dot(b, h) / max(ab, 1e-4);
    float nh = dot(n, h);
    float d = th * th + bh * bh + nh * nh;
    return 1.0 / (PI * max(at, 1e-4) * max(ab, 1e-4) * d * d);
}

float smithG(float ndv, float ndl, float a) {
    float k = a * 0.5;
    float gv = ndv / (ndv * (1.0 - k) + k);
    float gl = ndl / (ndl * (1.0 - k) + k);
    return gv * gl;
}

void main() {
    // Item pixels, from the centre, y up.
    vec2 p = vec2(qt_TexCoord0.x - 0.5, 0.5 - qt_TexCoord0.y) * res;
    float rPix = length(p);
    float R = max(pinR, 0.25);

    vec3 L = normalize(lightDir.xyz);
    vec4 outCol = vec4(0.0);

    // ---- the pin's shadow on the platter -----------------------------------
    // The capsule from the spindle to where the TIP's shadow lands. Every
    // cross-section between the two lands somewhere on the way, so their union
    // is exactly that capsule; the penumbra at parameter t is the penumbra of
    // the slice of pin that landed there, and that slice is t of the way up.
    // A key going grazing does not switch this off in one frame: it runs the
    // tip out toward infinity and spreads the same darkness over all of it, so
    // it DRAINS. Same band, same reasoning and same numbers as the record's
    // copy of this shadow in vinyl_disc.frag -- one law, two surfaces, and a
    // hard cutoff on either of them pops a long shadow out of existence the
    // moment the lamp is swept.
    if (castShadow > 0.5 && shadowStrength > 0.001 && L.z > 0.10) {
        vec2 tip = -L.xy / L.z * max(pinH, 0.0);
        float len2 = dot(tip, tip);
        float t = len2 > 1e-6 ? clamp(dot(p, tip) / len2, 0.0, 1.0) : 0.0;
        float d = length(p - tip * t) - R;
        float pen = max(penBase + penGrow * max(pinH, 0.0) * t, 0.25);
        float a = (1.0 - smoothstep(-pen, pen, d))
                * shadowStrength * smoothstep(0.10, 0.28, L.z)
                * (1.0 - clamp(shadowFade, 0.0, 1.0) * t);
        outCol = vec4(shadowColor.rgb, 1.0) * clamp(a, 0.0, 1.0);
    }

    // ---- the cap -----------------------------------------------------------
    // Its coverage is never harder than the pixel it is drawn in: a real
    // spindle is four pixels across at popup size, and a hard step there is a
    // square, not a circle.
    float aa = max(fwidth(rPix), 0.5);
    float cov = 1.0 - smoothstep(R - aa, R + aa, rPix);

    if (cov > 0.001) {
        float u = clamp(rPix / R, 0.0, 1.0);
        vec2 dir2 = rPix > 1e-4 ? p / rPix : vec2(1.0, 0.0);

        // A spherical cap of height capDome*R. Its slope runs away at the rim,
        // which is the point: that is the rolled edge, and it is where the
        // metal picks up the room instead of the lamp.
        float s = clamp(capDome, 0.0, 4.0) * u / sqrt(max(1.0 - u * u, 1e-3));
        s = min(s, 6.0);

        vec3 n = normalize(vec3(dir2 * s, 1.0));
        vec3 V = vec3(0.0, 0.0, 1.0);
        // Around the circle, and across it: the turned tangent frame. This is
        // the whole of what makes it read as machined rather than moulded --
        // the sharp direction runs AROUND the axis, so the highlight comes out
        // as two opposed arcs lying along the light's azimuth.
        vec3 tang = normalize(vec3(-dir2.y, dir2.x, 0.0));
        vec3 bit = normalize(vec3(dir2, 0.0));

        float ndv = max(dot(n, V), 1e-3);
        float ndl = dot(n, L);
        float spec = 0.0;
        if (ndl > 0.0) {
            vec3 h = normalize(L + V);
            spec = ggxAniso(n, h, tang, bit, brushAlong, brushAcross)
                 * smithG(ndv, ndl, 0.5 * (brushAlong + brushAcross));
        }
        // The same soft ceiling the record's sheen has: an arc that clips flat
        // is a white plate with no shape in it.
        spec = spec / (1.0 + spec);

        // Which half of the room this bit of the cap is looking at. The dome is
        // what gives it any answer but "straight up": a flat disc would reflect
        // the horizon everywhere and have no lit side at all.
        vec3 refl = vec3(2.0 * n.z * n.x, 2.0 * n.z * n.y, 2.0 * n.z * n.z - 1.0);
        float sky = smoothstep(-0.45, 0.45, refl.y);

        // One tone, and one ramp through the chrome. The record's shade pulls
        // it DOWN the ramp, toward the dark end -- which on a mirror is what
        // being overhung by a record actually looks like, since the record is
        // most of the sky the cap could otherwise see. The lamp survives that a
        // little longer than the room does, which is what makes the darkening
        // read as shade rather than as a dimmer.
        float occ = clamp(shade, 0.0, 1.0);
        float tone = clamp(shoulder(neutral
                         + envStrength * (sky - 0.5) * (1.0 - 0.7 * occ)
                         + metalSpec * spec * (1.0 - 0.6 * occ), 0.72)
                         - occ, 0.0, 1.0);
        vec3 col = tone < 0.5 ? mix(shadeColor.rgb, metalColor.rgb, tone * 2.0)
                              : mix(metalColor.rgb, litColor.rgb, (tone - 0.5) * 2.0);

        outCol = vec4(clamp(col, 0.0, 2.0), 1.0) * cov + outCol * (1.0 - cov);
    }

    fragColor = outCol * qt_Opacity;
}
