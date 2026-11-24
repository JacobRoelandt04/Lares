import QtQuick

// =============================================================================
// SecondaryStyle.qml -- the numbers the two panels share (CLAUDE.md "Design language": popup
// padding 12 on every side, card padding 12, one gap between things, container radius 14, title 16
// bold, body 12, figures 11). One object, handed down, so a panel never carries a number of its own.
// =============================================================================
QtObject {
    property string fontFamily: "Inter"

    // popup padding = card padding = the gap between cards and between blocks: one number
    property real padding: 12
    property real cardPadding: 12
    property real gap: 12
    property real radius: 14

    property int titleSize: 16
    property int bodySize: 12
    property int figureSize: 11

    // the three dialogs that are secondaries (the restart card, the keep prompt, the busy-dGPU question): one width,
    // so the box the engine grows out of the popup is the same size whichever of them it holds
    property real dialogWidth: 300

    // the carve of a card (the weather and network details' own numbers)
    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    property real cardShadowFalloff: 1

    // a short fade for presence and for a control that is locked
    property int fadeMs: 160
}
