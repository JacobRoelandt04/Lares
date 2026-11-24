#version 440

// =============================================================================
// weather_backdrop.frag
//
// The hero card's always-moving background: one quad, one uniform `mode`,
// one `time`. Everything is STATELESS -- every streak, star and blob is a
// function of (pixel, time) through hashes, so a frame costs one uniform
// write and nothing has to be simulated between frames. That is what lets the
// host run it at 30 Hz from a Timer instead of a frame clock.
//
// Modes (the model's kinds, in its order; `night` is a separate flag):
//   0 clear    day: 2-3 broad rays rotating from the top-left corner + a glow
//              night: ~40 hashed stars twinkling on their own phase + a glow
//   1 partly   2-3 big soft cloud blobs (two octaves of value noise) drifting,
//              with the day/night glow behind them
//   2 cloudy   more cover, cooler tint, no glow
//   3 fog      horizontal bands drifting sideways
//   4 rain     columns of hashed 1 px capsules scrolling down, slanted by the
//              wind, two depths
//   5 sleet    rain + snow, each thinned
//   6 snow     slow round flakes with a sideways wobble
//   7 hail     short fat streaks, fast
//   8 thunder  rain under a storm haze, plus `flash` (0..1, ONE eased fraction
//              the host animates): the whole card lifts by flash * 0.25 and a
//              hashed bolt is drawn at that opacity
//   9 wind     thin long wavy capsules of air at the wind's speed
//
// CONTRAST IS NORMALISED PER HUE. The content -- big figures, a glyph -- sits
// on this, so nothing here may exceed ~12 % luminance against the card. The
// same alpha of the same token is 0.24 luma per unit alpha in light mode (the
// sun on #E6E9F0) and 0.86 in dark (a pale sun on #282C34), so the host passes
// every hue as vec4(rgb, GAIN), gain = 0.24 / |luma(hue) - luma(card)| clamped
// to [0.15, 1], and every element's alpha is multiplied by its hue's gain. The
// numbers below are tuned for gain 1.
//
// Output is PREMULTIPLIED: layers are composited with `over` into `acc`, and
// `strength` and qt_Opacity scale the whole vec4.
//
// `cornerRadius` > 0 rounds the effect's own corners (a signed-distance box,
// feathered INWARD over one DEVICE pixel -- fwidth, so a magnified card keeps
// a one-pixel edge rather than a feather that grows with the zoom), for a host
// that does not clip its content; 0 is square. WeatherHero grows the effect
// past the card's edge under the card's opaque bevel rim, so the ink is full
// at the edge itself.
//
// The wrap of `time` at 3600 s (the host's) re-seeds the scrolling fields once
// an hour: every period here divides 3600 except the per-column streak speeds,
// whose one-frame jump at the hour is below what a 30 Hz field shows.
//
// No arrays: every hash is a named value (CLAUDE.md: a GLSL scratch array is
// spilled on iris).
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    // Theme hues: rgb straight, .a = the contrast gain (see above).
    vec4  cSun;
    vec4  cCloud;
    vec4  cRain;
    vec4  cSnow;
    vec4  cStorm;
    vec4  cFog;
    vec4  cNight;
    vec4  cFlash;           // the lightning's wash over the whole card
    vec4  cBolt;            // the bolt itself (the hue with more contrast)
    vec2  size;             // the item, px
    vec2  slant;            // x: rain dx per px of fall; y: the same for snow
    float mode;
    float time;             // seconds, wrapped at 3600
    float intensity;        // 0 light, 1 normal, 2 heavy
    float strength;
    float night;
    float flash;
    float flashSeed;
    float precipOn;         // 0 while the canvas renderer draws the precipitation
    float windSpeed;        // px/s, signed: positive blows right
    float cornerRadius;
};

// -----------------------------------------------------------------------------
// helpers
// -----------------------------------------------------------------------------
float hash21(vec2 p) {
    p = fract(p * vec2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

// Value noise: four hashes on the cell's corners, smoothly interpolated.
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + vec2(1.0, 0.0));
    float c = hash21(i + vec2(0.0, 1.0));
    float d = hash21(i + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float sdRoundBox(vec2 p, vec2 h, float r) {
    vec2 q = abs(p) - h + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Premultiplied `over`: a layer of colour `rgb` at alpha `a` on top of acc.
vec4 over(vec4 acc, vec3 rgb, float a) {
    a = clamp(a, 0.0, 1.0);
    return acc * (1.0 - a) + vec4(rgb * a, a);
}

// -----------------------------------------------------------------------------
// the sky
// -----------------------------------------------------------------------------

// Broad rays rotating about a point just outside the top-left corner, and a
// glow there. `ang` runs 0 (along the top edge) to pi/2 (down the left edge);
// 9 rad^-1 puts 2-3 ridges across that quadrant.
float rays(vec2 p, float t) {
    vec2 q = p - vec2(-24.0, -24.0);
    float dist = length(q);
    float ang = atan(q.y, q.x);
    float ph = t * 6.2831853 / 40.0;
    float ray = 0.5 + 0.5 * cos(ang * 9.0 - ph);
    ray = smoothstep(0.2, 1.0, ray);
    ray *= ray;
    return ray * exp(-dist / 240.0) * 0.28;
}

float glow(vec2 p, vec2 at, float reach) {
    return exp(-length(p - at) / reach);
}

// One star per 34 px cell, at a hashed spot at least 6 px inside it (a star's
// halo and sparkle stay inside the cell, which is what makes one cell lookup
// per pixel enough). ~60 % of cells hold one.
float stars(vec2 p, float t) {
    float cs = 34.0;
    vec2 cell = floor(p / cs);
    vec2 f = p - cell * cs;
    float h1 = hash21(cell + 0.37);
    float h2 = hash21(cell + 5.1);
    float h3 = hash21(cell + 9.3);
    float h4 = hash21(cell + 13.7);
    vec2 sp = vec2(6.0 + (cs - 12.0) * h1, 6.0 + (cs - 12.0) * h2);
    float present = step(h4, 0.6);
    vec2 dv = f - sp;
    float d = length(dv);
    float r = 0.7 + 1.3 * h3;
    float tw = 0.5 + 0.5 * sin(t * (0.6 + 1.8 * h2) + h1 * 6.2831853);
    float core = smoothstep(r + 0.9, r - 0.4, d);
    float halo = exp(-d / (r * 2.2)) * 0.4;
    float cross = exp(-abs(dv.x) * 1.5) * exp(-abs(dv.y) * 0.35)
                + exp(-abs(dv.y) * 1.5) * exp(-abs(dv.x) * 0.35);
    cross *= h3 * h3 * 0.5;
    return min(1.0, core + halo + cross) * (0.45 + 0.55 * tw) * present;
}

// Cloud cover 0..1: two octaves of value noise on cells wider than tall (a
// cloud is), drifting right at ~1 px/s, with a denser core so a blob reads as
// a body and not a stain. `th` is where a blob begins; lower = more cover.
float cloudField(vec2 p, vec2 cell, float th, float t) {
    vec2 q = p / cell + vec2(t * 0.011, 0.0);
    float n = 0.62 * vnoise(q) + 0.38 * vnoise(q * 2.03 + vec2(t * 0.005, 1.7));
    float body = smoothstep(th, th + 0.22, n);
    float core = smoothstep(th + 0.14, th + 0.42, n);
    return body * (0.6 + 0.4 * core);
}
// Two banks: big slow blobs and smaller quicker ones between them.
float clouds(vec2 p, float th, float t) {
    float big = cloudField(p, vec2(150.0, 62.0), th, t);
    float small = cloudField(p + vec2(37.0, 91.0), vec2(90.0, 40.0), th + 0.06, t * 1.4);
    return max(big, small * 0.75);
}

// Horizontal bands 44 px apart, bent by slow noise, each fading in and out
// along x as a drifting noise says: a bank of fog crossing the card, lying
// low (denser toward the foot).
float fog(vec2 p, float t) {
    float wob = vnoise(vec2(p.x / 170.0 + t * 0.025, p.y / 80.0));
    float ph = p.y * 0.143 + wob * 2.5;
    float band = 0.5 + 0.5 * sin(ph);
    band = smoothstep(0.15, 0.95, band);
    float idx = floor(ph / 6.2831853 + 0.25);
    float m = vnoise(vec2(p.x / 140.0 - t * 0.05, idx * 0.7));
    m = smoothstep(0.2, 0.85, m);
    float low = 0.5 + 0.5 * smoothstep(0.0, size.y, p.y);
    return band * m * low;
}

// -----------------------------------------------------------------------------
// precipitation: a stateless streak field
// -----------------------------------------------------------------------------
// Columns `colW` wide across `dir`, cells `cellL` long along it, one capsule
// per cell where the cell's hash is under `density`. The field scrolls along
// `dir` at `speed`, each column at its own 0.75..1.25 of it. `len` 0 draws a
// dot (snow); `halfW` is the capsule's half width and the margin the capsule
// keeps from its column's edges, `vary` how much smaller than it a capsule may
// hash; `wobble` is a sideways sway in px (snow).
float streakField(vec2 p, vec2 dir, float colW, float cellL, float speed, float len,
                  float halfW, float vary, float density, float wobble, float seed, float t)
{
    vec2 perp = vec2(-dir.y, dir.x);
    float u = dot(p, dir);
    float v = dot(p, perp);
    float col = floor(v / colW);
    float lv = v - col * colW;
    float hc = hash21(vec2(col, seed));
    float uu = u - t * speed * (0.75 + 0.5 * hc) + hc * cellL * 3.0;
    float cell = floor(uu / cellL);
    float lu = uu - cell * cellL;
    vec2 id = vec2(col, cell) + seed;
    float h1 = hash21(id + 1.3);
    float h2 = hash21(id + 4.7);
    float h3 = hash21(id + 9.1);
    float h4 = hash21(id + 2.2);
    float present = step(h1, density);
    float start = 2.0 + h2 * max(0.0, cellL - len - 4.0);
    float margin = halfW + 1.5 + wobble;
    float vc = margin + h3 * max(0.0, colW - 2.0 * margin);
    vc += wobble * sin(t * 1.3 + h1 * 6.2831853 + lu * 0.05);
    float hw = halfW * mix(1.0 - vary, 1.0, h4);
    float along = lu - clamp(lu, start, start + len);
    float d = length(vec2(along, lv - vc));
    float cov = smoothstep(hw + 0.75, hw - 0.25, d);
    // A drop's head is its brightest; the tail thins out.
    float taper = len > 0.0 ? mix(0.35, 1.0, clamp((lu - start) / max(len, 1.0), 0.0, 1.0)) : 1.0;
    return cov * taper * present;
}

// Wind: rows `rowH` tall, one wavy capsule per `cellL` of travel, blowing along
// x at `speed` (signed).
float airField(vec2 p, float speed, float rowH, float cellL, float seed, float t) {
    float dirX = speed < 0.0 ? -1.0 : 1.0;
    float row = floor(p.y / rowH);
    float ly = p.y - row * rowH;
    float hr = hash21(vec2(row, seed));
    float uu = p.x * dirX - t * abs(speed) * (0.7 + 0.6 * hr) + hr * cellL * 3.0;
    float cell = floor(uu / cellL);
    float lu = uu - cell * cellL;
    vec2 id = vec2(row, cell) + seed;
    float h1 = hash21(id + 1.3);
    float h2 = hash21(id + 4.7);
    float h3 = hash21(id + 9.1);
    float len = 30.0 + 80.0 * h2;
    float start = 2.0 + h3 * max(0.0, cellL - len - 4.0);
    float yc = 4.0 + h1 * (rowH - 8.0) + 2.5 * sin(lu * 0.045 + h2 * 6.2831853);
    float ends = smoothstep(0.0, 10.0, lu - start) * smoothstep(0.0, 10.0, start + len - lu);
    float d = abs(ly - yc);
    // Soft, 2 px wide: air, not a scratch.
    return smoothstep(2.0, 0.2, d) * ends * step(h1, 0.8);
}

// A bolt: a polyline of 14 px segments from a hashed x at the top, each vertex
// thrown +-15 px, leaning one way, ending 50-80 % of the way down.
float bolt(vec2 p, float seed) {
    float x0 = size.x * (0.3 + 0.4 * hash21(vec2(seed, 1.7)));
    float lean = (hash21(vec2(seed, 3.1)) - 0.5) * 0.5;
    float seg = 14.0;
    float sy = p.y / seg;
    float si = floor(sy);
    float xa = x0 + lean * si * seg + (hash21(vec2(si, seed)) - 0.5) * 30.0;
    float xb = x0 + lean * (si + 1.0) * seg + (hash21(vec2(si + 1.0, seed)) - 0.5) * 30.0;
    float xl = mix(xa, xb, fract(sy));
    float slope = (xb - xa) / seg;
    float d = abs(p.x - xl) / sqrt(1.0 + slope * slope);
    float yEnd = size.y * (0.5 + 0.3 * hash21(vec2(seed, 5.3)));
    float on = 1.0 - smoothstep(yEnd - 24.0, yEnd, p.y);
    return (smoothstep(1.8, 0.3, d) + exp(-d / 8.0) * 0.4) * on;
}

// -----------------------------------------------------------------------------
void main() {
    vec2 p = qt_TexCoord0 * size;
    float t = time;
    float k = clamp(intensity, 0.0, 2.0);
    int m = int(mode + 0.5);
    bool isNight = night > 0.5;
    vec4 acc = vec4(0.0);

    vec2 sunAt = vec2(-24.0, -24.0);
    vec2 moonAt = vec2(size.x + 20.0, -20.0);

    if (m == 0) {
        if (!isNight) {
            acc = over(acc, cSun.rgb, (glow(p, sunAt, 130.0) * 0.26 + rays(p, t)) * cSun.a);
        } else {
            acc = over(acc, cNight.rgb, glow(p, moonAt, 120.0) * 0.28 * cNight.a);
            acc = over(acc, cNight.rgb, stars(p, t) * 0.36 * cNight.a);
        }
    } else if (m == 1 || m == 2) {
        if (m == 1) {
            if (!isNight)
                acc = over(acc, cSun.rgb, glow(p, sunAt, 130.0) * 0.22 * cSun.a);
            else
                acc = over(acc, cNight.rgb, glow(p, moonAt, 120.0) * 0.20 * cNight.a);
            acc = over(acc, cCloud.rgb, clouds(p, 0.53, t) * 0.32 * cCloud.a);
        } else {
            vec3 cool = mix(cCloud.rgb, cNight.rgb, 0.3);
            float gain = mix(cCloud.a, cNight.a, 0.3);
            acc = over(acc, cool, (0.06 + clouds(p, 0.42, t) * 0.36) * gain);
        }
    } else if (m == 3) {
        acc = over(acc, cFog.rgb, (0.06 + fog(p, t) * 0.34) * cFog.a);
    } else if (m >= 4 && m <= 8) {
        // Thunder's rain is never light.
        float kr = m == 8 ? max(k, 1.0) : k;
        if (m == 8) {
            float haze = smoothstep(size.y * 0.7, 0.0, p.y) * (0.08 + 0.08 * clouds(p, 0.40, t));
            acc = over(acc, cStorm.rgb, haze * cStorm.a);
        }
        if (precipOn > 0.5) {
            vec2 rainDir = normalize(vec2(slant.x, 1.0));
            vec2 snowDir = normalize(vec2(slant.y, 1.0));
            bool rainy = m == 4 || m == 5 || m == 8;
            bool snowy = m == 5 || m == 6;
            // Sleet thins both; thunder's rain sits on the haze, so a shade less.
            float thin = m == 5 ? 0.55 : 1.0;
            float ink = m == 5 ? 0.7 : (m == 8 ? 0.85 : 1.0);
            if (rainy) {
                float far = streakField(p, rainDir, 21.0 - 4.0 * kr, 120.0, 150.0 + 45.0 * kr,
                                        9.0 + 4.0 * kr, 0.5, 0.0, (0.55 + 0.10 * kr) * thin, 0.0, 3.0, t);
                float near = streakField(p, rainDir, 15.0 - 3.0 * kr, 100.0 - 10.0 * kr, 240.0 + 70.0 * kr,
                                         14.0 + 7.0 * kr, 0.5, 0.0, (0.65 + 0.15 * kr) * thin, 0.0, 11.0, t);
                acc = over(acc, cRain.rgb, max(far * 0.18, near * 0.34) * ink * cRain.a);
            }
            if (snowy) {
                float flakes = streakField(p, snowDir, 21.0 - 3.0 * k, 64.0, 20.0 + 9.0 * k,
                                           0.0, 2.2, 0.45, (0.5 + 0.2 * k) * thin, 3.0, 23.0, t);
                float dust = streakField(p, snowDir, 14.0, 40.0, 14.0 + 5.0 * k,
                                         0.0, 1.0, 0.3, (0.35 + 0.15 * k) * thin, 2.0, 31.0, t);
                acc = over(acc, cSnow.rgb, max(dust * 0.18, flakes * 0.36) * ink * cSnow.a);
            }
            if (m == 7) {
                float stones = streakField(p, rainDir, 13.0, 70.0, 400.0 + 60.0 * k,
                                           7.0, 1.3, 0.3, 0.45 + 0.2 * k, 0.0, 41.0, t);
                acc = over(acc, cSnow.rgb, stones * 0.36 * cSnow.a);
            }
        }
        if (m == 8 && flash > 0.001) {
            acc = over(acc, cFlash.rgb, flash * 0.25 * cFlash.a);
            acc = over(acc, cBolt.rgb, bolt(p, flashSeed) * flash * 0.9);
        }
    } else if (m == 9) {
        float air = airField(p, windSpeed, 22.0, 220.0, 5.0, t)
                  + airField(p, windSpeed * 0.7, 30.0, 260.0, 17.0, t) * 0.6;
        acc = over(acc, cFog.rgb, air * 0.28 * cFog.a);
    }

    // Derivatives outside any branch: the corner distance is taken for every
    // fragment and only its use depends on the uniform.
    float edge = sdRoundBox(p - size * 0.5, size * 0.5, max(cornerRadius, 0.0));
    float aa = max(fwidth(edge), 1e-4);
    float cover = cornerRadius > 0.0 ? 1.0 - smoothstep(-aa, 0.0, edge) : 1.0;

    fragColor = acc * cover * strength * qt_Opacity;
}
