.pragma library

// =============================================================================
// FlourishPresets.js -- the confirm flourish's named presets (launcher.jsonc `"flourish": "<name>"`).
//
// Each preset is a COHERENT set of LauncherTune values -- the neck's whole life from its first pixel to
// its snap and its recoil, the freed card's glide and settle, the launcher's close, the splash -- not a
// bag of knobs: every one lists the same keys, so applying one replaces the last one completely.
// `honey` is the shipped default: LauncherTune's own values ARE honey's, so a launcher.jsonc with no
// `flourish` key plays honey.
//
// The disconnect must not happen too quickly: the eye has to be able to process the movement. The substance is
// a thick, warm liquid -- honey, caramel -- that the card is pulled out of.
// What a viscous strand does, and what the keys below say:
//   1  it is PULLED OUT SLOWLY and the thread thins a little at first and then all at once, until it
//      cannot hold (the card speeds up for detachFrac of the rise; the pinch is exactly its end);
//   2  it SNAPS at a hair's width (qPinch) -- not at a bridge eight pixels wide;
//   3  the two ends RECOIL and ball up (retractMs, bulbPx): the thread is drawn back into the card and
//      into the pool, and the launcher's close follows it, so the launcher's retreat never touches the
//      freed card;
//   4  and the freed card is THROWN: it coasts on, slowed by gravity to no speed at all at its
//      apex, hangs there the moment gravity gives it, and falls back on the same gravity, speeding up all the way, into the
//      pool -- no pause up there, no wait for the launched window.
// THE GRAVITY IS THE PRESET'S FEEL (confirmGravity, px/s^2): the rise's clock and the fall's follow from it and the geometry
// (FlourishPose.throwOf), so a preset cannot make a throw that drops like a stone: a gravity derived from
// `rise 420 ms, detach 0.95` would be more than ten times honey's. Every preset keeps a hang
// that can be seen, on the geometry of a 9-row launcher.
// THE HANG. The card needs time at low velocities, high speeds, and room to decelerate and accelerate down again without
// slowdown. On one parabola these come from two numbers:
//   the card is slow for 2 s / g (under a speed s) and 2 sqrt(2 e / g) (within e px of the apex): gravity alone, not the height
//   it goes fast at sqrt(2 g (1 - a) H) off the strand and sqrt(2 g D) on the bar: the height
// so a lower gravity gives the hang and a higher apex gives the speed back. The gravity is 9.81 m/s^2, on a bigger world: 9.81 x 1296 / metres,
//   honey and classic   4 m   3179 -> 3200 px/s^2      syrup   3.5 m   3633 -> 3600      dew   3 m   4238 -> 4200
// and the apex stands 430 to 500 px over the launcher's face, 80 px under the top bar on 9 rows.
// THE PRICE IS THE CLOCK, and it cannot be got around: 170 ms within 8 px of the apex is a gravity of 2200, and from there no launch over 1077 px/s comes
// in under about 1.8 s from Enter to the contact, whatever the apex. These are the middle of that trade; 'gravity px/s2' on the panel moves along it.
// Numbers a person notices, on a launcher of 9 rows:
//              launch      landing     apex    contact   within 8 px   under 200 px/s   (all from Enter)
//   classic    1405 px/s   2640 px/s   972 ms  1797 ms   141 ms        125 ms
//   honey      1462        2640        983     1808      141           125
//   syrup      1505        2761        893     1660      133           111
//   dew        1616        2926        780     1476      124            95
// detachFrac is lower for the same reason as the apex is higher: the climb is long, and most of it should be free flight you can watch slow.
// The pinch is at elapsed = liftMs + detachFrac x the rise; the launcher's close starts retractMs later. detachFrac is the
// pull's share of the rise's time AND of its distance (they must be the same for the pull and the coast to agree in speed at the
// snap), so a high one is a long stretched strand and a short coast, a low one the reverse; 0.5 pulls the card up at the
// very rate gravity then slows it.
// restClearPx: how far above the launcher's face the card's apex is kept where the launcher reaches near the
// screen's centre (9 rows at 1296 design px: this decides how far the card is thrown).
// =============================================================================

var DEFAULT = "honey";

var PRESETS = {
    // Thick and slow: the strand is drawn out and snaps at a thread, the card coasts up, hangs and falls, two
    // heavy beads go up from the splash.
    honey: {
        confirmRestClearPx: 500,
        confirmLiftMs: 280,
        confirmGravity: 3200,
        confirmDetachFrac: 0.35,
        confirmNeckMidFrac: 0.6,
        confirmNeckQStartPx: 26,
        confirmNeckQPinchPx: 2,
        confirmNeckBulbPx: 14,
        confirmNeckRetractMs: 280,
        confirmNeckRetractEasing: 0,
        confirmHostCloseDelayMs: 0,
        confirmSinkMs: 110,
        confirmDroplets: 2,
        confirmDropletPx: 6.5,
        confirmDropletVx: 150,
        confirmDropletVy: 760
    },
    // Syrup: the same movements a little quicker -- still readable, less waiting.
    syrup: {
        confirmRestClearPx: 470,
        confirmLiftMs: 250,
        confirmGravity: 3600,
        confirmDetachFrac: 0.35,
        confirmNeckMidFrac: 0.6,
        confirmNeckQStartPx: 26,
        confirmNeckQPinchPx: 2.5,
        confirmNeckBulbPx: 13,
        confirmNeckRetractMs: 220,
        confirmNeckRetractEasing: 0,
        confirmHostCloseDelayMs: 0,
        confirmSinkMs: 110,
        confirmDroplets: 2,
        confirmDropletPx: 5.5,
        confirmDropletVx: 170,
        confirmDropletVy: 820
    },
    // Dew: a thin, quick liquid. A short neck, an even waist, a fast snap and recoil and a little spray.
    dew: {
        confirmRestClearPx: 430,
        confirmLiftMs: 230,
        confirmGravity: 4200,
        confirmDetachFrac: 0.3,
        confirmNeckMidFrac: 0.5,
        confirmNeckQStartPx: 22,
        confirmNeckQPinchPx: 3,
        confirmNeckBulbPx: 11,
        confirmNeckRetractMs: 160,
        confirmNeckRetractEasing: 0,
        confirmHostCloseDelayMs: 0,
        confirmSinkMs: 100,
        confirmDroplets: 3,
        confirmDropletPx: 4.5,
        confirmDropletVx: 200,
        confirmDropletVy: 900
    },
    // Classic: one long pull, the snap well up it (a shorter coast than the others), the
    // launcher let go with it. Thrown like the others: a preset picks the strand, never a stone's fall.
    classic: {
        confirmRestClearPx: 500,
        confirmLiftMs: 240,
        confirmGravity: 3200,
        confirmDetachFrac: 0.4,
        confirmNeckMidFrac: 0.9,
        confirmNeckQStartPx: 26,
        confirmNeckQPinchPx: 4,
        confirmNeckBulbPx: 12,
        confirmNeckRetractMs: 200,
        confirmNeckRetractEasing: 0,
        confirmHostCloseDelayMs: 0,
        confirmSinkMs: 110,
        confirmDroplets: 3,
        confirmDropletPx: 5.5,
        confirmDropletVx: 170,
        confirmDropletVy: 800
    }
};

function names() {
    return Object.keys(PRESETS);
}

// The preset's values, or null for a name it does not have ("" and anything else unknown).
function values(name) {
    return Object.prototype.hasOwnProperty.call(PRESETS, name) ? PRESETS[name] : null;
}

// Write the preset into a LauncherTune. false: no such preset (nothing written).
function apply(tune, name) {
    const v = values(name);
    if (!v || !tune)
        return false;
    for (const k in v)
        tune[k] = v[k];
    return true;
}
