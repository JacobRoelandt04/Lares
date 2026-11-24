pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// AnimatedAppointmentRow.qml
//
// Wrapper around AppointmentRow that participates in the AppointmentList's
// day-change slide animation. Driven by `rowState` ("rest" | "entering" |
// "leaving") + `staggerIdx` (top-down rank) set from the parent ListModel.
//
// Motion is IMPERATIVE (a single NumberAnimation target = "x") rather than
// Behavior-on-x, because Qt's Behavior semantics silently skip the initial
// binding evaluation — a binding-driven x would flash entering
// rows briefly at x=0 and make their slide-in a no-op for the first
// row (staggerIdx=0 has a 0ms kickTimer). With an explicit NumberAnimation
// we snap x to _offLeft on creation (outside any Behavior), then start the
// animation after the stagger delay, so every row actually slides in.
// =============================================================================
Item {
    id: rowWrap

    // --- Inputs from the AppointmentList delegate binding ---
    property var evData: null
    property string rowState: "rest"
    property int staggerIdx: 0

    // Injected from parent
    property var calendarData: null
    property string fontFamily: "Audiowide"
    // The list's ONE BoundaryClock, epoch ms (the stripe's time left).
    property real nowMs: 0
    // ... and the clock itself, which an open row asks for the instant its `in <time>` line changes (AppointmentRow).
    property var clock: null

    // --- Animation tuning ---
    property int animDuration: 240
    property int staggerMs: 55
    property int animEasing: Easing.OutCubic
    property real offscreenMargin: 40

    width: parent ? parent.width : 0

    // --- Height & virtual spacing ---
    // Each wrapper reserves its content's height PLUS a virtual spacing
    // band; the enclosing Column runs with spacing=0. When a leaving row
    // collapses, both the content height AND its spacing contribution
    // collapse together, so entering rows' y values drift down to zero
    // smoothly instead of hopping the residual spacing at cleanup.
    property real virtualSpacing: 6

    implicitHeight: (rowState === "leaving" && _leaveDone)
        ? 0
        : content.implicitHeight + virtualSpacing
    Behavior on implicitHeight {
        enabled: rowWrap.rowState === "leaving"
        NumberAnimation { duration: rowWrap.animDuration; easing.type: Easing.OutCubic }
    }

    readonly property real _offRight: width + offscreenMargin
    readonly property real _offLeft: -width - offscreenMargin

    property bool _leaveDone: false

    // --- IMPERATIVE X ANIMATION ---
    NumberAnimation {
        id: slideAnim
        target: rowWrap
        property: "x"
        duration: rowWrap.animDuration
        easing.type: rowWrap.animEasing
    }

    Timer {
        id: kickTimer
        repeat: false
        onTriggered: rowWrap._kick()
    }
    Timer {
        id: leaveDoneTimer
        repeat: false
        onTriggered: rowWrap._leaveDone = true
    }

    Component.onCompleted: {
        // Snap to the state's initial position BEFORE the kick so the first
        // render shows e.g. entering rows at _offLeft, not at 0.
        x = _initialXForState();
        _scheduleKick();
    }
    onRowStateChanged: {
        // For subsequent state changes, stop any in-flight animation and
        // snap to the new initial position. Preserves clean handoff when
        // a row is flipped mid-enter to leaving (or vice versa).
        slideAnim.stop();
        x = _initialXForState();
        _leaveDone = false;
        _scheduleKick();
    }

    function _initialXForState() {
        if (rowState === "entering") return _offLeft;
        return 0;       // "rest" AND "leaving" both start at rest position
    }

    function _scheduleKick() {
        kickTimer.stop();
        leaveDoneTimer.stop();
        if (rowState === "entering" || rowState === "leaving") {
            // Minimum 16ms so the render at initial position gets one frame
            // before the kick starts animating away from it.
            kickTimer.interval = Math.max(16, staggerIdx * staggerMs);
            kickTimer.restart();
        }
        if (rowState === "leaving") {
            leaveDoneTimer.interval = Math.max(16, staggerIdx * staggerMs) + animDuration + 10;
            leaveDoneTimer.restart();
        }
    }

    function _kick() {
        slideAnim.stop();
        if (rowState === "entering") slideAnim.to = 0;
        else if (rowState === "leaving") slideAnim.to = _offRight;
        else return;
        slideAnim.start();
    }

    AppointmentRow {
        id: content
        // Render content centred within the wrapper's virtual-spacing band
        // (symmetric gap above + below). Content is not height-anchored so
        // its implicitHeight reflects its real content size regardless of
        // wrapper's collapsed state.
        anchors.left: parent.left
        anchors.right: parent.right
        y: rowWrap.virtualSpacing / 2
        ev: rowWrap.evData
        calendarData: rowWrap.calendarData
        fontFamily: rowWrap.fontFamily
        nowMs: rowWrap.nowMs
        clock: rowWrap.clock
        showTime: !(rowWrap.evData && rowWrap.evData.allDay)
    }
}
