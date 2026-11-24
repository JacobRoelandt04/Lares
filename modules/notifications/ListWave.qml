pragma ComponentBehavior: Bound

import QtQuick

import "ListWave.js" as Plan

// =============================================================================
// ListWave.qml
//
// docs/contracts/list_animation.md as a component: WHO animates when a list
// expands, collapses or swaps, over rows that are AnimatedListRows. The row
// animates what it is told (rest / entering / leaving / collapsed, staggerIdx,
// startDelayMs); this decides what each row is told, when, and when it is
// retired. The arithmetic is ListWave.js (pure, node-tested); this file keeps
// one RECORD per row it is managing and a sweeper that honours their deadlines.
//
//   expand(rows)            rows (in layout order) that sit at zero height --
//                           create them `rowState: "collapsed"` -- come in:
//                           the ones whose slots will land on screen fly in on
//                           the stagger, the rest are PLACED when the last
//                           flown row has landed (never at the start: a tail
//                           placed early is on screen before the head that
//                           belongs above it, and is then shoved down by it)
//   collapse(rows, done)    rows on screen fly out on the stagger, rows below
//                           the fold are retired in this frame, rows ABOVE the
//                           fold keep their full height until the wave is over
//                           and then go in one step -- every row wholly above
//                           the viewport, the margin does not count at the
//                           top of a collapse. `done()` runs once every
//                           row has been retired -- and never, if an expand
//                           took any of the rows back (the collapse was
//                           reversed). With `follow` and `anchorAbove` on,
//                           its top edge is the follow's LINE (ENDING AT THE
//                           LINE, below), and at the LIST'S END the rows above
//                           the fold that the clamp would pull into view go
//                           in this frame instead (THE LIST'S END, below).
//   swap(outRows, inRows[, done])   a collapse and an expand ON ONE CLOCK: the
//                           new rows' stagger starts with the old rows' (rank
//                           for rank), judged against where the new rows will
//                           land once the old ones have gone -- the collapse
//                           with the line, as collapse() has it. Started a
//                           stagger step later, the old rows would shrink for
//                           a step before anything grew and a list sized by
//                           its content would dip its foot and come back (the
//                           manager's popup: 614 -> 606 -> 614 at the list's
//                           end, 288 -> 256 before growing from a short one);
//                           rank for rank, the list's height moves
//                           only by what the two lists differ.
//   busy                    true while any deadline is pending.
//
// INTERRUPTING. Every row carries its own deadline and the sweeper retires it
// when ITS flight is over (as the row itself shows it: `_flightOver`) and on
// nothing else, so a second wave never touches the first one's rows.
// Reopening a list that is still emptying REWINDS it: every row that has
// already moved comes back, last out first, aimed at the instant the air
// clears. Collapsing a list that is still filling lets the rows in flight land
// first and drops the ones that never started.
//
// REASSESSING. While an expansion's tail is waiting, a scroll (or a viewport
// resize) that brings one of its slots on screen promotes it into the stagger
// after the last scheduled kick, so a row that comes into view before its
// turn flies in rather than popping in when the head lands.
//
// A VIEW THAT GROWS WITH ITS CONTENT (`viewMaxHeight`). A popup's list sized
// min(cap, content) is short when a group opens at its foot and at its cap
// when the rows have landed; every plan is judged at the height the view ENDS
// at (ListWave.js finalViewH), so the follow rides the rows that overflow the
// GROWN view and the rows it shows fly. Judged at the height it has, the
// follow would ride rows that only grow the view -- contentHeight - height
// stays 0 while the view grows, so the clamp would write nothing -- and a list
// opened at the very bottom would not follow at all. So contentY =
// min(the follow's formula, contentHeight - height), which stays
// at the list's end while the view is still growing and takes the formula as
// soon as the view has reached its cap -- both continuous, so no step.
//
// FOLLOWING (`follow`, list_animation.md "Expanding at the very bottom of the
// list"). An expansion whose rows land below the fold scrolls WITH them: the
// view goes down by what the arriving rows need to be seen, whole rows at a
// time, and stops before the next row would take the header they open under
// off the top (`followTopPx`). ONE CLOCK: contentY is written as
// base + sum(by_i * extent_i) over the followed rows -- a function of the
// rows' own extents, rewritten whenever one of them changes -- so the scroll
// has the rows' kick, duration and easing because it IS them; there is no
// animation on contentY. It is clamped to [0, contentHeight - height] here
// (a Flickable clamps only when its CONTENT shrinks; a write past either end
// sticks). A scroll that is not ours (a wheel, a host's reveal) ends it; so
// does the next expand / collapse / swap.
//
// ENDING AT THE LINE (a collapse or a swap, `follow` and `anchorAbove` on).
// What closes up under the leaving rows -- the header being opened, in an
// accordion; the next group, when one is cleared -- ends where the first
// leaving row began, and at the top of the viewport that is under the host's
// top fade. For that collapse the band between the
// viewport's top and the follow's line (`followTopPx`) is above the fold: a
// row wholly above the line is held and goes with the others, measured
// against the line; the row across the line leaves, and the part of it above
// the line comes off contentY AS IT SHRINKS -- the follow's one clock, run
// backwards (`_startLift`) -- so the header ends ON the line and nothing
// steps. The rows above the line glide down by that part meanwhile. At the
// LIST'S END the content can be shorter mid-wave (the old rows taller than the
// new ones they are paired with, rank for rank) and the Flickable clamps the
// view down by the difference: the lift holds contentY on its formula --
// clamped to the content there is -- for the whole collapse, so the view
// comes back up as the new rows grow, on their clock, before the held rows
// go. The line never asks for more scroll than there is (ListWave.js
// roomLine): near the list's top it is lowered until what it takes off
// contentY fits in it, and what closes up ends where the list's own top puts
// it, without a step -- ABOVE the viewport's top when the list's content
// starts above its origin (a first row taller than the scroll then leaves,
// unseen, on the lift's clock instead of being retired off a scroll that
// cannot hold it).
//
// THE LIST'S END (`anchorAbove` on). Where the content below the fold is
// less than a collapse takes away, the Flickable clamps the view to the
// content's end and what is ABOVE the leaving rows comes down into view. A
// row held above the fold would come down with it, in view at full height,
// and go in one frame at the wave's end with what was above it popping in
// there. So the collapse is judged against the viewport the clamp ends at
// (ListWave.js endPull): every held row the pull would bring into view is
// retired in the call's own frame, its height off contentY in that frame
// (_release), and what comes into view as the list shortens is what stays
// above it.
//
// ANCHORING (`anchorAbove`). Rows held above the fold go in one step when
// their wave is over; in that frame contentY loses the height they had above
// the viewport, so nothing on screen moves -- "exactly as if the collapsing
// list had only ever contained what you can see" (Collapsing 2). In an
// accordion the other group is still flying at that moment, which is the
// case rule 4 forbids ("it does it to the rows that are still flying"). The
// row just above the viewport is one of them (no margin at the top of a
// collapse): flown, its height left from above the viewport uncompensated
// and the accordion's new header ended one row above the viewport.
//
// What the host owes it: `view` is the Flickable (a row is on screen when its
// slot intersects [contentY, contentY + height], a row's worth of margin
// either side -- none at the top of a collapse); rows are handed over IN
// LAYOUT ORDER; and from the moment a row is handed over this component owns
// its `rowState`, `staggerIdx`, `startDelayMs`, `staggerMs` and
// `animDuration` (assigned from JS -- any binding the host had on them is
// gone). Rows may be destroyed at any time; their records are dropped. A
// row it has not finished with is still its own even when it reads
// `collapsed` -- a tail waiting to be placed does -- so a host that wants a
// row gone hands it to `collapse` whatever it shows: a hidden row this does
// not manage is left as it is there, so handing every row that should go is
// always safe (a header a wave places after the host has let it go stays:
// the manager's Undo then Clear-all). With `follow` or `anchorAbove`
// on, it also writes the view's contentY (never while nothing of it is
// running).
// =============================================================================
QtObject {
    id: root

    property Flickable view: null
    property int staggerMs: 55
    property int animMs: 240
    // A row's worth of margin either side of the viewport (a collapse has
    // none at the top). -1, the default, is each row's OWN height at rest,
    // which is right for a list whose rows differ (a header, a card with an
    // image, a one-liner). Any other value is px.
    property real marginPx: -1
    // Scroll with an expansion whose rows land below the fold (header).
    property bool follow: true
    // The view y the header an expansion opens under may rise to while the
    // view follows -- and, in a swap, where the header it opens ends (ENDING
    // AT THE LINE). -1, the default, is where the list's own first item
    // rests at contentY 0 -- the content's top inset. The header is the
    // nearest laid-out SIBLING before the first row handed in (the section's
    // header over its rows), or, when it has none -- a section arriving
    // whole, header first -- that row itself.
    property real followTopPx: -1
    // Rows held above the fold take their height off contentY when they go.
    property bool anchorAbove: true
    // The height the view GROWS to with its content: -1, the default, is a
    // view whose height is its own (whatever it is now is what it keeps);
    // >= 0 is a view whose height is min(viewMaxHeight, contentHeight) -- a
    // popup's list sized by its rows up to a cap. Every plan is then judged
    // at the height the view will have when the wave is over (A VIEW THAT
    // GROWS WITH ITS CONTENT, above). The notification manager's is its list
    // cap less the bevel slack: `maxListHeight - 2 * _s`.
    property real viewMaxHeight: -1

    readonly property bool busy: root._busy

    function expand(rows) {
        root._expand(rows || [], 0, false);
    }

    function collapse(rows, done) {
        const list = rows || [];
        root._collapse(list, done || null, root._lineFor(list), 0);
    }

    function swap(outRows, inRows, done) {
        const outs = outRows || [];
        const ins = inRows || [];
        const lift = root._collapse(outs, done || null, root._lineFor(outs.concat(ins)), root._growth(ins));
        root._expand(ins, lift, true);
    }

    // ---- internals ----------------------------------------------------------

    // The follow's line for a collapse of `rows` (ENDING AT THE LINE), or -1
    // when this host has no line (follow or anchorAbove off).
    function _lineFor(rows) {
        const any = rows.find(r => root._alive(r));
        return root.follow && root.anchorAbove && root.view && any ? root._topLine(any) : -1;
    }

    // What a swap's new rows will still add to the content (THE LIST'S END).
    function _growth(rows) {
        let px = 0;
        for (const row of rows)
            if (root._alive(row))
                px += Math.max(0, row._fullHeight - row.implicitHeight);
        return px;
    }

    // `line` >= 0: its top edge at that view y, and the part of the first
    // leaving row above it lifted (ENDING AT THE LINE). `grow`: what the
    // swap's expand will add (THE LIST'S END). Returns the px lifted.
    function _collapse(rows, done, line, grow) {
        const now = Date.now();
        root._endFollow();
        root._planning = true;
        const snap = root._snapshot(rows, now);
        const o = root._opts(now);
        if (line >= 0) {
            o.topLine = line;
            o.lift = true;
        }
        o.grow = grow;
        const plan = Plan.collapsePlan(snap, o);
        const W = root._newWave("collapse", done, plan);
        W.line = plan.line;
        const retired = [];
        for (let i = 0; i < snap.length; i++) {
            const it = snap[i];
            const r = plan.rows[i];
            if (r.act === "keep")
                continue;
            const rec = root._take(it, W);
            switch (r.act) {
            case "leave":
                rec.phase = "out";
                rec.kickAt = r.kickAt;
                rec.doneAt = r.doneAt;
                root._setState(it.row, "leaving", r.rank, r.startDelay);
                break;
            case "hold":
                rec.phase = "held";
                rec.doneAt = r.doneAt;
                break;
            case "retire":
                rec.phase = "held";
                rec.doneAt = r.doneAt;
                retired.push(rec);
                break;
            case "drop":
                rec.phase = "outHidden";
                rec.doneAt = r.doneAt;
                if (it.row.rowState !== "collapsed")
                    root._setState(it.row, "collapsed", 0, 0);
                break;
            case "pendOut":
                rec.pend = "out";
                rec.pendAt = r.pendAt;
                rec.pendRank = r.rank;
                break;
            case "pendHold":
                rec.pend = "hold";
                rec.pendAt = r.pendAt;
                break;
            case "pendDrop":
                rec.pend = "drop";
                break;
            case "cancelPend":
                rec.pend = "";
                break;
            }
        }
        // THE LIST'S END: gone in this frame, anchored -- before the lift
        // reads contentY, which they have just made shorter.
        if (retired.length > 0)
            root._release(retired);
        root._planning = false;
        const lifted = line >= 0 && root.view
            ? root._startLift(plan.lift ? snap[plan.lift.index].row : null, plan.lift ? plan.lift.px : 0, W)
            : 0;
        root._run();
        return lifted;
    }

    property bool _busy: false
    // Set while a plan is measured and applied: laying out the rows can move
    // the view, and a reassess in the middle of a plan would act on the
    // snapshot the plan is still applying.
    property bool _planning: false
    // One record per managed row:
    //   { row, phase, kickAt, doneAt, pend, pendAt, pendRank, wave }
    // phase: "in" | "out" | "tail" | "held" | "shown" | "hidden" | "outGone" |
    // "outHidden" (the first four owe something; ListWave.js has the rest).
    property var _recs: []
    // One per call: { kind, done, end, lastKick, reversed, line }. A wave is
    // over when none of its records owes anything; `line` is the top edge its
    // held rows are measured against when they go (0, or a swap's line).
    property var _waves: []
    // The running follow: { base, rows: [{ row, f, to }], wrote, wave } --
    // contentY is base + sum(f * extent), clamped to the content, each row
    // growing to `to` (1: an arrival the view rides down; 0: a swap's leaving
    // row lifted, ENDING AT THE LINE) -- or null. `wave`: a swap's lift, held
    // until that collapse is over (rows may be none: nothing to lift, only
    // the list's end to hold).
    property var _follow: null
    // Set while this writes contentY, so the view watch can tell our own
    // scroll from anybody else's.
    property bool _writingY: false

    property Timer _sweeper: Timer {
        interval: 16
        repeat: true
        onTriggered: root._sweep()
    }

    property Connections _viewWatch: Connections {
        target: root.view
        ignoreUnknownSignals: true
        function onContentYChanged() {
            if (root._writingY)
                return;
            if (root._follow && !root._viewFixup())
                root._endFollow();
            root._reassess();
        }
        function onHeightChanged() {
            root._applyFollow();
            root._reassess();
        }
        // A positioner lays its rows out in its polish, after the rows'
        // extents moved: the follow is rewritten against the content height
        // the frame will really draw -- and after the Flickable's own fixup,
        // which has just rounded the scroll to a whole pixel (_viewFixup).
        function onContentHeightChanged() {
            root._applyFollow();
        }
    }

    function _opts(now) {
        const v = root.view;
        return {
            now: now,
            // No viewport yet: nothing is off screen because nothing is on it.
            viewTop: v ? 0 : -1e9,
            viewH: v ? v.height : 2e9,
            margin: root.marginPx,
            staggerMs: root.staggerMs,
            animMs: root.animMs,
            anchored: root.anchorAbove && !!v,
            // The scroll above the viewport and the content below the fold
            // (a collapse's line and the list's end).
            room: v ? v.contentY : undefined,
            below: v ? v.contentHeight - v.contentY - v.height : undefined,
            // A view that grows with its content, and the content now
            // (ListWave.js finalViewH).
            viewMax: v ? root.viewMaxHeight : -1,
            content: v ? v.contentHeight : undefined
        };
    }

    // `inSwap`: a swap's second half, started with its collapse (rank for
    // rank). The collapse has just ended any older follow and may have
    // started its own lift (ENDING AT THE LINE), which stays -- even lifting
    // nothing, it holds the list's end -- and `lift`, the px it takes, is
    // where the new rows are judged.
    function _expand(rows, lift, inSwap) {
        const now = Date.now();
        if (!inSwap)
            root._endFollow();
        root._planning = true;
        const snap = root._snapshot(rows, now);
        const o = root._opts(now);
        o.follow = root.follow ? root._followKeep(snap) : null;
        o.lift = lift > 0 ? lift : 0;
        const plan = Plan.expandPlan(snap, o);
        const W = root._newWave("expand", null, plan);
        for (let i = 0; i < snap.length; i++) {
            const it = snap[i];
            const r = plan.rows[i];
            if (r.act === "keep")
                continue;
            const rec = root._take(it, W);
            switch (r.act) {
            case "rest":
                rec.phase = "shown";
                if (it.row.rowState !== "rest")
                    root._setState(it.row, "rest", 0, 0);
                break;
            case "enter":
                rec.phase = "in";
                rec.kickAt = r.kickAt;
                rec.doneAt = r.doneAt;
                root._setState(it.row, "entering", r.rank, r.startDelay);
                break;
            case "pendIn":
                // Still flying out; it turns at its own deadline.
                rec.pend = "in";
                rec.pendAt = r.pendAt;
                rec.pendRank = r.rank;
                break;
            case "tail":
                rec.phase = "tail";
                rec.doneAt = r.doneAt;
                if (it.row.rowState !== "collapsed")
                    root._setState(it.row, "collapsed", 0, 0);
                break;
            case "cancelPend":
                rec.pend = "";
                break;
            }
        }
        root._planning = false;
        root._startFollow(snap, plan.follow);
        root._run();
    }

    // Every managed row plus every row handed in, in layout order, measured
    // AFTER the positioners holding them have laid out: a Column places its
    // children in its polish, so heights changed earlier in this same call
    // (a swap's collapse) are not in `y` until it is forced. Where a row's
    // slot is, see `_slotTop`.
    function _snapshot(rows, now) {
        const list = [];
        for (const row of rows)
            if (root._alive(row) && !list.some(x => x.row === row))
                list.push({ row: row, rec: root._find(row), mine: true });
        for (const rec of root._recs)
            if (!list.some(x => x.row === rec.row) && root._alive(rec.row))
                list.push({ row: rec.row, rec: rec, mine: false });
        root._layOut(list.map(it => it.row));
        const v = root.view;
        for (let i = 0; i < list.length; i++) {
            const it = list[i];
            const rec = it.rec;
            it.seq = i;
            it.top = root._slotTop(it.row, v);
            it.h = it.row.implicitHeight;
            it.full = it.row._fullHeight;
            it.phase = root._phaseOf(rec, it.row, now);
            it.kickAt = rec ? rec.kickAt : 0;
            it.doneAt = rec ? rec.doneAt : 0;
            it.pend = rec ? rec.pend : "";
        }
        list.sort((a, b) => (a.top - b.top) || (a.seq - b.seq));
        return list;
    }

    // Every positioner between these items and the view's content, laid out
    // now, innermost first: a Column places its children in its polish, and a
    // nested one (the manager's rows' Column inside a section inside the
    // sections' Column) hands its new height up only when it has run.
    function _layOut(items) {
        const stop = root.view ? root.view.contentItem : null;
        const found = [];
        for (const item of items) {
            let depth = 0;
            for (let p = item ? item.parent : null; p && p !== stop; p = p.parent) {
                depth++;
                if (typeof p.forceLayout === "function" && !found.some(f => f.p === p))
                    found.push({ p: p, depth: depth });
            }
        }
        found.sort((a, b) => a.depth - b.depth);
        for (const f of found)
            f.p.forceLayout();
    }

    // A ROW AT ZERO HEIGHT IS NOT WHERE ITS `y` SAYS. A positioner (Column)
    // does not lay out a child with no height, so a collapsed row keeps the y
    // of whatever layout it last took part in: every hidden row
    // of a fresh list sits at y 0, and a list collapsed from further down at its
    // old place, which would put a whole expansion "above the fold". Its slot is
    // where the positioner will put it the moment it has height: after the
    // nearest sibling before it that is laid out, one `spacing` on. With none,
    // where the positioner's own content starts -- and a positioner that has
    // no height either (a section arriving whole: its header and rows all
    // zero) is not laid out itself, its y as stale as a row's (0 if it never
    // had height), so its own slot is found the same way. Any other parent
    // (a ListView places zero-height delegates too) is trusted.
    function _slotTop(row, v) {
        const p = row.parent;
        const map = (item, y) => v ? item.mapToItem(v, 0, y).y : item.y + y;
        if (row.height > 0 || !p)
            return map(row, 0);
        // A row inside a row (a bundle's members in the tail of their head's
        // slot): its parent is no positioner, and may itself be at no height,
        // not laid out, its `y` stale -- the slot is where the parent's slot
        // is, plus where the row stands in the parent.
        if (typeof p.forceLayout !== "function")
            return root._slotTop(p, v) + row.y;
        const kids = p.children;
        for (let j = kids.indexOf(row) - 1; j >= 0; j--) {
            const k = kids[j];
            if (k.visible && k.width > 0 && k.height > 0)
                return map(k, k.height) + (p.spacing || 0);
        }
        return root._slotTop(p, v) + (p.topPadding || 0);
    }

    // Waiting, flying or landed is read off the ROW, like the sweeper reads
    // it (`_flightOver`): judged by the wall clock alone, a row whose flight
    // lags would read as landed and be flipped mid-flight -- the one-frame
    // snap to full height the law forbids.
    function _phaseOf(rec, row, now) {
        if (!rec) {
            // Not ours: read what the row shows.
            const st = row.rowState;
            return st === "collapsed" || st === "leaving" ? "hidden" : "shown";
        }
        switch (rec.phase) {
        case "in":
            if (rec.pend === "" && root._flightOver(rec, now))
                return "shown";
            return root._started(rec, now) ? "inAir" : "inWait";
        case "out":
            if (rec.pend === "" && root._flightOver(rec, now))
                return "outGone";
            return root._started(rec, now) ? "outAir" : "outWait";
        default:
            return rec.phase;
        }
    }

    // The row has left its start position (or should long since have).
    function _started(rec, now) {
        if (now >= rec.kickAt + root.animMs)
            return true;
        const row = rec.row;
        if (row.rowState === "entering")
            return row.x > -(row.width + row.offscreenMargin) + 0.5;
        if (row.rowState === "leaving")
            return row.x > 0.5;
        return now >= rec.kickAt;
    }

    function _find(row) {
        for (const rec of root._recs)
            if (rec.row === row)
                return rec;
        return null;
    }

    function _alive(row) {
        return !!row && row.rowState !== undefined;
    }

    function _newWave(kind, done, plan) {
        const W = {
            kind: kind,
            done: done,
            end: plan.end,
            lastKick: plan.lastKick !== undefined ? plan.lastKick : plan.end,
            reversed: false,
            line: 0
        };
        root._waves.push(W);
        return W;
    }

    // A row joins wave W. Taken from a collapse, that collapse is REVERSED:
    // its `done` must not run over rows that are coming back.
    function _take(it, W) {
        let rec = it.rec;
        if (!rec) {
            rec = {
                row: it.row, phase: it.phase === "shown" ? "shown" : "hidden",
                kickAt: 0, doneAt: 0, pend: "", pendAt: 0, pendRank: 0, wave: null
            };
            root._recs.push(rec);
            it.rec = rec;
        }
        if (rec.wave && rec.wave !== W && rec.wave.kind === "collapse" && W.kind === "expand")
            rec.wave.reversed = true;
        rec.wave = W;
        return rec;
    }

    // staggerIdx and startDelayMs BEFORE rowState, always: writing the state
    // fires AnimatedListRow.onRowStateChanged synchronously and that schedules
    // the kick from whatever the two hold at the time.
    function _setState(row, st, rank, delay) {
        row.staggerMs = root.staggerMs;
        row.animDuration = root.animMs;
        row.startDelayMs = delay;
        row.staggerIdx = rank;
        row.rowState = st;
    }

    function _owes(rec) {
        return rec.pend !== "" || rec.phase === "in" || rec.phase === "out"
            || rec.phase === "tail" || rec.phase === "held";
    }

    // A wave's end moved later (a turn landed late, a tail row was promoted):
    // what waits for the end waits for the new one.
    function _raiseEnd(W, t) {
        if (!W || t <= W.end)
            return;
        W.end = t;
        for (const rec of root._recs) {
            if (rec.wave !== W)
                continue;
            if (rec.phase === "tail" || rec.phase === "held")
                rec.doneAt = t;
            else if (rec.pend === "hold")
                rec.pendAt = t;
        }
    }

    function _run() {
        root._busy = true;
        if (!root._sweeper.running)
            root._sweeper.start();
    }

    // A row that has finished the flight it was on and owes another. The
    // turned wave aims at ONE instant (`pendAt`), so what each row waits
    // depends on when its own flight ended -- that is `startDelayMs`.
    function _turn(rec, now) {
        const kind = rec.pend;
        rec.pend = "";
        if (kind === "in" || kind === "out") {
            const delay = Math.max(0, Math.round(rec.pendAt - now));
            rec.phase = kind;
            rec.kickAt = now + Math.max(Plan.MIN_KICK_MS, delay + rec.pendRank * root.staggerMs);
            rec.doneAt = rec.kickAt + root.animMs;
            root._setState(rec.row, kind === "in" ? "entering" : "leaving", rec.pendRank, delay);
            root._raiseEnd(rec.wave, rec.doneAt);
        } else if (kind === "hold") {
            rec.phase = "held";
            rec.doneAt = rec.wave ? Math.max(rec.wave.end, now) : now;
            if (rec.row.rowState !== "rest")
                rec.row.rowState = "rest";
        } else {
            rec.phase = "outHidden";
            rec.doneAt = now;
            rec.row.rowState = "collapsed";
        }
    }

    // TWO CLOCKS, AND THE ROW'S IS THE ONE THAT SAYS IT HAS LANDED. The plan
    // and this sweeper run on the wall clock; a row's kick and flight run on
    // Qt Quick's ANIMATION clock (its Timer and NumberAnimations), which is
    // stepped per frame and runs ahead of the wall or behind it -- offscreen,
    // the first wave of a fresh window lands at 388 ms against a
    // planned 790, and 240 ms flights take 224; a GUI-thread stall (a history
    // save mid-wave) holds it back instead. A sweeper that trusted the wall
    // would retire rows still in the air when the row clock lags, and turn a
    // rewind a tick late when it leads. So a flight is over when the row
    // SHOWS it: within a pixel of where it was going, by when a leaving row has
    // a tenth of a pixel of height left and an entering one is a tenth of a
    // pixel short. A row that never gets there -- resized in flight, its
    // target moved -- is let go one flight after its deadline.
    function _flightOver(rec, now) {
        if (now >= rec.doneAt + root.animMs)
            return true;
        const row = rec.row;
        if (row.rowState === "entering")
            return Math.abs(row.x) < 1;
        if (row.rowState === "leaving")
            return row.x >= row.width + row.offscreenMargin - 1;
        return now >= rec.doneAt;
    }

    // Anything of wave W still flying in `dir` ("in" / "out"), a turn owed
    // included: the tail waits for the head, a held row for the exits.
    function _flying(W, dir) {
        return root._recs.some(rec => rec.wave === W && (rec.phase === dir || rec.pend === dir));
    }

    // THE SWEEPER. It acts on a row only when that row's OWN flight is over,
    // which is what stops a second wave finishing the first one's flights
    // early, and it stops itself the moment nothing is owed.
    function _sweep() {
        const now = Date.now();
        for (const rec of root._recs.slice()) {
            if (!root._alive(rec.row)) {
                root._recs.splice(root._recs.indexOf(rec), 1);
                continue;
            }
            if (rec.pend !== "") {
                if (root._flightOver(rec, now))
                    root._turn(rec, now);
            } else if (rec.phase === "in" && root._flightOver(rec, now)) {
                rec.row.rowState = "rest";
                rec.phase = "shown";
            } else if (rec.phase === "out" && root._flightOver(rec, now)) {
                rec.row.rowState = "collapsed";
                rec.phase = "outGone";
            }
        }
        // What waits for a whole wave goes once the wave's own flights have
        // landed -- not merely when they were due to -- and not before the
        // instant the plan gave it either.
        const going = [];
        for (const rec of root._recs.slice()) {
            if (now < rec.doneAt)
                continue;
            if (rec.phase === "tail" && !root._flying(rec.wave, "in")) {
                rec.row.rowState = "rest";
                rec.phase = "shown";
            } else if (rec.phase === "held" && !root._flying(rec.wave, "out")) {
                going.push(rec);
            }
        }
        if (going.length > 0)
            root._release(going);
        // The follow is over once every row it rides has landed (a lift's
        // row: gone) -- written a last time against the layout of that
        // landing, or the clamp would keep the stale content height's answer
        // (short by the last sliver).
        const F = root._follow;
        if (F && F.rows.every(r => !root._alive(r.row) || root._settled(r)) && root._liftDone(F)) {
            root._layOut(F.rows.filter(r => root._alive(r.row)).map(r => r.row));
            root._applyFollow();
            root._endFollow();
            // At rest on a whole pixel, as the Flickable itself leaves a
            // scroll (a fractional one would raster its text differently
            // each time it is drawn) -- when that stays in range.
            const v = root.view;
            const whole = Math.round(v.contentY);
            if (whole <= Math.max(0, v.contentHeight - v.height))
                root._writeY(whole);
        }
        for (const W of root._waves.slice()) {
            if (!root._waveOver(W))
                continue;
            root._finish(W);
        }
        root._busy = root._waves.length > 0;
        if (!root._busy)
            root._sweeper.stop();
    }

    // Held rows go in one step. Measured BEFORE they go: the part of each
    // above its wave's top edge -- the viewport's top, or a swap's line -- is
    // what contentY loses in the same frame, so what is on screen below that
    // edge stays where it is (a held row the user has scrolled partly into
    // view closes only its visible part). A swap's held rows are wholly above
    // its line when they go, some of them in view under the host's top fade,
    // and what sits above them takes their place there: the lift holds the
    // view on its formula, and where the list's end has clamped it lower
    // instead, the Flickable clamps this write to the end in the same frame.
    // The rows a collapse retires at the LIST'S END go through here in the
    // call's own frame, wholly above its edge, before anything has moved.
    function _release(recs) {
        const v = root.view;
        let above = 0;
        if (root.anchorAbove && v) {
            root._layOut(recs.map(rec => rec.row));
            for (const rec of recs) {
                const edge = rec.wave && rec.wave.line > 0 ? rec.wave.line : 0;
                const y = rec.row.mapToItem(v, 0, 0).y;
                above += Math.max(0, Math.min(rec.row.implicitHeight, edge - y));
            }
        }
        for (const rec of recs) {
            rec.row.rowState = "collapsed";
            rec.phase = "outHidden";
        }
        if (above > 0) {
            if (root._follow)
                root._follow.base -= above;
            root._writeY(Math.max(0, v.contentY - above));
        }
    }

    function _waveOver(W) {
        return !root._recs.some(rec => rec.wave === W && root._owes(rec));
    }

    // A swap's lift lets go once its collapse is over and the view is back
    // on its formula (the list's end no longer clamping it) -- or once every
    // wave is over, when nothing of ours will grow the content again.
    function _liftDone(F) {
        if (!F.wave)
            return true;
        if (root._waves.every(W => root._waveOver(W)))
            return true;
        if (root._waves.indexOf(F.wave) >= 0 && !root._waveOver(F.wave))
            return false;
        let y = F.base;
        for (const r of F.rows)
            y += r.f * root._ext(r.row);
        return Math.abs(root.view.contentY - y) < 0.5;
    }

    function _finish(W) {
        root._waves.splice(root._waves.indexOf(W), 1);
        // Its rows are no longer anybody's: what they show is what they are.
        root._recs = root._recs.filter(rec => rec.wave !== W);
        if (W.kind === "collapse" && !W.reversed && typeof W.done === "function")
            W.done();
    }

    // Rule 4 of expanding: rows that come into view before their turn keep
    // animating. Only a waiting tail is ever promoted, in layout order, one
    // stagger step after the last kick already scheduled.
    function _reassess() {
        const v = root.view;
        if (!v || root._planning)
            return;
        const now = Date.now();
        if (!root._recs.some(rec => rec.phase === "tail"))
            return;
        root._planning = true;
        const snap = root._snapshot([], now);
        const finals = snap.map(it => Plan.finalHeight(it, false));
        const lift = root._liftLeft();
        const tops = Plan.predictTops(snap, finals, root.anchorAbove).map(t => t + lift);
        const band = Plan.bands(snap.map((it, i) => ({ top: tops[i], h: it.full, full: it.full })),
                                0, v.height, root.marginPx);
        for (let i = 0; i < snap.length; i++) {
            const rec = snap[i].rec;
            if (!rec || rec.phase !== "tail" || band[i] === "below")
                continue;
            const W = rec.wave;
            const kick = Math.max(now + Plan.MIN_KICK_MS, W.lastKick + root.staggerMs);
            W.lastKick = kick;
            rec.phase = "in";
            rec.kickAt = kick;
            rec.doneAt = kick + root.animMs;
            root._setState(rec.row, "entering", 0, kick - now);
            root._raiseEnd(W, rec.doneAt);
        }
        root._planning = false;
    }

    // ---- following -------------------------------------------------------------

    // The header an expansion opens under and the line it may rise to, in the
    // viewport's coordinates, for Plan.followShift. The header is the nearest
    // laid-out SIBLING before the first row handed in; with none, that row
    // itself keeps the place (its slot). Never an ancestor's sibling: a
    // section arriving whole hands its header in first, and climbing from it
    // finds the whole previous section -- its top far above the view, no room,
    // no follow (an Undo of a group cleared at the foot).
    function _followKeep(snap) {
        const v = root.view;
        if (!v)
            return null;
        const first = snap.find(it => it.mine);
        if (!first)
            return null;
        const keep = root._keepAbove(first.row);
        return { keepTop: keep ? keep.mapToItem(v, 0, 0).y : first.top, top: root._topLine(first.row) };
    }

    function _keepAbove(row) {
        // A row that opens under something that is not its sibling (a bundle's
        // first member opens under its head, which is its parent's) says so.
        if (row && row.waveKeep)
            return row.waveKeep;
        const p = row ? row.parent : null;
        if (!p)
            return null;
        const kids = p.children;
        for (let j = kids.indexOf(row) - 1; j >= 0; j--) {
            const k = kids[j];
            if (k.visible && k.width > 0 && k.height > 0)
                return k;
        }
        return null;
    }

    // The follow's line in view coordinates: followTopPx, or where the
    // list's own first item rests at contentY 0.
    function _topLine(row) {
        // A row that opens under a CARD, not a header with its gap above it,
        // names its own line (`waveTopPx`, view px; < 0 or absent: the host's).
        if (row && row.waveTopPx !== undefined && row.waveTopPx >= 0)
            return row.waveTopPx;
        if (root.followTopPx >= 0)
            return root.followTopPx;
        const v = root.view;
        for (let a = row; v && a && a.parent; a = a.parent)
            if (a.parent === v.contentItem)
                return a.y;
        return 0;
    }

    // How far a row has grown: its own `_extent`, the clock its height and
    // slide both run on (AnimatedListRow).
    function _ext(row) {
        const e = row ? row._extent : undefined;
        return e === undefined ? 1 : Math.max(0, Math.min(1, e));
    }

    function _startFollow(snap, fol) {
        const v = root.view;
        if (!v || !fol || fol.shift <= 0)
            return;
        const rows = [];
        let base = v.contentY;
        for (let i = 0; i < snap.length; i++) {
            if (fol.by[i] <= 0)
                continue;
            rows.push({ row: snap[i].row, f: fol.by[i], to: 1 });
            base -= fol.by[i] * root._ext(snap[i].row);
        }
        if (rows.length === 0)
            return;
        root._endFollow();
        root._follow = { base: base, rows: rows, wrote: v.contentY };
        for (const r of rows)
            r.row.implicitHeightChanged.connect(root._applyFollow);
        root._applyFollow();
    }

    // A swap's lift (ENDING AT THE LINE): the leaving row across the line
    // takes `px` -- its part above the line -- off contentY as it shrinks,
    // contentY = base + px * extent with base where it ends; never past the
    // list's top. With no such row it only holds the view on `base` for
    // wave W (the list's end). Returns the px it will take.
    function _startLift(row, px, W) {
        const v = root.view;
        const f = root._alive(row) ? Math.min(px, Math.max(0, v.contentY)) : 0;
        const rows = f > 0.01 ? [{ row: row, f: f, to: 0 }] : [];
        root._follow = {
            base: v.contentY - (rows.length > 0 ? f * root._ext(row) : 0),
            rows: rows, wrote: v.contentY, wave: W
        };
        for (const r of rows)
            r.row.implicitHeightChanged.connect(root._applyFollow);
        root._applyFollow();
        return rows.length > 0 ? f : 0;
    }

    // A followed row has got where it was going: grown and at rest, or (a
    // lift's) gone.
    function _settled(r) {
        return r.to === 0 ? root._ext(r.row) <= 0 && r.row.rowState === "collapsed"
                          : root._ext(r.row) >= 1 && r.row.rowState === "rest";
    }

    // What a running lift has still to take off contentY (signed: the list's
    // end may have clamped the view below where the lift ends): every slot
    // will sit that much lower in the viewport when it is done.
    function _liftLeft() {
        const F = root._follow;
        return F && F.wave && root.view ? root.view.contentY - F.base : 0;
    }

    // contentY from the rows' extents, clamped here: a Flickable clamps when
    // its content SHRINKS, but takes a write past either end as given. Called
    // when a followed row's height moves (the rows' own tick), and again
    // when the view's content height or height does (after the positioner
    // has laid that tick out, which is when the clamp's numbers are true).
    function _applyFollow() {
        const F = root._follow;
        const v = root.view;
        if (!F || !v)
            return;
        let y = F.base;
        for (const r of F.rows) {
            if (!root._alive(r.row)) {
                root._endFollow();
                return;
            }
            y += r.f * root._ext(r.row);
        }
        root._writeY(Math.max(0, Math.min(Math.max(0, v.contentHeight - v.height), y)));
    }

    function _writeY(y) {
        const v = root.view;
        if (Math.abs(v.contentY - y) > 1e-6) {
            root._writingY = true;
            v.contentY = y;
            root._writingY = false;
        }
        if (root._follow)
            root._follow.wrote = v.contentY;
    }

    // A contentY change that is not ours but the Flickable's own FIXUP leaves
    // the follow running; any other is somebody scrolling, and ends it. The
    // fixup runs on every content height change (setContentHeight, before it
    // emits contentHeightChanged) and does two things (Qt 6.11):
    // it clamps a scroll the content no longer covers (400 -> 200 when 200 px
    // went), and it ROUNDS a fractional one to a whole pixel (100.4 -> 100,
    // 250.6 -> 251) -- every frame of a follow, which is mid-pixel on most.
    // onContentHeightChanged then writes the exact value back.
    // A clamp may be SMALLER than half a pixel (the content shrinking a
    // fraction a frame at the list's end): it lands on a
    // fractional end and is still a clamp -- read as a scroll, it would end the
    // lift and the view would never come back up.
    function _viewFixup() {
        const v = root.view;
        const F = root._follow;
        const max = Math.max(0, v.contentHeight - v.height);
        if (F.wrote > max - 0.01 && Math.abs(v.contentY - max) < 0.5)
            return true;
        return Math.abs(v.contentY - F.wrote) < 1 && v.contentY === Math.round(v.contentY);
    }

    function _endFollow() {
        const F = root._follow;
        if (!F)
            return;
        root._follow = null;
        for (const r of F.rows) {
            try {
                r.row.implicitHeightChanged.disconnect(root._applyFollow);
            } catch (e) {
                // destroyed with the follow still on it
            }
        }
    }
}
