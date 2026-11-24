pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// BatteryBody.qml
//
// The battery's hull -- a groove carved into the surface -- and the charge
// lying in it. The charge is a second, shallower carved box ("closer to the
// camera"), cut in two where the charge-limit bar stands: the halves part
// around the bar as it rises and close again as it sinks, and each half's
// bar-side edge is a soft body (BatteryFillWavefield) that the bar's motion
// sets rippling.
//
// Used by the popup's big icon and, at a few pixels, by the bar's icon.
// =============================================================================
Item {
    id: root

    // ---- The hull ---------------------------------------------------------
    property real baseRadius: 30
    property real bevelWidth: 3
    property real shadowWidth: 14

    // ---- The charge -------------------------------------------------------
    // Gap between the hull's edge and the charge's. 0 lays the charge over
    // the whole hull.
    property real fillPadding: 8
    // Added to the charge's natural radius (the hull's, less the padding, so
    // the two curves stay concentric). Negative sharpens it.
    property real fillRadiusOffset: 0
    readonly property real fillRadius: Math.max(0, root.baseRadius - root.fillPadding + root.fillRadiusOffset)
    // The charge's own carve: no rim, a tighter inset shadow than the hull's.
    property real fillBevelWidth: 0
    property real fillShadowWidth: 7
    property int fillAnimationMs: 1800

    // 0..1, animated.
    property real fillRatio: 0.5
    Behavior on fillRatio {
        NumberAnimation {
            duration: root.fillAnimationMs
            easing.type: Easing.InOutCubic
        }
    }

    // ---- Colours ----------------------------------------------------------
    property color surfaceColor: Theme.surface
    property color grooveBackground: Theme.listBox
    property color grooveBevel: Theme.bevel
    property color grooveShadow: Theme.shadowDeep
    property color fillColor: Theme.batteryIdle
    // Relative to the fill, so they follow it through every state and mode.
    readonly property color fillBevel: Qt.lighter(root.fillColor, 1.15)
    readonly property color fillShadow: Qt.darker(root.fillColor, 1.35)

    // ---- The split (set by the host from the charge-limit bar) ------------
    property bool limitActive: false
    property real limitRatio: 1.0
    property real riseProgress: 0
    property real limitBarWidth: 22
    property real limitFillEdgePad: 7
    // The two halves' bar-side corner radius at full rise: the charge's own
    // radius plus this. Negative makes those corners sharper than the outer
    // ones. At no rise it is 0, so the halves meet flush.
    property real fillSplitRadiusOffset: 0

    // ---- The soft edges ---------------------------------------------------
    property BatteryWaveStyle waveStyle: null
    readonly property bool _waves: root.waveStyle !== null && root.waveStyle.enabled

    // Split while the bar stands, AND until both halves have settled after it
    // sank: at no rise the split halves are pixel-identical to one whole
    // charge, so staying split costs nothing to look at, and it is what lets
    // the dip the sinking bar leaves ring out instead of being cut off on the
    // frame the bar is gone.
    readonly property bool _split: root.limitActive || (root._waves && !(leftWave.settled && rightWave.settled))

    implicitWidth: 300
    implicitHeight: 140

    // ---- Geometry, in hull coordinates ------------------------------------
    // The charge maps linearly over the CAVITY (the hull less its padding),
    // so 10 % fills 10 % of what can be filled, whatever the padding.
    readonly property real _cavityLeft: root.fillPadding
    readonly property real _cavityWidth: Math.max(0, root.width - 2 * root.fillPadding)
    readonly property real _fillNaturalRight: root._cavityLeft + root.fillRatio * root._cavityWidth
    // Where the charge ends, in this item's x (animated with fillRatio).
    readonly property real fillEdgeX: root._fillNaturalRight
    readonly property real _barLeftX: Math.max(root.fillPadding, Math.min(root.width - root.limitBarWidth - root.fillPadding, root._cavityLeft + root.limitRatio * root._cavityWidth + root.limitFillEdgePad))
    readonly property real _barCenterX: root._barLeftX + root.limitBarWidth / 2

    // Half the gap the bar opens, centred on the bar: 0 at no rise (the halves
    // touch), barWidth/2 + edgePad at full rise. The waves are driven by how
    // fast this changes.
    readonly property real _halfGap: (root.limitBarWidth / 2 + root.limitFillEdgePad) * root.riseProgress

    readonly property real _leftCapX: root._split ? root._barCenterX - root._halfGap : root._fillNaturalRight
    readonly property real _rightFillLeftX: root._split ? root._barCenterX + root._halfGap : root._fillNaturalRight
    readonly property real _leftFillRightEdge: Math.min(root._fillNaturalRight, root._leftCapX)
    readonly property real _rightFillWidth: Math.max(0, root._fillNaturalRight - root._rightFillLeftX)

    // A half thinner than twice its radius has its corners clamped to half its
    // width -- sharper than the cavity's -- and its top and bottom poke past
    // the hull's curve. Shrink it vertically by the difference so it stays
    // inside the curvature however thin it gets.
    function _thinFillDelta(w) {
        if (w >= 2 * root.fillRadius)
            return 0;
        return Math.max(0, root.fillRadius - w / 2);
    }

    readonly property real _innerCornerRadius: root._split ? Math.max(0, root.fillRadius + root.fillSplitRadiusOffset) * root.riseProgress : root.fillRadius

    ShadowBox {
        id: groove
        anchors.fill: parent
        baseRadius: root.baseRadius
        bevelWidth: root.bevelWidth
        shadowWidth: root.shadowWidth
        surfaceColor: root.surfaceColor
        backgroundColor: root.grooveBackground
        bevelColor: root.grooveBevel
        shadowColor: root.grooveShadow
    }

    Item {
        id: fillClipArea
        x: root.fillPadding
        y: root.fillPadding
        width: parent.width - 2 * root.fillPadding
        height: parent.height - 2 * root.fillPadding
        clip: true

        // Left half, or the whole charge when nothing is split.
        ShadowBox {
            id: leftFill
            readonly property real _w: Math.max(0, root._leftFillRightEdge - root.fillPadding)
            readonly property real _delta: root._thinFillDelta(leftFill._w)
            y: leftFill._delta
            width: leftFill._w
            height: Math.max(0, parent.height - 2 * leftFill._delta)
            baseRadius: root.fillRadius
            topRightRadius: root._innerCornerRadius
            bottomRightRadius: root._innerCornerRadius
            bevelWidth: root.fillBevelWidth
            shadowWidth: root.fillShadowWidth
            surfaceColor: root.grooveBackground
            backgroundColor: root.fillColor
            bevelColor: root.fillBevel
            shadowColor: root.fillShadow
        }

        ShadowBox {
            id: rightFill
            readonly property real _w: root._rightFillWidth
            readonly property real _delta: root._thinFillDelta(rightFill._w)
            visible: root._split && rightFill._w > 0.5
            x: Math.max(0, root._rightFillLeftX - root.fillPadding)
            y: rightFill._delta
            width: rightFill._w
            height: Math.max(0, parent.height - 2 * rightFill._delta)
            baseRadius: root.fillRadius
            topLeftRadius: root._innerCornerRadius
            bottomLeftRadius: root._innerCornerRadius
            bevelWidth: root.fillBevelWidth
            shadowWidth: root.fillShadowWidth
            surfaceColor: root.grooveBackground
            backgroundColor: root.fillColor
            bevelColor: root.fillBevel
            shadowColor: root.fillShadow
        }
    }

    // The soft edges, outside the clip so a bulge can rise into the band
    // between the charge and the hull.
    BatteryFillWavefield {
        id: leftWave
        style: root.waveStyle
        active: root._waves && root._split && leftFill._w > 1
        fillX: root.fillPadding
        fillY: root.fillPadding + leftFill._delta
        fillWidth: leftFill._w
        fillHeight: leftFill.height
        fillColor: root.fillColor
        grooveBgColor: root.grooveBackground
        fillShadowWidth: root.fillShadowWidth
        fillShadowColor: root.fillShadow
        topLeftCornerRadius: root.fillRadius
        topRightCornerRadius: root._innerCornerRadius
        bottomRightCornerRadius: root._innerCornerRadius
        bottomLeftCornerRadius: root.fillRadius
        barSide: "right"
        pushPx: root._halfGap
        // Pushed only where the liquid reaches the bar's edge.
        contact: root._fillNaturalRight > root._barCenterX - root._halfGap
    }

    BatteryFillWavefield {
        id: rightWave
        style: root.waveStyle
        active: root._waves && root._split && rightFill.visible
        fillX: root.fillPadding + rightFill.x
        fillY: root.fillPadding + rightFill._delta
        fillWidth: rightFill._w
        fillHeight: rightFill.height
        fillColor: root.fillColor
        grooveBgColor: root.grooveBackground
        fillShadowWidth: root.fillShadowWidth
        fillShadowColor: root.fillShadow
        topLeftCornerRadius: root._innerCornerRadius
        topRightCornerRadius: root.fillRadius
        bottomRightCornerRadius: root.fillRadius
        bottomLeftCornerRadius: root._innerCornerRadius
        barSide: "left"
        pushPx: root._halfGap
        contact: true
    }

    readonly property bool split: root._split
}
