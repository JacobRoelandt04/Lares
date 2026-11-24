#version 440
// =============================================================================
// curtain_peel.frag -- ThemeCurtain's "peel": the old picture comes away like a sheet, its edge travelling from `origin` across the
// screen towards the far side.
//
// The front is a straight line moving along the direction from `origin` to the middle of the screen. Ahead of it the old picture, with a lit lip along the edge
// (the sheet curling up towards the viewer, a bright band that falls off over 64 px and a slight darkening behind it);
// behind it the new desktop, with the sheet's shadow lying on it (premultiplied black, 40 px, squared falloff). Nothing is drawn of the
// sheet's underside: the curtain is one flat picture. Progress 0 leaves every pixel untouched and 1 leaves none: the front starts one
// lip before the first corner and ends one shadow past the last.
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

void main() {
    vec2 px = qt_TexCoord0 * size;
    vec4 c = vec4(texture(src, qt_TexCoord0).rgb, 1.0);
    vec2 toward = size * 0.5 - origin;
    vec2 dir = length(toward) < 8.0 ? normalize(vec2(1.0, 0.35)) : normalize(toward);
    float lip = 64.0;
    float shadowW = 40.0;
    // the extent of the screen along dir
    float s0 = min(min(dot(vec2(0.0, 0.0), dir), dot(vec2(size.x, 0.0), dir)), min(dot(vec2(0.0, size.y), dir), dot(size, dir)));
    float s1 = max(max(dot(vec2(0.0, 0.0), dir), dot(vec2(size.x, 0.0), dir)), max(dot(vec2(0.0, size.y), dir), dot(size, dir)));
    float s = dot(px, dir);
    float front = mix(s0 - lip, s1 + shadowW, progress);
    float ahead = s - front;                 // > 0: the sheet still lies here
    float a = smoothstep(0.0, max(soft * 0.25, 1.0), ahead);
    float k = clamp(ahead / lip, 0.0, 1.0);
    float curl = (1.0 - k) * (1.0 - k);
    c.rgb = mix(c.rgb * (1.0 - 0.10 * smoothstep(0.0, 0.3, k) * (1.0 - k)), vec3(1.0), 0.20 * curl * a);
    float back = clamp(-ahead / shadowW, 0.0, 1.0);
    float sh = 0.30 * (1.0 - back) * (1.0 - back) * (1.0 - a) * step(-shadowW, ahead);
    fragColor = vec4(c.rgb * a, a + sh * (1.0 - a)) * qt_Opacity;
}
