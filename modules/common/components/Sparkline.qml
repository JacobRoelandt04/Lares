pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../theme"

// =============================================================================
// Sparkline.qml -- a line of values in a small box, no axes, no labels.
//
//   Sparkline { values: row.spark.v; baselineValue: row.spark.base
//               color: up ? Theme.stockGain : Theme.stockLoss }
//
// The bar's portfolio day (22 x 12) and every list row's day. The values are
// drawn left to right across the box, scaled to fill its height between the
// lowest and the highest value -- the baseline counts as a value, so a dashed
// "yesterday's close" is always inside the box and the line's side of it
// reads at a glance.
//
// `maxPoints` is the number of SLOTS the x axis spans: a live day with 40 of
// its 102 five-minute points drawn over the left 40 % of the box, growing to
// the right as the session runs (Yahoo's own intraday sparkline). 0 (the
// default) spans exactly the values given, so the line fills the width. More
// values than slots widens the axis to fit them: nothing is dropped.
//
// A value that is not a finite number (null, NaN) BREAKS the line: the two
// sides are drawn as separate runs, never joined across the gap.
//
// EVERYTHING BELOW IS OFF BY DEFAULT, and with it off the paths are the ones
// above, number for number (the bar's and the rows' lines):
//   `times` + `timeFrom` / `timeTo`   x by TIME, not by index: a gap in the
//                 data is a gap in the picture and the axis may be longer
//                 than the data (`xAt(t)` is public, for a label under it).
//   `rangeMinSpan`   the least value span the box's height stands for, so a
//                 small move looks small (the range grows about its middle).
//   `rangePad`    room added above and below the range, as a share of its span
//                 (after `rangeMinSpan`): a baseline or a peak that is the range's
//                 extreme then stands inside the box, not on its edge.
//   `emphasisFrom` / `emphasisTo`   the points inside (times when `times` is
//                 set, else indexes) are drawn again, over the line, in
//                 `emphasisColor`; `emphasisFill` > 0 lays a gradient of that
//                 alpha under that run only.
//   `endDot`      a dot of that radius on the last finite point.
//   `levelValue`  a second dashed line (`levelColor`), inside the range too.
//   `warp` + `warpT`   a displacement in PIXELS, `warp(x, width) -> dy`, added
//                 to every point of the line after it is placed (a flourish's
//                 ripple: warping the VALUES would rescale the whole line).
//                 `warpT` is what the path's binding reads: a function call
//                 captures nothing, so the host moves `warpT` to re-pose.
//                 Baseline, level, emphasis and dot do not move.
//
// ONE RENDERER FOR THE CURVE. Qt's default Shape renderer tessellates a line
// and its joins separately and they do not meet to the pixel (CLAUDE.md), so
// the line is the CurveRenderer's. The baseline is a straight horizontal dash
// on a pixel centre, which the default renderer draws exactly.
// =============================================================================
Item {
    id: root

    // ---- Contract --------------------------------------------------------
    property var values: []
    // NaN = no baseline. Drawn dashed, in `baselineColor`. Not `baseline`:
    // that is Item's own anchor line, FINAL, and a property of that name
    // shadows it (qmllint: property-override).
    property real baselineValue: NaN
    property color color: Theme.textPrimary
    property color baselineColor: Theme.textFaint
    property real lineWidth: 1.25
    property real baselineWidth: 1
    // The dash and the gap, in units of `baselineWidth` (ShapePath's own).
    property var baselineDash: [2, 2]
    // Slots the x axis spans; 0 = the values' own count (fills the width).
    property int maxPoints: 0

    property var times: null
    property real timeFrom: NaN
    property real timeTo: NaN
    property real rangeMinSpan: 0
    property real rangePad: 0
    property real emphasisFrom: NaN
    property real emphasisTo: NaN
    property color emphasisColor: Theme.accent
    property real emphasisWidth: root.lineWidth
    property real emphasisFill: 0
    property real endDot: 0
    property color endDotColor: root._hasEmph ? root.emphasisColor : root.color
    property real levelValue: NaN
    property color levelColor: Theme.accent
    property var warp: null
    property real warpT: 0

    implicitWidth: 22
    implicitHeight: 12

    // ---- Geometry ----------------------------------------------------------
    readonly property bool _hasBase: isFinite(root.baselineValue)
    readonly property bool _hasLevel: isFinite(root.levelValue)
    readonly property bool _hasEmph: isFinite(root.emphasisFrom) && isFinite(root.emphasisTo)
    readonly property bool _byTime: !!root.times && isFinite(root.timeFrom) && isFinite(root.timeTo)
                                    && root.timeTo > root.timeFrom

    // The value range, the baseline included, padded so the stroke's half
    // width and its antialiasing stay inside the box.
    readonly property var _range: {
        const v = root.values || [];
        let lo = Infinity, hi = -Infinity;
        for (let i = 0; i < v.length; i++) {
            const x = v[i];
            if (x === null || x === undefined || !isFinite(x))
                continue;
            if (x < lo) lo = x;
            if (x > hi) hi = x;
        }
        if (root._hasBase) {
            lo = Math.min(lo, root.baselineValue);
            hi = Math.max(hi, root.baselineValue);
        }
        if (!isFinite(lo))
            return null;
        if (root._hasLevel) {
            lo = Math.min(lo, root.levelValue);
            hi = Math.max(hi, root.levelValue);
        }
        if (root.rangeMinSpan > 0 && hi - lo < root.rangeMinSpan) {
            const mid = (lo + hi) / 2;
            lo = mid - root.rangeMinSpan / 2;
            hi = mid + root.rangeMinSpan / 2;
        }
        if (root.rangePad > 0 && hi > lo) {
            const room = (hi - lo) * root.rangePad;
            lo -= room;
            hi += room;
        }
        return { lo: lo, hi: hi };
    }
    readonly property real _pad: root.lineWidth / 2 + 0.5

    function _yFor(v) {
        const r = root._range;
        const top = root._pad, bot = root.height - root._pad;
        if (!r || r.hi - r.lo < 1e-12)
            return (top + bot) / 2;
        return bot - (v - r.lo) / (r.hi - r.lo) * (bot - top);
    }

    // Where a time stands on the x axis (only with `times`).
    function xAt(t) {
        const left = root._pad, right = root.width - root._pad;
        if (!root._byTime)
            return left;
        return left + (t - root.timeFrom) / (root.timeTo - root.timeFrom) * (right - left);
    }

    // Every finite value placed, unwarped: runs of { x, y, k } (k = its time,
    // or its index), broken where a value is not finite.
    readonly property var _placed: {
        const v = root.values || [];
        const r = root._range;
        if (!r || v.length < 2 || root.width <= 0 || root.height <= 0)
            return [];
        const slots = Math.max(v.length, root.maxPoints);
        const left = root._pad, right = root.width - root._pad;
        const step = (right - left) / Math.max(1, slots - 1);
        const byTime = root._byTime;
        const ts = root.times;
        const runs = [];
        let run = [];
        for (let i = 0; i < v.length; i++) {
            const x = v[i];
            if (x === null || x === undefined || !isFinite(x)) {
                if (run.length > 1)
                    runs.push(run);
                run = [];
                continue;
            }
            run.push({ x: byTime ? root.xAt(ts[i]) : left + i * step, y: root._yFor(x), k: byTime ? ts[i] : i });
        }
        if (run.length > 1)
            runs.push(run);
        return runs;
    }

    // Runs of consecutive finite values, as point arrays for PathMultiline.
    readonly property var _runs: {
        const placed = root._placed;
        const fn = root.warp;
        const wt = root.warpT;      // the dependency: `fn(...)` is no property read
        const w = root.width;
        const runs = [];
        for (let a = 0; a < placed.length; a++) {
            const run = [];
            for (let i = 0; i < placed[a].length; i++) {
                const p = placed[a][i];
                run.push(Qt.point(p.x, fn ? p.y + fn(p.x, w, wt) : p.y));
            }
            runs.push(run);
        }
        return runs;
    }

    // The emphasised points: the same places, cut to [emphasisFrom, emphasisTo].
    readonly property var _emphRuns: {
        if (!root._hasEmph)
            return [];
        const placed = root._placed;
        const runs = [];
        for (let a = 0; a < placed.length; a++) {
            const run = [];
            for (let i = 0; i < placed[a].length; i++) {
                const p = placed[a][i];
                if (p.k >= root.emphasisFrom && p.k <= root.emphasisTo)
                    run.push(Qt.point(p.x, p.y));
            }
            if (run.length > 1)
                runs.push(run);
        }
        return runs;
    }
    // The area under them, closed along the box's foot.
    readonly property var _emphAreas: {
        if (!(root.emphasisFill > 0))
            return [];
        const out = [];
        for (let a = 0; a < root._emphRuns.length; a++) {
            const run = root._emphRuns[a];
            const poly = run.slice();
            poly.push(Qt.point(run[run.length - 1].x, root.height));
            poly.push(Qt.point(run[0].x, root.height));
            poly.push(run[0]);
            out.push(poly);
        }
        return out;
    }
    readonly property var _last: {
        const placed = root._placed;
        if (!placed.length)
            return null;
        const run = placed[placed.length - 1];
        return run[run.length - 1];
    }
    readonly property real _levelY: root._hasLevel && root._range
                                    ? Math.floor(root._yFor(root.levelValue)) + 0.5 : 0

    // On a pixel centre, so the 1 px dash is one row of ink.
    readonly property real _baseY: root._hasBase && root._range
                                   ? Math.floor(root._yFor(root.baselineValue)) + 0.5 : 0

    // ---- Paint ---------------------------------------------------------------
    Shape {
        id: baseShape
        anchors.fill: parent
        visible: root._hasBase && root._range !== null
        ShapePath {
            strokeColor: root.baselineColor
            strokeWidth: root.baselineWidth
            strokeStyle: ShapePath.DashLine
            dashPattern: root.baselineDash
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
            startX: 0
            startY: root._baseY
            PathLine { x: root.width; y: root._baseY }
        }
    }

    Shape {
        id: levelShape
        anchors.fill: parent
        visible: root._hasLevel && root._range !== null
        ShapePath {
            strokeColor: root.levelColor
            strokeWidth: root.baselineWidth
            strokeStyle: ShapePath.DashLine
            dashPattern: root.baselineDash
            fillColor: "transparent"
            capStyle: ShapePath.FlatCap
            startX: 0
            startY: root._levelY
            PathLine { x: root.width; y: root._levelY }
        }
    }

    // Straight-edged fills take the geometry renderer (CLAUDE.md).
    Shape {
        id: areaShape
        anchors.fill: parent
        preferredRendererType: Shape.GeometryRenderer
        visible: root._emphAreas.length > 0
        ShapePath {
            strokeColor: "transparent"
            strokeWidth: 0
            fillGradient: LinearGradient {
                x1: 0; y1: 0; x2: 0; y2: root.height
                GradientStop { position: 0; color: Qt.rgba(root.emphasisColor.r, root.emphasisColor.g, root.emphasisColor.b, root.emphasisFill) }
                GradientStop { position: 1; color: Qt.rgba(root.emphasisColor.r, root.emphasisColor.g, root.emphasisColor.b, 0) }
            }
            PathMultiline {
                paths: root._emphAreas
            }
        }
    }

    Shape {
        id: lineShape
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: root._runs.length > 0
        ShapePath {
            strokeColor: root.color
            strokeWidth: root.lineWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline {
                paths: root._runs
            }
        }
    }

    Shape {
        id: emphShape
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
        visible: root._emphRuns.length > 0
        ShapePath {
            strokeColor: root.emphasisColor
            strokeWidth: root.emphasisWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathMultiline {
                paths: root._emphRuns
            }
        }
    }

    Rectangle {
        id: dot
        visible: root.endDot > 0 && root._last !== null
        width: root.endDot * 2
        height: width
        radius: root.endDot
        color: root.endDotColor
        x: (root._last ? root._last.x : 0) - root.endDot
        y: (root._last ? root._last.y : 0) - root.endDot
    }
}
