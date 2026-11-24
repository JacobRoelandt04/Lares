pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"
import "format.js" as Fmt

// The stopwatch view: the laps in the band under the ring -- newest first,
// each a lap time and the total, the fastest and slowest coloured once there
// are three. Start / Pause, and Lap and Reset under it, are the card's shared
// actions.
TimerView {
    id: view

    readonly property int lapCount: view.timers ? view.timers.laps.count : 0
    listViewport: lapFlick

    // The fastest and slowest lap, by number; recomputed when a lap lands.
    readonly property var _extremes: {
        const n = view.lapCount;
        if (n < 3)
            return { best: -1, worst: -1 };
        let best = 0, worst = 0;
        for (let i = 1; i < n; i++) {
            const l = view.timers.laps.get(i), b = view.timers.laps.get(best), w = view.timers.laps.get(worst);
            if (l.lapMs < b.lapMs) best = i;
            if (l.lapMs > w.lapMs) worst = i;
        }
        return { best: view.timers.laps.get(best).n, worst: view.timers.laps.get(worst).n };
    }

    Flickable {
        id: lapFlick
        x: Math.round(view.padding)
        y: view.bandTop
        width: Math.round(view.side - 2 * view.padding)
        height: Math.max(0, view.bandBottom - view.bandTop)
        clip: true
        interactive: false
        contentWidth: width
        contentHeight: lapCol.implicitHeight

        Column {
            id: lapCol
            width: lapFlick.width
            Repeater {
                model: view.timers ? view.timers.laps : null
                delegate: Item {
                    id: row
                    required property int n
                    required property real lapMs
                    required property real totalMs
                    readonly property color ink: row.n === view._extremes.best ? Theme.ok
                        : row.n === view._extremes.worst ? Theme.error : Theme.textPrimary
                    width: lapCol.width
                    height: 24
                    Text {
                        x: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Lap " + row.n
                        color: Theme.textMuted
                        font.family: view.fontFamily
                        font.pixelSize: 11
                    }
                    DigitCells {
                        text: Fmt.lap(row.lapMs)
                        fontFamily: view.fontFamily
                        pixelSize: 13
                        color: row.ink
                        x: Math.round(row.width * 0.36)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    DigitCells {
                        text: Fmt.lap(row.totalMs)
                        fontFamily: view.fontFamily
                        pixelSize: 11
                        bold: false
                        color: Theme.textFaint
                        x: Math.round(row.width - implicitWidth - 8)
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }
    ScrollDressing {
        anchors.fill: lapFlick
        flick: lapFlick
        wheelEnabled: view.listWheelEnabled
        ground: Theme.listBox
        fadeHeight: 18
    }
}
