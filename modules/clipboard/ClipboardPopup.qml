pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/EditKeys.js" as EK
import "data/ClipboardModel.js" as Model
import "shelf"

// =============================================================================
// ClipboardPopup.qml -- the clipboard shelf, a drop-in for thePopup.
//
// Holds nothing that must outlive it: the service (ClipboardService, or a
// ClipboardMock) and the style live bar-side (ClipboardBarOwner); this is built
// on every open and talks ONLY to the service API of CONTRACT.md.
//
// HOST CONTRACT (GooeyEngine; docs/contracts/gooey_engine.md):
//   implicitWidth/Height   `style.shelfCards` cards wide plus the padding, clamped to
//                          the host room's span; the
//                          padding, the header, the padding, the shelf, the
//                          padding -- as much room above the header as below
//                          the shelf. The editor takes the shelf's rectangle,
//                          so the popup never resizes through a mode.
//   keyboardFocusRequest   "exclusive": the popup is opened by a shortcut and the
//                          keyboard is its from the first key -- unless the
//                          host's focus grab holds it (`grabbed`: the shell's
//                          HyprlandFocusGrab on the bar window), when it asks
//                          for none: the grab is the keyboard AND the dismissal
//                          (a click elsewhere clears it, closes the popup, and is
//                          not delivered), and Exclusive on top would stop the
//                          grab ever clearing
//   hostRoom               assigned by the host
//   closeRequested()       a paste (the service sends the key after the popup
//                          has let go of the keyboard), or Escape at the end
//                          of its chain
//   handleEscape()         the whole Escape chain as one call, returning true:
//                          what the shell's Escape bind (a runtime Hyprland bind
//                          that swallows the key before any window hears it) asks
//                          of the primary content before it closes anything. A
//                          key that does reach the popup takes the same path, so
//                          the two meet in one function (see KEYS)
//
// WHAT THE SHELF SHOWS (`items`): the service's entries ranked by
// ClipboardModel.rank(query, filter, pinnedFirst), the sealed copies in front of them,
// newest first. A sealed copy has no text to match, so it shows only under the
// "All" chip with nothing typed -- and not at all while the screen is shared
// (`service.hidden`). Every binding that reads the entries reads `serial`
// FIRST: a ListModel move emits nothing else.
//
// KEYS (all of them are handled here, on the popup's own focus, so that
// typing always searches):
//   type / Backspace          the search (plain digits too; Alt+1..9 is paste)
//   Left Right Home End PgUp PgDn    move the focus mark
//   Tab / Shift+Tab           the chips
//   Enter / Shift+Enter       paste / copy (the marked cards, joined, when
//                             some are marked); the other way round with
//                             clipboard.jsonc `enter: "copy"`
//   Alt+1..9                  paste the nth visible card (digits show while
//                             Alt is held)
//   Ctrl+Space                mark / unmark (pick order is the badge order)
//   Ctrl+E                    edit the text (Ctrl+Enter pastes, Esc saves it as a
//                             card, Ctrl+Esc throws the edit away)
//   Ctrl+T / Menu / right-click   the menu: paste as (transforms), mark, pin,
//                             rename, seal, keep, delete
//   Ctrl+P                    pin / unpin
//   Delete                    remove (the header offers Undo); a sealed copy
//                             is forgotten
//   hold Ctrl+R               peek at the focused sealed copy
//   Esc                       clears the query, then the marks, then closes --
//                             and a card the user PICKED (arrows, a click) is
//                             copied on the way out, so reopening shows it first
//                             and a Ctrl+V pastes it: closing is confirming
//                             (clipboard.jsonc `copyOnClose`).
//                             Nothing picked, nothing copied: the card the mark
//                             opens on is only a default (and may be a sealed
//                             copy that is not the clipboard's content)
// A click on the search field moves the keyboard into it (caret, selection);
// the keys it does not use still reach this handler.
//
// SECRETS. A sealed copy's text is read from the service ONLY by a peek, into
// `peekText`, and cleared on release, on a change of focus, when the copy goes
// away and when the popup does. It is never logged, never in a Text but the
// peeking card's, and never in `items`.
//
// Content paints no background; the host's surface is the ground.
// =============================================================================
FocusScope {
    id: popup

    property var service: null
    property ClipStyle style: null
    property string stateDir: ""
    property var hostRoom: null
    property string fontFamily: "Inter"
    property int undoMs: 8000
    readonly property var prefs: popup.service && popup.service.prefs ? popup.service.prefs : Model.PREFS
    // The popup is opened by a shortcut: the keyboard is its at once.
    property bool grabbed: false
    readonly property string keyboardFocusRequest: popup.grabbed ? "none" : "exclusive"

    signal closeRequested
    signal contentGone

    // ---- Numbers ------------------------------------------------------------------
    readonly property real pad: 12
    // The shelf is `shelfCards` cards and the gaps between them; the popup adds its padding.
    readonly property int _wantW: {
        const st = popup.style;
        const cards = st ? st.shelfCards : 4;
        const stride = st ? st.cardWidth + st.cardGap : 194;
        return Math.round(Math.max(1, cards) * stride - (st ? st.cardGap : 10) + 2 * popup.pad);
    }
    readonly property real _roomSpan: popup.hostRoom && popup.hostRoom.hi !== undefined && popup.hostRoom.lo !== undefined ? popup.hostRoom.hi - popup.hostRoom.lo : 0
    readonly property real layoutWidth: Math.round(popup._roomSpan > 0 ? Math.min(popup._wantW, popup._roomSpan) : popup._wantW)
    // The shelf's rect is exactly its cards (implicitHeight = cardHeight): the
    // lift, the well and the shadows paint up to 12 px outside it, which is
    // the popup's padding, so nothing here clips at the shelf's own rect.
    readonly property real _shelfH: shelf.implicitHeight
    implicitWidth: popup.layoutWidth
    implicitHeight: Math.round(3 * popup.pad + header.implicitHeight + popup._shelfH)

    // ---- State ----------------------------------------------------------------------
    property string query: ""
    property string filter: "all"
    property int currentIndex: 0
    // Picked keys, in pick order.
    property var marks: []
    property bool altHeld: false
    property bool editing: false
    property string peekKey: ""
    property string peekText: ""
    property string _focusKey: ""
    property bool _focusFirst: true
    property string _menuKey: ""
    property string _renameKey: ""
    // The user chose a card (moved the mark, clicked one), as opposed to the mark resting where an
    // open or a new query put it: only a chosen card is confirmed by Escape.
    property bool _picked: false
    // An edit was saved: the text it stored, so the mark follows the card that text becomes.
    property string _focusSaved: ""
    readonly property var _filters: ["all", "text", "image", "link", "pinned"]

    // The ranked display list: { key, type: "entry"|"secret", d }.
    readonly property var items: {
        const svc = popup.service;
        if (!svc || svc.serial < 0)
            return [];
        const recs = [];
        for (let i = 0; i < svc.entries.count; i++)
            recs.push(svc.entries.get(i).rec.d);
        const out = [];
        if (!svc.hidden && popup.filter === "all" && popup.query.trim() === "") {
            const sec = svc.secrets.slice().sort((a, b) => b.t - a.t);
            for (let i = 0; i < sec.length; i++)
                out.push({
                    key: sec[i].key,
                    type: "secret",
                    d: sec[i]
                });
        }
        const ranked = Model.rank(recs, popup.query, popup.filter, popup.prefs.pinnedFirst);
        for (let i = 0; i < ranked.length; i++)
            out.push({
                key: ranked[i].id,
                type: "entry",
                d: ranked[i]
            });
        return out;
    }
    readonly property var currentItem: popup.currentIndex >= 0 && popup.currentIndex < popup.items.length ? popup.items[popup.currentIndex] : null
    readonly property bool _empty: popup.items.length === 0
    readonly property bool _anyStored: popup.service ? popup.service.entries.count > 0 || popup.service.secrets.length > 0 : false

    onItemsChanged: popup._reconcile()
    onCurrentIndexChanged: {
        // Read the list itself: a change handler runs before the binding
        // `currentItem` has followed the index (CLAUDE.md).
        const it = popup.currentIndex >= 0 && popup.currentIndex < popup.items.length ? popup.items[popup.currentIndex] : null;
        popup._focusKey = it ? it.key : "";
        popup.clearPeek();
        shelf.ensureVisible(popup.currentIndex);
    }
    // The focus mark stays on its card through a new copy, a bump or a delete;
    // a new query or filter puts it on the first card.
    function _reconcile() {
        const its = popup.items;
        let idx = 0;
        if (!popup._focusFirst && popup._focusKey !== "") {
            idx = -1;
            for (let i = 0; i < its.length; i++) {
                if (its[i].key === popup._focusKey) {
                    idx = i;
                    break;
                }
            }
            if (idx < 0)
                idx = popup.currentIndex;
        }
        if (popup._focusFirst)
            popup._picked = false;
        popup._focusFirst = false;
        if (popup._focusSaved !== "") {
            // The card a saved edit became: the newest with that text.
            for (let i = 0; i < its.length; i++) {
                if (its[i].type === "entry" && its[i].d.text === popup._focusSaved) {
                    idx = i;
                    popup._focusSaved = "";
                    break;
                }
            }
        }
        idx = Math.max(0, Math.min(idx, its.length - 1));
        popup._focusKey = its.length > 0 ? its[idx].key : "";
        popup.currentIndex = idx;
        if (popup.peekKey !== "" && !its.some(it => it.key === popup.peekKey))
            popup.clearPeek();
    }

    // Marks of cards the service no longer has go with them.
    function _pruneMarks() {
        const svc = popup.service;
        if (!svc || popup.marks.length === 0)
            return;
        const have = {};
        for (let i = 0; i < svc.entries.count; i++)
            have[svc.entries.get(i).key] = true;
        for (let i = 0; i < svc.secrets.length; i++)
            have[svc.secrets[i].key] = true;
        const kept = popup.marks.filter(k => have[k] === true);
        if (kept.length !== popup.marks.length)
            popup.marks = kept;
    }
    Connections {
        target: popup.service
        ignoreUnknownSignals: true
        function onSerialChanged() {
            popup._pruneMarks();
        }
    }

    Component.onCompleted: {
        popup.filter = popup.prefs.openOn;
        popup.forceActiveFocus();
    }
    Component.onDestruction: {
        popup.clearPeek();
        popup.contentGone();
    }

    // A reopen that finds this content still closing: the engine takes it back
    // as it is, so everything a session leaves (a query, marks, an open editor
    // or menu, a peek) goes first -- every open starts fresh.
    function freshen() {
        popup.clearPeek();
        popup.editing = false;
        popup._renameKey = "";
        menu.open = false;
        popup.marks = [];
        popup.altHeld = false;
        popup.filter = popup.prefs.openOn;
        popup._picked = false;
        popup._focusSaved = "";
        popup._focusFirst = true;
        popup.query = "";
        header.setQuery("");
        popup._reconcile();
        popup.forceActiveFocus();
    }

    // ---- Query and filter -------------------------------------------------------------
    function setQuery(t) {
        popup._focusFirst = true;
        popup.query = t;
        header.setQuery(t);
    }
    function setFilter(f) {
        if (popup.filter === f)
            return;
        popup._focusFirst = true;
        popup.filter = f;
    }
    function stepFilter(dir) {
        const n = popup._filters.length;
        const i = popup._filters.indexOf(popup.filter);
        popup.setFilter(popup._filters[((i < 0 ? 0 : i) + dir + n) % n]);
    }

    // ---- Moving ---------------------------------------------------------------------------
    function moveTo(i) {
        if (popup.items.length === 0)
            return;
        popup._picked = true;
        popup.currentIndex = Math.max(0, Math.min(popup.items.length - 1, i));
    }
    function _page() {
        const st = popup.style;
        const step = st ? st.cardWidth + st.cardGap : 194;
        return Math.max(1, Math.floor(shelf.width / step));
    }

    // ---- Marks ------------------------------------------------------------------------------
    function toggleMark(key) {
        if (!key)
            return;
        const at = popup.marks.indexOf(key);
        if (at >= 0)
            popup.marks = popup.marks.filter(k => k !== key);
        else
            popup.marks = popup.marks.concat([key]);
    }

    // ---- Peek -------------------------------------------------------------------------------
    function startPeek() {
        const it = popup.currentItem;
        if (!popup.service || !it || it.type !== "secret" || popup.service.hidden)
            return;
        popup.peekKey = it.key;
        popup.peekText = popup.service.revealSecret(it.key);
    }
    function clearPeek() {
        if (popup.peekKey !== "")
            popup.peekKey = "";
        if (popup.peekText !== "")
            popup.peekText = "";
    }

    // ---- Paste and the verbs -----------------------------------------------------------------
    function _paste(keys, opts) {
        popup.clearPeek();
        popup.service.paste(keys, opts);
        popup.closeRequested();
    }
    // Enter and Shift+Enter: the marked cards joined in pick order, else the
    // focused one.
    function confirm(mode) {
        if (!popup.service)
            return;
        if (popup.marks.length > 0) {
            popup._paste(popup.marks, {
                mode: mode,
                via: "join",
                joiner: popup.prefs.joiner
            });
            return;
        }
        const it = popup.currentItem;
        if (it)
            popup._paste([it.key], {
                mode: mode,
                via: "copy"
            });
    }
    function quickPaste(n) {
        const i = shelf.firstVisibleIndex + n - 1;
        if (!popup.service || i < 0 || i >= popup.items.length)
            return;
        popup._paste([popup.items[i].key], {
            mode: "paste",
            via: "copy"
        });
    }
    // A double click: what Enter does.
    function enterIndex(i) {
        if (!popup.service || i < 0 || i >= popup.items.length)
            return;
        popup._paste([popup.items[i].key], {
            mode: popup.prefs.enter,
            via: "copy"
        });
    }
    function _itemOf(key) {
        for (let i = 0; i < popup.items.length; i++)
            if (popup.items[i].key === key)
                return popup.items[i];
        return null;
    }
    function togglePin(it) {
        if (!popup.service || !it || it.type !== "entry")
            return;
        popup.service.pin(it.key, !it.d.pinned);
    }
    function removeItem(it) {
        if (!popup.service || !it)
            return;
        if (it.type === "entry") {
            popup.service.remove(it.key);
            header.armUndo();
        } else {
            popup.service.dropSecret(it.key);
        }
    }

    // ---- Edit -------------------------------------------------------------------------------
    function _editable(it) {
        return !!it && it.type === "entry" && it.d.truncated !== true && (it.d.kind === "text" || it.d.kind === "code" || it.d.kind === "link" || it.d.kind === "colour");
    }
    function startEdit() {
        const it = popup.currentItem;
        if (!popup._editable(it))
            return;
        popup.clearPeek();
        popup.editing = true;
        editor.begin(it.d.text, it.d.kind === "code");
    }
    function endEdit() {
        popup.editing = false;
        popup.forceActiveFocus();
    }
    // Escape in the editor: the edit is kept as a card (what Ctrl+Enter stores, without the paste),
    // it is the clipboard's from now on, and the mark goes to it. Nothing changed, nothing stored.
    function saveEdit(text) {
        const it = popup.currentItem;
        popup.endEdit();
        if (!popup.service || !it || it.type !== "entry" || text === it.d.text)
            return;
        popup._picked = true;
        popup._focusSaved = text;
        popup.service.paste([it.key], {
            mode: "copy",
            text: text,
            via: "edit"
        });
    }

    // ---- Rename: an inline field over the card -------------------------------------------------
    function startRename(it) {
        if (!it || it.type !== "entry")
            return;
        const i = popup.items.indexOf(it);
        const r = shelf.cardRect(i);
        const p = shelf.mapToItem(overlay, r.x, r.y);
        renameField.x = Math.round(p.x + 6);
        renameField.y = Math.round(p.y + 6);
        renameField.width = Math.round(Math.max(120, r.width - 12));
        popup._renameKey = it.key;
        renameField.text = it.d.title || "";
        renameField.forceFocus();
    }
    function _endRename(commit) {
        const key = popup._renameKey;
        if (key === "")
            return;
        popup._renameKey = "";
        if (commit && popup.service)
            popup.service.rename(key, renameField.text.trim());
        popup.forceActiveFocus();
    }

    // ---- Menu -------------------------------------------------------------------------------
    readonly property var _transformLabels: ({
            trim: "Trim",
            oneLine: "One line",
            upper: "UPPERCASE",
            lower: "lowercase",
            title: "Title Case",
            stripTracking: "Strip tracking",
            jsonPretty: "JSON pretty",
            jsonMinify: "JSON minify",
            urlDecode: "URL decode",
            urlEncode: "URL encode",
            base64Decode: "Base64 decode",
            base64Encode: "Base64 encode",
            pathFromUri: "Path from URI"
        })
    function _menuRows(it) {
        const rows = [];
        if (!it)
            return rows;
        const marked = popup.marks.indexOf(it.key) >= 0;
        if (it.type === "entry") {
            const r = it.d;
            if (popup.service.transforms(r.id).length > 0)
                rows.push({
                    id: "pasteas",
                    label: "Paste as …"
                });
            // The same editor as Ctrl+E, for the same cards.
            if (popup._editable(it))
                rows.push({
                    id: "edit",
                    label: "Edit"
                });
            rows.push({
                id: "mark",
                label: marked ? "Unmark" : "Mark"
            }, {
                id: "pin",
                label: r.pinned ? "Unpin" : "Pin"
            }, {
                id: "rename",
                label: "Rename"
            });
            if (r.kind === "text" || r.kind === "code" || r.kind === "link" || r.kind === "colour")
                rows.push({
                    id: "seal",
                    label: "Seal"
                });
        } else {
            rows.push({
                id: "mark",
                label: marked ? "Unmark" : "Mark"
            });
            if (it.d.reason === "heuristic")
                rows.push({
                    id: "keep",
                    label: "Keep"
                });
        }
        rows.push({
            separator: true
        }, {
            id: "delete",
            label: it.type === "entry" ? "Delete" : "Forget",
            danger: true
        });
        return rows;
    }
    function _transformRows(it) {
        const rows = [
            {
                id: "back",
                label: "‹  Paste as"
            },
            {
                separator: true
            }
        ];
        const names = popup.service.transforms(it.d.id);
        for (let i = 0; i < names.length; i++)
            rows.push({
                id: "t:" + names[i],
                label: popup._transformLabels[names[i]] || names[i]
            });
        return rows;
    }
    function openMenuFor(i, x, y) {
        const it = i >= 0 && i < popup.items.length ? popup.items[i] : null;
        if (!it || !popup.service)
            return;
        popup.clearPeek();
        popup._menuKey = it.key;
        menu.rows = popup._menuRows(it);
        menu.openAt(x, y);
    }
    function openMenuAtCard() {
        const i = popup.currentIndex;
        if (i < 0 || i >= popup.items.length)
            return;
        const r = shelf.cardRect(i);
        const p = shelf.mapToItem(overlay, r.x + 10, r.y + 34);
        popup.openMenuFor(i, p.x, p.y);
    }
    function _menuTriggered(id) {
        const it = popup._itemOf(popup._menuKey);
        if (!it)
            return;
        if (id === "pasteas") {
            menu.rows = popup._transformRows(it);
            return;
        }
        if (id === "back") {
            menu.rows = popup._menuRows(it);
            return;
        }
        menu.open = false;
        if (id.indexOf("t:") === 0) {
            popup._paste([it.key], {
                mode: "paste",
                text: popup.service.transform(it.d.id, id.slice(2)),
                via: "transform"
            });
        } else if (id === "mark") {
            popup.toggleMark(it.key);
        } else if (id === "pin") {
            popup.togglePin(it);
        } else if (id === "edit") {
            // A right-clicked card need not be the focused one: the editor opens on the focused card.
            popup.moveTo(popup.items.findIndex(x => x.key === it.key));
            popup.startEdit();
        } else if (id === "rename") {
            popup.startRename(it);
        } else if (id === "seal") {
            popup.service.seal(it.d.id);
        } else if (id === "keep") {
            popup.service.keep(it.key);
        } else if (id === "delete") {
            popup.removeItem(it);
        }
    }

    // ---- Keys -------------------------------------------------------------------------------
    function _escape() {
        if (popup.query !== "")
            popup.setQuery("");
        else if (popup.marks.length > 0)
            popup.marks = [];
        else {
            const it = popup.currentItem;
            if (popup._picked && it && popup.service && popup.prefs.copyOnClose) {
                popup.clearPeek();
                popup.service.paste([it.key], {
                    mode: "copy",
                    via: "copy"
                });
            }
            popup.closeRequested();
        }
    }
    // Escape as ONE call, for a host that hears the key itself (the shell's Escape bind swallows it
    // before the popup's focus does): every state the key means something in, then the chain. The
    // editor is checked first -- its own handler is on its text area, which the bind starves.
    function handleEscape() {
        if (popup.editing)
            editor.saveNow();
        else if (popup._renameKey !== "")
            popup._endRename(false);
        else if (menu.open)
            menu.open = false;
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
        if (k === Qt.Key_Alt) {
            popup.altHeld = true;
            e.accepted = true;
            return;
        }
        // The editor, the rename field and the menu own their keys.
        if (popup.editing || popup._renameKey !== "")
            return;
        if (menu.open) {
            menu.handleKey(e);          // Up / Down / Enter; nothing else leaks through an open menu
            e.accepted = true;
            return;
        }
        e.accepted = true;
        if (k === Qt.Key_Left)
            popup.moveTo(popup.currentIndex - 1);
        else if (k === Qt.Key_Right)
            popup.moveTo(popup.currentIndex + 1);
        else if (k === Qt.Key_Home)
            popup.moveTo(0);
        else if (k === Qt.Key_End)
            popup.moveTo(popup.items.length - 1);
        else if (k === Qt.Key_PageUp)
            popup.moveTo(popup.currentIndex - popup._page());
        else if (k === Qt.Key_PageDown)
            popup.moveTo(popup.currentIndex + popup._page());
        else if (k === Qt.Key_Tab)
            popup.stepFilter(1);
        else if (k === Qt.Key_Backtab)
            popup.stepFilter(-1);
        else if (k === Qt.Key_Return || k === Qt.Key_Enter) {
            if (!ctrl && !alt)
                popup.confirm(shift === (popup.prefs.enter === "paste") ? "copy" : "paste");
        } else if (alt && k >= Qt.Key_1 && k <= Qt.Key_9)
            popup.quickPaste(k - Qt.Key_0);
        else if (ctrl && k === Qt.Key_Space)
            popup.toggleMark(popup.currentItem ? popup.currentItem.key : "");
        else if (ctrl && k === Qt.Key_E)
            popup.startEdit();
        else if ((ctrl && k === Qt.Key_T) || k === Qt.Key_Menu)
            popup.openMenuAtCard();
        else if (ctrl && k === Qt.Key_P)
            popup.togglePin(popup.currentItem);
        else if (k === Qt.Key_Delete)
            popup.removeItem(popup.currentItem);
        else if (ctrl && k === Qt.Key_R) {
            if (!e.isAutoRepeat)
                popup.startPeek();
        } else if (k === Qt.Key_Escape)
            popup._escape();
        else if (EK.queryActionOf(k, m) !== null) {
            // Ctrl+Backspace / Alt+Backspace (a word), Ctrl+W (back to the blank), Ctrl+U (the lot).
            if (popup.query !== "")
                popup.setQuery(EK.queryAfter(EK.queryActionOf(k, m), popup.query));
        } else if (k === Qt.Key_Backspace) {
            if (popup.query !== "")
                popup.setQuery(popup.query.slice(0, -1));
        } else if (!ctrl && !alt && popup._printable(e)) {
            // A leading space types nothing; Ctrl+Space marks.
            if (!(e.text === " " && popup.query === ""))
                popup.setQuery(popup.query + e.text);
        } else
            e.accepted = false;
    }
    function handleRelease(e) {
        if (e.isAutoRepeat)
            return;
        if (e.key === Qt.Key_Alt)
            popup.altHeld = false;
        else if (e.key === Qt.Key_R || e.key === Qt.Key_Control)
            popup.clearPeek();
    }
    Keys.onPressed: e => popup.handleKey(e)
    Keys.onReleased: e => popup.handleRelease(e)

    // ---- Layout -------------------------------------------------------------------------------
    // Everything is laid out at the size the popup ASKED for, never at the
    // host's easing box (the box grows from the bar as the popup opens, and a
    // page that followed it would re-lay itself out on the way).
    ClipHeader {
        id: header
        objectName: "clipHeader"
        x: popup.pad
        y: popup.pad
        width: popup.layoutWidth - 2 * popup.pad
        height: implicitHeight
        fontFamily: popup.fontFamily
        filter: popup.filter
        count: popup.items.length
        total: popup.service ? popup.service.entries.count + (popup.service.hidden ? 0 : popup.service.secrets.length) : popup.items.length
        narrowed: popup.filter !== "all" || popup.query.trim() !== ""
        marksCount: popup.marks.length
        undoMs: popup.undoMs
        presenceMs: popup.style ? popup.style.presenceMs : 160
        onQueryEdited: t => {
            popup._focusFirst = true;
            popup.query = t;
        }
        onFilterPicked: id => popup.setFilter(id)
        onSearchEscaped: popup.forceActiveFocus()
        onUndoClicked: {
            if (popup.service)
                popup.service.undoRemove();
            popup.forceActiveFocus();
        }
    }

    ClipShelf {
        id: shelf
        objectName: "clipShelf"
        x: popup.pad
        y: header.y + header.height + popup.pad
        width: popup.layoutWidth - 2 * popup.pad
        height: popup._shelfH
        style: popup.style
        items: popup.items
        stateDir: popup.stateDir
        currentIndex: popup.currentIndex
        marks: popup.marks
        showDigits: popup.altHeld
        peekKey: popup.peekKey
        peekText: popup.peekText
        opacity: popup.editing ? 0 : 1
        enabled: !popup.editing
        Behavior on opacity {
            NumberAnimation {
                duration: popup.style ? popup.style.presenceMs : 160
                easing.type: Easing.OutCubic
            }
        }
        onClicked: i => {
            popup.moveTo(i);
            popup.forceActiveFocus();
        }
        onActivated: i => popup.enterIndex(i)
        onContextRequested: (i, sx, sy) => {
            popup.moveTo(i);
            const p = overlay.mapFromItem(null, sx, sy);
            popup.openMenuFor(i, p.x, p.y);
        }
        onPinClicked: key => popup.togglePin(popup._itemOf(key))
        onKeepClicked: key => {
            if (popup.service)
                popup.service.keep(key);
        }
    }

    ClipEditor {
        id: editor
        objectName: "clipEditor"
        x: shelf.x
        y: shelf.y
        width: shelf.width
        height: shelf.height
        active: popup.editing
        fontFamily: popup.fontFamily
        radius: 14
        fadeMs: popup.style ? popup.style.presenceMs : 160
        onPasteRequested: text => {
            const it = popup.currentItem;
            if (it)
                popup._paste([it.key], {
                    mode: "paste",
                    text: text,
                    via: "edit"
                });
        }
        onSaved: text => popup.saveEdit(text)
        onCancelled: popup.endEdit()
    }

    // The empty states: presence fades, the words swap at once.
    Text {
        id: emptyText
        objectName: "clipEmpty"
        x: shelf.x
        y: shelf.y
        width: shelf.width
        height: shelf.height
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        text: popup._anyStored || popup.query !== "" || popup.filter !== "all" ? "No match" : "Nothing copied yet"
        font.family: popup.fontFamily
        font.pixelSize: 14
        color: Theme.textFaint
        property real f: popup._empty && !popup.editing ? 1 : 0
        Behavior on f {
            NumberAnimation {
                duration: popup.style ? popup.style.presenceMs : 160
                easing.type: Easing.OutCubic
            }
        }
        opacity: emptyText.f
        visible: emptyText.f > 0
    }

    // ---- Floating things: the menu and the rename field -----------------------------------------
    Item {
        id: overlay
        objectName: "clipOverlay"
        anchors.fill: parent
        z: 1000
    }

    FloatingMenu {
        id: menu
        objectName: "clipMenu"
        overlayItem: overlay
        fontFamily: popup.fontFamily
        menuWidth: 180
        // "Paste as" swaps the rows in place and the menu stays up.
        keepOpen: true
        onTriggered: id => popup._menuTriggered(id)
    }

    CarvedSearchField {
        id: renameField
        objectName: "clipRename"
        parent: overlay
        visible: popup._renameKey !== ""
        height: 22
        placeholder: "Title"
        glyph: ""
        escapeClears: false
        fontFamily: popup.fontFamily
        surfaceColor: Theme.listBox
        // Deferred: the Escape goes on to the popup's own handler, which must
        // still find the rename open and leave it alone.
        onEscaped: Qt.callLater(() => popup._endRename(false))
        onHasFocusChanged: {
            if (!renameField.hasFocus && popup._renameKey !== "")
                popup._endRename(false);
        }
        Keys.onReturnPressed: popup._endRename(true)
        Keys.onEnterPressed: popup._endRename(true)
    }
}
