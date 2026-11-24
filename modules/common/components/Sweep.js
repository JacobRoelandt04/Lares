.pragma library

// =============================================================================
// Sweep.js
//
// THE TWO EDGES OF AN INDETERMINATE BAND, FROM ONE LINEAR CLOCK.
//
// A language model reports no progress. What the shell says while one is
// working is therefore not "this far" but "still working", and the mark that
// says it is a BAND that crosses the box and leaves at the far side -- the
// classic loading bar -- rather than a fill that reaches the end and is cut
// back to nothing in one frame (420 px of travel in 16 ms, every 1.6 s,
// measured).
//
// One phase `f` runs 0 -> 1 LINEARLY and forever; both edges are functions of
// it. The shaping lives per edge and not on the clock, because an easing on
// the clock would shape both edges identically and the band could then never
// stretch or close. That keeps the project's rule intact -- one animated
// property per motion, never a Behavior per consumer -- while giving the two
// edges different journeys:
//
//   lead(f, head)    the LEADING edge, in motion over f in [0, head]
//   trail(f, tail)   the TRAILING edge, in motion over f in [1 - tail, 1]
//
// Both are InOutQuad within their own window and parked outside it, so each
// arrives at and leaves its park at zero velocity: the band grows out of the
// resting mark, crosses, and closes up at the far edge with nothing snapping
// at either end. `head + tail - 1` is the overlap -- the part of the trip
// where both edges move and the band travels at its full width. Below that
// sum of 1 there is a beat where the band is closed at the right end before
// the next trip starts from the mark at the left.
//
// trail(f) <= lead(f) holds for every f whenever head and tail are in (0, 1],
// so the band never inverts: the leading edge's ramp is the steeper of the
// two and starts first, and at f = 1 they meet exactly.
//
// A `.pragma library`: pure arithmetic, no QML global needed (unlike Mix.js,
// which calls Qt.rgba), so one copy is shared by every caller.
// =============================================================================

function clamp01(x) {
    return x < 0 ? 0 : (x > 1 ? 1 : x);
}

// InOutQuad, written out rather than read off an Animation: these are values
// sampled from a fraction, not animations of their own.
function io(x) {
    return x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x);
}

function lead(f, head) {
    return io(clamp01(f / Math.max(0.05, head)));
}

function trail(f, tail) {
    const t = Math.max(0.05, tail);
    return io(clamp01((f - (1 - t)) / t));
}
