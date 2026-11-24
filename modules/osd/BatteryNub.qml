pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"

// =============================================================================
// BatteryNub.qml
//
// The battery's terminal: a thin carved box detached from the body, filling
// from the bottom. What its fill means is the host's business -- in the popup
// it is the power flowing in or out, in the bar it is simply full.
// =============================================================================
Item {
    id: root

    // ---- The hull ---------------------------------------------------------
    property real baseRadius: 10
    property real bevelWidth: 2
    property real shadowWidth: 9

    // ---- The fill ---------------------------------------------------------
    // Gap between the hull's edge and the fill's.
    property real fillPadding: 5
    // Added to the fill's natural (concentric) radius.
    property real fillRadiusOffset: 0
    readonly property real fillRadius: Math.max(0, root.baseRadius - root.fillPadding + root.fillRadiusOffset)
    property real fillBevelWidth: 0
    property real fillShadowWidth: 5
    property int fillAnimationMs: 2200

    // 0..1, from the bottom.
    property real fillRatio: 0.5

    // ---- Colours ----------------------------------------------------------
    property color surfaceColor: Theme.surface
    property color grooveBackground: Theme.listBox
    property color grooveBevel: Theme.bevel
    property color grooveShadow: Theme.shadowDeep
    property color fillColor: Theme.batteryIdle
    readonly property color fillBevel: Qt.lighter(root.fillColor, 1.15)
    readonly property color fillShadow: Qt.darker(root.fillColor, 1.35)

    implicitWidth: 24
    implicitHeight: 80

    ShadowBox {
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
        x: root.fillPadding
        y: root.fillPadding
        width: parent.width - 2 * root.fillPadding
        height: parent.height - 2 * root.fillPadding
        clip: true

        ShadowBox {
            id: fill
            width: parent.width
            // The fill's top edge sits at fillRatio of the HULL's height, so
            // the animation reads in the same units as the body's.
            height: Math.min(parent.height, Math.max(0, root.height * root.fillRatio - root.fillPadding))
            y: parent.height - fill.height
            baseRadius: root.fillRadius
            bevelWidth: root.fillBevelWidth
            shadowWidth: root.fillShadowWidth
            surfaceColor: root.grooveBackground
            backgroundColor: root.fillColor
            bevelColor: root.fillBevel
            shadowColor: root.fillShadow

            Behavior on height {
                NumberAnimation {
                    duration: root.fillAnimationMs
                    easing.type: Easing.InOutCubic
                }
            }
        }
    }
}
