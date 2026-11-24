pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../data/CastParse.js" as CP

// =============================================================================
// CastFigures.qml -- the running cast's figures in two columns, name at the left and figure at the right of each (the stream's own in the left
// column, the link's in the right one; CastParse.js FIGURES names them and their order). It exists only while a cast display's detail is open and
// HOLDS the figures for that time (service.castHoldStats: nobody looking, nothing is published).
//
// EVERY FIGURE IS OF ONE BEAT: all of them are read from the one `castStats` object. A figure is there once the cast has had it (one with no source,
// a TV that answers no echo, never is) and never goes while the cast runs; one that is not known right now shows "–". They flow in order, so a
// missing one leaves no hole. A figure is right-aligned on its column's edge with tabular digits: its unit stands still and nothing beside it moves.
// The height is a step per row: `mask` changes when a figure comes, never at a beat, so a beat re-lays nothing out.
// =============================================================================
Item {
    id: root

    required property var service
    property string fontFamily: "Inter"
    property real figureSize: 11
    property real rowHeight: 18
    property real columnGap: 12

    readonly property var stats: root.service ? root.service.castStats : null
    readonly property string mask: {
        const s = root.stats;
        let m = "";
        for (const f of CP.FIGURES)
            m += s !== null && s[f.key] !== undefined ? "1" : "0";
        return m;
    }
    readonly property int shownCount: root.mask.split("1").length - 1
    readonly property real columnWidth: Math.floor((root.width - root.columnGap) / 2)

    implicitHeight: Math.ceil(root.shownCount / 2) * root.rowHeight
    height: root.implicitHeight

    property var _held: null
    Component.onCompleted: {
        root._held = root.service;
        if (root._held)
            root._held.castHoldStats();
    }
    Component.onDestruction: {
        if (root._held)
            root._held.castReleaseStats();
    }

    Repeater {
        model: CP.FIGURES.length
        delegate: Item {
            id: cell
            required property int index
            readonly property string key: CP.FIGURES[cell.index].key
            // its place among the figures there are; -1: not there
            readonly property int slot: root.mask.charAt(cell.index) === "1" ? root.mask.slice(0, cell.index).split("1").length - 1 : -1
            objectName: "castFigure-" + cell.key
            visible: cell.slot >= 0
            x: cell.slot % 2 === 1 ? root.width - root.columnWidth : 0
            y: Math.max(0, Math.floor(cell.slot / 2)) * root.rowHeight
            width: root.columnWidth
            height: cell.slot >= 0 ? root.rowHeight : 0

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: CP.FIGURES[cell.index].label
                color: Theme.textMuted
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
            }
            Text {
                objectName: "castFigureText"
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: parent.right
                text: root.stats !== null ? CP.figureText(cell.key, root.stats[cell.key]) : ""
                color: Theme.textPrimary
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                font.features: ({ "tnum": 1 })
            }
        }
    }
}
