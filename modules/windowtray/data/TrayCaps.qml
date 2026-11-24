pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// TrayCaps.qml -- what each tray item CAN do, and the icon Quickshell loses.
// Processes only (busctl on the session bus): a few per registration, none per
// frame, none when `live` is false.
//
//   capsFor(itemId)    -> { activate, secondary, scroll, iconPixmap, attentionIcon, known }
//   iconNameFor(itemId) -> string   ("" until read)
//   refreshIcon(itemId)             re-read IconName and AttentionIconName: ONE call in
//                                   flight per item, a request during it re-runs once
//   refresh()                       re-read the watcher's list, read new entries
//   serial                          bumps when any answer changes
//
// WHY. A call to a method an item does not implement is silent:
// nm-applet (ayatana) has no Activate, blueman no SecondaryActivate or Scroll. So
// the tray reads what each item implements ONCE per registration, and a left click
// on an item without Activate opens its menu instead. An item whose caps are not
// read yet (`known` false) is assumed to implement everything, as the SNI default.
//
// And Quickshell 0.3.1 draws the missing-icon checkerboard (`image://qspixmap/...`) for
// an item in NeedsAttention that has no icon of its own for that state: nm-applet's
// AttentionIconName is "" and it has no AttentionIconPixmap. (It is not
// "the first NewIcon of an item without IconPixmap": the status is the trigger, an Active item
// follows every NewIcon fine.) `attentionIcon` says whether the item has such an icon
// (a name, or a non-empty AttentionIconPixmap) and `iconNameFor` is the normal icon's
// name to draw instead (`image://icon/<name>`, TrayRecord.iconSource). `iconPixmap`
// says whether the item answers Get(IconPixmap) at all (informational).
//
// HOW. The watcher's RegisteredStatusNotifierItems lists ":<unique>/<path>"; per
// new entry ONE sh reads Id, IconName, whether IconPixmap answers, and the
// introspection XML (the methods of org.kde.StatusNotifierItem). The service name
// and path come from the bus -- any client chooses them -- so they are checked
// against the D-Bus name grammar and handed to the shell as arguments, never as
// part of its text. One Process, a queue: jobs run one after another.
// =============================================================================
Item {
    id: root

    property bool live: false

    readonly property int serial: root._serial

    function capsFor(itemId: string): var {
        const e = root._byId[itemId];
        if (!e || !e.known)
            return { activate: true, secondary: true, scroll: true, iconPixmap: e ? e.iconPixmap : true, attentionIcon: true, known: false };
        return { activate: e.activate, secondary: e.secondary, scroll: e.scroll, iconPixmap: e.iconPixmap,
                 attentionIcon: e.attentionName !== "" || e.attentionPixmap, known: true };
    }

    function iconNameFor(itemId: string): string {
        const e = root._byId[itemId];
        return e ? e.iconName : "";
    }

    function refreshIcon(itemId: string): void {
        if (!root.live)
            return;
        const e = root._byId[itemId];
        if (!e) {
            root._iconDirty[itemId] = true;
            return;
        }
        root._scheduleIcon(e);
    }

    function refresh(): void {
        if (!root.live)
            return;
        if (root._listRunning) {
            root._relist = true;
            return;
        }
        if (root._listQueued)
            return;
        root._listQueued = true;
        root._enqueue({ kind: "list" });
    }

    // ---- Private ---------------------------------------------------------------
    property int _serial: 0
    // ":1.8/org/ayatana/..." -> { key, svc, path, id, known, activate, secondary, scroll,
    // iconPixmap, iconName, iconQueued, iconRunning, iconAgain }; all mutated in place
    property var _entries: ({})
    property var _byId: ({})
    property var _iconDirty: ({})
    property var _queue: []
    property var _job: null
    property bool _listQueued: false
    property bool _listRunning: false
    property bool _relist: false

    readonly property string _script:
        'i=$(busctl --user get-property "$1" "$2" org.kde.StatusNotifierItem Id 2>/dev/null) || exit 3\n'
        + 'n=$(busctl --user get-property "$1" "$2" org.kde.StatusNotifierItem IconName 2>/dev/null)\n'
        + 'a=$(busctl --user get-property "$1" "$2" org.kde.StatusNotifierItem AttentionIconName 2>/dev/null)\n'
        + 'ap=$(busctl --user get-property "$1" "$2" org.kde.StatusNotifierItem AttentionIconPixmap 2>/dev/null | head -c 24)\n'
        + 'if busctl --user get-property "$1" "$2" org.kde.StatusNotifierItem IconPixmap >/dev/null 2>&1; then p=1; else p=0; fi\n'
        + 'echo "ID $i"; echo "ICON $n"; echo "ATTN $a"; echo "ATTNPIX $ap"; echo "PIX $p"\n'
        + 'busctl --user introspect --xml-interface "$1" "$2" 2>/dev/null'

    // The two names a refresh re-reads (an item changes either with a NewIcon / NewAttentionIcon)
    readonly property string _iconScript:
        'busctl --user get-property "$1" "$2" org.kde.StatusNotifierItem IconName 2>/dev/null\n'
        + 'echo "@@"\n'
        + 'busctl --user get-property "$1" "$2" org.kde.StatusNotifierItem AttentionIconName 2>/dev/null'

    function _enqueue(job: var): void {
        root._queue.push(job);
        Qt.callLater(root._pump);
    }

    function _pump(): void {
        if (!root.live || root._job !== null || root._queue.length === 0 || proc.running)
            return;
        const job = root._queue.shift();
        root._job = job;
        job.got = false;
        job.text = "";
        if (job.kind === "list") {
            root._listQueued = false;
            root._listRunning = true;
            proc.command = ["busctl", "--user", "get-property", "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
                            "org.kde.StatusNotifierWatcher", "RegisteredStatusNotifierItems"];
        } else {
            const e = root._entries[job.entry];
            if (!e) {
                root._job = null;
                Qt.callLater(root._pump);
                return;
            }
            if (job.kind === "icon") {
                e.iconQueued = false;
                e.iconRunning = true;
                proc.command = ["sh", "-c", root._iconScript, "sh", e.svc, e.path];
            } else {
                proc.command = ["sh", "-c", root._script, "sh", e.svc, e.path];
            }
        }
        proc.running = true;
    }

    function _unq(s: string): string {
        return s.replace(/\\(.)/g, "$1");
    }

    // A watcher entry is "<service><path>"; a bare service name is an item at the
    // default path. null for anything the D-Bus grammar does not allow.
    function _split(entry: string): var {
        const i = entry.indexOf("/");
        const svc = i < 0 ? entry : entry.substring(0, i);
        const path = i < 0 ? "/StatusNotifierItem" : entry.substring(i);
        if (!/^[A-Za-z0-9_.:\-]+$/.test(svc) || svc.charAt(0) === "-" || !/^\/[A-Za-z0-9_\/]*$/.test(path))
            return null;
        return { svc: svc, path: path };
    }

    function _rebuild(): void {
        const by = {};
        for (const k in root._entries)
            if (root._entries[k].id !== "")
                by[root._entries[k].id] = root._entries[k];
        root._byId = by;
    }

    function _scheduleIcon(e: var): void {
        if (e.iconRunning) {
            e.iconAgain = true;
            return;
        }
        if (e.iconQueued)
            return;
        e.iconQueued = true;
        root._enqueue({ kind: "icon", entry: e.key });
    }

    function _finish(): void {
        const job = root._job;
        if (job === null)
            return;
        root._job = null;
        const text = job.text;
        if (job.kind === "list")
            root._listDone(text);
        else if (job.kind === "entry")
            root._entryDone(job.entry, text);
        else
            root._iconDone(job.entry, text);
        Qt.callLater(root._pump);
    }

    function _listDone(text: string): void {
        root._listRunning = false;
        const want = {};
        const re = /"((?:[^"\\]|\\.)*)"/g;
        let m;
        let changed = false;
        while ((m = re.exec(text)) !== null) {
            const entry = root._unq(m[1]);
            const sp = root._split(entry);
            if (sp === null)
                continue;
            want[entry] = true;
            if (!(entry in root._entries)) {
                root._entries[entry] = { key: entry, svc: sp.svc, path: sp.path, id: "", known: false, activate: true, secondary: true,
                                         scroll: true, iconPixmap: true, iconName: "", attentionName: "", attentionPixmap: false,
                                         iconQueued: false, iconRunning: false, iconAgain: false };
                root._enqueue({ kind: "entry", entry: entry });
            }
        }
        for (const k in root._entries)
            if (!want[k]) {
                delete root._entries[k];
                changed = true;
            }
        if (changed) {
            root._rebuild();
            root._serial++;
        }
        if (root._relist) {
            root._relist = false;
            root.refresh();
        }
    }

    function _entryDone(key: string, text: string): void {
        const e = root._entries[key];
        if (!e)
            return;
        const id = /^ID s "((?:[^"\\]|\\.)*)"/m.exec(text);
        if (id === null) {
            // not up yet, or gone: the next refresh asks again
            delete root._entries[key];
            return;
        }
        const icon = /^ICON s "((?:[^"\\]|\\.)*)"/m.exec(text);
        const pix = /^PIX (\d)/m.exec(text);
        const attn = /^ATTN s "((?:[^"\\]|\\.)*)"/m.exec(text);
        const attnPix = /^ATTNPIX a\(iiay\) (\d+)/m.exec(text);
        const ib = text.indexOf('<interface name="org.kde.StatusNotifierItem">');
        const block = ib < 0 ? "" : text.substring(ib, Math.max(ib, text.indexOf("</interface>", ib)));
        const has = name => block.indexOf('<method name="' + name + '"') >= 0;
        e.id = root._unq(id[1]);
        e.iconName = icon === null ? "" : root._unq(icon[1]);
        e.iconPixmap = pix === null || pix[1] === "1";
        e.attentionName = attn === null ? "" : root._unq(attn[1]);
        e.attentionPixmap = attnPix !== null && Number(attnPix[1]) > 0;
        e.known = ib >= 0;
        e.activate = ib < 0 || has("Activate");
        e.secondary = ib < 0 || has("SecondaryActivate");
        e.scroll = ib < 0 || has("Scroll");
        root._rebuild();
        root._serial++;
        if (root._iconDirty[e.id]) {
            delete root._iconDirty[e.id];
            root._scheduleIcon(e);
        }
    }

    function _iconDone(key: string, text: string): void {
        const e = root._entries[key];
        if (!e)
            return;
        e.iconRunning = false;
        const parts = text.split("@@");
        const icon = /^s "((?:[^"\\]|\\.)*)"/m.exec(parts[0]);
        const attn = parts.length > 1 ? /^s "((?:[^"\\]|\\.)*)"/m.exec(parts[1]) : null;
        const name = icon === null ? e.iconName : root._unq(icon[1]);
        const attention = attn === null ? "" : root._unq(attn[1]);
        if (name !== e.iconName || attention !== e.attentionName) {
            e.iconName = name;
            e.attentionName = attention;
            root._serial++;
        }
        if (e.iconAgain) {
            e.iconAgain = false;
            root._scheduleIcon(e);
        }
    }

    Process {
        id: proc
        stdout: StdioCollector {
            onStreamFinished: {
                if (root._job !== null) {
                    root._job.text = this.text;
                    root._job.got = true;
                    giveUp.stop();
                    root._finish();
                }
            }
        }
    }

    // A process that ended without its output stream finishing (it never started,
    // it was killed) must not hold the queue.
    Connections {
        target: proc
        function onExited(exitCode, exitStatus) {
            if (root._job !== null && !root._job.got)
                giveUp.restart();
            Qt.callLater(root._pump);
        }
    }
    Timer {
        id: giveUp
        interval: 150
        onTriggered: root._finish()
    }

    onLiveChanged: if (root.live) root.refresh()
    Component.onCompleted: if (root.live) root.refresh()
}
