.pragma library
.import "../../../common/components/GlyphOutline.js" as O
.import "../../../common/components/GlyphSignal.js" as S
.import "AudioParts.js" as P

// =============================================================================
// AudioPose.js -- the audio pill's flourishes (feedback/general.md "Last flourishes"): a SOUND CHECK, the family of
// GlyphSignal.js. Pure functions of the flourish's clock: `pose(text, t, life, live, look, px, ox, oy)` is the glyph `text`
// posed at t ms -- { parts: SVG paths (PosedGlyph's parts), shades: each part's share of the ink } -- and `path(...)` its
// parts alone; no parts for a glyph that has no outline here (an icon pack's: no flourish). `life(text, live)` is how long
// that glyph's play runs (the host's GlyphFlourish.ms).
//
//   speaker   THUMPS: the cone kicks out from its back edge (the pen's edge, which the bar pins: it never moves), each wave
//             it HAS is pushed outward in turn as the kick passes, and one more wave is thrown from the outermost and thins
//             to nothing. The level it shows (no wave, one, two) is in every frame: its own waves only ever shift, and the
//             thrown one is a thin crescent on the move (GlyphSignal). A speaker that makes NO SOUND -- muted, or at no
//             volume (no wave on it) -- kicks as hard and lets out a PUFF, a cartoon "poof": ONE little cloud is blown
//             out of the mouth -- fast, and then it all but stops, as air does --, and billows as it comes: its lobes swell
//             out of its body one after the other into a cumulus (a flat foot, a bumpy top, higher in front: the one
//             silhouette that is still a cloud at the bar's size, where a round lumpy thing is a dot). It hangs a moment,
//             rising, and then WEARS AWAY from its back: the lobes shrink into the body, the ones nearest the speaker
//             first, while the whole thins, and the body goes last. Air, not sound: never an arc. (And not bubbles, which
//             the two round discs that swelled and faded read as: this is one thing with a foot, a top, a front and a back,
//             it bursts out and slows, nothing swells while it goes, and no loose disc is ever left.)
//   mic       TOSSED AND CAUGHT: the cradle crouches, the capsule is thrown up out of it, turns once end over end and drops
//             back in; the cradle takes the catch on its stem like a spring, and the thud is PICKED UP: two small crescents
//             fly off either side of the capsule's head. Muted it is a dud: a small hop with a shake of the head, a small
//             catch, and nothing is picked up.
//   phones    headphones and a headset BURST: the cups are drawn in a little toward each other (the build-up), then both
//             let go -- two waves fly off each side, one after the other, and the cups are thrown apart; the headband's
//             stiffness springs them back and they ring down. The waves go OUTWARD: between the cups there are under four
//             pixels at the bar's size, where a wave is a smudge. Muted: the same squeeze and a smaller spring, and no wave.
//   whole     every other output device (a dock, a phone, a speaker box, a car, HDMI, Bluetooth) NODS to the beat: a quick
//             tilt about its middle and a small pop, smaller when muted.
//
// `live` is the half being ON (not muted). Every motion is zero at t = 0 and at t = life: there the pose IS the font's
// outline (`_rest`, the parts as checked in), to the digit.
// =============================================================================

var DEFAULTS = {
    // ---- the speaker ----
    kick: 0.2,            // the cone's stretch along its axis at the kick's peak
    kickSquash: 0.07,     // ... and how much it narrows across
    kickPeriodMs: 260,
    kickDecayMs: 140,
    push: 110,            // font units a real wave is pushed out as the kick passes it
    pushLagMs: 45,        // ... each wave this much after the one inside it
    pushMs: 150,
    waveMs: 340,          // the thrown wave's flight
    waveTravel: 360,      // font units
    waveWidth: 150,       // its thickness at its thickest (a real outer wave is 172)
    waveHalfDeg: 48,
    muted: 0.6,           // a muted half's share of the waves' push, the nod, the headphones' spring
    puffMs: 580,          // the puff's life
    puffR: 540,           // its size: the lobes' places and radii (PUFF_LOBES) are shares of this (font units; 136 are a pixel)
    puffOut: 0.3,         // the share of its life in which it is blown out: most of its way, fast, then it all but stops
    puffDrift: 80,        // how far it still drifts on after that, font units
    puffRise: 170,        // ... and how far up (it is light)
    puffBunch: 0.5,       // how close its lobes are bunched as it leaves the mouth (a share of their places): it BILLOWS out
    puffBack: 1.5,        // each lobe's swell overshoots (OutBack's s) and settles
    puffGoFrom: 0.5,      // the share of its life from which it goes: its lobes shrink away, the back ones first
    puffGather: 0.6,      // ... each drawn this share of the way in to the body as it goes (it stays ONE cloud: never loose discs)
    puffThin: 0.65,       // how much of its ink it has lost by its end (it thins as it goes; its lobes shrinking is what ends it)
    // ---- the microphone ----
    crouch: 0.08,         // the cradle's squash on its foot before the toss (a share of its height)
    crouchMs: 170,
    tossAtMs: 90,
    tossH: 500,           // how high the capsule goes, font units
    airMs: 340,           // ... and for how long
    turns: 1,             // end over end
    dudH: 150,            // a muted capsule's hop (its air time follows from the same gravity)
    dudShakeDeg: 13,
    catchDip: 0.13,       // the cradle's squash as the capsule lands
    catchPeriodMs: 200,
    catchDecayMs: 110,
    markMs: 280,          // the picked-up thud: two crescents off the capsule's head
    markFrom: 440,        // font units from the capsule's middle where each starts
    markTravel: 210,
    markWidth: 120,
    markHalfDeg: 30,
    markTiltDeg: 33,      // how far up from level they fly
    // ---- headphones, a headset ----
    squeeze: 70,          // the build-up: each cup drawn in this far, font units
    buildMs: 250,
    recoil: 150,          // ... and thrown out this far by the burst
    springPeriodMs: 190,
    springDecayMs: 150,
    burstMs: 320,         // one wave's flight
    burstGapMs: 110,      // the second wave after the first
    burstFrom: 400,       // font units from a cup's middle where a wave starts (the cup's outer face is 256 from it)
    burstTravel: 280,
    burstWidth: 130,
    burstHalfDeg: 40,
    burstTiltDeg: 8,      // up from level
    // ---- every other device ----
    nodDeg: 9,
    nodPeriodMs: 280,
    nodDecayMs: 170,
    nodPop: 0.07,
    nodPopMs: 170
};
// the speaker's waves are arcs about its mouth (the outer edges of its two at 384 and 768); where the thrown one starts (its
// middle's radius) by how many waves the speaker has: clear of the outermost at its push's peak, and of the cone's kick
var MOUTH = [768, 614];
var WAVE_FROM = [250, 585, 970];
// ... and where the puff comes out (its body's middle, right of the mouth: clear of the same) and how far it is blown, by the
// same count (a speaker with waves leaves it less room in its half of the pill)
var PUFF_FROM = [200, 520, 920];
var PUFF_TRAVEL = [400, 420, 350];
// THE PUFF'S LOBES, in shares of puffR about its body's middle (x away from the speaker, y up): its place, its radius, the
// share of the puff's life at which it swells out, and the share at which it is gone. A cumulus: the body, a lobe at its
// foot in front and one behind (their undersides level with the body's: a flat foot), one on top toward the front and a
// shoulder behind it -- no two alike, higher in front, stepping down toward the mouth it came from. The body comes out first
// and goes last; the lobes behind come out last and go first.
var PUFF_LOBES = [
    [0, 0, 0.50, 0, 1],
    [0.48, -0.16, 0.34, 0.04, 0.9],
    [0.10, 0.46, 0.36, 0.07, 0.96],
    [-0.36, 0.24, 0.30, 0.10, 0.8],
    [-0.52, -0.22, 0.28, 0.13, 0.68]
];
// the microphone: its stem's foot (what the cradle is squashed on), the capsule's seat (its lowest point) and its middle
var FOOT_Y = -196;
var SEAT_Y = 400;
var CAPSULE = [596, 912];
// headphones: the band's top is the glyph's top; the cups' tops stand 940 under it, their faces 256 either side of the middle,
// a cup's middle 512 either side and 342 under its top; the band is straight (it moves whole with its cup) up to 172 over the cup
var PHONES = { cx: 768, cupTop: 940, cupX: 512, cupMid: 342, straight: 172 };

// one play's length, ms (the host's GlyphFlourish.ms): by what the glyph does
function life(text, live) {
    const g = P.G[S.key(text)];
    if (!g)
        return 600;
    if (g.kind === "speaker")
        return live && g.parts.length > 1 ? 620 : throwStart(g.parts.length - 1, DEFAULTS) + DEFAULTS.puffMs + 20;
    if (g.kind === "mic")
        return live ? 760 : 580;
    if (g.kind === "phones")
        return 840;
    return 620;
}

function _look(look) {
    const l = {};
    for (const k in DEFAULTS)
        l[k] = look && look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}

function has(text) {
    return P.G[S.key(text)] !== undefined;
}

// the font's outline, untouched: what every pose is at its first and last instant
function _rest(g, k, ox, oy) {
    return { parts: g.parts.map(p => O.emit(p, O.same, k, ox, oy)), shades: [] };
}

// A speaker SOUNDS when it is on and shows a wave; one that does not lets out the puff.
function sounds(text, live) {
    const g = P.G[S.key(text)];
    return !!g && g.kind === "speaker" && live && g.parts.length > 1;
}

// when a speaker of `waves` waves lets out what it lets out, ms: the kick is at its peak and has passed the waves it has
function throwStart(waves, l) {
    return 60 + l.pushLagMs * waves;
}
// the thrown wave's flight share at t for a speaker of `waves` waves (0 before it leaves, 1 once it is gone)
function waveShare(t, waves, look) {
    const l = _look(look);
    return O.clamp01((t - throwStart(waves, l)) / l.waveMs);
}
// ... and the puff's
function puffShare(t, waves, look) {
    const l = _look(look);
    return O.clamp01((t - throwStart(waves, l)) / l.puffMs);
}

// The puff's lobes at share x of its life, as discs [x, y, r] in font units (their outline is what is drawn: GlyphSignal
// `clump`). It is blown out of the mouth (most of the way within `puffOut`, then a slow drift on and up); each lobe swells
// OUT OF THE BODY in its turn (from inside it to its place, bunched while the puff is on its way), and from `puffGoFrom`
// shrinks to nothing by its own end, drawn back in as it does -- so the cloud wears away from its back and is one cloud to
// the last.
function puffLobes(x, waves, look) {
    const l = _look(look);
    if (x <= 0 || x >= 1)
        return [];
    const w = Math.min(2, waves);
    const out = O.outCubic(x / l.puffOut);
    const bx = MOUTH[0] + PUFF_FROM[w] + PUFF_TRAVEL[w] * out + l.puffDrift * O.smooth(0, 1, x);
    const by = MOUTH[1] + l.puffRise * x * x;
    const spread = l.puffBunch + (1 - l.puffBunch) * out;
    // how much of its size the body has left: the whole cloud is drawn in about it by as much (so no lobe is ever left loose)
    const left = 1 - O.inQuad(O.seg(x, l.puffGoFrom, PUFF_LOBES[0][4]));
    const discs = [];
    for (let i = 0; i < PUFF_LOBES.length; ++i) {
        const b = PUFF_LOBES[i];
        const swell = O.outBack(O.seg(x, b[3], b[3] + 0.2), l.puffBack), going = O.inQuad(O.seg(x, l.puffGoFrom, b[4]));
        const r = l.puffR * b[2] * swell * (1 - going);
        if (r <= 0)
            continue;
        const near = l.puffR * spread * Math.min(1, swell) * (1 - l.puffGather * going) * left;
        discs.push([bx + b[0] * near, by + b[1] * near, r]);
    }
    return discs;
}
// the puff's share of the ink at x: whole until it starts to go, thinner as it does
function puffShade(x, look) {
    const l = _look(look);
    return x <= 0 || x >= 1 ? 0 : 1 - l.puffThin * O.smooth(l.puffGoFrom, 1, x);
}

function _speaker(g, t, life, live, l, k, ox, oy) {
    const waves = g.parts.length - 1;
    const sounding = live && waves > 0;
    const p = S.thump(t, life, l.kickPeriodMs, l.kickDecayMs);
    const out = [O.emit(g.parts[0], S.scaled(0, MOUTH[1], 1 + l.kick * p, 1 - l.kickSquash * p), k, ox, oy)];
    const shades = [];
    const a = live ? 1 : l.muted;
    for (let i = 1; i <= waves; ++i) {
        const dx = a * l.push * S.bump((t - l.pushLagMs * i) / l.pushMs);
        out.push(O.emit(g.parts[i], function (x, y) {
            return [x + dx, y];
        }, k, ox, oy));
    }
    if (sounding) {
        const w = S.wave(waveShare(t, waves, l), MOUTH[0], MOUTH[1], 0, WAVE_FROM[Math.min(2, waves)], l.waveTravel,
                         l.waveHalfDeg * Math.PI / 180, l.waveWidth);
        if (w)
            out.push(O.emit([w], O.same, k, ox, oy));
    } else {
        const x = puffShare(t, waves, l);
        const cs = S.clump(puffLobes(x, waves, l));
        if (cs.length > 0) {
            for (let i = 0; i <= waves; ++i)
                shades.push(1);
            shades.push(puffShade(x, l));
            out.push(O.emit(cs, O.same, k, ox, oy));
        }
    }
    return { parts: out, shades: shades };
}

// when a capsule thrown at tossAtMs is back in the cradle
function landMs(live, look) {
    const l = _look(look);
    return l.tossAtMs + (live ? l.airMs : l.airMs * Math.sqrt(l.dudH / l.tossH));
}
// the picked-up thud's flight share at t
function markShare(t, look) {
    const l = _look(look);
    return O.clamp01((t - landMs(true, l)) / l.markMs);
}

function _mic(g, t, life, live, l, k, ox, oy) {
    const land = landMs(live, l);
    const air = land - l.tossAtMs;
    // 0..1 through the air; the height is a throw's (one gravity for the toss and the dud)
    const p = O.clamp01((t - l.tossAtMs) / air);
    const h = (live ? l.tossH : l.dudH) * 4 * p * (1 - p);
    // end over end, clockwise, at one speed (nothing turns it in the air); the dud only shakes its head
    const th = live ? -2 * Math.PI * l.turns * p : l.dudShakeDeg * Math.PI / 180 * Math.sin(2 * Math.PI * p) * 4 * p * (1 - p);
    // the cradle on its foot: the crouch before the toss, the catch after it
    const sq = l.crouch * S.bump(t / l.crouchMs) + (live ? 1 : l.muted) * l.catchDip * S.thump(t - land, life - land, l.catchPeriodMs, l.catchDecayMs);
    // the capsule rides its seat, except in the air
    const ride = -(SEAT_Y - FOOT_Y) * sq;
    const out = [O.emit(g.parts[0], function (x, y) {
                     const q = O.turn(x, y, CAPSULE[0], CAPSULE[1], th);
                     return [q[0], q[1] + h + ride];
                 }, k, ox, oy),
                 O.emit(g.parts[1], function (x, y) {
                     return [x, FOOT_Y + (y - FOOT_Y) * (1 - sq)];
                 }, k, ox, oy)];
    if (live) {
        const x = markShare(t, l), tilt = l.markTiltDeg * Math.PI / 180, half = l.markHalfDeg * Math.PI / 180;
        const a = S.wave(x, CAPSULE[0], CAPSULE[1], tilt, l.markFrom, l.markTravel, half, l.markWidth);
        const b = S.wave(x, CAPSULE[0], CAPSULE[1], Math.PI - tilt, l.markFrom, l.markTravel, half, l.markWidth);
        if (a && b)
            out.push(O.emit([a, b], O.same, k, ox, oy));
    }
    return { parts: out, shades: [] };
}

// how far each cup stands out of its place at t (inward negative): the build-up, then the spring the burst lets go
function cupShift(t, life, live, look) {
    const l = _look(look);
    if (t <= 0 || t >= life)
        return 0;
    if (t < l.buildMs)
        return -l.squeeze * O.inOutQuad(t / l.buildMs);
    return S.sprung(t - l.buildMs, life - l.buildMs, -l.squeeze, (live ? 1 : l.muted) * l.recoil, l.springPeriodMs, l.springDecayMs);
}
// wave `i`'s (0, 1) flight share at t
function burstShare(t, i, look) {
    const l = _look(look);
    return O.clamp01((t - l.buildMs - l.burstGapMs * i) / l.burstMs);
}

function _phones(g, t, life, live, l, k, ox, oy) {
    const top = g.box[3], cupTop = top - PHONES.cupTop;
    const d = cupShift(t, life, live, l);
    // the band bends like a spring clamped at its top: nothing there, the whole shift from where it runs straight down to the cup
    const bendFrom = cupTop + PHONES.straight;
    const out = [O.emit(g.parts[0], function (x, y) {
                     const w = y <= bendFrom ? 1 : O.smooth(0, 1, (top - y) / (top - bendFrom));
                     return [x + (x < PHONES.cx ? -d : d) * w, y];
                 }, k, ox, oy)];
    if (live) {
        // a burst is its left and its right wave in one path (they are a glyph apart); the two bursts are two paths
        const cy = cupTop - PHONES.cupMid, tilt = l.burstTiltDeg * Math.PI / 180, half = l.burstHalfDeg * Math.PI / 180;
        for (let i = 0; i < 2; ++i) {
            const x = burstShare(t, i, l);
            const a = S.wave(x, PHONES.cx - PHONES.cupX, cy, Math.PI - tilt, l.burstFrom, l.burstTravel, half, l.burstWidth);
            const b = S.wave(x, PHONES.cx + PHONES.cupX, cy, tilt, l.burstFrom, l.burstTravel, half, l.burstWidth);
            if (a && b)
                out.push(O.emit([a, b], O.same, k, ox, oy));
        }
    }
    return { parts: out, shades: [] };
}

function _whole(g, t, life, live, l, k, ox, oy) {
    const a = live ? 1 : l.muted;
    const cx = (g.box[0] + g.box[2]) / 2, cy = (g.box[1] + g.box[3]) / 2;
    const th = a * l.nodDeg * Math.PI / 180 * S.thump(t, life, l.nodPeriodMs, l.nodDecayMs);
    const s = 1 + a * l.nodPop * S.bump(t / l.nodPopMs);
    return { parts: [O.emit(g.parts[0], function (x, y) {
                         const q = O.turn(x, y, cx, cy, th);
                         return [cx + (q[0] - cx) * s, cy + (q[1] - cy) * s];
                     }, k, ox, oy)], shades: [] };
}

function pose(text, t, life, live, look, px, ox, oy) {
    const g = P.G[S.key(text)];
    if (!g)
        return { parts: [], shades: [] };
    const l = _look(look);
    const k = px / P.UNITS;
    if (t <= 0 || t >= life)
        return _rest(g, k, ox, oy);
    if (g.kind === "speaker")
        return _speaker(g, t, life, live, l, k, ox, oy);
    if (g.kind === "mic")
        return _mic(g, t, life, live, l, k, ox, oy);
    if (g.kind === "phones")
        return _phones(g, t, life, live, l, k, ox, oy);
    return _whole(g, t, life, live, l, k, ox, oy);
}

function path(text, t, life, live, look, px, ox, oy) {
    return pose(text, t, life, live, look, px, ox, oy).parts;
}
