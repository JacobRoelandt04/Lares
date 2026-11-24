#version 440

// =============================================================================
// weather_backdrop_v2.frag -- the hero card's backdrop, v2.
//
// ONE SCENE, A RECIPE PER KIND. v1 drew each kind as one flat layer; here
// every kind is a composition of the same stages -- sky tint, sun or moon,
// stars, clouds, rain curtains, fog banks, falling particles, drops on the
// glass, air, lightning -- and WeatherBackdrop.qml hands the shader the kind's
// RECIPE (the vec4s `sky` .. `deck3`: how much of each stage). Each stage is
// written once and skipped by a uniform branch when its amount is 0.
//
// ONE COPY OF EACH THING. Every repeated element -- the two cloud layers, the
// three star layers, the eleven particle layers, the three fog banks, the two
// air layers, the bolt's two channels -- runs in a loop whose trip count is a
// UNIFORM (`loops`, `loops2`: the recipe's layer counts), so the compiler
// cannot unroll it and keeps ONE copy of its body (unrolled, a noise stack is
// inlined per call site -- 11.5k instructions -- and a bound the compiler can
// prove, like `sky.z > 0.0 ? 3 : 0`, is unrolled). A
// layer's parameters come from an if-chain on the index, never from an array
// (CLAUDE.md: a scratch array indexed by a loop counter is spilled on iris).
//
// STATELESS, like v1: everything is a function of (pixel, time), so the host
// runs it from a Timer at ambientHz with one uniform write per tick.
//
// THE MATERIAL. Every form has a lit side and a shaded side, the shell's
// bevel-and-shadow language. On the LIGHT card white has no room above the
// fill (+0.08 at most), so forms there are carried by shade and hue -- grey
// cloud bodies with white crowns, warm tint for sunlight, violet for night;
// on the DARK card by light. `dark` picks each stage's pair of alphas.
//
// DEPTH. Everything that repeats comes in layers (far: small, sharp, slow,
// faint; near: big, soft, fast), each on its own jittered lattice at its own
// pitch, so the layers slide past each other and no lattice shows.
//
// CONTRAST. Hues arrive as vec4(rgb, gain) as in v1 (gain = 0.24 /
// |luma(hue) - luma(card)|, clamped). The scene is then passed through a
// TONE LIMITER: its luminance change against the card (`cCard`) passes as it
// is up to `toneKnee` and is eased into `toneCap` above it, so the figures on
// top keep their contrast whatever a recipe stacks. POINT LIGHTS (star
// cores, a meteor's head, glints) are kept in their own layer and laid over
// the limited scene under their own ceiling, `sparkCap`: a point is not an
// area anything is read on, and a star held to the area bound is a grey dot.
// The strike comes last and is exempt (the flash is MEANT to lift the card).
//
// LIGHT MODE IS A SKY. On the light card white has
// +0.08 of room, so what the dark card draws as light -- pollen in the glare,
// most stars, the strike -- would vanish. In light mode the backdrop therefore
// paints the kind's sky as `ground`, opaque, under the scene: a tint well
// under the surface by day, dusk indigo at night, slate in a storm. On a dark
// sky the host hands over the theme's dark half and `dark` = 1, so the night
// and the storm are drawn exactly as on the dark card; on a light one
// `lightRoom` lets the dark card's point lights (a mote's sparkle, a flake's
// heart) in, since white has room there. In dark mode both are 0.
// THE NEUTRAL STORM: `cStorm` is slate, the bolt a white core with a
// blue-white glow (`cBolt`) in both themes.
//
// Output is PREMULTIPLIED; `strength` and qt_Opacity scale the whole vec4
// (over a ground: the scene over it, opaque).
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  cSun;     // warm light: the glare's tint, shafts, motes
    vec4  cGlow;    // the sun's deeper warmth, at the core
    vec4  cLight;   // the lit side of everything
    vec4  cCloud;   // cloud body
    vec4  cShade;   // cloud shade
    vec4  cRain;
    vec4  cSnow;
    vec4  cHail;
    vec4  cStorm;
    vec4  cFog;
    vec4  cNight;
    vec4  cStar;
    vec4  cBolt;    // the strike's glow (its core is white)
    vec4  cDeep;    // the card's own deepest shade (darker than a dark card)
    vec4  cCard;    // the ground under the effect (rgb), for the limiter
    vec4  cWind;    // the air's trails
    vec4  sky;      // x sun, y moon, z stars, w milky way
    vec4  deck;     // x cover, y heaviness, z ceiling depth (0: none), w churn
    vec4  deck2;    // x far layer, y scale (px), z drift (px/s, signed), w veil
    vec4  deck3;    // x cumulus (1: rows of cumulus, 0: a sheet), y perspective
    vec4  precip;   // x rain, y snow, z hail, w wet flakes
    vec4  extra;    // x glass, y fog, z wind, w storm
    vec4  extra2;   // x mist, y curtains, z motes
    vec4  loops;    // the recipe's layer counts: x cloud layers, y star layers,
                    // z..w the particle layers [first, end)
    vec4  loops2;   // x fog banks, y air layers, z bolt channels
    vec4  octaves;  // fbm octave counts: x cloud shape, y a sheet's light
                    // sample, z milky way and fog (a uniform, so each fbm is
                    // one noise in a loop and not one per octave)
    vec2  size;     // the item, px
    vec2  slant;    // x: rain dx per px of fall; y: the same for snow
    float time;     // seconds, wrapped at 3600
    float strength;
    float flash;
    float flashSeed;
    float precipOn; // 0 while the canvas renderer draws the precipitation
    float windSpeed;// px/s, signed: positive blows right
    float cornerRadius;
    float dark;     // 1 on a dark card, 0 on a light one
    float toneKnee;
    float toneCap;
    float sparkCap;
    vec4  ground;    // light mode: the sky painted UNDER the scene, opaque when
                     // a is 1; a 0 draws over the host's card (dark mode)
    float lightRoom; // 1 on a light sky: the dark card's point lights are drawn
};

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

// -----------------------------------------------------------------------------
// noise
// -----------------------------------------------------------------------------
// Dave Hoskins' sin-free hashes: stable for the large lattice indices a
// scrolling field reaches within the hour.
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
float hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

// 2D simplex noise, -1..1: three corners, no axis-aligned grain.
float snoise(vec2 p) {
    const float K1 = 0.366025404;
    const float K2 = 0.211324865;
    vec2 i = floor(p + (p.x + p.y) * K1);
    vec2 a = p - i + (i.x + i.y) * K2;
    float m = step(a.y, a.x);
    vec2 o = vec2(m, 1.0 - m);
    vec2 b = a - o + K2;
    vec2 c = a - 1.0 + 2.0 * K2;
    vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    vec3 n = h * h * h * h * vec3(dot(a, hash22(i) * 2.0 - 1.0),
                                  dot(b, hash22(i + o) * 2.0 - 1.0),
                                  dot(c, hash22(i + 1.0) * 2.0 - 1.0));
    return dot(n, vec3(70.0));
}

// 1D value noise, 0..1.
float noise1(float x) {
    float i = floor(x);
    float f = x - i;
    return mix(hash11(i), hash11(i + 1.0), f * f * (3.0 - 2.0 * f));
}

// fbm with a rotating octave matrix (drift's "2D Clouds"): each octave is
// turned ~37 degrees against the last, so no direction is preferred.
// `billowy` 1 sums |noise| instead (billows: rounded bumps split by creases,
// a cumulus crown). `low` returns the first two octaves' sum. Callers pass a
// count from the `octaves` uniform, which keeps this loop a loop.
const mat2 OCT = mat2(1.6, 1.2, -1.2, 1.6);
float fbm(vec2 p, int octaves, float billowy, out float low) {
    float s = 0.0;
    float a = 0.52;
    low = 0.0;
    for (int i = 0; i < octaves; i++) {
        float n = snoise(p);
        s += a * mix(n, abs(n), billowy);
        if (i == 1)
            low = s;
        p = OCT * p + vec2(1.7, 9.2);
        a *= mix(0.5, 0.42, billowy);
    }
    return s;
}

float sdRoundBox(vec2 p, vec2 h, float r) {
    vec2 q = abs(p) - h + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Premultiplied `over`.
vec4 over(vec4 acc, vec3 rgb, float a) {
    a = clamp(a, 0.0, 1.0);
    return acc * (1.0 - a) + vec4(rgb * a, a);
}
// A hue at an alpha, with its contrast gain.
vec4 ink(vec4 acc, vec4 hue, float a) {
    return over(acc, hue.rgb, a * hue.a);
}
// Two hues mixed (rgb and gain alike).
vec4 mixHue(vec4 a, vec4 b, float k) {
    return mix(a, b, clamp(k, 0.0, 1.0));
}

// -----------------------------------------------------------------------------
// clouds
// -----------------------------------------------------------------------------
// A cloud layer. Two forms:
//
// CUMULUS (deck3.x = 1): a row standing on a base line. The silhouette is a
// 1D height field -- where the clouds are and how tall: domes from three
// octaves of 1D noise -- with billows on the outline (the cauliflower), the
// field read a little to the side by the billows so the flanks are lumpy
// too, and a nearly flat base. `lit`: the crown bright, the base in the
// cloud's own shadow, the side facing the light a little brighter.
//
// SHEET (deck3.x = 0): overcast, or the ceiling of rain, snow and storms --
// soft fbm masses, gently warped and turning over on their own (`deck.w`),
// lit from above (the low octaves compared with themselves a few px higher),
// optionally in perspective (deck3.y): a plane overhead receding to a horizon
// below the card, cells big at the top and crowding toward the foot. No
// billows in a sheet: lit creases read as crumpled paper or a relief map.
float cloudLayer(vec2 p, bool far, vec2 toLight, float t, out float lit)
{
    float H = size.y;
    float lam = deck2.y;
    float drift = deck2.z * (far ? 0.45 : 1.0);
    float seed = far ? 3.0 : 11.0;
    bool cumulus = deck3.x > 0.5;
    // One fbm for both forms (one copy of its noise): billows for a cumulus
    // outline, smooth for a sheet.
    float l = lam * (cumulus ? (far ? 1.1 : 2.0) : (far ? 0.65 : 1.1));
    float x = p.x - t * drift;
    vec2 q;
    float baseY = H * (far ? 0.50 : 0.86);
    if (cumulus) {
        // The billows vary with y at 0.7 of their x rate, and move the
        // outline by at most half the dome's height: the outline is
        // top(x, y), and where it moves faster than 1 px per px of y the
        // tallest billows close into islands floating above the crown (lit,
        // soap bubbles); slower still and they streak into vertical drips.
        q = vec2(x, baseY + (p.y - baseY) * 0.7) / (l * 0.22) + seed * 5.0 + vec2(0.0, t * deck.w);
    } else {
        if (deck3.y > 0.0) {
            float z = 1.0 / (1.0 + deck3.y - p.y / H);
            // Across, only half the perspective: the full fan reads as a
            // zoom blur at the card's ends.
            float zx = mix(1.0 / (1.0 + deck3.y), z, 0.5);
            q = vec2(((p.x - size.x * 0.5) * zx - t * drift) / (l * 1.3), z * H / l * 1.25) + seed;
        } else {
            q = vec2(x / (l * 1.3), p.y / l) + seed;
        }
        q.x += 0.20 * snoise(q * 0.45 + vec2(0.0, t * deck.w));
        q *= 0.8;
    }
    float lo;
    float n = fbm(q, int(octaves.x), cumulus ? 1.0 : 0.0, lo);
    if (cumulus) {
        float hMax = H * (far ? 0.30 : 0.60);
        float cover = deck.x * (far ? 0.9 : 1.0);
        float xh = x + (n - 0.3) * l * 0.22;
        float m = smoothstep(1.0 - cover, 1.35 - cover,
                             noise1(xh / l + seed) * 0.55 + noise1(xh / (l * 0.41) + seed * 1.7) * 0.30
                             + noise1(xh / (l * 0.17) + seed * 2.3) * 0.15);
        float h = hMax * pow(m, 0.8);
        float top = baseY - h * (0.80 + 0.50 * n);
        float bottom = baseY + 10.0 * (noise1(x / 38.0 + seed) - 0.5) + 3.0;
        float soft = 2.5 + 0.06 * h;
        float cov = smoothstep(-soft * 0.4, soft, p.y - top) * smoothstep(-soft * 0.4, soft * 1.8, bottom - p.y);
        cov *= smoothstep(1.0, 7.0, h);
        float v = clamp((p.y - top) / max(bottom - top, 1.0), 0.0, 1.0);
        float base = smoothstep(0.62, 1.0, v);
        float side = clamp(0.5 + 1.5 * (n - 0.3) * sign(toLight.x), 0.0, 1.0);
        // On the light card the crown is a crisp white band at the top; on a
        // dark one the light falls off over the whole cloud, and its outer
        // few px are thinner (translucent) than just inside -- lit to the
        // very edge, a dark-mode cumulus reads as a glowing outline.
        float crown = 1.0 - smoothstep(0.0, mix(0.5, 0.85, dark), v);
        float inner = smoothstep(0.0, 6.0, p.y - top);
        lit = clamp(crown * 0.9 + side * 0.2 - base * 0.5, 0.0, 1.0) * mix(1.0, 0.5 + 0.5 * inner, dark);
        return cov;
    }
    float la;
    fbm(q - vec2(0.0, 5.6 / l), int(octaves.y), 0.0, la);
    float th = 0.18 - 0.7 * deck.x;
    lit = clamp(0.45 + (lo - la) * 7.0, 0.0, 1.0) * (0.6 + 0.4 * smoothstep(th, th + 0.6, n));
    // A sheet's light is a gentle modulation, not a cumulus crown.
    lit = 0.3 + (far ? 0.45 : 0.5) * lit;
    return smoothstep(th, th + 0.45, n);
}

// A cloud's material over the card. On the light card the form is carried by
// SHADE -- a grey body, heavier where the cloud is in its own shadow -- and a
// white crown; on a dark card by LIGHT -- the body brighter where lit, the
// crown brighter still, and a storm's belly darker than the card itself.
// `storm` (0..1) darkens and cools it; `amt` scales it all.
vec4 cloudInk(vec4 acc, float cov, float lit, float storm, float amt) {
    float sh = 1.0 - lit;
    float a = cov * amt;
    // A thunderstorm's deck takes a touch of the storm hue; rain's stays grey.
    vec4 bodyL = mixHue(mixHue(cCloud, cShade, storm * 0.5), cStorm, extra.w * 0.35);
    vec4 bodyD = mixHue(cCloud, cShade, 0.35 + 0.45 * storm);
    vec4 body = mixHue(bodyL, bodyD, dark);
    float aBody = mix(0.10 + 0.24 * sh + 0.06 * storm,
                      (0.03 + 0.26 * lit * lit) * (1.0 - 0.7 * storm), dark);
    float aDeep = dark * storm * (0.20 + 0.35 * sh);
    float aRim = lit * lit * mix(0.90 - 0.55 * storm, 0.60 - 0.35 * storm, dark);
    acc = ink(acc, body, a * aBody);
    acc = ink(acc, cDeep, a * aDeep);
    return ink(acc, cLight, a * aRim);
}

// -----------------------------------------------------------------------------
// particles
// -----------------------------------------------------------------------------
// One layer of falling particles on a jittered lattice in the fall frame:
// columns `cw` wide across `dir`, cells `ch` long along it, one particle per
// cell where the cell's hash is under `density`, every column offset along
// the fall by its own hash so no row lines up. The particle is a capsule
// `len` long (0: a disc) of radius `rad`, `soft` px of feather; `sway` px of
// sideways drift on its own phase; `bob` px of drift ALONG the fall, slow and
// on its own phase, so a particle now and then floats back against it (pollen
// riding an updraft) while its layer settles -- held inside the cell's margins
// like the sway, so it is never cut at a cell's edge. Returns the coverage in .x, how far along
// the capsule the pixel is (0 tail .. 1 head) in .y, and the distance to the
// head's centre in .z (a glint is a point there, not the whole head).
vec3 fallLayer(vec2 p, vec2 dir, float cw, float ch, float speed, float len, float rad,
               float soft, float density, float sway, float bob, float seed, float t)
{
    vec2 perp = vec2(-dir.y, dir.x);
    float u = dot(p, dir) - t * speed;
    float v = dot(p, perp);
    float col = floor(v / cw);
    float cv = v - col * cw;
    float uu = u + hash12(vec2(col, seed)) * ch * 7.0;
    float row = floor(uu / ch);
    float cu = uu - row * ch;
    vec2 id = vec2(col, row) + seed * 13.7;
    vec2 h = hash22(id);
    float present = step(hash12(id + 7.3), density);
    float m = rad + soft + sway + 1.0;
    float pv = m + h.x * max(0.0, cw - 2.0 * m);
    pv += sway * sin(t * (0.9 + 0.8 * h.y) + h.x * 6.2831853);
    // pu is the head (the leading end: larger u is further along the fall).
    float mu = rad + soft + 1.0 + bob;
    float pu = mu + len + h.y * max(0.0, ch - len - 2.0 * mu);
    pu -= bob * sin(t * (0.22 + 0.3 * h.x) + h.y * 18.849556);
    float along = clamp(cu, pu - len, pu);
    float d = length(vec2(cu - along, cv - pv));
    float cov = 1.0 - smoothstep(rad - soft * 0.5, rad + soft, d);
    float k = len > 0.0 ? (along - (pu - len)) / len : 1.0;
    return vec3(cov * present, k, present > 0.5 ? length(vec2(cu - pu, cv - pv)) : 1e3);
}

// -----------------------------------------------------------------------------
// the sky
// -----------------------------------------------------------------------------
// Stars: one per `cell` px cell where present, jittered inside it, twinkling
// on its own phase with a fast scintillation on top; `spike` > 0 adds soft
// four-point diffraction spikes. .x the core (a point light), .y the halo and
// spikes (an area: under the limiter), .z colour temperature (0..1).
vec3 starLayer(vec2 p, float cell, float presence, float rMin, float rMax, float spike,
               float seed, float t)
{
    vec2 c = floor(p / cell);
    vec2 f = p - c * cell;
    vec2 h = hash22(c + seed);
    float h3 = hash12(c + seed + 17.1);
    float m = rMax * 3.0 + 1.0;
    vec2 sp = vec2(m) + h * max(vec2(0.0), vec2(cell - 2.0 * m));
    vec2 dv = f - sp;
    float d = length(dv);
    float r = mix(rMin, rMax, h3 * h3);
    float tw = 0.55 + 0.45 * sin(t * (0.5 + 1.5 * h.x) + h.y * 6.2831853);
    tw *= 0.85 + 0.15 * sin(t * (7.0 + 5.0 * h3) + h.x * 40.0);
    // The core is a point (a px or two at most); the rest of the star's
    // light is its halo.
    float core = 1.0 - smoothstep(r * 0.25, r * 0.25 + 0.8, d);
    float halo = (1.0 - smoothstep(r * 0.5, r + 0.7, d)) * 0.45 + exp(-d / (r * 2.5)) * 0.35;
    float sp4 = exp(-abs(dv.x) * 1.4) * exp(-abs(dv.y) / (r * 3.5))
              + exp(-abs(dv.y) * 1.4) * exp(-abs(dv.x) / (r * 3.5));
    float on = tw * step(hash12(c + seed + 3.3), presence);
    return vec3(core * on, min(1.0, halo + sp4 * spike * tw) * on, h.y);
}

// A shooting star: in each 13 s window, most windows hold one, at a hashed
// moment, from a hashed spot in the upper half, 0.9 s across ~230 px.
float meteor(vec2 p, float t) {
    float win = floor(t / 13.0);
    float h0 = hash11(win * 1.37 + 0.5);
    float ts = win * 13.0 + 1.0 + 10.0 * hash11(win + 3.1);
    float tau = (t - ts) / 0.9;
    if (h0 > 0.7 || tau < 0.0 || tau > 1.0)
        return 0.0;
    float side = hash11(win + 7.7) < 0.5 ? -1.0 : 1.0;
    float ang = radians(18.0 + 20.0 * hash11(win + 9.2));
    vec2 dir = vec2(side * cos(ang), sin(ang));
    vec2 s = vec2(size.x * (0.2 + 0.6 * hash11(win + 5.5)), size.y * (0.05 + 0.3 * hash11(win + 2.4)));
    s -= dir * 60.0;
    float e = tau * tau * (3.0 - 2.0 * tau);
    vec2 head = s + dir * 230.0 * e;
    vec2 tail = head - dir * (20.0 + 70.0 * sin(3.14159 * tau));
    vec2 pa = p - tail;
    vec2 ba = head - tail;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    float d = length(pa - ba * h);
    float line = (1.0 - smoothstep(0.3, 1.4, d)) * h * h + exp(-d / 2.5) * 0.25 * h;
    float fade = smoothstep(0.0, 0.15, tau) * (1.0 - smoothstep(0.7, 1.0, tau));
    return line * fade;
}

// -----------------------------------------------------------------------------
// lightning
// -----------------------------------------------------------------------------
// The channel's x at height y: a lean plus three octaves of 1D noise (the
// midpoint-displacement look of a real bolt: big wanders, small kinks).
// `fine` 0 leaves the kinks out: the smooth path the glow follows.
float boltX(float y, float x0, float lean, float seed, float fine) {
    return x0 + lean * y
         + 34.0 * (noise1(y / 46.0 + seed * 11.0) - 0.5)
         + 14.0 * (noise1(y / 15.0 + seed * 23.0) - 0.5)
         + 5.0 * fine * (noise1(y / 5.0 + seed * 37.0) - 0.5);
}

// -----------------------------------------------------------------------------
void main() {
    vec2 p = qt_TexCoord0 * size;
    float t = time;
    float W = size.x;
    float H = size.y;
    vec4 acc = vec4(0.0);
    vec4 spark = vec4(0.0);

    vec2 sunAt = vec2(-30.0, -48.0);
    vec2 moonAt = vec2(W + 26.0, -34.0);
    float drift = deck2.z;
    float dirX = drift < 0.0 ? -1.0 : 1.0;

    // ---- sky tint: a veil, heavier at the top (a lid of weather) -------------
    if (deck2.w > 0.0) {
        float lid = mix(1.0, 0.45, smoothstep(0.0, H, p.y));
        acc = ink(acc, mixHue(cShade, cStorm, deck.y * 0.35), deck2.w * lid);
    }

    // ---- the cloud layers first: the sky behind them needs their cover --------
    float covA = 0.0, litA = 0.0;   // the far layer
    float covC = 0.0, litC = 0.0;   // the near layer
    if (deck.x > 0.0) {
        // Light comes from the sun's corner, the moon's, or straight above.
        vec2 toLight = sky.x > 0.0 ? normalize(sunAt - p) : (sky.y > 0.0 ? normalize(moonAt - p) : vec2(0.0, -1.0));
        // A ceiling reaching `deck.z` of the way down has a ragged, soft foot
        // (fractus), not a line; the far layer's foot sits higher.
        float foot = 1.0;
        float footB = 1.0;
        if (deck.z > 0.0) {
            float y = p.y / H + (noise1((p.x - t * drift * 1.4) / 60.0) - 0.5) * 0.30
                              + (noise1((p.x - t * drift * 1.4) / 17.0 + 5.0) - 0.5) * 0.12;
            foot = 1.0 - smoothstep(deck.z - 0.20, deck.z + 0.08, y);
            footB = 1.0 - smoothstep(deck.z * 0.75 - 0.15, deck.z * 0.75 + 0.10, y);
        }
        int nC = int(loops.x);
        for (int i = 0; i < nC; i++) {
            bool far = i == 0 && nC == 2;
            float f = deck3.x > 0.5 ? 1.0 : (far ? footB : foot);
            float lit;
            float cov = cloudLayer(p, far, toLight, t, lit) * f;
            if (far) {
                covA = cov;
                litA = lit;
            } else {
                covC = cov;
                litC = lit;
            }
        }
    }
    // What hides the sky behind: stars and shafts go behind the near layer.
    float cloudCov = max(covC, covA * (deck3.x > 0.5 ? 0.0 : 0.8));

    // ---- sun: glare, shafts, lens ghosts ------------------------------------------
    float light = 0.0;      // the light field, for the motes
    float shafts = 0.0;
    if (sky.x > 0.0) {
        vec2 q = p - sunAt;
        float r = length(q);
        float ang = atan(q.y, q.x);
        float wash = exp(-r / 230.0);
        float core = exp(-r / 85.0);
        // Shafts: broad and soft -- two octaves of angular noise drifting
        // apart (the shimmer), each broken along its length by a slower
        // radial noise, so no shaft is a clean wedge.
        float ra = noise1(ang * 7.0 + t * 0.03);
        float rb = noise1(ang * 13.0 - t * 0.021 + 40.0);
        float along = 0.55 + 0.45 * snoise(vec2(ang * 5.0, r / 190.0 - t * 0.04));
        shafts = (smoothstep(0.35, 1.0, ra) * 0.7 + smoothstep(0.45, 1.0, rb) * 0.4) * along;
        shafts *= smoothstep(30.0, 150.0, r) * exp(-r / 380.0) * (1.0 - cloudCov);
        // The sky away from the sun: a cool blue deepening toward the far
        // corner, so the card reads warm-to-cool, lit from one side.
        float away = smoothstep(W * 0.25, W * 1.1, length(p - sunAt));
        acc = ink(acc, mixHue(cRain, cNight, 0.5), away * mix(0.10, 0.07, dark) * sky.x);
        // The warmth IS the light on a light card (white has no room above
        // it); on a dark one the glare is white-hot and only its fringe warm
        // (orange at a low alpha over grey is mud).
        acc = ink(acc, mixHue(cSun, mixHue(cSun, cLight, 0.3), dark), wash * mix(0.40, 0.42, dark) * sky.x);
        acc = ink(acc, cGlow, core * mix(0.12, 0.05, dark) * sky.x);
        acc = ink(acc, cLight, core * mix(0.90, 0.60, dark) * sky.x);
        light = wash * 0.6 + shafts;
    }

    // ---- moon: the night sky's tint, the glow, a halo ---------------------------------
    if (sky.y > 0.0) {
        float r = length(p - moonAt);
        acc = ink(acc, cNight, (1.0 - smoothstep(0.0, H * 1.1, p.y)) * mix(0.16, 0.10, dark) * sky.y);
        acc = ink(acc, cNight, exp(-r / 160.0) * mix(0.30, 0.22, dark) * sky.y);
        acc = ink(acc, cLight, exp(-r / 60.0) * mix(0.85, 0.32, dark) * sky.y);
        acc = ink(acc, mixHue(cNight, cLight, 0.4), exp(-pow((r - 150.0) / 16.0, 2.0)) * mix(0.10, 0.06, dark) * sky.y);
    }

    // ---- the far layer, the shafts through the gaps -------------------------------
    if (covA > 0.0)
        acc = cloudInk(acc, covA, litA, deck.y * (deck3.x > 0.5 ? 1.0 : 0.8), deck3.x > 0.5 ? 0.55 * deck2.x : 0.6);
    if (shafts > 0.0)
        // On the light card a shaft is WHITE through the warm wash (the only
        // way it can be lighter than what surrounds it); on a dark one, warm.
        acc = ink(acc, mixHue(cSun, cLight, mix(1.0, 0.3, dark)), shafts * mix(0.85, 0.60, dark) * sky.x);

    // ---- stars, the milky way, a meteor ---------------------------------------------
    if (sky.z > 0.0) {
        float clear = (1.0 - cloudCov) * (1.0 - covA * deck2.x * 0.7);
        // The milky way: a soft glowing band from the lower left to the upper
        // right, patchy (isotropic noise: stretched noise reads as wood
        // grain), with one dark rift wandering down its spine; the faint
        // stars crowd into it.
        float band = 0.0;
        if (sky.w > 0.0) {
            vec2 a = vec2(W * 0.08, H * 1.3);
            vec2 ab = normalize(vec2(W * 0.84, -H * 1.8));
            float off = dot(p - a, vec2(-ab.y, ab.x));
            float along = dot(p - a, ab);
            float wob = (noise1(along / 260.0 + 3.0) - 0.5) * 44.0;
            float prof = exp(-pow((off + wob) / 42.0, 2.0));
            float lo;
            float n = fbm(p / 46.0 + vec2(3.0, 7.0), int(octaves.z), 0.0, lo);
            float rift = off + wob - 20.0 * (noise1(along / 90.0 + 9.0) - 0.5);
            float lane = smoothstep(2.0, 16.0, abs(rift));
            band = prof * (0.45 + 0.55 * smoothstep(-0.45, 0.45, n)) * (0.35 + 0.65 * lane);
            acc = ink(acc, mixHue(cNight, cLight, mix(0.2, 0.45, dark)), band * mix(0.14, 0.13, dark) * sky.w * clear);
        }
        // Colour temperature per star, blue-white to warm. On a light card a
        // star is a small sparkle of the night and star hues (white has no
        // room there); on a dark one it is light.
        vec4 warm = mixHue(cStar, mixHue(cLight, cStar, 0.45), dark);
        vec4 cool = mixHue(cNight, mixHue(cLight, cNight, 0.45), dark);
        int nS = int(loops.y);
        for (int i = 0; i < nS; i++) {
            // dust, mid, bright (spiked)
            float cell = i == 0 ? 9.0 : (i == 1 ? 27.0 : 71.0);
            vec2 off = i == 0 ? vec2(0.0) : (i == 1 ? vec2(13.0, 7.0) : vec2(31.0, 19.0));
            float pres = i == 0 ? 0.30 + 0.55 * band : (i == 1 ? 0.55 : 0.45);
            float r0 = i == 0 ? 0.35 : (i == 1 ? 0.6 : 0.9);
            float r1 = i == 0 ? 0.55 : (i == 1 ? 1.0 : 1.6);
            float a = i == 0 ? mix(0.30, 0.45, dark) : (i == 1 ? mix(0.50, 0.75, dark) : mix(0.70, 1.0, dark));
            vec3 s = starLayer(p + off, cell, pres, r0, r1, i == 2 ? 1.0 : 0.0, 1.0 + 4.0 * float(i), t);
            vec4 hue = mixHue(cool, warm, s.z);
            acc = ink(acc, hue, s.y * a * sky.z * clear);
            spark = ink(spark, hue, s.x * a * sky.z * clear);
        }
        spark = ink(spark, mixHue(cNight, cLight, dark), meteor(p, t) * mix(0.8, 1.0, dark) * sky.z * clear);
    }

    // ---- the near layer ----------------------------------------------------------------
    if (covC > 0.0)
        acc = cloudInk(acc, covC, litC, deck.y, 1.0);

    // ---- sheet lightning inside the clouds --------------------------------------------
    if (extra.w > 0.0) {
        // In each 4.7 s window, maybe a double flicker somewhere in the deck,
        // lighting only the cloud that is there.
        float win = floor(t / 4.7);
        float dt = t - (win * 4.7 + 0.5 + 3.5 * hash11(win + 1.9));
        float pulse = hash11(win * 3.3) < 0.65 && dt > 0.0 && dt < 0.45
                    ? exp(-dt * 9.0) + 0.7 * exp(-max(0.0, dt - 0.18) * 11.0) * step(0.18, dt) : 0.0;
        vec2 at = vec2(W * (0.15 + 0.7 * hash11(win + 4.2)), H * (0.05 + 0.25 * hash11(win + 6.6)));
        float glow = pulse * exp(-length(p - at) / 110.0) * (0.25 + cloudCov);
        // On the light card the lit cloud turns white (there is no room to
        // brighten, but the shade can go); on a dark one it glows.
        acc = ink(acc, mixHue(cLight, cStorm, 0.25), glow * mix(0.8, 0.45, dark) * extra.w);
    }

    // ---- curtains of rain -------------------------------------------------------------
    // One slow field in the rain's own slanted frame, moving with the wind:
    // where it is high the rain is heavier -- darker curtains under the deck,
    // and the streaks there drawn stronger (their alpha, never their
    // presence, so no drop pops in or out as a curtain passes).
    float curtain = 0.5;
    if (extra2.y > 0.0) {
        float sx = p.x - slant.x * p.y - t * drift * 1.6;
        curtain = smoothstep(-0.35, 0.55, snoise(vec2(sx / 95.0, p.y / 520.0 - t * 0.035)) * 0.7
                                         + (noise1(sx / 31.0 + 5.0) - 0.5) * 0.6);
        float base = deck.z * H;
        float below = smoothstep(base - 0.3 * H, base + 0.1 * H, p.y) * (1.0 - smoothstep(base, H * 1.1, p.y) * 0.5);
        acc = ink(acc, mixHue(cShade, cRain, 0.25), curtain * below * mix(0.16, 0.12, dark) * extra2.y);
    }

    // ---- fog --------------------------------------------------------------------------
    // A grey veil over the whole card, and three banks drifting at their own
    // depths through it -- far (high, thin, slow), mid, near (low, thick,
    // faster) -- each a soft band whose centre and thickness wander, its
    // density soft fbm stretched along the drift, lighter than the veil: on
    // the light card the banks are the only white, so they read against the
    // grey rather than against the fill.
    if (extra.y > 0.0) {
        float lowY = smoothstep(0.0, H, p.y);
        acc = ink(acc, mixHue(cFog, cLight, dark * 0.5), (0.10 + 0.10 * lowY) * mix(1.0, 0.7, dark) * extra.y);
        float fogAcc = 0.0;
        int nB = int(loops2.x);
        for (int i = 0; i < nB; i++) {
            float fi = float(i);
            float sp = (3.0 + 4.0 * fi) * dirX;
            float x = p.x - t * sp;
            float yc = H * (0.30 + 0.28 * fi) + 14.0 * (noise1(x / 170.0 + fi * 7.0) - 0.5);
            float th = (14.0 + 8.0 * fi) * (0.7 + 0.6 * noise1(x / 230.0 + fi * 3.0 + 11.0));
            float dy = (p.y - yc) / th;
            float lo;
            float n = fbm(vec2(x / (190.0 + 60.0 * fi), p.y / (36.0 + 10.0 * fi)) + fi * 17.0 + vec2(0.0, t * 0.02),
                          int(octaves.z), 0.0, lo);
            float bank = exp(-dy * dy) * smoothstep(-0.45, 0.35, n);
            fogAcc = fogAcc + bank * (0.40 + 0.25 * fi) * (1.0 - fogAcc);
        }
        acc = ink(acc, cLight, fogAcc * mix(0.95, 0.62, dark) * extra.y);
        acc = ink(acc, cFog, fogAcc * mix(0.0, 0.20, dark) * extra.y);
    }

    // ---- falling particles: motes, rain, snow, hail --------------------------------------
    // One loop over every layer the recipe asks for, far to near within each
    // kind: 0-1 motes in the sunlight, 2-4 rain, 5-8 snow (or wet flakes),
    // 9-10 hail. A layer's parameters come from an if-chain on its index.
    {
        vec2 rainDir = normalize(vec2(slant.x, 1.0));
        vec2 snowDir = normalize(vec2(slant.y, 1.0));
        bool motes = extra2.z > 0.0 && sky.x > 0.0;
        float kr = precip.x;
        float ks = max(precip.y, precip.w);
        float wet = precip.w > precip.y ? 1.0 : 0.0;
        float gust = (0.45 + 0.8 * curtain) * (0.6 + 0.5 * kr);
        vec4 rink = mixHue(cRain, cShade, 0.45);
        int j0 = int(loops.z);
        // the min in float, then converted: GLSL 1.20 and ES 1.00 have no integer min (NVIDIA refuses the 100 es variant, C7011);
        // int() truncates toward zero on both sides of 2, so this is the old min(int(loops.w), 2) for every finite loops.w
        int j1 = int(precipOn > 0.5 ? loops.w : min(loops.w, 2.0));
        for (int j = j0; j < j1; j++) {
            float fj = float(j);
            vec2 dir;
            float cw, ch, spd, len, rad, soft, dens, sway;
            float bob = 0.0;
            if (j < 2) {
                if (!motes)
                    continue;
                // Pollen drifting in the beams, seen only where the light is:
                // sporadic, a handful on the card, barely visible and never snow-like
                // (a density of 0.5 / 0.4 a cell puts about a hundred on the card),
                // settling slowly and now and then floating back up (`bob`).
                dir = normalize(vec2(fj < 0.5 ? 0.25 : -0.2, 1.0));
                cw = fj < 0.5 ? 23.0 : 41.0;
                ch = fj < 0.5 ? 29.0 : 47.0;
                // Settling slower than the bob can carry them back up: most
                // motes float upward for a while now and then.
                spd = fj < 0.5 ? 2.0 : 3.5;
                len = 0.0;
                rad = fj < 0.5 ? 0.8 : 1.5;
                soft = fj < 0.5 ? 0.8 : 1.6;
                dens = fj < 0.5 ? 0.07 : 0.10;
                sway = fj < 0.5 ? 5.0 : 8.0;
                bob = fj < 0.5 ? 7.0 : 12.0;
            } else if (j < 5) {
                if (kr <= 0.0)
                    continue;
                // A fine far veil, the body, a few long soft streaks close by.
                // Heavier rain: more drops in every layer, longer streaks, the
                // near layer only from moderate up.
                float i = fj - 2.0;
                float stretch = 0.8 + 0.4 * kr;
                dir = rainDir;
                cw = i < 0.5 ? 6.0 : (i < 1.5 ? 11.0 : 31.0);
                ch = i < 0.5 ? 40.0 : (i < 1.5 ? 80.0 : 160.0);
                spd = i < 0.5 ? 260.0 : (i < 1.5 ? 430.0 : 720.0);
                len = (i < 0.5 ? 8.0 : (i < 1.5 ? 16.0 : 38.0)) * stretch;
                rad = i < 0.5 ? 0.45 : (i < 1.5 ? 0.6 : 1.1);
                soft = i < 0.5 ? 0.5 : (i < 1.5 ? 0.6 : 1.3);
                dens = i < 0.5 ? 0.2 + 0.5 * kr : (i < 1.5 ? 0.1 + 0.6 * kr : max(0.0, kr - 0.4) * 0.9);
                sway = 0.0;
            } else if (j < 9) {
                if (ks <= 0.0)
                    continue;
                // Four depths from sharp dust to soft bokeh. Wet flakes
                // (sleet) fall faster and stretch a little.
                float i = fj - 5.0;
                float sp = mix(1.0, 3.2, wet);
                dir = snowDir;
                cw = i < 0.5 ? 11.0 : (i < 1.5 ? 19.0 : (i < 2.5 ? 31.0 : 67.0));
                ch = i < 0.5 ? 13.0 : (i < 1.5 ? 23.0 : (i < 2.5 ? 37.0 : 79.0));
                spd = (i < 0.5 ? 14.0 : (i < 1.5 ? 22.0 : (i < 2.5 ? 34.0 : 55.0))) * sp;
                len = wet * 1.5 * (i + 0.5);
                rad = i < 0.5 ? 0.55 : (i < 1.5 ? 1.1 : (i < 2.5 ? 1.9 : 4.5));
                soft = i < 0.5 ? 0.5 : (i < 1.5 ? 0.7 : (i < 2.5 ? 1.0 : 3.5));
                dens = (i < 2.5 ? 0.45 : 0.32) * ks;
                sway = i < 0.5 ? 2.0 : (i < 1.5 ? 3.5 : (i < 2.5 ? 6.0 : 10.0));
            } else {
                if (precip.z <= 0.0)
                    continue;
                // Round ice pellets, two depths, a short motion-blurred tail
                // (longer and they read as rain).
                float i = fj - 9.0;
                dir = rainDir;
                cw = i < 0.5 ? 15.0 : 31.0;
                ch = i < 0.5 ? 60.0 : 110.0;
                spd = i < 0.5 ? 380.0 : 560.0;
                len = i < 0.5 ? 5.0 : 8.0;
                rad = i < 0.5 ? 1.5 : 2.4;
                soft = i < 0.5 ? 0.6 : 0.8;
                dens = 0.45 * precip.z;
                sway = 0.0;
            }
            vec3 r = fallLayer(p + vec2(fj * 5.3, 0.0), dir, cw, ch, spd, len, rad, soft, dens, sway, bob,
                               3.0 + fj * 4.0, t);
            if (r.x <= 0.0)
                continue;
            if (j < 2) {
                // Dust glittering where the light is: a point of light on the
                // dark card, a warm speck on the light one.
                float lit = clamp(light, 0.0, 1.0) * extra2.z;
                if (lightRoom > 0.0) {
                    // On a light sky a mote is a white speck, seen wherever
                    // there is some light and not only in the glare.
                    spark = ink(spark, cLight, (1.0 - smoothstep(rad * 0.8, rad * 0.8 + 0.8, r.z))
                                               * (fj < 0.5 ? 0.4 : 0.3) * min(1.0, lit * 2.5));
                } else {
                    acc = ink(acc, mixHue(cSun, cLight, 0.5), r.x * (fj < 0.5 ? 0.22 : 0.14) * lit);
                    spark = ink(spark, cLight, dark * (1.0 - smoothstep(0.2, 1.0, r.z)) * (fj < 0.5 ? 0.35 : 0.22) * lit);
                }
            } else if (j < 5) {
                float i = fj - 2.0;
                float tailA = i < 0.5 ? 0.3 : (i < 1.5 ? 0.2 : 0.1);
                float a = i < 0.5 ? 0.20 : (i < 1.5 ? 0.34 : 0.24);
                acc = ink(acc, rink, r.x * mix(tailA, 1.0, r.y) * a * gust);
                // The near drops' heads catch the light: a point.
                if (i > 1.5)
                    spark = ink(spark, cLight, (1.0 - smoothstep(0.2, 1.1, r.z)) * 0.35 * gust);
            } else if (j < 9) {
                float i = fj - 5.0;
                // A bright disc with a cool rim -- the rim is what makes a
                // white flake read on the light card, so there it is a band at
                // the disc's edge and the light fills only the inside; the
                // nearest flakes are soft bokeh with a faint ring.
                float ring = r.x * smoothstep(rad * 0.35, rad + soft * 0.5, r.z);
                float rimA = i < 0.5 ? mix(0.30, 0.15, dark) : (i < 2.5 ? mix(0.42, 0.14, dark) : mix(0.14, 0.05, dark));
                float fillA = i < 0.5 ? mix(0.2, 0.45, dark) : (i < 2.5 ? mix(0.75, 0.62, dark) : mix(0.35, 0.28, dark));
                acc = ink(acc, cSnow, (i < 0.5 ? r.x : ring) * rimA);
                acc = ink(acc, cLight, (r.x - ring * mix(0.8, 0.3, dark)) * fillA);
                // On the dark card a flake's heart is a point of light (held
                // to the area bound it is a grey dot).
                if (i > 0.5 && i < 2.5)
                    spark = ink(spark, cLight, max(dark, lightRoom) * (1.0 - smoothstep(0.2, 1.0, r.z)) * 0.55);
            } else {
                float i = fj - 9.0;
                // An ice ball: a cool body, a bright core, the tail fading.
                float ring = r.x * smoothstep(rad * 0.3, rad + soft * 0.5, r.z);
                acc = ink(acc, cHail, r.x * mix(0.2, 1.0, r.y) * mix(0.45, 0.35, dark));
                acc = ink(acc, cLight, (r.x - ring) * smoothstep(0.6, 1.0, r.y) * mix(0.8, 0.5, dark));
                if (i > 0.5)
                    spark = ink(spark, cLight, (1.0 - smoothstep(0.2, 1.1, r.z)) * 0.6);
            }
        }
        if (precipOn > 0.5 && precip.z > 0.0) {
            // Pellets bouncing on the card's foot: per 23 px column, one lands
            // at a hashed moment in each 1.3 s window and hops twice.
            float col = floor(p.x / 23.0);
            float ph = t / 1.3 + hash11(col * 1.7);
            float win = floor(ph);
            float tl = ph - win;
            float hb = hash12(vec2(col, win));
            float hop = tl < 0.45 ? tl / 0.45 : (tl < 0.7 ? (tl - 0.45) / 0.25 : -1.0);
            if (hb < 0.45 * precip.z && hop >= 0.0) {
                float hgt = tl < 0.45 ? 14.0 + 8.0 * hb : 5.0;
                vec2 c = vec2(col * 23.0 + 4.0 + 15.0 * hash12(vec2(win, col))
                              + tl * 18.0 * (hash11(win + col) < 0.5 ? -1.0 : 1.0),
                              H - 3.0 - hgt * 4.0 * hop * (1.0 - hop));
                float dc = length(p - c);
                float fade = 1.0 - smoothstep(0.5, 0.7, tl);
                acc = ink(acc, cHail, (1.0 - smoothstep(1.2, 2.0, dc)) * 0.35 * fade);
                acc = ink(acc, cLight, (1.0 - smoothstep(1.2, 2.0, dc)) * 0.3 * fade);
                spark = ink(spark, cLight, (1.0 - smoothstep(0.3, 1.0, dc)) * 0.5 * fade);
            }
        }
    }

    // ---- mist at the foot ----------------------------------------------------------
    if (extra2.x > 0.0) {
        // A haze rising from the ground, barely structured: blobs here read
        // as a second cloud deck.
        float n = snoise(vec2((p.x - t * drift * 3.0) / 170.0, p.y / 70.0 - t * 0.06));
        acc = ink(acc, mixHue(cLight, cFog, 0.5), smoothstep(H * 0.4, H * 1.05, p.y) * (0.65 + 0.35 * n) * 0.30 * extra2.x);
    }

    // ---- air: trails on the wind's streamlines --------------------------------------
    // The way wind maps draw it: a stream function -- height plus a slow,
    // drifting noise -- whose level sets are the streamlines, wavy and never
    // crossing; on every lane of it, particles travel with the wind and leave
    // a trail that fades behind them. Two depths: far (fine, slow, faint) and
    // near (wider lanes, faster, softer).
    if (extra.z > 0.0) {
        float spd = abs(windSpeed);
        int nA = int(loops2.y);
        float airAcc = 0.0;
        float airHead = 0.0;
        for (int i = 0; i < nA; i++) {
            float fi = float(i);
            float x = p.x * dirX;
            // The stream function: the lane a pixel is on.
            float s = p.y + 26.0 * snoise(vec2(x / 300.0 - t * 0.05, fi * 3.7 + p.y / 150.0))
                          + 7.0 * snoise(vec2(x / 90.0 - t * 0.11, fi * 5.1 + p.y / 60.0));
            float laneH = 9.0 + 6.0 * fi;
            float lane = floor(s / laneH);
            // Across the lane in px: where the streamlines spread, a lane is
            // wider than laneH, and a trail drawn in lane units would swell.
            float ls = (s - (lane + 0.5) * laneH) / max(length(vec2(dFdx(s), dFdy(s))), 0.25);
            float hl = hash12(vec2(lane, fi * 13.0));
            // Along the lane: one trail per cell, at the lane's own speed.
            float cell = 170.0 + 110.0 * fi;
            float u = x - t * spd * (0.55 + 0.35 * fi) * (0.8 + 0.4 * hl) + hl * cell * 5.0;
            float c = floor(u / cell);
            float cu = u - c * cell;
            float hc = hash12(vec2(lane, c) + fi * 7.1);
            float len = cell * (0.35 + 0.45 * hc);
            float head = cell * 0.9;
            // 0 at the tail .. 1 at the head, in the direction of travel.
            float k = clamp((cu - (head - len)) / len, 0.0, 1.0);
            float on = step(head - len, cu) * step(cu, head) * step(hc, 0.55);
            float w = 0.55 + 0.45 * fi;
            float line = (1.0 - smoothstep(w * 0.4, w + 0.6, abs(ls))) * on;
            airAcc = max(airAcc, line * k * k * (0.7 + 0.3 * fi));
            airHead = max(airHead, line * smoothstep(0.9, 1.0, k));
        }
        // Grey on the light card (white would only erase it), light on the
        // dark one.
        acc = ink(acc, cWind, airAcc * mix(0.55, 0.45, dark) * extra.z);
        acc = ink(acc, cLight, airAcc * dark * 0.25 * extra.z);
        spark = ink(spark, mixHue(cWind, cLight, dark), airHead * mix(0.5, 0.35, dark) * extra.z);
    }

    // ---- drops on the glass --------------------------------------------------------
    if (extra.x > 0.0 && precipOn > 0.5) {
        // Beads: one per 19 px cell where present, each with its own life
        // (grow, sit, evaporate) on its own period: a lens with a dark head,
        // a bright foot where it gathers the light, and a glint.
        vec2 c = floor(p / 19.0);
        vec2 f = p - c * 19.0;
        vec2 h = hash22(c + 91.0);
        float life = fract(t / (7.0 + 6.0 * h.y) + h.x);
        float grow = smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(0.75, 1.0, life));
        float present = step(hash12(c + 3.7), 0.35 * extra.x);
        float r = (1.2 + 2.3 * h.x * h.x) * grow;
        vec2 dv = f - vec2(4.5) - h * 10.0;
        float d = length(dv);
        float body = 1.0 - smoothstep(r - 0.6, r + 0.4, d);
        float nd = r > 0.1 ? clamp(dv.y / r, -1.0, 1.0) : 0.0;
        float foot = body * smoothstep(0.1, 0.9, nd) * smoothstep(0.3, 0.9, d / max(r, 0.1));
        float head = body * smoothstep(0.1, 0.9, -nd);
        float glint = (1.0 - smoothstep(0.2, 0.8, length(dv + vec2(0.35, 0.45) * r))) * step(1.8, r);
        acc = ink(acc, mixHue(cShade, cRain, 0.3), (body * 0.12 + head * 0.22) * present);
        acc = ink(acc, cLight, foot * 0.6 * present);
        spark = ink(spark, cLight, glint * 0.7 * present);
    }

    // ---- the tone limiter, then the point lights ------------------------------------
    {
        vec3 comp = acc.rgb + cCard.rgb * (1.0 - acc.a);
        float ad = abs(dot(comp - cCard.rgb, LUMA));
        float room = max(toneCap - toneKnee, 1e-4);
        float lim = ad <= toneKnee ? ad : toneKnee + room * tanh((ad - toneKnee) / room);
        acc *= ad > 1e-5 ? lim / ad : 1.0;
        // The spark's own change is linear in its scale: it gets the room
        // the scene left under `sparkCap`.
        vec3 base = acc.rgb + cCard.rgb * (1.0 - acc.a);
        float db = abs(dot(base - cCard.rgb, LUMA));
        float dsp = abs(dot(spark.rgb - base * spark.a, LUMA));
        float roomS = max(sparkCap - db, 0.0);
        spark *= dsp > roomS ? roomS / dsp : 1.0;
        acc = spark + acc * (1.0 - spark.a);
    }

    // ---- the strike ------------------------------------------------------------------
    if (extra.w > 0.0 && flash > 0.001) {
        // In the card's middle, between the figures and the stats.
        float x0 = W * (0.5 + 0.22 * hash11(flashSeed * 91.0 + 1.7));
        float lean = (hash11(flashSeed * 57.0 + 3.1) - 0.5) * 0.5;
        float yEnd = H * (0.65 + 0.35 * hash11(flashSeed * 23.0 + 5.3));
        // One branch leaves the channel a third of the way down, leaning off
        // to one side, and thins out.
        float yb = yEnd * (0.3 + 0.2 * hash11(flashSeed * 13.0 + 2.0));
        float side = hash11(flashSeed * 7.0 + 8.0) < 0.5 ? -1.0 : 1.0;
        float core = 0.0;
        float halo = 0.0;
        int nCh = int(loops2.z);
        for (int i = 0; i < nCh; i++) {
            bool branch = i == 1;
            float ln = branch ? lean + side * 0.9 : lean;
            float sd = branch ? flashSeed + 0.37 : flashSeed;
            // The branch's own channel, shifted so it passes through the
            // main one at yb.
            float xo = branch ? boltX(yb, x0, lean, flashSeed, 1.0) - boltX(yb, 0.0, ln, sd, 1.0) : x0;
            float y0 = branch ? yb : -4.0;
            float y1 = branch ? yb + yEnd * 0.3 : yEnd;
            float y = clamp(p.y, y0, y1);
            float x = boltX(y, xo, ln, sd, 1.0);
            float sl = boltX(y + 1.0, xo, ln, sd, 1.0) - boltX(y - 1.0, xo, ln, sd, 1.0);
            // The slope correction (dx / sqrt(1 + slope^2) is the distance
            // near a sloped channel) only alongside it, and capped: it is a
            // first-order estimate, and at a kink or past the channel's end
            // an uncapped one stretches the halo sideways into streaks.
            float along = step(y0, p.y) * step(p.y, y1);
            float corr = mix(1.0, min(sqrt(1.0 + 0.25 * sl * sl), 1.7), along);
            float d = length(vec2((p.x - x) / corr, p.y - y));
            // The glow is measured from the smooth path: its slope changes
            // slowly, where the kinked one's correction jumps from row to row
            // and draws the glow as horizontal stripes.
            float dh = length(vec2(p.x - boltX(y, xo, ln, sd, 0.0), p.y - y));
            float taper = branch ? 1.0 - smoothstep(y0, y1, p.y) * 0.8 : 1.0;
            core = max(core, (1.0 - smoothstep(branch ? 0.2 : 0.4, branch ? 1.0 : 1.4, d)) * taper * (branch ? 0.8 : 1.0));
            halo += exp(-dh / (branch ? 5.0 : 7.0)) * (branch ? 0.25 : 0.5) * taper;
        }
        // The cloud around the channel's root, lit from inside.
        float root = exp(-length(p - vec2(x0, 0.0)) / 120.0) * (0.3 + cloudCov);
        acc = ink(acc, cLight, (flash * 0.18 + root * 0.45 * flash) * extra.w);
        acc = ink(acc, cBolt, halo * flash * 0.5 * extra.w);
        acc = over(acc, vec3(1.0), core * flash * 0.95 * extra.w);
    }

    // Derivatives outside any branch: the corner distance is taken for every
    // fragment and only its use depends on the uniform.
    float edge = sdRoundBox(p - size * 0.5, size * 0.5, max(cornerRadius, 0.0));
    float aa = max(fwidth(edge), 1e-4);
    float cover = cornerRadius > 0.0 ? 1.0 - smoothstep(-aa, 0.0, edge) : 1.0;

    if (ground.a > 0.5)
        // LIGHT MODE: the scene over its sky, opaque; the strength scales the
        // scene and never the ground.
        fragColor = vec4(min(acc.rgb * strength + ground.rgb * max(0.0, 1.0 - acc.a * strength), vec3(1.0)), 1.0)
                  * cover * qt_Opacity;
    else
        fragColor = acc * cover * strength * qt_Opacity;
}
