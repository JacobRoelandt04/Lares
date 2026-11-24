pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"

// =============================================================================
// GooeyBody.qml -- one popup slot of the gooey engine.
//
// A slot is a box on ONE clock plus the content hosted in it. The engine owns
// the geometry (it reads `t`, works out the box, and writes popX/popY/popW/popH
// back); this owns time and content: the clock, the content Loader clipped to
// the box, and the content's fade.
//
// The engine has seven: two primaries (the one on screen, and the one closing
// in place when thePopup jumps to a bar it has no path to), one child (the
// secondary popup that grows out of a primary), the LANE (the notifications'
// toast stack, which comes and goes on its own beside thePopup), the OSD (a
// transient popup that dips into its bar and comes back with other content:
// GooeyEngine, THE OSD SLOT), the REEL (the power and idle reels' strip, which
// hangs from its cell whatever popup is out: GooeyEngine, THE REEL SLOT) and the
// FLOURISH (a free body its owner drives box by box: GooeyEngine, THE FLOURISH).
// The flourish's clock never runs: its box is the owner's.
//
// `t` is LINEAR 0..1; the easing is applied by the engine to the value, so a
// retarget restarts one number instead of three Behaviors disagreeing.
// =============================================================================
Item {
    id: body

    property var engine: null

    // ---- Identity -------------------------------------------------------
    property string ownerId: ""
    property string barId: ""
    // The side it hangs from (a primary: its bar's edge) or grows toward (a
    // child: "bottom" means it grows downward out of its parent's bottom).
    property string edge: "top"
    property bool isChild: false
    property var parentSlot: null
    // The lane (GooeyEngine: THE LANE): never the primary, never the spare,
    // no secondary.
    property bool isLane: false
    // The flourish (GooeyEngine: THE FLOURISH): no bar, no parent, no input.
    property bool isFlourish: false
    // The OSD (GooeyEngine: THE OSD SLOT): never the primary, never the spare, no
    // secondary, no gesture. `dipping`: its close is a DIP -- it folds into its bar
    // and comes back with the next request's content instead of leaving (phase
    // "closing" until the bottom, where the engine swaps and rises).
    property bool isOsd: false
    // The reel slot (GooeyEngine: THE REEL SLOT): a primary-class body of its own for the power and idle reels' strips -- never the
    // primary or the spare, no secondary -- that comes and goes beside or over whatever popup is out.
    property bool isReel: false
    // FLOATING (GooeyEngine: THE FLOATING POPUP): opened while its screen was fullscreen, this popup stands `floatF` x the engine's floatGap
    // off the face it hangs from, related to nothing (a free body: a pill), until the fullscreen window goes and it slides home.
    property bool floating: false
    property real floatF: 0
    // The popup this one opens after (GooeyEngine: NOTHING TRAVELS OVER A FULLSCREEN WINDOW): set, it is the primary with its content in and its clock not started.
    // A run asked for meanwhile (its content's first size) is no start: the release runs it.
    property Item openAfter: null
    // THE ATTRACTION LETS GO AT REST (GooeyGeometry.js, the void): 1 in motion, eased to 0 after a landing; `engine._attractRest` starts that.
    // Fresh opens start at 1, a move eases back to 1, a close keeps what it has: a shape that has let go does not flare on its way out.
    property real attractF: 1
    // The lane's: its close is a FOLD FOR A POPUP (a hop, or no room beside it): the popup has the right of way on every frame --
    // it is never cut to the folding stack's side, and the stack is cut to the popup's (GooeyEngine: THE LANE GIVES WAY).
    property bool hopFold: false
    property bool dipping: false
    // Which side of each other slot the OSD is kept on along its bar, fixed at each
    // placement and applied on every frame (Geo.laneClip): { slotA, slotB, child,
    // lane } -> +1 past that slot's high face, -1 before its low face, 0 not kept.
    // The ids of the bodies it melts with (those it lies flush against, same bar).
    property var yieldSides: ({})
    property var peerIds: []
    // How far the OSD pushed this primary along its bar (screen px, + is +x / +y),
    // engine-owned: added to the primary's rest place (_targetsOf, _restAt).
    property real osdYield: 0
    // Which side of the lane this slot is kept on along the lane's bar, fixed
    // at each lane placement and applied on every frame (Geo.laneClip): +1 past
    // the lane's high face, -1 before its low face, 0 not kept.
    property int laneSide: 0
    // The lane's: the box it rests at when nothing is in its way, and where the
    // last placement put it relative to what is (Geo.lanePlace `side`).
    property var homeBox: null
    property int placedSide: 0
    // The lane's: it hangs from the popup's FOOT (Geo.laneBelowPlace) instead of standing beside it, and the axis the others are
    // kept apart from it on (GooeyEngine._laneSides): across its bar while it hangs below a slot, along it otherwise ("" = along).
    property bool placedBelow: false
    property string laneAxis: ""

    // "closed" | "opening" | "open" | "moving" | "closing"
    property string phase: "closed"
    // Closing, but its clock has not started: a popup whose secondary is going
    // in first holds its box and its content until the engine releases it.
    property bool closeHeld: false
    // ...or whose owner holds it for a flourish (GooeyEngine.close({ hold })):
    // released only by releaseClose(). Cleared with closeHeld by run(), snap()
    // and stop(), never by hold().
    property bool flourishHold: false
    // That hold's content fade has started (the release lets it run on).
    property bool holdFaded: false
    // The close's own clock (GooeyEngine.close(opts): ms; easingIndex and
    // overshoot are the slot's as for every run).
    property int closeMs: 400
    // A child closes on the FORWARD close curve from `closeFrom` of its size,
    // instead of its open curve played backwards (which swells first and spends
    // most of the time near full size).
    property bool closeCurve: false
    property real closeFrom: 1
    readonly property bool live: body.phase === "opening" || body.phase === "open" || body.phase === "moving"
    // "moving" on a MIGRATION (to another module, along the bar or around the
    // corners), as against a resize or a shift of the same popup: a live resize
    // never takes over a journey. It holds until the popup lands, through any
    // re-target on the way (the destination's content sizing itself).
    property bool travelling: false
    // Between the fade-out and the swap of a content change: the content that
    // is loaded is the one leaving, so its `alongShift` is not the popup's.
    property bool swapping: false
    // While `swapping` on a travel: the size the DESTINATION's content is remembered to ask for ({ iw, ih }, its implicit
    // width and height), so the trip is aimed at the box it will rest in while the old content is still the one loaded
    // (GooeyEngine: THE OWNER'S SIZE MEMORY). null: aim with the content that is loaded.
    property var sizeHint: null
    // The `alongShift` the targets were last placed with, and the last
    // `hostRoom` handed to the content (GooeyEngine: "The live contract").
    property real placedShift: 0
    // Whether they were placed for a content that continues its bar cell
    // (GooeyEngine `continuesBarCell`: on its anchor, no wall, no bar's end).
    property bool placedPinned: false
    // How far THE WALL or THE BAR'S END moved the targets along the track
    // (GooeyEngine `_flushPlace`); held through a live resize until the
    // content places itself.
    property real wallShift: 0
    property var room: null
    property bool roomDirty: false

    // ---- What it was asked for -----------------------------------------
    // Along the edge and out of it; null follows the content's implicit size.
    property var askAlong: null
    property var askOut: null
    property real localCenter: 0
    // The fraction of the box's length (along the track) that sits at
    // localCenter: 0.5 centres it (every primary); the lane of a spot at a
    // bar's end takes 0 or 1 (GooeyEngine.openLane's alongAt).
    property real alongAt: 0.5
    // A child's: which point of it sits on its anchor along its parent's side
    // (0 its start, 1 its end), held still through a resize; the open grows out
    // of it (GooeyEngine: secondaryAnchorAt).
    property real anchorAt: 0.5
    // A child's: the point of it its open grows out of, and the least length
    // along its parent's side it opens at (GooeyEngine: secondaryOpenAt / OpenMin).
    property real openAt: 0.5
    property real openMin: 0
    property real widthFrom: 0.5
    property bool corner2D: false

    // ---- Motion (engine-written) -----------------------------------------
    property var fromBox: null
    property var toBox: null
    property var originBox: null
    property var move: null
    property int easingIndex: 3
    property real overshoot: 1.2
    property real t: 1

    // A child's second clock: sliding along its parent's edge.
    property real slideT: 1
    // Where the child is anchored in its parent's content, and the SPAN it is
    // drawing: { rel0 (from the parent's side), along, out, ins }. Everything
    // about where a child sits -- the anchor, its width, its inset -- moves on
    // the slide clock from `spanFrom` to the target, so nothing teleports when
    // the content asks for a different one.
    property real anchorOffset: 0
    property var spanFrom: null
    property var spanLast: null
    property bool overhang: false
    // How far a child reaches into its parent (px).
    property real inset: 0
    property var key: undefined

    // The box as drawn this frame, and the size it is heading for (screen
    // axes), which the engine's surface tension reads.
    property var box: null
    property real fullW: 0
    property real fullH: 0
    property real popX: 0
    property real popY: 0
    property real popW: 0
    property real popH: 0

    // THE REST FRAME (GooeyEngine): where the content is laid out inside the body. An open's OutBack carries the SURFACE
    // past the box it rests at; the content does not follow it there. `framing`: this slot's motion is an open (or a close
    // that began as one), whose rest box is `restBox` (screen px; a primary's is its last placement, a child's its span at
    // full extent). While the body reaches past that box, `framed` holds and the content's frame is the rest box cut to the
    // body (frameX/Y/W/H, the body's own px): the content keeps its final size and its final place on the screen, and the
    // surface overshoots around it. Otherwise the frame is the body itself, to the bit (the binding below reads the body).
    property bool framing: false
    property var restBox: null
    property bool framed: false
    property real frameX: 0
    property real frameY: 0
    property real frameW: 0
    property real frameH: 0

    // ---- Content ----------------------------------------------------------
    property Component component: null
    // A content the ENGINE built and handed over (adopt): hosted in the content frame instead of the Loader's own, and let go of
    // by release() (GooeyEngine: THE PARKED CONTENT). A primary's content is the engine's: it can be built before the click,
    // parked, and adopted by whichever body opens. null: the Loader's (a child, the lane, the OSD, the flourish).
    property Item adopted: null
    readonly property Item contentItem: body.adopted ? body.adopted : (loader.item as Item)
    // The owner whose content this body hosts (the component's owner while `ownerId` is already the destination's: a travel
    // configures the body before the new content replaces the old).
    property string contentOwner: ""
    property real contentOpacity: 0
    property var _afterFade: null

    // ---- The cut to the field's own outline --------------------------------
    // `clip` is a RECTANGLE and the field draws this body as a box whose every
    // corner is cut by an ellipse -- one that surface tension inflates to half
    // the popup while it opens, so the content would be drawn straight across the
    // curve and out onto the wallpaper. The engine writes the outline it just
    // handed the field here every layout, in THIS ITEM's pixels (a snapped face
    // can put the drawn box off it), and gooey_clip.frag cuts the content to it
    // with the same distance function the surface is drawn with.
    //
    // `clipOn` is the engine's answer to "is the outline anything but the
    // resting rounded rectangle": at rest it is off and there is no layer.
    property bool clipOn: false
    property vector4d clipBox: Qt.vector4d(0, 0, 0, 0)
    property vector4d clipEx: Qt.vector4d(0, 0, 0, 0)
    property vector4d clipEy: Qt.vector4d(0, 0, 0, 0)
    property vector4d clipIx: Qt.vector4d(0, 0, 0, 0)
    property vector4d clipIy: Qt.vector4d(0, 0, 0, 0)
    // Device px per px of THIS body (the frame's): the layers' grid falls back on it. (`engine.renderScale` is per CONTENT px.)
    readonly property real renderScale: body.engine ? body.engine.frameRenderScale : 1
    // FRAME units per CONTENT unit (GooeyEngine: THE RATIOS). The content is laid out in its own units inside `contentFrame` (a ScaleRoot
    // of this) and drawn `ratio` times larger: the bar's ratio for a primary whose content CONTINUES its bar cell (`continuesBarCell`:
    // the reel's strip, the tray's), the popup's for every other body. It is the ratio of the content that is LOADED -- the one leaving,
    // while a swap fades it out -- so a content is never rescaled under its own fade.
    readonly property real ratio: {
        const e = body.engine;
        if (!e)
            return 1;
        const it = body.contentItem;
        const bar = !body.isChild && !body.isLane && !body.isOsd && !body.isFlourish && !!it && it.continuesBarCell === true;
        return Math.max(0.01, bar ? e.barRatio : e.popupRatio * body.ownScale);
    }
    // THE POPUP'S OWN RATIO (shell.jsonc `scale.popups.<owner>`): the factor on the popups' ratio that THIS content's owner asks for -- its entry
    // over `popupRatio`, 1 when it has none and for every body that is not a popup's (the lane, the OSD, the reel, the flourish). The
    // ratio of the content that is LOADED, like `ratio`: a travel between two popups of different ratios swaps it with the content.
    // A child (a secondary, its own secondary, a level of the reel's chain) is its parent's owner's -- "silicon/secondary" is silicon's -- but
    // never takes its parent's RATIO: its own entry is "<owner>.detail", and with none it is the plain popup ratio (1 here).
    readonly property real ownScale: {
        const e = body.engine;
        if (!e || body.isLane || body.isOsd || body.isFlourish || body.isReel || !e.popupScales || !(e.popupRatio > 0))
            return 1;
        const id = String(body.contentOwner !== "" ? body.contentOwner : body.ownerId).split("/")[0];
        const v = e.popupScales[body.isChild ? id + ".detail" : id];
        return typeof v === "number" && v > 0 ? v / e.popupRatio : 1;
    }
    readonly property bool clipActive: body.clipOn && body.width > 1 && body.height > 1
    // Whether the cut is really a layer this frame, for the probe that
    // proves a layered content still receives its clicks.
    readonly property bool contentLayered: clipHost.layer.enabled
    // A second cut box (item px), gooey_clip.frag's `lim`: the engine sets it
    // where the flourish sinks into a bar's face (GooeyEngine.setFlourishCut).
    // Far outside the item by default: the cut is the outline's alone.
    property vector4d clipLim: Qt.vector4d(-1e6, -1e6, 1e6, 1e6)
    // A feather for the WHOLE outline (item px), 0 = one device pixel: the
    // flourish's clipFeather (GooeyEngine.openFlourish).
    property real clipFeather: 0

    // ---- The fade beside a fillet -----------------------------------------
    // Where the field goes on PAST an edge the fold moves, the moving edge cut
    // the content straight across over surface: a card, its icon, a line of
    // text ended on a line with surface running on beyond it. Past the FAR
    // edge that is the fillet a far corner joined into a perpendicular bar (or
    // a peer) melts on down it (the lane closing into its corner, and opening
    // out of it); past a SIDE edge a 2D fold moves, it is the S fillet into
    // the bar the body hangs from, and the neck into a popup it sits beside
    // (the lane closing sideways away from thePopup). Nothing is cut hard, so
    // while the body folds its content fades out toward those edges:
    // edge_fade, the particles' own mask, over `seamFade` px per edge. The
    // engine sets it every layout (_applyClip), on the fold's envelope --
    // nothing at either end of the fold, so rest is untouched and the layer
    // comes and goes at no fade.
    // Alpha, not a band of the ground's colour (SeamFade): a tinted body's
    // ground is poured across its joins, and the corner that needs the fade
    // is a join -- there is no one colour to paint there.
    //   seamFade   the fade's length now per edge, item px (x left, y top,
    //              z right, w bottom); 0 none
    property vector4d seamFade: Qt.vector4d(0, 0, 0, 0)
    // Which run of the clock this is (run, runTo, hold: one per fold), and
    // the run in which the engine last saw a far corner joined (-1 none): a
    // join seen once keeps its edge's fade for the rest of that fold.
    property int runSerial: 0
    property int seamJoinRun: -1
    readonly property bool seamActive: (body.seamFade.x > 0.01 || body.seamFade.y > 0.01 || body.seamFade.z > 0.01
                                        || body.seamFade.w > 0.01) && body.width > 1 && body.height > 1

    // ---- The layers' grid ---------------------------------------------------
    // A layer is ONE TEXTURE drawn over its item's rect, and it is drawn 1:1 -- no
    // resampling, no blur -- only when that rect lies on whole DEVICE pixels of the
    // window and the texture is exactly its size in them. The SIZE is made whole
    // (the mockup's zoom and a fractional height would leave a texture a pixel taller than
    // its item), but the icons would still go soft while the toast resizes, because the
    // body's own place is fractional: the lane stands at x 576 of a stage zoomed to
    // 0.8, which is device pixel 460.8, and any screen puts a body at some fractional
    // x or y. Placing the layer's rect on the grid means moving it -- and the content
    // may not move. So while a layer is on, the layered item sits at minus the
    // fraction of a device pixel the body's corner lies past the one before it, is as
    // large as covers that fraction and the body in WHOLE device pixels, and what is in
    // it is shifted back by the same: the content is drawn into the texture at the
    // fractional phase it has on the screen, which is the picture at rest, and the
    // texture itself lands on pixels. (Text and images drawn into the texture at that
    // phase are rasterised exactly as they are at rest, which `layer.enabled` toggling
    // on and off at no visible change relies on.) The offset exists only while a layer
    // does: at rest the content is at the body's origin.
    //
    // Measured, not declared: the device scale is the body's FULL scene transform (the
    // stage's zoom, whatever scales the host) times the screen's own density, and the
    // body's place in the window. mapToItem does not re-evaluate in a binding when an
    // ancestor moves, so it is sampled when the body moves and on the window's
    // afterAnimating (after this frame's animations, before it is synchronised) for as
    // long as a layer is on -- nothing is sampled at rest.
    //
    // THE GRID IS THE WINDOW'S. A grab of an ANCESTOR (`scene.grabToImage`) re-renders the
    // subtree on a grid of its own, whose origin is the ancestor's: a layered body whose
    // ancestor stands on a fractional window position (the mockup stage centres its scene
    // at y 211.5) lands half a pixel off that grab's grid and is resampled there -- a
    // picture no screen shows, while the window's own picture is exactly the direct one
    // (a clip layer forced off differs by 9 px of 6669, one level). A layered body is
    // judged in the window's picture (the strip beside a wall
    // keeps its layer at rest, and a scene grab reads it a pixel short).
    //   _sx/_sy   device px per item unit; _fx/_fy  the corner's fractional device px
    readonly property bool _gridded: body.clipActive || body.seamActive
    property real _sx: 1
    property real _sy: 1
    property real _fx: 0
    property real _fy: 0
    // In item units: how far left/up of the body the layered item starts.
    readonly property real _offX: body._gridded ? body._fx / body._sx : 0
    readonly property real _offY: body._gridded ? body._fy / body._sy : 0
    // The layered item's size, whole device pixels covering that offset and the body.
    // (1e-3: a product like 384 * 0.8 + 0.8 is 308.00000000000006 and must not cost a column.)
    readonly property int _texW: Math.max(1, Math.ceil(body.width * body._sx + body._fx - 1e-3))
    readonly property int _texH: Math.max(1, Math.ceil(body.height * body._sy + body._fy - 1e-3))
    function _remap() {
        const o = body.mapToItem(null, 0, 0);
        const u = body.mapToItem(null, 1, 1);
        // The WINDOW's pixel ratio, never the attached Screen's: at a fractional Hyprland scale (1.25, 1.5) the Screen answers the
        // integer wl_output scale, 2, and the layer's texture would come out a third too big and its grid off.
        const win = body.Window.window;
        const dpr = win && win.devicePixelRatio > 0 ? win.devicePixelRatio : 1;
        const kx = u.x - o.x;
        const ky = u.y - o.y;
        // A degenerate transform (no window yet): the host's own word for it (`renderScale` is device px per design px).
        body._sx = kx > 1e-4 ? kx * dpr : Math.max(0.25, body.renderScale);
        body._sy = ky > 1e-4 ? ky * dpr : Math.max(0.25, body.renderScale);
        const px = o.x * dpr;
        const py = o.y * dpr;
        const fx = px - Math.floor(px);
        const fy = py - Math.floor(py);
        // A corner within a thousandth of a pixel of the grid is on it.
        body._fx = fx < 1e-3 || fx > 1 - 1e-3 ? 0 : fx;
        body._fy = fy < 1e-3 || fy > 1 - 1e-3 ? 0 : fy;
    }
    on_GriddedChanged: if (body._gridded) body._remap()
    onXChanged: if (body._gridded) body._remap()
    onYChanged: if (body._gridded) body._remap()
    Connections {
        target: body._gridded ? body.Window.window : null
        function onAfterAnimating() {
            body._remap();
        }
    }

    // Build `component`'s content in the content frame, the way the Loader does: its parent is set before it completes, so its
    // Component.onCompleted sees the window and a visible frame (a content that takes the keyboard at its build does), and its size
    // is the frame's from its first moment -- an item with no size of its own FOLLOWS its implicit size, and a binding that reads
    // `height` and `implicitHeight` (the notifications manager's side fade) is notified twice by one change: a binding loop. Null
    // when it does not build; the caller adopts what it returns.
    function build(component, initial) {
        const props = { width: contentFrame.width, height: contentFrame.height };
        if (initial)
            for (const k in initial)
                props[k] = initial[k];
        return component.createObject(contentFrame, props);
    }

    // build()'s twin for the warm-up (GooeyEngine.prewarm): the same content in the same frame with the same size, INCUBATED (Qt
    // spreads its bindings and completion over the frames); the incubator is returned, its object adopted when it is Ready.
    function incubate(component, initial) {
        const props = { width: contentFrame.width, height: contentFrame.height };
        if (initial)
            for (const k in initial)
                props[k] = initial[k];
        return component.incubateObject(contentFrame, props, Qt.Asynchronous);
    }

    // { component, item }: the next content, built ahead of a journey (GooeyEngine).
    property var ahead: null
    // `component`'s content, in the frame but not seen yet: adopt() takes it from there.
    function buildAhead(component) {
        return component.createObject(aheadHost, { width: contentFrame.width, height: contentFrame.height });
    }

    // Host `item` (built by the engine) in the content frame, filling it as the Loader's content does. The caller sets `component`
    // and emits `loaded` once the body is complete: the Loader's `loaded` comes after both. Set `adopted` BEFORE `component`: with
    // an item adopted the Loader builds nothing.
    function adopt(item) {
        body.adopted = item;
        item.parent = contentFrame;
        item.anchors.fill = contentFrame;
        item.visible = !(body.engine && body.engine.hideContent);
    }

    // Let go of the adopted content (its anchors cleared, its size where it stands) and hand it back; null if there is none. The
    // component goes first: with no item adopted and a component still set the Loader would build the content again.
    function release() {
        const it = body.adopted;
        if (!it)
            return null;
        body.component = null;
        it.anchors.fill = undefined;
        body.adopted = null;
        return it;
    }

    signal finished
    signal slid
    signal loaded
    signal contractChanged
    signal implicitSizeChanged
    // The live contract's content-owned members changed (GooeyEngine).
    signal contentLiveResize
    signal contentLiveMask
    signal contentShift
    signal contentTint
    // The content's swipe-hold contract changed (the engine listens on the lane).
    signal contentGesture
    // The content's `maskCatchAll` changed (GooeyEngine: the void catcher).
    signal contentCatch

    x: body.popX
    y: body.popY
    width: Math.max(0, body.popW)
    height: Math.max(0, body.popH)
    clip: true
    // (A held open is kept visible at no size: its content takes the keyboard now, and what is typed in the wait is the new popup's.)
    visible: (body.popW > 0.5 && body.popH > 0.5) || body.openAfter !== null

    onTChanged: if (body.engine) body.engine.layout()
    onSlideTChanged: if (body.engine) body.engine.layout()

    // Run the clock from 0 to 1 over `ms`.
    function run(ms) {
        if (body.openAfter)
            return;
        clock.stop();
        body.runSerial++;
        body.closeHeld = false;
        body.flourishHold = false;
        body.t = 0;
        clock.from = 0;
        clock.to = 1;
        clock.duration = Math.max(1, ms);
        clock.start();
        if (body.engine)
            body.engine.kickBoost(clock.duration);
    }

    // Run the clock from where it is to `target`, over the share of `ms` the
    // distance is (a child closing from half open takes half as long).
    function runTo(target, ms) {
        clock.stop();
        body.runSerial++;
        clock.from = body.t;
        clock.to = target;
        clock.duration = Math.max(1, ms * Math.abs(target - body.t));
        clock.start();
        if (body.engine)
            body.engine.kickBoost(clock.duration);
    }

    // The clock at its end, now: the box is its target on this frame. Unlike
    // stop() the content's fade keeps running -- a live resize can begin while
    // the content is still fading in.
    function snap() {
        clock.stop();
        body.closeHeld = false;
        body.flourishHold = false;
        body.t = 1;
    }

    // Closing, with the clock held at the start: the box stays where it is.
    function hold() {
        clock.stop();
        body.runSerial++;
        body.closeHeld = true;
        body.t = 0;
    }

    function runSlide(ms) {
        slideClock.stop();
        body.slideT = 0;
        slideClock.duration = Math.max(1, ms);
        slideClock.start();
        if (body.engine)
            body.engine.kickBoost(slideClock.duration);
    }

    function stop() {
        clock.stop();
        body.closeHeld = false;
        body.flourishHold = false;
        body.holdFaded = false;
        slideClock.stop();
        fade.stop();
        body._afterFade = null;
        // A swap waits for its fade-out; with the fade gone it never happens.
        body.swapping = false;
    }

    function fadeTo(v, ms, then) {
        fade.stop();
        body._afterFade = then || null;
        if (Math.abs(body.contentOpacity - v) < 1e-4) {
            body.contentOpacity = v;
            body._runAfterFade();
            return;
        }
        fade.from = body.contentOpacity;
        fade.to = v;
        fade.duration = Math.max(1, ms);
        fade.start();
    }

    function _runAfterFade() {
        const f = body._afterFade;
        body._afterFade = null;
        if (f)
            f();
    }

    NumberAnimation {
        id: clock
        target: body
        property: "t"
        easing.type: Easing.Linear
        onFinished: body.finished()
    }

    NumberAnimation {
        id: floatClock
        target: body
        property: "floatF"
        easing.type: Easing.OutCubic
        onFinished: {
            if (body.floatF <= 0.0005) {
                body.floatF = 0;
                body.floating = false;
            }
        }
    }
    // The float's own clock: to `v` (1 floating, 0 home) over `ms`; `ms` 0 is at once.
    function floatTo(v, ms) {
        floatClock.stop();
        if (ms <= 0 || Math.abs(body.floatF - v) < 1e-4) {
            body.floatF = v;
            if (v <= 0)
                body.floating = false;
            return;
        }
        floatClock.from = body.floatF;
        floatClock.to = v;
        floatClock.duration = ms;
        floatClock.start();
    }
    onFloatFChanged: if (body.engine) body.engine.layout()

    SequentialAnimation {
        id: attractClock
        PauseAnimation {
            id: attractHold
        }
        NumberAnimation {
            id: attractEase
            target: body
            property: "attractF"
            easing.type: Easing.InOutSine
        }
    }
    // To `v` after `holdMs`, over `ms`; `ms` 0 is at once.
    function attractTo(v, holdMs, ms) {
        attractClock.stop();
        if (ms <= 0 || Math.abs(body.attractF - v) < 1e-4) {
            body.attractF = v;
            return;
        }
        attractHold.duration = holdMs;
        attractEase.from = body.attractF;
        attractEase.to = v;
        attractEase.duration = ms;
        attractClock.start();
    }
    onAttractFChanged: if (body.engine) body.engine.layout()
    onPhaseChanged: {
        if (!body.engine)
            return;
        if (body.phase === "opening" || body.phase === "closed")
            body.attractTo(1, 0, 0);
        else if (body.phase === "moving")
            body.attractTo(1, 0, body.engine.attractReturnMs);
        else if (body.phase === "closing")
            attractClock.stop();
        else
            body.engine._attractRest(body);
    }

    NumberAnimation {
        id: slideClock
        target: body
        property: "slideT"
        from: 0
        to: 1
        easing.type: Easing.Linear
        onFinished: body.slid()
    }

    NumberAnimation {
        id: fade
        target: body
        property: "contentOpacity"
        easing.type: Easing.Linear
        onFinished: body._runAfterFade()
    }

    // The content's two layers, the CUT OUTSIDE and the fade beside a fillet
    // inside it. The cut's mask is evaluated per pixel of the frame it is
    // drawn into, which is what makes it exact; a layer INSIDE another is
    // drawn into that one's texture and resampled when it is (at a fractional
    // position, at a size that is not whole), and a cut resampled that way
    // carries ink past the outline -- the fade's layer wrapped the cut in
    // session 6, and once the sides of every 2D fold fade, the tiles popup's
    // open put 1.5-2.7 % of content ink on the surface's rim (the content-clip
    // gate). The fade inside the cut is resampled too, and the cut then ends
    // it where the surface ends.
    Item {
        id: clipHost
        x: -body._offX
        y: -body._offY
        width: body._texW / body._sx
        height: body._texH / body._sy
        opacity: body.contentOpacity

        // A LAYER, not a ShaderEffectSource with hideSource: a captured item
        // receives no input at all and this one is the popup's content. A layer
        // is a render detour only -- the item stays where it is in the scene and
        // keeps every click.
        layer.enabled: body.clipActive
        layer.smooth: true
        // The FBO is at the ITEM's pixel size unless it is told otherwise, and
        // a texture at item resolution drawn at a zoomed stage (or at a
        // fractional position) is resampled: the whole subtree comes back soft
        // and banded. At the device's own density, on the device's own grid
        // (THE LAYERS' GRID, above) it is drawn 1:1.
        layer.textureSize: Qt.size(body._texW, body._texH)
        layer.effect: ShaderEffect {
            fragmentShader: "shaders/gooey_clip.frag.qsb"
            property variant source
            property real boxW: clipHost.width
            property real boxH: clipHost.height
            // ONE DEVICE PIXEL, in the item's own units: the layer is
            // _sx times denser than they are -- or the body's own
            // feather for its whole outline, when it has a wider one.
            property real aa: Math.max(1.0 / Math.max(0.25, body._sx), body.clipFeather)
            // HALF a device pixel inside the outline. The field's own coverage
            // is centred on the edge and reaches 1 half a pixel in, while this
            // feather runs inward from the edge: the two overlap on a band
            // where the content is still partly drawn and the surface is not
            // yet solid, which is a few per cent of content ink on the
            // wallpaper (measured: 0.047 at its worst, on 508 px of the open).
            // Cutting half a pixel early makes the mask reach zero exactly
            // where the surface reaches one.
            property real inset: 0.5 / Math.max(0.25, body._sx)
            // The outline and the second box are the body's, in ITS pixels; the
            // texture's origin is the layered item's, which starts _offX / _offY
            // before the body (THE LAYERS' GRID), so the shader's pixel p is the body's
            // plus that. The corner radii are relative to the box and move with it.
            property vector4d box: Qt.vector4d(body.clipBox.x + body._offX, body.clipBox.y + body._offY,
                                               body.clipBox.z + body._offX, body.clipBox.w + body._offY)
            property vector4d ex: body.clipEx
            property vector4d ey: body.clipEy
            property vector4d ix: body.clipIx
            property vector4d iy: body.clipIy
            property vector4d lim: Qt.vector4d(body.clipLim.x + body._offX, body.clipLim.y + body._offY,
                                               body.clipLim.z + body._offX, body.clipLim.w + body._offY)
        }

        // The fade beside a fillet (above), on only while a fold fades an edge.
        // The same rect as the layer above it: a layer inside a layer is drawn into
        // the outer texture, where it too must land on whole pixels to stay sharp.
        Item {
            id: seamHost
            width: clipHost.width
            height: clipHost.height
            layer.enabled: body.seamActive
            layer.smooth: true
            layer.textureSize: Qt.size(body._texW, body._texH)
            layer.effect: ShaderEffect {
                fragmentShader: "../../common/components/shaders/edge_fade.frag.qsb"
                property variant source
                // In texture coordinates: a fading edge on its line (the body's
                // own edge, which lies _offX / _offY inside the texture's), every
                // other line so far out that no fade reaches the item. One length
                // per axis (the shader's): the sides a fold moves share one envelope.
                property vector4d edges: Qt.vector4d(
                    body.seamFade.x > 0 ? body._offX / Math.max(1, seamHost.width) : -1e4,
                    body.seamFade.y > 0 ? body._offY / Math.max(1, seamHost.height) : -1e4,
                    body.seamFade.z > 0 ? (body._offX + body.width) / Math.max(1, seamHost.width) : 1e4,
                    body.seamFade.w > 0 ? (body._offY + body.height) / Math.max(1, seamHost.height) : 1e4)
                property vector2d fade: Qt.vector2d(Math.max(body.seamFade.x, body.seamFade.z) / Math.max(1, seamHost.width),
                                                    Math.max(body.seamFade.y, body.seamFade.w) / Math.max(1, seamHost.height))
            }

            // The content's own frame: the body's origin, and its size in the content's own units -- a ScaleRoot of the body's ratio
            // over the body's size (at ratio 1 the body's size, to the bit, and no transform at all). While the body overshoots its
            // rest box (`framed`, above) the frame is that box, where it stands in the body.
            ScaleRoot {
                id: contentFrame
                x: body._offX + (body.framed ? body.frameX : 0)
                y: body._offY + (body.framed ? body.frameY : 0)
                factor: body.ratio
                hostWidth: body.framed ? body.frameW : body.width
                hostHeight: body.framed ? body.frameH : body.height

                // The next content of a journey, built before the flight and not seen until the swap (GooeyEngine: THE BUILD GOES IN FRONT OF THE FLIGHT): shown to everything
                // that asks (a hidden subtree lies about its height), drawn nowhere, deaf. (A popup that takes the keys at its build still has them after the swap: the
                // clipboard, the launcher and notes by their keys over an open popup.)
                Item {
                    id: aheadHost
                    anchors.fill: parent
                    opacity: 0
                    enabled: false
                }
                Loader {
                    id: loader
                    anchors.fill: parent
                    active: body.component !== null && body.adopted === null
                    sourceComponent: body.component
                    onLoaded: body.loaded()
                    // Debug: the surface with nothing in it, which is what the
                    // content-clip gate compares every frame against.
                    visible: !(body.engine && body.engine.hideContent)
                }
            }
        }
    }

    // The declarative contract a primary's content -- or a child's, for the
    // next level of THE CHILD CHAIN -- can use to open a secondary popup (see
    // GooeyEngine: "The content contract"). Unknown signals are ignored, so
    // content that does not speak it costs nothing.
    Connections {
        target: body.contentItem
        ignoreUnknownSignals: true
        function onSecondaryOpenChanged() { body.contractChanged(); }
        function onSecondaryKeyChanged() { body.contractChanged(); }
        function onSecondaryAnchorChanged() { body.contractChanged(); }
        function onSecondaryComponentChanged() { body.contractChanged(); }
        function onSecondarySideChanged() { body.contractChanged(); }
        function onSecondaryOverhangChanged() { body.contractChanged(); }
        function onSecondaryInsetChanged() { body.contractChanged(); }
        function onSecondaryAnchorAtChanged() { body.contractChanged(); }
        function onSecondaryOpenAtChanged() { body.contractChanged(); }
        function onSecondaryOpenMinChanged() { body.contractChanged(); }
        function onSecondaryWidthFromChanged() { body.contractChanged(); }
        function onSecondaryChildKeyChanged() { body.contractChanged(); }
        function onMaskCatchAllChanged() { body.contentCatch(); }
    }

    Connections {
        target: body.contentItem
        ignoreUnknownSignals: true
        function onImplicitWidthChanged() { body.implicitSizeChanged(); }
        function onImplicitHeightChanged() { body.implicitSizeChanged(); }
        function onSurfaceTintChanged() { body.contentTint(); }
        function onSwipeGestureActiveChanged() { body.contentGesture(); }
        function onGestureHoldWidthChanged() { body.contentGesture(); }
        function onGestureHoldHeightChanged() { body.contentGesture(); }
    }

    // Live resize and the shift along the bar are a primary's (a child is
    // placed by its parent).
    Connections {
        target: body.isChild ? null : body.contentItem
        ignoreUnknownSignals: true
        function onLiveResizeActiveChanged() { body.contentLiveResize(); }
        function onLiveResizeMaskChanged() { body.contentLiveMask(); }
        function onAlongShiftChanged() { body.contentShift(); }
    }

    // A CHILD'S TEXTURES FOLLOW ITS OWN RATIO: its content's `renderScale` (device px per content px: the number a layer, a canvas or a
    // decode is multiplied by) is what its OWNER handed the parent -- the parent's ratio, which the child no longer shares
    // (`ownScale`, "<owner>.detail"). A child content that declares one is handed the frame's scale x the ratio it is drawn at (the
    // ratio of the content that is LOADED, so a swap's fade is not re-textured); one without it is left alone (DeviceScale finds its own).
    // (Decided once per content, in a handler: a binding that tests `"renderScale" in` the item it is also written to loops.)
    property bool _wantsRenderScale: false
    onContentItemChanged: body._wantsRenderScale = body.isChild && !!body.contentItem && ("renderScale" in body.contentItem)
    Binding {
        target: body._wantsRenderScale ? body.contentItem : null
        property: "renderScale"
        value: (body.engine ? body.engine.frameRenderScale : 1) * body.ratio
    }

    // Debug: the box the engine placed, over the field.
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        border.width: 1
        border.color: body.isFlourish ? "#C838C6" : body.isReel ? "#7C4DFF" : body.isOsd ? "#F0AA0B" : body.isLane ? "#44C145" : body.isChild ? "#00BEC4" : "#EC0000"
        visible: body.engine ? body.engine.showBoxes : false
    }
}
