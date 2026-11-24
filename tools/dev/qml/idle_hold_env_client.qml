// The client of tools/dev/idle_hold_env_probe.sh -- inside tools/dev/lock_env.sh's nested Hyprland only (it starts nothing else and
// touches no bus). Neither part is the shell's:
//
//   IHC_MODE unset: the listener and the app.
//   - THE LISTENER: hypridle's 240 s suspend listener in small. An ext-idle-notify-v1 notification that RESPECTS INHIBITORS
//     (Quickshell's IdleMonitor asks get_idle_notification, as hypridle does for a listener without `ignore_inhibit`), its timeout
//     IHC_TIMEOUT seconds (default 3; the probe asks 4). The compositor says "idled" when the seat has had no input for that long AND no idle inhibitor it
//     counts is held: the moment hypridle would run `systemctl suspend`. Every verdict is printed: `IHC idle 1|0 <ms>`.
//   - THE APP: an ordinary toplevel (title `ihc-app`) the probe puts fullscreen, so the shell's bar window is covered and a popup
//     opened then floats over it (ShellScreen: over a fullscreen window).
//   `IHC up` once both exist.
//
//   IHC_MODE=blip: SOMETHING ELSE MAKES HYPRLAND RECHECK, as any window mapped or focused does in a real session: a small Top layer
//   (under a fullscreen window: alpha 0, so it counts for nothing itself) makes an idle inhibitor 0.3 s after it is up and quits at
//   1.2 s (the inhibitor destroyed: a second recheck). `IHC blip on|off`.
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root
    settings.watchFiles: false

    readonly property bool blip: Quickshell.env("IHC_MODE") === "blip"

    LazyLoader {
        active: !root.blip
        component: Scope {
            FloatingWindow {
                id: app
                title: "ihc-app"
                implicitWidth: 640
                implicitHeight: 400
                color: "#2a4d7a"
            }
            IdleMonitor {
                id: listener
                timeout: Number(Quickshell.env("IHC_TIMEOUT") || 3)
                respectInhibitors: true
                onIsIdleChanged: console.log("IHC idle " + (listener.isIdle ? 1 : 0) + " " + Date.now())
            }
            Component.onCompleted: console.log("IHC up timeout=" + listener.timeout + " " + Date.now())
        }
    }

    LazyLoader {
        active: root.blip
        component: Scope {
            PanelWindow {
                id: blipWin
                WlrLayershell.layer: WlrLayer.Top
                WlrLayershell.namespace: "ihc-blip"
                exclusionMode: ExclusionMode.Ignore
                anchors {
                    bottom: true
                    left: true
                }
                implicitWidth: 8
                implicitHeight: 8
                color: "#01000000"
                mask: Region {}
                IdleInhibitor {
                    window: blipWin
                    enabled: blipOn.running === false && blipOff.running
                }
            }
            Timer {
                id: blipOn
                interval: 300
                running: true
                onTriggered: console.log("IHC blip on " + Date.now())
            }
            Timer {
                id: blipOff
                interval: 1200
                running: true
                onTriggered: {
                    console.log("IHC blip off " + Date.now());
                    Qt.quit();
                }
            }
        }
    }
}
