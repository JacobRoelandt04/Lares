import QtQuick

// =============================================================================
// ScaledCanvas.qml -- a Canvas that paints at the glass's resolution.
//
// A Canvas paints into a texture of ITS OWN size, so under a magnifying transform (the shell's ScaleRoot) it is stretched and goes
// soft (measured: edge rise 1.08 px at 1.25, 1.80 at 1.5, native 0.80). `canvasSize` does NOT stretch a canvas over its item (the item shows
// the top left of a bigger canvas, so the content draws 1.25x too large at 1.25). This is the pattern that does: a Canvas `renderScale` times larger than the item, shown
// scaled back down from the top left, its context scaled by the same number after `reset()` -- so the painter draws in the item's own
// (design) px and the pixels are the glass's. Under a ScaleRoot it paints what a native canvas of k x the size paints (mean difference
// 0.003 of 255 against 0.8 for a plain Canvas).
//
//     ScaledCanvas {
//         anchors.fill: parent
//         antialiasing: true
//         renderStrategy: Canvas.Immediate
//         onDraw: (ctx, w, h) => { ctx.fillStyle = "red"; ctx.fillRect(0, 0, w, h); }   // design px; reset() and scale already done
//     }
//     canvas.requestPaint()      // when something the painter reads changed
//
// The painter must NOT call `ctx.reset()` itself: that drops the scale. The canvas is repainted when the item is resized and when
// the scale changes; everything else the painter reads is the host's to ask for (`requestPaint()`, as for a Canvas).
// `lineWidth`, `shadowBlur` and `shadowOffset*` all follow the context's scale in Qt's Canvas (measured, Qt 6.12.0: a ball's shadow
// painted through ctx.scale matches the native one to 0.1 of 255; multiplying the shadow by the scale as well is 2.5 off): a painter
// keeps every length in design px.
//
// `renderScale` (device px per design px) is FOUND -- DeviceScale: the nearest ScaleRoot's, else the window's pixel ratio -- so a
// canvas deep in a popup is right whatever hosts it; a host that knows better hands one.
// =============================================================================
Item {
    id: root

    property alias renderStrategy: canvas.renderStrategy
    property alias renderTarget: canvas.renderTarget
    readonly property alias available: canvas.available

    // Device px per design px.
    property real renderScale: dev.value

    // The painter: `ctx` is reset and scaled; w x h is this item's size in design px.
    signal draw(var ctx, real w, real h)

    function requestPaint(): void {
        canvas.requestPaint();
    }

    DeviceScale {
        id: dev
    }

    Canvas {
        id: canvas
        // A Cooperative canvas draws an UNINITIALISED texture, opaque, from the frame it is made until its first paint has landed:
        // a hole in what it stands on (nested Mesa) or a smear of whatever the memory held (the user's GPU: the boot's reel cells
        // and middle island, ~6 frames). It is shown once it has painted; at opacity 0 it is still synchronised, so it still paints.
        property bool _painted: false
        opacity: canvas._painted ? 1 : 0
        onPainted: canvas._painted = true
        readonly property real _rs: Math.max(0.25, root.renderScale)
        // NOT rounded: a Canvas of fractional size stretches its (rounded-up) texture over its rect by a sliver, as every canvas here
        // does, and rounding it here would move every picture painted at scale 1 (the ball's squish) by that sliver
        // (754 px of the install state, 85 of 255 at the thin edge)
        width: root.width * canvas._rs
        height: root.height * canvas._rs
        scale: 1 / canvas._rs
        transformOrigin: Item.TopLeft
        antialiasing: root.antialiasing

        on_RsChanged: canvas.requestPaint()
        onWidthChanged: canvas.requestPaint()
        onHeightChanged: canvas.requestPaint()

        onPaint: {
            const ctx = canvas.getContext("2d");
            ctx.reset();
            ctx.scale(canvas._rs, canvas._rs);
            root.draw(ctx, root.width, root.height);
        }
    }
}
