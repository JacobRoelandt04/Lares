import QtQuick
import Quickshell
import Quickshell.Wayland

// =============================================================================
// busy_layer.qml -- A REAL BOOT'S BUSY COMPOSITOR, for tools/dev/lock_boot_film.sh (a client of lock_env's nested
// Hyprland only; `"$E" run quickshell -p <copy of this>`).
//
// On a real boot the lock starts while hyprpaper maps and fades its wallpaper in, themectl re-sets it and the cursor
// theme is set: the compositor draws frame after frame of the whole output. A nested env where the lock starts two
// seconds after an idle hyprpaper draws NO frame between the lock's request and its first commit -- the span in which
// Hyprland renders the workspace (the wallpaper) under a lock that has not drawn yet -- so a film there cannot see what
// the user films at every boot. This layer stands in for that: a full-screen, fully transparent surface on the
// Background layer that commits every frame (a FrameAnimation), so every vsync is a whole-output frame. It draws
// nothing anyone can see; its namespace is its own.
// =============================================================================
ShellRoot {
    Variants {
        model: Quickshell.screens
        PanelWindow {
            id: win
            required property var modelData
            screen: win.modelData
            anchors {
                top: true
                bottom: true
                left: true
                right: true
            }
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "lockfilm-busy"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            color: "transparent"
            mask: Region {}

            // a value that changes every frame, drawn at an alpha no frame can show: the window re-renders (and commits
            // its whole surface) at every vsync
            property real phase: 0
            FrameAnimation {
                running: true
                onTriggered: win.phase = (win.phase + 1) % 2
            }
            Rectangle {
                width: 2
                height: 2
                color: Qt.rgba(win.phase, 0, 0, 0.001)
            }
        }
    }
}
