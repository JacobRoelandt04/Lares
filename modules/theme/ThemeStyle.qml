import QtQuick

import "../common/float"

// =============================================================================
// ThemeStyle.qml -- every number of the theme popup: what mockups/theme.qml's panel reaches and its Save writes. The float's numbers (the sway, the
// tilt, the deal) are the shared FloatStyle's, whose defaults were tuned here: a value Save changes lands as a line of this file.
// =============================================================================
FloatStyle {
    // Layout
    property real padding: 12
    property real cardWidth: 236
    property real cardHeight: 133
    property real cardRadius: 14
    property real strandGap: 96
    property real rowGap: 12
    property int maxRows: 4
    property real labelSize: 12
    property real labelRise: 34
    property real shadowWidth: 6
    property real faceScale: 2

    // The strands: amplitude px, wave number rad/px, flow rad/s, thickness px, alpha
    property real strand1Amp: 12
    property real strand1Wave: 0.08
    property real strand1Flow: 0.8
    property real strand1Width: 8
    property real strand1Alpha: 0.45
    property real strand2Amp: 8
    property real strand2Wave: 0.12
    property real strand2Flow: 1.2
    property real strand2Width: 5
    property real strand2Alpha: 0.7
    property real strand3Amp: 4
    property real strand3Wave: 0.15
    property real strand3Flow: 1.5
    property real strand3Width: 3
    property real strand3Alpha: 0.95
    property real strandEndWidth: 0.2
    property real strandTuck: 8
}
