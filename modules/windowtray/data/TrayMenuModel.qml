pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "TrayText.js" as TrayText

// =============================================================================
// TrayMenuModel.qml -- one level of a tray item's context menu, as the rows the
// menu UI draws. A submenu is another TrayMenuModel on the entry's `childHandle`.
//
//   in:  handle   a QsMenuHandle (the item's `menu`, or an entry with children) or a
//                 mock node ({children: [...]}); null = closed
//        mock     true: `handle` is a JS tree with QsMenuEntry's field names (text,
//                 icon, isSeparator, enabled, buttonType, checkState, hasChildren,
//                 children, triggered()); TrayService.mock / TrayMock.mock say which
//        loadTimeoutMs   600: after this `loaded` is true even if nothing arrived
//   out: rows     ListModel, ONE role `rec`: a QtObject { property var d } per row,
//                 d = { index, label, icon, separator, disabled, check:
//                 "none"|"checkbox"|"radio", checked, submenu } (MenuRows' facts).
//                 `index` is the row's POSITION in `rows`, after the separators are
//                 collapsed (no leading, trailing or doubled one) -- the number the UI
//                 hands to trigger() and childHandle()
//        loaded   the entries arrived (or the timeout passed: then `empty` may be true)
//        empty    loaded and no rows (a level the app emptied under an open menu is never `empty`: it is `stale`)
//        stale    the app has emptied this open level and the rows are the last it had (see THE HOLD)
//        title    "" (the owner knows the item's name)
//   fn:  trigger(i) -> bool     the row's entry triggered ONCE per open; false when the
//                               row is a separator, disabled or a submenu, or when this
//                               open has answered already (a fading menu still takes clicks)
//        childHandle(i)         a submenu row's entry (the next `handle`), else null
//        reread()               take the entries again (every change an entry signals does
//                               this by itself; a host that edits a plain JS tree calls it)
//
// LIVE UPDATES. While the menu is open the app can relabel, tick or disable an entry
// (nm-applet flips a checkmark ~30 ms after the click). The entries' own change signals
// land in ONE re-read; rows whose facts did not change are left alone, a changed row's
// `d` is re-assigned on the SAME record, and rows are only appended or removed at the end.
// A new handle clears the rows (a parent's rows must never stand for a child's).
//
// THE HOLD. Some apps empty a submenu while it is open and fill it again a moment later, or never --
// nm-applet's "Available networks" does, on its own scan, which is also why the same menu in waybar closed under the pointer. A level that
// goes from rows to NO rows keeps the rows it had for as long as it stays OPEN (a timed hold is outlasted by the applet's silence): `stale` says the app has none, and the moment it has entries again the rows follow them as any change does (the same records,
// nothing rebuilt). Closing the menu (a new handle, null) ends it. No timer: the menu is the user's, and a list that was there when they
// looked away is the list that is there when they look back. A held row's entry is gone from the app, so `trigger` says false while
// stale rather than call a dead object; nothing is dimmed (an applet that empties and refills in a blink would flash the list grey).
// It is the level's rule, so it holds for every tray item and every submenu.
//
// A LEVEL WHOSE ENTRY IS REPLACED. The hold above covers an app that
// takes the entries out from under a submenu; nm-applet also REBUILDS the menu on a scan -- the "Available networks" entry itself is
// destroyed and a new one with the same label takes its place -- and then this level's `handle` is a dead object and goes null by
// itself. A null the app caused (the entry's `destroyed`) is not the user closing the level: the rows are held, and `successor` (the
// host's way back to the entry that stands where this one stood: the parent level's row of the same label) is asked every 200 ms until
// it answers; the level then ADOPTS the new entry -- same rows, same records, nothing rebuilt -- and follows what it holds as any change.
// A level that is closed on purpose (the host writes `handle`, or a new handle) ends it at once.
//
// MNEMONICS. Quickshell has already stripped "_" and read "__" as "_" in a real menu
// (0.3.1, measured), so only a mock tree -- written as the apps write dbusmenu -- is
// stripped here (TrayText.stripMnemonic).
// =============================================================================
Item {
    id: root

    property var handle: null
    // function () -> the entry standing where `handle` stood (or null): see "A LEVEL WHOSE ENTRY IS REPLACED". The host sets it
    // for a submenu level; the root menu of an item has none (its object outlives the app's rebuilds).
    property var successor: null
    property bool mock: false
    property int loadTimeoutMs: 600

    readonly property ListModel rows: ListModel {
        id: rowsModel
    }
    readonly property bool loaded: root._loaded
    readonly property bool empty: root._loaded && rowsModel.count === 0
    readonly property bool stale: root._held
    readonly property string title: ""

    function trigger(i: int): bool {
        if (root._answered || root._held)
            return false;
        const d = root._ds[i];
        const e = root._entries[i];
        if (!d || !e || d.separator || d.disabled || d.submenu)
            return false;
        // (a row can stand for an entry the app has since removed)
        try {
            e.triggered();
        } catch (err) {
            return false;
        }
        root._answered = true;
        return true;
    }

    function childHandle(i: int): var {
        const d = root._ds[i];
        return d && d.submenu ? root._entries[i] : null;
    }

    function reread(): void {
        Qt.callLater(root._sync);
    }

    // ---- Private ---------------------------------------------------------------
    property bool _loaded: false
    property bool _answered: false
    property bool _held: false         // the app has emptied the level: the rows are the last it had
    property bool _hadHandle: false
    property bool _orphaned: false     // the app destroyed the entry this level shows (its rows are held until a successor is found)
    property bool _adopting: false
    // The entry this level was last given, held by a guarded pointer: it reads null when the APP destroys the entry, and still points at
    // it when the host merely lets go (the `destroyed` signal never reaches a QML handler here, measured).
    property QtObject _shown: null
    property var _entries: []          // the row's entry, by row position
    property var _ds: []               // the row's facts, by row position
    property var _sigs: []             // JSON of the facts, to see what changed

    function _source(): var {
        if (root.mock)
            return root.handle && root.handle.children ? root.handle.children : [];
        const c = opener.children;
        return c ? c.values : [];
    }

    function _facts(e: var): var {
        const sep = !!e.isSeparator;
        return {
            index: 0,
            label: sep ? "" : (root.mock ? TrayText.stripMnemonic(e.text) : String(e.text || "")),
            icon: sep ? "" : String(e.icon || ""),
            separator: sep,
            disabled: e.enabled === false,
            check: e.buttonType === 1 ? "checkbox" : (e.buttonType === 2 ? "radio" : "none"),
            checked: e.checkState === 2,
            submenu: !!e.hasChildren
        };
    }

    function _sync(): void {
        if (root.handle === null || root.handle === undefined)
            return;
        const src = root._source();
        const raw = [];
        for (let i = 0; i < src.length; i++) {
            const d = root._facts(src[i]);
            raw.push({ separator: d.separator, entry: src[i], d: d });
        }
        const kept = TrayText.collapseSeparators(raw);
        // THE HOLD: rows that suddenly have nothing under them stay while the level is open (see the header)
        if (kept.length === 0 && rowsModel.count > 0) {
            root._held = true;
            return;
        }
        root._held = false;
        const entries = [];
        const ds = [];
        const sigs = [];
        for (let j = 0; j < kept.length; j++) {
            kept[j].d.index = j;
            entries.push(kept[j].entry);
            ds.push(kept[j].d);
            sigs.push(JSON.stringify(kept[j].d));
        }
        // a row whose facts are unchanged is not touched; a changed one keeps its record
        const old = root._sigs;
        for (let j = 0; j < ds.length; j++) {
            if (j < rowsModel.count) {
                if (old[j] !== sigs[j])
                    rowsModel.get(j).rec.d = ds[j];
            } else {
                rowsModel.append({ rec: rowComp.createObject(root, { d: ds[j] }) });
            }
        }
        if (rowsModel.count > ds.length)
            rowsModel.remove(ds.length, rowsModel.count - ds.length);
        root._entries = entries;
        root._ds = ds;
        root._sigs = sigs;
        if (src.length > 0)
            root._loaded = true;
    }

    function _reset(): void {
        loadTimer.stop();
        adoptTimer.stop();
        root._orphaned = false;
        root._held = false;
        rowsModel.clear();
        root._entries = [];
        root._ds = [];
        root._sigs = [];
        root._loaded = false;
        root._answered = false;
        if (root.handle !== null && root.handle !== undefined) {
            loadTimer.restart();
            if (root.mock)
                root._sync();
        }
    }

    // The entry that was the handle went away on its own: held, and looked for again (see the header).
    function _orphan(): void {
        if (rowsModel.count === 0 || !root.successor) {
            root._hadHandle = false;
            root._reset();
            return;
        }
        root._orphaned = true;
        root._held = true;
        adoptTimer.restart();
    }
    function _adopt(): void {
        const h = root.successor ? root.successor() : null;
        if (!h)
            return;
        root._adopting = true;
        root.handle = h;
        root._adopting = false;
    }
    onHandleChanged: {
        if (root._adopting) {
            root._orphaned = false;
            root._hadHandle = true;
            root._shown = root.handle;
            adoptTimer.stop();
            root.reread();
            return;
        }
        const none = root.handle === null || root.handle === undefined;
        // a null with the entry gone (and not let go of by the host): the app rebuilt its menu under us
        if (none && !root.mock && root._hadHandle && root._shown === null) {
            root._orphan();
            return;
        }
        root._hadHandle = !none && !root.mock;
        root._shown = root._hadHandle ? root.handle : null;
        root._reset();
    }
    Timer {
        id: adoptTimer
        interval: 200
        repeat: true
        onTriggered: root._adopt()
    }
    onMockChanged: root._reset()
    Component.onCompleted: root._reset()

    Timer {
        id: loadTimer
        interval: root.loadTimeoutMs
        onTriggered: root._loaded = true
    }

    QsMenuOpener {
        id: opener
        menu: root.mock || root.handle === null || root.handle === undefined ? null : root.handle
    }

    // The opener's list arriving or changing. ONE re-read per burst: Quickshell takes a layout update's entries out one at a
    // time (a `valuesChanged` for each), so reading at every signal would show an emptied level shrinking row by row and
    // hold only the last row -- the hold is to keep the list the app had, and that is the state before the burst.
    Connections {
        target: opener
        function onChildrenChanged() {
            if (!root.mock)
                root.reread();
        }
    }
    Connections {
        target: opener.children
        ignoreUnknownSignals: true
        function onValuesChanged() {
            if (!root.mock)
                root.reread();
        }
    }

    // A mock node (a QObject) whose list of entries is replaced; a plain JS tree has no signal.
    Connections {
        target: root.mock && root.handle && root.handle.childrenChanged !== undefined ? root.handle : null
        ignoreUnknownSignals: true
        function onChildrenChanged() {
            root.reread();
        }
    }

    // Each entry's own changes (a relabel, a tick, a disabled row) -- one re-read.
    // Real entries and the mock's nodes alike signal them.
    Instantiator {
        model: root.mock ? (root.handle && root.handle.children ? root.handle.children : []) : opener.children
        delegate: QtObject {
            id: watch
            required property var modelData
            property Connections _c: Connections {
                target: watch.modelData
                ignoreUnknownSignals: true
                function onTextChanged() {
                    root.reread();
                }
                function onIconChanged() {
                    root.reread();
                }
                function onEnabledChanged() {
                    root.reread();
                }
                function onButtonTypeChanged() {
                    root.reread();
                }
                function onCheckStateChanged() {
                    root.reread();
                }
                function onIsSeparatorChanged() {
                    root.reread();
                }
                function onHasChildrenChanged() {
                    root.reread();
                }
            }
        }
    }

    Component {
        id: rowComp
        QtObject {
            property var d: null
        }
    }
}
