#version 440
// =============================================================================
// curtain_radial.frag -- ThemeCurtain's "radial": a ring opens in the old picture at `origin` (the theme button) and widens until
// the corner furthest from it is through.
//
// The front is a distance from `origin` over the furthest corner's distance, wobbled by two slow noise waves so it is a hand-drawn
// circle and not a compass one, feathered by `soft`. A thin bright rim sits on the picture side of the front and a soft shadow falls
// from it onto the new desktop (premultiplied black: the curtain lets the live desktop through there, it cannot sample it). Progress 0
// leaves every pixel untouched and 1 leaves none, whatever the seed: the front starts and ends outside the field (the wobble is at most
// 5 % of the reach either way, and the front allows 6 %).
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;       // the item, in item px
    vec2 origin;     // where the reveal starts, in item px (the theme button)
    float progress;  // 0 = the old picture covers everything, 1 = nothing of it is left
    float soft;      // the feather of the front, in item px
    float seed;      // moves the noise, so two switches do not dissolve alike
};
layout(binding = 1) uniform sampler2D src;   // the old frame (a capture of the output)

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
void main() {
    vec2 px = qt_TexCoord0 * size;
    vec4 c = vec4(texture(src, qt_TexCoord0).rgb, 1.0);
    float reach = length(max(origin, size - origin)) + 1.0;
    float shadowW = 36.0;
    float rimW = 5.0;
    float wob = (vnoise(px / 260.0 + vec2(seed * 11.0, 3.0)) - 0.5) * 0.10 * reach;
    float d = length(px - origin) + wob;
    // the front, in px: from before the first ring to past the last shadow
    float front = mix(-(soft + rimW + 0.06 * reach), reach + 0.06 * reach + shadowW + soft, progress);
    float a = smoothstep(front - soft * 0.5, front + soft * 0.5, d);
    // the rim: a bright line just inside the picture
    float rim = (1.0 - smoothstep(0.0, rimW, d - front - soft * 0.5)) * a;
    c.rgb = mix(c.rgb, vec3(1.0), 0.16 * rim);
    // the shadow, on the revealed side
    float behind = front - soft * 0.5 - d;
    float sh = 0.22 * (1.0 - smoothstep(0.0, shadowW, behind)) * step(0.0, behind);
    vec3 rgb = c.rgb * a;
    float alpha = a + sh * (1.0 - a);
    fragColor = vec4(rgb, alpha) * qt_Opacity;
}
