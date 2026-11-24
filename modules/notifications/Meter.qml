pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// Meter.qml
//
// Inset-track progress bar styled for the light palette. Named `Meter` rather
// than `ProgressBar` to avoid collision with `QtQuick.Controls.ProgressBar`
// which wins imports when both are in scope.
//   - from/to/value :  like QtQuick.Controls.ProgressBar
//   - indeterminate :  shimmer animation (hides value, loops a slim fill)
//
// Kept intentionally small: no text overlay, no label — callers stack their
// own label above/beside. Track and fill colours are properties so the bar
// can shift palette (blue → amber for warning, red for error, green for done).
// =============================================================================
Item {
    id: root

    property real from: 0
    property real to: 1
    property real value: 0
    property bool indeterminate: false

    property color trackColor:       "#E1E4EB"
    property color trackBorderColor: "#CED1D7"
    property color fillTopColor:     "#4D91F8"
    property color fillBottomColor:  "#4480F4"
    property color fillShadowColor:  "#3B73E0"

    property real radius: height / 2
    property int animDuration: 180

    implicitHeight: 10
    implicitWidth: 200

    // 0..1 sweep position for the indeterminate stripe.
    property real _shimPhase: 0
    NumberAnimation on _shimPhase {
        running: root.indeterminate && root.visible
        loops: Animation.Infinite
        from: 0
        to: 1
        duration: root.shimmerDuration
        easing.type: Easing.InOutSine
    }
    property int shimmerDuration: 1400

    readonly property real _progress: {
        if (root.indeterminate) return 0;
        const range = root.to - root.from;
        if (range <= 0) return 0;
        return Math.max(0, Math.min(1, (root.value - root.from) / range));
    }

    Rectangle {
        id: track
        anchors.fill: parent
        color: root.trackColor
        radius: root.radius
        border.color: root.trackBorderColor
        border.width: 1
    }

    Item {
        id: clip
        anchors.fill: parent
        anchors.margins: 1
        clip: true

        Rectangle {
            id: fill
            // Animate the progress fraction, NOT the rendered width. Both
            // value-change AND parent-width-change update `width` when the
            // expression is `parent.width * _progress`, so the previous
            // `Behavior on width` animated layout reflows too — visible as
            // a stutter on the meter every time the popup resized (mode
            // switch, prompt banner appearing, etc.) mid-update. Driving
            // the Behavior off `_animatedProgress` keeps progress motion
            // smooth without resizing animating sideways.
            property real _animatedProgress: root._progress
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: parent.width * _animatedProgress
            radius: Math.max(0, root.radius - 1)
            visible: !root.indeterminate
            gradient: Gradient {
                orientation: Gradient.Vertical
                GradientStop { position: 0.0; color: root.fillTopColor }
                GradientStop { position: 1.0; color: root.fillBottomColor }
            }
            Rectangle {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: Math.max(1, parent.radius)
                radius: parent.radius
                color: root.fillShadowColor
                opacity: 0.35
                visible: parent.width > parent.radius * 2
            }

            Behavior on _animatedProgress {
                NumberAnimation { duration: root.animDuration; easing.type: Easing.OutCubic }
            }
        }

        Rectangle {
            id: shim
            visible: root.indeterminate
            height: parent.height
            width: Math.min(80, Math.max(20, parent.width * 0.3))
            radius: Math.max(0, root.radius - 1)
            color: root.fillBottomColor
            opacity: 0.6

            // Position is DERIVED from a normalised 0..1 phase rather than
            // animated directly.
            //
            // Animating `x` from -width to clip.width samples the end point
            // once, when the animation starts. If the meter then gets wider —
            // which happens whenever the popup changes to a wider view — the
            // stripe keeps travelling to the OLD end point and stops short of
            // the new one. Driving a unitless phase and computing x from the
            // live width means a resize is picked up mid-flight: the stripe is
            // re-placed at the same proportional position and carries on. The
            // loop keeps its constant duration, so the stripe simply covers
            // more ground per second in a wider view, which is what a constant
            // sweep time means.
            x: -shim.width + root._shimPhase * (clip.width + shim.width)
        }
    }
}
