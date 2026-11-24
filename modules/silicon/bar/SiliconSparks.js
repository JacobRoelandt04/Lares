.pragma library

// =============================================================================
// SiliconSparks.js -- the maths of the bar button's charge burst. No Qt in it, so the numbers a render shows are the numbers a case can pin.
//
// THE BRIEF (feedback/silicon.md, "Particles at charge events on bar"): a tiny burst
// of subtle particles, SLOW, HIGH DRAG, NOT STRETCHED. They start shimmering when they approach the
// end of their life, or near zero velocity: the shimmer is a sine-like flicker riding an overall
// downward trend in opacity, and the worst thing it can do is run in sync across the particles -- so
// every particle draws its own phase and its own frequency from random initial values.
//
// A PARTICLE IS A PURE FUNCTION OF ITS AGE. With a constant drag k (1/s) a particle that leaves at
// velocity v0 is at   x(t) = x0 + v0 * (1 - e^(-k t)) / k   and moves at   |v0| e^(-k t)   -- no
// integration step, so no frame rate leaks into the picture and a harness can pin any instant.
//
//   alpha(t) = peak * rise(u) * (1 - u)^fall * (1 - w * depth * (1 - flicker(t)))
//     u        the life fraction age / life
//     flicker  0.5 + 0.5 sin(2 pi hz t + phi)            hz, phi: this particle's own
//     w        how much of the shimmer is on: the larger of "the end of life is near"
//              (smoothstep from `shimmerFrom` to 1 over u) and "it has almost stopped"
//              (smoothstep from 2 x slowSpeed down to 0.5 x slowSpeed over its speed)
//
// The flicker only ever TAKES AWAY from the downward trend (it never lifts a particle above it), so
// the envelope still falls and the shimmer reads as the particle catching light on its way out.
// =============================================================================

var DEFAULTS = {
    count: 14,
    lifeMin: 2000,          // ms (the bar button's `sparkLifeMin` / `sparkLifeMax`)
    lifeMax: 3200,
    speedMin: 8,            // px/s at the start; the drag brings it to a crawl in about a second
    speedMax: 20,
    drag: 2.6,              // 1/s: travel is speed / drag, 3 to 8 px
    sizeMin: 1.5,           // px across; a round dot, never a streak
    sizeMax: 2.4,
    peak: 0.95,
    rise: 0.07,             // the first fraction of life the dot comes up in
    fall: 1.35,             // the downward trend's exponent
    shimmerFrom: 0.45,      // life fraction where the end-of-life shimmer begins to come on
    slowSpeed: 3.5,         // px/s: under about twice this a particle is "near zero velocity"
    depth: 0.72,            // how far the flicker can take a particle down from the trend
    hzMin: 2.4,             // each particle's own flicker frequency, Hz
    hzMax: 6.2,
    spread: 0.5             // radians the launch direction may stray from the outward normal
};

function opts(o) {
    var r = {};
    for (var k in DEFAULTS)
        r[k] = o && o[k] !== undefined ? o[k] : DEFAULTS[k];
    return r;
}

function smooth(a, b, x) {
    var t = (x - a) / (b - a);
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return t * t * (3 - 2 * t);
}

// A point on the outline of a w x h capsule (radius r = min(w, h) / 2) and the outward normal there,
// from a fraction 0..1 of the perimeter. Origin at the capsule's top-left corner.
function onCapsule(w, h, f) {
    var r = Math.min(w, h) / 2;
    var straight = Math.max(w, h) - 2 * r;
    var arc = Math.PI * r;
    var per = 2 * straight + 2 * arc;
    var s = (f - Math.floor(f)) * per;
    var horizontal = w >= h;
    var cx0, cy0, cx1, cy1;
    if (horizontal) {
        cx0 = r; cy0 = h / 2; cx1 = w - r; cy1 = h / 2;
    } else {
        cx0 = w / 2; cy0 = r; cx1 = w / 2; cy1 = h - r;
    }
    // top (or left) straight, far arc, bottom (or right) straight, near arc -- going round once
    if (s < straight) {
        return horizontal ? { x: cx0 + s, y: 0, nx: 0, ny: -1 } : { x: 0, y: cy0 + s, nx: -1, ny: 0 };
    }
    s -= straight;
    if (s < arc) {
        var a = s / r;                                   // 0..pi round the far end
        if (horizontal)
            return { x: cx1 + r * Math.sin(a), y: cy1 - r * Math.cos(a), nx: Math.sin(a), ny: -Math.cos(a) };
        return { x: cx1 - r * Math.cos(a), y: cy1 + r * Math.sin(a), nx: -Math.cos(a), ny: Math.sin(a) };
    }
    s -= arc;
    if (s < straight) {
        return horizontal ? { x: cx1 - s, y: h, nx: 0, ny: 1 } : { x: w, y: cy1 - s, nx: 1, ny: 0 };
    }
    s -= straight;
    var b = s / r;
    if (horizontal)
        return { x: cx0 - r * Math.sin(b), y: cy0 + r * Math.cos(b), nx: -Math.sin(b), ny: Math.cos(b) };
    return { x: cx0 + r * Math.cos(b), y: cy0 - r * Math.sin(b), nx: Math.cos(b), ny: -Math.sin(b) };
}

// n particles leaving the outline of a w x h capsule. `rnd` is Math.random, or a seeded one for a still.
function spawn(w, h, o, rnd) {
    var p = opts(o);
    var out = [];
    for (var i = 0; i < p.count; i++) {
        var at = onCapsule(w, h, rnd());
        var ang = Math.atan2(at.ny, at.nx) + (rnd() * 2 - 1) * p.spread;
        var speed = p.speedMin + rnd() * (p.speedMax - p.speedMin);
        out.push({
            x0: at.x,
            y0: at.y,
            vx: Math.cos(ang) * speed,
            vy: Math.sin(ang) * speed,
            life: p.lifeMin + rnd() * (p.lifeMax - p.lifeMin),
            size: p.sizeMin + rnd() * (p.sizeMax - p.sizeMin),
            // The desync: a phase anywhere on the circle and a frequency anywhere in the range, per particle.
            phi: rnd() * 2 * Math.PI,
            hz: p.hzMin + rnd() * (p.hzMax - p.hzMin)
        });
    }
    return out;
}

// Where a particle is at `ageMs`, how big and how bright; null once it is gone.
function stateAt(q, ageMs, o) {
    var p = opts(o);
    if (ageMs < 0 || ageMs >= q.life)
        return null;
    var t = ageMs / 1000;
    var u = ageMs / q.life;
    var k = p.drag;
    var travel = (1 - Math.exp(-k * t)) / k;
    var speed = Math.hypot(q.vx, q.vy) * Math.exp(-k * t);
    var trend = p.peak * smooth(0, p.rise, u) * Math.pow(1 - u, p.fall);
    var w = Math.max(smooth(p.shimmerFrom, 1, u), smooth(2 * p.slowSpeed, 0.5 * p.slowSpeed, speed));
    var flicker = 0.5 + 0.5 * Math.sin(2 * Math.PI * q.hz * t + q.phi);
    return {
        x: q.x0 + q.vx * travel,
        y: q.y0 + q.vy * travel,
        size: q.size,
        alpha: trend * (1 - w * p.depth * (1 - flicker)),
        trend: trend,
        shimmer: w,
        speed: speed
    };
}

// The longest any of these particles lives, ms: when the burst is over.
function endOf(parts) {
    var m = 0;
    for (var i = 0; i < parts.length; i++)
        m = Math.max(m, parts[i].life);
    return m;
}

// A small seeded generator for a still (mulberry32): the render harness and the cases use it.
function seeded(seed) {
    var a = seed >>> 0;
    return function () {
        a = (a + 0x6D2B79F5) >>> 0;
        var t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}
