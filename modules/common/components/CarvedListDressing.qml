pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// CarvedListDressing.qml
//
// What a carved list box needs on top of its Flickable: a fade at each end
// where the content runs past the box, and a re-cut of the box's rounded
// corners over the scrolling rows.
//
// It is one component for the system update's list, the queue and the
// library, and it holds two rules:
//
//   - BOTH ends fade. If only the bottom end faded, scrolling down would run
//     the rows into the box's top edge with a hard cut, which reads as a
//     clipping bug rather than as a list that continues.
//   - the fade is gated on "there is content past this edge", not on "the
//     content is taller than the box": the latter would stay on at the very
//     bottom of a scrolled list, fading out rows that are the last ones there are.
//
// Both ends key on the scroll POSITION, so each fade says exactly one
// thing: there is more list this way.
//
// The corner re-cut is the other half. A Flickable clips to a RECTANGLE, so a
// row scrolled to the top edge shows a square corner in the sliver where the
// box's own corner curves away. Two rectangles drawn over the content put the
// curve back: an outer ring in the surface colour that eats everything outside
// the radius, and an inner one-pixel ring in the bevel colour that redraws the
// box's own rim on top.
//
// THE BANDS COVER WHAT THE CLIP LETS THROUGH, TO THE DEVICE PIXEL: where a box
// edge passes exactly through a row of pixel centres, the Flickable's scissor
// (rounded on the CPU) and a band's quad (rasterised on the GPU) can round
// opposite ways and leave a row of the list showing past the band's opaque
// end. Each band carries a seal across its outer edge and reaches a hair past
// both sides (ScrollDressing, THE BAND COVERS WHAT THE CLIP LETS THROUGH).
// =============================================================================
Item {
    id: dressing

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    property Flickable flick: null
    // The box this dresses: its fill (which the fades fade to), the ground
    // outside it, its rim, and the radius the corners are re-cut to.
    property color boxColor: "#E5E8EF"
    property color surfaceColor: "#EAEDF5"
    property color bevelColor: "#EDF0F7"
    property real radius: 14
    property real bevelWidth: 1

    property real fadeHeight: 34
    property int fadeMs: 160
    // Off for a list drawn without a box: there is no edge to fade into.
    property bool boxed: true

    // How far past an edge counts as "there is more this way". One pixel is
    // enough to be a real overhang and small enough that a list scrolled to
    // its exact end reads as ended.
    property real edgeEpsilon: 1

    // ScrollDressing's seal: 1/64 of a device pixel, in this item's units.
    DeviceScale {
        id: deviceScale
    }
    readonly property real _seal: 1 / 64 / Math.max(0.25, deviceScale.value)

    readonly property bool moreAbove: dressing.flick ? dressing.flick.contentY > dressing.edgeEpsilon : false
    readonly property bool moreBelow: dressing.flick ? dressing.flick.contentY < dressing.flick.contentHeight - dressing.flick.height - dressing.edgeEpsilon : false

    anchors.fill: parent
    visible: dressing.boxed

    // ---- the two fades ---------------------------------------------------
    Rectangle {
        id: headBand
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: -dressing._seal
        anchors.rightMargin: -dressing._seal
        height: dressing.fadeHeight
        // Each fade comes and goes with a short fade of ITS OWN: a list
        // crosses the "there is more" line while rows animate in and out, and
        // a fade popping on and off at that line is visible.
        opacity: dressing.moreAbove ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: dressing.fadeMs
            }
        }
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: dressing.boxColor
            }
            GradientStop {
                position: 1.0
                color: "transparent"
            }
        }
    }

    Rectangle {
        id: footBand
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: -dressing._seal
        anchors.rightMargin: -dressing._seal
        height: dressing.fadeHeight
        opacity: dressing.moreBelow ? 1 : 0
        visible: opacity > 0
        Behavior on opacity {
            NumberAnimation {
                duration: dressing.fadeMs
            }
        }
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: "transparent"
            }
            GradientStop {
                position: 1.0
                color: dressing.boxColor
            }
        }
    }

    // The seals: the box's colour straddling each outer edge, on the band's own (eased) weight.
    Rectangle {
        x: -dressing._seal
        y: -dressing._seal
        width: parent.width + 2 * dressing._seal
        height: 2 * dressing._seal
        color: dressing.boxColor
        opacity: headBand.opacity
        visible: opacity > 0
    }
    Rectangle {
        x: -dressing._seal
        y: parent.height - dressing._seal
        width: parent.width + 2 * dressing._seal
        height: 2 * dressing._seal
        color: dressing.boxColor
        opacity: footBand.opacity
        visible: opacity > 0
    }

    // ---- the corner re-cut ------------------------------------------------
    Item {
        readonly property real _bevel: dressing.boxed ? dressing.bevelWidth : 0
        anchors.fill: parent
        anchors.margins: -_bevel
        clip: true

        Rectangle {
            readonly property real _capW: dressing.radius + parent._bevel
            anchors.fill: parent
            anchors.margins: -_capW
            color: "transparent"
            radius: dressing.radius + parent._bevel + _capW
            border.width: _capW
            border.color: dressing.surfaceColor
            antialiasing: true
        }
        Rectangle {
            anchors.fill: parent
            color: "transparent"
            radius: dressing.radius + parent._bevel
            border.width: parent._bevel
            border.color: dressing.bevelColor
            antialiasing: true
            visible: parent._bevel > 0
        }
    }
}
