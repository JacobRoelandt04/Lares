pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/icons"
import ".."
import "../../common/components/Mix.js" as Mix
import "RowText.js" as RT

// =============================================================================
// FolderRow.qml -- a folder of scripts and linked apps in the launcher.
//
// Notes' group tile at row size: a folder is
// a carved WELL of the icon's size holding up to four of its items as mini
// icons, two by two, and its name beside it. It opens with notes'
// group morph (LauncherPopup): the row grows into the popup.
//
// `minis` are the facts of the first four items in the folder's order.
// =============================================================================
Item {
    id: row

    property var facts: null
    property var minis: []
    property LauncherTune tune: null
    property bool hovered: false
    property bool target: false
    property var matchIndices: []

    readonly property real _pad: row.tune ? row.tune.rowInset : 6
    readonly property real _icon: row.tune ? row.tune.iconSize : 40

    property real targetF: row.target ? 1 : 0
    Behavior on targetF {
        enabled: !row._snap
        NumberAnimation {
            duration: 140
            easing.type: Easing.OutCubic
        }
    }

    // Reused for another folder (LauncherGrid's face pool): see AppRow.snap.
    property bool _snap: false
    function snap() {
        row._snap = true;
        snapEnd.restart();
    }
    Timer {
        id: snapEnd
        interval: 0
        onTriggered: row._snap = false
    }

    // The well, the icon's size, carved into the surface (whatever passes
    // under it -- the gliding highlight, a carried row -- it eases to alpha).
    Item {
        id: well
        x: row._pad
        y: Math.round((row.height - row._icon) / 2)
        width: row._icon
        height: row._icon
        scale: 1 + 0.06 * row.targetF
        readonly property color fill: Mix.c(Mix.sunk(Theme.listBox, Theme.panelSunk, Theme.shadowDeep, Theme.surface), Theme.accent, 0.14 * row.targetF)

        ShadowBox {
            anchors.fill: parent
            baseWidth: well.width
            baseHeight: well.height
            baseRadius: Math.round(well.width * 0.22)
            surfaceColor: "transparent"
            bevelColor: Theme.bevel
            shadowColor: Theme.border
            backgroundColor: well.fill
            bevelWidth: 1
            shadowWidth: 2
        }

        // Up to four minis, two by two, inside a 3 px rim.
        Grid {
            id: miniGrid
            readonly property int cell: Math.floor((well.width - 2 * 4 - miniGrid.spacing) / 2)
            x: Math.round((well.width - (2 * miniGrid.cell + miniGrid.spacing)) / 2)
            y: x
            columns: 2
            spacing: 2
            Repeater {
                id: minisRep
                model: Math.min(4, row.minis.length)
                delegate: AppIcon {
                    id: mini
                    required property int index
                    readonly property var e: row.minis[mini.index]
                    size: miniGrid.cell
                    icon: mini.e ? mini.e.icon : ""
                    kind: mini.e ? mini.e.kind : ""
                    appId: mini.e ? mini.e.desktopId : ""
                }
            }
        }
    }

    Text {
        x: row._pad + row._icon + (row.tune ? row.tune.iconGap : 10)
        y: Math.round((row.height - height) / 2)
        width: Math.max(0, row.width - x - row._pad)
        textFormat: Text.StyledText
        text: RT.styled(row.facts ? row.facts.name : "", row.matchIndices, Theme.accent.toString(), "", "")
        elide: Text.ElideRight
        font.family: row.tune ? row.tune.fontFamily : "Inter"
        font.pixelSize: row.tune ? row.tune.nameSize : 12
        font.bold: true
        color: Theme.textPrimary
    }
}
