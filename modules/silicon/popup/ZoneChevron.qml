pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// ZoneChevron.qml -- the faint arrow beside a zone's name that steps it (the shell's Chevron, turned).
//
// HOVER-ONLY: it exists while the pointer is in its zone (`hovered`, which the popup works out by
// arithmetic on one root-level HoverHandler -- an item stacked over a link would take the link's hover)
// and is ABSENT at an end of the row (`available` false): no mark, no hit area, no looping. Presence is
// one eased fraction (160 ms); the hover brightening is another, a fraction too, never a Behavior on a
// colour. The hand cursor is the only other announcement.
// =============================================================================
Item {
    id: root

    property int dir: 1                    // -1 the previous step (points left), +1 the next
    property bool available: true
    property bool hovered: false
    property int fadeMs: 160
    property int hoverMs: 120
    property real size: 13

    signal clicked()

    // for the probes: the fraction the mark is shown at, and whether it has a hit area
    readonly property real presence: root._p
    readonly property bool live: root.available && root.hovered

    implicitWidth: 28
    implicitHeight: 28
    visible: root._p > 0
    opacity: root._p

    property real _p: root.available && root.hovered ? 1 : 0
    Behavior on _p {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real _hf: area.containsMouse ? 1 : 0
    Behavior on _hf {
        NumberAnimation {
            duration: root.hoverMs
            easing.type: Easing.OutCubic
        }
    }

    // FadeColors: what is live inside the board's island hole carries its own old colours to the new (SiliconIsland)
    property bool islandArmed: false
    FadeColor { id: faintFade; token: "textFaint"; active: root.islandArmed; place: root }
    FadeColor { id: primaryFade; token: "textPrimary"; active: root.islandArmed; place: root }
    Chevron {
        id: mark
        x: Math.round((root.width - width) / 2)
        y: Math.round((root.height - height) / 2)
        size: root.size
        thickness: 2
        rotation: root.dir < 0 ? 90 : -90
        color: Mix.c(faintFade.value, primaryFade.value, root._hf)
    }

    MouseArea {
        id: area
        anchors.fill: parent
        enabled: root.live
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
