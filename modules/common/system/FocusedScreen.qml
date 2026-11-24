pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "HyprWs.js" as HyprWs
import "OutputRecord.js" as Out

// =============================================================================
// FocusedScreen.qml -- which monitor has the focus, what every monitor shows,
// and whether the focused workspace has a fullscreen window: ONE source for
// everything in the shell that has to ask (the notification lane, the OSD, the
// auth pill, FullscreenWatch, each screen's Workspaces).
//
//   in:   live       true reads the compositor (hyprctl + socket2); false is a
//                    FAKE you drive (below) and Hyprland is never touched
//   out:  name       the focused monitor ("eDP-1"); "" while unknown
//         monitors   [{ id, name, focused, activeWorkspaceId, x, y, width, height, scale }]
//                    in Hyprland's id order; x/y are layout positions, width/height
//                    the mode's pixels (divide by scale for the logical size)
//         fullscreen the focused monitor's workspace has a fullscreen window -- the SPECIAL
//                    workspace (the scratchpad) when the monitor shows one over its regular
//                    workspace, which is where the window the user looks at is: hyprctl
//                    says `activeWorkspace` is still the regular one and `specialWorkspace`
//                    the one on top, and only the second has the fullscreen window (a
//                    fullscreen kitty in the scratchpad never raised the OSD pill)
//         fullscreenOn(name)   that monitor's answer to the same question ("" the focused one's)
//         displayFor(word)     the display a config's word stands for: a connector's name while it is in `monitors`, else the focused one
//                    ("focused", or a display that is not there)
//         outputs    EVERY output Hyprland lists, as the panorama contract's Output record (OutputRecord.js): the
//                    disabled and the mirroring ones too (`hyprctl -j monitors all`), the lock's hop and Hyprland's
//                    FALLBACK left out. `monitors` stays what it was: the enabled, non-mirroring ones
//         outputsChanged()   once per change of what an Output holds (a mode, a scale, a plug, a mirror), never for a
//                    focus or a workspace move; refresh() asks for a read now
//         activeWorkspaceOf(name)   the workspace that monitor shows (-1 when the
//                    monitor is unknown); "" asks for the focused monitor's
//         changed()  once per change of any of the above; a read that confirms
//                    what the events already said changes nothing
//
// WHY NOT QUICKSHELL'S HYPRLAND. On Hyprland 0.56 `Hyprland.focusedMonitor` and
// `focusedWorkspace` are null until an event arrives, every monitor's
// `lastIpcObject` is `{}` and every workspace reads `active: false`
// (measured). So the SINGLETON IS
// ONLY THE EVENT LINE (`rawEvent`), and the facts are read with `hyprctl -j
// monitors all` + `hyprctl -j workspaces` -- one batched, debounced, one-in-flight
// read at start and after the few events that do not carry the whole truth.
// ActiveWindowService (modules/windowtray/data/) takes its focus from this; the
// rule for a read overtaken by events is the one it started with.
//
// WHAT AN EVENT CARRIES (recorded in a two-output Hyprland 0.56):
//   focusedmonv2>>MON,WS   the monitor holds the focus and shows WS: exact, no read
//   workspacev2>>WS,NAME   a monitor now shows WS -- the one WS LIVES ON when that is known
//                          (`_wsMon`: the read's `monitor` of every workspace, kept by
//                          the events), else the focused one (+ a read: a monitor
//                          unplugged in the middle sends one for a workspace it
//                          never ended up on). NOT simply the focused one: Super+3 for a
//                          workspace hidden on another output, with a window under the
//                          pointer on this one, sends (Hyprland 0.57.2, measured nested)
//                          focusedmonv2>>OTHER,2  focusedmonv2>>THIS,1  workspacev2>>3,3
//                          focusedmonv2>>OTHER,3 -- the focus bounces back for an instant,
//                          and read as "the focused monitor" THIS bar's ball flew to 3 and
//                          back when the read came (feedback/workspaces.md "Ball x External
//                          monitor"). So the monitor is decided at the END of the turn the
//                          event came in (the burst's later events have been heard: the last
//                          focusedmonv2 names where 3 is), and a workspace's home comes
//                          from the map first; a new workspace (createworkspacev2) asks for a
//                          read, which tells where it lives
//   moveworkspacev2>>WS,NAME,MON   WS now lives on MON (+ a read)
//   destroyworkspacev2>>WS,NAME    WS is gone
//   fullscreen>>0|1        the focused window entered / left fullscreen (+ a read:
//                          the event does not say on which monitor, and leaving a
//                          fullscreen workspace sends nothing at all)
//   activespecialv2>>ID,NAME,MON   a SPECIAL workspace (the scratchpad) is shown on MON, or
//                          hidden (ID and NAME empty): exact, + a read
//   monitorremovedv2>>ID,NAME,DESC   gone at once, then a read (what the others show
//                          after the move is only in the read)
//   monitoradded(v2) configreloaded   a read
//
// EVERY READ IS TAKEN, FACT BY FACT: a fact an event set after the read began is
// newer than the read and is kept (the focused monitor, a monitor's workspace, a
// workspace's fullscreen flag, a monitor taken away). Discarding an overtaken read
// outright and taking a later one leaves the bar on a window that is no longer
// focused until the next event.
//
// A FAKE (`live: false`): a probe or a mockup drives it with the setters below and
// it answers exactly as the live one does, through the same state; a monitor the
// fake has not heard of is added when it is first named. `handleEvent` and
// `applyReading` are the live path's two inputs, public so a replay of a recorded
// stream can feed them without a compositor.
// =============================================================================
Item {
    id: root

    property bool live: false
    // HELD: the facts are moving and will come back (the theme curtain shows the hidden workspaces by turns under its picture:
    // modules/shell/ThemeControl.qml, "THE HIDDEN WINDOWS"). Nothing is published while held; at the release one read says where
    // the session really is.
    property bool held: false
    onHeldChanged: {
        if (!root.held) {
            root._publish();
            root._publishOutputs();
            root._requery();
        }
    }

    readonly property string name: root._state.name
    readonly property var monitors: root._state.monitors
    readonly property bool fullscreen: root._state.fullscreen
    signal changed()

    readonly property var outputs: root._outs
    // `outputsChanged()` is this property's own change signal, and it is raised ONLY by _publishOutputs: when the records moved
    // (a mode, a scale, a plug, a mirror), never for a focus or a workspace move. The signature is the records themselves, held in a
    // var (never a counter a binding reads).

    // A read now (a plug the shell was told of by something other than socket2, a popup opening).
    function refresh(): void {
        root._requery();
    }

    function fullscreenOn(monitorName: string): bool {
        const s = root._state;
        return s.fullscreens.indexOf(monitorName === "" ? s.name : monitorName) >= 0;
    }

    // The screens that have a shell window (ShellServices, from shell.jsonc bars.outputs); [] = every screen. What is shown on "the focused
    // screen" (the toasts' lane, the OSD) goes to one of these: a screen with no window draws nothing, and a toast's clock ran out unseen there.
    property var shellScreens: []
    function displayFor(word: string): string {
        const s = root._state;
        const at = s.monitors.some(m => m.name === word) ? word : s.name;
        const own = root.shellScreens;
        if (!own || own.length === 0 || own.indexOf(at) >= 0)
            return at;
        return own.indexOf(s.name) >= 0 ? s.name : own[0];
    }

    // Counters a probe reads and nothing binds: reads started, and reads an event ASKED for (live or not).
    readonly property var stats: ({ reads: 0, wanted: 0, published: 0 })

    function activeWorkspaceOf(monitorName: string): int {
        const s = root._state;
        const want = monitorName === "" ? s.name : monitorName;
        for (let i = 0; i < s.monitors.length; i++)
            if (s.monitors[i].name === want) {
                // a named workspace is its name (HyprWs.key): to a reader that asks for a number it is no number
                const id = s.monitors[i].activeWorkspaceId;
                return typeof id === "number" ? id : -1;
            }
        return -1;
    }

    // ---- The fake -------------------------------------------------------------
    // [{ name, id?, x?, y?, width?, height?, scale?, activeWorkspaceId? }]. The focus stays where
    // it was when that monitor is still there, else it falls to the first one.
    function setMonitors(list: var): void {
        const out = [];
        for (let i = 0; i < list.length; i++)
            out.push(root._monitor(list[i], out));
        out.sort((a, b) => a.id - b.id);
        root._mons = out;
        root._publish();
    }

    function addMonitor(m: var): void {
        if (root._index(m.name) >= 0)
            return;
        root._mons = root._mons.concat([root._monitor(m, root._mons)]).sort((a, b) => a.id - b.id);
        root._publish();
    }

    function removeMonitor(monitorName: string): void {
        root._onMonitorGone(monitorName);
    }

    function setFocused(monitorName: string): void {
        if (root._index(monitorName) < 0)
            root._mons = root._mons.concat([root._monitor({ name: monitorName }, root._mons)]);
        root._evFocus = { name: monitorName, seq: ++root._seq };
        root._focusedName = monitorName;
        root._publish();
    }

    function setActiveWorkspace(monitorName: string, id: int): void {
        if (root._index(monitorName) < 0)
            root._mons = root._mons.concat([root._monitor({ name: monitorName }, root._mons)]);
        root._setWorkspace(monitorName, id, ++root._seq);
        root._publish();
    }

    // The fullscreen flag of `workspaceId` (default: the focused monitor's workspace; needs one).
    function setFullscreen(on: bool, workspaceId: var): void {
        const ws = workspaceId === undefined ? root.activeWorkspaceOf("") : Number(workspaceId);
        if (ws < 0)
            return;
        root._setFullscreen(ws, on, ++root._seq);
        root._publish();
    }

    // The fake's outputs: [{ name, ...any Output field }] (OutputRecord.fill has the defaults). Independent of setMonitors.
    function setOutputs(list: var): void {
        const out = [];
        for (let i = 0; i < list.length; i++)
            if (!Out.isIgnored(list[i].name))
                out.push(Out.fill(Object.assign({ id: i }, list[i])));
        out.sort((a, b) => a.id - b.id);
        root._outsRaw = out;
        root._publishOutputs();
    }

    // ---- The live path's two inputs --------------------------------------------
    // One socket2 line, split at ">>".
    function handleEvent(eventName: string, data: string): void {
        switch (eventName) {
        case "focusedmonv2": {
            // "<monitor>,<workspace id>": the monitor holds the focus, showing that workspace
            const i = data.lastIndexOf(",");
            if (i > 0 && i < data.length - 1)
                root._onFocusedMonitor(data.substring(0, i), HyprWs.key({ id: data.substring(i + 1) }));
            return;
        }
        case "workspacev2": {
            // "<id>,<name>": the focused monitor now shows it
            const i = data.indexOf(",");
            root._onWorkspace(i > 0 ? HyprWs.key({ id: data.substring(0, i), name: data.substring(i + 1) }) : root._int(data));
            break;
        }
        case "fullscreen":
            root._onFullscreen(String(data).trim() === "1");
            break;
        case "activespecialv2": {
            // "<id>,<name>,<monitor>": a special workspace shown on that monitor; id and name are empty when it is hidden (on Hyprland 0.57 the
            // id field carries the name too: HyprWs.key)
            const parts = data.split(",");
            if (parts.length >= 3)
                root._onSpecial(parts[2], HyprWs.key({ id: parts[0], name: parts[1] }));
            break;
        }
        case "monitorremovedv2": {
            // "<id>,<name>,<description>"
            const parts = data.split(",");
            if (parts.length > 1)
                root._onMonitorGone(parts[1]);
            break;
        }
        case "monitorremoved":
            root._onMonitorGone(data);
            break;
        case "moveworkspacev2": {
            // "<id>,<name>,<monitor>": the workspace now lives there
            const parts = data.split(",");
            if (parts.length >= 3)
                root._wsMon[HyprWs.key({ id: parts[0], name: parts[1] })] = parts[parts.length - 1];
            break;
        }
        case "destroyworkspacev2": {
            const i = data.indexOf(",");
            delete root._wsMon[i > 0 ? HyprWs.key({ id: data.substring(0, i), name: data.substring(i + 1) }) : root._int(data)];
            return;
        }
        case "monitoradded":
        case "monitoraddedv2":
        case "createworkspacev2":
        case "configreloaded":
            break;
        default:
            return;
        }
        root._requery();
    }

    // Marks where a read begins: facts events set after this are newer than its answer.
    function beginReading(): void {
        root._runSeq = root._seq;
        root.stats.reads += 1;
    }

    // What a read answered: `hyprctl -j monitors all` and `hyprctl -j workspaces`. True when both parsed.
    function applyReading(monitorsText: string, workspacesText: string): bool {
        const mons = root._json(monitorsText);
        const wss = root._json(workspacesText);
        if (!Array.isArray(mons) || !Array.isArray(wss))
            return false;
        const newer = s => s !== undefined && s > root._runSeq;
        const list = [];
        const outs = [];
        let focused = "";
        for (let i = 0; i < mons.length; i++) {
            const m = mons[i];
            if (newer(root._evGone[m.name]))
                continue;
            if (!Out.isIgnored(m.name))
                outs.push(Out.build(m, mons));
            // `monitors` is what plain `hyprctl -j monitors` listed: neither a disabled output nor a mirroring one
            if (m.disabled === true || Out.isMirror(m))
                continue;
            let ws = m.activeWorkspace ? HyprWs.key(m.activeWorkspace) : -1;
            const ev = root._evWs[m.name];
            if (ev && newer(ev.seq))
                ws = ev.id;
            let sp = HyprWs.key(m.specialWorkspace);
            const evSp = root._evSpecial[m.name];
            if (evSp && newer(evSp.seq))
                sp = evSp.id;
            if (m.focused === true)
                focused = String(m.name);
            list.push(root._monitor({
                id: m.id, name: m.name, x: m.x, y: m.y, width: m.width, height: m.height,
                scale: m.scale, activeWorkspaceId: ws, specialWorkspaceId: sp
            }, list));
        }
        list.sort((a, b) => a.id - b.id);
        outs.sort((a, b) => a.id - b.id);
        root._outsRaw = outs;
        if (newer(root._evFocus.seq))
            focused = root._evFocus.name;
        else if (focused === "")
            focused = root._focusedName;
        const fs = {};
        const wsMon = {};
        for (let i = 0; i < wss.length; i++) {
            if (wss[i].hasfullscreen === true)
                fs[HyprWs.key(wss[i])] = true;
            if (typeof wss[i].monitor === "string" && wss[i].monitor !== "")
                wsMon[HyprWs.key(wss[i])] = wss[i].monitor;
        }
        // a workspace an event put on a monitor after the read began lives there
        for (const m in root._evWs)
            if (newer(root._evWs[m].seq))
                wsMon[root._evWs[m].id] = m;
        for (const k in root._evFs) {
            if (!newer(root._evFs[k].seq))
                continue;
            if (root._evFs[k].on)
                fs[k] = true;
            else
                delete fs[k];
        }
        root._mons = list;
        root._focusedName = focused;
        root._fs = fs;
        root._wsMon = wsMon;
        root._publish();
        root._publishOutputs();
        return true;
    }

    // ---- Private ----------------------------------------------------------------
    // What the readers see, in ONE object (name, monitors and fullscreen come from the same read of it); `fullscreens` the names of the
    // monitors that show a fullscreen window.
    property var _state: ({ name: "", monitors: [], fullscreen: false, fullscreens: [] })
    property string _stateKey: ""
    // The outputs as last read, and what the readers see (held back while `held`); the signature that decides a change.
    property var _outsRaw: []
    property var _outs: []
    property var _outsKey: ""

    // The model: monitors as last read / patched, the focused one's name (may name a
    // monitor that has just gone: _publish() falls back), the workspaces with a fullscreen window.
    property var _mons: []
    property string _focusedName: ""
    property var _fs: ({})

    // Every event that says something is numbered; a read remembers the number it began at.
    property int _seq: 0
    property int _runSeq: 0
    property var _evFocus: ({ name: "", seq: 0 })
    property var _evWs: ({})        // monitor -> { id, seq }
    property var _evFs: ({})        // workspace id -> { on, seq }
    property var _evGone: ({})      // monitor -> seq
    property var _evSpecial: ({})   // monitor -> { id (0 none), seq }
    // Where each workspace lives (HyprWs key -> monitor name): the read's, then every event that says it. Read only inside functions.
    property var _wsMon: ({})
    // workspacev2 events heard this turn, decided at its end (`_settleWorkspaces`)
    property var _wsPending: []
    property bool _busy: false
    property bool _again: false
    readonly property string _mark: "@@QS" + Math.floor(Math.random() * 1000000000) + "@@"

    // An integer from an event's text, NaN for anything else (Number("") is 0: a truncated line is not workspace 0).
    function _int(text: string): var {
        return /^-?[0-9]+$/.test(text) ? Number(text) : NaN;
    }

    function _json(s: string): var {
        try {
            return JSON.parse(s);
        } catch (e) {
            return null;
        }
    }

    function _index(monitorName: string): int {
        for (let i = 0; i < root._mons.length; i++)
            if (root._mons[i].name === monitorName)
                return i;
        return -1;
    }

    // A monitor record with defaults; the id (Hyprland's order) is the next free one when not given.
    function _monitor(m: var, others: var): var {
        let id = m.id !== undefined ? Number(m.id) : 0;
        if (m.id === undefined)
            for (let i = 0; i < others.length; i++)
                id = Math.max(id, others[i].id + 1);
        let x = m.x !== undefined ? Number(m.x) : 0;
        if (m.x === undefined)
            for (let i = 0; i < others.length; i++)
                x = Math.max(x, others[i].x + others[i].width);
        return {
            id: id,
            name: String(m.name),
            x: x,
            y: m.y !== undefined ? Number(m.y) : 0,
            width: m.width !== undefined ? Number(m.width) : 1920,
            height: m.height !== undefined ? Number(m.height) : 1080,
            scale: m.scale !== undefined ? Number(m.scale) : 1,
            activeWorkspaceId: m.activeWorkspaceId !== undefined ? HyprWs.key({ id: m.activeWorkspaceId }) : (id + 1),
            // the special workspace shown over the regular one (its HyprWs.key), 0 when none
            specialWorkspaceId: m.specialWorkspaceId !== undefined ? m.specialWorkspaceId : 0
        };
    }

    // The name the readers get: the monitor the events named if it is live, else the first live one.
    function _focusName(): string {
        const ms = root._mons;
        for (let i = 0; i < ms.length; i++)
            if (ms[i].name === root._focusedName)
                return ms[i].name;
        return ms.length > 0 ? ms[0].name : "";
    }

    function _publish(): void {
        if (root.held)
            return;
        const name = root._focusName();
        const list = [];
        const full = [];
        for (let i = 0; i < root._mons.length; i++) {
            const m = root._mons[i];
            list.push({
                id: m.id, name: m.name, focused: m.name === name, activeWorkspaceId: m.activeWorkspaceId,
                x: m.x, y: m.y, width: m.width, height: m.height, scale: m.scale
            });
            // the workspace the user is LOOKING at: the special one on top when there is one
            const ws = m.specialWorkspaceId !== 0 ? m.specialWorkspaceId : m.activeWorkspaceId;
            if (ws !== -1 && root._fs[ws] === true)
                full.push(m.name);
        }
        const next = { name: name, monitors: list, fullscreen: full.indexOf(name) >= 0, fullscreens: full };
        const key = JSON.stringify(next);
        if (key === root._stateKey)
            return;
        root._stateKey = key;
        root._state = next;
        root.stats.published += 1;
        root.changed();
    }

    function _publishOutputs(): void {
        if (root.held)
            return;
        const key = JSON.stringify(root._outsRaw);
        if (key === root._outsKey)
            return;
        root._outsKey = key;
        root._outs = root._outsRaw;
    }

    function _setWorkspace(monitorName: string, id: var, seq: int): void {
        root._evWs[monitorName] = { id: id, seq: seq };
        root._wsMon[id] = monitorName;
        const i = root._index(monitorName);
        if (i < 0)
            return;
        const next = root._mons.slice();
        next[i] = Object.assign({}, next[i], { activeWorkspaceId: id });
        root._mons = next;
    }

    function _setFullscreen(ws: var, on: bool, seq: int): void {
        root._evFs[ws] = { on: on, seq: seq };
        const next = Object.assign({}, root._fs);
        if (on)
            next[ws] = true;
        else
            delete next[ws];
        root._fs = next;
    }

    function _onFocusedMonitor(monitorName: string, id: var): void {
        const seq = ++root._seq;
        root._evFocus = { name: monitorName, seq: seq };
        root._focusedName = monitorName;
        root._setWorkspace(monitorName, id, seq);
        root._publish();
    }

    function _onWorkspace(id: var): void {
        if (Number.isNaN(id))
            return;
        root._wsPending.push(id);
        if (root._wsPending.length === 1)
            Qt.callLater(root._settleWorkspaces);
    }
    // The turn's workspace events, in order: each on the monitor the workspace lives on, while that monitor is there; else on the focused
    // one (a new workspace opens there).
    function _settleWorkspaces(): void {
        const ids = root._wsPending;
        root._wsPending = [];
        let any = false;
        for (const id of ids) {
            const home = root._wsMon[id];
            const name = home !== undefined && root._index(home) >= 0 ? home : root._focusName();
            if (name === "")
                continue;
            root._setWorkspace(name, id, ++root._seq);
            any = true;
        }
        if (any)
            root._publish();
    }

    // The workspace the focused monitor's user is looking at: its special workspace when one is shown, else the regular one.
    function _focusedWs(): var {
        const i = root._index(root._focusName());
        if (i < 0)
            return -1;
        const m = root._mons[i];
        return m.specialWorkspaceId !== 0 ? m.specialWorkspaceId : m.activeWorkspaceId;
    }

    function _setSpecial(monitorName: string, id: var, seq: int): void {
        root._evSpecial[monitorName] = { id: id, seq: seq };
        const i = root._index(monitorName);
        if (i < 0)
            return;
        const next = root._mons.slice();
        next[i] = Object.assign({}, next[i], { specialWorkspaceId: id });
        root._mons = next;
    }

    function _onSpecial(monitorName: string, id: var): void {
        root._setSpecial(monitorName, id, ++root._seq);
        root._publish();
    }

    function _onFullscreen(on: bool): void {
        const ws = root._focusedWs();
        if (ws === -1)
            return;
        root._setFullscreen(ws, on, ++root._seq);
        root._publish();
    }

    function _onMonitorGone(monitorName: string): void {
        const seq = ++root._seq;
        root._evGone[monitorName] = seq;
        delete root._evWs[monitorName];
        delete root._evSpecial[monitorName];
        root._mons = root._mons.filter(m => m.name !== monitorName);
        // The focus settles where it fell: a monitor that comes back does not take it back.
        if (root._focusedName === monitorName)
            root._focusedName = root._focusName();
        root._publish();
    }

    function _requery(): void {
        root.stats.wanted += 1;
        if (!root.live)
            return;
        if (root._busy) {
            root._again = true;
            return;
        }
        debounce.restart();
    }

    function _run(): void {
        if (!root.live)
            return;
        if (root._busy) {
            root._again = true;
            return;
        }
        if (reader.running) {
            debounce.restart();
            return;
        }
        root._busy = true;
        root.beginReading();
        reader.running = true;
    }

    function _readText(text: string): void {
        const parts = text.split(root._mark);
        if (parts.length >= 2)
            root.applyReading(parts[0], parts[1]);
        root._busy = false;
        if (root._again) {
            root._again = false;
            debounce.restart();
        }
    }

    Timer {
        id: debounce
        interval: 25
        onTriggered: root._run()
    }

    Process {
        id: reader
        command: ["sh", "-c", "hyprctl -j monitors all; echo '" + root._mark + "'; hyprctl -j workspaces"]
        stdout: StdioCollector {
            onStreamFinished: root._readText(this.text)
        }
    }

    // A reader that never produced output (no hyprctl, killed) must not leave the
    // service waiting for it.
    Connections {
        target: reader
        function onExited(exitCode, exitStatus) {
            if (root._busy && exitCode !== 0)
                root._busy = false;
        }
    }

    // The singleton is the event line and nothing else, and only when live. The first
    // read starts inside the loader, once the line is connected: no event can slip
    // between the read and the listener.
    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    root.handleEvent(ev.name, ev.data);
                }
            }
            Component.onCompleted: root._run()
        }
    }
}
