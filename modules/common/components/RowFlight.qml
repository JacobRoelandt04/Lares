pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "../theme"

// =============================================================================
// RowFlight.qml
//
// A row changing its place in a list, flown rather than teleported: a clone of
// the row travels from where it was to where the model puts it, so the move
// reads as one object rather than a disappearance and a reappearance.
//
// Shared by the system update popup (favouriting a package: favourites sort to
// the top of their category, so the row physically moves) and the LLM sidebar
// (a conversation moving into and out of `Favorites`, ACROSS groups). The two
// host-specific things it needs, the ghost's appearance and where the
// destination is, are handed in as a Component and a handful of functions.
//
// Every comment below gives the reason for a rule of the motion.
//
//   RowFlight {
//       id: flightOverlay
//       anchors.fill: parent            // at the HOST's root: no clip may cut
//       cloneComponent: Component { MyRow { property var flightData: null } }
//       findDest:   key => host.findRow(key)
//       destTopIn:  (item, key) => host.restTopIn(item, key)   // NaN if unknown
//       beginGap:   key => host.holdSlotOpen(key)
//       endGap:     () => host.releaseSlot()
//       commit:     key => host.model.toggle(key)
//       indexOf:    key => host.model.indexOf(key)
//   }
//   ... flightOverlay.begin(key, rowItem, data)   // from the row's own gesture
//   ... flightOverlay.begin(key, rowItem, data, fromItem)   // lifted off where
//       fromItem IS (a card released mid-swipe): see LIFTED OFF A MOVED FACE
//   ... host hides the row whose id === flightOverlay.key
//   ... host binds its blur to flightOverlay.blur and freezes its wheel
//       handler while flightOverlay.scrollLocked
//
// CAMERA FOLLOW
// -------------
// When the destination is off-screen -- favouriting something far down a long
// category, or un-favouriting something whose new home is below the fold --
// the list scrolls to bring it into view while the clone stays roughly where
// the user's cursor left it, with the moving list motion-blurred in proportion
// to how fast it is travelling.
//
// The scroll target is chosen so the destination lands under the clone, then
// CLAMPED to the Flickable's real bounds -- and the clone's own target is
// derived from the clamped value, not the wish:
//
//     ghostTargetY = destY_in_content - actualScroll + flickScreenY
//
// If nothing clamps, that expression equals the clone's start position and it
// holds still while the list slides under it. If the Flickable runs out of
// room, the same expression automatically gives the clone the leftover
// distance to cover itself. Deriving the path from the UNCLAMPED intent would
// work in normal view and misbehave in verbose, whose short panel clamps
// almost every time: the clone would land above its slot, or shoot off the
// top.
//
// ONE CLOCK FOR THE TRAVEL AND THE SLOT
// -------------------------------------
// The destination's space is opened by `_revealAnim` over exactly the travel's
// own duration, and the leg is PLANNED AT THE MOMENT IT IS FLOWN, not when the
// destination was first measured. Both matter for the same reason: the
// duration scales down for a short hop, so a leg measured before the clone has
// finished riding the hole (see sourceTopIn) is timed for a distance it no
// longer has to cover, and the slot -- opening on the un-scaled `travelMs` --
// would still be two thirds shut when the clone arrives. The clone would reach
// its place in 130 ms and then PARK for 210 ms over a list that is visibly
// still rearranging itself, which reads as a mid-travel stutter.
//
// LIFTED OFF A MOVED FACE
// -----------------------
// A row committed by a swipe is still displaced when the flight begins (a pin
// is released at half the card's width). Begun from the row, the clone
// would appear at the row's REST on the next frame -- a snap sideways, and the
// card's own swing back never seen. `begin(..., fromItem)` starts
// the clone where fromItem is drawn (a SwipeVerbCard's `faceItem`) and eases
// it back into the row's column over `returnMs` (OutCubic) from that frame on
// -- the card's own spring back, continued by the clone, into the lift that
// starts once the host has reconciled; the travel then flies it.
// Without fromItem the clone starts at the row.
//
// A face displaced in a list is drawn through its SideFade's cut (SideCut:
// cut to the host's outline per row, faded out before the side clip), so a
// clone that took over as it was would pop from faded to whole along that
// side and be cut hard by whatever clips the overlay. With `sideFade` the
// clone is drawn through the same cut for as long as it is off its row's
// column -- the return, and the sideways exit leg -- and is the face's own
// picture on the hand-over frame; `cloneRadius` is its corner radius (where a
// resting row begins in a corner's rows). A layer only while it is off the
// column, sized at the scale it is seen at; no sideFade: no layer, ever.
//
// THE SHADOW'S BOUNDS
// -------------------
// The lifted clone's contact shadow reaches past the clone by its spread and
// its blur. A host whose side padding must stay bare ground (the manager's
// gutter outside its rows' clip) gives `shadowBounds`: the shadow's
// rect then SHRINKS so its blurred ink ends at those bounds -- it is never
// cut, which would draw an edge across a shadow. While the clone is drawn
// through a SideFade's cut, the bounds also give up that cut's fade zone on
// the side the clone is displaced to, at the cut's own strength: a shadow
// under the part of the card that is fading out is a shadow with no card
// over it. Unset, the shadow is the plain one, to the pixel.
// =============================================================================
Item {
    id: flight

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    // The overlay draws above the list it came out of. The host still decides
    // where the item lives; this only settles the stacking inside it.
    z: 100
    visible: flight._active

    // ---- Host contract ----------------------------------------------------
    //
    // The ghost. Its root must carry `property var flightData`; the host binds
    // everything else it needs from that object, so this file never learns
    // what a row looks like.
    property Component cloneComponent: null
    // key -> the live row Item that is the destination, or null.
    property var findDest: null            // function(key) -> Item|null
    // key -> the destination's top in `item`'s coordinates, NaN if not known.
    // Asked of the MODEL, never measured off a row that is still moving --
    // see the note in _startTravel.
    property var destTopIn: null           // function(item, key) -> real
    property var beginGap: null            // function(key)  -- hold the slot open
    // Release whatever `beginGap` reserved. Called at the top of the teardown,
    // BEFORE the flight's own state is cleared: the host's rows are still
    // suppressed at that moment, so the slot
    // closes and the row unhides in the same turn rather than one after it.
    property var endGap: null              // function()
    property var commit: null              // function(key)  -- flip the model
    property var indexOf: null             // function(key) -> int, -1 if absent
    // OPTIONAL: the live top of the VACATED slot (the hole) in `item`'s
    // coordinates, NaN when unknown. While the flight is still waiting to
    // travel (reconcile, lift, pre-move beat) the clone's y follows this
    // every frame, so a relayout that nudges the hole -- the sidebar's
    // Favorites header materialising above it on a first-ever favourite --
    // carries the clone with it instead of leaving it hovering over pixels
    // the hole has moved away from. Sampled per frame rather than bound:
    // mapToItem in a binding does not re-evaluate on an ancestor relayout.
    property var sourceTopIn: null         // function(item, key) -> real
    // Optional: the Flickable the rows live in. When null it is found by
    // walking up from the row that started the flight.
    property var flick: null
    // OPTIONAL: the layer the clone is DRAWN in. The clone, its backing and
    // its contact shadow live in one host item (`cloneHost` below) which is
    // reparented into `overlayItem` when one is given, so a shadow that
    // spills past this item's bounds is not sliced off by whatever the
    // host's sibling draws over it (the LLM sidebar's ghost would lose 26px
    // of its shadow's falloff to the conversation container).
    //
    // EVERY LEG IS MEASURED IN THAT HOST ITEM'S COORDINATES, never in this
    // one's. That is what makes the reparenting free: the clone's numbers
    // are already in the space it is drawn in, so nothing has to be offset,
    // and -- the reason it is done this way -- nothing has to SAMPLE the
    // offset per frame either. mapToItem does not re-evaluate in a binding
    // when an ancestor moves, so an offset would have needed a FrameAnimation
    // running for the whole flight, which forces a repaint every frame for a
    // number that never changes. With no overlayItem the host item fills
    // this one exactly, so every figure below is unchanged to the pixel.
    property Item overlayItem: null

    // ---- Tuning -----------------------------------------------------------
    property int  liftMs: 160
    property int  travelMs: 340
    property int  landMs: 160
    // The exit leg, for a row with no on-screen home to land in. Matches the
    // host list's own row-leave duration so the two read as one motion.
    property int  exitMs: 240
    property real liftScale: 1.055
    // Travel time is constant, except for genuinely short hops: below this
    // distance it scales down so a two-row move is not padded out to the full
    // duration.
    property real shortDistance: 220
    property int  minTravelMs: 130
    // The list is only scrolled when the destination would otherwise be off
    // screen. Inset from the viewport edges (as a fraction of its height)
    // before a destination counts as "comfortably visible", so a row does not
    // land flush against an edge.
    property real visibleInset: 0.08
    // Blur peaks when the list travels this far; further than that and it is
    // already saturated.
    property real blurRefDistance: 700
    property real blurMax: 0.55
    // Long enough for the host's queued re-sync AND the resulting relayout to
    // land before anything is measured.
    property int  settleMs: 90
    // Beat before the clone starts travelling, and again before it drops into
    // place. Gives the eye a moment to register the lift as a distinct step
    // rather than one continuous slide.
    property int  preMoveDelayMs: 100
    property int  preDropDelayMs: 100
    // Below this the row is not really moving, so there is nothing for a
    // flight to convey.
    property real minTravel: 4
    // Density of the list the clone came from, so it matches its neighbours.
    // Written at launch from the row's own `listScale` when it has one; a host
    // whose rows have no such property can set it once and it stays.
    property real cloneScaleFactor: 1.0
    // The clone's visible PLATE may be inset from the loader's horizontal
    // bounds (the sidebar's row wash starts `rowInset` in from the row's
    // edge). The backing and the contact shadow hug the plate, not the
    // loader, or the ghost reads wider than the row it lifted off. 0/0 puts
    // the plate at the loader's full width.
    property real contentInsetLeft: 0
    property real contentInsetRight: 0
    // The contact shadow's reach. `liftShadowSpread` is how far its rect
    // reaches past the plate at the sides, and its drop scales with it: the
    // rect begins 0.4 x spread below the plate's top and ends 1.6 x spread
    // below its foot, so 10 gives the 4 / 16 rect and 0 is
    // a rect exactly under the plate. `liftShadowBlur` is the blur's radius
    // (MultiEffect's blurMax) and adds its own reach on every side; 0 draws
    // the plain rect with no layer at all -- a layer at blurMax 0 is the rect
    // as a texture resampled under the lift's scale (measured: 1048 px of ink
    // for 1816, half a pixel short at head and foot). Lifted, the rect scales
    // with the clone, so its ink reaches past the slot's side and its foot
    //     side  plateWidth  * (liftScale - 1) / 2 + spread * liftScale + blur
    //     foot  plateHeight * (liftScale - 1) / 2 + spread * (1 + 0.6 * liftScale) + blur
    // (+1 px of antialiasing). On a 396 x 56 row at liftScale 1.03 that is
    // 41 / 42 px with these defaults, measured, and 11 / 7 at spread 1, blur 4:
    // a host whose content is cut at a 12 px padding needs the smaller pair
    // (the notifications manager).
    property real liftShadowSpread: 10
    property real liftShadowBlur: 24
    // LIFTED OFF A MOVED FACE: how long the clone takes to come back into its
    // row's column from where `fromItem` was drawn. The lift's own length by
    // default: it is back in its column as the lift gets going.
    property int  returnMs: flight.liftMs
    // THE SHADOW'S BOUNDS, in the layer the clone is drawn in (overlayItem's
    // coordinates, else this item's). An empty rect: no bounds.
    property rect shadowBounds: Qt.rect(0, 0, 0, 0)
    // LIFTED OFF A MOVED FACE: the list's SideFade, whose cut the clone is
    // drawn through while it is off its column, and the clone's corner radius.
    property SideFade sideFade: null
    property real cloneRadius: 0
    // OPTIONAL: travel on BOTH axes. In a list every row has the same x, so
    // by default the clone takes the destination's x (and keeps its own
    // width) the moment the travel is planned, and only y is flown. A host
    // whose rows sit in COLUMNS (the launcher's grid) sets this: the clone's
    // x and width then ease from the cell it left to the cell it lands in,
    // on the travel's own clock, and "did it move" and the leg's length are
    // measured in the plane. false flies y only.
    property bool travelX: false

    // ---- Palette ----------------------------------------------------------
    // The ground the clone is lifted off, painted opaque behind it so it is
    // not translucent over the list.
    property color backingColor: Theme.surface
    // The contact shadow under the lifted clone. Black on purpose and in both
    // themes: it is a shadow cast by the clone, not a surface of the design,
    // and it is drawn blurred at 30% -- a themed grey would read as a grey
    // card behind the row on light and as nothing at all on dark.
    property color dropShadowColor: "#000000"

    // ---- Live -------------------------------------------------------------
    readonly property bool   active: flight._active
    readonly property string key: flight._key          // host hides this row
    readonly property real   blur: flight._blur        // host binds MotionBlur
    // The destination's space, 0 while the clone is still on its way and 1 by
    // the time it lands. Opening it over the travel rather than the instant
    // the model reorders means the list is not left with a hole waiting to be
    // filled -- the space is made by the row arriving in it.
    readonly property real   reveal: flight._reveal
    readonly property bool   scrollLocked: flight._scrollLocked
    readonly property alias  cloneItem: cloneLoader.item

    signal ended()

    // ---- Commands ---------------------------------------------------------
    //
    // `data` is handed straight to the clone's `flightData`. The host commits
    // the model change in `commit` and, if the clone's own copy has to change
    // with it (a favourite flag flipping colour mid-air), writes a new
    // `flightData` there too -- both inside the same call, so no frame is
    // drawn between them.
    function begin(key, rowItem, data, fromItem) {
        if (!rowItem || flight._active) return false;

        const restPos = rowItem.mapToItem(cloneHost, 0, 0);
        const startPos = fromItem ? fromItem.mapToItem(cloneHost, 0, 0) : restPos;
        flight._flick = flight.flick ? flight.flick : flight._flickableFor(rowItem);
        if (cloneLoader.item) cloneLoader.item.flightData = data;
        flight._x = startPos.x;
        flight._colX = startPos.x;
        flight._y = startPos.y;
        flight._w = rowItem.width;
        flight._h = rowItem.implicitHeight;
        flight._scale = 1.0;
        flight._shadow = 0;
        flight._blur = 0;
        flight._key = key;
        flight._active = true;
        flight._scrollLocked = true;
        if (rowItem.listScale !== undefined) flight.cloneScaleFactor = rowItem.listScale;

        // The clone is pixel-identical to the row it replaces, so it can be
        // shown before we know whether it will move. Committing the toggle
        // first lets us measure the real distance and skip the whole
        // lift-and-fly performance when the row is not going anywhere.
        flight._commit();
        // Lifted off a moved face: back into the row's column (the flight may
        // already be over -- a row that keeps its slot ends in _commit).
        if (flight._active && Math.abs(startPos.x - restPos.x) > 0.5) {
            flight._colX = restPos.x;
            _return.from = startPos.x;
            _return.to = restPos.x;
            _return.restart();
        }
        return true;
    }

    // The host's model has re-synced and re-laid out: measure now.
    function reconciled() {
        if (!flight._awaitingReconcile) return;
        flight._awaitingReconcile = false;
        _settle.stop();
        // One more beat so the column has actually applied the new order
        // before anything is measured.
        _layoutSettle.restart();
    }

    function cancel() { if (flight._active) flight._end(); }

    // Belt and braces for the host: released only when nothing is airborne.
    // The lock is cleared by every path out of a flight already; this exists
    // so a host that notices its own list has finished moving can be sure.
    function releaseScrollLock() {
        if (!flight._active) flight._scrollLocked = false;
    }

    // ---- State ------------------------------------------------------------
    property string _key: ""
    property real  _reveal: 1
    property bool  _active: false
    property real  _x: 0
    property real  _y: 0
    property real  _w: 0
    property real  _h: 0
    property real  _scale: 1.0
    property real  _shadow: 0
    property real  _blur: 0
    property bool  _scrollLocked: false
    property var   _flick: null
    property bool  _awaitingReconcile: false
    property bool  _blurPending: false
    property bool  _scrollPending: false
    // True from commit until the travel leg starts: the window in which the
    // clone follows the hole (see sourceTopIn).
    property bool  _trackSource: false
    // The destination, measured once the host has reconciled, in the
    // flickable's content space -- and where that flickable's own top sits on
    // screen. The LEG is not derived from these until `_planLeg`.
    property real  _destInContent: 0
    property real  _flickOnScreen: 0
    // travelX: where the clone's left edge and width land, in cloneHost's
    // coordinates, measured with the destination in _startTravel.
    property real  _destX: 0
    property real  _destW: 0
    // The row's column: where the clone's left edge rests, in cloneHost's
    // coordinates. The clone is OFF it while it returns from a moved face and
    // on the exit leg -- the frames the SideFade's cut is drawn for.
    property real  _colX: 0
    readonly property bool _cutting: flight._active && flight.sideFade !== null
        && !flight.travelX && Math.abs(flight._x - flight._colX) > 0.01
    on_CuttingChanged: if (flight._cutting) flight._sampleCut()
    // The cut's per-item half (SideCut), in the SideFade's units, sampled per
    // frame while cutting: mapToItem in a binding does not re-evaluate when
    // an ancestor moves, and the clone scales as it lifts.
    property vector4d _uLayer: Qt.vector4d(0, 0, 0, 0)
    property vector4d _uRest: Qt.vector4d(0, 0, 0, 0)
    property real  _uDisp: 0
    property real  _uRadius: 0
    property real  _uAa: 1
    property size  _uTex: Qt.size(1, 1)
    function _sampleCut() {
        const f = flight.sideFade;
        if (!f)
            return;
        const w = Math.max(1, cloneLoader.width);
        const h = Math.max(1, cloneLoader.height);
        const lo = cloneLoader.mapToItem(f, 0, 0);
        const hi = cloneLoader.mapToItem(f, w, h);
        // The clone's scale to the SideFade (the lift included), and the host
        // layer's: the displacement is in the host layer's units.
        const kf = Math.abs(hi.x - lo.x) > 0.0001 ? (hi.x - lo.x) / w : 1;
        const c0 = cloneHost.mapToItem(f, 0, 0);
        const c1 = cloneHost.mapToItem(f, 1, 0);
        const kh = Math.abs(c1.x - c0.x) > 0.0001 ? c1.x - c0.x : 1;
        const dx = (flight._x - flight._colX) * kh;
        flight._uLayer = Qt.vector4d(lo.x, lo.y, hi.x - lo.x, hi.y - lo.y);
        flight._uRest = Qt.vector4d(lo.x - dx, lo.y, hi.x - lo.x, hi.y - lo.y);
        flight._uDisp = dx;
        flight._uRadius = flight.cloneRadius * kf;
        // Device pixels per clone unit: the texture's size, and one device
        // pixel in the SideFade's units (the cut's feather).
        // the WINDOW's ratio, not the attached Screen's (an integer at a fractional Hyprland scale)
        const win = flight.Window.window;
        const dpr = win && win.devicePixelRatio > 0 ? win.devicePixelRatio : 1;
        const g0 = cloneLoader.mapToItem(null, 0, 0);
        const g1 = cloneLoader.mapToItem(null, w, h);
        const kw = Math.abs(g1.x - g0.x) / w * dpr;
        const kwy = Math.abs(g1.y - g0.y) / h * dpr;
        flight._uAa = kf / Math.max(0.0001, kw);
        flight._uTex = Qt.size(Math.max(1, Math.ceil(w * kw)), Math.max(1, Math.ceil(h * kwy)));
    }
    Connections {
        target: flight._cutting ? flight.Window.window : null
        function onAfterAnimating() {
            flight._sampleCut();
        }
    }

    // The contact shadow's rect: spread past the plate (liftShadowSpread),
    // then, with shadowBounds, shrunk about its centre until its scaled rect
    // plus the blur's scaled reach (+1 px of antialiasing) lies inside them
    // (less the cut's fade zone while the clone is displaced: THE SHADOW'S
    // BOUNDS).
    readonly property var _shadowRect: {
        const x = cloneLoader.x + flight.contentInsetLeft - flight.liftShadowSpread;
        const y = cloneLoader.y + flight.liftShadowSpread * 0.4;
        const w = cloneLoader.width - flight.contentInsetLeft
                - flight.contentInsetRight + 2 * flight.liftShadowSpread;
        const h = cloneLoader.height + flight.liftShadowSpread * 1.2;
        const b = flight.shadowBounds;
        if (!(b.width > 0 && b.height > 0))
            return { x: x, y: y, w: w, h: h };
        const k = Math.max(0.0001, flight._scale);
        const reach = Math.max(0, flight.liftShadowBlur) * k + 1;
        // The cut's fade zone on the displaced side (the SideFade's units are
        // the host layer's here: both lie in the host, unscaled).
        const fd = flight.sideFade;
        const zone = flight._cutting && fd
            ? (fd.leadPx + fd.fadeLength) * Math.min(1, Math.abs(flight._uDisp) / Math.max(1, fd.fadeLength)) : 0;
        const bl = b.x + (flight._x < flight._colX ? zone : 0);
        const br = b.x + b.width - (flight._x > flight._colX ? zone : 0);
        const cx = x + w / 2;
        const cy = y + h / 2;
        const l = Math.max(cx - w * k / 2, bl + reach);
        const r = Math.min(cx + w * k / 2, br - reach);
        const t = Math.max(cy - h * k / 2, b.y + reach);
        const f = Math.min(cy + h * k / 2, b.y + b.height - reach);
        const bw = Math.max(0, r - l) / k;
        const bh = Math.max(0, f - t) / k;
        return { x: (l + r) / 2 - bw / 2, y: (t + f) / 2 - bh / 2, w: bw, h: bh };
    }

    // The pre-travel ride. Runs only while a flight is waiting to travel
    // AND the host offers sourceTopIn, so there is no standing cost. Sampled
    // per frame rather than bound, because mapToItem in a binding does not
    // re-evaluate on an ancestor relayout.
    FrameAnimation {
        running: flight._active && flight._trackSource
                 && flight.sourceTopIn !== null
        onTriggered: {
            const v = flight.sourceTopIn(cloneHost, flight._key);
            if (v !== undefined && v !== null && !isNaN(v)) flight._y = v;
        }
    }

    // Flickable the given row lives in, found by walking up. Duck-typed on
    // contentY so it works for Flickable and any subclass.
    function _flickableFor(item) {
        let cur = item ? item.parent : null;
        while (cur) {
            if (cur.contentY !== undefined && cur.contentHeight !== undefined
                && cur.contentItem !== undefined) return cur;
            cur = cur.parent;
        }
        return null;
    }

    // =====================================================================
    //  THE CLONE
    //
    // One clone of the row currently moving, drawn at the host's root so no
    // Flickable or clip region can cut it off mid-flight. The real row hides
    // itself while its key matches `flight.key`, so exactly one copy is ever
    // on screen.
    //
    // The Loader carries the position and the lift scale, and the clone fills
    // it -- so the clone component itself needs to know nothing about the
    // flight beyond its own `flightData`.
    // =====================================================================

    // The three pieces the flight draws, in one item -- and the ONE
    // coordinate space every leg is measured in. With no overlayItem it
    // fills `flight` exactly, so it is a transparent transform node and the
    // drawing is the plain clone, to the pixel.
    Item {
        id: cloneHost
        parent: flight.overlayItem ? flight.overlayItem : flight
        anchors.fill: parent
        z: flight.z
        visible: flight._active

        // Soft drop shadow: an opaque rounded rect pushed under the clone and
        // blurred, so the lift reads as height rather than just scale. Its
        // reach is liftShadowSpread / liftShadowBlur (see there).
        Rectangle {
            id: flightShadow
            x: flight._shadowRect.x
            y: flight._shadowRect.y
            width: flight._shadowRect.w
            height: flight._shadowRect.h
            radius: 12
            color: flight.dropShadowColor
            opacity: flight._shadow * 0.30
            scale: flight._scale
            transformOrigin: Item.Center
            z: -2
            layer.enabled: flight.liftShadowBlur > 0
            layer.textureSize: dev.texSize(flightShadow.width, flightShadow.height)
            layer.effect: MultiEffect {
                blurEnabled: true
                blur: 1.0
                blurMax: Math.round(flight.liftShadowBlur)
            }
        }

        // Opaque backing so the clone is not translucent over the list. A host
        // whose clone already paints an opaque plate sets backingColor
        // transparent and this draws nothing.
        Rectangle {
            x: cloneLoader.x + flight.contentInsetLeft - 2
            y: cloneLoader.y
            width: cloneLoader.width - flight.contentInsetLeft
                   - flight.contentInsetRight + 4
            height: cloneLoader.height
            radius: 7
            color: flight.backingColor
            scale: flight._scale
            transformOrigin: Item.Center
            z: -1
        }

        Loader {
            id: cloneLoader
            sourceComponent: flight.cloneComponent
            x: flight._x
            y: flight._y
            width: flight._w
            // No height: the clone's own implicitHeight is the height, exactly as
            // for a plain child of the overlay. `_h` is the height of the row
            // that LAUNCHED it, which is not always the same thing (a running
            // row carries a download meter the clone does not).
            scale: flight._scale
            transformOrigin: Item.Center
            layer.enabled: flight._cutting
            layer.smooth: true
            layer.textureSize: flight._uTex
            layer.effect: Component {
                SideCut {
                    fade: flight.sideFade
                    layerRect: flight._uLayer
                    rest: flight._uRest
                    disp: flight._uDisp
                    cardRadius: flight._uRadius
                    aa: flight._uAa
                }
            }
        }
    }

    // =====================================================================
    //  THE LEGS
    // =====================================================================

    // Lift in place, then commit and measure. The travel leg is chained on
    // `onFinished` rather than declared inside one SequentialAnimation,
    // because its destination does not exist until the model change has
    // propagated AND the host has re-laid out -- filling `to` in from a
    // callback while the sequence is already running that leg is a race that
    // measures a 1 px move instead of the real one.
    // Just the lift. The toggle is committed BEFORE this runs, so the real
    // distance is known and a row that is not moving never lifts at all.
    ParallelAnimation {
        id: _lift
        NumberAnimation {
            target: flight; property: "_scale"
            to: flight.liftScale
            duration: flight.liftMs; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: flight; property: "_shadow"
            to: 1; duration: flight.liftMs; easing.type: Easing.OutCubic
        }
    }

    // LIFTED OFF A MOVED FACE: back into the row's column.
    NumberAnimation {
        id: _return
        target: flight; property: "_x"
        duration: flight.returnMs
        easing.type: Easing.OutCubic
    }

    Timer {
        id: _settle
        interval: flight.settleMs
        repeat: false
        onTriggered: flight._startTravel()
    }

    // The list scrolling under the clone.
    NumberAnimation {
        id: _scroll
        property: "contentY"
        duration: flight.travelMs
        easing.type: Easing.InOutCubic
    }
    // The destination's slot opening as the clone comes in to fill it. The
    // duration is written by `_planLeg` from the travel's own, so "as the
    // clone comes in" is literal: the space finishes being made on the frame
    // the clone finishes arriving in it.
    NumberAnimation {
        id: _revealAnim
        target: flight; property: "_reveal"
        from: 0; to: 1
        duration: flight.travelMs
        easing.type: Easing.InOutCubic
    }
    // travelX: the sideways half of the travel, and the width the clone
    // lands at. Planned with the vertical leg and started with it, so both
    // halves are one motion.
    NumberAnimation {
        id: _travelXAnim
        target: flight; property: "_x"
        duration: flight.travelMs
        easing.type: Easing.InOutCubic
    }
    NumberAnimation {
        id: _travelWAnim
        target: flight; property: "_w"
        duration: flight.travelMs
        easing.type: Easing.InOutCubic
    }
    // The clone's own movement -- usually none, unless the scroll clamped.
    NumberAnimation {
        id: _travel
        target: flight; property: "_y"
        duration: flight.travelMs
        easing.type: Easing.InOutCubic
        onStarted: _revealAnim.restart()
        onFinished: {
            _preDrop.interval = Math.max(1, flight.preDropDelayMs);
            _preDrop.restart();
        }
    }
    Timer {
        id: _preDrop
        repeat: false
        onTriggered: _land.start()
    }
    // Blur rises and falls across the travel, scaled by how far the list moves.
    SequentialAnimation {
        id: _blurSeq
        NumberAnimation {
            id: _blurUp
            target: flight; property: "_blur"
            duration: Math.round(flight.travelMs * 0.4)
            easing.type: Easing.OutQuad
        }
        NumberAnimation {
            id: _blurDown
            target: flight; property: "_blur"
            to: 0
            duration: Math.round(flight.travelMs * 0.6)
            easing.type: Easing.InQuad
        }
    }

    // Exit-right, matching a list row's leave.
    ParallelAnimation {
        id: _exit
        NumberAnimation {
            target: flight; property: "_x"
            to: cloneHost.width + flight._w
            duration: flight.exitMs
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: flight; property: "_scale"
            to: 1.0; duration: flight.exitMs; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: flight; property: "_shadow"
            to: 0; duration: flight.exitMs; easing.type: Easing.OutCubic
        }
        onFinished: flight._end()
    }

    ParallelAnimation {
        id: _land
        NumberAnimation {
            target: flight; property: "_scale"
            to: 1.0; duration: flight.landMs; easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: flight; property: "_shadow"
            to: 0; duration: flight.landMs; easing.type: Easing.OutCubic
        }
        onFinished: flight._end()
    }

    // =====================================================================
    //  THE SEQUENCE
    // =====================================================================

    function _commit() {
        // Position in the host's model, asked before and after the change.
        // Whether a toggle actually moves the row is a question about the
        // MODEL and must not be answered by measuring pixels: the host
        // re-syncs on a callLater and re-lays out after that, so immediately
        // post-commit the row is still sitting at its old coordinates and
        // every move looks like a no-move.
        const before = flight.indexOf ? flight.indexOf(flight._key) : -1;
        // Closed before the model moves, so the destination never exists at
        // full height for even a frame, and a phantom is left in the slot the
        // row is about to vacate so that gap does not snap shut either.
        flight._reveal = 0;
        if (flight.beginGap) flight.beginGap(flight._key);
        if (flight.commit) flight.commit(flight._key);
        const after = flight.indexOf ? flight.indexOf(flight._key) : -1;

        // The row keeps its slot: it was already at the top of its group, or
        // the sort put it back where it was. Nothing is being moved, so there
        // is nothing for a flight to convey -- whatever the change looks like
        // in place carries the meaning on its own.
        if (before >= 0 && before === after) {
            flight._end();
            return;
        }
        // Wait for the host to actually reconcile before measuring.
        //
        // The destination's position is meaningless until the row model has
        // been brought back in line with the source and the column has laid
        // out again. That work is deferred through Qt.callLater and re-deferred
        // while any wave is running, so a fixed delay is a race it loses: the
        // row is still sitting at its ORIGINAL index when its new position is
        // sampled, the clone flies roughly nowhere, and a one-row correction on
        // top of that sends it a row in the wrong direction. The timer is
        // purely a backstop.
        flight._trackSource = true;
        flight._awaitingReconcile = true;
        _settle.restart();
    }

    Timer {
        id: _layoutSettle
        interval: 32
        repeat: false
        onTriggered: flight._startTravel()
    }

    function _destTopIn(item) {
        if (!flight.destTopIn) return NaN;
        const v = flight.destTopIn(item, flight._key);
        return v === undefined || v === null ? NaN : v;
    }

    function _startTravel() {
        const dest = flight.findDest ? flight.findDest(flight._key) : null;
        const flick = flight._flick;

        // Backstop for the model-index check in _commit: if the row did change
        // index but its pixel position did not meaningfully move, still skip
        // the performance.
        // The phantom still holds the vacated slot open, so the list has not
        // shifted yet and anything below it reads one row too low.
        // Asked of the host, not measured off the row: the row is moving.
        const restY = flight._destTopIn(cloneHost);

        if (dest) {
            const here = dest.mapToItem(cloneHost, 0, 0);
            if (!isNaN(restY)) here.y = restY;
            const moved = flight.travelX
                ? Math.hypot(here.x - flight._x, here.y - flight._y)
                : Math.abs(here.y - flight._y);
            if (moved < flight.minTravel) {
                flight._end();
                return;
            }
        }

        if (!dest || !flick) {
            // The row has no on-screen home any more -- un-favouriting
            // something while its group is collapsed sends it back to a
            // hidden part of the list. Rather than hovering and fading in
            // place, the clone leaves the way a row leaves a collapsing list:
            // straight out to the right.
            //
            // NOTE for a host that draws the clone in an overlay: this leg
            // carries the clone a full row's width past the host's own right
            // edge, and in an overlay nothing paints over it on the way. The
            // LLM sidebar never reaches here -- its toggle expands the
            // destination group first, so the destination always exists --
            // and the system update, which does reach it, passes no overlay
            // and is unaffected. The real row is already sliding out
            // on the same choreography, and the content below closes up with
            // it, so the two read as one motion.
            flight._trackSource = false;
            _return.stop();
            _exit.start();
            return;
        }

        // Where the destination sits in the scrollable content, and where the
        // viewport itself sits on screen. MEASURED here and nowhere else --
        // both are facts about the settled list, and the list is settled now.
        // Everything DERIVED from them waits for _planLeg, because the clone
        // is still free to move (it rides the hole all through the lift) and
        // a leg is only as good as the position it is flown from.
        const restInContent = flight._destTopIn(flick.contentItem);
        flight._destInContent = isNaN(restInContent)
            ? dest.mapToItem(flick.contentItem, 0, 0).y : restInContent;
        flight._flickOnScreen = flick.mapToItem(cloneHost, 0, 0).y;

        if (flight.travelX) {
            flight._destX = dest.mapToItem(cloneHost, 0, 0).x;
            flight._destW = dest.width;
        } else {
            const destX = dest.mapToItem(cloneHost, 0, 0).x;
            if (!_return.running) {
                flight._x = destX;
                flight._colX = destX;
            } else if (Math.abs(_return.to - destX) > 0.5) {
                // Still coming back from a moved face: to the destination's column.
                flight._colX = destX;
                _return.stop();
                _return.from = flight._x;
                _return.to = destX;
                _return.start();
            }
        }

        // Lift, hold a beat, then travel; another beat before the drop.
        _lift.start();
        _preMove.interval = flight.liftMs + Math.max(1, flight.preMoveDelayMs);
        _preMove.restart();
    }

    // The leg, derived at the instant it is flown: from where the clone
    // actually is, to the slot measured in _startTravel, over a duration and
    // a scroll that answer to THAT distance.
    function _planLeg() {
        const flick = flight._flick;
        const destInContent = flight._destInContent;
        const flickOnScreen = flight._flickOnScreen;

        // Where the destination would sit if we did NOT scroll at all.
        const destNow = destInContent - flick.contentY + flickOnScreen;
        const inset = flick.height * flight.visibleInset;
        const alreadyVisible = destNow >= flickOnScreen + inset
                            && destNow + flight._h <= flickOnScreen + flick.height - inset;

        // Scrolling exists to bring an OFF-SCREEN destination into view. When
        // the row only has to hop a short distance that is already visible,
        // moving the whole list under it is louder than the thing it is
        // announcing -- favouriting something two rows down must not drag the
        // entire list.
        //
        // The test is purely about this row and its destination: nothing about
        // what the rest of the list is doing enters into it.
        const maxY = Math.max(0, flick.contentHeight - flick.height);
        const wanted = alreadyVisible
            ? flick.contentY
            : destInContent - (flight._y - flickOnScreen);
        const actual = Math.max(0, Math.min(maxY, wanted));
        const scrollDist = Math.abs(actual - flick.contentY);

        // Clone's target derives from the CLAMPED scroll, so it covers exactly
        // whatever the list could not.
        const ghostTarget = destInContent - actual + flickOnScreen;
        const ghostDist = flight.travelX
            ? Math.hypot(ghostTarget - flight._y, flight._destX - flight._x)
            : Math.abs(ghostTarget - flight._y);

        // Constant duration, shortened only for genuinely small moves.
        const dist = Math.max(scrollDist, ghostDist);
        const dur = dist >= flight.shortDistance
            ? flight.travelMs
            : Math.max(flight.minTravelMs,
                       Math.round(flight.travelMs * dist / flight.shortDistance));

        _travel.duration = dur;
        _travel.from = flight._y;
        _travel.to = ghostTarget;
        if (flight.travelX) {
            _travelXAnim.duration = dur;
            _travelXAnim.from = flight._x;
            _travelXAnim.to = flight._destX;
            _travelWAnim.duration = dur;
            _travelWAnim.from = flight._w;
            _travelWAnim.to = flight._destW;
        }
        // ONE CLOCK. The slot is opened by the row arriving in it, so it
        // opens over the arrival and not over the un-scaled travelMs: a
        // clone that reaches its place in 130 ms would hang there for
        // another 210 ms while the space it came for is still being
        // made under it, and that pause reads as a stutter.
        _revealAnim.duration = dur;

        if (scrollDist > 0.5) {
            _scroll.stop();
            _scroll.target = flick;
            _scroll.from = flick.contentY;
            _scroll.to = actual;
            _scroll.duration = dur;
            // Started with the travel below, so the list and the clone move
            // on the same beat.
            const peak = Math.min(1, scrollDist / flight.blurRefDistance)
                       * flight.blurMax;
            _blurUp.to = peak;
            _blurUp.duration = Math.round(dur * 0.4);
            _blurDown.duration = Math.round(dur * 0.6);
            flight._blurPending = true;
            flight._scrollPending = true;
        } else {
            flight._blurPending = false;
            flight._scrollPending = false;
        }
    }

    Timer {
        id: _preMove
        repeat: false
        onTriggered: {
            // The ride is over and the clone is wherever the hole left it.
            // The leg is planned from HERE -- distance, duration, scroll and
            // blur -- because a leg planned before the ride was timed for a
            // distance that no longer exists.
            flight._trackSource = false;
            flight._planLeg();
            _travel.start();
            if (flight.travelX) {
                _return.stop();
                _travelXAnim.start();
                _travelWAnim.start();
            }
            if (flight._scrollPending) _scroll.start();
            if (flight._blurPending)   _blurSeq.restart();
        }
    }

    // Safety net. Every path out of a flight calls _end, but if one ever fails
    // to (an exception mid-sequence, a delegate torn down under the
    // animation), `scrollLocked` would stay true and the list would be
    // permanently unscrollable with no way back short of a restart. The
    // watchdog force-ends any flight that outlives its worst-case duration.
    Timer {
        id: _watchdog
        running: flight._active
        interval: flight.liftMs + flight.settleMs
                + flight.travelMs + flight.landMs + 600
        repeat: false
        onTriggered: {
            if (flight._active) flight._end();
        }
    }

    function _end() {
        flight._trackSource = false;
        flight._awaitingReconcile = false;
        _layoutSettle.stop();
        _revealAnim.stop();
        flight._reveal = 1;
        if (flight.endGap) flight.endGap();
        // The pending legs too, or a pre-move timer still fires the stale
        // scroll after the flight is gone.
        _preMove.stop();
        _preDrop.stop();
        _lift.stop();
        _land.stop();
        _exit.stop();
        _settle.stop();
        _travel.stop();
        _travelXAnim.stop();
        _travelWAnim.stop();
        _return.stop();
        _scroll.stop();
        _blurSeq.stop();
        flight._blur = 0;
        flight._active = false;
        flight._key = "";
        // Dropped: the clone sits between flights with nothing in it rather
        // than holding the last row's data alive.
        // qmllint disable missing-property
        if (cloneLoader.item) cloneLoader.item.flightData = null;
        // qmllint enable missing-property
        flight._flick = null;
        flight._scale = 1.0;
        flight._shadow = 0;
        flight._scrollLocked = false;
        flight.ended();
    }
}
