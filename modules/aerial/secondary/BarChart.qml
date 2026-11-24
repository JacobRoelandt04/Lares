pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../../common/components"
import "../../common/theme"
import "PanelWords.js" as Words

// =============================================================================
// BarChart.qml -- the usage popup's 30-day chart: one bar per day, drawn TO SCALE (a bar's height is its bytes over the axis maximum,
// a 1-2-5 number), as ONE Shape -- the bars are rectangles of one path, today's bar a second path in the accent, the guides a third --
// never a pool of Rectangles. Bars and guides sit on whole device pixels. The labels (the axis maximum and half, the first / middle
// / last day) are Texts in the theme's muted ink.
//
//   days [{ day: "YYYY-MM-DD", bytes }]   oldest first, today last
// =============================================================================
Item {
    id: chart

    property PanelStyle look: null
    property var days: []
    property real plotHeight: 112
    property real gutter: 46
    property color barColor: Theme.border
    property color todayColor: Theme.accent
    property color guideColor: Theme.border

    readonly property int count: Math.max(1, chart.days.length)
    readonly property real maxBytes: {
        let m = 0;
        for (let i = 0; i < chart.days.length; i++)
            m = Math.max(m, Number(chart.days[i].bytes) || 0);
        return Words.niceMax(m);
    }
    readonly property real _dpr: dev.value
    readonly property real _plotW: Math.max(1, chart.width - chart.gutter)
    readonly property real _slot: chart._plotW / chart.count
    readonly property real _labelH: 16

    DeviceScale { id: dev }

    implicitWidth: 320
    implicitHeight: chart.plotHeight + chart._labelH + 6

    function _px(v: real): real {
        return Math.round(v * chart._dpr) / chart._dpr;
    }

    // the bars as one path string, in plot coordinates (x from the gutter, y from the top of the plot)
    readonly property var _paths: {
        const barW = Math.max(1 / chart._dpr, chart._px(chart._slot) - 2);
        const bars = [];
        let today = "";
        const n = chart.days.length;
        for (let i = 0; i < n; i++) {
            const b = Math.max(0, Number(chart.days[i].bytes) || 0);
            if (b <= 0)
                continue;
            const h = Math.max(1 / chart._dpr, chart._px(b / chart.maxBytes * chart.plotHeight));
            const x = chart.gutter + chart._px(i * chart._slot + (chart._slot - barW) / 2);
            const r = "M " + x + " " + (chart.plotHeight - h) + " h " + barW + " v " + h + " h " + (-barW) + " z";
            if (i === n - 1)
                today = r;
            else
                bars.push(r);
        }
        return { bars: bars.join(" "), today: today };
    }

    Shape {
        objectName: "chartShape"
        anchors.fill: parent
        preferredRendererType: Shape.GeometryRenderer
        // guides: the baseline, half and the maximum, hairlines
        ShapePath {
            strokeColor: chart.guideColor
            strokeWidth: 1 / chart._dpr
            fillColor: "transparent"
            PathSvg {
                path: "M " + chart.gutter + " 0.5 H " + chart.width
                      + " M " + chart.gutter + " " + (chart._px(chart.plotHeight / 2)) + " H " + chart.width
                      + " M " + chart.gutter + " " + chart.plotHeight + " H " + chart.width
            }
        }
        ShapePath {
            fillColor: chart.barColor
            strokeWidth: -1
            PathSvg { path: chart._paths.bars }
        }
        ShapePath {
            fillColor: chart.todayColor
            strokeWidth: -1
            PathSvg { path: chart._paths.today }
        }
    }

    PText {
        look: chart.look
        tone: 1
        small: true
        text: Words.bytes(chart.maxBytes)
        x: 0
        y: -implicitHeight / 2 + 0.5
        width: chart.gutter - 6
        horizontalAlignment: Text.AlignRight
    }
    PText {
        look: chart.look
        tone: 1
        small: true
        text: Words.bytes(chart.maxBytes / 2)
        x: 0
        y: chart._px(chart.plotHeight / 2) - implicitHeight / 2
        width: chart.gutter - 6
        horizontalAlignment: Text.AlignRight
    }
    PText {
        look: chart.look
        tone: 1
        small: true
        text: "0"
        x: 0
        y: chart.plotHeight - implicitHeight / 2
        width: chart.gutter - 6
        horizontalAlignment: Text.AlignRight
    }
    PText {
        look: chart.look
        tone: 1
        small: true
        x: chart.gutter
        y: chart.plotHeight + 6
        text: chart.days.length > 0 ? Words.dayLabel(chart.days[0].day) : ""
    }
    PText {
        look: chart.look
        tone: 1
        small: true
        x: chart.gutter + (chart._plotW - implicitWidth) / 2
        y: chart.plotHeight + 6
        text: chart.days.length > 2 ? Words.dayLabel(chart.days[Math.floor(chart.days.length / 2)].day) : ""
    }
    PText {
        look: chart.look
        tone: 1
        small: true
        x: chart.width - implicitWidth
        y: chart.plotHeight + 6
        text: chart.days.length > 1 ? "today" : ""
    }
}
