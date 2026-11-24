import QtQuick
import QtQuick.Window

// tools/dev/qml/wheel_record.qml -- what THIS machine's pointer really sends a Qt window (tools/dev/wheel_record.sh runs it, for a
// person, on their own desktop): every wheel event as a MouseArea sees it, the same event's phase and device as a WheelHandler sees
// it, and the mouse's buttons with the motion made while one is held. One line of JSON per event on stderr (`WR {..}`); the steps
// on show only say what to do next.
Window {
    id: win
    visible: true
    width: 860
    height: 420
    title: "lares-wheel-record"
    color: "#EAEDF5"

    property int step: 0
    readonly property var steps: [
        "1 / 7   Scroll DOWN 3 notches, slowly, one at a time.   Then press Space.",
        "2 / 7   Scroll UP 3 notches, slowly.   Then press Space.",
        "3 / 7   Scroll down FAST (a normal quick scroll of a page).   Then press Space.",
        "4 / 7   Hold the BACK side button, move the mouse left, then right, let go.   Then press Space.",
        "5 / 7   The same with the FORWARD side button.   Then press Space.",
        "6 / 7   Hold the BACK side button and scroll 3 notches down.   Then press Space.",
        "7 / 7   Hold the FORWARD side button and scroll 3 notches down.   Then press Space to finish.",
        "Done. Thank you."
    ]
    property int seen: 0
    function log(o: var): void {
        o.step = win.step + 1;
        o.t = Date.now();
        console.log("WR " + JSON.stringify(o));
        win.seen++;
    }

    Item {
        anchors.fill: parent
        focus: true
        Keys.onPressed: ev => {
            win.log({ ev: "key", key: ev.key, text: ev.text });
            if (ev.key !== Qt.Key_Space)
                return;
            win.step++;
            win.seen = 0;
            if (win.step >= win.steps.length - 1)
                quit.start();
        }
        Timer {
            id: quit
            interval: 900
            onTriggered: Qt.quit()
        }

        Text {
            anchors.centerIn: parent
            width: parent.width - 60
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: win.steps[Math.min(win.step, win.steps.length - 1)] + "\n\n" + win.seen + " events in this step"
            color: "#5D5D5F"
            font.pixelSize: 22
        }
        WheelHandler {
            id: wh
            acceptedDevices: PointerDevice.AllDevices
            orientation: Qt.Vertical | Qt.Horizontal
            blocking: false
            target: null
            onWheel: ev => win.log({
                    ev: "handler", ax: ev.angleDelta.x, ay: ev.angleDelta.y, px: ev.pixelDelta.x, py: ev.pixelDelta.y, phase: ev.phase, inverted: ev.inverted,
                    dev: wh.point.device ? wh.point.device.name + " type=" + wh.point.device.type : "-"
                })
        }
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true
            onWheel: w => {
                win.log({ ev: "wheel", ax: w.angleDelta.x, ay: w.angleDelta.y, px: w.pixelDelta.x, py: w.pixelDelta.y, inverted: w.inverted, buttons: w.buttons, mods: w.modifiers });
                w.accepted = false;
            }
            onPressed: m => win.log({ ev: "press", button: m.button, buttons: m.buttons, x: m.x, y: m.y })
            onReleased: m => win.log({ ev: "release", button: m.button, buttons: m.buttons, x: m.x, y: m.y })
            onCanceled: win.log({ ev: "cancel" })
            onPositionChanged: m => {
                if (m.buttons !== 0)
                    win.log({ ev: "drag", buttons: m.buttons, x: Math.round(m.x), y: Math.round(m.y) });
            }
        }
    }
}
