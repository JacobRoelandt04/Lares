import QtQuick
import QtQuick.Shapes

import "../theme"

// =============================================================================
// DirectionArrow.qml -- a down or an up arrow, DRAWN: a stem and a head in a
// 5 x 7 design box, so it sits on the same pixels in any font (a typed arrow
// is a glyph of whatever face is loaded, and shifts about as the face and the
// digits beside it change). The bar's traffic figures draw it at 5 x 7; the
// network popup's status line at the box its type size needs, the same strokes.
//
// `width` / `height` scale the drawing (the stroke too), so a host sizes it by
// whole pixels and never by a transform. `ink` is the colour: a host that
// fades it mixes themed colours with Mix.js; this component animates nothing.
// =============================================================================
Shape {
    id: arrow

    property bool up: false
    property color ink: Theme.textFaint

    width: 5
    height: 7
    preferredRendererType: Shape.CurveRenderer

    readonly property real _kx: arrow.width / 5
    readonly property real _ky: arrow.height / 7

    ShapePath {
        strokeColor: arrow.ink
        strokeWidth: 1.2 * arrow._kx
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 2.5 * arrow._kx
        startY: (arrow.up ? 6.4 : 0.6) * arrow._ky
        PathLine { x: 2.5 * arrow._kx; y: (arrow.up ? 0.6 : 6.4) * arrow._ky }
        PathMove { x: 0.7 * arrow._kx; y: (arrow.up ? 2.6 : 4.4) * arrow._ky }
        PathLine { x: 2.5 * arrow._kx; y: (arrow.up ? 0.6 : 6.4) * arrow._ky }
        PathLine { x: 4.3 * arrow._kx; y: (arrow.up ? 2.6 : 4.4) * arrow._ky }
    }
}
