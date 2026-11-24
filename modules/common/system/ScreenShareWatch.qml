pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire

// =============================================================================
// ScreenShareWatch.qml -- is the screen being shared or recorded right now? ONE per shell (ShellServices), read by the toasts'
// holds (NotificationHolds: a toast waits while the screen is shown) and the idle auto layer (IdleAuto: no dimming while others see
// the screen). It used to live in NotificationHolds; it is the same reading, lifted so both ask one watcher.
//
// THE SCREEN SHARE (`active`) IS TWO SESSIONS, each read from the thing that stands for as long as the share does. Hyprland's
// `screencast>>STATE,OWNER` is not one, and on its own it cannot be made into one (on Hyprland 0.56.2 and 0.57):
//
//   The event says only that SOMEBODY took a frame. 1 is a frame, 0 is half a second with no more, OWNER is the share's TYPE
//   (monitor, window, region), never the client. A grim sends 1 and 0 within milliseconds; a recorder on a still screen sends 1, 0
//   half a second later, and 1 again at the next damage; and the shell's OWN stills (one frame of a ScreencopyView: the theme
//   curtain, the sleep fade, the lock's desktop), whose client stays connected, send 1 and 0 exactly 500 ms apart, which is a
//   recorder's shape to the millisecond. Any reading that tries to tell them apart by timing breaks on the next case (a recorder's
//   quiet half second ends the hold; a screenshot reads as a share; two theme switches in 20 s read as "a recorder woken by damage",
//   and the quiet period that ends it plays the aura out of nowhere). So the event decides nothing here: it only says when it is
//   worth asking who.
//
//   THE PORTAL'S NODE. xdg-desktop-portal-hyprland serves every cast (OBS, a browser's or Discord's screen share) as a PipeWire
//   Video/Source node for as long as the session lives, frames or none, and the node going is the end of the share, at once. On xdph
//   1.4.1 `xdph-streaming-<n>` is its media.name, and its node.name, the only one Quickshell gives without tracking the node
//   (`PwNode.name`; `properties` is empty until then), is the program's, `xdg-desktop-portal-hyprland`. `castNodes` counts those
//   from Quickshell's PipeWire (`livePipewire`). A camera's node is a Video/Source too and is not named so.
//
//   A RECORDER'S PROCESS. A wlr recorder has no node, but it has a name: on a `1` (and every `recorderPollMs` while one runs)
//   `pidof` asks after `recorders`, of THIS session only (any Wayland client has this runtime dir in its environment; a client of a
//   nested compositor has its own). A shell's still and a screenshot have no such process, whatever their timing; a recorder is a
//   share from its first frame until its process is gone. The price is the list: a recorder not on it is not seen.
//
// `active` = either reader says so. LIVE (`liveSignals`): Hyprland's socket2 through `Hyprland.rawEvent` (the `screencast` event);
// NOT LIVE: nothing Hyprland is created and a probe writes `fakeRecorder` / `castNodes` and calls `castEvent`. `livePipewire` is
// OFF until the host turns it on (against a private daemon in a probe): a watch made live only to read the compositor must not
// open a PipeWire connection, which logs an ERROR wherever there is no daemon (a nested test compositor).
// =============================================================================
Item {
    id: root

    property bool liveSignals: true
    property bool livePipewire: false
    // The recorders with no portal session, by process name (every one of them captures through wlr-screencopy or ext-image-copy-capture).
    property var recorders: ["wf-recorder", "wl-screenrec", "wayvnc"]
    // How often a running recorder is asked after: its end is seen this late at most.
    property int recorderPollMs: 2000

    // The portal's screen-cast sessions now: live from PipeWire, or written by a probe.
    property int castNodes: 0
    // What a probe says the recorder's process answers when not live.
    property bool fakeRecorder: false

    // The screen is being shared or recorded.
    readonly property bool active: root._recorder || root.castNodes > 0
    // True until the first reading of the graph: a share that stands then was not started now (the shell came up during it).
    readonly property bool pending: root.livePipewire && !root._castsRead

    // One line of Hyprland's `screencast>>STATE,OWNER` (STATE 1 | 0). Only a 1 says anything: somebody just took a frame.
    function castEvent(data: var): void {
        if (String(data).split(",")[0].trim() === "1")
            root._askRecorder();
    }

    // A recorder's process is running. (`_castsRead`: the graph has been read once.)
    property bool _recorder: false
    property bool _castsRead: false

    function _askRecorder(): void {
        if (!root.liveSignals)
            root._recorder = root.fakeRecorder;
        else if (!recorderAsk.running)
            recorderAsk.running = true;
    }
    Process {
        id: recorderAsk
        command: ["sh", "-c", 'for p in $(pidof "$@"); do grep -qzxF "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" "/proc/$p/environ" 2> /dev/null && exit 0; done; exit 1', "sh"].concat(root.recorders)
        onExited: code => root._recorder = code === 0
    }
    Timer {
        interval: root.recorderPollMs
        running: root._recorder
        repeat: true
        onTriggered: root._askRecorder()
    }

    // Count the portal's cast nodes (live PipeWire only; the loader below calls it).
    function _readCasts(): void {
        const ns = Pipewire.nodes ? Pipewire.nodes.values : [];
        let n = 0;
        for (let i = 0; i < ns.length; i++)
            if (ns[i].name === "xdg-desktop-portal-hyprland")
                n++;
        root.castNodes = n;
        if (Pipewire.ready)
            root._castsRead = true;
    }

    LazyLoader {
        active: root.livePipewire
        component: Scope {
            id: casts
            // Held in a var so the linter does not take the model for a QObject type; the signal is real
            // (an ObjectModel says `valuesChanged` for every node that comes or goes).
            readonly property var model: Pipewire.nodes
            Connections {
                target: casts.model
                function onValuesChanged() { root._readCasts(); }
            }
            Connections {
                target: Pipewire
                function onReadyChanged() { root._readCasts(); }
            }
            Component.onCompleted: root._readCasts()
        }
    }

    LazyLoader {
        active: root.liveSignals
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    if (ev.name === "screencast")
                        root.castEvent(String(ev.data));
                }
            }
        }
    }
}
