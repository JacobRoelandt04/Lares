pragma ComponentBehavior: Bound

import QtQuick

import "../../common/scroll"

// =============================================================================
// GlobeGesture.qml -- the globe's two-finger gestures (docs/contracts/gestures.md: a two-finger swipe is a WHEEL; a MouseArea with no buttons that never accepts the event; a zero-delta
// event is the fingers LIFTING).
//
//   horizontal   ROTATES the globe with the live input as progress: a touchpad's pixel deltas are arc length on the globe's middle (px / radius = rad, no threshold, nothing lost: the
//                events that decided the axis are applied as one), and a fast lift coasts out through the shell's ONE scroll engine (KineticScroll, ScrollFeel's feel) -- the globe's turn
//                is the position of a hidden Flickable the engine moves. A mouse's tilt-wheel notch glides a fixed step (15 deg) through the same engine.
//   vertical     TILTS it between two states (`tilt` 0 = the north faces up as drawn so far, 1 = the south pole leans to the viewer): the fingers move it live (140 px = the whole way,
//                clamped: never past the two), the lift settles it on the nearer state (a short flick counts), eased 260 ms. A mouse's vertical notch goes straight to its state.
//   AXIS LOCK    a gesture picks its axis from the first events (one clearly ahead of the other) and keeps it to the lift (a zero delta; an idle timer for a device that never sends one); no
//                tilt while a horizontal rotation runs (live, or coasting out).
//
// The wheel only counts over the globe's disc (a gesture already begun is sticky). Natural scrolling is the compositor's (applied before the client): fingers moving right / up read as +x /
// -y here, so the surface follows the fingers.
// =============================================================================
Item {
    id: root

    // ---- in ----
    property var globe: null                    // GlobeLayer: containsGlobe, rotateBy, tiltLive, settleTilt, tilt, _fr
    property real tiltRange: 140                // px of fingers for the whole tilt
    property real notchDeg: 15
    property real idleEndMs: 6000               // the fallback end of a gesture whose device never lifts
    property real lingerMs: 1400                // the globe stays grown (and the spin waits) this long after the last motion

    // ---- out ----
    readonly property bool live: root._axis !== ""
    readonly property bool rotating: root._axis === "h" || engine.moving
    readonly property bool held: root.live || engine.moving || linger.running
    readonly property string axis: root._axis
    signal activity

    property string _axis: ""
    property real _ax: 0                        // the undecided gesture's accumulated deltas
    property real _ay: 0
    property real _tiltStart: 0
    property real _tiltDir: 0
    property real _lastX: 0
    readonly property real _rp: root.globe ? Math.max(8, root.globe._fr.rp) : 60

    // the turn is the position of a hidden Flickable: ONE scroll engine for the whole shell
    Flickable {
        id: carrier
        visible: false
        width: 100
        height: 100
        interactive: false
        contentWidth: 2000000
        contentHeight: 100
        contentX: 1000000
    }
    KineticScroll {
        id: engine
        flick: carrier
        axis: Qt.Horizontal
        onMoved: {
            const x = carrier.contentX, d = x - root._lastX;
            root._lastX = x;
            // the content moves against the fingers (touch(-px)): the surface follows them. 1 content px = 1/speed px of fingers = 1/(speed x radius) rad
            if (root.globe && d !== 0)
                root.globe.rotateBy(-d / (root._rp * engine.speed));
            root.activity();
        }
    }
    Component.onCompleted: root._lastX = carrier.contentX
    Timer {
        id: linger
        interval: root.lingerMs
    }
    Timer {
        id: idleEnd
        interval: root.idleEndMs
        onTriggered: root._end()
    }
    function _lock(a: string): void {
        root._axis = a;
        root._tiltStart = root.globe ? root.globe.tilt : 0;
        root._tiltDir = 0;
    }
    function _end(): void {
        idleEnd.stop();
        if (root._axis === "h") {
            engine.release();
        } else if (root._axis === "v" && root.globe) {
            const t = root.globe.tilt, bias = 0.18 * root._tiltDir;
            root.globe.settleTilt(t + bias >= 0.5 ? 1 : 0);
        }
        root._axis = "";
        root._ax = 0;
        root._ay = 0;
        linger.restart();
    }
    // a touchpad's finger deltas (px, +x right / +y down as the compositor hands them) on the locked axis
    function _fingers(dx: real, dy: real): void {
        if (root._axis === "h") {
            engine.touch(-dx * engine.speed);
        } else if (root._axis === "v" && root.globe) {
            if (engine.moving)          // no tilt while a horizontal rotation runs (coasting out too)
                return;
            const before = root.globe.tilt;
            root.globe.tiltLive(before - dy / root.tiltRange);
            if (root.globe.tilt !== before)
                root._tiltDir = root.globe.tilt > before ? 1 : -1;
            root.activity();
        }
    }
    // the first events of a gesture decide its axis: one clearly ahead (2 x) of the other; until then they only add up, and the decision applies the sum (nothing is lost)
    function feed(ev: var): bool {
        const ax = ev.angleDelta.x, ay = ev.angleDelta.y, px = ev.pixelDelta.x, py = ev.pixelDelta.y;
        if (ax === 0 && ay === 0 && px === 0 && py === 0) {
            if (root._axis !== "")
                root._end();
            return false;
        }
        const touch = px !== 0 || py !== 0;
        if (!root.globe || !root.globe.containsGlobe(ev.x, ev.y) && root._axis === "" && !engine.moving)
            return false;
        idleEnd.restart();
        if (!touch) {
            // a mouse's notch: a step, never a gesture to hold
            if (Math.abs(ax) > Math.abs(ay)) {
                engine.notch(-ax / 120 * root.notchDeg * Math.PI / 180 * root._rp * engine.speed);
            } else if (!engine.moving) {
                root.globe.settleTilt(ay < 0 ? 1 : 0);
            }
            linger.restart();
            root.activity();
            return true;
        }
        if (root._axis === "") {
            root._ax += px;
            root._ay += py;
            const hx = Math.abs(root._ax), hy = Math.abs(root._ay);
            if (hx >= 2 * hy && hx > 0)
                root._lock("h");
            else if (hy >= 2 * hx && hy > 0)
                root._lock("v");
            else
                return true;
            const sx = root._ax, sy = root._ay;
            root._ax = 0;
            root._ay = 0;
            root._fingers(sx, sy);
            return true;
        }
        root._fingers(px, py);
        return true;
    }

    WheelArea {
        anchors.fill: parent
        enabled: root.enabled
        turned: wheel => {
            root.feed(wheel);
            wheel.accepted = false;
        }
    }
}
