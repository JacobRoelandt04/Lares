const vec3 V_CAM = vec3(0.57735027, 0.57735027, 0.57735027);
const float SILK_RANGE = 1.0;            // mm: the silkscreen field covers +-this around a glyph's edge

// ---- small helpers --------------------------------------------------------------------------
float sat(float x) { return clamp(x, 0.0, 1.0); }
float pxMm() {                           // device pixels per mm
    return view.z * max(quad.w, 1.0);
}
float aaMm() {                           // an antialiasing half-width: 0.6 device px, in mm
    return 0.6 / pxMm();
}
// a mask that is 1 inside (d < 0) and falls to 0 over `aa` around the edge
float inside(float d, float aa) {
    return 1.0 - smoothstep(-aa, aa, d);
}
