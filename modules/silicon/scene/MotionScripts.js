.pragma library

// =============================================================================
// MotionScripts.js -- silicon's motions as pure functions of time: given a motion's name and
// t (s since it started), the scene state at that instant. The films (FILMS) expand them frame by
// frame; MotionDirector plays the same curves live, so a film shows what the popup does.
//
// Every state is a plain object of SiliconScene properties layered over `base` (the resting
// state the motion starts from). No Qt here: it runs under node.
// =============================================================================

// The battery event's whole life, s: how long MotionDirector.eventS runs the event's age (the pulse runs 55 mm/s and is gone at
// 220 mm, tools/dev/silicon_event_walk.js PULSE). The director keeps a literal of its own (the mockup's wiring check reads defaults it compares as
// numbers); this is the `pulse` film's, which runs at least as long as the director's. The passive pulse trains fade
// out under the event and are all back as it ends, so a film that stopped the age early would pop them back where it stopped.
var EVENT_SECONDS = 4.0;
var EVENT_LEAD = 0.15;            // the `pulse` film's quiet start, s
var EVENT_TAIL = 0.25;            // ... and its end, with the event over (the scene shows none: the trains are all there, as the age ended)

var FILMS = {
    // a profile change: the package lifts, turns a quarter per step (clockwise going up), settles;
    // the hologram de-rezzes across the turn
    lift1: { duration: 1.4, from: { profile: 0 }, note: "Quiet -> Balanced: the package lifts, turns a quarter, settles" },
    lift2: { duration: 1.6, from: { profile: 0 }, note: "Quiet -> Performance: one lift, a half turn" },
    liftDown: { duration: 1.4, from: { profile: 1 }, note: "Balanced -> Quiet: the quarter turn back" },
    // the three profiles are a cycle: the step past Performance is Quiet, the step before Quiet is Performance. Each is ONE half turn that
    // never passes over Balanced -- on, the way the swipe was going (clockwise up), or back, the way it was going (counter-clockwise)
    liftWrapUp: { duration: 1.6, from: { profile: 2 }, note: "Performance -> Quiet (the swipe on, past the end): one lift, a half turn on in the same direction, not over Balanced" },
    liftWrapDown: { duration: 1.6, from: { profile: 0 }, note: "Quiet -> Performance (the swipe back, past the start): one lift, a half turn the other way, not over Balanced" },
    // the card leaves its slot for Integrated, and comes back
    cardOut: { duration: 1.8, from: { gpuMode: 2, dgpuAwake: 1 }, note: "Hybrid -> Integrated: the card lifts and dissolves, the tile beams its silhouette" },
    cardIn: { duration: 1.8, from: { gpuMode: 0 }, note: "Integrated -> Hybrid: the silhouette condenses into the card, it seats" },
    // a symbol change at rest (the de-rez alone), CPU and GPU
    derezCpu: { duration: 1.0, from: { profile: 1 }, note: "the CPU hologram de-rezzes from scales to shock" },
    derezGpu: { duration: 1.0, from: { gpuMode: 2, dgpuAwake: 1 }, note: "the GPU hologram de-rezzes from the Menger sponge to the Mandelbulb" },
    // the popup's entrance: power-on from the pack outward
    entrance: { duration: 1.3, from: {}, note: "power-on: traces from the pack, the chips, then the holograms flicker on" },
    // a battery event: the board-wide pulse from the pack, for its WHOLE life (EVENT_SECONDS), the passive trains fading out under it and back as it fades
    pulse: { duration: EVENT_LEAD + EVENT_SECONDS + EVENT_TAIL, from: { flowW: 0 }, note: "charge start: the pulse from the pack along the traces for its whole life; the passive pulse trains fade out under it and come back as it fades" },
    // the charger plug going in, then out (no event: the pulse film plays it whole, and it outlives this one)
    plug: { duration: 2.0, from: { plugIn: 0, flowW: -11 }, note: "the plug slides into the jack, the flow turns to charging; then out" },
    // the HDMI cable in the card's port: it unplugs and fades FIRST, then the card lifts and scatters; and the way back: the card seats, then the cable plugs in
    hdmiOut: { duration: 2.1, from: { gpuMode: 2, dgpuAwake: 1, hdmiIn: 1 }, note: "Hybrid -> Integrated with a display on the HDMI port: the cable unplugs and fades, then the card lifts and dissolves" },
    hdmiIn: { duration: 2.2, from: { gpuMode: 0, hdmiIn: 0 }, note: "Integrated -> Hybrid with a display on the HDMI port: the card seats, then the cable plugs in" },
    // the DIP switch flip: 80 -> 100 and back
    dip: { duration: 1.6, from: { lever: 0 }, note: "the charge limit DIP flips 80 -> 100 and back" },
    // the charge limit's lock: the lever lands at "80", then the bar slides in and the shackle drops; and the way back
    lockOn: { duration: 1.2, from: { lever: 1, lock: 0 }, note: "the limit goes on: the lever lands at 80, the bar slides in across the 4th cell, the shackle drops shut" },
    lockOff: { duration: 1.0, from: { lever: 0, lock: 1 }, note: "the limit goes off: the lever and the lock leave together, the shackle opens and the bar slides out" },
    // nothing changes: the scene's own life for a while (a hologram's idle motion, the sparks)
    idle: { duration: 5.0, from: {}, note: "five seconds of the scene at rest: the hologram's idle motion" }
};

function clamp01(x) {
    return x < 0 ? 0 : (x > 1 ? 1 : x);
}
// 0..1 progress of t through [a, b]
function span(t, a, b) {
    return clamp01((t - a) / (b - a));
}
function easeInOutCubic(x) {
    return x < 0.5 ? 4 * x * x * x : 1 - Math.pow(-2 * x + 2, 3) / 2;
}
function easeOutCubic(x) {
    return 1 - Math.pow(1 - x, 3);
}
function easeInCubic(x) {
    return x * x * x;
}
function assign(a, b) {
    for (var k in b)
        a[k] = b[k];
    return a;
}

// The scene state of `name` at t seconds (merged over the film's `from` and `base`).
function stateAt(name, t, base) {
    var F = FILMS[name];
    var s = assign(assign({}, base || {}), F.from);
    s.time = t;
    // every film keeps the live phases moving so a still frame never looks frozen mid-pulse
    s.cpuPhase = t * 0.9;
    s.gpuPhase = t * 1.2;
    s.flowPhase = t * 24;
    switch (name) {
    case "lift1":
    case "lift2":
    case "liftDown": {
        var from = name === "liftDown" ? 1 : 0;
        var to = name === "lift2" ? 2 : (name === "liftDown" ? 0 : 1);
        var turnDur = Math.abs(to - from) > 1 ? 0.75 : 0.5;
        var tUp = 0.15, tTurn = 0.30, tEnd = tTurn + turnDur;       // lift, turn, set down
        var up = easeOutCubic(span(t, tUp, tUp + 0.25)) * (1 - easeInOutCubic(span(t, tEnd - 0.1, tEnd + 0.15)));
        s.pkgRise = up;
        s.pkgQuarter = from + (to - from) * easeInOutCubic(span(t, tTurn, tEnd));
        s.profile = from;
        s.cpuNextProfile = to;
        s.cpuDerez = span(t, tTurn, tEnd);
        if (t >= tEnd + 0.15) {
            s.pkgQuarter = to;
            s.pkgRise = 0;
            s.profile = to;
            s.cpuDerez = 0;
            s.cpuNextProfile = -1;
        }
        break;
    }
    case "liftWrapUp":
        assign(s, liftTurn(t, 2, 2 + stepQuarters(2, 0)));
        break;
    case "liftWrapDown":
        assign(s, liftTurn(t, 0, stepQuarters(0, 2)));
        break;
    case "cardOut": {
        // the latch releases (0.1), the card lifts and dissolves (0.15 .. 1.0), the beam rises after
        var lift = easeInCubic(span(t, 0.15, 1.0));
        s.cardLift = 34 * lift;
        s.cardDissolve = span(t, 0.35, 1.05);
        s.dgpuAwake = 1 - span(t, 0.0, 0.3);
        s.beam = easeOutCubic(span(t, 0.95, 1.45));
        s.gpuMode = t < 0.95 ? 2 : 0;
        break;
    }
    case "cardIn": {
        var back = 1 - easeOutCubic(span(t, 0.35, 1.25));
        s.cardLift = 34 * back;
        s.cardDissolve = 1 - span(t, 0.25, 0.95);
        s.beam = 1 - span(t, 0.0, 0.45);
        s.gpuMode = t < 0.45 ? 0 : 2;
        s.dgpuAwake = span(t, 1.25, 1.6);
        break;
    }
    case "derezCpu": {
        s.profile = 1;
        s.cpuNextProfile = 2;
        s.cpuDerez = span(t, 0.15, 0.75);
        if (t >= 0.75) {
            s.profile = 2;
            s.cpuDerez = 0;
            s.cpuNextProfile = -1;
        }
        break;
    }
    case "derezGpu": {
        s.gpuMode = 2;
        s.gpuNextMode = 3;
        s.gpuDerez = span(t, 0.15, 0.75);
        if (t >= 0.75) {
            s.gpuMode = 3;
            s.gpuDerez = 0;
            s.gpuNextMode = -1;
        }
        break;
    }
    case "entrance":
        s.power = span(t, 0.1, 1.2);
        break;
    case "pulse": {
        // the event's whole life, as the director plays it: the age runs 0 .. EVENT_SECONDS and then there is none
        var age = t - EVENT_LEAD;
        s.eventAge = age >= 0 && age < EVENT_SECONDS ? age : -1;
        s.eventKind = 2;
        s.flowW = t < EVENT_LEAD ? 0 : 14;
        break;
    }
    case "plug": {
        var inn = easeOutCubic(span(t, 0.1, 0.45));
        var out = easeInCubic(span(t, 1.3, 1.65));
        s.plugIn = inn * (1 - out);
        s.flowW = s.plugIn > 0.99 ? 14 : -11;
        break;
    }
    case "hdmiOut": {
        // the cable leaves over HDMI_SECONDS (from 0.1 s), and the card's own film starts when it is gone
        var hT0 = 0.1 + HDMI_SECONDS;
        assign(s, stateAt("cardOut", Math.max(0, t - hT0), base));
        s.time = t;
        s.cpuPhase = t * 0.9;
        s.gpuPhase = t * 1.2;
        s.flowPhase = t * 24;
        s.hdmiIn = plugPose(1 - span(t, 0.1, hT0));
        break;
    }
    case "hdmiIn": {
        // the card's way in (its film), then the cable plugs in over HDMI_SECONDS
        var hT1 = 1.6 + 0.1;
        assign(s, stateAt("cardIn", t, base));
        s.time = t;
        s.cpuPhase = t * 0.9;
        s.gpuPhase = t * 1.2;
        s.flowPhase = t * 24;
        s.hdmiIn = plugPose(span(t, hT1, hT1 + HDMI_SECONDS));
        break;
    }
    case "lockOn": {
        // the director's own arithmetic: the lever's linear progress p runs 1 -> 0 (it lands at t = 0.36), the lock's fraction
        // starts from the landing
        var pOn = 1 - span(t, 0.2, 0.2 + LEVER_SECONDS);
        s.lever = leverPose(pOn);
        s.lock = span(t, 0.2 + LEVER_SECONDS, 0.2 + LEVER_SECONDS + LOCK_SECONDS);
        break;
    }
    case "lockOff": {
        var pOff = span(t, 0.2, 0.2 + LEVER_SECONDS);
        s.lever = leverPose(pOff);
        s.lock = 1 - span(t, 0.2, 0.2 + LOCK_SECONDS);
        break;
    }
    case "dip": {
        var on = easeInOutCubic(span(t, 0.2, 0.36));
        var off = easeInOutCubic(span(t, 1.0, 1.16));
        s.lever = on * (1 - off);
        break;
    }
    }
    return s;
}

function frames(name, fps) {
    return Math.round(FILMS[name].duration * fps) + 1;
}

// =============================================================================
// THE LIVE DIRECTOR'S MOTIONS. These are the SAME curves as the films', with their endpoints as arguments, so MotionDirector
// can play any step -- the films show the package only for 0 -> 1, 0 -> 2 and 1 -> 0 and the card only for the Hybrid seat.
//
// A motion is a function of its OWN time `t` (s since it started); the director owns the play-head and
// may run it backwards (a write that was refused plays the way back), so every one of them is pure.
// =============================================================================

// ---- the package: lift, turn a quarter per step, set down (lift1 / lift2 / liftDown) ----
var LIFT_UP = 0.15;               // the package starts to rise
var LIFT_TURN = 0.30;             // ... and to turn

function liftTurnEnd(from, to) {
    return LIFT_TURN + (Math.abs(to - from) > 1 ? 0.75 : 0.5);
}

// the whole motion, until the package rests at `to`
function liftTurnDuration(from, to) {
    return liftTurnEnd(from, to) + 0.15;
}

// THE PACKAGE'S TURN IS IN QUARTERS, UNWRAPPED. Quiet, Balanced and Performance stand at 0, 1 and 2 quarters
// (clockwise going up); the profiles are a cycle, so a step past an end carries on round: Performance -> Quiet
// is 2 -> 4 (a half turn on, clockwise) and Quiet -> Performance is 0 -> -2 (a half turn back), neither over
// Balanced. A position is any real number of quarters; the profile it stands for is `reduceQ`.
function reduceQ(q) {
    return ((Math.round(q) % 4) + 4) % 4;
}
// The signed quarters one step from profile index `from` to `to` turns the package: the adjacent profiles a
// quarter either way, the two ends a half turn the way AWAY from Balanced (the step wraps).
function stepQuarters(from, to) {
    var d = to - from;
    return Math.abs(d) === 2 ? -d : d;
}

// quarter position `from` -> `to` (unwrapped; a quarter turn each) at t: the scene fields it drives
function liftTurn(t, from, to) {
    var tEnd = liftTurnEnd(from, to);
    var up = easeOutCubic(span(t, LIFT_UP, LIFT_UP + 0.25)) * (1 - easeInOutCubic(span(t, tEnd - 0.1, tEnd + 0.15)));
    var s = {
        pkgRise: up,
        pkgQuarter: from + (to - from) * easeInOutCubic(span(t, LIFT_TURN, tEnd)),
        profile: reduceQ(from),
        cpuNextProfile: reduceQ(to),
        cpuDerez: span(t, LIFT_TURN, tEnd)
    };
    if (t >= tEnd + 0.15) {
        s.pkgQuarter = to;
        s.pkgRise = 0;
        s.profile = reduceQ(to);
        s.cpuDerez = 0;
        s.cpuNextProfile = -1;
    }
    return s;
}

// The time at which `liftTurn(.., from, to)` has turned the package to quarter `q` (a fractional
// quarter between `from` and `to`), or null while it has not begun to turn: how a motion already in
// the air is carried on toward a further profile without a jump (one lift, one longer turn).
function liftTimeAtQuarter(q, from, to) {
    var n = to - from;
    var f = n === 0 ? 0 : (q - from) / n;
    if (!(f > 1e-6))
        return null;
    var tEnd = liftTurnEnd(from, to);
    if (f >= 1)
        return tEnd;
    var lo = 0, hi = 1;
    for (var i = 0; i < 40; i++) {
        var mid = (lo + hi) / 2;
        if (easeInOutCubic(mid) < f)
            lo = mid;
        else
            hi = mid;
    }
    return LIFT_TURN + (lo + hi) / 2 * (tEnd - LIFT_TURN);
}

// The time at which any lift has risen to `r` (0 .. 1) on its way UP (the film's own rise: ease-out over
// LIFT_UP .. LIFT_UP + 0.25): where a package that is only setting down starts again from, so the next
// step begins at the height it is at (no jump) and carries on up.
function liftTimeAtRise(r) {
    return LIFT_UP + 0.25 * (1 - Math.pow(1 - clamp01(r), 1 / 3));
}

// ---- the card: out of its slot for Integrated and back (cardOut / cardIn), from / into seated mode `m` ----
var CARD_OUT_MM = 34;             // how far it rises as it leaves

function cardOutDuration() {
    return 1.45;
}
function cardOutAt(t, m) {
    return {
        gpuMode: t < 0.95 ? m : 0,
        cardLift: CARD_OUT_MM * easeInCubic(span(t, 0.15, 1.0)),
        cardDissolve: span(t, 0.35, 1.05),
        beam: easeOutCubic(span(t, 0.95, 1.45))
    };
}

function cardInDuration() {
    return 1.25;
}
function cardInAt(t, m) {
    return {
        gpuMode: t < 0.45 ? 0 : m,
        cardLift: CARD_OUT_MM * (1 - easeOutCubic(span(t, 0.35, 1.25))),
        cardDissolve: 1 - span(t, 0.25, 0.95),
        beam: 1 - span(t, 0.0, 0.45)
    };
}

// the GPU hologram's glitch de-rez between two seated modes (derezGpu)
function derezGpuDuration() {
    return 0.75;
}
function derezGpuAt(t, from, to) {
    var s = { gpuMode: from, gpuNextMode: to, gpuDerez: span(t, 0.15, 0.75) };
    if (t >= 0.75) {
        s.gpuMode = to;
        s.gpuDerez = 0;
        s.gpuNextMode = -1;
    }
    return s;
}

// ---- the plug and the DIP lever, as a function of a LINEAR progress p (0 out .. 1 in; 0 "80" .. 1 "100") ----
// The film's plug goes in on easeOutCubic and out on 1 - easeInCubic: the same function of p, so a plug
// that turns round half way (the mains flapping) does not jump. Likewise the lever's two flips.
var PLUG_SECONDS = 0.35;
var LEVER_SECONDS = 0.16;
// the HDMI cable in the card's port goes in and out as the charger's plug does, on the same pose (plugPose), a little slower: it is
// the longer way (HDMI.travel 14 mm against the jack's 22 mm, but a plug the card's own motion has to wait for)
var HDMI_SECONDS = 0.45;

function plugPose(p) {
    return easeOutCubic(clamp01(p));
}
function leverPose(p) {
    return easeInOutCubic(clamp01(p));
}

// ---- the charge limit's lock ----
// ONE fraction drives every piece (one clock per motion): `f`, 0 disengaged .. 1 locked, moves linearly over LOCK_SECONDS and the
// pieces are pure functions of it, as the plug's and the lever's are of theirs. Engaging runs after the DIP lever has landed at "80";
// disengaging starts WITH the lever, so the way back is the way in run backwards (the shackle opens first, then the bar slides out).
//   the bar      slides in across the 4th cell's contacts over the first LOCK_BAR_END of f, on an ease-out, no bounce; it fades in
//                over the first stretch of its slide (SceneGeometry.LOCK.travel mm out it is not there at all)
//   the shackle  drops shut over the padlock's body from LOCK_SHACKLE_FROM on, overlapping the bar's last stretch, and settles
//                (a hair into the body and back)
//   the cell     dims with f itself
var LOCK_SECONDS = 0.34;
var LOCK_BAR_END = 0.62;
var LOCK_SHACKLE_FROM = 0.50;
var LOCK_SETTLE_MM = 0.35;
function lockPose(f, openMm) {
    f = clamp01(f);
    var open = openMm === undefined ? 2.6 : openMm;
    var bar = easeOutCubic(span(f, 0, LOCK_BAR_END));
    var sp = span(f, LOCK_SHACKLE_FROM, 1);
    var drop = easeOutCubic(span(sp, 0, 0.62));
    var press = Math.sin(Math.PI * span(sp, 0.55, 1));
    var a = clamp01(bar / 0.55);
    return {
        bar: bar,                                                  // 0 waiting out .. 1 home
        shackle: (1 - drop) * open - LOCK_SETTLE_MM * press,       // mm the shackle stands above its shut place
        dim: f * f * (3 - 2 * f),                                  // how far the 4th cell is dimmed
        alpha: a * a * (3 - 2 * a)                                 // how much of the lock is there
    };
}

// =============================================================================
// THE ENTRANCE, THE ZONES AND THE MOMENTS A SOUND MARKS
// =============================================================================

// ---- the entrance: power-on, from the pack outward (the `entrance` film's power curve) ----
// `stateAt("entrance", t).power` is span(t, 0.1, 1.2): the traces light from the pack, the chips after them,
// the holograms flicker on once the power is past `HoloLayer.powerFrom`. The live entrance plays the SAME
// curve from the moment the popup is mostly out, and a power-on that is asked for again carries on from the
// power it already has (entranceTimeAt).
var ENTRANCE_LEAD = 0.1;
var ENTRANCE_END = 1.2;

function entranceDuration() {
    return ENTRANCE_END;
}
function entrancePower(t) {
    return span(t, ENTRANCE_LEAD, ENTRANCE_END);
}
// the time at which the entrance has reached power `p` (0 .. 1)
function entranceTimeAt(p) {
    return ENTRANCE_LEAD + clamp01(p) * (ENTRANCE_END - ENTRANCE_LEAD);
}

// ---- a zone's daemon appears or goes: its hologram powers on / off over the entrance's own span ----
var ZONE_SECONDS = 1.1;
// ---- the MUX breath comes in and out over this ----
var BREATH_SECONDS = 0.5;

// ---- the moments a sound marks (the director's `cardLatched` / `leverFlipped` / `plugMoved`) ----
// The card's latch lets go this far into its way out (the film's own comment: "the latch releases (0.1)")
// and takes hold again where the way back crosses it; a card that never got that far never unlatched.
var LATCH_AT = 0.10;
// The DIP lever flips when its (linear) progress passes the middle of its travel, and the lever's pose
// (leverPose) is at its middle there too, because easeInOutCubic(0.5) = 0.5.
var LEVER_MIDDLE = 0.5;

// =============================================================================
// THE CARD'S PLACE AND THE HOLOGRAM'S LOOK
// =============================================================================

// ---- the card's PLACE and the hologram's LOOK are two motions ----
// One motion per step -- the card out, the card in, or the hologram's de-rez between two modes -- would be rewound by a step asked
// in the air: Integrated -> Smart -> Hybrid would turn the card that was coming round and play it again, and Hybrid -> Smart ->
// Integrated would take the card out with the look it had BEFORE Smart. So the card's place (cardOutAt / cardInAt, the films'
// own) and the hologram's look (derezGpuAt) are played apart, and the look is decided as late as it can be: while none of the hologram is drawn it simply IS the mode asked for; once it is, another mode is a de-rez.
//
// The scene colours the iGPU's beam with ITS mode (SiliconScene's beam Holo: colour = gpuColour(gpuMode)), so while any of the beam
// is drawn the scene's mode is Integrated, and the hologram's look rides in the de-rez's own slots there: (Integrated, next = the
// look, derez 1) draws the picture of `next` in `next`'s colour (the shader's derez > 0.9999), and everything that follows the
// live colour -- the glow, the sparks, the card's dust -- takes the look's colour too. For the same reason a change of look and
// the beam are never in the air together: the card waits at the edge of the beam until the de-rez has landed.
var BEAM_OUT_AT = 0.95;           // s into cardOutAt where the beam begins to rise (where the film flips gpuMode to Integrated)
var BEAM_IN_AT = 0.45;            // s into cardInAt where the beam has gone (where the film flips gpuMode to the mode)
// The look may change, unseen, while the card shows none of itself: dissolved past this, with the hologram under that much
var HOLO_UNSEEN_DISSOLVE = 0.98;  // the dust is at a twentieth of its alpha there (particles_common.glsl: 1 - smoothstep(0.85, 1, D))
var HOLO_UNSEEN_PRESENCE = 0.05;  // the slices scan in at presence x 1.3 - h x 0.3 (holo_common.glsl glitchOf): about one in twenty

// how much of the GPU hologram is drawn at a card pose { cardDissolve, beam } (SiliconScene's `presence` for it)
function holoPresence(pose) {
    return (1 - pose.beam) * (1 - pose.cardDissolve);
}
// no part of the hologram, and none of the card's dust, is on show at this pose: its look may change without anyone seeing
function holoUnseen(pose) {
    return pose.cardDissolve >= HOLO_UNSEEN_DISSOLVE && holoPresence(pose) < HOLO_UNSEEN_PRESENCE;
}
