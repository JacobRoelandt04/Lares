pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// LineViewport.qml -- a virtualised vertical list of variable-height rows.
//
// Only the rows on screen (plus an overscan band) have a delegate; the rest
// are a height in an array. Built for the notes editor, where a row is one
// source line in its own TextEdit: a 2000-line note laid out as one document
// costs 33 ms per resize step, the rows on screen cost ~1 (stage-0 spike), so
// what is not visible must not exist.
//
// WHY NOT ListView. ListView estimates its content height and shifts its own
// origin when a delegate above the viewport changes height, which fights a
// host that clamps contentY by hand; and it recycles the delegate that holds
// keyboard focus the moment it scrolls away. Here:
//   * heights live in an array: measured for rows that have been built at
//     this width, `estimate(i, width)` for the rest, prefix sums rebuilt in
//     O(n) only when a height changed (~20 us at 2000 rows);
//   * a row that changes height ABOVE the viewport moves contentY by the same
//     amount, so what is on screen never jumps (the anchor rule);
//   * `pinned` names a row whose delegate is kept however far it scrolls --
//     the caret's line, so focus survives a scroll away and back;
//   * a delegate keeps its row while that row stays in range, and a freed one
//     takes a new row, so scrolling one line re-renders one line.
//
// The Flickable is NOT interactive: the host puts a ScrollDressing beside
// this (the shell's one wheel reader) and every change to contentY -- wheel,
// ensureVisible, anchoring -- runs relayout() in the same frame.
//
// Delegate contract: an Item with `property int lineIndex` (set here; -1 when
// free) whose `implicitHeight` is its height at the viewport's width.
// `assigned(item, index)` is emitted when a delegate takes a row, so the host
// fills it in synchronously -- its height is read right after.
// =============================================================================
Item {
    id: vp

    property int count: 0
    property Component delegate: null
    // An item shown above row 0 inside the scrolled content (the note's
    // title); its height counts.
    property Item header: null
    property real topPadding: 0
    property real headerGap: 0
    property real bottomPadding: 0
    // A row whose delegate must exist wherever it is (-1: none).
    property int pinned: -1
    property real overscan: 120
    // function(index, width) -> estimated height of a row never built.
    property var estimate: null
    // Optional batch form, function(width, from, to) -> [heights]: a host
    // that reads its metrics once per batch instead of once per row (2000
    // rows cost 1.8 ms one by one through QML property reads).
    property var estimateRange: null
    property real defaultRowHeight: 18

    readonly property alias flick: flick
    readonly property alias contentItem: flick.contentItem
    // An item under the rows, in content coordinates (block backgrounds).
    readonly property alias underlay: underlayItem
    readonly property real headSpace: vp.topPadding + (vp.header ? vp.header.height + vp.headerGap : 0)
    readonly property real contentHeight: flick.contentHeight

    signal assigned(Item item, int index)
    signal laidOut

    property var _h: []
    property var _pre: [0]
    property bool _preDirty: true
    property var _pool: []
    property var _byLine: ({})
    property bool _inLayout: false
    property bool _again: false
    property real _lastWidth: -1

    Flickable {
        id: flick
        anchors.fill: parent
        interactive: false
        clip: true
        contentWidth: width
        boundsBehavior: Flickable.StopAtBounds
        onContentYChanged: vp.relayout()
        Item {
            id: underlayItem
            width: flick.width
            height: flick.contentHeight
        }
    }

    onWidthChanged: vp._widthChanged()
    onHeightChanged: vp.relayout()
    // A header given at construction fires no change signal: attach it on
    // completion as well.
    onHeaderChanged: vp._attachHeader()
    Component.onCompleted: vp._attachHeader()
    function _attachHeader() {
        if (vp.header) {
            vp.header.parent = flick.contentItem;
            vp.header.y = Qt.binding(() => vp.topPadding);
            vp.header.width = Qt.binding(() => flick.width);
        }
        vp.relayout();
    }
    Connections {
        target: vp.header
        function onHeightChanged() {
            vp.relayout();
        }
    }

    // ---- Heights -----------------------------------------------------------------

    function _est(i) {
        const e = vp.estimate ? vp.estimate(i, vp.width) : vp.defaultRowHeight;
        return e > 0 ? e : 0;
    }

    function _prefix() {
        if (!vp._preDirty)
            return;
        const n = vp._h.length;
        const pre = new Array(n + 1);
        let acc = 0;
        pre[0] = 0;
        for (let i = 0; i < n; ++i) {
            acc += vp._h[i];
            pre[i + 1] = acc;
        }
        vp._pre = pre;
        vp._preDirty = false;
    }

    function yOf(i) {
        vp._prefix();
        const k = Math.max(0, Math.min(vp._h.length, i));
        return vp.headSpace + vp._pre[k];
    }

    function heightOf(i) {
        return i >= 0 && i < vp._h.length ? vp._h[i] : 0;
    }

    // The row at content y (clamped to [0, count - 1]).
    function indexAt(y) {
        vp._prefix();
        const n = vp._h.length;
        if (n === 0)
            return -1;
        const t = y - vp.headSpace;
        let lo = 0, hi = n - 1;
        while (lo < hi) {
            const mid = (lo + hi + 1) >> 1;
            if (vp._pre[mid] <= t)
                lo = mid;
            else
                hi = mid - 1;
        }
        return lo;
    }

    function delegateFor(i) {
        return vp._byLine[i] || null;
    }

    function assignedItems() {
        const out = [];
        for (const d of vp._pool)
            if (d.lineIndex >= 0)
                out.push(d);
        return out;
    }

    // ---- Model changes -------------------------------------------------------------

    // Everything is new (a document was loaded).
    function _estRange(from, to) {
        if (vp.estimateRange)
            return vp.estimateRange(vp.width, from, to);
        const out = new Array(Math.max(0, to - from));
        for (let i = from; i < to; ++i)
            out[i - from] = vp._est(i);
        return out;
    }

    function reset() {
        vp._h = vp._estRange(0, vp.count);
        vp._preDirty = true;
        for (const d of vp._pool)
            vp._free(d);
        vp._byLine = {};
        flick.contentY = 0;
        vp.relayout();
    }

    // Old rows [from, from + removed) became new rows [from, from + inserted).
    function linesChanged(from, removed, inserted) {
        const add = vp._estRange(from, from + inserted);
        vp._h.splice(from, removed, ...add);
        vp._preDirty = true;
        const delta = inserted - removed;
        const map = {};
        for (const d of vp._pool) {
            const i = d.lineIndex;
            if (i < 0)
                continue;
            if (i >= from && i < from + removed) {
                // The row it showed was replaced: it is re-filled below if
                // its new row is still in range.
                if (i < from + inserted) {
                    map[i] = d;
                    d.lineIndex = i;
                    vp.assigned(d, i);
                } else {
                    vp._free(d);
                }
            } else if (i >= from + removed) {
                d.lineIndex = i + delta;
                map[i + delta] = d;
            } else {
                map[i] = d;
            }
        }
        vp._byLine = map;
        if (vp.pinned >= vp.count)
            vp.pinned = vp.count - 1;
        vp.relayout();
    }

    // A width change: rows built at the old width are measured again when
    // they are next on screen; the rest are re-estimated. The row at the top
    // of the viewport keeps its place.
    function _widthChanged() {
        if (vp._lastWidth === vp.width)
            return;
        vp._lastWidth = vp.width;
        vp._prefix();
        const cy = flick.contentY;
        const top = vp.indexAt(cy);
        const off = top >= 0 ? cy - vp.yOf(top) : 0;
        const frac = top >= 0 && vp._h[top] > 0 ? off / vp._h[top] : 0;
        const est = vp._estRange(0, vp._h.length);
        for (let i = 0; i < vp._h.length; ++i)
            if (!vp._byLine[i])
                vp._h[i] = est[i];
        vp._preDirty = true;
        vp._measureAll();
        if (top >= 0) {
            vp._inLayout = true;
            flick.contentY = vp._clampY(vp.yOf(top) + frac * vp._h[top]);
            vp._inLayout = false;
        }
        vp.relayout();
    }

    function _free(d) {
        d.lineIndex = -1;
        d.visible = false;
    }

    function _take() {
        for (const d of vp._pool)
            if (d.lineIndex < 0)
                return d;
        if (!vp.delegate)
            return null;
        const d = vp.delegate.createObject(flick.contentItem, {
            lineIndex: -1
        });
        d.width = Qt.binding(() => flick.width);
        d.implicitHeightChanged.connect(() => {
            if (d.lineIndex >= 0 && !vp._inLayout)
                vp.relayout();
        });
        vp._pool.push(d);
        return d;
    }

    function _clampY(y) {
        return Math.max(0, Math.min(y, Math.max(0, flick.contentHeight - flick.height)));
    }

    // Read every assigned delegate's height; rows above the viewport that
    // changed move contentY with them. Returns whether anything changed.
    function _measureAll() {
        let changed = false;
        let shift = 0;
        const cy = flick.contentY;
        vp._prefix();
        for (const d of vp._pool) {
            const i = d.lineIndex;
            if (i < 0 || i >= vp._h.length)
                continue;
            const h = d.implicitHeight;
            const old = vp._h[i];
            if (Math.abs(h - old) > 0.01) {
                if (vp.yOf(i) + old <= cy + 0.01)
                    shift += h - old;
                vp._h[i] = h;
                changed = true;
            }
        }
        if (changed)
            vp._preDirty = true;
        if (shift !== 0)
            vp._shift += shift;
        return changed;
    }
    property real _shift: 0

    function relayout() {
        if (vp._inLayout) {
            vp._again = true;
            return;
        }
        vp._inLayout = true;
        try {
            for (let pass = 0; pass < 6; ++pass) {
                vp._again = false;
                vp._shift = 0;
                vp._prefix();
                flick.contentHeight = vp.headSpace + vp._pre[vp._h.length] + vp.bottomPadding;
                const cy = vp._clampY(flick.contentY);
                if (cy !== flick.contentY)
                    flick.contentY = cy;
                const n = vp._h.length;
                let first = n > 0 ? vp.indexAt(cy - vp.overscan) : 0;
                let last = n > 0 ? vp.indexAt(cy + vp.height + vp.overscan) : -1;
                // Free what left the range.
                const map = {};
                for (const d of vp._pool) {
                    const i = d.lineIndex;
                    if (i < 0)
                        continue;
                    if (i >= n || ((i < first || i > last) && i !== vp.pinned))
                        vp._free(d);
                    else
                        map[i] = d;
                }
                vp._byLine = map;
                // Fill what entered it.
                const want = [];
                for (let i = first; i <= last && i >= 0; ++i)
                    if (!map[i])
                        want.push(i);
                if (vp.pinned >= 0 && vp.pinned < n && !map[vp.pinned])
                    want.push(vp.pinned);
                for (const i of want) {
                    const d = vp._take();
                    if (!d)
                        break;
                    d.lineIndex = i;
                    map[i] = d;
                    vp.assigned(d, i);
                    d.visible = true;
                }
                const changed = vp._measureAll();
                if (vp._shift !== 0) {
                    vp._prefix();
                    flick.contentHeight = vp.headSpace + vp._pre[vp._h.length] + vp.bottomPadding;
                    flick.contentY = vp._clampY(flick.contentY + vp._shift);
                }
                // Place.
                vp._prefix();
                for (const d of vp._pool)
                    if (d.lineIndex >= 0)
                        d.y = vp.yOf(d.lineIndex);
                if (!changed && !vp._again)
                    break;
            }
            flick.contentHeight = vp.headSpace + vp._pre[vp._h.length] + vp.bottomPadding;
        } finally {
            vp._inLayout = false;
        }
        vp.laidOut();
    }

    // Scroll the least so [yOf(i) + top, yOf(i) + bottom] is on screen, with
    // `margin` to spare.
    function ensureVisible(i, top, bottom, margin) {
        if (i < 0 || i >= vp.count)
            return;
        const m = margin === undefined ? 12 : margin;
        const y0 = vp.yOf(i) + (top || 0) - m;
        const y1 = vp.yOf(i) + (bottom === undefined ? vp.heightOf(i) : bottom) + m;
        let cy = flick.contentY;
        if (y0 < cy)
            cy = y0;
        else if (y1 > cy + flick.height)
            cy = y1 - flick.height;
        cy = vp._clampY(cy);
        if (cy !== flick.contentY)
            flick.contentY = cy;
    }

    function scrollToTop() {
        flick.contentY = 0;
    }
}
