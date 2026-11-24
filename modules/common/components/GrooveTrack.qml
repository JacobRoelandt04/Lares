pragma ComponentBehavior: Bound

import QtQuick
import "CarvedPath.js" as CarvedPath

// =============================================================================
// GrooveTrack.qml
//
// A straight engraved groove with dots at fixed stops, drawn with the same
// layered technique as the workspaces rail: many concentric strokes from the
// outer bevel inwards, so the line and the dots union into one carved shape
// with a continuous inset shadow and no seams where they meet.
//
// The carve is CarvedPath.js, which Workspaces paints with too. Unlike
// modules/bar/workspaces/Workspaces.qml's groove it has no clock split or
// side tracks, and its fill colour can differ before and after `progress`.
// That is the progress bar. It works here because the ball always sits exactly
// at the progress point, so the hard colour transition is hidden underneath it —
// which is also why this is a shared component rather than something local to
// the update popup.
//
// ORIENTATION. "vertical" draws the same engraving in a frame rotated -90
// degrees (GrooveSlider rotates its inner item the same way), so every
// number here stays in the horizontal frame: along the track, across it.
// Rotating by -90 rather than +90 puts progress 0 at the BOTTOM and the fill
// climbing, which is how a level reads. The host sizes the item in its own
// frame: a vertical track is `implicitWidth` wide and as tall as it is given.
// =============================================================================
Item {
    id: track

    // ---- Geometry ----
    property real lineThickness: 6
    property real dotSize: 12
    property real edgePadding: 18
    property real sizeScale: 1.0
    property string orientation: "horizontal"   // "horizontal" | "vertical"

    // Stop positions along the track, 0..1. Rendered as engraved dots.
    property var stops: []

    // ---- Progress ----
    // 0..1 along the usable span. Everything before it uses `fillColor`.
    property real progress: 0
    property bool showFill: true

    // ---- Colours ----
    property color surfaceColor:      "#EAEDF5"
    property color grooveColor:       "#E1E4EB"
    property color grooveBevelColor:  "#EEF0F7"
    property color grooveShadowColor: "#CED1D7"
    property color fillColor:         "#4480F4"
    property color fillShadowColor:   "#3B73E0"

    property real grooveShadowWidth: 3
    property real grooveBevelWidth:  2
    property var  grooveGradientEasing: [0.15, 0.60, 0.35, 1]
    property var  grooveBevelEasing:    [0.15, 0.10, 0.25, 1.0]

    // ---- Derived ----
    readonly property real scLine: lineThickness * sizeScale
    readonly property real scDot:  dotSize * sizeScale
    readonly property real scPad:  edgePadding * sizeScale

    readonly property bool isHorizontal: orientation !== "vertical"
    // The item's two extents in the track's own frame.
    readonly property real along: isHorizontal ? width : height
    readonly property real cross: isHorizontal ? height : width

    readonly property real trackStart: scPad
    readonly property real trackEnd: Math.max(scPad, along - scPad)
    readonly property real trackSpan: Math.max(0, trackEnd - trackStart)
    readonly property real lineCenter: cross / 2

    // Pixel x for a 0..1 position.
    function xAt(t) { return track.trackStart + track.trackSpan * Math.max(0, Math.min(1, t)); }

    readonly property real crossExtent: Math.max(scDot, scLine) + grooveBevelWidth * sizeScale * 2
    implicitHeight: isHorizontal ? crossExtent : 0
    implicitWidth: isHorizontal ? 0 : crossExtent

    // Shared painter. Both canvases draw the SAME carved geometry; only the
    // palette differs. That is what makes the filled part read as the same
    // engraving as the rest rather than a coloured bar laid on top of it — it
    // has the identical bevel, inset shadow and dot union, because it is the
    // identical drawing.
    function _paintGroove(ctx, core, shadow, bevelTint) {
        // (the context arrives reset and scaled: ScaledCanvas)
        if (track.trackSpan <= 0) return;

        const cy = track.lineCenter;
        const x0 = track.trackStart;
        const x1 = track.trackEnd;
        CarvedPath.paintCarve(ctx, {
            bw: track.grooveBevelWidth * track.sizeScale,
            sw: track.grooveShadowWidth * track.sizeScale,
            halfLine: track.scLine / 2,
            halfDot: track.scDot / 2
        }, {
            surface: track.surfaceColor,
            bevel: bevelTint,
            shadow: shadow,
            core: core,
            bevelEasing: track.grooveBevelEasing,
            shadowEasing: track.grooveGradientEasing
        }, function (ctx, rLine, rDot) {
            if (rLine > 0) {
                ctx.lineWidth = rLine * 2;
                ctx.beginPath();
                ctx.moveTo(x0, cy);
                ctx.lineTo(x1, cy);
                ctx.stroke();
            }
            if (rDot > 0) {
                ctx.beginPath();
                for (let j = 0; j < track.stops.length; j++) {
                    const dx = track.xAt(track.stops[j]);
                    ctx.moveTo(dx + rDot, cy);
                    ctx.arc(dx, cy, rDot, 0, Math.PI * 2);
                }
                ctx.fill();
            }
        });
    }

    // Everything the drawing depends on — deliberately NOT progress.
    //
    // Repainting the whole groove whenever progress moves would mean ~20 stroke
    // passes plus a dot pass per frame for the entire download phase. The
    // fill is a clip rectangle over a second, identical canvas instead, so
    // progress costs a width change and no repaint at all.
    //
    // ONE KEY PER CANVAS, not one for both. They share the geometry and the
    // bevel — the carved shape, and the light edge outside it, which is drawn
    // in the same two colours by both — and each then has its own pair. A
    // single key would make both canvases repaint whenever either palette moved,
    // so the player's rail would re-raster its whole channel every frame for the
    // 160 ms of a hover whose only effect is on the FILL. The paint is
    // synchronous (see the canvases below), so that work is on the GUI
    // thread, and half of it would be for nothing.
    readonly property string _shapeKey: [
        track.scLine, track.scDot, track.scPad, track.lineCenter,
        track.grooveBevelWidth, track.grooveShadowWidth, track.sizeScale,
        track.surfaceColor, track.grooveBevelColor,
        JSON.stringify(track.stops), JSON.stringify(track.grooveGradientEasing),
        JSON.stringify(track.grooveBevelEasing)
    ].join("|")
    readonly property string _baseKey:
        track._shapeKey + "|" + track.grooveColor + "|" + track.grooveShadowColor
    readonly property string _fillKey:
        track._shapeKey + "|" + track.fillColor + "|" + track.fillShadowColor

    on_BaseKeyChanged: baseCanvas.requestPaint()
    on_FillKeyChanged: fillCanvas.requestPaint()
    onWidthChanged:    { baseCanvas.requestPaint(); fillCanvas.requestPaint(); }
    onHeightChanged:   { baseCanvas.requestPaint(); fillCanvas.requestPaint(); }

    // SYNCHRONOUS, so the rail follows a theme switch in the same frame as
    // everything else.
    //
    // The lag is not a `Behavior on color` (the rail has none): `Canvas.Cooperative`
    // issues the paint to the scene graph's own thread, so the texture that
    // reaches the screen is the one painted for the PREVIOUS frame. The theme moves every
    // colour every frame for 420 ms, so one frame of latency is one frame of
    // visible disagreement between the groove and everything around it, for
    // the whole fade. Measured against a Rectangle bound to the same colour:
    // 6–12 ms behind on every
    // frame of the fade — measured at the steepest part, 14/255 off the
    // colour the theme said it was showing (138,142,147 against the swatch's
    // 124,127,134) — and under 2.5 ms with `Immediate`, where the same two
    // frames agree within 2/255. The whole engraving costs 0.15–0.23 ms to
    // paint at 400 px (0.155 measured in a 200-repeat loop, 0.20–0.23 per real
    // paint with its overhead, both on this machine), which is what makes doing
    // it on the GUI thread the cheap answer rather than the expensive one: two
    // canvases at that price is ~3% of a 60 Hz frame, and only while a colour
    // is actually moving. It changes no pixel: the system update's render
    // states come back bit-identical across the switch.
    //
    // Both canvases live in `frame`, the track's own horizontal frame: the
    // item itself when horizontal (same size, no rotation), the item turned
    // -90 degrees about its centre when vertical.
    Item {
        id: frame
        width: track.along
        height: track.cross
        x: (track.width - width) / 2
        y: (track.height - height) / 2
        rotation: track.isHorizontal ? 0 : -90

        ScaledCanvas {
            id: baseCanvas
            anchors.fill: parent
            antialiasing: true
            renderStrategy: Canvas.Immediate
            onDraw: (ctx, cw, ch) => track._paintGroove(ctx,
                                                        track.grooveColor, track.grooveShadowColor,
                                                        track.grooveBevelColor)
        }

        // The filled head: the same engraving, in the progress palette, revealed
        // by a clip whose width IS the progress. The seam is a straight cut
        // through two identical shapes, and the ball sits exactly on it.
        Item {
            id: fillClip
            visible: track.showFill
            x: 0
            y: 0
            height: frame.height
            width: track.showFill ? Math.max(0, track.xAt(track.progress)) : 0
            clip: true

            ScaledCanvas {
                id: fillCanvas
                x: 0
                y: 0
                width: frame.width
                height: frame.height
                antialiasing: true
                renderStrategy: Canvas.Immediate
                onDraw: (ctx, cw, ch) => track._paintGroove(ctx,
                                                            track.fillColor, track.fillShadowColor,
                                                            track.grooveBevelColor)
            }
        }
    }
}
