// Stage 0 proof: a bare session lock inside tools/dev/lock_env.sh. Never run it
// outside that environment -- on the real desktop it LOCKS THE USER'S SESSION.
// Keys: "u" unlocks (after 300 ms the process quits), anything else is logged.
import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    settings.watchFiles: false

    WlSessionLock {
        id: lock
        locked: true
        onSecureChanged: console.log("PROBE secure", lock.secure)
        onLockedChanged: console.log("PROBE locked", lock.locked)

        WlSessionLockSurface {
            id: surf
            color: "#EAEDF5"
            Component.onCompleted: console.log("PROBE surface", surf.screen ? surf.screen.name : "?")
            Rectangle {
                x: (parent.width - width) / 2; y: (parent.height - height) / 2
                width: 400; height: 200; radius: 14; color: "#4480F4"
            }
            HoverHandler { onHoveredChanged: if (hovered) console.log("PROBE pointer hover") }
            TapHandler { onTapped: console.log("PROBE pointer tap") }
            Item {
                anchors.fill: parent
                focus: true
                Keys.onPressed: (e) => {
                    console.log("PROBE key", e.key, JSON.stringify(e.text))
                    if (e.text === "u") {
                        lock.locked = false
                        console.log("PROBE unlocked")
                        quitTimer.start()
                    }
                }
            }
        }
    }
    Timer { id: quitTimer; interval: 300; onTriggered: Qt.quit() }
}
