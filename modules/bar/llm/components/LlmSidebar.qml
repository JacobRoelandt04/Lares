pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls

import "../../../common/theme"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix

// =============================================================================
// LlmSidebar.qml
//
// The chat-history panel of the LLM popup: a search field and the conversation
// list grouped into Favorites / Today / Yesterday / Previous 7 days / Older.
// That is the whole of it -- the panel is the history and nothing else.
//
// THE SESSION CONTROLS ARE NOT HERE. The burger, the pin, the incognito
// switch and New chat live in the POPUP's own top row, which spans the
// popup's full width and holds its buttons still while the panel collapses
// under it. Two consequences for this file: the panel's content starts at
// y = 0, and the only buttons in it are the two the delete confirmation asks
// with.
//
// THE LIST IS ONE FLAT MODEL, HEADERS INCLUDED. A group header is a row of
// `kind: "header"`; that is what lets a collapse animate: collapsing a group
// simply removes its rows from the wanted set, and the same merge that handles
// a new conversation arriving handles those seven leaving. The merge is the
// system update's category wave, in one pass: rows that vanish are flipped to
// "leaving" (out to the RIGHT, staggered), rows that appear are inserted as
// "entering" (in from the LEFT), survivors are updated in place -- with
// `staggerIdx` written BEFORE `rowState` every time, because writing the state
// is what schedules the flight and it reads the stagger as it does. The
// Column's own spacing is 0 -- AnimatedListRow reserves its spacing internally
// so that a leaving row's gap closes with it.
//
// EVERY ROW CARRIES ITS OWN DEADLINE, AND ONLY THE VIEWPORT IS ANIMATED.
// Both facts are docs/contracts/list_animation.md; the failure they
// prevent is one wave trampling another.
//
//  * `kickAt` / `doneAt` are written into the model entry at the same moment
//    as its `staggerIdx`, so `retireTimer` (a 16 ms sweeper, not a one-shot
//    sized to the last merge) only ever retires a row whose OWN flight is
//    over. Collapsing a second group with one shared timer restarted at an
//    interval sized to the small new wave would splice the first wave's deep
//    rows out of the model in mid-air (measured: 9 of 22 rows, the worst
//    still 30.5 px tall).
//  * `_bandOf` puts every entry of a wave in one of three bands. ON screen
//    flies, staggered. BELOW the fold is retired in the same frame
//    ("collapsed"), so the next header closes up exactly as if the group had
//    only ever held what you can see -- and an ARRIVING row past the fold is
//    placed only once the head has landed, never before it. ABOVE the fold
//    keeps its FULL height until the wave retires: zeroing content above a
//    contentY that is at its maximum shrinks the scroll out from under the
//    rows that are still flying.
//  * An interruption is a TURN-AROUND, not a second wave laid over the first.
//    A row that has not started is cancelled where it stands; a row that is in
//    the air finishes its flight and is turned at its own deadline (`pend`,
//    `_turn`), and the whole turned wave aims at ONE instant -- the moment the
//    air clears -- through AnimatedListRow's `startDelayMs`. Re-expanding a
//    collapsing group therefore rewinds it: last row out is the first back.
//    Inserting the wanted rows as fresh copies UNDER the still-flying ones
//    would draw every conversation twice for a second.
//
// FAVOURITES ARE THE STORE'S `pinned` FLAG. There is no second flag: in this
// module's UI "pinned" means "favourite", and the fact that it also protects
// the conversation from trimming is exactly right. Right-clicking a row toggles
// it, and the row does not teleport into its new group -- a clone flies there,
// through the shared `RowFlight` overlay, across groups. While it is airborne
// the row exists twice in the model: a PHANTOM holding the slot it is leaving
// (height 1 - reveal) and the destination (height reveal), both with their
// content at zero opacity, so the space closes exactly as fast as it opens and
// the clone is the only visible copy. The destination's group is expanded if it
// was folded -- a flight into a closed group is a row vanishing, which is the
// thing the flight exists to prevent.
//
// THE CLONE RIDES THE HOLE, BUT NEVER OUT OF VIEW. Before it travels the
// clone follows the slot it left, so a shelf materialising above carries it
// along instead of leaving it over pixels the hole has moved away from. With
// the list at its end and the shelf folded, favouriting one of the last rows
// would make that ride carry the clone past the foot of the list and out of
// the popup. So the hole's rest is summed from the model the moment the phantom
// exists, and if it would end outside the viewport the hole is anchored
// where it is and the list scrolls by exactly what each positioning pass
// grew above it (`_anchorHole`, `_absorbNudge`) -- the row and its hole hold
// still on screen, and the camera follow then takes the list to the
// destination.
//
// A FAVOURITE IS TWO THINGS, AND THEY DO NOT HAPPEN AT THE SAME TIME: a row
// moving, and a line written to disk. The move is immediate -- it is the
// gesture's whole answer -- and it is flown against a PENDING flag held here
// (`_pendingPinId`), not against the store. The store is told once the panel
// has come to rest: the clone has landed and the wave the landing started has
// been retired.
//
// Written mid-flight, the save would stall the clone. LlmStore debounces its
// save 400 ms after a change; a flight lasts about 800 ms; so the save would
// land squarely mid-travel, and the save is synchronous JSON of the whole
// history on the UI thread -- 242-294 ms measured on a real history (23 MB,
// mostly persisted image payloads). The compositor gets no frame for a
// quarter of a second: the motion HALTS.
//
// THE FIRST FILL IS A PLACEMENT, AND THE CELLS ARE VIRTUAL. A panel built with its history in it has
// nothing on screen that ARRIVED, so its rows are at rest from the first frame (`_place`): a history appearing row by row from the top
// at build would read as arrivals that did not happen; every later change is the merge above. And a row's wrapper -- its slot, its
// waves, its flight target -- exists for every entry, but what is DRAWN in it exists only within two row pitches of the viewport
// (`_syncCells`): 3 654 of the popup's 4 541 items are this panel's, which would all be built in the click's frame. While the popup is parked (LlmPopup.parked)
// the panel does not follow the store; it catches up, placed, when it is shown (`_resync`).
//
// THE PANEL DOES NOT ANIMATE ITS OWN WIDTH, AND IT COLLAPSES TO NOTHING.
// `implicitWidth` is openWidth or 0 -- there is no rail, and the
// transcript takes the width back; the popup eases the change. What this file
// owns is the FADE: the layer leaves on one fraction (`_openF`) over
// `resizeMs`, so the fade covers exactly the span the host spends resizing.
// The layer is laid out ONCE, at openWidth, and squashed on the x axis while
// the host resizes: re-laying it out at every animated width re-elided every
// title per frame and sent right-anchored content out over the popup. The
// scale is exactly 1 whenever the panel is at rest and open, so no ShadowBox
// bevel is ever sheared on a settled frame, and by the time the width is 0
// the layer has already faded out of the frame.
//
// NO WORD EVER STANDS IN FOR A MISSING TITLE -- but an EMPTY conversation is
// not a missing title. A conversation with no messages says "New conversation"
// in faint text: nothing is being generated, so a skeleton would be promising
// work that is not happening. The skeleton appears only once a message exists
// and the name is still on its way, and it is cut to the real row's own
// geometry -- an icon-sized square in the icon slot and a bar at the title's
// line -- so it resolves in place when the classification lands.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // ---- Data ----
    // An LlmStore. Read-only from here except for `setPinned`, which is the
    // favourite flag and belongs to the row the user right-clicked; every
    // other mutation leaves as a signal so the service stays the only writer.
    property var store: null
    property string activeId: ""

    // The popup is built but not shown (LlmPopup.parked): the panel holds still. The store may change while it is held -- a title lands,
    // midnight passes -- and a wave over a panel nobody sees is CPU for nobody (and a clock that runs out before the first look), so the
    // changes are remembered (`_stale`) and, when the panel is let go of, brought in at once, at rest (`_resync`).
    property bool parked: false

    // The ACTIVE conversation has no title yet, so its row draws a skeleton
    // rather than a word. Every other row reads its own empty title.
    property bool titlePending: false

    // ---- Geometry ----
    property bool open: true
    property real openWidth: 268
    property string fontFamily: "Inter"
    // The group headers carve their boxes at this same radius, all four
    // corners -- one curve for the container and everything that meets its
    // edge.
    property real containerRadius: 14
    property real rowInset: 6
    property real padding: 12
    // The host's resize easing. Not used to move anything here -- it is how
    // long the panel's own fade lasts, so the two are one motion.
    property int resizeMs: 260
    property real listScale: 1.0
    property bool showSearch: true
    // Two-way: bound into the field, written back on edit. A host may set it.
    property string query: ""
    property real scrollSpeed: 1.0

    // The list's one gap. A row pair is `rowGap` apart -- the house number --
    // and a section header stands exactly as far from the last row of the
    // group above as it does from its own first row. Space above equals space
    // below -- symmetric always: a separate clearance above the header would
    // read as MORE space before it than after it (15 px against 9 px on a
    // one-row group).
    property real rowGap: 6
    // How far the list dissolves into the container at each end.
    property real fadeHeight: 34
    // The search field's height. Named for the popup's button row because it
    // is the same number: the field and the buttons beside it are one band.
    property real buttonHeight: 30
    property int titleSize: 12
    property int timeSize: 10
    property int animDuration: 240

    // How many rows are airborne at any moment of a wave. The stagger is
    // DERIVED from it -- staggerMs = animDuration / waveConcurrency -- so a
    // collapse of a full-viewport group streams rows out one after another
    // the whole way down instead of shooting everything past a clamp off in
    // one block. 6.0 on purpose: 240 / 6 is the 40 ms cadence every wave in
    // this panel runs at.
    //
    // What BOUNDS a wave is not this number but the viewport (`_bandOf`):
    // only the rows you can see are ever given a rank, so the deepest stagger
    // is a screenful however long the group is. Without that bound a 22-row
    // group in a 15-row viewport would spend 40 % of the collapse closing
    // over rows nobody can see (the next header still creeping at 1037 ms
    // against a 766 ms wave).
    property real waveConcurrency: 6.0
    readonly property real staggerMs:
        root.animDuration / Math.max(1, root.waveConcurrency)

    // ---- Palette (every colour the popup passes down) ----
    property color surfaceColor: Theme.surface
    property color listBoxColor: Theme.listBox
    property color panelColor: Theme.panelSunk
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color headerBoxColor: Theme.headerBox
    property color headerBoxBevelColor: Theme.headerBoxBevel
    property color headerBoxShadowColor: Theme.headerBoxShadow
    property color primaryText: Theme.textPrimary
    property color mutedText: Theme.textMuted
    property color faintText: Theme.textFaint
    property color accent: Theme.accent
    property color accentHover: Theme.accentHover
    property color accentBevel: Theme.accentBevel
    property color textOnAccent: Theme.textOnAccent
    // Handed down by the popup for a uniform palette. Nothing in a history
    // list reports success, so it is carried and not drawn -- assigning a
    // colour the host passes is cheaper than a host that has to know which
    // of its tokens this panel happens to use.
    property color okColor: Theme.ok
    property color errColor: Theme.error
    property color buttonPlateau: Theme.buttonPlateau
    property color buttonPlateauHover: Theme.buttonPlateauHover
    property color buttonBevel: Theme.buttonBevel
    property color buttonShadow: Theme.buttonShadow
    // The category hues, for the SELECTED row's stripe and title. The popup
    // passes its own cat* set down so the sidebar and the transcript header
    // can never disagree about what "code" looks like. There is no
    // catOtherColor on purpose: "other" -- and a conversation not yet
    // classified -- falls back to the accent, so an unclassified selection
    // takes the accent.
    property color catCodeColor: Theme.catAur
    property color catSystemColor: Theme.catCore
    property color catExplainColor: Theme.catExtra
    property color catWriteColor: Theme.catFlatpak
    property color catDataColor: Theme.catMultilib

    // ---- Extras (defaults chosen so a host that ignores them sees the
    //      layout the contract describes) ----
    // Forces the hover affordances onto one row from outside: what a
    // keyboard-navigating host would drive, and how the mockup grabs the
    // hovered state without a pointer. "" is the ordinary case.
    property string hoverId: ""
    property string glyphFamily: "Symbols Nerd Font"
    property int sectionTitleSize: 12
    property int confirmMs: 4000
    property int fadeMs: 160

    // The category taxonomy, LlmService.categories fed through by the host:
    // [{ key, label, glyph, ... }]. What the rows use it for is the FALLBACK
    // glyph when a conversation has no stored icon yet, and the words a
    // category icon's hover tip says. Empty means no fallback and no tip --
    // a host without a service still lays out.
    property var categories: []

    // Where floating things are reparented so no Flickable clip and no
    // ancestor bounds can cut their paint or their place: the icons' hover
    // tips, and the favourite flight's clone -- whose contact shadow spills
    // past this panel's right edge, where the conversation container drawn
    // over it would slice it off. Null falls back to local
    // parenting -- fine for a harness, wrong for a list (see HoverTip.qml
    // for the measured reasons).
    property Item overlayItem: null

    // Which groups are folded away, keyed "g0".."g4". Public so a host (and
    // the render harness) can drive a collapse; absent means the default,
    // which is folded for Favorites and open for every date group. Favorites
    // starts closed because it is a shelf, not the list you came to read.
    property var collapsedGroups: ({})

    // How many entries the list is showing, headers included. The host can
    // use it to tell an empty sidebar from a filtered one; the render probe
    // uses it to prove the row merge settles on exactly the wanted set.
    readonly property int rowCount: rowModel.count

    signal selected(string convId)
    signal renameRequested(string convId, string title)
    signal removeRequested(string convId)

    // The host gives the height; the width is one of two numbers and the
    // host eases between them. Collapsed is ZERO: the panel goes away and
    // the conversation takes the space, so there is no rail to reserve.
    implicitWidth: root.open ? root.openWidth : 0

    readonly property real _s: Math.max(0.2, root.listScale)

    // ======================================================================
    // STATE
    // ======================================================================

    // At most one row is being renamed or is asking to be deleted, so both
    // live here rather than in a row: opening one closes the other.
    property string _renameId: ""
    property string _confirmId: ""
    property string _emptyText: ""
    property bool _rebuildQueued: false
    // The list has had its first fill. Until then a merge is a PLACEMENT (see `_place`): the rows that a history is made of when the
    // panel is built are not arrivals, and nothing flies in a list that did not exist a frame ago.
    property bool _filled: false

    // The conversation currently in flight, "" when none. Set from the
    // overlay's beginGap and cleared by its endGap, so the merge below knows
    // to leave a phantom instead of a departing row.
    property string _flightKey: ""
    // The group the flying row LEFT. While the flight is airborne that
    // group's header stays listed even if the row was its last -- a header
    // vanishing mid-flight would move the measured destination under the
    // clone, and the ghost would land a header's height off.
    property string _flightFromGroup: ""
    // The favourites the user has toggled that the store has not been told
    // about yet: convId -> true/false. `_wantRows` reads these over the
    // store's own flag, so the list -- and the flight, which asks the same
    // function where the row is going -- moves the instant the gesture lands
    // while the disk waits for the panel to stop moving. A MAP rather than
    // one slot: a second toggle while the first is still unwritten must not
    // force the first one to disk, because forcing it to disk mid-flight is
    // the very thing this exists to stop. `_pendingPinCount` is the half that
    // notifies (a `var` map's contents do not), and it drives the watch.
    property var _pendingPins: ({})
    property int _pendingPinCount: 0

    // False from beginGap until the deferred merge has left the phantom in
    // the vacated slot. Until then the live row IS the slot, and it must
    // keep its full height: zeroing it through `reveal` before the merge ran
    // would flicker for one frame on un-favouriting, depending on whether a
    // frame lands between beginGap and the callLater.
    property bool _flightMerged: false
    // The line (listFlick coordinates) the vacated slot is HELD at while
    // the shelf opens above it, NaN while the hole is free to ride. Set by
    // _anchorHole once per flight, cleared the frame the travel starts.
    property real _holdHoleY: NaN

    // Midnight is the only thing that can regroup the list on its own. The
    // timer ticks every minute but `_todayStart` changes once a day, and the
    // rebuild hangs off that change, not off the tick.
    property real _todayStart: root._dayStart(Date.now())

    onQueryChanged: root._scheduleRebuild()
    onStoreChanged: root._scheduleRebuild()
    onCollapsedGroupsChanged: root._scheduleRebuild()
    on_TodayStartChanged: root._scheduleRebuild()
    Component.onCompleted: root._rebuild()

    Connections {
        target: root.store
        ignoreUnknownSignals: true
        function onChanged(convId) { root._scheduleRebuild() }
        function onLoadedChanged() { root._scheduleRebuild() }
    }
    // A conversation appearing or disappearing does not go through
    // `changed()`, so the model's own count is watched too.
    Connections {
        target: root.store && root.store.conversations ? root.store.conversations : null
        ignoreUnknownSignals: true
        function onCountChanged() { root._scheduleRebuild() }
    }

    Timer {
        interval: 60000; repeat: true; running: root.visible
        onTriggered: root._todayStart = root._dayStart(Date.now())
    }
    Timer {
        id: confirmTimer
        interval: root.confirmMs
        onTriggered: root._confirmId = ""
    }
    // THE SWEEPER, not a wave timer. It runs while anything in the model owes
    // a transition and stops itself when nothing does, and it acts on a row
    // only when that row's own `doneAt` has passed -- which is what makes a
    // second collapse harmless to the first one's rows. `running` therefore
    // still means exactly what the pin persist reads it as: something in this
    // panel is still moving.
    Timer {
        id: retireTimer
        interval: 16
        repeat: true
        onTriggered: root._retire()
    }

    FontMetrics {
        id: rowFm
        font.family: root.fontFamily
        font.pixelSize: root.titleSize * root._s
    }

    ListModel { id: rowModel }

    // A row's full height, computed rather than measured: it is the formula
    // the row cell itself is sized by, so the analytic list geometry the
    // flight needs (see `_entryTop`) cannot drift from the layout.
    readonly property real _rowH: Math.max(24 * root._s, rowFm.height + 10 * root._s)
    // A header's is measured, because it is ListSectionHeader's own business.
    property real _measuredHeaderH: 0
    readonly property real _headerH: root._measuredHeaderH > 4
        ? root._measuredHeaderH
        : (root.sectionTitleSize * 1.4 + 16 + root.rowGap / 2) * root._s

    // ======================================================================
    // GROUPING AND SEARCH
    // ======================================================================

    // Favorites is FIRST: a shelf above the chronology, not a date.
    readonly property var _groupLabels: ["Favorites", "Today", "Yesterday",
                                         "Previous 7 days", "Older"]

    function _dayStart(ms) {
        const d = new Date(ms);
        d.setHours(0, 0, 0, 0);
        return d.getTime();
    }

    function _dateGroupOf(ms) {
        if (!(ms > 0)) return 3;
        if (ms >= root._todayStart) return 0;
        // Midnights are calendar days back from today's, not 24 h multiples: a day is 23 or 25 h across a DST change
        // and the group boundary would sit an hour off for the six days after it.
        const t = new Date(root._todayStart);
        const midnight = (back) => new Date(t.getFullYear(), t.getMonth(), t.getDate() - back).getTime();
        if (ms >= midnight(1)) return 1;
        if (ms >= midnight(6)) return 2;
        return 3;
    }

    function _isCollapsed(gk) {
        const v = root.collapsedGroups[gk];
        return v === undefined ? (gk === "g0") : !!v;
    }

    function toggleGroup(gk) {
        // A fresh object, never a mutation in place: `property var` only
        // emits a change when the reference changes.
        const next = ({});
        for (const k in root.collapsedGroups) next[k] = root.collapsedGroups[k];
        next[gk] = !root._isCollapsed(gk);
        root.collapsedGroups = next;
    }

    function _setCollapsed(gk, on) {
        if (root._isCollapsed(gk) === on) return;
        root.toggleGroup(gk);
    }

    // Today is a clock reading, this week is a weekday, anything older is a
    // date -- each group says the thing its neighbours in that group differ
    // by, and nothing more. A favourite keeps the reading its DATE deserves,
    // not its shelf's.
    function _timeText(ms) {
        if (!(ms > 0)) return "";
        const g = root._dateGroupOf(ms);
        const d = new Date(ms);
        if (g === 0) return Qt.formatDateTime(d, "HH:mm");
        if (g <= 2) return Qt.formatDateTime(d, "ddd");
        return d.getFullYear() === new Date(root._todayStart).getFullYear()
            ? Qt.formatDateTime(d, "d MMM") : Qt.formatDateTime(d, "d MMM yy");
    }

    // The store owns search; these are the fallbacks for a host that has
    // handed over a plain model instead (the mockup does exactly that).
    function _searchSet(q) {
        if (root.store && typeof root.store.search === "function") {
            try {
                const ids = root.store.search(q);
                if (ids && ids.length !== undefined) {
                    const set = ({});
                    for (let i = 0; i < ids.length; i++) set[ids[i]] = true;
                    return set;
                }
            } catch (e) { /* fall through to the local filter */ }
        }
        return null;
    }

    function _hay(c) {
        return ((c.title || "") + " " + (c.preview || "")).toLowerCase();
    }

    function _localMatch(c, q) { return root._hay(c).indexOf(q) >= 0; }

    // The query, lowered once: the row titles colour their matching
    // substrings against this. Empty when not searching, and everything
    // downstream of it is gated on that, so the plain path stays plain.
    readonly property string _queryLC: root.query.trim().toLowerCase()

    function _escapeHtml(s) {
        return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // The elided title with every case-insensitive occurrence of the query
    // wrapped in the accent TEXT colour. Composed from the ALREADY-ELIDED
    // string -- Qt eliding is plain-text-only, so the truncation is settled
    // by TextMetrics before any markup exists and cannot move. An
    // occurrence the ellipsis cut in half is not a visible match and stays
    // uncoloured. root.accent is read inside, so a theme switch recolours
    // every binding that calls this.
    function _styledTitle(elided, q) {
        const col = String(root.accent);
        const lc = elided.toLowerCase();
        let out = "";
        let i = 0;
        for (;;) {
            const j = lc.indexOf(q, i);
            if (j < 0) return out + root._escapeHtml(elided.substring(i));
            out += root._escapeHtml(elided.substring(i, j))
                 + "<font color=\"" + col + "\">"
                 + root._escapeHtml(elided.substring(j, j + q.length))
                 + "</font>";
            i = j + q.length;
        }
    }

    // The view is safe against any title on its own: newlines and runs of
    // whitespace become one space here, and the Text below still caps itself
    // at one elided line. The service sanitises at the source too; this is
    // the belt to that suspender.
    function _oneLine(t) {
        return (t || "").replace(/\s+/g, " ").trim();
    }

    // The colour the selected row wears: its category's hue, accent for
    // "other" and for a row the classifier has not reached. One switch, so
    // the stripe and the title cannot disagree.
    function categoryColor(key) {
        if (key === "code") return root.catCodeColor;
        if (key === "system") return root.catSystemColor;
        if (key === "explain") return root.catExplainColor;
        if (key === "write") return root.catWriteColor;
        if (key === "data") return root.catDataColor;
        return root.accent;
    }

    function _catInfo(key) {
        if (!key) return null;
        for (let i = 0; i < root.categories.length; i++)
            if (root.categories[i].key === key) return root.categories[i];
        return null;
    }

    function _matchCount(c, q) {
        if (root.store && typeof root.store.matchCount === "function") {
            try { return root.store.matchCount(c.convId, q); } catch (e) { }
        }
        const hay = root._hay(c);
        let n = 0;
        let i = hay.indexOf(q);
        while (i >= 0) { n++; i = hay.indexOf(q, i + q.length); }
        return n;
    }

    // ======================================================================
    // THE ROW LIST
    // ======================================================================

    function _scheduleRebuild() {
        if (root._rebuildQueued) return;
        if (root.parked) {
            root._stale = true;
            return;
        }
        root._rebuildQueued = true;
        Qt.callLater(function () { if (!root._gone) root._rebuild(); });
    }

    // Changes that arrived while the panel was parked, and what is done about them when it is not: the model is made to match the
    // wanted list in one step, at rest -- unless nothing it shows has changed, which is the usual case and costs a comparison.
    property bool _stale: false
    onParkedChanged: {
        if (root.parked || !root._stale)
            return;
        root._stale = false;
        root._resync();
    }
    function _resync() {
        const want = root._wantRows();
        if (!root._differs(want))
            return;
        root._place(want);
        root._emptyText = want.length === 0
            ? (root.query.trim().length > 0 ? "no chats match" : "no chats yet") : "";
    }
    function _differs(want) {
        if (want.length !== rowModel.count)
            return true;
        for (let i = 0; i < want.length; i++) {
            const w = want[i], e = rowModel.get(i);
            if (e.key !== w.key || e.label !== w.label || e.count !== w.count || e.title !== w.title || e.timeText !== w.timeText
                    || e.incognito !== w.incognito || e.pinned !== w.pinned || e.icon !== w.icon || e.catKey !== w.catKey
                    || e.msgCount !== w.msgCount || e.matches !== w.matches)
                return true;
        }
        return false;
    }

    // A conversation's favourite flag, with a toggle the store has not been
    // told about yet applied over it.
    function _pinnedOf(c) {
        if (root._pendingPinCount > 0) {
            const v = root._pendingPins[c.convId];
            if (v !== undefined) return v;
        }
        return !!c.pinned;
    }

    // The entries the list SHOULD hold, in order. Pure: the flight asks it
    // for a row's index before and after a toggle, which is a question about
    // the model and must never be answered by measuring pixels.
    function _wantRows() {
        const m = root.store && root.store.conversations ? root.store.conversations : null;
        const q = root.query.trim().toLowerCase();
        const allow = q.length > 0 ? root._searchSet(q) : null;
        const buckets = [[], [], [], [], []];

        if (m) {
            for (let i = 0; i < m.count; i++) {
                const c = m.get(i);
                if (!c) continue;
                const id = c.convId || "";
                if (id.length === 0) continue;
                if (q.length > 0) {
                    if (allow) { if (!allow[id]) continue; }
                    else if (!root._localMatch(c, q)) continue;
                }
                const at = c.updatedAt || c.createdAt || 0;
                // The favourite shelf overrides the chronology: a starred
                // conversation is one the user asked to keep in view.
                const pin = root._pinnedOf(c);
                const g = pin ? 0 : 1 + root._dateGroupOf(at);
                // The stored topic icon, or the category's glyph while the
                // topic has none, or no slot at all: the row draws exactly
                // what it knows, never a guess.
                const catKey = c.category || "";
                const cat = root._catInfo(catKey);
                buckets[g].push({
                    key: "c:" + id,
                    kind: "row",
                    groupKey: "g" + g,
                    label: "",
                    count: 0,
                    convId: id,
                    // One line of whatever the store holds. An empty one is
                    // not "New chat" -- it is a title that has not been
                    // written, and the row decides below whether that means
                    // a skeleton (messages exist) or a placeholder (none).
                    title: root._oneLine(c.title),
                    timeText: root._timeText(at),
                    incognito: !!c.incognito,
                    pinned: pin,
                    icon: (c.icon && c.icon.length > 0) ? c.icon
                                                        : (cat ? cat.glyph : ""),
                    catKey: catKey,
                    msgCount: c.messageCount || 0,
                    matches: q.length > 0 ? root._matchCount(c, q) : 0,
                    isPhantom: false
                });
            }
        }

        // A group with nothing in it has no header: an empty section is a
        // heading over nothing. A folded one keeps its header and drops its
        // rows -- that removal IS the collapse animation. The one exception
        // is the group a flying favourite just left: its header stays until
        // the flight has landed, because dropping it mid-flight moves the
        // measured destination out from under the clone. endGap schedules
        // the rebuild that lets it leave, animated, after the landing.
        const want = [];
        for (let g = 0; g < 5; g++) {
            const gk = "g" + g;
            const holdEmpty = buckets[g].length === 0
                && root._flightKey.length > 0
                && gk === root._flightFromGroup;
            if (buckets[g].length === 0 && !holdEmpty) continue;
            want.push({
                key: "h:" + g, kind: "header", groupKey: gk,
                label: root._groupLabels[g], count: buckets[g].length,
                convId: "", title: "", timeText: "", incognito: false,
                pinned: false, icon: "", catKey: "", msgCount: 0,
                matches: 0, isPhantom: false
            });
            if (root._isCollapsed(gk)) continue;
            for (let j = 0; j < buckets[g].length; j++) want.push(buckets[g][j]);
        }
        return want;
    }

    function _rebuild() {
        root._rebuildQueued = false;
        const want = root._wantRows();
        if (!root._filled && root._storeReady()) {
            root._place(want);
            root._filled = true;
        } else {
            root._merge(want);
        }
        root._emptyText = want.length === 0
            ? (root.query.trim().length > 0 ? "no chats match" : "no chats yet") : "";
        // The phantom now holds the vacated slot, so the live copy may hand
        // its height over to `reveal` -- see `_flightMerged`. The first
        // merge of a flight is also the moment the rows entering above the
        // hole exist in the model, at zero height: whether the hole is
        // ridden or held is decided here, once, from what they will grow to.
        if (root._flightKey.length > 0 && !root._flightMerged) {
            root._flightMerged = true;
            root._anchorHole();
        }
        // The model is back in line and the Column has been told; the flight
        // may measure its destination now.
        flightOverlay.reconciled();
    }

    // WHICH BAND OF THE VIEWPORT AN ENTRY IS IN -- the law's own rule
    // (docs/contracts/list_animation.md, "Only what is on screen animates"): a row is on
    // screen when its slot intersects [contentY, contentY + height], with a
    // row's worth of margin either side so a row a pixel past the fold does
    // not read as a popped-in one. `topY` is the entry's top in the Column's
    // coordinates, summed ANALYTICALLY by the merge from `_entryFullH` --
    // never measured, because every row being asked about may be mid-flight.
    function _bandOf(topY, h) {
        // No viewport yet (the first build, before the host has given the
        // panel a height): nothing is off screen because nothing is on it.
        if (!(listFlick.height > 0)) return "on";
        const m = root._rowH + root.rowGap * root._s;
        if (topY + h <= listFlick.contentY - m) return "above";
        if (topY >= listFlick.contentY + listFlick.height + m) return "below";
        return "on";
    }

    // A row joining the list. Past the fold it is PLACED, not flown -- and
    // placed LATE: held at zero height until the wave filling the viewport
    // above it has landed (list_animation.md, Expanding 2a), because a tail
    // placed at the start is on screen before the head that belongs above it
    // and then gets shoved down by it. `late` collects those entries; the
    // merge writes the wave's end into their `doneAt` once it knows it.
    function _arriving(w, band, idx, now, wave) {
        // The row in flight arrives at REST: its slot is opened by the
        // clone's reveal, not by a slide of its own. Two animations on one
        // piece of space is the bug this shell keeps finding.
        const flying = w.kind === "row" && w.convId === root._flightKey;
        const tail = band === "below" && !flying;
        const kick = now + Math.max(16, idx * root.staggerMs);
        const doneAt = (flying || tail) ? 0 : kick + root.animDuration;
        // THE TAIL WAITS FOR THE HEAD. A row past the fold is PLACED, but
        // placing it in the frame the wave starts is not "instant", it is
        // EARLY -- the eye sees the nineteenth row before the first
        // (list_animation.md, Expanding 2a). The
        // caller patches those rows to `Math.max(wave.end, now)`, so the
        // wave's end has to count the rows ARRIVING and not only the ones
        // leaving or being revived: on a PURE expansion nothing else raises
        // it, wave.end stays 0, and the whole tail lands on the sweeper's very
        // next tick.
        if (wave && doneAt > wave.end)
            wave.end = doneAt;
        return root._record(w, (flying || tail) ? 0 : idx, flying ? 0 : kick, doneAt,
                            flying ? "rest" : (tail ? "collapsed" : "entering"));
    }

    // One entry of the model: the wanted row's facts and the wave's own bookkeeping. ONE shape for every entry -- a ListModel takes its
    // roles from what it is given first -- so an arrival and a placement are written by the same line.
    function _record(w, staggerIdx, kickAt, doneAt, rowState) {
        return {
            key: w.key, kind: w.kind, groupKey: w.groupKey, label: w.label,
            count: w.count, convId: w.convId, title: w.title,
            timeText: w.timeText, incognito: w.incognito, pinned: w.pinned,
            icon: w.icon, catKey: w.catKey, msgCount: w.msgCount,
            matches: w.matches, isPhantom: false,
            // ---- the wave's own bookkeeping ----
            exiting: false, exitRank: -1, pend: "", pendAt: 0, pendIdx: 0,
            startDelay: 0,
            staggerIdx: staggerIdx,
            kickAt: kickAt,
            doneAt: doneAt,
            rowState: rowState
        };
    }

    // THE FIRST FILL IS A PLACEMENT (list_animation.md: only what is ON SCREEN animates -- and a list that was built a frame ago, with its
    // history, has nothing on screen that arrived). The rows of an open are at rest from the first frame, not flying in one after
    // another from the left: no state to leave, no kick, no sweeper owed. Everything after it -- a
    // conversation arriving, a search, a fold -- is a merge, and waves. The store has to be READY for this to be the first
    // fill: a history still on its way in is not "the list", and its arrival, when it comes, is placed too.
    function _storeReady() {
        return !!root.store && root.store.loaded !== false;
    }
    function _place(want) {
        rowModel.clear();
        for (let i = 0; i < want.length; i++)
            rowModel.append(root._record(want[i], 0, 0, 0, "rest"));
        // Laid out now, and the cells near the viewport built now: a panel that is built ahead of the click (a parked content, which is
        // not polished until it is shown) has its rows ready, not first-frame work.
        listCol.forceLayout();
        root._syncCells();
    }

    // A row leaving the list, in its band. ON screen flies out to the right on
    // the stagger; BELOW the fold gives up its height in this frame; ABOVE it
    // holds FULL height until the wave retires (UpdateCategorySection's reason,
    // and the same shape here -- one Flickable for every group: zeroing rows
    // above the fold shrinks the content under a contentY that may be at its
    // maximum, and the Flickable clamps, yanking the visible wave out of view).
    // The "above" rows' `doneAt` is patched to the wave's end by the caller.
    function _leave(i, band, rank, now, wave) {
        const on = band === "on";
        const kick = now + Math.max(16, rank * root.staggerMs);
        const end = on ? kick + root.animDuration : now;
        rowModel.setProperty(i, "exiting", true);
        rowModel.setProperty(i, "exitRank", on ? rank : -1);
        rowModel.setProperty(i, "kickAt", on ? kick : 0);
        rowModel.setProperty(i, "doneAt", end);
        rowModel.setProperty(i, "pend", "");
        // staggerIdx -- and the delay it is added to -- BEFORE rowState,
        // always: writing the state fires AnimatedListRow.onRowStateChanged
        // synchronously and that schedules the flight from whatever the two
        // hold at the time. Setting them afterwards is one frame too late.
        rowModel.setProperty(i, "startDelay", 0);
        rowModel.setProperty(i, "staggerIdx", on ? rank : 0);
        rowModel.setProperty(i, "rowState",
                             on ? "leaving" : (band === "below" ? "collapsed" : "rest"));
        if (end > wave.end) wave.end = end;
    }

    // A row that was on its way out and is wanted back -- the user changing
    // their mind mid-collapse. THE DEPARTURE IS PLAYED BACKWARDS: the row that
    // left last is the first to return, and the rows above it follow in
    // reverse, each landing above the one before. A row that never started is
    // simply put back where it stands; one below the fold was never seen and
    // is placed when the return has landed.
    function _revive(i, e, now, reviveAt, topRank, late, wave) {
        if (e.rowState === "leaving" && e.kickAt > 0 && e.kickAt <= now) {
            // It is in the air. It finishes the flight it started -- the turn
            // happens at its OWN deadline (_turn) -- and every turned row aims
            // at one instant, `reviveAt`.
            const idx = Math.max(0, topRank - e.exitRank);
            rowModel.setProperty(i, "pend", "in");
            rowModel.setProperty(i, "pendAt", reviveAt);
            rowModel.setProperty(i, "pendIdx", idx);
            const end = reviveAt + idx * root.staggerMs + root.animDuration;
            if (end > wave.end) wave.end = end;
            return;
        }
        rowModel.setProperty(i, "exiting", false);
        rowModel.setProperty(i, "exitRank", -1);
        rowModel.setProperty(i, "pend", "");
        if (e.rowState === "collapsed") { late.push(i); return; }
        rowModel.setProperty(i, "startDelay", 0);
        rowModel.setProperty(i, "staggerIdx", 0);
        rowModel.setProperty(i, "rowState", "rest");
    }

    function _updateAt(i, w) {
        const e = rowModel.get(i);
        if (e.label !== w.label) rowModel.setProperty(i, "label", w.label);
        // A header's count holds still while a favourite is airborne: the
        // number changing the instant the model flips gives the move away
        // before the clone has carried it there. endGap's rebuild writes
        // the settled counts the moment the flight is over.
        if (e.count !== w.count && !(e.kind === "header" && root._flightKey.length > 0))
            rowModel.setProperty(i, "count", w.count);
        if (e.title !== w.title) rowModel.setProperty(i, "title", w.title);
        if (e.timeText !== w.timeText) rowModel.setProperty(i, "timeText", w.timeText);
        if (e.incognito !== w.incognito) rowModel.setProperty(i, "incognito", w.incognito);
        if (e.pinned !== w.pinned) rowModel.setProperty(i, "pinned", w.pinned);
        if (e.icon !== w.icon) rowModel.setProperty(i, "icon", w.icon);
        if (e.catKey !== w.catKey) rowModel.setProperty(i, "catKey", w.catKey);
        if (e.msgCount !== w.msgCount) rowModel.setProperty(i, "msgCount", w.msgCount);
        if (e.matches !== w.matches) rowModel.setProperty(i, "matches", w.matches);
    }

    // One greedy pass. `wi` is how far into `want` the surviving rows have
    // accounted for; a live row whose key does not appear at or after `wi`
    // is either gone or has moved backwards past a row that already claimed
    // its place -- both mean "leave here", and a moved row is re-inserted
    // further up as a fresh arrival.
    function _merge(want) {
        const keys = [];
        for (let i = 0; i < want.length; i++) keys.push(want[i].key);

        const now = Date.now();

        // WHEN THE AIR CLEARS. A wave that interrupts one still in flight is
        // aimed at the last deadline among the rows that have actually started
        // moving -- rows that have not started are cancelled rather than flown,
        // so this is never more than one row's flight away, whatever the depth
        // of the wave being interrupted. `topRank` is the deepest rank that
        // got out, and the return is ranked backwards from it.
        let reviveAt = now, exitAt = now, topRank = -1;
        for (let i = 0; i < rowModel.count; i++) {
            const e = rowModel.get(i);
            if (!(e.kickAt > 0) || e.kickAt > now) continue;
            const wanted = keys.indexOf(e.key) >= 0;
            if (e.exiting && wanted && e.rowState === "leaving") {
                if (e.doneAt > reviveAt) reviveAt = e.doneAt;
                if (e.exitRank > topRank) topRank = e.exitRank;
            } else if (!e.exiting && !wanted && e.rowState === "entering") {
                if (e.doneAt > exitAt) exitAt = e.doneAt;
            }
        }

        let wi = 0, mi = 0, enterN = 0, leaveN = 0;
        let moved = false;
        // The running geometry the bands are read from: `topY` is the top of
        // the entry about to be handled, `placed` how many entries stand above
        // it (only the first one's missing spacing depends on it). Each
        // entry's height is taken BEFORE it is touched, so a row zeroed by
        // this very wave does not move the rows below it into the viewport.
        let topY = 0, placed = 0;
        const wave = ({end: 0});
        const late = [];        // entries whose deadline is the wave's own end

        while (mi < rowModel.count) {
            const e = rowModel.get(mi);
            const h = root._entryFullH(placed, e);
            // A phantom belongs to the flight, not to the merge: it holds a
            // slot open and is removed by endGap. Its key was rewritten when
            // it became one, so it can never be matched as a survivor.
            if (e.isPhantom) { topY += h; placed++; mi++; continue; }
            // The row in flight, caught BEFORE the key lookup. Left where it
            // was as a phantom, so its old slot closes on the clone's reveal
            // rather than snapping shut -- and the wanted copy is inserted at
            // its destination further down this same pass. Looked up first,
            // it would have been treated as the survivor and the destination
            // would never have been created at all (an un-favourite moves the
            // row DOWN, so its key is still ahead of the cursor).
            if (e.kind === "row" && e.convId === root._flightKey) {
                rowModel.setProperty(mi, "key", "p:" + e.convId);
                rowModel.setProperty(mi, "isPhantom", true);
                topY += h; placed++; mi++;
                continue;
            }
            const j = keys.indexOf(e.key, wi);
            if (j < 0) {
                if (e.exiting) {
                    // Already on its way out on its own clock, and no wave may
                    // touch another's rows. A turn-around scheduled for it is
                    // simply off again.
                    if (e.pend !== "") { rowModel.setProperty(mi, "pend", ""); moved = true; }
                } else if (e.rowState === "entering" && e.kickAt > now) {
                    // It had not started, so it was never seen: gone now.
                    rowModel.setProperty(mi, "staggerIdx", 0);
                    rowModel.setProperty(mi, "rowState", "collapsed");
                    rowModel.setProperty(mi, "exiting", true);
                    rowModel.setProperty(mi, "doneAt", now);
                    moved = true;
                } else if (e.rowState === "entering") {
                    // IN FLIGHT the other way. It lands first and leaves
                    // afterwards, with the rest of its group: flipping it here
                    // would snap it from mid-entrance back to x = 0 at full
                    // height in one frame (measured 30.5 px of height and
                    // 340 px of x, against 6.0 and 67.3 for an ease step).
                    rowModel.setProperty(mi, "pend", "out");
                    rowModel.setProperty(mi, "pendAt", exitAt);
                    rowModel.setProperty(mi, "pendIdx", leaveN++);
                    moved = true;
                } else if (e.rowState === "collapsed") {
                    // A tail that was never placed: it was never on screen.
                    rowModel.setProperty(mi, "exiting", true);
                    rowModel.setProperty(mi, "doneAt", now);
                    moved = true;
                } else {
                    const band = root._bandOf(topY, h);
                    root._leave(mi, band, band === "on" ? leaveN++ : 0, now, wave);
                    if (band === "above") late.push(mi);
                    moved = true;
                }
                topY += h; placed++; mi++;
                continue;
            }
            while (wi < j) {
                const aw = want[wi];
                const ah = root._entryFullH(placed, aw);
                const band = root._bandOf(topY, ah);
                rowModel.insert(mi, root._arriving(aw, band,
                                                   band === "below" ? 0 : enterN++, now, wave));
                if (band === "below") late.push(mi);
                topY += ah; placed++;
                wi++; mi++; moved = true;
            }
            // A survivor -- or a row that was leaving and is wanted back,
            // which is a survivor too: it is turned around where it is, and no
            // second copy of it is ever inserted.
            if (e.exiting) {
                root._revive(mi, e, now, reviveAt, topRank, late, wave);
                moved = true;
            } else if (e.pend === "out") {
                // A deferred exit that the user has just cancelled.
                rowModel.setProperty(mi, "pend", "");
                moved = true;
            }
            root._updateAt(mi, want[j]);
            wi = j + 1;
            topY += h; placed++; mi++;
        }
        while (wi < want.length) {
            const aw = want[wi];
            const ah = root._entryFullH(placed, aw);
            const band = root._bandOf(topY, ah);
            rowModel.append(root._arriving(aw, band, band === "below" ? 0 : enterN++, now, wave));
            if (band === "below") late.push(rowModel.count - 1);
            topY += ah; placed++;
            wi++; moved = true;
        }
        // The rows that wait for the whole wave: the ones held at full height
        // above the fold, and the tail that is placed once the head has landed.
        // Their indices were taken as they were passed, and everything inserted
        // since went in BELOW them, so they still point where they did.
        for (let k = 0; k < late.length; k++)
            rowModel.setProperty(late[k], "doneAt", Math.max(wave.end, now));
        if (moved) retireTimer.restart();
    }

    // The sweeper. It acts on a row only when that row's OWN deadline has
    // passed, which is what stops a second wave finishing the first one's
    // flights early, and it stops itself the moment nothing is owed -- so
    // `retireTimer.running` still means "something in this panel is moving".
    function _retire() {
        const now = Date.now();
        let owed = false;
        for (let i = rowModel.count - 1; i >= 0; i--) {
            const e = rowModel.get(i);
            if (!e.exiting && e.pend === "" && e.rowState !== "entering"
                && e.rowState !== "collapsed")
                continue;
            if (now < e.doneAt) { owed = true; continue; }
            if (e.pend !== "") { root._turn(i, e, now); owed = true; continue; }
            if (e.exiting) { rowModel.remove(i); continue; }
            // An arrival that has landed, or a tail whose turn to be placed
            // has come.
            rowModel.setProperty(i, "rowState", "rest");
        }
        if (!owed) retireTimer.stop();
    }

    // A row that has finished the flight it was on and owes another one. The
    // turned wave aims at ONE instant (`pendAt`), so what each row must wait
    // depends on when its own flight ended -- that is AnimatedListRow's
    // `startDelayMs`, and it is why the return's order is the wave's and not
    // the order the rows happened to land in.
    function _turn(i, e, now) {
        const inbound = e.pend === "in";
        const idx = e.pendIdx;
        const delay = Math.max(0, Math.round(e.pendAt - now));
        const kick = now + Math.max(16, delay + idx * root.staggerMs);
        rowModel.setProperty(i, "pend", "");
        rowModel.setProperty(i, "pendAt", 0);
        rowModel.setProperty(i, "pendIdx", 0);
        rowModel.setProperty(i, "exiting", !inbound);
        rowModel.setProperty(i, "exitRank", inbound ? -1 : idx);
        rowModel.setProperty(i, "kickAt", kick);
        rowModel.setProperty(i, "doneAt", kick + root.animDuration);
        // startDelay and staggerIdx BEFORE rowState, always.
        rowModel.setProperty(i, "startDelay", delay);
        rowModel.setProperty(i, "staggerIdx", idx);
        rowModel.setProperty(i, "rowState", inbound ? "entering" : "leaving");
    }

    // ======================================================================
    // FLIGHT GLUE
    //
    // What RowFlight asks of its host: where the row is going, how to hold
    // the slot it vacates open and let it go again, how to commit the toggle,
    // and where the row sits in the model.
    // ======================================================================

    // Position in the WANTED list, which is derived from the store and so is
    // already correct the instant `setPinned` returns -- the model itself is
    // not rebuilt until the next callLater. -1 when the row is not listed
    // (its group is folded, or the search excludes it).
    //
    // The figure is a PLACE code -- group ordinal in the thousands, flat
    // index in the units -- not a bare index. RowFlight compares it before
    // and after the commit to decide whether the toggle moved the row at
    // all, and favouriting the FIRST row keeps its flat index: the fresh
    // Favorites header materialises exactly where the old top header stood,
    // so the row is still entry 1 and a bare index would read as "no move" and
    // skip the whole flight (the row would then re-enter on the list wave).
    // A favourite toggle always changes GROUP, so the group is part of the
    // answer. Only equality and -1 are ever read off this number.
    function _wantIndexOf(convId) {
        const want = root._wantRows();
        for (let i = 0; i < want.length; i++)
            if (want[i].kind === "row" && want[i].convId === convId)
                return Number(want[i].groupKey.substring(1)) * 1000 + i;
        return -1;
    }

    // The live wrapper for a conversation, skipping the phantom copy.
    function _rowItemFor(convId) {
        for (let i = 0; i < rowModel.count; i++) {
            const e = rowModel.get(i);
            if (e.isPhantom || e.kind !== "row" || e.convId !== convId) continue;
            return rowRepeater.itemAt(i);
        }
        return null;
    }

    function _modelIndexOf(convId) {
        for (let i = 0; i < rowModel.count; i++) {
            const e = rowModel.get(i);
            if (!e.isPhantom && e.kind === "row" && e.convId === convId) return i;
        }
        return -1;
    }

    // The live top of the vacated slot -- the phantom wrapper's CONTENT
    // line -- in `item` coordinates. NaN while no phantom exists: until the
    // deferred merge has swapped one in, the live row still holds the slot
    // and nothing has moved yet. The half row-gap is the wrapper's own
    // content offset, the same analytic figure _flightDestTopIn adds (the
    // phantom keeps its full spacing for as long as the ride lasts --
    // reveal is still 0).
    function _holeTopIn(item) {
        for (let i = 0; i < rowModel.count; i++) {
            if (!rowModel.get(i).isPhantom) continue;
            const it = rowRepeater.itemAt(i);
            if (!it) return NaN;
            return it.mapToItem(item, 0, 0).y
                 + (i === 0 ? 0 : root.rowGap * root._s / 2);
        }
        return NaN;
    }

    // Where the hole will COME TO REST once every row entering above it has
    // grown to full height -- summed from the model the way the destination
    // is (_flightDestTopIn), because those rows are still at zero height
    // when this is asked. The destination copy is skipped: its space opens
    // with the clone's reveal, not with the shelf.
    function _holeRestTopIn(item) {
        let pi = -1;
        for (let i = 0; i < rowModel.count; i++)
            if (rowModel.get(i).isPhantom) { pi = i; break; }
        if (pi < 0) return NaN;
        let y = 0;
        for (let i = 0; i < pi; i++) {
            const e = rowModel.get(i);
            if (e.kind === "row" && e.convId === root._flightKey) continue;
            y += root._entryFullH(i, e);
        }
        return listCol.mapToItem(item, 0, 0).y + y
             + (pi === 0 ? 0 : root.rowGap * root._s / 2);
    }

    // THE RIDE NEVER LEAVES THE VIEWPORT. Favouriting one of the last rows
    // with the list at its end and the shelf folded: the shelf opening above
    // would push the hole past the foot of the list, and the clone -- riding the
    // hole, which is right -- would go out of the popup with it. Decided ONCE
    // per flight, the moment the merge has left the phantom: if the rows
    // entering above would carry the hole past either end of the viewport,
    // the hole is anchored to the line it is on now and the list absorbs
    // the growth instead (_absorbNudge); otherwise the clone rides the
    // hole. One decision, from the model, so a row is either ridden or
    // held -- never ridden to the edge and then stopped.
    function _anchorHole() {
        const now = root._holeTopIn(listFlick);
        const rest = root._holeRestTopIn(listFlick);
        if (isNaN(now) || isNaN(rest)) { root._holdHoleY = NaN; return; }
        const out = rest + root._rowH > listFlick.height || rest < 0;
        root._holdHoleY = out ? now : NaN;
    }

    // The list's foot anchored instead of its head: after every positioning
    // pass of the Column while the hole is held, scroll by exactly what the
    // pass moved the hole, so the hole -- and the clone riding it -- hold
    // still on screen while the shelf grows above them. The content grew by
    // the same amount, so the scroll is always there to take. Done inside
    // the layout pass rather than from the ride's per-frame sample: a scroll
    // driven from the sample trails the layout by a frame, and the row at
    // the foot would wobble by that frame's growth (a fifth of the shelf on
    // the first one, the way OutCubic starts).
    function _absorbNudge() {
        const v = root._holeTopIn(listFlick);
        if (isNaN(v)) return;
        const d = v - root._holdHoleY;
        if (Math.abs(d) < 0.01) return;
        const maxY = Math.max(0, listFlick.contentHeight - listFlick.height);
        listFlick.contentY = Math.max(0, Math.min(maxY, listFlick.contentY + d));
    }
    Connections {
        target: listCol
        enabled: !isNaN(root._holdHoleY)
        function onPositioningComplete() { root._absorbNudge(); }
    }

    // The full height an entry occupies in the Column, from the same numbers
    // the delegate is sized by.
    function _entryFullH(i, e) {
        // A row retired below the fold gave up its space in the frame it was
        // told to, so it takes none here either.
        if (e.rowState === "collapsed" && e.exiting) return 0;
        const vs = i === 0 ? 0 : root.rowGap * root._s;
        if (e.kind === "header")
            // _headerH is normalised (the box and its half row-gap of
            // clearance), so every header is the same formula: box, half a
            // row gap below, the top pad matching it inside `vs` above.
            return root._headerH + root.rowGap / 2 * root._s + vs;
        return root._rowH + vs;
    }

    // WHICH CELLS ARE BUILT. A row's wrapper (its slot, its waves) exists for every entry of the model; what is drawn in it exists only
    // while the slot is within `_cellReach` of the viewport -- two row pitches either side, so a cell is built before it is seen and
    // a scroll of a notch (four rows) builds its new rows a frame ahead. Read from where the Column PUT the wrappers, after it has
    // put them (`positioningComplete`: a wrapper is at y 0 until then, and "near" would read as true for all of them -- the whole
    // history built, which is what this exists to avoid) and when the viewport moves. Imperative, not a binding per wrapper: one
    // walk, and a write only where the answer changed.
    readonly property real _cellReach: 2 * (root._rowH + root.rowGap * root._s)
    function _syncCells() {
        const lo = listFlick.contentY - root._cellReach;
        const hi = listFlick.contentY + listFlick.height + root._cellReach;
        for (let i = 0; i < rowRepeater.count; i++) {
            const it = rowRepeater.itemAt(i);
            if (!it)
                continue;
            const on = it.y + it.height >= lo && it.y <= hi;
            if (it.cellOn !== on)
                it.cellOn = on;
        }
    }
    Connections {
        target: listCol
        function onPositioningComplete() { root._syncCells(); }
    }

    // Where a row will COME TO REST, summed from the model rather than
    // measured off the item. Measuring is unusable here: the destination is
    // itself animating toward its new slot at exactly the moment the flight
    // needs to know where it is going, so a sample at any delay reads a
    // moving target. The phantom is skipped because it is about to give up
    // all of its height.
    function _flightDestTopIn(item, convId) {
        const di = root._modelIndexOf(convId);
        if (di < 0) return NaN;
        let y = 0;
        for (let i = 0; i < di; i++) {
            const e = rowModel.get(i);
            if (e.isPhantom) continue;
            y += root._entryFullH(i, e);
        }
        // AnimatedListRow offsets its content by half the virtual spacing and
        // the clone is aligned to the CONTENT, so summing wrapper heights
        // alone aims a few pixels high and the landing snaps.
        return listCol.mapToItem(item, 0, 0).y + y
             + (di === 0 ? 0 : root.rowGap * root._s / 2);
    }

    // The toggle the user just made, held here instead of being written
    // through.
    function _setPendingPin(convId, on) {
        if (root._pendingPins[convId] === undefined) root._pendingPinCount += 1;
        root._pendingPins[convId] = on;
        root._scheduleRebuild();
    }

    // The disk half, run only when nothing in the panel is moving. The map is
    // emptied BEFORE the store is told, so `_wantRows` gives one answer
    // across the swap: the override goes away in the same turn the real flag
    // arrives, and no rebuild ever catches the row back in its old group.
    function _persistPin() {
        if (root._pendingPinCount === 0) return;
        const pend = root._pendingPins;
        root._pendingPins = ({});
        root._pendingPinCount = 0;
        if (root.store && typeof root.store.setPinned === "function")
            for (const id in pend) root.store.setPinned(id, pend[id]);
    }

    // "At rest" is the flight being over AND the wave the landing started
    // having been retired -- both are facts this file already keeps, so the
    // watch is a poll of two booleans rather than a duration to guess at (a
    // wave's length depends on how many rows it moves). It runs only while a
    // favourite is unwritten, which is under a second per gesture.
    Timer {
        id: persistWatch
        interval: 60
        repeat: true
        running: root._pendingPinCount > 0
        onTriggered: {
            if (flightOverlay.active || retireTimer.running) return;
            root._persistPin();
        }
    }
    // A panel torn down with a favourite still in the air writes it now: the
    // user's gesture is not lost to a popup being closed.
    // Set as the panel goes: a rebuild queued for after the engine destroyed the popup would run in a half-torn item.
    property bool _gone: false
    Component.onDestruction: {
        root._gone = true;
        root._persistPin();
    }

    // Right-click on a row. The flight is the whole of the animation; the
    // model change happens inside it (RowFlight commits, then measures, so a
    // toggle that does not move the row never lifts at all).
    function _toggleFavorite(convId, rowItem) {
        if (!root.store || typeof root.store.setPinned !== "function") return;
        const idx = root._modelIndexOf(convId);
        const e = idx >= 0 ? rowModel.get(idx) : null;
        const willPin = e ? !e.pinned : true;
        if (!rowItem || flightOverlay.active) {
            // No clone to fly, but the list still waves the row into its new
            // group -- so this goes through the same pending flag, and the
            // disk still waits for the wave to finish.
            root._setPendingPin(convId, willPin);
            return;
        }
        // The destination has to exist to be flown to. A folded group would
        // swallow the row and the flight would degrade to a clone leaving
        // stage right -- which is RowFlight's answer for a row with no home,
        // not an answer for a move the user just asked to see.
        root._setCollapsed(willPin ? "g0" : ("g" + (1 + root._dateGroupOf(
            root._updatedAtOf(convId)))), false);
        // Recorded before the commit: _wantRows holds this group's header
        // alive for the whole flight even if this row was its last.
        root._flightFromGroup = e ? e.groupKey : "";
        // Lift off from the wrapper's CONTENT, not the wrapper: the wrapper
        // starts half its virtual spacing above the visible row, and a
        // clone launched from there would hang 3px over the wash it is cloning.
        const srcItem = rowItem.cellItem !== undefined ? rowItem.cellItem
                                                       : rowItem;
        flightOverlay.begin(convId, srcItem, {
            title: e ? e.title : "",
            timeText: e ? e.timeText : "",
            incognito: e ? e.incognito : false,
            icon: e ? e.icon : "",
            catKey: e ? e.catKey : "",
            active: root.activeId === convId
        });
    }

    function _updatedAtOf(convId) {
        const m = root.store && root.store.conversations ? root.store.conversations : null;
        if (!m) return 0;
        for (let i = 0; i < m.count; i++) {
            const c = m.get(i);
            if (c.convId === convId) return c.updatedAt || c.createdAt || 0;
        }
        return 0;
    }

    // ======================================================================
    // THE COLLAPSE
    //
    // One fraction for the whole open/close transition. The layer stops
    // taking input the moment it starts leaving, so a click during the ease
    // cannot land on the half-faded panel.
    // ======================================================================
    property real _openF: root.open ? 1 : 0
    Behavior on _openF {
        NumberAnimation { duration: root.resizeMs; easing.type: Easing.OutCubic }
    }

    // ======================================================================
    // EXPANDED
    // ======================================================================
    Item {
        id: expanded
        // Laid out ONCE at openWidth and SQUASHED to the animated width, so
        // collapsing cannot spill: re-laying out at every animated width
        // sent the right-anchored things past the panel's own edges (and
        // out over the popup), and re-elided every title per frame. The
        // scale is 1 exactly whenever the panel is open and at rest, so no
        // ShadowBox bevel is sheared on any settled frame -- only while the
        // collapse's own fade already has this whole layer on its way out,
        // and it is long gone by the time the width reaches 0.
        width: root.openWidth
        height: root.height
        transform: Scale {
            origin.x: 0
            xScale: root.openWidth > 0
                ? Math.min(1, root.width / root.openWidth) : 1
        }
        opacity: root._openF
        visible: root._openF > 0.01
        enabled: root.open

        // ONE padding number, and the host has already applied it: the popup
        // lays this panel out inside its own margin, so a container here sits
        // at x = 0 and runs to the panel's edges. Padding again on the inside
        // would put the list box two paddings from the popup's edge while the
        // transcript beside it sits at one, and would lift the sidebar's foot
        // clear of the composer's. `padding` is the gap BETWEEN the search
        // box and the list container, and nothing else.
        readonly property real innerW: expanded.width

        // -- Search --------------------------------------------------------
        ShadowBox {
            id: searchBox
            visible: root.showSearch
            // The panel's content starts at the panel's top: the header row
            // lives in the popup.
            y: 0
            width: expanded.innerW
            height: root.buttonHeight
            baseRadius: 8
            // Carved into the popup's surface, so that is the ground
            // outside its edge.
            surfaceColor: root.surfaceColor
            backgroundColor: root.panelColor
            bevelColor: root.bevelColor
            shadowColor: root.borderColor
            bevelWidth: 1
            shadowWidth: 3

            Text {
                id: searchGlyph
                x: 9
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                font.family: root.glyphFamily
                font.pixelSize: root.timeSize
                color: root.faintText
            }

            TextField {
                id: searchField
                Keys.forwardTo: [searchFieldKeys]
                EditKeys {
                    id: searchFieldKeys
                    target: searchField
                }
                anchors.fill: parent
                anchors.leftMargin: searchGlyph.x + searchGlyph.implicitWidth + 7
                anchors.rightMargin: 8
                // Bound, then written back on edit: the property stays the
                // one place the query lives, so a host can set it.
                text: root.query
                onTextEdited: root.query = searchField.text
                placeholderText: "Search chats"
                font.family: root.fontFamily
                font.pixelSize: root.titleSize
                color: root.primaryText
                placeholderTextColor: root.faintText
                selectionColor: root.accent
                selectedTextColor: root.textOnAccent
                verticalAlignment: TextInput.AlignVCenter
                background: null            // the ShadowBox is the chrome
                Keys.onEscapePressed: root.query = ""
            }
        }

        // -- The list ------------------------------------------------------
        ShadowBox {
            id: listBox
            y: searchBox.visible ? searchBox.y + searchBox.height + root.padding : 0
            width: expanded.innerW
            // To the panel's foot, which the popup has put level with the
            // composer's foot.
            height: Math.max(0, root.height - y)
            baseRadius: root.containerRadius
            surfaceColor: root.surfaceColor
            backgroundColor: root.listBoxColor
            bevelColor: root.bevelColor
            shadowColor: root.borderColor
            bevelWidth: 1
            shadowWidth: 3

            Text {
                anchors.centerIn: parent
                width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
                text: root._emptyText
                visible: root._emptyText.length > 0
                color: root.faintText
                font.family: root.fontFamily
                font.pixelSize: root.titleSize
                elide: Text.ElideRight
            }

            // A HEADER MEETS THE CONTAINER'S EDGE, SO THE CLIP MUST NOT BE
            // ON IT. The list is laid out at the container's width and a
            // header's box runs edge to edge, which is the whole reason the
            // two share a corner -- but a clip is a SCISSOR RECTANGLE IN
            // DEVICE PIXELS, and Qt rounds the viewport's scene rect to whole
            // ones, while the container's own ShadowBox draws its edge where
            // it really is, antialiased. Put the panel on a half pixel --
            // which a centred stage and a physics-driven popup both do --
            // and the two disagree by one column: the scissor lands a pixel
            // inside the container on the side the rounding leans away from,
            // the header's last column is scissored off there, and the
            // container's own inset shadow shows through the gap. Measured at
            // a +0.5px offset, on the column straddling the edge: LEFT half
            // bevel + half header box, RIGHT all bevel and no header box at
            // all. A half pixel rounds DOWN, so any offset up to a half cuts
            // the RIGHT edge, and an offset above it cuts the left, the same
            // defect on the other side.
            // It is a rounding, not a width and not a margin: at a
            // whole-pixel offset the same layout is exact to the pixel.
            //
            // So the clip is moved one pixel OUT on each side and the list is
            // put back where it was (`listCol.x`): the geometry is identical,
            // and the rounding now eats a pixel of slack instead of a pixel
            // of header. The only thing that lives in that ring is the header
            // box's own bevel -- the light rim a ShadowBox draws outside its
            // edge -- and the dressing's bevel line, the same colour
            // (`bevel` and `headerBoxBevel` are one value in both modes),
            // is painted over it. VERTICALLY the clip stays exactly on the
            // container's edge: rows scroll through that edge and the clip is
            // what keeps them out of the surface.
            //
            // ONE pixel, and not more, because one pixel is exactly the ring
            // the dressing paints over: give the clip four and a row sliding
            // out of a search wave would show outside the container, which is
            // what the clip is there to prevent.
            readonly property real clipBleed: 1
            Flickable {
                id: listFlick
                objectName: "llmSidebarList"      // the scroll probe wheels it
                anchors.fill: parent
                anchors.leftMargin: -listBox.clipBleed
                anchors.rightMargin: -listBox.clipBleed
                clip: true
                contentWidth: width
                contentHeight: listCol.height
                boundsBehavior: Flickable.StopAtBounds
                // Frozen while a clone is airborne: the flight scrolls the
                // list itself to bring an off-screen destination into view.
                interactive: !flightOverlay.scrollLocked
                // The viewport moved or was resized: the cells near it are the ones built (`_syncCells`).
                onContentYChanged: root._syncCells()
                onHeightChanged: root._syncCells()

                Column {
                    id: listCol
                    // Full width: there is no scroll bar and no reserved
                    // lane, so the header boxes run edge to edge and the
                    // titles have the lane's pixels. The width is
                    // the CONTAINER's, not the clip's -- the clip is a pixel
                    // wider on each side (see `clipBleed`) and this puts the
                    // list back on the container's own edges.
                    x: listBox.clipBleed
                    width: listFlick.width - 2 * listBox.clipBleed
                    // AnimatedListRow reserves its own virtual spacing; a
                    // Column spacing on top of it would double the gap and
                    // would not collapse with a leaving row.
                    spacing: 0

                    Repeater {
                        id: rowRepeater
                        model: rowModel

                        delegate: AnimatedListRow {
                            id: wrap
                            required property int index
                            required property var model

                            // The content cell, for the flight's lift-off:
                            // the wrapper's own top sits half the virtual
                            // spacing ABOVE the visible row, so the clone
                            // maps this instead.
                            readonly property Item cellItem: cell

                            // THE CELL IS BUILT ONLY NEAR THE VIEWPORT (`_syncCells`):
                            // a conversation row is ~25 items and a history is
                            // 80 of them -- 3 654 of the popup's 4 541 items,
                            // which would be built in the click's frame. The
                            // wrapper stays for every entry (it is the row's
                            // slot: its height is a formula, the waves animate
                            // it, the flight aims at it); only what is drawn in
                            // it comes and goes. Headers are always built (five
                            // at most, and a header measures itself).
                            property bool cellOn: false

                            width: listCol.width
                            animDuration: root.animDuration
                            staggerMs: root.staggerMs

                            // The row in flight exists twice: the phantom
                            // gives up exactly the space the destination is
                            // taking, so the list shifts by the difference
                            // rather than twice.
                            readonly property real revealF: {
                                if (root._flightKey.length === 0) return 1;
                                if (wrap.model.isPhantom) return 1 - flightOverlay.reveal;
                                if (wrap.model.kind === "row"
                                    && wrap.model.convId === root._flightKey)
                                    // Before the merge has left the phantom,
                                    // this live copy IS the vacated slot:
                                    // reading `reveal` (0) here would collapse
                                    // it for however long the deferred merge
                                    // takes -- a one-frame flicker. After
                                    // the merge it is the destination, whose
                                    // space the clone's travel opens.
                                    return root._flightMerged
                                        ? flightOverlay.reveal : 1;
                                return 1;
                            }
                            // Exactly one copy of a flying row is on screen,
                            // and it is the clone. Zero opacity rather than
                            // `visible: false`: the wrapper measures its
                            // content, and an invisible child measures short.
                            readonly property bool flying:
                                root._flightKey.length > 0
                                && wrap.model.kind === "row"
                                && wrap.model.convId === root._flightKey

                            // The first entry meets the container's top edge,
                            // so it claims no spacing above it.
                            virtualSpacing: (wrap.index === 0 ? 0 : root.rowGap * root._s)
                                          * wrap.revealF
                            // A row's height is a formula, not a measurement,
                            // so the flight's analytic geometry and the layout
                            // cannot disagree. A header measures itself.
                            contentHeight: wrap.model.kind === "row"
                                ? root._rowH * wrap.revealF : -1
                            // startDelay and staggerIdx BEFORE rowState: the
                            // state change is what schedules the flight, and it
                            // reads both of them when it does.
                            startDelayMs: wrap.model.startDelay
                            staggerIdx: wrap.model.staggerIdx
                            rowState: wrap.model.rowState

                            Loader {
                                id: cell
                                anchors.left: parent.left
                                anchors.right: parent.right
                                opacity: wrap.flying ? 0 : 1
                                // A row being renamed or asked about stays built wherever it scrolls to: its field and its
                                // question are a thing in progress.
                                active: wrap.model.kind === "header" || wrap.cellOn
                                        || (wrap.model.kind === "row" && (wrap.model.convId === root._renameId
                                                                          || wrap.model.convId === root._confirmId))
                                sourceComponent: wrap.model.kind === "header" ? headerCell : rowCell
                            }

                            // ---- A group ----
                            Component {
                                id: headerCell

                                // The half row-gap here mirrors the half the
                                // header's own bottomGap keeps below its box:
                                // with the wrapper's symmetric spacing on top
                                // of each, a header stands exactly as far
                                // from the last row above as from its own
                                // first row. A section clearance only above
                                // would read as a bigger gap before every
                                // header than after it.
                                Item {
                                    id: headCell
                                    implicitHeight: sectionHeader.y + sectionHeader.implicitHeight

                                    ListSectionHeader {
                                        id: sectionHeader
                                        width: headCell.width
                                        y: wrap.index === 0
                                           ? 0 : root.rowGap / 2 * root._s
                                        // The next row brings half the row gap
                                        // with it, so this is the other half
                                        // -- except for the topmost header,
                                        // whose wrapper claims no spacing at
                                        // all (it meets the container's top
                                        // edge), so its own gap carries the
                                        // half the wrapper would have: every
                                        // header sits exactly rowGap * 1.5
                                        // from its first row, first or not.
                                        bottomGap: wrap.index === 0
                                                   ? root.rowGap : root.rowGap / 2
                                        // Measured once for the flight's
                                        // analytic geometry; the header is
                                        // the one entry whose height is
                                        // ListSectionHeader's own business.
                                        // NORMALISED to box + half row-gap:
                                        // the topmost header carries a full
                                        // rowGap in its bottomGap (see
                                        // above), and the two variants must
                                        // write the same figure or a flight
                                        // past the first header lands 3px
                                        // off.
                                        onImplicitHeightChanged:
                                            root._measuredHeaderH = sectionHeader.implicitHeight
                                                - (wrap.index === 0 ? root.rowGap / 2 * root._s : 0)
                                        Component.onCompleted:
                                            root._measuredHeaderH = sectionHeader.implicitHeight
                                                - (wrap.index === 0 ? root.rowGap / 2 * root._s : 0)

                                        title: wrap.model.label
                                        // Compact puts the count on the title
                                        // line, right-aligned, and leaves the
                                        // header one line tall. The chevron is
                                        // the component's own -- there is no
                                        // second one anywhere in this file.
                                        compactLayout: true
                                        subtitle: wrap.model.count === 1
                                            ? "1 conversation"
                                            : wrap.model.count + " conversations"
                                        expandable: true
                                        expanded: !root._isCollapsed(wrap.model.groupKey)
                                        onToggled: root.toggleGroup(wrap.model.groupKey)

                                        titleSize: root.sectionTitleSize
                                        subtitleSize: root.timeSize
                                        listScale: root.listScale
                                        fontFamily: root.fontFamily
                                        // Muted: the conversation titles are the
                                        // ink here, the group is the scaffolding.
                                        textColor: root.mutedText
                                        mutedColor: root.mutedText
                                        faintColor: root.faintText
                                        boxColor: root.headerBoxColor
                                        // Carved into the list container, so its
                                        // fill is the ground outside this box.
                                        boxSurfaceColor: root.listBoxColor
                                        boxBevelColor: root.headerBoxBevelColor
                                        boxShadowColor: root.headerBoxShadowColor
                                        // ONE radius, all four corners, every
                                        // header: the container's. A mixed
                                        // box (the container's 14 on top, the
                                        // house 10 below) reads as a mistake.
                                        // The headers run edge to edge, so
                                        // every header meets the container's
                                        // sides and takes its curve; ShadowBox's
                                        // limitRadius keeps the short box
                                        // sane. Handed over pre-divided --
                                        // ShadowBox multiplies every radius
                                        // by sizeScale (here the list scale).
                                        boxRadius: root.containerRadius / root._s
                                        // No category colour to report: kill the
                                        // idle sliver ShadowBox would otherwise
                                        // draw at progress 0.
                                        idleWidthPx: 0
                                        accentColor: root.accent
                                        errorColor: root.errColor
                                    }
                                }
                            }

                            // ---- A conversation ----
                            Component {
                                id: rowCell

                                Item {
                                    id: rowItem

                                    readonly property string convId: wrap.model.convId
                                    readonly property bool renaming: root._renameId === rowItem.convId
                                    readonly property bool confirming: root._confirmId === rowItem.convId
                                    readonly property bool busy: rowItem.renaming || rowItem.confirming
                                    onRenamingChanged: if (rowItem.renaming) renameField.begin()
                                    readonly property bool active: root.activeId === rowItem.convId
                                    // An EMPTY conversation is a fact, not a
                                    // promise: it says "New conversation" in
                                    // faint text. A skeleton stands in only
                                    // for a title actually being made --
                                    // messages exist and the name has not
                                    // landed. The active conversation is
                                    // told by the host; every other row
                                    // reads its own empty title.
                                    readonly property bool placeholder:
                                        wrap.model.title.length === 0
                                        && wrap.model.msgCount === 0
                                    readonly property bool pending: !rowItem.placeholder
                                        && (wrap.model.title.length === 0
                                            || (rowItem.active && root.titlePending))
                                    // The icon slot exists when there is an
                                    // icon to show or one is on its way with
                                    // the pending title; no category, no
                                    // slot. Fixed width -- glyphs vary by a
                                    // pixel or two, the slot does not, so
                                    // every title in a group starts flush.
                                    readonly property bool hasIcon: !rowItem.placeholder
                                        && (wrap.model.icon.length > 0 || rowItem.pending)
                                    readonly property real iconSlotW: 14 * root._s
                                    readonly property string catLabel: {
                                        const c = root._catInfo(wrap.model.catKey);
                                        return c ? c.label : "";
                                    }

                                    implicitHeight: root._rowH

                                    // Hover is OR-ed across the row and its
                                    // glyph buttons: a child MouseArea takes
                                    // the hover for itself, so without this
                                    // pointing at the trash would fade the
                                    // trash away.
                                    readonly property bool hovered:
                                        rowMa.containsMouse || editMa.containsMouse || delMa.containsMouse
                                        || iconTipMa.containsMouse
                                        || root.hoverId === rowItem.convId
                                    property real hoverF: (rowItem.hovered && !rowItem.busy) ? 1 : 0
                                    Behavior on hoverF {
                                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                                    }
                                    property real activeF: rowItem.active ? 1 : 0
                                    Behavior on activeF {
                                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                                    }

                                    readonly property real contentL: root.rowInset + 9 * root._s
                                    readonly property real contentR: Math.max(0, rowItem.width - root.rowInset)
                                    // The right slot is as wide as the widest
                                    // thing that can occupy it, so hovering a
                                    // row never re-elides its title.
                                    readonly property real rightW: rowItem.confirming
                                        ? confirmRow.width
                                        : Math.max(timeRow.implicitWidth, controlsRow.width)
                                    // What the title has to say its name in.
                                    // A long one elides; nothing overflows.
                                    readonly property real titleW: Math.max(0,
                                        rowItem.contentR - rowItem.rightW - 8 * root._s - titleText.x)

                                    // While searching, the matched
                                    // substring(s) of the title wear the
                                    // accent TEXT colour. Engaged only when
                                    // the query actually occurs in the
                                    // TITLE (a row can be listed on a
                                    // preview hit alone), so a row without
                                    // a visible match -- and every row when
                                    // the query is empty -- renders through
                                    // the untouched plain path.
                                    readonly property bool searchStyled:
                                        root._queryLC.length > 0
                                        && !rowItem.placeholder && !rowItem.pending
                                        && wrap.model.title.toLowerCase()
                                               .indexOf(root._queryLC) >= 0

                                    // The truncation the Text would have
                                    // done, computed up front: styled text
                                    // cannot elide, so the string is elided
                                    // HERE and marked up afterwards. Same
                                    // font, same width, so the cut lands
                                    // where the plain path cuts.
                                    TextMetrics {
                                        id: titleMetrics
                                        font.family: root.fontFamily
                                        font.pixelSize: root.titleSize * root._s
                                        elide: Text.ElideRight
                                        elideWidth: Math.max(0, rowItem.titleW)
                                        text: rowItem.searchStyled
                                              ? wrap.model.title : ""
                                    }

                                    // How deep the row's own wash is. One
                                    // number, because anything drawn ON the
                                    // wash has to move with it to keep its
                                    // contrast -- the skeleton below is the
                                    // case that proved it. The row being
                                    // renamed or asked about keeps the wash:
                                    // it is the one the question is about.
                                    readonly property real washF: Math.max(
                                        rowItem.hoverF * 0.8, rowItem.activeF,
                                        rowItem.busy ? 0.8 : 0)

                                    // A faint wash, deeper for the open chat.
                                    Rectangle {
                                        x: root.rowInset
                                        width: Math.max(0, rowItem.width - root.rowInset * 2)
                                        height: rowItem.height
                                        radius: 8 * root._s
                                        color: Mix.c(root.listBoxColor, root.headerBoxColor,
                                                     rowItem.washF)
                                    }

                                    MouseArea {
                                        id: rowMa
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                                        onClicked: mouse => {
                                            if (mouse.button === Qt.RightButton)
                                                root._toggleFavorite(rowItem.convId, wrap);
                                            else
                                                root.selected(rowItem.convId);
                                        }
                                    }

                                    // The open conversation's stripe, the
                                    // same 3px mark the package rows carry
                                    // -- in the conversation's own category
                                    // hue, accent when it has none.
                                    Rectangle {
                                        x: root.rowInset
                                        y: 3 * root._s
                                        width: 3 * root._s
                                        height: Math.max(0, rowItem.height - 6 * root._s)
                                        radius: width / 2
                                        color: root.categoryColor(wrap.model.catKey)
                                        opacity: rowItem.activeF
                                    }

                                    // The conversation's topic icon, muted
                                    // like the turn header's: one fact one
                                    // mark -- the category's colour lives in
                                    // the transcript's header inset, not
                                    // here a second time. The words live in
                                    // the hover tip, once.
                                    Text {
                                        id: catIcon
                                        x: rowItem.contentL
                                        width: rowItem.iconSlotW
                                        horizontalAlignment: Text.AlignHCenter
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: rowItem.hasIcon && !rowItem.pending
                                        text: wrap.model.icon
                                        font.family: root.glyphFamily
                                        font.pixelSize: root.titleSize * root._s
                                        color: root.mutedText

                                        // Hover only -- no buttons, so a
                                        // click on the icon is still a click
                                        // on the row underneath it.
                                        MouseArea {
                                            id: iconTipMa
                                            anchors.fill: parent
                                            anchors.margins: -2
                                            hoverEnabled: true
                                            acceptedButtons: Qt.NoButton
                                            cursorShape: undefined   // clicks pass through: the cursor is what lies under it (a MouseArea owns an Arrow)
                                        }
                                    }

                                    HoverTip {
                                        show: iconTipMa.containsMouse && catIcon.visible
                                        anchorItem: catIcon
                                        overlayItem: root.overlayItem
                                        text: rowItem.catLabel
                                        fontFamily: root.fontFamily
                                        surfaceColor: root.surfaceColor
                                        bevelColor: root.bevelColor
                                        shadowColor: root.borderColor
                                        textColor: root.primaryText
                                    }

                                    // Incognito, and nothing else: being in
                                    // the Favorites group already says the
                                    // row is a favourite, and a second mark
                                    // for the same fact is a second claim.
                                    Text {
                                        id: marks
                                        x: rowItem.hasIcon
                                           ? rowItem.contentL + rowItem.iconSlotW + 6 * root._s
                                           : rowItem.contentL
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: ""
                                        visible: wrap.model.incognito
                                        font.family: root.glyphFamily
                                        font.pixelSize: root.timeSize * root._s
                                        color: root.mutedText
                                    }

                                    Text {
                                        id: titleText
                                        x: marks.visible ? marks.x + marks.implicitWidth + 5 * root._s
                                                         : marks.x
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: rowItem.titleW
                                        visible: !rowItem.renaming && !rowItem.pending
                                        text: rowItem.searchStyled
                                              ? root._styledTitle(
                                                    titleMetrics.elidedText,
                                                    root._queryLC)
                                              : (rowItem.placeholder
                                                 ? "New conversation"
                                                 : wrap.model.title)
                                        // One line, elided, whatever arrives.
                                        // The model already collapsed the
                                        // string to one line; these two make
                                        // the Text safe against any string
                                        // on its own -- a pasted paragraph
                                        // can neither wrap nor overflow.
                                        // While a match is coloured the
                                        // string is StyledText -- which Qt
                                        // cannot elide -- so it arrives
                                        // pre-elided from titleMetrics and
                                        // the Text's own elide steps aside.
                                        elide: rowItem.searchStyled
                                               ? Text.ElideNone : Text.ElideRight
                                        textFormat: rowItem.searchStyled
                                                    ? Text.StyledText : Text.PlainText
                                        maximumLineCount: 1
                                        font.family: root.fontFamily
                                        font.pixelSize: root.titleSize * root._s
                                        color: rowItem.placeholder
                                               ? root.faintText
                                               : Mix.c(root.primaryText,
                                                       root.categoryColor(wrap.model.catKey),
                                                       rowItem.activeF)
                                    }

                                    // The icon's silhouette: a small square
                                    // in the icon slot, so the skeleton is
                                    // the SHAPE of what will arrive -- the
                                    // classification lands an icon and a
                                    // title together, and both resolve in
                                    // place.
                                    //
                                    // A skeleton is ~10 objects (the slab, its fade, the
                                    // breath's animations) and only a row whose title is
                                    // being written needs one, so it is built when it is
                                    // wanted and gone when the title lands.
                                    Loader {
                                        x: catIcon.x + (rowItem.iconSlotW - width) / 2
                                        anchors.verticalCenter: parent.verticalCenter
                                        active: rowItem.pending && !rowItem.renaming
                                        sourceComponent: SkeletonBar {
                                            width: Math.round(root.titleSize * 0.9 * root._s)
                                            height: width
                                            radius: 3 * root._s
                                            barColor: Mix.c(root.headerBoxColor,
                                                            root.borderColor, rowItem.washF)
                                            groundColor: Mix.c(root.listBoxColor,
                                                               root.headerBoxColor, rowItem.washF)
                                        }
                                    }

                                    // Cut to the real text's own geometry --
                                    // the line's x, its vertical centre, a
                                    // plausible run of it -- so the title
                                    // resolves in place when it arrives.
                                    Loader {
                                        x: titleText.x
                                        anchors.verticalCenter: parent.verticalCenter
                                        active: rowItem.pending && !rowItem.renaming
                                        sourceComponent: SkeletonBar {
                                            width: Math.min(rowItem.titleW, 120 * root._s)
                                            height: Math.round(rowFm.height * 0.5)
                                            // Darkens exactly as far as the
                                            // ground under it does, so the bar
                                            // reads the same on a plain row and
                                            // on the open one -- at one fixed
                                            // colour it would vanish into the
                                            // active row's wash, the same tone.
                                            barColor: Mix.c(root.headerBoxColor,
                                                            root.borderColor, rowItem.washF)
                                            groundColor: Mix.c(root.listBoxColor,
                                                               root.headerBoxColor, rowItem.washF)
                                        }
                                    }

                                    // Rename happens where the title is, not
                                    // in a dialog: the row keeps its place in
                                    // the list while it is being retitled.
                                    TextInput {
                                        id: renameField
                                        Keys.forwardTo: [renameFieldKeys]
                                        EditKeys {
                                            id: renameFieldKeys
                                            target: renameField
                                            selectAll: true
                                        }
                                        x: titleText.x
                                        width: rowItem.titleW
                                        anchors.verticalCenter: parent.verticalCenter
                                        visible: rowItem.renaming
                                        clip: true
                                        font.family: root.fontFamily
                                        font.pixelSize: root.titleSize * root._s
                                        color: root.primaryText
                                        selectByMouse: true
                                        selectionColor: root.accent
                                        selectedTextColor: root.textOnAccent
                                        // Driven off `renaming`, not off
                                        // `visible`: an Item is visible by
                                        // default, so a row created ALREADY
                                        // in rename never sees the change
                                        // -- and `visible` read back is
                                        // effective visibility, which says
                                        // nothing about this binding.
                                        function begin() {
                                            renameField.text = wrap.model.title;
                                            renameField.forceActiveFocus();
                                            // Selected backwards, so the
                                            // cursor lands at 0 and a title
                                            // too long for the slot shows its
                                            // START -- what you are about to
                                            // retype, not its tail.
                                            renameField.select(renameField.text.length, 0);
                                        }
                                        Component.onCompleted: if (rowItem.renaming) renameField.begin()
                                        onActiveFocusChanged: {
                                            if (!renameField.activeFocus && rowItem.renaming)
                                                root._renameId = "";
                                        }
                                        Keys.onReturnPressed: rowItem.commitRename()
                                        Keys.onEnterPressed: rowItem.commitRename()
                                        Keys.onEscapePressed: root._renameId = ""
                                    }

                                    function commitRename() {
                                        const t = renameField.text.trim();
                                        root._renameId = "";
                                        if (t.length > 0 && t !== wrap.model.title)
                                            root.renameRequested(rowItem.convId, t);
                                    }

                                    // Right slot, at rest: how many times the
                                    // query hits in this chat, then when it
                                    // was last spoken in.
                                    Row {
                                        id: timeRow
                                        anchors.right: parent.right
                                        anchors.rightMargin: root.rowInset + 4 * root._s
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 6 * root._s
                                        opacity: rowItem.busy ? 0 : 1 - rowItem.hoverF
                                        visible: timeRow.opacity > 0.01

                                        Text {
                                            text: wrap.model.matches > 0 ? String(wrap.model.matches) : ""
                                            visible: text.length > 0
                                            font.family: root.fontFamily
                                            font.pixelSize: root.timeSize * root._s
                                            color: root.accent
                                        }
                                        Text {
                                            text: wrap.model.timeText
                                            font.family: root.fontFamily
                                            font.pixelSize: root.timeSize * root._s
                                            color: root.faintText
                                        }
                                    }

                                    // Right slot, hovered. Bare glyphs: the
                                    // pointer and a colour fade are the whole
                                    // affordance.
                                    Row {
                                        id: controlsRow
                                        anchors.right: parent.right
                                        anchors.rightMargin: root.rowInset + 4 * root._s
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: 10 * root._s
                                        opacity: rowItem.busy ? 0 : rowItem.hoverF
                                        visible: controlsRow.opacity > 0.01

                                        Text {
                                            id: editGlyph
                                            text: ""
                                            font.family: root.glyphFamily
                                            font.pixelSize: root.titleSize * root._s
                                            color: Mix.c(root.mutedText, root.primaryText,
                                                         editMa.containsMouse ? 1 : 0)
                                            MouseArea {
                                                id: editMa
                                                anchors.fill: parent
                                                anchors.margins: -4
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root._confirmId = "";
                                                    root._renameId = rowItem.convId;
                                                }
                                            }
                                        }
                                        Text {
                                            id: delGlyph
                                            text: ""
                                            font.family: root.glyphFamily
                                            font.pixelSize: root.titleSize * root._s
                                            color: Mix.c(root.mutedText, root.errColor,
                                                         delMa.containsMouse ? 1 : 0)
                                            MouseArea {
                                                id: delMa
                                                anchors.fill: parent
                                                anchors.margins: -4
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    root._renameId = "";
                                                    root._confirmId = rowItem.convId;
                                                    confirmTimer.restart();
                                                }
                                            }
                                        }
                                    }

                                    // Asked once, in place, and forgotten
                                    // again after confirmMs -- a question
                                    // that stays on screen is a trap.
                                    //
                                    // Two buttons and no question: "Yes" and
                                    // "No" ARE the question, and the row they
                                    // sit in is what they are about. A word
                                    // asking "delete?" beside them says the
                                    // same thing a second time and costs the
                                    // title the width to say its own name.
                                    Loader {
                                        id: confirmRow
                                        anchors.right: parent.right
                                        anchors.rightMargin: root.rowInset + 4 * root._s
                                        anchors.verticalCenter: parent.verticalCenter
                                        // Built when a deletion is asked and gone when it is answered: two RaisedButtons are
                                        // ~15 items on every row of the history, for a question one row at a time is ever asked.
                                        active: rowItem.confirming
                                        sourceComponent: Row {
                                            spacing: 6 * root._s

                                            RaisedButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                height: Math.max(16, rowItem.height - 6 * root._s)
                                                minWidth: 0
                                                horizontalPadding: 8
                                                text: "Yes"
                                                fontPixelSize: root.timeSize * root._s
                                                fontFamily: root.fontFamily
                                                accent: true
                                                // The destructive answer wears
                                                // the error colour, not the
                                                // accent: it is not the default.
                                                accentColor: root.errColor
                                                accentHoverColor: Qt.lighter(root.errColor, 1.12)
                                                accentBevelColor: Qt.lighter(root.errColor, 1.35)
                                                accentTextColor: root.textOnAccent
                                                surfaceColor: root.listBoxColor
                                                plateauColor: root.buttonPlateau
                                                plateauHoverColor: root.buttonPlateauHover
                                                bevelColor: root.buttonBevel
                                                shadowColor: root.buttonShadow
                                                textColor: root.primaryText
                                                faintTextColor: root.faintText
                                                shadowWidth: 3
                                                onClicked: {
                                                    root._confirmId = "";
                                                    confirmTimer.stop();
                                                    root.removeRequested(rowItem.convId);
                                                }
                                            }
                                            RaisedButton {
                                                anchors.verticalCenter: parent.verticalCenter
                                                height: Math.max(16, rowItem.height - 6 * root._s)
                                                minWidth: 0
                                                horizontalPadding: 8
                                                text: "No"
                                                fontPixelSize: root.timeSize * root._s
                                                fontFamily: root.fontFamily
                                                surfaceColor: root.listBoxColor
                                                plateauColor: root.buttonPlateau
                                                plateauHoverColor: root.buttonPlateauHover
                                                bevelColor: root.buttonBevel
                                                shadowColor: root.buttonShadow
                                                accentColor: root.accent
                                                accentHoverColor: root.accentHover
                                                accentBevelColor: root.accentBevel
                                                textColor: root.mutedText
                                                faintTextColor: root.faintText
                                                accentTextColor: root.textOnAccent
                                                shadowWidth: 3
                                                onClicked: {
                                                    root._confirmId = "";
                                                    confirmTimer.stop();
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Smears the list vertically while it scrolls under a flying
                // favourite. Idle at all other times -- MotionBlur bypasses
                // its own capture below `threshold`, so there is no standing
                // cost.
                MotionBlur {
                    source: listCol
                    amount: flightOverlay.blur
                    threshold: 0.02
                    direction: Qt.vector2d(0, 1)
                }
            }

            // The dressing every carved list in this shell wears -- the wheel
            // and the two edge fades, in the one object that owns both.
            // A SIBLING of the Flickable, never a child: a child is reparented
            // into `contentItem` and scrolls away with the list. The Flickable
            // clips to the box's RECTANGLE, so the container's rounded corners
            // are painted back over the content below this.
            ScrollDressing {
                anchors.fill: parent
                flick: listFlick
                scrollSpeed: root.scrollSpeed
                // Frozen with the list while a clone is airborne: the flight
                // scrolls the list itself to bring a destination into view.
                wheelEnabled: !flightOverlay.scrollLocked
                ground: root.listBoxColor
                fadeHeight: root.fadeHeight
            }

            Item {
                anchors.fill: parent
                anchors.margins: -1        // out to the bevel
                clip: true

                Rectangle {
                    id: cornerCap
                    readonly property real capW: root.containerRadius + 1
                    anchors.fill: parent
                    anchors.margins: -cornerCap.capW
                    color: "transparent"
                    radius: root.containerRadius + 1 + cornerCap.capW
                    border.width: cornerCap.capW
                    border.color: root.surfaceColor
                    antialiasing: true
                }
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    radius: root.containerRadius + 1
                    border.width: 1
                    border.color: root.bevelColor
                    antialiasing: true
                }
            }
        }
    }

    // ======================================================================
    // THE FAVOURITE FLIGHT
    //
    // At the SIDEBAR's root, because that is where it is placed and sized --
    // but the clone is DRAWN IN THE POPUP'S OVERLAY LAYER, so its contact
    // shadow is not sliced off at the panel's right edge by the conversation
    // container painted over it.
    // RowFlight measures every leg in the layer's own coordinates, so the
    // two answers below are asked for whatever item it hands them and must
    // not assume it is this one.
    // ======================================================================
    RowFlight {
        id: flightOverlay
        anchors.fill: parent
        exitMs: root.animDuration
        // A favourite toggle always changes the row's GROUP, and a group
        // change must fly even when the pixels barely move: row 0 pinned
        // into a fresh Favorites shelf lands within a pixel of where it
        // took off (the new header replaces the old one above it), and the
        // 4px backstop dropped that flight. 0 disables the pixel backstop;
        // "did it move" is _wantIndexOf's place code alone.
        minTravel: 0
        // Measured here, drawn in the popup's layer: the clone's geometry is
        // this panel's, its pixels are the popup's.
        overlayItem: root.overlayItem
        // The ghost's opaque extent is the row's hover-wash rect and nothing
        // more: the clone's own plate is opaque and wash-sized, so the
        // overlay's backing strip paints nothing, and the contact shadow
        // hugs the plate (rowInset in from the row's edges) instead of the
        // full row width: a backing strip or a full-width shadow would be
        // visibly wider than the wash.
        backingColor: "transparent"
        contentInsetLeft: root.rowInset
        contentInsetRight: root.rowInset
        flick: listFlick
        // The hold ends the frame the travel starts: from here the camera
        // follow owns the scroll, and a hold still correcting the hole under
        // it would fight the leg. Fires in the animation tick, before that
        // frame's positioning pass.
        onRevealChanged: if (flightOverlay.reveal > 0) root._holdHoleY = NaN

        findDest: (id) => root._rowItemFor(id)
        destTopIn: (item, id) => root._flightDestTopIn(item, id)
        indexOf: (id) => root._wantIndexOf(id)
        // The live top of the hole the flying row left -- the phantom's
        // content line. RowFlight samples it every frame before the travel
        // starts, so the clone RIDES the Favorites header materialising
        // above it (the 0-favourites nudge) instead of hovering over pixels
        // its hole has moved away from.
        sourceTopIn: (item, id) => root._holeTopIn(item)
        // The slot is held open by the phantom the merge leaves behind, and
        // the merge only knows to leave one while this is set -- so it is set
        // BEFORE the commit and cleared after the last leg has landed.
        beginGap: (id) => {
            // The slot is the LIVE row until the merge has swapped the
            // phantom in -- _flightMerged is what keeps it at full height
            // across that window (the one-frame un-favourite flicker).
            root._flightMerged = false;
            root._flightKey = id;
        }
        endGap: () => {
            root._flightKey = "";
            root._flightFromGroup = "";
            root._flightMerged = false;
            root._holdHoleY = NaN;
            for (let i = rowModel.count - 1; i >= 0; i--)
                if (rowModel.get(i).isPhantom) rowModel.remove(i);
            // The facts the flight held back -- header counts, and the
            // header of a group it emptied -- settle now, animated.
            root._scheduleRebuild();
        }
        // The model half of the toggle, and only that half: the row moves
        // now, the store is told when the panel has stopped moving (see
        // _persistPin). `_wantRows` reads the pending flag, so the index
        // RowFlight asks for either side of this call already answers with
        // the row in its new group.
        commit: (id) => {
            const idx = root._modelIndexOf(id);
            const e = idx >= 0 ? rowModel.get(idx) : null;
            root._setPendingPin(id, e ? !e.pinned : true);
        }

        cloneComponent: Component {
            // The row's own look, without any of its behaviour: a clone
            // never hovers, renames or asks to be deleted, so it is the row
            // minus three quarters of it rather than the row itself.
            Item {
                id: ghost
                property var flightData: null
                implicitHeight: root._rowH

                Rectangle {
                    x: root.rowInset
                    width: Math.max(0, ghost.width - root.rowInset * 2)
                    height: ghost.implicitHeight
                    radius: 8 * root._s
                    // Lifted off the list, so it wears the tone a row wears
                    // when it is the one being acted on.
                    color: root.headerBoxColor
                }

                Rectangle {
                    x: root.rowInset
                    y: 3 * root._s
                    width: 3 * root._s
                    height: Math.max(0, ghost.implicitHeight - 6 * root._s)
                    radius: width / 2
                    color: root.categoryColor(
                        ghost.flightData ? ghost.flightData.catKey : "")
                    visible: !!ghost.flightData && !!ghost.flightData.active
                }

                // The topic icon rides along: the clone is the row's look,
                // and the row leads with its icon.
                Text {
                    id: ghostIcon
                    x: root.rowInset + 9 * root._s
                    width: 14 * root._s
                    horizontalAlignment: Text.AlignHCenter
                    y: (ghost.implicitHeight - height) / 2
                    text: ghost.flightData ? (ghost.flightData.icon || "") : ""
                    visible: text.length > 0
                    font.family: root.glyphFamily
                    font.pixelSize: root.titleSize * root._s
                    color: root.mutedText
                }

                Text {
                    id: ghostMark
                    x: ghostIcon.visible ? ghostIcon.x + ghostIcon.width + 6 * root._s
                                         : root.rowInset + 9 * root._s
                    y: (ghost.implicitHeight - height) / 2
                    text: ""
                    visible: !!ghost.flightData && !!ghost.flightData.incognito
                    font.family: root.glyphFamily
                    font.pixelSize: root.timeSize * root._s
                    color: root.mutedText
                }

                Text {
                    id: ghostTime
                    x: ghost.width - root.rowInset - 4 * root._s - width
                    y: (ghost.implicitHeight - height) / 2
                    text: ghost.flightData ? ghost.flightData.timeText : ""
                    font.family: root.fontFamily
                    font.pixelSize: root.timeSize * root._s
                    color: root.faintText
                }

                Text {
                    x: ghostMark.visible
                       ? ghostMark.x + ghostMark.implicitWidth + 5 * root._s
                       : ghostMark.x
                    y: (ghost.implicitHeight - height) / 2
                    width: Math.max(0, ghostTime.x - 8 * root._s - x)
                    text: ghost.flightData ? ghost.flightData.title : ""
                    elide: Text.ElideRight
                    maximumLineCount: 1
                    font.family: root.fontFamily
                    font.pixelSize: root.titleSize * root._s
                    color: (!!ghost.flightData && !!ghost.flightData.active)
                           ? root.categoryColor(ghost.flightData.catKey)
                           : root.primaryText
                }
            }
        }
    }
}
