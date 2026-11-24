pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "Mix.js" as Mix

// =============================================================================
// RaisedButton.qml
//
// A button that stands proud of the surface: a raised ShadowBox (drop
// shadow outside, highlight inside) with a label. The counterpart of the
// carved text field it sits beside in the prompt banner, so a field and its
// buttons read as one surface -- groove and plateau.
//
//   pressed   the plateau sinks: shadow and highlight shrink toward nothing
//             and the label drops a pixel, then springs back
//   hover     the plateau lightens a touch
//   accent    the default answer: accent plateau, light text
//   disabled  faint text, no press
//
// THE LABEL NEVER SPILLS OUT OF ITS PLATE. A host may animate the button's
// width through less than its words need (the notification manager's Clear
// all comes and goes on its width, ManagerHeader): centred and unclipped, the
// label would lie over the plate's ends and over whatever stands beside it --
// 10 px of "Clear all" on the do-not-disturb toggle, in 9 of 16 frames of
// every leave. So the label's presence fades out over the last
// `_labelFadePx` of room: whole while the plate is that much wider than the
// words, gone by the time they would reach its ends. Every host's plate is
// wider than that at rest (its padding, or a glyph in a round button), so
// the fade never shows there.
// =============================================================================
Item {
    id: btn

    property string text: ""
    property bool accent: false
    property string fontFamily: "Inter"
    property real fontPixelSize: 12
    property bool bold: true
    property real horizontalPadding: 14
    property real minWidth: 64

    // ---- Palette (eva-light literals; the themed ones follow Theme) ----
    // The theme's button tokens (the same values in light mode): as eva-light literals, a host that set none drew a light plateau
    // with a white bevel in dark mode (the terminal's input row).
    property color surfaceColor: Theme.headerBox       // what the button stands on
    property color plateauColor: Theme.buttonPlateau
    property color plateauHoverColor: Theme.buttonPlateauHover
    property color bevelColor: Theme.buttonBevel
    property color shadowColor: Theme.buttonShadow
    // Text. Both follow the theme: as eva-light literals no call site passes,
    // the ENABLED label would be dark-on-dark on the dark theme and the
    // DISABLED one light-on-dark, so the button that can be pressed would read
    // as the faint one. A host may still override.
    property color textColor: Theme.textPrimary
    property color faintTextColor: Theme.textFaint
    // The accent's three shades follow the theme too: as eva-light literals a host that set only `accentColor` (the player's
    // health banner) hovered to light mode's blue in dark mode, with a light bevel on top.
    property color accentColor: Theme.accent
    property color accentHoverColor: Theme.accentHover
    property color accentBevelColor: Theme.accentBevel
    property color accentTextColor: Theme.textOnAccent

    // ---- Relief ----
    // Separately tuned: a highlight is a thin line, a shadow spreads.
    property real bevelWidth: 1.5
    property real shadowWidth: 5
    property real radius: 8
    // The drop shadow blends to transparent instead of to surfaceColor --
    // identical at rest on that surface, but whatever slides beneath the
    // button shows through the falloff. See ShadowBox.shadowToAlpha.
    property bool shadowToAlpha: false
    property real shadowEdgeAlpha: 0.9
    property int  pressMs: 90
    property int  hoverMs: 120

    signal clicked()

    implicitWidth: Math.max(btn.minWidth, label.implicitWidth + btn.horizontalPadding * 2)
    implicitHeight: 30

    // The label's room: 4 px each side of the words at the least, then it
    // fades (above). A plain number, not the padding: a round glyph button
    // with no padding (the player's transport) has only its own room.
    readonly property real _labelFadePx: 8
    readonly property real _labelFit: btn.text.length === 0 ? 1
        : Math.max(0, Math.min(1, (btn.width - label.implicitWidth) / btn._labelFadePx))

    readonly property bool _hovered: area.containsMouse && btn.enabled
    // 0 at rest, 1 fully pressed: the relief scales by (1 - _press).
    property real _press: area.pressed && btn.enabled ? 1 : 0
    Behavior on _press { NumberAnimation { duration: btn.pressMs; easing.type: Easing.OutCubic } }

    // HOVER IS A FRACTION, NOT A COLOUR ANIMATION.
    //
    // A `Behavior on backgroundColor` on the plateau would also catch the
    // theme: on a light/dark switch every button would chase the crossfade
    // 120ms behind it, so the buttons would arrive visibly after the card
    // they sit on. The theme already animates its colours on one clock;
    // a second clock downstream of it can only lag. Easing the hover FRACTION
    // instead leaves any colour change from above instant, and hover still
    // fades. The mix itself is Mix.js, shared with everything else that
    // crossfades a colour.
    property real _hoverF: btn._hovered ? 1 : 0
    Behavior on _hoverF { NumberAnimation { duration: btn.hoverMs; easing.type: Easing.OutCubic } }

    ShadowBox {
        id: box
        anchors.fill: parent
        raised: true
        shadowToAlpha: btn.shadowToAlpha
        baseRadius: btn.radius
        surfaceColor: btn.surfaceColor
        bevelColor: btn.accent && btn.enabled ? btn.accentBevelColor : btn.bevelColor
        shadowColor: btn.shadowColor
        // A disabled default answer drops its accent: a blue plateau with
        // nothing to press reads as a live button.
        backgroundColor: btn.accent && btn.enabled
            ? Mix.c(btn.accentColor, btn.accentHoverColor, btn._hoverF)
            : Mix.c(btn.plateauColor, btn.plateauHoverColor, btn._hoverF)
        bevelWidth: Math.max(0.5, btn.bevelWidth * (1 - btn._press * 0.8))
        shadowWidth: Math.max(0.5, btn.shadowWidth * (1 - btn._press * 0.85))
        shadowEdgeAlpha: btn.shadowEdgeAlpha * (1 - btn._press * 0.6)
    }

    Text {
        id: label
        anchors.centerIn: parent
        anchors.verticalCenterOffset: btn._press * 1
        text: btn.text
        opacity: btn._labelFit
        color: !btn.enabled ? btn.faintTextColor
             : btn.accent ? btn.accentTextColor : btn.textColor
        font.family: btn.fontFamily
        font.pixelSize: btn.fontPixelSize
        font.bold: btn.bold
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        enabled: btn.enabled
        cursorShape: btn.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: btn.clicked()
    }
}
