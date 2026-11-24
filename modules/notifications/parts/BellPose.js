.pragma library
.import "../../common/components/GlyphOutline.js" as O
.import "BellParts.js" as P

// =============================================================================
// BellPose.js -- the bell's flourish (feedback/notification.md "The flourish"): it RINGS. Pure functions of its clock
// (GlyphFlourish `t` and `kicks`, ms): `path(sleep, t, kicks, life, look, px, ox, oy)` is the bell's two parts as SVG paths.
//
//   body      swings about its crown (the loop it hangs from): struck hard and fast, then a few quick, shrinking swings -- a toy
//             bell, not a church bell's slow sway. The strike also pops it a few per cent bigger for an instant.
//   clapper   the dome under the lip HANGS from the same crown and follows the body LATE and FURTHER (`lagMs`, `swing`): it is
//             left behind when the bell is struck, then overtakes it on the way back.
//
// A RE-STRIKE (a notification while it rings: GlyphFlourish "extend") lifts the swing back to full where it stands: the phase
// runs on, only the envelope rises, over the strike's own attack, and the strongest kick wins -- so a burst rings longer, never
// harder, and never jumps. Every motion is zero at the run's first instant and its last (the envelope's end factor is on the
// clapper's undelayed clock too), so the swap with the plain glyph shows nothing. Angles are counter-clockwise in font space.
// =============================================================================

// The motion's numbers. A caller may hand overrides (`look`: a tuning pass, a probe); a member left out is this one.
var DEFAULTS = {
    amp: 24,          // deg, the strike's swing
    hz: 4.4,          // swings a second: quick and playful
    decayMs: 260,     // the swing's e-folding time: four or five swings you can see
    attackMs: 30,     // the strike's rise (a re-strike's too)
    lagMs: 45,        // how late the clapper follows
    swing: 1.5,       // how much further the clapper swings than the bell
    pop: 0.08,        // the strike's kick of scale
    popMs: 150
};
// the crown's loop (the pivot) and the bell's middle (what the pop scales about), font units
var PIVOT = [768, 1430];
var MIDDLE = [768, 600];

// A resolved look is marked (`_r`) and handed back as it is: `path` resolves once and `angle` / `scale` ask again for every sample
// (1312 calls and an object each in a three-toast run, profiled); an unset look is one shared object, never written.
var _DEFAULT_LOOK = (function () {
    const l = { _r: true };
    for (const k in DEFAULTS)
        l[k] = DEFAULTS[k];
    return l;
})();
function _look(look) {
    if (!look)
        return _DEFAULT_LOOK;
    if (look._r === true)
        return look;
    const l = { _r: true };
    for (const k in DEFAULTS)
        l[k] = look[k] !== undefined ? Number(look[k]) : DEFAULTS[k];
    return l;
}

// the envelope of one kick, `x` ms after it (delayed by the clapper's lag), ended on the undelayed clock (`xe`)
function _env(x, xe, life, l) {
    if (x <= 0 || xe >= life)
        return 0;
    return O.smooth(0, l.attackMs, x) * Math.exp(-x / l.decayMs) * (1 - xe / life);
}

// the swing at run time t (ms), `lag` ms late: the strongest kick's envelope on one running phase
function angle(t, kicks, life, look, lag) {
    const l = _look(look);
    let a = 0;
    for (let i = 0; i < kicks.length; ++i)
        a = Math.max(a, _env(t - lag - kicks[i], t - kicks[i], life, l));
    return l.amp * Math.PI / 180 * a * Math.sin(2 * Math.PI * l.hz * (t - lag) / 1000);
}

// the pop: 1 + a sine bump at every kick, the largest
function scale(t, kicks, look) {
    const l = _look(look);
    let b = 0;
    for (let i = 0; i < kicks.length; ++i) {
        const x = t - kicks[i];
        if (x > 0 && x < l.popMs)
            b = Math.max(b, Math.sin(Math.PI * x / l.popMs));
    }
    return 1 + l.pop * b;
}

// [body, clapper] at run time t: the bell (or, `sleep`, the bell with its z's) posed
function path(sleep, t, kicks, life, look, px, ox, oy) {
    const l = _look(look);
    const k = px / P.UNITS;
    const th = angle(t, kicks, life, l, 0);
    const tc = l.swing * angle(t, kicks, life, l, l.lagMs);
    const s = scale(t, kicks, l);
    const pop = function (q) {
        return [MIDDLE[0] + (q[0] - MIDDLE[0]) * s, MIDDLE[1] + (q[1] - MIDDLE[1]) * s];
    };
    const body = function (x, y) {
        return pop(O.turn(x, y, PIVOT[0], PIVOT[1], th));
    };
    const clapper = function (x, y) {
        return pop(O.turn(x, y, PIVOT[0], PIVOT[1], tc));
    };
    return [O.emit(sleep ? P.sleepBody : P.bellBody, body, k, ox, oy),
            O.emit(sleep ? P.sleepClapper : P.bellClapper, clapper, k, ox, oy)];
}
