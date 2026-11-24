pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

// =============================================================================
// PosedGlyph.qml -- one Nerd Font glyph in the bar: its Text at rest, its OWN OUTLINE, posed, while a flourish plays.
//
// At rest it is exactly the plain Text it replaces (same item size: the Text's own; the Text at 0,0), so a host swaps a Text for
// this at 0 px. While `posing` the Text gives way to `parts`: SVG paths in this item's pixels, the font's outline moved by a pose
// (GlyphOutline.js `emit`, placed from `origin`, where the Text puts the glyph's pen on its baseline). A pose is the font's own
// outline at the start and at the end of its clock, so the swap shows nothing but the motion. One ShapePath per part (the curve
// renderer resolves touching contours of ONE path wrongly), at most four, drawn in order on the curve renderer: vector, as sharp
// as the Text on any scale. At rest the Shape is hidden and has no path: nothing is built or drawn.
//
// ONE INK: every part is the glyph's colour. `shades` may give a part a SHARE of it (0..1, its alpha: a sheet further down a
// block, something coming into being); a part with none is the full ink. A share is a fraction the pose eases, never a colour.
// =============================================================================
Item {
    id: root

    property string text: ""
    property string family: "Symbols Nerd Font"
    property real pixelSize: 16
    property color color: "black"
    property bool posing: false
    property var parts: []
    property var shades: []

    // where the Text puts the glyph's pen on its baseline, in this item's pixels: what a pose is placed from
    readonly property point origin: Qt.point(label.x, label.y + label.baselineOffset)

    implicitWidth: label.implicitWidth
    implicitHeight: label.implicitHeight

    Text {
        id: label
        text: root.text
        font.family: root.family
        font.pixelSize: root.pixelSize
        // A Nerd Font glyph never renders bold: the synthetic weight deforms it.
        font.bold: false
        color: root.color
        visible: !root.posing
    }

    component PartPath: ShapePath {
        id: sp
        required property int part
        readonly property real share: sp.part < root.shades.length ? root.shades[sp.part] : 1
        fillColor: sp.share >= 1 ? root.color : Qt.rgba(root.color.r, root.color.g, root.color.b, root.color.a * Math.max(0, sp.share))
        strokeColor: "transparent"
        strokeWidth: -1
        fillRule: ShapePath.WindingFill
        PathSvg {
            path: sp.part < root.parts.length ? root.parts[sp.part] : ""
        }
    }

    Shape {
        visible: root.posing
        preferredRendererType: Shape.CurveRenderer
        PartPath {
            part: 0
        }
        PartPath {
            part: 1
        }
        PartPath {
            part: 2
        }
        PartPath {
            part: 3
        }
    }
}
