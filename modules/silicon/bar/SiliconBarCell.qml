pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// SiliconBarCell.qml -- the charge, as the shell draws every container: a groove carved into the
// bar's surface with the charge lying in it, a shade shallower, filling left to right. It is the
// face's thin track; the face is laid out in the SCREEN frame and counter-rotated against its
// bar, so the track runs left to right on every edge.
//
//   - The charge's length is a whole number of pixels; one eased fraction (`fillF`) is the only
//     clock of the length.
//   - `fullPercent` is the charge at which the track is full: 100, or the charge limit while it is on
//     (no cap mark: the track is re-scaled to the limit, so 50 % at an 80 % limit fills
//     62.5 % of it). Turning the limit on or off moves `fullPercent`, and the one fraction below eases
//     the length to its new scale.
//   - The event pulse is one fraction, `pulseProgress` (0 just fired .. 1 spent): the groove takes
//     the event's colour for a moment (a tint mixed in, never an additive glow: it must read on a
//     light ground too). The ring that leaves the pill is the face's, not the track's.
//   - The thin-charge rule: a charge narrower than twice its corner radius
//     is shortened across by the difference so its corners stay inside the groove's curve.
//
// Every colour is a Theme token or a mix of two; the cell sits on `groundColor` (transparent by
// default: the pill's own fill, which sinks under the pointer -- a carved box on a ground that changes
// eases to alpha, CLAUDE.md). The face hands it `grooveColor`, a step deeper than that fill.
// =============================================================================
Item {
    id: cell

    // ---- geometry (screen frame, whole pixels) ----
    property int length: 44                 // along the charge
    property int thickness: 22              // across it
    property real radius: 7
    property int pad: 2                     // groove wall to charge
    property real bevelWidth: 1
    property real shadowWidth: 2
    property real fillBevelWidth: 0.5
    property real fillShadowWidth: 1
    property real fillRadiusOffset: -1

    // ---- the facts ----
    property real percent: 0                // 0..100
    property color fillColor: Theme.textPrimary
    property real fullPercent: 100          // the charge that fills the track: 100, or the limit while it is on
    property color groundColor: "transparent"
    property color grooveColor: Theme.listBox
    property color grooveBevel: Theme.bevel
    property color grooveShadow: Theme.shadowDeep

    // ---- the event pulse ----
    property real pulseProgress: 1
    property color pulseColor: Theme.batteryCharge
    property real pulseTint: 0.32

    // The cavity the charge lies in: along the charge, and across it.
    readonly property int _cav: Math.max(1, cell.length - 2 * cell.pad)
    readonly property int _cavT: cell.thickness - 2 * cell.pad

    implicitWidth: cell.length
    implicitHeight: cell.thickness

    // ---- the charge ----
    property real fillF: Math.max(0, Math.min(1, cell.percent / Math.max(1, cell.fullPercent)))
    Behavior on fillF {
        NumberAnimation {
            duration: 420
            easing.type: Easing.OutCubic
        }
    }
    readonly property int fillPx: Math.round(cell.fillF * cell._cav)
    readonly property real _fillRadius: Math.max(0, cell.radius - cell.pad + cell.fillRadiusOffset)
    readonly property int _delta: cell.fillPx >= 2 * cell._fillRadius ? 0
                                  : Math.ceil(Math.max(0, cell._fillRadius - cell.fillPx / 2))

    // The pulse, as the tint reads it.
    readonly property real _flash: Math.max(0, 1 - cell.pulseProgress * 2.4)

    ShadowBox {
        id: groove
        anchors.fill: parent
        baseRadius: cell.radius
        bevelWidth: cell.bevelWidth
        shadowWidth: cell.shadowWidth
        surfaceColor: cell.groundColor
        backgroundColor: Mix.c(cell.grooveColor, cell.pulseColor, cell.pulseTint * cell._flash)
        bevelColor: cell.grooveBevel
        shadowColor: cell.grooveShadow
    }

    ShadowBox {
        id: fill
        visible: cell.fillPx > 0
        x: cell.pad
        y: cell.pad + cell._delta
        width: cell.fillPx
        height: cell._cavT - 2 * cell._delta
        baseRadius: cell._fillRadius
        bevelWidth: cell.fillBevelWidth
        shadowWidth: cell.fillShadowWidth
        surfaceColor: "transparent"
        backgroundColor: cell.fillColor
        bevelColor: Qt.lighter(cell.fillColor, 1.15)
        shadowColor: Qt.darker(cell.fillColor, 1.35)
    }
}
