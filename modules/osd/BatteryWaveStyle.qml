pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// BatteryWaveStyle.qml
//
// The numbers the fill's soft edges move by, in one object. The fill is split
// in two around the charge-limit bar and each half carries its own
// BatteryFillWavefield; they are one liquid, so they share one set of values,
// and the mockup's Wave tab writes here and moves both.
// =============================================================================
QtObject {
    id: style

    // Off: the halves keep their straight edges and nothing is simulated.
    property bool enabled: true

    // How hard the bar's motion drives the edge next to it: target
    // displacement in px per px/s of the gap opening (positive, a bulge) or
    // closing (negative, a dip).
    property real impulseGain: 0.08
    // Cap on that target, px.
    property real maxAmplitudePx: 16

    // Propagation speed, in fill-half widths per second.
    property real waveSpeedNorm: 2.5
    // Exponential decay of the wave per second.
    property real dampingPerSec: 6.0
    // How fast the driven edge chases its target, per second.
    property real driveLerpPerSec: 25.0
    // Grid points per fill half. Cost is linear in it.
    property int gridN: 48

    // How far a bulge may rise past the fill's edge, px. It rises into the
    // band between fill and hull, so it stays under that band's width (the
    // body's fill padding) or it paints over the hull's inset shadow.
    property real maxOutwardPx: 6
    // How deep a dip may press into the fill, px.
    property real maxInwardPx: 24
}
