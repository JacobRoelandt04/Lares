pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components/Mix.js" as Mix

// =============================================================================
// ScreentimeSpan.qml -- the Span face: one floating bar per day from the first
// activity to the last, on an axis of the logical day's hours (the day's start
// at the top, time flowing down).
//
// The same hold / progress contract as the heat grid: `target` is the host's
// 7 {lo, hi} (hours since the day's start; null for a day without activity),
// `hold()` snapshots what is DRAWN, `progress` is the host's one clock. A bar
// that exists on one side only grows out of (shrinks into) its own midpoint
// while its presence fades -- the chart's rule for a bar with one side missing.
// =============================================================================
Item {
    id: span

    property var target: []
    property real progress: 1
    property color hue: Theme.accent
    property var dayLabels: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    property int startHour: 4
    property int selectedDay: -1
    property string fontFamily: "Inter"
    property int labelSize: 10
    property real barWidth: 14
    property real barAlpha: 0.85

    property var _from: null
    property color _fromHue: span.hue

    readonly property real _p: Math.max(0, Math.min(1, span.progress))
    readonly property color hueNow: Mix.c(span._fromHue, span.hue, span._p)

    // A frame is 7 x {lo, hi, w}: w is the bar's presence.
    function _frameOf(t) {
        const out = [];
        for (let d = 0; d < 7; d++) {
            const x = t && d < t.length ? t[d] : null;
            out.push(x ? { lo: x.lo, hi: x.hi, w: 1 } : { lo: 0, hi: 0, w: 0 });
        }
        return out;
    }
    readonly property var _targetFrame: span._frameOf(span.target)
    readonly property var _drawn: {
        const B = span._targetFrame, A = span._from || B, p = span._p;
        const out = [];
        for (let d = 0; d < 7; d++) {
            const a = A[d], b = B[d];
            const w = a.w + (b.w - a.w) * p;
            let lo, hi;
            if (a.w > 0 && b.w > 0) {
                lo = a.lo + (b.lo - a.lo) * p;
                hi = a.hi + (b.hi - a.hi) * p;
            } else if (a.w > 0) {                       // leaving: into its own midpoint
                const m = (a.lo + a.hi) / 2;
                lo = a.lo + (m - a.lo) * p;
                hi = a.hi + (m - a.hi) * p;
            } else if (b.w > 0) {                       // arriving: out of its own midpoint
                const m = (b.lo + b.hi) / 2;
                lo = m + (b.lo - m) * p;
                hi = m + (b.hi - m) * p;
            } else {
                lo = 0;
                hi = 0;
            }
            out.push({ lo: lo, hi: hi, w: w });
        }
        return out;
    }

    function hold() {
        span._fromHue = span.hueNow;
        span._from = span._drawn;
    }

    // ---- geometry ----------------------------------------------------------------
    readonly property real _labelW: 24
    readonly property real _top: 7
    readonly property real _foot: 16
    readonly property real _y1: span.height - span._foot
    readonly property real scaleY: (span._y1 - span._top) / 24
    readonly property real colW: (span.width - span._labelW) / 7

    function dayAt(x) {
        const d = Math.floor((x - span._labelW) / span.colW);
        return d >= 0 && d < 7 ? d : -1;
    }
    function _p2(n) {
        return (n < 10 ? "0" : "") + n;
    }

    Repeater {
        model: 5
        Item {
            id: grid
            required property int index
            readonly property real gy: Math.round(span._top + grid.index * 6 * span.scaleY)
            Rectangle {
                x: span._labelW
                y: grid.gy
                width: span.width - span._labelW
                height: 1
                color: Theme.border
                opacity: 0.7
            }
            Text {
                x: 0
                y: grid.gy - Math.round(height / 2)
                text: span._p2((span.startHour + grid.index * 6) % 24)
                color: Theme.textFaint
                font.family: span.fontFamily
                font.pixelSize: span.labelSize
            }
        }
    }
    Repeater {
        model: 7
        Item {
            id: col
            required property int index
            readonly property var f: span._drawn[col.index]
            readonly property real cx: span._labelW + (col.index + 0.5) * span.colW
            Rectangle {
                x: Math.round(col.cx - span.barWidth / 2)
                y: Math.round(span._top + col.f.lo * span.scaleY)
                width: Math.round(span.barWidth)
                height: Math.max(3, Math.round(span._top + col.f.hi * span.scaleY) - y)
                radius: Math.min(width / 2, 5)
                color: span.hueNow
                opacity: span.barAlpha * col.f.w
                visible: col.f.w > 0.002
            }
            Text {
                x: Math.round(col.cx - width / 2)
                y: span.height - height
                text: col.index < span.dayLabels.length ? span.dayLabels[col.index] : ""
                color: col.index === span.selectedDay ? Theme.accent : Theme.textFaint
                font.family: span.fontFamily
                font.pixelSize: span.labelSize
            }
        }
    }
}
