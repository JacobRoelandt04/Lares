pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

import "../../common/theme"
import "../../common/components"
import ".."
import "../../common/components/DragIntent.js" as DI
import "../../common/components/EditKeys.js" as EK
import "RowGeometry.js" as RG

// =============================================================================
// LauncherGrid.qml -- the launcher's rows: a list, or N columns of them.
//
// The order is the service's: the primary grid shows `service.rows` (the
// level being viewed, or a query's ranked hits across every folder); a
// second grid, used only while a folder opens or closes, shows another level
// through `service.levelKeys(folder)`. Rows are laid out ACROSS the columns
// (1 2 / 3 4), so the best hit is always top-left; each row is a whole-pixel
// cell (fractional column widths, each cell's edges rounded on their own).
//
// One highlight: a carved well that GLIDES between rows on one clock
// (`glideT`), moved by the arrows and by the pointer. Enter launches what it
// is on; Shift+Enter launches and keeps the launcher open.
//
// A change of sort makes the rows on screen travel to their new cells
// (`reflowT`, one clock for all of them); a query or a folder is a page of
// its own and is placed. A favourite toggled FLIES (the
// flight is the LLM sidebar's): the shared RowFlight lifts a clone of the
// row, carries it to its new cell -- on both axes in columns -- and the
// other rows make room for it on the flight's own clock (`reveal`); the
// highlight well travels under the clone, so it lands in it. A flight the
// list is re-cut under ends where it stands, and its clone lands in its row.
//
// The pointer: a faint star at the end of a hovered row makes it a
// favourite (a favourite's star takes it off); a link's chain glyph opens the
// file chooser where its real file is. A wheel under a still pointer moves
// the highlight to the row that comes under it; rows moving under
// a still pointer otherwise (a morph, a reflow) are only hovered. All of it is hit by
// arithmetic on RowGeometry's numbers: this grid's one MouseArea is the only
// pointer layer over the rows.
//
// Dragging is the notes grid's, exactly (DragIntent: a folder only by a
// deliberate dwell on a row's centre; the header band of a folder is its
// exit), minus reordering -- there is no custom sort -- and minus nesting:
// a folder is never dragged into anything, and nothing is grouped inside a
// folder. The carried row is a ghost in the overlay; dropped on a folder it
// flies into it, shrinking.
// =============================================================================
Item {
    id: grid

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    property var service: null
    property LauncherTune tune: null
    property Item overlayItem: null
    property color ground: Theme.surface
    property var outline: null
    // The primary grid follows `service.rows`; another shows `folder`'s level.
    property bool primary: true
    property string folder: ""
    property int columns: 1
    // The row a morph is standing in for (drawn by the card instead).
    property string hiddenKey: ""
    // A folder's header band, in this item's coordinates: the drag's exit.
    property var exitRect: null
    // A launch's row has left for the confirm flourish: the list holds still
    // under it (no rebuild, no re-sort, no input) until the popup is gone --
    // the launch's own frecency re-sort lands a moment later and would move the
    // gap the row lifts out of.
    property bool frozen: false
    readonly property bool searching: grid.primary && !!grid.service && grid.service.query !== ""
    // The list is the hidden apps (the service's hidden view): a row there can be unhidden and opened, nothing else.
    readonly property bool hiddenView: grid.primary && !!grid.service && grid.service.hiddenView
    readonly property alias flick: gridFlick

    signal activated(string key, bool keepOpen)
    signal openFolder(string key)
    signal menuRequested(string key, real x, real y)
    signal exitRequested
    signal typed(string text)
    signal backspaced
    // Ctrl+Backspace / Ctrl+W / Ctrl+U on the typed query (EditKeys.js: the action's name).
    signal queryKilled(string action)
    signal escaped
    signal sortStep(int dir)
    // The quick answer (AnswerRow, hosted by the popup above this list): `answerOn` says one is shown, `answerSel` that the
    // highlight is on it (the popup sets it when an answer first lands for a query; the pointer or a key into the hits clears it).
    // Enter on it is `answerActivated`; Down leaves it for the first hit, Up from the first hit comes back.
    property bool answerOn: false
    property bool answerSelRaw: false
    readonly property bool answerSel: grid.primary && grid.answerOn && grid.answerSelRaw
    signal answerActivated(bool keepOpen)
    // The user did something that should keep a hover-opened launcher open.
    signal engaged

    // The layer the favourite flight's clone is drawn in (above the rows, cut
    // to the popup); the overlay when none is given.
    property Item flightLayer: null
    // The favourite flight. Only the primary grid can fly a row, so only it
    // builds one (flightLoader): a morph's parent grid never flies, and every
    // RowFlight builds its lift shadow's MultiEffect layer with itself -- two
    // per popup open, one of them for nothing.
    readonly property RowFlight _flight: flightLoader.item as RowFlight
    // The flight's legs are running: the list is frozen under them.
    readonly property bool _airborne: !!grid._flight && grid._flight.active
    // A favourite in the air, or its clone landing after a cut (the service
    // defers its write until this is false again: LauncherPopup binds its
    // favWriteHold).
    readonly property bool flying: grid._airborne || grid._landKey !== ""
    readonly property string _flightKey: grid._flight ? grid._flight.key : ""
    readonly property real _flightReveal: grid._flight ? grid._flight.reveal : 1

    // ---- Geometry -----------------------------------------------------------------------------------
    readonly property real pad: grid.tune ? grid.tune.padding : 12
    readonly property real rowH: grid.tune ? grid.tune.iconSize + 2 * grid.tune.rowInset : 52
    // Room above the first row and below the last for a carved well's bevel,
    // so the flick's clip never shears it (CLAUDE.md).
    readonly property real slack: 3
    readonly property int cols: Math.max(1, grid.columns)
    readonly property real gap: grid.tune ? grid.tune.columnGap : 12
    readonly property real colWf: grid._geo().colWf

    // The column geometry from the RAW inputs, read fresh on every call: the
    // bindings above can lag inside a change handler (a column switch runs
    // onColumnsChanged and onWidthChanged before `colWf` has caught up), and
    // every row placed there would keep the old width -- the first column at 192 px
    // beside a second at 300 until a scroll rebuilt the rows.
    // Stop a glide or a coast before the host writes the position itself (an open
    // at the top, a folder entered or left): it would stop on its own a frame later.
    function stopScroll() {
        dressing.stopMotion();
    }

    function _geo() {
        const cols = Math.max(1, grid.columns);
        const pad = grid.tune ? grid.tune.padding : 12;
        const gap = grid.tune ? grid.tune.columnGap : 12;
        return {
            cols: cols,
            pad: pad,
            gap: gap,
            colWf: Math.max(40, (grid.width - 2 * pad - (cols - 1) * gap) / cols)
        };
    }

    function cell(i) {
        const g = grid._geo();
        const c = i % g.cols, r = Math.floor(i / g.cols);
        const x0 = Math.round(g.pad + c * (g.colWf + g.gap));
        const x1 = Math.round(g.pad + c * (g.colWf + g.gap) + g.colWf);
        return {
            x: x0,
            y: grid.slack + r * grid.rowH,
            w: x1 - x0,
            h: grid.rowH
        };
    }
    function cellAt(cx, cy, count) {
        const r = Math.floor((cy - grid.slack) / grid.rowH);
        if (r < 0)
            return -1;
        const cols = grid._geo().cols;
        for (let c = 0; c < cols; c++) {
            const i = r * cols + c;
            if (i >= count)
                return -1;
            const b = grid.cell(i);
            if (cx >= b.x && cx < b.x + b.w)
                return i;
        }
        return -1;
    }

    // ---- The order -----------------------------------------------------------------------------------
    property var order: []
    property int layoutSerial: 0
    property real reflowT: 1
    property bool _animateNext: false
    property string _lastQuery: ""
    property string _lastFolder: "\u0001"
    property bool _lastHidden: false
    property int current: 0
    property bool _userMoved: false
    readonly property string currentKey: grid.current >= 0 && grid.current < grid.order.length ? grid.order[grid.current] : ""

    // The primary grid's records are the ROWS' own (a query's match indices
    // live there, not in `entry()`, which is the level's plain record); kept
    // by key, read through each record's `d` so a re-assigned record redraws
    // its row alone.
    property var _recs: ({})
    // A key's facts as its row shows them (the primary grid's record, or the
    // level's plain entry).
    function _factsOf(key) {
        return grid.primary && grid._recs[key] ? grid._recs[key].d : grid.service.entry(key);
    }
    function _keysOfRows() {
        const m = grid.service ? grid.service.rows : null;
        const out = [], recs = {};
        for (let i = 0; m && i < m.count; i++) {
            const r = m.get(i);
            out.push(r.key);
            recs[r.key] = r.rec;
        }
        grid._recs = recs;
        return out;
    }
    function refreshOrder() {
        if (!grid.service || grid.frozen)
            return;
        const next = grid.primary ? grid._keysOfRows() : grid.service.levelKeys(grid.folder);
        // A query or a folder is a page of its own: placed, highlight on top.
        const q = grid.primary ? grid.service.query : "";
        const f = grid.primary ? grid.service.folder : grid.folder;
        const newPage = q !== grid._lastQuery || f !== grid._lastFolder || grid.hiddenView !== grid._lastHidden;
        grid._lastQuery = q;
        grid._lastFolder = f;
        grid._lastHidden = grid.hiddenView;
        if (!newPage && JSON.stringify(next) === JSON.stringify(grid.order))
            return;
        // The list re-cut under a favourite in the air by anything but the
        // flight's own commit (a query typed, a folder opened, a sort, a
        // rescan) ends the flight here, before the new order is laid out,
        // and the row goes with the others (_cutFlight); its clone lands in
        // it once the order is laid out (_planLanding, below). Its leg is
        // planned against the old order, so flown on it would land where the
        // cell HAD been (52 px off its row after a letter, 156 after Tab) and
        // then jump, and the re-sort's rows would go onto the flight's clock
        // mid-travel. The flight's own rebuild arrives inside the commit, or
        // as the serial it awaits. A re-cut while the clone lands re-plans
        // the landing from where the clone is.
        if (grid.flying && !grid._inCommit && grid._awaitSerial < 0)
            grid._cutFlight(newPage);
        const keep = grid.currentKey;
        grid.order = next;
        grid._syncRows();
        // Until the user moves the highlight it stays on the TOP row -- what
        // Enter launches: an open's rescan re-sorts the list a moment after
        // the popup is built (frecency moved), and following the old top
        // row's key would put the highlight on row 2. Once
        // the user has moved it, it follows its row through a re-sort.
        if (newPage || !grid._userMoved) {
            grid.current = 0;
            if (newPage) {
                grid._userMoved = false;
                dressing.stopMotion();
                gridFlick.contentY = 0;
            }
        } else {
            const at = next.indexOf(keep);
            grid.current = at >= 0 ? at : Math.min(grid.current, Math.max(0, next.length - 1));
        }
        grid.relayout(!newPage);
        grid._planLanding();
    }
    Connections {
        target: grid.service
        function onSerialChanged() {
            grid.refreshOrder();
            grid._flightReconcile();
        }
    }
    onFolderChanged: grid.refreshOrder()
    // A switch of columns changes how many rows a screen holds, so the slot
    // window is re-cut before the rows are placed.
    onColumnsChanged: {
        grid._syncWindow();
        grid.relayout(true);
    }
    onWidthChanged: grid.relayout(false)
    Component.onCompleted: grid.refreshOrder()

    ListModel {
        id: rows
    }
    // A slot exists only for the rows within a screen of the view, as a
    // ListView keeps them: 104 slots cost 6 ms of every open, of which some
    // 30 are ever near the screen. The window follows the scroll; a row
    // coming into it is PLACED (only what is on screen animates -- the house
    // list rule), and the carried row of a drag always has its slot.
    // Rows of slots kept above and below the view; -1: one screen.
    property int windowMargin: -1
    onWindowMarginChanged: grid._syncWindow()
    property int _winLo: -1
    property int _winHi: -1
    function _window() {
        const screen = Math.max(1, Math.ceil(gridFlick.height / grid.rowH));
        const margin = grid.windowMargin >= 0 ? grid.windowMargin : screen;
        const top = Math.floor(Math.max(0, gridFlick.contentY - grid.slack) / grid.rowH);
        return {
            lo: Math.max(0, (top - margin) * grid._geo().cols),
            hi: (top + screen + margin + 1) * grid._geo().cols
        };
    }
    function _syncWindow() {
        const w = grid._window();
        if (w.lo !== grid._winLo || w.hi !== grid._winHi)
            grid._syncRows();
    }
    Connections {
        target: gridFlick
        function onContentYChanged() {
            grid._syncWindow();
        }
        function onHeightChanged() {
            grid._syncWindow();
        }
    }
    function _syncRows() {
        const w = grid._window();
        grid._winLo = w.lo;
        grid._winHi = w.hi;
        const want = {};
        const n = grid.order.length;
        for (let i = w.lo; i < Math.min(n, w.hi); i++)
            want[grid.order[i]] = true;
        if (grid.dragKey !== "")
            want[grid.dragKey] = true;
        // The flight's destination, wherever it is: RowFlight measures it
        // off its slot and the camera follows it there.
        if (grid._flightKey !== "")
            want[grid._flightKey] = true;
        // The row a cut flight's clone is landing in: the landing follows it.
        if (grid._landKey !== "")
            want[grid._landKey] = true;
        for (let i = rows.count - 1; i >= 0; i--)
            if (!want[rows.get(i).key])
                rows.remove(i);
        const have = {};
        for (let i = 0; i < rows.count; i++)
            have[rows.get(i).key] = true;
        for (const k in want)
            if (!have[k])
                rows.append({
                    key: k
                });
    }

    // The cell a key is shown in: a drag takes its row out of the order and
    // leaves its gap where it was (no reorder, so nothing moves into it).
    function displayIndexOf(key) {
        if (grid.dragKey !== "" && grid._dragOrder) {
            const pos = grid._dragOrder.indexOf(key);
            if (pos < 0)
                return -1;
            return pos + (pos >= grid._intent.gap ? 1 : 0);
        }
        return grid.order.indexOf(key);
    }
    function _cellOf(key) {
        const i = grid.displayIndexOf(key);
        return i < 0 ? null : grid.cell(i);
    }
    // A key's row on screen, in this item's coordinates (null: not shown).
    function rectOf(key) {
        const r = grid._cellOf(key);
        return r ? {
            x: r.x,
            y: r.y - gridFlick.contentY,
            w: r.w,
            h: r.h
        } : null;
    }
    // Scroll, at once, so that `key`'s row is whole on screen.
    function reveal(key) {
        const r = grid._cellOf(key);
        if (!r)
            return;
        const max = Math.max(0, gridFlick.contentHeight - gridFlick.height);
        // The keyboard outranks a glide or a coast that is still running.
        dressing.stopMotion();
        if (r.y - grid.slack < gridFlick.contentY)
            gridFlick.contentY = Math.max(0, r.y - grid.slack);
        else if (r.y + r.h + grid.slack > gridFlick.contentY + gridFlick.height)
            gridFlick.contentY = Math.min(max, r.y + r.h + grid.slack - gridFlick.height);
    }
    // Scroll, at once, so that `key`'s row is CENTRED in the viewport, clamped to the list's ends (the top of
    // a short list stays at 0, the foot of a long one at its end): where a folder is when it is left (the
    // morph back, the drag's exit, a file just dropped in). Only the scroll: the highlight is the caller's.
    // The one place the centred position is computed; the motion is the dressing's (stopped here, so a
    // glide or a coast that is still running does not carry the list off again).
    function centreRow(key) {
        const r = grid._cellOf(key);
        if (!r)
            return false;
        const max = Math.max(0, gridFlick.contentHeight - gridFlick.height);
        dressing.stopMotion();
        gridFlick.contentY = Math.max(0, Math.min(max, Math.round(r.y + r.h / 2 - gridFlick.height / 2)));
        return true;
    }
    // The drag's auto-scroll is held while centred by an exit (see _stepDrag's
    // pointer handler).
    property bool _autoHeld: false
    // Scroll, at once, so that `key`'s row is CENTRED in the viewport (clamped
    // to the list's ends) and put the highlight on it, with no glide: the
    // list's answer to "this is where it is" -- a folder a drag has just
    // left, a file just dropped in. Not while a flight
    // freezes the list.
    function centreOn(key) {
        const i = grid.order.indexOf(key);
        if (i < 0 || grid._airborne)
            return false;
        grid.centreRow(key);
        grid.current = i;
        grid._userMoved = true;
        grid._retargetWell(0);
        if (grid.dragKey !== "") {
            autoScroll.end();
            grid._autoHeld = true;
        }
        return true;
    }
    function minisOf(key) {
        const e = grid.service ? grid.service.entry(key) : null;
        if (!e || !e.minis)
            return [];
        return e.minis.slice(0, 4).map(k => grid.service.entry(k)).filter(x => x);
    }

    // ---- Faces, built a few per frame at the open --------------------------------------------------
    // Building every visible row's face in the open's first frame freezes
    // it: 18 faces of a handful of items each, on top of the popup's own
    // tree (234 ms, against 34 with only the visible faces built and 8
    // without the rows). So the first frame
    // builds none, and each frame after builds `facesPerFrame` more, top
    // down; the popup is still growing out of its bar for 260 ms, so they
    // land under the reveal. Once the first screenful is in (or after a few
    // frames whatever the count), the budget is lifted for good: a scroll or
    // a query builds what it shows at once.
    // The live slots by key (each registers itself), for relayout's loop.
    property var _slots: ({})
    property int facesPerFrame: 6
    property int faceBudget: 0
    property int _fillFrames: 0
    FrameAnimation {
        running: grid.faceBudget < 1e9
        onTriggered: {
            grid._fillFrames++;
            grid.faceBudget += grid.facesPerFrame;
            const shown = Math.ceil(gridFlick.height / grid.rowH + 1) * grid.cols;
            if (grid.faceBudget >= shown || grid._fillFrames >= 8)
                grid.faceBudget = 1e9;
        }
    }

    // ---- The face pool ---------------------------------------------------------------------------------
    // A face is BUILT once and REUSED: the row leaving the view hands its face
    // to the row coming in, in the same step. Building one per row crossing
    // the view's edge is the scroll's cost (80 % of a scrolled frame's work
    // is faces, and none of it draws anything new). A pooled face is created under `facePark` -- its
    // QObject parent, so it outlives the slots it visits -- and only its
    // VISUAL parent is the slot it serves. It is snapped before it takes a
    // new row, so nothing fades out of the last row's state.
    Item {
        id: facePark
        visible: false
    }
    property var _freeFaces: ({
            app: [],
            folder: []
        })
    // How many faces were ever built (a scroll builds
    // for the screen, not for every row that passes). Written here only.
    property int facesBuilt: 0
    function _takeFace(slot, folder) {
        const pool = grid._freeFaces[folder ? "folder" : "app"];
        const f = pool.pop();
        if (!f) {
            grid.facesBuilt++;
            return (folder ? folderFace : appFace).createObject(facePark, {
                    sl: slot,
                    parent: slot
                });
        }
        f.snap();
        f.parent = slot;
        f.sl = slot;
        f.visible = true;
        return f;
    }
    function _releaseFace(f, folder) {
        // A row being renamed as it leaves the screen takes its editor with
        // it: the rename ends and the list has the keyboard back (the hidden
        // editor kept it, and typing went into a field nobody could see).
        if (f.renaming)
            grid._endRename(true);
        f.visible = false;
        f.parent = facePark;
        grid._freeFaces[folder ? "folder" : "app"].push(f);
    }

    // The faces: a new one is built WITH its slot (`sl`, required: an initial
    // property, set before any binding runs). A face in the pool keeps the
    // `sl` it last served (clearing it would re-evaluate every binding of the
    // face twice per swap), so what the pointer and the keyboard do reaches
    // only the face its slot is SHOWING (`serving`): a pooled face still
    // naming the renamed row began a second editor and took its focus, and
    // one naming the hovered link would open a tip for a glyph nobody sees.
    Component {
        id: appFace
        AppRow {
            id: af
            required property var sl
            readonly property bool serving: !!af.sl && af.sl.face === af
            anchors.fill: parent
            readonly property var slf: af.sl ? af.sl.facts : null
            facts: af.slf
            tune: grid.tune
            overlayItem: grid.overlayItem
            hovered: af.serving && grid.hoveredKey === af.sl.key
            starHovered: af.serving && grid.hoveredStar === af.sl.key
            linkHovered: af.serving && grid.hoveredLink === af.sl.key
            renaming: af.serving && grid.renameKey === af.sl.key
            target: af.serving && af.sl.isTarget
            matchIndices: grid.searching && af.slf ? (af.slf.matchIndices || []) : []
            showFolder: grid.searching
            onRenameCommitted: text => grid._commitRename(af.sl ? af.sl.key : "", text)
            onRenameCancelled: refocus => grid._endRename(refocus)
        }
    }
    Component {
        id: folderFace
        FolderRow {
            id: ff
            required property var sl
            readonly property bool serving: !!ff.sl && ff.sl.face === ff
            anchors.fill: parent
            readonly property var slf: ff.sl ? ff.sl.facts : null
            facts: ff.slf
            minis: ff.sl && grid.layoutSerial >= 0 && grid.service.serial >= 0 ? grid.minisOf(ff.sl.key) : []
            tune: grid.tune
            hovered: ff.serving && grid.hoveredKey === ff.sl.key
            target: ff.serving && ff.sl.isTarget
            matchIndices: grid.searching && ff.slf ? (ff.slf.matchIndices || []) : []
        }
    }

    function relayout(animate) {
        // A drag keeps its row's cell as the gap, so the count never changes.
        gridFlick.contentHeight = 2 * grid.slack + Math.ceil(Math.max(grid.order.length, 1) / grid._geo().cols) * grid.rowH;
        grid._animateNext = animate === true;
        grid.layoutSerial++;
        // A favourite in the air: the rows make room for it on the FLIGHT'S
        // clock, not on a reflow of their own -- 0 until the clone sets off,
        // 1 as it lands, so the hole closes and the new cell opens over the
        // clone's travel (RowFlight: one clock for the travel and the slot).
        const onFlight = grid._animateNext && grid._airborne;
        if (onFlight && !grid._flightClock)
            grid._takeFlightClock();
        // Every slot to its cell: one loop over the slots that registered,
        // not a Connections per slot.
        for (const k in grid._slots)
            grid._slots[k].retarget();
        if (onFlight) {
            grid._retargetWell(-1);
            return;
        }
        if (grid._animateNext)
            reflow.restart();
        grid._retargetWell(grid._animateNext ? (grid.tune ? grid.tune.reflowMs : 220) : 0);
    }
    // The clock the rows move on: a reflow's, or the flight's while a clone
    // is in the air.
    property bool _flightClock: false
    readonly property real moveT: grid._flightClock ? grid._flightReveal : grid.reflowT
    // Hands the rows to the flight's clock WHERE THEY STAND: every slot's
    // origin and target become its present place (whatever a reflow had left
    // of its own travel), so switching the clock moves nothing.
    function _takeFlightClock() {
        grid._holdSlots();
        reflow.stop();
        grid.reflowT = 1;
        grid._flightClock = true;
    }
    // The highlight well likewise: it rides the flight's clock under the
    // clone, and dropping that clock put it at the flight's destination in
    // one frame (a second well beside the clone's plate) before it glided
    // on.
    function _holdWell() {
        const now = grid.wellRect;
        grid._wellFrom = {
            x: now.x,
            y: now.y,
            w: now.w
        };
        grid._wellTo = grid._wellFrom;
        grid._wellOnFlight = false;
        grid._wellRides = false;
        grid.glideT = 1;
    }
    // Every slot's origin and target become its present place: whichever
    // clock drives it next, it moves from where it stands.
    function _holdSlots() {
        for (const k in grid._slots) {
            const sl = grid._slots[k];
            const x = sl.x, y = sl.y;
            sl.fx = x;
            sl.fy = y;
            sl.tx = x;
            sl.ty = y;
        }
    }
    NumberAnimation {
        id: reflow
        target: grid
        property: "reflowT"
        from: 0
        to: 1
        duration: grid.tune ? grid.tune.reflowMs : 220
        easing.type: Easing.OutCubic
    }
    function _onScreen(y, h) {
        return y + h >= gridFlick.contentY - 20 && y <= gridFlick.contentY + gridFlick.height + 20;
    }

    // ---- The highlight well -------------------------------------------------------------------------
    // One clock: the well travels from where it is to the current row's
    // cell; a reflow carries it on the reflow's duration so it stays with
    // its row.
    property var _wellFrom: ({
            x: 0,
            y: 0,
            w: 0
        })
    property var _wellTo: ({
            x: 0,
            y: 0,
            w: 0
        })
    property real glideT: 1
    // Under a flight the well rides the flight's clock with the rows, on
    // whichever row it is (the flown one, it travels under its clone).
    property bool _wellOnFlight: false
    readonly property real _wellT: grid._wellOnFlight ? grid._flightReveal : grid.glideT
    // Under a cut flight's landing clone that carries the highlight (it
    // wears the well's plate), the well RIDES the clone: its rect is the
    // clone's, in the list's coordinates -- the slot plus what is left of
    // the gap -- so it is hidden under the plate, and at landE = 1 it is the
    // row's own place. Placed at the new cell instead, it would be a second well
    // beside the clone's plate for the whole landing (123 px apart after a
    // letter). Set where the landing is planned (_planLanding); it ends with
    // the landing (_endLanding: the glide underneath, started from where the
    // well stood, under the clone, has brought it to the row by then), when
    // the highlight leaves the row (onCurrentChanged) or at a re-cut
    // (_holdWell), which take the well on from where it is drawn.
    property bool _wellRides: false
    readonly property var _rideRect: {
        const L = grid._land;
        const sl = grid._wellRides && L && L.track ? grid._slots[grid._landKey] : null;
        if (!sl)
            return null;
        const k = 1 - grid.landE;
        return {
            x: sl.x + L.dx * k,
            y: sl.y + L.dy * k,
            w: sl.width + L.dw * k
        };
    }
    readonly property var wellRect: grid._rideRect ? grid._rideRect : ({
            x: grid._wellFrom.x + (grid._wellTo.x - grid._wellFrom.x) * grid._wellT,
            y: grid._wellFrom.y + (grid._wellTo.y - grid._wellFrom.y) * grid._wellT,
            w: grid._wellFrom.w + (grid._wellTo.w - grid._wellFrom.w) * grid._wellT
        })
    NumberAnimation {
        id: glide
        target: grid
        property: "glideT"
        from: 0
        to: 1
        easing.type: Easing.OutCubic
    }
    // Reads the key from `order` itself: called from onCurrentChanged, where
    // the `currentKey` binding may not have caught up yet (CLAUDE.md: one
    // cascade, two generations). `ms` < 0: on the flight's clock.
    function _retargetWell(ms) {
        const k = grid.current >= 0 && grid.current < grid.order.length ? grid.order[grid.current] : "";
        const r = k !== "" ? grid._cellOf(k) : null;
        if (!r)
            return;
        const now = grid.wellRect;
        glide.stop();
        const first = grid._wellTo.w === 0;
        grid._wellOnFlight = ms < 0 && !first;
        grid._wellFrom = first || ms === 0 ? {
            x: r.x,
            y: r.y,
            w: r.w
        } : {
            x: now.x,
            y: now.y,
            w: now.w
        };
        grid._wellTo = {
            x: r.x,
            y: r.y,
            w: r.w
        };
        grid.glideT = first || ms <= 0 ? 1 : 0;
        if (!first && ms > 0) {
            glide.duration = ms;
            glide.start();
        }
    }
    onCurrentChanged: {
        grid._retargetWell(grid.tune ? grid.tune.glideMs : 120);
        // The highlight has left the row a landing clone carries it on: the
        // well glides on from under the clone (read above, while it rode).
        if (grid._wellRides && grid.order[grid.current] !== grid._landKey)
            grid._wellRides = false;
    }

    // Moves the highlight by `d` cells (keyboard), keeping it on screen. Not
    // while a favourite is in the air: the list is frozen under a flight for
    // the keyboard as for the wheel -- a reveal() mid-flight would scroll the list
    // under a leg planned against the old scroll, and the clone would land where
    // its cell had been -- and the well is riding the flight's clock.
    function step(d) {
        if (grid.order.length === 0 || grid._airborne)
            return;
        grid.current = Math.max(0, Math.min(grid.order.length - 1, grid.current + d));
        grid._userMoved = true;
        grid.reveal(grid.currentKey);
        grid.engaged();
    }
    // ---- The confirm ---------------------------------------------------------------------------------
    // Shift+Enter launches and stays: no flourish, a pulse of the row (1 ->
    // confirmPulseScale -> 1 over confirmPulseMs, one clock), its well with it.
    property string pulseKey: ""
    property real pulseT: 1
    readonly property real pulseScaleNow: 1 + ((grid.tune ? grid.tune.confirmPulseScale : 1.03) - 1) * Math.sin(Math.PI * grid.pulseT)
    NumberAnimation {
        id: pulseAnim
        target: grid
        property: "pulseT"
        from: 0
        to: 1
        duration: grid.tune ? grid.tune.confirmPulseMs : 160
        onFinished: grid.pulseKey = ""
    }
    function pulse(key) {
        grid.pulseKey = key;
        pulseAnim.restart();
    }
    // What the confirm flourish carries off: the row as it is drawn now --
    // where its slot stands (this item's coordinates: a row still gliding to
    // its cell is taken where it is), the list's viewport and how far its
    // edge fades are on (the row may lie under one, or past the clip), its
    // record (a query's marks included), where its name and icon sit, the
    // well if it is on the row, the star's fractions as the face has them.
    // null when the row cannot be carried (not on screen, a favourite in the
    // air, a drag in the way).
    function flourishCapture(key) {
        const sl = grid._slots[key];
        const r = grid.rectOf(key);
        const fc = sl ? sl.face as AppRow : null;
        if (!sl || !r || !sl.visible || !fc || !fc.nameItem || grid.flying || grid.dragKey !== "")
            return null;
        const facts = grid._factsOf(key);
        const cell = grid._cellOf(key);
        const wr = grid.wellRect;
        return {
            key: key,
            item: grid,
            rect: {
                x: sl.x - gridFlick.contentX + gridFlick.x,
                y: sl.y - gridFlick.contentY + gridFlick.y,
                w: r.w,
                h: r.h
            },
            view: {
                x: gridFlick.x,
                y: gridFlick.y,
                w: gridFlick.width,
                h: gridFlick.height
            },
            fade: {
                head: dressing._headF,
                foot: dressing._footF,
                h: dressing.fadeHeight
            },
            facts: facts,
            matchIndices: grid.searching && facts ? (facts.matchIndices || []) : [],
            showFolder: grid.searching,
            well: grid.currentKey === key && !!cell && Math.abs(wr.y - cell.y) < 1 && Math.abs(wr.x - cell.x) < 1,
            star: {
                favF: fc.favF,
                hoverStarF: fc.hoverStarF,
                starHoverF: fc.starHoverF
            },
            link: fc.isLink,
            linkHovered: grid.hoveredLink === key,
            name: {
                x: fc.nameItem.x,
                y: fc.nameItem.y,
                w: fc.nameItem.width,
                h: fc.nameItem.height,
                natural: fc.nameItem.implicitWidth
            },
            icon: {
                x: fc.iconItem.x,
                y: fc.iconItem.y
            }
        };
    }
    // A launch is about to carry a row off: a cut flight's clone still
    // landing is put down now (it has landed all the same, as a new toggle
    // ends it), with the highlight where it is, so the row stands in its cell
    // for the capture. A favourite still in the AIR is not: its rows are on
    // the flight's clock, and the launch closes the popup plainly.
    function settleForLaunch() {
        if (grid._landKey !== "" && !grid._airborne)
            grid._endLanding(true);
    }
    function activateCurrent(keepOpen) {
        const k = grid.currentKey;
        if (k === "")
            return;
        const e = grid.service.entry(k);
        if (e && e.kind === "folder")
            grid.openFolder(k);
        else
            grid.activated(k, keepOpen);
    }

    // ---- The rows ------------------------------------------------------------------------------------
    Flickable {
        id: gridFlick
        anchors.fill: parent
        interactive: false
        clip: true
        contentWidth: width
        boundsBehavior: Flickable.StopAtBounds

        // The well and the rows in one item, so the list can be smeared as a
        // whole while a flight scrolls it (the LLM sidebar's MotionBlur).
        Item {
            id: rowsLayer
            width: gridFlick.width
            height: gridFlick.contentHeight

            ShadowBox {
                id: well
                objectName: "highlightWell"
                visible: grid.currentKey !== "" && grid.dragKey === "" && grid.currentKey !== grid.hiddenKey && !grid.answerSel
                x: Math.round(grid.wellRect.x)
                y: Math.round(grid.wellRect.y)
                width: Math.round(grid.wellRect.w)
                height: grid.rowH
                baseWidth: well.width
                baseHeight: well.height
                baseRadius: grid.tune ? grid.tune.wellRadius : 10
                surfaceColor: "transparent"
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                backgroundColor: Theme.panelSunk
                bevelWidth: 1
                shadowWidth: 3
                scale: grid.pulseKey !== "" && grid.currentKey === grid.pulseKey ? grid.pulseScaleNow : 1
            }

            Repeater {
                model: rows
                delegate: Item {
                    id: slot
                    required property string key
                    readonly property int di: grid.layoutSerial >= 0 ? grid.displayIndexOf(slot.key) : -1
                    readonly property bool shown: slot.di >= 0 && slot.key !== grid.dragKey
                    property real fx: 0
                    property real fy: 0
                    property real tx: 0
                    property real ty: 0
                    property int tw: 0
                    property bool placed: false
                    // Only once PLACED: a slot is born at y = 0, where every one of
                    // them is "on screen", and the face Loader below would then build
                    // all 104 faces and tear 86 of them down again on every open
                    // (234 ms warm, 14 ms without the faces).
                    visible: slot.placed && slot.shown && grid._onScreen(slot.y, slot.height)
                    // A morph's row is drawn by its card, a flying one by the
                    // flight's clone, a landing one by the landing: exactly one
                    // copy on screen.
                    opacity: slot.key === grid.hiddenKey || slot.key === grid._flightKey || slot.key === grid._landKey ? 0 : 1
                    x: slot.fx + (slot.tx - slot.fx) * grid.moveT
                    y: slot.fy + (slot.ty - slot.fy) * grid.moveT
                    width: slot.tw
                    height: grid.rowH
                    // RowFlight reads the height of the row it lifts off.
                    implicitHeight: grid.rowH
                    // Shift+Enter's confirm pulse (the launcher stays open).
                    scale: slot.key === grid.pulseKey ? grid.pulseScaleNow : 1

                    function retarget() {
                        if (slot.di < 0) {
                            slot.placed = false;
                            return;
                        }
                        const r = grid.cell(slot.di);
                        const from = {
                            x: slot.x,
                            y: slot.y
                        };
                        slot.tx = r.x;
                        slot.ty = r.y;
                        slot.tw = r.w;
                        // The flying row is hidden and already where it lands: its
                        // clone does the travelling (and RowFlight measures the
                        // destination off this slot).
                        let travel = slot.placed && grid._animateNext && slot.key !== grid._flightKey && (grid._onScreen(from.y, r.h) || grid._onScreen(r.y, r.h));
                        const st = grid._settle;
                        if (st && st.key === slot.key) {
                            from.x = st.x;
                            from.y = st.y;
                            travel = true;
                            grid._settle = null;
                        }
                        slot.fx = travel ? from.x : r.x;
                        slot.fy = travel ? from.y : r.y;
                        slot.placed = true;
                    }
                    Component.onCompleted: {
                        grid._slots[slot.key] = slot;
                        slot.retarget();
                        slot.syncFace();
                    }
                    Component.onDestruction: {
                        if (grid._slots[slot.key] === slot)
                            delete grid._slots[slot.key];
                        if (slot.face)
                            grid._releaseFace(slot.face, slot._faceFolder);
                    }

                    // Facts, read fresh when the service changes: a plain object.
                    readonly property var facts: grid.service && grid.service.serial >= 0 ? grid._factsOf(slot.key) : null
                    readonly property bool isTarget: grid._intentSerial >= 0 && grid._intent !== null && grid._intent.intent === "group" && grid._intent.target === slot.key

                    // The face: only for a row on screen, and at the open only
                    // within the frame's budget (`faceBudget`, below), taken from
                    // the pool (above). A new one is built WITH its slot as an
                    // initial property: a Loader that builds it empty and hands it the
                    // slot in onLoaded runs every binding of the face twice (and
                    // decodes each icon for a state it never draws).
                    readonly property bool wantFace: slot.visible && slot.di < grid.faceBudget
                    readonly property bool isFolder: !!slot.facts && slot.facts.kind === "folder"
                    property Item face: null
                    property bool _faceFolder: false
                    function syncFace() {
                        if (slot.face && (!slot.wantFace || slot._faceFolder !== slot.isFolder)) {
                            grid._releaseFace(slot.face, slot._faceFolder);
                            slot.face = null;
                        }
                        if (slot.wantFace && !slot.face) {
                            slot._faceFolder = slot.isFolder;
                            slot.face = grid._takeFace(slot, slot.isFolder);
                        }
                    }
                    onWantFaceChanged: slot.syncFace()
                    onIsFolderChanged: slot.syncFace()
                }
            }
        }

        // Smears the list while a flight scrolls it to a destination off the
        // screen; bypassed at rest (below its threshold nothing is captured).
        MotionBlur {
            source: grid.primary ? rowsLayer : null
            amount: grid._flight ? grid._flight.blur : 0
            threshold: 0.02
            direction: Qt.vector2d(0, 1)
        }
    }

    ScrollDressing {
        id: dressing
        objectName: "launcherScrollDressing"     // the popup probe feeds it touchpad events
        anchors.fill: gridFlick
        flick: gridFlick
        fadeHeight: 24
        ground: grid.ground
        outline: grid.outline
        // Frozen while a clone is in the air: the flight scrolls the list
        // itself when its destination is off the screen.
        wheelEnabled: !grid._flight || !grid._flight.scrollLocked
    }
    // A wheel under a still pointer: the highlight goes to the row that comes
    // under it. The keyboard's reveal() scrolls without a wheel, so
    // the two never fight. A notch GLIDES and a lift COASTS (the shell's
    // KineticScroll), so the list keeps moving under the pointer after the
    // event: the highlight follows the movement, frame by frame, for as long
    // as the wheel's own motion runs -- not only the event that started it.
    // Every programmatic scroll (reveal, centreOn, a new page) stops that
    // motion first, so it never reads as the wheel's.
    Connections {
        target: dressing
        function onWheeled() {
            grid._followPointer();
        }
    }
    Connections {
        target: gridFlick
        function onContentYChanged() {
            if (dressing.moving)
                grid._followPointer();
        }
    }

    SelectionAutoScroll {
        id: autoScroll
        flickable: gridFlick
    }
    function autoScrollReapply() {
    }

    // ---- Pointer -------------------------------------------------------------------------------------
    property string hoveredKey: ""
    property string dragKey: ""
    property var _dragOrder: null
    property var _intent: null
    property var _press: null
    property string _dragFrom: ""
    property real _grabDX: 0
    property real _grabDY: 0
    property var _pointer: ({
            x: 0,
            y: 0
        })
    property var _ghostFacts: null
    property int _intentSerial: 0
    // The pointer's last place on the screen (onPositionChanged).
    property var _pointerScene: ({
            x: -1e6,
            y: -1e6
        })

    // Whether a point (content coordinates) is on `key`'s star or on its
    // chain glyph: the row draws them at its right end (AppRow), and this
    // one pointer layer hit-tests them by the same numbers (RowGeometry), as
    // the notes grid does its link glyph. Every app row has a star to click
    // (a favourite's shows, any other's shows faint on hover); a folder has
    // none, and only a link has the glyph.
    property string hoveredStar: ""
    property string hoveredLink: ""
    function _onStar(key, cx, cy) {
        const e = grid.service ? grid.service.entry(key) : null;
        const r = grid._cellOf(key);
        if (!e || e.kind === "folder" || !r || grid.hiddenView)
            return false;
        return RG.onStar(cx - r.x, r.w, grid.tune) && cy >= r.y && cy < r.y + r.h;
    }
    function _onLink(key, cx, cy) {
        const e = grid.service ? grid.service.entry(key) : null;
        const r = grid._cellOf(key);
        if (!e || !e.isLink || !r)
            return false;
        return RG.onLink(cx - r.x, r.w, grid.tune) && cy >= r.y && cy < r.y + r.h;
    }
    // The pointer is on (cx, cy), content coordinates: the row there is the
    // hovered one, and takes the highlight unless `keepHighlight`.
    function _hoverAt(cx, cy, keepHighlight) {
        const k = grid.keyAt(cx, cy);
        grid.hoveredKey = k || "";
        grid.hoveredStar = k && grid._onStar(k, cx, cy) ? k : "";
        grid.hoveredLink = k && grid._onLink(k, cx, cy) ? k : "";
        if (k && !keepHighlight) {
            grid.answerSelRaw = false;
            const i = grid.order.indexOf(k);
            if (i >= 0 && i !== grid.current) {
                grid.current = i;
                grid._userMoved = true;
            }
        }
    }
    // The list moved under a pointer that did not (a wheel, a flight's
    // landing): hover what is under it now, and give it the highlight unless
    // `keepHighlight` (a flight the keyboard sent keeps it on the row it
    // flew). Not while a button is down or something is carried or in the
    // air (a landing clone follows its row, so the list is live under it).
    function _followPointer(keepHighlight) {
        if (!mouse.containsMouse || grid._press || grid.dragKey !== "" || grid._airborne)
            return;
        const c = mouse.mapToItem(gridFlick.contentItem, mouse.mouseX, mouse.mouseY);
        grid._hoverAt(c.x, c.y, keepHighlight);
    }

    function keyAt(cx, cy) {
        const list = grid.dragKey !== "" ? grid._dragOrder : grid.order;
        const n = list ? list.length + (grid.dragKey !== "" ? 1 : 0) : 0;
        const i = grid.cellAt(cx, cy, n);
        if (i < 0 || !list)
            return null;
        for (const k of list)
            if (grid.displayIndexOf(k) === i)
                return k;
        return null;
    }

    MouseArea {
        id: mouse
        anchors.fill: gridFlick
        enabled: !grid.frozen
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: grid.renameKey !== "" && grid.hoveredKey === grid.renameKey ? Qt.IBeamCursor : grid.hoveredKey !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
        onPositionChanged: m => {
            const c = mouse.mapToItem(gridFlick.contentItem, m.x, m.y);
            // Where the pointer is on the screen: an event that finds it where
            // the last one did is Qt's hover for the rows that moved under it.
            // So is the FIRST this list hears (nothing seen before it): the
            // launcher opening under a resting pointer brings Qt's hover and
            // no move, and handing it the highlight made Enter launch the row
            // under the hand instead of the top one. A hand that really moves
            // in sends more than one event; the next one moves the highlight.
            const w = mouse.mapToItem(null, m.x, m.y);
            const first = grid._pointerScene.x < -1e5;
            const still = first || (Math.abs(w.x - grid._pointerScene.x) < 0.5 && Math.abs(w.y - grid._pointerScene.y) < 0.5);
            grid._pointerScene = {
                x: w.x,
                y: w.y
            };
            if (!grid._press) {
                // The pointer moving over a row moves the highlight to it (a
                // list scrolling under a still pointer: _followPointer). Not
                // under a flight: the order is already the new one while the
                // rows still stand where they were -- the landing hovers
                // whatever is under the pointer then. And only the POINTER
                // moving does: rows moving under a hand at rest (a folder's
                // morph after Enter, the popup growing under it, a reflow)
                // bring Qt's synthetic hover, which hovers them and leaves the
                // highlight where the keyboard put it -- the morph's last
                // frame handed it to the row under the hand (backlog b).
                if (!grid._airborne)
                    grid._hoverAt(c.x, c.y, still);
                return;
            }
            if (grid.dragKey === "") {
                const d = Math.hypot(m.x - grid._press.x, m.y - grid._press.y);
                if (d >= 6 && grid._press.key && !grid.searching && !grid.hiddenView)
                    grid._beginDrag(grid._press.key, grid._press.cx, grid._press.cy);
            }
            if (grid.dragKey !== "") {
                grid._pointer = {
                    x: c.x,
                    y: c.y
                };
                const sy = mouse.mapToItem(null, m.x, m.y).y;
                // Centred by an exit out of a folder, the list must not creep
                // off it while the hand is still up in the header band
                // (past the top edge, the auto-scroll's way to the top): it
                // is live again once the pointer is back over the list.
                if (grid._autoHeld && sy >= gridFlick.mapToItem(null, 0, 0).y) {
                    grid._autoHeld = false;
                    autoScroll.begin(grid);
                }
                if (!grid._autoHeld)
                    autoScroll.at(sy);
            }
        }
        onExited: {
            grid.hoveredKey = "";
            grid.hoveredStar = "";
            grid.hoveredLink = "";
        }
        onPressed: m => {
            const c = mouse.mapToItem(gridFlick.contentItem, m.x, m.y);
            const k = grid.keyAt(c.x, c.y);
            // The row being renamed takes its own presses: its editor lies
            // under this layer (a caret placed, a word selected).
            if (grid.renameKey !== "" && k === grid.renameKey && m.button === Qt.LeftButton) {
                m.accepted = false;
                return;
            }
            grid.forceActiveFocus();
            // Nothing is picked out of a list whose rows are in the air.
            if (grid._airborne)
                return;
            if (m.button === Qt.RightButton) {
                if (k) {
                    grid.current = grid.order.indexOf(k);
                    const o = mouse.mapToItem(grid.overlayItem || grid, m.x, m.y);
                    grid.menuRequested(k, o.x, o.y);
                }
                return;
            }
            grid._press = {
                x: m.x,
                y: m.y,
                key: k,
                cx: c.x,
                cy: c.y,
                shift: (m.modifiers & Qt.ShiftModifier) !== 0
            };
        }
        onReleased: m => {
            const p = grid._press;
            grid._press = null;
            if (grid.dragKey !== "") {
                grid._drop();
                return;
            }
            if (!p || m.button !== Qt.LeftButton || !p.key)
                return;
            // Nothing is dragged in the hidden view, and a hand that moved was not clicking: unhiding is not an accident.
            if (grid.hiddenView && Math.hypot(m.x - p.x, m.y - p.y) >= 6)
                return;
            // The star: the favourite on or off, not a launch.
            if (grid._onStar(p.key, p.cx, p.cy)) {
                grid.toggleFavourite(p.key, true);
                grid.engaged();
                return;
            }
            // The chain glyph: the file chooser where the link's real file
            // is; what is picked there is linked in here.
            if (grid._onLink(p.key, p.cx, p.cy)) {
                grid.service.showInFileManager(p.key, true);
                grid.engaged();
                return;
            }
            const e = grid.service.entry(p.key);
            if (e && e.kind === "folder")
                grid.openFolder(p.key);
            else if (e)
                grid.activated(p.key, p.shift);
        }
        onCanceled: {
            grid._press = null;
            if (grid.dragKey !== "")
                grid._endDrag();
        }
    }

    function _beginDrag(key, cx, cy) {
        const e = grid.service.entry(key);
        if (!e)
            return;
        const c = grid.cell(grid.displayIndexOf(key));
        grid._grabDX = cx - c.x;
        grid._grabDY = cy - c.y;
        grid._ghostFacts = e;
        grid._dragFrom = grid.primary ? grid.service.folder : grid.folder;
        grid._dragOrder = grid.order.filter(k => k !== key);
        grid._intent = DI.create(grid.order.indexOf(key));
        grid._pointer = {
            x: cx,
            y: cy
        };
        grid.dragKey = key;
        autoScroll.begin(grid);
        grid.engaged();
        grid.relayout(true);
    }

    // What the carried row may be grouped with: nothing when it is a folder
    // (no nesting) or when this level is a folder already; otherwise any
    // row but itself. DragIntent's `descendants` is its "never onto" set.
    function _noGroup() {
        const all = {};
        const inFolder = (grid.primary ? grid.service.folder : grid.folder) !== "";
        if ((grid._ghostFacts && grid._ghostFacts.kind === "folder") || inFolder)
            for (const k of grid._dragOrder)
                all[k] = 1;
        return all;
    }

    function _targetCells() {
        const out = [];
        for (let pos = 0; pos < grid._dragOrder.length; pos++) {
            const k = grid._dragOrder[pos];
            const r = grid.cell(pos + (pos >= grid._intent.gap ? 1 : 0));
            out.push({
                key: k,
                pos: pos,
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h
            });
        }
        return out;
    }

    FrameAnimation {
        running: grid.dragKey !== ""
        onTriggered: grid._stepDrag()
    }
    function _stepDrag() {
        if (grid.dragKey === "" || !grid._intent)
            return;
        const intentBefore = grid._intent.intent + grid._intent.target;
        const exits = [];
        if (grid.exitRect)
            exits.push({
                x: grid.exitRect.x,
                y: grid.exitRect.y + gridFlick.contentY,
                w: grid.exitRect.w,
                h: grid.exitRect.h
            });
        DI.step(grid._intent, grid._pointer, grid._targetCells(), {
            now: Date.now(),
            customSort: false,
            dragged: {
                key: grid.dragKey,
                isGroup: !!(grid._ghostFacts && grid._ghostFacts.kind === "folder"),
                descendants: grid._noGroup()
            },
            exitRects: exits
        });
        if (grid._intent.intent + grid._intent.target !== intentBefore) {
            grid._intentSerial++;
            if (grid._intent.intent === "exit")
                grid.exitRequested();
        }
    }
    // After an exit the host has switched the level: the drag goes on here.
    function continueDrag() {
        if (grid.dragKey === "")
            return;
        grid._dragOrder = grid.order.filter(k => k !== grid.dragKey);
        grid._intent = DI.create(grid._dragOrder.length);
        grid.relayout(false);
    }

    function _drop() {
        const it = grid._intent;
        const key = grid.dragKey;
        const levelNow = grid.primary ? grid.service.folder : grid.folder;
        const gc = ghost.mapToItem(gridFlick.contentItem, ghost.width / 2, ghost.height / 2);
        const here = {
            key: key,
            x: gc.x - ghost.width / 2,
            y: gc.y - grid.rowH / 2
        };
        let grouped = false;
        if (it.intent === "group" && it.target) {
            const tc = grid._cellOf(it.target);
            if (tc)
                grid._flyInto(tc);
            const t = grid.service.entry(it.target);
            if (t && t.kind === "folder")
                grid.service.moveInto(key, it.target, null);
            else
                grid.service.makeFolder(it.target, key, null);
            grouped = true;
        } else if (levelNow !== grid._dragFrom && levelNow === "") {
            // Carried out of a folder through its header band: back to the root.
            grid.service.moveOut(key, null);
        }
        if (!grouped)
            grid._settle = here;
        grid._endDrag();
        settleExpiry.restart();
    }
    property var _settle: null
    Timer {
        id: settleExpiry
        interval: 600
        onTriggered: grid._settle = null
    }

    // The carried row going into a folder: to the target's centre, shrinking
    // to a mini and fading, on one fraction (the notes grid's fly).
    property var _fly: null
    property real flyT: 0
    NumberAnimation {
        id: flyAnim
        target: grid
        property: "flyT"
        from: 0
        to: 1
        duration: 220
        easing.type: Easing.OutCubic
        onFinished: {
            grid._fly = null;
            grid._ghostFacts = null;
        }
    }
    // The ghost shrinks about its left edge's middle, so landing it on the
    // target cell's origin puts it into the folder's well.
    function _flyInto(c) {
        const to = gridFlick.contentItem.mapToItem(ghost.parent, c.x, c.y);
        grid._fly = {
            x0: ghost.x,
            y0: ghost.y,
            x1: to.x,
            y1: to.y,
            s0: ghost.scale
        };
        grid.flyT = 0;
        flyAnim.restart();
    }
    function _endDrag() {
        autoScroll.end();
        grid._autoHeld = false;
        grid.dragKey = "";
        grid._dragOrder = null;
        grid._intent = null;
        if (!grid._fly)
            grid._ghostFacts = null;
        grid.refreshOrder();
        grid.relayout(true);
    }

    // The ghost: the carried row, drawn in the overlay above everything.
    Loader {
        id: ghost
        objectName: "dragGhost"
        parent: grid.overlayItem || grid
        z: 500
        active: (grid.dragKey !== "" || grid._fly !== null) && grid._ghostFacts !== null
        readonly property point at: grid.dragKey !== "" ? gridFlick.contentItem.mapToItem(ghost.parent, grid._pointer.x - grid._grabDX, grid._pointer.y - grid._grabDY) : Qt.point(0, 0)
        readonly property var fly: grid._fly
        x: ghost.fly ? ghost.fly.x0 + (ghost.fly.x1 - ghost.fly.x0) * grid.flyT : ghost.at.x
        y: ghost.fly ? ghost.fly.y0 + (ghost.fly.y1 - ghost.fly.y0) * grid.flyT : ghost.at.y
        width: Math.round(grid.colWf)
        height: grid.rowH
        transformOrigin: Item.Left
        property real shrink: grid._intentSerial >= 0 && grid._intent && grid._intent.intent === "group" ? 1 : 0
        Behavior on shrink {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }
        property real liftF: 0
        onActiveChanged: {
            if (ghost.active && !grid._fly) {
                ghost.liftF = 0;
                liftAnim.restart();
            }
        }
        NumberAnimation {
            id: liftAnim
            target: ghost
            property: "liftF"
            to: 1
            duration: 140
            easing.type: Easing.OutCubic
        }
        scale: ghost.fly ? ghost.fly.s0 + (0.35 - ghost.fly.s0) * grid.flyT : 1 + 0.04 * ghost.liftF - 0.12 * ghost.shrink
        opacity: ghost.fly ? 1 - grid.flyT : 1
        sourceComponent: grid._ghostFacts && grid._ghostFacts.kind === "folder" ? ghostFolder : ghostApp
        Component {
            id: ghostApp
            Item {
                // The carried row stands proud: a raised plate under it.
                ShadowBox {
                    anchors.fill: parent
                    baseWidth: width
                    baseHeight: height
                    baseRadius: grid.tune ? grid.tune.wellRadius : 10
                    raised: true
                    shadowToAlpha: true
                    surfaceColor: Theme.surface
                    bevelColor: Theme.buttonBevel
                    shadowColor: Theme.buttonShadow
                    backgroundColor: Theme.buttonPlateau
                    bevelWidth: 1.5
                    shadowWidth: 3 + 2 * ghost.liftF
                }
                AppRow {
                    anchors.fill: parent
                    facts: grid._ghostFacts
                    tune: grid.tune
                }
            }
        }
        Component {
            id: ghostFolder
            Item {
                ShadowBox {
                    anchors.fill: parent
                    baseWidth: width
                    baseHeight: height
                    baseRadius: grid.tune ? grid.tune.wellRadius : 10
                    raised: true
                    shadowToAlpha: true
                    surfaceColor: Theme.surface
                    bevelColor: Theme.buttonBevel
                    shadowColor: Theme.buttonShadow
                    backgroundColor: Theme.buttonPlateau
                    bevelWidth: 1.5
                    shadowWidth: 3 + 2 * ghost.liftF
                }
                FolderRow {
                    anchors.fill: parent
                    facts: grid._ghostFacts
                    minis: grid._ghostFacts ? grid.minisOf(grid._ghostFacts.key) : []
                    tune: grid.tune
                }
            }
        }
    }

    // ---- The favourite flight ------------------------------------------------------------------------
    // The LLM sidebar's flight, on the shared RowFlight: the
    // clone lifts off the row, rides the hole it leaves until it sets off,
    // travels to its new cell on both axes (two columns) while the rows make
    // room on the same clock, and lands in the highlight well that travelled
    // under it. `minTravel` 0: whether the row moved is the ORDER's answer,
    // never a pixel threshold. The list's own wheel is frozen meanwhile, and
    // the favourites file is written once it is all at rest (the service
    // holds the write while `flying`). The star appears (or goes) in mid-air:
    // the clone's copy flips as the travel starts.
    //
    // The service rebuilds its order a moment after the toggle (a callLater)
    // or at once; `indexOf` says "not known yet" (-1) until it has, and the
    // answer then either sends the flight on its way (reconciled) or, when the
    // row kept its cell (Name sort), ends it before anything lifted.
    property int _flightFrom: -1
    property int _awaitSerial: -1
    property bool _inCommit: false
    // The clone has set off: it shows the row it is becoming.
    property bool _starFlipped: false
    // The star was clicked: the landing gives the highlight to the row under
    // the pointer then.
    property bool _flightByPointer: false

    // A row's favourite on or off, flown when it can be: the row on screen,
    // nothing carried, no flight already in the air (a list frozen under a
    // flight takes no second one; it lasts under a second). A cut flight's
    // clone still landing is not in the air: its list is live again, the
    // pointer and the keyboard with it, so the landing ends at once and the
    // new toggle flies (returning on `flying` dropped a star click, Ctrl+F or
    // the menu's toggle made in those 160 ms without a word). `byPointer`: its
    // star was clicked. A toggle from the keyboard or the menu keeps the
    // highlight on the row it flew, whatever lies under a resting pointer
    // when it lands (the landing hovers that row, and no more).
    function toggleFavourite(key, byPointer) {
        const e = grid.service ? grid.service.entry(key) : null;
        if (!e || e.kind === "folder" || grid._airborne)
            return;
        // A toggle from the keyboard or the menu ends the landing with the
        // highlight where it is: handed to the row under a resting pointer
        // (a star-clicked landing's rule), Ctrl+F flew one row with the
        // highlight on another.
        if (grid._landKey !== "")
            grid._endLanding(byPointer !== true);
        const slot = grid._slots[key];
        if (!grid._flight || !slot || !slot.visible || grid.dragKey !== "") {
            grid.service.toggleFavorite(key);
            return;
        }
        // `highlighted`: the well is on the row that flies (FlightClone then
        // carries its plate); a star clicked under a still pointer after the
        // keyboard moved the highlight flies a row the well is not on.
        const data = {
            facts: slot.facts,
            hovered: grid.hoveredKey === key,
            starHovered: grid.hoveredStar === key,
            highlighted: grid.currentKey === key
        };
        grid._flightByPointer = byPointer === true;
        // The row under the pointer is now the clone; the landing hovers
        // whatever is under the pointer then.
        grid.hoveredKey = "";
        grid.hoveredStar = "";
        grid.hoveredLink = "";
        grid._starFlipped = false;
        grid._cloneWanted = true;
        // The clone takes the row's look at once, as a face from the pool
        // takes its row's (AppRow.snap), never easing out of the last one.
        const clone = grid._flight.cloneItem as FlightClone;
        if (clone)
            clone.snap();
        grid._flight.begin(key, slot, data);
    }
    // The list re-cut under the flight (refreshOrder) ends it where
    // everything stands: before the flight lets go of its clock, every slot
    // is held at the place it has reached (the rows making room stop part
    // way, they do not snap to their ends) and so is the highlight well
    // (where it is drawn: on the flight's clock, or riding a landing clone),
    // and the relayout that follows moves each of them on from there. On a
    // re-sort the flown row sets off for its new cell from where its clone
    // was, as a dropped row does (`_settle`); a new page is placed, the flown
    // row with it. The clone is not dropped with the flight: it is put down
    // (_putDown) and lands in its row (_planLanding) while the row stays
    // hidden under it. A re-cut while it lands does the same from where the
    // landing has brought it.
    function _cutFlight(newPage) {
        const at = grid._cloneAt();
        // Read while the plan it may ride on is still the old one.
        grid._holdWell();
        if (!newPage && at) {
            const c = landLayer.mapToItem(gridFlick.contentItem, at.x + at.w / 2, at.y + at.h / 2);
            grid._settle = {
                key: grid._airborne ? grid._flightKey : grid._landKey,
                x: c.x - at.w / 2,
                y: c.y - grid.rowH / 2
            };
            settleExpiry.restart();
        }
        grid._putDown(at, newPage);
        grid._holdSlots();
        if (grid._airborne)
            grid._flight.cancel();
    }
    function _flightReconcile() {
        if (grid._awaitSerial < 0 || grid._inCommit || !grid._airborne || grid.service.serial === grid._awaitSerial)
            return;
        grid._awaitSerial = -1;
        if (grid.order.indexOf(grid._flightKey) === grid._flightFrom)
            grid._flight.cancel();
        else
            grid._flight.reconciled();
    }

    Loader {
        id: flightLoader
        anchors.fill: parent
        active: grid.primary
        sourceComponent: flightComp
    }
    Component {
        id: flightComp
        RowFlight {
            id: flight
            objectName: "favouriteFlight"
            overlayItem: grid.flightLayer || grid.overlayItem
            // Qualified: inside the Component an unqualified `flick` is the
            // RowFlight's own property.
            flick: grid.flick
            minTravel: 0
            travelX: true
            // The clone paints its own opaque plate (the well's, or the
            // ground's for a row the well is not on), so the flight backs it
            // with nothing; its contact shadow hugs the plate a row
            // inset in (the LLM sidebar's numbers), and takes the small reach
            // RowFlight gives a host whose rows sit a 12 px padding from the
            // popup's edge (the notifications manager's pair).
            backingColor: "transparent"
            contentInsetLeft: grid.tune ? grid.tune.rowInset : 6
            contentInsetRight: grid.tune ? grid.tune.rowInset : 6
            liftShadowSpread: 6
            liftShadowBlur: 18

            findDest: key => grid._slots[key] || null
            // Asked of the ORDER, never read off a slot that is still moving.
            destTopIn: (item, key) => {
                const c = grid._cellOf(key);
                return c ? grid.flick.contentItem.mapToItem(item, 0, c.y).y : NaN;
            }
            // The hole the flying row left: its old cell.
            sourceTopIn: (item, key) => grid._flightFrom >= 0 ? grid.flick.contentItem.mapToItem(item, 0, grid.cell(grid._flightFrom).y).y : NaN
            indexOf: key => grid._awaitSerial >= 0 && grid.service.serial === grid._awaitSerial ? -1 : grid.order.indexOf(key)
            commit: key => {
                grid._flightFrom = grid.order.indexOf(key);
                grid._awaitSerial = grid.service.serial;
                grid._inCommit = true;
                grid.service.toggleFavorite(key);
                grid._inCommit = false;
                // Rebuilt at once: the order already answers, and the rows were
                // handed to the flight's clock in the relayout it made.
                if (grid.service.serial !== grid._awaitSerial) {
                    grid._awaitSerial = -1;
                    Qt.callLater(flight.reconciled);
                }
            }
            // The travel has started: the clone becomes the row it is turning
            // into (FlightClone.flipped).
            onRevealChanged: {
                if (flight.reveal > 0 && flight.active)
                    grid._starFlipped = true;
            }
            onEnded: {
                grid._flightClock = false;
                grid._wellOnFlight = false;
                grid.glideT = 1;
                grid._awaitSerial = -1;
                grid._flightFrom = -1;
                grid._starFlipped = false;
                // A cut flight's clone lands first; the landing hovers.
                if (grid._landKey === "")
                    grid._followPointer(!grid._flightByPointer);
                grid._flightByPointer = false;
            }

            // Built at the first favourite, not with every popup: the open's
            // frame budget has no room for a row nobody may fly.
            cloneComponent: grid._cloneWanted ? cloneComp : null
        }
    }
    property bool _cloneWanted: false

    // ---- The landing of a cut flight --------------------------------------------------------------
    // RowFlight's cancel() hides its clone and its contact shadow in one
    // frame, and the lifted clone (1.055, the shadow at full) became the
    // flat row: a pop. So the cut puts the clone DOWN instead: its body is
    // drawn in `landBody` below, beside a contact shadow drawn as RowFlight
    // draws its own, and eases from its lifted state -- where it was, its
    // width, its scale, its shadow -- to its row's rest over the flight's
    // landMs, OutCubic, on one clock (`landE`). The row stays hidden until
    // it has landed, then takes over in the same frame. Where it lands is
    // the row's slot, followed as it moves (a re-sort's reflow, a scroll):
    // the clone is the slot plus what was left of the gap, (1 - landE) of
    // it. A row with no place on screen (not on the new page, or its cell
    // past the fold) has none to land in: the clone settles where it is and
    // its presence fades on the same clock. The favourites file waits for
    // it (`flying`).
    property string _landKey: ""
    property real landE: 1
    // The plan: the clone's state at the cut ({x, y, w, h, s, sh, op}, in
    // landLayer's coordinates) and whether a cut since the flight was a new
    // page ({newPage}: latched, a re-cut keeps it), then, laid out, whether
    // it lands in its slot and the gap to it ({track, ox, oy, dx, dy, dw}).
    property var _land: null
    property bool _landByPointer: false
    // The shadow's MultiEffect is built at the first cut, not with every
    // popup, and kept.
    property bool _landWanted: false
    // Where the clone is drawn now, in landLayer's coordinates: its unscaled
    // rect, its scale, its contact shadow and its opacity. In the air it is
    // read off the flight (RowFlight publishes no reading of its lift; its
    // state is read here, never written); landing, off the landing. null:
    // there is no clone.
    function _cloneAt() {
        if (grid._land) {
            const r = grid._landRect;
            return {
                x: r.x,
                y: r.y,
                w: r.w,
                h: r.h,
                s: r.s,
                sh: r.sh,
                op: r.op
            };
        }
        const fl = grid._flight;
        const cl = fl ? fl.cloneItem as FlightClone : null;
        if (!grid._airborne || !cl)
            return null;
        const c = cl.mapToItem(landLayer, cl.width / 2, cl.height / 2);
        return {
            x: c.x - cl.width / 2,
            y: c.y - cl.height / 2,
            w: cl.width,
            h: cl.height,
            s: fl._scale,
            sh: fl._shadow,
            op: 1
        };
    }
    // The clone put down where `at` says it is: the body into landBody,
    // showing the row it now is (the committed facts, as the new cut shows
    // them; the pointer's look it had), before the flight drops its data.
    // Planned once the new order is laid out (_planLanding).
    function _putDown(at, newPage) {
        if (!at)
            return;
        landAnim.stop();
        grid._landWanted = true;
        grid.landE = 0;
        grid._land = Object.assign({}, at, {
            newPage: newPage === true || !!grid._land && grid._land.newPage === true
        });
        const fl = grid._flight;
        const cl = fl.cloneItem as FlightClone;
        if (!grid._airborne) {
            // Put down already: its row as this cut shows it (a query's
            // marks move with the query).
            cl.landData = Object.assign({}, cl.landData, {
                facts: grid._factsOf(grid._landKey)
            });
            return;
        }
        const d = cl.flightData;
        grid._landKey = fl.key;
        grid._landByPointer = grid._flightByPointer;
        cl.landData = {
            facts: grid._factsOf(fl.key),
            hovered: !!d && d.hovered,
            starHovered: !!d && d.starHovered
        };
        cl.landHost = landBody;
    }
    function _planLanding() {
        const L = grid._land;
        if (!L || L.track !== undefined)
            return;
        const sl = grid._slots[grid._landKey];
        const track = !!sl && sl.placed && sl.shown && grid._onScreen(sl.ty, grid.rowH);
        const o = gridFlick.mapToItem(landLayer, 0, 0);
        const p = Object.assign({}, L, {
            track: track,
            ox: o.x,
            oy: o.y,
            dx: 0,
            dy: 0,
            dw: 0
        });
        if (track) {
            p.dx = L.x - (o.x + sl.x - gridFlick.contentX);
            p.dy = L.y - (o.y + sl.y - gridFlick.contentY);
            p.dw = L.w - sl.width;
        } else if (sl && sl.placed) {
            // Its cell is past the fold: placed there (only what is on
            // screen moves), while the clone fades where it is.
            sl.fx = sl.tx;
            sl.fy = sl.ty;
        }
        grid._land = p;
        // The highlight on the row it lands in: the clone wears the well's
        // plate and the well rides under it (above). Read off the order: the
        // `currentKey` binding may lag inside the re-cut.
        grid._wellRides = track && grid.order[grid.current] === grid._landKey;
        landAnim.restart();
    }
    // The clone as drawn this frame (one object: its shadow and its body
    // read the same generation).
    readonly property var _landRect: {
        const L = grid._land;
        if (!L)
            return null;
        const k = 1 - grid.landE;
        const sl = L.track ? grid._slots[grid._landKey] : null;
        let x = L.x, y = L.y, w = L.w;
        if (sl) {
            x = L.ox + sl.x - gridFlick.contentX + L.dx * k;
            y = L.oy + sl.y - gridFlick.contentY + L.dy * k;
            w = sl.width + L.dw * k;
        }
        return {
            x: x,
            y: y,
            w: w,
            h: L.h,
            s: 1 + (L.s - 1) * k,
            sh: L.sh * k,
            op: L.track ? 1 + (L.op - 1) * k : L.op * k
        };
    }
    NumberAnimation {
        id: landAnim
        target: grid
        property: "landE"
        from: 0
        to: 1
        duration: grid._flight ? grid._flight.landMs : 160
        easing.type: Easing.OutCubic
        onFinished: grid._endLanding()
    }
    // Landed (or ended at once by a new toggle): the body back in the
    // clone, the row shown in the same frame, and what is under the pointer
    // hovered (as a landing flight does). A well that rode the clone goes
    // back to its own glide, which the re-cut started from where the well
    // stood -- under the clone -- to the row's cell on the row's clock, so
    // it is on its row as the ride ends. After a new page (a query typed, a
    // folder opened) the pointer is only hovered: the page's highlight is on
    // its top row until the user moves it (refreshOrder), and handing it to
    // the row under a resting pointer 160 ms later would make Enter launch that
    // row instead of the top match. `keepHighlight`: a toggle from the
    // keyboard or the menu ended it -- the highlight stays where it is.
    function _endLanding(keepHighlight) {
        // Ended early, it has landed all the same: the row takes over now.
        landAnim.stop();
        grid.landE = 1;
        grid._wellRides = false;
        const newPage = !!grid._land && grid._land.newPage === true;
        const fl = grid._flight;
        const cl = fl ? fl.cloneItem as FlightClone : null;
        if (cl) {
            cl.landHost = null;
            cl.landData = null;
        }
        grid._land = null;
        grid._landKey = "";
        grid._followPointer(keepHighlight === true || !grid._landByPointer || newPage);
        grid._landByPointer = false;
    }
    // In the flight's own layer (RowFlight's clone host fills the same one).
    Item {
        id: landLayer
        parent: grid.flightLayer || grid.overlayItem || grid
        anchors.fill: parent
        visible: !!grid._landRect

        // RowFlight's contact shadow, drawn as it draws its own: the plate a
        // row inset in, spread and blurred by what this grid hands the
        // flight, its 12 px radius and 0.30 of its colour.
        Rectangle {
            id: landShadow
            objectName: "landShadow"
            readonly property var r: grid._landRect
            readonly property RowFlight f: grid._flight
            readonly property real spread: landShadow.f ? landShadow.f.liftShadowSpread : 0
            readonly property real insetL: landShadow.f ? landShadow.f.contentInsetLeft : 0
            readonly property real insetR: landShadow.f ? landShadow.f.contentInsetRight : 0
            x: landShadow.r ? landShadow.r.x + landShadow.insetL - landShadow.spread : 0
            y: landShadow.r ? landShadow.r.y + landShadow.spread * 0.4 : 0
            width: landShadow.r ? landShadow.r.w - landShadow.insetL - landShadow.insetR + 2 * landShadow.spread : 0
            height: landShadow.r ? landShadow.r.h + landShadow.spread * 1.2 : 0
            radius: 12
            color: landShadow.f ? landShadow.f.dropShadowColor : "transparent"
            opacity: landShadow.r ? landShadow.r.sh * 0.30 : 0
            scale: landShadow.r ? landShadow.r.s : 1
            transformOrigin: Item.Center
            layer.enabled: grid._landWanted && !!landShadow.f && landShadow.f.liftShadowBlur > 0
            layer.textureSize: dev.texSize(landShadow.width, landShadow.height)
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                blurMax: Math.round(landShadow.f ? landShadow.f.liftShadowBlur : 0)
            }
        }
        // The clone's body, put down (FlightClone.landHost).
        Item {
            id: landBody
            objectName: "landBody"
            readonly property var r: grid._landRect
            x: landBody.r ? landBody.r.x : 0
            y: landBody.r ? landBody.r.y : 0
            width: landBody.r ? landBody.r.w : 0
            height: landBody.r ? landBody.r.h : 0
            scale: landBody.r ? landBody.r.s : 1
            opacity: landBody.r ? landBody.r.op : 0
            transformOrigin: Item.Center
        }
    }

    Component {
        id: cloneComp
        FlightClone {
            flipped: grid._starFlipped
            landing: grid._starFlipped && grid._flightReveal >= 1
            landHighlighted: grid._wellRides
            ground: grid.ground
            tune: grid.tune
            searching: grid.searching
        }
    }

    // ---- Rename -----------------------------------------------------------------------------------------
    // The row menu's Rename: an editor in the row, in place of its name (the
    // LLM sidebar's inline rename). A DISPLAY title (the service keeps it; the
    // file is never touched); empty resets it to the real name. The row must
    // be on screen, so it is revealed first.
    property string renameKey: ""
    function beginRename(key) {
        const e = grid.service ? grid.service.entry(key) : null;
        if (!e || e.kind === "folder")
            return;
        grid.reveal(key);
        grid.renameKey = key;
    }
    function _commitRename(key, text) {
        if (key === "" || key !== grid.renameKey)
            return;
        const e = grid.service.entry(key);
        grid.renameKey = "";
        grid.forceActiveFocus();
        if (e && text !== e.name)
            grid.service.renameItem(key, text);
    }
    // Escape gives the keyboard back to the list; a focus taken elsewhere is
    // left where it went.
    function _endRename(refocus) {
        if (grid.renameKey === "")
            return;
        grid.renameKey = "";
        if (refocus)
            grid.forceActiveFocus();
    }

    // ---- Keys ------------------------------------------------------------------------------------------
    Keys.onPressed: event => {
        // A launch's row is on its way out: the closing list takes no key.
        if (grid.frozen) {
            event.accepted = true;
            return;
        }
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const page = Math.max(1, Math.floor(gridFlick.height / grid.rowH)) * grid.cols;
        // The terminal's kills on the query: a word, a blank-delimited word, the lot.
        const kill = EK.queryActionOf(event.key, event.modifiers);
        if (kill !== null) {
            grid.queryKilled(kill);
            grid.engaged();
            event.accepted = true;
            return;
        }
        const svc = grid.primary ? grid.service : null;
        switch (event.key) {
        case Qt.Key_Down:
            if (svc && svc.answerRecalling)
                svc.recallStep(-1);
            else if (grid.answerSel)
                grid.answerSelRaw = false;
            else
                grid.step(grid.cols);
            break;
        case Qt.Key_Up:
            if (grid.answerSel) {
                if (svc && svc.answerRecalling)
                    svc.recallStep(1);
            } else if (grid.answerOn && grid.current < grid.cols) {
                grid.answerSelRaw = true;
            } else if (svc && grid.current < grid.cols && svc.folder === "" && !svc.hiddenView && svc.recallStep(1)) {
                // an older answered query is back in the header
            } else {
                grid.step(-grid.cols);
            }
            break;
        case Qt.Key_Right:
            if (grid.cols === 1)
                return;
            if (!grid.answerSel)
                grid.step(1);
            break;
        case Qt.Key_Left:
            if (grid.cols === 1)
                return;
            if (!grid.answerSel)
                grid.step(-1);
            break;
        case Qt.Key_PageDown:
            if (grid.answerSel)
                grid.answerSelRaw = false;
            else
                grid.step(page);
            break;
        case Qt.Key_PageUp:
            if (!grid.answerSel)
                grid.step(-page);
            break;
        case Qt.Key_Home:
        case Qt.Key_End:
            // The query is no caret (typed text is appended): Home / End jump to the first / last GRID row, out of the answer row.
            grid.answerSelRaw = false;
            grid.step(event.key === Qt.Key_Home ? -grid.order.length : grid.order.length);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
            if (grid.answerSel)
                grid.answerActivated(shift);
            else
                grid.activateCurrent(shift);
            break;
        case Qt.Key_Escape:
            grid.escaped();
            break;
        case Qt.Key_Backspace:
            grid.backspaced();
            grid.engaged();
            break;
        case Qt.Key_Tab:
            grid.sortStep(1);
            break;
        case Qt.Key_Backtab:
            grid.sortStep(-1);
            break;
        case Qt.Key_F:
            if (ctrl) {
                if (grid.currentKey !== "" && !grid.answerSel)
                    grid.toggleFavourite(grid.currentKey, false);
                grid.engaged();
                break;
            }
            grid._typedKey(event);
            return;
        default:
            grid._typedKey(event);
            return;
        }
        event.accepted = true;
    }
    function _typedKey(event) {
        if (event.text.length > 0 && event.text.charCodeAt(0) >= 32 && !(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))) {
            grid.typed(event.text);
            grid.engaged();
            event.accepted = true;
        }
    }
}
