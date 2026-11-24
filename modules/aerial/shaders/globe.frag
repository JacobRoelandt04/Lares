#version 440
// =============================================================================
// globe.frag -- the VPN globe: a translucent hologram sphere on the board's globe lens. Latitude / longitude hairlines, the land as a field of dots (one dot per cell of a
// grid whose rows are `look.x` degrees apart and whose columns thin out toward the poles, lit where the committed land mask (assets/landmask.png, Natural Earth 1:110m,
// public domain; tools/aerial/make_landmask.py) says land at the dot's centre), the near face bright and the far face seen through it faint (one loop, two faces), a rim,
// the projector's beam from the lens. The camera is the board's isometric one (R right, U up, C toward the viewer); the sphere's polar axis is the world's y, so the
// north pole leans toward the viewer by the camera's elevation. The turn: world = Ry(theta) local, theta = 45 deg + turn, which puts longitude 0 toward the viewer at
// turn 0 and makes east run to the right (modules/aerial/scene/GlobeMath.js is the same arithmetic for the lights and the picking, and the probe holds the two to each other
// by the marker below). Premultiplied: a TINT, never an additive glow (a light ground would blow out).
// =============================================================================

// QSB-NO-100ES: no GLSL ES 1.00 variant (tools/dev/bake_shaders.sh reads this line): this effect has a vertex shader of its own (globe.vert), so on an OpenGL ES context the pair links at GLSL ES 3.00.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 view;      // x, y: the item in px; z: the globe radius in px; w: family (0 Material, 1 Blueprint)
    vec4 centre;    // x, y: the globe's centre in item px; z: the turn angle (rad, the sphere about its polar axis); w: dark (1 on the dark theme)
    vec4 look;      // x: the dot spacing (deg); y: a dot's radius (px); z: the hairline step (deg); w: render scale (device px per item px)
    vec4 hue;       // rgb: the ink hue (the theme's own, BarHues); a: the strength (the entrance x presence)
    vec4 beam;      // x: the lens cap's y in item px; y: the beam's half width at the lens (px); z: its half width at the sphere (px); w: the beam's strength
    vec4 mark;      // a probe's marker: x lat, y lon (deg), z on (0 = off), w radius px
    vec4 tilt;      // x: the tilt (rad) of the sphere about the camera's right axis (0 = the pole leans to the viewer as drawn so far; positive brings the SOUTH pole toward the viewer)
};

layout(binding = 1) uniform sampler2D mask;

const vec3 CAM_R = vec3(0.70710678, 0.0, -0.70710678);
const vec3 CAM_U = vec3(-0.40824829, 0.81649658, -0.40824829);
const vec3 CAM_C = vec3(0.57735027, 0.57735027, 0.57735027);
const float DEG = 0.017453293;
const float POLAR_CAP = 1.3526301;       // 77.5 deg: the polar circle every meridian ends on

// local (the globe's own frame) <-> world
vec3 toWorld(vec3 v, float cs, float sn) {
    return vec3(v.x * cs + v.z * sn, v.y, -v.x * sn + v.z * cs);
}
vec3 toLocal(vec3 v, float cs, float sn) {
    return vec3(v.x * cs - v.z * sn, v.y, v.x * sn + v.z * cs);
}
// the tilt: a turn of the whole sphere about the camera's right axis (Rodrigues, R perpendicular to nothing in particular); +a leans the north pole AWAY from the viewer. GlobeMath.js tilt() is the same.
vec3 rotR(vec3 v, float c, float s) {
    return v * c - cross(CAM_R, v) * s + CAM_R * dot(CAM_R, v) * (1.0 - c);
}
vec3 dirOf(float lat, float lon) {
    float cl = cos(lat);
    return vec3(cl * sin(lon), sin(lat), cl * cos(lon));
}
// a line's coverage from its distance in px
float lineCov(float dPx, float hw, float aa) {
    return 1.0 - smoothstep(hw - aa, hw + aa, dPx);
}

void main() {
    float Rp = view.z;
    vec2 pp = qt_TexCoord0 * view.xy - centre.xy;
    pp.y = -pp.y;
    vec2 q = pp / Rp;
    float aa = 0.75 / (Rp * look.w);
    float dark = centre.w;
    float eva = 1.0 - view.w;
    vec3 base = hue.rgb;
    vec3 ink = mix(base * 0.62, mix(base, vec3(1.0), 0.34), dark);
    float cs = cos(centre.z + 0.78539816), sn = sin(centre.z + 0.78539816);
    float tc = cos(tilt.x), ts = sin(tilt.x);
    float r2 = dot(q, q);
    float d = sqrt(r2);

    // ---- the beam from the lens up to the sphere's foot (a haze, widest at the sphere)
    float acc = 0.0;
    vec4 outc = vec4(0.0);
    float yPx = qt_TexCoord0.y * view.y;
    if (beam.w > 0.0 && yPx > centre.y && yPx < beam.x) {
        float t = (yPx - centre.y) / max(beam.x - centre.y, 1.0);   // 0 at the sphere's middle .. 1 at the lens
        float hw = mix(beam.z, beam.y, t);
        float dx = abs(qt_TexCoord0.x * view.x - centre.x);
        float cone = (1.0 - smoothstep(hw * 0.35, hw, dx)) * smoothstep(0.0, 0.3, t) * (0.35 + 0.65 * t);
        acc = cone * beam.w * 0.16;
    }

    float alpha = 0.0;
    if (d < 1.0 + 3.0 * aa) {
        float edge = (1.0 - d) * Rp;                                     // px inside the rim
        float w0 = sqrt(max(0.0, 1.0 - r2));
        float body = 0.0;
        float inkA = 0.0;
        for (int s = 0; s < 2; s++) {
            float sg = s == 0 ? 1.0 : -1.0;
            float gain = s == 0 ? 1.0 : 0.30;
            vec3 rel = q.x * CAM_R + q.y * CAM_U + sg * w0 * CAM_C;
            vec3 loc = toLocal(rotR(rel, tc, -ts), cs, sn);
            float lat = asin(clamp(loc.y, -1.0, 1.0));
            float lon = atan(loc.x, loc.z);
            float cl = max(cos(lat), 0.0001);
            // hairlines: the distance to the nearest parallel / meridian, in px (the tangent's own compression across the view)
            float stepD = look.z;
            float pl = lat / (stepD * DEG);
            float dLat = abs(pl - floor(pl + 0.5)) * stepD * DEG;
            vec3 tLat = rotR(toWorld(vec3(-sin(lat) * sin(lon), cos(lat), -sin(lat) * cos(lon)), cs, sn), tc, ts);
            float gLat = sqrt(max(1.0 - dot(tLat, CAM_C) * dot(tLat, CAM_C), 0.01));
            float ml = lon / (stepD * DEG);
            float dLon = abs(ml - floor(ml + 0.5)) * stepD * DEG * cl;
            vec3 tLon = rotR(toWorld(vec3(cos(lon), 0.0, -sin(lon)), cs, sn), tc, ts);
            float gLon = sqrt(max(1.0 - dot(tLon, CAM_C) * dot(tLon, CAM_C), 0.01));
            float hw = mix(0.42, 0.55, view.w);
            // THE POLAR CIRCLES (round 3, the user: the meridians "just end abruptly ... usually these vertical lines terminate in a final horizontal line"): every meridian
            // runs to the parallel at POLAR_CAP and stops ON it; that parallel is drawn whatever the hairline step is
            float dCap = abs(abs(lat) - POLAR_CAP);
            float lines = max(max(lineCov(dLat * Rp * gLat, hw, 0.6 / look.w), lineCov(dCap * Rp * gLat, hw, 0.6 / look.w)),
                              abs(lat) < POLAR_CAP ? lineCov(dLon * Rp * gLon, hw, 0.6 / look.w) : 0.0);
            // the land: one dot per cell
            float S = look.x;
            float row = floor(lat / (S * DEG) + 0.5);
            float latc = row * S * DEG;
            float nlon = max(1.0, floor(360.0 * cos(latc) / S + 0.5));
            float stepLon = 6.2831853 / nlon;
            float lonc = floor(lon / stepLon + 0.5) * stepLon;
            vec3 dc = rotR(toWorld(dirOf(latc, lonc), cs, sn), tc, ts);
            float fr = sg * dot(dc, CAM_C);
            float onLand = smoothstep(0.35, 0.65, texture(mask, vec2(lonc / 6.2831853 + 0.5, 0.5 - latc / 3.1415927)).r);
            vec2 sc = vec2(dot(dc, CAM_R), dot(dc, CAM_U));
            float dpx = length(q - sc) * Rp;
            float rd = look.y * (0.55 + 0.45 * clamp(fr, 0.0, 1.0));
            float dots = lineCov(dpx, rd, 0.6 / look.w) * onLand * smoothstep(0.0, 0.12, fr);
            float lineGain = mix(0.55, 0.85, view.w);
            inkA = max(inkA, gain * max(dots * 0.95, lines * lineGain * (1.0 - 0.5 * dots)));
            // the body's wash: a faint fill, brighter toward the rim (Material), a flat wash (Blueprint)
            float rimF = pow(1.0 - w0, 2.2);
            body += gain * (eva * (0.045 + 0.16 * rimF) + view.w * 0.035);
        }
        float rim = lineCov(abs(edge - 0.3), mix(0.7, 0.55, view.w), 0.6 / look.w) * mix(0.75, 0.95, view.w);
        float inside = smoothstep(-0.5, 0.5, edge);
        alpha = max(inkA * inside, rim) ;
        float washA = body * inside;
        // light on the near face (Material): a soft shine at the upper left
        float shine = eva * pow(max(dot(normalize(q.x * CAM_R + q.y * CAM_U + w0 * CAM_C), normalize(vec3(-0.4, 0.55, 0.7))), 0.0), 8.0) * 0.14 * inside;
        vec3 wash = mix(base * 0.9, base, dark);
        vec4 o = vec4(wash * (washA + shine), washA + shine);
        // FROST: the sphere stands in front of what lies behind it (the coax, the board's window), so its disc veils the ground a little, in the ground's own tone (round 2 quality pass)
        float fa = inside * mix(0.30, 0.16, view.w) * mix(1.0, 0.75, dark);
        o = o + vec4(mix(vec3(0.94, 0.95, 0.97), vec3(0.07, 0.08, 0.10), dark) * fa, fa) * (1.0 - o.a);
        o = vec4(ink * alpha, alpha) + o * (1.0 - alpha);
        outc = o;
    }
    // the beam under the sphere
    outc = outc + vec4(ink * acc, acc) * (1.0 - outc.a);

    // ---- a probe's marker, by the shader's own arithmetic: a magenta disc where lat / lon lands
    if (mark.z > 0.5) {
        vec3 wm = rotR(toWorld(dirOf(mark.x * DEG, mark.y * DEG), cs, sn), tc, ts);
        vec2 sm = vec2(dot(wm, CAM_R), dot(wm, CAM_U));
        float dm = length(q - sm) * Rp;
        float on = (1.0 - smoothstep(mark.w - 0.5, mark.w + 0.5, dm)) * step(0.0, dot(wm, CAM_C));
        outc = mix(outc, vec4(1.0, 0.0, 1.0, 1.0), on);
    }

    fragColor = outc * (hue.a * qt_Opacity);
}
