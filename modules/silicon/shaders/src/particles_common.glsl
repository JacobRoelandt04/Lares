// =============================================================================
// particles_common.glsl -- the vertex stage's helpers and every emitter's motion (spliced into
// silicon_particles.vert after the generated geometry, which gives it the POLE_* constants,
// the TRACE_* ids, the ANCHOR_* constants and the box cast scenePrimary).
//
// A particle is a PURE FUNCTION of (id, time, the drive uniforms): nothing is stored, a film sets
// `time` per frame and gets the same picture the live scene would. Float hashes only (the bake's
// target set includes GLSL ES 100: no bit operations), no local array indexed by a loop counter.
//
// Streaks are drawn from the particle's own SCREEN velocity, got by evaluating its path a little
// later and differencing, so every emitter shapes its path freely and the streak follows it.
// =============================================================================

const vec3 CAM_R = vec3(0.70710678, 0.0, -0.70710678);
const vec3 CAM_U = vec3(-0.40824829, 0.81649658, -0.40824829);
const vec3 CAM_C = vec3(0.57735027, 0.57735027, 0.57735027);
const vec3 PLANE_N = vec3(0.70710678, 0.0, 0.70710678);     // the hologram planes face the viewer
const float TAU = 6.2831853;

vec2 project(vec3 p) {
    return vec2(cfgView.x + cfgView.z * dot(p, CAM_R), cfgView.y - cfgView.z * dot(p, CAM_U));
}

float h11(float n) {
    return fract(sin(n * 12.9898 + 4.1414) * 43758.5453);
}
vec4 h4(float n) {
    return vec4(h11(n), h11(n + 17.31), h11(n * 1.93 + 3.7), h11(n * 0.71 + 91.3));
}

// the board shader's own noise (silicon_board.frag.in), so the card's dust leaves where its
// surface has gone
float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
    vec2 i = floor(p);
    vec2 u = fract(p);
    u = u * u * (3.0 - 2.0 * u);
    return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

struct Pt {
    vec2  c;       // quad centre, item px
    vec2  d;       // unit direction of travel on screen
    float L;       // spine half length px (the head is at +d * L from the centre)
    float R;       // head radius px
    float H;       // halo radius px
    float alpha;   // life x edge x gate
    vec3  col;     // the colour it shows
    float heat;    // 0 cool .. 1 hot (a young spark)
};

Pt deadPt() {
    Pt p;
    p.c = vec2(-4000.0);
    p.d = vec2(1.0, 0.0);
    p.L = 0.0;
    p.R = 0.0;
    p.H = 0.0;
    p.alpha = 0.0;
    p.col = vec3(0.0);
    p.heat = 0.0;
    return p;
}

// fade over the last 28 px before the item's edge: nothing is cut hard at the popup's clip
float edgeFade(vec2 c) {
    float e = min(min(c.x, cfgClock.z - c.x), min(c.y, cfgClock.w - c.y));
    return smoothstep(0.0, 28.0, e);
}

// the streak of a particle that is at `pos` now and at `pos2` dt seconds later: it trails behind
// its head, so the centre of the quad is half a length back along the travel
void streak(inout Pt p, vec3 pos, vec3 pos2, float dt, float minLen, float lenPerSpeed, float width, float halo) {
    vec2 c0 = project(pos);
    vec2 v = (project(pos2) - c0) / dt;
    float sp = length(v);
    vec2 d = sp > 1.0 ? v / sp : vec2(0.0, -1.0);
    float L = 0.5 * (minLen + sp * lenPerSpeed);
    p.d = d;
    p.L = L;
    p.c = c0 - d * L;
    p.R = 0.5 * width;
    p.H = halo;
}

// a dot: no travel to draw (a streak of no length)
void dotPt(inout Pt p, vec3 pos, float radius, float halo) {
    p.d = vec2(1.0, 0.0);
    p.L = 0.0;
    p.c = project(pos);
    p.R = radius;
    p.H = halo;
}

// How far behind the face of a part that stands in front of it a point goes from seen to hidden, mm along the view: a point resting
// HIDE_FROM into a surface still shows (the poles' fields start on the terminals' faces), and by HIDE_TO it is gone. A particle that
// passes behind a part is faded out and in over that distance, never cut.
#define HIDE_FROM 0.4
#define HIDE_TO 1.4

// 1 where the camera sees the point, 0 where a part of the board stands in front of it, and a fade between: the ray comes from the
// camera's side (as the board shader's own does), so a point inside a box is behind that box's face by the distance it is inside.
//
// EVERY frame variable the cast reads is set here. The generated cast (the board's parts, as the glow casts them) reads the pose of
// every group it holds, and a variable nobody sets is UNDEFINED, not zero. A lock slide (gLockX, gShackleY) or HDMI plug pose (gHdmiOut)
// left unset puts the lock bar's box wherever the driver's registers leave it, and it hides most of the (+) terminal's field for most of every
// particle's run: a particle that appears and is gone in a blink, at any charge rate. The card, the plugs and the
// lock are left out of the cast by the flags: none of them stands near a pole, and the lock is drawn only while the charge limit is on.
float seen(vec3 p, float pkgTurn, float pkgLift) {
    gPkgTurn = pkgTurn;
    gPkgLift = pkgLift;
    gCardLift = 0.0;
    gPlugOut = 0.0;
    gHdmiOut = 0.0;
    gLeverX = 0.0;
    gLockX = 0.0;
    gShackleY = 0.0;
    gFlags = FLAG_CARD + FLAG_PLUG + FLAG_LOCK;
    scenePrimary(p + CAM_C * 400.0, -CAM_C);
    return 1.0 - smoothstep(HIDE_FROM, HIDE_TO, 400.0 - hT);
}

// ===========================================================================================
// sparks: the CPU die / the GPU die -> a 3D cone toward the hologram plane
// ===========================================================================================
#define SPARK_PROFILE 0.15      // 0: fast out and slowing, 1: lazy, quick through the middle, hanging at the top

vec3 sparkPos(vec3 P0, vec3 dir, vec3 t1, vec3 t2, float reach, float uu, float age, vec4 s, float scatter) {
    float e = mix(1.0 - (1.0 - uu) * (1.0 - uu), uu * uu * (3.0 - 2.0 * uu), SPARK_PROFILE);
    float w = 2.4 * scatter * uu;                                          // the scatter grows with age
    vec3 wob = t1 * (sin(TAU * (1.3 * age + s.y)) * w) + t2 * (sin(TAU * (1.7 * age + s.z)) * w);
    return P0 + dir * (reach * e) + wob;
}

Pt sparkParticle(float k) {
    Pt p = deadPt();
    float seed = cfgClock.y;
    float E = cfgDrive.x;
    float h0 = h11(k + seed * 17.0);
    float h1 = h11(k * 1.7 + 5.3 + seed * 3.0);
    float mote = step(0.80, h1);                                          // a fifth of them are slow, small motes: the beam's dust
    float life = cfgDrive2.y * (0.6 + 0.8 * h1) * (1.0 + 0.7 * mote);
    float local = cfgClock.x + h0 * life;
    float cyc = floor(local / life);
    float age = local - cyc * life;
    float u = age / life;
    float cm = mod(cyc, 1024.0);
    vec4 r = h4(k * 0.713 + cm * 12.9898 + seed);
    vec4 s = h4(k * 1.37 + cm * 78.233 + seed + 3.1);

    // How many live and how far they climb both follow the load: a spark is alive while the load is
    // above its own threshold (its `vigour`), and the more vigorous it is the farther it flies.
    // A change in load thins or thickens the plume through a soft gate, never a pop.
    float vig = r.z;
    float thr = cfgDrive.y + (1.0 - cfgDrive.y) * E;
    float gate = clamp((thr - vig) / 0.10, 0.0, 1.0);
    float on = smoothstep(0.45, 0.70, cfgLook.w);                         // the entrance: sparks follow the power-on
    if (gate * on <= 0.0)
        return p;
    float grow = mix(0.35, 1.0, smoothstep(0.5, 1.0, cfgLook.w));         // the plume rises as the power comes up

    float az = TAU * r.x;
    float cosA = cos(cfgAnchor.w);
    float cp = 1.0 - r.y * (1.0 - cosA);                                  // uniform over the cone's solid angle
    float sn = sqrt(max(1.0 - cp * cp, 0.0));
    vec3 dir = vec3(sn * cos(az), cp, sn * sin(az));
    vec3 t1 = normalize(cross(dir, vec3(1.0, 0.0, 0.0)));
    vec3 t2 = cross(dir, t1);
    float reach = mix(cfgDrive.z, cfgDrive.w, pow(vig, 0.75)) * grow * (1.0 - 0.38 * mote);
    float rd = cfgDrive2.x * sqrt(s.w);                                   // out of a disc on the die, so the cone has volume
    float ra = TAU * s.x;
    vec3 P0 = cfgAnchor.xyz + vec3(rd * cos(ra), 0.3, rd * sin(ra));

    float dt = 0.03;
    vec3 pos = sparkPos(P0, dir, t1, t2, reach, u, age, s, 1.0 + 1.4 * mote);
    vec3 pos2 = sparkPos(P0, dir, t1, t2, reach, min(u + dt / life, 1.0), age + dt, s, 1.0 + 1.4 * mote);

    // one pass draws the sparks behind the hologram's plane, the other those in front of it
    bool behind = dot(pos - cfgAnchor.xyz, PLANE_N) < 0.0;
    if ((cfgMesh.w < 0.5) != behind)
        return p;

    float fin = smoothstep(0.0, 0.10, u);
    float fout = 1.0 - smoothstep(0.50, 1.0, u);
    float top = 1.0 - smoothstep(52.0, 66.0, pos.y - cfgAnchor.y);        // inside the plane's reach
    float hero = step(0.94, s.w * 0.37 + r.w * 0.63) * (1.0 - mote);      // the few long bright ones
    float wid = mix(1.1, 1.7, s.y) * (1.0 + 0.5 * hero) * (1.0 - 0.35 * u) * (1.0 - 0.3 * mote);
    streak(p, pos, pos2, dt, 2.0 + 2.0 * hero - 1.0 * mote, 0.05 * (1.0 + 1.3 * hero) * (1.0 - 0.6 * mote), wid, 1.4);
    float tw = 0.82 + 0.18 * sin(TAU * (cfgClock.x * (2.0 + 2.0 * s.z) + 13.0 * s.x));
    p.alpha = fin * fout * top * gate * on * (0.85 + 0.45 * hero) * tw * (1.0 - 0.45 * mote);
    p.col = colNow.rgb;
    p.heat = (1.0 - u) * (0.6 + 0.4 * hero);
    return p;
}

// ===========================================================================================
// traces (the emitter's name; what it draws is the pack's POLES): the funnel and the swirl at the
// two terminals. The flow along the copper is the glow's pulses alone (the pulses suffice there), so these fields
// stay at the poles, close enough that the (-) pole's does not reach the CPU package.
//
// EVERY NUMBER OF A FIELD is a uniform (ParticleField.qml's charge* / discharge* properties; the layout is particles_ubo.glsl's), so the mockup's
// Particles tab can tune both fields; their defaults are in ParticleField.qml with the reasons. What stays here is the shape's form.
// ===========================================================================================
#define POLE_SWIRL_START 0.3        // the swirl's radius at its start (it grows to the tuned radius)
#define POLE_FUNNEL_FLAT 0.4        // the (+) funnel's vertical half-extent as a share of its width: the cross-section is an ellipse centred on the face's middle (the (-) funnel hangs above its origin, see terminalParticle)
#define POLE_SWIRL_LIFT 0.35        // how far the swirl's ring rises and falls about the axis, as a share of its radius (the ring is centred on the origin's height)

// the funnel (charging: drawn in) and the swirl (discharging: thrown out) at one terminal
Pt terminalParticle(float k, float W) {
    Pt p = deadPt();
    float seed = cfgClock.y;
    float src = mod(k, 2.0);                                // 0: the (-) terminal, 1: the (+) terminal
    bool charging = W > 0.0;
    float strong = (charging ? src > 0.5 : src < 0.5) ? 1.0 : 0.0;
    vec4 t0 = charging ? cfgPole0 : cfgPole4;               // density knee W, weak share, life, alpha
    vec4 tL = charging ? cfgPole3 : cfgPole7;               // lean (-), lean (+), alpha floor, soft edge
    float dens = (1.0 - exp(-abs(W) / max(t0.x, 0.1))) * mix(t0.y, 1.0, strong);
    vec4 r = h4(k * 0.57 + seed * 3.0);
    // The density is the only thing the rate scales (a particle's life, size and speed are the same at 1 W and at 100),
    // and what it scales is how many slots are alive and how strongly. The soft edge (it keeps a change of load from
    // popping slots in) is a tenth of the range at most and half the density at least: at 5 W the weak pole's whole
    // range (0.1) would be edge, and every particle of it would live at some fraction of its alpha -- and a faint particle
    // is only above what reads for the top of its fade, which looks like a blink. A particle either reads (its
    // gate x ramp is at least the floor, tL.z) or is not spawned.
    float gw = min(tL.w, 0.5 * dens);
    float gate = clamp((dens - r.w) / max(gw, 0.001), 0.0, 1.0);
    float ramp = smoothstep(0.1, 0.8, abs(W));
    float reach = cfgLook.w * 220.0;
    float live = gate * ramp;
    if (live < tL.z || reach < 4.0)
        return p;
    float h1 = h11(k * 2.3 + 8.0 + seed);
    float lifeBase = src < 0.5 ? t0.z : (charging ? cfgPole8.x : cfgPole8.y);
    float life = lifeBase * (0.7 + 0.6 * h1);
    float local = cfgClock.x + r.x * life;
    float cyc = floor(local / life);
    float age = local - cyc * life;
    float u = age / life;
    vec4 s = h4(k * 1.13 + mod(cyc, 1024.0) * 31.7 + seed);

    // the terminal's outer face (its middle: the tuned height up the face), and the way out of it: the face's normal, leaned toward +z
    vec2 tp = src < 0.5 ? POLE_MINUS_AT : POLE_PLUS_AT;
    vec2 nrm = src < 0.5 ? POLE_MINUS_DIR : POLE_PLUS_DIR;
    float lean = src < 0.5 ? tL.x : tL.y;
    vec2 ax = vec2(nrm.x * cos(lean), nrm.y * cos(lean) + sin(lean));
    vec4 t2 = charging ? cfgPole2 : cfgPole6;
    float oy = charging ? (src < 0.5 ? t2.z : cfgPole8.z) : t2.y;      // the charging field's height: the (-) funnel's own, the (+) funnel's own (cfgPole8.z)
    float size = charging ? t2.w : t2.z;
    vec3 O = vec3(tp.x, oy, tp.y);
    vec3 axis = vec3(ax.x, 0.0, ax.y);
    vec3 side = vec3(-ax.y, 0.0, ax.x);

    float al;
    float dt = 0.03;
    vec3 pos, pos2;
    float u2 = min(u + dt / life, 1.0);
    if (charging) {
        // drawn in along the field lines of a funnel: wide mouth out at its reach, pinched at the terminal
        float D = src < 0.5 ? cfgPole1.x : cfgPole1.y;
        float k1 = sqrt(s.x);
        float phi0 = TAU * (s.y + cfgPole2.y * u);          // the twist: turns about the axis on the way in (none at rest)
        float phi1 = TAU * (s.y + cfgPole2.y * u2);
        float a0 = 1.0 - u * u;
        float a1 = 1.0 - u2 * u2;
        float mouth = src < 0.5 ? cfgPole1.z : cfgPole1.w;
        float w0 = cfgPole2.x + mouth * k1 * pow(a0, 2.2);
        float w1 = cfgPole2.x + mouth * k1 * pow(a1, 2.2);
        // the cross-section's height: the (-) funnel hangs above its origin (0..w: the cast hides what nears that face, and a funnel centred on the
        // face's middle would fade out a millimetre early), the (+) one is an ellipse centred on the face's middle
        vec2 fy = src < 0.5 ? vec2(0.5, 0.5) : vec2(0.0, POLE_FUNNEL_FLAT);
        pos = O + axis * (D * a0) + side * (w0 * cos(phi0)) + vec3(0.0, w0 * (fy.x + fy.y * sin(phi0)), 0.0);
        pos2 = O + axis * (D * a1) + side * (w1 * cos(phi1)) + vec3(0.0, w1 * (fy.x + fy.y * sin(phi1)), 0.0);
        al = smoothstep(0.0, 0.25, u) * (1.0 - smoothstep(0.88, 1.0, u));
    } else {
        // thrown out and swirling as it goes: a ring about the axis, centred on the origin's height, opening as it travels. The (+) field's reach is
        // SHORT on purpose: it runs straight out along +x and the charger's first capacitor stands 6.7 mm from the face, so the particle has faded
        // out (the end of its life is its reach) before it gets there -- a baked part cannot hide a particle, the fade has to
        float D = src < 0.5 ? cfgPole5.x : cfgPole5.y;
        float turns = (s.z < 0.5 ? 1.0 : -1.0) * mix(cfgPole5.w, cfgPole6.x, s.w);
        float rad = src < 0.5 ? cfgPole5.z : cfgPole6.w;
        float e0 = 1.0 - (1.0 - u) * (1.0 - u);
        float e1 = 1.0 - (1.0 - u2) * (1.0 - u2);
        float w0 = (POLE_SWIRL_START + rad * s.x) * smoothstep(0.0, 0.85, u);
        float w1 = (POLE_SWIRL_START + rad * s.x) * smoothstep(0.0, 0.85, u2);
        float g0 = TAU * (s.y + turns * u);
        float g1 = TAU * (s.y + turns * u2);
        pos = O + axis * (D * e0) + side * (w0 * cos(g0)) + vec3(0.0, POLE_SWIRL_LIFT * w0 * sin(g0), 0.0);
        pos2 = O + axis * (D * e1) + side * (w1 * cos(g1)) + vec3(0.0, POLE_SWIRL_LIFT * w1 * sin(g1), 0.0);
        al = smoothstep(0.0, 0.10, u) * (1.0 - smoothstep(0.35, 1.0, u));
    }
    streak(p, pos, pos2, dt, 2.2, 0.05, mix(1.2, 1.9, s.w) * size, 1.4);
    // What hides a particle is asked at the end of its streak NEAREST THE TERMINAL: a discharging one leaves from behind the terminal's edge,
    // and it is its tail that is last to clear it (the head alone clears it while the tail is still drawn over the edge); a charging one goes
    // in, and its head is the end that sinks behind it. The tail is held to the face's plane: the (+) face looks at the camera, and a tail still
    // inside the box would hide a particle that has already left it (it pops in); the (-) face is turned away, and there the face's own point is
    // what the pack's edge hides. One call site either way (the cast is the vertex stage's compile cost).
    vec2 c0 = project(pos);
    float dpx = max(length(project(pos2) - c0), 1e-3);
    vec3 tail = pos - (pos2 - pos) * (2.0 * p.L / dpx);
    tail -= axis * min(dot(tail - O, axis), 0.0);           // never farther back than the face itself: a streak's tail that starts inside the terminal would hide a particle that has left it
    tail.y = max(tail.y, 0.25);                             // and never under the board: a ring's fast climb would put an extrapolated tail below it, and the board would hide the particle for a frame
    p.alpha = live * al * t0.w * seen(charging ? pos : tail, cfgDrive.z, cfgDrive.w);
    p.col = charging ? colAux.rgb : colNow.rgb;
    p.heat = charging ? u : 1.0 - u;
    return p;
}

Pt traceParticle(float k) {
    float W = cfgDrive.x;
    if (abs(W) < 0.1)
        return deadPt();
    return terminalParticle(k, W);
}

// ===========================================================================================
// card: the card dissolving into particles, condensing back the other way
// ===========================================================================================
Pt cardParticle(float k) {
    Pt p = deadPt();
    float D = cfgDrive.x;
    if (D <= 0.0)
        return p;
    float seed = cfgClock.y;
    vec4 r = h4(k * 0.77 + seed * 5.0);
    vec4 s = h4(k * 1.31 + 13.7 + seed);
    vec2 q = vec2(mix(cfgCard.x, cfgCard.z, r.x), mix(cfgCard.y, cfgCard.w, r.y));
    // the board shader's dissolve: the surface at q has gone once D passes theta
    float theta = (vnoise(q * 0.35) * 0.65 + vnoise(q * 1.3) * 0.35) / 1.05;
    float dlt = mix(0.20, 0.46, r.z);
    float f = (D - theta) / dlt;                               // flight progress, 0 at the surface .. 1 gone
    if (f <= 0.0 || f >= 1.0)
        return p;
    f = clamp(f + 0.025 * sin(cfgClock.x * 3.0 + 40.0 * s.x), 0.0, 1.0);
    float chunk = step(0.82, s.w);                             // a few bigger bits among the fine dust
    float H = mix(5.0, 24.0, r.w * r.w);
    float ang = TAU * s.y + f * (2.0 + 3.0 * s.z);
    float rad = (1.2 + 5.6 * s.w) * f;
    float y0 = cfgDrive.z + cfgDrive.y + 0.3 + 1.2 * s.x;
    vec3 pos = vec3(q.x + rad * cos(ang), y0 + H * (1.0 - (1.0 - f) * (1.0 - f)), q.y + rad * sin(ang));
    float al = smoothstep(0.0, 0.10, f) * (1.0 - smoothstep(0.45, 1.0, f)) * (1.0 - smoothstep(0.85, 1.0, D));
    float tw = 0.70 + 0.30 * sin(TAU * (cfgClock.x * 1.3 + 9.0 * s.y));
    dotPt(p, pos, mix(0.65, 1.15, s.x) + 0.9 * chunk, 1.6);
    p.alpha = al * tw;
    p.col = colNow.rgb;
    p.heat = 1.0 - f;
    return p;
}

Pt particle(float k) {
    Pt p;
    if (k < 0.0 || k >= cfgMesh.y)
        return deadPt();
    float em = cfgMesh.z;
    if (em < 0.5)
        p = sparkParticle(k);
    else if (em < 1.5)
        p = traceParticle(k);
    else
        p = cardParticle(k);
    p.alpha *= edgeFade(p.c) * cfgLook.z;
    if (p.alpha < 0.004)
        return deadPt();
    return p;
}
