pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../../common/components/Mix.js" as Mix

// =============================================================================
// ReelGlyphArt.qml -- the vector half of a reel glyph: what the font's Text cannot do while a flourish runs (the moon's phases, the
// 1 and the 0 trading places, the arrow leaving its box, the Zs drifting off, the sun setting, the spoon, the twisting strip) and the
// padlock, whose rest is OPEN (the font has no open padlock).
//
// It draws the LAYERS of the item's pose (its set's `poseOf`: ReelFlourish.js / IdleFlourish.js `pose`), in order, and knows no item by
// name: a reel's flourishes are the set's. Laid over the glyph's Text in the Text's own frame (the same origin and size): the outlines
// are the font's, put on the Text's pixels by the set, so at the start and the end of a flourish the art and the Text are one picture
// and the swap is not seen. A pose may keep the Text and draw over it (the mug's spoon and steam), or turn the Text itself (reboot,
// hibernate: IconReelView), with no layer at all.
//
// A layer: { path, stroke, cap, join, rule, alpha, shade, dy, ground, stops, x0, x1 } (ReelFlourish.js THE POSE). At most `slots` of
// them (six); none is built while there is none (the Loader), so a reel at rest builds no shape but the padlock's.
// =============================================================================
Item {
    id: art

    property var layers: []
    property color ink: "black"
    // what a layer marked `ground` is drawn in: the cell's ground (a gap cut into what lies under it)
    property color ground: "white"
    // what `shade` mixes the ink toward
    property color faint: "gray"
    readonly property int slots: 6

    readonly property bool drawing: !!art.layers && art.layers.length > 0

    function colourOf(lay: var, shade: real): color {
        const base = lay.ground ? art.ground : art.ink;
        const c = shade > 0 ? Mix.c(base, art.faint, shade) : base;
        const a = lay.alpha === undefined ? 1 : lay.alpha;
        return a >= 1 ? c : Qt.rgba(c.r, c.g, c.b, c.a * Math.max(0, a));
    }

    Loader {
        active: art.drawing
        sourceComponent: Item {
            Slot {
                slot: 0
            }
            Slot {
                slot: 1
            }
            Slot {
                slot: 2
            }
            Slot {
                slot: 3
            }
            Slot {
                slot: 4
            }
            Slot {
                slot: 5
            }
        }
    }

    component Slot: Shape {
        id: sh
        required property int slot
        readonly property var lay: art.layers && sh.slot < art.layers.length ? art.layers[sh.slot] : null
        readonly property bool isStroke: !!sh.lay && sh.lay.stroke > 0
        readonly property bool graded: !!sh.lay && !!sh.lay.stops
        visible: !!sh.lay && sh.lay.path !== "" && (sh.lay.alpha === undefined || sh.lay.alpha > 0)
        y: sh.lay && sh.lay.dy ? sh.lay.dy : 0
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: sh.isStroke ? sh.lay.stroke : -1
            strokeColor: sh.isStroke ? art.colourOf(sh.lay, sh.lay.shade || 0) : "transparent"
            fillColor: sh.isStroke || !sh.lay ? "transparent" : art.colourOf(sh.lay, sh.lay.shade || 0)
            fillGradient: sh.graded && !sh.isStroke ? grad : null
            fillRule: sh.lay && sh.lay.rule === "winding" ? ShapePath.WindingFill : ShapePath.OddEvenFill
            capStyle: sh.lay && sh.lay.cap === "round" ? ShapePath.RoundCap : sh.lay && sh.lay.cap === "flat" ? ShapePath.FlatCap : ShapePath.SquareCap
            joinStyle: sh.lay && sh.lay.join === "round" ? ShapePath.RoundJoin : sh.lay && sh.lay.join === "miter" ? ShapePath.MiterJoin : ShapePath.BevelJoin
            PathSvg {
                path: sh.lay ? sh.lay.path : ""
            }
        }
        // the shade across x (a twisting strip's faces): nine stops, evenly from x0 to x1
        LinearGradient {
            id: grad
            x1: sh.graded ? sh.lay.x0 : 0
            x2: sh.graded ? sh.lay.x1 : 1
            y1: 0
            y2: 0
            GradientStop { position: 0 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[0]) : "transparent" }
            GradientStop { position: 1 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[1]) : "transparent" }
            GradientStop { position: 2 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[2]) : "transparent" }
            GradientStop { position: 3 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[3]) : "transparent" }
            GradientStop { position: 4 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[4]) : "transparent" }
            GradientStop { position: 5 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[5]) : "transparent" }
            GradientStop { position: 6 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[6]) : "transparent" }
            GradientStop { position: 7 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[7]) : "transparent" }
            GradientStop { position: 8 / 8; color: sh.graded ? art.colourOf(sh.lay, sh.lay.stops[8]) : "transparent" }
        }
    }
}
