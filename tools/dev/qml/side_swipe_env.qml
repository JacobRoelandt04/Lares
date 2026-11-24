pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

import "modules/common/scroll"
import "modules/common/scroll/HeldPointer.js" as Held
import "modules/common/theme"
import "modules/shell/cursor"

// =============================================================================
// tools/dev/qml/side_swipe_env.qml -- a mouse and a touchpad as a real compositor hands them to a layer window, read by the shell's one reader
// (WheelArea), and a side-button swipe whose hidden pointer Hyprland keeps in place (SideSwipe, HeldPointer.js; the wiring is ShellScreen's).
// tools/dev/side_swipe_env_probe.sh runs it in the nested Hyprland of tools/dev/lock_env.sh. Prints SSE lines.
// =============================================================================
ShellRoot {
    PanelWindow {
        id: win
        screen: Quickshell.screens[0]
        anchors {
            top: true
            left: true
        }
        implicitWidth: 700
        implicitHeight: 800
        color: Theme.surface
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.namespace: "lares-probe"

        Item {
            anchors.fill: parent
            WheelArea {
                anchors.fill: parent
                turned: ev => console.log("SSE ev " + ev.device + " ax=" + ev.angleDelta.x + " ay=" + ev.angleDelta.y + " px=" + ev.pixelDelta.x + " py=" + ev.pixelDelta.y
                                          + " phase=" + ev.phase + " steps=" + ev.steps + " click=" + ev.click)
            }
        }
        SideSwipe {
            id: side
            holds: true
            onPointer: (what, dx, dy) => {
                console.log("SSE ask " + what + " " + dx + " " + dy);
                Hyprland.dispatch(Held.expr(what, dx, dy));
            }
            onHidingChanged: console.log("SSE hiding " + side.hiding)
        }
        CursorCover {
            anchors.fill: parent
            hidden: side.hiding
        }
    }
    Timer {
        interval: 1500
        running: true
        onTriggered: console.log("SSE ready")
    }
}
