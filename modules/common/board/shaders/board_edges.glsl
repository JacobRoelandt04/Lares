// ---- the box's edges, seen from the camera ---------------------------------------------------
// A TOP face: px to its nearest edge and that edge's outward direction in the world (xz).
void topEdge(Surf s, out float dPx, out vec2 outDir) {
    vec3 a = s.pl - s.bmin;
    vec3 b = s.bmax - s.pl;
    float m = a.x;
    vec3 dl = vec3(-1.0, 0.0, 0.0);
    if (b.x < m) { m = b.x; dl = vec3(1.0, 0.0, 0.0); }
    if (a.z < m) { m = a.z; dl = vec3(0.0, 0.0, -1.0); }
    if (b.z < m) { m = b.z; dl = vec3(0.0, 0.0, 1.0); }
    dPx = m * 0.70710678 * s.pxPerMm;
    outDir = groupNormal(s.group, dl).xz;
}

// A SIDE face: px to its top edge, to its foot, and to the nearest vertical edge; `creaseOut` is 1
// when that vertical edge is a crease with the other visible side (not a silhouette).
void sideEdges(Surf s, out float dTop, out float dFoot, out float dVert, out float creaseOut) {
    dTop = (s.bmax.y - s.pl.y) * 0.70710678 * s.pxPerMm;
    dFoot = (s.pl.y - s.bmin.y) * 0.70710678 * s.pxPerMm;
    bool alongZ = abs(s.nl.x) > 0.5;
    float u = alongZ ? s.pl.z : s.pl.x;
    float lo = alongZ ? s.bmin.z : s.bmin.x;
    float hi = alongZ ? s.bmax.z : s.bmax.x;
    float dl = u - lo, dh = hi - u;
    vec3 outL = alongZ ? vec3(0.0, 0.0, dl < dh ? -1.0 : 1.0) : vec3(dl < dh ? -1.0 : 1.0, 0.0, 0.0);
    dVert = min(dl, dh) * 0.70710678 * s.pxPerMm;
    creaseOut = dot(groupNormal(s.group, outL), V_CAM) > 0.0 ? 1.0 : 0.0;
}

// the ground's shadow rule shared by the families: the board's footprint with a soft edge
float footprintShadow(float sd, float contact, float reach) {
    return exp(-max(sd, 0.0) / contact) * 0.6 + (1.0 - smoothstep(0.0, reach, sd)) * 0.4;
}

// The ground is seen through the item's rect and nothing may be cut at its edge: the shadow of the
// board dies out over the last 12 px before the rect's border (the camera leaves ~14 px of margin).
float itemEdgeFade(vec2 p) {
    if (frame.z > 0.5)
        return 1.0;                      // the patch is a sub-rect of the scene: its edge is not the scene's
    vec3 P = vec3(p.x, BOARD_Y.x, p.y);
    float xs = frame.x + view.z * dot(P, CAM_R) - quad.x;
    float ys = frame.y - view.z * dot(P, CAM_U) - quad.y;
    float m = min(min(xs, view.x - xs), min(ys, view.y - ys));
    return smoothstep(1.0, 12.0, m);
}
