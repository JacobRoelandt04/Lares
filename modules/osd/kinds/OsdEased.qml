import QtQuick

// =============================================================================
// OsdEased.qml -- a value on ONE clock: `value` follows `goal` over `ms`
// (OutCubic) when something else moved the goal, and is the goal itself while
// `direct` (the pointer is dragging it; an ease under a finger is a lag).
//
// Not a Behavior: a Behavior cannot be told "not now" without a second path,
// and the figure beside the bar must not be one more clock.
// =============================================================================
Item {
    id: e

    property real goal: 0
    property real value: 0
    property bool direct: false
    property int ms: 120

    visible: false
    width: 0
    height: 0

    // The value is set where the pointer says (and the ease, if any, stops).
    function snap(v) {
        anim.stop();
        e.value = v;
    }

    onGoalChanged: {
        if (e.direct) {
            e.snap(e.goal);
        } else {
            anim.stop();
            anim.to = e.goal;
            anim.start();
        }
    }
    Component.onCompleted: e.value = e.goal

    NumberAnimation {
        id: anim
        target: e
        property: "value"
        duration: e.ms
        easing.type: Easing.OutCubic
    }
}
