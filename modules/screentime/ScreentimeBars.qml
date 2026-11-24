pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/ScreentimeModel.js" as Model

// =============================================================================
// ScreentimeBars.qml -- the Days face: seven bars of a week's active time.
//
// A TimelineChart, unboxed (the card's faces box carries the carve), with two
// bar series on one slot: the GHOST (every app, the week's totals, faint) and
// the FOCUS (the focused app's own seconds in its hue; with none focused the
// totals again, in the accent, covering the ghost). The series ids never
// change, so a focus change or a week step is one morph: the focus bars' colour
// and alpha mix on the chart's clock (`morphBarStyle`) and the heat grid and
// the span bars take the SAME clock from `chart.morphProgress`.
// =============================================================================
Item {
    id: root

    // A WEEK (service.week shape, today's day live-merged) or null.
    property var week: null
    // The week's first date: the labels come from it, so they are right while
    // the data is still on its way.
    property string weekKey: ""
    property string today: ""
    property string focusCls: ""
    property color focusHue: Theme.accent
    property int selectedDay: -1
    property string fontFamily: "Inter"

    property real ghostAlpha: 0.22
    property real barAlpha: 0.85
    property int morphMs: 260
    property real chartPadding: 6
    property real yMaxFloor: 3

    readonly property alias chart: chart
    readonly property int hoverIndex: chart.hoverIndex

    readonly property var _dates: root.weekKey !== "" ? Model.weekDates(root.weekKey) : []
    readonly property var _bars: Model.bars(root.week, root.focusCls !== "" ? root.focusCls : null, root.today)

    function _hours(list) {
        const out = [];
        for (let i = 0; i < 7; i++)
            out.push(list && i < list.length ? list[i] / 3600 : 0);
        return out;
    }

    TimelineChart {
        id: chart
        anchors.fill: parent
        boxed: false
        padding: root.chartPadding
        fontFamily: root.fontFamily
        surfaceColor: Theme.listBox
        fillColor: Theme.listBox
        morphMs: root.morphMs
        morphBarStyle: true
        barAlpha: root.barAlpha
        xLabelEvery: 1
        xLabels: root._dates.map(d => Model.dayLabel(d))
        // Today and the selected day are slot-wide columns behind the bars (the
        // weather strip's selected hour), not hairlines over them.
        markerStyle: "column"
        nowIndex: root._bars.todayIndex
        markerIndex: root.selectedDay
        yMin: 0
        yMaxFloor: root.yMaxFloor
        yNiceSteps: [1, 2, 5]
        yFormat: v => v + "h"
        series: [
            { id: "ghost", kind: "bars", values: root._hours(root._bars.total), color: Theme.textFaint,
              alpha: root.focusCls !== "" ? root.ghostAlpha : 0 },
            { id: "focus", kind: "bars", values: root._hours(root.focusCls !== "" ? root._bars.focus : root._bars.total),
              color: root.focusHue, alpha: root.barAlpha }
        ]
    }
}
