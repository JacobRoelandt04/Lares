pragma ComponentBehavior: Bound

import QtQuick
import "../scroll"

// =============================================================================
// SwipeScrub.qml -- two fingers sideways: back, scrubbed under the fingers.
// The notes popup's swipe-back, general (a browser's back gesture); the
// launcher's folders go back with the same one.
//
// A swipe is a WHEEL (docs/contracts/gestures.md): this is a MouseArea that
// takes no buttons, placed by the host over its whole content
// (`anchors.fill: parent`, a z above the pages). A gesture's axis is picked
// when one is clearly ahead (1.2x) and kept until the fingers lift -- a
// zero-delta wheel event, or `idleMs` without one. A VERTICAL gesture is let
// through to the scrolling below (`wheel.accepted = false`); a horizontal one
// is this reader's:
//
//   scrub(p)   the fingers' share of the way, 0..0.999 (`units` of wheel
//              motion is the whole way; motion against `sign` takes it back).
//              On the FIRST scrub of a gesture `active` is still false: that
//              is where the host starts its back morph. Feed p to
//              MorphClock.scrubTo(p).
//   commit()   the fingers lifted past a third of the way, or on a fling
//              (> 2600 units/s) -- `active` is still true -- OR a mouse's
//              notch to the previous (a side button's, a tilt's; whatever
//              `sign`): one whole back, `active` false
//   cancel()   the fingers lifted short: spring back (`active` still true)
//   step()     `stepOnly`: the back cannot be scrubbed right now (notes: a
//              search, which is cleared, not morphed) -- one step once the
//              fingers have gone 35 % of the way, or on a mouse's notch
//
//   canBegin   false while there is nothing to go back to: the sideways
//              motion is still taken (it is not a scroll), nothing happens
//   blocked    the host says a committed back is still playing out (its morph
//              runs on its own clock after the lift): the sideways motion is
//              taken and nothing starts -- not a scrub, not a notch, not a
//              step. Default false. The fingers that committed a back and
//              drift on (the idle timer ends a gesture whose lift event never
//              came) would otherwise start a second back over the first: the
//              exit would play twice, overlapping.
//   active     a scrub is under the fingers. The host's gesture hold follows
//              it (`swipeGestureActive`), and while it holds, the host routes
//              the wheels that land outside its body here through
//              gestureWheel(ev) (gestures.md section 4), which answers false
//              when no scrub is held.
// =============================================================================
WheelArea {
    id: sc

    property real units: 900
    property real sign: 1
    property bool canBegin: true
    property bool blocked: false
    property bool stepOnly: false
    property int idleMs: 260
    readonly property bool active: sc._active

    signal scrub(real p)
    signal commit
    signal cancel
    signal step

    // NO CURSOR OF ITS OWN: Qt 6.12 gives every MouseArea an Arrow cursor at birth, and the topmost item with a cursor under the
    // pointer decides the window's -- this area lies over the whole popup, so every hand cursor and the bridge's hidden free-look
    // pointer under it read Arrow (measured nested with qt.quick.hover.cursor: "setting cursor ArrowCursor from QQuickMouseArea").
    // The reset (unsetCursor) takes it out of the lookup.
    turned: wheel => {
        wheel.accepted = sc._wheel(wheel);
    }

    function gestureWheel(ev) {
        if (!sc._active)
            return false;
        sc._wheel(ev);
        return true;
    }

    property bool _active: false
    property var _sw: ({
            axis: "",
            acc: 0,
            v: 0,
            t: 0,
            done: false
        })

    // -> whether the event was this gesture's (accepted).
    function _wheel(ev) {
        const ad = ev.angleDelta, pd = ev.pixelDelta;
        if (ev.device === "wheel") {
            if (ad.x === 0)
                return false;
            if (ev.steps < 0 && sc.canBegin && !sc.blocked) {
                if (sc.stepOnly)
                    sc.step();
                else
                    sc.commit();
            }
            return true;
        }
        const sw = sc._sw;
        const ux = ad.x !== 0 ? ad.x : pd.x * 2.5;
        const uy = ad.y !== 0 ? ad.y : pd.y * 2.5;
        if (ux === 0 && uy === 0) {
            const mine = sw.axis === "x";
            sc._end();
            return mine;
        }
        idle.restart();
        if (sw.axis === "") {
            if (Math.abs(ux) > 1.2 * Math.abs(uy))
                sw.axis = "x";
            else if (Math.abs(uy) > 1.2 * Math.abs(ux))
                sw.axis = "y";
            else
                return false;
        }
        if (sw.axis !== "x")
            return false;
        if (sw.done)
            return true;
        const d = ux * sc.sign;
        const now = Date.now();
        if (sw.t > 0)
            sw.v = sw.v * 0.6 + (d / Math.max(1, now - sw.t) * 1000) * 0.4;
        sw.t = now;
        sw.acc = Math.max(0, sw.acc + d);
        if (!sc._active) {
            if (sw.acc <= 0 || !sc.canBegin || sc.blocked)
                return true;
            if (sc.stepOnly) {
                if (sw.acc >= sc.units * 0.35) {
                    sw.done = true;
                    sc.step();
                }
                return true;
            }
        }
        const p = Math.min(0.999, sw.acc / sc.units);
        sw.p = p;
        const first = !sc._active;
        sc.scrub(p);
        if (first)
            sc._active = true;
        return true;
    }

    function _end() {
        idle.stop();
        const sw = sc._sw;
        if (sc._active) {
            // The FINGERS' share decides, not the page's: the page may be
            // trailing a fast swipe.
            if ((sw.p || 0) >= 0.33 || sw.v > 2600)
                sc.commit();
            else
                sc.cancel();
        }
        sc._active = false;
        sc._sw = {
            axis: "",
            acc: 0,
            v: 0,
            t: 0,
            done: false
        };
    }

    Timer {
        id: idle
        interval: sc.idleMs
        onTriggered: sc._end()
    }
}
