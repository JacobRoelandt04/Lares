#version 440
// =============================================================================
// label_plate.frag -- the ground of the card's label, under its print (AerialLabel.qml: the print is live QML text over this). PAPER where the tunnel's wipe has not been,
// the tunnel's SHIELD where it has: while the VPN is up the sticker is a plate of satin chrome (Material) or a drafted metal plate (Blueprint).
//
// The plate is drawn in the label's own millimetres (uv x the label's size), under the label's affine map, so it tilts and shakes with the label. The chrome is a MIRROR
// LYING FLAT: it shows the upper half of a room, and the room is laid out on the SCREEN (`axes`), not on the sticker -- the far corner shows the horizon (a dark land, a
// bright slit over it), the middle a large soft light and its end, the near corner a strip light; overhead hangs a round lamp nobody sees until the card TILTS (airplane): the
// mirror then turns toward the viewer and the whole room slides down the plate by twice the angle (`env.x`). A reflection reads as one only when something in it moves
// (round 5, the user), so three things do: the tilt, the POINTER (`env.yz`: the room shifts a little against it, as it would for a head that moves) and the CLOUD'S PULSE,
// whose front is mirrored in the plate as it leaves the label (`pulse`: the half of the ring below the origin, in the cloud's hue). The metal is brushed along the text: the
// room's edges are smeared ACROSS the grain, streak by streak. A thin bevel at the rim (pale on the lamp's side, dark on the far one). Nothing here has a clock of its own.
// THE WIPE (`wipe.x`, 0 paper .. 1 chrome, eased by the host): a front sweeps the label's length from +x to -x, leaning and rippled so it reads as metal flowing over the paper
// and not as a ruler; a hot line 2-3 device px wide ON the front, a narrow darker edge behind it, the metal behind still bright from the heat, the paper just ahead in its shadow.
// Opaque but for the rounded corners; premultiplied.
// =============================================================================

// QSB-NO-100ES: no GLSL ES 1.00 variant (tools/dev/bake_shaders.sh reads this line): this effect has a vertex shader of its own (label_plate.vert), so on an OpenGL ES context
// the pair links at GLSL ES 3.00.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 plate;      // x, y: the label's size mm; z: its corner radius mm; w: family (0 Material, 1 Blueprint)
    vec4 wipe;       // x: the wipe 0 (paper) .. 1 (chrome); y: the clock, s; z: 1 = dark mode; w: mm per DEVICE px along the text (the antialiasing's unit)
    vec4 lamp;       // x, y: the lamp's side in the label's plane (unit: the rim that is lit); z: the scene's live layer 0..1 (the mirrored pulse's strength); w: the paper's fibre / the brushing's strength (1 = as designed)
    vec4 axes;       // the plate's x axis (xy) and y axis (zw) ON SCREEN, px per mm: the room in the chrome is the screen's, not the sticker's
    vec4 env;        // x: the card's tilt, rad (the mirror turns toward the viewer: the room slides by twice that); y, z: where the pointer leads the room, -1..1 each way
    vec4 pulse;      // the cloud's front mirrored in the plate: x its radius on screen, px (< 0: none in flight); y its strength 0..1; z the fan's half angle, rad
    vec4 colPaper;   // the sticker's paper
    vec4 colSky;     // chrome: the pale band (Blueprint: unused)
    vec4 colBase;    // chrome: the plate's own tone (Blueprint: the face wash)
    vec4 colDeep;    // chrome: the dark horizon band (Blueprint: the faint ink of the hatch)
    vec4 colInk;     // Blueprint: the frame's ink (Material: unused)
    vec4 colHot;     // the front's hot line and the rim's light
    vec4 colPulse;   // the cloud's own hue (its front in the chrome)
};

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 u = fract(p);
    u = u * u * (3.0 - 2.0 * u);
    return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}
float gauss(float x, float w) {
    float k = x / w;
    return exp(-k * k);
}
// a soft-edged box in the room: centre c, half extents h, corner radius r, edge softness f (all in the room's own units); 1 inside
float softBox(vec2 q, vec2 c, vec2 h, float r, float f) {
    vec2 d = abs(q - c) - h + r;
    float sd = min(max(d.x, d.y), 0.0) + length(max(d, vec2(0.0))) - r;
    return 1.0 - smoothstep(-f, f, sd);
}
// THE ROOM, as brightness (0 dark .. 1 the lights' faces, a little over in their cores): q.x across (0 = straight ahead), q.y up (0 = the horizon, 1 = high overhead)
float room(vec2 q) {
    // every band bows a little away from straight ahead: a room, not a ruled sheet
    q.y += 0.085 * q.x * q.x;
    // the far wall: brightest low down, dimming upward; the ceiling darker still
    float L = mix(0.56, 0.30, smoothstep(0.0, 0.9, q.y));
    L = mix(L, 0.20, smoothstep(0.95, 1.5, q.y));
    // the horizon: a dark land under a crisp line, a bright slit of daylight right over it
    L = mix(0.10, L, smoothstep(0.070, 0.082, q.y));
    L += 0.50 * gauss(q.y - 0.118, 0.030) * (0.75 + 0.25 * cos(q.x * 2.2));
    // the large soft light, left of centre and a little under the middle of the view (on the plate: over the small print, clear of most of the docked name): its right END stands in the plate
    L = mix(L, 1.06, softBox(q, vec2(-0.42, 0.40), vec2(0.62, 0.100), 0.07, 0.022));
    // a strip light, higher and to the right
    L = mix(L, 0.98, softBox(q, vec2(0.48, 0.80), vec2(0.50, 0.032), 0.03, 0.012));
    // overhead: a round lamp (it comes onto the plate when the card tilts)
    float lampD = length((q - vec2(0.10, 1.27)) * vec2(1.0, 1.25));
    L = mix(L, 1.12, 1.0 - smoothstep(0.150, 0.175, lampD));
    L += 0.16 * gauss(lampD, 0.36);
    return L;
}
// a line's coverage: `d` mm from its middle, `hw` its half width, `aa` a device px
float lineCov(float d, float hw, float aa) {
    return 1.0 - smoothstep(hw - aa * 0.5, hw + aa * 0.5, abs(d));
}

void main() {
    vec2 size = plate.xy;
    vec2 p = qt_TexCoord0 * size;                    // mm from the label's corner: x along the text, y toward the fingers
    float aa = max(wipe.w, 0.001);
    float c = clamp(wipe.x, 0.0, 1.0);
    float t = wipe.y;
    bool blueprint = plate.w > 0.5;
    float k = lamp.w;

    // the outline: mm inside it (e > 0), feathered INWARD only
    vec2 pc = p - size * 0.5;
    vec2 q = abs(pc) - size * 0.5 + plate.z;
    float d = min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - plate.z;
    float e = -d;
    float cover = smoothstep(0.0, aa, e);
    // the rim's outward direction (the nearer edge; the corner's own radius where both are near)
    vec2 n = q.x > 0.0 && q.y > 0.0 ? normalize(q) * sign(pc) : (q.x > q.y ? vec2(sign(pc.x), 0.0) : vec2(0.0, sign(pc.y)));

    // ---- the front ----
    float wip = smoothstep(0.0, 0.05, c) * (1.0 - smoothstep(0.95, 1.0, c));      // 1 while the wipe is under way
    float xf = mix(size.x + 3.6, -3.6, c);
    float lean = (p.y - size.y * 0.5) * 0.22;
    // the front's own shape: two slow swells and a faint shiver (a long wave reads as metal flowing; a jagged one as torn paper)
    float rip = (vnoise(vec2(p.y * 0.26, t * 0.5)) - 0.5) * 2.6 + (vnoise(vec2(p.y * 0.62 + 7.0, t * 0.9 + 3.0)) - 0.5) * 0.9 + (vnoise(vec2(p.y * 2.4 + 2.0, t * 1.7)) - 0.5) * 0.14;
    float s = p.x - (xf + lean + rip);               // mm behind the front (> 0: chrome)
    float m = smoothstep(-aa * 0.5, aa * 0.5, s);

    // ---- the paper ----
    vec3 paper = colPaper.rgb;
    if (!blueprint)
        paper *= 1.0 + k * ((vnoise(p * 6.0) - 0.5) * 0.014 + (vnoise(p * vec2(1.3, 15.0)) - 0.5) * 0.010);
    paper *= 1.0 - 0.12 * wip * gauss(min(s, 0.0), 0.55);                        // the lip's shadow just ahead of the front

    // ---- the plate ----
    vec3 metal;
    if (!blueprint) {
        // where this point of the mirror looks. Screen millimetres from the plate's middle (x right, y down), then the room's own coordinates: the far side (up the
        // screen) looks at the horizon, the near side overhead; the tilt and the pointer move the whole view
        float ppm = max(length(axes.xy), 0.001);
        vec2 sm = (axes.xy * pc.x + axes.zw * pc.y) / ppm;
        vec2 q = vec2(sm.x * 0.036 - env.y * 0.16, 0.47 + sm.y * 0.043 + env.x * 1.75 - env.z * 0.10);
        // brushed along the text: the grain smears the room ACROSS itself (along the plate's y, here in the room's units) -- five looks spread over 1.5 mm, and each
        // streak of the grain throws its own a little further, so a light's edge is soft with a fine tooth and never a ruled line
        vec2 across = vec2(axes.z * 0.036, axes.w * 0.043) / ppm;
        float streak = (vnoise(vec2(p.x * 0.30, p.y * 24.0)) - 0.5) * 0.9 + (vnoise(vec2(p.x * 0.9 + 3.0, p.y * 57.0)) - 0.5) * 0.5;
        q += across * streak * 0.45 * k;
        float L = 0.30 * room(q) + 0.22 * (room(q + across * 0.38) + room(q - across * 0.38)) + 0.13 * (room(q + across * 0.76) + room(q - across * 0.76));
        metal = L < 0.5 ? mix(colDeep.rgb, colBase.rgb, L * 2.0) : mix(colBase.rgb, colSky.rgb, min((L - 0.5) * 2.0, 1.0));
        metal = mix(metal, colHot.rgb, clamp((L - 1.0) * 4.0, 0.0, 0.55));
        // the grain itself: fine streaks of its own tone
        float br = (vnoise(vec2(p.x * 0.35, p.y * 26.0)) - 0.5) * 0.050 + (vnoise(vec2(p.x * 1.1 + 3.0, p.y * 61.0)) - 0.5) * 0.030;
        metal *= 1.0 + k * br;
        // the cloud's front, mirrored: the fan stands on the label's centre and opens upward, so its picture in the plate is the same arc opening DOWN the screen,
        // within the fan's own angle, clipped by the plate itself
        if (pulse.x > 0.0 && pulse.y > 0.0) {
            vec2 sp = axes.xy * pc.x + axes.zw * pc.y;
            float r = length(sp);
            float dr = r - pulse.x;
            float ring = gauss(dr, 2.4) + (dr < 0.0 ? 0.26 * exp(dr / 14.0) : 0.0);
            float ath = abs(atan(sp.x, sp.y));                                 // 0 straight down the screen
            float inFan = 1.0 - smoothstep(pulse.z - 0.26, pulse.z + 0.05, ath);
            float born = smoothstep(3.0, 30.0, pulse.x);
            metal = mix(metal, mix(colPulse.rgb, colHot.rgb, 0.30), clamp(ring * inFan * born * pulse.y * lamp.z * 0.8, 0.0, 0.48));
        }
        metal = mix(metal, colSky.rgb, wip * 0.65 * gauss(max(s, 0.0), 1.7));       // still bright from the heat
        // the rim: a thin bevel
        float bev = 1.0 - smoothstep(0.0, 0.30, e);
        float lit = dot(n, lamp.xy);
        metal = mix(metal, colHot.rgb, bev * max(lit, 0.0) * 0.80);
        metal = mix(metal, colDeep.rgb * 0.72, bev * max(-lit, 0.0) * 0.85);
        metal *= 1.0 - 0.34 * wip * gauss(s - 0.34, 0.17);                         // the narrow darker edge behind the front
    } else {
        // a drafted plate: the wash, a fine diagonal hatch, a double frame
        metal = mix(colPaper.rgb, colBase.rgb, 0.62);
        float h = (fract((p.x + p.y) / 0.72) - 0.5) * 0.72;
        metal = mix(metal, colDeep.rgb, lineCov(h, 0.03, aa) * 0.34);
        metal = mix(metal, colPaper.rgb, 0.5 * (1.0 - smoothstep(0.75, 1.05, e)));  // the frame's own margin stays clear of the hatch
        metal = mix(metal, colInk.rgb, max(lineCov(e - 0.30, 0.07, aa), lineCov(e - 0.56, 0.035, aa)) * 0.92);     // (both inside the label's 0.9 mm margin: the inner line once ran through the head's caps)
    }

    vec3 col = mix(paper, metal, m);
    // the hot line ON the front (2-3 device px wide)
    float hw = max(0.11, 1.25 * aa);
    col = mix(col, colHot.rgb, gauss(s, hw) * wip * (blueprint ? 0.9 : 0.96));
    fragColor = vec4(col, 1.0) * cover * qt_Opacity;
}
