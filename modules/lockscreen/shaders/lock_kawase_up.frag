#version 440
// =============================================================================
// lock_kawase_up.frag -- one UPSAMPLE pass of Hyprland's dual-Kawase blur (see
// lock_kawase_down.frag), and, on the LAST pass (`grade` = 1), what Hyprland's
// blur-finish does to the result: contrast about the mid grey and a static
// grain (noise 0.1 -> uniform +-0.05: measured std 7.5 levels in the
// compositor's flat regions, 0.0289 * 255 by this formula). The grade matters:
// without it the handover to the live blur is a visible step in every flat
// colour (red 192 -> 185 in the contrast alone).
//
// `mixw` blends the sharp capture (`sharp`) into the blurred, graded result:
// the blur-in ramps it from 0 (the sharp desktop, exactly) to 1 (the full
// blur) together with `radius`, so the picture defocuses instead of dissolving.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 halfpixel;
    float radius;
    float grade;
    float mixw;
    float contrast;
    float grain;
    vec2 texSize;
};
layout(binding = 1) uniform sampler2D src;
layout(binding = 2) uniform sampler2D sharp;

// The grain's hash of a PIXEL coordinate (up to 2880 x 1620 and beyond). Not `fract(sin(dot(p, (12.9898, 78.233))) * 43758.5453)`: that sine's argument
// reaches ~160 000 at the far corner, where a GPU's sine is no longer random and the result is a woven lattice of diagonal stripes, strongest at the
// bottom right. Only fract() and a dot product, whose operands stay below ~300.
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 o = halfpixel * radius;
    vec4 s = texture(src, uv + vec2(-o.x * 2.0, 0.0));
    s += texture(src, uv + vec2(-o.x, o.y)) * 2.0;
    s += texture(src, uv + vec2(0.0, o.y * 2.0));
    s += texture(src, uv + vec2(o.x, o.y)) * 2.0;
    s += texture(src, uv + vec2(o.x * 2.0, 0.0));
    s += texture(src, uv + vec2(o.x, -o.y)) * 2.0;
    s += texture(src, uv + vec2(0.0, -o.y * 2.0));
    s += texture(src, uv + vec2(-o.x, -o.y)) * 2.0;
    s /= 12.0;
    if (grade > 0.5) {
        vec3 c = (s.rgb - 0.5) * contrast + 0.5;
        c += (hash(floor(uv * texSize)) - 0.5) * grain;
        c = mix(texture(sharp, uv).rgb, c, mixw);
        fragColor = vec4(c, 1.0) * qt_Opacity;
    } else {
        fragColor = vec4(s.rgb, 1.0);
    }
}
