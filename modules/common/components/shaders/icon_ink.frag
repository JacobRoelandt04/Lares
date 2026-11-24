#version 440
// =============================================================================
// icon_ink.frag -- an icon's ALPHA drawn in one ink (TrayInk.qml).
//
// A tray icon comes from a theme that was drawn for somebody else's panel:
// Papirus' panel icons are LIGHT on dark, invisible on eva-light, and every
// app ships its own palette. Drawn as ink -- the icon's coverage times one
// themed colour -- they read on either ground and take the shell's states
// (accent on hover, warn for attention, faint for a passive item) the way the
// reel's glyphs do.
//
//   inkMode  1: premultiplied `ink * tex.a * qt_Opacity`
//            0: the image as it is (`colour`), times the opacity
//
// A colour property reaches a shader premultiplied; the ink is un-premultiplied
// here so an ink with an alpha of its own (a faint passive item) is that alpha
// of the colour, not of a darker one. Written for GLSL 1.20 and 300 es as well:
// no integers, no bit operations.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float inkMode;
    vec4 ink;
};
layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 tex = texture(source, qt_TexCoord0);
    if (inkMode > 0.5) {
        vec3 c = ink.a > 0.0 ? ink.rgb / ink.a : vec3(0.0);
        float a = tex.a * ink.a * qt_Opacity;
        fragColor = vec4(c * a, a);
    } else {
        fragColor = tex * qt_Opacity;
    }
}
