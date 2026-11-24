pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "Interest.js" as Interest

// =============================================================================
// WikiState.qml -- what the module remembers between runs. THE ONE WRITER of
// $XDG_STATE_HOME/lares/wiki/state.json (overridable: `statePath`); the
// tool never touches it (CONTRACT.md "Paths", "State").
//
//   { v: 1,
//     seen:     { "<id>": ms },
//     slots:    { discover: { day, id, shownMs, why } | null, deepen: ... },
//     interest: { discover: { events: [...] }, deepen: { events: [...] } },
//     ask:      { discover: { latchedAt, at, answered, later }, deepen: ... },
//     batch:    { running, tab, pid },
//     jev:      { tokens, calls },
//     opened:   [ { id, title, at } ]        the last 20 the reader opened
//     choices:  { "<tab>|<id>": { taste: "more" | "less" | "", knew, day, f, t, band?, at } }
//               what the reader pressed on a card (more / less / "I knew this") and that is NOT yet in
//               `interest`: it counts at the next daily turnover (WikiService._commitChoices), and until
//               then the buttons undo and switch it }
//
// `opened` is an addition to the contract's shape (the batch's `recent` titles
// come from it: the interest events carry a family and a topic, not a title).
//
// Read once, synchronously, at completion or on the first `ensureLoaded()`
// (blockLoading: no waiting for onLoaded). Every change is written 300 ms after the last one, atomically,
// into a directory made first; a write equal to the last one we made is
// skipped (the self-echo guard: the bytes we just wrote are never re-read as
// news). `persist: false` keeps it in memory. A file that is not a version-1
// state is ignored -- every part is normalised, a bad part takes its default
// -- and the first change replaces it. The pending write is flushed when the
// object is destroyed (a shell reload), with waitForJob() so it is on disk
// when the process goes.
//
// Every change is a NEW object (assign, never mutate): the holder of a part
// compares it by identity, and the write timer starts only through `_save`.
// =============================================================================
Item {
    id: root

    property bool persist: true
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/wiki/state.json"

    readonly property var tabs: ["discover", "deepen"]
    property int seenCap: 4000
    property int openedCap: 20

    property var seen: ({})
    property var slots: ({ discover: null, deepen: null })
    property var interest: ({ discover: { events: [] }, deepen: { events: [] } })
    property var ask: ({ discover: root._noAsk(), deepen: root._noAsk() })
    property var batch: ({ running: false, tab: null, pid: 0 })
    property var jev: ({ tokens: 0, calls: 0 })
    property var opened: []
    property var choices: ({})

    // True once the file has been read (or found missing).
    readonly property bool loaded: root._loaded
    signal changed()

    // ---- changes (each one replaces its part) ----------------------------------------
    function markSeen(id, ms) {
        if (!id || root.seen[id]) return false;
        let s = Object.assign({}, root.seen);
        s[id] = Math.round(ms);
        const ids = Object.keys(s);
        if (ids.length > root.seenCap) {
            ids.sort(function (a, b) { return s[a] - s[b]; });
            const drop = ids.length - root.seenCap + 100;
            for (let i = 0; i < drop; i++) delete s[ids[i]];
        }
        root.seen = s;
        root._save();
        return true;
    }

    function setSlot(tab, slot) {
        const s = Object.assign({}, root.slots);
        s[tab] = slot;
        root.slots = s;
        root._save();
    }

    // The events of a tab, with `ev` appended (Interest.record: pure, bounded).
    function record(tab, ev, cfg) {
        const i = Object.assign({}, root.interest);
        i[tab] = Interest.record(i[tab], ev, cfg);
        root.interest = i;
        root._save();
    }

    function setAsk(tab, latch) {
        const a = Object.assign({}, root.ask);
        a[tab] = { latchedAt: typeof latch.latchedAt === "number" ? latch.latchedAt : null,
                   at: latch.at || 0, answered: latch.answered === true, later: latch.later === true };
        root.ask = a;
        root._save();
    }

    function setBatch(b) {
        root.batch = { running: !!b.running, tab: b.tab || null, pid: b.pid | 0 };
        root._save();
    }

    // The pending choice of one card, replaced (null removes it).
    function setChoice(key, c) {
        const m = Object.assign({}, root.choices);
        if (c) m[key] = c;
        else delete m[key];
        root.choices = m;
        root._save();
    }

    function addJev(tokens, calls) {
        root.jev = { tokens: root.jev.tokens + (tokens | 0), calls: root.jev.calls + (calls | 0) };
        root._save();
    }

    function noteOpened(id, title, at) {
        if (!id) return;
        const list = root.opened.filter(function (o) { return o.id !== id; });
        list.push({ id: id, title: String(title || ""), at: Math.round(at) });
        root.opened = list.length > root.openedCap ? list.slice(list.length - root.openedCap) : list;
        root._save();
    }

    function flush() {
        if (!root.persist || !root._loaded) return;
        if (!root._dirReady) { writeTimer.restart(); return; }
        writeTimer.stop();
        const txt = root._serialize();
        if (txt === root._selfWrite) return;
        root._selfWrite = txt;
        file.setText(txt);
    }

    // ---- Private ---------------------------------------------------------------------
    property bool _loaded: false
    property bool _dirReady: false
    property string _selfWrite: ""

    function _noAsk() { return { latchedAt: null, at: 0, answered: false, later: false }; }

    function _save() {
        root.changed();
        if (!root.persist || !root._loaded) return;
        writeTimer.restart();
    }

    function _serialize() {
        return JSON.stringify({
            v: 1, seen: root.seen, slots: root.slots, interest: root.interest,
            ask: root.ask, batch: root.batch, jev: root.jev, opened: root.opened, choices: root.choices
        }, null, 1) + "\n";
    }

    function _num(v, dflt) { return typeof v === "number" && isFinite(v) ? v : dflt; }

    function _ingest(txt) {
        if (!txt || txt.trim().length === 0) return;
        let o = null;
        try { o = JSON.parse(txt); } catch (e) { return; }
        if (!o || typeof o !== "object" || Array.isArray(o) || o.v !== 1) return;

        const seen = {};
        if (o.seen && typeof o.seen === "object" && !Array.isArray(o.seen))
            for (const id in o.seen)
                if (typeof o.seen[id] === "number" && isFinite(o.seen[id])) seen[id] = o.seen[id];
        root.seen = seen;

        const slots = { discover: null, deepen: null };
        const interest = { discover: { events: [] }, deepen: { events: [] } };
        const ask = { discover: root._noAsk(), deepen: root._noAsk() };
        for (let i = 0; i < root.tabs.length; i++) {
            const tab = root.tabs[i];
            const sl = o.slots ? o.slots[tab] : null;
            if (sl && typeof sl === "object" && typeof sl.id === "string" && sl.id.length > 0)
                slots[tab] = { day: typeof sl.day === "string" ? sl.day : "", id: sl.id,
                               shownMs: root._num(sl.shownMs, 0), why: sl.why && typeof sl.why === "object" ? sl.why : null };
            interest[tab] = Interest.normalise(o.interest ? o.interest[tab] : null);
            const a = o.ask ? o.ask[tab] : null;
            if (a && typeof a === "object")
                ask[tab] = { latchedAt: typeof a.latchedAt === "number" ? a.latchedAt : null,
                             at: root._num(a.at, 0), answered: a.answered === true, later: a.later === true };
        }
        root.slots = slots;
        root.interest = interest;
        root.ask = ask;

        const b = o.batch && typeof o.batch === "object" ? o.batch : {};
        root.batch = { running: b.running === true, tab: root.tabs.indexOf(b.tab) >= 0 ? b.tab : null,
                       pid: Math.max(0, Math.floor(root._num(b.pid, 0))) };
        const j = o.jev && typeof o.jev === "object" ? o.jev : {};
        root.jev = { tokens: Math.max(0, Math.floor(root._num(j.tokens, 0))), calls: Math.max(0, Math.floor(root._num(j.calls, 0))) };
        const op = [];
        if (Array.isArray(o.opened))
            for (let i = 0; i < o.opened.length; i++) {
                const x = o.opened[i];
                if (x && typeof x.id === "string" && typeof x.at === "number")
                    op.push({ id: x.id, title: typeof x.title === "string" ? x.title : "", at: x.at });
            }
        root.opened = op.slice(Math.max(0, op.length - root.openedCap));
        const ch = {};
        if (o.choices && typeof o.choices === "object" && !Array.isArray(o.choices))
            for (const k in o.choices) {
                const c = o.choices[k];
                const bar = k.indexOf("|");
                if (!c || typeof c !== "object" || bar < 1 || root.tabs.indexOf(k.substring(0, bar)) < 0 || typeof c.f !== "string" || c.f.length === 0) continue;
                const taste = c.taste === "more" || c.taste === "less" ? c.taste : "";
                if (taste === "" && c.knew !== true) continue;
                ch[k] = { taste: taste, knew: c.knew === true, day: typeof c.day === "string" ? c.day : "", f: c.f,
                          t: typeof c.t === "string" ? c.t : "", at: root._num(c.at, 0) };
                if (typeof c.band === "number" && isFinite(c.band)) ch[k].band = c.band;
            }
        root.choices = ch;
        root._selfWrite = root._serialize();
    }

    Timer {
        id: writeTimer
        interval: 300
        onTriggered: root.flush()
    }

    FileView {
        id: file
        path: root.persist ? root.statePath : ""
        blockLoading: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }

    Process {
        id: mkdir
        command: ["mkdir", "-p", "--", root.statePath.substring(0, root.statePath.lastIndexOf("/"))]
        running: false
    }
    Connections {
        target: mkdir
        function onExited(exitCode) {
            root._dirReady = exitCode === 0;
            if (root._dirReady && writeTimer.running) root.flush();
        }
    }

    // Read once, by whichever comes first: the completion or the owner that needs
    // the state at ITS completion (a parent's onCompleted runs before its child's).
    property bool _read: false
    function ensureLoaded() {
        if (root._read) return;
        root._read = true;
        if (root.persist) root._ingest(file.text());
        root._loaded = true;
        if (root.persist) mkdir.running = true;
        else root._dirReady = true;
    }
    Component.onCompleted: root.ensureLoaded()
    Component.onDestruction: {
        if (!root.persist || !root._loaded || !root._dirReady) return;
        if (writeTimer.running) root.flush();
        file.waitForJob();
    }
}
