pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../components"

// =============================================================================
// Sleep.qml -- the shell's ONE SleepWatcher.
//
//   Sleep.watcher    the SleepWatcher every BoundaryClock follows by default
//                    (its `sleepWatcher`); anything else that shows the wall
//                    clock relative to now hooks the same one:
//                        Connections { target: Sleep.watcher; function onResumed() { ... } }
//
// CREATED ON FIRST USE. A QML singleton is instantiated the first time a
// binding reads it, so a shell that shows no relative time runs no monitor,
// and the first clock that follows starts the one `gdbus monitor` every later
// clock shares -- however many LlmTurns, note tiles and notification cards
// build their own BoundaryClock. A clock whose host hands it a watcher (or
// null) never reads this default, so it never creates it (measured: an
// assignment in the instantiating document replaces the component's own
// binding before it is evaluated). It lives as long as the shell's engine:
// a config reload makes a new one and ends the old one's monitor, and the
// monitor itself runs under `setpriv --pdeathsig TERM`, so it dies with the
// shell however the shell dies.
//
// LARES_SLEEP_MONITOR (the environment, read once) -- for test runners only:
//   unset / anything else   the monitor on the SYSTEM bus (the shell)
//   off                     no monitor; `feed()` still works, so a probe can
//                           play logind's lines to every clock at once. A
//                           runner whose QML builds clocks (LlmTurn, NotesGrid,
//                           SystemUpdatePopup, the notification card) and that
//                           must not read the system bus, or that puts a stub
//                           `gdbus` on PATH or empties PATH, sets this.
//   session                 the same monitor on the SESSION bus: only under a
//                           private bus with a stand-in logind
//
// ONE EVEN WHEN A FILE IS LOADED BY PATH. A singleton is one per TYPE, and a
// type is one per URL: Quickshell loads a config's files as `qs:@/qs/<path>`,
// but a file created with Qt.createComponent(Quickshell.shellDir + "/x.qml") is
// `qs:/home/.../x.qml`, so everything it imports is a second set of types --
// and this a second singleton. Its clocks would follow a second watcher:
// Sleep.watcher.feed() from the root would reach none of them, and without
// LARES_SLEEP_MONITOR=off the shell would run two gdbus monitors (measured with
// the createComponent pattern). So only the config's OWN copy builds a watcher:
// the one at `qs:@/qs/`, or -- the shell's body is created from a `file:` URL
// (shell.qml's stub, shell.jsonc `workarounds.fileRoot`) -- the one at
// `file://<shellDir>/`; the shell loads one of the two, never both. Any other
// copy hands out the own one of its own scheme (a `qs:` copy the `qs:@/qs/` one,
// a `file:` copy the one under shellDir), looked up by its URL at runtime --
// never by a static import, which Quickshell's scanner and qmllint both reject.
// A file created by a URL relative to its creator's (Qt.resolvedUrl("x.qml"),
// or "x.qml") shares the shell's types and never needs this.
// =============================================================================
Singleton {
    id: root

    readonly property string mode: Quickshell.env("LARES_SLEEP_MONITOR") ?? ""
    // `var`: the shell's watcher is of the shell's SleepWatcher type, which
    // a copy loaded by path does not share (a cast to its own is null).
    readonly property var watcher: root._forward ? root._forward.w : root._own

    property var _own: null
    // A copy loaded by path: a QtObject compiled against the shell's URL
    // whose `w` is bound to the shell's Sleep.watcher.
    property var _forward: null
    Component {
        id: ownC
        SleepWatcher {
            enabled: root.mode !== "off"
            bus: root.mode === "session" ? "session" : "system"
        }
    }
    // Where this copy was loaded from: the stack's TOP frame names its file
    // (the frames under it are whoever first read Sleep, anywhere).
    Component.onCompleted: {
        const top = String(new Error().stack).split("\n")[0];
        const fileRoot = "file://" + encodeURI(String(Quickshell.shellDir).replace(/\/+$/, "")) + "/";
        if (top.indexOf("@qs:@/qs/") >= 0 || top.indexOf("@" + fileRoot) >= 0) {
            root._own = ownC.createObject(root);
            return;
        }
        const own = top.indexOf("@file:") >= 0 ? fileRoot : "qs:@/qs/";
        root._forward = Qt.createQmlObject(
            "import QtQml\nimport \"" + own + "modules/common/system\"\nQtObject { readonly property var w: Sleep.watcher }",
            root, "SleepForward");
    }
}
