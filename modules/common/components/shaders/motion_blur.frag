#version 440

// Directional motion blur. Samples the source texture along `dir` at N
// uniformly-spaced offsets and averages with a triangular weight that
// favours the centre, so unblurred content stays near its real position
// while fringe samples add a soft streak in the direction of motion.
//
// `amount` in [0..1] scales the half-length of the sample window (in UV
// space). 0 = pure passthrough. `dir` is typically (±1, 0) for horizontal
// motion — it doesn't need to be a unit vector; its magnitude also
// contributes to the streak length.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float amount;
    vec2 dir;
};

layout(binding = 1) uniform sampler2D src;

void main() {
    const int N = 15;
    float halfN = float(N - 1) * 0.5;
    float maxOffset = amount * 0.25;

    vec4 accum = vec4(0.0);
    float totalW = 0.0;
    for (int i = 0; i < N; i++) {
        float t = (float(i) - halfN) / halfN; // -1..1
        float w = 1.0 - abs(t);                 // triangular weight
        vec2 uv = qt_TexCoord0 + (t * maxOffset) * dir;
        // Sample without clamping; out-of-range reads fade toward edge
        // colour / transparent, which produces a natural streak
        // boundary rather than a hard cutoff.
        if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0) {
            accum += texture(src, uv) * w;
            totalW += w;
        }
    }

    fragColor = (accum / max(totalW, 1e-4)) * qt_Opacity;
}
