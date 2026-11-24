pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components/Mix.js" as Mix

// =============================================================================
// ScreentimeHeatmap.qml -- the Hours face: seven days by 24 hours of the
// logical day, each cell the share of that hour spent.
//
// 168 cells in ONE fixed Repeater (its model is the count, never a colour: a
// delegate resolves its own from the fraction). The cell's fraction is
// `from + (to - from) * progress`: `to` is `target` (what the host binds),
// `from` is what `hold()` took of what was DRAWN, and `progress` is the host's
// one clock (the bars chart's morphProgress), so a week step or an app focus
// moves the grid with the bars and never on a clock of its own. An interrupted
// step holds what is on screen, so nothing jumps. At rest progress is 1 and
// the grid IS the target.
// =============================================================================
Item {
    id: heat

    // 168 fractions 0..1, row = day, column = hour from the day's start.
    property var target: []
    property real progress: 1
    // The colour of a full cell (the focused app's hue, else the accent).
    property color hue: Theme.accent
    property var dayLabels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    property int startHour: 4
    property int selectedDay: -1
    property string fontFamily: "Inter"
    property int labelSize: 10
    property real cellGap: 2
    property real cellRadius: 3
    // The share a first second of an hour is drawn at, so a thin hour reads.
    property real floorFraction: 0.12

    property var _from: null
    property color _fromHue: heat.hue

    readonly property real _p: Math.max(0, Math.min(1, heat.progress))
    readonly property var _drawn: {
        const t = heat.target || [], f = heat._from, p = heat._p;
        const out = new Array(168);
        for (let i = 0; i < 168; i++) {
            const b = t[i] || 0;
            const a = f ? (f[i] || 0) : b;
            out[i] = a + (b - a) * p;
        }
        return out;
    }
    readonly property color hueNow: Mix.c(heat._fromHue, heat.hue, heat._p)

    // What is drawn now becomes the picture the next morph starts from.
    function hold() {
        heat._fromHue = heat.hueNow;
        heat._from = heat._drawn;
    }

    // ---- geometry (whole pixels) ----------------------------------------------
    readonly property real _labelW: 30
    readonly property real _topH: 14
    readonly property real _plotW: heat.width - heat._labelW
    readonly property real _plotH: heat.height - heat._topH
    readonly property real cellW: Math.max(1, Math.floor((heat._plotW - 23 * heat.cellGap) / 24))
    readonly property real cellH: Math.max(1, Math.floor((heat._plotH - 6 * heat.cellGap) / 7))
    readonly property real gridX: heat._labelW + Math.floor((heat._plotW - (24 * heat.cellW + 23 * heat.cellGap)) / 2)
    readonly property real gridY: heat._topH + Math.floor((heat._plotH - (7 * heat.cellH + 6 * heat.cellGap)) / 2)
    readonly property real rowPitch: heat.cellH + heat.cellGap

    function rowAt(y) {
        const r = Math.floor((y - heat.gridY + heat.cellGap / 2) / heat.rowPitch);
        return r >= 0 && r < 7 ? r : -1;
    }

    function _p2(n) {
        return (n < 10 ? "0" : "") + n;
    }

    Repeater {
        model: 7
        Text {
            required property int index
            x: 0
            y: heat.gridY + index * heat.rowPitch + Math.round((heat.cellH - height) / 2)
            text: index < heat.dayLabels.length ? heat.dayLabels[index] : ""
            color: index === heat.selectedDay ? Theme.accent : Theme.textFaint
            font.family: heat.fontFamily
            font.pixelSize: heat.labelSize
        }
    }
    Repeater {
        model: 4
        Text {
            required property int index
            x: heat.gridX + index * 6 * (heat.cellW + heat.cellGap)
            y: 0
            text: heat._p2((heat.startHour + index * 6) % 24)
            color: Theme.textFaint
            font.family: heat.fontFamily
            font.pixelSize: heat.labelSize
        }
    }
    Repeater {
        model: 168
        Rectangle {
            id: cell
            required property int index
            readonly property real v: heat._drawn[cell.index]
            x: heat.gridX + (cell.index % 24) * (heat.cellW + heat.cellGap)
            y: heat.gridY + Math.floor(cell.index / 24) * heat.rowPitch
            width: heat.cellW
            height: heat.cellH
            radius: heat.cellRadius
            color: Mix.c(Theme.panelSunk, heat.hueNow, cell.v > 0 ? heat.floorFraction + (1 - heat.floorFraction) * Math.pow(cell.v, 0.7) : 0)
        }
    }
}
