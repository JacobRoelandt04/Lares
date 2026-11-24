pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "Frecency.js" as F

// =============================================================================
// LauncherState.qml -- $XDG_STATE_HOME/lares/launcher/state.json: what
// the launcher remembers that is not a setting.
//
//   { "version": 1,
//     "sort": { "mode": "default"|"name"|"recent", "ascending": true },
//     "layout": "list"|"columns",
//     "frecency": { "<id>": { "count": 12, "recent": [ms, ... up to 10] } },
//     "names": { "<id>": "<title>" },
//     "answerHistory": [ "<query>", ... up to 20, newest first ] }
//
// <id> is an app's desktop id, or "scripts:<path under the scripts root>"
// for a script or .desktop file there (LauncherService.identityOf). A script
// that moves takes its records with it (renameId).
//
// `names` are the user's DISPLAY titles (the menu's Rename): the launcher
// shows and sorts by the title, and never touches the .desktop file or the
// script behind it. The member is optional, so a state written before it
// existed is still a version-1 state and loads as it is. `answerHistory` is the same: the queries the user
// copied an answer for (Up on an empty query recalls them), optional.
//
// WRITES. Debounced (writeDelayMs), atomic (FileView atomicWrites), after a
// mkdir -p of the folder. Our own writes' echoes are recognised by their text
// (the last few are remembered) and skipped. An outside edit replaces memory
// and emits ingested(). A missing file is the defaults; one that is not a
// version-1 state is logged once and replaced by the first change (it is the
// launcher's own bookkeeping, not a hand-edited file).
//
// `path` is set once, at creation (a FileView is never repointed).
// =============================================================================
Scope {
    id: st

    required property string path
    property int writeDelayMs: 300

    readonly property int serial: st._serial

    signal ingested

    readonly property var modes: ["default", "name", "recent"]
    readonly property var layouts: ["list", "columns"]

    function sortMode() {
        return st._d.sort.mode;
    }
    function sortAscending() {
        return st._d.sort.ascending;
    }
    function layout() {
        return st._d.layout;
    }
    // { count, recent } (a copy) or null.
    function frecencyOf(id) {
        const r = st._d.frecency[id];
        return r ? {
            count: r.count,
            recent: r.recent.slice()
        } : null;
    }
    function scoreOf(id, nowMs) {
        return F.score(st._d.frecency[id], nowMs);
    }
    // The display title given to `id`, or "".
    function nameOf(id) {
        return st._hasName(id) ? st._d.names[id] : "";
    }
    // A title for `id`; "" removes it. True when that changed anything.
    function setName(id, title) {
        if (typeof id !== "string" || id.length === 0)
            return false;
        const t = String(title === undefined || title === null ? "" : title);
        if (t.length === 0) {
            if (!st._hasName(id))
                return false;
            delete st._d.names[id];
        } else {
            if (st.nameOf(id) === t)
                return false;
            st._d.names[id] = t;
        }
        st._touch();
        return true;
    }

    // How many answered queries are remembered (launcher.jsonc answers.history).
    property int historyMax: 20
    // The remembered answered queries, newest first (a copy).
    function answerHistory() {
        return st._d.answerHistory.slice(0, st.historyMax);
    }
    // `q` becomes the newest; an earlier copy of it goes; the list keeps historyMax.
    function pushAnswerHistory(q) {
        const t = String(q === undefined || q === null ? "" : q).trim();
        if (t.length === 0 || st.historyMax < 1)
            return;
        const h = st._d.answerHistory;
        if (h.length > 0 && h[0] === t)
            return;
        const out = [t];
        for (let i = 0; i < h.length && out.length < st.historyMax; i++)
            if (h[i] !== t)
                out.push(h[i]);
        st._d.answerHistory = out;
        st._touch();
    }

    function setSort(mode, ascending) {
        if (st.modes.indexOf(mode) < 0)
            return false;
        const s = st._d.sort;
        if (s.mode === mode && s.ascending === !!ascending)
            return false;
        st._d.sort = {
            mode: mode,
            ascending: !!ascending
        };
        st._touch();
        return true;
    }
    function setLayout(l) {
        if (st.layouts.indexOf(l) < 0 || st._d.layout === l)
            return false;
        st._d.layout = l;
        st._touch();
        return true;
    }
    function recordLaunch(id, nowMs) {
        if (typeof id !== "string" || id.length === 0)
            return;
        st._d.frecency[id] = F.record(st._d.frecency[id], nowMs);
        st._touch();
    }
    function renameId(oldId, newId) {
        if (oldId === newId)
            return;
        let moved = false;
        if (st._d.frecency[oldId]) {
            const a = st._d.frecency[oldId], b = st._d.frecency[newId];
            delete st._d.frecency[oldId];
            // Two records meeting (a file moved onto a name that had one): the
            // launches add up, the newest stamps are kept.
            st._d.frecency[newId] = b ? F.normalise({
                count: a.count + b.count,
                recent: a.recent.concat(b.recent)
            }) : a;
            moved = true;
        }
        // The title goes with the file that moved; one the new id had is
        // replaced (it named a file that is no longer there).
        if (st._hasName(oldId)) {
            st._d.names[newId] = st._d.names[oldId];
            delete st._d.names[oldId];
            moved = true;
        }
        if (moved)
            st._touch();
    }

    // An item that is gone for good: its launches and its title go.
    function forgetId(id) {
        let gone = false;
        if (st._d.frecency[id]) {
            delete st._d.frecency[id];
            gone = true;
        }
        if (st._hasName(id)) {
            delete st._d.names[id];
            gone = true;
        }
        if (gone)
            st._touch();
    }

    // ---- internals ---------------------------------------------------------

    property var _d: st._fresh()
    property int _serial: 0
    property var _recent: []
    property bool _dirty: false
    property bool _dirReady: false
    property bool _loggedCorrupt: false
    readonly property string _dir: st.path.substring(0, st.path.lastIndexOf("/"))

    function _fresh() {
        return {
            version: 1,
            sort: {
                mode: "default",
                ascending: true
            },
            layout: "list",
            frecency: {},
            names: {},
            answerHistory: []
        };
    }
    function _hasName(id) {
        return Object.prototype.hasOwnProperty.call(st._d.names, id) && typeof st._d.names[id] === "string";
    }

    function _parse(txt) {
        let d;
        try {
            d = JSON.parse(txt);
        } catch (e) {
            return null;
        }
        if (!d || typeof d !== "object" || d.version !== 1)
            return null;
        const out = st._fresh();
        const s = d.sort || {};
        if (st.modes.indexOf(s.mode) >= 0)
            out.sort.mode = s.mode;
        if (typeof s.ascending === "boolean")
            out.sort.ascending = s.ascending;
        if (st.layouts.indexOf(d.layout) >= 0)
            out.layout = d.layout;
        const f = d.frecency && typeof d.frecency === "object" && !Array.isArray(d.frecency) ? d.frecency : {};
        for (const k in f) {
            const r = F.normalise(f[k]);
            if (r !== null)
                out.frecency[k] = r;
        }
        const n = d.names && typeof d.names === "object" && !Array.isArray(d.names) ? d.names : {};
        for (const k in n)
            if (k.length > 0 && typeof n[k] === "string" && n[k].length > 0)
                out.names[k] = n[k];
        if (Array.isArray(d.answerHistory))
            for (let i = 0; i < d.answerHistory.length && out.answerHistory.length < st.historyMax; i++)
                if (typeof d.answerHistory[i] === "string" && d.answerHistory[i].length > 0 && out.answerHistory.indexOf(d.answerHistory[i]) < 0)
                    out.answerHistory.push(d.answerHistory[i]);
        return out;
    }

    function _touch() {
        st._dirty = true;
        st._serial += 1;
        writeTimer.restart();
    }

    function flush() {
        writeTimer.stop();
        if (!st._dirty)
            return;
        if (!st._dirReady) {
            mkdir.running = true;
            return;
        }
        st._dirty = false;
        const txt = JSON.stringify(st._d, null, 1) + "\n";
        const r = st._recent.slice(-3);
        r.push(txt);
        st._recent = r;
        file.setText(txt);
    }

    Timer {
        id: writeTimer
        interval: st.writeDelayMs
        onTriggered: st.flush()
    }
    Process {
        id: mkdir
        command: ["mkdir", "-p", "--", st._dir]
        running: false
    }
    Connections {
        target: mkdir
        function onExited(exitCode) {
            st._dirReady = exitCode === 0;
            if (st._dirReady)
                st.flush();
            else
                console.log("LauncherState: could not create " + st._dir + "; " + st.path + " is not written");
        }
    }

    function _onDisk(txt, initial) {
        if (st._recent.indexOf(txt) >= 0)
            return;
        if (!txt || txt.length === 0)
            return;
        st._dirReady = true;
        const d = st._parse(txt);
        if (d === null) {
            if (!st._loggedCorrupt) {
                st._loggedCorrupt = true;
                console.log("LauncherState: " + st.path + " is not a version-1 state; it is replaced by the first change");
            }
            return;
        }
        st._d = d;
        st._dirty = false;
        writeTimer.stop();
        st._serial += 1;
        if (!initial)
            st.ingested();
    }

    FileView {
        id: file
        path: st.path
        blockLoading: true
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onFileChanged: file.reload()
        onLoaded: st._onDisk(file.text(), false)
    }

    Component.onCompleted: st._onDisk(file.text(), true)
    Component.onDestruction: {
        if (writeTimer.running || st._dirty)
            st.flush();
        file.waitForJob();
    }
}
