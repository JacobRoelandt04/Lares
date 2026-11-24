pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/theme"

// A duration in whole minutes, carved into the card, set by the wheel: a
// notch is a minute, with Ctrl five; a touchpad steps once per `pixelUnits`
// of travel and then rests `cooldownMs` -- the shell's detent (WheelStepper),
// the view switcher's numbers: 500 units and no rest runs away. A
// right-click puts back `defaultMs`. The host's wheel reader calls wheel()
// and, when the fingers lift, endWheel() -- this item reads no wheel itself
// (one reader per event).
//
// `compact`: label and value on one line, half the height -- two stacked
// take the footprint of one full field. Wide enough for the label and the
// widest value (three digits: two hours) -- side by side when compact, one
// over the other when not; a host that lines fields up gives them all the
// widest (the compact "long" field would run its label into its value at 64).
Item {
    id: field

    property string label: ""
    property real valueMs: 60000
    property real defaultMs: 60000
    property real minMs: 60000
    property real maxMs: 120 * 60000
    property string fontFamily: "Audiowide"
    property real pixelUnits: 1000
    property int cooldownMs: 200
    property bool compact: false
    signal changed(real ms)

    implicitWidth: Math.ceil(field.compact
        ? 8 + labelText.implicitWidth + 6 + 3 * valueCells.digitW + 8
        : Math.max(64, labelText.implicitWidth + 16, 3 * valueCells.digitW + 16))
    implicitHeight: field.compact ? 23 : 52

    WheelStepper {
        id: stepper
        notchThreshold: 120
        pixelThreshold: field.pixelUnits
        stepCooldownMs: field.cooldownMs
    }
    function wheel(units, fromPixels, modifiers) {
        const steps = stepper.feed(units, fromPixels);
        if (steps === 0)
            return;
        const size = (modifiers & Qt.ControlModifier) ? 5 : 1;
        const v = Math.max(field.minMs, Math.min(field.maxMs, field.valueMs + steps * size * 60000));
        if (v !== field.valueMs)
            field.changed(v);
    }
    function endWheel() {
        stepper.end();
    }

    ShadowBox {
        anchors.fill: parent
        baseWidth: width
        baseHeight: height
        baseRadius: field.compact ? 8 : 10
        surfaceColor: Theme.listBox
        backgroundColor: Theme.headerBox
        bevelColor: Theme.headerBoxBevel
        shadowColor: Theme.headerBoxShadow
        bevelWidth: 1
        shadowWidth: 3
    }
    Text {
        id: labelText
        text: field.label
        color: Theme.textFaint
        font.family: field.fontFamily
        font.pixelSize: 10
        x: field.compact ? 8 : Math.round((field.width - implicitWidth) / 2)
        y: field.compact ? Math.round((field.height - implicitHeight) / 2) : 7
    }
    DigitCells {
        id: valueCells
        text: String(Math.round(field.valueMs / 60000))
        fontFamily: field.fontFamily
        pixelSize: field.compact ? 14 : 18
        x: field.compact ? Math.round(field.width - 8 - implicitWidth) : Math.round((field.width - implicitWidth) / 2)
        y: field.compact ? Math.round((field.height - implicitHeight) / 2) : 22
    }
    HoverHandler {
        cursorShape: Qt.SizeVerCursor
    }
    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.RightButton
        cursorShape: undefined   // the left button passes through: the cursor is what lies under it (a MouseArea owns an Arrow)
        onClicked: if (field.valueMs !== field.defaultMs)
            field.changed(field.defaultMs)
    }
}
