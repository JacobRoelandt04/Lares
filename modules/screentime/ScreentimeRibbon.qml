pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../common/theme"
import "../common/components"

// =============================================================================
// ScreentimeRibbon.qml -- one day as a histogram in a carved groove: the day
// cut into equal slots (whole hours round it), each slot a column whose height
// is the share of it spent active, stacked by app in the apps' hues -- the
// day's top apps each a layer, the rest one faint layer. A bursty day stays a
// row of clean columns however short its stops are, and every app's area is
// exactly its time (Model.dayColumns: readable while still accurate in
// proportions). Hour labels underneath, as many as fit.
//
// `columns` is Model.dayColumns(): {start, end, slotMs, n, layers: [{app, f}]}.
// Layers carry facts (a class or null, and fractions); `hueOf(cls)` is the
// host's function and each path resolves its own colour. The columns are ONE
// Shape (the geometry renderer: straight edges) with a fixed pool of paths.
// The slot's height and presence belong to the host's one fraction.
// =============================================================================
Item {
    id: root

    property var columns: null
    // function (cls) -> colour, from the host (the app's hue).
    property var hueOf: null
    property string fontFamily: "Inter"
    property int labelSize: 10
    property real stripHeight: 30
    property real inset: 3
    property real columnGap: 1
    property real labelGap: 4
    // Hour labels at least this far apart (px between their centres).
    property real tickMinPx: 56

    readonly property int layerPool: 6
    implicitHeight: root.stripHeight + root.labelGap + Math.ceil(labelFm.height)

    readonly property bool _has: root.columns !== null && root.columns.n > 0
    readonly property real _innerW: Math.max(0, root.width - 2 * root.inset)
    readonly property real _innerH: Math.max(0, root.stripHeight - 2 * root.inset)

    // One SVG path per layer: its part of every column, stacked from the foot
    // in layer order. Cumulative heights are rounded, so neighbours meet.
    readonly property var _paths: {
        const out = [];
        for (let i = 0; i < root.layerPool; i++)
            out.push("");
        if (!root._has)
            return out;
        const c = root.columns, n = c.n, w = root._innerW, h = root._innerH;
        const cw = w / n, gap = cw >= 4 ? root.columnGap : 0;
        const cum = new Array(n).fill(0);
        for (let i = 0; i < c.layers.length && i < root.layerPool; i++) {
            let p = "";
            const f = c.layers[i].f;
            for (let k = 0; k < n; k++) {
                if (f[k] <= 0)
                    continue;
                const x0 = Math.round(k * cw), x1 = Math.round((k + 1) * cw) - gap;
                const yb = h - Math.round(cum[k] * h), yt = h - Math.round(Math.min(1, cum[k] + f[k]) * h);
                cum[k] += f[k];
                if (yt < yb && x1 > x0)
                    p += "M" + x0 + " " + yt + "H" + x1 + "V" + yb + "H" + x0 + "Z";
            }
            out[i] = p;
        }
        return out;
    }

    // The hour labels' instants: every k hours from the first, k the fewest
    // hours whose labels stand tickMinPx apart.
    readonly property var _ticks: {
        if (!root._has)
            return [];
        const c = root.columns, hours = (c.end - c.start) / 3600000;
        const pxPerHour = hours > 0 ? root._innerW / hours : 0;
        let k = 12;
        for (const s of [1, 2, 3, 4, 6, 12])
            if (s * pxPerHour >= root.tickMinPx) {
                k = s;
                break;
            }
        const out = [];
        for (let t = c.start; t <= c.end + 1; t += k * 3600000)
            out.push(t);
        return out;
    }
    function _xOf(ms) {
        const c = root.columns;
        return root.inset + (ms - c.start) / Math.max(1, c.end - c.start) * root._innerW;
    }

    FontMetrics {
        id: labelFm
        font.family: root.fontFamily
        font.pixelSize: root.labelSize
    }

    ShadowBox {
        x: 0
        y: 0
        width: root.width
        height: root.stripHeight
        baseRadius: 8
        surfaceColor: Theme.surface
        bevelColor: Theme.bevel
        shadowColor: Theme.border
        backgroundColor: Theme.panelSunk
        bevelWidth: 1
        shadowWidth: 3
    }
    Shape {
        x: root.inset
        y: root.inset
        width: root._innerW
        height: root._innerH
        preferredRendererType: Shape.GeometryRenderer
        component Layer: ShapePath {
            id: layer
            property int i: 0
            readonly property var _layer: root._has && layer.i < root.columns.layers.length ? root.columns.layers[layer.i] : null
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: !layer._layer ? "transparent"
                : (layer._layer.app === null ? Theme.textFaint : (root.hueOf ? root.hueOf(layer._layer.app) : Theme.accent))
            PathSvg { path: root._paths[layer.i] }
        }
        Layer { i: 0 }
        Layer { i: 1 }
        Layer { i: 2 }
        Layer { i: 3 }
        Layer { i: 4 }
        Layer { i: 5 }
    }
    Repeater {
        model: root._ticks.length
        Text {
            id: tick
            required property int index
            readonly property real _cx: root._xOf(root._ticks[tick.index])
            x: Math.round(Math.max(0, Math.min(root.width - width, tick._cx - width / 2)))
            y: root.stripHeight + root.labelGap
            text: Qt.formatTime(new Date(root._ticks[tick.index]), "HH:mm")
            color: Theme.textFaint
            font.family: root.fontFamily
            font.pixelSize: root.labelSize
        }
    }
}
