pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// The pomodoro view: how a phase hands over to the next (top-right), the
// focus duration in the lower-left corner and the two breaks stacked in the
// lower-right (set by the wheel, a right-click for the default). Start /
// Pause and Skip and Reset under it (two clicks each) are the card's shared
// actions.
TimerView {
    id: view

    // Touchpad travel per minute on a duration, and the pause after a minute.
    property real fieldPixelUnits: 1000
    property int fieldCooldownMs: 200
    // The three durations share one width, the widest of them: the stacked
    // pair then has exactly the focus field's footprint.
    readonly property real fieldW: Math.max(focusF.implicitWidth, shortF.implicitWidth, longF.implicitWidth)
    readonly property var modes: [
        { id: "wait", label: "Wait for me" },
        { id: "auto", label: "Auto" },
        { id: "breaksAuto", label: "Auto breaks" }
    ]

    function fieldAt(px, py) {
        const fields = [focusF, shortF, longF];
        for (const f of fields) {
            const q = f.mapFromItem(view, px, py);
            if (q.x >= 0 && q.y >= 0 && q.x < f.width && q.y < f.height)
                return f;
        }
        return null;
    }

    Row {
        spacing: 8
        x: Math.round(view.side - view.padding - width)
        y: Math.round(view.padding)
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "next phase"
            color: Theme.textFaint
            font.family: view.fontFamily
            font.pixelSize: 11
        }
        TimerButton {
            text: {
                const m = view.modes.find(x => x.id === (view.timers ? view.timers.advanceMode : "wait"));
                return m ? m.label : "Wait for me";
            }
            onClicked: {
                const i = view.modes.findIndex(x => x.id === view.timers.advanceMode);
                view.timers.advanceMode = view.modes[(i + 1) % view.modes.length].id;
            }
        }
    }

    // The durations: focus alone in the lower-left corner, the two breaks
    // stacked in the lower-right in the same footprint -- the two corners
    // balance each other. A right-click puts one back to its default.
    MinuteField {
        id: focusF
        width: view.fieldW
        x: Math.round(view.padding)
        y: Math.round(view.side - view.padding - height)
        label: "focus"
        fontFamily: view.fontFamily
        pixelUnits: view.fieldPixelUnits
        cooldownMs: view.fieldCooldownMs
        valueMs: view.timers ? view.timers.focusMs : 0
        defaultMs: view.timers ? view.timers.defaultFocusMs : 0
        onChanged: ms => view.timers.focusMs = ms
    }
    Column {
        spacing: 6
        x: Math.round(view.side - view.padding - width)
        y: Math.round(view.side - view.padding - height)
        MinuteField {
            id: shortF
            width: view.fieldW
            compact: true
            label: "break"
            fontFamily: view.fontFamily
            pixelUnits: view.fieldPixelUnits
        cooldownMs: view.fieldCooldownMs
            valueMs: view.timers ? view.timers.shortMs : 0
            defaultMs: view.timers ? view.timers.defaultShortMs : 0
            onChanged: ms => view.timers.shortMs = ms
        }
        MinuteField {
            id: longF
            width: view.fieldW
            compact: true
            label: "long"
            fontFamily: view.fontFamily
            pixelUnits: view.fieldPixelUnits
        cooldownMs: view.fieldCooldownMs
            valueMs: view.timers ? view.timers.longMs : 0
            defaultMs: view.timers ? view.timers.defaultLongMs : 0
            onChanged: ms => view.timers.longMs = ms
        }
    }
}
