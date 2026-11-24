pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/glyphs"
import "../../common/particles"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../../common/scroll"

// =============================================================================
// IconReelView.qml -- a clipped window onto an IconReel.
//
// The ring is drawn in two places at once: the bar's own cell, and thePopup
// hanging out of it. Both are this, on the same `IconReel`, showing different
// slices of the axis -- so an icon sliding into the bar leaves one view and
// enters the other at the same coordinate and the join is invisible.
//
//   bar cell : aFrom 0,             the view is the module's slot in the bar
//   popup    : aFrom style.barCell, the view fills the popup's content
//
// `a` is the distance from the bar's OUTER edge inward. `edge` says which way
// that runs on screen. INSIDE A GooeyBar THE LOCAL FRAME IS ALWAYS TOP-LIKE
// (x along the bar, y inward) whatever edge the bar is on, because the bar
// item itself is rotated -- so a bar-cell view passes edge "top" and gives its
// glyphs the counter-rotation instead, to keep them upright on screen. A popup
// view is in the engine's own unrotated frame and passes the real edge.
//
// Fog is per end and they are not the same thing:
//   fogFar   permanent -- the last icon dissolves into it rather than ending,
//            and it is why a rectangular clip is invisible inside the popup's
//            round end: nothing reaches the corner still opaque.
//   fogNear  only while the reel is turning (`reel.motion`), because at rest
//            the icon in the bar has to be exact.
// =============================================================================
Item {
    id: view

    // Device px per design px here (the nearest ScaleRoot's, else the window's): what `renderScale` is unless a host hands one.
    DeviceScale {
        id: dev
    }

    property IconReel reel: null
    // Which way `a` runs on screen: "top" and "left" grow with the
    // coordinate, "bottom" and "right" against it.
    property string edge: "top"
    // The `a` this view's near edge sits at.
    property real aFrom: 0
    // Counter-rotation for the glyphs, when the view is inside a rotated bar.
    property real glyphRotation: 0
    property real fogNear: 0
    property real fogFar: 0
    // The corner radius of the far end. THE FOG IS OPAQUE, and the popup's
    // content is clipped to a RECTANGLE while the popup itself ends in a
    // curve -- so a square fog band paints the shell's surface into the two
    // corners the shape leaves out, and the half-round end comes out cut
    // square. The fog carries the same radius, so it stops where the shape
    // does.
    property real farRadius: 0
    // The radius the CUT uses, which is not always the one the fog uses: the
    // engine's surface tension inflates the popup's free corner while it
    // opens, closes and travels, so a cut at the resting radius would sit
    // outside the paint for the whole of every animation. The host feeds it
    // `GooeyEngine.popupRadius`, that inflated free-corner radius on this
    // frame (the engine cuts the popup's own content to the same outline
    // with its clip shader while it moves; this view cuts its captured
    // strip itself, since a captured item receives no input). Defaults to
    // farRadius for a host that has nothing better to offer.
    property real cutRadius: view.farRadius
    // How far short of the far tip the fog must already be solid -- see Fog.
    property real fogClearance: 0
    // How far INSIDE the popup's outline the cut falls. Tolerance, on purpose:
    // better to end an icon a shade early than a shade late, since the fog has
    // all but taken it by the time it is near the outline.
    property real maskInset: 1
    // The scale this view is finally drawn at. The rounded cut is a shader
    // over a captured texture, and a texture is made at a size: without this
    // a magnified stage would show the strip's icons at the size the texture
    // was made while the bar's, which are not captured, stayed sharp. FOUND by default (DeviceScale: the shell's frame is a ScaleRoot, and
    // no host above a reel has to hand the number down); a host that knows better (a mockup's zoom) hands one.
    property real renderScale: dev.value
    // Paint the shell's own ground behind the icons, the far end rounded like the fog's. A strip hung from its cell over a popup
    // (GooeyEngine: THE REEL SLOT) would otherwise show that popup's content between its icons; the bar's cell and a strip that
    // is alone on the surface paint nothing.
    property bool opaque: false
    // Only one view of a ring draws its sparks, or every turn throws them twice.
    property bool sparks: false
    // Whether the strip runs vertically ON SCREEN. Normally that is `vertical`
    // -- but a view inside a GooeyBar is drawn in the bar's own rotated frame,
    // so a module on a LEFT bar has a top-like view that is horizontal on
    // screen. A wheel event's deltas are in the device's axes and are NOT
    // rotated with the item, so the axis the gesture arrives on is the screen
    // one, not the layout one.
    property bool screenVertical: view.vertical

    readonly property alias hovered: hoverArea.hovered
    // THE POINTER ARRIVED: an entry, then a motion of at least a window px after it (GlyphFlourish's rule for every bar glyph's hover
    // flourish). A view that comes up under a resting pointer, and the hover Qt re-delivers to a resting one, are not the user arriving.
    // Once per entry; a wheel spends it (the user is already here, turning the ring, and what the turn brings in plays as it arrives).
    signal pointerArrived()
    property bool _entryArmed: false
    property point _entryAt: Qt.point(0, 0)
    // THE POINTER CAME ONTO AN ICON (the strip's hover flourish, feedback/reel.md "Flourish on hover": every icon in the open strip shows
    // it can be clicked, with the motion it already has). GlyphFlourish's rule, per icon: an icon becomes the pointer's by an entry -- the
    // pointer coming into the view, or the ring turning an icon under it (a wheel, a swipe, a travel) -- and the pointer's FIRST MOTION
    // over it says the user is there. `_pointedAt` is the icon the last motion was over; -2 after an entry or a turn, so whatever the
    // next motion is over plays; a motion over the same icon as the one before plays nothing. A MOTION moved the pointer (Qt re-delivers
    // a resting pointer's hover every frame, and a ring turning under it would otherwise play every icon it brings).
    signal pointerOnIcon(int index)
    property int _pointedAt: -2
    property point _lastPointer: Qt.point(-1e9, -1e9)
    Connections {
        target: view.reel
        function onReelAtChanged(): void {
            view._pointedAt = -2;
        }
    }
    readonly property IconReelStyle style: view.reel ? view.reel.style : null

    clip: true

    readonly property bool vertical: view.edge === "top" || view.edge === "bottom"
    readonly property bool fromStart: view.edge === "top" || view.edge === "left"
    readonly property real viewLen: view.vertical ? view.height : view.width
    readonly property real across: view.vertical ? view.width : view.height
    readonly property real aTo: view.aFrom + view.viewLen

    // A span [a0, a0+len] of the axis, in this view's own coordinates.
    function coordFor(a0, len) {
        return view.fromStart ? a0 - view.aFrom
                              : view.viewLen - (a0 - view.aFrom) - len;
    }

    // =====================================================================
    //  INPUT
    //
    // A HoverHandler for the hover (the cells own the clicks, and an item on
    // top of them would take their hover away), and a MouseArea -- NOT a
    // WheelHandler -- for the wheel.
    //
    // Two reasons:
    //   * A WheelHandler has an `orientation`, and it DEFAULTS TO VERTICAL.
    //     A two-finger horizontal swipe arrives as a horizontal wheel and a
    //     vertical handler never sees it at all, so a horizontal reel could
    //     not be swiped by it.
    //   * A WheelHandler is shadowed by any scrolling handler deeper in the
    //     scene, so TabSelector would not work inside a popup full of lists.
    // The MouseArea takes no buttons and never accepts the event, so it only
    // observes: the cells keep their clicks and the wheel still reaches
    // whatever is behind. docs/contracts/gestures.md has the whole rule.
    // =====================================================================
    HoverHandler {
        id: hoverArea
    }

    // ONE hit target for the whole view, not one per icon: the icons are
    // captured into a texture so the end can be cut to the popup's curve, and
    // a captured item receives no input. Which icon is under the pointer is
    // arithmetic the ring already knows how to do.
    MouseArea {
        id: pick
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: pick.hoveredIndex >= 0 ? Qt.PointingHandCursor : Qt.ArrowCursor

        readonly property real pointerA: {
            const along = view.vertical ? pick.mouseY : pick.mouseX;
            return view.aFrom + (view.fromStart ? along : view.viewLen - along);
        }
        readonly property int hoveredIndex: (view.reel && pick.containsMouse)
            ? view.reel.indexAt(pick.pointerA) : -1

        onPressedChanged: {
            if (!view.reel)
                return;
            if (pick.pressed)
                view.reel.pressedIndex = pick.hoveredIndex;
            else if (view.reel.pressedIndex === pick.hoveredIndex)
                view.reel.pressedIndex = -1;
        }
        onExited: {
            if (view.reel)
                view.reel.pressedIndex = -1;
        }
        onContainsMouseChanged: {
            view._entryArmed = pick.containsMouse;
            view._pointedAt = -2;
            if (pick.containsMouse) {
                view._entryAt = pick.mapToItem(null, pick.mouseX, pick.mouseY);
                view._lastPointer = view._entryAt;
            }
        }
        onPositionChanged: mouse => {
            const p = pick.mapToItem(null, mouse.x, mouse.y);
            const moved = Math.abs(p.x - view._lastPointer.x) + Math.abs(p.y - view._lastPointer.y) >= 1;
            view._lastPointer = p;
            const i = moved && view.reel ? view.reel.indexAt(pick.pointerA) : view._pointedAt;
            if (i !== view._pointedAt) {
                view._pointedAt = i;
                if (i >= 0)
                    view.pointerOnIcon(i);
            }
            if (!view._entryArmed)
                return;
            if (Math.abs(p.x - view._entryAt.x) + Math.abs(p.y - view._entryAt.y) < 1)
                return;
            view._entryArmed = false;
            view.pointerArrived();
        }
        onClicked: mouse => {
            if (!view.reel)
                return;
            const i = pick.hoveredIndex;
            if (i < 0)
                return;
            // a ring with a floor refuses plain input under it and takes Ctrl past it (the user's way past an automatic mode); it
            // travels by itself deaf to all
            const ctrl = (mouse.modifiers & Qt.ControlModifier) !== 0;
            if (view.reel.traveling)
                return;
            view.reel.inputCtrl = ctrl;
            view.reel.lastInputOverride = view.reel.floorActive && ctrl;
            if (i === view.reel.selectedIndex) {
                if (mouse.button === Qt.RightButton || view.reel.leftClickActivates)
                    view.reel.activate();
                return;
            }
            if (mouse.button === Qt.LeftButton)
                view.reel.step(Math.round(view.reel.slotOf(i)));
        }
    }

    WheelArea {
        anchors.fill: parent
        turned: wheel => {
            view._entryArmed = false;
            if (!view.reel || !view.style)
                return;
            wheel.accepted = false;
            const ctrl = (wheel.modifiers & Qt.ControlModifier) !== 0;
            if (view.reel.traveling)
                return;
            view.reel.inputCtrl = ctrl;
            view.reel.lastInputOverride = view.reel.floorActive && ctrl;
            // A MOUSE: one notch is one icon, whichever way the strip lies and however fast they come.
            if (wheel.device === "wheel") {
                view.reel.notch(wheel.steps);
                return;
            }
            // The strip's own axis first; the other one as a fallback.
            const aMain = view.screenVertical ? wheel.angleDelta.y : wheel.angleDelta.x;
            const aAlt = view.screenVertical ? wheel.angleDelta.x : wheel.angleDelta.y;
            const pMain = view.screenVertical ? wheel.pixelDelta.y : wheel.pixelDelta.x;
            const pAlt = view.screenVertical ? wheel.pixelDelta.x : wheel.pixelDelta.y;
            const a = aMain !== 0 ? aMain : aAlt;
            const p = pMain !== 0 ? pMain : pAlt;
            // Angle where there is one, pixels scaled where there is not.
            const raw = a !== 0 ? a : p * 2.5;
            // Scroll down, or right, is the next item -- the list convention,
            // and power.md's "one icon down". The same movement of the hand
            // does the same thing whether the strip hangs down, rises, or
            // lies across, which is what the module asks for when it says the
            // horizontal gesture must match the feel of the vertical one.
            view.reel.applySwipe(-raw);
        }
    }

    function scenePoint(a, cross) {
        const along = view.coordFor(a, 0);
        return view.vertical ? Qt.point(view.across / 2 + cross, along)
                             : Qt.point(along, view.across / 2 + cross);
    }

    function spark(dir) {
        const st = view.style;
        if (!st || !st.particlesEnabled || view.viewLen < 2)
            return;
        // Positive `dir` turns the ring toward the bar, so the sparks are
        // thrown the other way along the axis.
        const sign = (view.fromStart ? -1 : 1) * (dir > 0 ? 1 : -1);
        const tone = Theme.textFaint;
        for (let i = 0; i < st.particleCount; i++) {
            const p = view.scenePoint(view.aFrom + Math.random() * view.viewLen,
                                      (Math.random() - 0.5) * view.across * 0.55);
            const v = st.particleSpeed * (0.7 + Math.random() * 0.6) * sign;
            sparkField.emit({
                x: p.x,
                y: p.y,
                vx: view.vertical ? (Math.random() - 0.5) * st.particleScatter : v,
                vy: view.vertical ? v : (Math.random() - 0.5) * st.particleScatter,
                lifetime: st.particleLifetimeMs * (0.7 + Math.random() * 0.6),
                maxHistory: 4,
                sizeStart: st.particleSizeStart,
                sizeEnd: st.particleSizeEnd,
                colorStart: tone.toString(),
                colorEnd: Qt.rgba(tone.r, tone.g, tone.b, 0).toString(),
                drag: st.particleDrag,
                deathFadeFraction: 0.4
            }, 1);
        }
    }

    function burst() {
        const st = view.style;
        if (!st || !st.particlesEnabled || !view.reel)
            return;
        const tone = view.reel.tintOf(view.reel.selectedItem);
        const p = view.scenePoint(view.aFrom, 0);
        for (let i = 0; i < st.burstCount; i++) {
            const ang = Math.random() * Math.PI * 2;
            const s = st.burstSpeed * (0.5 + Math.random());
            sparkField.emit({
                x: p.x,
                y: p.y,
                vx: Math.cos(ang) * s,
                vy: Math.sin(ang) * s,
                lifetime: st.particleLifetimeMs,
                maxHistory: 3,
                sizeStart: st.particleSizeStart,
                sizeEnd: st.particleSizeEnd,
                colorStart: tone.toString(),
                colorEnd: Qt.rgba(tone.r, tone.g, tone.b, 0).toString(),
                drag: st.particleDrag * 1.6,
                deathFadeFraction: 0.45
            }, 1);
        }
    }

    // =====================================================================
    //  THE ROUNDED END
    //
    // `clip` is a RECTANGLE and the popup ends in a curve, so everything this
    // view draws is captured and cut to the popup's own outline by
    // shaders/reel_cap.frag. A shader because Qt's own masking does not take
    // here: MultiEffect's `maskSource` and OpacityMask both leave the mask
    // out silently, while a colourisation on the same effect applies.
    //
    // Only where there is a radius to honour. The bar's own cell has none, so
    // it is never captured and pays nothing.
    // =====================================================================
    // Not before the view has a size and a frame has gone by: a texture is
    // uninitialised until something has been drawn into it, and this view is
    // created fresh every time thePopup opens or travels to another module.
    // Until then the content draws straight, clipped to the rectangle -- one
    // frame of a square corner rather than one frame of whatever was in that
    // memory.
    property bool texReady: false
    readonly property bool cutToShape: view.farRadius > 0 && view.width > 1
        && view.height > 1 && view.texReady
    Component.onCompleted: Qt.callLater(() => view.texReady = true)

    ShaderEffectSource {
        id: contentTex
        anchors.fill: parent
        sourceItem: content
        hideSource: view.cutToShape
        live: true
        visible: false
        smooth: true
        textureSize: Qt.size(Math.max(1, Math.ceil(view.width * view.renderScale)),
                             Math.max(1, Math.ceil(view.height * view.renderScale)))
    }

    ShaderEffect {
        anchors.fill: parent
        visible: view.cutToShape
        fragmentShader: "../../common/components/shaders/reel_cap.frag.qsb"

        property variant source: contentTex
        property real boxW: view.width
        property real boxH: view.height
        // ONE DEVICE PIXEL, in the item's own units. This shader measures in
        // those while the texture is renderScale times denser, so a device
        // pixel is 1/renderScale of them -- passing renderScale itself would put
        // several device pixels of feather OUTSIDE the outline and spill ink
        // over it.
        property real aa: 1.0 / Math.max(0.25, view.renderScale)
        property real inset: view.maskInset
        // The edge where the strip meets its bar is exempt: there is no
        // outline to protect there -- the bar covers it -- and an inset
        // applied to it eats a pixel of every icon crossing the join, which
        // is a white line cut through the icon. The box is grown past that
        // edge so the cut never reaches it; the item's own clip still does.
        property vector4d pad: {
            const g = Math.max(view.width, view.height);
            return Qt.vector4d(view.edge === "left" ? g : 0,
                               view.edge === "top" ? g : 0,
                               view.edge === "right" ? g : 0,
                               view.edge === "bottom" ? g : 0);
        }
        property vector4d radii: Qt.vector4d(
            (view.edge === "bottom" || view.edge === "right") ? view.cutRadius : 0,
            (view.edge === "bottom" || view.edge === "left") ? view.cutRadius : 0,
            (view.edge === "top" || view.edge === "left") ? view.cutRadius : 0,
            (view.edge === "top" || view.edge === "right") ? view.cutRadius : 0)
    }

    Item {
        id: content
        anchors.fill: parent

    Rectangle {
        id: ground
        anchors.fill: parent
        visible: view.opaque
        color: Theme.surface
        readonly property real r: Math.min(view.farRadius, view.across / 2)
        topLeftRadius: (view.edge === "bottom" || view.edge === "right") ? ground.r : 0
        topRightRadius: (view.edge === "bottom" || view.edge === "left") ? ground.r : 0
        bottomRightRadius: (view.edge === "top" || view.edge === "left") ? ground.r : 0
        bottomLeftRadius: (view.edge === "top" || view.edge === "right") ? ground.r : 0
    }

    // =====================================================================
    //  THE ICONS
    // =====================================================================
    Repeater {
        model: view.reel ? view.reel.items : []

        delegate: Item {
            id: cell
            required property int index
            required property var modelData

            readonly property real a: view.reel ? view.reel.aOf(cell.index) : 0
            readonly property real cellLen: view.style ? view.style.cellPitch : 36
            readonly property bool isSelected: view.reel && cell.index === view.reel.selectedIndex

            // Outside the view by more than a cell it cannot be seen, and a
            // bar cell shows one icon out of five.
            visible: cell.a > view.aFrom - cell.cellLen && cell.a < view.aTo + cell.cellLen

            width: view.vertical ? view.across : cell.cellLen
            height: view.vertical ? cell.cellLen : view.across
            x: view.vertical ? 0 : view.coordFor(cell.a - cell.cellLen / 2, cell.cellLen)
            y: view.vertical ? view.coordFor(cell.a - cell.cellLen / 2, cell.cellLen) : 0

            // THE HIGHLIGHT BELONGS TO THE ITEM, NOT TO THE DELEGATE. The ring
            // is drawn by two views and the same icon has a delegate in each; a
            // hover that lived on the delegate would light the bar's copy and not the
            // popup's, so an icon sliding across the seam would be cut in half by
            // its own colour. Both delegates read the same two facts -- is this
            // the icon in the bar, and is the pointer on the bar's cell -- so
            // they are always the same colour, and when the ring turns the icon
            // leaving FADES its highlight out on the bar's one hover clock while it slides
            // instead of dropping it at the seam.
            //
            // Fractions mixed into themed colours with Mix.js, never a Behavior
            // on the colour itself: that would also catch the theme's own
            // crossfade and arrive a beat behind everything else.
            // ... and while something else holds the ring (an automatic idle mode): the colour stays, the mark that it was automatic
            property real hoverF: (cell.isSelected && view.reel && (view.reel.pointerOnBarCell || view.reel.open || view.reel.autoHeld)) ? 1 : 0
            Behavior on hoverF {
                GlyphHoverEase {}
            }
            property real pressF: (view.reel && view.reel.pressedIndex === cell.index) ? 1 : 0
            Behavior on pressF {
                NumberAnimation {
                    duration: view.style ? view.style.pressMs : 90
                    easing.type: Easing.OutCubic
                }
            }

            readonly property color tint: view.reel ? view.reel.tintOf(cell.modelData) : Theme.accent
            // At rest: the one in the bar is the primary ink, the rest are
            // faint. Position already says which is selected, so it does not
            // also get a hue. Colour is the affordance and arrives with the
            // pointer -- the accent on one that would only be selected, the
            // item's OWN colour on the one that can actually be fired.
            readonly property color restInk: cell.isSelected ? Theme.textMuted : Theme.textFaint
            // ONLY THE ACTIONABLE ONE LIGHTS UP. A hanging icon that took
            // the accent on hover would be lit in the view under the pointer only, so an icon
            // crossing the seam would change colour half way. The pointer already
            // says the icon is a target -- the hand cursor is on every cell.
            readonly property color hoverInk: cell.isSelected ? cell.tint : cell.restInk
            readonly property real fireF: cell.isSelected && view.reel
                ? Math.max(cell.pressF, view.reel.flash) : cell.pressF
            readonly property color ink: Mix.c3(cell.restInk, cell.hoverInk, cell.hoverF, cell.tint, cell.fireF)

            // THE GLYPH'S OWN FRAME: the counter-rotation of a rotated bar, so what is inside is upright on the screen -- the
            // Text, and the flourish that moves it (the reel's flourish set) in the screen's own axes. CENTRED BY HAND,
            // not by `anchors.centerIn`. The anchor ROUNDS the centring offset to a whole pixel, and the two views of one ring are
            // in different frames -- the bar's cell is inside a rotated bar, the popup is not -- so the same icon would be rounded
            // in one and not the other. Half a pixel of disagreement, in a seam whose whole job is to be invisible.
            Item {
                id: upright
                // the refusal's shake (IconReel.refuse) moves the selected icon across the strip
                x: (cell.width - width) / 2 + (cell.isSelected && view.reel && view.vertical ? view.reel.shakeX : 0)
                y: (cell.height - height) / 2 + (cell.isSelected && view.reel && !view.vertical ? view.reel.shakeX : 0)
                width: glyph.implicitWidth
                height: glyph.implicitHeight
                rotation: view.glyphRotation

                readonly property string itemId: cell.modelData && cell.modelData.id ? cell.modelData.id : ""
                // THE POSE (ReelFlourish.js): what the item's flourish set draws for it now -- the Text's turn, scale and shade, and the
                // layers drawn instead of it or over it. The view knows no item by name: a reel without flourishes draws its Text.
                readonly property var fset: view.reel ? view.reel.flourishes : null
                // the logout arrow is cut 2 px short of the cell's edge on the screen
                readonly property real reach: (Math.abs(view.glyphRotation % 180) === 90 ? cell.height : cell.width) / 2 - 2
                readonly property var pose: upright.fset ? upright.fset.poseOf(upright.itemId, glyph.font.pixelSize, glyph.baselineOffset, upright.reach) : null

                Text {
                    id: glyph
                    // Named so a probe can find every glyph in the scene and
                    // watch where it actually is, frame by frame.
                    objectName: "reelGlyph"
                    visible: !upright.pose || upright.pose.text
                    text: cell.modelData && cell.modelData.glyph ? cell.modelData.glyph : "?"
                    color: upright.pose && upright.pose.shade > 0 ? Mix.c(cell.ink, Theme.textFaint, upright.pose.shade) : cell.ink
                    font.family: view.style ? view.style.iconFamily : "Symbols Nerd Font"
                    font.pixelSize: view.style ? view.style.iconPixelSize : 21
                    // the pose's turn and its scale across (identity at rest)
                    transform: [
                        Rotation {
                            origin.x: upright.pose ? upright.pose.ox : 0
                            origin.y: upright.pose ? upright.pose.oy : 0
                            angle: upright.pose ? upright.pose.angle : 0
                        },
                        Scale {
                            origin.x: upright.pose ? upright.pose.sx : 0
                            xScale: upright.pose ? upright.pose.xScale : 1
                        }
                    ]
                }
                ReelGlyphArt {
                    layers: upright.pose ? upright.pose.layers : []
                    ink: cell.ink
                    ground: Theme.surface
                    faint: Theme.textFaint
                }
            }
        }
    }

    // =====================================================================
    //  SPARKS
    // =====================================================================
    // A turn throws a few off the way it is going; firing throws a small
    // radial burst in the item's own colour. They live inside the clip and
    // under the fog, so they dissolve where the icons do.
    ParticleSystem {
        id: sparkField
        anchors.fill: parent
        maxParticles: 96
        running: view.sparks && !!view.style && view.style.particlesEnabled
    }

    Connections {
        target: view.sparks ? view.reel : null
        function onSparked(dir) {
            if (dir === 0)
                view.burst();
            else
                view.spark(dir);
        }
    }

    // `a` and a sideways offset -> this view's own coordinates.

    // =====================================================================
    //  FOG
    // =====================================================================
    // Alpha-matched to the ground rather than ramped to "transparent", which
    // would tint the band grey.
    component Fog: Rectangle {
        id: fog
        // How long the FADE is. Not necessarily how long the band is.
        property real fade: 0
        // How far short of the tip the fade must already be SOLID. This is
        // what replaces a shaped clip: `clip` is a rectangle and the popup ends
        // in a curve, so an icon still visible where the shape has curved in
        // peeks out of it. It only can in the last few pixels -- the strip is
        // 40 across and a glyph 32 at its widest, so the outline is narrower
        // than the glyph only within about 8 px of the tip -- so the fog is
        // simply asked to have finished by then, and there is nothing left to
        // cut. No mask, no layer, and the icons stay at the resolution the
        // whole bar is drawn at.
        property real clearance: 0
        // true: opaque at the view's FAR end. false: at its near end.
        property bool atFar: true
        readonly property color ground: Theme.surface
        // Alpha-matched to the ground rather than ramped to "transparent",
        // which would tint the band grey.
        readonly property color clear: Qt.rgba(fog.ground.r, fog.ground.g, fog.ground.b, 0)
        readonly property color mid: Qt.rgba(fog.ground.r, fog.ground.g, fog.ground.b, 0.6)
        // The corner radius at the far end -- the popup's own, never more
        // than half the strip.
        readonly property real r: fog.atFar ? Math.min(view.farRadius, view.across / 2) : 0
        // THE BAND IS AT LEAST TWO RADII LONG. Qt clamps a rectangle's corner
        // radii to half its SHORTEST side, so a 30-long band asking for
        // 20-radius corners is drawn with 15 -- squarer than the popup's own
        // cap. The corners of an OPAQUE band then stand outside the shape,
        // and against the desktop that reads as the fade having less rounding
        // than the popup, which is exactly what it is. So the band is grown
        // to fit its radius and the gradient is placed inside it, which keeps
        // the fade the length it was asked for.
        readonly property real len: Math.max(fog.fade + fog.clearance, 2 * fog.r)
        // Measured from the SOLID end, as fractions of the band: solid for
        // `c`, then fading over `f`, then clear.
        readonly property real c: fog.len > 0 ? Math.min(1, fog.clearance / fog.len) : 0
        readonly property real f: fog.len > 0 ? Math.max(0, Math.min(1 - fog.c, fog.fade / fog.len)) : 0
        readonly property real a0: fog.atFar ? view.aTo - fog.len : view.aFrom
        // Which end of the gradient is the solid one, once the axis' own
        // direction has been folded in.
        readonly property bool solidAtZero: fog.atFar !== view.fromStart

        topLeftRadius: (view.edge === "bottom" || view.edge === "right") ? fog.r : 0
        topRightRadius: (view.edge === "bottom" || view.edge === "left") ? fog.r : 0
        bottomRightRadius: (view.edge === "top" || view.edge === "left") ? fog.r : 0
        bottomLeftRadius: (view.edge === "top" || view.edge === "right") ? fog.r : 0

        visible: fog.fade > 0.5 && fog.opacity > 0.01
        x: view.vertical ? 0 : view.coordFor(fog.a0, fog.len)
        y: view.vertical ? view.coordFor(fog.a0, fog.len) : 0
        width: view.vertical ? view.across : fog.len
        height: view.vertical ? fog.len : view.across

        gradient: Gradient {
            orientation: view.vertical ? Gradient.Vertical : Gradient.Horizontal
            // Four stops, and their POSITIONS ALWAYS INCREASE: a Gradient
            // ignores a list that does not. So the direction is carried by
            // which stop gets which colour, not by mirroring the numbers.
            // Written any other way the near band comes out upside down --
            // opaque a third of the way into the bar and clear at the very
            // edge, which is the opposite of what a band hiding icons LEAVING
            // through that edge is for.
            GradientStop {
                position: fog.solidAtZero ? 0 : 1 - (fog.c + fog.f)
                color: fog.solidAtZero ? fog.ground : fog.clear
            }
            GradientStop {
                position: fog.solidAtZero ? fog.c : 1 - (fog.c + 0.45 * fog.f)
                color: fog.solidAtZero ? fog.ground : fog.mid
            }
            GradientStop {
                position: fog.solidAtZero ? fog.c + 0.45 * fog.f : 1 - fog.c
                color: fog.solidAtZero ? fog.mid : fog.ground
            }
            GradientStop {
                position: fog.solidAtZero ? fog.c + fog.f : 1
                color: fog.solidAtZero ? fog.clear : fog.ground
            }
        }
    }

    Fog {
        fade: Math.min(view.fogFar, view.viewLen)
        clearance: view.fogClearance
        atFar: true
    }
    Fog {
        fade: Math.min(view.fogNear, view.viewLen)
        atFar: false
        opacity: view.reel ? view.reel.motion : 0
    }
    }
}
