pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/FuzzyMatch.js" as Fuzzy
import "../common/components/EditKeys.js" as EK
import "data/NotifyPolicy.js" as Policy
import "parts"
import "manager"
import "../wiki"

// =============================================================================
// NotificationManagerPopup.qml -- the manager, thePopup's content.
//
//   Notifications              Do not disturb [o  ]  [ Clear all ]
//   [ Critical  1 · download stalled ................................ v ]
//   [ System  3 notifications ........................................ ^ ]
//      [ card ]
//      [ card ]
//   [ Normal  7 · newest summary ...................................... v ]
//
// The groups in their fixed order (Critical, System, Normal, Low), each shown
// while it holds something. ONE group open at a time (an accordion),
// the one that last RECEIVED a notification when the manager is opened (the group last opened tells
// nothing about where to look); opening another is a SWAP on the list's clock (list_animation.md). While the user
// types, every group that matches is open (the launcher's search flattens
// folders the same way). Empty, the title says "No notifications" and there
// is no list at all: the popup is the top row.
//
// THE WIKI'S CARD. Handed a `wiki` (the shell's one WikiService, by
// injection: this popup never builds one), an EMPTY manager -- nothing to show
// and no undo on offer -- fills the list's place with today's Discover as a
// wide WikiCompactCard, 12 px under the top row and 12 px above the foot.
// Clicking it asks the service to open its full card and closes the manager
// (the clock popup takes the wiki up). ONE eased fraction, `_wikiF` (260 ms
// OutCubic, the room's own clock), is the card's presence and its share of
// `implicitHeight`, so the box grows and shrinks with the card and a
// notification's arrival pushes it out at the foot as its row's room opens.
// With `wiki: null` nothing here is created and every size is that of a manager with no card.
//
// CLEARING. A group's header swipes away either way (or takes
// Delete while it is highlighted): the group is cleared and leaves on the
// list's wave -- under a filter, only the rows the filter shows. Clear all
// plays the same exit for every card and header on screen. The top row's
// button is the ONE undo slot: it offers the latest clear ("Undo" / "Undo
// clear <Group>") for the undo window, and Undo plays everything back on the
// wave. The slot IS the service's `undoState` (one source): a manager built
// inside a window -- the popup closed and opened again -- re-arms from it.
//
// THE BOX MOVES WITH THE ROWS. A content's implicit size change is eased
// by the engine over its own 260 ms, which is a chase when the size moves
// every frame (an arrival's box 70 px off its rows, Clear
// all 425). So while anything here moves, the content says `liveResizeActive`
// and the engine FOLLOWS its implicit size frame by frame (GooeyEngine: THE
// LIVE CONTRACT) -- raised before a change this file makes and by any implicit
// size change at all (this handler runs before the engine's, which connects
// later), and dropped once the size has held still for `liveSettleFrames`
// frames and no wave or flight is running. At rest it is false: the resting
// box, its input mask and every pixel are what they are without it.
//
// PARKED. The engine may build this content
// ahead of the click (on hover intent, `engine.prebuild`) or keep the last closed one,
// and says so with `parked`: while it is true the manager is QUIET -- it does not
// react to the service (no row arrives, flies or waves; a wave started in a hidden
// box is CPU burnt for nobody), its live follower does not run, no undo is armed,
// the wiki's card is not built, nothing is marked seen and nothing takes the focus
// -- while its data and its size are right (the rows are built, instantly), so a
// size asked of it is the size it will have. When `parked` turns false the manager
// is OPENED: every read of the service that was skipped is done at once, in the
// opening's instant (no wave: the box is opening on the final state), the filter
// and the highlight start empty, the unseen are marked seen and the keys are taken
// -- the same sequence a content built unparked runs at completion. When it turns
// true again (a closed manager kept for the next open) the same silence is
// restored. Not reset on a re-park: the rows' own folds (an unfolded bundle, an
// expanded card) and the list's scroll position -- an engine that keeps a USED
// manager must rebuild it for now; a manager that was only prebuilt is exact. The
// engine sets `parked` as an INITIAL property (a content parked at completion never
// ran the opening sequence) and clears it BEFORE it reads the content's implicit
// size (the wiki's card of an empty manager is built by the opening).
//
// A drop-in: sized through implicitWidth / implicitHeight only, and laid out
// at the width it ASKED for (12 px of padding both sides): the engine's box
// eases while the popup opens (and is squeezed by a leaving toast lane), and
// a list laid out on that box re-flows every card and elides the title on
// every frame of the open. The growing
// box reveals it; at rest the two are the same. Keys: typing
// filters, Backspace edits, Esc clears the query and then closes, Up/Down move
// a carved highlight over headers and cards, Enter opens a header or acts on a
// card, Delete deletes a card or clears a header's group, Ctrl+P pins.
// =============================================================================
Item {
    id: root

    property var service: null
    property var clock: null
    // The engine's word that this content is built but not shown (see PARKED above). Never set here.
    property bool parked: false
    // The wiki's service (WikiService / WikiMock), or null: no card, no cost.
    property var wiki: null
    property NotificationStyle style: null
    property bool openedByKeyboard: false
    property color surfaceColor: Theme.surface
    // Assigned by the engine (the content contract): which side of the popup
    // is its bar, for the rows' side clip at the rounded corners.
    property var hostRoom: null
    // Device px per px (a magnified mockup stage): the pin flight's layer is
    // rendered at it.
    property real renderScale: root.style ? root.style.renderScale : 1

    // ---- tunables (the mockup's panel binds these) -------------------------------------
    property string fontFamily: root.style ? root.style.fontFamily : "Inter"
    property real managerWidth: root.style ? root.style.managerWidth : 420
    property real maxListHeight: root.style ? root.style.maxListHeight : 560
    property real padding: root.style ? root.style.managerPadding : 12
    // A header's own margin above and below its box: 12 between two groups,
    // 6 from a header to its first card (its margin below).
    property real sectionGap: root.style ? root.style.sectionGap : 6
    // Between two cards (a group's rows, a bundle's cards): 6. It stands under
    // each row, so an open group's last card adds it to the next header's
    // margin above.
    property real rowGap: root.style ? root.style.rowGap : 6
    property int rowAnimMs: root.style ? root.style.rowAnimMs : 240
    property int staggerMs: root.style ? root.style.staggerMs : 55
    // A single arrival grows its room in place over this, OutCubic, and fades
    // in over presenceMs (the toast's clocks).
    property int arriveMs: root.style ? root.style.enterMs : 260
    property int presenceMs: root.style ? root.style.presenceMs : 160
    // A bundle's cards unfolding and folding.
    // Clear all coming and going (presence and width, one clock), and the gap
    // it keeps from the do-not-disturb toggle.
    property int buttonMs: root.style ? root.style.buttonMs : 260
    property real buttonGap: root.style ? root.style.buttonGap : 12
    // The popup's resting corner radius (the engine's maxR): the corners a
    // displaced card's side cut and the pin flight's cut follow when no
    // `cornerRadii` is handed. (The rows' clip itself is a straight line
    // `clipInset` from each side at any radius; the cuts keep off the curve.)
    property real popupRadius: 20
    // The popup's corners as the engine DRAWS them, [tl, tr, br, bl] (a host
    // hands GooeyEngine.popupCornerRadii; null: `popupRadius` on every corner
    // that is not the bar's). A corner beside a bar's end is drawn rounder
    // than the resting radius -- the fillet into the bar: 32.1 px where the
    // mockup's flush placement rests 14 px below the right bar's end -- and
    // the pin flight's cut at 20 there let its shadow out (8 levels, 6 px).
    // The side cut and the flight's cut follow it.
    property var cornerRadii: null
    // The list follows a group opened at its foot (list_animation.md).
    property bool followOpen: root.style ? root.style.followOpen : true
    property int liveSettleFrames: root.style ? root.style.liveSettleFrames : 2
    property string title: root.style ? root.style.managerTitle : "Notifications"
    property string emptyTitle: root.style ? root.style.emptyTitle : "No notifications"
    property int undoMs: root.service && root.service.config && root.service.config.undoMs
        ? root.service.config.undoMs : 10000
    // The pin flight (RowFlight).
    property int flightLiftMs: root.style ? root.style.flightLiftMs : 160
    property int flightTravelMs: root.style ? root.style.flightTravelMs : 340
    property int flightLandMs: root.style ? root.style.flightLandMs : 160
    property real flightLiftScale: root.style ? root.style.flightLiftScale : 1.03
    property int flightPreMoveDelayMs: root.style ? root.style.flightPreMoveDelayMs : 100
    property int flightPreDropDelayMs: root.style ? root.style.flightPreDropDelayMs : 100
    // The lifted clone's shadow, kept inside the 12 px padding (1 / 4;
    // RowFlight's own 10 / 24 reaches 41 px past the row).
    property real flightShadowSpread: root.style ? root.style.flightShadowSpread : 1
    property real flightShadowBlur: root.style ? root.style.flightShadowBlur : 4

    // ---- content contract --------------------------------------------------------
    readonly property string keyboardFocusRequest: root.openedByKeyboard ? "exclusive" : "onDemand"
    // THE RELEASE OF AN EXCLUSIVE MANAGER. Opened by a key, IPC or "+N more" there is no pointer
    // resting on the layer to hand the keys to, so the manager holds the keyboard exclusively for
    // as long as it is open -- and under Exclusive no window receives any pointer at all,
    // so a click elsewhere would reach nobody and the keys would never be given
    // back. It asks the engine for the whole track as input (`maskCatchAll`): a press on no body
    // and no bar lands on the engine's void catcher, which calls `outsidePress()`, and the manager
    // closes. Opened by a click on the bell (on demand) it asks for neither: the pointer is on the
    // layer, and a click elsewhere is an ordinary click.
    readonly property bool maskCatchAll: root.openedByKeyboard
    function outsidePress() {
        if (root.service)
            root.service.closeManagerRequested();
    }
    readonly property bool swipeGestureActive: reader.active
    property real gestureHoldWidth: 0
    property real gestureHoldHeight: 0
    function gestureWheel(ev) {
        return reader.gestureWheel(ev);
    }
    onSwipeGestureActiveChanged: {
        if (root.swipeGestureActive) {
            root.gestureHoldWidth = root.width;
            root.gestureHoldHeight = root.height;
        }
    }
    readonly property bool liveResizeActive: root._live
    // While live, the engine's input mask stays the popup's BOX (not the
    // whole engine): a click beside a moving manager reaches the shell
    // (the engine's content contract).
    property string liveResizeMask: "box"
    // The list's wave, for a probe (busy, follow, followTopPx).
    readonly property QtObject listWave: wave

    readonly property var groupOrder: ["critical", "system", "normal", "low"]

    property string filter: ""
    property string openGroup: ""
    property string highlightKey: ""         // "h:<group>" or an entry key
    // The notification the highlight is on: a pin renames its entry
    // ("a:app" -> "p:uid"), or takes the head out of its app's row, which
    // keeps its key -- either way the highlight follows the notification to
    // the row that holds it now (Ctrl+P on a bundle's head flies the
    // rim to the pin, and the highlight must not stay on the row it came from). A row
    // that still holds it keeps the highlight (a new head folded it in). The
    // notification gone, the highlight stays with its row and takes what the
    // row shows now: a key that outlived its record (its app's row emptied
    // and filled again) would otherwise follow a uid nothing holds.
    property string _highlightUid: ""
    onHighlightKeyChanged: {
        const u = root.highlightKey.indexOf("h:") === 0 ? "" : root._uidOfKey(root.highlightKey);
        if (u !== "" || root.highlightKey === "")
            root._highlightUid = u;
    }
    function _keepHighlight() {
        const k = root.highlightKey, u = root._highlightUid;
        if (k === "" || k.indexOf("h:") === 0)
            return;
        if (u !== "")
            for (const g of root.groupOrder)
                for (const e of root._data[g] ? root._data[g].entries : [])
                    if (("|" + e.uidList + "|").indexOf("|" + u + "|") >= 0) {
                        if (e.key !== k)
                            root.highlightKey = e.key;
                        return;
                    }
        root._highlightUid = root._uidOfKey(k);
    }
    property var _data: ({})                 // group -> { entries, count, pins, newest }
    property int _dataSerial: 0
    property string _latestGroup: ""
    property int _totalAll: 0
    // What Clear all would clear: the unpinned records shown (under a filter,
    // the ones it shows -- clearAll() passes them). Its button is there only
    // while this is something (a filter that shows nothing, or only
    // pins, would leave a button that clears nothing).
    property int _clearable: 0

    // The style's palette (a host overrides a group's colour there, once).
    readonly property GroupPalette _groups: root.style && root.style.groups ? root.style.groups : ownGroups
    GroupPalette {
        id: ownGroups
    }

    // ---- the data: per group, entries (pins alone, the rest one per app) -----------
    function _match(d, q) {
        return !!Fuzzy.best(q, [d.summary || "", d.bodyText || "", d.appName || ""], [1.0, 0.7, 0.8]);
    }
    // The folded line's preview of a record: its summary, else its body, else
    // its app's name -- never nothing after the dot. One line and
    // plain text are the header's (ListSectionHeader subtitleOneLine, PlainText).
    function _preview(d) {
        for (const s of [d.summary, d.bodyText, d.appName]) {
            const t = String(s || "").trim();
            if (t !== "")
                return t;
        }
        return "";
    }
    // Whether the user is searching, read from the query ITSELF wherever it
    // decides something: a `filtering` binding read inside onFilterChanged is
    // still the previous generation's, so every filter change would open and
    // fold the rows by the mode before it (headers
    // open with no rows under them while searching, folded headers over their
    // cards once the query was cleared). Derive a pair of facts from
    // ONE read.
    function _filtering() {
        return root.filter.trim() !== "";
    }
    function _compute() {
        const out = {};
        for (const g of root.groupOrder)
            out[g] = { entries: [], count: 0, pins: 0, newest: "", uids: [], records: [] };
        let total = 0, clearable = 0;
        const everything = [];
        const svc = root.service;
        if (svc && svc.store) {
            const all = svc.store.all();
            const q = root.filter.trim();
            for (let i = 0; i < all.length; i++) {
                const d = all[i];
                if (!out[d.group])
                    continue;
                total++;
                if (q !== "" && !root._match(d, q))
                    continue;
                if (!d.pinned)
                    clearable++;
                const g = out[d.group];
                g.records.push(d);
                everything.push(d);
                g.uids.push(d.uid);
                g.count++;
                if (d.pinned)
                    g.pins++;
            }
            for (const gk of root.groupOrder) {
                const g = out[gk];
                // The newest by the policy's tie-break: a burst in one
                // millisecond previews its LAST record.
                const n = Policy.newest(g.records);
                g.newest = n ? root._preview(n) : "";
                // Pins first, each its own row; then ONE row per app (a
                // single notification is a bundle of one), keyed by the app
                // so its second notification makes it a bundle in place.
                for (const d of g.records.filter(r => r.pinned))
                    g.entries.push({ key: "p:" + d.uid, uid: d.uid, uidList: d.uid });
                for (const b of Policy.bundle(g.records.filter(r => !r.pinned), 1)) {
                    if (b.records && b.records.length > 0)
                        g.entries.push({ key: "a:" + b.appKey, uid: b.records[0].uid,
                                         uidList: b.records.map(r => r.uid).join("|") });
                    else if (b.record)
                        g.entries.push({ key: "u:" + b.record.uid, uid: b.record.uid, uidList: b.record.uid });
                }
                delete g.records;
            }
        }
        // The group that last RECEIVED a notification, by the policy's own "newest" (a tie goes to the record the
        // store put last).
        const latest = Policy.newest(everything);
        root._latestGroup = latest ? latest.group : "";
        root._totalAll = total;
        root._clearable = clearable;
        // A record that has gone takes its opened body with it.
        for (const u of Object.keys(root._expanded))
            if (!svc || !svc.store.get(u))
                delete root._expanded[u];
        root._data = out;
        root._dataSerial++;
    }
    function _visible(g) {
        return !!root._data[g] && root._data[g].count > 0;
    }
    function isOpen(g) {
        return root._filtering() ? root._visible(g) : root.openGroup === g;
    }

    // ---- one change, one choreography ------------------------------------------------
    // Every change of the data runs through here: computed once, handed to the
    // sections with the way it should move (GroupSection: instant / arrive /
    // wave), and what they gathered goes to ListWave in layout order.
    function _refresh(mode) {
        root._liveOn();
        root._compute();
        root._keepHighlight();
        root._applyAll(mode);
    }
    function _applyAll(mode) {
        const retire = [], incoming = [];
        for (let i = 0; i < sectionRep.count; i++) {
            const s = sectionRep.itemAt(i) as GroupSection;
            if (!s)
                continue;
            s.apply(root._data[s.group], mode);
            retire.push.apply(retire, s.takeRetire());
            incoming.push.apply(incoming, s.takeIncoming());
        }
        root._wave(retire, incoming);
    }
    function _wave(retire, incoming) {
        if (retire.length > 0)
            wave.collapse(retire);
        if (incoming.length > 0)
            wave.expand(incoming);
    }
    // Rows a section gathered outside a change of the data (a bundle opened
    // or folded: its members are rows of the list like any other).
    function _flushWave() {
        const retire = [], incoming = [];
        for (let i = 0; i < sectionRep.count; i++) {
            const s = sectionRep.itemAt(i) as GroupSection;
            if (!s)
                continue;
            retire.push.apply(retire, s.takeRetire());
            incoming.push.apply(incoming, s.takeIncoming());
        }
        if (retire.length === 0 && incoming.length === 0)
            return;
        root._liveOn();
        root._wave(retire, incoming);
    }
    // A service call that changes many records (a clear, an undo) is ONE
    // change here: the store bumps its serial per record.
    property bool _batching: false
    function _batch(mode, fn) {
        root._batching = true;
        try {
            fn();
        } finally {
            root._batching = false;
        }
        root._refresh(mode);
    }

    Connections {
        target: root.service
        enabled: !root.parked
        ignoreUnknownSignals: true
        function onSerialChanged() {
            if (!root._batching)
                root._refresh(root._filtering() ? "instant" : "arrive");
        }
    }
    onFilterChanged: {
        if (root.parked)
            return;
        root._refresh("instant");
        root._applyInstant();
    }
    // Set once the opening state has been written: until then nothing in the
    // top row animates (a manager opened with notifications shows its Clear
    // all at once).
    property bool _ready: false
    // The group that is open when the manager opens (notifications.jsonc manager.openGroup).
    function _startGroup() {
        const want = root.service && root.service.config ? root.service.config.manager.openGroup : "latest";
        if (want === "latest")
            return root._latestGroup;
        if (want === "none")
            return "";
        return want === "first" ? Policy.GROUPS.find(g => root._visible(g)) || "" : want;
    }
    // The data and the rows, written instantly: all a PARKED content does at completion (its size is
    // then right), and the first half of the opening.
    function _build() {
        root._compute();
        root.openGroup = root._startGroup();
        root._applyAll("instant");
        root._applyInstant();
    }
    // THE OPENING: what a manager does when it is shown -- at completion for a content built unparked,
    // when `parked` turns false for one built or kept parked. Everything a parked content did not do.
    function _open() {
        root._ready = false;
        root.filter = "";
        root.highlightKey = "";
        root._build();
        root._syncUndo();
        root._syncWiki();
        if (root.service && root.service.markSeen)
            root.service.markSeen();
        root.forceActiveFocus();
        root._ready = true;
    }
    // THE SILENCE: back to parked (a closed manager kept for the next open). The live follower stops,
    // a flight in the air is let go, the undo button's drain stops (the opening re-arms it from the
    // service's offer), and the opening's state is cleared.
    function _quiesce() {
        root._live = false;
        root._still = 0;
        root._ready = false;
        flight.cancel();
        if (root._armedToken !== "") {
            root._armedToken = "";
            header.disarm();
        }
        root.filter = "";
        root.highlightKey = "";
    }
    // (An initial `parked` is applied before the children exist: only a CHANGE after completion acts.)
    property bool _completed: false
    onParkedChanged: {
        if (!root._completed)
            return;
        if (root.parked)
            root._quiesce();
        else
            root._open();
    }
    Component.onCompleted: {
        if (root.parked)
            root._build();
        else
            root._open();
        root._completed = true;
    }

    // ---- the accordion -----------------------------------------------------------
    function _section(g) {
        for (let i = 0; i < sectionRep.count; i++) {
            const s = sectionRep.itemAt(i) as GroupSection;
            if (s && s.group === g)
                return s;
        }
        return null;
    }
    function toggleGroup(g) {
        if (root._filtering())
            return;
        const before = root.openGroup;
        const next = before === g ? "" : g;
        const outRows = before !== "" && root._section(before) ? root._section(before).rowItems() : [];
        const inRows = next !== "" && root._section(next) ? root._section(next).rowItems() : [];
        root._liveOn();
        root.openGroup = next;
        wave.swap(outRows, inRows);
    }
    // Open or fold without a wave: the popup opening, the filter.
    function _applyInstant() {
        root._liveOn();
        for (let i = 0; i < sectionRep.count; i++) {
            const s = sectionRep.itemAt(i) as GroupSection;
            if (s)
                s.setRowsInstant(root.isOpen(s.group));
        }
    }

    // ---- clears and the one undo slot ----------------------------------------------
    // The slot is the service's `undoState`: the LATEST clear on offer, or null
    // (taken, expired, emptied by its apps). The button is armed for a new
    // offer and disarmed when it ends; its words are the offer's, kept once
    // it has ended so the leaving button still says them (ManagerHeader).
    property string _armedToken: ""
    property string _undoWords: "Undo"
    function _syncUndo() {
        const u = root.service ? root.service.undoState : null;
        if (u && u.token !== root._armedToken) {
            root._armedToken = u.token;
            root._undoWords = u.kind === "group" ? "Undo clear " + root._groups.title(u.group) : "Undo";
            header.arm(Math.max(0, u.deadlineMs - Date.now()));
        } else if (!u && root._armedToken !== "") {
            root._armedToken = "";
            header.disarm();
        }
    }
    Connections {
        target: root.service
        enabled: !root.parked
        ignoreUnknownSignals: true
        function onUndoStateChanged() {
            root._syncUndo();
        }
    }
    // Under a filter Clear all stands for what the filter shows, in every
    // group, and its undo brings back exactly those (DATA's clearAll(uids)).
    function clearAll() {
        if (!root.service)
            return;
        const only = root._filtering()
            ? root.groupOrder.reduce((a, g) => a.concat(root._data[g] ? root._data[g].uids : []), []) : undefined;
        root._batch("wave", () => root.service.clearAll(only));
        root._shakeKept(only);
    }
    // The records a clear leaves because they are kept say no: each shakes once, to the left.
    function _shakeKept(only) {
        for (const r of root.service.store.all()) {
            if (r.kept !== true || (only && only.indexOf(r.uid) < 0))
                continue;
            const c = root._cardOf(r.uid) as NotificationRow;
            if (c)
                c.refuse(-1);
        }
    }
    // Under a filter a header stands for the rows it shows: only those go,
    // and the undo brings back exactly them.
    function clearGroup(g) {
        if (!root.service)
            return;
        const only = root._filtering() && root._data[g] ? root._data[g].uids : undefined;
        const shown = root._data[g] ? root._data[g].uids.slice() : [];
        root._batch("wave", () => root.service.clearGroup(g, only));
        root._shakeKept(shown);
    }
    function undo() {
        const u = root.service ? root.service.undoState : null;
        header.disarm();
        if (u)
            root._batch("wave", () => root.service.undo(u.token));
    }
    readonly property string undoText: root._undoWords

    // ---- the box follows the rows ------------------------------------------------
    property bool _live: false
    property int _still: 0
    property real _lastH: -1
    function _liveOn() {
        if (root.parked)
            return;
        root._still = 0;
        root._live = true;
    }
    onImplicitHeightChanged: root._liveOn()
    onImplicitWidthChanged: root._liveOn()
    FrameAnimation {
        running: root._live && !root.parked
        onTriggered: {
            const h = root.implicitHeight;
            if (h === root._lastH && !wave.busy && !flight.active && !root._wikiMoving) {
                root._still++;
                if (root._still >= root.liveSettleFrames)
                    root._live = false;
            } else {
                root._still = 0;
            }
            root._lastH = h;
        }
    }

    // ---- the wiki's card --------------------------------------------------------------
    // `_wikiOn` is the decision -- a wiki, nothing to show, no undo on offer --
    // taken by `_syncWiki` AFTER the turn's writes have landed: an Undo
    // disarms the button before the service brings the records back, and a
    // binding on `header.undoing` and `_totalAll` saw that instant as an empty
    // manager and built the card for nothing (one binding that reads
    // two others can see them from different generations). The opening state
    // is decided in the completion, before `_ready`, so a manager that opens
    // empty has its card at once, as its Clear all comes at once.
    property bool _wikiOn: false
    // The card exists from the moment it is wanted to the end of its leave.
    property bool _wikiBuilt: false
    // The card's height as it reports it (0: nothing to show, it collapsed),
    // and the last height it had: a card that empties while it is up leaves on
    // the room it had instead of stepping out.
    readonly property real _wikiItemH: wikiLoader.item ? (wikiLoader.item as Item).implicitHeight : 0
    property real _wikiHeld: 0
    on_WikiItemHChanged: {
        if (root._wikiItemH > 0)
            root._wikiHeld = root._wikiItemH;
    }
    readonly property real _wikiTarget: root._wikiOn && root._wikiItemH > 0 ? 1 : 0
    // ONE clock for the card's presence and its share of the box.
    property real _wikiF: root._wikiTarget
    Behavior on _wikiF {
        enabled: root._ready
        NumberAnimation {
            duration: root.arriveMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property bool _wikiMoving: root._wikiF !== root._wikiTarget
    // The card's room: 12 above it (under the top row) and 12 below (the foot).
    readonly property real _wikiGap: root.padding
    function _syncWiki() {
        if (root.parked)
            return;
        const on = !!root.wiki && root._totalAll === 0 && !header.undoing;
        if (on !== root._wikiOn) {
            root._liveOn();
            if (on)
                root._wikiBuilt = true;
            root._wikiOn = on;
        }
        root._wikiUnbuild();
    }
    // Gone and not coming: the card is taken down.
    function _wikiUnbuild() {
        if (!root._wikiOn && root._wikiF <= 0)
            root._wikiBuilt = false;
    }
    on_WikiFChanged: root._wikiUnbuild()
    on_TotalAllChanged: {
        if (root._ready)
            Qt.callLater(root._syncWiki);
    }
    onWikiChanged: Qt.callLater(root._syncWiki)
    Connections {
        target: header
        function onUndoingChanged() {
            if (root._ready)
                Qt.callLater(root._syncWiki);
        }
    }
    // The card was chosen: the wiki opens its full card (the clock popup
    // takes it up), and this manager goes. The card's On-this-day line is the
    // same door; with Ctrl it is the rabbit hole's first step -- that article
    // is loaded into the card the wiki opens.
    // NOT named `openWiki`: that is the clock popup's content contract (a string tab), and the clock owner, handing a request to "the content
    // on show" while the engine still shows THIS one (a travel swaps the content a fade later), would take the manager for the clock's content and
    // call it with "discover" -- a truthy followOtd: followOnThisDay + another request, for ever.
    function openWikiCard(followOtd: bool) {
        const w = root.wiki, svc = root.service;
        if (!w)
            return;
        if (followOtd)
            w.followOnThisDay();
        w.requestOpen("discover");
        if (svc)
            svc.closeManagerRequested();
    }

    // ---- layout ----------------------------------------------------------------------
    // The width the content ASKED for (see the head of the file); the list is
    // that less the padding on both sides.
    readonly property real _W: root.implicitWidth
    readonly property real listWidth: root._W - root.padding * 2
    // The rows carry their gaps (a header 6 above and below its box, a card 6
    // below), so the list's ends hold one gap of empty room each: the list
    // sits `padding - gap` under the top row and over the foot, and the
    // popup's padding comes out equal above and below. The clip keeps 2 px of
    // that room for the boxes' bevels (`_s` is the rest, hidden past it).
    readonly property real _colH: sections.height
    readonly property real _listVis: Math.min(root.maxListHeight, root._colH)
    readonly property real _s: Math.max(0, Math.min(root.sectionGap, root.rowGap) - 2)
    // Empty, the popup is the top row with `padding` under it; with a list,
    // `padding - sectionGap` at either end of it. One fraction of the list's
    // own height takes one to the other (the same with the defaults).
    readonly property real _listF: Math.min(1, root._listVis / Math.max(1, 2 * root.sectionGap))
    readonly property real _inset: root.padding / 2 + (root.padding - root.sectionGap - root.padding / 2) * root._listF
    readonly property real _listTop: root.padding + header.implicitHeight + root._inset

    implicitWidth: Math.ceil(root.managerWidth)
    // The card's share is whole pixels: its height and the 12 above it, times
    // its fraction, over the list's own room. An empty list's room is the
    // popup's padding under the top row and over the foot, so the card ends
    // 12 above the foot. Zero without a wiki, to the pixel.
    implicitHeight: Math.ceil(root._listTop + root._listVis + root._inset)
        + Math.round(root._wikiF * (root._wikiHeld + root._wikiGap))

    ManagerHeader {
        id: header
        x: root.padding
        y: root.padding
        width: root.listWidth
        // Empty is nothing to show AND nothing to undo: while the undo window
        // runs the history can still come back, and the button's reserved
        // width leaves the longer title no room. The words swap once the
        // button has gone.
        title: root._totalAll === 0 && !header.undoing && header.buttonFraction < 0.001 ? root.emptyTitle : root.title
        query: root.filter
        dnd: root.service ? !!root.service.dnd : false
        present: root._clearable > 0 || header.undoing
        animatePresence: root._ready
        undoText: root.undoText
        reserveWords: root.groupOrder.map(g => "Undo clear " + root._groups.title(g))
        undoMs: root.undoMs
        buttonMs: root.buttonMs
        buttonGap: root.buttonGap
        fontFamily: root.fontFamily
        surfaceColor: root.surfaceColor
        titleSize: root.style ? root.style.managerTitleSize : 16
        dndLabelSize: root.style ? root.style.dndLabelSize : 11
        searchGlyphSize: root.style ? root.style.searchGlyphSize : 14
        buttonTextSize: root.style ? root.style.headerButtonTextSize : 12
        buttonHeight: root.style ? root.style.headerButtonHeight : 30
        dndLabelGap: root.style ? root.style.dndLabelGap : 10
        titleGap: root.style ? root.style.titleGap : 12
        searchGlyphGap: root.style ? root.style.searchGlyphGap : 6
        onDndToggled: on => {
            if (root.service)
                root.service.dnd = on;
        }
        onClearAllClicked: root.clearAll()
        onUndoClicked: root.undo()
    }

    // The rows' strip: the popup's full width over the list's clip span. The
    // rows are clipped on a straight line SideFade's `clipInset` from each
    // side; a card swiped or flown sideways cuts and fades ITSELF before that
    // line, and in a corner's rows before the curve (SideFade's cut, the
    // outline as drawn), so it never meets a hard edge and never reaches the
    // popup's outline.
    Item {
        id: rowStrip
        y: root._listTop + root._s
        width: root._W
        height: Math.max(0, root._listVis - 2 * root._s)
    }
    readonly property var _radii: {
        const c = root.cornerRadii;
        if (c && c.length === 4)
            return [c[0], c[1], c[2], c[3]];
        const r = root.popupRadius;
        const e = root.hostRoom ? root.hostRoom.edge : "";
        return e === "top" ? [0, 0, r, r] : e === "bottom" ? [r, r, 0, 0]
             : e === "left" ? [0, r, r, 0] : e === "right" ? [r, 0, 0, r] : [r, r, r, r];
    }

    Flickable {
        id: flick
        x: fade.clipInset
        y: rowStrip.y
        width: root._W - 2 * fade.clipInset
        height: rowStrip.height
        interactive: false
        clip: true
        contentWidth: width
        contentHeight: Math.max(0, root._colH - 2 * root._s)

        Column {
            id: sections
            x: root.padding - fade.clipInset
            y: -root._s
            width: root.listWidth
            spacing: 0

            Repeater {
                id: sectionRep
                model: root.groupOrder

                GroupSection {
                    id: sec
                    required property string modelData
                    group: sec.modelData
                    open: root._dataSerial >= 0 && root.isOpen(sec.modelData)
                    service: root.service
                    clock: root.clock
                    overlayItem: overlay
                    groups: root._groups
                    sectionWidth: root.listWidth
                    style: root.style
                    surfaceColor: root.surfaceColor
                    highlightKey: root.highlightKey
                    arriveMs: root.arriveMs
                    presenceMs: root.presenceMs
                    rowGap: root.rowGap
                    headGap: root.sectionGap
                    pinHandler: (uid, item) => root.pinWithFlight(uid, item)
                    flightUid: flight.active ? flight.key : ""
                    flightReveal: flight.reveal
                    sideFade: fade
                    // A bundle's first member opens under its head CARD, which
                    // may rise to the top fade's foot.
                    memberFollowTopPx: dressing.fadeHeight
                    holdToken: root.service && root.service.undoState ? String(root.service.undoState.token) : ""
                    expandedStore: root._expanded
                    onToggleRequested: root.toggleGroup(sec.modelData)
                    onClearRequested: root.clearGroup(sec.modelData)
                    onWaveWanted: root._flushWave()
                }
            }
        }
    }

    ScrollDressing {
        id: dressing
        anchors.fill: flick
        flick: flick
        ground: root.surfaceColor
        fadeHeight: root.style ? root.style.listFadeHeight : 34
        scrollSpeed: (root.style ? root.style.listScrollStep : 120) / 120
        wheelEnabled: !flight.scrollLocked
    }

    // The wiki's card under the top row, at the list's foot: a row that arrives
    // grows its room above it and pushes it down and out. Fixed at the top of
    // its own room (the growing box reveals it), and no input while it leaves.
    Loader {
        id: wikiLoader
        active: root._wikiBuilt
        enabled: root._wikiOn
        visible: root._wikiF > 0
        opacity: root._wikiF
        x: root.padding
        y: root.padding + header.implicitHeight + root._wikiGap + root._listVis
        width: root.listWidth
        height: root._wikiItemH
        sourceComponent: WikiCompactCard {
            service: root.wiki
            tab: "discover"
            variant: "wide"
            groundColor: root.surfaceColor
            fontFamily: root.fontFamily
            renderScale: root.renderScale
            radius: root.style ? root.style.cardRadius : 14
            collapseWhenEmpty: true
            onActivated: root.openWikiCard(false)
            onOnThisDayActivated: follow => root.openWikiCard(follow)
        }
    }

    // The rows' side cut and fade (SideFade draws nothing: every card handed
    // it cuts and fades itself while it is displaced). The outline is the
    // box AS DRAWN this frame -- the content item is the engine's box -- with
    // its corners (`cornerRadii`, else the resting radius); its long ramp is
    // the list's own fade length.
    SideFade {
        id: fade
        target: rowStrip
        inset: root.style ? root.style.sideFadeInset : 2
        rimPx: root.style ? root.style.sideFadeRimPx : 2
        leadPx: root.style ? root.style.sideFadeLeadPx : 1
        cornerMargin: root.style ? root.style.sideFadeCornerMargin : 1
        fadeLength: dressing.fadeHeight
        outline: ({ x: 0, y: -rowStrip.y, w: root.width > 0 ? root.width : root._W,
                    h: root.height > 0 ? root.height : root.implicitHeight, radii: root._radii })
    }

    SwipeVerbReader {
        id: reader
        anchors.fill: flick
        units: root.style ? root.style.swipeUnits : 900
        flingUnitsPerS: root.style ? root.style.swipeFlingUnitsPerS : 2600
        pullThrough: root.style ? root.style.swipePullThrough : 2.0
        idleMs: root.style ? root.style.swipeIdleMs : 6000
        mouseIdleMs: root.style ? root.style.swipeMouseIdleMs : 400
        sign: root.style ? root.style.swipeSign : 1
        rowAt: (x, y) => {
            const p = reader.mapToItem(sections, x, y);
            let item = sections.childAt(p.x, p.y);
            let local = sections.mapToItem(item, p.x, p.y);
            // Walk down to the SwipeVerbCard under the point.
            for (let depth = 0; item && depth < 16; depth++) {
                // A row already on its way out takes no new gesture.
                const wrapper = item as AnimatedListRow;
                if (wrapper && wrapper.rowState !== "rest")
                    return null;
                const card = item as SwipeVerbCard;
                if (card)
                    return card;
                const next = item.childAt(local.x, local.y);
                if (!next)
                    break;
                local = item.mapToItem(next, local.x, local.y);
                item = next;
            }
            return null;
        }
    }

    ListWave {
        id: wave
        view: flick
        animMs: root.rowAnimMs
        staggerMs: root.staggerMs
        follow: root.followOpen
        // An accordion opened at the foot scrolls with its rows until the
        // header they open under would pass under the top fade: the header's
        // box stays below the band (its slot starts one gap above the box).
        followTopPx: dressing.fadeHeight - root.sectionGap
        // The view is min(cap, content): every plan is judged at the height it
        // grows to, so a group opened at the foot of a short list is followed
        // once the view has reached its cap (the flick's height
        // is the list's less the bevel slack at both ends).
        viewMaxHeight: Math.max(0, root.maxListHeight - 2 * root._s)
    }

    // ---- the pin flight: every pin and unpin is a flown move ---------------------
    // The clone shows the record as it will be once it has landed: its pin
    // flipped, its body open if the user opened it, the keyboard's rim if the
    // card carried it. It lifts off where the card's face IS
    // -- a pin swiped right is released half a card to the right -- and the
    // face is not drawn while it flies (the card's `faceHidden`, through the
    // flight's key: AppBundleRow), so the swipe's well fades where it was.
    // Under a filter the flight is the same. It lifts off
    // as the card it replaces and lands as the card it becomes -- a bundle's
    // head says "+1 more from Signal" and has a chevron, a pin does not (the
    // clone's two faces, below).
    property bool _ghostFlip: false
    // uid -> true: the cards whose body is open in full (NotificationRow).
    readonly property var _expanded: ({})
    // A pin while another flies waits for the air to clear, then flies:
    // falling back to a toggle in place would be a leave and an enter, and the
    // first flight would then land on the wrong card.
    property var _pinQueue: []
    function pinWithFlight(uid, cardItem) {
        const svc = root.service;
        if (!svc || uid === "")
            return;
        const d = svc.store.get(uid);
        if (!d)
            return;
        if (flight.active) {
            if (flight.key !== uid && root._pinQueue.indexOf(uid) < 0)
                root._pinQueue = root._pinQueue.concat([uid]);
            return;
        }
        const card = cardItem as NotificationRow;
        if (!card) {
            svc.togglePin(uid);
            return;
        }
        root._liveOn();
        root._ghostFlip = false;
        // The rim flies with the clone: the highlight follows this record.
        if (card.highlighted)
            root._highlightUid = uid;
        flight.begin(uid, card, { d: d, from: root._faceOf(card), highlighted: card.highlighted }, card.faceItem);
    }
    // A card's face as the clone needs it: the line under its text, its
    // chevron, its body (or bundle) open, its height.
    function _faceOf(card) {
        return { footnote: card.shownFootnote, chevron: card.chevronShown, expanded: card.faceExpanded,
                 h: card.implicitHeight };
    }
    readonly property var _bareFace: ({ footnote: "", chevron: false, expanded: false, h: 0 })
    // The face the flight lands as: its destination's, once there is one to
    // land on (a card that shows the record; a folded bundle's slot has none).
    // A getter: it only reads.
    function _destFace(uid) {
        const c = root._flightDest(uid) as NotificationRow;
        return c && c.d && c.d.uid === uid ? root._faceOf(c) : null;
    }
    // The footnote's line in a NotificationCard: the text column's one
    // plain-text line (its body is StyledText). A READ of the card's layout,
    // for the clone's morph alone -- the card has no presence for that line;
    // with one, the morph is one card and this goes.
    function _footLine(card) {
        for (const c of card.children) {
            const col = c as Column;
            if (!col)
                continue;
            for (const t of col.children) {
                const tx = t as Text;
                if (tx && tx.textFormat === Text.PlainText)
                    return tx;
            }
        }
        return null;
    }
    function _nextPin() {
        if (flight.active || root._pinQueue.length === 0)
            return;
        const q = root._pinQueue.slice();
        const uid = q.shift();
        root._pinQueue = q;
        if (root.service && root.service.store.get(uid))
            root.pinWithFlight(uid, root._cardOf(uid));
        else
            root._nextPin();
    }
    // Where the record's card is in its group's entries -- as a row's head
    // (or alone) at the entry's index, as a member folded or unfolded under a
    // head half a step after it: a member pinned from a bundle at the group's
    // top lands at the same index, and is still a move.
    function _entryIndexOf(uid) {
        for (const g of root.groupOrder) {
            const gd = root._data[g];
            if (!gd)
                continue;
            const i = gd.entries.findIndex(e => ("|" + e.uidList + "|").indexOf("|" + uid + "|") >= 0);
            if (i >= 0)
                return i + (gd.entries[i].uidList.split("|")[0] === uid ? 0 : 0.5);
        }
        return -1;
    }
    // How far the flight had opened its destination before it ended (1: the
    // travel ran; 0: it never travelled -- RowFlight's end opens it at once).
    property real _revealNow: 1
    property real _revealPrev: 1
    property double _revealAt: 0
    Connections {
        target: flight
        function onRevealChanged() {
            root._revealPrev = root._revealNow;
            root._revealNow = flight.reveal;
            root._revealAt = Date.now();
        }
        function onEnded() {
            Qt.callLater(root._nextPin);
        }
    }
    function _flightDest(uid) {
        for (let i = 0; i < sectionRep.count; i++) {
            const s = sectionRep.itemAt(i) as GroupSection;
            if (!s || !s.open)
                continue;
            const c = s.cardFor(uid);
            if (c)
                return c;
            // Folded inside its app's bundle: it lands on the bundle's head.
            const b = s.slotHolding(uid);
            if (b)
                return b;
        }
        return null;
    }
    function _phantom() {
        for (let i = 0; i < sectionRep.count; i++) {
            const s = sectionRep.itemAt(i) as GroupSection;
            const p = s ? s.phantomSlot() : null;
            if (p)
                return p;
        }
        return null;
    }
    // Where the card will REST, asked of the layout it will have: its slot
    // may still be at zero height (opening with the flight), and the hole
    // above it is about to close.
    function _flightDestTop(item, uid) {
        const c = root._flightDest(uid);
        if (!c)
            return NaN;
        // The ENTRY's slot: a member's card sits in a row of its own, in the
        // tail of its entry's.
        let slot = c as Item;
        while (slot && !((slot as ManagerSlot) && (slot.parent as GroupSection)))
            slot = slot.parent;
        let sec = slot ? slot.parent : null;
        while (sec && !(sec as GroupSection))
            sec = sec.parent;
        const gs = sec as GroupSection;
        // (The card's place in its slot as it will rest: the bundle's sum, not
        // a member's stale place; less the slot's reorder translate, not a
        // frame of that motion.)
        const ms = slot as ManagerSlot;
        const b = ms ? ms.bodyItem as AppBundleRow : null;
        const inBundle = b ? b.restTopOf(uid) : NaN;
        const off = !isNaN(inBundle) ? b.mapToItem(slot, 0, 0).y - ms.flipY + inBundle
            : c.mapToItem(slot, 0, 0).y - (ms ? ms.flipY : 0);
        let y = slot && gs ? gs.slotTopIn(slot, item) + off : c.mapToItem(item, 0, 0).y;
        const ph = root._phantom();
        if (ph && ph.mapToItem(item, 0, 0).y < y)
            y -= ph.height;
        return y;
    }

    RowFlight {
        id: flight
        anchors.fill: parent
        flick: flick
        overlayItem: flightLayer
        liftMs: root.flightLiftMs
        travelMs: root.flightTravelMs
        landMs: root.flightLandMs
        exitMs: root.rowAnimMs
        liftScale: root.flightLiftScale
        preMoveDelayMs: root.flightPreMoveDelayMs
        preDropDelayMs: root.flightPreDropDelayMs
        liftShadowSpread: root.flightShadowSpread
        liftShadowBlur: root.flightShadowBlur
        // The card paints its own opaque face.
        backingColor: "transparent"
        // Lifted off a displaced face: drawn through the rows' side cut while
        // it swings back into its column, and its shadow kept to
        // the rows' clip -- the side padding is ground.
        sideFade: fade
        cloneRadius: root.style ? root.style.cardRadius : 14
        shadowBounds: Qt.rect(flick.x, flick.y, flick.width, flick.height)

        findDest: uid => root._flightDest(uid)
        destTopIn: (item, uid) => root._flightDestTop(item, uid)
        sourceTopIn: (item, uid) => {
            const ph = root._phantom();
            return ph ? ph.mapToItem(item, 0, 0).y : NaN;
        }
        beginGap: uid => {
            for (let i = 0; i < sectionRep.count; i++) {
                const s = sectionRep.itemAt(i) as GroupSection;
                if (s)
                    s.beginFlightGap(uid);
            }
        }
        endGap: () => {
            // RowFlight opens the destination all the way as it ends: what it
            // had opened before that is the value before this frame's step.
            const pre = root._revealNow >= 1 && Date.now() - root._revealAt < 5 ? root._revealPrev : root._revealNow;
            for (let i = 0; i < sectionRep.count; i++) {
                const s = sectionRep.itemAt(i) as GroupSection;
                if (s)
                    s.endFlightGap(pre);
            }
        }
        indexOf: uid => root._entryIndexOf(uid)
        commit: uid => {
            const svc = root.service;
            if (!svc)
                return;
            // The clone's pin flips in the same call as the model.
            root._ghostFlip = true;
            svc.togglePin(uid);
            Qt.callLater(flight.reconciled);
        }
        // THE CLONE'S TWO FACES. It lifts off as the card it replaces (`from`,
        // handed at the begin) and lands as the card it becomes (the
        // destination's face, read while it travels). They differ where a
        // bundle's head is involved: the head says "+1 more from Signal" and
        // has a chevron, a pin does not -- a clone that is always the bare
        // card would lift off a head with its line, chevron and foot gone in one
        // frame, and land on one with the line popping in under it. Between the two, on the flight's reveal (the clock the
        // rooms move on, the travel), the line comes or goes as a line put
        // into a card would: what lies from the line's slot down -- the line,
        // anything under it, the foot -- slides out from under the text above
        // as the clone grows, or back under it as it shrinks, and the chevron
        // fades. NotificationCard has no presence for its footnote,
        // so the morph is drawn from whole cards: the card WITH the
        // line, cut at the line's slot above and slid below, and the same card
        // with its chevron over the lower part at the chevron's weight. On the
        // lift and the landing the clone is one plain card, the face itself.
        cloneComponent: Component {
            Item {
                id: ghost
                property var flightData: null
                // The record as it will be once landed: its pin flips in the
                // call that flips the model.
                readonly property var _d: !ghost.flightData || !ghost.flightData.d ? null
                    : root._ghostFlip ? Object.assign({}, ghost.flightData.d, { pinned: !ghost.flightData.d.pinned })
                    : ghost.flightData.d
                readonly property var _a: ghost.flightData && ghost.flightData.from ? ghost.flightData.from : root._bareFace
                readonly property var _b: flight.active && flight.reveal > 0 ? root._destFace(flight.key) : null
                readonly property real _r: Math.max(0, Math.min(1, flight.reveal))
                readonly property bool _differ: !!ghost._b
                    && (ghost._a.footnote !== ghost._b.footnote || ghost._a.chevron !== ghost._b.chevron)
                readonly property bool _morph: ghost._differ && ghost._r > 0 && ghost._r < 1
                // The plain card: the lift's face, the landing's once the travel is over.
                readonly property var _face: ghost._b && ghost._r >= 1 ? ghost._b : ghost._a
                // The line: the card that carries it, its height, how much of it is in.
                readonly property bool _la: ghost._a.footnote !== ""
                readonly property bool _lb: !!ghost._b && ghost._b.footnote !== ""
                readonly property string _line: ghost._lb ? ghost._b.footnote : ghost._a.footnote
                readonly property real _L: !ghost._b || ghost._la === ghost._lb ? 0 : Math.abs(ghost._b.h - ghost._a.h)
                readonly property real _hNo: ghost._b && ghost._la && !ghost._lb ? ghost._b.h : ghost._a.h
                readonly property int _k: Math.round(ghost._L * (ghost._la === ghost._lb ? 1 : ghost._lb ? ghost._r : 1 - ghost._r))
                readonly property real _chev: (ghost._a.chevron ? 1 - ghost._r : 0) + (ghost._b && ghost._b.chevron ? ghost._r : 0)
                readonly property bool _open: ghost._b ? ghost._b.expanded : ghost._a.expanded
                // The chevron's way (up: open) is the face's that has it: one
                // fading out keeps the way it pointed.
                readonly property bool _chevOpen: ghost._b && ghost._b.chevron ? ghost._b.expanded : ghost._a.expanded
                // The morph's cards are built with the first flight, not with the popup.
                property bool _used: false
                onFlightDataChanged: if (ghost.flightData)
                    ghost._used = true

                implicitWidth: plain.implicitWidth
                implicitHeight: ghost._morph ? ghost._hNo + ghost._k : plain.implicitHeight

                NotificationCard {
                    id: plain
                    opacity: ghost._morph ? 0 : 1
                    d: ghost._d
                    service: root.service
                    clock: root.clock
                    style: root.style
                    cardWidth: root.listWidth
                    groupColor: ghost._d ? root._groups.color(ghost._d.group) : Theme.accent
                    countdown: -1
                    expandable: true
                    footnote: ghost._face.footnote
                    chevronAlways: ghost._face.chevron
                    expanded: ghost._face.expanded
                }

                // Hidden by opacity, never `visible`: a Column under a hidden
                // ancestor does not hear its line come.
                Loader {
                    active: ghost._used
                    opacity: ghost._morph ? 1 : 0
                    sourceComponent: Component {
                        Item {
                            id: morph
                            // The bevel's reach past the card, kept by the cuts.
                            readonly property real slack: 2
                            property Text footLine: null
                            // Where the lower part begins: the line's slot (the
                            // column's gap above it) -- never inside the icon;
                            // with no line, the card's foot.
                            readonly property int ys: {
                                const t = morph.footLine;
                                const col = t ? t.parent as Column : null;
                                const top = t && t.visible && col ? col.y + t.y - col.spacing : lineA.implicitHeight - lineA.padding;
                                const icon = lineA.textX > lineA.padding + 0.5 ? lineA.padding + lineA.iconSize : 0;
                                return Math.round(Math.max(top, icon));
                            }
                            Item {
                                x: -morph.slack
                                y: -morph.slack
                                width: ghost.width + 2 * morph.slack
                                height: morph.ys + morph.slack
                                clip: true

                                NotificationCard {
                                    id: lineA
                                    x: morph.slack
                                    y: morph.slack
                                    d: ghost._d
                                    service: root.service
                                    clock: root.clock
                                    style: root.style
                                    cardWidth: root.listWidth
                                    groupColor: ghost._d ? root._groups.color(ghost._d.group) : Theme.accent
                                    countdown: -1
                                    expandable: false
                                    footnote: ghost._line
                                    expanded: ghost._open
                                    Component.onCompleted: morph.footLine = root._footLine(lineA)
                                }
                            }
                            Item {
                                x: -morph.slack
                                y: morph.ys
                                width: ghost.width + 2 * morph.slack
                                height: Math.max(0, ghost.height - morph.ys + morph.slack)
                                clip: true

                                NotificationCard {
                                    id: lineB
                                    x: morph.slack
                                    y: -morph.ys - (ghost._L - ghost._k)
                                    d: ghost._d
                                    service: root.service
                                    clock: root.clock
                                    style: root.style
                                    cardWidth: root.listWidth
                                    groupColor: ghost._d ? root._groups.color(ghost._d.group) : Theme.accent
                                    countdown: -1
                                    expandable: false
                                    footnote: ghost._line
                                    expanded: ghost._open
                                }
                                NotificationCard {
                                    x: morph.slack
                                    y: lineB.y
                                    opacity: ghost._chev
                                    d: ghost._d
                                    service: root.service
                                    clock: root.clock
                                    style: root.style
                                    cardWidth: root.listWidth
                                    groupColor: ghost._d ? root._groups.color(ghost._d.group) : Theme.accent
                                    countdown: -1
                                    expandable: true
                                    chevronAlways: true
                                    footnote: ghost._line
                                    expanded: ghost._chevOpen
                                }
                            }
                        }
                    }
                }

                // The keyboard's rim, as NotificationRow draws it.
                Rectangle {
                    objectName: "flightHighlight"
                    readonly property real inset: root.style ? root.style.highlightInset : 2
                    anchors.fill: parent
                    anchors.margins: -inset
                    radius: plain.radius + inset
                    color: "transparent"
                    border.width: root.style ? root.style.highlightWidth : 1.5
                    border.color: Theme.accent
                    opacity: root.style ? root.style.highlightAlpha : 0.8
                    visible: !!ghost.flightData && !!ghost.flightData.highlighted
                }
            }
        }
    }

    // The flight's LAYER: the lifted clone and its drop shadow (RowFlight's
    // clone host is drawn in here). The shadow reaches ~34 px past the clone,
    // far past the 12 px padding; the popup's rectangle cuts it at its sides,
    // but not at its ROUNDED corners -- lifted at the list's foot, the shadow
    // filled the corner squares outside the curve (194 levels, g2f), and while
    // the content is live the engine clips nothing. So for as long as a flight
    // runs, the layer is captured and drawn through reel_cap: cut 1 px inside
    // the popup's outline as drawn (`_radii`), no cut at the bar's edge. At
    // rest it is empty and not captured: the resting frame is what it is
    // without it.
    Item {
        id: flightLayer
        anchors.fill: parent
    }
    readonly property bool _flightCut: flight.active
    ShaderEffectSource {
        id: flightTex
        anchors.fill: parent
        sourceItem: flightLayer
        hideSource: root._flightCut
        live: root._flightCut
        visible: false
        textureSize: Qt.size(Math.max(1, Math.ceil(root.width * root.renderScale)),
                             Math.max(1, Math.ceil(root.height * root.renderScale)))
    }
    ShaderEffect {
        anchors.fill: parent
        visible: root._flightCut
        fragmentShader: "../common/components/shaders/reel_cap.frag.qsb"
        property variant source: flightTex
        property real boxW: width
        property real boxH: height
        // One device pixel of feather, running inward (reel_cap's units).
        property real aa: 1.0 / Math.max(0.25, root.renderScale)
        property real inset: 1
        property vector4d radii: Qt.vector4d(root._radii[0], root._radii[1], root._radii[2], root._radii[3])
        // No cut where the popup meets its bar: there is no outline there.
        property vector4d pad: {
            const e = root.hostRoom ? root.hostRoom.edge : "";
            const g = Math.max(width, height);
            return Qt.vector4d(e === "left" ? g : 0, e === "top" ? g : 0, e === "right" ? g : 0, e === "bottom" ? g : 0);
        }
    }

    // Menus and tips float above everything here.
    Item {
        id: overlay
        anchors.fill: parent
        z: 100
    }

    // ---- keys ----------------------------------------------------------------------------
    focus: true
    function _navItems() {
        const out = [];
        for (const g of root.groupOrder) {
            if (!root._visible(g))
                continue;
            out.push("h:" + g);
            if (root.isOpen(g) && root._data[g])
                for (const e of root._data[g].entries)
                    out.push(e.key);
        }
        return out;
    }
    function _uidOfKey(key) {
        for (const g of root.groupOrder) {
            const gd = root._data[g];
            if (!gd)
                continue;
            for (const e of gd.entries)
                if (e.key === key)
                    return e.uid;
        }
        return "";
    }
    // Delete on a highlighted header: the swipe's path -- its card commits
    // (flies off, or springs back over the pins that stay), the group clears
    // and its undo is offered. The highlight moves on to what is
    // left when the header goes.
    function _clearByKey(g) {
        const s = root._section(g);
        const card = s ? s.headerCard as SwipeVerbCard : null;
        const gd = root._data[g];
        if (!card || !gd || gd.count <= gd.pins)
            return;
        if (gd.pins === 0) {
            const items = root._navItems();
            const at = items.indexOf("h:" + g);
            const own = new Set(gd.entries.map(e => e.key));
            let next = "";
            for (let i = at + 1; i < items.length && next === ""; i++)
                if (!own.has(items[i]))
                    next = items[i];
            for (let i = at - 1; i >= 0 && next === ""; i--)
                next = items[i];
            root.highlightKey = next;
        }
        card.commit(-1);
    }
    function _cardOf(uid) {
        for (let i = 0; i < sectionRep.count; i++) {
            const s = sectionRep.itemAt(i) as GroupSection;
            const c = s ? s.cardFor(uid) : null;
            if (c)
                return c;
        }
        return null;
    }
    function _move(step) {
        const items = root._navItems();
        if (items.length === 0)
            return;
        let i = items.indexOf(root.highlightKey);
        i = i < 0 ? (step > 0 ? 0 : items.length - 1) : Math.max(0, Math.min(items.length - 1, i + step));
        root.highlightKey = items[i];
        root._reveal(root.highlightKey);
    }
    function _reveal(key) {
        let target = null;
        if (key.indexOf("h:") === 0) {
            const s = root._section(key.substring(2));
            target = s ? s.headerRow : null;
        } else {
            for (let i = 0; i < sectionRep.count && !target; i++) {
                const s = sectionRep.itemAt(i) as GroupSection;
                target = s ? s.rowFor(key) : null;
            }
        }
        if (!target)
            return;
        const p = target.mapToItem(flick.contentItem, 0, 0);
        const top = p.y, bottom = p.y + Math.min(target.height, flick.height);
        if (top < flick.contentY)
            dressing.scrollBy(top - flick.contentY);
        else if (bottom > flick.contentY + flick.height)
            dressing.scrollBy(bottom - (flick.contentY + flick.height));
    }
    Keys.onPressed: event => {
        const svc = root.service;
        const key = root.highlightKey;
        const uid = key.indexOf("h:") === 0 ? "" : root._uidOfKey(key);
        if (event.key === Qt.Key_Escape) {
            if (root.filter !== "")
                root.filter = "";
            else if (svc)
                svc.closeManagerRequested();
            event.accepted = true;
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Up) {
            root._move(event.key === Qt.Key_Down ? 1 : -1);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (key.indexOf("h:") === 0)
                root.toggleGroup(key.substring(2));
            else if (uid !== "" && svc)
                svc.activate(uid);
            event.accepted = true;
        } else if (event.key === Qt.Key_Delete) {
            if (key.indexOf("h:") === 0)
                root._clearByKey(key.substring(2));
            else if (uid !== "" && svc) {
                // a folded bundle's head takes the whole app (NotificationRow.deleteAction), as its swipe does
                const card = root._cardOf(uid) as NotificationRow;
                const rec = svc.store.get(uid);
                if (rec && rec.kept === true) {
                    // a kept card (a mounted drive's) is not deleted: the row shakes and the highlight stays
                    if (card)
                        card.refuse(-1);
                } else {
                    root._move(1);
                    if (card)
                        card.deleteAction();
                    else
                        svc.remove(uid);
                }
            }
            event.accepted = true;
        } else if (event.key === Qt.Key_P && (event.modifiers & Qt.ControlModifier)) {
            if (uid !== "")
                root.pinWithFlight(uid, root._cardOf(uid));
            event.accepted = true;
        } else if (EK.queryActionOf(event.key, event.modifiers) !== null) {
            // the terminal's kills on the typed filter (Ctrl+Backspace / Ctrl+W a word, Ctrl+U all of it): EditKeys' query rule
            root.filter = EK.queryAfter(EK.queryActionOf(event.key, event.modifiers), root.filter);
            event.accepted = true;
        } else if (event.key === Qt.Key_Backspace) {
            root.filter = root.filter.slice(0, -1);
            event.accepted = true;
        } else if (event.text.length === 1 && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier))
                   && event.text.charCodeAt(0) >= 32) {
            root.filter += event.text;
            event.accepted = true;
        }
    }
}
