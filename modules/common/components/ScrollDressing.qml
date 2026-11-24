pragma ComponentBehavior: Bound

import QtQuick

import "../scroll"

// =============================================================================
// ScrollDressing.qml
//
// EVERY FLICKABLE IN THIS SHELL SCROLLS THE SAME DISTANCE AND FADES ITS OWN
// EDGES. Both facts live here, in one object a host drops beside its
// Flickable, because "how far does a notch go, and does this box fade" answered
// file by file gives several answers at once (120 px with a fade here, 60 px
// there, and Qt's own 72 px with no fade at all in a box left on the
// desktop's `wheelScrollLines` style hint rather than on a number this shell
// chose).
//
// HOW IT MOVES is the shell's one feel (modules/common/scroll: ScrollFeel +
// KineticScroll): a mouse notch is ScrollFeel.notchPx
// (120) and GLIDES over notchMs, notches adding up (Qt's own glide swallows
// the notches that arrive while it decays); a touchpad follows the fingers, and a lift while they move COASTS and
// eases out. `scrollSpeed` multiplies the feel's own speed for this box (a box
// that genuinely wants less takes 0.5); a horizontal box adds ScrollFeel.hSpeed.
//
// WHY THE FADE IS A DISTANCE, NOT A FLAG. The band's opacity is how far the
// content is from that end, measured in fade-heights. A flag with a Behavior
// on it burns at the end of a list -- the flag flips while rows are still
// animating and the fade blinks -- and it cannot be off EXACTLY at rest,
// which is the one moment it must be.
//
// THE BAND COVERS WHAT THE CLIP LETS THROUGH, TO THE DEVICE PIXEL. A
// Flickable's clip is a scissor rectangle the renderer rounds from the edge's
// DEVICE position on the CPU (qRound, in double); a band is a quad the GPU
// rasterises by pixel centres (in float, snapped to its subpixel grid). Where
// the edge passes exactly through a row of pixel centres -- a tie, one edge in
// sixteen at the user's 1.25 shell on a 1.25 screen, more at a popup centred on
// a half pixel -- the two can round opposite ways, and the scissor keeps a row
// the band leaves bare: a line of rows seen through, right past the fade's
// opaque end (the stocks list's foot, the weather strip's right end). Which
// way a tie goes depends on the render path (a window, a layer's texture, a
// grab) and on float noise, so it is not predicted: every band SEALS its edges.
// A `_seal` (1/64 device px each way) ground strip straddles the outer edge, so
// the pixel whose centre the edge passes through is covered, and the bands and
// leads reach the same hair past the two sides. Nothing moves where the edge
// is not on a tie (no other pixel centre lies that close to it), and the
// gradients are not touched (the seal is its own quad).
// tools/dev/fade_edges_probe.sh holds every band to it.
//
// THE HOST OWNS THE FLICKABLE; this owns nothing but the two bands and the
// wheel. It must be a SIBLING of the Flickable, never a child: a child is
// reparented into `contentItem` and scrolls away with the text.
//
//     Item {                      // the box
//         Flickable { id: box; objectName: "detail"; ... }
//         ScrollDressing { anchors.fill: parent; flick: box; ground: fill }
//     }
// =============================================================================
Item {
    id: dressing

    // ---- Contract ---------------------------------------------------------
    property Flickable flick: null
    // Which way this box scrolls. A horizontal strip maps the wheel's y to x,
    // because a mouse has no x wheel and a two-finger swipe reports both.
    property int orientation: Qt.Vertical
    // 1.0 == one notch, 120 px. The module's one speed.
    property real scrollSpeed: 1.0
    property bool wheelEnabled: true
    // The colour the content fades INTO: the box's own fill, not the surface
    // outside it.
    property color ground: "transparent"
    property real fadeHeight: 34
    // How far the content must be from an end for that end's band to be
    // fully on. A fade-height suits content whose ink runs to its end. A box
    // whose content ends in EMPTY ROOM (a list inset for its rows' bevels)
    // takes that room instead: ink reaches the clip only once the content is
    // that far from its end, so the band is fully on before anything is cut.
    // With a fade-height there, the alarm list (2 px of room, an 18 px fade)
    // would cut a row at the clip under a band a sixth on (measured: 0.17).
    property real rampLength: dressing.fadeHeight
    // An OPAQUE band of the ground before each fade's gradient, for a box whose
    // viewport reaches into its card's padding (the weather strip's does, so
    // its first column's ink sits at the card's margin at rest): once content
    // lies beyond an end, the lead covers the part of the viewport inside the
    // padding and the content still fades out at the padding line. 0 (every
    // other host) draws no lead.
    property real fadeLead: 0
    // A named exception, declared once: the transcript's first frame has a
    // pad above the newest answer that is not "more content" and must not
    // fade. Nothing else may suppress a band.
    property bool headSuppressed: false
    property bool footSuppressed: false
    // The host asks the foot band to step aside: 0 leaves it as the distance
    // says (every host but the notes editor, and that one at rest), 1 takes it
    // off. EASED BY THE HOST on a clock of its own, which is why it is not
    // `footSuppressed`: a flag cuts, and the editor wants the band to fade out
    // from under the line being written and back in when the writing stops.
    // Nothing but the host's own state moves it, so it is exactly 0 at rest,
    // where the band must be the distance's alone.
    property real footYield: 0
    // A rounded outline the bands must stay inside, in this item's
    // coordinates: {x, y, w, h, radii: [tl, tr, br, bl]} -- the host's
    // drawn shape when it is rounder than its clip. A band lies over the
    // clip RECTANGLE, so one that ends closer to a corner than that corner's
    // radius pokes its opaque end out of the curve (the notes grid's foot,
    // 12 px above a popup corner of 20). With an outline the bands are
    // drawn by shaders/fade_band.frag, cut to it; null keeps the plain ones.
    // THE OUTLINE MUST STAND OUTSIDE THE CLIP at each end of the bands, by more than two device pixels: the cut band feathers
    // inward from it and one pixel further in, so an outline that IS the clip leaves the clip's first two rows bare and the
    // content shows through them (the picker's grid, feedback/picker.md). Cut the clip in from the box, never the outline in.
    property var outline: null
    // The ground is NOT one colour when the engine pours a tint across the host's join with the bar (a coloured note):
    // { base: <the untinted surface>, reach: <the engine's tintBlend, in this item's units>, sides: [left, top, right, bottom] }
    // with the sides of `outline` that hang from a bar. The bands then fade into the surface as the field draws it there
    // (shaders/fade_band.frag), not into `ground` over the whole width -- which would leave a hard-edged patch where a band meets
    // the ramp (the notes editor's foot). null: the band fades into `ground`.
    property var surfaceRamp: null
    readonly property bool _ramped: !!dressing.surfaceRamp && !!dressing.outline && dressing.surfaceRamp.reach > 0
    readonly property bool _cut: !!dressing.outline && (dressing._ramped || dressing.outline.radii.some(r => r > 0))
    // The host's own bookkeeping after a wheel: a follow band to re-measure,
    // a sticky anchor to re-seat, an auto-follow to stop.
    signal wheeled()
    // A glide or a coast is under way. A probe waits for this to fall before it
    // reads a position: offscreen, a QML Timer's interval is not wall time
    // (CLAUDE.md), and the motion runs on the wall clock.
    readonly property bool moving: engine.moving

    readonly property bool _horizontal: dressing.orientation === Qt.Horizontal
    // THE SEAL (header): 1/64 of a device pixel, in this item's units. Far above the GPU's subpixel snap (1/256), far below
    // the grid an edge at rest lands on (1/32 at 1.25 x 1.25), so it decides ties and nothing else.
    DeviceScale {
        id: deviceScale
    }
    readonly property real _seal: 1 / 64 / Math.max(0.25, deviceScale.value)
    readonly property real _pos: !dressing.flick ? 0 : (dressing._horizontal ? dressing.flick.contentX : dressing.flick.contentY)
    readonly property real _max: !dressing.flick ? 0
        : Math.max(0, (dressing._horizontal ? dressing.flick.contentWidth - dressing.flick.width
                                            : dressing.flick.contentHeight - dressing.flick.height))
    readonly property real _ramp: Math.max(1e-3, dressing.rampLength)
    readonly property real _headF: dressing.headSuppressed || dressing.fadeHeight <= 0 ? 0
        : Math.max(0, Math.min(1, dressing._pos / dressing._ramp))
    readonly property real _footF: dressing.footSuppressed || dressing.fadeHeight <= 0 ? 0
        : Math.max(0, Math.min(1, (dressing._max - dressing._pos) / dressing._ramp))
          * (1 - Math.max(0, Math.min(1, dressing.footYield)))

    // Takes no input itself: the bands are paint and the handler is on the
    // Flickable, so a click still reaches whatever is under them.
    // It FILLS ITS PARENT unless the host anchors it elsewhere, and a host's
    // x/y/width/height lose to that anchor without a word: a host that sets
    // all four to its Flickable's has the bands lie on the CARD's top and
    // bottom edges instead -- no fade over the list's head, and the foot's
    // square end over the card's rounded corners. Place it with anchors.fill.
    anchors.fill: parent

    // Immediate: a host's programmatic move (a reveal, keeping a row in view).
    // It stops any glide or coast first, so the two never fight.
    function scrollBy(d) {
        engine.jump(d);
    }

    // A wheel event a host read itself (its content reads wheels of its own,
    // see below): the same motion this box's own reader gives. A horizontal box
    // takes the larger of the two components (a mouse has no x wheel).
    function wheel(ev) {
        const px = ev.pixelDelta, ad = ev.angleDelta;
        const useX = dressing._horizontal && (Math.abs(px.x) + Math.abs(ad.x) >= Math.abs(px.y) + Math.abs(ad.y));
        engine.feed(useX ? px.x : px.y, useX ? ad.x : ad.y, ev.phase);
        dressing.wheeled();
    }

    // Stop a glide or a coast (a host about to animate the position itself).
    function stopMotion() {
        engine.stop();
    }

    KineticScroll {
        id: engine
        flick: dressing.flick
        axis: dressing.orientation
        speed: dressing.scrollSpeed * (dressing._horizontal ? ScrollFeel.hSpeed : ScrollFeel.speed)
        maxPos: dressing._max
    }

    // ---- The two bands ----------------------------------------------------
    Rectangle {
        objectName: "scrollFadeHead"
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.right: dressing._horizontal ? undefined : parent.right
        anchors.bottom: dressing._horizontal ? parent.bottom : undefined
        anchors.leftMargin: dressing._horizontal ? dressing.fadeLead : -dressing._seal
        anchors.topMargin: dressing._horizontal ? -dressing._seal : dressing.fadeLead
        anchors.rightMargin: dressing._horizontal ? 0 : -dressing._seal
        anchors.bottomMargin: dressing._horizontal ? -dressing._seal : 0
        width: dressing._horizontal ? dressing.fadeHeight : undefined
        height: dressing._horizontal ? undefined : dressing.fadeHeight
        opacity: dressing._headF
        visible: !dressing._cut && opacity > 0.001
        gradient: Gradient {
            orientation: dressing._horizontal ? Gradient.Horizontal : Gradient.Vertical
            GradientStop {
                position: 0.0
                color: dressing.ground
            }
            GradientStop {
                position: 1.0
                color: "transparent"
            }
        }
    }

    Rectangle {
        objectName: "scrollFadeFoot"
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.left: dressing._horizontal ? undefined : parent.left
        anchors.top: dressing._horizontal ? parent.top : undefined
        anchors.rightMargin: dressing._horizontal ? dressing.fadeLead : -dressing._seal
        anchors.bottomMargin: dressing._horizontal ? -dressing._seal : dressing.fadeLead
        anchors.leftMargin: dressing._horizontal ? 0 : -dressing._seal
        anchors.topMargin: dressing._horizontal ? -dressing._seal : 0
        width: dressing._horizontal ? dressing.fadeHeight : undefined
        height: dressing._horizontal ? undefined : dressing.fadeHeight
        opacity: dressing._footF
        visible: !dressing._cut && opacity > 0.001
        gradient: Gradient {
            orientation: dressing._horizontal ? Gradient.Horizontal : Gradient.Vertical
            GradientStop {
                position: 0.0
                color: "transparent"
            }
            GradientStop {
                position: 1.0
                color: dressing.ground
            }
        }
    }

    // The leads (fadeLead), on the same weights as their bands, a seal past each side.
    Rectangle {
        x: dressing._horizontal ? 0 : -dressing._seal
        y: dressing._horizontal ? -dressing._seal : 0
        width: dressing._horizontal ? dressing.fadeLead : parent.width + 2 * dressing._seal
        height: dressing._horizontal ? parent.height + 2 * dressing._seal : dressing.fadeLead
        color: dressing.ground
        opacity: dressing._headF
        visible: !dressing._cut && dressing.fadeLead > 0 && opacity > 0.001
    }
    Rectangle {
        x: dressing._horizontal ? parent.width - width : -dressing._seal
        y: dressing._horizontal ? -dressing._seal : parent.height - height
        width: dressing._horizontal ? dressing.fadeLead : parent.width + 2 * dressing._seal
        height: dressing._horizontal ? parent.height + 2 * dressing._seal : dressing.fadeLead
        color: dressing.ground
        opacity: dressing._footF
        visible: !dressing._cut && dressing.fadeLead > 0 && opacity > 0.001
    }

    // The seals (header): a strip of the ground straddling each outer edge, 2 x `_seal` across, the band's length plus a seal
    // past each side, on its band's weight. Their own quads, so the bands' gradients are exactly what they were.
    Rectangle {
        objectName: "scrollFadeHeadSeal"
        x: -dressing._seal
        y: -dressing._seal
        width: dressing._horizontal ? 2 * dressing._seal : parent.width + 2 * dressing._seal
        height: dressing._horizontal ? parent.height + 2 * dressing._seal : 2 * dressing._seal
        color: dressing.ground
        opacity: dressing._headF
        visible: !dressing._cut && opacity > 0.001
    }
    Rectangle {
        objectName: "scrollFadeFootSeal"
        x: dressing._horizontal ? parent.width - dressing._seal : -dressing._seal
        y: dressing._horizontal ? -dressing._seal : parent.height - dressing._seal
        width: dressing._horizontal ? 2 * dressing._seal : parent.width + 2 * dressing._seal
        height: dressing._horizontal ? parent.height + 2 * dressing._seal : 2 * dressing._seal
        color: dressing.ground
        opacity: dressing._footF
        visible: !dressing._cut && opacity > 0.001
    }

    // The same two bands (leads included) cut to `outline`, each with its seals (THE SEAL, header) as quads of their own: the
    // strip across the outer edge and one along each side. A piece is a window onto ITS band -- the ramp is taken from the
    // band's own start, the outline from the piece's -- so a seal paints the colour the band has there, cut like the rest,
    // and the band's own quad is exactly what it was (a quad grown by the seal computes every colour in it a hair apart: a
    // level here and there over the whole band).
    //   piece  0 the band, 1 the seal across its outer edge, 2 / 3 the seals along its two sides
    component CutBand: ShaderEffect {
        id: cb
        required property bool head
        required property int piece
        // Inline components do not see the file's ids: the dressing is handed in.
        required property var dr
        readonly property bool hz: cb.dr._horizontal
        readonly property real len: cb.dr.fadeLead + cb.dr.fadeHeight
        readonly property real seal: cb.dr._seal
        // The band's own rect.
        readonly property real bx: cb.hz && !cb.head ? cb.dr.width - cb.len : 0
        readonly property real by: !cb.hz && !cb.head ? cb.dr.height - cb.len : 0
        readonly property real bw: cb.hz ? cb.len : cb.dr.width
        readonly property real bh: cb.hz ? cb.dr.height : cb.len
        // The outer edge's coordinate along the axis, and the two sides' across it.
        readonly property real edgeAt: cb.head ? 0 : (cb.hz ? cb.dr.width : cb.dr.height)
        readonly property real sideAt: cb.piece === 3 ? (cb.hz ? cb.dr.height : cb.dr.width) : 0
        x: cb.piece === 0 ? cb.bx
         : cb.piece === 1 ? (cb.hz ? cb.edgeAt - cb.seal : cb.bx - cb.seal)
         : (cb.hz ? cb.bx : cb.sideAt - cb.seal)
        y: cb.piece === 0 ? cb.by
         : cb.piece === 1 ? (cb.hz ? cb.by - cb.seal : cb.edgeAt - cb.seal)
         : (cb.hz ? cb.sideAt - cb.seal : cb.by)
        width: cb.piece === 0 ? cb.bw : cb.piece === 1 ? (cb.hz ? 2 * cb.seal : cb.bw + 2 * cb.seal) : (cb.hz ? cb.bw : 2 * cb.seal)
        height: cb.piece === 0 ? cb.bh : cb.piece === 1 ? (cb.hz ? cb.bh + 2 * cb.seal : 2 * cb.seal) : (cb.hz ? 2 * cb.seal : cb.bh)
        opacity: cb.head ? cb.dr._headF : cb.dr._footF
        visible: cb.dr._cut && opacity > 0.001
        // Where this quad starts along the band's axis, from the band's own start.
        readonly property real along: cb.hz ? cb.x - cb.bx : cb.y - cb.by
        property real boxW: cb.width
        property real boxH: cb.height
        property color c0: cb.head ? cb.dr.ground : "transparent"
        property color c1: cb.head ? "transparent" : cb.dr.ground
        property real horizontal: cb.hz ? 1 : 0
        property real rampFrom: (cb.head ? cb.dr.fadeLead : 0) - cb.along
        property real rampTo: (cb.head ? cb.len : cb.dr.fadeHeight) - cb.along
        property vector4d outline: cb.dr._cut ? Qt.vector4d(cb.dr.outline.x - cb.x, cb.dr.outline.y - cb.y, cb.dr.outline.w, cb.dr.outline.h) : Qt.vector4d(0, 0, 0, 0)
        property vector4d radii: cb.dr._cut ? Qt.vector4d(cb.dr.outline.radii[0], cb.dr.outline.radii[1], cb.dr.outline.radii[2], cb.dr.outline.radii[3]) : Qt.vector4d(0, 0, 0, 0)
        property color rampBase: cb.dr._ramped ? cb.dr.surfaceRamp.base : "transparent"
        property vector4d rampSides: cb.dr._ramped ? Qt.vector4d(cb.dr.surfaceRamp.sides[0], cb.dr.surfaceRamp.sides[1], cb.dr.surfaceRamp.sides[2], cb.dr.surfaceRamp.sides[3]) : Qt.vector4d(0, 0, 0, 0)
        property real rampReach: cb.dr._ramped ? cb.dr.surfaceRamp.reach : 0
        // A literal, resolved against this file, so it is set when the object is made. A Qt.resolvedUrl binding can land after the
        // effect has loaded its shaders in a content still being built, and an empty shader is Qt's built-in one, which samples
        // `source`: "ShaderEffect: 'source' does not have a matching property" in the log (the binding then loads the real one).
        fragmentShader: "shaders/fade_band.frag.qsb"
    }
    CutBand {
        objectName: "scrollFadeHeadCut"
        head: true
        piece: 0
        dr: dressing
    }
    CutBand {
        objectName: "scrollFadeFootCut"
        head: false
        piece: 0
        dr: dressing
    }
    Repeater {
        // Only a dressing with an outline has them (the plain bands seal with Rectangles, above).
        model: dressing._cut ? [[true, 1], [true, 2], [true, 3], [false, 1], [false, 2], [false, 3]] : []
        delegate: CutBand {
            required property var modelData
            head: modelData[0]
            piece: modelData[1]
            dr: dressing
        }
    }

    // ---- The wheel --------------------------------------------------------
    // This reader sits on THIS ITEM, which is anchored OVER the box, so it
    // takes every wheel before anything nested in the content sees it
    // (a sideways swipe over the stocks detail's range chips would scroll the
    // body). A host whose content reads wheels of its own
    // sets `wheelEnabled: false` and gives the box ONE reader that offers each
    // event to the nested control first, then hands it to `wheel(ev)`
    // (modules/stocks/StockDetail.qml). A MouseArea that takes no button and no
    // hover, not a WheelHandler: a WheelHandler never hears a purely sideways
    // event (CLAUDE.md), and a coast starts from the lift event, which every
    // reader must see. A two-finger SWIPE across a surface is a gesture, not
    // this (docs/contracts/gestures.md).
    WheelArea {
        anchors.fill: parent
        enabled: dressing.wheelEnabled && dressing.flick !== null
        turned: wheel => {
            // a click of a side button moves no box: whoever steps back and on under this one has it
            if (wheel.click) {
                wheel.accepted = false;
                return;
            }
            dressing.wheel(wheel);
            wheel.accepted = true;
        }
    }
}
