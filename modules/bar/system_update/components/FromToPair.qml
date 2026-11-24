pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

// =============================================================================
// FromToPair.qml
//
// Two related values joined by a thin connector line, where the second value
// is revealed by expanding. Generalised from the start/end time block in
// modules/clock/calendar/AppointmentRow.qml.
//
//   collapsed (expandFraction 0)   secondary hidden, tucked inline to the
//                                  right of primary
//   expanded  (expandFraction 1)   secondary faded in and swung to its
//                                  stacked position; the connector, drawn
//                                  between the two text centres, therefore
//                                  ROTATES from horizontal to vertical as it
//                                  goes
//
// The rotation is emergent, not scripted: the connector is always drawn
// between the live centres of the two labels, so animating the secondary's
// position from "inline right" to "stacked below" rotates the line for free
// and keeps the endpoints attached throughout.
//
// Everything is driven off the single `expandFraction` input rather than each
// property carrying its own Behavior. Per-property Behaviors chase each
// other's changing bindings and visibly lag (the "pill waits for everything
// else" problem in the calendar row); one shared fraction makes position,
// opacity and height lerp in lock-step. Animate `expandFraction` in the
// PARENT so the row's height animation and this stay on the same clock.
//
// Usage (package versions — new on top, current revealed below):
//
//   FromToPair {
//       primaryText: entry.newVer
//       secondaryText: entry.oldVer
//       expandFraction: row._expandFraction
//   }
// =============================================================================
Item {
    id: pair

    // ---- Content ----
    property string primaryText: ""
    property string secondaryText: ""

    // 0 → collapsed (primary only), 1 → expanded (both + connector).
    property real expandFraction: 0

    // "below" stacks the secondary under the primary (block grows downward —
    // the safe choice inside a list). "above" stacks it over the primary.
    property string secondaryPosition: "below"

    // ---- Styling ----
    property color primaryColor:   "#8A8A8C"
    property color secondaryColor: "#B8BBC2"
    property color connectorColor: "#B8BBC2"
    property string fontFamily: "Inter"
    property int  fontPixelSize: 11
    property real connectorWidth: 1.25
    // Gap between the two label BOXES when stacked (edge to edge), and the
    // horizontal gap when the secondary is tucked inline.
    //
    // Edge-to-edge, not centre-to-centre: the connector is trimmed by half a
    // label height at each end so it stops clear of the glyphs, so a
    // centre-to-centre gap smaller than the two half-heights combined leaves
    // the line with negative length and it silently disappears. Measuring
    // between the boxes makes the visible line length simply
    // `stackedGap - 2 * connectorPad`, which is predictable and always > 0.
    property real stackedGap: 14
    property real inlineGap: 8
    // Clearance between a label's box and the end of the connector.
    property real connectorPad: 2
    // Fraction of the expansion that must elapse before the revealed value
    // starts fading in.
    property real textRevealStart: 0.35

    readonly property bool _hasSecondary: secondaryText.length > 0

    readonly property bool _above: secondaryPosition === "above"

    // How far the stacked label sits from the other one's far edge.
    readonly property real _stackOffset: pair._above
        ? secondaryLabel.implicitHeight + pair.stackedGap
        : primaryLabel.implicitHeight + pair.stackedGap

    implicitWidth: Math.max(primaryLabel.implicitWidth,
                            _hasSecondary ? secondaryLabel.implicitWidth : 0)
    // Measured rather than derived, so the row above grows by exactly what
    // the reveal actually occupies at any point in the animation.
    implicitHeight: Math.max(primaryLabel.y + primaryLabel.implicitHeight,
                             _hasSecondary
                                ? secondaryLabel.y + secondaryLabel.implicitHeight
                                : 0)

    Text {
        id: primaryLabel
        text: pair.primaryText
        color: pair.primaryColor
        font.pixelSize: pair.fontPixelSize
        font.family: pair.fontFamily
        x: 0
        // Stacking above pushes the primary down to make room; stacking below
        // leaves it anchored and the block grows downward.
        y: pair._above ? pair.expandFraction * pair._stackOffset : 0
    }

    Text {
        id: secondaryLabel
        visible: pair._hasSecondary
        text: pair.secondaryText
        color: pair.secondaryColor
        font.pixelSize: pair.fontPixelSize
        font.family: pair.fontFamily
        // Held back until the row has visibly started making room. Fading the
        // text in from the very first frame makes it appear before there is
        // space for it, which reads as the text arriving early.
        opacity: Math.max(0, Math.min(1,
            (pair.expandFraction - pair.textRevealStart) / (1 - pair.textRevealStart)))
        // Lerp from "tucked inline, level with the primary" to the stacked
        // anchor. This single interpolation is what rotates the connector.
        x: (1 - pair.expandFraction)
           * (primaryLabel.implicitWidth + pair.inlineGap)
        y: pair._above ? 0 : pair.expandFraction * pair._stackOffset
    }

    // Connector between the two label centres, trimmed at each end so it
    // stops clear of the glyphs. Padding is projected onto the line's own
    // direction, so it stays correct at every angle during the rotation.
    // BUILT ONLY ONCE THE ROW HAS STARTED TO OPEN.
    //
    // A Shape with the curve renderer is real geometry on the GPU, and this
    // one is drawn at opacity 0 for the entire life of a collapsed row -- the
    // opacity ramp below does not leave zero until `expandFraction` passes
    // `textRevealStart`. In a list of 69 rows that would be 69 curve-renderer
    // Shapes maintained to draw nothing, re-deriving all eleven of their
    // geometry bindings on every view switch.
    //
    // Gated on `expandFraction > 0` rather than on the opacity ramp: it is
    // then created on the first frame of the open, still well before the
    // ramp lifts it off zero, so it is never seen arriving. Only one row is
    // ever mid-open, so this is one Shape at a time instead of 69.
    Loader {
        anchors.fill: parent
        active: pair._hasSecondary && pair.expandFraction > 0
        sourceComponent: shapeComponent
    }
    Component {
        id: shapeComponent
    Shape {
        id: connector
        anchors.fill: parent
        antialiasing: true
        preferredRendererType: Shape.CurveRenderer
        // Held back until the row has visibly started making room. Fading the
        // text in from the very first frame makes it appear before there is
        // space for it, which reads as the text arriving early.
        opacity: Math.max(0, Math.min(1,
            (pair.expandFraction - pair.textRevealStart) / (1 - pair.textRevealStart)))

        readonly property real sCX: primaryLabel.x + primaryLabel.implicitWidth / 2
        readonly property real sCY: primaryLabel.y + primaryLabel.implicitHeight / 2
        readonly property real eCX: secondaryLabel.x + secondaryLabel.implicitWidth / 2
        readonly property real eCY: secondaryLabel.y + secondaryLabel.implicitHeight / 2
        readonly property real _dx: eCX - sCX
        readonly property real _dy: eCY - sCY
        readonly property real _len: Math.sqrt(_dx * _dx + _dy * _dy)
        readonly property real _ux: _len > 0.01 ? _dx / _len : 0
        readonly property real _uy: _len > 0.01 ? _dy / _len : 0
        readonly property real sPad:
              Math.abs(_ux) * (primaryLabel.implicitWidth  / 2)
            + Math.abs(_uy) * (primaryLabel.implicitHeight / 2) + pair.connectorPad
        readonly property real ePad:
              Math.abs(_ux) * (secondaryLabel.implicitWidth  / 2)
            + Math.abs(_uy) * (secondaryLabel.implicitHeight / 2) + pair.connectorPad
        readonly property real p1x: sCX + _ux * sPad
        readonly property real p1y: sCY + _uy * sPad
        readonly property real p2x: eCX - _ux * ePad
        readonly property real p2y: eCY - _uy * ePad
        // Below this the trimmed line would be inverted (the labels overlap),
        // so hide it rather than draw a backwards stub.
        readonly property bool _drawable: _len > (sPad + ePad + 1)

        ShapePath {
            strokeColor: pair.connectorColor
            strokeWidth: connector._drawable ? pair.connectorWidth : 0
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            startX: connector.p1x
            startY: connector.p1y
            PathLine { x: connector.p2x; y: connector.p2y }
        }
    }
    }
}
