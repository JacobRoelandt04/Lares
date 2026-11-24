import QtQuick

// =============================================================================
// SideSwipe -- the mouse's side buttons as a two-finger swipe, for everything under it: one per window (or stage), filling it, above all.
//
// A press of a side button finds the WheelAreas under the pointer (WheelHub.chainAt, the order Qt would offer them a wheel) and keeps that
// chain for the whole gesture, as fingers resting on a touchpad keep theirs: a popup that shrinks under the swipe changes nothing.
//   moved `slopPx`     the chain is fed fingers: a begin (zero, ScrollBegin), the hand's way as pixels (angle 12 x, as Qt makes them),
//                      an end (zero, ScrollEnd) at the release. The content follows the hand. The place of the events is the press.
//   turned             the wheel's notches go sideways by themselves (WheelHub.read sees the button); the press is then neither
//   released at once   one sideways notch: Back = to the previous, Forward = to the next
// A press over no reader at all is let through.
//
// THE POINTER. With WheelHub.sideHold it is hidden (`hiding`: the host's CursorCover follows it, nothing under that can decide a cursor)
// and the host is asked to keep it: `pointer("hold")` at the press (the place to come back to), `pointer("anchor", dx, dy)` whenever it has
// strayed `strayPx` from its ANCHOR, `pointer("home")` at the end. The anchor is the press itself, or -- where a window edge is nearer than
// the hand needs (the reels sit 20 px from the screen's: a swipe up ended there) -- the window's middle: hidden, it is nowhere. The jump to
// the anchor is no motion of the hand, but what the pointer is off it when the jump is SEEN is (the bridge's free look measured it: dropping
// that event loses a sixth of a sweep). A host that cannot move it (a mockup, a probe) leaves it free.
// `grabbing` (from the press until shortly after the way home): the host takes input over its whole window meanwhile. The compositor gives
// the focus to whatever is under the pointer as the button comes up, and that must be this window, not an app 140 px off.
// =============================================================================
MouseArea {
    id: ss

    // what the swipe reaches: this item's parent, unless the host says
    property Item root: ss.parent
    // the host moves the real pointer (a live shell's window); false: it goes where the hand takes it
    property bool holds: false
    property real slopPx: 5
    property real strayPx: 140
    readonly property bool hiding: ss._moved && ss.holds && WheelHub.sideHold
    readonly property bool grabbing: ss.holds && WheelHub.sideHold && (ss._down || settle.running)
    signal pointer(string what, real dx, real dy)
    Timer {
        id: settle
        interval: 150
    }

    anchors.fill: parent
    z: 190000
    enabled: WheelHub.sideMask !== Qt.NoButton
    acceptedButtons: WheelHub.sideMask
    preventStealing: true
    cursorShape: ss.hiding ? Qt.BlankCursor : undefined

    property var _chain: []
    property int _button: 0
    property point _start: Qt.point(0, 0)
    property point _last: Qt.point(0, 0)
    property point _anchor: Qt.point(0, 0)
    property bool _down: false
    property bool _moved: false
    property bool _homeDue: false

    onPressed: m => {
        if (ss._down)
            return;
        ss._chain = WheelHub.chainAt(ss.root, m.x, m.y);
        if (ss._chain.length === 0) {
            m.accepted = false;
            return;
        }
        ss._down = true;
        ss._moved = false;
        ss._homeDue = false;
        ss._rx = 0;
        ss._ry = 0;
        ss._button = m.button;
        ss._start = Qt.point(m.x, m.y);
        ss._last = ss._start;
        WheelHub.sideTurned = false;
        // the place to come back to is the PRESS's: asked for at the first motion, it was that motion further on
        if (ss.holds && WheelHub.sideHold)
            ss.pointer("hold", 0, 0);
        const need = ss.strayPx + 40;
        const near = Math.min(m.x, m.y, ss.width - m.x, ss.height - m.y) < need;
        ss._anchor = near ? Qt.point(Math.round(ss.width / 2), Math.round(ss.height / 2)) : ss._start;
    }
    onPositionChanged: m => {
        if (!ss._down || WheelHub.sideTurned)
            return;
        const ax = ss._anchor.x, ay = ss._anchor.y;
        if (!ss._moved) {
            if (Math.hypot(m.x - ss._start.x, m.y - ss._start.y) < ss.slopPx)
                return;
            ss._moved = true;
            WheelHub._swiping = true;
            ss._feed(0, 0, Qt.ScrollBegin);
            ss._way(m.x - ss._start.x, m.y - ss._start.y);
        } else if (ss._homeDue && Math.hypot(m.x - ax, m.y - ay) < 0.4 * ss.strayPx) {
            ss._homeDue = false;
            ss._way(m.x - ax, m.y - ay);
        } else {
            ss._way(m.x - ss._last.x, m.y - ss._last.y);
        }
        ss._last = Qt.point(m.x, m.y);
        if (ss.hiding && !ss._homeDue && Math.hypot(m.x - ax, m.y - ay) > ss.strayPx) {
            ss._homeDue = true;
            ss.pointer("anchor", ax - ss._start.x, ay - ss._start.y);
        }
    }
    onReleased: m => ss._release(m.button === ss._button && !ss._moved && !WheelHub.sideTurned)
    onCanceled: ss._release(false)

    function _release(click: bool): void {
        if (!ss._down)
            return;
        ss._down = false;
        if (ss._moved) {
            ss._feed(0, 0, Qt.ScrollEnd);
            if (ss.hiding) {
                settle.restart();
                ss.pointer("home", 0, 0);
            }
            ss._moved = false;
            WheelHub._swiping = false;
        } else if (click && WheelHub.sideClick) {
            const n = ss._button === Qt.BackButton ? 1 : -1;
            ss._send(Object.assign(WheelHub.fingers(0, 0, Qt.NoScrollPhase),
                                   { device: "wheel", angleDelta: Qt.point(120 * n, 0), notches: Qt.point(n, 0), steps: -n, click: true }));
        }
        ss._chain = [];
    }

    // The hand's way (px): the content follows it, as fingers' under natural scrolling.
    property real _rx: 0
    property real _ry: 0
    function _way(dx: real, dy: real): void {
        ss._rx += dx * WheelHub.sideGain;
        ss._ry += dy * WheelHub.sideGain;
        const px = Math.trunc(ss._rx), py = Math.trunc(ss._ry);
        ss._rx -= px;
        ss._ry -= py;
        if (px !== 0 || py !== 0)
            ss._feed(px, py, Qt.ScrollUpdate);
    }
    // `inverted`: the deltas follow the hand (what a natural-scrolling device's do), so a reader of the hand's own direction turns them.
    function _feed(px: real, py: real, phase: int): void {
        ss._send(Object.assign(WheelHub.fingers(px, py, phase), { device: "swipe", inverted: true }));
    }
    function _send(ev: var): void {
        WheelHub.deliver(ss._chain, ss.root, ss._start.x, ss._start.y, ev);
    }
    Component.onDestruction: {
        if (ss._moved)
            WheelHub._swiping = false;
    }
}
