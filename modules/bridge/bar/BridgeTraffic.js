.pragma library
.import "../../common/components/GlyphOutline.js" as O
.import "../../common/components/GlyphSignal.js" as S

// =============================================================================
// BridgeTraffic.js -- what crosses the bridge button's bridge (BridgePose.js; docs/contracts/bridge.md, the bar glyph): CARS,
// one dot each, on the deck between the two towers. A car is a FACT: something goes between this computer (the left tower)
// and the phone (the right one), and it drives the way the data goes. Pure functions of an age in ms; font units.
//
//   crossing(age, dir)        a car's x through one crossing (CROSS_MS), null before and after: out of one tower, into the other
//   failing(age, dir)         a car that does not get across: to mid span, a stop, back the way it came (FAIL_MS)
//   parked(f)                 the car that stands at the phone's tower while its storage is mounted (f 0..1: driving in)
//   longX(step, steps, dir)   a long run's car (a cast lasts an hour) at one of `steps` places: the host steps it a whole device
//                             pixel at a time, so a cast costs a handful of frames a second and nothing at rest
//   ring(age)                 no car: two thin waves off the phone's tower top (RING_MS), the phone made to ring
//   emit(xs, extra, px, ox, oy)   the cars at those x (and any extra contours) as one SVG path for PosedGlyph
// =============================================================================

var R = 86;                    // a car's radius: about 1.5 px across at the bar's size
var LANE = 484 + 58;           // its middle: on the deck's top edge, sunk into it a little (one piece of ink with the deck)
var FROM = 344 - 40, TO = 1536 + 40;       // from inside one tower to inside the other
var MID = 940;
var CROSS_MS = 1000;
var GAP_MS = 620;              // a convoy's cars follow each other this far apart
var FAIL_MS = 1500;
var RING_MS = 900;
var PARK = 1536 - R - 70;      // where the parked car stands, beside the phone's tower

function crossing(age, dir) {
    if (age <= 0 || age >= CROSS_MS)
        return null;
    const p = O.inOutQuad(age / CROSS_MS) * 0.35 + (age / CROSS_MS) * 0.65;
    return dir > 0 ? FROM + (TO - FROM) * p : TO - (TO - FROM) * p;
}

function failing(age, dir) {
    if (age <= 0 || age >= FAIL_MS)
        return null;
    const out = O.outCubic(age / 420);
    const back = O.inOutQuad((age - 820) / (FAIL_MS - 820));
    const p = 0.5 * out * (1 - back);
    return dir > 0 ? FROM + (TO - FROM) * p : TO - (TO - FROM) * p;
}

function parked(f) {
    return f <= 0 ? null : TO - (TO - PARK) * O.outCubic(f);
}

function longX(step, steps, dir) {
    if (step < 0 || step > steps)
        return null;
    const p = step / Math.max(1, steps);
    return dir > 0 ? FROM + (TO - FROM) * p : TO - (TO - FROM) * p;
}

function ring(age) {
    const out = [];
    for (let i = 0; i < 2; ++i) {
        const w = S.wave((age - i * 220) / (RING_MS - 220), 1622, 1084, Math.PI / 2, 70, 330, 0.95, 120);
        if (w)
            out.push(w);
    }
    return out;
}

function _disc(x) {
    const pts = [];
    for (let i = 0; i < 12; ++i) {
        const a = -i * Math.PI / 6;
        pts.push([x + R * Math.cos(a), LANE + R * Math.sin(a)]);
    }
    return O.polygon(pts);
}

function emit(xs, extra, px, ox, oy) {
    const cs = [];
    for (let i = 0; i < xs.length; ++i)
        if (xs[i] !== null && xs[i] !== undefined)
            cs.push(_disc(xs[i]));
    for (let j = 0; extra && j < extra.length; ++j)
        cs.push(extra[j]);
    return cs.length > 0 ? O.emit(cs, O.same, px / 2048, ox, oy) : "";
}
