#version 440

// =============================================================================
// bridge_body.vert -- Qt Quick's own ShaderEffect vertex stage, written out (the texture coordinate through, the corner
// through qt_Matrix) for one reason: with a vertex shader of its own that has a 300 es variant, the pair links at GLSL
// ES 3.00 on an OpenGL ES context (NVIDIA in dGPU-only mode). With Qt's built-in one it would link at ES 1.00, whose
// uniform struct Qt cannot find by name: every uniform 0, a body that draws nothing, and no word about it.
// =============================================================================

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;

layout(location = 0) out vec2 qt_TexCoord0;

// The uniform block, the SAME in both stages (a ShaderEffect's two stages share one buffer: a member in one and not the
// other shifts every later one, with no error; tools/dev/shader_ubo_match.py holds them to it). BodyLayer.qml names each.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 view;      // stage width, height (px), device px per stage px, the camera's distance (px)
    vec4 bodyA;     // centre x, y (stage px), half width, half height
    vec4 bodyB;     // half thickness, the outline's corner radius, the rounded edge's radius, how far a key stands proud
    vec4 dispA;     // the display's half width, half height, corner radius; the body's lift towards the viewer
    vec4 backA;     // the frame's rim round each glass (px), how wide the seam between rim and glass is (px), px per mm, how deep the decor's deepest lies (mm)
    vec4 backB;     // the fan's centre as the back is seen (px from the centre), the earpiece slit's half width and height (px)
    vec4 patA;      // the back's ringed window as the back is seen: centre x, y, half width, half height (px from the centre)
    vec4 patB;      // its corner radius, the rings' pitch, the plate's seam x, the plate's head y (px)
    vec4 patC;      // the plate's lines' pitch (px), how strongly the ruled lines show, how far a groove tips the light, how wide the lenses' collars are (px; 0: none)
    vec4 patD;      // the two main lenses as the back is seen: x, the first's y, the second's y, their radius (px from the centre)
    vec4 frameA;    // the frame's atlas: the end walls' share of its width, a strip's share of its height, a row's step, half a texel of its height
    vec4 axX;       // the body's own axes in the stage's space (x right, y down, z to the viewer)
    vec4 axY;
    vec4 axZ;
    vec4 keyA;      // what stands proud of the frame: y0, y1 (px from the centre), side (+1 right, -1 left), kind + its half extent across the frame in mm / 10 (1 a bar, 4 the slider, 5 a pill, 6 round)
    vec4 keyB;
    vec4 keyC;
    vec4 keyD;
    vec4 pressA;    // how far keys A..D are pressed, 0..1
    vec4 lightA;    // the key light: the direction TO it (xyz), its strength
    vec4 lightB;    // the fill light
    vec4 stripA;    // the strip light the glass mirrors: its middle (a direction), its strength
    vec4 stripB;    // its long axis, its half length (as a sine)
    vec4 skyC;      // what a reflection sees above (rgb) and how much of the room it takes (a)
    vec4 groundC;   // ... below (rgb); how soft the horizon is (a)
    vec4 shadowA;   // the cast shadow: colour, strength
    vec4 shadowB;   // where the body's middle throws its shadow at rest: x, y (px); its softness (px); how high that middle stands over the surface at rest (px)
    vec4 frameC;    // the frame's metal (rgb), its roughness
    vec4 backC;     // the back's ground (rgb) where no decor is drawn; how bright the two side lights are
    vec4 bezelC;    // the glass border round the display (rgb), the glass's reflectivity
    vec4 accentC;   // spare (0); the field's stripes' pitch (px); how much of a ring's inward step its corner radius gives up (1: plain offsets); the busy light, 0..1
    vec4 tune;      // the display's glare, the strip's sharpness, how much of the room the frame's metal mirrors, the decor's presence (0 = none drawn)
    vec4 filmA;     // the film printed under the glass: how high it stands over the plate (px), how dark its shadow on the plate is, how much longer the shadow runs in a ruled line's valley
    vec4 platA;     // what stands proud of the back, in the body's space: the plateau's centre x, y, half width, half height (px; 0: a flat back)
    vec4 platB;     // its corner radius, its height, its top edge's radius, how much further each lens stands (px)
    vec4 ringA;     // a lens: x, y, radius, its top edge's radius (px; radius 0: none)
    vec4 ringB;
    vec4 ringC;
};

out gl_PerVertex { vec4 gl_Position; };

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
