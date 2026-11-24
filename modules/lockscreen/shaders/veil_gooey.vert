#version 440
// =============================================================================
// veil_gooey.vert -- the GOOEY TIDE veil's blob field, evaluated at the vertices.
//
// The nine blobs joined by the quadratic smooth-min are a smooth (C1) distance, so they
// are evaluated once per vertex of a coarse grid (a GridMesh, one vertex per few pixels)
// and the fragment shader reconstructs the field between them: it gets d, grad d and
// C = grad d . p_v (p measured from the item's centre, for precision) and takes
// d = A + 0.5 (G . p - C): the mean of the linear interpolant and of the blended
// first-order Taylor steps, exact for a quadratic field. A texture would do the same job
// but a ShaderEffectSource that re-grabs every tick asks Qt for a second frame per tick.
//
// The uniform block is the fragment shader's, member for member.
// =============================================================================
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
layout(location = 1) out vec4 fieldV;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  size;         // the item, item px
    vec4  stone;        // the popup: x0 y0 x1 y1
    vec4  bar;          // the bar:   x0 y0 x1 y1
    float unit;         // size.y / 1620
    float presence;
    float pourFeather;  // the entrance front's soft edge, px at 1620 high
    float opaqueMode;
    float stoneR;
    float barR;
    float joinK;        // popup <-> bar fillet
    float smoothK;      // blob <-> blob merge radius
    float stoneBlend;   // blob <-> shell merge radius, as a fraction of smoothK
    float failTint;
    float budCount;     // buds drawn: the first budCount of bud0..bud15
    float budPad;       // how far from the shell's boxes a bud reaches, merge radius included (0 = none)
    vec4  light1;       // shadowW, shadowA, bevelW, bevelA
    vec4  light2;       // lightBias, pillow, shadowDrop
    vec4  ground1;      // alpha over the desktop, vignette, haloReach, haloStrength
    vec4  cMat;
    vec4  cBevel;
    vec4  cShadow;
    vec4  cGround;
    vec4  cEdge;
    vec4  cErr;
    vec4  b0;           // blobs: cx cy r stretch
    vec4  b1;
    vec4  b2;
    vec4  b3;
    vec4  b4;
    vec4  b5;
    vec4  b6;
    vec4  b7;
    vec4  b8;
    vec4  t0;           // blobs: cos, sin of the tilt
    vec4  t1;
    vec4  t2;
    vec4  t3;
    vec4  t4;
    vec4  t5;
    vec4  t6;
    vec4  t7;
    vec4  t8;
    vec4  bud0;         // cx cy r (r 0 = not drawn)
    vec4  bud1;
    vec4  bud2;
    vec4  bud3;
    vec4  bud4;
    vec4  bud5;
    vec4  bud6;
    vec4  bud7;
    vec4  bud8;
    vec4  bud9;
    vec4  bud10;
    vec4  bud11;
    vec4  bud12;
    vec4  bud13;
    vec4  bud14;
    vec4  bud15;
    vec4  sheen;        // DETAIL: the glint's direction (xy), strength, rim width in px at 1620 high (strength 0 = off)
    float shellInset;   // the shell's boxes drawn in by this many px: it joins the union out of nothing (VeilGooey `_attach`)
};

// ---- the field: distance and outward gradient -------------------------------
void smn(inout float d, inout vec2 n, float e, vec2 ne, float k) {
    float h = max(k - abs(d - e), 0.0) / k;
    float wa = d < e ? 1.0 - 0.5 * h : 0.5 * h;
    n = mix(ne, n, wa);                      // a convex mix; normalised once, at the end
    d = min(d, e) - h * h * k * 0.25;
}

// One blob: b = (cx, cy, r, stretch), t = (cos, sin) of its tilt. r < 1: not drawn.
void blob(inout float d, inout vec2 n, vec2 p, vec4 b, vec4 t) {
    if (b.z < 0.5)
        return;
    vec2 q0 = p - b.xy;
    float lb = (min(1.0, b.w) * length(q0) - b.z) / max(1.0, b.w);
    if (lb >= d + smoothK)
        return;
    vec2 q = vec2(t.x * q0.x + t.y * q0.y, -t.y * q0.x + t.x * q0.y);
    vec2 qs = vec2(q.x, q.y * b.w);
    float len = max(length(qs), 1e-3);
    vec2 g = vec2(qs.x, qs.y * b.w) / len;               // grad of len, in the blob's frame
    float gl = max(length(g), 1e-3);
    float e0 = (len - b.z) / gl;
    vec2 gw = vec2(t.x * g.x - t.y * g.y, t.y * g.x + t.x * g.y) / gl;
    smn(d, n, e0, gw, smoothK);
}

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
    vec2 p = qt_MultiTexCoord0 * size;
    float d = 1e5;
    vec2 n = vec2(0.0, 1.0);
    blob(d, n, p, b0, t0);
    blob(d, n, p, b1, t1);
    blob(d, n, p, b2, t2);
    blob(d, n, p, b3, t3);
    blob(d, n, p, b4, t4);
    blob(d, n, p, b5, t5);
    blob(d, n, p, b6, t6);
    blob(d, n, p, b7, t7);
    blob(d, n, p, b8, t8);
    d = clamp(d, -3000.0, 3000.0);
    fieldV = vec4(d, n, dot(n, p - 0.5 * size));
}
