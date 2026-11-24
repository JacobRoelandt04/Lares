// =============================================================================
// cutouts.glsl -- the outlines a few parts are CUT to (spliced into silicon_board.frag and silicon_glow.frag by tools/dev/silicon_shader_gen.js).
//
// The scene is made of axis-aligned boxes, and a box has square corners. A part flagged `cut` (SceneGeometry B() opts) is still ONE box for
// the ray; where the shader finds that the point it hit lies outside the part's real outline, it marks the part skipped (cutPart) and casts
// again, so the pixel shows what is behind. That is how the I/O bracket gets its rounded corners and its tapered tongue, how the display ribbon gets
// its bends, and how a RAM stick gets its rounded corners and the notches in its short edges and a socket its U of housing and end walls -- with no extra
// work for a ray that has nothing to do with them. A cut part must be flat enough for its box's faces to be its real ones (the strip, the plate, a
// prism of one height): the faces of the real outline that are not faces of the box are not there.
//
// In:  the generated PART_* ids and the BRK_* / RIB_* / RAM_* numbers (SceneGeometry), `pl` the hit point in the part's own frame.
// Out: cutSd(part, pl) -- signed mm, negative inside the outline (a part that is not cut is inside everywhere); a pixel with cutSd > 0.01 is cut.
// (Call it ONCE per pixel and hand the answer on: it is a big function and a shader compiles every copy.)
// =============================================================================

// a rounded rectangle: centre c, half extents h, corner radius r
float rrSd(vec2 q, vec2 c, vec2 h, float r) {
    vec2 d = abs(q - c) - (h - r);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}
// a polynomial smooth maximum: where two half-planes of an outline (both positive OUTSIDE) meet, it rounds the corner (k ~ 1.7 x the radius)
float smaxK(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return max(a, b) + h * h * k * 0.25;
}

// the I/O bracket's plate, in its own plane (u = z, v = y): a rounded rectangle
float plateSd(vec2 q) {
    vec4 P = BRK_PLATE;
    return rrSd(q, (P.xy + P.zw) * 0.5, (P.zw - P.xy) * 0.5, BRK_R);
}
// the tongue: a tab that tapers from the plate down to its tip, the tip's corners rounded, off the plate's centre line
float tongueSd(vec2 q) {
    vec4 T = BRK_TONGUE;
    float h = BRK_TONGUE_Y.y - BRK_TONGUE_Y.x;
    float hw = mix(T.z, T.y, clamp((q.y - BRK_TONGUE_Y.x) / h, 0.0, 1.0));
    float slope = (T.y - T.z) / h;
    float dSide = (abs(q.x - T.x) - hw) / sqrt(1.0 + slope * slope);
    return smaxK(dSide, BRK_TONGUE_Y.x - q.y, T.w * 1.7);
}

// the display ribbon (board plane, p = x z): ONE strip along a centre line -- a leg along +z, a bend of RIB_A's angle toward +x, a straight stretch along
// that heading, a bend of the same angle back to +z, a leg along +z (RIB_P: the first leg's x, where the first bend starts, the bends' radius, the
// straight stretch between them) -- as wide as RIB_W. ribbonSd is the signed distance to its outline (mm, < 0 inside); it leaves the point's signed offset
// across the strip in gRibU (positive on the +x side of the +z legs: the side the first bend's centre is on) and the arc length along the centre line from
// the strip's start in gRibS (the fade's coordinate): the conductors lie at fixed offsets from the centre line, so they run concentric through the bends
// and cannot fold. The legs are told apart by planes through the bends' ends (a bend is the wedge between two of them), so no point is two legs.
float gRibU;
float gRibS;
float ribbonSd(vec2 p) {
    float R = RIB_P.z;
    vec2 d = RIB_A.xy;                                     // the stretch's heading (sin, cos of the angle: x, z)
    vec2 c1 = vec2(RIB_P.x + R, RIB_P.y);                  // the first bend's centre
    vec2 e1 = c1 + R * vec2(-d.y, d.x);                    // where the first bend ends and the straight stretch begins
    vec2 e2 = e1 + RIB_P.w * d;                            // where the stretch ends and the second bend begins
    vec2 c2 = e2 + R * vec2(-d.y, d.x);                    // the second bend's centre
    float s1 = RIB_P.y - RIB_A.w + R * RIB_A.z;            // the arc length at e1 and at e2 and where the last leg starts
    float s2 = s1 + RIB_P.w;
    float s3 = s2 + R * RIB_A.z;
    float u, s;
    if (p.y <= c1.y) {
        u = p.x - RIB_P.x;                                 // the first leg
        s = p.y - RIB_A.w;
    } else if (dot(p - e1, d) <= 0.0 || (dot(p - e2, d) > 0.0 && p.y <= c2.y)) {
        // a bend: the first (about c1, turning toward +x) or the second (about c2, turning back); one angle, one length
        bool first = dot(p - e1, d) <= 0.0;
        vec2 c = first ? c1 : c2;
        float sg = first ? 1.0 : -1.0;
        float phi = atan(sg * (p.y - c.y), sg * (c.x - p.x));       // how far round the bend (the first: from the leg; the second: from the stretch's end, backwards)
        u = sg * (R - length(p - c));
        s = first ? s1 - R * RIB_A.z + R * phi : s2 + R * (RIB_A.z - phi);
    } else if (dot(p - e2, d) <= 0.0) {
        u = dot(p - e1, vec2(d.y, -d.x));                  // the straight stretch
        s = s1 + dot(p - e1, d);
    } else {
        u = p.x - (c2.x + R);                              // the last leg
        s = s3 + p.y - c2.y;
    }
    gRibU = u;
    gRibS = s;
    return abs(u) - RIB_W * 0.5;
}
// a cable's fade: 1 at the start, 0 `CABLE_FADE_LEN` mm on; `along` is how far past the fade's own start the cable has run. The charger's cable
// (its plug's frame: along = x - CABLE_FADE_X) and the display ribbon (along = gRibS - RIB_FADE) fade by this one curve over this one length.
float cableFade(float along) {
    return 1.0 - smoothstep(0.0, CABLE_FADE_LEN, along);
}

// a box's signed distance in the plane (rect = [x0, z0, x1, z1]): exact inside, a lower bound outside
float boxSd2(vec2 p, vec4 r) {
    vec2 d = abs(p - (r.xy + r.zw) * 0.5) - (r.zw - r.xy) * 0.5;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}
// a RAM stick's plate, R = [x0, z0, x1, z1]: a rounded rectangle with a half-round notch in each short edge, and a tooth left standing in each notch (the
// hook of the socket's end wall). gTooth is the tooth's signed distance at the point (< 0 inside), for the material's metal.
float gTooth;
float stickSd(vec4 R, vec2 p) {
    float d = rrSd(p, (R.xy + R.zw) * 0.5, (R.zw - R.xy) * 0.5, RAM_STICK_R);
    vec2 q = vec2(min(p.x - R.x, R.z - p.x), p.y - RAM_NOTCH.x);      // in from the nearer short edge, and along it from the notch's centre
    float dn = length(q) - RAM_NOTCH.y;                                // inside the notch's disc: < 0
    gTooth = max(q.x - RAM_NOTCH.z, abs(q.y) - RAM_NOTCH.w);
    return max(d, min(-dn, gTooth));
}
// a RAM socket's footprint, R = [x0, z0, x1, z1 where the walls end]: the housing along the back and an end wall at each short end
float socketSd(vec4 R, vec2 p) {
    float dh = boxSd2(p, vec4(R.x, R.y, R.z, RAM_SOCK.x));
    float dl = boxSd2(p, vec4(R.x, R.y, R.x + RAM_SOCK.y, R.w));
    float dr = boxSd2(p, vec4(R.z - RAM_SOCK.y, R.y, R.z, R.w));
    return min(dh, min(dl, dr));
}

float cutSd(int part, vec3 pl) {
    if (part == PART_IOPLATE)
        return plateSd(pl.zy);
    if (part == PART_IOTONGUE)
        return tongueSd(pl.zy);
    if (part == PART_RIBBON)
        return ribbonSd(pl.xz);
    if (part == PART_RAMPCBA || part == PART_RAMPCBB)
        return stickSd(part == PART_RAMPCBA ? RAM_STICKA : RAM_STICKB, pl.xz);
    if (part == PART_RAMSOCKETA || part == PART_RAMSOCKETB)
        return socketSd(part == PART_RAMSOCKETA ? RAM_SOCKA : RAM_SOCKB, pl.xz);
    return -1.0;
}

// the distance (mm) to the nearest conductor's centre line (9 in the strip's margins, where none lies): a drawing's single line per conductor
float ribbonCondLine() {
    float v = gRibU + RIB_W * 0.5;
    float pitch = RIB_W / RIB_N;
    return (v < 0.3 || v > RIB_W - 0.3) ? 9.0 : abs(fract(v / pitch) - 0.5) * pitch;
}
// the ribbon's conductors: positive inside one, at fixed offsets across the strip (gRibU, left by ribbonSd for this very point: call that first)
float ribbonCondSd() {
    float v = gRibU + RIB_W * 0.5;                          // across from the strip's -u edge, 0 .. RIB_W
    float pitch = RIB_W / RIB_N;
    float c = abs(fract(v / pitch) - 0.5) * pitch;
    return min(0.27 - c, min(v - 0.3, RIB_W - 0.3 - v));
}
