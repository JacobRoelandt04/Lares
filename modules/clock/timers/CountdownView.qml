pragma ComponentBehavior: Bound

import QtQuick

import "format.js" as Fmt
import ".."

// The timer view: add a preset (+, top-right) and the presets in the
// lower-left corner (a right-click removes one). Start / Pause / Stop and
// Reset under it are the card's shared actions; the time itself is wound on
// the ring.
TimerView {
    id: view

    readonly property var c: view.timers ? view.timers.countdown : null
    readonly property string state_: view.c ? view.c.state : "idle"
    readonly property bool settable: view.state_ === "idle" || view.state_ === "done"

    PlusButton {
        id: addPreset
        x: Math.round(view.side - view.padding - width - 4)
        y: Math.round(view.padding + 4)
        enabled: !!view.timers && view.timers.canAddPreset(view.c ? view.c.setMs : 0)
        onClicked: view.timers.addPreset(view.c.setMs)
    }

    // The presets: rows of three from the corner up.
    Flow {
        id: presets
        x: Math.round(view.padding)
        y: Math.round(view.side - view.padding - height)
        width: 3 * 64 + 2 * 6
        spacing: 6
        Repeater {
            model: view.timers ? view.timers.presets : []
            delegate: TimerButton {
                id: chip
                required property real modelData
                text: Fmt.preset(chip.modelData)
                minWidth: 64
                horizontalPadding: 8
                enabled: view.settable
                onClicked: {
                    if (view.state_ === "done")
                        view.timers.dismiss("countdown");
                    view.timers.setCountdown(chip.modelData);
                }
                // Right-click removes it. Only the right button: the left one
                // falls through to the button's own area.
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.RightButton
                    cursorShape: undefined   // the left button passes through: the cursor is what lies under it (a MouseArea owns an Arrow)
                    onClicked: view.timers.removePreset(chip.modelData)
                }
            }
        }
    }
}
