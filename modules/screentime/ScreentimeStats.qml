pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "../common/theme"
import "data/ScreentimeModel.js" as Model

// =============================================================================
// ScreentimeStats.qml -- three columns under the faces, for the week or for the
// selected day: switches per hour (flush with the left edge), the longest
// stretch on one app (centred: its DUR, then the app's name), pickups (flush
// with the right edge). The edges are the boxes' above and below, so the strip
// lines up with them.
//
// Each column's caption and figure share its alignment: a figure changing
// length grows away from the edge it is pinned to (the centre one grows both
// ways), and nothing beside it moves.
// =============================================================================
Item {
    id: root

    // Model.stats(): {switchesPerHour, longest: {app, s}, pickups}; null = no data.
    property var stats: null
    property string longestName: ""
    property string fontFamily: "Inter"
    property int captionSize: 10
    property int figureSize: 12
    // The side columns' room; the centre takes the rest.
    property real sideSlot: 96
    // Where the tips float (the card), and the minutes away that end a session
    // (the daemon's `sessionBreakMin`, from the state's config).
    property Item overlayItem: null
    property int breakMin: 5

    implicitHeight: Math.ceil(fig.y + fig.height)

    readonly property bool _has: root.stats !== null && root.stats !== undefined
    readonly property bool _hasLongest: root._has && root.stats.longest.s > 0
    readonly property real _midW: Math.max(0, root.width - 2 * root.sideSlot)

    component Caption: Text {
        y: 0
        color: Theme.textFaint
        font.family: root.fontFamily
        font.pixelSize: root.captionSize
    }
    component Figure: Text {
        y: Math.ceil(capLeft.y + capLeft.height) + 2
        color: Theme.textPrimary
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
        font.bold: true
    }

    // A tip over one column: the area spans the caption and the figure.
    component ColumnTip: Item {
        id: ct
        property string tipText: ""
        property real areaX: 0
        property real areaW: 0
        x: ct.areaX
        y: 0
        width: ct.areaW
        height: root.implicitHeight
        MouseArea {
            id: ctArea
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            cursorShape: undefined   // a hover area for the tip: the cursor is what lies under it (a MouseArea owns an Arrow)
        }
        HoverTip {
            anchorItem: ct
            overlayItem: root.overlayItem
            side: "below"
            fontFamily: root.fontFamily
            fontPixelSize: 11
            show: ctArea.containsMouse
            text: ct.tipText
        }
    }

    // ---- left: switches per hour -----------------------------------------------
    Caption {
        id: capLeft
        x: 0
        text: "Switches / h"
    }
    Figure {
        id: fig
        x: 0
        text: root._has ? root.stats.switchesPerHour.toFixed(1) : "–"
    }

    // ---- centre: the longest stretch --------------------------------------------
    Caption {
        id: capMid
        x: Math.round((root.width - width) / 2)
        text: "Longest stretch"
    }
    Item {
        id: longest
        readonly property real _nameW: Math.min(Math.ceil(name.implicitWidth), Math.max(0, root._midW - Math.ceil(dur.implicitWidth) - 6))
        width: Math.ceil(dur.implicitWidth) + (longest._nameW > 0 ? 6 + longest._nameW : 0)
        height: dur.height
        x: Math.round((root.width - width) / 2)
        y: fig.y
        Figure {
            id: dur
            x: 0
            y: 0
            text: root._hasLongest ? Model.fmt(root.stats.longest.s) : "–"
        }
        Text {
            id: name
            visible: root._hasLongest
            x: Math.ceil(dur.implicitWidth) + 6
            width: longest._nameW
            y: dur.baselineOffset - name.baselineOffset
            elide: Text.ElideRight
            text: root.longestName
            color: Theme.textMuted
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
    }

    ColumnTip {
        areaX: 0
        areaW: Math.ceil(Math.max(capLeft.width, fig.width))
        tipText: "How often the focus moved to another app, per active hour"
    }
    ColumnTip {
        areaW: Math.ceil(Math.max(longest.width, capMid.width))
        areaX: Math.round((root.width - areaW) / 2)
        tipText: "The longest time on one app without a switch"
    }
    ColumnTip {
        areaW: Math.ceil(Math.max(pickCap.width, pickFig.width))
        areaX: root.width - areaW
        tipText: "Times you came back after a break (" + root.breakMin + " min away ends a session)"
    }

    // ---- right: pickups ------------------------------------------------------------
    Caption {
        id: pickCap
        x: root.width - width
        text: "Pickups"
    }
    Figure {
        id: pickFig
        x: root.width - width
        text: root._has ? String(root.stats.pickups) : "–"
    }
}
