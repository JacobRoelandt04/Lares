pragma ComponentBehavior: Bound

import QtQuick

import QtQuick.Shapes

import "../../common/theme"
import "SiliconGlyphPose.js" as Pose

// =============================================================================
// SiliconBarGlyph.qml -- the CPU profile as one tiny Nerd Font glyph in the profile's hue, the
// scene's three holograms in miniature: Quiet a leaf, Balanced scales, Performance a lightning
// bolt. (A tweaked profile is marked by the face, with a dot of its own, not by the glyph.)
//
// The glyph is placed by its INK, not its line box: every Material Design glyph of this font is
// centred on 614 / 2048 em above the baseline and on half its advance (read from the font's
// outlines: leaf, scale_balance and lightning_bolt all measure exactly that), so the ink centre
// of the Text sits `0.2998 * pixelSize` above its baseline whatever the face's ascent. The box
// is `box` x `box` and the ink is centred in it to the pixel.
// Codepoints are md-leaf F032A, md-scale_balance F05D1, md-lightning_bolt F140B (checked by name
// against the installed Symbols Nerd Font, not by value).
//
// THE FLOURISH. While `flexing` the plain Text gives way to the same glyph drawn as an OUTLINE that the flourish's
// clock moves (SiliconGlyphPose.js: the leaf's blade bends on its stem; the scales throw a weight from the left pan to the right,
// which drops under it, stands tipped and comes back; the bolt's ink runs off downward to a point and a new charge strikes in from
// above), a Shape on the curve renderer: vector, so it is as sharp as the Text on any renderScale. The pose is the
// font's own outline at u = 0 and at u = 1, so the swap shows nothing but the motion. At rest the Shape is hidden and has no path:
// nothing is built, drawn or polled.
// =============================================================================
Item {
    id: glyph

    property int profile: 1                 // 0 Quiet, 1 Balanced, 2 Performance
    property color color: Theme.textMuted
    property int pixelSize: 16
    property int box: 16

    // the flourish: whether the outline replaces the Text, and the clock (0..1) and strength it is posed by
    property bool flexing: false
    property real flexU: 0
    property real flexStrength: 1

    readonly property string text: glyph.profile === 0 ? "\u{F032A}"
        : (glyph.profile === 1 ? "\u{F05D1}" : "\u{F140B}")

    implicitWidth: glyph.box
    implicitHeight: glyph.box

    Text {
        id: label
        x: Math.round(glyph.width / 2 - label.implicitWidth / 2)
        y: Math.round(glyph.height / 2 + 0.2998 * glyph.pixelSize - label.baselineOffset)
        text: glyph.text
        color: glyph.color
        font.family: "Symbols Nerd Font"
        font.pixelSize: glyph.pixelSize
        // A Nerd Font glyph never renders bold: the synthetic weight deforms it.
        font.bold: false
        visible: !glyph.flexing
    }

    // the pose: one SVG path per part (the leaf and the bolt are one part, the scales five), built once per tick of the flourish
    // the font's origin (where the Text puts the glyph's pen on the baseline), in the glyph's own pixels: what a pose is placed by
    readonly property point origin: Qt.point(label.x, label.y + label.baselineOffset)
    readonly property var poseParts: glyph.flexing ? Pose.path(glyph.profile, glyph.flexU, glyph.flexStrength, glyph.pixelSize,
                                                               glyph.origin.x, glyph.origin.y) : []

    component PartPath: ShapePath {
        id: sp
        required property int part
        fillColor: glyph.color
        strokeColor: "transparent"
        strokeWidth: -1
        fillRule: ShapePath.WindingFill
        PathSvg {
            path: sp.part < glyph.poseParts.length ? glyph.poseParts[sp.part] : ""
        }
    }

    Shape {
        id: outline
        visible: glyph.flexing
        preferredRendererType: Shape.CurveRenderer
        PartPath { part: 0 }
        PartPath { part: 1 }
        PartPath { part: 2 }
        PartPath { part: 3 }
        PartPath { part: 4 }
    }
}
