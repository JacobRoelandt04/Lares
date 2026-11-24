#version 440
// =============================================================================
// curtain_louvres.frag -- ThemeCurtain's "louvres": the old picture is a row of vertical slats, and each turns edge-on and is gone,
// the turning travelling out from `origin`'s column (the lock's Louvres veil, played the other way).
//
// A slat is 64 px wide. Its own progress is the screen's, delayed by its distance from `origin` in x (at most half of the whole run), so the
// last slat starts turning at 0.5 and has turned by 1. A turning slat narrows to its centre line (its visible half width is cos of the
// angle) and shades from lit to dark across its width, as a slat does when its far edge is the one that turns away from the light.
// `soft` is unused (the edge of a slat is one pixel of antialiasing). Progress 0 leaves every pixel untouched and 1 leaves none: a
// slat of no width draws nothing.
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
    float pitch = 64.0;
    float cells = floor(size.x / pitch + 0.5);
    float w = size.x / max(cells, 1.0);                 // the slats fill the screen exactly
    float i = floor(px.x / w);
    float centre = (i + 0.5) * w;
    float delay = clamp(abs(centre - origin.x) / max(max(origin.x, size.x - origin.x), 1.0), 0.0, 1.0);
    float lp = clamp((progress - 0.5 * delay) / 0.5, 0.0, 1.0);
    // a slat that has not begun to turn is the picture, whole: the antialiased edge of a slat whose width is a fraction of a pixel would
    // otherwise draw a faint seam between slats on the very first frame
    if (lp <= 0.0) {
        fragColor = vec4(c.rgb, 1.0) * qt_Opacity;
        return;
    }
    float turn = lp * 1.57079632;
    float hw = 0.5 * w * cos(turn);
    float dist = abs(px.x - centre);
    float a = clamp(hw - dist + 0.5, 0.0, 1.0) * smoothstep(0.0, 1.0, hw);
    float side = clamp((px.x - centre) / max(hw, 1.0), -1.0, 1.0);
    float lit = 1.0 - 0.30 * sin(turn) * (0.5 + 0.5 * side);
    c.rgb *= lit;
    // the slat's edge catches the light
    c.rgb = mix(c.rgb, vec3(1.0), 0.10 * sin(turn) * smoothstep(hw - 3.0, hw, dist));
    fragColor = vec4(c.rgb * a, a) * qt_Opacity;
}
