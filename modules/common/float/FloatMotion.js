.pragma library

// =============================================================================
// FloatMotion.js -- one card's float: the Balatro sway, a pointer tilt and a lift, and the deal that brings a hand of cards in. Pure: the popup's one clock
// (FloatClock) calls step() through each FloatCard, nothing here knows Qt, and node can hold its laws. The numbers are a FloatStyle's.
//
// THE PHASE IS INTEGRATED. A sin(t * freq + phase) with `freq` eased towards a new target every few seconds has the speed
// d/dt (t * freq) = freq + t * dfreq/dt: the term with `t` in it grows for as long as the widget stays open, so a card that drifts at 0.2 rad/s when it opens
// would be shaking after ten minutes. So every oscillator keeps a phase and adds freq * dt to it, and its speed IS `freq`, at any age.
//
// Three oscillators per card (x, y, the rotation), each with its own phase, amplitude and speed, each rolling new targets on its own period, eased InOutSine. tilt and lift are springs towards what the pointer asks: a little under critical, so a card settles with one small overshoot.
// =============================================================================

// A small seeded generator, so that a card's float is the same in every run of a render.
function rng(seed) {
    var a = (seed * 2654435761) >>> 0;
    return function () {
        a = (a + 0x6D2B79F5) >>> 0;
        var t = a;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

function _range(r, lo, hi) {
    return lo + (hi - lo) * r();
}

// `kind` names the ranges in p: "move" or "rot". They are read at every roll, so a panel's slider reaches a card that is already floating.
function _rollAmp(r, kind, p) {
    return kind === "move" ? _range(r, p.moveAmpMin, p.moveAmpMax) : _range(r, p.rotAmpMin, p.rotAmpMax);
}
function _rollFreq(r, kind, p) {
    return kind === "move" ? _range(r, p.moveFreqMin, p.moveFreqMax) : _range(r, p.rotFreqMin, p.rotFreqMax);
}
function _osc(r, kind, p) {
    var a = _rollAmp(r, kind, p);
    var f = _rollFreq(r, kind, p);
    return { kind: kind, ph: r() * 2 * Math.PI, a0: a, a1: a, f0: f, f1: f, t: 0, dur: _range(r, p.retargetMin, p.retargetMax), amp: a, freq: f, v: 0 };
}

// p: { moveAmpMin, moveAmpMax, moveFreqMin, moveFreqMax, rotAmpMin, rotAmpMax, rotFreqMin, rotFreqMax, retargetMin, retargetMax, tiltStiffness, tiltDamping }
function make(seed, p) {
    var r = rng(seed);
    return {
        r: r,
        x: _osc(r, "move", p),
        y: _osc(r, "move", p),
        rot: _osc(r, "rot", p),
        tx: { v: 0, d: 0 }, ty: { v: 0, d: 0 }, lift: { v: 0, d: 0 },
        age: 0
    };
}

function _stepOsc(o, dt, p, r) {
    o.t += dt;
    if (o.t >= o.dur) {
        o.a0 = o.a1;
        o.f0 = o.f1;
        o.a1 = _rollAmp(r, o.kind, p);
        o.f1 = _rollFreq(r, o.kind, p);
        o.t = 0;
        o.dur = _range(r, p.retargetMin, p.retargetMax);
    }
    var k = (1 - Math.cos(Math.PI * Math.min(1, o.t / o.dur))) / 2;
    o.amp = o.a0 + (o.a1 - o.a0) * k;
    o.freq = o.f0 + (o.f1 - o.f0) * k;
    o.ph = (o.ph + o.freq * dt) % (2 * Math.PI);
    o.v = Math.sin(o.ph) * o.amp;
}

// One spring towards `target`. Sub-stepped: a slow frame must not throw it.
function _spring(s, target, dt, k, c) {
    var n = Math.max(1, Math.ceil(dt / 0.008));
    var h = dt / n;
    for (var i = 0; i < n; i++) {
        s.d += (k * (target - s.v) - c * s.d) * h;
        s.v += s.d * h;
    }
}

// The deal: how far a card still is from its place, 1 -> 0, overshooting once (OutBack), `delay` s after the popup opened.
function dealLeft(age, delay, dur) {
    if (dur <= 0)
        return 0;
    var t = Math.max(0, Math.min(1, (age - delay) / dur));
    var c = 1.70158;
    var u = t - 1;
    return 1 - (1 + (c + 1) * u * u * u + c * u * u);
}

// Advance `st` by dt seconds. ask: { tx, ty, lift }, what the pointer wants, each -1..1 (lift 0..1).
function step(st, dt, p, ask) {
    _stepOsc(st.x, dt, p, st.r);
    _stepOsc(st.y, dt, p, st.r);
    _stepOsc(st.rot, dt, p, st.r);
    _spring(st.tx, ask.tx, dt, p.tiltStiffness, p.tiltDamping);
    _spring(st.ty, ask.ty, dt, p.tiltStiffness, p.tiltDamping);
    _spring(st.lift, ask.lift, dt, p.tiltStiffness, p.tiltDamping);
    st.age += dt;
}

// A push on the lift: a click's answer.
function kick(st, v) {
    st.lift.d += v;
}

// The springs are at their asks and nearly still: nothing the pointer asked for is still on its way, so the clock may slow to its rest beat.
// A tilt of 0.002 is 0.02 degrees at a 9 degree tilt; a lift of 0.002 is a hundredth of a pixel on a 200 px card.
function settled(st, ask) {
    const near = (s, t) => Math.abs(s.v - t) < 0.002 && Math.abs(s.d) < 0.02;
    return near(st.tx, ask.tx) && near(st.ty, ask.ty) && near(st.lift, ask.lift);
}
