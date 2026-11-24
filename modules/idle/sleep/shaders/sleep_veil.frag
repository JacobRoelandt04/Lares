#version 440
// =============================================================================
// sleep_veil.frag -- the screen falling asleep and waking (modules/idle/sleep/SleepVeilEffect.qml; docs/idle.md).
//
// ONE clock, `progress`: 0 awake (the pass draws NOTHING: the live screen, exactly), 1 asleep (opaque black). The same picture played
// backwards is the wake. Drawn OVER the live output (premultiplied: out = C + (1 - A) * live), so what it cannot sample -- the live
// screen -- it shapes with its alpha, and what it can -- `src`, one capture of the output, mipmapped -- it DREAMS over the live screen
// with an alpha that rises with the clock: p = 0 is the live screen whatever the resampling, and a key typed during the wake shows
// through.
//
//   the dream      the still, defocused (a golden-angle disc of 9 taps on the mip chain), split into its channels along the radius
//                  (chromatic aberration, red out and blue in, growing to the corners), sunk into the glass (a small zoom with a touch
//                  of barrel) and desaturated
//   the vignette   the classic one: the dark comes in from the corners, an ellipse of the screen's own shape with a wide soft edge all the way down to
//                  nothing -- never a shape of its own (an emulated opening eye is too much)
//   the light      on an output whose light is not the backlight's (`selfDim`: an external screen, a panel that is not ours), the veil
//                  dims the picture itself along the backlight's perceived curve
//   the dither     half a level of noise on everything drawn: the OLED bands a dark gradient
//
// `strength` (0 .. 1) scales the dream (blur, split, sink, desaturation); the vignette and the light are the fade itself. GLSL 1.20-safe
// (no bit operations, no integer %), `texture(s, uv, bias)` for the mip level (no textureLod in an ES 1.00 fragment shader).
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // the output, in device px
    float progress;   // 0 awake .. 1 asleep
    float strength;   // 0 .. 1: the dream's amount
    float still;      // 1: src holds the output's own picture; 0: none (the vignette and the light alone)
    float selfDim;    // 1: the veil dims this output itself (no backlight of ours under it)
    float seed;       // moves the dither between fades
};
layout(binding = 1) uniform sampler2D src;

float ease(float x) {
    x = clamp(x, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// The dream at uv: the still through the lens, one channel per radius.
vec3 dream(vec2 uv, float k, float s) {
    vec2 c = vec2(0.5);
    vec2 dv = uv - c;
    float r2 = dot(dv * vec2(size.x / size.y, 1.0), dv * vec2(size.x / size.y, 1.0));
    float e = ease(k);
    // sunk into the glass: a zoom in, a little more at the middle than at the edge (barrel)
    float sink = 1.0 - s * 0.045 * e * (1.0 - 0.55 * r2);
    vec2 base = c + dv * sink;
    // the channels' radii: red outwards, blue inwards, more at the corners
    float ca = s * 0.010 * e * (0.35 + 1.6 * r2);
    vec2 uvR = c + (base - c) * (1.0 + ca);
    vec2 uvB = c + (base - c) * (1.0 - ca);
    // the defocus, in device px, and the mip level that makes 9 taps enough
    float rad = s * 0.024 * size.y * pow(e, 0.75);
    vec3 acc = vec3(0.0);
    if (rad < 0.75) {
        acc = vec3(texture(src, uvR).r, texture(src, base).g, texture(src, uvB).b);
    } else {
        float bias = log2(max(1.0, rad / 2.5));
        vec2 px = vec2(1.0) / size;
        float wsum = 0.0;
        for (int i = 0; i < 9; i++) {
            float fi = float(i);
            float rr = i == 0 ? 0.0 : sqrt((fi - 0.5) / 8.0);
            float a = fi * 2.39996323 + seed * 6.2831853;
            vec2 o = vec2(cos(a), sin(a)) * rr * rad * px;
            float wgt = 1.0 - 0.35 * rr;
            acc += wgt * vec3(texture(src, uvR + o, bias).r, texture(src, base + o, bias).g, texture(src, uvB + o, bias).b);
            wsum += wgt;
        }
        acc /= wsum;
    }
    // desaturated as it sinks
    float lum = dot(acc, vec3(0.2126, 0.7152, 0.0722));
    return mix(acc, vec3(lum), 0.45 * s * e);
}

void main() {
    float k = clamp(progress, 0.0, 1.0);
    if (k <= 0.0) {
        fragColor = vec4(0.0);
        return;
    }
    if (k >= 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, qt_Opacity);
        return;
    }
    float s = clamp(strength, 0.0, 1.0);
    vec2 uv = qt_TexCoord0;

    // the vignette: `R` is where the edge's middle stands, in a space where the screen's sides are at 1 and its corners at sqrt(2). Closed by k = 0.95, most of the
    // closing in the second half, while the light is low; the edge is wide at the start (the corners only sink) and stays soft to the end
    float c = ease(k / 0.95);
    float R = mix(1.75, -0.6, c);
    float f = mix(0.85, 0.55, c);
    float mg = mix(1.0, 1.0 - smoothstep(R - f, R + f, length((uv - 0.5) * 2.0)), smoothstep(0.0, 0.14, k));

    // the light this veil owes the output (none where the backlight carries it)
    float ex = selfDim > 0.5 ? pow(1.0 - k, 1.35) : 1.0;

    // how much of the dream covers the live screen
    float a = still > 0.5 && s > 0.0 ? smoothstep(0.02, 0.45, k) : 0.0;
    vec3 col = a > 0.0 ? dream(uv, k, s) : vec3(0.0);

    vec3 C = ex * a * mg * col;
    float A = 1.0 - ex * mg * (1.0 - a);

    // half a level of noise wherever anything is drawn
    float n = hash12(gl_FragCoord.xy + seed * 397.0) - 0.5;
    float n2 = hash12(gl_FragCoord.yx * 1.37 + seed * 211.0) - 0.5;
    if (A > 0.0) {
        C = max(C + vec3(n / 255.0) * A, vec3(0.0));
        A = clamp(A + n2 / 255.0, 0.0, 1.0);
        C = min(C, vec3(A));
    }
    fragColor = vec4(C, A) * qt_Opacity;
}
