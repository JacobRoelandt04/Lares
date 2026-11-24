pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../parts"
import ".."
import "../parts/ModelSync.js" as ModelSync

// =============================================================================
// GroupSection.qml -- one group of the manager (Critical / System / Normal /
// Low): its header and its entries, every one a ManagerSlot (an
// AnimatedListRow), so the manager's ListWave flies headers and cards alike.
//
//   header  ListSectionHeader in the header-box material, the group's colour
//           as the idle mark of its inset; the subtitle says "3 · <newest>"
//           folded and "3 notifications" open (the count leads the
//           line, no figure slot) -- folded with nothing to preview, the count
//           in words too, never a dot with nothing after it; one line, plain
//           text (a sender's summary is not the header's markup). The header
//           is a SwipeVerbCard: swiped either way it CLEARS the group ("clear" |
//           "clear"; the manager offers the undo in its top row). A click
//           still toggles it.
//   entries one per app (AppBundleRow; a single notification is a bundle of
//           one) and one per pinned notification, kept in a ListModel by a
//           STABLE key ("p:<uid>" pinned, "a:<appKey>" an app's unpinned
//           ones, "u:<uid>" a record with no app) so a change never rebuilds
//           a card and an app's second notification turns its row into a
//           bundle in place.
//
// WHO MOVES, AND HOW (the manager decides per change; `apply(data, mode)`):
//   instant  everything simply is where it belongs (the popup opening, the
//            filter): no motion
//   arrive   a new row in an OPEN group grows its room in place with a
//            presence fade (the toast's rule), a new group's header too; a
//            row in a FOLDED group is born folded and removed at once --
//            never handed to an animation, since a row told "leaving" snaps
//            to its full height first (a flash)
//   wave     the list's clock: what went leaves on the stagger and what came
//            back returns on it (Clear all, a group swiped away, and their
//            Undo). The section hands its rows to the manager (`_retire`,
//            `_incoming`), which gives them to ListWave in layout order.
// A row (or the header) that comes back while the wave still has it -- leaving,
// or held above the fold -- is handed back to the wave in any mode: ListWave
// rewinds it or keeps it (list_animation.md, Interrupting; Collapsing 4).
// A leaving row is dropped from the model when it has gone (rowState
// "collapsed"), not by a timer of its own.
//
// A CLEAR'S ROWS WAIT FOR ITS UNDO. The rows a clear took (they left in
// "wave" mode) stay in the model, gone -- collapsed, no room, nothing drawn --
// for as long as that clear's undo is on offer (`holdToken`, the service's
// undoState token), and are dropped when the offer ends. Undo then brings back
// the SAME delegates on the wave instead of building every card again: the
// rebuild would be the whole of Undo's first-frame stall (43-133 ms of
// JS before the wave's first frame, ~5 ms a card; the service's restore and
// the compute are 2-5 ms). A gone row that comes back
// otherwise (an app's new notification during the window, or records removed
// and sent again in one turn) comes back as that mode's new row would: grown
// in place on an arrival, at rest when instant, collapsed in a folded group --
// never handed to the wave there, which would draw a folded group's rows under
// its header.
// =============================================================================
Column {
    id: section

    property string group: "normal"
    property bool open: false
    property var service: null
    property var clock: null
    property Item overlayItem: null
    property GroupPalette groups: null
    property NotificationStyle style: null
    property real sectionWidth: 396
    property color surfaceColor: Theme.surface
    property string highlightKey: ""
    property int arriveMs: 260
    property int presenceMs: 160
    property real rowGap: 6
    property real headGap: 6
    property var pinHandler: null
    // The pin flight (RowFlight) the manager runs: its key and its share.
    property string flightUid: ""
    property real flightReveal: 1
    // The list's side cut and fade: every card here (the header, the rows)
    // cuts and fades itself through it while it is displaced.
    property SideFade sideFade: null
    // How long the fog at a growing or shrinking row's edge is: the side cut's
    // long ramp (ManagerSlot).
    readonly property real fogPx: section.sideFade ? section.sideFade.fadeLength : 34
    // The undo on offer ("" none): the rows its clear took wait for it.
    property string holdToken: ""
    // uid -> true: the cards whose body is open in full (the manager's).
    property var expandedStore: null

    // Where the unfold of a bundle's members may rise to (ListWave's line for
    // a row that opens under a CARD: the top fade's foot).
    property real memberFollowTopPx: -1

    signal toggleRequested()
    signal clearRequested()
    // Rows were gathered outside an apply() (a bundle opened or folded, a
    // member that came or went on its own): the manager hands them to the wave.
    signal waveWanted()

    readonly property string fontFamily: section.style ? section.style.fontFamily : "Inter"
    // A header is a box of the same list: the cards' radius.
    readonly property real _radius: section.style ? section.style.cardRadius : 14
    readonly property bool present: section._present
    readonly property Item headerRow: headSlot
    readonly property Item headerCard: headCard

    spacing: 0
    width: section.sectionWidth

    // ---- what the section shows (the manager writes it through apply()) ------
    property bool _present: false
    property bool _hasPins: false
    property bool _clearable: false
    // The text the header keeps while it leaves (it must not read "0 · ").
    property int _shownCount: 0
    property string _shownNewest: ""

    // ---- the choreography -------------------------------------------------------
    property string _mode: "instant"
    property var _retire: []
    property var _incoming: []
    // Set by the flight: the key whose row becomes the hole it leaves.
    property string _phantomKey: ""

    property bool _inApply: false
    function apply(g, mode) {
        section._mode = mode;
        section._inApply = true;
        const was = section._present;
        // A reorder in view is drawn from where the rows were (FLIP, below).
        const before = mode === "arrive" && was && section.open ? section._rowList() : null;
        const now = !!g && g.count > 0;
        section._hasPins = !!g && g.pins > 0;
        section._clearable = !!g && g.count > g.pins;
        if (now) {
            section._shownCount = g.count;
            section._shownNewest = g.newest;
        }
        section._present = now;
        // The header.
        if (now && (!was || headSlot.rowState === "collapsed" || headSlot.rowState === "leaving")) {
            if (headSlot.rowState !== "collapsed")
                // Still the wave's -- flying out, or HELD above the fold at
                // full height until its wave is over (list_animation.md,
                // Collapsing 4). Handed back, the wave rewinds it or simply
                // keeps it. Rested in place instead, the held one would be
                // collapsed by its wave's end: the group's rows would stay with
                // no header over them (a burst of removals and arrivals
                // while the list is scrolled).
                section._incoming.push(headSlot);
            else if (mode === "instant")
                section._rest(headSlot);
            else if (mode === "wave")
                section._bringIn(headSlot);
            else if (section.open) {
                // The group's first arrival: its header and its card grow as
                // ONE block on one clock -- the header whole before its card's
                // room opens -- not each through its own room's clip, which
                // draw the header's box cut in half over a card.
                section._rest(headSlot);
                headSlot.arriveJoined();
                section._joint = [headSlot];
            } else {
                section._rest(headSlot);
                headSlot.arrive();
            }
            // A header that comes back after its card flew off is on its face again.
            headCard.reset();
        } else if (!now && was) {
            // Handed to the wave whatever it shows: a pending tail reads
            // "collapsed" and would otherwise be placed later by an Undo's wave
            // (a duplicate header); the wave keeps a hidden row a no-op.
            if (mode === "instant")
                headSlot.rowState = "collapsed";
            else
                section._retire.push(headSlot);
        }
        // The entries.
        section._renameForFlight(g ? g.entries : []);
        const byKey = {};
        const keys = [];
        for (const e of g ? g.entries : []) {
            byKey[e.key] = e;
            keys.push(e.key);
        }
        ModelSync.sync(rowsModel, keys, k => ({
                    uid: byKey[k].uid || "",
                    uidList: byKey[k].uidList || ""
                }), true);
        if (before)
            section._flip(before);
        if (section._joint)
            section._startJoint();
        section._mode = "instant";
        section._inApply = false;
    }

    // ---- a reorder, in motion ---------------------------------------------
    // The model MOVES a row (ModelSync: an app's new notification takes its
    // row to the top of the group; a bundle falls below a neighbour when its
    // head is pinned away) and the Column lays the rows out anew in one frame.
    // So every row that was here before and after is drawn where it was and
    // eases home (ManagerSlot.flip): the old and the new places are summed
    // over those rows alone, at their heights now -- a row arriving or leaving
    // in the same change takes its own room on its own clock, and is not a move.
    function _rowList() {
        const out = [];
        for (let i = 0; i < rowRep.count && i < rowsModel.count; i++) {
            const r = rowRep.itemAt(i) as ManagerSlot;
            if (r)
                out.push(r);
        }
        return out;
    }
    function _flip(before) {
        const after = section._rowList();
        const keep = before.filter(r => after.indexOf(r) >= 0);
        const tops = list => {
            const m = new Map();
            let y = 0;
            for (const r of list) {
                if (keep.indexOf(r) < 0)
                    continue;
                m.set(r, y);
                y += r.height;
            }
            return m;
        };
        const t0 = tops(before), t1 = tops(after);
        for (const r of keep) {
            const dy = t0.get(r) - t1.get(r);
            if (Math.abs(dy) > 0.5 && r.height > 0.5 && r.rowState === "rest")
                r.flip(dy);
        }
    }

    // ---- the first arrival, one block -------------------------------------
    // The header and the rows that arrive with it grow on ONE clock over their
    // summed room: the header's share first, then the rows', so the edge that
    // reveals them moves at one speed down the block.
    property var _joint: null
    property real _jointF: 1
    function _startJoint() {
        const list = section._joint;
        section._joint = null;
        section._jointList = list;
        section._jointF = 0;
        jointAnim.restart();
    }
    property var _jointList: []
    on_JointFChanged: {
        const list = section._jointList;
        if (!list || list.length === 0)
            return;
        // (A row removed while the block grows is gone from the list.)
        const live = list.filter(r => !!r && r.fullHeight !== undefined);
        let total = 0;
        for (const r of live)
            total += Math.max(1, r.fullHeight);
        let y = section._jointF * total;
        for (const r of live) {
            const h = Math.max(1, r.fullHeight);
            r.grow = Math.max(0, Math.min(1, y / h));
            y -= h;
        }
        if (section._jointF >= 1)
            section._jointList = [];
    }
    NumberAnimation {
        id: jointAnim
        target: section
        property: "_jointF"
        from: 0
        to: 1
        duration: section.arriveMs
        easing.type: Easing.OutCubic
    }

    function _rest(slot) {
        slot.place();
        if (slot.rowState !== "rest")
            slot.rowState = "rest";
    }
    // A row that has gone, flown back in on the wave.
    function _bringIn(slot) {
        slot.place();
        section._incoming.push(slot);
    }

    // ---- an entry is its head's row and one row per member of its bundle ------------
    // (AppBundleRow, ManagerSlot): the wave flies every card on its own step.
    function _members(wrap, withLeaving) {
        const b = wrap["bundleItem"];
        return b ? b.memberSlots(withLeaving) : [];
    }
    function _restEntry(wrap) {
        section._rest(wrap);
        for (const m of section._members(wrap, false))
            section._rest(m);
    }
    function _bringInEntry(wrap) {
        section._bringIn(wrap);
        for (const m of section._members(wrap, false)) {
            m.place();
            section._incoming.push(m);
        }
    }
    function _pushIn(wrap) {
        section._incoming.push(wrap);
        for (const m of section._members(wrap, false))
            section._incoming.push(m);
    }
    function _pushOut(wrap) {
        section._retire.push(wrap);
        for (const m of section._members(wrap, true))
            section._retire.push(m);
    }
    // An entry whose head has collapsed goes once its members have.
    function _tryGone(wrap) {
        const b = wrap["bundleItem"];
        if (!b || b.tailGone())
            section._gone(wrap);
    }
    function _flushLater() {
        if (!section._inApply)
            Qt.callLater(section.waveWanted);
    }
    function _folded() {
        return !section.open || !section._present;
    }
    // A bundle was opened or folded by the user (its chevron): the members that
    // came or went are the wave's.
    function toggleBundle(bundle) {
        bundle.open = !bundle.open;
        section.waveWanted();
    }
    // A member is born: on the wave when the bundle was just opened (or the
    // wave is what is running), in place when a record joined an open bundle,
    // folded when the group is.
    function _memberBorn(m, opening) {
        if (section._folded()) {
            m.rowState = "collapsed";
            return;
        }
        const mode = section._mode;
        if (opening || mode === "wave" || (mode === "instant" && !section._inApply)) {
            m.rowState = "collapsed";
            section._incoming.push(m);
            section._flushLater();
        } else {
            m.rowState = "rest";
            if (mode === "arrive")
                m.arrive();
        }
    }
    // A member is gone (deleted, folded away): the wave takes it unless nobody
    // can see it.
    function _memberLeft(m) {
        if (m.rowState === "collapsed" || section._folded() || (section._mode === "instant" && section._inApply)) {
            m.rowState = "collapsed";
            return;
        }
        section._retire.push(m);
        section._flushLater();
    }
    function _memberReturned(m) {
        if (section._folded()) {
            m.rowState = "collapsed";
            return;
        }
        if (m.rowState !== "collapsed") {
            // Back while it was leaving: the wave rewinds it.
            section._incoming.push(m);
            section._flushLater();
        } else if (section._mode === "arrive") {
            section._rest(m);
            m.arrive();
        } else if (section._mode === "instant" && section._inApply) {
            section._rest(m);
        } else {
            m.place();
            section._incoming.push(m);
            section._flushLater();
        }
    }

    // A pinned row that keeps its place is the same row: the row whose card
    // shows the record at its head follows the record to its new key in
    // place ("a:app" -> "p:uid", or back), so the card the user swiped stays
    // where it is and the flight has nothing to fly (RowFlight ends when the
    // index is unchanged). What the row held besides that record becomes a row
    // of its own that arrives beside it (the rest of a bundle whose head was
    // pinned at the group's top) -- and a row the record joins in place (an
    // unpin into its app's bundle right below it) is let go: it merged.
    property int _deadKeys: 0
    function _renameForFlight(entries) {
        const uid = section.flightUid;
        if (uid === "")
            return;
        const head = ul => String(ul).split("|")[0];
        let oldAt = -1, at = -1, live = 0;
        for (let i = 0; i < rowsModel.count; i++) {
            const r = rowsModel.get(i);
            if (r.leaving)
                continue;
            if (head(r.uidList) === uid) {
                oldAt = live;
                at = i;
                break;
            }
            live++;
        }
        const newAt = entries.findIndex(e => head(e.uidList) === uid);
        if (oldAt < 0 || newAt < 0 || oldAt !== newAt)
            return;
        const key = rowsModel.get(at).key, want = entries[newAt].key;
        if (section._phantomKey === key)
            section._phantomKey = "";
        if (key === want)
            return;
        for (let j = 0; j < rowsModel.count; j++)
            if (j !== at && rowsModel.get(j).key === want)
                rowsModel.setProperty(j, "key", "x:" + (++section._deadKeys));
        rowsModel.setProperty(at, "key", want);
    }

    // What apply() gathered, in layout order (the header above its entries):
    // the manager hands them to ListWave.
    function _ordered(list) {
        const rank = it => it["order"] !== undefined ? it["order"] : 1e6;
        return list.filter((it, i) => list.indexOf(it) === i).sort((a, b) => rank(a) - rank(b));
    }
    function takeRetire() {
        const out = section._ordered(section._retire);
        section._retire = [];
        return out;
    }
    function takeIncoming() {
        const out = section._ordered(section._incoming);
        section._incoming = [];
        return out;
    }

    function _dropKey(key) {
        for (let i = 0; i < rowsModel.count; i++) {
            const r = rowsModel.get(i);
            if (r.key === key && r.leaving) {
                rowsModel.remove(i);
                return;
            }
        }
    }
    // Rows that have gone are dropped after the handler that saw them go
    // (a delegate may not be destroyed inside its own signal). ONE deferred
    // call drains them all: Qt.callLater runs a function once per turn with
    // the LAST arguments it was given, so a callLater per key would drop only
    // one row of a Clear all and leave the rest in the model, folded.
    property var _dropQueue: []
    function _dropLater(key) {
        section._dropQueue.push(key);
        Qt.callLater(section._drainDrops);
    }
    function _drainDrops() {
        const keys = section._dropQueue;
        section._dropQueue = [];
        for (const k of keys)
            section._dropKey(k);
    }
    // A row that has gone: kept while its clear's undo is on offer, else dropped.
    function _gone(wrap) {
        if (wrap.heldBy === "" || wrap.heldBy !== section.holdToken)
            section._dropLater(wrap.key);
    }
    // The offer changed (taken, expired, replaced): the rows held for another
    // one go. Deferred: an Undo ends its offer INSIDE the batch whose refresh
    // brings its rows back, and a row dropped before that refresh would be
    // built again.
    onHoldTokenChanged: Qt.callLater(section._releaseHeld)
    function _releaseHeld() {
        for (let i = 0; i < rowRep.count && i < rowsModel.count; i++) {
            const r = rowRep.itemAt(i) as ManagerSlot;
            if (r && rowsModel.get(i).leaving && r.rowState === "collapsed" && r.phantomHeight <= 0
                    && r.heldBy !== "" && r.heldBy !== section.holdToken)
                section._dropLater(rowsModel.get(i).key);
        }
    }

    // ---- what the manager asks ----------------------------------------------------
    // The live entry slots, in order: what an accordion's wave animates.
    function rowItems() {
        const out = [];
        for (let i = 0; i < rowRep.count; i++) {
            const r = rowRep.itemAt(i) as ManagerSlot;
            if (r && i < rowsModel.count && !rowsModel.get(i).leaving && r.phantomHeight <= 0) {
                out.push(r);
                out.push.apply(out, section._members(r, false));
            }
        }
        return out;
    }
    // Open or fold without a wave: the popup opening on this group, the filter
    // opening every group that matches. The rows simply are where they belong.
    function setRowsInstant(open) {
        for (let i = 0; i < rowRep.count; i++) {
            const r = rowRep.itemAt(i) as ManagerSlot;
            if (r && i < rowsModel.count && !rowsModel.get(i).leaving) {
                r.place();
                r.rowState = open ? "rest" : "collapsed";
                const b = r["bundleItem"];
                if (b)
                    b.setMembers(open ? "rest" : "collapsed");
            }
        }
    }
    // The slot of an entry key (the keyboard scrolls it into view).
    function rowFor(key) {
        for (let i = 0; i < rowRep.count && i < rowsModel.count; i++) {
            if (rowsModel.get(i).key === key && !rowsModel.get(i).leaving)
                return rowRep.itemAt(i);
        }
        return null;
    }
    // The card (a NotificationRow) showing `uid`, or null.
    function cardFor(uid) {
        for (let i = 0; i < rowRep.count; i++) {
            const s = rowRep.itemAt(i) as ManagerSlot;
            if (!s || s.phantomHeight > 0 || (i < rowsModel.count && rowsModel.get(i).leaving))
                continue;
            const b = s.bodyItem as AppBundleRow;
            const c = b ? b.cardFor(uid) : null;
            if (c)
                return c;
        }
        return null;
    }
    // The entry slot a folded bundle keeps `uid` under, when no card shows it.
    function slotHolding(uid) {
        for (let i = 0; i < rowRep.count && i < rowsModel.count; i++) {
            const r = rowsModel.get(i);
            if (!r.leaving && ("|" + r.uidList + "|").indexOf("|" + uid + "|") >= 0)
                return rowRep.itemAt(i);
        }
        return null;
    }
    // Where a slot's top is, in `item`'s coordinates -- also for a slot at
    // zero height, which a Column does not lay out: its `y` is whatever it
    // was last (a pin's destination opening from nothing would read the header's
    // top, and the flown card land a row too high). Its place is right
    // after the nearest laid-out sibling before it (ListWave's _slotTop).
    function slotTopIn(slot, item) {
        if (slot.height > 0)
            return slot.mapToItem(item, 0, 0).y;
        const kids = section.children;
        for (let j = kids.indexOf(slot) - 1; j >= 0; j--) {
            const k = kids[j];
            if (k.visible && k.width > 0 && k.height > 0)
                return k.mapToItem(item, 0, k.height).y;
        }
        return section.mapToItem(item, 0, 0).y;
    }
    function phantomSlot() {
        for (let i = 0; i < rowRep.count; i++) {
            const s = rowRep.itemAt(i) as ManagerSlot;
            if (s && s.phantomHeight > 0)
                return s;
        }
        return null;
    }
    // RowFlight's gap: the row that holds only `uid` becomes the hole the
    // flown card leaves when its key goes (beginFlightGap), and the hole is
    // dropped when the flight is over (endFlightGap).
    function beginFlightGap(uid) {
        for (let i = 0; i < rowsModel.count; i++) {
            const r = rowsModel.get(i);
            if (!r.leaving && r.uidList === uid) {
                section._phantomKey = r.key;
                return;
            }
        }
    }
    // `pre`: how far the flight had opened its destination when it ended
    // (1: all the way; less: it never travelled). A hole still holding room
    // then closes on its own clock, and a destination still shut opens on it,
    // instead of both stepping on the flight's last frame.
    property real _endPre: 1
    function endFlightGap(pre) {
        section._phantomKey = "";
        section._endPre = pre === undefined ? 1 : pre;
        for (let i = rowRep.count - 1; i >= 0; i--) {
            const s = rowRep.itemAt(i) as ManagerSlot;
            if (!s || s.phantomHeight <= 0)
                continue;
            if (section._endPre < 0.99)
                s.closeHole(1 - section._endPre);
            else
                section._dropKey(rowsModel.get(i).key);
        }
    }

    // ---- the header ------------------------------------------------------------
    ManagerSlot {
        id: headSlot
        objectName: "groupHeaderSlot"
        width: section.sectionWidth
        gapAbove: section.headGap
        gapBelow: section.headGap
        arriveMs: section.arriveMs
        presenceMs: section.presenceMs
        groundColor: section.surfaceColor
        fogPx: section.fogPx
        order: -1
        rowState: "collapsed"

        SwipeVerbCard {
            id: headCard
            objectName: "groupHeaderCard"
            width: section.sectionWidth
            rightVerb: section._clearable ? "clear" : ""
            leftVerb: section._clearable ? "clear" : ""
            // Pinned notifications survive a clear: the group stays, so its
            // header springs back rather than flying off.
            rightFliesOff: !section._hasPins
            leftFliesOff: !section._hasPins
            groundColor: section.surfaceColor
            radius: section._radius
            sideFade: section.sideFade
            // The swipe's tuning, from the one style (the mockup's Swipe tab).
            commitFraction: section.style ? section.style.swipeCommitFraction : 0.4
            fadeFrom: section.style ? section.style.swipeFadeFrom : 0.45
            maxFraction: section.style ? section.style.swipeMaxFraction : 0.8
            flyMs: section.style ? section.style.swipeFlyMs : 260
            springMs: section.style ? section.style.swipeSpringMs : 260
            swingMs: section.style ? section.style.swipeSwingMs : 120
            flingPxPerS: section.style ? section.style.swipeFlingPxPerS : 900
            dragThreshold: section.style ? section.style.swipeDragThreshold : 6
            glyphSize: section.style ? section.style.swipeGlyphSize : 20
            glyphInset: section.style ? section.style.swipeGlyphInset : 12
            wellShadowWidth: section.style ? section.style.swipeWellShadowWidth : 4
            wellBevelWidth: section.style ? section.style.swipeWellBevelWidth : 1
            blockedGivePx: section.style ? section.style.swipeBlockedGivePx : 24
            onCommitted: dir => section.clearRequested()

            ListSectionHeader {
                id: header
                width: section.sectionWidth
                title: section.groups ? section.groups.title(section.group) : section.group
                subtitle: section.open || section._shownNewest === ""
                    ? section._shownCount + (section._shownCount === 1 ? " notification" : " notifications")
                    : section._shownCount + " · " + section._shownNewest
                textFormat: Text.PlainText
                subtitleOneLine: true
                fontFamily: section.fontFamily
                titleSize: section.style ? section.style.headerTitleSize : 14
                subtitleSize: section.style ? section.style.headerSubtitleSize : 11
                chevronSize: section.style ? section.style.headerChevronSize : 14
                boxPadding: section.style ? section.style.headerPadX : 11
                boxPaddingV: section.style ? section.style.headerPadY : 8
                expandable: true
                expanded: section.open
                accentColor: section.groups ? section.groups.color(section.group) : Theme.accent
                progress: 0
                textColor: Theme.textPrimary
                mutedColor: Theme.textMuted
                faintColor: Theme.textFaint
                errorColor: Theme.error
                boxColor: Theme.headerBox
                // The face slides over the well: its rim eases to alpha.
                boxSurfaceColor: "transparent"
                boxBevelColor: Theme.headerBoxBevel
                boxShadowColor: Theme.headerBoxShadow
                boxRadius: section._radius
                containerRadius: section._radius
                bottomGap: 0
                onToggled: section.toggleRequested()
            }
        }
    }

    // ---- the entries -------------------------------------------------------------
    ListModel {
        id: rowsModel
        // { key, uid, uidList, leaving }
    }

    Repeater {
        id: rowRep
        model: rowsModel

        delegate: ManagerSlot {
            id: wrap
            required property int index
            required property string key
            required property string uid
            required property string uidList
            required property bool leaving

            width: section.sectionWidth
            gapAbove: 0
            gapBelow: section.rowGap
            arriveMs: section.arriveMs
            presenceMs: section.presenceMs
            groundColor: section.surfaceColor
            fogPx: section.fogPx
            order: wrap.index
            // The bundle inside (its members are rows of this entry's tail).
            readonly property AppBundleRow bundleItem: bundleRow
            // A flight's destination opens as the clone comes in; the hole it
            // left closes on the same share.
            property bool flightDest: false
            reveal: section.flightUid !== "" && (wrap.flightDest || wrap.phantomHeight > 0) ? section.flightReveal : 1
            Connections {
                target: section
                function onFlightUidChanged() {
                    if (section.flightUid !== "" || !wrap.flightDest)
                        return;
                    wrap.flightDest = false;
                    if (section._endPre < 0.99)
                        wrap.arriveFrom(section._endPre);
                }
            }
            onHoleClosed: section._dropLater(wrap.key)

            Component.onCompleted: {
                const m = section._mode;
                const folded = !section.open || !section._present;
                if (section.flightUid !== "" && ("|" + wrap.uidList + "|").indexOf("|" + section.flightUid + "|") >= 0
                        && !folded) {
                    // The pin flight's destination: at rest, opened by the flight.
                    wrap.flightDest = true;
                    wrap.rowState = "rest";
                } else if (folded || m === "wave") {
                    wrap.rowState = "collapsed";
                    if (!folded)
                        section._incoming.push(wrap);
                } else {
                    wrap.rowState = "rest";
                    if (m === "arrive" && section._joint) {
                        wrap.arriveJoined();
                        section._joint.push(wrap);
                    } else if (m === "arrive") {
                        wrap.arrive();
                    }
                }
            }
            onLeavingChanged: {
                if (wrap.leaving) {
                    wrap.heldBy = section._mode === "wave" ? section.holdToken : "";
                    if (section._phantomKey !== "" && section._phantomKey === wrap.key) {
                        // The hole the flown card left: it holds its room
                        // until the flight's destination has opened.
                        wrap.phantomHeight = Math.max(1, wrap.height);
                        section._phantomKey = "";
                    } else if (wrap.rowState === "collapsed" || section._mode === "instant") {
                        wrap.rowState = "collapsed";
                        bundleRow.setMembers("collapsed");
                        section._tryGone(wrap);
                    } else {
                        section._pushOut(wrap);
                    }
                } else if (wrap.phantomHeight <= 0) {
                    const gone = wrap.rowState === "collapsed";
                    wrap.heldBy = "";
                    if (!gone)
                        // Back while it was leaving: the wave rewinds it.
                        section._pushIn(wrap);
                    else if (!section.open || !section._present) {
                        // Gone (held for an undo, or sent again in the turn
                        // it went), back into a folded group: it stays folded.
                        wrap.rowState = "collapsed";
                        bundleRow.setMembers("collapsed");
                    } else if (section._mode === "arrive") {
                        section._restEntry(wrap);
                        if (section._joint) {
                            wrap.arriveJoined();
                            section._joint.push(wrap);
                        } else {
                            wrap.arrive();
                        }
                    } else if (section._mode === "instant")
                        section._restEntry(wrap);
                    else
                        // Held, back on the undo's wave.
                        section._bringInEntry(wrap);
                }
            }
            onRowStateChanged: {
                if (wrap.leaving && wrap.rowState === "collapsed" && wrap.phantomHeight <= 0)
                    section._tryGone(wrap);
            }

            AppBundleRow {
                id: bundleRow
                width: section.sectionWidth
                uidList: wrap.uidList
                service: section.service
                clock: section.clock
                overlayItem: section.overlayItem
                groups: section.groups
                cardWidth: section.sectionWidth
                style: section.style
                surfaceColor: section.surfaceColor
                gap: section.rowGap
                presenceMs: section.presenceMs
                tailHost: wrap.tailHost
                ownerIndex: wrap.index
                fogPx: section.fogPx
                keepItem: wrap
                followTopPx: section.memberFollowTopPx
                toggleHandler: () => section.toggleBundle(bundleRow)
                highlighted: section.highlightKey !== "" && section.highlightKey === wrap.key
                suppressedUid: section.flightUid
                flightReveal: section.flightReveal
                resizeMs: section.arriveMs
                pinHandler: section.pinHandler
                sideFade: section.sideFade
                expandedStore: section.expandedStore
                leaving: wrap.leaving
                onMemberBorn: (member, opening) => section._memberBorn(member, opening)
                onMemberLeft: member => section._memberLeft(member)
                onMemberReturned: member => section._memberReturned(member)
                onMemberSettled: {
                    if (wrap.leaving && wrap.rowState === "collapsed" && wrap.phantomHeight <= 0)
                        section._tryGone(wrap);
                }
            }
        }
    }
}
