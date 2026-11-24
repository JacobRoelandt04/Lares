#version 440
#extension GL_GOOGLE_include_directive : enable

// =============================================================================
// wiki_veil_ripples.frag -- wiki veil "Ripples": three slow wave sources (one in
// the picture, two far outside it) and the pattern their waves make where they
// cross. No line is drawn: the surface itself rises and falls a fraction of a
// pixel and the one light does the rest, so it is the calmest of the veils.
//
// Each wave is A f(k r' - w t) / (1 + r / R), with r' = sqrt(r^2 + a^2) so the
// source in view is a smooth boss, not a point, and f a wave with a narrow crest
// and a wide trough (1 - 2 sqrt(sin^2(x / 2) + e^2): a plain sine lit this softly
// reads as a picture out of focus; a crest is a line). The gradient is analytic.
// The sources stand at places measured from the picture's CENTRE in pattern px,
// so a thumbnail is the middle of the same pond.
//
//   p0   wavelength px, height px, decay radius px, -
//   p1   speed (the waves travel `5 * speed` px a second), crest roundness (0.05 sharp .. 0.5 soft), -, -
// =============================================================================

#include "wiki_veil.glsl"

void main() {
    vec2 P = veilCoord();
    float t = time * p1.x;
    float h = 0.0;
    vec2 g = vec2(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float ang = TAU * fract(seed.z + fi * 0.41 + seed.w * 0.3);
        vec2 c = i == 0 ? (seed.xy - 0.5) * vec2(260.0, 130.0)
                        : (240.0 + 150.0 * fi) * vec2(cos(ang), sin(ang));
        float lam = p0.x * (i == 0 ? 1.0 : (i == 1 ? 1.31 : 0.83));
        float k = TAU / lam;
        vec2 rv = P - c;
        float r2 = dot(rv, rv);
        float rs = sqrt(r2 + 100.0);
        float env = 1.0 / (1.0 + sqrt(r2) / p0.z);
        float amp = i == 0 ? 1.0 : 0.6;
        float ph = k * rs - k * 5.0 * t + TAU * hash11(seed.x * 57.0 + fi * 3.1);
        float root = sqrt(sin(0.5 * ph) * sin(0.5 * ph) + p1.y * p1.y);
        float wave = 1.0 - 2.0 * root;
        float dwave = -0.5 * sin(ph) / root;
        h += amp * wave * env;
        g += amp * (k * dwave * env - wave * env * env / p0.z) * rv / rs;
    }
    // only a trough is "deep": the even share of the shade must leave the plain surface alone
    fragColor = veilShade(max(0.0, -0.3 * h), p0.y * g);
}
