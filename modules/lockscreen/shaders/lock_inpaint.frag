#version 440
// =============================================================================
// lock_inpaint.frag -- the final held frame with the shell's own surfaces taken
// out of it.
//
// The held desktop was captured OUTPUT-wide, so it contains the bars and the
// popup exactly where the real ones (drawn above the lock by the compositor)
// are. When the popup later changes size a copy of it would stay behind in the
// still: a ghost. So every pixel inside a hint rectangle (grown by `pad` for
// shadows and antialiasing) is rebuilt from what lies around it.
//
// The rebuild is a Shepard interpolation of the four nearest edge samples:
// from a masked pixel march along each axis to the first point outside the
// UNION of the rectangles (so a popup butting against a bar is one hole, not
// two), sample the picture there (three taps along the edge, from mip level 2.5, a
// ~6 px box, taken 8 px clear of the hole so the box never reaches into it: the picture carries grain, and one texel per column of a fill draws
// vertical streaks),
// and weight by 1 / (distance^2 + 1). The picture is a blur, so its edges are
// smooth and this is invisible; a direction that leaves the screen has no
// sample and takes no part (a bar on the top edge fills from below only).
// Grain is added back so the fill is not smoother than what is around it.
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;
    float pad;
    float grain;
    float count;
    vec4 r0; vec4 r1; vec4 r2; vec4 r3; vec4 r4; vec4 r5; vec4 r6; vec4 r7;
};
layout(binding = 1) uniform sampler2D src;

// The grain's hash of a PIXEL coordinate (up to 2880 x 1620 and beyond). Not `fract(sin(dot(p, (12.9898, 78.233))) * 43758.5453)`: that sine's argument
// reaches ~160 000 at the far corner, where a GPU's sine is no longer random and the result is a woven lattice of diagonal stripes, strongest at the
// bottom right. Only fract() and a dot product, whose operands stay below ~300.
float hash(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

vec4 rectAt(int i) {
    if (i == 0) return r0;
    if (i == 1) return r1;
    if (i == 2) return r2;
    if (i == 3) return r3;
    if (i == 4) return r4;
    if (i == 5) return r5;
    if (i == 6) return r6;
    return r7;
}

bool inRect(vec2 p, vec4 r) {
    return p.x >= r.x - pad && p.x < r.x + r.z + pad && p.y >= r.y - pad && p.y < r.y + r.w + pad;
}

bool inAny(vec2 p) {
    for (int i = 0; i < 8; ++i)
        if (float(i) < count && inRect(p, rectAt(i)))
            return true;
    return false;
}

// distance from p along unit axis d to the first point outside the union
float exitDist(vec2 p, vec2 d) {
    float t = 0.0;
    for (int k = 0; k < 8; ++k) {
        vec2 q = p + d * t;
        bool hit = false;
        for (int i = 0; i < 8; ++i) {
            if (float(i) >= count)
                continue;
            vec4 r = rectAt(i);
            if (!inRect(q, r))
                continue;
            hit = true;
            float e = d.x > 0.5 ? r.x + r.z + pad - p.x
                    : d.x < -0.5 ? p.x - (r.x - pad)
                    : d.y > 0.5 ? r.y + r.w + pad - p.y
                    : p.y - (r.y - pad);
            t = max(t, e + 0.5);
        }
        if (!hit)
            break;
    }
    return t;
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 p = uv * size;
    if (!inAny(p)) {
        fragColor = texture(src, uv) * qt_Opacity;
        return;
    }
    vec3 acc = vec3(0.0);
    float wsum = 0.0;
    for (int k = 0; k < 4; ++k) {
        vec2 d = k == 0 ? vec2(-1.0, 0.0) : k == 1 ? vec2(1.0, 0.0) : k == 2 ? vec2(0.0, -1.0) : vec2(0.0, 1.0);
        float t = exitDist(p, d);
        vec2 q = p + d * (t + 8.0);
        if (q.x < 8.0 || q.y < 8.0 || q.x > size.x - 8.0 || q.y > size.y - 8.0)
            continue;
        vec2 tang = vec2(d.y, d.x);
        vec3 c = vec3(0.0);
        for (int j = -1; j <= 1; ++j) {
            vec2 s = clamp(q + tang * float(j) * 8.0, vec2(0.5), size - 0.5);
            c += textureLod(src, s / size, 2.5).rgb;
        }
        float w = 1.0 / (t * t + 1.0);
        acc += c / 3.0 * w;
        wsum += w;
    }
    vec3 col = wsum > 0.0 ? acc / wsum : texture(src, uv).rgb;
    col += (hash(floor(p)) - 0.5) * grain;
    fragColor = vec4(col, 1.0) * qt_Opacity;
}
