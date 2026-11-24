import QtQuick

// =============================================================================
// SeamFade.qml
//
// A fold seam's fade: a band dissolving content into the ground at a MOVING
// clip edge, the way edge_fade does for particles, so a fold never cuts a
// line of text in half. It sits on one `edge` of whatever clips (bottom by
// default), and its opacity is min(1, 6e(1-e)) of the fold's own extent -- 0
// at both resting extents, saturated by extent ~0.2 -- so the band exists
// ONLY while the fold is moving. At rest the edge is exact. The band is
// unmistakable rather than subliminal (a 20 px linear band can only be found
// frame by frame): 42 px with a mid-stop that pulls the ramp forward -- three
// lines of text visibly dissolving, not one line slightly greyed.
//
// The gradient's transparent end is alpha-matched to the ground, not
// "transparent": a straight RGBA ramp toward black-transparent tints the band
// grey. One clock: `extent` is the fold's own fraction, never a second one.
//
// Every fold in the LLM module (the turn's body, the sent question, the
// thinking drawer, a tool block) rides it, and so do the calendar's sliding week rows (left and right) and its
// visibility panel's moving edge (both sides of it).
// =============================================================================
Rectangle {
    id: seam
    property real extent: 1
    property color ground: "transparent"
    property real fadeHeight: 42
    // Which edge of the parent the band sits on; the ground is at that edge.
    // Fixed per instance -- positioned by x/y, so it is never an anchor pair.
    property int edge: Qt.BottomEdge

    readonly property bool _across: seam.edge === Qt.LeftEdge || seam.edge === Qt.RightEdge
    // Where the ground is: at the gradient's START for a top or left edge,
    // at its END otherwise. A Gradient ignores stops whose positions do not
    // increase, so the direction is carried by which stop gets which colour.
    readonly property bool _groundFirst: seam.edge === Qt.TopEdge || seam.edge === Qt.LeftEdge
    readonly property color _clear: Qt.rgba(seam.ground.r, seam.ground.g, seam.ground.b, 0)
    readonly property color _mid: Qt.rgba(seam.ground.r, seam.ground.g, seam.ground.b, 0.55)

    x: seam.edge === Qt.RightEdge ? seam.parent.width - seam.width : 0
    y: seam.edge === Qt.BottomEdge ? seam.parent.height - seam.height : 0
    width: seam._across ? seam.fadeHeight : seam.parent.width
    height: seam._across ? seam.parent.height : seam.fadeHeight
    opacity: Math.min(1, 6 * seam.extent * (1 - seam.extent))
    visible: opacity > 0
    gradient: Gradient {
        orientation: seam._across ? Gradient.Horizontal : Gradient.Vertical
        GradientStop {
            position: 0
            color: seam._groundFirst ? seam.ground : seam._clear
        }
        GradientStop {
            position: seam._groundFirst ? 0.6 : 0.4
            color: seam._mid
        }
        GradientStop {
            position: 1
            color: seam._groundFirst ? seam._clear : seam.ground
        }
    }
}
