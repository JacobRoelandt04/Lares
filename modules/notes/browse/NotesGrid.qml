pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/float"
import "../../common/theme"
import "../GridLayout.js" as GL
import "../../common/components/DragIntent.js" as DI
import "../../common/components/EditKeys.js" as EK

// =============================================================================
// NotesGrid.qml -- the notes of one folder (or a search's results) as tiles.
//
// The + tile first, then the folder's entries in the service's display order
// (its sort, or the custom order). Tiles are placed from that order by
// GridLayout.js; every change of placement -- a sort, a column added by a
// resize, the gap a drag opens, a drop -- moves them on ONE clock (`reflowT`,
// 220 ms OutCubic): each tile keeps where it was (mid-flight included) and
// eases to its new cell. Only what is on screen travels; a tile whose old and
// new cells are both off screen is simply placed (docs/
// list_animation.md).
//
// DRAGGING. A press that travels 6 px picks the tile up: it is drawn as a
// ghost in the host's overlay (lifted: deeper shadow), its cell becomes the
// gap, and every frame DragIntent.js decides from the pointer, its speed and
// the TARGET cells whether this is a GROUP (dwelling on a tile's centre) or a
// REORDER (anywhere else, Custom sort only) -- see that file for the
// thresholds and why nothing flaps. The drop: group -> a new group from the
// two (or into the group dropped on); reorder -> the custom order; a nested
// grid's header band -> the parent folder (the drag carries on there).
//
// THE FLOAT. Every tile is a FloatCard (modules/common/float) on the popup's
// one FloatClock (`floatClock`, the host's: NotesPopup): it sways, leans
// towards the pointer and lifts under it, and the hand is dealt in when the
// popup opens. The + slot is part of the page: it is dealt in, never sways.
// A tile's sway is its own (its seed is a hash of its key) and outlives its
// delegate (the clock keeps it by key), so a tile handed from one grid to
// the other in a group's morph sways on where it was. While a drag, a
// reorder (the reflow) or a scroll runs, the grid asks for calm
// (`floatCalm`): the sway eases to rest and the clock stops. Input follows
// the picture: a press is taken by the card DRAWN under it (_cardKeyAt),
// the link glyph is hit-tested in the card's own frame, and a tile picked
// up leaves from where it was drawn (the ghost carries its pose and lets go
// of it as it lifts).
// =============================================================================
FocusScope {
    id: grid

    property var service: null
    property string folder: ""
    // A search's results: a flat list of keys from every folder (null: browse).
    property var searchKeys: null
    property Item overlayItem: null
    property string fontFamily: "Inter"
    property var opt: ({
            pad: 12,
            gap: 12,
            minTile: 132,
            maxTile: 176,
            aspect: 1.18,
            hysteresis: 6
        })
    // What the grid stands on: its edge fades fade into it.
    property color ground: "transparent"
    // The popup's rounded outline in this item's coordinates (ScrollDressing).
    property var outline: null
    // Room under the last row, inside this item: the grid's padding unless
    // the host ends this item short of its own margin (NotesPopup: the page
    // stops a tile shadow's reach above the popup's foot and this is the rest).
    property real footPad: grid.opt.pad
    // A tile drawn elsewhere for now -- the popup's morph card is growing out
    // of it or shrinking into it ("+" is the new-note tile). Kept in the
    // layout, only not painted.
    property string hiddenKey: ""
    // The header band a drag leaves a nested folder through (grid coordinates).
    property var exitRect: null
    // The float: the popup's one clock (null: the tiles stand still) and its numbers.
    property FloatClock floatClock: null
    property FloatStyle floatStyle: FloatStyle {}
    // A drag, a reorder or a scroll is running: the host hands it to the clock's `calm`. A reorder is a reflow that moves a
    // tile (`_travelling`): the one that lays the page out as it opens moves nothing, and the deal is the motion then.
    readonly property bool floatCalm: grid.dragKey !== "" || (reflow.running && grid._travelling) || flyAnim.running || dressing.moving
    property bool _travelling: false
    readonly property bool searching: grid.searchKeys !== null
    readonly property bool customSort: grid.service ? grid.service.sortMode === "custom" : false
    readonly property alias flick: flick

    signal openNote(string key)
    signal openGroup(string key)
    signal createNote
    signal menuRequested(string key, real x, real y)
    // A foreign note's link glyph was clicked: where the file really lives.
    signal revealReal(string key)
    signal exitRequested
    signal typed(string text)
    signal backspaced
    // Ctrl+Backspace / Ctrl+W / Ctrl+U on the typed query (EditKeys.js: the action's name).
    signal queryKilled(string action)
    signal escaped

    // ---- The keyboard highlight ---------------------------------------------------------------
    // Arrows, Home, End, PgUp and PgDn move it over the tiles (the "+" tile is not one); it is drawn only after such a key and
    // goes when the pointer moves over the grid, a key types, or the tile leaves the view's order. Enter opens it as a click does.
    property string kbKey: ""
    property bool kbShown: false
    function _kbHide() {
        grid.kbShown = false;
    }
    function _kbMove(key) {
        const n = grid.order.length;
        if (n === 0)
            return;
        const lead = grid._leadNow();
        const cols = grid.geo.cols;
        const cur = grid.kbShown ? grid.order.indexOf(grid.kbKey) : -1;
        const page = Math.max(1, Math.floor((flick.height - grid.geo.pad + grid.geo.gap) / (grid.geo.tileH + grid.geo.gap))) * cols;
        let i;
        if (cur < 0) {
            // The first press shows the highlight where the view is: the first tile whose row is in view.
            i = 0;
            if (key !== Qt.Key_Home && key !== Qt.Key_End) {
                for (let j = 0; j < n; j++) {
                    const r = GL.cell(lead + j, grid.geo);
                    if (r.y + r.h > flick.contentY + 1) {
                        i = j;
                        break;
                    }
                }
            }
            if (key === Qt.Key_End)
                i = n - 1;
        } else {
            i = cur;
            if (key === Qt.Key_Left)
                i = cur - 1;
            else if (key === Qt.Key_Right)
                i = cur + 1;
            else if (key === Qt.Key_Up)
                i = cur - cols;
            else if (key === Qt.Key_Down)
                i = cur + cols;
            else if (key === Qt.Key_PageUp)
                i = cur - page;
            else if (key === Qt.Key_PageDown)
                i = cur + page;
            else if (key === Qt.Key_Home)
                i = 0;
            else if (key === Qt.Key_End)
                i = n - 1;
            i = Math.max(0, Math.min(n - 1, i));
        }
        grid.kbKey = grid.order[i];
        grid.kbShown = true;
        grid.reveal(grid.kbKey);
    }
    // The pointer moving over the grid hands the highlight back to the hand. A resting pointer's hover point is
    // re-delivered every frame (Qt 6.11) and the keys scroll tiles under it: only a real displacement counts.
    HoverHandler {
        id: pointerWatch
        property point _at: Qt.point(-1, -1)
        onPointChanged: {
            const p = pointerWatch.point.position;
            if (pointerWatch._at.x >= 0 && Math.hypot(p.x - pointerWatch._at.x, p.y - pointerWatch._at.y) > 2)
                grid._kbHide();
            pointerWatch._at = p;
        }
        onHoveredChanged: if (!pointerWatch.hovered)
            pointerWatch._at = Qt.point(-1, -1)
    }

    // ---- The relative-time clock ---------------------------------------------------------------
    // One BoundaryClock for every tile's modified time: each tile asks it for
    // the instant its own words change ("now" -> "1 min" at its minute, "23 h"
    // -> "Thu" at its day), and it wakes only then. Nothing ticks between, and
    // nothing at all while no tile is built -- tiles exist only on screen, so
    // a hidden grid asks for nothing. A probe pins the tiles by handing in any
    // object with `now` and `request()`.
    property var clock: relClock
    BoundaryClock {
        id: relClock
    }
    // The instant the tiles read (the popup's morph card draws a tile at it).
    readonly property real now: grid.clock ? grid.clock.now : 0

    // ---- Order and geometry -----------------------------------------------------------------
    property var order: []
    property var geo: GL.geometry(400, grid.opt, 0)
    property int layoutSerial: 0
    property real reflowT: 1

    // The lead the layout was last built with (_leadNow(): 1 while the + tile
    // takes cell 0, 0 while a search hides it). The key list alone does not
    // say where the tiles go: a search whose results are the folder's whole
    // list leaves `order` as it was, so clearing it would keep every tile one cell
    // too far up and the first note would draw over the + tile, until the next
    // search changes the list.
    property int _laidLead: -1
    function refreshOrder() {
        if (!grid.service)
            return;
        // Read searchKeys itself, not `searching`: in its own change handler
        // the derived binding may not have caught up yet (CLAUDE.md: one
        // cascade, two generations).
        const next = grid.searchKeys !== null ? grid.searchKeys.slice() : grid.service.children(grid.folder);
        const lead = grid._leadNow();
        if (lead !== grid._laidLead || JSON.stringify(next) !== JSON.stringify(grid.order)) {
            grid._laidLead = lead;
            grid.order = next;
            if (next.indexOf(grid.kbKey) < 0)
                grid.kbShown = false;
            grid._syncRows();
            grid.relayout(true);
        }
    }
    Connections {
        target: grid.service
        function onSerialChanged() {
            grid.refreshOrder();
        }
    }
    // Tiles that ARRIVE while this view is showing (the group a drop just
    // made, a note just saved) pop in; a new folder or search is a page of
    // its own and is placed.
    property bool _appearOk: false
    onFolderChanged: {
        grid._appearOk = false;
        grid.order = [];
        grid.refreshOrder();
        flick.contentY = 0;
        Qt.callLater(() => grid._appearOk = true);
    }
    onSearchKeysChanged: {
        grid._appearOk = false;
        grid.refreshOrder();
        Qt.callLater(() => grid._appearOk = true);
    }

    // A resize moves tiles with the edge; only a change of column count
    // (tiles changing rows) is animated.
    onWidthChanged: {
        const cols = GL.columns(grid.width, grid.opt, grid.geo ? grid.geo.cols : 0);
        grid.relayout(!grid.geo || cols !== grid.geo.cols);
    }

    // The delegates: one per key this view shows (plus a carried tile).
    ListModel {
        id: rows
    }
    function _syncRows() {
        const want = {};
        for (const k of grid.order)
            want[k] = true;
        if (grid.dragKey !== "")
            want[grid.dragKey] = true;
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
    Component.onCompleted: {
        grid.refreshOrder();
        Qt.callLater(() => grid._appearOk = true);
    }

    // The + tile's cell (none while searching). A function, read fresh, for
    // the same reason as refreshOrder's.
    function _leadNow() {
        return grid.searchKeys !== null ? 0 : 1;
    }

    // The display cell of a key: the + tile is cell 0 while browsing; a drag
    // takes its tile out of the order and opens the gap.
    function displayIndexOf(key) {
        if (grid.dragKey !== "" && grid._dragOrder) {
            const pos = grid._dragOrder.indexOf(key);
            if (pos < 0)
                return -1;
            return grid._leadNow() + pos + (pos >= grid._intent.gap ? 1 : 0);
        }
        const i = grid.order.indexOf(key);
        return i < 0 ? -1 : grid._leadNow() + i;
    }

    // Where `key`'s tile is ("+": the new-note tile), in this item's
    // coordinates, from the layout's target cell; null when it has none.
    function _cellOf(key) {
        const i = key === "+" ? (grid.searchKeys !== null ? -1 : 0) : grid.displayIndexOf(key);
        return i < 0 || !grid.geo ? null : GL.cell(i, grid.geo);
    }
    function rectOf(key) {
        const r = grid._cellOf(key);
        return r ? {
            x: r.x,
            y: r.y - flick.contentY,
            w: r.w,
            h: r.h
        } : null;
    }
    // Scroll, at once, so that `key`'s tile is on screen.
    function reveal(key) {
        const r = grid._cellOf(key);
        if (!r)
            return;
        const max = Math.max(0, flick.contentHeight - flick.height);
        if (r.y - grid.geo.pad < flick.contentY)
            flick.contentY = Math.max(0, r.y - grid.geo.pad);
        else if (r.y + r.h + grid.geo.pad > flick.contentY + flick.height)
            flick.contentY = Math.min(max, r.y + r.h + grid.geo.pad - flick.height);
    }

    function cellCount() {
        return grid._leadNow() + grid.order.length;
    }

    // animate: whether tiles on screen travel to their new cells.
    function relayout(animate) {
        grid.geo = GL.geometry(grid.width, grid.opt, grid.geo ? grid.geo.cols : 0);
        flick.contentHeight = GL.contentHeight(grid.cellCount(), grid.geo) - grid.geo.pad + grid.footPad;
        grid._animateNext = animate !== false;
        grid._travelling = false;
        grid.layoutSerial++;
        if (grid._animateNext)
            reflow.restart();
    }
    property bool _animateNext: true
    NumberAnimation {
        id: reflow
        target: grid
        property: "reflowT"
        from: 0
        to: 1
        duration: 220
        easing.type: Easing.OutCubic
    }

    function _onScreen(y, h) {
        return y + h >= flick.contentY - 20 && y <= flick.contentY + flick.height + 20;
    }

    // ---- The grid ----------------------------------------------------------------------------------
    Flickable {
        id: flick
        anchors.fill: parent
        interactive: false
        clip: true
        contentWidth: width
        boundsBehavior: Flickable.StopAtBounds

        FloatCard {
            id: plusCard
            visible: !grid.searching
            opacity: grid.hiddenKey === "+" ? 0 : 1
            readonly property var r: GL.cell(0, grid.geo)
            x: plusCard.r.x
            y: plusCard.r.y
            width: plusCard.r.w
            height: plusCard.r.h
            clock: grid.floatClock
            style: grid.floatStyle
            floats: false
            NewNoteTile {
                anchors.fill: parent
            }
        }

        Repeater {
            id: tileRepeater
            // Only what this view shows has a delegate (not every row of every
            // folder: 328 of them retargeted on each resize step, measured).
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
                readonly property alias card: card
                readonly property bool kb: grid.kbShown && grid.kbKey === slot.key
                property int tw: grid.geo.tileW
                property bool placed: false
                visible: slot.shown && grid._onScreen(slot.y, slot.height)
                opacity: (slot.key === grid.hiddenKey ? 0 : 1) * slot.appearF
                scale: 0.9 + 0.1 * slot.appearF
                property real appearF: 1
                NumberAnimation on appearF {
                    id: appearAnim
                    running: false
                    from: 0
                    to: 1
                    duration: 200
                    easing.type: Easing.OutCubic
                }
                x: slot.fx + (slot.tx - slot.fx) * grid.reflowT
                y: slot.fy + (slot.ty - slot.fy) * grid.reflowT
                width: slot.tw
                height: grid.geo.tileH
                z: 1

                function retarget() {
                    if (slot.di < 0) {
                        slot.placed = false;
                        return;
                    }
                    const r = GL.cell(slot.di, grid.geo);
                    const from = {
                        x: slot.x,
                        y: slot.y
                    };
                    slot.tx = r.x;
                    slot.ty = r.y;
                    slot.tw = r.w;
                    let travel = slot.placed && grid._animateNext && (grid._onScreen(from.y, r.h) || grid._onScreen(r.y, r.h));
                    // The tile just dropped settles from under the finger,
                    // not from the cell it was lifted out of.
                    const st = grid._settle;
                    if (st && st.key === slot.key) {
                        from.x = st.x;
                        from.y = st.y;
                        travel = true;
                        grid._settle = null;
                    }
                    slot.fx = travel ? from.x : r.x;
                    slot.fy = travel ? from.y : r.y;
                    if (travel && (from.x !== r.x || from.y !== r.y))
                        grid._travelling = true;
                    slot.placed = true;
                }
                Connections {
                    target: grid
                    function onLayoutSerialChanged() {
                        slot.retarget();
                    }
                }
                Component.onCompleted: {
                    slot.retarget();
                    if (grid._appearOk && grid._onScreen(slot.y, slot.height)) {
                        slot.appearF = 0;
                        appearAnim.start();
                    }
                }

                // Facts, read fresh when the service changes (colour, preview,
                // time): a plain object, never a colour.
                readonly property var facts: grid.service && grid.service.serial >= 0 ? grid.service.entry(slot.key) : null

                FloatCard {
                    id: card
                    anchors.fill: parent
                    clock: grid.floatClock
                    style: grid.floatStyle
                    stateKey: slot.key
                    seed: grid.seedOf(slot.key)
                    order: Math.max(0, slot.di)
                    lifted: cardHover.hovered || slot.kb
                    tilting: cardHover.hovered
                    pointerX: Math.max(-1, Math.min(1, cardHover.point.position.x / Math.max(1, card.width) * 2 - 1))
                    pointerY: Math.max(-1, Math.min(1, cardHover.point.position.y / Math.max(1, card.height) * 2 - 1))
                    // On the card, not the tile: an ancestor of the tile's link glyph does not take its hover (CLAUDE.md).
                    HoverHandler {
                        id: cardHover
                        enabled: grid.dragKey === "" && slot.key !== grid.hiddenKey
                    }
                    Loader {
                        anchors.fill: parent
                        active: slot.visible
                        sourceComponent: slot.facts && slot.facts.isGroup ? groupFace : noteFace
                    }
                }
                Component {
                    id: noteFace
                    NoteTile {
                        entry: slot.facts
                        faceLayered: !!grid.floatClock && grid.floatClock.layers
                        clock: grid.clock
                        overlayItem: grid.overlayItem
                        fontFamily: grid.fontFamily
                        target: grid._intent !== null && grid._intent.intent === "group" && grid._intent.target === slot.key
                        hoverEnabled: grid.dragKey === ""
                        kbFocus: slot.kb
                    }
                }
                Component {
                    id: groupFace
                    GroupTile {
                        entry: slot.facts
                        faceLayered: !!grid.floatClock && grid.floatClock.layers
                        minis: grid.layoutSerial >= 0 ? grid.minisOf(slot.key) : []
                        fontFamily: grid.fontFamily
                        target: grid._intent !== null && grid._intent.intent === "group" && grid._intent.target === slot.key
                        hoverEnabled: grid.dragKey === ""
                        kbFocus: slot.kb
                    }
                }
            }
        }
    }

    ScrollDressing {
        id: dressing
        anchors.fill: flick
        flick: flick
        fadeHeight: 24
        ground: grid.ground
        outline: grid.outline
    }

    // A search nothing matches: the family's empty words (presence fades, never while the notes still load).
    Text {
        objectName: "notesNoMatch"
        anchors.fill: flick
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: "No match"
        font.family: grid.fontFamily
        font.pixelSize: 14
        color: Theme.textFaint
        property real f: grid.searching && grid.searchKeys.length === 0 && grid.service && grid.service.serial >= 0 ? 1 : 0
        Behavior on f {
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }
        opacity: f
        visible: f > 0
    }

    SelectionAutoScroll {
        id: autoScroll
        flickable: flick
    }

    function minisOf(key) {
        if (!grid.service)
            return [];
        return grid.service.children(key).slice(0, 4).map(k => grid.service.entry(k)).filter(e => e);
    }

    // ---- Pointer --------------------------------------------------------------------------------------
    property string dragKey: ""
    property var _dragOrder: null
    property var _intent: null
    property var _press: null
    property real _grabDX: 0
    property real _grabDY: 0
    property var _pointer: ({
            x: 0,
            y: 0
        })
    property var _ghostFacts: null
    property int _intentSerial: 0

    // The key of the tile DRAWN under a point (content coordinates; "+": the
    // new-note slot), or null: the point mapped into each card's own frame,
    // through its pose, so a press lands on the card the user sees -- its
    // lifted edge reaches into the gap, a card swayed off a corner of its
    // cell no longer covers it.
    function keyAt(cx, cy) {
        if (plusCard.visible && grid._inCard(plusCard, cx, cy))
            return "+";
        for (let i = 0; i < tileRepeater.count; i++) {
            const s = tileRepeater.itemAt(i);
            if (s && s.visible && grid._inCard(s.card, cx, cy))
                return s.key;
        }
        return null;
    }
    function _inCard(c, cx, cy) {
        const p = c.mapFromItem(flick.contentItem, cx, cy);
        return p.x >= 0 && p.y >= 0 && p.x <= c.width && p.y <= c.height;
    }
    function _cardOf(key) {
        if (key === "+")
            return plusCard;
        for (let i = 0; i < tileRepeater.count; i++) {
            const s = tileRepeater.itemAt(i);
            if (s && s.key === key)
                return s.card;
        }
        return null;
    }
    // Where `key`'s card is drawn on this tick (FloatCard's pose; a binding
    // that calls this follows it), or null when it has no card.
    function poseOf(key) {
        const c = grid._cardOf(key);
        return c ? {
            x: c.poseX,
            y: c.poseY,
            rot: c.poseRot,
            tiltX: c.poseTiltX,
            tiltY: c.poseTiltY,
            lift: c.poseLift
        } : null;
    }
    // A tile's own sway: FNV-1a of its key, so it sways the same way at every open.
    function seedOf(key) {
        let h = 2166136261;
        for (let i = 0; i < key.length; i++) {
            h ^= key.charCodeAt(i);
            h = Math.imul(h, 16777619) >>> 0;
        }
        return h % 100000 + 1;
    }

    // Whether a point (content coordinates) is on `key`'s link glyph: the
    // tile draws it at its top-right corner inside the padding (NoteTile);
    // the grid's one mouse layer hit-tests it by the same numbers, in the
    // card's own frame.
    function _onLinkGlyph(key, cx, cy) {
        const e = grid.service ? grid.service.entry(key) : null;
        const c = grid._cardOf(key);
        if (!e || !e.isLink || !c)
            return false;
        const p = c.mapFromItem(flick.contentItem, cx, cy);
        return p.x >= c.width - 12 - 16 && p.x <= c.width - 12 + 4 && p.y >= 4 && p.y <= 26;
    }

    MouseArea {
        id: mouse
        anchors.fill: flick
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: m => {
            grid.forceActiveFocus();
            const c = mouse.mapToItem(flick.contentItem, m.x, m.y);
            const k = grid.keyAt(c.x, c.y);
            if (m.button === Qt.RightButton) {
                if (k && k !== "+") {
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
                cy: c.y
            };
        }
        onPositionChanged: m => {
            if (!grid._press)
                return;
            if (grid.dragKey === "") {
                const d = Math.hypot(m.x - grid._press.x, m.y - grid._press.y);
                if (d >= 6 && grid._press.key && grid._press.key !== "+")
                    grid._beginDrag(grid._press.key, grid._press.cx, grid._press.cy);
            }
            if (grid.dragKey !== "") {
                const c = mouse.mapToItem(flick.contentItem, m.x, m.y);
                grid._pointer = {
                    x: c.x,
                    y: c.y
                };
                autoScroll.at(mouse.mapToItem(null, m.x, m.y).y);
            }
        }
        onReleased: m => {
            const p = grid._press;
            grid._press = null;
            if (grid.dragKey !== "") {
                grid._drop();
                return;
            }
            if (!p || m.button !== Qt.LeftButton)
                return;
            if (p.key === "+")
                grid.createNote();
            else if (p.key && grid._onLinkGlyph(p.key, p.cx, p.cy))
                grid.revealReal(p.key);
            else if (p.key)
                grid.openKey(p.key);
        }
        onCanceled: {
            grid._press = null;
            if (grid.dragKey !== "")
                grid._cancelDrag();
        }
    }

    // What a click on a tile does (a folder opens as a group, a note in the editor), and what Enter does.
    function openKey(key) {
        const e = grid.service ? grid.service.entry(key) : null;
        if (e && e.isGroup)
            grid.openGroup(key);
        else if (e)
            grid.openNote(key);
    }

    function autoScrollReapply() {
    }

    function _beginDrag(key, cx, cy) {
        const e = grid.service.entry(key);
        if (!e)
            return;
        const cell = GL.cell(grid.displayIndexOf(key), grid.geo);
        grid._grabDX = cx - cell.x;
        grid._grabDY = cy - cell.y;
        grid._ghostFacts = e;
        // The ghost leaves from where the tile was drawn: its pose, let go of as it lifts.
        grid._liftPose = grid.poseOf(key);
        const desc = {};
        if (e.isGroup)
            for (const r of grid._allUnder(key))
                desc[r] = 1;
        grid._dragDesc = desc;
        grid._dragOrder = grid.order.filter(k => k !== key);
        grid._intent = DI.create(grid.order.indexOf(key));
        grid._pointer = {
            x: cx,
            y: cy
        };
        grid.dragKey = key;
        autoScroll.begin(grid);
        grid.relayout(true);
    }
    property var _dragDesc: ({})
    property var _liftPose: null

    function _allUnder(key) {
        const out = [];
        const walk = k => {
            for (const c of grid.service.children(k)) {
                out.push(c);
                walk(c);
            }
        };
        walk(key);
        return out;
    }

    function _targetCells() {
        const out = [];
        for (let pos = 0; pos < grid._dragOrder.length; pos++) {
            const k = grid._dragOrder[pos];
            const r = GL.cell(grid._leadNow() + pos + (pos >= grid._intent.gap ? 1 : 0), grid.geo);
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
        const before = grid._intent.gap;
        const intentBefore = grid._intent.intent + grid._intent.target;
        const exits = [];
        if (grid.exitRect)
            exits.push({
                x: grid.exitRect.x,
                y: grid.exitRect.y + flick.contentY,
                w: grid.exitRect.w,
                h: grid.exitRect.h
            });
        DI.step(grid._intent, grid._pointer, grid._targetCells(), {
            now: Date.now(),
            customSort: grid.customSort && !grid.searching,
            dragged: {
                key: grid.dragKey,
                isGroup: !!(grid._ghostFacts && grid._ghostFacts.isGroup),
                descendants: grid._dragDesc
            },
            exitRects: exits
        });
        if (grid._intent.gap !== before)
            grid.relayout(true);
        if (grid._intent.intent + grid._intent.target !== intentBefore) {
            grid._intentSerial++;
            grid._intent = grid._intent;
            if (grid._intent.intent === "exit")
                grid.exitRequested();
        }
    }

    // After an exit, the host has switched `folder`: the drag carries on here.
    function continueDragInFolder() {
        if (grid.dragKey === "")
            return;
        grid._dragOrder = grid.order.filter(k => k !== grid.dragKey);
        grid._intent = DI.create(grid._dragOrder.length);
        grid.relayout(false);
    }

    function _drop() {
        const it = grid._intent;
        const key = grid.dragKey;
        const folderNow = grid.folder;
        let committed = false;
        // Where the carried tile is now, in the grid's content: a reorder
        // settles from here; a group swallows it from here.
        const gc = ghost.mapToItem(flick.contentItem, ghost.width / 2, ghost.height / 2);
        const here = {
            key: key,
            x: gc.x - grid.geo.tileW / 2,
            y: gc.y - grid.geo.tileH / 2
        };
        if (it.intent === "group" && it.target) {
            const tc = grid._cellOf(it.target);
            if (tc)
                grid._flyInto(tc);
            const t = grid.service.entry(it.target);
            if (t && t.isGroup)
                grid.service.moveEntry(key, it.target);
            else
                grid.service.makeGroup(it.target, key);
            committed = true;
        } else if (it.intent === "reorder" && grid.customSort) {
            const next = grid._dragOrder.slice();
            next.splice(it.gap, 0, key);
            grid.service.setCustomOrder(folderNow, next);
            committed = true;
        }
        // Dropped into this folder after coming from another: move it here.
        const e = grid.service.entry(key);
        if (!committed && e && e.parentKey !== folderNow)
            grid.service.moveEntry(key, folderNow);
        if (!(it.intent === "group" && it.target))
            grid._settle = here;
        grid._endDrag();
        settleExpiry.restart();
    }
    // A drop's settle is consumed by the tile's next placement; one that
    // never comes (the tile left the view) is forgotten.
    property var _settle: null
    Timer {
        id: settleExpiry
        interval: 600
        onTriggered: grid._settle = null
    }

    // ---- The carried tile going into a group --------------------------------------------------------
    // Like an icon dropped on a folder: it flies to the target's centre,
    // shrinking to a mini and fading, on one fraction. The ghost stays alive
    // for it (its facts are kept until it lands).
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
    function _flyInto(cell) {
        const to = flick.contentItem.mapToItem(ghost.parent, cell.x + cell.w / 2 - grid.geo.tileW / 2, cell.y + cell.h / 2 - grid.geo.tileH / 2);
        grid._fly = {
            x0: ghost.x,
            y0: ghost.y,
            x1: to.x,
            y1: to.y,
            s0: ghost.scale,
            facts: grid._ghostFacts,
            minis: grid.minisOf(grid.dragKey),
            group: !!(grid._ghostFacts && grid._ghostFacts.isGroup)
        };
        grid.flyT = 0;
        flyAnim.restart();
    }

    function _cancelDrag() {
        grid._endDrag();
    }

    function _endDrag() {
        autoScroll.end();
        grid.dragKey = "";
        grid._dragOrder = null;
        grid._intent = null;
        if (!grid._fly)
            grid._ghostFacts = null;
        grid.refreshOrder();
        grid.relayout(true);
    }

    // The ghost: the carried tile, drawn in the overlay above everything.
    Loader {
        id: ghost
        objectName: "dragGhost"
        parent: grid.overlayItem || grid
        z: 500
        active: (grid.dragKey !== "" || grid._fly !== null) && grid._ghostFacts !== null
        readonly property point at: grid.dragKey !== "" ? flick.contentItem.mapToItem(ghost.parent, grid._pointer.x - grid._grabDX, grid._pointer.y - grid._grabDY) : Qt.point(0, 0)
        readonly property var fly: grid._fly
        x: ghost.fly ? ghost.fly.x0 + (ghost.fly.x1 - ghost.fly.x0) * grid.flyT : ghost.at.x
        y: ghost.fly ? ghost.fly.y0 + (ghost.fly.y1 - ghost.fly.y0) * grid.flyT : ghost.at.y
        width: grid.geo.tileW
        height: grid.geo.tileH
        property real shrink: grid._intentSerial >= 0 && grid._intent && grid._intent.intent === "group" ? 1 : 0
        Behavior on shrink {
            NumberAnimation {
                duration: 140
                easing.type: Easing.OutCubic
            }
        }
        // It rises when it is picked up (a fraction eased in, never a jump).
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
        sourceComponent: grid._ghostFacts && grid._ghostFacts.isGroup ? ghostGroup : ghostNote
        // The pose the tile had when it was picked up, still held by (1 - liftF).
        readonly property var pose: grid._liftPose
        readonly property real hold: 1 - ghost.liftF
        Component {
            id: ghostNote
            FloatCard {
                style: grid.floatStyle
                poseX: ghost.pose ? ghost.pose.x * ghost.hold : 0
                poseY: ghost.pose ? ghost.pose.y * ghost.hold : 0
                poseRot: ghost.pose ? ghost.pose.rot * ghost.hold : 0
                poseTiltX: ghost.pose ? ghost.pose.tiltX * ghost.hold : 0
                poseTiltY: ghost.pose ? ghost.pose.tiltY * ghost.hold : 0
                poseLift: ghost.pose ? ghost.pose.lift * ghost.hold : 0
                NoteTile {
                    anchors.fill: parent
                    entry: grid._ghostFacts
                    clock: grid.clock
                    liftF: ghost.liftF
                    hoverEnabled: false
                    fontFamily: grid.fontFamily
                }
            }
        }
        Component {
            id: ghostGroup
            FloatCard {
                style: grid.floatStyle
                poseX: ghost.pose ? ghost.pose.x * ghost.hold : 0
                poseY: ghost.pose ? ghost.pose.y * ghost.hold : 0
                poseRot: ghost.pose ? ghost.pose.rot * ghost.hold : 0
                poseTiltX: ghost.pose ? ghost.pose.tiltX * ghost.hold : 0
                poseTiltY: ghost.pose ? ghost.pose.tiltY * ghost.hold : 0
                poseLift: ghost.pose ? ghost.pose.lift * ghost.hold : 0
                GroupTile {
                    anchors.fill: parent
                    entry: grid._ghostFacts
                    minis: grid._fly ? grid._fly.minis : grid.minisOf(grid.dragKey)
                    lifted: true
                    hoverEnabled: false
                    fontFamily: grid.fontFamily
                }
            }
        }
    }

    // ---- Typing searches ---------------------------------------------------------------------------------
    Keys.onPressed: event => {
        const kill = EK.queryActionOf(event.key, event.modifiers);
        if (kill !== null) {
            grid.queryKilled(kill);
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Escape) {
            grid.escaped();
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right || event.key === Qt.Key_Up || event.key === Qt.Key_Down
                || event.key === Qt.Key_Home || event.key === Qt.Key_End || event.key === Qt.Key_PageUp || event.key === Qt.Key_PageDown) {
            if (!(event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) && grid.dragKey === "")
                grid._kbMove(event.key);
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            // The shown highlight, else the one result of a search.
            if (grid.kbShown && grid.order.indexOf(grid.kbKey) >= 0)
                grid.openKey(grid.kbKey);
            else if (grid.searching && grid.order.length === 1)
                grid.openKey(grid.order[0]);
            event.accepted = true;
            return;
        }
        if (event.key === Qt.Key_Backspace) {
            grid._kbHide();
            grid.backspaced();
            event.accepted = true;
            return;
        }
        if (event.text.length > 0 && event.text.charCodeAt(0) >= 32 && !(event.modifiers & Qt.ControlModifier)) {
            grid._kbHide();
            grid.typed(event.text);
            event.accepted = true;
        }
    }
}
