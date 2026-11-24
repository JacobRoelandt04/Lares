// =============================================================================
// holo_common.glsl -- what every hologram shares (spliced into silicon_holo.frag by
// tools/dev/silicon_shader_gen.js).
//
// In:  the uniforms (silicon_holo.frag.in).
// Out: noise and shape helpers, the ink colours, the glitch (the de-rez), the entrance curve, the
//      steady flicker and scanlines, the projector cone, the lens glow, the corner brackets.
//
// PHOTOSENSITIVITY, in one place. The steady state's fastest oscillators are the 1.57 Hz flicker
// (2 % swing) and the 0.83 Hz one (3 %); the hiccup (a 5 % dip, 0.75 s wide) comes every 6 s; a
// scanline passes a pixel at 0.55 Hz; the scan band crosses once in 6 s. The flicker's three terms
// sum to at most 10 % of the hologram's own luminance, and the hologram is a translucent object a
// few hundred px across. The entrance has three dips in its ~0.5 s (once per popup open); the de-rez moves slice by
// slice (1.7 mm bands switch at their own moment), never the whole field at once.
//
// The additions keep to it (nothing flashes): the shock's scope trace moves at 0.11 and 0.22 Hz and is a thin faint line; the dials turn at 1.4 ticks a second; the beam's swell passes a pixel at
// about one in 2 s (2.4 mm/s over 5 mm cells) and varies the core by 22 %; the armillary turns at the pace of a clock's second hand or slower. Every EVENT is multiplied
// by `liveP.x`, so a halted hologram is the plain still picture.
// =============================================================================

const float PI = 3.14159265;
const float TAU = 6.2831853;
const float SQ3 = 1.7320508;

float gAA;        // an antialiasing half-width, mm (set in main)
float gDark;      // 1 on the dark theme

// ---- noise ----------------------------------------------------------------------------------
float hash11(float x) {
    return fract(sin(x * 12.9898 + 4.1414) * 43758.5453);
}
float hash21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float vn1(float x) {
    float i = floor(x);
    float f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash11(i), hash11(i + 1.0), f);
}
float vn2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x), mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// ---- shapes ---------------------------------------------------------------------------------
vec2 rot(vec2 p, float a) {               // rotate a point counter-clockwise by a
    float c = cos(a), s = sin(a);
    return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}
float sdSeg(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}
float sdBox2(vec2 p, vec2 b) {
    vec2 d = abs(p) - b;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
// coverage of a stroke of half width hw whose centre line is at distance d
float strokeCov(float d, float hw) {
    return 1.0 - smoothstep(hw - gAA, hw + gAA, d);
}
float fillCov(float d) {                  // 1 inside (d < 0), antialiased
    return 1.0 - smoothstep(-gAA, gAA, d);
}

// ---- colour ---------------------------------------------------------------------------------
vec3 hueRot(vec3 c, float a) {
    float cs = cos(a), sn = sin(a);
    const vec3 k = vec3(0.57735027);
    return c * cs + cross(k, c) * sn + k * dot(k, c) * (1.0 - cs);
}
// the line colour on this ground: a deep saturated ink on the light theme (it must read on
// #EAEDF5 and on a white solder mask), a brighter one on the dark theme (it glows there)
vec3 inkOf(vec3 c) {
    return mix(c * 0.62, mix(c, vec3(1.0), 0.34), gDark);
}
// the body tint: the colour itself, a touch deeper on the light theme
vec3 bodyOf(vec3 c) {
    return mix(c * 0.90, c, gDark);
}
// premultiplied "over": `a` of colour rgb on top of acc
vec4 inkOver(vec4 acc, vec3 rgb, float a) {
    a = clamp(a, 0.0, 1.0);
    return vec4(rgb * a, a) + acc * (1.0 - a);
}
vec4 over(vec4 top, vec4 bot) {
    return top + bot * (1.0 - top.a);
}

// ---- the entrance: flickers on irregularly, three brief dips, then stable -----------------------
float powerCurve(float h) {
    if (h >= 0.999)
        return 1.0;
    float base = smoothstep(0.0, 0.85, h);
    float dip = 0.55 * exp(-pow((h - 0.28) / 0.065, 2.0)) + 0.45 * exp(-pow((h - 0.50) / 0.055, 2.0)) + 0.30 * exp(-pow((h - 0.70) / 0.05, 2.0));
    return base * (1.0 - dip);
}

// ---- the steady state: a gentle flicker (< 10 % swing, < 3 Hz) ----------------------------------
float flicker() {
    float f1 = 0.5 + 0.5 * sin(TAU * phA.y);
    float f2 = 0.5 + 0.5 * sin(TAU * phA.z);
    float hic = pow(0.5 + 0.5 * sin(TAU * phA.w), 18.0);
    // worst case (all three at once): 10 %; the idle ladder's `live` eases it to nothing on the way to
    // halt, so a halted hologram stands at its full brightness and not wherever the flicker stopped.
    // `liveP.y` is the hologram's BREATH (the GPU's, while a MUX request waits for its restart): one slow
    // brightness factor on the light of the whole hologram, whatever the dGPU's wakefulness dims it to.
    return (1.0 - liveP.x * (0.030 * f1 + 0.020 * f2 + 0.050 * hic)) * liveP.y;
}
// thin scanlines drifting up the plane (v: mm up the plane), and a slow soft band that crosses it
float scanlines(float v) {
    float sc = fract(v / 1.5 - phA.x);
    float line = pow(1.0 - abs(2.0 * sc - 1.0), 5.0);       // thin peaks
    float band = exp(-pow((fract(v / 64.0 - phA.w - 0.5) - 0.5) * 64.0 / 7.0, 2.0));
    return 1.0 - liveP.x * (look2.z * line - look2.w * band);       // at rest (live 0): no scan at all
}

// ---- the glitch: the de-rez, and presence scanning in -------------------------------------------
struct Glitch {
    vec2 uv;        // where the picture is sampled (mm)
    float keep;     // how much of this slice's picture shows, 0..1
    float next;     // 1 when this slice already shows the NEXT picture
    float colMix;   // 0..1 the colour on its way to the next
    float amp;      // 0..1 how hard the glitch is (the chromatic split follows)
};

Glitch glitchOf(vec2 uv, float derez, float presence) {
    Glitch g;
    g.uv = uv;
    g.keep = 1.0;
    g.next = derez > 0.9999 ? 1.0 : 0.0;
    g.colMix = derez > 0.9999 ? 1.0 : 0.0;
    g.amp = 0.0;
    float sid = floor(uv.y / 1.7);
    float h1 = hash11(sid * 1.37 + 0.11);
    float h2 = hash11(sid * 2.91 + 7.3);
    float h3 = hash11(floor(uv.y / 6.8) * 3.7 + 1.9);
    if (derez > 0.0001 && derez < 0.9999) {
        float amp = pow(sin(PI * derez), 1.3);
        g.amp = amp;
        // each slice swaps from the old picture to the new at its own moment around the middle
        float ts = 0.5 + (h1 - 0.5) * 0.42;
        g.next = derez >= ts ? 1.0 : 0.0;
        g.colMix = smoothstep(0.34, 0.66, derez + (h1 - 0.5) * 0.24);
        // slice displacement: smooth in derez, harder near the slice's own swap
        float sgn = (vn2(vec2(sid * 0.73, derez * 2.0)) - 0.5) * 2.0;
        float disp = sgn * amp * (0.8 + 3.0 * h3 * h3);
        disp += exp(-pow((derez - ts) / 0.06, 2.0)) * (h2 - 0.5) * 6.0;
        g.uv.x += clamp(disp, -4.5, 4.5);                       // the item's rect has 2.9 mm of room past the plane
        // block pixelation, staggered by slice
        float blockOn = smoothstep(0.30 + 0.30 * h2, 0.58 + 0.30 * h2, amp);
        float blk = mix(0.05, 2.6, blockOn * blockOn);
        g.uv = (floor(g.uv / blk) + 0.5) * blk;
        // the picture breaks into scanline fragments: a share of the slices drop out, leaving dashes
        float dropFrac = smoothstep(0.28, 1.0, amp) * 0.62;
        float keep = smoothstep(dropFrac - 0.06, dropFrac + 0.06, h2);
        float dash = step(0.5, fract(uv.x / 3.4 + h1));
        g.keep = max(keep, 0.34 * dash * smoothstep(0.1, 0.5, amp));
    }
    // presence: the slices scan in and out at their own moments
    g.keep *= smoothstep(0.0, 0.30, presence * 1.30 - h2 * 0.30);
    return g;
}

// ---- the projector: a cone of light from the anchor, widening upward -----------------------------
// Volumetric: the view ray is integrated through a soft-edged cone (radius r0 + k h at height h
// above the anchor) in 12 steps. Pulses of light climb it at the beam's own tempo.
float coneHaze(vec3 ro, vec3 rd, vec3 A, float hTop, float r0, float k) {
    float rMax = r0 + k * hTop + 1.0;
    // the slab: heights A.y .. A.y + hTop (rd.y < 0: the top is met first)
    float tTop = (A.y + hTop - ro.y) / rd.y;
    float tBot = (A.y - ro.y) / rd.y;
    // the bounding cylinder
    vec2 o = ro.xz - A.xz;
    vec2 d = rd.xz;
    float a = dot(d, d);
    float b = dot(o, d);
    float c = dot(o, o) - rMax * rMax;
    float disc = b * b - a * c;
    if (disc <= 0.0)
        return 0.0;
    float sq = sqrt(disc);
    float t0 = max(tTop, (-b - sq) / a);
    float t1 = min(tBot, (-b + sq) / a);
    if (t1 <= t0)
        return 0.0;
    float dt = (t1 - t0) / 12.0;
    float acc = 0.0;
    for (int i = 0; i < 12; i++) {
        float t = t0 + (float(i) + 0.5) * dt;
        vec3 p = ro + rd * t;
        float h = p.y - A.y;
        float rad = r0 + k * h;
        float rr = length(p.xz - A.xz) / rad;
        float rr2 = rr * rr;
        float dens = exp(-rr2 * rr2 * 3.0) * (0.30 + 0.60 * exp(-rr2 * 2.0) + 0.55 * exp(-pow((rr - 0.88) / 0.14, 2.0)));   // a soft core, and a brighter limb at the cone's edge
        dens *= 1.0 / (1.0 + (h / 42.0) * (h / 42.0));
        dens *= 1.0 + 2.2 * exp(-h / 3.5);                           // the lens end is the brightest
        dens *= 1.0 - smoothstep(hTop - 10.0, hTop, h);              // out at the top
        float ring = pow(0.5 + 0.5 * sin(TAU * (h / 15.0 - phC.w)), 8.0);
        dens *= 1.0 + 0.55 * ring;
        acc += dens * dt;
    }
    return acc;
}

// the emitter's lens on the package or die top: a soft disc and a thin ring in the horizontal plane at A.y.
// Its radii are SceneGeometry.LENS (the generated LENS_* constants): IsoCamera.beamRect pads the beam's rect by them.
// The circles that are the base of a hologram's projection are faint, and when the rendering has frozen they disappear entirely, since they look weird
// without particles: the lens is `liveP.z` (HoloLayer.lensStrength, 0.5 = half strength) of its full strength, times the idle ladder's `live` like every
// motion of the scene, so it fades out with the particles and is gone at halt.
float lensGlow(vec3 ro, vec3 rd, vec3 A, float r, float discK, float ringK) {
    float t = (A.y - ro.y) / rd.y;
    vec3 p = ro + rd * t;
    float d = length(p.xz - A.xz);
    float disc = exp(-pow(d / (r * LENS_DISC), 2.0));
    float ring = exp(-pow((d - r) / LENS_RING_FALL, 2.0));
    return (discK * disc + ringK * ring) * liveP.x * liveP.z;
}

// the plane's corner brackets (a 4 mm L at each corner, 1.8 mm inside the plane's edge)
float cornerBrackets(vec2 pl) {              // pl: mm from the plane's centre (u, v)
    vec2 a = abs(pl) - vec2(plane.x * 0.5 - 1.8, plane.z * 0.5 - 1.8);
    float armA = sdBox2(vec2(a.x, a.y + 2.0), vec2(0.14, 2.0));
    float armB = sdBox2(vec2(a.x + 2.0, a.y), vec2(2.0, 0.14));
    return strokeCov(min(armA, armB), 0.02);
}

// the view ray of a screen point (mm): origin 600 mm out toward the camera, direction -CAM_C
vec3 rayOrigin(vec2 scr) {
    return scr.x * CAM_R + scr.y * CAM_U + CAM_C * 600.0;
}
