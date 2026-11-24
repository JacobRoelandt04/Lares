pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// TimerIconButton.qml -- an icon action on the timers card: a raised disc
// with a Material Design glyph (the audio player's transport buttons, the
// shell's form for an icon control).
//
// `confirm`: an action that throws something away (reset, skip) takes TWO
// clicks. The first arms it -- the glyph turns the warning colour and the
// plateau warms towards it, no words -- and a second within `confirmMs`
// does it; left alone it disarms itself. `activated` is the only signal a
// host listens to.
// =============================================================================
TimerButton {
    id: btn

    property string glyph: ""
    property bool confirm: false
    property int confirmMs: 2500
    // The glyph's ink at rest, and armed.
    property color glyphColor: Theme.textMuted
    property color armedColor: Theme.warn

    signal activated()

    readonly property bool armed: btn._armed
    property bool _armed: false
    property real _armedF: btn._armed ? 1 : 0
    Behavior on _armedF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    width: 30
    height: 30
    implicitHeight: 30
    minWidth: 30
    horizontalPadding: 0
    radius: 15
    text: btn.glyph
    fontFamily: "Symbols Nerd Font"
    fontPixelSize: 16
    bold: false
    textColor: Mix.c(btn.glyphColor, btn.armedColor, btn._armedF)
    plateauColor: Mix.c(Theme.buttonPlateau, Mix.c(Theme.buttonPlateau, btn.armedColor, 0.18), btn._armedF)

    onClicked: {
        if (!btn.confirm) {
            btn.activated();
            return;
        }
        if (btn._armed) {
            btn._armed = false;
            disarm.stop();
            btn.activated();
        } else {
            btn._armed = true;
            disarm.restart();
        }
    }
    // A disabled button forgets that it was armed, and so does one whose
    // confirmation changed (the card's shared icons change action with the
    // view: an arming on the pomodoro is not one on the stopwatch).
    function disarmNow() {
        btn._armed = false;
        disarm.stop();
    }
    onEnabledChanged: if (!btn.enabled)
        btn.disarmNow()
    onConfirmChanged: btn.disarmNow()

    Timer {
        id: disarm
        interval: btn.confirmMs
        onTriggered: btn._armed = false
    }
}
