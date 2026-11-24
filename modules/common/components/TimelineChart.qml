pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../theme"

// =============================================================================
// TimelineChart.qml -- a carved plot of one day's series, generic.
//
// A ShadowBox listBox with a plot inside it: lines (Catmull-Rom smoothed,
// clamped so the curve never overshoots its data, broken at gaps), bars, a
// filled band between two series, direction arrows along a top baseline,
// horizontal dashed thresholds with a label (placed clear of every line), a
// value-band gradient the first gradient line is stroked and filled with, a
// marker hairline with a dot on every line, and a faint "now" mark. Nothing
// here knows what a metric is.
//
//     TimelineChart {
//         series: [
//             { id: "temp",  kind: "line",  values: [...], color: Theme.accent, width: 2, gradient: true },
//             { id: "feels", kind: "line",  values: [...], color: Theme.textMuted, dotted: true },
//             { id: "gust",  kind: "band",  values: gust, bandLow: speed, color: Theme.accent },
//             { id: "mm",    kind: "bars",  values: [...], color: Theme.weatherRain },
//             { id: "prob",  kind: "line",  values: [...], color: Theme.textFaint, range: [0, 100] },
//             { id: "dir",   kind: "arrows", values: degrees, color: Theme.textMuted }
//         ]
//         xLabels: ["00", "01", ...]; xLabelEvery: 3
//         yMin: NaN; yMax: NaN                 // NaN = auto, padded to nice ticks
//         yMaxFloor: NaN                       // an auto top never below this
//         yMinSpan: 0                          // an auto extent never narrower than this
//         yNiceSteps: [1, 2, 5]                // tick mantissas; default [1, 2, 2.5, 5]
//         yFormat: v => v + "°"
//         thresholds: [{ value: 0, label: "Freezing", color: Theme.weatherSnow }]
//         gradientStops: [{ value: -10, color: c1 }, { value: 30, color: c2 }]
//         markerIndex: 15; nowIndex: 19
//         onHovered: index => ...
//     }
//
// `values` are numbers or null (a gap). A series with its own `range: [lo, hi]`
// is mapped on that instead of the shared axis (a probability beside
// millimetres). Every x is SLOT-BASED: index i sits at the centre of the i-th
// of n equal slots, so a bar and a line at the same index are on one vertical,
// and so is the marker -- `xFor(i)` is the one mapping, `yFor(v)` the other,
// and both are public so a host or a probe can hold the drawing to them.
//
// THE LINES ARE A FIXED POOL. A Shape's ShapePaths are declared, not
// repeated, so there are four stroke slots, one gradient line, one gradient
// area, two bands and one arrow path; an unused slot holds an empty path and
// draws nothing. A gradient stroke does not exist in Qt Quick Shapes, so the
// gradient line is drawn as a FILLED offset band of the curve (two sides,
// `width` apart) under a vertical LinearGradient whose stops are the value
// stops mapped through the axis; the area under it takes the same gradient at
// `areaAlpha`.
//
// ---- THE MORPH ------------------------------------------------------------------
//
// A host that changes WHAT is plotted (the detail's day, its pollutant tab)
// wraps the change:
//
//     chart.morph(() => host.day = 3)     // the drawn picture moves to the new one
//     chart.jump(() => host.metric = m)   // no motion: the new picture at once
//
// Everything is drawn from ONE object, `_frame`. At rest it is `_target`, the
// picture of the current inputs (the static mappings above, captured once).
// morph() SNAPSHOTS THE DRAWN FRAME, holds the target while the host's
// inputs cascade (a day change moves a dozen properties one binding at a
// time: the target is built once, after all of them), and starts one clock
// (ViewBlend, `morphMs` OutCubic); every tick draws `_lerpFrame(from,
// target, e)`. A morph that lands while another is moving starts from what is
// on screen, so rapid steps never jump. Per kind:
//
//   axis      lo/hi move in DATA space and every value is mapped through the
//             drawn axis, so a line and the grid line at its value move
//             together; the label column's width, the plot's top (the room
//             a top threshold's label takes) move with it
//   lines     each slot's point moves from its old value to its new one. A
//   bands     slot with a value on one side only COLLAPSES onto the nearest
//             point the other side has: today's empty morning unrolls out of
//             "now" (and rolls back into it), a last day's missing evening
//             out of its last hour, one path throughout. A gap that opens or
//             closes inside a run splits at its middle slot, whose two copies
//             part or meet there. A series with no point on one side rises
//             from (sinks to) the axis floor while its presence fades
//   bars      each bar's value moves; one side missing is the axis floor
//   arrows    the shorter way round; an arrow on one side only grows from /
//             shrinks to its centre
//   ticks     matched by value: a tick on both sides stays (and moves with
//             the axis); the others fade, their labels in the half of the
//             clock that is theirs (out in the first, in in the second), so
//             two labels never crossfade in one place. A figure's text swaps
//             at once
//   thresholds  by index: the line follows its value; a label that changes
//             side fades out on the old one and in on the new, by halves
//   gradient  the stops follow their values (by index), so the colour bands
//             stay on their values while the axis moves
//   now       presence (it exists on today only), the marker too
//   empty     the plot and the empty text fade by halves, never through each
//             other; an empty target keeps the axis it morphed from as its
//             grid silhouette (jump() drops it)
//
// Anything that leaves the plot while the axis moves fades over `edgeFadePx`
// past the plot's edge (a soft edge that is zero at both ends of the clock:
// at rest the plot's edge is hard).
//
// NOTHING IS CREATED BY A CHANGE. The grid, the bars, the thresholds and the
// dots are fixed POOLS (Repeaters over a constant count, `_tickPool` etc.), and
// the lines are a fixed pool of ShapePaths: a day change inside a wheel
// delivery moves numbers and nothing else (the wheel trap). The frame holds
// facts and captured colours; the Repeater models hold counts (CLAUDE.md: a
// themed colour in a model regenerates every delegate).
//
// HARNESS STILLS. pinMorph(t) stops the clock at linear t of the current morph.
//
// ---- OPT-IN EXTENSIONS (the stocks module; every default draws the plain chart) ----
//
//   series `curve`   "smooth" (default, the clamped Catmull-Rom) | "linear"
//                    (straight segments point to point) | "step" (a value holds
//                    until the next: across at its level, then up or down)
//   bars `range`     a bars series with its own [lo, hi] stands on it, held
//                    inside it (volume under a price); `alpha` per series
//                    (default barAlpha)
//   areaFade         0..1: the gradient line's area falls from areaAlpha at
//                    the plot's top to areaAlpha x (1 - areaFade) at its foot
//   kind "marks"     `values` (null where none) + `glyphs` ("buy" | "sell")
//                    per index: a triangle from Symbols Nerd Font centred ON
//                    (xFor(i), yFor(v)), buyColor / sellColor unless the series
//                    has a `color`; a fixed pool of 24
//   threshold `extendsAxis: true`   its value is inside the auto axis
//   xTicks           [{ i, text }]: sparse labels at slot i (pool 12), beside
//                    xLabels, which are untouched
//   boxed            false drops the carved box; knock-outs take surfaceColor
//   hoverY           the pointer's y in the item (NaN off the plot), beside
//                    hoverIndex
//   line `dash`      [on, off] in line widths: a dashed stroke (a join drawn
//                    across missing data); `alpha` on a line scales its stroke
//   series `group`   parts of one line (_borrow): a morph moves them as one
//   markerFollowsPointer   the hairline is the POINTER's, not the index's: it
//                    stands at the pointer's x whatever the chart does under
//                    it (a morph included), each line's dot rides that line as
//                    drawn at that x. (`hoverIndex` re-reads the slot when the
//                    mapping changes under a still pointer, a range swiped
//                    under it: `_rehover`. Qt's re-delivered
//                    hover does not do it: a plot that did not move under the
//                    pointer hears nothing.) `markerIndex` then only says
//                    whether it shows.
//   spanEnds         the first and last slots' centres on the plot's edges, so
//                    every range's line runs edge to edge: the slot strip is
//                    the plot grown by half a slot on each side (`sx0`, the
//                    strip's origin; spacing (W) / (n - 1)). Without it a line
//                    of n points stops half a slot short of each edge -- 9.5 px
//                    on the summary's 24-point month, 1 px on a 250-point year.
//
// ---- OPT-INS (screentime) ----
//
//   morphBarStyle    a bars series present on both sides mixes its colour and
//                    alpha on the morph's clock (a total becoming one app's
//                    share in that app's hue) instead of taking the new style
//                    at once
//   morphProgress    the morph's eased fraction (1 at rest), and `morphing`:
//                    for a host drawing pictures of its own on the same clock
//   markerStyle      "line" (default: the hairlines) or "column": the marker and
//                    the now mark are slot-wide rounded columns BEHIND the grid
//                    and the bars, from the plot's top to the foot of the x
//                    labels -- the weather strip's selected hour. The now
//                    column is `nowColumnAlpha` of the marker's
// =============================================================================
Item {
    id: root

    // ---- Data -------------------------------------------------------------
    property var series: []
    property var xLabels: []
    property int xLabelEvery: 3
    property real yMin: NaN
    property real yMax: NaN
    // The auto axis' policy (WeatherSeries.js has the weather table). A FLOOR
    // for the top: data under it is drawn against it, so a fine value does not
    // climb to the top of the plot just because nothing worse happened that
    // day; data above it extends the axis as before. A MINIMUM SPAN for a
    // range-type axis: a narrower data extent is widened about its midpoint
    // (or away from a fixed end), so a 1-degree evening is not drawn as the
    // swing of a heatwave. NaN / 0 leave the axis to the data.
    property real yMaxFloor: NaN
    property real yMinSpan: 0
    property int yTicks: 4
    // The mantissas a tick step may take (x 10^k), ascending. A host whose
    // figures print as whole numbers leaves 2.5 out: a 2.5 step labels 7.5 as
    // "8" and the grid then lies about where 8 is.
    property var yNiceSteps: [1, 2, 2.5, 5]
    // v => string. null prints the plain number.
    property var yFormat: null
    property var thresholds: []
    property var gradientStops: []
    property int markerIndex: -1
    property int nowIndex: -1
    // Where the pointer is, in indices; -1 when it is not over the plot.
    property int hoverIndex: -1
    signal hovered(int index)
    // Drawn centred in the plot when there is nothing to plot.
    property string emptyText: ""
    // Sparse x labels, [{ i: slot, text }] (see OPT-IN EXTENSIONS).
    property var xTicks: []
    // The gradient area's fall towards the plot's foot (0 = none).
    property real areaFade: 0
    // false: no carved box, the plot sits on the host's ground.
    property bool boxed: true
    // ---- Opt-ins for charts whose slot count changes (the stocks charts; the
    // weather draws without them) ------------------------------------------
    // Bars drawn as ONE path per series instead of a pool of Rectangles sized
    // 2 x slots. A range change resizes that pool, and creating the delegates
    // is two thirds of a stock chart's rebuild (9-25 ms against 3-8 with the
    // slot count unchanged); during a morph every delegate also re-reads the
    // frame on every tick. No rounded corners.
    property bool barsAsPath: false
    // A morph between frames with DIFFERENT slot counts pairs points by where
    // they are on the plot, not by index: both frames are resampled onto the
    // merged set of their own point positions (_resamplePair), so each line
    // passes through every one of its own points and the morph's first and
    // last frames ARE the two pictures (exact for "linear" and "step" curves;
    // a "smooth" one bends slightly differently through the extra points).
    property bool morphResample: false
    property bool markerFollowsPointer: false
    property bool spanEnds: false
    // The held axis's grid without its labels -- the label column keeps its
    // width, so the plot does not move -- and the series drawn on their own
    // ranges: a loading picture a morph can go into and come out of. Without a
    // held axis (after jump(), or first) a plain 0..1 grid with no label column.
    property bool skeleton: false
    // A morph whose line changes COLOUR (a gain turning into a loss) passes
    // through this one instead of mixing the two: red and green meet in brown.
    // Transparent (the default): the two are mixed.
    property color morphColorVia: "transparent"
    // A morph whose BARS change colour or alpha (screentime: a day's total
    // turning into one app's share, in that app's hue) mixes both on the
    // morph's clock. Off (the default): the bars take the new series' style
    // at once.
    property bool morphBarStyle: false
    // The pointer's y in the item's coordinates; NaN when it is not over the plot.
    readonly property real hoverY: root._hoverY
    property real _hoverY: NaN
    // The pointer's x in the item while it is over the plot (NaN off it).
    property real _hoverPx: NaN

    // ---- Look -------------------------------------------------------------
    // "line" | "column" (see OPT-INS (screentime)).
    property string markerStyle: "line"
    property color columnColor: Theme.headerBox
    property real nowColumnAlpha: 0.5
    property real columnInset: 3
    property string fontFamily: "Inter"
    property bool compact: false
    property real radius: root.compact ? 10 : 14
    property real padding: root.compact ? 8 : 12
    property int figureSize: root.compact ? 10 : 11
    property color surfaceColor: Theme.surface
    property color fillColor: Theme.listBox
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color gridColor: Theme.border
    property color textColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color markerColor: Theme.textPrimary
    property color nowColor: Theme.accent
    property real lineWidth: 2
    // The carve of the plot's box; a host that does not set them gets these.
    property real bevelWidth: 1
    property real shadowWidth: 3
    property real shadowFalloff: 1
    property real areaAlpha: 0.22
    property real bandAlpha: 0.2
    property real barAlpha: 0.8
    // Reserved above the plot while an arrows series has an arrow to draw.
    property real arrowBand: 16
    property real dotRadius: 3.5
    // Trade marks: the glyph's pixel size (the triangle's ink is about a third
    // of it) and the two colours. The face is fixed (`_markFont`): the marks
    // are centred from its outline.
    property int markPixelSize: root.compact ? 21 : 24
    property color buyColor: Theme.stockBuy
    property color sellColor: Theme.stockSell

    implicitWidth: 320
    implicitHeight: 160

    // ---- The slots and the axes ------------------------------------------
    readonly property int _n: {
        let n = root.xLabels.length;
        for (let k = 0; k < root.series.length; k++) {
            const s = root.series[k];
            if (s && s.values && s.values.length > n)
                n = s.values.length;
        }
        return n;
    }
    // The arrows' band is reserved while an arrows series has an arrow to
    // draw: a day without one (a steady pressure day) gives the plot the
    // room, and a day change moves the plot's top with the rest.
    readonly property bool _hasArrows: {
        const k = root._firstOfKind("arrows");
        const vs = k >= 0 && root.series[k].values ? root.series[k].values : [];
        for (let i = 0; i < vs.length; i++) {
            if (root._isNum(vs[i]))
                return true;
        }
        return false;
    }
    readonly property bool _empty: root._n === 0 || root.series.length === 0

    function _firstOfKind(kind) {
        for (let k = 0; k < root.series.length; k++) {
            if (root.series[k] && root.series[k].kind === kind)
                return k;
        }
        return -1;
    }
    function _isNum(v) {
        return typeof v === "number" && isFinite(v);
    }

    // The shared axis: the data's extent over every series without a range
    // of its own, held to the floor and the minimum span, then padded out to
    // nice ticks (`yNiceSteps` x 10^k).
    readonly property var _axis: {
        let lo = Infinity, hi = -Infinity;
        for (let k = 0; k < root.series.length; k++) {
            const s = root.series[k];
            if (!s || s.kind === "arrows" || (s.range && s.range.length === 2))
                continue;
            const lists = [s.values || []];
            if (s.kind === "band" && s.bandLow)
                lists.push(s.bandLow);
            for (const vs of lists) {
                for (let i = 0; i < vs.length; i++) {
                    const v = vs[i];
                    if (!root._isNum(v))
                        continue;
                    if (v < lo) lo = v;
                    if (v > hi) hi = v;
                }
            }
        }
        // A threshold that asks for it is part of the extent (an average cost
        // the price has left far behind is still on the plot).
        const ths = root.thresholds || [];
        for (let k = 0; k < ths.length; k++) {
            const t = ths[k];
            if (t && t.extendsAxis === true && root._isNum(t.value)) {
                if (t.value < lo) lo = t.value;
                if (t.value > hi) hi = t.value;
            }
        }
        const fixedLo = root._isNum(root.yMin), fixedHi = root._isNum(root.yMax);
        if (fixedLo) lo = root.yMin;
        if (fixedHi) hi = root.yMax;
        if (!isFinite(lo) || !isFinite(hi)) {
            lo = fixedLo ? lo : 0;
            hi = fixedHi ? hi : lo + 1;
        }
        if (!fixedHi && root._isNum(root.yMaxFloor) && hi < root.yMaxFloor)
            hi = root.yMaxFloor;
        const span = root._isNum(root.yMinSpan) ? root.yMinSpan : 0;
        if (span > 0 && hi - lo < span) {
            if (fixedLo && !fixedHi) {
                hi = lo + span;
            } else if (fixedHi && !fixedLo) {
                lo = hi - span;
            } else if (!fixedLo && !fixedHi) {
                const mid = (lo + hi) / 2;
                lo = mid - span / 2;
                hi = mid + span / 2;
            }
        }
        if (hi - lo < 1e-9)
            hi = lo + 1;
        const ticks = Math.max(1, root.yTicks);
        const raw = (hi - lo) / ticks;
        const mag = Math.pow(10, Math.floor(Math.log10(raw)));
        const norm = raw / mag;
        const choices = Array.isArray(root.yNiceSteps) && root.yNiceSteps.length > 0 ? root.yNiceSteps : [1, 2, 2.5, 5];
        let mant = 10;
        for (let k = 0; k < choices.length; k++) {
            if (norm <= choices[k] + 1e-9) {
                mant = choices[k];
                break;
            }
        }
        const step = mant * mag;
        const aLo = fixedLo ? lo : Math.floor(lo / step + 1e-9) * step;
        const aHi = fixedHi ? hi : Math.ceil(hi / step - 1e-9) * step;
        const tv = [];
        const first = Math.ceil(aLo / step - 1e-9) * step;
        for (let v = first; v <= aHi + 1e-9 && tv.length < 64; v += step)
            tv.push(Math.abs(v) < 1e-9 ? 0 : v);
        return { lo: aLo, hi: aHi, step: step, ticks: tv };
    }
    readonly property var _tickValues: root._axis.ticks

    function _fmt(v) {
        return root.yFormat ? root.yFormat(v) : String(v);
    }
    // The tick labels, in ONE precision. A host's formatter decides decimals
    // per value (the weather module prints one decimal under 10 and none from
    // 10), so an axis would read "0.0, 10, 20, 30", or "0.00, 1.0, 2.0" in mg/m³.
    // When every label is a plain number (a unit suffix allowed) they are
    // printed again with the fewest decimals that still state each one
    // exactly; anything else is left as the formatter wrote it. An EMPTY
    // chart states no quantity: its grid stays as a silhouette behind the
    // empty text, and its labels are blank (a 0..1 axis in 0.25 steps would
    // be figures about nothing).
    readonly property var _tickLabels: {
        if (root._empty)
            return root._tickValues.map(() => "");
        const raw = root._tickValues.map(v => String(root._fmt(v)));
        const re = /^(-?\d+)(?:\.(\d+))?(\D*)$/;
        const parts = [];
        let maxDec = 0;
        for (let i = 0; i < raw.length; i++) {
            const m = re.exec(raw[i]);
            if (!m)
                return raw;
            parts.push({ n: parseFloat(m[1] + (m[2] ? "." + m[2] : "")), suffix: m[3] });
            maxDec = Math.max(maxDec, m[2] ? m[2].length : 0);
        }
        let d = 0;
        while (d < maxDec && !parts.every(q => Math.abs(parseFloat(q.n.toFixed(d)) - q.n) < 1e-9))
            d++;
        return parts.map(q => {
            let t = q.n.toFixed(d);
            if (/^-0(\.0*)?$/.test(t))
                t = t.substring(1);
            return t + q.suffix;
        });
    }

    FontMetrics {
        id: fm
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }
    // Reads `fm.font` first: advanceWidth is a call, and the binding would
    // otherwise keep its first answer when the face changes.
    readonly property real _yLabelW: {
        const f = fm.font;
        let w = 0;
        const labels = root._tickLabels;
        for (let i = 0; i < labels.length; i++)
            w = Math.max(w, fm.advanceWidth(labels[i]));
        return Math.ceil(w);
    }
    readonly property real _lineH: Math.ceil(fm.height)
    // Where a figure's INK sits in its line box: its digits' top and foot
    // below the box's top (the face's ascent over the digits). Reads the
    // metrics' font first: tightBoundingRect is a call and captures nothing.
    readonly property var _labelInk: {
        const f = fm.font;
        const r = fm.tightBoundingRect("0123456789°");
        return { top: Math.round(fm.ascent + r.y), bottom: Math.round(fm.ascent + r.y + r.height) };
    }

    // The plot rectangle, in the item's coordinates. THE MARGIN IS MEASURED
    // TO INK (the popup's rule): the top figure's
    // digits start `padding` below the card's edge (or the arrows do, the
    // figures then a band lower), the hour labels' digits end `padding`
    // above its foot, and the figures' column starts on the padding line --
    // an empty chart, which prints no figure, runs its grid from there.
    readonly property real px0: root.padding + (root._yLabelW > 0 ? root._yLabelW + 6 : 0)
    readonly property real px1: root.width - root.padding
    readonly property real py0: root._py0Base + root._labelRoom
    readonly property real _py0Base: root.padding + (root._hasArrows ? root.arrowBand : 0)
                                     + (root._yLabelW > 0 ? Math.ceil(root._lineH / 2) - root._labelInk.top : 0)
    // A threshold's label stands ABOVE its line, and with an axis floor the
    // band's line is often the axis top itself: its label would rise a whole
    // line above the plot, into the card's padding. The plot gives up the
    // difference so that label's ink, like the top tick's, starts no higher
    // than the padding line (the arrows' band's foot when there are arrows):
    // it may rise half a line over the plot. Only the highest labelled threshold decides (the spacing pass
    // keeps the topmost label always; a line through both of its ends can
    // still hide it, which costs a few pixels of room, never a collision);
    // measured on the unshifted plot, which is self-consistent -- the shift
    // only brings the line nearer the top. It must not read the placement:
    // the placement reads the plot this sizes.
    readonly property real _labelRoom: {
        const a = root._axis, ths = root.thresholds;
        const ph = root.py1 - root._py0Base;
        if (ph <= 0 || !(a.hi > a.lo))
            return 0;
        let top = -Infinity;
        for (let k = 0; k < ths.length; k++) {
            const t = ths[k];
            if (t && root._isNum(t.value) && t.value >= a.lo && t.value <= a.hi && t.label)
                top = Math.max(top, t.value);
        }
        if (!isFinite(top))
            return 0;
        const below = (a.hi - top) / (a.hi - a.lo) * ph;
        return Math.max(0, Math.ceil(Math.floor(root._lineH / 2) - below));
    }
    readonly property real py1: root.height - root.padding - root._labelInk.bottom - 4
    readonly property bool _span: root.spanEnds && root._n > 1
    readonly property real slotW: root._n > 0 ? (root.px1 - root.px0) / (root._span ? root._n - 1 : root._n) : 0
    // Where the slot strip starts: the plot's left edge, or half a slot left
    // of it (spanEnds).
    readonly property real _sx0: root._span ? root.px0 - root.slotW / 2 : root.px0

    function xFor(i) {
        return root._sx0 + (i + 0.5) * root.slotW;
    }
    function yFor(v) {
        const a = root._axis;
        return root.py1 - (v - a.lo) / (a.hi - a.lo) * (root.py1 - root.py0);
    }
    function _yForRange(v, r) {
        return root.py1 - (v - r[0]) / (r[1] - r[0]) * (root.py1 - root.py0);
    }
    function _ySeries(s, v) {
        return s.range && s.range.length === 2 ? root._yForRange(v, s.range) : root.yFor(v);
    }
    // A series' curve: "smooth" unless it asks for "linear" or "step".
    function _curveOf(s) {
        return s && (s.curve === "linear" || s.curve === "step") ? s.curve : "smooth";
    }
    // The anchor points of a series: { x, y } or null per index.
    function pointsOf(sid) {
        const s = root.series[sid];
        const out = [];
        if (!s || !s.values)
            return out;
        for (let i = 0; i < s.values.length; i++) {
            const v = s.values[i];
            out.push(root._isNum(v) ? { x: root.xFor(i), y: root._ySeries(s, v) } : null);
        }
        return out;
    }


    // ---- Paths: runs of { x, y } (and y2, a band's low side) into SVG ------------
    function _f(v) {
        return v.toFixed(2);
    }
    // The contiguous runs of a point list.
    function _runs(pts) {
        const runs = [];
        let cur = [];
        for (let i = 0; i < pts.length; i++) {
            if (pts[i]) {
                cur.push(pts[i]);
            } else if (cur.length) {
                runs.push(cur);
                cur = [];
            }
        }
        if (cur.length)
            runs.push(cur);
        return runs;
    }
    // Catmull-Rom control points for the segment p1 -> p2, with the control
    // ys clamped to the segment's own range so the curve never leaves the
    // band between two neighbouring values.
    function _controls(p0, p1, p2, p3) {
        const lo = Math.min(p1.y, p2.y), hi = Math.max(p1.y, p2.y);
        const c1x = p1.x + (p2.x - p0.x) / 6, c1y = Math.max(lo, Math.min(hi, p1.y + (p2.y - p0.y) / 6));
        const c2x = p2.x - (p3.x - p1.x) / 6, c2y = Math.max(lo, Math.min(hi, p2.y - (p3.y - p1.y) / 6));
        return [c1x, c1y, c2x, c2y];
    }
    // One run as an SVG path: "M x y C ..." (or a dot-length segment for a
    // single point, so a lone value still shows as a cap).
    // `curve` "linear" joins the points straight; "step" holds each value
    // until the next (across, then up or down; walked backwards -- a band's
    // low side -- the same corners in reverse).
    function _runPath(run, reverse, curve) {
        const r = reverse ? run.slice().reverse() : run;
        if (r.length === 1)
            return "M " + root._f(r[0].x) + " " + root._f(r[0].y) + " L " + root._f(r[0].x + 0.01) + " " + root._f(r[0].y);
        let d = "M " + root._f(r[0].x) + " " + root._f(r[0].y);
        if (curve === "linear" || curve === "step") {
            for (let k = 0; k + 1 < r.length; k++) {
                const p1 = r[k], p2 = r[k + 1];
                if (curve === "step")
                    d += reverse ? " L " + root._f(p1.x) + " " + root._f(p2.y)
                                 : " L " + root._f(p2.x) + " " + root._f(p1.y);
                d += " L " + root._f(p2.x) + " " + root._f(p2.y);
            }
            return d;
        }
        for (let k = 0; k + 1 < r.length; k++) {
            const p0 = r[Math.max(0, k - 1)], p1 = r[k], p2 = r[k + 1], p3 = r[Math.min(r.length - 1, k + 2)];
            const c = root._controls(p0, p1, p2, p3);
            d += " C " + root._f(c[0]) + " " + root._f(c[1]) + " " + root._f(c[2]) + " " + root._f(c[3])
               + " " + root._f(p2.x) + " " + root._f(p2.y);
        }
        return d;
    }
    function _lineOfRuns(runs, curve) {
        let d = "";
        for (let k = 0; k < runs.length; k++)
            d += (d ? " " : "") + root._runPath(runs[k], false, curve);
        return d;
    }
    // The area under each run, down to `base`.
    function _areaOfRuns(runs, base, curve) {
        let d = "";
        for (let k = 0; k < runs.length; k++) {
            const r = runs[k];
            if (r.length < 2)
                continue;
            d += (d ? " " : "") + root._runPath(r, false, curve)
               + " L " + root._f(r[r.length - 1].x) + " " + root._f(base)
               + " L " + root._f(r[0].x) + " " + root._f(base) + " Z";
        }
        return d;
    }
    // A band per run: forward along the high side (y), back along the low (y2).
    function _bandOfRuns(runs, curve) {
        let d = "";
        for (let k = 0; k < runs.length; k++) {
            const r = runs[k];
            if (r.length < 2)
                continue;
            d += (d ? " " : "") + root._runPath(r.map(p => ({ x: p.x, y: p.y })), false, curve)
               + " L " + root._runPath(r.map(p => ({ x: p.x, y: p.y2 })), true, curve).substring(2) + " Z";
        }
        return d;
    }
    // The gradient stroke: each run's curve sampled densely, offset half a
    // width to each side along the normal, closed into one polygon per run.
    // A straight curve ("linear", "step") is offset at its corners with a
    // mitre, so the stroke keeps its width round a step's right angle.
    function _offsetOfRuns(runs, w, curve) {
        const half = w / 2;
        let d = "";
        for (let k = 0; k < runs.length; k++) {
            const r = runs[k];
            const dense = [];
            let mitred = false;
            if (r.length === 1) {
                dense.push({ x: r[0].x - 0.5, y: r[0].y }, { x: r[0].x + 0.5, y: r[0].y });
            } else if (curve === "linear" || curve === "step") {
                mitred = true;
                const put = p => {
                    const q = dense.length ? dense[dense.length - 1] : null;
                    if (!q || Math.abs(q.x - p.x) > 1e-6 || Math.abs(q.y - p.y) > 1e-6)
                        dense.push(p);
                };
                for (let s = 0; s < r.length; s++) {
                    if (curve === "step" && s > 0)
                        put({ x: r[s].x, y: r[s - 1].y });
                    put(r[s]);
                }
                if (dense.length === 1) {
                    mitred = false;
                    dense.push({ x: dense[0].x + 0.5, y: dense[0].y });
                    dense[0] = { x: dense[0].x - 0.5, y: dense[0].y };
                }
            } else {
                for (let s = 0; s + 1 < r.length; s++) {
                    const p0 = r[Math.max(0, s - 1)], p1 = r[s], p2 = r[s + 1], p3 = r[Math.min(r.length - 1, s + 2)];
                    const c = root._controls(p0, p1, p2, p3);
                    const steps = 6;
                    for (let t = 0; t < steps; t++) {
                        const u = t / steps, mu = 1 - u;
                        dense.push({
                            x: mu * mu * mu * p1.x + 3 * mu * mu * u * c[0] + 3 * mu * u * u * c[2] + u * u * u * p2.x,
                            y: mu * mu * mu * p1.y + 3 * mu * mu * u * c[1] + 3 * mu * u * u * c[3] + u * u * u * p2.y
                        });
                    }
                }
                dense.push(r[r.length - 1]);
            }
            const left = [], right = [];
            const unitN = (a, b) => {
                const nx = -(b.y - a.y), ny = b.x - a.x;
                const len = Math.hypot(nx, ny) || 1;
                return { x: nx / len, y: ny / len };
            };
            for (let i = 0; i < dense.length; i++) {
                let nx, ny;
                if (mitred) {
                    const n1 = unitN(dense[Math.max(0, i - 1)], dense[Math.max(1, i)]);
                    const n2 = unitN(dense[Math.min(dense.length - 2, i)], dense[Math.min(dense.length - 1, i + 1)]);
                    let mx = n1.x + n2.x, my = n1.y + n2.y;
                    const ml = Math.hypot(mx, my);
                    if (ml < 1e-6) {
                        mx = n1.x; my = n1.y;
                    } else {
                        mx /= ml; my /= ml;
                    }
                    const k = half / Math.max(0.25, mx * n1.x + my * n1.y);
                    nx = mx * k; ny = my * k;
                } else {
                    const a = dense[Math.max(0, i - 1)], b = dense[Math.min(dense.length - 1, i + 1)];
                    nx = -(b.y - a.y); ny = b.x - a.x;
                    const len = Math.hypot(nx, ny) || 1;
                    nx = nx / len * half; ny = ny / len * half;
                }
                left.push({ x: dense[i].x + nx, y: dense[i].y + ny });
                right.push({ x: dense[i].x - nx, y: dense[i].y - ny });
            }
            let p = "M " + root._f(left[0].x) + " " + root._f(left[0].y);
            for (let i = 1; i < left.length; i++)
                p += " L " + root._f(left[i].x) + " " + root._f(left[i].y);
            for (let i = right.length - 1; i >= 0; i--)
                p += " L " + root._f(right[i].x) + " " + root._f(right[i].y);
            d += (d ? " " : "") + p + " Z";
        }
        return d;
    }
    // The stroke path of a series on the static mapping: every run, gaps as
    // moves (probes hold the drawing to it; `drawnPathOf` is what is drawn).
    function linePath(sid) {
        return sid < 0 ? "" : root._lineOfRuns(root._runs(root.pointsOf(sid)), root._curveOf(root.series[sid]));
    }
    // The path the frame DRAWS for series `sid` (its index in the drawn list,
    // which at rest is `series`' own order): the area for the gradient line,
    // the band for a band, the stroke otherwise; "" when it is not drawn.
    function drawnPathOf(sid) {
        const F = root._frame, sl = F.slots;
        if (sid < 0)
            return "";
        if (sl.grad === sid)
            return F.paths.gradArea;
        for (const name of ["band0", "band1", "line0", "line1", "line2", "line3", "line4"]) {
            if (sl[name] === sid)
                return F.paths[name];
        }
        return "";
    }

    // Direction arrows along the top baseline: value = degrees the arrow
    // POINTS (0 up, 90 right), one per `_arrowEvery` slots; an arrow's length
    // is its presence (2w - 1: a leaving one is gone in the first half of a
    // morph, an arriving one grows in the second).
    readonly property int _arrowEvery: root.slotW > 0 ? Math.max(1, Math.ceil(12 / root.slotW)) : 1
    // The arrows' centre line: an upright arrow's tip on the padding line.
    readonly property real _arrowLen: Math.min(10, root.arrowBand - 4)
    readonly property real _arrowY: root.padding + root._arrowLen / 2
    function _arrowsOf(F, s) {
        const full = root._arrowLen;
        const head = Math.min(3.5, full * 0.4);
        const cy = root._arrowY;
        const ars = s.arrows || [];
        let d = "";
        for (let i = 0; i < ars.length; i += root._arrowEvery) {
            const ar = ars[i];
            if (!ar)
                continue;
            const k = Math.max(0, Math.min(1, 2 * ar.w - 1));
            const L = full * k, h = head * k;
            if (L < 0.5)
                continue;
            const a = ar.deg * Math.PI / 180;
            const dx = Math.sin(a), dy = -Math.cos(a);
            const cx = root._fxAt(F, i);
            const tx = cx + dx * L / 2, ty = cy + dy * L / 2;
            const bx = cx - dx * L / 2, by = cy - dy * L / 2;
            const h1 = a + Math.PI * 5 / 6, h2 = a - Math.PI * 5 / 6;
            d += (d ? " " : "") + "M " + root._f(bx) + " " + root._f(by) + " L " + root._f(tx) + " " + root._f(ty)
               + " M " + root._f(tx) + " " + root._f(ty) + " L " + root._f(tx + Math.sin(h1) * h) + " " + root._f(ty - Math.cos(h1) * h)
               + " M " + root._f(tx) + " " + root._f(ty) + " L " + root._f(tx + Math.sin(h2) * h) + " " + root._f(ty - Math.cos(h2) * h);
        }
        return d;
    }

    function _alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a);
    }
    function _widthOf(sid) {
        const s = sid >= 0 ? root.series[sid] : null;
        return s && root._isNum(s.width) ? s.width : root.lineWidth;
    }
    // A colour read from a property is a REFERENCE to that property in Qt 6:
    // kept in a frame, it re-reads the property, so the snapshot a morph starts
    // from takes the NEW colour the moment the host changes it, and a colour
    // morph (morphBarStyle: a total turning into one app's hue) would snap at
    // its first frame. The frame holds a copy.
    function _captured(c) {
        return c && typeof c !== "string" && c.r !== undefined ? Qt.rgba(c.r, c.g, c.b, c.a) : c;
    }
    function _mixColor(a, b, e) {
        if (!a)
            return b;
        if (!b)
            return a;
        return Qt.rgba(a.r + (b.r - a.r) * e, a.g + (b.g - a.g) * e, a.b + (b.b - a.b) * e, a.a + (b.a - a.a) * e);
    }

    // The gradient's stops, sorted by value descending (top first).
    readonly property var _gradSorted: {
        const st = (root.gradientStops || []).filter(s => s && root._isNum(s.value));
        st.sort((a, b) => b.value - a.value);
        return st;
    }

    // =========================================================================
    // THE FRAME (see THE MORPH in the header)
    // =========================================================================
    // How long a morph takes, and how far past the plot's edge something the
    // moving axis carries out of the plot fades (the soft edge; hard at rest).
    property int morphMs: 260
    property real edgeFadePx: 8

    // WHERE A FRAME PUTS THINGS. x: a slot position s (fractional while a
    // point travels) through the frame's own plot. y: a NORMALIZED height n
    // (0 the plot's foot, 1 its top), which is what a morph interpolates: a
    // point moves in a straight line between where it is drawn on each side,
    // and so does a grid line, so a line that sits on a grid value on both
    // days stays on it (the drawn axis is the same mix of the two:
    // n(v) = mix(a) v + mix(b), still linear). At rest n is the axis mapping
    // itself, and these are xFor / yFor exactly.
    function _fx(F, s) {
        return (F.sx0 !== undefined ? F.sx0 : F.px0) + (s + 0.5) * F.slotW;
    }
    // Where the thing an INDEX names stands (a bar, a mark, an arrow): its slot
    // centre, or in a resampled frame its place on the plot (`places`, the
    // merged list it was put on -- uneven, so index k is not at k + 0.5).
    function _fxAt(F, i) {
        return F.places && i >= 0 && i < F.places.length ? (F.sx0 !== undefined ? F.sx0 : F.px0) + F.places[i] * F.n * F.slotW
                                                         : root._fx(F, i);
    }
    function _fyN(F, n) {
        return F.py1 - n * (F.py1 - F.py0);
    }
    // Where a value one side does not show stands on that side: on its
    // shared axis (its linear map), held just outside the plot. A tick that
    // only the new day has slides in from past the edge it enters by, never
    // from where a very different axis would put it (a day with no data
    // keeps a 0..1 silhouette: 40 on it is 40 plots up).
    function _nOf(F, v) {
        return Math.max(-0.15, Math.min(1.15, F.ma * v + F.mb));
    }
    function _anyPt(list) {
        if (!list)
            return false;
        for (let i = 0; i < list.length; i++) {
            if (list[i])
                return true;
        }
        return false;
    }

    // ---- The picture of the current inputs ---------------------------------------
    // The axis an EMPTY target shows as its grid silhouette: the last
    // non-empty target's, kept by morph() and dropped by jump(), so a day
    // without data keeps the grid it came from and the next day's axis moves
    // from there.
    property var _heldAxis: null
    function _build() {
        const a = root._axis;
        const empty = root._empty;
        const skel = root.skeleton && !empty;
        const held = (empty || skel) && root._heldAxis ? root._heldAxis
                   : (skel ? { lo: 0, hi: 1, ticks: [0, 0.25, 0.5, 0.75, 1], yLabelW: 0 } : null);
        const lo = held ? held.lo : a.lo, hi = held ? held.hi : a.hi;
        // A skeleton keeps the label column the held axis had (blank), so the
        // plot stands where it stood.
        const hw = skel && held.yLabelW !== undefined ? held.yLabelW : root._yLabelW;
        const px0 = skel ? root.padding + (hw > 0 ? hw + 6 : 0) : root.px0;
        const py0 = skel ? root._labelRoom + root.padding + (root._hasArrows ? root.arrowBand : 0)
                           + (hw > 0 ? Math.ceil(root._lineH / 2) - root._labelInk.top : 0)
                         : root.py0;
        const tv = held ? held.ticks : root._tickValues;
        const labels = root._tickLabels;
        const n = root._n;
        // (v - lo) / (hi - lo), written as yFor writes it.
        const nv = v => (v - lo) / (hi - lo);
        const span = root.spanEnds && n > 1;
        const slotW = skel ? (n > 0 ? (root.px1 - px0) / (span ? n - 1 : n) : 0) : root.slotW;
        const sx0 = skel ? (span ? px0 - slotW / 2 : px0) : root._sx0;
        const F = {
            empty: empty, n: n,
            px0: px0, px1: root.px1, py0: py0, py1: root.py1,
            slotW: slotW, sx0: sx0,
            yLabelW: hw, lo: lo, hi: hi, ma: 1 / (hi - lo), mb: -lo / (hi - lo),
            ticks: [], series: [], th: [], stops: [],
            now: { s: root.nowIndex, w: root.nowIndex >= 0 && root.nowIndex < n ? 1 : 0 },
            emptyText: root.emptyText,
            textW: empty && root.emptyText.length > 0 ? 1 : 0
        };
        for (let k = 0; k < tv.length; k++) {
            const text = held ? "" : (labels[k] !== undefined ? labels[k] : "");
            F.ticks.push({ v: tv[k], n: nv(tv[k]), text: text, w: 1, lw: text !== "" ? 1 : 0, base: Math.abs(tv[k] - lo) < 1e-9 ? 1 : 0 });
        }
        for (let k = 0; k < root.series.length; k++) {
            const s = root.series[k] || {};
            const rg = s.range && s.range.length === 2 && root._isNum(s.range[0]) && root._isNum(s.range[1])
                       && s.range[1] !== s.range[0] ? [s.range[0], s.range[1]] : null;
            // A series with its own range is mapped on it (a probability
            // beside millimetres); the rest on the shared axis.
            const ns = rg ? (v => (v - rg[0]) / (rg[1] - rg[0])) : nv;
            const o = {
                id: s.id !== undefined ? String(s.id) : "#" + k, kind: String(s.kind || ""),
                color: root._captured(s.color !== undefined ? s.color : (s.kind === "arrows" ? root.textColor : root.markerColor)),
                width: root._widthOf(k),
                dotted: !!s.dotted, gradient: s.gradient === true, w: 0,
                dash: Array.isArray(s.dash) && s.dash.length >= 2 ? s.dash : null,
                group: s.group !== undefined ? String(s.group) : "",
                curve: root._curveOf(s), alpha: root._isNum(s.alpha) ? s.alpha : NaN,
                ownColor: s.color !== undefined,
                pts: null, bars: null, arrows: null, marks: null
            };
            const vs = s.values || [];
            let any = false;
            if (o.kind === "line" || o.kind === "band") {
                const lows = o.kind === "band" ? (s.bandLow || []) : null;
                const pts = [];
                for (let i = 0; i < vs.length; i++) {
                    const v = vs[i], v2 = lows ? lows[i] : v;
                    const ok = root._isNum(v) && root._isNum(v2);
                    const h = ok ? ns(v) : 0, h2 = ok ? ns(v2) : 0;
                    pts.push(ok ? { ls: i, ln: h, ln2: h2, rs: i, rn: h, rn2: h2, split: false, link: false } : null);
                    any = any || ok;
                }
                for (let i = 0; i + 1 < pts.length; i++) {
                    if (pts[i] && pts[i + 1])
                        pts[i].link = true;
                }
                o.pts = pts;
            } else if (o.kind === "bars") {
                // A bar's top; its foot is the plot's. A series with its own
                // range stands on that range and is held inside it.
                const rlo = rg ? Math.min(rg[0], rg[1]) : 0, rhi = rg ? Math.max(rg[0], rg[1]) : 0;
                o.bars = vs.map(v => root._isNum(v) ? (rg ? ns(Math.max(rlo, Math.min(rhi, v))) : nv(Math.max(v, lo))) : null);
                any = o.bars.some(v => v !== null);
            } else if (o.kind === "arrows") {
                o.arrows = vs.map(v => root._isNum(v) ? { deg: v, w: 1 } : null);
                any = o.arrows.some(v => v !== null);
            } else if (o.kind === "marks") {
                const gl = s.glyphs || [];
                o.marks = vs.map((v, i) => root._isNum(v) ? { n: ns(v), g: gl[i] === "sell" ? "sell" : "buy", w: 1 } : null);
                any = o.marks.some(m => m !== null);
            }
            o.w = any ? 1 : 0;
            F.series.push(o);
        }
        // A threshold is present where its value is on the axis; outside it
        // it is not drawn at rest, and a morph fades it on that weight.
        const place = root._thresholdPlace;
        for (let k = 0; k < root.thresholds.length; k++) {
            const t = root.thresholds[k] || {};
            const v = root._isNum(t.value) ? t.value : NaN;
            const p = place[k] || "off";
            const on = isFinite(v) && v >= lo && v <= hi;
            F.th.push({
                v: v, n: isFinite(v) ? nv(v) : 0, text: t.label !== undefined ? String(t.label) : "",
                color: t.color !== undefined ? t.color : root.faintColor,
                w: on ? 1 : 0, wr: p === "right" ? 1 : 0, wl: p === "left" ? 1 : 0
            });
        }
        F.stops = root._gradSorted.map(s => ({ v: s.value, n: nv(s.value), c: s.color }));
        // The sparse x labels, placed by THIS frame: a morph takes them from
        // each side's own geometry (_lerpXTicks) instead of placing the new
        // range's slots on the old range's axis.
        F.xt = [];
        const xts = Array.isArray(root.xTicks) ? root.xTicks : [];
        for (let k = 0; k < xts.length && F.xt.length < root._xTickPool; k++) {
            const t = xts[k];
            if (t && root._isNum(t.i) && n > 0)
                F.xt.push({ x: sx0 + (t.i + 0.5) * slotW,
                            text: t.text !== undefined ? String(t.text) : "", w: 1 });
        }
        return root._finish(F);
    }

    // Pool slots, runs, paths and the gradient's geometry of a frame.
    function _finish(F) {
        const slots = { line0: -1, line1: -1, line2: -1, line3: -1, line4: -1, grad: -1, band0: -1, band1: -1, arrows: -1 };
        const bars = [];
        const marks = [];
        const hasStops = F.stops.length > 0;
        let nl = 0, nb = 0, gradSeen = false;
        for (let k = 0; k < F.series.length; k++) {
            const s = F.series[k];
            if (s.kind === "line") {
                // The first gradient line takes the gradient slot (or, with
                // no stops, the fifth plain one); a second is not drawn.
                if (s.gradient) {
                    if (!gradSeen) {
                        gradSeen = true;
                        if (hasStops)
                            slots.grad = k;
                        else
                            slots.line4 = k;
                    }
                } else if (nl < 4) {
                    slots["line" + nl] = k;
                    nl++;
                }
            } else if (s.kind === "band") {
                if (nb < 2) {
                    slots["band" + nb] = k;
                    nb++;
                }
            } else if (s.kind === "arrows") {
                if (slots.arrows < 0)
                    slots.arrows = k;
            } else if (s.kind === "bars") {
                bars.push(k);
            } else if (s.kind === "marks") {
                const ms = s.marks || [];
                for (let i = 0; i < ms.length && marks.length < root._markPool; i++) {
                    if (ms[i] && ms[i].w > 0.001)
                        marks.push({ sid: k, s: i, n: ms[i].n, g: ms[i].g, w: ms[i].w });
                }
            }
        }
        const runsOf = k => k >= 0 ? root._drawnRuns(F, F.series[k]) : [];
        const gr = runsOf(slots.grad);
        const cv = k => k >= 0 ? F.series[k].curve : "smooth";
        F.slots = slots;
        F.bars = bars;
        F.marks = marks;
        F.barW = Math.max(2, Math.floor((F.barSlotW > 0 ? F.barSlotW : F.slotW) * 0.62));
        F.paths = {
            band0: root._bandOfRuns(runsOf(slots.band0), cv(slots.band0)),
            band1: root._bandOfRuns(runsOf(slots.band1), cv(slots.band1)),
            gradArea: root._areaOfRuns(gr, F.py1, cv(slots.grad)),
            gradLine: slots.grad >= 0 ? root._offsetOfRuns(gr, F.series[slots.grad].width, cv(slots.grad)) : "",
            line0: root._lineOfRuns(runsOf(slots.line0), cv(slots.line0)),
            line1: root._lineOfRuns(runsOf(slots.line1), cv(slots.line1)),
            line2: root._lineOfRuns(runsOf(slots.line2), cv(slots.line2)),
            line3: root._lineOfRuns(runsOf(slots.line3), cv(slots.line3)),
            line4: root._lineOfRuns(runsOf(slots.line4), cv(slots.line4)),
            arrows: slots.arrows >= 0 ? root._arrowsOf(F, F.series[slots.arrows]) : "",
            bar0: root.barsAsPath && bars.length > 0 ? root._barsPath(F, F.series[bars[0]]) : "",
            bar1: root.barsAsPath && bars.length > 1 ? root._barsPath(F, F.series[bars[1]]) : ""
        };
        // The gradient: stop k's position is its y as a fraction of the run
        // from the highest stop's y to the lowest's. Eight declared stops;
        // past the list every stop repeats the last (position 1), which keeps
        // the list monotone (a Gradient ignores one that is not).
        const st = F.stops;
        const y1 = st.length ? root._fyN(F, st[0].n) : 0;
        const y2 = st.length ? root._fyN(F, st[st.length - 1].n) : 1;
        const pos = [], col = [];
        for (let k = 0; k < 8; k++) {
            if (!st.length) {
                pos.push(k === 0 ? 0 : 1);
                col.push(null);
                continue;
            }
            const span = y2 - y1;
            pos.push(k >= st.length ? 1 : (Math.abs(span) < 1e-6 ? (k === 0 ? 0 : 1)
                                                               : Math.max(0, Math.min(1, (root._fyN(F, st[k].n) - y1) / span))));
            col.push(st[Math.min(k, st.length - 1)].c);
        }
        F.grad = { y1: y1, y2: y2, pos: pos, col: col };
        return F;
    }

    // A series' drawn runs. Slot i's point has a LEFT copy (where the link
    // from slot i - 1 lands) and a RIGHT copy (where the link to i + 1
    // leaves); they differ only at a split, where a run ends on the left copy
    // and the next begins on the right one. Consecutive points closer than
    // 0.05 px are one: at the start of a morph every collapsed point sits on
    // its neighbour, and dropping them draws exactly the picture before.
    //
    // A RESAMPLED morph's frame (`F.thin`, px) also draws no point closer than
    // that across to the last one it kept, the run's own end excepted: points
    // a side does not have collapse onto a neighbour, and a hundred of them
    // squeezed into a few pixels make the line's outline fold over itself at
    // every one -- 53 ms of curve-renderer polish a frame.
    // A pixel of detail inside a moving line is not seen; at rest (and in
    // every frame the chart builds itself) nothing is thinned.
    function _drawnRuns(F, s) {
        const pts = s.pts || [];
        const runs = [];
        let cur = null;
        const thin = F.thin > 0 ? F.thin : 0;
        let held = null;
        const add = function (sp, h, h2) {
            const x = root._fx(F, sp), y = root._fyN(F, h), y2 = root._fyN(F, h2);
            if (cur.length) {
                const q = cur[cur.length - 1];
                if (Math.abs(q.x - x) < 0.05 && Math.abs(q.y - y) < 0.05 && Math.abs(q.y2 - y2) < 0.05)
                    return;
                if (thin > 0 && Math.abs(q.x - x) < thin) {
                    held = { x: x, y: y, y2: y2 };
                    return;
                }
            }
            held = null;
            cur.push({ x: x, y: y, y2: y2 });
        };
        const endRun = function () {
            if (held && cur) {
                cur.push(held);
                held = null;
            }
            if (cur && cur.length)
                runs.push(cur);
        };
        for (let i = 0; i < pts.length; i++) {
            const p = pts[i];
            if (!p) {
                endRun();
                cur = null;
                continue;
            }
            const linkedIn = i > 0 && pts[i - 1] && pts[i - 1].link;
            if (!linkedIn || !cur) {
                endRun();
                cur = [];
            }
            add(p.ls, p.ln, p.ln2);
            if (p.split) {
                endRun();
                cur = [];
                add(p.rs, p.rn, p.rn2);
            }
            if (!p.link) {
                endRun();
                cur = null;
            }
        }
        endRun();
        return runs;
    }

    // ---- The drawn picture between two frames --------------------------------------
    // One bar series as rectangles from the plot's foot, at the frame's own
    // bar width (the pool's geometry, without its rounded corners).
    function _barsPath(F, s) {
        const vs = s && s.bars ? s.bars : [];
        const w = F.barW, base = F.py1;
        let d = "";
        for (let i = 0; i < vs.length; i++) {
            const v = vs[i];
            if (v === null || v === undefined)
                continue;
            const top = root._fyN(F, v);
            const y0 = Math.min(top, base), y1 = Math.max(top, base);
            if (y1 - y0 < 0.01)
                continue;
            const x0 = Math.round(root._fxAt(F, i) - w / 2);
            d += "M" + x0 + "," + y0 + "H" + (x0 + w) + "V" + y1 + "H" + x0 + "Z";
        }
        return d;
    }

    // ---- Resampling (morphResample) ------------------------------------------------
    // Two frames with different slot counts, re-expressed on ONE list of
    // positions: the merge of both frames' own point positions, each a fraction
    // u of the plot's width (a point at slot s of n stands at (s + 0.5) / n).
    // Index k of both results is the same place on the plot, so the existing
    // index lerp moves every point straight up or down, and each side's line
    // passes through all of its own points: at e = 0 the picture is A, at 1 it
    // is B. A place outside one side's runs is null on that side and the
    // collapse rule takes it (the line grows from / sinks into its end). Bars,
    // marks and arrows go to their own position (it is in the list). Kept for
    // the pair it was made for: a frame's lerp runs on every tick.
    property var _rsMemo: ({ a: null, b: null, r: null })
    function _resamplePair(A, B) {
        const m = root._rsMemo;
        if (m.a === A && m.b === B)
            return m.r;
        // The places: every drawn point's own (a frame caught mid-morph has
        // points between slots), and every place a bar, mark or arrow stands
        // on (_placeOf: in a resampled frame the place it was put on, NOT its
        // index's even slot centre -- read that way, a frame caught mid-morph
        // adds one false place per bar) -- nothing else. Each side's line keeps all of its corners, and the
        // paths carry no vertex that is not somebody's point: every vertex is
        // polish work for the curve renderer, which grows faster than the
        // count (a frame's uniform slot centres added here too would double
        // the count and double it again on every interrupted morph -- 51 ms of
        // polish a frame).
        const us = [];
        for (const F of [A, B]) {
            for (const sr of F.series) {
                for (const p of (sr.pts || [])) {
                    if (p)
                        us.push(((p.ls + p.rs) / 2 + 0.5) / F.n);
                }
                for (const list of [sr.bars, sr.marks, sr.arrows]) {
                    if (!list)
                        continue;
                    for (let i = 0; i < list.length; i++) {
                        if (list[i] !== null && list[i] !== undefined)
                            us.push(root._placeOf(F, i));
                    }
                }
            }
        }
        us.sort((x, y) => x - y);
        const U = [];
        for (const u of us) {
            if (!U.length || u - U[U.length - 1] > 1e-9)
                U.push(u);
        }
        if (!U.length)
            U.push(0.5);
        const r = [root._resampleOn(A, U), root._resampleOn(B, U)];
        m.a = A;
        m.b = B;
        m.r = r;
        return r;
    }
    // An index's place as a fraction of the plot (see _fxAt).
    function _placeOf(F, i) {
        return F.places && i >= 0 && i < F.places.length ? F.places[i] : (i + 0.5) / F.n;
    }
    function _resampleOn(F, U) {
        const K = U.length;
        const pos = u => u * K - 0.5;                      // a place in the new slot units
        const idx = s => {                                 // a source slot's own place in U
            const u = root._placeOf(F, s);
            let lo = 0, hi = K - 1;
            while (lo < hi) {
                const mid = (lo + hi) >> 1;
                if (U[mid] < u - 1e-9)
                    lo = mid + 1;
                else
                    hi = mid;
            }
            return lo;
        };
        const R = Object.assign({}, F);
        R.n = K;
        R.places = U;
        // The places are fractions of the frame's slot STRIP (n slots wide).
        R.slotW = K > 0 ? F.n * F.slotW / K : 0;
        R.now = { s: pos((F.now.s + 0.5) / F.n), w: F.now.w };
        R.series = F.series.map(sr => {
            const o = Object.assign({}, sr);
            if (sr.pts)
                o.pts = root._resamplePts(sr.pts, F.n, U, sr.curve);
            const place = list => {
                if (!list)
                    return list;
                const out = new Array(K).fill(null);
                for (let i = 0; i < list.length; i++) {
                    if (list[i] !== null && list[i] !== undefined)
                        out[idx(i)] = list[i];
                }
                return out;
            };
            o.bars = place(sr.bars);
            o.marks = place(sr.marks);
            o.arrows = place(sr.arrows);
            return o;
        });
        return R;
    }
    // A line's points on the places U: inside one of its runs the height on
    // its own drawn segment (a "step" holds the left point's), outside every
    // run nothing. A lone point sits on its own place.
    function _resamplePts(pts, n, U, curve) {
        const K = U.length;
        const out = new Array(K).fill(null);
        const runs = [];
        let cur = null;
        for (let i = 0; i < n; i++) {
            const p = pts[i];
            if (!p) {
                cur = null;
                continue;
            }
            const q = { u: ((p.ls + p.rs) / 2 + 0.5) / n, h: (p.ln + p.rn) / 2, h2: (p.ln2 + p.rn2) / 2 };
            if (!cur) {
                cur = [q];
                runs.push(cur);
            } else {
                cur.push(q);
            }
            if (!p.link)
                cur = null;
        }
        let k = 0;
        for (const run of runs) {
            const u0 = run[0].u, u1 = run[run.length - 1].u;
            while (k < K && U[k] < u0 - 1e-9)
                k++;
            let seg = 0, first = -1;
            while (k < K && U[k] <= u1 + 1e-9) {
                const u = U[k];
                while (seg + 1 < run.length - 1 && run[seg + 1].u <= u + 1e-12)
                    seg++;
                const a = run[seg], b = run[Math.min(seg + 1, run.length - 1)];
                let h, h2;
                if (Math.abs(u - b.u) <= 1e-9) {
                    h = b.h;
                    h2 = b.h2;
                } else if (curve === "step" || b.u - a.u <= 1e-12) {
                    h = a.h;
                    h2 = a.h2;
                } else {
                    const t = (u - a.u) / (b.u - a.u);
                    h = a.h + (b.h - a.h) * t;
                    h2 = a.h2 + (b.h2 - a.h2) * t;
                }
                const s = u * K - 0.5;
                out[k] = { ls: s, ln: h, ln2: h2, rs: s, rn: h, rn2: h2, split: false, link: false };
                if (first < 0)
                    first = k;
                else
                    out[k - 1].link = true;
                k++;
            }
        }
        return out;
    }

    function _lerpFrame(A, B, e) {
        if (!A || e >= 1)
            return B;
        if (e <= 0)
            return A;
        let barSlot = null;
        if (root.morphResample && A.n > 0 && B.n > 0 && A.n !== B.n) {
            const pair = root._resamplePair(A, B);
            barSlot = [A.barSlotW > 0 ? A.barSlotW : A.slotW, B.barSlotW > 0 ? B.barSlotW : B.slotW];
            A = pair[0];
            B = pair[1];
        }
        const L = (a, b) => a + (b - a) * e;
        const n = B.n > 0 ? B.n : A.n;
        const ma = L(A.ma, B.ma), mb = L(A.mb, B.mb);
        const F = {
            empty: B.empty, n: n,
            px0: L(A.px0, B.px0), px1: L(A.px1, B.px1), py0: L(A.py0, B.py0), py1: L(A.py1, B.py1),
            slotW: A.n > 0 && B.n > 0 ? L(A.slotW, B.slotW) : (B.n > 0 ? B.slotW : A.slotW),
            sx0: L(A.sx0 !== undefined ? A.sx0 : A.px0, B.sx0 !== undefined ? B.sx0 : B.px0),
            yLabelW: L(A.yLabelW, B.yLabelW),
            ma: ma, mb: mb, lo: -mb / ma, hi: (1 - mb) / ma,
            now: {
                s: A.now.w > 0 && B.now.w > 0 ? L(A.now.s, B.now.s) : (B.now.w > 0 ? B.now.s : A.now.s),
                w: L(A.now.w, B.now.w)
            },
            emptyText: B.textW > 0 ? B.emptyText : A.emptyText,
            textW: L(A.textW, B.textW),
            ticks: root._lerpTicks(A, B, e),
            xt: root._lerpXTicks(A, B, e),
            series: [], th: [], stops: [],
            barSlotW: barSlot ? L(barSlot[0], barSlot[1]) : 0,
            // A resampled pair's places (both sides share them): where an
            // index's bar or mark stands, and what the next resample of this
            // frame (a morph caught mid-way) takes its places from -- read as
            // even slot centres they would be a second set of places, one per bar.
            places: barSlot ? B.places : null,
            // A resampled morph's frame draws no two points within a pixel of
            // each other across (see _drawnRuns).
            thin: barSlot ? 1 : 0
        };
        // Series by id: the target's in its order, then the ones leaving.
        // A part of a grouped line takes its missing side from the group (see
        // _borrow); the part that carries the gradient keeps its own.
        const aById = {};
        for (const s of A.series)
            aById[s.id] = s;
        const kept = {};
        const lend = (own, F2, want) => own && own.group && !own.gradient && own.pts && want
                                        ? root._borrow(own.pts, F2, own.group, want, n) : (own ? own.pts : null);
        for (const b of B.series) {
            let a = aById[b.id] && aById[b.id].kind === b.kind ? aById[b.id] : null;
            if (a)
                kept[b.id] = true;
            let bb = b;
            if (b.group && !b.gradient && b.pts) {
                const ap = root._borrow(a ? a.pts : null, A, b.group, b.pts, n);
                if (root._anyPt(ap))
                    a = Object.assign({}, a || b, { pts: ap, w: a ? a.w : 0 });
                if (a && a.pts)
                    bb = Object.assign({}, b, { pts: lend(b, B, a.pts) });
            }
            F.series.push(root._lerpSeries(a, bb, e, n));
        }
        for (const a of A.series) {
            if (kept[a.id] || !(a.w * (1 - e) > 0.001))
                continue;
            if (a.group && !a.gradient && a.pts) {
                const bp = root._borrow(null, B, a.group, a.pts, n);
                if (root._anyPt(bp)) {
                    F.series.push(root._lerpSeries(a, Object.assign({}, a, { pts: bp, w: 0 }), e, n));
                    continue;
                }
            }
            F.series.push(root._lerpSeries(a, null, e, n));
        }
        // Thresholds by index (a scale's k-th boundary on both sides); one
        // side only is placed where its value is on the other side's axis.
        const tn = Math.max(A.th.length, B.th.length);
        for (let k = 0; k < tn; k++) {
            const a = A.th[k] || null, b = B.th[k] || null;
            const av = !!a && isFinite(a.v), bv = !!b && isFinite(b.v);
            const na = av ? a.n : (bv ? root._nOf(A, b.v) : 0);
            const nb = bv ? b.n : (av ? root._nOf(B, a.v) : 0);
            F.th.push({
                v: bv ? b.v : (av ? a.v : NaN), n: L(na, nb),
                text: b && b.text !== "" ? b.text : (a ? a.text : ""),
                color: b ? b.color : a.color,
                w: L(a ? a.w : 0, b ? b.w : 0), wr: L(a ? a.wr : 0, b ? b.wr : 0), wl: L(a ? a.wl : 0, b ? b.wl : 0)
            });
        }
        // Gradient stops by index; both lists run high to low, and padding the
        // shorter with its last keeps the mix in order.
        const sn = Math.max(A.stops.length, B.stops.length);
        for (let k = 0; k < sn; k++) {
            const a = A.stops.length ? A.stops[Math.min(k, A.stops.length - 1)] : null;
            const b = B.stops.length ? B.stops[Math.min(k, B.stops.length - 1)] : null;
            F.stops.push(a && b ? { v: b.v, n: L(a.n, b.n), c: root._morphColor(a.c, b.c, e) } : (b || a));
        }
        return root._finish(F);
    }

    // Two colours on the morph's clock: mixed, or -- with `morphColorVia` and
    // two that differ -- out to it in the first half and in from it in the second.
    // A GROUPED LINE (series sharing `group`: one price line drawn in parts --
    // solid, a dashed join over empty slots, the extended hours) morphs as one
    // line. Where a part has no point but the other side draws one of its
    // points there, it takes the point of whichever part of its group this
    // frame draws at that slot: a gap that closes turns its dashed stretch into
    // the solid line's place, the extended hours grow out of the old line,
    // instead of rising from the floor or flying to another run of their own.
    // `own` first; slots `want` has no point at stay empty; joined wherever
    // two neighbours are both drawn (the group drew them joined).
    function _borrow(own, F, group, want, n) {
        const out = new Array(n).fill(null);
        for (let i = 0; i < n; i++) {
            let p = own && i < own.length ? own[i] : null;
            if (!p && want && i < want.length && want[i]) {
                for (const s of F.series) {
                    if (s.group === group && s.pts && i < s.pts.length && s.pts[i]) {
                        p = s.pts[i];
                        break;
                    }
                }
            }
            out[i] = p ? Object.assign({}, p) : null;
        }
        for (let i = 0; i < n; i++) {
            if (out[i])
                out[i].link = i + 1 < n && !!out[i + 1];
        }
        return out;
    }
    function _morphColor(a, b, e) {
        const via = root.morphColorVia;
        if (!a || !b || via.a <= 0 || Qt.colorEqual(a, b))
            return root._mixColor(a, b, e);
        return e < 0.5 ? root._mixColor(a, via, 2 * e) : root._mixColor(via, b, 2 * e - 1);
    }
    // The x labels: one on both sides (the same text within half a pixel)
    // stays and moves with the plot; the others by halves -- the old ones out
    // in the first half, where they stood, the new ones in during the second,
    // where they will stand -- so two labels never cross in one place.
    function _lerpXTicks(A, B, e) {
        const At = A.xt || [], Bt = B.xt || [];
        const out = [];
        const used = Bt.map(() => false);
        for (const a of At) {
            let j = -1;
            for (let q = 0; q < Bt.length; q++) {
                if (!used[q] && Bt[q].text === a.text && Math.abs(Bt[q].x - a.x) < 0.5) {
                    j = q;
                    break;
                }
            }
            if (j >= 0) {
                used[j] = true;
                out.push({ x: a.x + (Bt[j].x - a.x) * e, text: a.text, w: a.w + (Bt[j].w - a.w) * e });
            } else if (e < 0.5) {
                out.push({ x: a.x, text: a.text, w: a.w * (1 - 2 * e) });
            }
        }
        for (let q = 0; q < Bt.length; q++) {
            if (!used[q] && e > 0.5)
                out.push({ x: Bt[q].x, text: Bt[q].text, w: Bt[q].w * (2 * e - 1) });
        }
        return out;
    }

    // Ticks matched by value. One side only is placed where its value is on
    // the other side's axis, so it travels with the grid while it fades. A
    // figure's text is the target's (at once); its presence and its label's
    // move on the clock.
    readonly property int _tickPool: 16
    function _lerpTicks(A, B, e) {
        const L = (a, b) => a + (b - a) * e;
        const At = A.ticks, Bt = B.ticks;
        const same = (x, y) => Math.abs(x - y) <= 1e-9 * Math.max(1, Math.abs(x), Math.abs(y));
        const used = Bt.map(() => false);
        const out = [];
        for (const a of At) {
            let j = -1;
            for (let q = 0; q < Bt.length; q++) {
                if (!used[q] && same(a.v, Bt[q].v)) {
                    j = q;
                    break;
                }
            }
            const b = j >= 0 ? Bt[j] : null;
            if (b)
                used[j] = true;
            const w = L(a.w, b ? b.w : 0);
            if (!b && w <= 0.001)
                continue;
            out.push({ v: a.v, n: L(a.n, b ? b.n : root._nOf(B, a.v)), text: b && b.text !== "" ? b.text : a.text,
                       w: w, lw: L(a.lw, b ? b.lw : 0), base: b ? L(a.base, b.base) : a.base });
        }
        for (let q = 0; q < Bt.length; q++) {
            if (!used[q]) {
                const b = Bt[q];
                out.push({ v: b.v, n: L(root._nOf(A, b.v), b.n), text: b.text, w: e * b.w, lw: e * b.lw, base: b.base });
            }
        }
        if (out.length > root._tickPool) {
            out.sort((p, q) => q.w - p.w);
            out.length = root._tickPool;
        }
        out.sort((p, q) => p.v - q.v);
        return out;
    }

    function _lerpSeries(a, b, e, n) {
        const src = b || a;
        const o = {
            id: src.id, kind: src.kind, color: src.color, width: src.width, dotted: src.dotted,
            dash: src.dash, group: src.group,
            gradient: src.gradient, curve: src.curve, alpha: src.alpha, ownColor: src.ownColor,
            w: (a ? a.w : 0) * (1 - e) + (b ? b.w : 0) * e,
            pts: null, bars: null, arrows: null, marks: null
        };
        if (root.morphBarStyle && o.kind === "bars" && a && b) {
            const aa = root._isNum(a.alpha) ? a.alpha : root.barAlpha;
            const ba = root._isNum(b.alpha) ? b.alpha : root.barAlpha;
            o.color = root._morphColor(a.color, b.color, e);
            o.alpha = aa + (ba - aa) * e;
        }
        if (o.kind === "line" || o.kind === "band")
            o.pts = root._lerpPts(a ? a.pts : null, b ? b.pts : null, e, n);
        else if (o.kind === "bars")
            o.bars = root._lerpBars(a ? a.bars : null, b ? b.bars : null, e, n);
        else if (o.kind === "arrows")
            o.arrows = root._lerpArrows(a ? a.arrows : null, b ? b.arrows : null, e, n);
        else if (o.kind === "marks")
            o.marks = root._lerpMarks(a ? a.marks : null, b ? b.marks : null, e, n);
        return o;
    }

    // A mark on both sides moves with its value; one side only fades in place.
    function _lerpMarks(am, bm, e, n) {
        const out = [];
        for (let i = 0; i < n; i++) {
            const a = am && i < am.length ? am[i] : null, b = bm && i < bm.length ? bm[i] : null;
            if (a && b)
                out.push({ n: a.n + (b.n - a.n) * e, g: b.g, w: a.w + (b.w - a.w) * e });
            else if (a)
                out.push(a.w * (1 - e) > 0.001 ? { n: a.n, g: a.g, w: a.w * (1 - e) } : null);
            else if (b)
                out.push({ n: b.n, g: b.g, w: b.w * e });
            else
                out.push(null);
        }
        return out;
    }

    // Per slot, from the drawn point to the target's (see _drawnRuns for the
    // two copies). A slot on one side only collapses onto the nearest point
    // the other side has, on its side of the gap it is in; a gap with points
    // on both sides splits at its middle slot, whose left copy goes to (comes
    // from) the left neighbour and right copy to the right one. A series with
    // no point at all on one side rises from / sinks to the plot's foot.
    function _lerpPts(ap, bp, e, n) {
        const L = (x, y) => x + (y - x) * e;
        const aOn = root._anyPt(ap), bOn = root._anyPt(bp);
        const out = new Array(n).fill(null);
        if (!aOn && !bOn)
            return out;
        const P = (list, i) => list && i < list.length ? list[i] : null;
        if (!aOn || !bOn) {
            const src = aOn ? ap : bp;
            const k = aOn ? 1 - e : e;
            for (let i = 0; i < n; i++) {
                const p = P(src, i);
                if (p)
                    out[i] = { ls: p.ls, ln: p.ln * k, ln2: p.ln2 * k, rs: p.rs, rn: p.rn * k, rn2: p.rn2 * k,
                               split: aOn && p.split, link: p.link };
            }
            return out;
        }
        // The nearest point on each side, per slot, for both frames.
        const near = function (list) {
            const prev = new Array(n).fill(-1), next = new Array(n).fill(-1);
            let last = -1;
            for (let i = 0; i < n; i++) {
                prev[i] = last;
                if (P(list, i))
                    last = i;
            }
            last = -1;
            for (let i = n - 1; i >= 0; i--) {
                next[i] = last;
                if (P(list, i))
                    last = i;
            }
            return { prev: prev, next: next };
        };
        const na = near(ap), nb = near(bp);
        const leftOf = p => ({ s: p.ls, n: p.ln, n2: p.ln2 });
        const rightOf = p => ({ s: p.rs, n: p.rn, n2: p.rn2 });
        // (A built frame's point i stands at slot i; a resampled one where it is.)
        const atB = i => ({ s: bp[i].ls, n: bp[i].ln, n2: bp[i].ln2 });
        for (let i = 0; i < n; i++) {
            const pa = P(ap, i), pb = P(bp, i);
            if (!pa && !pb)
                continue;
            if (pa && pb) {
                out[i] = { ls: L(pa.ls, pb.ls), ln: L(pa.ln, pb.ln), ln2: L(pa.ln2, pb.ln2),
                           rs: L(pa.rs, pb.rs), rn: L(pa.rn, pb.rn), rn2: L(pa.rn2, pb.rn2), split: pa.split, link: false };
                continue;
            }
            // From (entering) or to (leaving) the neighbours on the other side.
            const nn = pb ? na : nb;
            const g0 = nn.prev[i], g1 = nn.next[i];
            let lft, rgt, split = false;
            if (pb) {
                if (g0 < 0) {
                    lft = rgt = leftOf(ap[g1]);
                } else if (g1 < 0) {
                    lft = rgt = rightOf(ap[g0]);
                } else {
                    const m = Math.floor((g0 + g1) / 2);
                    lft = i <= m ? rightOf(ap[g0]) : leftOf(ap[g1]);
                    rgt = i < m ? rightOf(ap[g0]) : leftOf(ap[g1]);
                    split = i === m;
                }
                out[i] = { ls: L(lft.s, pb.ls), ln: L(lft.n, pb.ln), ln2: L(lft.n2, pb.ln2),
                           rs: L(rgt.s, pb.rs), rn: L(rgt.n, pb.rn), rn2: L(rgt.n2, pb.rn2), split: split, link: false };
            } else {
                if (g0 < 0) {
                    lft = rgt = atB(g1);
                } else if (g1 < 0) {
                    lft = rgt = atB(g0);
                } else {
                    const m = Math.floor((g0 + g1) / 2);
                    lft = i <= m ? atB(g0) : atB(g1);
                    rgt = i < m ? atB(g0) : atB(g1);
                    split = i === m;
                }
                out[i] = { ls: L(pa.ls, lft.s), ln: L(pa.ln, lft.n), ln2: L(pa.ln2, lft.n2),
                           rs: L(pa.rs, rgt.s), rn: L(pa.rn, rgt.n), rn2: L(pa.rn2, rgt.n2), split: split || pa.split, link: false };
            }
        }
        // A pair is joined while either side joins it: a join only one side
        // has is zero-length on the other (its points collapse onto one).
        for (let i = 0; i + 1 < n; i++) {
            if (!out[i] || !out[i + 1])
                continue;
            const ja = !!(P(ap, i) && P(ap, i + 1) && ap[i].link);
            const jb = !!(P(bp, i) && P(bp, i + 1) && bp[i].link);
            out[i].link = ja || jb;
        }
        return out;
    }

    // A bar missing on one side stands at the plot's foot (height 0).
    function _lerpBars(ab, bb, e, n) {
        const out = [];
        for (let i = 0; i < n; i++) {
            const a = ab && i < ab.length ? ab[i] : null, b = bb && i < bb.length ? bb[i] : null;
            if (a === null && b === null) {
                out.push(null);
                continue;
            }
            const na = a !== null ? a : 0, nb = b !== null ? b : 0;
            out.push(na + (nb - na) * e);
        }
        return out;
    }

    // The shorter way round; one side only: grows from / shrinks to its centre.
    function _lerpArrows(aa, ba, e, n) {
        const out = [];
        for (let i = 0; i < n; i++) {
            const a = aa && i < aa.length ? aa[i] : null, b = ba && i < ba.length ? ba[i] : null;
            if (a && b) {
                const d = ((((b.deg - a.deg) % 360) + 540) % 360) - 180;
                out.push({ deg: a.deg + d * e, w: a.w + (b.w - a.w) * e });
            } else if (a) {
                const w = a.w * (1 - e);
                out.push(w > 0.001 ? { deg: a.deg, w: w } : null);
            } else if (b) {
                out.push({ deg: b.deg, w: b.w * e });
            } else {
                out.push(null);
            }
        }
        return out;
    }

    // ---- The clock -------------------------------------------------------------------
    property bool _batching: false
    property var _held: null
    property var _from: null
    property bool _morphing: false
    property int _morphSerial: 0
    readonly property var _target: root._batching && root._held ? root._held : root._build()
    readonly property real _e: morphClock.progress
    readonly property var _frame: root._morphing && root._from ? root._lerpFrame(root._from, root._target, root._e) : root._target
    // The morph's eased fraction, for a host that draws pictures of its own on
    // the chart's clock (screentime's heat cells and span bars move with the
    // bars, one clock per motion): 1 at rest.
    readonly property real morphProgress: root._morphing ? root._e : 1
    readonly property bool morphing: root._morphing
    ViewBlend {
        id: morphClock
        count: 2
        target: root._morphSerial % 2
        durationMs: root.morphMs
        onTicked: {
            if (root._morphing && morphClock.progress >= 1)
                root._morphing = false;
        }
    }

    // What is drawn moves from where it is to the picture after `fn` has
    // changed the inputs. The target is built once, after `fn`.
    function morph(fn) {
        const from = root._frame;
        root._markFrom = root._mk;
        const tgt = root._target;
        // Hold the target BEFORE writing anything it reads: `_heldAxis` is an
        // input of _build, and written first it would rebuild the target from
        // the old inputs -- and with it a whole in-between picture at the old
        // progress, for nothing.
        root._held = tgt;
        root._batching = true;
        if (tgt && !tgt.empty)
            root._heldAxis = { lo: tgt.lo, hi: tgt.hi, ticks: tgt.ticks.map(t => t.v), yLabelW: tgt.yLabelW };
        try {
            if (fn)
                fn();
        } finally {
            // The clock first: at 0 every picture the writes below cascade
            // into is the snapshot itself (_lerpFrame at e 0 is `from`).
            // Handed the snapshot first, a morph caught mid-way would build one
            // whole in-between picture against the OLD target at the old
            // progress and throw it away -- 9-13 ms of a swap's arrival frame
            // for a line in parts.
            root._morphSerial++;
            root._from = from;
            root._morphing = true;
            root._batching = false;
        }
    }
    // The picture after `fn`, at once: any morph stops, the held axis goes.
    function jump(fn) {
        morphClock.pin(1);
        root._morphing = false;
        root._held = root._target;
        root._batching = true;
        root._heldAxis = null;
        try {
            if (fn)
                fn();
        } finally {
            root._batching = false;
        }
    }
    // Harness stills: the current morph at linear time t.
    function pinMorph(t) {
        morphClock.pin(t);
    }

    // The marker's presence moves on the same clock (it exists on the key's
    // day only); a pointer moving it is instant.
    readonly property bool _markerOn: root.markerIndex >= 0 && root.markerIndex < root._n
    property var _markFrom: ({ i: -1, w: 0 })
    readonly property var _mk: {
        const on = root._markerOn;
        if (!root._morphing)
            return { i: on ? root.markerIndex : -1, w: on ? 1 : 0 };
        const f = root._markFrom;
        return { i: on ? root.markerIndex : f.i, w: f.w + ((on ? 1 : 0) - f.w) * root._e };
    }

    // How much of something at pixel y the plot shows: 1 inside, fading to 0
    // over `edgeFadePx` past its top or foot. At rest nothing present is
    // outside (ticks are the axis', a threshold off the axis weighs 0), so
    // this only acts on what a moving axis carries out of the plot or in.
    function _edgeOf(y) {
        const F = root._frame;
        const out = Math.max(F.py0 - y, y - F.py1);
        return out <= 0 ? 1 : Math.max(0, 1 - out / Math.max(0.001, root.edgeFadePx));
    }
    function _presence(w) {
        return Math.max(0, Math.min(1, 2 * w - 1));
    }
    function _slotSeries(name) {
        const F = root._frame;
        const k = F.slots[name];
        return k !== undefined && k >= 0 ? F.series[k] : null;
    }
    function _slotStroke(name, alpha) {
        const s = root._slotSeries(name);
        const own = s && s.kind === "line" && root._isNum(s.alpha) ? s.alpha : 1;
        return s ? root._alpha(s.color, alpha * own * root._presence(s.w)) : "transparent";
    }
    function _slotWidth(name) {
        const s = root._slotSeries(name);
        return s ? s.width : 0;
    }
    function _slotDashed(name) {
        const s = root._slotSeries(name);
        return !!(s && (s.dotted || s.dash));
    }
    function _slotDash(name) {
        const s = root._slotSeries(name);
        return s && s.dash ? s.dash : root._dotDash;
    }
    readonly property var _dotDash: [1, 2.5]
    // The gradient's colour at stop k, without alpha.
    function _gradBase(k) {
        const c = root._frame.grad.col[k];
        const s = root._slotSeries("grad");
        return c !== null && c !== undefined ? c : (s ? s.color : root.markerColor);
    }
    // The area's gradient. Without areaFade it is the line's own (value stops,
    // areaAlpha); with it, eight stops from the plot's top to its foot, each
    // the value gradient's colour at that height with the alpha falling.
    function _areaPos(k) {
        return root.areaFade > 0 ? k / 7 : root._frame.grad.pos[k];
    }
    function _areaColor(k) {
        if (!(root.areaFade > 0))
            return root._gradColor(k, root.areaAlpha);
        const F = root._frame, g = F.grad;
        const y = F.py0 + k / 7 * (F.py1 - F.py0);
        const span = g.y2 - g.y1;
        const t = Math.abs(span) < 1e-6 ? (y < g.y1 ? 0 : 1) : Math.max(0, Math.min(1, (y - g.y1) / span));
        let c = root._gradBase(7);
        for (let j = 0; j < 7; j++) {
            if (t <= g.pos[j + 1]) {
                const p0 = g.pos[j], p1 = g.pos[j + 1];
                const u = p1 - p0 > 1e-9 ? Math.max(0, Math.min(1, (t - p0) / (p1 - p0))) : 1;
                c = root._mixColor(root._gradBase(j), root._gradBase(j + 1), u);
                break;
            }
        }
        const s = root._slotSeries("grad");
        const fall = 1 - Math.max(0, Math.min(1, root.areaFade)) * k / 7;
        return root._alpha(c, root.areaAlpha * fall * (s ? root._presence(s.w) : 0));
    }
    function _gradColor(k, alpha) {
        const F = root._frame;
        const s = root._slotSeries("grad");
        const c = F.grad.col[k];
        const base = c !== null && c !== undefined ? c : (s ? s.color : root.markerColor);
        return root._alpha(base, alpha * (s ? root._presence(s.w) : 0));
    }

    // ---- The carved plot area -----------------------------------------------
    // What a knocked-out label or a dot's rim is cut in: the box's fill, or
    // the host's ground when there is no box.
    readonly property color _knockColor: root.boxed ? root.fillColor : root.surfaceColor
    ShadowBox {
        visible: root.boxed
        anchors.fill: parent
        baseRadius: root.radius
        surfaceColor: root.surfaceColor
        backgroundColor: root.fillColor
        bevelColor: root.bevelColor
        shadowColor: root.shadowColor
        bevelWidth: root.bevelWidth
        shadowWidth: root.shadowWidth
        shadowFalloff: root.shadowFalloff
    }

    // The marker and now columns (markerStyle "column"): under the grid and the
    // bars, so a bar stands IN its column and a grid line runs across it.
    FontMetrics {
        id: columnFm
        font.family: root.fontFamily
        font.pixelSize: root.figureSize
    }
    component SlotColumn: Rectangle {
        property real slot: 0
        property real presence: 0
        readonly property real _w: Math.max(0, Math.round(root._frame.slotW) - 2 * root.columnInset)
        visible: root.markerStyle === "column" && root._frame.n > 0 && presence > 0.001
        x: Math.round(root._fx(root._frame, slot) - _w / 2)
        y: Math.round(root._frame.py0) - root.columnInset
        width: _w
        height: Math.round(root.py1 + 4 + columnFm.height) + root.columnInset - y
        radius: Math.min(8, _w / 2)
        color: root.columnColor
    }
    SlotColumn {
        slot: root._frame.now.s
        presence: root._frame.now.w * (root._mk.i === Math.round(root._frame.now.s) ? 1 - root._mk.w : 1)
        opacity: root.nowColumnAlpha * presence
    }
    SlotColumn {
        slot: Math.max(0, root._mk.i)
        presence: root._mk.i >= 0 && root._mk.i < root._frame.n ? root._mk.w : 0
        opacity: presence
    }

    // Grid lines and y labels: a pool the frame's ticks fill in value order.
    Repeater {
        model: root._tickPool
        delegate: Item {
            id: tick
            required property int index
            readonly property var t: root._frame.ticks[tick.index] || null
            readonly property real v: tick.t ? tick.t.v : 0
            readonly property real ty: tick.t ? root._fyN(root._frame, tick.t.n) : 0
            readonly property real edge: tick.t ? root._edgeOf(tick.ty) : 0
            visible: tick.t !== null && tick.edge * tick.t.w > 0.001
            Rectangle {
                x: root._frame.px0
                y: Math.round(tick.ty) - 0.5
                width: Math.max(0, root._frame.px1 - root._frame.px0)
                height: 1
                color: root.gridColor
                opacity: tick.t ? (0.45 + 0.45 * tick.t.base) * tick.t.w * tick.edge : 0
            }
            Text {
                x: root.padding
                width: root._frame.yLabelW
                y: Math.round(tick.ty - height / 2)
                horizontalAlignment: Text.AlignRight
                text: tick.t ? tick.t.text : ""
                opacity: tick.t ? root._presence(tick.t.lw) * tick.edge : 0
                visible: opacity > 0.001
                color: root.faintColor
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
            }
        }
    }

    // X labels, every `xLabelEvery` slots, centred on their slot but never
    // past the padding line: a chart with no figures' column (an empty day)
    // runs its plot from the padding, and its first hour would stand 2 px
    // outside.
    Repeater {
        model: root.xLabels.length
        delegate: Text {
            id: xl
            required property int index
            visible: xl.index % Math.max(1, root.xLabelEvery) === 0
            x: Math.max(root.padding, Math.min(root.width - root.padding - xl.width,
                                               Math.round(root._fx(root._frame, xl.index) - xl.width / 2)))
            y: root.py1 + 4
            text: root.xLabels[xl.index] !== undefined ? String(root.xLabels[xl.index]) : ""
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
    }
    // Sparse x labels, placed like the hour labels: a fixed pool.
    // Twelve labels a range; during a morph both ranges' are drawn at once.
    readonly property int _xTickPool: 24
    Repeater {
        model: root._xTickPool
        delegate: Text {
            id: xt
            required property int index
            readonly property var tk: root._frame.xt && xt.index < root._frame.xt.length ? root._frame.xt[xt.index] : null
            visible: xt.tk !== null && xt.tk.w > 0.001
            opacity: xt.tk ? xt.tk.w : 0
            x: xt.visible ? Math.max(root.padding, Math.min(root.width - root.padding - xt.width,
                                                            Math.round(xt.tk.x - xt.width / 2))) : 0
            y: root.py1 + 4
            text: xt.tk && xt.tk.text !== undefined ? String(xt.tk.text) : ""
            color: root.faintColor
            font.family: root.fontFamily
            font.pixelSize: root.figureSize
        }
    }

    // The "now" mark: a faint accent hairline.
    Rectangle {
        readonly property real _w: root._frame.n > 0 ? root._frame.now.w : 0
        visible: _w > 0.001 && root.markerStyle !== "column"
        x: Math.round(root._fx(root._frame, root._frame.now.s) - 0.5)
        y: root._frame.py0
        width: 1
        height: Math.max(0, root._frame.py1 - root._frame.py0)
        color: root.nowColor
        opacity: 0.4 * _w
    }

    // Bars as paths (barsAsPath): one per bar series, under everything else.
    function _barFill(k) {
        const b = root._frame.bars || [];
        const sr = k < b.length ? root._frame.series[b[k]] : null;
        return sr ? root._alpha(sr.color, root._isNum(sr.alpha) ? sr.alpha : root.barAlpha) : "transparent";
    }
    // The geometry renderer, not the curve renderer: bars are straight edges,
    // and during a resampled morph two sets of them interleave and overlap --
    // the curve renderer resolves every overlap in polish (~50 ms a frame,
    // measured), the triangulator does not care. (The curve renderer is the chart's rule for its LINES, where a
    // curve meeting a straight edge must not step -- a rectangle has neither.)
    Shape {
        id: barPlot
        anchors.fill: parent
        visible: root.barsAsPath
        antialiasing: true
        preferredRendererType: Shape.GeometryRenderer
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: root._barFill(0)
            PathSvg { path: root._frame.paths.bar0 || "" }
        }
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: root._barFill(1)
            PathSvg { path: root._frame.paths.bar1 || "" }
        }
    }

    // Bars: a pool of (bar series, slot) cells, coloured by their series.
    readonly property int _barPool: root.barsAsPath ? 0 : Math.max(48, 2 * root._n)
    Repeater {
        model: root._barPool
        delegate: Rectangle {
            id: bar
            required property int index
            readonly property int _slots: Math.max(1, root._frame.n)
            readonly property int _i: bar.index % bar._slots
            readonly property int _sid: {
                const b = Math.floor(bar.index / bar._slots);
                return b < root._frame.bars.length ? root._frame.bars[b] : -1;
            }
            readonly property var _s: bar._sid >= 0 ? root._frame.series[bar._sid] : null
            readonly property var _v: bar._s && bar._s.bars && bar._i < bar._s.bars.length ? bar._s.bars[bar._i] : null
            // For probes: which fact this bar draws (series index, slot, value).
            readonly property var fact: ({ sid: bar._v !== null ? bar._sid : -1, i: bar._i, v: bar._v })
            readonly property real barTop: bar._v !== null ? root._fyN(root._frame, bar._v) : 0
            readonly property real barBase: root._frame.py1
            visible: bar._v !== null
            x: Math.round(root._fxAt(root._frame, bar._i) - root._frame.barW / 2)
            width: root._frame.barW
            y: Math.min(bar.barTop, bar.barBase)
            height: Math.max(0, bar.barBase - bar.barTop)
            radius: Math.min(2, root._frame.barW / 2)
            color: bar._s ? root._alpha(bar._s.color, root._isNum(bar._s.alpha) ? bar._s.alpha : root.barAlpha) : "transparent"
        }
    }

    // Bands, areas, lines, arrows: one Shape, a fixed pool of paths.
    Shape {
        id: plot
        anchors.fill: parent
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: root._slotStroke("band0", root.bandAlpha)
            fillRule: ShapePath.WindingFill
            PathSvg { path: root._frame.paths.band0 }
        }
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillColor: root._slotStroke("band1", root.bandAlpha)
            fillRule: ShapePath.WindingFill
            PathSvg { path: root._frame.paths.band1 }
        }
        // The gradient line's area, then the line itself as an offset band.
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillRule: ShapePath.WindingFill
            fillGradient: LinearGradient {
                x1: 0; x2: 0
                y1: root.areaFade > 0 ? root._frame.py0 : root._frame.grad.y1
                y2: root.areaFade > 0 ? root._frame.py1 : root._frame.grad.y2
                spread: ShapeGradient.PadSpread
                GradientStop { position: root._areaPos(0); color: root._areaColor(0) }
                GradientStop { position: root._areaPos(1); color: root._areaColor(1) }
                GradientStop { position: root._areaPos(2); color: root._areaColor(2) }
                GradientStop { position: root._areaPos(3); color: root._areaColor(3) }
                GradientStop { position: root._areaPos(4); color: root._areaColor(4) }
                GradientStop { position: root._areaPos(5); color: root._areaColor(5) }
                GradientStop { position: root._areaPos(6); color: root._areaColor(6) }
                GradientStop { position: root._areaPos(7); color: root._areaColor(7) }
            }
            PathSvg { path: root._frame.paths.gradArea }
        }
        ShapePath {
            strokeWidth: 0
            strokeColor: "transparent"
            fillRule: ShapePath.WindingFill
            fillGradient: LinearGradient {
                x1: 0; x2: 0
                y1: root._frame.grad.y1
                y2: root._frame.grad.y2
                spread: ShapeGradient.PadSpread
                GradientStop { position: root._frame.grad.pos[0]; color: root._gradColor(0, 1) }
                GradientStop { position: root._frame.grad.pos[1]; color: root._gradColor(1, 1) }
                GradientStop { position: root._frame.grad.pos[2]; color: root._gradColor(2, 1) }
                GradientStop { position: root._frame.grad.pos[3]; color: root._gradColor(3, 1) }
                GradientStop { position: root._frame.grad.pos[4]; color: root._gradColor(4, 1) }
                GradientStop { position: root._frame.grad.pos[5]; color: root._gradColor(5, 1) }
                GradientStop { position: root._frame.grad.pos[6]; color: root._gradColor(6, 1) }
                GradientStop { position: root._frame.grad.pos[7]; color: root._gradColor(7, 1) }
            }
            PathSvg { path: root._frame.paths.gradLine }
        }
        // Plain strokes.
        ShapePath {
            strokeColor: root._slotStroke("line0", 1)
            strokeWidth: root._slotWidth("line0")
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            strokeStyle: root._slotDashed("line0") ? ShapePath.DashLine : ShapePath.SolidLine
            dashPattern: root._slotDash("line0")
            PathSvg { path: root._frame.paths.line0 }
        }
        ShapePath {
            strokeColor: root._slotStroke("line1", 1)
            strokeWidth: root._slotWidth("line1")
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            strokeStyle: root._slotDashed("line1") ? ShapePath.DashLine : ShapePath.SolidLine
            dashPattern: root._slotDash("line1")
            PathSvg { path: root._frame.paths.line1 }
        }
        ShapePath {
            strokeColor: root._slotStroke("line2", 1)
            strokeWidth: root._slotWidth("line2")
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            strokeStyle: root._slotDashed("line2") ? ShapePath.DashLine : ShapePath.SolidLine
            dashPattern: root._slotDash("line2")
            PathSvg { path: root._frame.paths.line2 }
        }
        ShapePath {
            strokeColor: root._slotStroke("line3", 1)
            strokeWidth: root._slotWidth("line3")
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            strokeStyle: root._slotDashed("line3") ? ShapePath.DashLine : ShapePath.SolidLine
            dashPattern: root._slotDash("line3")
            PathSvg { path: root._frame.paths.line3 }
        }
        ShapePath {
            strokeColor: root._slotStroke("line4", 1)
            strokeWidth: root._slotWidth("line4")
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            strokeStyle: root._slotDashed("line4") ? ShapePath.DashLine : ShapePath.SolidLine
            dashPattern: root._slotDash("line4")
            PathSvg { path: root._frame.paths.line4 }
        }
        // Arrows: each carries its own presence in its length.
        ShapePath {
            strokeColor: root._slotSeries("arrows") ? root._slotSeries("arrows").color : "transparent"
            strokeWidth: root._slotSeries("arrows") ? 1.2 : 0
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: root._frame.paths.arrows }
        }
    }

    // The marker: a hairline at the index. Drawn UNDER the thresholds, so a
    // label it crosses knocks it out as it does a bar, instead of the hairline
    // striking through the word.
    readonly property real markerX: marker.x + 0.5
    Rectangle {
        id: marker
        readonly property real _w: root._mk.i >= 0 && root._mk.i < root._frame.n ? root._mk.w : 0
        visible: marker._w > 0.001 && root.markerStyle !== "column"
        x: root.markerFollowsPointer && !isNaN(root._hoverPx) ? Math.round(root._hoverPx - 0.5)
                                                              : Math.round(root._fx(root._frame, Math.max(0, root._mk.i)) - 0.5)
        y: root._frame.py0
        width: 1
        height: Math.max(0, root._frame.py1 - root._frame.py0)
        color: root.markerColor
        opacity: 0.55 * marker._w
    }

    // Thresholds: a dashed line each, only when in range, and a label standing
    // on its line. A label is drawn only where it has a line's height of room
    // below the label above it -- close bands (fog at 1 km, mist at 5 on a
    // 60 km axis) keep their lines and lose the crowded words.
    //
    // WHERE A LABEL STANDS. At the plot's right end, unless a LINE series runs
    // through that box; then at the left end; else nowhere (the dashed line
    // stays). A label is knocked out of whatever it crosses (its outline is the
    // fill colour): right over a bar or an area, but through a line it cuts a
    // gap, and the marker's dot sits ON a line. So every line's segments are
    // obstacles grown by the dot's radius -- a box clear of them is clear of
    // the dot at every hour, the placement is a fact of the day's data, and
    // hovering never moves a label. When the whole set fits on one side it
    // takes that side (right first), so one crossing does not scatter it.
    // Each side has its own label in the pool, so a label that changes side
    // in a morph leaves one end and arrives at the other, by halves.
    //
    // A segment's box bounds its curve: the controls are clamped to the
    // segment's own y range and sit inside its x span (`_controls`).
    readonly property var _lineBoxes: {
        const out = [];
        for (let k = 0; k < root.series.length; k++) {
            const s = root.series[k];
            if (!s || s.kind !== "line")
                continue;
            const pad = Math.max(root.dotRadius, root._widthOf(k) / 2) + 1;
            const runs = root._runs(root.pointsOf(k));
            for (const r of runs) {
                for (let i = 0; i < r.length; i++) {
                    const a = r[i], b = r[Math.min(r.length - 1, i + 1)];
                    out.push({ x0: Math.min(a.x, b.x) - pad, x1: Math.max(a.x, b.x) + pad,
                               y0: Math.min(a.y, b.y) - pad, y1: Math.max(a.y, b.y) + pad });
                }
            }
        }
        return out;
    }
    // Per threshold: "right" | "left" | "off". Reads `fm.font` first
    // (advanceWidth is a call and captures nothing).
    readonly property var _thresholdPlace: {
        const f = fm.font;
        const ths = root.thresholds, a = root._axis, lh = root._lineH;
        const place = [];
        const items = [];
        for (let k = 0; k < ths.length; k++) {
            place.push("off");
            const t = ths[k];
            if (t && root._isNum(t.value) && t.value >= a.lo && t.value <= a.hi) {
                const label = t.label !== undefined ? String(t.label) : "";
                items.push({ k: k, y: root.yFor(t.value), w: Math.ceil(fm.advanceWidth(label)) });
            }
        }
        items.sort((p, q) => p.y - q.y);
        const shown = [];
        let lastY = -Infinity;
        for (const it of items) {
            if (it.y - lastY >= lh + 1) {
                shown.push(it);
                lastY = it.y;
            }
        }
        const boxes = root._lineBoxes;
        const clear = (x0, x1, y0, y1) => !boxes.some(b => b.x1 > x0 && b.x0 < x1 && b.y1 > y0 && b.y0 < y1);
        let allRight = true, allLeft = true;
        for (const it of shown) {
            const y1 = Math.round(it.y), y0 = y1 - lh;
            it.right = clear(root.px1 - 4 - it.w - 1, root.px1 - 3, y0, y1);
            it.left = clear(root.px0 + 3, root.px0 + 4 + it.w + 1, y0, y1);
            allRight = allRight && it.right;
            allLeft = allLeft && it.left;
        }
        const side = allRight ? "right" : (allLeft ? "left" : "");
        for (const it of shown)
            place[it.k] = side || (it.right ? "right" : (it.left ? "left" : "off"));
        return place;
    }
    readonly property int _thPool: Math.max(12, root.thresholds.length)
    Repeater {
        model: root._thPool
        delegate: Item {
            id: th
            required property int index
            readonly property var t: root._frame.th[th.index] || null
            readonly property bool _valued: th.t !== null && isFinite(th.t.v)
            readonly property real ty: th._valued ? root._fyN(root._frame, th.t.n) : 0
            readonly property real edge: th._valued ? root._edgeOf(th.ty) : 0
            // By halves, like the labels: a band's line leaves with the
            // data it bounds, before an empty day's text arrives.
            readonly property real lineA: th._valued ? root._presence(th.t.w) * th.edge : 0
            readonly property color c: th.t ? th.t.color : root.faintColor
            // Where its label is (the side it mostly is on), and that label
            // (probes read both).
            readonly property string place: !th.t ? "off" : (th.t.wr > 0.5 ? "right" : (th.t.wl > 0.5 ? "left" : "off"))
            readonly property Item label: th.place === "left" ? thLabelL : thLabelR
            visible: th.lineA > 0.001
            Shape {
                anchors.fill: parent
                antialiasing: true
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    strokeColor: root._alpha(th.c, 0.8 * th.lineA)
                    strokeWidth: 1
                    fillColor: "transparent"
                    strokeStyle: ShapePath.DashLine
                    dashPattern: [4, 3]
                    startX: root._frame.px0
                    startY: Math.round(th.ty) + 0.5
                    PathLine { x: root._frame.px1; y: Math.round(th.ty) + 0.5 }
                }
            }
            // Knocked out of whatever it crosses: with an axis floor the data
            // runs among the lower bands' lines, through their labels.
            Text {
                id: thLabelR
                opacity: th.t ? root._presence(th.t.wr) * th.lineA : 0
                visible: opacity > 0.001
                text: th.t ? th.t.text : ""
                color: th.c
                style: Text.Outline
                styleColor: root._knockColor
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                x: Math.round(root._frame.px1 - 4 - width)
                y: Math.round(th.ty) - height
            }
            Text {
                id: thLabelL
                opacity: th.t ? root._presence(th.t.wl) * th.lineA : 0
                visible: opacity > 0.001
                text: th.t ? th.t.text : ""
                color: th.c
                style: Text.Outline
                styleColor: root._knockColor
                font.family: root.fontFamily
                font.pixelSize: root.figureSize
                x: Math.round(root._frame.px0 + 4)
                y: Math.round(th.ty) - height
            }
        }
    }

    // Trade marks: a triangle per mark, its INK centred on the value's point
    // (xFor(i), yFor(v)), knocked out of what it crosses. A fixed pool.
    readonly property int _markPool: 24
    // Audiowide and Inter have no triangles; this face has a matched pair.
    readonly property string _markFont: "Symbols Nerd Font"
    readonly property string _glyphBuy: String.fromCodePoint(0xF1A0A)
    readonly property string _glyphSell: String.fromCodePoint(0xF1A09)
    // Each glyph's ink centre from its origin (x from the Text's left, y from
    // its baseline, which the delegate reads from the Text itself), from the
    // font's own outline: both triangles span x 0..680 and y 316..912 of a
    // 2048 em. FontMetrics.tightBoundingRect answers in whole pixels and puts
    // the ink 1.2 px off at 24 px (measured).
    readonly property var _markInk: {
        const em = root.markPixelSize / 2048;
        const c = { x: 340 * em, y: -614 * em };
        return { buy: c, sell: c };
    }
    Repeater {
        model: root._markPool
        delegate: Text {
            id: mark
            required property int index
            readonly property var m: root._frame.marks && mark.index < root._frame.marks.length ? root._frame.marks[mark.index] : null
            readonly property var _s: mark.m ? root._frame.series[mark.m.sid] : null
            readonly property bool sell: !!mark.m && mark.m.g === "sell"
            readonly property var _ink: mark.sell ? root._markInk.sell : root._markInk.buy
            // Where its ink centre is meant to be (probes hold it to xFor / yFor).
            readonly property real cx: mark.m ? root._fxAt(root._frame, mark.m.s) : 0
            readonly property real cy: mark.m ? root._fyN(root._frame, mark.m.n) : 0
            readonly property real _o: mark.m ? root._presence(mark.m.w) * root._edgeOf(mark.cy) : 0
            visible: mark._o > 0.001
            opacity: mark._o
            x: Math.round(mark.cx - mark._ink.x)
            y: Math.round(mark.cy - mark.baselineOffset - mark._ink.y)
            text: mark.sell ? root._glyphSell : root._glyphBuy
            color: mark._s && mark._s.ownColor ? mark._s.color : (mark.sell ? root.sellColor : root.buyColor)
            style: Text.Outline
            styleColor: root._knockColor
            font.family: root._markFont
            font.pixelSize: root.markPixelSize
        }
    }

    // The marker's dots, one on every line series at the index, over the
    // labels (which the placement keeps a dot's radius clear of every line).
    readonly property int _dotPool: Math.max(6, root.series.length)
    Repeater {
        model: root._dotPool
        delegate: Rectangle {
            id: dot
            required property int index
            readonly property var s: root._frame.series[dot.index] || null
            readonly property bool isLine: !!(dot.s && dot.s.kind === "line")
            readonly property bool _follow: root.markerFollowsPointer && !isNaN(root._hoverPx)
            // Following the pointer: the line's height as drawn at the
            // hairline (null where this line does not pass).
            readonly property real _fy: dot._follow && dot.isLine && root._mk.w > 0 ? root._lineYAt(root._frame, dot.s, root.markerX) : NaN
            readonly property var p: dot._follow ? (isNaN(dot._fy) ? null : ({ ls: -1, ln: 0 }))
                                   : dot.isLine && root._mk.w > 0 && root._mk.i >= 0 && dot.s.pts && root._mk.i < dot.s.pts.length
                                     ? dot.s.pts[root._mk.i] : null
            readonly property real _o: dot.p ? root._mk.w * root._presence(dot.s.w) : 0
            visible: dot.p !== null && dot._o > 0.001
            readonly property real cy: dot._follow ? dot._fy : (dot.p ? root._fyN(root._frame, dot.p.ln) : 0)
            width: root.dotRadius * 2
            height: width
            radius: width / 2
            x: (!dot._follow && dot.p && Math.abs(dot.p.ls - root._mk.i) > 1e-6 ? root._fx(root._frame, dot.p.ls) : root.markerX) - width / 2
            y: dot.cy - height / 2
            opacity: dot._o
            color: dot.s ? dot.s.color : root.markerColor
            border.width: 1.5
            border.color: root._knockColor
        }
    }

    Text {
        id: emptyLabel
        readonly property real _o: root._presence(root._frame.textW)
        visible: emptyLabel._o > 0.001
        opacity: emptyLabel._o
        anchors.centerIn: parent
        text: root._frame.emptyText
        color: root.faintColor
        font.family: root.fontFamily
        font.pixelSize: root.figureSize + 1
    }

    // Hover: which slot the pointer is over. Takes no buttons, so a click
    // still reaches whatever the host puts under the chart.
    MouseArea {
        x: root.px0
        y: root.py0
        width: Math.max(0, root.px1 - root.px0)
        height: Math.max(0, root.py1 - root.py0)
        hoverEnabled: true
        acceptedButtons: Qt.NoButton
        cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
        onPositionChanged: mouse => {
            root._hoverY = root.py0 + mouse.y;
            root._hoverPx = root.px0 + mouse.x;
            if (root.slotW <= 0)
                return;
            root.hoverIndex = Math.max(0, Math.min(root._n - 1, Math.floor((root.px0 + mouse.x - root._sx0) / root.slotW)));
        }
        onExited: {
            root._hoverY = NaN;
            root._hoverPx = NaN;
            root.hoverIndex = -1;
        }
    }

    // The height a line is DRAWN at, at pixel x, in this frame: its drawn runs
    // (what the paths are made of) read as a polyline; NaN where no run of it
    // passes. A dot riding it moves with the line through a morph.
    function _lineYAt(F, s, x) {
        if (!s || s.kind !== "line")
            return NaN;
        const runs = root._drawnRuns(F, s);
        for (const run of runs) {
            if (run.length === 0 || x < run[0].x - 0.5 || x > run[run.length - 1].x + 0.5)
                continue;
            if (run.length === 1)
                return run[0].y;
            for (let k = 0; k + 1 < run.length; k++) {
                const a = run[k], b = run[k + 1];
                if (x <= b.x || k + 2 === run.length) {
                    if (b.x - a.x < 1e-6)
                        return b.y;
                    const t = Math.max(0, Math.min(1, (x - a.x) / (b.x - a.x)));
                    return a.y + (b.y - a.y) * t;
                }
            }
        }
        return NaN;
    }
    onHoverIndexChanged: root.hovered(root.hoverIndex)
    function _rehover() {
        if (!isNaN(root._hoverPx) && root.slotW > 0)
            root.hoverIndex = Math.max(0, Math.min(root._n - 1, Math.floor((root._hoverPx - root._sx0) / root.slotW)));
    }
    on_NChanged: root._rehover()
    onSlotWChanged: root._rehover()
    on_Sx0Changed: root._rehover()
}
