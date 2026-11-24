pragma ComponentBehavior: Bound

import QtQuick

import "../components"
import "../scroll"

// =============================================================================
// BoardInput.qml -- the one input layer over a board scene, by ARITHMETIC (the toolkit's; silicon's SceneInput and aerial's are this with their picks).
//
// The scene is a stack of shader effects and receives no input of its own worth having (an item that is
// drawn by a shader, or captured, hears nothing, and an item that paints outside its parent's bounds never
// hears a click there). So nothing sits over a drawn part: ONE MouseArea covers the whole scene and a click
// is turned into a board part by the scene's pick (`pickPart`: IsoCore.pickBoxes over the boxes, with the frames the parts are in RIGHT NOW), the same boxes
// and the same camera the shaders draw with.
//
// WHAT A SCENE SUPPLIES (function-valued properties; each may read the scene):
//   pickPart(x, y)           the part drawn at item px (x, y), or ""
//   intentFor(part, x, y)    what a click on that part (or, where no part answers, at that point) means: an intent string, "" for nothing
//   anchorFor(intent)        where the intent's part is, as [x, y] item px: what a secondary hangs from
//   zoneFor(x, y)            the zone a swipe at that point belongs to (`regions` is the scene's polygons to read it from), or "" for nobody's
//   pickReady                false while the scene is not there to ask
//
//   click   a part -> `clicked(intent, at)`; `at` is where the part is, item px (what a secondary hangs from), the click's own point when no part answers.
//   hover   the part under the pointer (`hoverPart`); the HAND cursor over what answers a
//           click, nothing else announces it.
//   wheel   a horizontal two-finger swipe over a zone steps it (gestures.md: a MouseArea that observes and
//           never accepts, never a WheelHandler; the zero-delta event is the fingers lifting, an idle
//           timer the fallback for a mouse, which never lifts). The owner is the zone under the pointer
//           where the gesture BEGAN, latched with its axis until the fingers lift -- a two-finger read is
//           never one axis, so the one clearly ahead (x1.2) is taken and kept. One step per gesture: what
//           follows is spent until the lift. +x steps +1 (the tab selector's sign).
//
// `gestureWheel(ev)` is the engine's hand-over for a gesture that has left this content (a clipping body
// delivers nothing outside its box): a forwarded wheel never starts a gesture, it only carries one on.
// =============================================================================
Item {
    id: root

    // ---- in ----
    property var regions: ({})                // the scene's zone polygons (what `zoneFor` reads)
    property var pickPart: function (x, y) { return ""; }
    property var intentFor: function (part, x, y) { return ""; }
    property var anchorFor: function (intent) { return [0, 0]; }
    property var zoneFor: function (x, y) { return ""; }
    property bool pickReady: true
    property real swipePixelToAngle: 2.5      // a device that sends only pixels, in angle units
    property int gestureIdleEndMs: 300        // a gesture with no lift ends after this much silence
    property real notchThreshold: 120
    property real pixelThreshold: 1000
    property bool wheelEnabled: true

    // ---- out ----
    signal clicked(string intent, point at)
    signal swiped(string zone, int dir)
    signal activity()

    readonly property int cursorShape: area.cursorShape
    readonly property string hoverPart: root._hoverPart
    readonly property bool gestureActive: root._active

    property string _hoverPart: ""
    property string _hoverIntent: ""

    // ---- the pick ----
    // the part drawn at (x, y), or ""
    function partAt(x, y) {
        return root.pickReady ? root.pickPart(x, y) : "";
    }
    // what a click at (x, y) means: the part drawn there, or, where no part answers, what the scene says of the point
    function intentOf(part, x, y) {
        return root.intentFor(part, x, y);
    }
    function intentAt(x, y) {
        return root.intentOf(root.partAt(x, y), x, y);
    }

    function _hoverAt(x, y) {
        const part = root.partAt(x, y);
        root._hoverPart = part;
        root._hoverIntent = root.pickReady ? root.intentOf(part, x, y) : "";
    }

    MouseArea {
        id: area
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        hoverEnabled: true
        cursorShape: root._hoverIntent !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
        // a hover that is only the scene re-delivering a resting pointer is not activity (the ladder would
        // never go calm under a pointer left over the popup)
        property real _lx: -1
        property real _ly: -1
        onPositionChanged: mouse => {
            root._hoverAt(mouse.x, mouse.y);
            if (mouse.x !== area._lx || mouse.y !== area._ly) {
                area._lx = mouse.x;
                area._ly = mouse.y;
                root.activity();
            }
        }
        onExited: {
            root._hoverPart = "";
            root._hoverIntent = "";
        }
        onClicked: mouse => {
            root.activity();
            const intent = root.intentAt(mouse.x, mouse.y);
            const a = intent === "" ? [mouse.x, mouse.y] : root.anchorFor(intent);
            root.clicked(intent, Qt.point(a[0], a[1]));
        }
    }

    // ---- the swipe ----
    WheelStepper {
        id: stepper
        notchThreshold: root.notchThreshold
        pixelThreshold: root.pixelThreshold
        stepCooldownMs: 0
    }
    property bool _active: false
    property string _owner: ""
    property string _axis: ""
    property bool _spent: false

    Timer {
        id: idle
        interval: root.gestureIdleEndMs
        onTriggered: root._end()
    }
    // Over: the gesture and what the pointer was on (the popup was put away under it).
    function reset() {
        root._end();
        root._hoverPart = "";
        root._hoverIntent = "";
    }
    function _end() {
        idle.stop();
        stepper.end();
        root._active = false;
        root._owner = "";
        root._axis = "";
        root._spent = false;
    }

    // One wheel event (WheelHub's) in this item's coordinates.
    function wheel(wx, wy, ev, forwarded) {
        const ad = ev.angleDelta, pd = ev.pixelDelta;
        // A mouse over a part: a notch is a step, turned either way or sideways with a side button (nothing here scrolls).
        if (ev.device === "wheel") {
            const at = forwarded || !root.wheelEnabled || ev.steps === 0 ? "" : root.zoneFor(wx, wy);
            if (at !== "") {
                root.activity();
                root.swiped(at, ev.steps > 0 ? 1 : -1);
            }
            return;
        }
        const xPixels = pd.x !== 0;
        const dx = ad.x !== 0 ? ad.x : pd.x * root.swipePixelToAngle;
        const dy = ad.y !== 0 ? ad.y : pd.y * root.swipePixelToAngle;
        // nothing on either axis is the touchpad's scroll-end: the fingers lifted
        if (dx === 0 && dy === 0) {
            root._end();
            return;
        }
        root.activity();
        if (!root._active) {
            if (forwarded || !root.wheelEnabled)
                return;                            // outside the popup nothing is owned
            const zone = root.zoneFor(wx, wy);
            if (zone === "")
                return;                            // over the pack, the board's margin, nothing: nobody's
            root._owner = zone;
            root._active = true;
            root._axis = "";
            root._spent = false;
        }
        idle.restart();
        if (root._axis === "") {
            if (Math.abs(dx) > Math.abs(dy) * 1.2)
                root._axis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                root._axis = "y";
        }
        if (root._axis !== "x" || dx === 0 || root._spent)
            return;
        const steps = stepper.feed(dx, xPixels);
        if (steps !== 0) {
            root._spent = true;
            root.swiped(root._owner, steps > 0 ? 1 : -1);
        }
    }

    function gestureWheel(ev) {
        if (!root._active || !ev)
            return false;
        root.wheel(ev.x, ev.y, ev, true);
        return true;
    }

    WheelArea {
        id: wheelArea
        anchors.fill: parent
        turned: wheel => {
            root.wheel(wheel.x, wheel.y, wheel, false);
            wheel.accepted = false;
        }
    }
}
