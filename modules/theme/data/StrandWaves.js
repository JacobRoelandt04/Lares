.pragma library

// =============================================================================
// StrandWaves.js -- the theme popup's strands: which waves each ThemeStrands instance draws. Pure, and a .pragma library, so the count below is the
// engine's, one for every instance (it came out of FloatMotion.js when the card float moved to modules/common/float).
// =============================================================================

// ---- the strands ---------------------------------------------------------------------------------------------------------------------------------------
// Every ThemeStrands takes the next number as it is built (this file is a .pragma library, so the count is the engine's, one for all of them), which is what makes two instances
// differ with no host saying so. A count and not Math.random(): a render is the same picture in every run.
var _strands = 0;
function nextStrand() {
    _strands += 1;
    return _strands;
}

// fract(n x), the Weyl sequence: for any n it is spread evenly, and two near numbers are never near each other (the golden ratio's own property).
function _weyl(n, x) {
    return (n * x) % 1;
}
var STRAND_SPEED = 0.14;       // a strand's flow, +- this share
var STRAND_WAVE = 0.08;        // a strand's wave number, +- this share: more would change how many crests fit the gap
var _STRAND_BASE = [0, 2, 4];  // the three strands of one instance stand apart

// One instance's waves: for each of its three strands a phase (rad), and multipliers of the speed and of the wave number. Constants of `n`: nothing here reads a clock.
function strandWaves(n) {
    var irr = [0.6180339887, 0.7548776662, 0.5698402910];
    var r = { phase: [], speed: [], wave: [] };
    for (var i = 0; i < 3; i++) {
        r.phase.push(_STRAND_BASE[i] + 2 * Math.PI * _weyl(n, irr[i]));
        r.speed.push(1 + STRAND_SPEED * (2 * _weyl(n + 7, irr[(i + 1) % 3]) - 1));
        r.wave.push(1 + STRAND_WAVE * (2 * _weyl(n + 13, irr[(i + 2) % 3]) - 1));
    }
    return r;
}
