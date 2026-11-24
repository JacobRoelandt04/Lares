.pragma library

// =============================================================================
// GooeyRipple.js -- the bar ripple: one bar's face displaced by an analytic,
// deterministic height field. The JS twin of shaders/gooey_field.frag's
// rippleFaceAt / rippleSource / ripplePacket, term for term, so the host can put
// joins and fillets on the displaced face (height, slope) and GooeyField can
// reduce the time-dependent factors to the shader's lanes once per frame
// (frame).
//
// h(s, t), s along the face, positive OUTWARD (a crest rises out of the bar):
//
//   h = win(t) * [ bulge + sum_i sum_images P_i ],  tapered at round ends,
//                                                   troughs floored softly
//   bulge  = B exp(-(s - sb)^2 / (2 w^2)) exp(-t / tauB) on(t)
//   P_i(d) = A_i exp(-gamma tt) on(tt) exp(-((d - c tt) / sigma)^2)
//            cos(k (d - c tt) + k c (1 - phaseRatio) tt),     tt = t - t0_i
//   d      = sqrt((s - q)^2 + a^2)     a SMOOTH source: no V at the impact
//   win(t) = 1 - smoothstep(Tend - fade, Tend, t)   EXACTLY 0 from Tend on
//
// The envelope rides at the group speed c and the carrier at phaseRatio * c,
// so crests run through the packet instead of riding it (capillary waves have
// phase = 2/3 group). The images q of every impact point s_i in the bar's two
// ends L0, L1 (Neumann, same sign) are unrolled by reflection order, up to
// MAX_ORDER; imageCount(p) says how many orders can reach the bar before Tend.
//
// A round end (e0, e1: its corner's reach along the face) keeps the wave off
// its corner -- the corner's ellipse would cut a crest off with a step -- and
// brings it back over as far again; a square end keeps it to the wall. A trough
// is floored by tanh so it never takes the bar below its last pixel
// (floor = thickness - 1).
//
// p (params()) = the globals of DEFAULTS, the bar's geometry { face, L0, L1,
// e0, e1, floor } and sources [{ s, t0, A }] (at most 3). Every function here
// is pure.
// =============================================================================

var MAX_SOURCES = 3;
var MAX_ORDER = 4;           // the reflection orders gooey_field.frag unrolls
var TINY = 0.05;             // gooey_field.frag's: a corner below this is square
var ENVELOPE = 4;            // sigmas past which a packet is taken as gone (e^-16)

var DEFAULTS = {
    c: 420,             // px/s  the packets' group speed
    sigma: 10,          // px    the envelope's width
    wavelength: 24,     // px    the carrier's (k = 2 pi / wavelength)
    gamma: 3,           // 1/s   the packets' damping
    phaseRatio: 2 / 3,  // the carrier's speed over the envelope's (1: rides it)
    a: 3.5,             // px    the source's smoothing
    B: 0,               // px    the bulge's height at t = 0
    w: 14,              // px    the bulge's width (its Gaussian's sigma)
    tauB: 0.25,         // s     the bulge's decay
    sb: 0,              // px    where the bulge stands, along the face
    Tend: 1.2,          // s     h is exactly 0 from here on
    fade: 0.3,          // s     the window's fade before Tend
    onset: 0            // s     each source (and the bulge) ramps in over this
};

function num(v, d) {
    const x = Number(v);
    return isFinite(x) ? x : d;
}

function smoothUp(x) {
    const t = Math.min(1, Math.max(0, x));
    return t * t * (3 - 2 * t);
}

function smoothUpSlope(x) {
    const t = Math.min(1, Math.max(0, x));
    return 6 * t * (1 - t);
}

// The bar's geometry for `face` (0 top, 1 bottom, 2 left, 3 right) from a body
// as GooeyGeometry.fieldShape hands it out (the box as DRAWN, corner insets ix /
// iy, each [tl, tr, br, bl]).
function geometry(body, face) {
    const f = Math.round(num(face, 0));
    const ix = body.ix || [0, 0, 0, 0], iy = body.iy || [0, 0, 0, 0];
    const alongX = f === 0 || f === 1;
    const thick = alongX ? body.y1 - body.y0 : body.x1 - body.x0;
    const e = [[ix[0], ix[1]], [ix[3], ix[2]], [iy[0], iy[3]], [iy[1], iy[2]]][Math.min(3, Math.max(0, f))];
    return {
        face: f,
        L0: alongX ? body.x0 : body.y0,
        L1: alongX ? body.x1 : body.y1,
        e0: e[0], e1: e[1],
        floor: Math.max(0, thick - 1)
    };
}

// The full parameter set: the globals (DEFAULTS for what is missing), the bar's
// geometry and the sources ([{ s, t0, A }] or Qt.vector4d(s, t0, A, _)).
function params(globals, geo, sources) {
    const g = globals || {};
    const p = {};
    for (const k in DEFAULTS)
        p[k] = num(g[k], DEFAULTS[k]);
    p.sigma = Math.max(0.5, p.sigma);
    p.wavelength = Math.max(1, p.wavelength);
    p.a = Math.max(0.5, p.a);
    p.w = Math.max(0.5, p.w);
    p.tauB = Math.max(1e-3, p.tauB);
    p.fade = Math.max(0, p.fade);
    p.onset = Math.max(0, p.onset);
    p.k = 2 * Math.PI / p.wavelength;
    const G = geo || {};
    p.face = Math.round(num(G.face, 0));
    p.L0 = num(G.L0, 0);
    p.L1 = num(G.L1, 0);
    p.e0 = num(G.e0, 0);
    p.e1 = num(G.e1, 0);
    p.floor = Math.max(0, num(G.floor, 0));
    p.sources = [];
    const list = sources || [];
    for (let i = 0; i < list.length && p.sources.length < MAX_SOURCES; i++) {
        const v = list[i];
        if (!v)
            continue;
        const s = v.s !== undefined ? v.s : v.x;
        const t0 = v.t0 !== undefined ? v.t0 : v.y;
        const A = v.A !== undefined ? v.A : v.z;
        p.sources.push({ s: num(s, 0), t0: num(t0, 0), A: num(A, 0) });
    }
    p.orders = imageCount(p);
    p.crest = crestBound(p);
    return p;
}

// The images of an impact point q0 of reflection order n (1..MAX_ORDER): the
// same two expressions the shader unrolls, in the same order.
function images(q0, n, L0, L1) {
    const W = L1 - L0;
    switch (n) {
    case 1: return [2 * L0 - q0, 2 * L1 - q0];
    case 2: return [q0 - 2 * W, q0 + 2 * W];
    case 3: return [2 * L0 - q0 - 2 * W, 2 * L1 - q0 + 2 * W];
    case 4: return [q0 - 4 * W, q0 + 4 * W];
    }
    return [];
}

// How many reflection orders can reach the bar before Tend: an image whose
// packet, grown to its radius at Tend plus its envelope, still falls short of
// the bar is left out. At most MAX_ORDER (what the shader unrolls).
function imageCount(p) {
    let need = 0;
    for (const src of p.sources) {
        if (!(src.A !== 0))
            continue;
        const R = p.c * Math.max(0, p.Tend - src.t0) + ENVELOPE * p.sigma + p.a;
        for (let n = 1; n <= MAX_ORDER; n++) {
            for (const q of images(src.s, n, p.L0, p.L1)) {
                const D = Math.max(p.L0 - q, q - p.L1, 0);
                if (D <= R)
                    need = Math.max(need, n);
            }
        }
    }
    return need;
}

// A HARD bound on how far a crest can rise past the face (plus a pixel): every
// term's envelope and carrier are at most 1, the taper and the window at most 1,
// and the floor only acts on troughs.
function crestBound(p) {
    let b = Math.abs(p.B);
    const terms = 1 + 2 * p.orders;
    for (const src of p.sources)
        b += Math.abs(src.A) * terms;
    return b + 1;
}

// The window: exactly 0 from Tend on.
function windowAt(p, t) {
    if (p.fade <= 0)
        return t < p.Tend ? 1 : 0;
    return 1 - smoothUp((t - (p.Tend - p.fade)) / p.fade);
}

// Whether the field has anything to draw at t: inside [0, Tend) with a bulge or
// a source that has amplitude.
function active(p, t) {
    if (!(t >= 0 && t < p.Tend))
        return false;
    if (p.B !== 0)
        return true;
    for (const src of p.sources)
        if (src.A !== 0)
            return true;
    return false;
}

// The per-frame reduction the shader's lanes carry: for each source slot
// [q0, c tt, amplitude, phase] (amplitude 0: off), the bulge [sb, amplitude,
// 1 / (2 w^2)], and the constants.
function frame(p, t) {
    const win = windowAt(p, t);
    const src = [];
    for (let i = 0; i < MAX_SOURCES; i++) {
        const s = p.sources[i];
        const tt = s ? t - s.t0 : -1;
        if (!s || !(tt >= 0) || s.A === 0 || win === 0) {
            src.push([s ? s.s : 0, 0, 0, 0]);
            continue;
        }
        const on = p.onset > 0 ? smoothUp(tt / p.onset) : 1;
        const amp = s.A * Math.exp(-p.gamma * tt) * on * win;
        const phase = (p.k * p.c * (1 - p.phaseRatio) * tt) % (2 * Math.PI);
        src.push([s.s, p.c * tt, amp, phase]);
    }
    const onB = p.onset > 0 ? smoothUp(t / p.onset) : 1;
    const Bt = t >= 0 ? p.B * Math.exp(-t / p.tauB) * onB * win : 0;
    return {
        t: t,
        win: win,
        src: src,
        bulge: [p.sb, Bt, 1 / (2 * p.w * p.w)],
        invSigma: 1 / p.sigma,
        k: p.k,
        a2: p.a * p.a,
        orders: p.orders,
        floor: p.floor,
        crest: p.crest
    };
}

// ripplePacket: one image's height and slope at x = s - q.
function packet(x, src, fr) {
    const d = Math.sqrt(x * x + fr.a2);
    const u = d - src[1];
    const v = u * fr.invSigma;
    const env = src[2] * Math.exp(-v * v);
    const arg = fr.k * u + src[3];
    const cs = Math.cos(arg);
    const dh = env * (-2 * v * fr.invSigma * cs - fr.k * Math.sin(arg));
    return [env * cs, dh * x / Math.max(d, 1e-4)];
}

// rippleSource: an impact point with its images up to fr.orders.
function source(s, src, fr, L0, L1) {
    let h = 0, hs = 0;
    function add(q) {
        const r = packet(s - q, src, fr);
        h += r[0];
        hs += r[1];
    }
    add(src[0]);
    for (let n = 1; n <= fr.orders && n <= MAX_ORDER; n++)
        for (const q of images(src[0], n, L0, L1))
            add(q);
    return [h, hs];
}

// rippleFaceAt: { h, hs, n } at s for a frame (n = 1 / sqrt(1 + hs^2), the
// factor the shader divides the face's distance by). s is clamped to the bar.
function faceAt(s0, fr, p) {
    const s = Math.min(p.L1, Math.max(p.L0, s0));
    const xb = s - fr.bulge[0];
    let h = fr.bulge[1] * Math.exp(-xb * xb * fr.bulge[2]);
    let hs = -2 * xb * fr.bulge[2] * h;
    for (let i = 0; i < MAX_SOURCES; i++) {
        if (fr.src[i][2] === 0)
            continue;
        const r = source(s, fr.src[i], fr, p.L0, p.L1);
        h += r[0];
        hs += r[1];
    }
    let T = 1, Ts = 0;
    if (p.e0 > TINY) {
        const x = (s - p.L0 - p.e0) / p.e0;
        T = smoothUp(x);
        Ts = smoothUpSlope(x) / p.e0;
    }
    if (p.e1 > TINY) {
        const x = (p.L1 - p.e1 - s) / p.e1;
        const T1 = smoothUp(x);
        Ts = Ts * T1 - T * smoothUpSlope(x) / p.e1;
        T *= T1;
    }
    let hT = h * T, hsT = hs * T + h * Ts;
    if (hT < 0) {
        if (fr.floor > 0) {
            const th = 1 - 2 / (Math.exp(-2 * hT / fr.floor) + 1);
            hT = -fr.floor * th;
            hsT *= 1 - th * th;
        } else {
            hT = 0;
            hsT = 0;
        }
    }
    return { h: hT, hs: hsT, n: 1 / Math.sqrt(1 + hsT * hsT) };
}

// The face's displacement (px, outward) and slope (dh/ds) at s, time t.
function height(s, t, p) {
    return faceAt(s, frame(p, t), p).h;
}

function slope(s, t, p) {
    return faceAt(s, frame(p, t), p).hs;
}
