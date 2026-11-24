#version 440
#extension GL_GOOGLE_include_directive : enable
// =============================================================================
// curtain_over.frag -- the live curtain's upper half: the OLD shell, over the live new one (ThemeWipe.qml; the line is curtain_reveal.glsl).
//
// `shellOld` is the shell's picture taken at the switch's commit (premultiplied, nothing but the shell). On the side the line has not reached, the
// pixel is that picture OVER THE DESKTOP'S STILL, and opaque wherever the old shell had any ink: a half-covered edge or a shadow pixel of the
// new shell lies under it, and a plain src-over would count that edge twice (a shadow twice as dark at the first frame of every reveal).
//
// `shellNow` is the live shell. Where the shell has LEFT a place the old picture must go too, or a popup that closes stays on screen as a picture until the line
// reaches it: a test of "is there still shell here", not a ratio (the two palettes' shadows need not have the same alpha). Where the shell has ARRIVED (much more ink than the old
// picture has on that pixel: a popup that opened after the commit) there is no old picture to show, so the live ink is put in the old palette here (`inOldPalette`) and the line cuts
// it like the rest. A shadow is left alone, it has no palette to speak of.
//
// The holes are ThemeCrossfade's (theme_hole.frag): an island keeps moving through them. The sheet's shadow on the revealed side is drawn here
// and only here, over everything, so it falls on the new shell and the new desktop alike.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    vec2 origin;
    float progress;
    float soft;
    float seed;
    float style;
    float px1;       // one device pixel, in item px
    vec4 surfOld;    // the palette's two ends, before and after the switch
    vec4 inkOld;
    vec4 surfNew;
    vec4 inkNew;
    vec4 holeA;      // centre x, centre y, half width, half height (item px)
    vec4 holeB;
    vec4 holeC;
    vec4 holeD;
    vec4 holeR;      // the corner radius of A, B, C, D
    vec4 holeH;      // 1: a hard edge, per hole
};
layout(binding = 1) uniform sampler2D shot;
layout(binding = 2) uniform sampler2D shellThen;
layout(binding = 3) uniform sampler2D shellOld;    // the shell at the commit
layout(binding = 4) uniform sampler2D shellNow;    // the shell, live
#include "curtain_reveal.glsl"
#include "curtain_desk.glsl"

float keep(vec2 p, vec4 h, float r, float hard) {
    if (h.z <= 0.0 || h.w <= 0.0)
        return 1.0;
    float rr = min(r, min(h.z, h.w));
    vec2 q = abs(p - h.xy) - (h.zw - vec2(rr));
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
    if (hard > 0.5)
        return d < -0.25 * px1 ? 0.0 : 1.0;
    return clamp(1.0 + d / max(px1, 1e-4), 0.0, 1.0);
}

// A colour of the new palette in the old: the axis from the surface to the text goes to the old axis, so the surface, the text and everything antialiased between them land
// exactly, and what is off the axis (a hue) stays off it by as much. Across a light / dark flip what is darker than a dark surface or lighter than a light one (a carve, a
// bevel) was on the far side of the surface from the text, and is on the near side in the other mode: hence the abs.
vec3 inOldPalette(vec3 c) {
    vec3 axisNew = inkNew.rgb - surfNew.rgb;
    vec3 axisOld = inkOld.rgb - surfOld.rgb;
    float t = dot(c - surfNew.rgb, axisNew) / max(dot(axisNew, axisNew), 1e-4);
    vec3 hue = c - surfNew.rgb - t * axisNew;
    return clamp(surfOld.rgb + (dot(axisNew, axisOld) < 0.0 ? abs(t) : t) * axisOld + hue, 0.0, 1.0);
}

void main() {
    vec2 px = qt_TexCoord0 * size;
    vec4 c = vec4(0.0);
    vec4 old = texture(shellOld, qt_TexCoord0);
    vec4 now = texture(shellNow, qt_TexCoord0);
    if (old.a > 0.0) {
        float k = keep(px, holeA, holeR.x, holeH.x) * keep(px, holeB, holeR.y, holeH.y) * keep(px, holeC, holeR.z, holeH.z) * keep(px, holeD, holeR.w, holeH.w);
        float here = clamp(now.a * 8.0, 0.0, 1.0);
        c = (old + (1.0 - old.a) * curtainDesk(qt_TexCoord0)) * k * here;
    }
    float arrived = smoothstep(0.4, 0.8, now.a - old.a);
    if (arrived > 0.0)
        c = mix(c, vec4(inOldPalette(now.rgb / now.a), 1.0), arrived);
    float sh;
    float a = curtainShade(px, c, sh);
    c *= a;
    fragColor = vec4(c.rgb, c.a + sh * (1.0 - c.a)) * qt_Opacity;
}
