pragma ComponentBehavior: Bound

import QtQuick

import "../common/components"
import "data"

// =============================================================================
// WindowTrayOwner.qml -- the window title + tray module's long-lived half: what
// the strip and its popups show, and every rule about opening and closing them.
// The engine builds a popup's content on open and destroys it on close, so
// everything that must outlive a frame of that lives here: the hover state, the
// label's facts, every menu level's state and its two models.
//
// OPENING. The pointer resting on the title opens the strip, as it does a reel
// (`style.openOnHover`, the reels' open delay), and so does a click -- unless the
// tray is empty: then the title is inert. The strip hangs from the
// window icon's cell (`continuesBarCell`), and which SIDE its secondary takes
// is decided once, at the open, from the room towards the bar's end (a label
// at the end of a top bar would leave the screen; a side that changed while
// open would regrow instead of slide).
//
// THE REEL SLOT (feedback window+tray "Tray should be reel like popup type"). The strip is the engine's reel slot, the
// slot the power and idle reels' strips use (GooeyEngine: THE REEL SLOT, THE REEL'S CHAIN) -- not a reel, the popup type: it
// comes out OVER whatever popup is out and leaves it be (a hover that crosses the title no longer shuts the popup), and it is
// one slot with the reels, so from a reel's cell to the title (and back) the strip travels along the bar while it is still
// out ("if I am quick enough"), and folds and opens fresh when it has gone. Its label and menus are the slot's chain.
// NEVER INTERRUPTED, NEVER INTERRUPTING (the user: "I want one to never interupt the other"): while the idle reel's automatic
// cinematic plays (`reelBusy`, the host's) the strip waits and opens when it has ended, if the pointer is still there; while
// the strip is out the cinematic waits for it (ReelFollow) and plays once it has closed.
//
// CLOSING. Leaving the cell, the strip and every popup out of it -- the label, a
// menu and its submenus alike -- closes the strip after the reel's grace (the
// pointer crosses from one to the next through a frame where none has it); a
// menu being loaded holds it, an open one does NOT: it is the pointer's. A pick
// closes everything, as a native menu does; Escape closes the deepest level.
// There is NO click-anywhere-to-close (the strip opens on hover and already closes
// when the pointer goes off it): no void catcher, no focus grab, so a click elsewhere
// does nothing to the strip and the press is the window's under it.
//
// THE KEYS. Only while a menu is out does the strip ask for the keyboard (`keyboardFocusRequest`, the engine's `reelKeyboard`):
// the arrows, Enter and Left, and Escape -- which the engine hands the strip first while it holds the keys (GooeyEngine
// `pressEscape`), so a popup under it stays. The strip takes the focus from whatever had it (a field of the popup under it)
// and gives it back when its menus close or it goes.
//
// THE CHILD CHAIN. The hovered icon's NAME comes out beside the strip after
// `labelDelayMs` (the engine's secondary), then follows the pointer from icon
// to icon (the engine slides it: same key). A RIGHT click -- only the right
// button opens a menu -- loads the item's menu into level 0's hidden
// model and, once its rows have arrived, swaps the key: the label fades into
// the menu, the box growing from the edge both are anchored at, nothing
// translating (`secondaryAnchorAt`). A right click on that icon again
// takes the menu back into its label. A SUBMENU row opens the next level -- the
// engine's tertiary -- beside the row (a tertiary popup out of the
// menu, as the menu is out of the strip); clicking it again closes it, another
// submenu row swaps it. Escape and Left close the deepest level.
//
// THE FIRST ICON'S POPUP GROWS OUT OF THE CORNER: a label or menu laid
// against the bar face (flushGap) is anchored at that edge and opens from a
// point (`secondaryWidthFrom` 0) -- part of the bar and the strip from its first
// frame, never growing into the bar and melting with it.
//
// SIZES ARE FACTS. The label's size is the words' measured advance and line
// heights; a menu's is its rows' kinds. TraySide takes its size from here and
// the anchors are computed from the same numbers -- never from the box the
// engine writes back (CLAUDE.md: a content placing its secondary from the
// secondary's live size loops through the engine).
//
// TWO RATIOS (shell.jsonc `scale.bar` / `scale.popup`). The strip CONTINUES
// the bar's cell, so the engine hosts it in the BAR's units (GooeyBody.ratio); the label and the
// menus are the secondary and the tertiary, in the POPUP's. Every number in here is in the units
// of what it is about -- the strip's (a distance from the bar face, an anchor), a label's or a
// menu's -- and where one of the first is compared with one of the second (is a label's edge
// within flushGap of the face, do the label and the menu stand on the same edge) it is converted
// through `_k`, popup units per strip unit. At ratio 1 and 1 every conversion is the identity.
// The textures follow: the strip's icons are made at `stripScale` (the bar's device scale), the
// menus' rows at `renderScale` (the popup's).
// =============================================================================
Item {
    id: root

    visible: false

    property var engine: null
    property var bar: null
    property string barId: ""
    property string ownerId: "windowtray"
    property var window: null           // ActiveWindowService / ActiveWindowMock
    property var tray: null             // TrayService / TrayMock
    property var appLookup: null
    property var config: ({})           // WindowTrayConfig.config
    property WindowTrayStyle style: WindowTrayStyle {}
    property IconReelStyle reelStyle: IconReelStyle {}
    // Holds the strip open without the pointer (a render, a still).
    property bool pinnedOpen: false

    // THE SHELL HOSTS THIS OWNER (docs/contracts/shell.md section 4). Every rule
    // of that section already holds here, which is why the flag changes nothing
    // and exists for the host's symmetry with the owners it does change: every
    // service is injected (the owner builds only its own menu models), it
    // registers no shortcut, it WRITES no property of a service (a click on an
    // item is a call -- activate, scroll -- not a write), it connects to no
    // request signal of one and hosts no once-per-shell watcher. There is no scan
    // flag to share either: `sharedFlags` is empty.
    property bool shellHosted: false
    readonly property var sharedFlags: ({})

    // Set by the button, the strip and level 0 of the chain themselves.
    property var button: null
    property var strip: null
    property var sideItem: null

    // Device px per px of what a MENU or a label draws: a detail of this owner's, at its own ratio (`windowtray.detail`, else the
    // plain popup ratio -- never the ratio of whatever popup the strip lies over: engine.detailRenderScale)...
    readonly property real renderScale: root.engine ? root.engine.detailRenderScale(root.ownerId) : 1
    // ... and per px of the STRIP, which continues the bar's cell and is laid out in the bar's units (the engine's `barRenderScale`).
    readonly property real stripScale: root.engine ? root.engine.barRenderScale : 1
    // Frame px per strip unit and per label / menu unit, and popup units per strip unit (THE TWO RATIOS, above).
    readonly property real _bar: root.engine ? Math.max(0.01, root.engine.barRatio) : 1
    readonly property real _pop: root.engine ? Math.max(0.01, root.engine.detailRatio(root.ownerId)) : 1
    readonly property real _k: root._pop / root._bar
    // The strip is out and this owner's: the engine's reel slot (THE REEL SLOT, header), not thePopup -- the name is every
    // owner's ("is the popup mine"), the slot is the reels'.
    readonly property bool popupMine: !!root.engine && root.engine.reelOpen
        && root.engine.reelOwnerId === root.ownerId
    // Host-bound: the reel slot plays a motion that must not be cut (the idle reel's automatic cinematic: ReelFollow). An open asked
    // for meanwhile waits for it (`_openWaiting`) and happens when it has ended -- if the pointer is still on the title.
    property bool reelBusy: false
    // The title is inert while the session is locked (WindowTitleButton.locked): a strip that was out goes, as the power reel's does,
    // and none opens -- the lock's popup is the one thing up (it replaced the strip when the strip was thePopup; beside it now, it
    // would stay over the lock's popup).
    readonly property bool _locked: !!root.button && root.button.locked === true
    on_LockedChanged: {
        if (root._locked)
            root.close();
    }
    readonly property bool usable: !!root.tray && !root.tray.empty
    readonly property string edge: root.bar ? root.bar.edge : "top"

    // ---- level 0: the secondary (the label, or the item's menu) --------------------
    property bool sideOpen: false
    property string sideKey: "label"
    property point sideAnchor: Qt.point(0, 0)
    property real sideAnchorAt: 0.5
    property real sideOpenAt: 0.5
    property real sideWidthFrom: 0.5
    property string side: "end"
    property string sideItemKey: ""
    readonly property bool menuOpen: root.levelOpen[0] === true
    readonly property real menuWidth: root.style.menuWidth

    // The label: the record under it, read live (a status that changes while
    // it is out changes the words at once).
    readonly property var labelRec: root.tray && root.sideItemKey !== ""
        ? (root.tray.serial >= 0 ? root.tray.record(root.sideItemKey) : null) : null
    readonly property string labelName: root.labelRec ? root.labelRec.name : ""
    readonly property string labelStatus: root.labelRec ? root.labelRec.statusText : ""
    // The extent ALONG the strip is EVEN: the engine centres the label on its icon's middle, a whole pixel (the strip's
    // pitch and thickness are whole), so an odd extent (29 for one line) puts both edges, and the text in them, on half
    // pixels (CLAUDE.md: a box's edges must be whole pixels, not its centre). The nearest even number to padding + the
    // lines, as the idle reel's reason (ReelReason); the text takes the rounded middle (TraySide).
    readonly property real _labelTextW: Math.ceil(Math.max(nameMetrics.advanceWidth + 1,
        root.labelStatus !== "" ? statusMetrics.advanceWidth : 0)) + 2 * root.style.labelPadX
    readonly property real _labelTextH: 2 * root.style.labelPadY + nameLine.height
        + (root.labelStatus !== "" ? statusLine.height : 0)
    readonly property real labelW: root._alongIsY ? root._labelTextW : 2 * Math.ceil(root._labelTextW / 2)
    readonly property real labelH: root._alongIsY ? 2 * Math.round(root._labelTextH / 2) : Math.ceil(root._labelTextH)
    // Words laid from the strip's side, so a name that changes width while
    // the label slides stays against the strip.
    readonly property int labelAlign: root.edge === "left" || root.edge === "right" ? Text.AlignHCenter
        : root.side === "start" ? Text.AlignRight : Text.AlignLeft

    // In the bar instead of beside the strip (labelPlace "bar"): the hovered
    // item's name, which the button shows in place of the title.
    readonly property string hoverName: {
        if (root.style.labelPlace !== 1 || root.hoverKey === "" || !root.tray || !root.popupMine)
            return "";
        const r = root.tray.serial >= 0 ? root.tray.record(root.hoverKey) : null;
        return r ? r.name : "";
    }

    TextMetrics {
        id: nameMetrics
        font.family: root.style.titleFamily
        font.pixelSize: root.style.labelNameSize
        font.bold: true
        text: root.labelName
    }
    TextMetrics {
        id: statusMetrics
        font.family: root.style.titleFamily
        font.pixelSize: root.style.labelStatusSize
        text: root.labelStatus
    }
    FontMetrics {
        id: nameLine
        font.family: root.style.titleFamily
        font.pixelSize: root.style.labelNameSize
        font.bold: true
    }
    FontMetrics {
        id: statusLine
        font.family: root.style.titleFamily
        font.pixelSize: root.style.labelStatusSize
    }

    // ---- the menu levels ------------------------------------------------------------
    // Level 0 is the item's menu (the engine's secondary), level 1 a submenu (the
    // tertiary), level 2 a submenu of that: as many as the engine has child levels.
    // Each level has TWO models: the shown one keeps drawing while the next (another
    // item's menu, another submenu) loads into the other, and the key's `slot` says
    // which one a TraySide draws -- the engine assigns the key while it is faded out.
    readonly property int menuLevels: 3
    property var levelOpen: [false, false, false]
    property var levelKey: ["", "", ""]
    property var levelAnchor: [0, 0, 0]          // levels >= 1: y in the parent level's content
    property var levelSlot: [0, 0, 0]
    property var levelRow: [-1, -1, -1]          // levels >= 1: the parent row that opened it
    // Per level, per slot: { key (the item), title, status, handle }.
    property var levelInfo: [[{}, {}], [{}, {}], [{}, {}]]
    property var _pending: null                  // { level, slot, key, row, anchor }

    function _setAt(name, i, v) {
        const a = root[name].slice();
        a[i] = v;
        root[name] = a;
    }
    function _setInfo(level, slot, info) {
        const a = root.levelInfo.map(l => l.slice());
        a[level][slot] = info;
        root.levelInfo = a;
    }

    readonly property bool menuMock: !!root.tray && root.tray.mock === true
    TrayMenuModel {
        id: m00
        mock: root.menuMock
        loadTimeoutMs: root.style.menuLoadTimeoutMs
        onLoadedChanged: root._modelLoaded(0, 0)
    }
    TrayMenuModel {
        id: m01
        mock: root.menuMock
        loadTimeoutMs: root.style.menuLoadTimeoutMs
        onLoadedChanged: root._modelLoaded(0, 1)
    }
    TrayMenuModel {
        id: m10
        mock: root.menuMock
        loadTimeoutMs: root.style.menuLoadTimeoutMs
        onLoadedChanged: root._modelLoaded(1, 0)
    }
    TrayMenuModel {
        id: m11
        mock: root.menuMock
        loadTimeoutMs: root.style.menuLoadTimeoutMs
        onLoadedChanged: root._modelLoaded(1, 1)
    }
    TrayMenuModel {
        id: m20
        mock: root.menuMock
        loadTimeoutMs: root.style.menuLoadTimeoutMs
        onLoadedChanged: root._modelLoaded(2, 0)
    }
    TrayMenuModel {
        id: m21
        mock: root.menuMock
        loadTimeoutMs: root.style.menuLoadTimeoutMs
        onLoadedChanged: root._modelLoaded(2, 1)
    }
    readonly property var _models: [[m00, m01], [m10, m11], [m20, m21]]
    function menuModelOf(level, slot) {
        const l = root._models[Math.max(0, Math.min(root.menuLevels - 1, level))];
        return l[slot === 1 ? 1 : 0];
    }
    readonly property var _info0: root.levelInfo[0][root.levelSlot[0]] || ({})
    readonly property string menuTitle: root._info0.title || ""
    readonly property string menuStatus: root._info0.status || ""

    // A menu's height from its rows' kinds (MenuRows' own: a separator row is 9 px,
    // every other row rowHeight), plus, at level 0, the head and its rule.
    function menuHeightOf(level, slot) {
        const st = root.style;
        const m = root.menuModelOf(level, slot);
        let rowsH = 0;
        const n = m.rows ? m.rows.count : 0;
        for (let i = 0; i < n; i++) {
            const rec = m.rows.get(i).rec;
            rowsH += rec && rec.d && rec.d.separator ? 9 : st.menuRowHeight;
        }
        if (n === 0)
            rowsH = st.menuRowHeight;
        const natural = Math.ceil(2 * st.menuPad + (level === 0 ? st.menuHeadHeight + 9 : 0) + rowsH);
        return Math.min(natural, root.menuMaxHeight);
    }
    // The most a menu may be: the style's cap, and never more than the screen
    // between two bars' worth of edge (the rest scrolls).
    // (A menu's units are the popup's; the screen, and the two bars it lies between, are in frame px.)
    readonly property real menuMaxHeight: Math.max(root.style.menuRowHeight * 4,
        Math.min(root.style.menuMaxHeight, ((root.engine ? root.engine.height : 800) - 2 * root.reelStyle.thickness * root._bar - 24 * root._pop) / root._pop))
    // Where row `i` starts inside a level's scrolled rows (separators are 9 px).
    function menuRowTop(level, slot, i) {
        const m = root.menuModelOf(level, slot);
        let y = 0;
        for (let k = 0; k < i && k < m.rows.count; k++) {
            const rec = m.rows.get(k).rec;
            y += rec && rec.d && rec.d.separator ? 9 : root.style.menuRowHeight;
        }
        return y;
    }

    // ---- hover ---------------------------------------------------------------------
    property string hoverKey: ""
    property int hoverIndex: -1
    readonly property bool _buttonHovered: !!root.button && root.button.hovered
    readonly property bool _stripHovered: !!root.strip && root.strip.hovered
    // Every level of the chain reports its own hover (a bit each).
    property int _sideHoverMask: 0
    readonly property bool _sideHovered: root._sideHoverMask !== 0
    function setSideHover(level, on) {
        const bit = 1 << Math.max(0, level);
        const m = on ? (root._sideHoverMask | bit) : (root._sideHoverMask & ~bit);
        if (m !== root._sideHoverMask)
            root._sideHoverMask = m;
    }
    readonly property bool wantOpen: root.pinnedOpen || root._buttonHovered || root._stripHovered
        || root._sideHovered || root._pending !== null

    onWantOpenChanged: root._leaveCheck()
    onPopupMineChanged: {
        if (!root.popupMine)
            root._reset();
        root._leaveCheck();
    }
    function _leaveCheck() {
        if (root.popupMine && !root.wantOpen && root.style.closeOnLeave)
            closeTimer.restart();
        else
            closeTimer.stop();
    }
    Timer {
        id: closeTimer
        interval: root.reelStyle.closeGraceMs
        onTriggered: {
            if (!root.wantOpen)
                root.close();
        }
    }

    function cellHover(key, index, on) {
        if (on) {
            root.hoverIndex = index;
            root.hoverKey = key;
        } else if (root.hoverKey === key) {
            root.hoverKey = "";
            root.hoverIndex = -1;
        }
    }
    onHoverKeyChanged: {
        if (root.menuOpen || root._pending !== null || !root.popupMine || root.style.labelPlace === 1)
            return;
        if (root.hoverKey !== "") {
            labelCloseTimer.stop();
            if (root.sideOpen && root.sideKey === "label")
                root._showLabel(root.hoverKey);
            else
                labelTimer.restart();
        } else {
            labelTimer.stop();
            if (root.sideOpen && root.sideKey === "label")
                labelCloseTimer.restart();
        }
    }
    on_SideHoveredChanged: {
        if (!root._sideHovered && !root.menuOpen && root.hoverKey === "" && root.sideOpen)
            labelCloseTimer.restart();
    }
    Timer {
        id: labelTimer
        interval: root.style.labelDelayMs
        onTriggered: {
            if (root.hoverKey !== "" && !root.menuOpen && root._pending === null)
                root._showLabel(root.hoverKey);
        }
    }
    Timer {
        id: labelCloseTimer
        interval: root.style.labelGraceMs
        onTriggered: {
            if (!root.menuOpen && root._pending === null && root.hoverKey === "" && !root._sideHovered)
                root.sideOpen = false;
        }
    }

    // ---- placement ----------------------------------------------------------------
    function rowIndexOf(key) {
        const rows = root.tray ? root.tray.rows : null;
        if (!rows)
            return -1;
        for (let i = 0; i < rows.count; i++) {
            const r = rows.get(i).rec;
            if (r && r.key === key)
                return i;
        }
        return -1;
    }
    readonly property bool _alongIsY: root.edge === "top" || root.edge === "bottom"
    // Which end of a box beside the strip faces the bar (0 its start, 1 its end,
    // in screen order along the strip): the top beside a strip from a top bar,
    // the bottom from a bottom bar, the left below a strip from a left bar.
    readonly property real _faceAt: root.edge === "top" || root.edge === "left" ? 0 : 1
    // Beside a strip hanging from a top or bottom bar a box is centred on the
    // icon's height; below or above a strip out of a side bar, on its x. A box
    // that would come within flushGap of the bar face lies against it instead (a
    // few px of wallpaper between them read as a sliver) -- and then grows out of
    // the corner of bar and strip.
    // The label of icon i: { near (its face-side edge's distance from the face),
    // flush, centre }, in the STRIP's units (what `strip.at` takes): the label's extent is in the
    // popup's, so it is converted, and flushGap -- a number of the labels' and menus' -- with it.
    function _labelPlace(i) {
        const d = root.strip.centreOf(i);
        const extent = (root._alongIsY ? root.labelH : root.labelW) * root._k;
        const near = d - extent / 2;
        return near < root.style.flushGap * root._k ? { near: 0, flush: true, centre: extent / 2 }
                                                     : { near: near, flush: false, centre: d };
    }
    function _placeLabel(i) {
        const p = root._labelPlace(i);
        // Centred on its icon (it opens about it); flush, anchored at the face
        // and opened from a point there.
        root.sideAnchorAt = p.flush ? root._faceAt : 0.5;
        root.sideOpenAt = root.sideAnchorAt;
        root.sideWidthFrom = p.flush ? 0 : (root.engine ? root.engine.childWidthFrom : 0.5);
        root.sideAnchor = root.strip.at(p.flush ? 0 : p.centre);
    }
    // The item's menu: anchored at the edge the label has (or would have) on
    // the face's side, so the label grows into it from there and nothing slides.
    // Opened fresh (no label out), it opens about its own centre -- out of the
    // corner when it lies against the face.
    function _placeMenu(i) {
        const p = root._labelPlace(i);
        root.sideAnchorAt = root._faceAt;
        root.sideOpenAt = p.flush ? root._faceAt : 0.5;
        if (!(root.sideOpen && root.sideKey === "label" && root.sideItemKey === root.rowKeyAt(i)))
            root.sideWidthFrom = p.flush ? 0 : (root.engine ? root.engine.childWidthFrom : 0.5);
        root.sideAnchor = root.strip.at(p.near);
    }
    function rowKeyAt(i) {
        const rows = root.tray ? root.tray.rows : null;
        return rows && i >= 0 && i < rows.count ? rows.get(i).rec.key : "";
    }
    // The side with room for a menu, decided when the strip opens: "end" is
    // right of a strip from a top/bottom bar, below one from a side bar.
    function _chooseSide() {
        const cell = root.button ? root.button.iconCell : null;
        if (!cell || !root.engine)
            return "end";
        // (frame px: the strip's half width is a strip distance, the room a menu needs is a menu's)
        const p = cell.mapToItem(root.engine, cell.width / 2, cell.height / 2);
        const half = root.reelStyle.thickness / 2 * root._bar;
        const across = root._alongIsY;
        const roomEnd = across ? root.engine.width - (p.x + half) : root.engine.height - (p.y + half);
        const roomStart = across ? p.x - half : p.y - half;
        return roomEnd >= root.style.sideRoom * root._pop || roomEnd >= roomStart ? "end" : "start";
    }
    // Where a submenu comes out of its menu: on the menu's far side from the
    // strip -- the same screen direction the menu took.
    readonly property string subSide: root._alongIsY ? (root.side === "end" ? "right" : "left")
                                                      : (root.edge === "left" ? "right" : "left")

    // ---- the label ----------------------------------------------------------------
    function _showLabel(key) {
        const i = root.rowIndexOf(key);
        if (i < 0 || !root.strip)
            return;
        root.sideItemKey = key;
        root._placeLabel(i);
        root.sideKey = "label";
        root.sideOpen = true;
    }

    // ---- the menus ----------------------------------------------------------------
    function openMenu(key) {
        const rec = root.tray ? root.tray.record(key) : null;
        if (!rec || !rec.hasMenu || !root.popupMine)
            return;
        labelTimer.stop();
        labelCloseTimer.stop();
        root._closeLevels(1);
        root._load(0, key, root.tray.menuHandle(key), { title: rec.name, status: rec.statusText });
    }
    function _load(level, key, handle, extra) {
        if (!handle)
            return;
        // Always the model that is NOT shown: the shown one keeps drawing until
        // the engine has faded it out.
        const slot = 1 - root.levelSlot[level];
        releaseTimer.stop();
        root._setInfo(level, slot, { key: key, title: extra.title || "", status: extra.status || "", handle: handle });
        root._pending = { level: level, slot: slot, key: key, row: extra.row === undefined ? -1 : extra.row,
                           anchor: extra.anchor || 0 };
        const m = root.menuModelOf(level, slot);
        // A submenu's way back to its entry when the app rebuilds its menu and destroys this one (TrayMenuModel "A LEVEL WHOSE ENTRY IS
        // REPLACED"): the parent level's row of the same label. The item's own menu (level 0) outlives such a rebuild.
        m.successor = extra.parent ? root._successorOf(extra.parent.level, extra.parent.slot, extra.title || "") : null;
        m.handle = handle;
        if (m.loaded)
            root._commit();
    }
    function _successorOf(parentLevel, parentSlot, label) {
        return function () {
            const pm = root.menuModelOf(parentLevel, parentSlot);
            for (let i = 0; i < pm.rows.count; i++) {
                const d = pm.rows.get(i).rec.d;
                if (d && d.submenu && d.label === label)
                    return pm.childHandle(i);
            }
            return null;
        };
    }
    function _modelLoaded(level, slot) {
        const p = root._pending;
        if (p !== null && p.level === level && p.slot === slot && root.menuModelOf(level, slot).loaded)
            root._commit();
    }
    function _commit() {
        const p = root._pending;
        root._pending = null;
        if (!p || !root.popupMine)
            return;
        const key = "menu:" + p.key + ":" + p.level + ":" + p.slot;
        if (p.level === 0) {
            const i = root.rowIndexOf(p.key);
            if (i < 0)
                return;
            root._placeMenu(i);
            root.sideItemKey = p.key;
            root._setAt("levelSlot", 0, p.slot);
            root._setAt("levelOpen", 0, true);
            root.sideKey = key;
            root.sideOpen = true;
        } else {
            root._setAt("levelSlot", p.level, p.slot);
            root._setAt("levelRow", p.level, p.row);
            root._setAt("levelAnchor", p.level, p.anchor);
            root._setAt("levelKey", p.level, key);
            root._setAt("levelOpen", p.level, true);
        }
        root.keyLevel = p.level;
        root.keyIndex = -1;
        // The keys go to the strip (Escape, the arrows, Enter): it asks the
        // engine for the keyboard while a menu is out, and takes the focus -- from whatever had it, which gets it back (_giveFocusBack).
        if (root.strip) {
            const w = root.strip.Window.window;
            const had = w ? w.activeFocusItem : null;
            if (had && had !== root.strip && root._focusBefore === null && !root._inStrip(had))
                root._focusBefore = had;
            root.strip.forceActiveFocus();
        }
        // The other model of that level keeps its rows until the swap has faded them.
        releaseTimer.restart();
    }
    // A pick in a menu (TraySide, at `level`): a submenu row opens the level
    // below beside it (again: closes it; another: swaps it), anything else is
    // triggered -- once: the model answers once per open -- and everything closes.
    function menuPick(level, slot, index, row, rowY) {
        if (slot !== root.levelSlot[level] || !root.levelOpen[level] || root._pending !== null
                || !row || row.disabled || row.separator)
            return;
        if (row.submenu) {
            const sub = level + 1;
            if (sub >= root.menuLevels)
                return;
            if (root.levelOpen[sub] && root.levelRow[sub] === index) {
                root._closeLevels(sub);
                return;
            }
            const h = root.menuModelOf(level, slot).childHandle(index);
            if (!h)
                return;
            root._closeLevels(sub + 1);
            const info = root.levelInfo[level][slot] || {};
            root._load(sub, info.key, h, { title: row.label || "", row: index, parent: { level: level, slot: slot },
                                           anchor: rowY - root.style.menuPad });
            return;
        }
        if (root.menuModelOf(level, slot).trigger(index))
            root.close();
    }
    // Close every level from `from` down (the engine closes a level's own levels
    // with it; this keeps the owner's state in step).
    function _closeLevels(from) {
        for (let l = Math.max(0, from); l < root.menuLevels; l++)
            if (root.levelOpen[l])
                root._setAt("levelOpen", l, false);
        if (root._pending !== null && root._pending.level >= from)
            root._pending = null;
        if (root.keyLevel >= from) {
            root.keyLevel = Math.max(0, from - 1);
            root.keyIndex = -1;
        }
        releaseTimer.restart();
    }
    // The menu back into the label of the same item (a right click on its icon
    // again): the same secondary, the key swapped back, the box shrinking to the
    // label's size from the edge it is anchored at.
    function menuToLabel(key) {
        root._closeLevels(0);
        root._showLabel(key);
    }
    function closeMenu() {
        root._closeLevels(0);
        root.sideOpen = false;
    }
    // A model's handle is let go (the app hears the menu close) only once the
    // engine has faded what it drew: a model emptied under a fading box would
    // resize it on its way out. A level's shown model is never let go while that
    // level is out -- a submenu's entries are its parent menu's: let go, the
    // submenu would empty at rest.
    Timer {
        id: releaseTimer
        interval: (root.engine ? root.engine.childMs : 400) + 120
        onTriggered: {
            for (let l = 0; l < root.menuLevels; l++)
                for (const s of [0, 1]) {
                    if (root.levelOpen[l] && s === root.levelSlot[l])
                        continue;
                    if (root._pending !== null && root._pending.level === l && root._pending.slot === s)
                        continue;
                    root.menuModelOf(l, s).handle = null;
                }
        }
    }

    // ---- the keyboard (while a menu is out): the deepest open level ------------------
    property int keyLevel: 0
    property int keyIndex: -1
    function _rowAt(level, i) {
        const m = root.menuModelOf(level, root.levelSlot[level]);
        return m.rows && i >= 0 && i < m.rows.count ? m.rows.get(i).rec.d : null;
    }
    function _pickable(level, i) {
        const d = root._rowAt(level, i);
        return !!d && !d.separator && !d.disabled;
    }
    function _step(level, dir) {
        const m = root.menuModelOf(level, root.levelSlot[level]);
        const n = m.rows ? m.rows.count : 0;
        let i = root.keyIndex;
        for (let t = 0; t < n; t++) {
            i = i < 0 ? (dir > 0 ? 0 : n - 1) : (i + dir + n) % n;
            if (root._pickable(level, i))
                return i;
        }
        return -1;
    }
    function handleKey(event) {
        if (!root.popupMine)
            return false;
        const k = event.key;
        const L = root.keyLevel;
        if (k === Qt.Key_Escape)
            return root.handleEscape();
        if (!root.menuOpen)
            return false;
        if (k === Qt.Key_Down || k === Qt.Key_Up) {
            root.keyIndex = root._step(L, k === Qt.Key_Down ? 1 : -1);
            return true;
        }
        if (k === Qt.Key_Left) {
            if (L > 0)
                root._closeLevels(L);
            return true;
        }
        if (k === Qt.Key_Return || k === Qt.Key_Enter || k === Qt.Key_Right) {
            if (root._pickable(L, root.keyIndex)) {
                const d = root._rowAt(L, root.keyIndex);
                if (k !== Qt.Key_Right || d.submenu)
                    root.menuPick(L, root.levelSlot[L], root.keyIndex, d, root._keyRowY(L, root.keyIndex));
            }
            return true;
        }
        return false;
    }
    // Escape (the key itself, or the shell's Escape bind through the engine's `pressEscape`): the deepest level, then the menu,
    // then the strip.
    function handleEscape(): bool {
        if (!root.popupMine)
            return false;
        if (root.menuOpen && root.keyLevel > 0)
            root._closeLevels(root.keyLevel);
        else if (root.menuOpen)
            root.closeMenu();
        else
            root.close();
        return true;
    }
    // A keyed row's y in its level's content (the submenu it opens is placed by
    // it): the head at level 0, the pad, the rows above it (no scroll: the
    // content scrolls the keyed row into view itself).
    function _keyRowY(level, i) {
        const st = root.style;
        return st.menuPad + (level === 0 ? st.menuHeadHeight + 9 : 0)
            + root.menuRowTop(level, root.levelSlot[level], i);
    }

    // ---- the focus the strip took (THE KEYS, header) -----------------------------------
    // What had the focus when a menu took it (a field of the popup under the strip): an Item property, null once it is destroyed.
    property Item _focusBefore: null
    function _inStrip(it) {
        for (let p = it; p; p = p.parent)
            if (p === root.strip)
                return true;
        return false;
    }
    // The menus closed, or the strip went: the focus goes back where it was, if that is still on screen.
    function _giveFocusBack() {
        const it = root._focusBefore;
        root._focusBefore = null;
        if (it && it.visible)
            it.forceActiveFocus();
    }
    onMenuOpenChanged: {
        if (!root.menuOpen)
            root._giveFocusBack();
    }

    // ---- the cells' input ---------------------------------------------------------
    // The RIGHT button opens an item's menu, and only it (a left-click
    // menu, nm-applet's ayatana convention, reads as a bug). A
    // right click on the icon whose menu is out takes the menu back into its
    // label: the pointer is still on that icon. The LEFT button activates an
    // item that can be activated, and does nothing on one that cannot.
    function cellClicked(key, button) {
        const rec = root.tray ? root.tray.record(key) : null;
        if (!rec)
            return;
        if (button === Qt.RightButton) {
            if (root.menuOpen && root.sideItemKey === key)
                root.menuToLabel(key);
            else if (rec.hasMenu)
                root.openMenu(key);
            return;
        }
        if (button === Qt.MiddleButton) {
            root.tray.middleClick(key);
            return;
        }
        if (root.tray.leftClick(key) && root.style.closeOnActivate)
            root.close();
    }
    // A peeking icon in the bar. Left: the item's own activation -- or, for an
    // item that cannot be activated, the strip with that item's name out (so a
    // click on it is never a click that does nothing). Right: the strip and its
    // menu.
    property var _afterOpen: null           // { key, menu } for the strip that is opening
    function peekClicked(key, button) {
        const rec = root.tray ? root.tray.record(key) : null;
        if (!rec)
            return;
        const menu = button === Qt.RightButton && rec.hasMenu;
        if (!menu && rec.canActivate) {
            root.tray.leftClick(key);
            return;
        }
        if (root.popupMine && root.strip) {
            root._afterOpenRun({ key: key, menu: menu });
            return;
        }
        root._afterOpen = { key: key, menu: menu };
        root.open();
    }
    function _afterOpenRun(a) {
        if (a.menu)
            root.openMenu(a.key);
        else
            root._showLabel(a.key);
    }
    onStripChanged: {
        if (!root.strip)
            root._giveFocusBack();
        if (root.strip && root._afterOpen !== null) {
            const a = root._afterOpen;
            root._afterOpen = null;
            Qt.callLater(() => root._afterOpenRun(a));
        }
    }
    function cellWheel(key, wheel) {
        const dy = wheel.angleDelta.y, dx = wheel.angleDelta.x;
        const horizontal = dy === 0 && dx !== 0;
        const delta = horizontal ? dx : dy;
        if (delta !== 0 && root.tray)
            root.tray.scroll(key, delta, horizontal);
    }
    Connections {
        target: root.tray
        ignoreUnknownSignals: true
        function onEmptyChanged() {
            if (root.tray.empty)
                root.close();
        }
        function onSerialChanged() {
            // An item gone under its label or menu takes them along; one that
            // moved keeps them at its icon.
            if ((!root.sideOpen && root._pending === null) || !root.strip)
                return;
            const i = root.rowIndexOf(root.sideItemKey);
            if (i < 0) {
                root.closeMenu();
                return;
            }
            if (root.menuOpen)
                root._placeMenu(i);
            else
                root._placeLabel(i);
        }
    }

    // ---- open / close --------------------------------------------------------------
    // OPEN ON HOVER (style.openOnHover): the pointer resting on the title's cell for the reels' openDelayMs opens the strip, and the leave
    // rule above (the reels' closeGraceMs) closes it. It opens in the reel slot, over whatever popup is out (THE REEL SLOT, header). It
    // takes no focus grab and asks for no click outside: hovering a bar must not take the keys from the window being typed in, and the
    // pointer leaving is what closes it.
    on_ButtonHoveredChanged: {
        if (root._buttonHovered && root.style.openOnHover && !root.popupMine && root.usable)
            hoverOpenTimer.restart();
        else
            hoverOpenTimer.stop();
        // an open that waited for the cinematic is for a pointer that is still here
        if (!root._buttonHovered && !root.pinnedOpen)
            root._openWaiting = false;
    }
    Timer {
        id: hoverOpenTimer
        interval: root.reelStyle.openDelayMs
        onTriggered: {
            if (!root._buttonHovered || root.popupMine || !root.style.openOnHover)
                return;
            root.open();
        }
    }
    // A click on the title: opens the strip. On an open one it does nothing while the hover opens it (the click that follows the hover is
    // the user's "yes", not a toggle: the pointer leaving closes it); with the hover or the leave rule off it closes it.
    function toggle() {
        if (!root.popupMine)
            root.open();
        else if (!root.style.openOnHover || !root.style.closeOnLeave)
            root.close();
    }
    function open() {
        if (!root.engine || !root.bar || !root.button || root.popupMine || !root.usable || root._locked)
            return;
        // NEVER INTERRUPTING (header): the reel slot's cinematic first; the open waits for it.
        if (root.reelBusy) {
            root._openWaiting = true;
            return;
        }
        root._openWaiting = false;
        const cell = root.button.iconCell;
        // Read at the open, never bound: a mapToItem in a binding does not
        // follow the layout that moved it (ReelBarModule).
        const centre = cell.mapToItem(root.bar, cell.width / 2, cell.height / 2).x;
        root._reset();
        root.side = root._chooseSide();
        root.engine.openReel(root.ownerId, root.barId, centre, null, null, stripComp, root.reelStyle.popupWidthFrom);
    }
    function close() {
        closeTimer.stop();
        root._openWaiting = false;
        if (root.engine && root.popupMine)
            root.engine.closeReel();
    }
    // An open that waits for the reel slot's cinematic: it happens when that has ended, while the pointer still asks for it (on the
    // title, or held) -- a pointer that left meanwhile asked for nothing.
    property bool _openWaiting: false
    onReelBusyChanged: {
        if (root.reelBusy || !root._openWaiting)
            return;
        root._openWaiting = false;
        if (root._buttonHovered || root.pinnedOpen)
            root.open();
    }
    function _reset() {
        labelTimer.stop();
        labelCloseTimer.stop();
        root._closeLevels(0);
        root.sideOpen = false;
        root.sideKey = "label";
        root.sideItemKey = "";
        root.hoverKey = "";
        root.hoverIndex = -1;
        root._sideHoverMask = 0;
        root._afterOpen = root.popupMine ? null : root._afterOpen;
    }

    Component {
        id: stripComp
        TrayStrip {
            owner: root
            tray: root.tray
            style: root.style
            reelStyle: root.reelStyle
            edge: root.edge
            renderScale: root.stripScale
        }
    }
    readonly property Component sideComponent: Component {
        TraySide {
            owner: root
            style: root.style
        }
    }
}
