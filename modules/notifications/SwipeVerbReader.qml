pragma ComponentBehavior: Bound

import QtQuick
import "../common/scroll"

// =============================================================================
// SwipeVerbReader.qml -- the two-finger swipe for a LIST of SwipeVerbCards.
// One reader over the whole list (it fills the list area, over the rows); the
// host tells it which card is where through `rowAt(x, y)`.
//
// A swipe is a WHEEL (docs/contracts/gestures.md, whole): this is a MouseArea
// that takes no buttons and never accepts a click, so the rows keep theirs.
//
//   AXIS     picked when one is clearly ahead (1.2x) and LATCHED until the
//            fingers lift -- the zero-delta wheel event -- or, for a device
//            that never sends one, an idle timeout: `idleMs` once the gesture
//            has carried a pixel delta (a touchpad, which does lift), else
//            `mouseIdleMs` (a mouse wheel has no fingers to lift: a 6 s latch
//            would swallow the next tilt and strand a card half-swiped).
//            A vertical gesture is let through untouched (wheel.accepted =
//            false) to the list's own scroller; an undecided first event too.
//   ROW      picked at the gesture's START (the first event, whichever axis),
//            used once the gesture latches horizontal. A horizontal gesture
//            over no card is still swallowed: it is not a scroll.
//   SCRUB    the fingers' travel, `units` of wheel motion = the card's
//            commitFraction of its width, handed to the card as px; the card
//            gives and chases (SwipeVerbCard).
//   LIFT     card.release(v): v is the last 100 ms of motion, converted so
//            that `flingUnitsPerS` is the card's `flingPxPerS`.
//   NOTCH    a mouse's tilt notch (a whole notch of angle, no pixel delta)
//            commits at once, one whole swipe (gestures.md "a classic notch is
//            one item").
//   PULL     fingers `pullThrough` x units past the start commit at once,
//            without waiting for the lift.
//   HOLDING  after either, on a TOUCHPAD, the rest of that gesture is
//            swallowed until the lift: the host collapses the committed row
//            and the next one slides up under the fingers, which must not move
//            it (the next gesture does).
//   SPENT    a gesture that never carried a pixel delta (a mouse) has no lift
//            to wait for: its commit ENDS it -- `active` falls before the card
//            commits, so the host sees the decision with nothing held (R2E
//            I3.1: a notch held the lane's close for mouseIdleMs, 400 ms of a
//            full-height popup with its content emptying). The rest of that
//            tilt is still swallowed -- a tilt wheel repeats while held, and
//            one tilt is one card -- until `mouseIdleMs` passes without one;
//            a vertical wheel is a new gesture and goes through. A mouse
//            scrub under the pull-through (angle, no whole notch) is let go
//            by its idle instead, and that release ends the gesture first
//            too: whichever way a mouse's card commits, nothing is held.
//
//   active   a horizontal gesture is latched on a card (holding included):
//            the host's swipeGestureActive, and while it is true the host
//            routes the wheels that land OUTSIDE its body here through
//            gestureWheel(ev) (gestures.md section 4), which answers false
//            when no gesture is held. The lane's close waits for it too.
//
// `sign` flips what "right" is in angle units (natural scrolling: the
// fingers moving right send +x here -- the notes' swipeBackSign is the same
// question; confirm on the desktop).
// =============================================================================
WheelArea {
    id: r

    // ---- Contract (CONTRACT.md C1) -------------------------------------------------
    property var rowAt: null          // function(x, y) -> SwipeVerbCard | null (reader coords)
    property real units: 900          // wheel units to cross a card's commitFraction
    property real flingUnitsPerS: 2600
    property int idleMs: 6000         // the fallback lift of a gesture that carried pixels
    readonly property bool active: r._active
    readonly property bool holding: r._holding
    readonly property Item card: r._card

    signal committed(Item card, int direction)

    // ---- Tuning ----------------------------------------------------------------------
    property int mouseIdleMs: 400     // the "lift" of a gesture with no pixel delta
    property real pullThrough: 2.0    // x units: commits without the lift
    property real sign: 1

    function gestureWheel(ev) {
        if (!r._active)
            return false;
        r._wheel(ev.x, ev.y, ev.angleDelta, ev.pixelDelta);
        return true;
    }

    // (A CLICK of a side button goes back or on elsewhere; a verb deletes or files a notification, so it takes a swipe or a notch meant for it.)
    turned: wheel => {
        wheel.accepted = !wheel.click && r._wheel(wheel.x, wheel.y, wheel.angleDelta, wheel.pixelDelta);
    }

    // ---- The gesture -----------------------------------------------------------------
    property bool _active: false
    property bool _holding: false
    // SPENT: a mouse gesture's commit ended it; the rest of its tilt is swallowed.
    property bool _spent: false
    property SwipeVerbCard _card: null
    property SwipeVerbCard _cand: null
    property var _g: r._fresh()

    function _fresh() {
        return {
            axis: "",
            started: false,
            touch: false,
            acc: 0,
            hist: []
        };
    }

    // -> whether the event was this gesture's (accepted).
    function _wheel(x, y, ad, pd) {
        const g = r._g;
        const touch = pd.x !== 0 || pd.y !== 0;
        const ux = (ad.x !== 0 ? ad.x : pd.x * 2.5) * r.sign;
        const uy = ad.y !== 0 ? ad.y : pd.y * 2.5;
        if (ux === 0 && uy === 0) {
            // The fingers lifted.
            const mine = g.axis === "x";
            r._end();
            return mine;
        }
        if (r._spent) {
            // The rest of a spent tilt: swallowed, and it keeps the swallow
            // alive. Pixels (fingers) or a vertical wheel start a new gesture.
            if (!touch && Math.abs(ux) >= Math.abs(uy)) {
                idle.interval = r.mouseIdleMs;
                idle.restart();
                return true;
            }
            r._spent = false;
        }
        if (touch)
            g.touch = true;
        if (!g.started) {
            g.started = true;
            r._cand = r.rowAt ? r.rowAt(x, y) : null;
        }
        idle.interval = g.touch ? r.idleMs : r.mouseIdleMs;
        idle.restart();
        if (g.axis === "") {
            if (Math.abs(ux) > 1.2 * Math.abs(uy)) {
                g.axis = "x";
                r._card = r._cand;
                r._active = r._card !== null;
            } else if (Math.abs(uy) > 1.2 * Math.abs(ux)) {
                g.axis = "y";
            } else {
                return false;
            }
        }
        if (g.axis !== "x")
            return false;
        const c = r._card;
        if (r._holding || !c)
            return true;
        const dir = ux > 0 ? 1 : -1;
        if (!touch && Math.abs(ad.x) >= 120) {
            // A classic notch: one whole swipe.
            r._commit(c, dir);
            return true;
        }
        const now = Date.now();
        g.acc += ux;
        g.hist.push({
            t: now,
            d: ux
        });
        while (g.hist.length > 1 && now - g.hist[0].t > 100)
            g.hist.shift();
        c.scrub(g.acc / r.units * c.commitFraction * c.width);
        if (Math.abs(g.acc) >= r.pullThrough * r.units)
            r._commit(c, g.acc > 0 ? 1 : -1);
        return true;
    }

    function _commit(c, dir) {
        if (!r._g.touch) {
            // SPENT: no lift will come. The gesture ends first, so the
            // commit's consequences (the lane's close) find nothing held.
            r._spent = true;
            idle.interval = r.mouseIdleMs;
            idle.restart();
            r._reset();
            if (c.commit(dir))
                r.committed(c, dir);
            return;
        }
        if (!c.commit(dir))
            return;
        r._holding = true;
        r.committed(c, dir);
    }

    // Units/s over the last 100 ms before now: a gesture that stood still
    // before its lift has none.
    function _velocity() {
        const h = r._g.hist;
        const now = Date.now();
        let sum = 0;
        let first = now;
        for (let i = h.length - 1; i >= 0 && now - h[i].t <= 100; i--) {
            sum += h[i].d;
            first = h[i].t;
        }
        return sum / Math.max(0.05, (now - first) / 1000);
    }

    function _end() {
        idle.stop();
        r._spent = false;
        const c = r._card;
        const letGo = r._g.axis === "x" && c !== null && !r._holding;
        const v = letGo ? r._velocity() : 0;
        // A mouse's gesture (no pixel delta: its end is the idle, never a
        // lift) is over before its card decides, as a notch's is in _commit:
        // the release may commit, and the commit must find nothing held. A
        // touchpad's lift lets go of a gesture that is whole until it is done.
        const endsFirst = !r._g.touch;
        if (endsFirst)
            r._reset();
        if (letGo) {
            const dir = c.release(v / r.flingUnitsPerS * c.flingPxPerS);
            if (dir !== 0)
                r.committed(c, dir);
        }
        if (!endsFirst)
            r._reset();
    }

    function _reset() {
        r._g = r._fresh();
        r._card = null;
        r._cand = null;
        r._holding = false;
        // The flag last: nothing reads a half-reset gesture as live.
        r._active = false;
    }

    Timer {
        id: idle
        onTriggered: r._end()
    }
}
