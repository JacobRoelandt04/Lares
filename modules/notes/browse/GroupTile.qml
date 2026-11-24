pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// GroupTile.qml -- a group (a folder) in the notes grid.
//
// Where a note stands proud, a group is a carved WELL holding what is in it:
// up to four mini tiles (tinted, titled at 8 px) in a 2x2, the group's name
// and how many things it holds under them -- a phone's app folder, in this
// shell's material. `minis` are facts objects of the first four children in
// the group's own order.
// =============================================================================
Item {
    id: tile

    property var entry: null
    property var minis: []
    property string fontFamily: "Inter"
    property real padding: 12
    property real radius: 12
    property bool lifted: false
    property bool target: false
    property bool hoverEnabled: true
    // The keyboard highlight (NotesGrid): the look the pointer gives.
    property bool kbFocus: false
    // The face alone (minis, name, count), no well: on the morph card.
    property bool bare: false
    readonly property alias hovered: hover.hovered
    // The face (the minis, the name, the count) held as one texture while the grid floats (NoteTile's rule).
    property bool faceLayered: false

    readonly property string colorKey: tile.entry ? (tile.entry.colorKey || "") : ""

    function tintOf(key) {
        if (!key)
            return Theme.buttonPlateau;
        const k = "note" + key.charAt(0).toUpperCase() + key.substring(1);
        return Theme[k] !== undefined ? Theme[k] : Theme.buttonPlateau;
    }

    property real hoverF: (hover.hovered && tile.hoverEnabled) || tile.kbFocus ? 1 : 0
    Behavior on hoverF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    property real targetF: tile.target ? 1 : 0
    Behavior on targetF {
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    HoverHandler {
        id: hover
        cursorShape: Qt.PointingHandCursor
    }
    scale: 1 + 0.04 * tile.targetF

    ShadowBox {
        visible: !tile.bare
        anchors.fill: parent
        baseWidth: tile.width
        baseHeight: tile.height
        baseRadius: tile.radius
        // The bevel eases to alpha: identical on the surface, and right over
        // whatever else passes beneath (a carried group).
        surfaceColor: "transparent"
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Mix.c(Mix.c(tile.colorKey ? tile.tintOf(tile.colorKey) : Theme.listBox, Theme.panelSunk, tile.hoverF * 0.6), Theme.accent, 0.14 * tile.targetF)
        bevelWidth: 1
        shadowWidth: tile.targetF > 0 ? 3 + 2 * tile.targetF : 3
    }

    DeviceScale {
        id: dev
    }
    Item {
        id: face
        anchors.fill: parent
        layer.enabled: tile.faceLayered
        layer.smooth: true
        layer.mipmap: true
        layer.textureSize: Qt.size(Math.ceil(face.width * dev.value * 2), Math.ceil(face.height * dev.value * 2))

        // Up to four minis, two by two, filling the well's width above the name;
        // a landscape well makes them strips, as the tiles themselves are.
        Grid {
            id: miniGrid
            readonly property real cell: Math.floor((tile.width - 2 * tile.padding - miniGrid.spacing) / 2)
            readonly property real cellH: Math.max(12, Math.min(Math.round(miniGrid.cell * 0.72), Math.floor((nameText.y - 6 - tile.padding - miniGrid.spacing) / 2)))
            x: tile.padding
            y: tile.padding
            columns: 2
            spacing: 6
            Repeater {
                model: Math.min(4, tile.minis.length)
                delegate: Item {
                    id: mini
                    required property int index
                    readonly property var e: tile.minis[mini.index]
                    width: miniGrid.cell
                    height: miniGrid.cellH
                    ShadowBox {
                        anchors.fill: parent
                        baseWidth: mini.width
                        baseHeight: mini.height
                        baseRadius: 6
                        raised: true
                        // In the well, not on the surface: the shadow falls to alpha.
                        shadowToAlpha: true
                        surfaceColor: Theme.surface
                        bevelColor: Theme.buttonBevel
                        shadowColor: Theme.buttonShadow
                        backgroundColor: mini.e && mini.e.isGroup ? Theme.listBox : tile.tintOf(mini.e ? (mini.e.colorKey || "") : "")
                        bevelWidth: 1
                        shadowWidth: 3
                    }
                    Text {
                        x: 5
                        y: 4
                        width: parent.width - 10
                        text: mini.e ? mini.e.title : ""
                        font.family: tile.fontFamily
                        font.pixelSize: 8
                        font.bold: true
                        color: Theme.textMuted
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Text {
            id: nameText
            x: tile.padding
            y: tile.height - tile.padding - height - countText.height
            width: tile.width - 2 * tile.padding
            text: tile.entry ? tile.entry.title : ""
            font.family: tile.fontFamily
            font.pixelSize: 12
            font.bold: true
            color: Theme.textPrimary
            elide: Text.ElideRight
        }
        Text {
            id: countText
            x: tile.padding
            y: tile.height - tile.padding - height + 2
            text: tile.entry ? (tile.entry.childCount + (tile.entry.childCount === 1 ? " item" : " items")) : ""
            font.family: tile.fontFamily
            font.pixelSize: 10
            color: Theme.textFaint
        }
    }
}
