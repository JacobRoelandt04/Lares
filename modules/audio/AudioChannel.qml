pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "data/AudioModel.js" as Model

// =============================================================================
// AudioChannel.qml -- one slider line: a channel's label (none when the channels are locked), the groove, and pavucontrol's figure, percent and dB, in slots that
// never jitter. The slider follows `value` except while the hand is on it, and the hand's position is what `held` reports: a row that vanishes under
// a held slider is the service's to say. `armed`: the wheel is this slider's now (the pointer came to rest on it, AudioPopup): the percent takes the accent, the one thing
// that says so.
// =============================================================================
Item {
    id: line

    property int channel: -1
    property string label: ""
    property real value: 0
    property bool muted: false
    property real mutedF: 0                      // the row's own fade
    property bool boost: false
    property bool decibels: true
    property bool armed: false
    property color ground: Theme.listBox         // what it is carved into: the row's
    property AudioStyle style: AudioStyle {}
    property string fontFamily: "Inter"
    property real renderScale: 1
    signal moved(real v)

    readonly property bool held: slider.held
    property real _armedF: line.armed ? 1 : 0
    Behavior on _armedF {
        NumberAnimation {
            duration: 120
            easing.type: Easing.OutCubic
        }
    }
    // The slider's own room is for a ball dragged hard off the line; a line of text beside it does not need all of that, so it reaches into the row's padding.
    readonly property real _bleed: 6
    implicitHeight: Math.round(slider.neededCross) - 2 * line._bleed

    Text {
        id: labelText
        visible: line.label !== ""
        width: visible ? line.style.channelLabelWidth : 0
        height: parent.height
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
        text: line.label
        font.family: line.fontFamily
        font.pixelSize: line.style.subtitleSize
        color: Theme.textMuted
    }

    GrooveSlider {
        id: slider
        objectName: "slider"
        x: labelText.width
        y: -line._bleed
        width: line.width - labelText.width - line.style.figureWidth - 4
        height: Math.round(slider.neededCross)
        orientation: "horizontal"
        sizeScale: line.style.sliderScale
        ballSize: line.style.sliderBall
        edgePadding: line.style.sliderEdge
        muteEnabled: false
        sparksEnabled: false
        allowBoost: line.boost
        boostMaxValue: 1.53
        renderScale: line.renderScale

        surfaceColor: line.ground
        grooveColor: Theme.headerBox
        grooveBevelColor: Theme.bevel
        grooveShadowColor: Theme.shadowDeep
        ballColor: line.muted ? Theme.textFaint : Theme.accent
        ballShadowColor: line.muted ? Theme.textFaint : Theme.accent

        // The hand: from the first value it sets until a moment after the last. Quickshell writes the value itself on a drag, so `value` is a
        // Binding that lets go while held, never a plain binding (CLAUDE.md, "A plain binding onto a property the component assigns ITSELF").
        property bool held: false
        Binding {
            target: slider
            property: "value"
            value: line.value
            when: !slider.held
        }
        onUserChangedValue: v => {
            slider.held = true;
            hold.restart();
            line.moved(v);
        }
        Timer {
            id: hold
            interval: 350
            onTriggered: slider.held = false
        }
    }

    Item {
        id: figures
        x: line.width - line.style.figureWidth
        width: line.style.figureWidth
        height: parent.height
        Text {
            width: 40
            height: parent.height
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            text: Model.percentText(line.value)
            font.family: line.fontFamily
            font.pixelSize: line.style.figureSize
            color: Mix.c(Mix.c(Theme.textPrimary, Theme.textFaint, line.mutedF), Theme.accent, line._armedF)
        }
        Text {
            visible: line.decibels
            x: 40
            width: parent.width - 40
            height: parent.height
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            text: Model.dbText(line.value)
            font.family: line.fontFamily
            font.pixelSize: line.style.figureSize
            color: Theme.textFaint
        }
    }
}
