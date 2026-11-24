// =============================================================================
// curtain_reveal.glsl -- THE LINE of the live curtain (modules/shell/ThemeWipe.qml): one function of a pixel and `progress`, included by
// every shader that draws a part of the old world (curtain_under: the desktop's still; curtain_over: the old shell; curtain_ghost: an
// island's old copy). The three are drawn in ONE window, in one frame, from one `progress`, so what the desktop does at a pixel the shell does
// at that pixel: there is no second clock and no second copy of the geometry to fall out of step.
//
// The numbers are the stand-alone curtain's (curtain_radial / _peel / _louvres.frag), which an output under a fullscreen window still
// uses. There the picture is opaque; here it is premultiplied, so "towards white" is towards white times its alpha.
//
//   float curtainShade(vec2 px, inout vec4 c, out float sh)
//       px   the pixel, in the window's item px
//       c    premultiplied, shaded in place (the rim, the lip, a turning slat)
//       sh   the sheet's shadow on the revealed side, 0..1 (black over whatever is there; only the topmost layer draws it)
//       returns the share of the sheet that still covers this pixel
//
// Progress 0 leaves every pixel untouched and 1 leaves none, whatever the seed (each style's front starts and ends outside the screen).
// Declared by the includer, in its uniform block: vec2 size, vec2 origin, float progress, float soft, float seed, float style
// (0 radial, 1 peel, 2 louvres).
// =============================================================================
float curtainHash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float curtainNoise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(curtainHash(i), curtainHash(i + vec2(1.0, 0.0)), f.x), mix(curtainHash(i + vec2(0.0, 1.0)), curtainHash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float curtainRadial(vec2 px, inout vec4 c, out float sh) {
    float reach = length(max(origin, size - origin)) + 1.0;
    float shadowW = 36.0;
    float rimW = 5.0;
    float wob = (curtainNoise(px / 260.0 + vec2(seed * 11.0, 3.0)) - 0.5) * 0.10 * reach;
    float d = length(px - origin) + wob;
    float front = mix(-(soft + rimW + 0.06 * reach), reach + 0.06 * reach + shadowW + soft, progress);
    float a = smoothstep(front - soft * 0.5, front + soft * 0.5, d);
    float rim = (1.0 - smoothstep(0.0, rimW, d - front - soft * 0.5)) * a;
    c.rgb = mix(c.rgb, vec3(c.a), 0.16 * rim);
    float behind = front - soft * 0.5 - d;
    sh = 0.22 * (1.0 - smoothstep(0.0, shadowW, behind)) * step(0.0, behind);
    return a;
}

float curtainPeel(vec2 px, inout vec4 c, out float sh) {
    vec2 toward = size * 0.5 - origin;
    vec2 dir = length(toward) < 8.0 ? normalize(vec2(1.0, 0.35)) : normalize(toward);
    float lip = 64.0;
    float shadowW = 40.0;
    float s0 = min(min(dot(vec2(0.0, 0.0), dir), dot(vec2(size.x, 0.0), dir)), min(dot(vec2(0.0, size.y), dir), dot(size, dir)));
    float s1 = max(max(dot(vec2(0.0, 0.0), dir), dot(vec2(size.x, 0.0), dir)), max(dot(vec2(0.0, size.y), dir), dot(size, dir)));
    float front = mix(s0 - lip, s1 + shadowW, progress);
    float ahead = dot(px, dir) - front;
    float a = smoothstep(0.0, max(soft * 0.25, 1.0), ahead);
    float k = clamp(ahead / lip, 0.0, 1.0);
    float curl = (1.0 - k) * (1.0 - k);
    c.rgb = mix(c.rgb * (1.0 - 0.10 * smoothstep(0.0, 0.3, k) * (1.0 - k)), vec3(c.a), 0.20 * curl * a);
    float back = clamp(-ahead / shadowW, 0.0, 1.0);
    sh = 0.30 * (1.0 - back) * (1.0 - back) * (1.0 - a) * step(-shadowW, ahead);
    return a;
}

float curtainLouvres(vec2 px, inout vec4 c, out float sh) {
    sh = 0.0;
    float cells = floor(size.x / 64.0 + 0.5);
    float w = size.x / max(cells, 1.0);
    float i = floor(px.x / w);
    float centre = (i + 0.5) * w;
    float delay = clamp(abs(centre - origin.x) / max(max(origin.x, size.x - origin.x), 1.0), 0.0, 1.0);
    float lp = clamp((progress - 0.5 * delay) / 0.5, 0.0, 1.0);
    if (lp <= 0.0)
        return 1.0;
    float turn = lp * 1.57079632;
    float hw = 0.5 * w * cos(turn);
    float dist = abs(px.x - centre);
    float a = clamp(hw - dist + 0.5, 0.0, 1.0) * smoothstep(0.0, 1.0, hw);
    float side = clamp((px.x - centre) / max(hw, 1.0), -1.0, 1.0);
    c.rgb *= 1.0 - 0.30 * sin(turn) * (0.5 + 0.5 * side);
    c.rgb = mix(c.rgb, vec3(c.a), 0.10 * sin(turn) * smoothstep(hw - 3.0, hw, dist));
    return a;
}

float curtainShade(vec2 px, inout vec4 c, out float sh) {
    if (style < 0.5)
        return curtainRadial(px, c, sh);
    if (style < 1.5)
        return curtainPeel(px, c, sh);
    return curtainLouvres(px, c, sh);
}
