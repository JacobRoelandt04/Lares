pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland

import "modules/common/theme"
import "modules/bridge"
import "modules/bridge/data"
import "modules/common/scroll/HeldPointer.js" as Look

// =============================================================================
// tools/dev/qml/bridge_look_env.qml -- the bridge popup's FREE LOOK on a real compositor (tools/dev/bridge_look_env_probe.sh
// runs it in the nested Hyprland of tools/dev/lock_env.sh; it has a PanelWindow, so a bare smoke only loads it there).
// What offscreen cannot show: the keyboard modifiers reaching a layer surface that asked for the keyboard on demand, the
// pointer hidden, and Hyprland putting the pointer back (HeldPointer.js). The real BridgePopup over the mock service in a
// layer window that follows the popup's own keyboard ask; the runner holds Alt (wtype) and moves the env's pointer.
// Prints BLE lines.
// =============================================================================
ShellRoot {
    id: root

    property int mods: 0
    BridgeService {
        id: svc
        live: false
        scenario: "wired"
        mockLineMs: 0
        mockStepMs: 0
    }
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
        WlrLayershell.keyboardFocus: popup.keyboardFocusRequest === "onDemand" ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

        BridgePopup {
            id: popup
            x: 190
            y: 68
            width: popup.implicitWidth
            height: popup.implicitHeight
            service: svc
            flipOnOpen: false
            onLookPointer: what => {
                console.log("BLE ask " + what);
                Hyprland.dispatch(Look.expr(what));
            }
            onKeyboardFocusRequestChanged: console.log("BLE keys " + popup.keyboardFocusRequest)
            Keys.onPressed: event => console.log("BLE key " + event.key)
            onActiveFocusChanged: console.log("BLE focus " + popup.activeFocus)
        }
        Connections {
            target: popup.stage
            function onLookHeldChanged(): void {
                if (popup.stage.lookHeld)
                    console.log("BLE held");
                else
                    console.log("BLE let yaw=" + popup.stage._lookYaw0.toFixed(3) + " pitch=" + popup.stage._lookPitch0.toFixed(1));
            }
            function onPointerMoved(modifiers: int): void {
                if (modifiers !== root.mods) {
                    root.mods = modifiers;
                    console.log("BLE mods " + modifiers);
                }
            }
            function onLookingChanged(): void {
                if (!popup.stage.looking)
                    console.log("BLE rest face=" + popup.stage.face + " ex=" + popup.stage._axes.ex[0]);
            }
        }
    }
    Timer {
        interval: 1500
        running: true
        onTriggered: console.log("BLE ready " + (190 + 160) + " " + (68 + 300))
    }
}
