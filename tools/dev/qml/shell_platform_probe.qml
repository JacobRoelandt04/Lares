import QtQuick
import Quickshell

// =============================================================================
// tools/dev/qml/shell_platform_probe.qml -- the CLIENT of tools/dev/shell_probe.sh: what sits UNDER the shell's windows in the
// nested Hyprland of tools/dev/lock_env.sh (stream F2). Never run by hand next to a shell in use; everything it says is
// `SHP ...` on the console.
//
// One Background-layer window per output, the whole output, a flat colour, taking every click: the shell's bar window
// is a Top-layer window over the same output with an input region that is only its bodies (the islands, the open
// popups), so a click on the screen's edge under a slim bar -- or in the void between two islands, or anywhere else the
// shell has nothing -- must reach THIS window, and the runner counts which window each click went to:
//
//     SHP bg click <output> <x> <y>
//
// `SHP ready <n>` is said once the n windows exist. The runner reads the layers and the clicks; nothing here moves.
//
// The windows are made from a string, and only in the mode the runner asks for (SHP_MODE=bg): Quickshell rejects a
// PanelWindow in the FILE of an offscreen run ("No PanelWindow backend loaded"), and tools/dev/smoke.sh --all loads every
// harness offscreen.
// =============================================================================
ShellRoot {
    id: root
    settings.watchFiles: false

    readonly property string mode: Quickshell.env("SHP_MODE") || "none"
    property int made: 0

    function windowMade(): void {
        root.made++;
        if (root.made === Quickshell.screens.length)
            readyTimer.start();
    }
    Component.onCompleted: {
        if (root.mode === "bg")
            Qt.createQmlObject(root.bgSource, root, Qt.resolvedUrl("shell_platform_probe.qml"));
    }

    readonly property string bgSource: `
        import QtQuick
        import Quickshell
        import Quickshell.Wayland
        Variants {
            model: Quickshell.screens
            PanelWindow {
                id: win
                required property var modelData
                screen: modelData
                WlrLayershell.layer: WlrLayer.Background
                WlrLayershell.namespace: "shp-bg"
                WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
                exclusionMode: ExclusionMode.Ignore
                anchors { top: true; bottom: true; left: true; right: true }
                color: "#C0392B"
                MouseArea {
                    anchors.fill: parent
                    onClicked: mouse => console.log("SHP bg click " + win.modelData.name + " " + Math.round(mouse.x) + " " + Math.round(mouse.y))
                }
                Component.onCompleted: root.windowMade()
            }
        }`

    Timer {
        id: readyTimer
        interval: 300
        onTriggered: console.log("SHP ready " + root.made)
    }
    Timer {
        interval: 0
        running: root.mode !== "bg"
        onTriggered: console.log("SHP not armed (SHP_MODE=bg: tools/dev/shell_probe.sh)")
    }
}
