#version 440
// =============================================================================
// globe.vert -- Qt Quick's own ShaderEffect vertex shader, written out (the texture coordinate through, the corner through qt_Matrix), for the reason aerial_board.vert
// gives: with a vertex shader of its own that has a 300 es variant the pair links at GLSL ES 3.00 on NVIDIA's OpenGL ES context. The uniform block is globe.frag's, copied
// whole (tools/dev/shader_ubo_match.py holds the two to each other).
// =============================================================================

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;

layout(location = 0) out vec2 qt_TexCoord0;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 view;      // x, y: the item in px; z: the globe radius in px; w: family (0 Material, 1 Blueprint)
    vec4 centre;    // x, y: the globe's centre in item px; z: the turn angle (rad, the sphere about its polar axis); w: dark (1 on the dark theme)
    vec4 look;      // x: the dot spacing (deg); y: a dot's radius (px); z: the hairline step (deg); w: render scale (device px per item px)
    vec4 hue;       // rgb: the ink hue (the theme's own, BarHues); a: the strength (the entrance x presence)
    vec4 beam;      // x: the lens cap's y in item px; y: the beam's half width at the lens (px); z: its half width at the sphere (px); w: the beam's strength
    vec4 mark;      // a probe's marker: x lat, y lon (deg), z on (0 = off), w radius px
    vec4 tilt;      // x: the tilt (rad) of the sphere about the camera's right axis (0 = the pole leans to the viewer as drawn so far; positive brings the SOUTH pole toward the viewer)
};

out gl_PerVertex { vec4 gl_Position; };

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
