pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"

// =============================================================================
// EaseBox.qml -- the room of ONE card, eased when the card's height STEPS.
//
// A card's height never moves by itself, it jumps: a bundle's head taking a
// taller record, a footnote ("+1 more from Signal") coming or going, a body
// opened in full. A resize eases (260 ms OutCubic, the design language), so
// the room follows a step on one clock -- as an offset from the card's height
// that decays, `off * (1 - t)^3` -- and a second step while the first eases
// starts from what is drawn (CLAUDE.md: sum two eased values, never a Behavior
// restarted per change). Without it the head swapping 102 -> 92 and a
// bundle's footnote 70 -> 82 each move the popup's foot in one frame.
//
// Growing, the card is revealed from its top by the room: the room clips it,
// with the bevel's slack on its top and sides (a carved box draws its bevel
// outside itself: a clip on its edge would shear it, CLAUDE.md) -- the edge
// that moves is the reveal. Shrinking, the room closes under the card and
// nothing is clipped. At rest nothing is clipped. The first height a card
// reports (its creation and first layout) is taken as it is.
//
// THE REVEAL'S EDGE IS FOG ("nothing is cut hard": the same rule as the
// list's moving rows, ManagerSlot). While the room grows and clips the card,
// a SeamFade dissolves the last `fogPx` of what is shown into the ground at
// that edge, on the step's own progress (0 at its start and its end, so the
// band exists only while the edge moves and a resting card is exactly what it
// was).
// =============================================================================
Item {
    id: box

    default property alias content: holder.data
    // The ease; 0 takes every step at once.
    property int ms: 260
    // The bevel's reach past the card, kept by the clip while it reveals.
    property real slack: 2
    // An outside clock, 0..1 (-1 none): a step taken while it runs eases on
    // it instead (a pin flight's reveal: what the flight changes in a row
    // moves with the flight's destination, not on a clock of its own).
    property real driver: -1
    // What the reveal's edge dissolves into (the ground the card sits on) and
    // how far: one length shell-wide, the side cut's long ramp.
    property color groundColor: Theme.surface
    property real fogPx: 34

    readonly property Item child: holder.children.length > 0 ? holder.children[0] : null
    readonly property real target: box.child ? box.child.implicitHeight : 0
    readonly property bool easing: anim.running

    // The card's own width (a Column does not lay out a child of no width).
    implicitWidth: box.child ? box.child.width : 0
    implicitHeight: Math.round(box.target + box._off * box._k)

    property real _off: 0
    property real _t: 1
    property real _last: 0
    property bool _armed: false
    property bool _driven: false
    property real _d0: 0
    // What is left of the step: (1 - t)^3 on the own clock (OutCubic), the
    // driver's remainder on an outside one (from where it stood at the step).
    readonly property real _k: box._driven
        ? Math.max(0, Math.min(1, (1 - Math.max(0, box.driver)) / Math.max(0.000001, 1 - box._d0)))
        : Math.pow(1 - box._t, 3)

    // A step: drawn from where it stands (k = 1 on either clock), and the
    // clock chosen once the change that made it is over -- the driver is a
    // binding of the host's, and inside that change it may still be the
    // previous generation's (CLAUDE.md).
    onTargetChanged: {
        if (box._armed && box.ms > 0) {
            const shown = box._last + box._off * box._k;
            box._off = shown - box.target;
            anim.stop();
            box._driven = false;
            box._t = 0;
            Qt.callLater(box._decide);
        }
        box._last = box.target;
    }
    function _decide() {
        if (box._t > 0 || box._driven)
            return;
        if (box.driver >= 0 && box.driver < 1) {
            box._d0 = box.driver;
            box._driven = true;
        } else {
            anim.restart();
        }
    }
    // The outside clock done (or gone). What it had not yet taken of the
    // step eases on the own clock from where it is drawn: a flight that ends
    // without travelling opens its destination all at once, and a step it
    // drove would have landed in that one frame.
    property real _dPrev: 0
    onDriverChanged: {
        if (box._driven && (box.driver < 0 || box.driver >= 1)) {
            const left = Math.max(0, Math.min(1, (1 - Math.max(0, box._dPrev)) / Math.max(0.000001, 1 - box._d0)));
            box._driven = false;
            if (left > 0.01 && box.ms > 0) {
                box._off = box._off * left;
                box._t = 0;
                anim.restart();
            } else {
                box._off = 0;
                box._t = 1;
            }
        }
        box._dPrev = box.driver;
    }
    // A ROOM HANDED OVER: a card that stood beside this one now stands in it
    // (or the other way), and the room it had moves here at once -- the room
    // drawn grows by `px` in this frame (shrinks for a negative one), and
    // what that leaves between it and the target eases (or rides the driver)
    // as any step does. Called in the same turn as the change that hands the
    // room over, before or after the target moves: either way the step starts
    // from the room drawn plus `px`. (An open bundle's column: the card under
    // an away head is the member it was; AppBundleRow.)
    function carry(px) {
        if (!box._armed || box.ms <= 0 || px === 0)
            return;
        const shown = box._last + box._off * box._k + px;
        box._off = shown - box.target;
        box._last = box.target;
        anim.stop();
        box._driven = false;
        box._t = 0;
        Qt.callLater(box._decide);
    }
    Component.onCompleted: Qt.callLater(box._arm)
    function _arm() {
        box._last = box.target;
        box._armed = true;
    }

    // Linear time: the curve is the (1 - t)^3 above.
    NumberAnimation {
        id: anim
        target: box
        property: "_t"
        from: 0
        to: 1
        duration: box.ms
    }

    Item {
        id: clipper
        x: -box.slack
        y: -box.slack
        width: box.width + 2 * box.slack
        height: box.height + box.slack
        clip: box.implicitHeight < box.target - 0.5

        Item {
            id: holder
            x: box.slack
            y: box.slack
            width: box.width
            height: box.target
        }

        SeamFade {
            objectName: "easeFog"
            ground: box.groundColor
            fadeHeight: box.fogPx
            // The step's progress while the room is still opening (1 - what is
            // left of it); a room closing under the card clips nothing.
            extent: clipper.clip ? 1 - box._k : 1
        }
    }
}
