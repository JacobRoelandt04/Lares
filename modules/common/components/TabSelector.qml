pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "../scroll"

// =============================================================================
// TabSelector.qml
//
// General-purpose segmented tab selector. Track and sliding pill are both
// ShadowBox components — the track is carved into its surface, the pill is a
// raised box standing in it, so the active tab reads as physically sitting on
// top of the track.
//
// Features:
//   - orientation: "horizontal" | "vertical" — pill slides along that axis
//   - arbitrary tab count; each tab may carry an icon + label
//   - configurable palette per ShadowBox role; animation duration + easing
//   - exposes currentTab (string id) bidirectionally; emits tabChanged(id)
//
// Tabs model is an array of objects with shape:
//     { id: string, label: string, icon: optional string, tip: optional string }
//
// A `tip` is the tab's hover tip (HoverTip, on `overlayItem` when the host has one): what an
// icon-only selector says in words. Tabs without one carry no tip and cost nothing.
//
// Two laws hold the drawing together:
//
//   THE PILL SITS IN THE GROOVE, IT DOES NOT PAINT OVER IT. What a raised
//   ShadowBox lays outside its edge is an opaque apron, and the track's own
//   inset shadow lives in exactly the `pillInset` px the pill is held away
//   from the edge by. So `pillShadowWidth` < `pillInset`, always -- see the
//   measurement at that property.
//
//   THE PILL'S PLACE IS A FRACTION OF THE TRACK, NOT A PIXEL. Hosts resize
//   this selector while it is running, and a pill animated in pixels stalls,
//   is left behind, and squishes for a resize nobody asked for. Everything
//   about the pill's rectangle is resolved from `_pillSlot` against the track
//   as it is this frame -- see the block at `_pillSlot`.
//
// The size is the host's: `width`/`height` like any item, and
// `trackRadiusOverride` when it must wear the same corner as a container
// standing beside it. Asked for its own size instead, it answers with one made
// of its tabs and its font.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    property var tabs: []
    // See the label fade in `tabCell`: air above the label's own width at
    // which it is still fully drawn, and the fraction of that width below
    // which it is gone.
    property real labelFadeAir: 6
    property real labelFadeFloor: 0.6
    property string currentTab: tabs.length > 0 ? tabs[0].id : ""

    property string orientation: "horizontal"   // "horizontal" | "vertical"

    // --- Track ShadowBox palette (inset look) ---
    // WHAT THIS SELECTOR PAINTS OUTSIDE ITS OWN RECT, in whole pixels: the track is a carved box,
    // and a carved ShadowBox lays its bevel OUTSIDE its edge (`bevelWidth` plus a pixel of
    // antialiasing). A host that clips on this selector's edge -- a panel flush with it on its top,
    // right and left -- scissors that band, and in the light theme the band is the only ink between
    // the track and the ground, which reads as "the selector has no top". A clip that stands on this selector's edge must stand at least
    // `bleed` outside it (AudioPlayerPopup's `panelHost._slack` is derived from it).
    readonly property real bleed: Math.ceil(track._margin)

    // Every colour default is a Theme token (the system update's dressing,
    // which is the shell's one selector), so a host that passes nothing wears
    // the theme in both modes; a literal here would leave a light pill
    // on a dark card. A host overrides only to wear a different ground.
    property color trackSurfaceColor: Theme.surface
    property color trackBevelColor: Theme.border
    property color trackShadowColor: Theme.headerBoxShadow
    property color trackBackgroundColor: Theme.panelSunk
    property real trackBevelWidth: 1.5
    property real trackShadowWidth: 3
    // ShadowBox.shadowFalloff of the track's inset (1: ShadowBox's own curve).
    property real trackShadowFalloff: 1.0

    // --- Tips ---
    // Where the host's floating things live (its overlay layer): a tip painted inside a clipping
    // ancestor is cut. Null: the tip falls back to this selector's own parent.
    property Item overlayItem: null
    // Which side of a tab its tip opens on ("below" for a selector at the top of a popup).
    property string tipSide: "below"

    // --- Pill ShadowBox palette (RAISED: it stands on the track) ---
    //
    // The pill is a raised box, not a carved one in accent tones: carved is
    // the wrong shape for it, since reading outward from the middle you would
    // get the plateau, then a darker blue inset shadow, then the box's edge,
    // then a LIGHTER blue bevel outside it, then the track. Two rims in
    // opposite directions with a hard edge between them -- visible in the
    // light theme, obvious in the dark one.
    //
    // Raised puts the bands in the one order a real object can have: a
    // highlight inside the edge, the edge, a drop shadow falling outward
    // onto the track. Same treatment as RaisedButton, so the pill and the
    // prompt's buttons read as the same material at the same height.
    property color pillSurfaceColor: Theme.panelSunk       // the track it stands on
    property color pillBevelColor: Theme.accentBevel       // highlight inside its edge
    property color pillShadowColor: Theme.buttonShadow     // drop shadow on the track
    property color pillBackgroundColor: Theme.accent       // the plateau
    // A highlight is a thin line, a shadow spreads -- tuned separately, as on
    // the buttons.
    property real pillBevelWidth: 1.5
    // THE APRON MAY NOT REACH THE TRACK'S EDGE.
    //
    // What a raised ShadowBox paints OUTSIDE its edge is a drop shadow
    // `pillShadowWidth` wide, and with `shadowToAlpha` off -- which is what
    // this is -- that band is OPAQUE: the pill's own surface colour shaded
    // down to the shadow, laid over whatever is beneath it. Beneath it is the
    // TRACK'S OWN INSET SHADOW, which lives in exactly the `pillInset` px the
    // pill is held away from the track's edge by.
    //
    // At 3 -- the same number as the inset -- the apron would reach the
    // track's edge and repaint the groove out of existence, so the border
    // would read as THINNING wherever the pill stands. MEASURED in light
    // mode, reading inward from the track's top edge: bare track goes
    // 188, 213, 223 (dark at the edge, easing into the fill), and under the
    // pill it goes 225, 219, 200 -- the same ramp upside down, because that
    // is the PILL's shadow and the groove is gone. Obvious in the dark
    // theme, where the rim above and below the pill simply vanishes.
    //
    // Half the inset stops the apron halfway across the groove and leaves the
    // darkest part of it -- the pixel at the edge itself -- untouched. The
    // invariant, not the number, is the point: apron < inset. What stands
    // proud may not paint over the channel it stands in. Derived from the
    // inset so a host that widens the channel cannot break it by accident.
    property real pillShadowWidth: root.pillInset * 0.5
    property real pillShadowEdgeAlpha: 0.9

    // --- Text ---
    property color textColor: Theme.textPrimary
    property color activeTextColor: Theme.textOnAccent
    property string fontFamily: "Audiowide"
    // The icons' face, when it is not the labels' (an icon font such as
    // "Symbols Nerd Font"); empty means `fontFamily`.
    property string iconFontFamily: ""
    // Which half of each tab is drawn. The tabs MODEL never changes to hide a
    // half: a model change regenerates every delegate, and a host that
    // switches to an icon-only selector from inside a wheel event would have
    // the items under the pointer destroyed mid-delivery. The natural size
    // measures only what is drawn.
    property bool labelsVisible: true
    property bool iconsVisible: true
    readonly property string _iconFamily: root.iconFontFamily !== "" ? root.iconFontFamily : root.fontFamily

    // --- Geometry ---
    // A host gives the selector its size through `width`/`height` like any
    // item, and the corner it must wear through `trackRadiusOverride` -- which
    // is how it takes the same radius as a container standing beside it
    // instead of the stadium it defaults to. The pill's own corner then falls
    // out of that one number (see `_pillRadius`): the two curves are
    // concentric, so the pill's corner and the track's coincide.
    property real trackRadiusOverride: -1
    property real pillRadiusOverride: -1
    property real pillInset: 3
    // Room around a label when the selector is asked for its natural size.
    // Along the track this is what separates two labels; across it, what the
    // pill has above and below the text, on top of the inset.
    property real slotPaddingAlong: 14
    property real slotPaddingAcross: 6
    property real iconSize: 14
    property real iconSpacing: 6
    property int fontPixelSize: 13

    // --- Animation ---
    property int animDuration: 220
    property int animEasing: Easing.OutCubic

    // --- Swipe ---
    // A two-finger horizontal swipe (reported as a horizontal wheel) moves the
    // selection one tab in that direction. Every parameter is exposed, because
    // the natural failure mode is a flick of a few millimetres skipping two
    // tabs at once.
    // The gesture itself is SwipeSteps (the shell's one sticky swipe, which the
    // workspaces' ball steps with too): these are its knobs, under this
    // selector's names, and its defaults are the system update's tuned values
    // so every selector in the shell wears the same feel unless a host has a
    // reason of its own. What each does is documented there.
    property alias swipeEnabled: swipe.enabled
    // When false the selector stops listening for wheel events itself and the
    // host drives `applySwipe()` instead. A selector is a small target, and a
    // swipe is a gesture aimed at the surface as a whole, not at the widget —
    // so the host usually wants to capture it across its whole area.
    property bool swipeSelfHandled: true
    property alias swipeThreshold: swipe.threshold      // wheel units that commit one tab
    property alias swipeMaxPull: swipe.maxPull          // the pill's lean, as a fraction of a slot
    property alias swipeIdleResetMs: swipe.idleResetMs  // the fallback for a device with no lift event
    property alias swipePullTaper: swipe.pullTaper      // >1 front-loads the lean
    property alias swipeMomentumRate: swipe.momentumRate    // units/s that counts as a flick
    property alias swipeCooldownMs: swipe.cooldownMs    // gap between slow-swipe commits

    // --- Squash and stretch ---
    // The pill elongates along its direction of travel and thins perpendicular
    // to it, conserving area. Kept subtler than the workspace ball: this is a
    // control, not a character.
    property bool squishEnabled: true
    property real squishMax: 0.18          // peak elongation, as a fraction
    property real squishVelocityRef: 850   // px/s at which peak is reached
    property real squishDecay: 0.82        // how quickly it relaxes once stopped

    signal tabChanged(string tabId)
    // A RIGHT click on a tab, which selects nothing: the host decides what a secondary press on a tab means (the
    // player's sidebar rescans its library on the active library tab). Emitted for any tab, current or not.
    signal tabSecondaryClicked(string tabId)

    readonly property bool _horizontal: orientation === "horizontal"

    // The engine, and what this selector reads of it. `_swipePull` is the lean in PIXELS
    // against the track as it is this frame (the engine speaks in slots, so a host that
    // resizes the selector mid-gesture carries the lean with the track).
    SwipeSteps {
        id: swipe
        count: root._tabCount
        index: root._currentIdx
        onStepped: (dir, to) => {
            const id = root.tabs[to].id;
            root.currentTab = id;
            root.tabChanged(id);
        }
    }
    readonly property real _swipeAccum: swipe.accum
    readonly property real _swipePull: swipe.pull * root._slotLength

    // ======================================================================
    // WHERE THE PILL IS: IN SLOTS, NEVER IN PIXELS
    //
    // `_pillSlot` is the one number the slide animates -- 0 is the first slot,
    // 1 the second -- and every pixel of the pill's rectangle is resolved from
    // it against THE TRACK AS IT IS THIS FRAME.
    //
    // Hosts resize this selector while it is running: the library's tab row
    // gives up 60 px when its Clear button appears and takes them back when it
    // goes. Animating `pill.x` in pixels instead would put three separate faults
    // into that one motion:
    //
    //   * THE SLIDE STALLS. `x`'s binding re-evaluates on every frame of the
    //     host's resize, and every re-evaluation restarts the Behavior's
    //     animation from where it stands. Restarts arriving as fast as (or
    //     faster than) the animation driver's own tick mean it barely
    //     advances at all -- measured: 0.0 % of the travel done by the time
    //     the 220 ms slide is due to be over, which reads as a stutter.
    //   * THE PILL IS LEFT BEHIND, in absolute space, while the track shrinks
    //     under it: measured 45 px outside its own container.
    //   * AND IT SQUISHES for a resize nobody asked for, because the velocity
    //     that drives the stretch is measured off `x`, which the resize
    //     moves: the pill ends up flatter than at normal rest.
    //
    // In slots none of those is expressible: a resize changes what a slot is
    // worth in pixels, not where the pill is on the track.
    // ======================================================================
    property real _pillSlot: root._currentIdx
    Behavior on _pillSlot {
        NumberAnimation {
            duration: root.animDuration
            easing.type: root.animEasing
        }
    }

    // The pill's position ALONG the track, in slots: what the animation moves
    // plus what a finger is pulling. This is what the stretch is measured
    // from, so a track resizing under a still pill cannot stretch it.
    readonly property real _pillTrackSlot: root._pillSlot
        + (root._slotLength > 0 ? swipe.pull : 0)

    // Live pill motion, sampled per frame while anything is moving.
    property real _pillVel: 0
    property real _pillLastSlot: 0
    property bool _sampled: false
    property int _motionTicks: 0
    // Below this the stretch is under a ten-thousandth and the pill is round
    // to the eye; snapping to zero here is what lets the sampler stop and
    // what guarantees the pill comes home to exactly its resting shape.
    readonly property real _velRest: 0.5
    readonly property real _squish: {
        if (!root.squishEnabled)
            return 0;
        return Math.min(1, Math.abs(root._pillVel) / Math.max(1, root.squishVelocityRef)) * root.squishMax;
    }

    // The pill's own along-axis extent and the track's, so the stretch can be
    // held inside the channel.
    readonly property real _trackLength: root._horizontal ? root.width : root.height
    readonly property real _pillAlong: Math.max(0, root._slotLength - root.pillInset * 2)

    // THE STRETCH MAY NOT TAKE THE PILL OUT OF THE CHANNEL IT RUNS IN.
    // At either end of the track there is only `pillInset` of room, and the
    // apron needs its own width out of that, so the elongation is capped at
    // whatever is left. Anywhere but the last few pixels of travel the cap is
    // far above `squishMax` and does nothing at all.
    readonly property real _stretchAlong: {
        const want = 1 + root._squish;
        const half = root._pillAlong / 2;
        if (half <= 0)
            return want;
        const centre = root._pillSlot * root._slotLength + root.pillInset + half + root._swipePull;
        const room = Math.min(centre, root._trackLength - centre) - root.pillShadowWidth;
        return Math.max(1, Math.min(want, room / half));
    }
    // Area conservation, so stretching one axis genuinely thins the other.
    readonly property real _stretchAcross: 1 / Math.max(0.01, _stretchAlong)

    readonly property real _pillScaleX: root._horizontal ? _stretchAlong : _stretchAcross
    readonly property real _pillScaleY: root._horizontal ? _stretchAcross : _stretchAlong

    // Pill rectangle in root coordinates, including pull and squish. Drives
    // both the pill's own transform and the label mask, so the two can never
    // disagree. Both axes, because the scissor has to cut on the axis the pill
    // MOVES on: a vertical selector clipped only in x would put every one of
    // its labels inside the window, so all three would be painted in the
    // ON-PILL colour and the two inactive ones would be near-white on a light
    // track.
    readonly property real _pillMaskX: pill.x + (root._horizontal ? root._swipePull : 0) + (1 - root._pillScaleX) * pill.width / 2
    readonly property real _pillMaskW: pill.width * root._pillScaleX
    readonly property real _pillMaskY: pill.y + (root._horizontal ? 0 : root._swipePull) + (1 - root._pillScaleY) * pill.height / 2
    readonly property real _pillMaskH: pill.height * root._pillScaleY

    // Per-frame sampler. Self-limiting: any movement resets the tick budget,
    // and it keeps running past the budget only while the pill is still
    // measurably moving, so there is no standing per-frame cost while the
    // selector is idle and no velocity can be left frozen in it either.
    FrameAnimation {
        running: root._motionTicks > 0 || Math.abs(root._pillVel) >= root._velRest
        // A burst always begins by TAKING a position rather than assuming one.
        // Seeding at the kick instead is a frame too early:
        // `currentTab` arrives before `tabs` does, so the seed is taken while
        // `_currentIdx` still reads 0, and a selector whose current tab is not
        // the first then reads the whole distance to its own slot as one
        // frame's travel -- 226 px/s of velocity out of nowhere, and a pill
        // that flashes 3 % flat for half a second every time the popup is
        // built.
        onRunningChanged: if (!running) root._sampled = false
        onTriggered: {
            const pos = root._pillTrackSlot;
            if (!root._sampled) {
                root._pillLastSlot = pos;
                root._sampled = true;
            }
            const dt = Math.max(0.001, frameTime);
            // Slots per second, read back into px/s against the track as it
            // stands now, so `squishVelocityRef` keeps meaning px/s.
            const v = (pos - root._pillLastSlot) / dt * root._slotLength;
            root._pillLastSlot = pos;
            // Smooth, then decay, so the stretch eases out on arrival rather
            // than snapping back to round the instant motion stops.
            root._pillVel = root._pillVel * root.squishDecay + v * (1 - root.squishDecay);
            root._motionTicks -= 1;
            if (Math.abs(root._pillVel) < root._velRest)
                root._pillVel = 0;
        }
    }
    function _kickMotion() {
        root._motionTicks = 45;
    }
    onCurrentTabChanged: _kickMotion()
    on_SwipePullChanged: _kickMotion()

    // Feed one delta into the gesture; 0 signals that it has ended (fingers lifted).
    // Public: a host that owns the wheel drives the selector through it.
    function applySwipe(d) {
        swipe.feed(d);
    }
    // A mouse's whole notches (WheelHub's `steps`, > 0 the next tab), from a host that owns the wheel.
    function applySteps(n) {
        swipe.notch(n);
    }

    // MouseArea rather than WheelHandler: a WheelHandler is shadowed by any
    // scrolling handler that happens to sit deeper in the scene, which stops
    // it working when the selector lives inside a popup full of scrollable
    // lists. Takes no buttons and never accepts fingers, so it
    // only observes.
    //
    // A MOUSE OVER THE SELECTOR ITSELF: one notch is one tab, whoever reads the swipes (a host's reader over its whole popup has the
    // sideways ones; the upright notch under the pointer is the selector's own). That one is kept.
    WheelArea {
        anchors.fill: parent
        enabled: root.swipeEnabled
        turned: wheel => {
            if (wheel.device === "wheel") {
                wheel.accepted = wheel.angleDelta.y !== 0 || root.swipeSelfHandled;
                if (wheel.accepted)
                    swipe.notch(wheel.steps);
                return;
            }
            wheel.accepted = false;
            if (!root.swipeSelfHandled)
                return;
            const a = root._horizontal ? wheel.angleDelta.x : wheel.angleDelta.y;
            const px = root._horizontal ? wheel.pixelDelta.x : wheel.pixelDelta.y;
            const dv = a !== 0 ? a : px * 2.5;
            swipe.feed(dv);
        }
    }

    // ---- Natural size ----------------------------------------------------
    // A host that states a width and a height gets exactly them, and the
    // track is divided into equal slots. This is only what the
    // selector asks for when it is asked -- and it is made of the tabs and
    // the font rather than of two magic numbers, so a five-tab selector in a
    // 10 px face and a two-tab one in a 13 px face do not both claim 260x36.
    //
    // Measured with FontMetrics, never by reading a Text's own width back
    // into what sizes it -- that is a binding loop.
    FontMetrics {
        id: _labelMetrics
        font.family: root.fontFamily
        font.pixelSize: root.fontPixelSize
    }
    FontMetrics {
        id: _iconMetrics
        font.family: root._iconFamily
        font.pixelSize: root.iconSize
    }
    readonly property real _widestTab: {
        // advanceWidth() is a method call and captures nothing: the metrics'
        // own fonts are read here so a face or size change re-measures.
        const lf = _labelMetrics.font;
        const icf = _iconMetrics.font;
        let w = 0;
        for (let i = 0; i < root.tabs.length; i++) {
            const t = root.tabs[i];
            const hasLabel = root.labelsVisible && !!t.label;
            const hasIcon = root.iconsVisible && !!t.icon;
            let tw = hasLabel ? _labelMetrics.advanceWidth(t.label) : 0;
            if (hasIcon)
                tw += _iconMetrics.advanceWidth(t.icon) + (hasLabel ? root.iconSpacing : 0);
            if (tw > w)
                w = tw;
        }
        return w;
    }
    readonly property real _naturalLong: Math.ceil(root._widestTab + 2 * root.slotPaddingAlong)
    readonly property real _naturalAcross: Math.ceil(Math.max(root.labelsVisible ? _labelMetrics.height : 0,
                                                              root.iconsVisible ? root.iconSize : 0)
        + 2 * (root.pillInset + root.slotPaddingAcross))

    implicitWidth: root._horizontal ? Math.max(1, root._tabCount) * root._naturalLong : root._naturalLong
    implicitHeight: root._horizontal ? root._naturalAcross : Math.max(1, root._tabCount) * root._naturalAcross

    readonly property int _tabCount: tabs.length
    readonly property int _currentIdx: {
        for (let i = 0; i < tabs.length; i++) {
            if (tabs[i].id === currentTab)
                return i;
        }
        return 0;
    }

    readonly property real _slotLength: _tabCount > 0 ? (_horizontal ? width / _tabCount : height / _tabCount) : 0

    readonly property real _trackRadius: trackRadiusOverride >= 0 ? trackRadiusOverride : (_horizontal ? height / 2 : width / 2)

    readonly property real _pillRadius: pillRadiusOverride >= 0 ? pillRadiusOverride : Math.max(0, _trackRadius - pillInset)

    // Pull ShadowBox from common/components — this file LIVES in that folder
    // so we import the sibling via relative "./".
    ShadowBox {
        id: track
        anchors.fill: parent
        baseWidth: width
        baseHeight: height
        baseRadius: root._trackRadius
        surfaceColor: root.trackSurfaceColor
        bevelColor: root.trackBevelColor
        shadowColor: root.trackShadowColor
        backgroundColor: root.trackBackgroundColor
        bevelWidth: root.trackBevelWidth
        shadowWidth: root.trackShadowWidth
        shadowFalloff: root.trackShadowFalloff
    }

    ShadowBox {
        id: pill
        // Resolved from the pill's slot against THIS FRAME's track, so a track
        // that resizes carries the pill with it instead of leaving it standing
        // in absolute space. Nothing here eases -- the easing is on
        // `_pillSlot`, one clock for the one motion.
        x: root._horizontal ? root._pillSlot * root._slotLength + root.pillInset : root.pillInset
        y: root._horizontal ? root.pillInset : root._pillSlot * root._slotLength + root.pillInset

        // The gesture pull is a TRANSFORM, not part of x/y.
        //
        // x and y are resolved from `_pillSlot`, and `_pillSlot` is the one
        // thing the 220 ms Behavior eases. Folding the live pull into the slot
        // would put that animation between the finger and the pill, and the
        // drag would feel chased rather than followed. As a transform the pull
        // is immediate, and the Behavior is left to do only the job it is
        // there for.
        transform: [
            Scale {
                origin.x: pill.width / 2
                origin.y: pill.height / 2
                xScale: root._pillScaleX
                yScale: root._pillScaleY
            },
            Translate {
                x: root._horizontal ? root._swipePull : 0
                y: root._horizontal ? 0 : root._swipePull
            }
        ]
        baseWidth: Math.max(0, root._horizontal ? root._slotLength - root.pillInset * 2 : root.width - root.pillInset * 2)
        baseHeight: Math.max(0, root._horizontal ? root.height - root.pillInset * 2 : root._slotLength - root.pillInset * 2)
        baseRadius: root._pillRadius
        raised: true
        surfaceColor: root.pillSurfaceColor
        bevelColor: root.pillBevelColor
        shadowColor: root.pillShadowColor
        backgroundColor: root.pillBackgroundColor
        bevelWidth: root.pillBevelWidth
        shadowWidth: root.pillShadowWidth
        shadowEdgeAlpha: root.pillShadowEdgeAlpha
    }

    // One tab's icon + label at a given tint. Used twice per tab: once in the
    // inactive colour as the base, once in the active colour clipped to the
    // pill. Identical geometry both times, so the two line up exactly.
    component TabLabel: Row {
        property color tint: "#000000"
        property string iconText: ""
        property string labelText: ""
        readonly property bool iconShown: root.iconsVisible && !!iconText
        readonly property bool labelShown: root.labelsVisible && !!labelText
        spacing: (iconShown && labelShown) ? root.iconSpacing : 0

        Text {
            visible: parent.iconShown
            text: parent.iconText
            font.pixelSize: root.iconSize
            font.family: root._iconFamily
            color: parent.tint
            anchors.verticalCenter: parent.verticalCenter
        }
        Text {
            visible: parent.labelShown
            text: parent.labelText
            font.pixelSize: root.fontPixelSize
            font.family: root.fontFamily
            color: parent.tint
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    Item {
        anchors.fill: parent

        Repeater {
            model: root.tabs
            delegate: Item {
                id: tabCell
                required property int index
                required property var modelData

                readonly property bool isActive: root._currentIdx === tabCell.index

                x: root._horizontal ? tabCell.index * root._slotLength : 0
                y: root._horizontal ? 0 : tabCell.index * root._slotLength
                width: root._horizontal ? root._slotLength : root.width
                height: root._horizontal ? root.height : root._slotLength

                // A LABEL FADES BEFORE ITS SLOT CAN CRUSH IT. Labels are
                // centred in their slot with no elide and no clip, so a
                // selector squeezed below its natural width -- a sidebar
                // mid-reveal, a host easing a layout -- would run its three
                // labels into one another.
                // Fully drawn while the slot has the label's width plus a
                // little air; gone by the time the slot is `labelFadeFloor`
                // of the label. At every resting size in the shell the slot
                // is wider than that, so this draws nothing differently at
                // rest.
                readonly property real _along: root._horizontal ? tabCell.width : tabCell.height
                readonly property real _need: root._horizontal ? baseLabel.implicitWidth : baseLabel.implicitHeight
                opacity: {
                    const full = tabCell._need + root.labelFadeAir;
                    const none = tabCell._need * root.labelFadeFloor;
                    if (full <= none) return 1;
                    return Math.max(0, Math.min(1, (tabCell._along - none) / (full - none)));
                }

                // Colour comes from WHERE THE PILL IS, not from which tab
                // is selected.
                //
                // Tying it to selection would mean that the moment the pill is
                // dragged out from under a label, light text is left sitting
                // on the light track. Two layers and a clip solve it per pixel:
                // the base is always the inactive colour, and a copy in the
                // active colour is clipped to the pill's live rectangle. Half a
                // glyph outside the pill is drawn half in each colour, because
                // the clip is a scissor rectangle, not a per-item test.
                //
                // Cost is one extra Text pair per tab and one scissor rect —
                // no shader, no per-frame script — so it needs no gating.
                TabLabel {
                    id: baseLabel
                    anchors.centerIn: parent
                    tint: root.textColor
                    iconText: tabCell.modelData.icon || ""
                    labelText: tabCell.modelData.label || ""
                }

                Item {
                    id: pillWindow
                    // The window is the pill's own extent along the axis it
                    // travels on, and the whole cell across it -- so a label
                    // is only ever tinted by a pill that is actually over it.
                    x: root._horizontal ? root._pillMaskX - tabCell.x : 0
                    y: root._horizontal ? 0 : root._pillMaskY - tabCell.y
                    width: root._horizontal ? Math.max(0, root._pillMaskW) : tabCell.width
                    height: root._horizontal ? tabCell.height : Math.max(0, root._pillMaskH)
                    clip: true
                    visible: width > 0 && height > 0

                    TabLabel {
                        // Positioned so it lands exactly on top of the base.
                        x: baseLabel.x - pillWindow.x
                        y: baseLabel.y - pillWindow.y
                        tint: root.activeTextColor
                        iconText: tabCell.modelData.icon || ""
                        labelText: tabCell.modelData.label || ""
                    }
                }

                MouseArea {
                    id: cellArea
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    hoverEnabled: !!tabCell.modelData.tip
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    onClicked: mouse => {
                        if (mouse.button === Qt.RightButton) {
                            root.tabSecondaryClicked(tabCell.modelData.id);
                            return;
                        }
                        root.currentTab = tabCell.modelData.id;
                        root.tabChanged(tabCell.modelData.id);
                    }
                }

                // Built only for a tab that has a tip.
                Loader {
                    active: !!tabCell.modelData.tip
                    sourceComponent: HoverTip {
                        show: cellArea.containsMouse
                        anchorItem: tabCell
                        overlayItem: root.overlayItem
                        side: root.tipSide
                        text: tabCell.modelData.tip || ""
                        fontFamily: root.fontFamily
                        fontPixelSize: Math.max(10, root.fontPixelSize - 1)
                    }
                }
            }
        }
    }
}
