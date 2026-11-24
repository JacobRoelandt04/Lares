struct EvaInk {
    vec3 surf;     // the plateau
    vec3 hi;       // the bevel
    vec3 shd;      // the deep shadow
    vec3 flr;      // a carved floor
    vec3 sunk;     // a sunk part
    vec3 well;     // a cell's well
    vec3 metal;
    vec3 ink;      // engraving
    bool dk;
};

EvaInk evaInk() {
    EvaInk e;
    e.surf = palA.rgb;
    e.hi = palB.rgb;
    e.shd = palC.rgb;
    e.flr = palD.rgb;
    e.sunk = palF.rgb;
    e.well = palG.rgb;
    e.metal = palH.rgb;
    e.ink = palE.rgb;
    e.dk = frame.w > 0.5;
    return e;
}

// How a carved region reads at one point. din: mm inside it (negative outside); slope: how din
// changes per mm walking TOWARD the light (negative near the wall on the light's side, which casts
// the shadow). Returns the colour of the plateau `col` after the carve.
vec3 evaCarve(EvaInk e, vec3 col, vec3 floorCol, float din, float slope, float inset, float rim, float aa, float strength) {
    float face = (1.0 - smoothstep(-0.7, 0.7, slope));                    // 1 where the edge faces the light
    float insideM = smoothstep(-aa, aa, din);
    // outside: the bevel, a light rim on the edges that face the light
    float rimM = (1.0 - smoothstep(0.0, rim, -din)) * (1.0 - insideM) * (0.35 + 0.65 * face);
    col = mix(col, e.hi, rimM * strength);
    // inside: the floor, shaded from the wall on the light's side
    float sh = exp(-max(din, 0.0) / inset) * (0.30 + 0.70 * (1.0 - face));
    vec3 fl = mix(floorCol, e.shd, sh * (e.dk ? 0.85 : 0.70));
    return mix(col, fl, insideM);
}
