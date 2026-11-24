pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// TrayModel.qml -- the public face of TrayService and TrayMock, once. The two are
// this component with a source of items added (`_setItems`); whatever reads one
// reads the other.
//
//   in:  config       WindowTrayConfig.config: trayOrder, trayHide, trayRename, trayPassive
//        appLookup    AppLookup
//   out: rows         ListModel, ONE role `rec`: a TrayRecord. Mirrored on insert,
//                     remove and reorder -- never rebuilt from an array
//        count, empty, attention ([key] of items in NeedsAttention, in row order)
//        serial       bumps on insert / remove / reorder (a ListModel `move` emits
//                     nothing a binding can watch)
//        log          the calls made on items, one line each (newest last):
//                     "activate <key>", "secondary <key>", "scroll <key> <delta> <horizontal>"
//                     (a mock adds "trigger <key> <path>"); `acted(line)` as they happen
//   fn:  record(key), leftClick(key), middleClick(key), scroll(key, delta, horizontal),
//        menuHandle(key)
//
// ORDER. trayOrder first (item ids, in that order), then registration order; ids in
// trayHide are not rows, nor are passive items while trayPassive is "hide". KEYS are unique and stable: the first item of an id is
// "id", the next "id#2"; an item keeps its key until it goes.
//
// CLICKS do what the item can do (TrayCaps): a left click on an item that has no
// Activate and has a menu asks for the menu; a middle click or a wheel step reaches
// the item only if it implements SecondaryActivate / Scroll. An item whose caps are
// not read yet is assumed to implement them all (the SNI default).
// =============================================================================
Item {
    id: root

    property var config: null
    property var appLookup: null
    // A TrayCaps, or null (a mock sets its records' caps itself).
    property var capsSource: null

    readonly property ListModel rows: ListModel {
        id: rowsModel
    }
    readonly property int count: rowsModel.count
    readonly property bool empty: rowsModel.count === 0
    readonly property var attention: root._attention
    readonly property int serial: root._serial
    readonly property var log: root._log

    signal acted(string line)
    // After a record exists and before it is in the rows.
    signal recordCreated(var rec)

    function record(key: string): var {
        return root._rec(key);
    }

    // A left click ACTIVATES, and only an item that can: one without Activate
    // (nm-applet) or that is only a menu gets nothing. A menu opens on the right
    // button and nowhere else (a left-click menu, nm-applet's
    // ayatana convention, reads as a bug).
    function leftClick(key: string): bool {
        const rec = root._rec(key);
        if (!rec || !rec.item || !rec.canActivate)
            return false;
        rec.item.activate();
        root._note("activate " + key);
        return true;
    }

    function middleClick(key: string): void {
        const rec = root._rec(key);
        if (!rec || !rec.item || rec.caps.secondary === false)
            return;
        rec.item.secondaryActivate();
        root._note("secondary " + key);
    }

    function scroll(key: string, delta: int, horizontal: bool): void {
        const rec = root._rec(key);
        if (!rec || !rec.item || rec.caps.scroll === false)
            return;
        rec.item.scroll(delta, !!horizontal);
        root._note("scroll " + key + " " + delta + " " + (horizontal ? "true" : "false"));
    }

    function menuHandle(key: string): var {
        const rec = root._rec(key);
        return rec && rec.item && rec.hasMenu ? rec.item.menu : null;
    }

    // ---- For the sources ------------------------------------------------------
    property int _serial: 0
    property var _log: []
    property var _attention: []
    property var _recs: ({})            // key -> record, every item (hidden ones too)
    property var _all: []               // [record], registration order
    property var _rowKeys: []           // the keys of the rows, in row order
    readonly property bool _hidePassive: !!root.config && root.config.trayPassive === "hide"

    function _rec(key: string): var {
        return Object.prototype.hasOwnProperty.call(root._recs, key) ? root._recs[key] : null;
    }

    function _note(line: string): void {
        const l = root._log.length >= 200 ? root._log.slice(1) : root._log.slice();
        l.push(line);
        root._log = l;
        root.acted(line);
    }

    function _keyFor(id: string): string {
        const base = id === "" ? "item" : id;
        if (root._rec(base) === null)
            return base;
        for (let n = 2; ; n++)
            if (root._rec(base + "#" + n) === null)
                return base + "#" + n;
    }

    // The items, in registration order. Records of items that went are removed,
    // records of new items made; every record that stays is the same object.
    function _setItems(items: var): void {
        let changed = false;
        const keep = [];
        const gone = [];
        for (let i = 0; i < root._all.length; i++) {
            const rec = root._all[i];
            if (items.indexOf(rec.item) >= 0)
                keep.push(rec);
            else
                gone.push(rec);
        }
        for (let i = 0; i < gone.length; i++) {
            delete root._recs[gone[i].key];
            changed = true;
        }
        for (let i = 0; i < items.length; i++) {
            if (!items[i] || keep.some(r => r.item === items[i]))
                continue;
            const rec = recComp.createObject(root, { item: items[i] });
            rec.key = root._keyFor(rec.itemId);
            rec.config = Qt.binding(() => root.config);
            rec.appLookup = Qt.binding(() => root.appLookup);
            root._recs[rec.key] = rec;
            rec.statusChanged.connect(root._statusChanged);
            if (items[i].iconChanged)
                items[i].iconChanged.connect(() => root._iconChanged(rec));
            root.recordCreated(rec);
            keep.push(rec);
            changed = true;
        }
        // registration order = the order the items came in
        keep.sort((a, b) => items.indexOf(a.item) - items.indexOf(b.item));
        root._all = keep;
        root._applyCaps();
        root._layout(changed);
        // the removed records outlive their rows by a moment: a delegate that is
        // still being torn down must not read a destroyed object
        for (let i = 0; i < gone.length; i++)
            gone[i].destroy(500);
    }

    // (a status decides a row while passive items are hidden)
    function _statusChanged(): void {
        if (root._hidePassive)
            root._layout(false);
        else
            root._attentionDirty();
    }

    function _iconChanged(rec: var): void {
        if (root.capsSource && rec.item)
            root.capsSource.refreshIcon(rec.itemId);
    }

    function _applyCaps(): void {
        const src = root.capsSource;
        if (!src)
            return;
        for (let i = 0; i < root._all.length; i++) {
            const rec = root._all[i];
            const c = src.capsFor(rec.itemId);
            const o = rec.caps;
            if (c.activate !== o.activate || c.secondary !== o.secondary || c.scroll !== o.scroll || c.iconPixmap !== o.iconPixmap || c.attentionIcon !== o.attentionIcon || c.known !== o.known)
                rec.caps = c;
            const n = src.iconNameFor(rec.itemId);
            if (n !== rec.iconName)
                rec.iconName = n;
        }
    }

    // The keys of the rows that should be: not hidden, trayOrder first.
    function _wanted(): var {
        const cfg = root.config;
        const hide = cfg && cfg.trayHide ? cfg.trayHide : [];
        const order = cfg && cfg.trayOrder ? cfg.trayOrder : [];
        const shown = root._all.filter(r => hide.indexOf(r.itemId) < 0 && !(root._hidePassive && r.status === "passive"));
        const rank = r => {
            const i = order.indexOf(r.itemId);
            return i < 0 ? order.length : i;
        };
        const idx = r => root._all.indexOf(r);
        shown.sort((a, b) => rank(a) - rank(b) || idx(a) - idx(b));
        return shown.map(r => r.key);
    }

    // Mirror the wanted keys into the ListModel: remove, then move or insert.
    function _layout(force: bool): void {
        const want = root._wanted();
        let changed = force;
        const have = root._rowKeys;
        for (let i = have.length - 1; i >= 0; i--)
            if (want.indexOf(have[i]) < 0 || root._rec(have[i]) === null) {
                rowsModel.remove(i);
                have.splice(i, 1);
                changed = true;
            }
        for (let i = 0; i < want.length; i++) {
            if (have[i] === want[i])
                continue;
            const j = have.indexOf(want[i]);
            if (j > i) {
                rowsModel.move(j, i, 1);
                have.splice(i, 0, have.splice(j, 1)[0]);
            } else {
                rowsModel.insert(i, { rec: root._rec(want[i]) });
                have.splice(i, 0, want[i]);
            }
            changed = true;
        }
        if (changed) {
            root._rowKeys = have;
            root._serial++;
        }
        root._attentionDirty();
    }

    function _attentionDirty(): void {
        const out = [];
        for (let i = 0; i < root._rowKeys.length; i++) {
            const rec = root._rec(root._rowKeys[i]);
            if (rec && rec.status === "attention")
                out.push(rec.key);
        }
        if (JSON.stringify(out) !== JSON.stringify(root._attention))
            root._attention = out;
    }

    onConfigChanged: root._layout(false)
    on_HidePassiveChanged: root._layout(false)

    Connections {
        target: root.capsSource
        ignoreUnknownSignals: true
        function onSerialChanged() {
            root._applyCaps();
        }
    }

    Component {
        id: recComp
        TrayRecord {
        }
    }
}
