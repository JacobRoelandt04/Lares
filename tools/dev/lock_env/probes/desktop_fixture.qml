// A stand-in desktop for the lock proofs (tools/dev/lock_env.sh): a wallpaper
// layer, one "application" window with readable content, and a bar layer in
// the `lares-bar` namespace that the test Hyprland draws ABOVE the lock.
// Colours are chosen to be told apart by a pixel probe:
//   wallpaper  #2E8B57 (green) with white stripes
//   window     #C0392B (red) with the word SECRET
//   bar        #EAEDF5 with a #4480F4 square at its left end
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    settings.watchFiles: false

    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            WlrLayershell.layer: WlrLayer.Background
            WlrLayershell.namespace: "fixture-wallpaper"
            exclusionMode: ExclusionMode.Ignore
            anchors { left: true; right: true; top: true; bottom: true }
            color: "#2E8B57"
            Repeater {
                model: 40
                Rectangle { required property int index; x: 0; y: index * 48; width: parent.width; height: 6; color: "white" }
            }
        }
    }

    Variants {
        model: Quickshell.screens
        PanelWindow {
            required property var modelData
            screen: modelData
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "lares-bar"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            anchors { left: true; right: true; top: true }
            implicitHeight: 40
            color: "#EAEDF5"
            Rectangle { x: 8; y: 8; width: 24; height: 24; color: "#4480F4" }
            Text { x: 44; y: 10; text: "fixture bar"; color: "#5D5D5F"; font.pixelSize: 16 }
            // The pointer proof: while locked this must hear NOTHING (the
            // bar is drawn above the lock but is not interactive).
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: console.log("FIXTURE bar hover")
                onClicked: console.log("FIXTURE bar click")
            }
        }
    }

    FloatingWindow {
        title: "fixture-secret"
        implicitWidth: 900
        implicitHeight: 600
        color: "#C0392B"
        Text {
            anchors.centerIn: parent
            text: "SECRET"
            color: "white"
            font.pixelSize: 160
            font.bold: true
        }
    }
}
