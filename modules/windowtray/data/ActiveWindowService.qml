pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "../../common/system/HyprWs.js" as HyprWs

// =============================================================================
// ActiveWindowService.qml -- the window a bar shows, from the live Hyprland.
// READ ONLY: it dispatches nothing.
//
//   in:  live         false: Hyprland is never touched (the event listener is a
//                     LazyLoader, the reader a Process that is never started)
//        follow       "screen": the last window of THIS bar's monitor's active
//                     workspace; "focus": the focused window, whatever screen
//        screenName   the bar's monitor ("eDP-1"); "" -> follow the focus
//        focusSource  the shell's ONE FocusedScreen (modules/common/system), or
//                     null (below)
//        config, appLookup, and the outs: ActiveWindowState.qml
//
// WITH A FOCUS SOURCE, EVERY MONITOR FACT IS THE SOURCE'S. A shell has a service
// per screen, and without the source each would read the monitors itself -- which one holds the
// focus, which workspace each shows -- and patch them from the same events, so N
// screens would mean N readers that could disagree for a frame. The source is that
// reader, once; this service asks it (`monitors`, and re-resolves on `changed`)
// and keeps for itself what is about WINDOWS: the clients, each workspace's last
// window, the focused address, titles. The one monitor fact the source does not
// carry is the SPECIAL workspace a monitor shows (a scratchpad hides the regular
// workspace's window), so that stays this service's own reading -- the monitors in
// its batch read, used for nothing else. Without a source everything
// is read here (a mockup, a probe, a bar on its own).
//
// WHERE THE FACTS COME FROM (measured). Quickshell
// 0.3.1 on Hyprland 0.56 gives no usable monitors (empty `lastIpcObject`, null
// `activeWorkspace`, null focusedMonitor), no class on a toplevel, and an
// `activeToplevel` that is null until the first focus event. So the SINGLETON IS
// ONLY THE EVENT LINE (`rawEvent`), and the facts are read with ONE batched
// `hyprctl -j` (activewindow, monitors, workspaces, clients: four requests on one
// short-lived sh) whenever the set of windows or the focus really changed:
//
//   openwindow closewindow movewindowv2 workspacev2 focusedmonv2 moveworkspacev2
//   monitor(added|removed)(v2) create/destroyworkspacev2 activespecial(v2)
//       -> one read, debounced 25 ms, one in flight; events during it ask for
//          another read after it
//   activewindowv2 with a new address -> the focus moves at once from what is
//       known (a known window needs no read); an unknown one reads
//
// EVERY READ IS TAKEN, FACT BY FACT: what an event said after the read began is
// newer than what the read says, and is kept -- the focused address (an
// activewindowv2), the monitors (focusedmonv2, workspacev2), a window opened or
// closed at an address (its client is dropped: the read describes the window that
// was there before), a title (windowtitlev2). Discarding a read
// that events had overtaken and taking the fourth anyway would leave a quick run of window
// switches with the bar on a window that is no longer focused, until the
// next event.
//
// HYPRLAND REUSES A CLOSED WINDOW'S ADDRESS for the next one. So a closewindow or an openwindow drops that address's
// client and title at once, and an address no read has described yet is HELD:
// the bar keeps what it shows until the read lands, rather than drawing the
// closed window's class beside the new window's title.
//   windowtitlev2 (address,title) -> THE TITLE IS TAKEN FROM THE EVENT. No read,
//       no refresh: Claude Code's kitty spinner fires this at ~1.2 Hz forever.
//       A title event that is newer than a read in flight wins over that read.
//   activewindowv2 for the address already shown (Hyprland repeats it with every
//       title change) -> nothing at all.
//   urgent -> the flag; focusing the window clears it.
//
// The class is the client's `class`, the initial title its `initialTitle`; both
// are the reader's, never `wayland.appId` (null without a wl_display).
// =============================================================================
ActiveWindowState {
    id: root

    property bool live: false
    // HELD: the focus is moving and will come back (ThemeControl's repaint of the hidden windows); the title stays what it is,
    // and at the release one read says what is really focused.
    property bool held: false
    onHeldChanged: {
        if (!root.held) {
            root._resolve();
            root._requery();
        }
    }
    property string follow: "screen"
    property string screenName: ""
    property var focusSource: null

    // ---- Private ---------------------------------------------------------------
    // address -> hyprctl client; monitors as read (patched by the events that carry
    // the same facts -- with a focus source only their special workspaces are
    // used); workspace id -> its last window's address
    property var _clients: ({})
    property var _monitors: []
    property var _wsLast: ({})
    property string _active: ""
    property var _titles: ({})
    property var _titleSeq: ({})
    property var _urgentSet: ({})
    // Every event that says something is numbered; a read remembers the number it
    // began at, and a fact an event set after that is newer than the read's.
    property int _seq: 0
    property int _runSeq: 0
    property int _activeSeq: 0
    property int _monSeq: 0
    property var _addrSeq: ({})          // address -> the last open/close event at it
    property bool _busy: false
    property bool _again: false
    readonly property string _mark: "@@QS" + Math.floor(Math.random() * 1000000000) + "@@"

    function _addr(s: string): string {
        if (s === "")
            return "";
        return s.indexOf("0x") === 0 ? s : "0x" + s;
    }

    function _onEvent(name: string, data: string): void {
        switch (name) {
        case "windowtitlev2": {
            const i = data.indexOf(",");
            if (i > 0)
                root._onTitle(root._addr(data.substring(0, i)), data.substring(i + 1));
            return;
        }
        case "activewindowv2":
            root._onActive(root._addr(data));
            return;
        case "urgent":
            root._onUrgent(root._addr(data));
            return;
        case "focusedmonv2": {
            // "<monitor>,<workspace id>": the monitor holds the focus, showing that workspace
            // (a focus source has it already: it listens to the same line)
            const i = data.lastIndexOf(",");
            if (i > 0 && !root.focusSource)
                root._patchMonitor(data.substring(0, i), Number(data.substring(i + 1)), true);
            break;
        }
        case "workspacev2": {
            // "<id>,<name>": the focused monitor now shows it
            const i = data.indexOf(",");
            if (i > 0 && !root.focusSource)
                root._patchFocusedWorkspace(Number(data.substring(0, i)));
            break;
        }
        case "openwindow":
        case "closewindow":
            root._onOpenClose(root._addr(data.split(",")[0]));
            break;
        case "movewindowv2":
        case "moveworkspacev2":
        case "monitoradded":
        case "monitoraddedv2":
        case "monitorremoved":
        case "createworkspacev2":
        case "destroyworkspacev2":
        case "activespecial":
        case "activespecialv2":
            break;
        default:
            return;
        }
        root._requery();
    }

    // A window opened or closed at this address: whatever was known about the
    // window there is about another window now (Hyprland reuses addresses).
    function _onOpenClose(addr: string): void {
        if (addr === "")
            return;
        root._addrSeq[addr] = ++root._seq;
        delete root._clients[addr];
        delete root._titles[addr];
        delete root._titleSeq[addr];
        delete root._urgentSet[addr];
    }

    function _onTitle(addr: string, title: string): void {
        root._titles[addr] = title;
        root._titleSeq[addr] = ++root._seq;
        if (addr === root.address)
            root._apply({ title: title });
    }

    function _onUrgent(addr: string): void {
        root._urgentSet[addr] = true;
        if (addr === root.address)
            root._apply({ urgent: true });
    }

    function _onActive(addr: string): void {
        if (addr === root._active)
            return;
        root._activeSeq = ++root._seq;
        root._active = addr;
        delete root._urgentSet[addr];
        const c = addr !== "" ? root._clients[addr] : null;
        if (c)
            root._wsLast[HyprWs.key(c.workspace)] = addr;
        root._resolve();
        if (addr !== "" && !c)
            root._requery();
    }

    function _patchMonitor(name: string, wsId: int, focused: bool): void {
        root._monSeq = ++root._seq;
        const ms = root._monitors;
        for (let i = 0; i < ms.length; i++) {
            if (focused)
                ms[i].focused = ms[i].name === name;
            if (ms[i].name === name)
                ms[i].activeWorkspace = { id: wsId, name: String(wsId) };
        }
        root._resolve();
    }

    function _patchFocusedWorkspace(wsId: int): void {
        root._monSeq = ++root._seq;
        const ms = root._monitors;
        for (let i = 0; i < ms.length; i++)
            if (ms[i].focused)
                ms[i].activeWorkspace = { id: wsId, name: String(wsId) };
        root._resolve();
    }

    // What `name` shows and whether it holds the focus: { focused, workspace, special }
    // (special: the HyprWs.key of the special workspace over it, 0 for none), or null for a
    // monitor nobody knows. With a focus source the first two are ITS facts; the special
    // workspace is always this service's own reading.
    function _monitorFacts(name: string): var {
        let mon = null;
        for (let i = 0; i < root._monitors.length; i++)
            if (root._monitors[i].name === name)
                mon = root._monitors[i];
        const sp = mon ? HyprWs.key(mon.specialWorkspace) : 0;
        const src = root.focusSource;
        if (src) {
            const ms = src.monitors;
            for (let i = 0; i < ms.length; i++)
                if (ms[i].name === name)
                    return { focused: ms[i].focused === true, workspace: ms[i].activeWorkspaceId, special: sp };
            return null;
        }
        if (!mon)
            return null;
        return { focused: !!mon.focused, workspace: mon.activeWorkspace ? mon.activeWorkspace.id : 0, special: sp };
    }

    // What the bar shows, from what is known.
    function _resolve(): void {
        if (root.held)
            return;
        let addr = root._active;
        let focused = true;
        if (root.follow === "screen" && root.screenName !== "") {
            const mon = root._monitorFacts(root.screenName);
            if (mon) {
                addr = root._wsLast[mon.special !== 0 ? mon.special : mon.workspace] || "";
                focused = mon.focused;
            }
        }
        const c = addr !== "" ? root._clients[addr] : null;
        if (!c) {
            // A window no read has described yet (just opened, or a reused
            // address): HELD -- what is shown stays until the read lands.
            if (addr !== "")
                return;
            root._applyEmpty(focused);
            return;
        }
        root._apply({
            address: addr,
            cls: String(c["class"] || ""),
            title: root._titles[addr] !== undefined ? root._titles[addr] : String(c.title || ""),
            initialTitle: String(c.initialTitle || ""),
            empty: false,
            focused: focused,
            urgent: root._urgentSet[addr] === true
        });
    }

    function _requery(): void {
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
        root._runSeq = root._seq;
        reader.running = true;
    }

    function _json(s: string, fallback: var): var {
        try {
            return JSON.parse(s);
        } catch (e) {
            return fallback;
        }
    }

    function _read(text: string): void {
        const parts = text.split(root._mark);
        if (parts.length < 4) {
            root._busy = false;
            return;
        }
        const act = root._json(parts[0], {});
        const mons = root._json(parts[1], null);
        const wss = root._json(parts[2], null);
        const cls = root._json(parts[3], null);
        if (!Array.isArray(mons) || !Array.isArray(wss) || !Array.isArray(cls)) {
            root._busy = false;
            return;
        }
        const newer = seq => seq !== undefined && seq > root._runSeq;
        const clients = {};
        for (let i = 0; i < cls.length; i++) {
            const c = cls[i];
            // A window opened or closed at this address since the read began:
            // the read describes the one before.
            if (c.mapped === false || newer(root._addrSeq[c.address]))
                continue;
            clients[c.address] = c;
            // a title event newer than this read's start is newer than the read
            if (root._titleSeq[c.address] !== undefined && root._titleSeq[c.address] > root._runSeq)
                c.title = root._titles[c.address];
            else
                root._titles[c.address] = String(c.title || "");
        }
        for (const a in root._titles)
            if (!(a in clients) && !newer(root._titleSeq[a])) {
                delete root._titles[a];
                delete root._titleSeq[a];
                delete root._urgentSet[a];
            }
        const last = {};
        for (let i = 0; i < wss.length; i++)
            last[wss[i].id] = wss[i].lastwindow && wss[i].lastwindow !== "0x0" ? wss[i].lastwindow : "";
        root._clients = clients;
        // The monitors and the focus as events left them, if events are newer.
        if (!newer(root._monSeq))
            root._monitors = mons;
        if (!newer(root._activeSeq))
            root._active = act && act.address ? String(act.address) : "";
        else if (clients[root._active])
            last[HyprWs.key(clients[root._active].workspace)] = root._active;
        root._wsLast = last;
        root._ready = true;
        root._resolve();
        root._busy = false;
        if (root._again) {
            root._again = false;
            debounce.restart();
        }
    }

    onFollowChanged: root._resolve()
    onScreenNameChanged: root._resolve()
    onFocusSourceChanged: root._resolve()

    // The source moved: a monitor took the focus, showed another workspace, came or
    // went. It tells us once per real change, and no event of ours need have said so.
    Connections {
        target: root.focusSource
        ignoreUnknownSignals: true
        function onChanged() {
            root._resolve();
        }
    }

    Timer {
        id: debounce
        interval: 25
        onTriggered: root._run()
    }

    Process {
        id: reader
        command: ["sh", "-c", "hyprctl -j activewindow; echo '" + root._mark + "'; hyprctl -j monitors; echo '" + root._mark
            + "'; hyprctl -j workspaces; echo '" + root._mark + "'; hyprctl -j clients"]
        stdout: StdioCollector {
            onStreamFinished: root._read(this.text)
        }
    }

    // A reader that never produced output (no hyprctl, killed) must not leave the
    // service waiting for it.
    Connections {
        target: reader
        function onExited(exitCode, exitStatus) {
            if (root._busy && exitCode !== 0) {
                root._busy = false;
                root._ready = true;
            }
        }
    }

    // The singleton is the event line and nothing else, and only when live.
    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    root._onEvent(ev.name, ev.data);
                }
            }
            Component.onCompleted: {
                root._ready = false;
                root._run();
            }
        }
    }
}
