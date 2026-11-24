#version 440
// =============================================================================
// label_plate.vert -- Qt Quick's own ShaderEffect vertex shader, written out (see globe.vert for why); the uniform block is label_plate.frag's, copied whole.
// =============================================================================

layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;

layout(location = 0) out vec2 qt_TexCoord0;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 plate;      // x, y: the label's size mm; z: its corner radius mm; w: family (0 Material, 1 Blueprint)
    vec4 wipe;       // x: the wipe 0 (paper) .. 1 (chrome); y: the clock, s; z: 1 = dark mode; w: mm per DEVICE px along the text (the antialiasing's unit)
    vec4 lamp;       // x, y: the lamp's side in the label's plane (unit: the rim that is lit); z: the scene's live layer 0..1 (the mirrored pulse's strength); w: the paper's fibre / the brushing's strength (1 = as designed)
    vec4 axes;       // the plate's x axis (xy) and y axis (zw) ON SCREEN, px per mm: the room in the chrome is the screen's, not the sticker's
    vec4 env;        // x: the card's tilt, rad (the mirror turns toward the viewer: the room slides by twice that); y, z: where the pointer leads the room, -1..1 each way
    vec4 pulse;      // the cloud's front mirrored in the plate: x its radius on screen, px (< 0: none in flight); y its strength 0..1; z the fan's half angle, rad
    vec4 colPaper;   // the sticker's paper
    vec4 colSky;     // chrome: the pale band (Blueprint: unused)
    vec4 colBase;    // chrome: the plate's own tone (Blueprint: the face wash)
    vec4 colDeep;    // chrome: the dark horizon band (Blueprint: the faint ink of the hatch)
    vec4 colInk;     // Blueprint: the frame's ink (Material: unused)
    vec4 colHot;     // the front's hot line and the rim's light
    vec4 colPulse;   // the cloud's own hue (its front in the chrome)
};

out gl_PerVertex { vec4 gl_Position; };

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
