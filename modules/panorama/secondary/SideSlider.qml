pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/scroll"

// =============================================================================
// SideSlider.qml -- one number of the side popup on the shell's GrooveSlider. Its `figure` is what the host's caption shows (Captioned `note`).
//
// WHEN A VALUE IS WRITTEN. A write may take seconds (a monitor's DDC), so `committed(v)` does not follow the ball: it fires on RELEASE, or after
// `settleMs` of the ball standing still while held. The FIGURE follows the ball at once (the person sees what they are choosing). The slider
// assigns its own `value` while held, which severs a plain binding: a `Binding { when: !slider.held }` carries `hostValue` in whenever the hand
// is off it. After a commit the ball stays where it was put (`_goal`) until the host's fact reaches it, so a slow write does not snap it back;
// a host that refuses has `goalMs` to show it before the ball goes back to the fact.
//   hostValue  0..1, what the machine says      pending  the write is in flight: the figure is muted
//   from / to / unit   the figure's scale (figure = from + v * (to - from), rounded to `step`)
// =============================================================================
Item {
    id: row

    property real hostValue: 0
    property bool pending: false
    property bool known: true                      // false: the service has no reading yet (the figure says so, the ball rests at 0)
    property real from: 0
    property real to: 100
    property real step: 1
    property string unit: ""
    property int settleMs: 250
    property int goalMs: 8000

    signal committed(real v)

    property real _drag: -1                         // the ball's value while the hand is on it, -1 none
    property real _last: -1
    property real _goal: -1                         // the value last committed, held until the host agrees
    readonly property real shown: row._drag >= 0 ? row._drag : (row._goal >= 0 ? row._goal : row.hostValue)
    readonly property bool dragging: row._drag >= 0
    readonly property alias slider: s
    readonly property real _span: Math.max(1e-9, row.to - row.from)

    readonly property string figure: row.known || row.dragging ? row.figureOf(row.shown) : "—"
    // the figure is muted while the write is in flight (the host puts it in its caption)
    readonly property bool figureMuted: (row.pending || !row.known) && !row.dragging
    implicitHeight: Math.ceil(s.height)

    function figureOf(v: real): string {
        const q = Math.round((row.from + v * (row.to - row.from)) / row.step) * row.step;
        return String(Math.round(q * 1000) / 1000) + row.unit;
    }

    GrooveSlider {
        id: s
        width: row.width
        height: Math.round(s.neededCross)
        orientation: "horizontal"
        sizeScale: 1
        ballSize: 12
        edgePadding: 8
        muteEnabled: false
        allowBoost: false
        sparksEnabled: false
        maxValue: 1
        surfaceColor: Theme.surface
        grooveColor: Theme.panelSunk
        grooveBevelColor: Theme.bevel
        grooveShadowColor: Theme.border
        ballColor: Theme.accent
        ballShadowColor: Theme.accent
        // the hand: from the first value it sets until the release (the PointHandler below) or a moment after the last value
        property bool held: false
        onUserChangedValue: v => {
            s.held = true;
            hold.restart();
            row._drag = v;
            settle.restart();
        }
        Timer {
            id: hold
            interval: 350
            onTriggered: s.held = false
        }
    }
    // the release, watched passively IN FRONT of the slider (a handler on the slider sits behind its own area); the wheel is eaten here
    Item {
        anchors.fill: s
        z: 1
        PointHandler {
            onActiveChanged: {
                if (!active) {
                    hold.stop();
                    s.held = false;
                    row.flush();
                }
            }
        }
        WheelArea {
            anchors.fill: parent
            turned: wheel => wheel.accepted = true
        }
    }
    Binding {
        target: s
        property: "value"
        value: row.shown
        when: !s.held
    }

    Timer {
        id: settle
        interval: row.settleMs
        onTriggered: row.flush()
    }
    Timer {
        id: goalTimer
        interval: row.goalMs
        onTriggered: {
            row._goal = -1;
            row._last = -1;
        }
    }
    function flush(): void {
        settle.stop();
        if (row._drag < 0)
            return;
        const v = row._drag;
        if (v !== row._last) {
            row._last = v;
            row._goal = v;
            goalTimer.restart();
            row.committed(v);
        }
        if (!s.held)
            row._drag = -1;
    }
    onHostValueChanged: {
        if (row._goal >= 0 && Math.abs(row.hostValue - row._goal) <= row.step / row._span / 2 + 1e-6) {
            row._goal = -1;
            row._last = -1;
            goalTimer.stop();
        }
    }
}
