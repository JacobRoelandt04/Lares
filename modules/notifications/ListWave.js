.pragma library
// =============================================================================
// ListWave.js -- the planning half of ListWave.qml, pure: no Qt, no items.
// docs/contracts/list_animation.md is
// the specification; this file is its arithmetic.
//
// ListWave.qml takes a snapshot of every row it is asked about and every row
// it is still managing -- one ENTRY per row, in layout order -- hands it to a
// plan, and applies the plan's per-row ACT. Nothing here reads a clock: `now`
// comes in with the options, so a plan is the same answer every time.
//
// AN ENTRY
//   { mine    true when the row is one this call was handed
//     phase   what the row is doing now (below)
//     top     the slot's top in the VIEWPORT's coordinates (0 = the fold's top)
//     h       its height now
//     full    its height at rest
//     kickAt  when its current flight starts (ms), 0 if none
//     doneAt  when its current flight ends / its deadline (ms)
//     pend    "" or the turn it owes at doneAt: "in" | "out" | "hold" | "drop" }
//
// PHASES
//   shown      at rest, full height, owed nothing
//   hidden     zero height, owed nothing
//   inWait     entering, its kick has not come (off-screen left, flat)
//   inAir      entering, kicked, not landed
//   tail       zero height, PLACED when its wave's head has landed
//   outWait    leaving, its kick has not come (still standing, full height)
//   outAir     leaving, kicked, not landed
//   outGone    has left, and the collapse it left in is still running
//   outHidden  retired at once (below the fold), its collapse still running
//   held       above the fold: full height until its collapse is over
//
// The rules everything here serves (list_animation.md):
//   * ONLY WHAT IS ON SCREEN ANIMATES. A slot intersecting the viewport, a
//     row's worth of margin either side, flies on the stagger; everything past
//     the fold is placed or retired, never flown. A collapse has no margin at
//     the TOP: a row wholly above the viewport is held (collapsePlan).
//   * THE TAIL WAITS FOR THE HEAD. Placed rows take their height at the
//     wave's END -- when the last flown row has landed -- never at its start.
//   * NO WAVE TOUCHES ANOTHER'S ROWS. A row owned by a running flight keeps
//     its deadline; a turn-around is a PEND the row takes at its own
//     deadline, and the whole turned wave aims at ONE instant (`start`).
//   * AN EXPANSION AT THE FOOT FOLLOWS ITS ROWS ("Expanding at the very bottom
//     of the list"): the view scrolls with the arriving rows, whole rows at a
//     time, and stops before the next row would take the opened group's
//     header off the top (`followShift`). Judged against the viewport the
//     follow ends at, so the rows it brings into view fly and the rest wait.
//   * CONTENT ABOVE THE FOLD THAT GOES IN ONE STEP MOVES NOTHING ON SCREEN
//     (`anchored`): ListWave takes the same height off contentY in that frame,
//     so a row held above the fold is judged, while it waits, as the space it
//     will NOT take out from under the rows below it.
//   * A COLLAPSE (a swap's too) ENDS WHAT CLOSES UP UNDER IT AT THE FOLLOW'S
//     LINE, not under the top fade (`topLine` / `lift` in collapsePlan, `lift`
//     in expandPlan): the band between the viewport's top and the line is
//     above the fold for that collapse, and the part of the first leaving row
//     above the line is taken off the scroll as the row shrinks. Never more
//     than the scroll there is (`room`, `roomLine`).
//   * AT THE LIST'S END A COLLAPSE PULLS WHAT IS ABOVE IT DOWN (`below`,
//     `grow`, `anchored` in collapsePlan): judged against the viewport the
//     clamp ends at, a row the pull would bring into view is RETIRED in this
//     frame -- off contentY, so nothing on screen moves -- and what comes
//     into view as the list shortens is what stays above it; nothing pops in
//     at the top when a held row would have gone.
//   * A VIEWPORT THAT GROWS WITH ITS CONTENT IS JUDGED AT THE HEIGHT IT ENDS
//     AT (`viewMax`, `content` in expandPlan, `finalViewH`): a popup's list
//     sized min(cap, content) is short when an expansion starts and at its
//     cap when it ends, and the rows the follow rides are the ones that
//     overflow THAT fold.
// =============================================================================

// AnimatedListRow's own floor: a kick is never sooner than one frame.
var MIN_KICK_MS = 16;

// The head start a row is handed (AnimatedListRow.startDelayMs): what is left
// until the wave's shared instant, from the moment the row is set.
function startDelayOf(startMs, fromMs) {
    return Math.max(0, Math.round(startMs - fromMs));
}

// When a row set at `fromMs` with this rank really starts to move -- the
// row's own formula, max(16, startDelayMs + staggerIdx * staggerMs).
function kickAt(startMs, fromMs, rank, staggerMs) {
    return fromMs + Math.max(MIN_KICK_MS, startDelayOf(startMs, fromMs) + rank * staggerMs);
}

// WHICH BAND OF THE VIEWPORT EACH SLOT IS IN (list_animation.md, "What on
// screen means"): "on" when [top, top + h] intersects [viewTop, viewTop +
// viewH] widened by `margin` either side, "above" / "below" otherwise.
// `margin` -1 is each slot's OWN full height (a row's worth, in a list whose
// rows differ); anything else is px, clamped at 0. `topMargin`, when given,
// is the margin at the viewport's TOP edge instead (same units): a collapse
// passes 0.
function bands(slots, viewTop, viewH, margin, topMargin) {
    var out = [];
    for (var i = 0; i < slots.length; i++) {
        var s = slots[i];
        var own = s.full !== undefined ? s.full : s.h;
        var m = margin === -1 ? own : Math.max(0, margin);
        var mt = topMargin === undefined ? m : (topMargin === -1 ? own : Math.max(0, topMargin));
        if (s.top + s.h <= viewTop - mt)
            out.push("above");
        else if (s.top >= viewTop + viewH + m)
            out.push("below");
        else
            out.push("on");
    }
    return out;
}

// The height a row will SETTLE at once every running flight is over. A row
// this call expands settles full; otherwise the phase (and a pending turn)
// says. This is what lets an expansion that starts while another list is
// leaving above it judge its slots where they will land, not where they are.
function finalHeight(e, mine) {
    if (mine)
        return e.full;
    if (e.pend === "in")
        return e.full;
    if (e.pend)
        return 0;               // out, hold, drop: all end at zero
    switch (e.phase) {
    case "shown":
        return e.h;
    case "inWait":
    case "inAir":
    case "tail":
        return e.full;
    default:
        return 0;               // hidden, and every phase of a departure
    }
}

// Each entry's top once the rows above it have settled: its top now, moved by
// what every entry ABOVE it will still gain or lose. `entries` are in layout
// order; anything between them that no entry describes is assumed to hold.
//
// `anchored` (ListWave's `anchorAbove`): a row HELD above the fold goes in one
// step with contentY taking the same height off in that frame, so in the
// viewport's coordinates it moves nothing below it. It still counts what it
// has to GROW first (an arrival in the air that will be held when it lands).
function predictTops(entries, finals, anchored) {
    var out = [];
    var shift = 0;
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        out.push(e.top + shift);
        if (anchored && (e.phase === "held" || e.pend === "hold"))
            shift += Math.max(0, e.full - e.h);
        else
            shift += finals[i] - e.h;
    }
    return out;
}

// A row the follow may ride: one of this call's, at zero height now and
// growing from here to full (hidden, retired, or gone and coming back) -- a
// row still flying out first would drag the view back up with it.
function followable(e) {
    return e.mine && !e.pend && (e.phase === "hidden" || e.phase === "outHidden" || e.phase === "outGone");
}

// ---------------------------------------------------------------------------
// THE VIEW THE WAVE ENDS WITH (list_animation.md, "Expanding at the very
// bottom of the list": a view that grows)
//
// A host whose viewport is sized by its content up to a cap -- the
// notification manager's list is min(cap, content) -- passes the cap as
// `o.viewMax` and the content's height now as `o.content`. Such a view is
// SHORT when an expansion starts and at its cap when it ends, and judged at
// the height it has now, a plan would follow rows that only grow the view
// (the clamp, contentHeight - height, stays 0 while the view grows with the
// content) and place as tail rows that the grown view shows: a list
// opened at the very bottom would follow nothing. So the fold is
// the one the view ENDS at: the content once every entry has settled (the
// content now, moved by what each entry will still gain or lose; a held row
// goes, anchored or not, so it counts as gone) and never more than the cap.
// A positioner's `spacing` between rows that appear or go is not counted:
// such a host carries its gaps inside its rows (the manager does).
// Without `viewMax` (-1, undefined) the view keeps the height it has.
// ---------------------------------------------------------------------------
function finalViewH(entries, finals, o) {
    if (!(o.viewMax >= 0) || o.content === undefined)
        return o.viewH;
    var c = o.content;
    for (var i = 0; i < entries.length; i++)
        c += finals[i] - entries[i].h;
    return Math.max(0, Math.min(o.viewMax, c));
}

// ---------------------------------------------------------------------------
// FOLLOW (list_animation.md, "Expanding at the very bottom of the list")
//
//   "It should follow them to before the point where with the next follow the
//    header would go partially off-screen at the top."
//
// o.follow = { keepTop, top }: keepTop is the top of the item the rows open
// under (the group's header) in the viewport's coordinates NOW; `top` is the
// line it may rise to. `tops` are predictTops' answer for `entries`; `viewH`
// the height the view ends at (finalViewH), o.viewH when not given.
//
// A followable row i needs the view `need_i = bottom_i - fold` further down to
// be seen whole (0 if it already is). The header rises by what the view
// scrolls, so the room is its predicted top less `top`, and the follow takes
// the deepest row whose need fits: WHOLE ROWS, the next one's need would take
// the header off. `by[i]` is what row i adds to the scroll as it grows from 0
// to full -- ListWave writes contentY = base + sum(by[i] * extent_i), one
// clock with the rows -- so the increments sum to `shift` exactly.
// ---------------------------------------------------------------------------
function followShift(entries, tops, o, viewH) {
    var by = [];
    var i;
    for (i = 0; i < entries.length; i++)
        by.push(0);
    var out = { shift: 0, by: by };
    if (!o.follow)
        return out;
    var m = -1;
    for (i = 0; i < entries.length && m < 0; i++)
        if (entries[i].mine)
            m = i;
    if (m < 0)
        return out;
    // Nothing sits between the header and the first row it opens over, so
    // it moves by what that row's slot moves.
    var room = o.follow.keepTop + (tops[m] - entries[m].top) - o.follow.top;
    var fold = o.viewTop + (viewH === undefined ? o.viewH : viewH);
    var need = [];
    var shift = 0;
    for (i = 0; i < entries.length; i++) {
        var n = followable(entries[i]) ? Math.max(0, tops[i] + entries[i].full - fold) : -1;
        need.push(n);
        if (n >= 0 && n <= room + 1e-6 && n > shift)
            shift = n;
    }
    var prev = 0;
    for (i = 0; i < entries.length; i++) {
        if (need[i] < 0)
            continue;
        var c = Math.min(need[i], shift);
        if (c > prev) {
            by[i] = c - prev;
            prev = c;
        }
    }
    out.shift = shift;
    return out;
}

function _row() {
    return { act: "keep", rank: -1, kickAt: 0, doneAt: 0, startDelay: 0, pendAt: 0 };
}

// ---------------------------------------------------------------------------
// EXPAND
//
// o = { now, viewTop, viewH, margin, staggerMs, animMs[, anchored,
//       follow, lift, viewMax, content] }
//     The wave starts now -- a swap's second half too, rank for rank with
//     its collapse (list_animation.md, Swapping 2) -- or once the rows it
//     rewinds that are still flying out have landed. anchored / follow: see
//     predictTops and followShift; without them the plan is the one without
//     either. lift: the px the swap's collapse is taking off contentY
//     (collapsePlan) -- every slot will sit that much lower in the viewport,
//     so the new rows are judged there, and the header's room to follow
//     shrinks by it.
//     viewMax / content: a view that grows with its content (finalViewH).
//
// The plan's `follow` is followShift's answer; every band is judged against
// the viewport the follow ENDS at ([viewTop + shift, ... + viewH], viewH the
// height the view ends at: `viewH` in the plan).
//
// Acts, per entry:
//   keep        not this call's row, or one it must not touch: already shown,
//               or arriving in an earlier wave (inWait / inAir / tail)
//   rest        a departure that had not started (outWait) or a row held
//               above the fold: it never moved, it simply stays
//   enter       fly in: rank, startDelay, kickAt, doneAt
//   pendIn      the REWIND of a row still in the air: it lands first, then
//               turns at its own deadline and aims at `start` with its rank
//   tail        placed (rowState rest) at `end`, when the head has landed
//   cancelPend  a row still arriving with an exit pending: the exit is off
//
// THE REWIND (list_animation.md, "Interrupting"). Every row of a departure
// that has already MOVED -- in the air or gone -- comes back, last out first:
// ranked by its kick, latest first. The returned wave waits for the air to
// clear (`start` = the last in-air landing) and every row aims at that one
// instant with its own rank; the ordinary entrance continues after it with
// the next ranks, and everything past the fold is the tail.
// ---------------------------------------------------------------------------
function expandPlan(entries, o) {
    var now = o.now;
    var S = o.staggerMs;
    var A = o.animMs;
    var i;
    var finals = [];
    for (i = 0; i < entries.length; i++)
        finals.push(finalHeight(entries[i], entries[i].mine));
    var tops = predictTops(entries, finals, !!o.anchored);
    if (o.lift > 0)
        for (i = 0; i < tops.length; i++)
            tops[i] += o.lift;
    var viewH = finalViewH(entries, finals, o);
    var follow = followShift(entries, tops, o, viewH);
    var slots = [];
    for (i = 0; i < entries.length; i++)
        slots.push({ top: tops[i], h: entries[i].full, full: entries[i].full });
    var band = bands(slots, o.viewTop + follow.shift, viewH, o.margin);
    var rows = [];
    for (i = 0; i < entries.length; i++)
        rows.push(_row());

    var start = now;
    var rewind = [];
    for (i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (!e.mine || e.pend)
            continue;
        if (e.phase === "outAir" || e.phase === "outGone") {
            rewind.push(i);
            if (e.phase === "outAir" && e.doneAt > start)
                start = e.doneAt;
        }
    }
    // Last out, first back: the latest kick first; a tie (one block) by depth.
    rewind.sort(function (a, b) {
        return (entries[b].kickAt - entries[a].kickAt) || (b - a);
    });

    var rank = 0;
    var end = start;
    var lastKick = start - S;
    function fly(r, fromMs) {
        r.kickAt = kickAt(start, fromMs, r.rank, S);
        r.doneAt = r.kickAt + A;
        if (r.doneAt > end)
            end = r.doneAt;
        if (r.kickAt > lastKick)
            lastKick = r.kickAt;
    }
    for (var k = 0; k < rewind.length; k++) {
        var ri = rewind[k];
        var re = entries[ri];
        var rr = rows[ri];
        rr.rank = rank++;
        if (re.phase === "outAir") {
            // Still flying out: it turns at its own deadline, not here.
            rr.act = "pendIn";
            rr.pendAt = start;
            fly(rr, re.doneAt);
        } else {
            rr.act = "enter";
            rr.startDelay = startDelayOf(start, now);
            fly(rr, now);
        }
    }
    for (i = 0; i < entries.length; i++) {
        var en = entries[i];
        if (!en.mine)
            continue;
        var r = rows[i];
        switch (en.phase) {
        case "hidden":
        case "outHidden":
            if (band[i] === "below") {
                r.act = "tail";
            } else {
                r.act = "enter";
                r.rank = rank++;
                r.startDelay = startDelayOf(start, now);
                fly(r, now);
            }
            break;
        case "outWait":
        case "held":
            r.act = "rest";
            break;
        case "inWait":
        case "inAir":
            if (en.pend)
                r.act = "cancelPend";
            break;
        case "outAir":
            if (en.pend === "in")
                r.act = "keep";         // already coming back
            break;
        default:
            break;                      // shown, tail, and the rewind above
        }
    }
    for (i = 0; i < rows.length; i++)
        if (rows[i].act === "tail")
            rows[i].doneAt = end;
    return { start: start, end: end, ranks: rank, lastKick: lastKick, rows: rows, follow: follow,
             viewH: viewH };
}

// ---------------------------------------------------------------------------
// THE LINE NEVER ASKS FOR MORE SCROLL THAN THERE IS
//
// What a collapse with a line takes off contentY -- every row of this call
// wholly above the line (held, then gone anchored) and the part of the row
// across it (the lift) -- has to fit in the scroll above the viewport
// (`room`: contentY). Near the list's top it may not: at contentY 50, a row
// at -50..-8 held and 36 px of the next lifted ask for 78, and the 28 the
// view cannot give came off in one step when the held row went (everything
// on screen jumped up). That much, H(L) = the sum over this call's standing
// rows of clamp(L - top, 0, h), is continuous and grows with L, so the line
// used is the largest L <= line with H(L) <= room: what closes up ends where
// the list's own top puts it, at contentY 0, never above it and never by a
// step. `entries` in layout order; `line` in their coordinates.
//
// THE LIST'S OWN TOP MAY BE ABOVE THE VIEWPORT'S. A host whose content starts
// above its origin (the notification manager's column sits `_s` px up, the
// room its first box's bevel is hidden in) puts its first row's top at
// -contentY - _s, and the line that fits is then NEGATIVE: at contentY 56 a
// 58 px first row wholly above the viewport fits 56 of itself, so the line is
// -4, the row is ACROSS it -- it leaves, invisible, and lifts its 56 px as it
// shrinks while 2 px of it come off the content on the same clock. Clamped at
// the viewport's top (0), the row would be held, the list's end would
// retire it, 58 px would go off a 56 px scroll in the call's frame, and
// everything on screen and the popup's foot would move 2 px in one step
// before the wave began.
// ---------------------------------------------------------------------------
function roomLine(entries, line, room) {
    var acc = 0;
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (!e.mine || e.phase !== "shown" || e.h <= 0)
            continue;
        if (e.top >= line)
            break;
        if (acc + Math.min(e.h, line - e.top) > room + 1e-6)
            return e.top + (room - acc);
        acc += e.h;
    }
    return line;
}

// ---------------------------------------------------------------------------
// THE LIST'S END (list_animation.md, "Collapsing at the very bottom of the
// list")
//
// A collapse makes the content shorter. Where there is less content below the
// fold than the collapse takes away while it runs, the Flickable clamps the
// view to the content's end: what is ABOVE the leaving rows is pulled DOWN
// into view instead of what is below closing up. `pull` is how far, once the
// wave is over: what the rows leaving or dropped now take away (a row held
// above the fold is anchored -- it goes off contentY and moves nothing),
// less what a swap's new rows will add (`o.grow`), less the content below the
// fold (`o.below`), and never more than the scroll above the viewport
// (`o.room`).
// ---------------------------------------------------------------------------
function endPull(entries, rows, o) {
    if (o.below === undefined)
        return 0;
    var shrink = 0;
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i];
        var a = rows[i].act;
        if (a === "hold" || a === "pendHold" || e.phase === "held" || e.pend === "hold")
            continue;
        // leave, drop, pendOut, pendDrop, cancelPend: all end at zero;
        // another wave's rows end where their own phase says.
        shrink += a === "keep" ? e.h - finalHeight(e, false) : e.h;
    }
    var pull = shrink - (o.grow || 0) - Math.max(0, o.below);
    return o.room !== undefined ? Math.min(pull, o.room) : pull;
}

// ---------------------------------------------------------------------------
// COLLAPSE
//
// o = { now, viewTop, viewH, margin, staggerMs, animMs[, topLine, lift, room,
//       anchored, below, grow] }
//
// Acts, per entry:
//   keep        not this call's row, already hidden, or a row another
//               collapse owns (outWait / outAir / outGone / outHidden / held)
//               -- a second wave never touches the first one's rows
//   leave       ON screen: fly out on the stagger (rank, startDelay, ...)
//   hold        ABOVE the fold: full height until `end`, then gone in one
//               step (zeroed early it would shrink the content under the
//               viewport and yank the rows still flying)
//   retire      ABOVE the fold at the LIST'S END, where the pull would bring
//               it into view (below) -- a row at rest or one still landing:
//               zero height in this frame, its height off contentY in the
//               same frame (ListWave anchors it)
//   drop        BELOW the fold, or never seen (an arrival not yet kicked, a
//               tail not yet placed): zero height in this frame
//   pendOut     an arrival IN THE AIR on screen: it lands first, then leaves
//               with its rank (flipped mid-entrance it would snap back to
//               full height)
//   pendHold / pendDrop   the same arrival off screen: lands, then is held /
//               retired
//   cancelPend  a departure turned around by a rewind that has not turned
//               yet: the turn is off, the row finishes leaving
//
// The wave WAITS FOR THE AIR TO CLEAR: `start` is the last landing among the
// on-screen arrivals still in flight, so a collapse of a list still filling
// begins when the rows that made it in have landed, and one of a list at rest
// begins now.
//
// A ROW WHOLLY ABOVE THE VIEWPORT TAKES NO RANK. It can be "on" only across a
// line that is itself above the viewport (roomLine, a list whose top is above
// its origin); it leaves because the lift rides it, but nobody sees it go,
// and a rank of its own would hold every visible row back one stagger step.
// It kicks with the first visible row.
//
// THE TOP EDGE HAS NO MARGIN HERE. A row wholly above the viewport is ABOVE
// even inside the row's worth of margin, and is held with the rest: nobody
// can see it fly, and flown, its height goes from above the viewport while
// the wave is in the air -- everything on screen slides up under the rows
// still flying (Collapsing 4), and in an accordion (a swap scrolled into the
// old list) the new list's header lands one row above the viewport. Held,
// it goes at the end in one step, off contentY in that same frame when
// ListWave anchors. The foot keeps its margin: a row just past the fold
// that flies out moves nothing on screen.
//
// A SWAP'S TOP EDGE IS THE FOLLOW'S LINE (`o.topLine`, px below viewTop; the
// manager's is its top fade less a gap). What closes up under the leaving
// rows -- the header being opened -- ends where the first leaving row began,
// and a line under the fade says it must not end above it (list_animation.md,
// "Expanding at the very bottom": the header stays whole on screen). So for
// this collapse the band [viewTop, viewTop + topLine] is above the fold: a
// row wholly above the LINE is held with the rest. The row across the line
// leaves -- it is on screen -- and with `o.lift` the plan says how much of it
// lies above the line: `lift = { index, px }`, which ListWave takes off
// contentY as that row shrinks, on its own clock, so the header ends ON the
// line. Only when the first row on screen is one this call flies from rest
// (a row still arriving, or another wave's, is nobody's to lift). With
// `o.room` the line is lowered to what the scroll can give (`roomLine`); the
// plan's `line` is the one it used, the edge ListWave measures its held rows
// against when they go.
//
// AT THE LIST'S END (`o.anchored`, `o.below`: endPull > 0) the collapse is
// judged against the viewport the clamp ENDS at. The pull brings what is
// above the leaving rows down into view as the list shortens; a row held
// above the line would come down with it -- on screen at full height -- and
// then vanish in one frame when its wave ended, the next thing above it
// popping in there (352 px of held rows in view before they went). So,
// walking up from the line, every held row the pull would bring
// below it -- counting the rows already retired under it, which bring the
// ones above them that much closer -- is RETIRED now, anchored: off contentY
// in this frame, nothing on screen moves, and what comes into view is what
// stays above it. A row still landing above the fold (`pendHold`) will be
// held too and is judged the same way: retired, it stops where it is. The
// first held row out of reach ends the walk; it and everything above it are
// held as before (nothing brings them into view).
// ---------------------------------------------------------------------------
function collapsePlan(entries, o) {
    var now = o.now;
    var S = o.staggerMs;
    var A = o.animMs;
    var i;
    var line = Math.max(0, Math.min(o.viewH, o.topLine || 0));
    if (o.lift && line > 0 && o.room !== undefined)
        line = roomLine(entries, o.viewTop + line, o.room) - o.viewTop;
    var slots = [];
    for (i = 0; i < entries.length; i++)
        slots.push({ top: entries[i].top, h: entries[i].h, full: entries[i].full });
    var band = bands(slots, o.viewTop + line, o.viewH - line, o.margin, 0);
    var rows = [];
    for (i = 0; i < entries.length; i++)
        rows.push(_row());

    var start = now;
    for (i = 0; i < entries.length; i++) {
        var e = entries[i];
        if (e.mine && e.phase === "inAir" && band[i] === "on" && e.doneAt > start)
            start = e.doneAt;
    }
    var rank = 0;
    var end = start;
    function fly(r, fromMs) {
        r.kickAt = kickAt(start, fromMs, r.rank, S);
        r.doneAt = r.kickAt + A;
        if (r.doneAt > end)
            end = r.doneAt;
    }
    for (i = 0; i < entries.length; i++) {
        var en = entries[i];
        if (!en.mine)
            continue;
        var r = rows[i];
        switch (en.phase) {
        case "shown":
            if (band[i] === "on") {
                r.act = "leave";
                r.rank = rank;
                if (en.top + en.h > o.viewTop)
                    rank++;
                r.startDelay = startDelayOf(start, now);
                fly(r, now);
            } else if (band[i] === "above") {
                r.act = "hold";
            } else {
                r.act = "drop";
                r.doneAt = now;
            }
            break;
        case "inAir":
            if (en.pend)
                break;                  // already turning: its own business
            if (band[i] === "on") {
                r.act = "pendOut";
                r.rank = rank++;
                r.pendAt = start;
                fly(r, en.doneAt);
            } else {
                r.act = band[i] === "above" ? "pendHold" : "pendDrop";
                if (en.doneAt > end)
                    end = en.doneAt;
            }
            break;
        case "inWait":
        case "tail":
            r.act = "drop";
            r.doneAt = now;
            break;
        case "outAir":
            if (en.pend === "in")
                r.act = "cancelPend";
            break;
        default:
            break;                      // hidden, and every departure's own row
        }
    }
    for (i = 0; i < rows.length; i++) {
        if (rows[i].act === "hold")
            rows[i].doneAt = end;
        else if (rows[i].act === "pendHold")
            rows[i].pendAt = end;
    }
    var pull = o.anchored ? endPull(entries, rows, o) : 0;
    if (pull > 1e-6) {
        var R = 0;
        for (i = entries.length - 1; i >= 0; i--) {
            if (rows[i].act !== "hold" && rows[i].act !== "pendHold")
                continue;
            var p = o.room !== undefined ? Math.min(pull, o.room - R) : pull;
            if (entries[i].top - o.viewTop + entries[i].h + R + p <= line + 1e-6)
                break;
            rows[i].act = "retire";
            rows[i].doneAt = now;
            R += entries[i].h;
        }
    }
    var lift = null;
    if (o.lift) {
        for (i = 0; i < entries.length; i++) {
            if (band[i] !== "on")
                continue;
            var over = o.viewTop + line - entries[i].top;
            if (rows[i].act === "leave" && over > 0)
                lift = { index: i, px: Math.min(over, entries[i].h) };
            break;
        }
    }
    return { start: start, end: end, ranks: rank, rows: rows, lift: lift, line: line,
             pull: Math.max(0, pull) };
}
