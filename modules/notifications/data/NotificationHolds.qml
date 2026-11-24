pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Wayland
import "../../common/components/SenderMatch.js" as SenderMatch
import "../../common/system"

// =============================================================================
// NotificationHolds.qml -- what keeps a toast off the screen right now, and
// who is looking at what (`service.holds`).
//
// LIVE (`liveSignals: true`, the shell): Hyprland's socket2 through
// `Hyprland.rawEvent` --
//   activewindowv2>>ADDRESS    focus moved (the address without 0x)
// (`screencast` is in Hyprland 0.56.2's binary; `fullscreen` is the
// documented name -- it is short enough to be built inline, so `strings`
// cannot show it). A workspace switch re-reads the fullscreen
// fact from the focused workspace's `hasfullscreen` (after one refresh),
// since a fullscreen window left behind on another workspace sends no event
// when you leave it -- that fullscreen fact and the focused screen are
// FullscreenWatch's (common/system), which the OSD uses too. `IdleMonitor` (timeout
// `idleMs`) says when the user is away. The windows come from
// `Hyprland.toplevels` (their `lastIpcObject`: class, initialClass, pid),
// refreshed at start and when a window opens -- never polled. LOCKED IS
// NEVER GUESSED: there is no lock signal to read without locking
// the session, so the user's hypridle `lock_cmd` says it through IPC
// (`quickshell ipc call notifications hold locked true`).
//
// PROBES (`liveSignals: false`): nothing Hyprland or Wayland is created; the
// probe writes fullscreen / screencast / locked / idle / fakeWindows /
// fakeActiveWindow / fakeScreen itself (and the watcher's fakeRecorder / castNodes, through `share`), and `focusApp` only records
// what it would have focused (`lastFocus`) -- a probe never dispatches.
//
// `reason` is the strongest hold: "locked" > "screencast" > "fullscreen" > "app" (a window of `dnd.holdApps` has the
// focus) > "". The config can switch the middle two off (dnd.holdFullscreen / dnd.holdScreencast).
//
// WHERE THE TOASTS COME (`lane`): the display notifications.jsonc names (`screen`) while it is there, else the focused one;
// the fullscreen hold is about that display.
//
// THE SCREEN SHARE (`screencast`) IS READ BY ONE WATCHER PER SHELL, `ScreenShareWatch` (modules/common/system; the portal's cast node
// and a recorder's process, and why Hyprland's `screencast` event decides nothing: its header has it all), which the idle auto layer
// reads too. ShellServices hands the shell's one in as `share`; with none (a mockup, a probe) this holds its own, switched on by
// `liveSignals` / `livePipewire` as before. `screencast` stays a plain property (the IPC's `hold screencast <bool>` and the probes
// write it); it follows the watcher's `active` whenever that changes. `castEvent(data)` is the event's entry for a probe's replay
// (it goes to the watcher).
// =============================================================================
Item {
    id: root

    property bool liveSignals: true
    // The portal's cast nodes from Quickshell's PipeWire, for the watcher this holds when it is handed none: OFF until the service
    // turns it on (it follows its own liveSignals) or a probe does, against a private daemon (PIPEWIRE_RUNTIME_DIR). Not tied to
    // liveSignals here: a holds object made live only to read the compositor (the hosted probes' focus step) must not open a
    // PipeWire connection, which logs an ERROR wherever there is no daemon (a nested test compositor).
    property bool livePipewire: false
    // The shell's ONE screen-share watcher (a ScreenShareWatch, ShellServices); null = this holds its own.
    property var share: null
    property var config: null
    // The shell's one focus tracker (a FocusedScreen, modules/common/system). The watch below then asks IT, not
    // Hyprland, so the lane's screen and the fullscreen hold are right from the first frame and the whole shell
    // reads the same screen; the source is live or a fake itself, so `liveSignals` means nothing for these two.
    // null = today's (this watch reads Hyprland, or a probe writes the fakes).
    property var focusSource: null
    property int idleMs: root.config && root.config.idleMs > 0 ? root.config.idleMs : 60000

    // Live: FullscreenWatch's answer (the Binding below). Not live: whatever the
    // probe writes.
    property bool fullscreen: false
    property bool screencast: false
    // The portal's screen-cast sessions now and whether the graph has been read yet (the watcher's).
    readonly property int castNodes: root._share.castNodes
    // True until the first reading of the graph: a share that stands then was not started now (the shell came up during it).
    readonly property bool castsPending: root._share.pending
    property bool locked: false
    property bool idle: false

    // What the probes set when liveSignals is false.
    property var fakeWindows: []
    property var fakeActiveWindow: null
    property string fakeScreen: ""

    readonly property string reason: root.locked ? "locked"
        : (root.screencast && root._holdScreencast) ? "screencast"
        : (root.fullscreen && root._holdFullscreen) ? "fullscreen"
        : root._holdApp ? "app" : ""

    // { cls, initialClass, title, pid } | null
    readonly property var activeWindow: root.liveSignals ? root._liveActive : root.fakeActiveWindow
    // [{ cls, initialClass, title, pid, address }]
    readonly property var windows: root.liveSignals ? root._liveWindows : root.fakeWindows
    // The focused monitor's name (the lane follows it).
    readonly property string focusedScreen: root.liveSignals || !!root.focusSource ? watch.focusedScreen : root.fakeScreen
    // The display the toasts come on (a focus source says which are there), and whether it is the one the config names.
    readonly property string lane: root.focusSource ? root.focusSource.displayFor(root._screenWord) : root.focusedScreen
    readonly property bool laneNamed: root.lane !== "" && root.lane === root._screenWord
    // The address focusApp last asked for ("" none), for the probes.
    readonly property string lastFocus: root._lastFocus

    // One line of Hyprland's `screencast>>STATE,OWNER` (a probe's replay; the watcher reads the event itself when live).
    function castEvent(data) {
        root._share.castEvent(data);
    }

    // Re-read the windows and the focused one (live only; a lastIpcObject
    // changes with no signal the list hears, so readers ask first).
    function refresh() {
        if (root.liveSignals)
            root._readWindows();
    }

    // The sender's window, focused. False when no window matches.
    function focusApp(rec) {
        root.refresh();
        const w = SenderMatch.focusTarget(rec, root.windows);
        if (!w || !w.address)
            return false;
        root._lastFocus = String(w.address);
        if (root.liveSignals)
            root._focus(root._lastFocus);
        return true;
    }

    // Is this record's sender the focused window?
    function senderFocused(rec) {
        root.refresh();
        const w = root.activeWindow;
        return !!w && SenderMatch.matches(rec, w);
    }

    // ---- Private -------------------------------------------------------------
    readonly property bool _holdScreencast: !root.config || !root.config.dnd || root.config.dnd.holdScreencast !== false
    readonly property string _screenWord: root.config && root.config.screen ? root.config.screen : "focused"
    readonly property bool _holdApp: {
        const apps = root.config && root.config.dnd && root.config.dnd.holdApps ? root.config.dnd.holdApps : [];
        const w = apps.length > 0 ? root.activeWindow : null;
        return !!w && apps.some(a => SenderMatch.norm(a) !== ""
                                     && [SenderMatch.norm(w.cls), SenderMatch.norm(w.initialClass)].indexOf(SenderMatch.norm(a)) >= 0);
    }
    readonly property bool _holdFullscreen: !root.config || !root.config.dnd || root.config.dnd.holdFullscreen !== false
    property var _liveActive: null
    property var _liveWindows: []
    property string _lastFocus: ""

    // The watcher this reads: the shell's, else its own (below).
    readonly property var _share: root.share ? root.share : ownShare
    ScreenShareWatch {
        id: ownShare
        liveSignals: root.liveSignals && !root.share
        livePipewire: root.livePipewire && !root.share
    }
    on_ShareChanged: root.screencast = root._share.active
    Connections {
        target: root._share
        function onActiveChanged() {
            root.screencast = root._share.active;
        }
    }

    // Live only (called when liveSignals is true, so the Hyprland singleton
    // is never touched by a probe).
    // Hyprland's config is Lua, and `Hyprland.dispatch(x)` is `hl.dispatch(x)`: a Lua expression.
    // The `focuswindow address:..` form is a syntax error that only logs a warning and
    // focuses nothing. This one switches to the window's workspace and warps the pointer onto it
    // -- expected for "show me"; a wrong address answers
    // `hl.focus: window not found` with exit 0 and moves nothing.
    function _focus(address) {
        const a = address.indexOf("0x") === 0 ? address : "0x" + address;
        Hyprland.dispatch('hl.dsp.focus({ window = "address:' + a + '" })');
    }

    function _winOf(t) {
        const o = t && t.lastIpcObject ? t.lastIpcObject : {};
        return {
            cls: String(o["class"] || ""),
            initialClass: String(o.initialClass || ""),
            title: String(t && t.title ? t.title : (o.title || "")),
            pid: Number(o.pid || 0),
            address: String(t && t.address ? t.address : (o.address || "")),
            focusHistoryId: typeof o.focusHistoryID === "number" ? o.focusHistoryID : -1
        };
    }

    function _readWindows() {
        const list = Hyprland.toplevels ? Hyprland.toplevels.values : [];
        const out = [];
        for (let i = 0; i < list.length; i++)
            out.push(root._winOf(list[i]));
        root._liveWindows = out;
        root._readActive();
    }

    // Hyprland.activeToplevel is null until the first focus event after a
    // start; until then the focused window is the one whose focusHistoryID
    // is 0 in the last client list.
    function _readActive() {
        const a = Hyprland.activeToplevel;
        if (a) {
            root._liveActive = root._winOf(a);
            return;
        }
        const ws = root._liveWindows;
        let found = null;
        for (let i = 0; i < ws.length; i++)
            if (ws[i].focusHistoryId === 0)
                found = ws[i];
        root._liveActive = found;
    }

    FullscreenWatch {
        id: watch
        liveSignals: root.liveSignals
        fake: !root.liveSignals
        fakeFullscreen: root.fullscreen
        focusSource: root.focusSource
    }
    Binding {
        target: root
        property: "fullscreen"
        value: root.laneNamed ? root.focusSource.fullscreenOn(root.lane) : watch.fullscreen
        when: root.liveSignals || !!root.focusSource
    }

    LazyLoader {
        active: root.liveSignals
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    const n = ev.name;
                    if (n === "activewindowv2")
                        root._readActive();
                    else if (n === "openwindow" || n === "closewindow")
                        Hyprland.refreshToplevels();
                }
                function onActiveToplevelChanged() { root._readActive(); }
            }
            // a window that takes the focus as it opens has no class yet: its object lands with the refresh
            Connections {
                target: Hyprland.activeToplevel
                ignoreUnknownSignals: true
                function onLastIpcObjectChanged() { root._readActive(); }
            }
            Connections {
                target: Hyprland.toplevels
                function onValuesChanged() { root._readWindows(); }
            }

            IdleMonitor {
                enabled: root.liveSignals
                respectInhibitors: true
                timeout: root.idleMs / 1000
                onIsIdleChanged: root.idle = isIdle
            }

            Component.onCompleted: {
                Hyprland.refreshToplevels();
                root._readWindows();
            }
        }
    }
}
