import QtQuick
import Quickshell

import "modules/osd"
import "modules/osd/data/sources"

// tools/dev/qml/osd_lockkeys_probe.qml -- the Caps / Num Lock card from the REAL key (tools/dev/osd_lockkeys_probe.sh runs it inside
// tools/dev/lock_env.sh, a nested Hyprland with the shell's two bind lines; a virtual keyboard presses the laptop's keycodes).
//
// The real path but the owner: OsdShortcuts registers the global shortcuts (lares:osd-lockkeys) exactly as the shell does,
// its press goes to `lockkeys()` here, which is OsdService's (the LockKeysSource, live: it reads the nested Hyprland's
// `hyprctl -j devices`), and the source's request is the card the owner would put out. A focused field beside it says the key
// still reaches the application (the binds are non_consuming): Caps then `a` types "A".
//
// Beside them `OLKT press|release|card <ms>`: the instants the runner holds the card to.
// Prints `OLK ready` once the shortcuts are up and the field has the keyboard, `OLK shortcut <n>` per press heard, `OLK card
// caps=<b> num=<b> changed=<k>` per card, `OLK text <t>` when the field changes. The runner presses and judges.
Scope {
    id: root

    property int presses: 0

    // OsdService's lockkeys() and its source, nothing else of the service (no audio, no brightness, no notifier)
    QtObject {
        id: svc
        function lockkeys() {
            root.presses++;
            console.log("OLK shortcut " + root.presses);
            console.log("OLKT press " + Date.now());
            lockKeys.press();
            return true;
        }
        function lockkeysReleased() {
            console.log("OLKT release " + Date.now());
            lockKeys.release();
        }
    }
    LockKeysSource {
        id: lockKeys
        live: true
        onRequest: req => {
            console.log("OLK card caps=" + req.keys.caps + " num=" + req.keys.num + " changed=" + req.changed);
            console.log("OLKT card " + Date.now());
        }
    }
    OsdShortcuts {
        service: svc
    }

    Window {
        id: win
        visible: true
        width: 200
        height: 60
        color: "white"
        TextInput {
            id: field
            anchors.fill: parent
            focus: true
            font.pixelSize: 20
            onTextChanged: console.log("OLK text " + field.text)
        }
    }
    Timer {
        interval: 100
        repeat: true
        running: true
        property int n: 0
        onTriggered: {
            n++;
            if (field.activeFocus) {
                console.log("OLK ready");
                stop();
            } else if (n % 10 === 1) {
                win.requestActivate();
                field.forceActiveFocus();
            }
        }
    }
}
