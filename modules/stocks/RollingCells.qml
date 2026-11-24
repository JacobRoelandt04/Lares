pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"

// =============================================================================
// RollingCells.qml -- N cells side by side, rolling through a longer list.
//
//   RollingCells {
//       items: service.indices                 // FACTS, never colours
//       override: hovered ? service.moversOrder : null
//       delegate: Item { required property var item; required property int cell ... }
//   }
//
// The stocks popup's index strip: three cells showing three of the indices,
// the whole row advancing to the next three every `cycleMs`, each cell a
// `staggerMs` after the one to its left. Cell c shows item (offset + c) mod n,
// and a cycle adds `count` to the offset, so every item gets its turn.
//
// OVERRIDE. An array of item indices; while it is non-null cell c shows
// `items[override[c]]` (a cell past the array's end keeps what it shows) and
// NOTHING cycles -- the strip holds. Setting it rolls every cell that shows
// something else, staggered, within one roll (a roll already running lands
// first and the cell rolls again at once). Clearing it rolls the cells back to
// the page they were on and restarts the cycle from there.
//
// THE POOL IS FIXED: two instances of `delegate` per cell, created once when
// the component (or `count`, or `delegate`) is set up, and never again. A roll
// only re-points the idle one's `item` and moves the two. An items array
// replaced whole with fresh facts (a price tick) re-points both in place --
// an instant text swap, no roll.
//
// A ROLL IS PRESENCE, NOT A CROSSFADE (CLAUDE.md motion rules): the shown
// instance rises and fades out over the first half of the cell's clock, the
// next one rises into place and fades in over the second half, so the two are
// never on screen together. Opacity is tied to displacement -- 1 at rest, 0 at
// `rollDistance` -- and `rollDistance` is by default the free room between the
// delegate's content (its direct children) and the cell's top or bottom edge,
// whichever is less: the content reaches the edge at the moment it is gone.
// Nothing is clipped: a clip on a carved cell's edge shears its bevel, and a
// hard cut is what the rule forbids. A delegate whose content fills its cell
// gets 0 -- no travel, a plain presence fade out and in.
//
// ONE CLOCK PER CELL: `phase` 0 -> 1, eased once; both instances' position
// and opacity are functions of it.
//
// HELD STILL while `paused` or `Theme.crossfading`: a theme crossfade is a
// still picture of the frame before, and anything moving under it is a second
// copy of itself (CLAUDE.md). A roll in flight freezes where it is and resumes;
// the cycle waits and starts over when the hold ends.
//
// Sizing: cells split the width (whole-pixel edges, `spacing` between them);
// each delegate is given its cell's full size. implicitHeight is the tallest
// delegate's implicitHeight, implicitWidth `count` of the widest plus the gaps.
// =============================================================================
Item {
    id: root

    // ---- Contract --------------------------------------------------------
    property int count: 3
    property var items: []
    property Component delegate: null
    property int cycleMs: 4000
    property int rollMs: 420
    property int staggerMs: 90
    property var override: null
    property bool paused: false

    property real spacing: 0
    // How far an instance travels as it leaves or arrives; its opacity is 0
    // there. By default the room its content has to the cell's edge.
    property real rollDistance: root._freeRoom
    property int rollEasing: Easing.InOutCubic

    // The item index each cell's SHOWN instance holds (-1 = none): what the
    // strip says right now, for a host (a click on cell c) or a probe.
    readonly property var shownIndices: root._shown
    // A roll scheduled or running on any cell, the stagger's wait included.
    readonly property bool rolling: root._busy > 0

    signal rollStarted(int cell, int fromIndex, int toIndex)
    signal rollFinished(int cell)

    // ---- State -----------------------------------------------------------
    readonly property int _n: root.items ? root.items.length : 0
    readonly property bool _frozen: root.paused || Theme.crossfading
    property int _offset: 0
    property var _shown: []
    property int _busy: 0
    // The pool, [cell][slot] -> delegate instance. Filled once per build.
    property var _pool: []

    // The least room, over the pool, between a delegate's content and the top
    // or bottom of its cell (whole pixels, down).
    readonly property real _freeRoom: {
        const p = root._pool;
        let m = Infinity;
        for (let c = 0; c < p.length; c++)
            for (let s = 0; s < p[c].length; s++) {
                const o = p[c][s];
                const b = root.contentBox(o);
                if (b)
                    m = Math.min(m, b.top, o.height - b.bottom);
            }
        return isFinite(m) ? Math.max(0, Math.floor(m)) : 0;
    }
    // The vertical extent of a delegate's visible direct children, or null.
    // Read child by child rather than through `childrenRect`, which is
    // computed lazily on read and signals its own change inside the binding
    // that reads it (a binding loop).
    function contentBox(o) {
        let top = Infinity, bottom = -Infinity;
        const ch = o.children;
        for (let i = 0; i < ch.length; i++) {
            const k = ch[i];
            if (!k.visible || k.height <= 0)
                continue;
            top = Math.min(top, k.y);
            bottom = Math.max(bottom, k.y + k.height);
        }
        return isFinite(top) ? { top: top, bottom: bottom } : null;
    }

    implicitHeight: {
        let h = 0;
        const p = root._pool;
        for (let c = 0; c < p.length; c++)
            for (let s = 0; s < p[c].length; s++)
                h = Math.max(h, p[c][s].implicitHeight);
        return Math.ceil(h);
    }
    implicitWidth: {
        let w = 0;
        const p = root._pool;
        for (let c = 0; c < p.length; c++)
            for (let s = 0; s < p[c].length; s++)
                w = Math.max(w, p[c][s].implicitWidth);
        return Math.ceil(w * root.count + root.spacing * Math.max(0, root.count - 1));
    }

    // What cell c should show now.
    function _desired(c) {
        const n = root._n;
        if (n === 0 || c >= n)
            return -1;
        const o = root.override;
        if (o) {
            if (c < o.length && o[c] >= 0 && o[c] < n)
                return o[c];
            return root._cellAt(c).shownIndex;       // held as it is
        }
        return (root._offset + c) % n;
    }

    function _cellAt(c) {
        return cells.itemAt(c);
    }

    function _publishShown() {
        const a = [];
        for (let c = 0; c < root.count; c++) {
            const cell = root._cellAt(c);
            a.push(cell ? cell.shownIndex : -1);
        }
        root._shown = a;
    }

    // Start a roll on every cell whose shown item is not the one it should
    // show, the k-th such cell `k * staggerMs` after the first.
    function _sync() {
        if (root._frozen || root._pool.length !== root.count)
            return;
        let k = 0;
        for (let c = 0; c < root.count; c++) {
            const cell = root._cellAt(c);
            if (!cell || cell.busy)
                continue;
            const want = root._desired(c);
            if (want === cell.shownIndex)
                continue;
            cell.rollTo(want, k * root.staggerMs);
            k++;
        }
    }

    function _advance() {
        const n = root._n;
        if (n <= root.count)
            return;
        root._offset = (root._offset + root.count) % n;
        root._sync();
    }

    // ---- The pool ----------------------------------------------------------
    function _destroyPool() {
        const p = root._pool;
        for (let c = 0; c < p.length; c++)
            for (let s = 0; s < p[c].length; s++)
                p[c][s].destroy();
        root._pool = [];
    }

    function _build() {
        root._destroyPool();
        if (!root.delegate || cells.count !== root.count)
            return;
        const pool = [];
        for (let c = 0; c < root.count; c++) {
            const cell = root._cellAt(c);
            cell.reset(root._desired(c));
            const pair = [];
            for (let s = 0; s < 2; s++) {
                const holder = cell.slotAt(s);
                const obj = root.delegate.createObject(holder, {
                    item: holder.itemData,
                    cell: c,
                    width: holder.width,
                    height: holder.height
                });
                if (!obj) {
                    console.warn("RollingCells: the delegate could not be created");
                    continue;
                }
                obj.item = Qt.binding(() => holder.itemData);
                obj.width = Qt.binding(() => holder.width);
                obj.height = Qt.binding(() => holder.height);
                pair.push(obj);
            }
            pool.push(pair);
        }
        root._pool = pool;
        root._busy = 0;                  // every cell was reset to rest
        root._publishShown();
        root._armCycle();
    }

    property bool _completed: false
    Component.onCompleted: {
        root._completed = true;
        root._build();
    }
    onDelegateChanged: if (root._completed) root._build()

    onItemsChanged: {
        // A shorter list can leave an offset past its end.
        if (root._n > 0 && root._offset >= root._n)
            root._offset = 0;
        root._sync();
        root._publishShown();
        root._armCycle();
    }
    onOverrideChanged: {
        root._armCycle();
        root._sync();
    }
    on_FrozenChanged: {
        root._armCycle();
        root._sync();
    }
    onCycleMsChanged: root._armCycle()

    // The cycle starts over from now whenever it may run again: after a hold,
    // an override, a new list. Armed by hand -- never a binding on `running`
    // that a restart() would have to write through.
    function _armCycle() {
        cycle.stop();
        if (!root._frozen && !root.override && root._n > root.count
                && root._pool.length === root.count)
            cycle.start();
    }
    Timer {
        id: cycle
        interval: root.cycleMs
        repeat: true
        onTriggered: root._advance()
    }

    // ---- Cells -----------------------------------------------------------
    Repeater {
        id: cells
        model: root.count
        onCountChanged: if (root._completed && cells.count === root.count) Qt.callLater(root._build)

        delegate: Item {
            id: cell
            objectName: "rollCell"
            required property int index

            readonly property real _cw: (root.width - root.spacing * Math.max(0, root.count - 1)) / Math.max(1, root.count)
            x: Math.round(cell.index * (cell._cw + root.spacing))
            y: 0
            width: Math.round((cell.index + 1) * (cell._cw + root.spacing) - root.spacing) - cell.x
            height: root.height

            // Which slot is shown (0 | 1), the item each slot holds, and the
            // cell's one clock.
            property int front: 0
            property int shownIndex: -1
            property int nextIndex: -1
            property real phase: 0
            readonly property bool busy: rollAnim.running
            onBusyChanged: root._busy += cell.busy ? 1 : -1
            property int _delay: 0

            function slotAt(s) {
                return slots.itemAt(s);
            }
            function reset(i) {
                rollAnim.stop();
                cell.phase = 0;
                cell.front = 0;
                cell.shownIndex = i;
                cell.nextIndex = i;
            }
            function rollTo(i, delay) {
                cell.nextIndex = i;          // the idle slot's words, while it is invisible
                cell._delay = delay;
                cell.phase = 0;
                rollAnim.restart();
            }
            function _begin() {
                root.rollStarted(cell.index, cell.shownIndex, cell.nextIndex);
            }
            // In this order, so no slot ever holds a stale index: the words
            // land on the (invisible) outgoing slot first, then the slots
            // trade places, then the clock goes back to rest.
            function _land() {
                cell.shownIndex = cell.nextIndex;
                cell.front = 1 - cell.front;
                cell.phase = 0;
                root._publishShown();
                root.rollFinished(cell.index);
                // What it should show may have changed while it rolled.
                const want = root._desired(cell.index);
                if (want !== cell.shownIndex && !root._frozen)
                    cell.rollTo(want, 0);
            }

            SequentialAnimation {
                id: rollAnim
                paused: root._frozen && rollAnim.running
                PauseAnimation { duration: cell._delay }
                ScriptAction { script: cell._begin() }
                NumberAnimation {
                    target: cell
                    property: "phase"
                    from: 0
                    to: 1
                    duration: root.rollMs
                    easing.type: root.rollEasing
                }
                // Landing in onFinished, not a trailing ScriptAction: a
                // re-roll restarts this animation, which it must not do from
                // inside itself.
                onFinished: cell._land()
            }

            Repeater {
                id: slots
                model: 2
                delegate: Item {
                    id: slot
                    objectName: "rollSlot"
                    required property int index
                    readonly property int which: slot.index
                    readonly property bool isFront: cell.front === slot.which
                    readonly property int itemIndex: slot.isFront ? cell.shownIndex : cell.nextIndex
                    readonly property var itemData: slot.itemIndex >= 0 && slot.itemIndex < root._n
                                                    ? root.items[slot.itemIndex] : null
                    // The shown slot leaves over the first half of the clock, the
                    // other arrives over the second; each one's opacity is 1 at
                    // rest and 0 at `rollDistance` from it.
                    readonly property real _t: slot.isFront
                                               ? -Math.min(1, cell.phase * 2)
                                               : 1 - Math.max(0, cell.phase * 2 - 1)
                    x: 0
                    y: slot._t * root.rollDistance
                    width: cell.width
                    height: cell.height
                    opacity: 1 - Math.abs(slot._t)
                    visible: slot.opacity > 0 && slot.itemData !== null
                    enabled: slot.isFront ? cell.phase < 0.5 : cell.phase >= 0.5
                    z: slot.isFront ? 0 : 1
                }
            }
        }
    }
}
