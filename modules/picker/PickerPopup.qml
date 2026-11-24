pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/EditKeys.js" as EK
import "data/PickerModel.js" as Model

// =============================================================================
// PickerPopup.qml -- the emoji / symbol / Nerd Fonts picker, a drop-in for thePopup.
//
// Holds nothing that must outlive it: the service (PickerService: the data, the memory, the paste) and the style live bar-side
// (PickerBarOwner); this is built on every open and talks ONLY to the service's surface.
//
// HOST CONTRACT (GooeyEngine; docs/contracts/gooey_engine.md) -- the clipboard shelf's, member for member:
//   implicitWidth/Height   the grid's cells and the padding (12 all round): the popup never resizes through a tab, a search or a
//                          section, so there is nothing to ease; clamped to the host room's span
//   keyboardFocusRequest   "exclusive": opened by a key, the keyboard is the popup's from the first key -- unless the host's focus
//                          grab holds it (`grabbed`): then "none", the grab is the keyboard AND the dismissal
//   hostRoom               assigned by the host
//   closeRequested()       a pick (the service pastes once the popup has let go of the keyboard), or Escape at the end of its chain
//   handleEscape()         the whole Escape chain as one call, returning true (what the shell's Escape bind asks of the primary)
//   freshen()              a reopen that finds this content still closing: every open starts fresh
//
// THREE TABS, ONE SEARCH. Emoji, Symbols (alt codes, math, arrows, currency, Greek, kaomoji) and Nerd (the icons of the installed Nerd
// Font, by name: "lightbulb on" finds nf-md-lightbulb_on; a category bar per icon set). The query is matched against ALL of them (names
// and keywords); the grid shows the active tab's hits and each tab's label says how many it holds, so a search that finds nothing here
// says where it found something (Tab). On Symbols a query of only digits is an ALT CODE: the grid shows the codes that start with it
// and the exact one first and highlighted ("233" is the theta, Alt+233; "0233" is the e acute, Alt+0233).
// THE NERD TAB's list is fetched for the installed font's version (PickerService.ensureNerd, the first time the tab is shown): until it is
// there the page says so, and when it cannot be (offline, no Nerd Font) it says why in one line and that coming back to the tab retries; the other tabs never wait for it.
// On the Nerd tab Enter / a click pastes the GLYPH and Ctrl+Enter / Ctrl+click the NAME (`nf-md-lightbulb_on`; `nerdPick: "name"` is the other
// way round); the foot shows the name of the highlighted icon.
// `tabList` says which of the three there are and in which order (one alone has no selector), `openTab` the one every open starts on ("last":
// the service's `lastTab`), `recents` whether a Recent row stands above the list.
//
// A PICK pastes into the window the popup was opened over. Enter or a click picks the highlighted cell (and anything in the TRAY);
// Shift+Enter / Shift+click puts a cell in the tray without closing. The tray is pasted JOINED by the one pick that closes the
// popup: the popup holds the keyboard, so a key can only be sent after it lets go, and one paste into the window the service
// verified is still the active one cannot land anywhere else -- a paste per pick would need the keyboard released and taken back
// between picks, and the second one would go to whatever has the focus by then.
//
// KEYS (all handled on the popup's own focus, so typing always searches):
//   type / Backspace            the search (Backspace on an empty query takes the tray's last pick back)
//   arrows Home End PgUp PgDn   move the highlight (left / right walk across sections)
//   Ctrl+Left / Ctrl+Right      the previous / next category
//   Tab / Shift+Tab             the other tab
//   Enter / Shift+Enter         pick (with the tray) / add to the tray
//   Ctrl+Enter / Ctrl+Shift+Enter   the same, as the icon's NAME (the Nerd tab only)
//   Ctrl+T / Menu / right-click the skin-tone popover (Left Right Enter Esc inside it)
//   Delete                      on a highlighted Recent tile: forget that one (nowhere else, and never while a query is typed)
//   Esc                         the popover, then the query, then the tray, then closes
//
// Content paints no background; the host's surface is the ground.
// =============================================================================
FocusScope {
    id: popup

    property var service: null
    property PickerStyle style: null
    property var hostRoom: null
    property string fontFamily: "Inter"
    // The popup is opened by a key: the keyboard is its at once.
    property bool grabbed: false
    property var tabList: ["emoji", "symbols", "nerd"]
    property string openTab: "emoji"
    property string nerdPick: "glyph"
    property bool recents: true
    readonly property string keyboardFocusRequest: popup.grabbed ? "none" : "exclusive"

    signal closeRequested
    signal contentGone

    // ---- Numbers ------------------------------------------------------------------
    readonly property real pad: 12
    readonly property real _boxPad: popup.style ? popup.style.boxPad : 6
    readonly property real _wantW: popup.style ? Math.round(popup.style.emojiCols * popup.style.emojiCell + 2 * popup._boxPad + 2 * popup.pad) : 564
    readonly property real _roomSpan: popup.hostRoom && popup.hostRoom.hi !== undefined && popup.hostRoom.lo !== undefined ? popup.hostRoom.hi - popup.hostRoom.lo : 0
    readonly property real layoutWidth: Math.round(popup._roomSpan > 0 ? Math.min(popup._wantW, popup._roomSpan) : popup._wantW)
    readonly property real _gridW: popup.layoutWidth - 2 * popup.pad
    readonly property real _gridH: popup.style ? popup.style.gridHeight : 276
    implicitWidth: popup.layoutWidth
    implicitHeight: Math.round(4 * popup.pad + header.implicitHeight + popup._gridH + foot.implicitHeight)

    // ---- State ----------------------------------------------------------------------
    property string tab: popup.tabIds[0]
    readonly property var tabIds: {
        const t = popup.tabList.filter((x, i, a) => a.indexOf(x) === i);
        return t.length > 0 ? t : ["emoji", "symbols", "nerd"];
    }
    property string query: ""
    property int currentIndex: 0
    // The tray: items, in pick order.
    property var tray: []
    property bool toneOpen: false
    // THE UNDO of the last Clear: { tab, saved } (what PickerService.clearRecents took out). It lives as long as this content: the button
    // drains for `undoMs`, a tab change or a close ends it, and what it held is then gone for good.
    property var _undo: null
    property string _toneBase: ""
    property bool _focusFirst: true

    readonly property var idx: popup.service ? popup.service.index : null
    // The Nerd Fonts list (PickerService.nerdIndex): null until the tab has been shown and the list is there.
    readonly property var nidx: popup.service ? popup.service.nerdIndex : null
    readonly property string nerdState: popup.service ? popup.service.nerdState : "idle"
    readonly property bool ready: popup.idx !== null
    readonly property int tone: popup.service ? popup.service.tone : 0
    readonly property string digits: Model.digitsOf(popup.query)
    readonly property bool searching: popup.query.trim() !== ""

    // ---- Search: BOTH tabs, every keystroke ----------------------------------------------------
    // Emoji hits: a ranked list. Symbol hits: sections per set (a set's tiles are its own profile), or the alt codes a digit query
    // asks for.
    readonly property var _emojiHits: popup.idx && popup.searching ? Model.dedupe(Model.search(popup.idx.emoji, popup.query)) : []
    readonly property var _symbolSections: {
        const ix = popup.idx;
        if (!ix || !popup.searching)
            return [];
        if (popup.digits !== "") {
            const alt = Model.altMatches(ix.sets[0].items, popup.digits);
            return alt.length > 0 ? [{ id: "alt", label: "Alt code " + popup.digits, profile: "alt", items: alt }] : [];
        }
        const out = [];
        for (let s = 0; s < ix.sets.length; s++) {
            const hits = Model.search(ix.sets[s].items, popup.query);
            if (hits.length > 0)
                out.push({ id: ix.sets[s].id, label: ix.sets[s].label, profile: popup._profileOf(ix.sets[s].tile), items: hits });
        }
        return out;
    }
    // Nerd hits: one section per icon set. Once the list is there it is searched on every keystroke whatever the tab (the label counts): ~10 ms.
    readonly property var _nerdHits: popup.nidx && popup.searching ? Model.searchNerd(popup.nidx.items, popup.query, 3) : []
    readonly property var _nerdSections: popup.nidx && popup.searching ? Model.groupBySet(popup.nidx.sets, popup._nerdHits) : []
    readonly property int _nerdCount: popup._nerdHits.length
    readonly property int _emojiCount: popup._emojiHits.length
    readonly property int _symbolCount: popup._symbolSections.reduce((n, s) => n + s.items.length, 0)
    // The alt codes' text of the same digits typed on the Emoji tab are plain words: the keywords hold no codes there.

    function _profileOf(tile) {
        return tile === "alt" ? "alt" : tile === "wide" ? "wide" : "symbol";
    }
    function _nameOf(tab) {
        return tab === "emoji" ? "Emoji" : tab === "symbols" ? "Symbols" : "Nerd";
    }
    function _countOf(tab) {
        return tab === "emoji" ? popup._emojiCount : tab === "symbols" ? popup._symbolCount : popup._nerdCount;
    }
    // The hits of another tab, as words for the empty page: "12 in Symbols, 3 in Nerd (Tab)".
    function _elsewhere() {
        const parts = popup.tabIds.filter(x => x !== popup.tab && popup._countOf(x) > 0).map(x => popup._countOf(x) + " in " + popup._nameOf(x));
        return parts.length > 0 ? "\n" + parts.join(", ") + " (Tab)" : "";
    }
    function _colsOf(profile) {
        const st = popup.style;
        if (!st)
            return 1;
        const inner = popup._gridW - 2 * popup._boxPad;
        const minW = profile === "emoji" ? st.emojiCell : profile === "alt" ? st.altCellW : profile === "wide" ? st.wideCellW : profile === "nerd" ? st.nerdCell : st.symbolCell;
        return Math.max(1, Math.floor(inner / minW));
    }

    // The sections the grid shows.
    readonly property var sections: {
        const ix = popup.idx;
        const st = popup.style;
        if (!ix || !st)
            return [];
        if (popup.tab === "nerd") {
            const nx = popup.nidx;
            if (!nx)
                return [];
            if (popup.searching)
                return popup._nerdSections;
            const nrec = popup.recents ? popup.service.recentsOf("nerd", st.recentRows * popup._colsOf("nerd")) : [];
            const nout = nrec.length > 0 ? [{ id: "recent", label: "Recent", profile: "nerd", items: nrec }] : [];
            for (let s = 0; s < nx.sets.length; s++)
                nout.push({ id: nx.sets[s].id, label: nx.sets[s].label, profile: "nerd", items: nx.sets[s].items });
            return nout;
        }
        if (popup.searching)
            return popup.tab === "emoji" ? [{ id: "hits", label: "", profile: "emoji", items: popup._emojiHits }] : popup._symbolSections;
        const out = [];
        const rc = st.recentRows * popup._colsOf(popup.tab === "emoji" ? "emoji" : "symbol");
        const rec = popup.service && popup.recents ? popup.service.recentsOf(popup.tab, rc) : [];
        if (rec.length > 0)
            out.push({ id: "recent", label: "Recent", profile: popup.tab === "emoji" ? "emoji" : "symbol", items: rec });
        if (popup.tab === "emoji") {
            for (let c = 0; c < ix.cats.length; c++) {
                out.push({ id: ix.cats[c].id, label: ix.cats[c].label, profile: "emoji", items: ix.byCat[ix.cats[c].id] || [] });
            }
        } else {
            for (let s = 0; s < ix.sets.length; s++) {
                const set = ix.sets[s];
                out.push({ id: set.id, label: set.id === "alt" ? "Alt codes: Alt+nnn (" + popup.service.oemName + "), Alt+0nnn (" + popup.service.ansiName + ")" : set.label,
                           profile: popup._profileOf(set.tile), items: set.items });
            }
        }
        return out;
    }
    // The category bar: the tab's categories (what the grid can jump to); with a query the sections are the hits.
    readonly property var cats: {
        const ix = popup.idx;
        if (!ix)
            return [];
        if (popup.tab === "nerd")
            return popup.nidx ? popup.nidx.sets : [];
        return popup.tab === "emoji" ? ix.cats : ix.sets;
    }

    readonly property var geom: ({
            width: popup._gridW,
            pad: popup._boxPad,
            padTop: 6,
            padBottom: 12,
            headH: popup.style ? popup.style.headH : 26,
            sectionGap: popup.style ? popup.style.sectionGap : 6,
            profiles: popup.style ? {
                emoji: { minW: popup.style.emojiCell, h: popup.style.emojiCell },
                symbol: { minW: popup.style.symbolCell, h: popup.style.symbolCell },
                alt: { minW: popup.style.altCellW, h: popup.style.altCellH },
                wide: { minW: popup.style.wideCellW, h: popup.style.wideCellH },
                nerd: { minW: popup.style.nerdCell, h: popup.style.nerdCell }
            } : {}
        })
    readonly property var lay: Model.layout(popup.sections, popup.geom)
    // The header that carries the Clear / Undo control: the Recent one; while an Undo is on offer and Recent is gone, the first header, which
    // stands at the very same y. Nowhere with a query typed (there are no sections of the tab's own then).
    readonly property string _clearSec: {
        if (popup.searching || popup.sections.length === 0)
            return "";
        if (popup.sections[0].id === "recent")
            return "recent";
        return popup._undo !== null && popup._undo.tab === popup.tab ? popup.sections[0].id : "";
    }
    readonly property var currentItem: popup.currentIndex >= 0 && popup.currentIndex < popup.lay.flat.length ? popup.lay.flat[popup.currentIndex] : null
    readonly property bool _empty: popup.lay.flat.length === 0

    onLayChanged: {
        // A new page puts the highlight on its first cell and the box at its top; the same page re-laid out keeps both.
        const fresh = popup._focusFirst;
        popup._focusFirst = false;
        popup.currentIndex = fresh ? 0 : Math.max(0, Math.min(popup.currentIndex, popup.lay.flat.length - 1));
        if (fresh)
            grid.scrollTo(0, false);
    }
    onCurrentIndexChanged: grid.ensureVisible(popup.currentIndex, true)

    // ---- Tray ------------------------------------------------------------------------------------
    readonly property var trayCounts: {
        const m = {};
        for (let i = 0; i < popup.tray.length; i++)
            m[popup.tray[i].ch] = (m[popup.tray[i].ch] || 0) + 1;
        return m;
    }
    function _textOf(it) {
        return popup.service ? popup.service.textOf(it) : it.ch;
    }
    readonly property string trayText: popup.tray.map(it => popup._textOf(it)).join(popup._joiner(popup.tray))
    // Kaomoji and names are joined by a space (a glyph of any other kind runs on).
    function _joiner(items) {
        return items.some(it => it.set === "kaomoji" || it.asName === true) ? " " : "";
    }
    function addTray(it) {
        if (it)
            popup.tray = popup.tray.concat([it]);
    }

    // ---- Picks ----------------------------------------------------------------------------------
    // The tray's picks and `it`, joined, onto the clipboard; the popup closes and the service pastes after it let go.
    function commit(it) {
        if (!popup.service)
            return;
        const items = popup.tray.concat(it ? [it] : []);
        if (items.length === 0)
            return;
        popup.service.pick(items.map(x => popup.service.textOf(x)).join(popup._joiner(items)), items.map(x => x.ch));
        popup.closeRequested();
    }
    // `ctrl` picks the NAME of a Nerd icon (nf-md-lightbulb_on) instead of its glyph (`nerdPick`: the other way round); on the other tabs
    // it means nothing.
    function confirm(shift, ctrl) {
        let it = popup.currentItem;
        if (it && it.tab === "nerd" && (ctrl === true) !== (popup.nerdPick === "name"))
            it = Model.asName(it);
        if (shift)
            popup.addTray(it);
        else
            popup.commit(it);
    }

    // ---- Tab, query, moving -----------------------------------------------------------------------
    function setTab(t) {
        if (popup.tab === t)
            return;
        popup._focusFirst = true;
        popup._dropUndo();
        popup._showTab(t);
        if (popup.openTab === "last" && popup.service)
            popup.service.rememberTab(t);
    }
    function _showTab(t) {
        popup.tab = t;
        if (t === "nerd" && popup.service)
            popup.service.ensureNerd();
    }
    // Every open's first tab.
    function _toOpenTab() {
        const want = popup.openTab === "last" ? (popup.service ? popup.service.lastTab : "") : popup.openTab;
        popup._showTab(popup.tabIds.indexOf(want) >= 0 ? want : popup.tabIds[0]);
    }
    function stepTab(dir) {
        const n = popup.tabIds.length;
        popup.setTab(popup.tabIds[(popup.tabIds.indexOf(popup.tab) + (dir < 0 ? -1 : 1) + n) % n]);
    }
    // A tab taken away under an open popup.
    onTabIdsChanged: {
        if (popup.tabIds.indexOf(popup.tab) < 0)
            popup.setTab(popup.tabIds[0]);
    }
    function setQuery(t) {
        popup._focusFirst = true;
        popup.query = t;
        header.setQuery(t);
    }
    function moveBy(dRow, dCol) {
        if (popup._empty)
            return;
        popup.currentIndex = Model.move(popup.lay, popup.currentIndex, dRow, dCol);
    }
    // The rows the grid shows at once: its height over the current tile row's pitch, at least one.
    function _pageRows() {
        const L = popup.lay;
        const r = L && !popup._empty ? L.rows[L.rowOf[popup.currentIndex]] : null;
        return Math.max(1, Math.floor(grid.height / Math.max(1, r ? r.h : L ? L.minRowH : 1)));
    }
    function moveTo(i) {
        if (!popup._empty)
            popup.currentIndex = Math.max(0, Math.min(popup.lay.flat.length - 1, i));
    }
    // A category: the section the grid scrolls to. With a query the page IS the hits, so a click on the bar leaves the search
    // and goes there.
    function jumpToCat(id) {
        if (popup.searching) {
            popup._focusFirst = true;
            popup.query = "";
            header.setQuery("");
            // the page is rebuilt on the next turn; its sections exist then
            Qt.callLater(() => popup._scrollToCat(id));
        } else {
            popup._scrollToCat(id);
        }
    }
    // The highlight goes to the section's first cell FIRST (its own reveal runs), then the section's header is scrolled to: the
    // last writer of the scroll position wins, and it must be the jump.
    function _scrollToCat(id) {
        const L = popup.lay;
        for (let i = 0; i < L.flat.length; i++) {
            if (L.rows[L.rowOf[i]].sec === id) {
                popup.currentIndex = i;
                break;
            }
        }
        grid.scrollToSection(id, true);
    }
    function stepCat(dir) {
        const cs = popup.cats;
        if (cs.length === 0 || popup.searching)
            return;
        let at = -1;
        for (let i = 0; i < cs.length; i++)
            if (cs[i].id === popup._topCat)
                at = i;
        popup.jumpToCat(cs[Math.max(0, Math.min(cs.length - 1, at + dir))].id);
    }
    // The category the pill stands on: the section at the top of the grid, a "Recent" section being no category.
    readonly property string _topCat: {
        if (popup.searching)
            return "";
        const s = grid.topSection;
        return s === "recent" ? (popup.cats.length > 0 ? popup.cats[0].id : "") : s;
    }

    // ---- Clear, Undo, Delete -----------------------------------------------------------------------
    // The Clear control: this tab's recents go (all of them, the ones past the row too) and the control becomes the Undo.
    function clearRecents() {
        if (!popup.service)
            return;
        const saved = popup.service.clearRecents(popup.tab);
        if (Object.keys(saved).length === 0)
            return;
        popup._undo = { tab: popup.tab, saved: saved };
        grid.armUndo();
    }
    function undoClear() {
        if (popup._undo !== null && popup.service)
            popup.service.restoreRecents(popup._undo.saved);
        popup._undo = null;
    }
    function _dropUndo() {
        popup._undo = null;
        grid.disarmUndo();
    }
    // Delete: the highlighted tile, when it is in the Recent section and no query is typed.
    function _highlightIsRecent() {
        const L = popup.lay;
        return !popup.searching && popup.currentIndex >= 0 && popup.currentIndex < L.flat.length && L.rows[L.rowOf[popup.currentIndex]].sec === "recent";
    }

    // ---- Tone popover ------------------------------------------------------------------------------
    function openToneFor(i) {
        const it = i >= 0 && i < popup.lay.flat.length ? popup.lay.flat[i] : null;
        if (!it || !it.tonable || popup.tab !== "emoji")
            return;
        popup._toneBase = it.ch;
        const r = grid.cellRectIn(i, overlay);
        popup._placeTone(r.x + r.w / 2, r.y, r.y + r.h);
    }
    function openToneFromButton() {
        const it = popup.currentItem;
        popup._toneBase = it && it.tonable ? it.ch : "👋";
        const p = foot.mapToItem(overlay, foot.width - 18, 0);
        popup._placeTone(p.x, p.y, p.y + foot.height);
    }
    // The popover stands above the cell, centred on it, inside the popup -- below it when above would cover the search field.
    function _placeTone(cx, top, bottom) {
        const w = tonePop.width;
        const h = tonePop.height;
        tonePop.x = Math.round(Math.max(popup.pad, Math.min(popup.layoutWidth - popup.pad - w, cx - w / 2)));
        tonePop.y = Math.round(top - h - 4 >= header.y + header.height + 4 ? top - h - 4 : bottom + 4);
        tonePop.focusIdx = popup.tone;
        popup.toneOpen = true;
    }
    function closeTone() {
        popup.toneOpen = false;
        popup.forceActiveFocus();
    }
    function chooseTone(t) {
        if (popup.service)
            popup.service.setTone(t);
        popup.closeTone();
    }

    // ---- Captions --------------------------------------------------------------------------------
    function captionOf(it) {
        if (!it)
            return "";
        if (it.tab === "nerd")
            return it.name + "   U+" + it.code.toUpperCase();
        if (it.codes.length > 0)
            return it.codes.map(c => "Alt+" + c).join(" \u00B7 ") + "   " + it.name;
        return it.name;
    }

    // ---- Lifecycle ---------------------------------------------------------------------------------
    Component.onCompleted: {
        if (popup.service)
            popup.service.ensureLoaded();
        popup._toOpenTab();
        popup.forceActiveFocus();
    }
    Component.onDestruction: popup.contentGone()

    // A reopen that finds this content still closing: everything a session leaves goes first.
    function freshen() {
        popup.toneOpen = false;
        popup.tray = [];
        popup._dropUndo();
        popup._focusFirst = true;
        popup._toOpenTab();
        popup.query = "";
        header.setQuery("");
        popup.forceActiveFocus();
    }

    // ---- Keys -------------------------------------------------------------------------------------
    function _escape() {
        if (popup.query !== "")
            popup.setQuery("");
        else if (popup.tray.length > 0)
            popup.tray = [];
        else
            popup.closeRequested();
    }
    function handleEscape() {
        if (popup.toneOpen)
            popup.closeTone();
        else
            popup._escape();
        return true;
    }
    function _printable(e) {
        if (e.text.length !== 1)
            return false;
        const c = e.text.charCodeAt(0);
        return c >= 32 && c !== 127;
    }
    function handleKey(e) {
        const k = e.key;
        const m = e.modifiers;
        const ctrl = (m & Qt.ControlModifier) !== 0;
        const alt = (m & Qt.AltModifier) !== 0;
        const shift = (m & Qt.ShiftModifier) !== 0;
        e.accepted = true;
        if (popup.toneOpen) {
            if (k === Qt.Key_Left)
                tonePop.step(-1);
            else if (k === Qt.Key_Right)
                tonePop.step(1);
            else if (k === Qt.Key_Return || k === Qt.Key_Enter)
                tonePop.chooseFocused();
            else if (k === Qt.Key_Escape)
                popup.closeTone();
            return;
        }
        if (k === Qt.Key_Left)
            ctrl ? popup.stepCat(-1) : popup.moveBy(0, -1);
        else if (k === Qt.Key_Right)
            ctrl ? popup.stepCat(1) : popup.moveBy(0, 1);
        else if (k === Qt.Key_Up)
            popup.moveBy(-1, 0);
        else if (k === Qt.Key_Down)
            popup.moveBy(1, 0);
        else if (k === Qt.Key_Home)
            popup.moveTo(0);
        else if (k === Qt.Key_End)
            popup.moveTo(popup.lay.flat.length - 1);
        else if (k === Qt.Key_PageUp)
            popup.moveBy(-popup._pageRows(), 0);
        else if (k === Qt.Key_PageDown)
            popup.moveBy(popup._pageRows(), 0);
        else if (k === Qt.Key_Tab || k === Qt.Key_Backtab)
            popup.stepTab(k === Qt.Key_Backtab || shift ? -1 : 1);
        else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (!alt && (!ctrl || popup.tab === "nerd"))
                popup.confirm(shift, ctrl);
        } else if (k === Qt.Key_Delete && !ctrl && !alt && popup.service && popup._highlightIsRecent()) {
            popup.service.forget(popup.currentItem.ch);
        } else if ((ctrl && k === Qt.Key_T) || k === Qt.Key_Menu) {
            if (popup.tab === "emoji") {
                if (popup.currentItem && popup.currentItem.tonable)
                    popup.openToneFor(popup.currentIndex);
                else
                    popup.openToneFromButton();
            }
        } else if (k === Qt.Key_Escape)
            popup._escape();
        else if (EK.queryActionOf(k, m) !== null) {
            if (popup.query !== "")
                popup.setQuery(EK.queryAfter(EK.queryActionOf(k, m), popup.query));
        } else if (k === Qt.Key_Backspace) {
            if (popup.query !== "")
                popup.setQuery(popup.query.slice(0, -1));
            else if (popup.tray.length > 0)
                popup.tray = popup.tray.slice(0, -1);
        } else if (!ctrl && !alt && popup._printable(e)) {
            // A leading space types nothing.
            if (!(e.text === " " && popup.query === ""))
                popup.setQuery(popup.query + e.text);
        } else
            e.accepted = false;
    }
    Keys.onPressed: e => popup.handleKey(e)

    // ---- Layout --------------------------------------------------------------------------------------
    // Everything is laid out at the size the popup ASKED for (the host's box grows from the bar as the popup opens).
    Item {
        id: header
        objectName: "pickerHeader"
        x: popup.pad
        y: popup.pad
        width: popup.layoutWidth - 2 * popup.pad
        height: implicitHeight
        implicitHeight: 32
        readonly property bool tabbed: popup.tabIds.length > 1
        readonly property real gap: header.tabbed ? 12 : 0
        readonly property real tabsW: header.tabbed ? 90 * popup.tabIds.length : 0

        function setQuery(t) {
            if (search.text !== t)
                search.text = t;
        }

        CarvedSearchField {
            id: search
            objectName: "pickerSearch"
            x: 0
            y: 0
            width: header.width - header.tabsW - header.gap
            height: header.height
            placeholder: popup.tab === "nerd" ? "Search icon names" : popup.tab === "emoji" ? "Search emoji" : "Search, or type an alt code"
            fontFamily: popup.fontFamily
            onEdited: t => {
                popup._focusFirst = true;
                popup.query = t;
            }
            onEscaped: popup.forceActiveFocus()
        }
        TabSelector {
            id: tabs
            objectName: "pickerTabs"
            x: header.width - header.tabsW
            y: 0
            width: header.tabsW
            height: header.height
            visible: header.tabbed
            trackSurfaceColor: Theme.surface
            fontFamily: popup.fontFamily
            fontPixelSize: 12
            overlayItem: overlay
            tabs: popup.tabIds.map(t => ({ id: t, label: popup.searching && (t !== "nerd" || popup.nidx) ? popup._nameOf(t) + " " + popup._countOf(t) : popup._nameOf(t) }))
            onTabChanged: id => popup.setTab(id)
        }
        Binding {
            target: tabs
            property: "currentTab"
            value: popup.tab
        }
    }

    PickerGrid {
        id: grid
        objectName: "pickerGrid"
        x: popup.pad
        y: header.y + header.height + popup.pad
        width: popup._gridW
        height: popup._gridH
        style: popup.style
        layoutObj: popup.lay
        current: popup.currentIndex
        fontFamily: popup.fontFamily
        nerdFamily: popup.service ? popup.service.nerdFamily : "Symbols Nerd Font"
        tone: popup.tone
        tones: popup.service ? popup.service.tones : []
        trayCounts: popup.trayCounts
        onHovered: i => popup.moveTo(i)
        onPicked: (i, shift, ctrl) => {
            popup.moveTo(i);
            popup.confirm(shift, ctrl);
            popup.forceActiveFocus();
        }
        onContextRequested: i => popup.openToneFor(i)
        clearSec: popup._clearSec
        undoMs: popup.style ? popup.style.undoMs : 10000
        onClearClicked: {
            popup.clearRecents();
            popup.forceActiveFocus();
        }
        onUndoClicked: {
            popup.undoClear();
            popup.forceActiveFocus();
        }
        onUndoExpired: popup._undo = null
    }

    // The empty page: presence fades, the words swap at once.
    Text {
        id: emptyText
        objectName: "pickerEmpty"
        x: grid.x
        y: grid.y
        width: grid.width
        height: grid.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        wrapMode: Text.WordWrap
        font.family: popup.fontFamily
        font.pixelSize: 14
        color: Theme.textFaint
        text: !popup.ready ? (popup.service && popup.service.error !== "" ? popup.service.error : "")
            : popup.tab === "nerd" && popup.nerdState === "error" ? "No Nerd Fonts list: " + popup.service.nerdError + ". Leave this tab and come back to retry."
            : popup.tab === "nerd" && !popup.nidx ? "Loading the Nerd Fonts list"
            : popup.tab === "symbols" && popup.digits !== "" ? "No alt code starts with " + popup.digits
            : "No match" + popup._elsewhere()
        property real f: popup._empty ? 1 : 0
        Behavior on f {
            NumberAnimation {
                duration: popup.style ? popup.style.presenceMs : 160
                easing.type: Easing.OutCubic
            }
        }
        opacity: emptyText.f
        visible: emptyText.f > 0
    }

    PickerFoot {
        id: foot
        objectName: "pickerFoot"
        x: popup.pad
        y: grid.y + grid.height + popup.pad
        width: popup.layoutWidth - 2 * popup.pad
        height: implicitHeight
        style: popup.style
        fontFamily: popup.fontFamily
        catFontFamily: popup.tab === "emoji" ? "Noto Color Emoji" : popup.tab === "nerd" ? (popup.service ? popup.service.nerdFamily : "Symbols Nerd Font") : "Inter"
        catCell: popup.tab === "nerd" && popup.style ? popup.style.nerdCatCell : popup.style ? popup.style.catCell : 32
        cats: popup.cats
        currentCat: popup._topCat
        caption: popup.captionOf(popup.currentItem)
        trayText: popup.trayText
        trayCount: popup.tray.length
        toneVisible: popup.tab === "emoji"
        tone: popup.tone
        tones: popup.service ? popup.service.tones : []
        overlayItem: overlay
        onCatPicked: id => {
            popup.jumpToCat(id);
            popup.forceActiveFocus();
        }
        onToneClicked: popup.openToneFromButton()
    }

    // ---- Floating things: the tone popover -------------------------------------------------------------
    Item {
        id: overlay
        objectName: "pickerOverlay"
        anchors.fill: parent
        z: 1000

        // A click outside the popover closes it and is not delivered below.
        MouseArea {
            anchors.fill: parent
            visible: popup.toneOpen
            acceptedButtons: Qt.AllButtons
            onPressed: popup.closeTone()
        }
        PickerTonePop {
            id: tonePop
            objectName: "pickerTonePop"
            open: popup.toneOpen
            base: popup._toneBase
            tones: popup.service ? popup.service.tones : []
            selected: popup.tone
            style: popup.style
            onChosen: t => popup.chooseTone(t)
        }
    }
}
