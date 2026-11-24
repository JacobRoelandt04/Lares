.pragma library

// =============================================================================
// DragIntent.js -- is this drag GROUPING or REORDERING? Decided again every
// frame, never once per drag.
//
// The same gesture must be able to mean either, and the grid has to tell
// which from what the hand is doing now -- like a phone's home screen. So a
// pure state machine, stepped once per frame while a tile
// is carried, over three facts:
//
//   WHERE   each target tile has a MERGE ZONE (its centre: inset 22 % across,
//           18 % down); the rest of the tile and the gutters are REORDER
//           ground -- left of a tile's centre means "before it", right "after".
//   HOW FAST the pointer's speed over the last 80 ms. Grouping is deliberate:
//           it arms only after DWELLING 260 ms in a merge zone at <= 0.35
//           px/ms. Sweeping across a tile never groups.
//   WHAT IS SETTLED  hysteresis everywhere a boundary could flap:
//           * an armed group holds until the pointer leaves an 8 %-inset KEEP
//             rect (bigger than the merge zone) or runs fast (> 0.9 px/ms)
//             for 60 ms;
//           * the gap moves only when the same insertion point has been
//             proposed for 100 ms (a hand passing through a tile's band on
//             its way to another tile's centre must not push that tile
//             away), and never sooner than 90 ms after it last moved;
//           * intent is judged against the layout's TARGET cells, never the
//             animated positions -- a tile sliding under a still pointer is
//             not the pointer moving. When the gap opens before a tile, that
//             tile's target cell moves on and the pointer is over the gap,
//             which owns no intent, so the gap stays: stable by construction.
//
// In a sort that is not Custom a drag can only group: reorder ground does
// nothing. A group may be dropped on a group (nesting is
// allowed) but never on itself.
//
// Exit zones (a nested grid's header band, outside the grid) arm an EXIT
// after 350 ms: the host swaps to the parent folder and the drag goes on.
// =============================================================================

var MERGE_X = 0.22;
var MERGE_Y = 0.18;
var KEEP = 0.08;
var ARM_MS = 260;
var ARM_SPEED = 0.35;
var BREAK_SPEED = 0.9;
var BREAK_MS = 60;
var GAP_MS = 90;
var REORDER_MS = 100;
var EXIT_MS = 350;
var WINDOW_MS = 80;

function create(gap) {
    return {
        intent: "none",       // none | group | reorder | exit
        target: null,         // key of the tile a group would form on
        gap: gap,             // insertion index in the order WITHOUT the dragged item
        armKey: null,
        armSince: 0,
        fastSince: -1,
        lastGapMove: -1e9,
        proposal: -1,
        proposalSince: 0,
        exitSince: -1,
        samples: [],
        speed: 0,
        transitions: 0
    };
}

function _inside(p, r, fx, fy) {
    var ix = r.w * (fx || 0), iy = r.h * (fy === undefined ? (fx || 0) : fy);
    return p.x >= r.x + ix && p.x < r.x + r.w - ix && p.y >= r.y + iy && p.y < r.y + r.h - iy;
}

function _speed(st, now, p) {
    st.samples.push({ t: now, x: p.x, y: p.y });
    while (st.samples.length > 2 && now - st.samples[0].t > WINDOW_MS)
        st.samples.shift();
    var a = st.samples[0], b = st.samples[st.samples.length - 1];
    var dt = b.t - a.t;
    st.speed = dt > 0 ? Math.sqrt((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)) / dt : 0;
    return st.speed;
}

function _set(st, intent, target) {
    if (st.intent !== intent || st.target !== target)
        st.transitions++;
    st.intent = intent;
    st.target = target;
}

// One frame.
//   p      pointer, grid content coordinates
//   cells  [{key, pos, x, y, w, h, isGroup}] -- the TARGET cells of the items
//          (pos: index in the order without the dragged item); the + tile
//          and the gap are not in it
//   o      { now, customSort, dragged: {key, isGroup, descendants: {key:1}},
//            exitRects: [{x,y,w,h}] }
function step(st, p, cells, o) {
    var now = o.now;
    var speed = _speed(st, now, p);
    if (speed > BREAK_SPEED) {
        if (st.fastSince < 0)
            st.fastSince = now;
    } else {
        st.fastSince = -1;
    }
    var fastLong = st.fastSince >= 0 && now - st.fastSince >= BREAK_MS;

    // Exit zones first: they sit outside the tiles.
    var inExit = false;
    for (var e = 0; o.exitRects && e < o.exitRects.length; e++)
        if (_inside(p, o.exitRects[e], 0))
            inExit = true;
    if (inExit) {
        if (st.exitSince < 0)
            st.exitSince = now;
        if (now - st.exitSince >= EXIT_MS)
            _set(st, "exit", null);
        st.armKey = null;
        return st;
    }
    st.exitSince = -1;
    if (st.intent === "exit")
        _set(st, "none", null);

    var hit = null;
    for (var i = 0; i < cells.length; i++)
        if (_inside(p, cells[i], 0)) {
            hit = cells[i];
            break;
        }

    // An armed group holds until the pointer leaves its keep rect or runs.
    if (st.intent === "group") {
        var t = null;
        for (var k = 0; k < cells.length; k++)
            if (cells[k].key === st.target)
                t = cells[k];
        if (t && _inside(p, t, KEEP) && !fastLong)
            return st;
        _set(st, "none", null);
        st.armKey = null;
    }

    var canGroup = hit && hit.key !== o.dragged.key && !(o.dragged.descendants && o.dragged.descendants[hit.key]);
    if (hit && canGroup && _inside(p, hit, MERGE_X, MERGE_Y)) {
        // In a merge zone: only grouping can happen here.
        if (speed <= ARM_SPEED) {
            if (st.armKey !== hit.key) {
                st.armKey = hit.key;
                st.armSince = now;
            } else if (now - st.armSince >= ARM_MS) {
                _set(st, "group", hit.key);
            }
        } else {
            st.armKey = hit.key;
            st.armSince = now;
        }
        return st;
    }
    st.armKey = null;

    if (!o.customSort) {
        if (st.intent === "reorder")
            _set(st, "none", null);
        return st;
    }
    // Reorder ground: over a tile outside its merge zone. Over the gap or a
    // gutter nothing changes.
    if (hit) {
        var before = p.x < hit.x + hit.w / 2;
        var proposed = before ? hit.pos : hit.pos + 1;
        if (proposed !== st.proposal) {
            st.proposal = proposed;
            st.proposalSince = now;
        }
        if (proposed !== st.gap && now - st.proposalSince >= REORDER_MS && now - st.lastGapMove >= GAP_MS) {
            st.gap = proposed;
            st.lastGapMove = now;
            st.transitions++;
        }
        if (st.intent !== "reorder")
            _set(st, "reorder", null);
    } else {
        st.proposal = -1;
    }
    return st;
}
