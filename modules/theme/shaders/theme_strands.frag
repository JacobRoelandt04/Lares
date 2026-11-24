#version 440
// The sine strands that join a pair's two cards: y = sin(x * wave - flow * speed + phase) * amp * sin(pi u), three of them, pinched to nothing at both cards. wave, speed and
// phase are the instance's own (ThemeStrands), the pinch is a function of u alone.
// a and b are where the strands leave the cards, which float, so the chord between them moves; the distance is divided by the slope's length, so a strand keeps its width
// on the steep parts. Colours come in as data, the pair's own: light card -> mid -> dark card.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float boxW;
    float boxH;
    float ax;
    float ay;
    float bx;
    float by;
    float flow;
    float endWidth;
    vec4 s1;        // amp, wave, speed, width
    vec4 s2;
    vec4 s3;
    vec4 alphas;    // the three strands' alpha, the fourth is unused
    vec4 phases;    // the three strands' phase, the fourth is unused
    vec4 colA;
    vec4 colB;
    vec4 mid1;
    vec4 mid2;
    vec4 mid3;
};

const float PI = 3.14159265358979;

float strand(vec2 p, vec4 s, float phase, float px, float u, float pinch, float dPinch, float chord, float dChord) {
    float a = p.x * s.y - flow * s.z + phase;
    float sa = sin(a);
    float y = chord + sa * s.x * pinch;
    float slope = dChord + cos(a) * s.y * s.x * pinch + sa * s.x * dPinch;
    float d = abs(p.y - y) / sqrt(1.0 + slope * slope);
    float w = 0.5 * s.w * (endWidth + (1.0 - endWidth) * sqrt(pinch));
    return clamp((w - d) / px + 0.5, 0.0, 1.0);
}

vec3 ramp(float u, vec4 mid) {
    float k = smoothstep(0.0, 1.0, u * 2.0);
    float e = smoothstep(0.0, 1.0, u * 2.0 - 1.0);
    return u < 0.5 ? mix(colA.rgb, mid.rgb, k) : mix(mid.rgb, colB.rgb, e);
}

void main() {
    vec2 p = qt_TexCoord0 * vec2(boxW, boxH);
    float px = length(vec2(dFdx(p.x), dFdy(p.x)));
    float L = max(1.0, bx - ax);
    float u = (p.x - ax) / L;
    if (u <= 0.0 || u >= 1.0) {
        fragColor = vec4(0.0);
        return;
    }
    float pinch = sin(PI * u);
    float dPinch = cos(PI * u) * PI / L;
    float e = u * u * (3.0 - 2.0 * u);
    float chord = ay + (by - ay) * e;
    float dChord = (by - ay) * 6.0 * u * (1.0 - u) / L;

    vec4 out1 = vec4(0.0);
    float c = strand(p, s1, phases.x, px, u, pinch, dPinch, chord, dChord) * alphas.x;
    out1 = vec4(ramp(u, mid1) * c, c);
    c = strand(p, s2, phases.y, px, u, pinch, dPinch, chord, dChord) * alphas.y;
    out1 = vec4(ramp(u, mid2) * c, c) + out1 * (1.0 - c);
    c = strand(p, s3, phases.z, px, u, pinch, dPinch, chord, dChord) * alphas.z;
    out1 = vec4(ramp(u, mid3) * c, c) + out1 * (1.0 - c);
    fragColor = out1 * qt_Opacity;
}
