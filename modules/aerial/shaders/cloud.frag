#version 440
// =============================================================================
// cloud.frag -- the field of aerial's cloud, THE SIGNAL FAN: a standing Wi-Fi glyph on the card's label. Everything is measured from one origin, the label's centre (item px):
//
//   the source     a small dot and halo on the origin only as a pulse leaves it (nothing stands on the label's print between two pulses)
//   THE PULSE      a wavefront leaving the origin every period: a thin bright line with a soft trail behind it, inside the fan's span (soft toward its ends), fading
//                  with the radius and gone by `fan.w`. A scan makes the next front a stronger one (`pulse.z`); the own hotspot sends three at once (`pulse.w`).
//   the guides     the arcs the tags stand on, as dotted hairlines (the near field's only while something is on it), fading toward the span's ends; a guide lifts a
//                  little as the front crosses it.
//
// Premultiplied: a TINT of the theme's accent laid over whatever is behind (never added: an additive glow blows a light ground out), so it reads on a light and on a
// dark surface and over both board families. No texture, no derivative, no array: every variant (GLSL 1.20, ES 1.00, ES 3.00) is the same arithmetic.
// The pulse's curve is CloudPlace.js `pulseRadius` (the tags' glint reads it there): change one, change the other.
// =============================================================================

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 view;      // x, y: the item in px; z: render scale (device px per item px); w: the Wi-Fi arcs' guides 0..1
    vec4 fan;       // x, y: the origin in item px; z: the span (rad either side of the vertical); w: where a pulse is gone (px)
    vec4 radii;     // the arcs in px: the near field, the two Wi-Fi arcs, the fringe
    vec4 pulse;     // x: the phase 0..1 of the period; y: the share of the period a front travels; z: 1 = the front now in flight is a scan's (wider, brighter: the same clock as every other); w: 1 = three fronts in flight (the hotspot)
    vec4 tint;      // rgb: the hue; a: the strength (the entrance, airplane)
    vec4 look;      // x: the guides' alpha; y: the near field's guide 0..1; z: the pulse's alpha; w: the source dot's alpha
};

// one front at travel `u` (0 at the origin .. 1 gone), at radius r: the line and its trail; `wide` > 1 thickens it (a scan)
float front(float r, float u, float wide) {
    if (u <= 0.0 || u >= 1.0)
        return 0.0;
    float px = 1.0 / max(view.z, 1.0);
    float rp = fan.w * (1.0 - pow(1.0 - u, 1.35));
    float d = r - rp;                                              // > 0 ahead of the front
    float core = 1.0 - smoothstep(0.7 * wide, 0.7 * wide + px, abs(d));
    float trail = d < 0.0 ? exp(d / (14.0 * wide)) * 0.36 : 0.0;
    float life = smoothstep(3.0, 30.0, rp) * (1.0 - smoothstep(0.52, 1.0, u));
    return (core + trail) * life;
}
// how near the front is to radius R (1 on it, 0 a trail behind): a guide lifts as the front crosses it
float crossing(float R, float u) {
    if (u <= 0.0 || u >= 1.0)
        return 0.0;
    float rp = fan.w * (1.0 - pow(1.0 - u, 1.35));
    float d = rp - R;
    return d < 0.0 ? 0.0 : max(0.0, 1.0 - d / 30.0) * (1.0 - smoothstep(0.52, 1.0, u));
}
float guide(float r, float th, float R) {
    float px = 1.0 / max(view.z, 1.0);
    float line = 1.0 - smoothstep(0.45, 0.45 + px, abs(r - R));
    float s = R * th;
    float dash = 1.0 - smoothstep(1.0, 1.0 + px, abs(mod(s + 3500.0, 7.0) - 3.5));
    return line * dash;
}

void main() {
    vec2 p = qt_TexCoord0 * view.xy;
    vec2 d = p - fan.xy;
    float r = length(d);
    float th = atan(d.x, -d.y);                                    // 0 straight up, + to the right
    float ath = abs(th);
    float inFan = 1.0 - smoothstep(fan.z - 0.26, fan.z + 0.05, ath);
    float ends = 1.0 - smoothstep(fan.z * 0.60, fan.z, ath);

    // the fronts
    float u0 = pulse.x / max(pulse.y, 0.05);
    // (pulse.z: this front is a scan's -- wider and brighter, on the same clock as every other)
    float f = pulse.z > 0.5 ? front(r, u0, 1.8) * 1.7 : front(r, u0, 1.0);
    float cr0 = u0;
    if (pulse.w > 0.5) {
        float u1 = fract(pulse.x + 0.3333) / max(pulse.y, 0.05);
        float u2 = fract(pulse.x + 0.6667) / max(pulse.y, 0.05);
        f = max(f, max(front(r, u1, 1.0), front(r, u2, 1.0)));
    }
    float a = f * look.z * inFan;

    // the guides
    float g = guide(r, th, radii.y) * (1.0 + 1.8 * crossing(radii.y, cr0));
    g = max(g, guide(r, th, radii.z) * (1.0 + 1.8 * crossing(radii.z, cr0)));
    g = max(g, guide(r, th, radii.w) * 0.8 * (1.0 + 1.8 * crossing(radii.w, cr0)));
    g *= view.w;
    g = max(g, guide(r, th, radii.x) * look.y * (1.0 + 1.8 * crossing(radii.x, cr0) * view.w));
    a += g * look.x * ends;

    // the source: a dot on the origin, brightest as a front leaves
    float px = 1.0 / max(view.z, 1.0);
    float born = 1.0 - smoothstep(0.0, 0.22, pulse.x);
    // (only AS a front leaves: a steady dot stood on the label's print, in the middle of the docked network's name)
    float dotA = (1.0 - smoothstep(2.2, 2.2 + px, r)) * 0.55 * born;
    float halo = (1.0 - smoothstep(2.0, 9.0 + 6.0 * born, r)) * 0.22 * born;
    a += (dotA + halo) * look.w;

    a = clamp(a, 0.0, 1.0) * tint.a;
    fragColor = vec4(tint.rgb * a, a) * qt_Opacity;
}
