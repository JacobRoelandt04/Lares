import QtQuick
import Quickshell

// =============================================================================
// tools/dev/qml/aerial_keys_app.qml -- the STAND-IN APP of tools/dev/aerial_keys_env_probe.sh (the user's vscode): a toplevel window
// with a focused text field that logs what the compositor's keyboard delivers to it:  `AKA text <whole text>`.
// Only run in the nested Hyprland of tools/dev/lock_env.sh. The window is made from a string, only when AKA_MODE=win (Quickshell
// rejects a window of this kind in the FILE of an offscreen run, and `tools/dev/smoke.sh --all` loads every harness offscreen).
// =============================================================================
ShellRoot {
    id: root
    settings.watchFiles: false
    Component.onCompleted: {
        if (Quickshell.env("AKA_MODE") === "win")
            Qt.createQmlObject(root.src, root, Qt.resolvedUrl("aerial_keys_app.qml"));
    }
    readonly property string src: `
        import QtQuick
        import Quickshell
        FloatingWindow {
            id: win
            title: "aka-app"
            implicitWidth: 500
            implicitHeight: 200
            color: "#ffffff"
            visible: true
            TextInput {
                id: ti
                anchors.fill: parent
                focus: true
                font.pixelSize: 24
                onTextChanged: console.log("AKA text " + ti.text)
                onActiveFocusChanged: console.log("AKA focus " + ti.activeFocus)
                Component.onCompleted: { ti.forceActiveFocus(); console.log("AKA ready") }
            }
        }
    `
}
