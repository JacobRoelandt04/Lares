.pragma library

// =============================================================================
// NetTraffic.js -- when the bar shows the network's up / down figures, and what
// they say. Pure: no Qt.
//
// THE FIGURE IS WHOLE Mbps, no unit, no decimal. Bytes become megabits (x 8 / 1e6): a link is sold in megabits and
// the popup, which says the same traffic in bytes (NetRate.js), spells its link speed
// in them. So:
//
//   appears   when either direction reaches `enterMbps` (10). A lower threshold
//             makes the figures come and go too often, and every time they do
//             the shell redraws -- so 10, where a transfer is a transfer and not
//             chatter, an ACK stream or a sync client's heartbeat.
//   stays     while either direction is at least `stayMbps` (5, half of it: a transfer
//             that wobbles around the threshold does not flap in and out)
//   leaves    after `holdReadings` readings in a row below `stayMbps` -- with the
//             shell's 1 s beat that is four seconds, counted in READINGS and not
//             in a clock of its own, so the figures leave on a reading, never
//             between two (CLAUDE.md "Figures change together"). A burst that
//             dips and comes back inside the hold never makes them flap.
//
// Three digits: a 999 Mbps cap (a gigabit link's whole range bar the last
// tenth; a figure past it reads 999 rather than growing a fourth slot).
//
// `rxBob` / `txBob` say that a direction's arrow bobs on THIS reading: while the figures are up, every
// reading bobs every direction whose figure is not 0 -- a changed figure and an equal one alike, so the
// flourish plays on the polling interval. A direction at 0 does not,
// nor does a reading while the figures are away or the one that takes them away. It is decided here,
// once per reading, so a bob is never between two readings and a host does one thing per beat.
//
// `digits` is how many digits the LARGER figure has (1..3): the pill widens by half a
// digit a side for each (AerialBarButton). It grows on the reading that needs it and
// shrinks like the figures leave -- after `holdReadings` readings in a row that need
// fewer -- so a rate wobbling around 99 / 100 does not make the pill breathe.
// =============================================================================

var ENTER_MBPS = 10;
var STAY_MBPS = 5;
var HOLD_READINGS = 4;
var CAP = 999;

function mbps(bps) {
    return bps * 8 / 1000000;
}

function fresh() {
    return { shown: false, below: 0, rx: 0, tx: 0, rxActive: false, txActive: false, rxBob: false, txBob: false, digits: 1, fewer: 0 };
}

// One reading in, the next state out. `cfg` may leave any key out.
function step(s, rxBps, txBps, cfg) {
    var enter = cfg && cfg.enterMbps !== undefined ? cfg.enterMbps : ENTER_MBPS;
    var stay = cfg && cfg.stayMbps !== undefined ? cfg.stayMbps : STAY_MBPS;
    var hold = cfg && cfg.holdReadings !== undefined ? cfg.holdReadings : HOLD_READINGS;
    var cap = cfg && cfg.cap !== undefined ? cfg.cap : CAP;

    var rxM = mbps(Math.max(0, rxBps || 0));
    var txM = mbps(Math.max(0, txBps || 0));
    var peak = Math.max(rxM, txM);

    var shown = s.shown;
    var below = s.below;
    if (!shown) {
        shown = peak >= enter;
        below = 0;
    } else if (peak >= stay) {
        below = 0;
    } else {
        below += 1;
        if (below >= hold) {
            shown = false;
            below = 0;
        }
    }
    // What is hidden is not moved: its figures keep what they last said, so a bar that is
    // not shown assigns nothing and costs nothing.
    if (!shown && !s.shown)
        return { shown: false, below: 0, rx: s.rx, tx: s.tx, rxActive: false, txActive: false, rxBob: false, txBob: false, digits: s.digits, fewer: 0 };
    var rx = Math.min(cap, Math.round(rxM));
    var tx = Math.min(cap, Math.round(txM));
    // The digits the larger figure needs; a newly shown state takes them at once.
    var need = String(Math.max(rx, tx)).length;
    var digits = s.shown ? s.digits : need;
    var fewer = s.shown ? s.fewer : 0;
    if (need >= digits) {
        digits = need;
        fewer = 0;
    } else if (++fewer >= hold) {
        digits = need;
        fewer = 0;
    }
    // Every reading of a direction that carries something is a bob, whatever it said before.
    var rxBob = shown && rx >= 1;
    var txBob = shown && tx >= 1;
    return { shown: shown, below: below, rx: rx, tx: tx, rxActive: rx >= 1, txActive: tx >= 1, rxBob: rxBob, txBob: txBob, digits: digits, fewer: fewer };
}
