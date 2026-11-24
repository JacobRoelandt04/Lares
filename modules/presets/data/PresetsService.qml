pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Hyprland
import Quickshell.Io

import "../../common/system"
import "PresetFixtures.js" as Fixtures
import "PresetLockWatch.js" as LockWatch

// =============================================================================
// PresetsService.qml -- the desktop presets, the shell's part (docs/presets.md). ONE per shell, injected into every screen's popup.
//
// Everything that knows a window is the tool's (tools/session/lares-session `preset ...`: the files, the capture, the plan, the load);
// this service only asks it and keeps what it answered:
//
//   presets    [{ name, slug, created, updated, windows, workspaces, face, deleted }] -- `preset list --json`, read on refresh()
//              (the shell's start, so the first open has its size; the popup's open) and after every verb. `deleted`: a preset in its Undo window (the file is in the tool's trash;
//              undo() puts it back, the window's end drops the row)
//   current    { windows, workspaces, face } -- the live desktop (`preset current --json`), read on refreshCurrent(), and FOLLOWED while
//              watched (holdWatch / releaseWatch / desktopChanged, below): the save card shows it
//   save(name, over, cb)          cb(ok, reason)   reason: "exists" | "name" | "missing" | "failed"
//   rename(old, new, cb)          cb(ok, reason)
//   remove(name)                  to the trash; the row stays `deleted` for `undoMs`
//   undo(name)                    back from the trash
//   plan(name, mode, cb)          cb({ close: [...], reuse: [...], launch: [...] })   (`load --dry --json`: what a load would do)
//   load(name, mode)              mode "replace" | "add": through the session service (its progress and result toasts)
//
// No poll: a preset changes only through these verbs (or `lares session preset` typed in a terminal, which the next open reads). The
// live desktop is read again on Hyprland's own events while a Presets tab is on show, never on a clock (a group's lock, which Hyprland
// announces nowhere, through a watcher the service installs in the compositor for that time: PresetLockWatch.js).
// A mock (`live: false`) runs nothing: it serves `PresetFixtures.js`, answers the verbs in memory, and records every call in `calls`.
// =============================================================================
Item {
    id: root

    property bool live: false
    property var session: null
    property string tool: RepoRoot.dir + "/tools/session/lares-session"
    property string python: "python3"
    // A deleted preset's Undo, ms.
    property int undoMs: 5000
    // A load that closes other windows asks first (session.jsonc presets.confirmReplace).
    readonly property bool confirmReplace: !root.session || root.session.confirmReplace

    readonly property var presets: root._presets
    readonly property var current: root._current
    readonly property bool ready: root._ready
    property var _presets: []
    property var _current: null
    property bool _ready: false

    // the Undo windows: slug -> the wall instant it ends
    property var _deleted: ({})

    property var calls: []
    function _record(what: string): void {
        const c = root.calls.slice();
        c.push(what);
        root.calls = c.length > 200 ? c.slice(c.length - 200) : c;
    }

    // ---- the mock's memory -------------------------------------------------------------------------------
    property var mockPresets: Fixtures.presets()
    property var mockCurrent: Fixtures.current()
    // how many windows a replace would close, per preset name (a mock answer; absent: 3)
    property var mockClose: ({})

    function slugOf(name: string): string {
        return String(name).trim().toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
    }
    function validName(name: string): bool {
        const n = String(name).trim();
        return n.length > 0 && n.length <= 40 && root.slugOf(n) !== "";
    }

    // ---- reading -------------------------------------------------------------------------------------------
    // Once at the start: an open takes its columns and rows from what is known, and the list takes the tool ~0.2 s.
    Component.onCompleted: {
        if (root.live)
            root.refresh();
    }
    function refresh(): void {
        root._record("list");
        if (!root.live) {
            root._publish(root.mockPresets);
            return;
        }
        root._run(["preset", "list", "--json"], (code, d) => {
            if (code === 0 && d && d.presets)
                root._publish(d.presets);
        });
    }
    function refreshCurrent(): void {
        root._record("current");
        if (!root.live) {
            root._setCurrent(root.mockCurrent);
            return;
        }
        if (root._currentBusy) {          // one read at a time; a change during it reads once more after it
            root._currentAgain = true;
            return;
        }
        root._currentBusy = true;
        root._run(["preset", "current", "--json"], (code, d) => {
            root._currentBusy = false;
            if (code === 0 && d && d.face)
                root._setCurrent(d);
            if (root._currentAgain) {
                root._currentAgain = false;
                root.refreshCurrent();
            }
        });
    }
    property bool _currentBusy: false
    property bool _currentAgain: false
    // The same desktop read again changes nothing: the card keeps its picture (and the name being typed under it).
    function _setCurrent(d: var): void {
        if (JSON.stringify(d) !== JSON.stringify(root._current))
            root._current = d;
    }

    // ---- the live desktop while a Presets tab is on show ----
    // The save card shows `current`, so it follows the desktop while it is up (the user, 2026-11-23: a change on the desktop must show on
    // the card, "since I might want to switch something right before saving"). Each owner that shows the tab HOLDS the watch, by
    // identity (one service, a popup per screen). While held, Hyprland's window, workspace and monitor events and every display change an
    // owner reports (desktopChanged) restart ONE debounce, and its end reads `current` again: a burst of events is one read.
    property int watchDebounceMs: 250
    property var _watchers: []
    readonly property bool watching: root._watchers.length > 0
    // A group's lock is told by no event: while watched, PresetLockWatch.js's watcher runs inside Hyprland and sends `custom>>EVENT` on a
    // change. Started when the watch is first held, renewed (its lease is 120 s) every `lockLeaseRenewMs` and after a config reload (a fresh
    // Lua state), stopped when the last holder lets go. The mock records it in `calls` and dispatches nothing.
    property int lockLeaseRenewMs: 60000
    onWatchingChanged: root._lockWatch(root.watching ? "start" : "stop")
    property bool _lockStarted: false
    function _lockWatch(what: string): void {
        if (what === "stop" ? !root._lockStarted : !root.watching)
            return;
        root._lockStarted = what !== "stop";
        root._record("lockwatch " + what);
        if (root.live)
            Hyprland.dispatch(what === "stop" ? LockWatch.stop() : LockWatch.start());
    }
    Timer {
        interval: root.lockLeaseRenewMs
        repeat: true
        running: root.watching
        onTriggered: root._lockWatch("renew")
    }
    function holdWatch(who: var): void {
        if (root._watchers.indexOf(who) >= 0)
            return;
        root._watchers = root._watchers.concat([who]);
    }
    function releaseWatch(who: var): void {
        if (root._watchers.indexOf(who) < 0)
            return;
        root._watchers = root._watchers.filter(w => w !== who);
        if (!root.watching)
            watchDebounce.stop();
    }
    function desktopChanged(why: string): void {
        if (root.watching)
            watchDebounce.restart();
    }
    // A group's shown tab changes with `activewindowv2` alone (a tab flip sends nothing else); grouping and ungrouping send `togglegroup`,
    // `moveintogroup`, `moveoutofgroup`; `lockgroups` is the lock of ALL groups; one group's lock comes as `custom>>` from the lock watch.
    readonly property var _desktopEvents: ["openwindow", "closewindow", "movewindow", "movewindowv2", "workspace", "workspacev2", "moveworkspace",
        "moveworkspacev2", "createworkspace", "destroyworkspace", "changefloatingmode", "fullscreen", "activespecial", "focusedmon",
        "monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2", "configreloaded", "activewindowv2", "togglegroup",
        "moveintogroup", "moveoutofgroup", "lockgroups"]
    // One raw event: is it a change of the desktop the card shows? (the probe asks this with Hyprland's own event shapes)
    function isDesktopEvent(name: string, data: string): bool {
        if (name === "custom")
            return data === LockWatch.EVENT;
        return root._desktopEvents.indexOf(name) >= 0;
    }
    Connections {
        target: Hyprland
        enabled: root.live && root.watching
        function onRawEvent(ev: var): void {
            if (ev.name === "configreloaded")
                root._lockWatch("renew");
            if (root.isDesktopEvent(ev.name, ev.data))
                root.desktopChanged(ev.name);
        }
    }
    Timer {
        id: watchDebounce
        interval: root.watchDebounceMs
        onTriggered: {
            if (root.watching)
                root.refreshCurrent();
        }
    }
    // The tool's rows plus the ones in their Undo window (the tool no longer lists those), in the tool's order.
    function _publish(rows: var): void {
        const now = Date.now();
        const out = [];
        const seen = {};
        const src = rows || [];
        for (let i = 0; i < src.length; i++) {
            const r = Object.assign({}, src[i]);
            r.deleted = false;
            seen[r.slug] = true;
            out.push(r);
        }
        for (const slug in root._deleted) {
            const d = root._deleted[slug];
            if (d.until <= now || seen[slug])
                continue;
            const r = Object.assign({}, d.row);
            r.deleted = true;
            out.push(r);
        }
        out.sort((a, b) => String(a.name).toLowerCase().localeCompare(String(b.name).toLowerCase()));
        root._presets = out;
        root._ready = true;
    }
    function _rowOf(name: string): var {
        const slug = root.slugOf(name);
        for (let i = 0; i < root._presets.length; i++)
            if (root._presets[i].slug === slug)
                return root._presets[i];
        return null;
    }

    // ---- the verbs -------------------------------------------------------------------------------------------
    function save(name: string, over: bool, cb: var): void {
        const n = String(name).trim();
        root._record("save " + n + (over ? " --over" : ""));
        if (!root.validName(n)) {
            root._answer(cb, false, "name");
            return;
        }
        if (!root.live) {
            const slug = root.slugOf(n);
            const list = root.mockPresets.slice();
            const at = list.findIndex(p => p.slug === slug);
            if (at >= 0 && !over) {
                root._answer(cb, false, "exists");
                return;
            }
            const cur = root.mockCurrent;
            const row = { name: at >= 0 ? list[at].name : n, slug: slug, created: Date.now() / 1000, updated: Date.now() / 1000,
                windows: cur.windows, workspaces: cur.workspaces, face: cur.face };
            if (at >= 0)
                list[at] = row;
            else
                list.push(row);
            root.mockPresets = list;
            root._publish(list);
            root._answer(cb, true, "");
            return;
        }
        root._run(["preset", "save", n].concat(over ? ["--over"] : []).concat(["--json"]), (code, d) => {
            root._answer(cb, code === 0, code === 0 ? "" : ((d && d.reason) || "failed"));
            root.refresh();
        });
    }
    function rename(oldName: string, newName: string, cb: var): void {
        const n = String(newName).trim();
        root._record("rename " + oldName + " -> " + n);
        if (!root.validName(n)) {
            root._answer(cb, false, "name");
            return;
        }
        if (n === oldName) {
            root._answer(cb, true, "");
            return;
        }
        if (!root.live) {
            const list = root.mockPresets.slice();
            const at = list.findIndex(p => p.slug === root.slugOf(oldName));
            const clash = list.findIndex(p => p.slug === root.slugOf(n));
            if (at < 0) {
                root._answer(cb, false, "missing");
                return;
            }
            if (clash >= 0 && clash !== at) {
                root._answer(cb, false, "exists");
                return;
            }
            list[at] = Object.assign({}, list[at], { name: n, slug: root.slugOf(n) });
            root.mockPresets = list;
            root._publish(list);
            root._answer(cb, true, "");
            return;
        }
        root._run(["preset", "rename", oldName, n, "--json"], (code, d) => {
            root._answer(cb, code === 0, code === 0 ? "" : ((d && d.reason) || "failed"));
            root.refresh();
        });
    }
    function remove(name: string): void {
        const row = root._rowOf(name);
        if (!row || row.deleted)
            return;
        root._record("delete " + name);
        const d = Object.assign({}, root._deleted);
        d[row.slug] = { until: Date.now() + root.undoMs, row: row };
        root._deleted = d;
        undoSweep.restart();
        if (!root.live) {
            root.mockPresets = root.mockPresets.filter(p => p.slug !== row.slug);
            root._publish(root.mockPresets);
            return;
        }
        root._run(["preset", "delete", row.name, "--json"], () => root.refresh());
        // the row shows deleted at once, whatever the tool's turn
        root._publish(root._presets.filter(p => p.slug !== row.slug));
    }
    function undo(name: string): void {
        const slug = root.slugOf(name);
        const d = root._deleted[slug];
        if (!d)
            return;
        root._record("undelete " + name);
        const next = Object.assign({}, root._deleted);
        delete next[slug];
        root._deleted = next;
        if (!root.live) {
            root.mockPresets = root.mockPresets.concat([d.row]);
            root._publish(root.mockPresets);
            return;
        }
        root._run(["preset", "undelete", d.row.name, "--json"], () => root.refresh());
    }
    // How long a deleted row's Undo has left, ms (0: none).
    function undoLeft(name: string): real {
        const d = root._deleted[root.slugOf(name)];
        return d ? Math.max(0, d.until - Date.now()) : 0;
    }
    // The end of an Undo window: the row goes (the tool's trash is swept at its next save).
    Timer {
        id: undoSweep
        interval: 250
        repeat: true
        onTriggered: {
            const now = Date.now();
            const next = {};
            let left = 0, gone = 0;
            for (const slug in root._deleted) {
                if (root._deleted[slug].until > now) {
                    next[slug] = root._deleted[slug];
                    left++;
                } else {
                    gone++;
                }
            }
            if (gone > 0) {
                root._deleted = next;
                root._publish(root._presets.filter(p => !p.deleted));
            }
            if (left === 0)
                undoSweep.stop();
        }
    }

    function plan(name: string, mode: string, cb: var): void {
        root._record("plan " + name + " " + mode);
        if (!root.live) {
            const n = root.mockClose[name] !== undefined ? root.mockClose[name] : 3;
            const close = [];
            for (let i = 0; i < (mode === "replace" ? n : 0); i++)
                close.push({ address: "0x" + i, "class": "kitty", title: "window " + i });
            Qt.callLater(() => root._answerPlan(cb, { close: close, reuse: [], launch: [] }));
            return;
        }
        root._run(["preset", "load", name, "--" + mode, "--dry", "--json"], (code, d) => {
            root._answerPlan(cb, d && d.close ? d : { close: [], reuse: [], launch: [], failed: true });
        });
    }
    function load(name: string, mode: string): void {
        root._record("load " + name + " " + mode);
        if (root.session)
            root.session.loadPreset(name, mode);
    }

    function _answer(cb: var, ok: bool, reason: string): void {
        if (typeof cb === "function")
            cb(ok, reason);
    }
    function _answerPlan(cb: var, d: var): void {
        if (typeof cb === "function")
            cb(d);
    }

    // ---- the tool --------------------------------------------------------------------------------------------
    // One Process per ask, destroyed when it ends; its stdout is one JSON object (the tool's --json).
    function _run(args: var, cb: var): void {
        const proc = procComp.createObject(root, { command: [root.python, root.tool].concat(args) });
        proc.done.connect((code, text) => {
            let d = null;
            try {
                d = JSON.parse(String(text).trim().split("\n").filter(l => l.trim() !== "").pop() || "null");
            } catch (e) {
                d = null;
            }
            if (typeof cb === "function")
                cb(code, d);
            proc.destroy();
        });
        proc.running = true;
    }
    Component {
        id: procComp
        Process {
            id: p
            signal done(int code, string text)
            // the answer is whole when the child has exited AND its stdout has ended (either may come first)
            property int code: -1
            property bool exitedYet: false
            property bool streamEnded: false
            function _check(): void {
                if (p.exitedYet && p.streamEnded) {
                    p.exitedYet = false;
                    p.done(p.code, out.text);
                }
            }
            stdout: StdioCollector {
                id: out
                onStreamFinished: {
                    p.streamEnded = true;
                    p._check();
                }
            }
            onExited: code => {
                p.code = code;
                p.exitedYet = true;
                p._check();
            }
        }
    }
}
