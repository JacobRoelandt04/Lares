import QtQuick

// =============================================================================
// PanelStyle.qml -- the numbers every aerial panel shares (CLAUDE.md "Design language": popup padding 12 on every side, card padding
// 12, one gap between things, container radius 14, title 16 bold, body 12, figures 11). One object handed down; a panel never carries a
// number of its own. The dialog width is the shell's secondary width (silicon's SecondaryStyle.dialogWidth is 300; a network's pages
// carry a table of facts, so a panel is 360).
// =============================================================================
QtObject {
    property string fontFamily: "Inter"

    property real padding: 12
    property real cardPadding: 12
    property real gap: 12
    property real rowGap: 8
    property real radius: 14

    property int titleSize: 16
    property int bodySize: 12
    property int figureSize: 11

    property real panelWidth: 360
    property real maxHeight: 560
    property real rowHeight: 28
    property real fieldHeight: 30

    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    property real cardShadowFalloff: 1

    property int fadeMs: 160
}
