pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import "WeatherInkCompose.js" as Ink
import "WeatherInkPose.js" as Pose

// =============================================================================
// WeatherGlyphInk.qml -- a weather condition as an ink icon: the drawn set (tools/dev/weather_ink_parts.py).
//
// Solid shapes at Material Design's weight on its 24-unit grid, so the icon sits beside the bar's font glyphs as one of
// them: everything in the glyph's `ink` (the bar's muted ink by default) except the icon's ONE accent part -- the sun, the
// moon, the drops, the flakes or stones, the bolt -- in that part's weather colour. Parts that overlap keep a gap between
// them, cut in the outlines themselves, so the icon draws nothing but its own shapes on any ground.
//
// Two fills in one Shape, no shader, no layer, no clock: the outlines are data (WeatherInkCompose.js) scaled to `size`.
// WeatherGlyph is the public item; it builds this one when the ink set is chosen and hands it everything below.
//
// THE FLOURISH (WeatherInkPose.js): while `posing` the icon is drawn at `poseBeat` of its flourish -- the host's clock
// (GlyphFlourish.t over its flourishMs); `flourishBeats` is how long this icon's runs. Each fill is then two paths, the parts
// that stand still and the parts that move, so only what moves is tessellated again each frame. The pose at its first and
// last beat is the icon at rest. The moon by phase and the wind arrow are not compositions: they move as whole items (the
// moon rocks, the arrow draws back and darts along its heading, the dot of "no direction" swells).
// =============================================================================
Item {
    id: root

    property string kind: "clear"
    property int intensity: 1
    property bool night: false
    property bool shower: false
    property real moonPhase: 0.5
    // "arrow" only: degrees the wind blows FROM; the dart points where the air goes. Not a number: a dot.
    property var direction: null
    property real size: 48
    property color ink: "black"
    // The accent part's colour, the host's to resolve from `accentToken` (a weather theme token; "" = the icon has none).
    property color accent: root.ink
    readonly property string accentToken: root._paths.token

    property bool posing: false
    property real poseBeat: 0
    readonly property real flourishBeats: Pose.beats(root.kind, root.intensity, root.night, root.shower, root._hasDirection)
    readonly property bool _moving: root.posing && root.flourishBeats > 0

    implicitWidth: root.size
    implicitHeight: root.size

    readonly property bool _conditional: root.kind !== "moon" && root.kind !== "arrow"
    readonly property string _key: Ink.key(root.kind, root.intensity, root.night, root.shower)
    readonly property bool _hasDirection: typeof root.direction === "number" && isFinite(root.direction)
    readonly property var _paths: root.kind === "moon" ? Ink.moon(root.moonPhase)
        : root.kind === "arrow" ? Ink.paths(root._hasDirection ? "arrow" : "dot")
        : root._moving ? Pose.paths(root._key, root.poseBeat)
        : Ink.paths(root._key)
    readonly property size _unit: Qt.size(root.size / Ink.UNITS, root.size / Ink.UNITS)

    Item {
        width: root.size
        height: root.size
        // the arrow's heading; the moon's rock (Pose.moonAngle is counter-clockwise, an item turns clockwise)
        rotation: root.kind === "arrow" ? (root._hasDirection ? root.direction + 180 : 0)
            : root.kind === "moon" && root._moving ? -Pose.moonAngle(root.poseBeat, Pose.DEFAULTS) : 0
        scale: root.kind === "arrow" && !root._hasDirection && root._moving ? Pose.dotPulse(root.poseBeat) : 1

    Shape {
        width: root.size
        height: root.size
        preferredRendererType: Shape.CurveRenderer
        // the arrow along its heading (the dart points up before the turn)
        y: root.kind === "arrow" && root._hasDirection && root._moving ? -Pose.arrowNudge(root.poseBeat) * root.size / Ink.UNITS : 0

        ShapePath {
            fillColor: root.ink
            strokeColor: "transparent"
            strokeWidth: -1
            fillRule: ShapePath.WindingFill
            scale: root._unit
            PathSvg {
                path: root._paths.ink
            }
        }
        ShapePath {
            fillColor: root.ink
            strokeColor: "transparent"
            strokeWidth: -1
            fillRule: ShapePath.WindingFill
            scale: root._unit
            PathSvg {
                path: root._paths.inkMove || ""
            }
        }
        ShapePath {
            fillColor: root.accent
            strokeColor: "transparent"
            strokeWidth: -1
            fillRule: ShapePath.WindingFill
            scale: root._unit
            PathSvg {
                path: root._paths.accent
            }
        }
        ShapePath {
            fillColor: root.accent
            strokeColor: "transparent"
            strokeWidth: -1
            fillRule: ShapePath.WindingFill
            scale: root._unit
            PathSvg {
                path: root._paths.accentMove || ""
            }
        }
    }
    }
}
