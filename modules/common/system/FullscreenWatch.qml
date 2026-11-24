pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Hyprland

// =============================================================================
// FullscreenWatch.qml -- is the focused workspace showing a fullscreen window,
// and which screen is focused. Shared by the toast holds and the OSD, so
// they ask the same question the same way.
//
// LIVE (`liveSignals: true`, `fake: false`): Hyprland's socket2 through
// `Hyprland.rawEvent` --
//   fullscreen>>0|1   the focused window left / entered fullscreen
// (the documented event name; it is short enough to be built inline in the
// binary, so `strings` cannot show it). A workspace switch re-reads the fact
// from the focused workspace's `hasfullscreen` (after one refresh), since a
// fullscreen window left behind on another workspace sends no event when you
// leave it. The focused monitor's name follows `focusedMonitor`.
//
// NOT LIVE (`liveSignals: false`, or `fake: true`): nothing Hyprland is
// created. `fake: true` answers `fakeFullscreen` and an empty `focusedScreen`;
// a probe or a mockup drives it and never reaches the compositor.
//
// WITH A SOURCE (`focusSource`: a FocusedScreen): both answers come from it and
// nothing here talks to Hyprland, so they are right from the first frame -- the
// source reads hyprctl at start where `Hyprland.focusedMonitor` is null until an
// event arrives (Hyprland 0.56) -- and the whole shell asks ONE focus tracker.
// `liveSignals` and `fake` then mean nothing: the source is live or a fake, and
// that is its own flag. (An Item's `focus` is FINAL, so a component that is an
// Item cannot declare a property of that name.)
// =============================================================================
Item {
    id: root

    property bool liveSignals: true
    property bool fake: false
    property bool fakeFullscreen: false
    // A FocusedScreen (modules/common/system); null = this reads Hyprland itself.
    property var focusSource: null

    // The focused workspace has a fullscreen window.
    readonly property bool fullscreen: root.focusSource ? root.focusSource.fullscreen
                                                         : (root.fake ? root.fakeFullscreen : root._live)
    // The focused monitor's name ("" when unknown / not live).
    readonly property string focusedScreen: root.focusSource ? root.focusSource.name
                                                              : (root.fake ? "" : root._liveScreen)

    property bool _live: false
    property string _liveScreen: ""

    // The focused workspace's own answer: `hasfullscreen` from its last IPC
    // object (fresh after a refresh), else the property.
    function _readFullscreen() {
        const ws = Hyprland.focusedWorkspace;
        if (!ws) {
            root._live = false;
            return;
        }
        const o = ws.lastIpcObject || {};
        root._live = o.hasfullscreen !== undefined ? !!o.hasfullscreen : !!ws.hasFullscreen;
    }

    function _readScreen() {
        root._liveScreen = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
    }

    LazyLoader {
        active: root.liveSignals && !root.fake && !root.focusSource
        component: Scope {
            Connections {
                target: Hyprland
                function onRawEvent(ev) {
                    if (ev.name === "fullscreen")
                        root._live = String(ev.data) === "1";
                }
                function onFocusedMonitorChanged() { root._readScreen(); }
                // A fullscreen window left on the workspace we came from sends
                // nothing when we leave it: ask the new one (one request per
                // switch; its answer lands as lastIpcObjectChanged below).
                function onFocusedWorkspaceChanged() {
                    Hyprland.refreshWorkspaces();
                    root._readFullscreen();
                }
            }
            Connections {
                target: Hyprland.focusedWorkspace
                function onLastIpcObjectChanged() { root._readFullscreen(); }
                function onHasFullscreenChanged() { root._readFullscreen(); }
            }

            Component.onCompleted: {
                root._readScreen();
                root._readFullscreen();
            }
        }
    }
}
