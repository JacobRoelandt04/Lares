import QtQuick

import "../common/float"

// =============================================================================
// PresetsStyle.qml -- every number of the presets popup: what mockups/presets.qml's panel reaches and its Save writes. The float's numbers (sway, tilt,
// deal) are the shared FloatStyle's (tuned on the theme popup); a value Save changes lands as a line of this file.
// =============================================================================
FloatStyle {
    // Layout: a grid of cards, `columns` across at most, the last card the "save the desktop now" one
    property real padding: 12
    property int columns: 2
    property real cardWidth: 280
    property real cardGap: 12
    // The columns `cells` cards take: never more than there are cards (no preset saved: the save card alone, one column) -- and the popup's
    // width with them, between the paddings (the drop-in's implicitWidth; a host that holds a swipe asks it unbuilt).
    function columnsFor(cells: int): int {
        return Math.max(1, Math.min(columns, cells));
    }
    function widthFor(cells: int): real {
        const n = columnsFor(cells);
        return Math.ceil(2 * padding + n * cardWidth + (n - 1) * cardGap);
    }
    property int maxRows: 3
    property real cardRadius: 14
    property real cardPadding: 12
    property real shadowWidth: 5
    property real faceScale: 2
    property real titleSize: 13
    property real metaSize: 11
    property real titleGap: 8
    property real footGap: 10
    property real buttonHeight: 26
    property real buttonGap: 8

    // The face: one mini screen per workspace, side by side, all at one scale
    property real faceHeight: 72
    property real screenGap: 6
    property real screenMinWidth: 46
    property real screenMaxWidth: 128
    property real screenRadius: 4
    property real labelSize: 9
    property real labelGap: 2
    property real tileRadius: 2.5
    property real tileGap: 1
    property real iconMax: 18
    property real iconMin: 8
    property real tabStrip: 3
    property real badgeWidth: 26

    // The Load confirm: how long "Close N windows?" waits for its second click, ms
    property int confirmMs: 4000
    // The refusal's wiggle, px
    property real shakePx: 4
}
