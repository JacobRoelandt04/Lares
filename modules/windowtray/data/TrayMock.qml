pragma ComponentBehavior: Bound

import QtQuick
import "TrayMockSpecs.js" as Specs

// =============================================================================
// TrayMock.qml -- TrayService's API over scripted items, for the mockup and the
// probes. Never touches SystemTray or the bus.
//
//   in:  seed (true): start with the three default items (below)
//        and TrayModel's config / appLookup
//   out: TrayModel's (rows, count, empty, attention, serial, log, record(key),
//        leftClick / middleClick / scroll / menuHandle, acted), and
//        mock: true       the owner sets TrayMenuModel.mock from it
//        chatSpec         the spec that add() takes to bring the chat item back
//   fn:  add(spec) -> key, remove(key) -> bool, clear(), reset() (the defaults again)
//        setStatus(key, "Passive"|"Active"|"NeedsAttention"), setIcon(key, url),
//        setTooltip(key, title, description)
//
// THE DEFAULTS are TrayMockSpecs.js: the REAL blueman and nm-applet (their captured
// properties, implemented methods and whole menus) and "chat", a chat app with a
// checkbox and a submenu of radio rows. A spec is
//   { id, title, icon (URL), status, category, tooltipTitle, tooltipDescription,
//     hasMenu, onlyMenu, methods ("Activate", "SecondaryActivate", "Scroll"),
//     menu: [{ text, icon, isSeparator, enabled, buttonType (1 check, 2 radio),
//              checkState (2 checked), children }] }
// and its menu is handed out as nodes with QsMenuEntry's field names that CHANGE LIKE THE
// REAL ONES (a checkbox flips, a radio takes the selection from its siblings) and notify,
// which TrayMenuModel follows with no help. Labels are as dbusmenu apps write them
// ("_Exit"); the mock-mode TrayMenuModel strips the mnemonics.
//
// `log` is TrayModel's ("activate <key>", ...) plus "trigger <key> <path>" for a menu
// entry, <path> being the entry's indices in the raw menu joined by "/" ("3/0").
// =============================================================================
TrayModel {
    id: root

    readonly property bool mock: true
    property bool seed: true
    readonly property var chatSpec: Specs.chat

    function add(spec: var): string {
        const status = root._statusNumber(spec.status);
        const it = itemComp.createObject(root, {
            trayId: String(spec.id || ""),
            title: String(spec.title || ""),
            icon: String(spec.icon || ""),
            status: status === undefined ? 1 : status,
            category: spec.category === "Hardware" ? 0 : (spec.category === "SystemServices" ? 1 : 2),
            tooltipTitle: String(spec.tooltipTitle || ""),
            tooltipDescription: String(spec.tooltipDescription || ""),
            hasMenu: spec.hasMenu !== undefined ? !!spec.hasMenu : !!spec.menu,
            onlyMenu: !!spec.onlyMenu,
            methods: spec.methods || ["Activate", "SecondaryActivate", "Scroll"]
        });
        if (spec.menu) {
            const top = entryComp.createObject(root, { owner: it, hasChildren: true });
            top.children = root._build(it, spec.menu, "");
            it.menu = top;
        }
        root._items.push(it);
        root._setItems(root._items.slice());
        const rec = root._recOf(it);
        return rec ? rec.key : "";
    }

    function remove(key: string): bool {
        const rec = root.record(key);
        if (!rec)
            return false;
        const it = rec.item;
        root._items.splice(root._items.indexOf(it), 1);
        root._setItems(root._items.slice());
        root._dispose(it);
        return true;
    }

    function clear(): void {
        const gone = root._items;
        root._items = [];
        root._setItems([]);
        for (let i = 0; i < gone.length; i++)
            root._dispose(gone[i]);
    }

    function reset(): void {
        root.clear();
        root.add(Specs.blueman);
        root.add(Specs.nmApplet);
        root.add(Specs.chat);
    }

    function setStatus(key: string, status: var): void {
        const rec = root.record(key);
        const n = root._statusNumber(status);
        if (rec && rec.item && n !== undefined)
            rec.item.status = n;
    }

    function setIcon(key: string, url: string): void {
        const rec = root.record(key);
        if (rec && rec.item)
            rec.item.icon = url;
    }

    function setTooltip(key: string, title: string, description: string): void {
        const rec = root.record(key);
        if (rec && rec.item) {
            rec.item.tooltipTitle = title;
            rec.item.tooltipDescription = description;
        }
    }

    // ---- Private ---------------------------------------------------------------
    property var _items: []

    function _statusNumber(s: var): var {
        if (typeof s === "number")
            return s >= 0 && s <= 2 ? s : undefined;
        const t = String(s).toLowerCase();
        if (t === "passive")
            return 0;
        if (t === "active")
            return 1;
        if (t === "needsattention" || t === "attention")
            return 2;
        return undefined;
    }

    function _recOf(it: var): var {
        for (let i = 0; i < root._all.length; i++)
            if (root._all[i].item === it)
                return root._all[i];
        return null;
    }

    function _build(owner: var, list: var, base: string): var {
        const out = [];
        for (let i = 0; i < list.length; i++) {
            const t = list[i];
            const path = base === "" ? String(i) : base + "/" + i;
            const kids = !!(t.children && t.children.length);
            const e = entryComp.createObject(root, {
                owner: owner,
                path: path,
                text: String(t.text || ""),
                icon: String(t.icon || ""),
                isSeparator: !!t.isSeparator,
                enabled: t.enabled !== false,
                buttonType: t.buttonType || 0,
                checkState: t.checkState || 0,
                hasChildren: kids
            });
            if (kids)
                e.children = root._build(owner, t.children, path);
            out.push(e);
        }
        for (let i = 0; i < out.length; i++)
            out[i].siblings = out;
        return out;
    }

    function _walk(entry: var, fn: var): void {
        fn(entry);
        for (let i = 0; i < entry.children.length; i++)
            root._walk(entry.children[i], fn);
    }

    // The item and its menu go a moment after its row, so a delegate still being
    // torn down never reads a destroyed object.
    function _dispose(it: var): void {
        if (it.menu)
            root._walk(it.menu, e => e.destroy(500));
        it.destroy(500);
    }

    function _entryTriggered(entry: var): void {
        const rec = root._recOf(entry.owner);
        root._note("trigger " + (rec ? rec.key : "?") + " " + entry.path);
        if (entry.buttonType === 1) {
            entry.checkState = entry.checkState === 2 ? 0 : 2;
        } else if (entry.buttonType === 2) {
            for (let i = 0; i < entry.siblings.length; i++)
                if (entry.siblings[i].buttonType === 2)
                    entry.siblings[i].checkState = entry.siblings[i] === entry ? 2 : 0;
        }
    }

    onRecordCreated: rec => {
        const m = rec.item.methods;
        rec.caps = {
            activate: m.indexOf("Activate") >= 0,
            secondary: m.indexOf("SecondaryActivate") >= 0,
            scroll: m.indexOf("Scroll") >= 0,
            iconPixmap: true,
            attentionIcon: true,
            known: true
        };
    }

    Component.onCompleted: if (root.seed) root.reset()

    Component {
        id: itemComp
        // SystemTrayItem's names; `trayId` is its `id`
        QtObject {
            property string trayId: ""
            property string title: ""
            property int status: 1
            property int category: 1
            property string icon: ""
            property string tooltipTitle: ""
            property string tooltipDescription: ""
            property bool hasMenu: false
            property bool onlyMenu: false
            property var menu: null
            property var methods: []
            function activate(): void {
            }
            function secondaryActivate(): void {
            }
            function scroll(delta: int, horizontal: bool): void {
            }
        }
    }

    Component {
        id: entryComp
        // QsMenuEntry's names
        QtObject {
            id: entry
            property var owner: null
            property string path: ""
            property var siblings: []
            property string text: ""
            property string icon: ""
            property bool isSeparator: false
            property bool enabled: true
            property int buttonType: 0
            property int checkState: 0
            property bool hasChildren: false
            property var children: []
            function triggered(): void {
                root._entryTriggered(entry);
            }
        }
    }
}
