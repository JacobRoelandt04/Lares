pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SelectionAutoScroll.qml
//
// Edge auto-scroll for a selection drag: hold the pointer past the top or the
// bottom of a scrolling area while dragging a selection and the area scrolls,
// the selection growing with it. Every text surface that lives inside a
// Flickable needs this and none of them get it for free -- Qt Quick's
// TextEdit selection stops at whatever is on screen when the pointer stops
// moving, because a pointer that is not moving sends no events, so nothing
// asks for more text.
//
// THE SHAPE, which is the industry's and not an invention:
//
//   * A DEAD ZONE past the edge. Dragging to the very edge -- or a hair past
//     it, which is what a hand does when it means "select to the last visible
//     line" -- must not start moving the ground. `deadZone` px of overshoot
//     buy nothing.
//   * Then a speed that GROWS with the overshoot, linearly, reaching
//     `maxSpeed` at `deadZone + rampDistance` and never exceeding it. Linear
//     because it is the one law a reader can predict: twice as far past the
//     edge is twice as fast. A cap because an unbounded ramp turns a slip of
//     the wrist into a jump to the end of the conversation.
//   * It STOPS AT THE ENDS. contentY is clamped to [0, contentHeight -
//     height]; at the clamp the wheel does not spin -- the tick simply
//     stops moving anything, and the selection stops growing with it.
//   * It ENDS WITH THE DRAG. `end()` on release, on cancel, on anything that
//     takes the grab away. There is no state that outlives the gesture.
//
// It is driven by a FrameAnimation, so the speed is in px per SECOND and the
// distance travelled is `speed * frameTime` -- the same distance at 30 fps as
// at 144. A Timer at a fixed interval would make the scroll rate a function
// of the machine.
//
// WHO MOVES THE SELECTION. This object scrolls; it does not know what a
// selection is. After each move it calls `autoScrollReapply()` on the owner
// that began the gesture, and the owner re-derives its selection endpoint
// from the pointer's SCENE position -- which has not changed, while the text
// under it has. That is the whole trick: the pointer is still, the document
// moved, so the character under the pointer is a new one.
// =============================================================================
Item {
    id: sas

    // Not a visual thing. Zero-sized so it cannot disturb a layout it is
    // declared in.
    visible: false
    width: 0
    height: 0

    // The area that scrolls.
    property Flickable flickable: null

    // The drag that is pushing, for the duration of the push. Anything with
    // an `autoScrollReapply()` function -- a duck-typed contract, so `var`
    // and not `QtObject`: the owner is a MouseArea in one caller and a view
    // in another, and neither shares a base type worth naming.
    property var owner: null

    // px of overshoot past the edge that buy nothing.
    property real deadZone: 12
    // px of overshoot past the dead zone that reach `maxSpeed`.
    property real rampDistance: 140
    // px per second at full overshoot.
    property real maxSpeed: 1100

    // True while the ground is actually moving under the pointer.
    readonly property bool active: tick.running

    // The last speed the tick used, px/s, signed (negative = towards the top).
    // Public because it is the thing a probe has to be able to read to say
    // "faster the further past the edge", and it costs nothing.
    readonly property real speed: sas._speed

    // How far past the edge the pointer is, signed. 0 = inside, or inside the
    // dead zone.
    property real _over: 0
    property real _speed: 0

    // Begin a gesture. The owner is remembered until `end()`.
    function begin(o) {
        sas.owner = o;
        sas._over = 0;
        sas._speed = 0;
        tick.running = false;
    }

    // The pointer moved (or the drag started): `sceneY` in scene coordinates.
    // Everything about whether to scroll, and how fast, follows from this one
    // number and the viewport's own scene rect.
    function at(sceneY) {
        if (!sas.flickable) {
            sas._over = 0;
            tick.running = false;
            return;
        }
        const top = sas.flickable.mapToItem(null, 0, 0).y;
        const bottom = top + sas.flickable.height;
        let over = 0;
        if (sceneY < top)
            over = sceneY - top;              // negative: past the TOP
        else if (sceneY > bottom)
            over = sceneY - bottom;           // positive: past the BOTTOM
        // Inside the dead zone is inside.
        if (Math.abs(over) <= sas.deadZone)
            over = 0;
        sas._over = over;
        tick.running = over !== 0 && sas.owner !== null;
        if (!tick.running)
            sas._speed = 0;
    }

    // The gesture is over, however it ended.
    function end() {
        tick.running = false;
        sas.owner = null;
        sas._over = 0;
        sas._speed = 0;
    }

    // The speed the current overshoot asks for, px/s, signed. Public so the
    // law is readable (and testable) without reproducing it.
    function speedFor(over) {
        const past = Math.abs(over) - sas.deadZone;
        if (past <= 0)
            return 0;
        const f = Math.min(1, past / Math.max(1, sas.rampDistance));
        return (over < 0 ? -1 : 1) * sas.maxSpeed * f;
    }

    signal scrolled(real dy)

    FrameAnimation {
        id: tick
        running: false
        onTriggered: {
            const f = sas.flickable;
            if (!f || sas._over === 0) {
                tick.running = false;
                return;
            }
            sas._speed = sas.speedFor(sas._over);
            const maxY = Math.max(0, f.contentHeight - f.height);
            const want = f.contentY + sas._speed * tick.frameTime;
            const ny = Math.max(0, Math.min(maxY, want));
            if (Math.abs(ny - f.contentY) < 1e-6)
                return;                       // at the end: nothing moves
            const dy = ny - f.contentY;
            f.contentY = ny;
            sas.scrolled(dy);
            if (sas.owner && typeof sas.owner.autoScrollReapply === "function")
                sas.owner.autoScrollReapply();
        }
    }
}
