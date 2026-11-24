pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/float"
import "data/WeatherModel.js" as WM
import "data/PlaceBlend.js" as PB
import "../common/scroll"

// =============================================================================
// WeatherPopup.qml -- the weather module's primary popup: the drop-in for
// thePopup, and the root that declares the engine's content
// contract for its detail screen.
//
// It takes ONE object, `service` (WeatherService or WeatherMock: the same
// interface), and reads only the members that interface lists. Everything visual is one of four
// children, each a carved card that reads the model through `popup`:
//
//   WeatherHero          the prevalent card: glyph, temperature, condition,
//                        the KMI observation, H/L, feels-like, the context
//                        line; the backdrop moves under it
//   WeatherHourlyStrip   48 hours in 44 px columns, nine views of them
//   WeatherDailyList     16 days, seven views of them
//   WeatherTiles         the ten niche metrics
//
// THREE VIEWS, each a first-class layout sized through implicitWidth /
// implicitHeight, switched by the TabSelector or a two-finger horizontal
// swipe (docs/contracts/gestures.md):
//
//   mini       header + the compact hero; the selector shows icons only, so
//              the location name keeps the header
//   normal     header, hero, strip, list in one column
//   detailed   two columns of one height. Left: the hero at its own height,
//              the list filling the rest. Right: the strip at its own height,
//              the tiles (three columns) filling the rest. The hero and the
//              list share their right edge; the split between the columns is
//              a vertical line, the splits inside them sit at different
//              heights.
//
// Nothing is laid out by a Layout: every card's rect comes from `_drawn`, the
// view's layout on the popup's live width, and a switch MOVES the cards that
// both views show (THE VIEW MORPH, below) while the host eases the popup's
// size; the cards a view does not show fade their PRESENCE in or out over
// `fadeMs` where they stand. Nothing crossfades two layouts through each
// other. A view switch closes the detail.
//
// THE SWIPE RULE (the one wheel reader). One MouseArea over the whole popup
// observes every wheel event and never accepts it. Ownership is latched when
// a gesture begins, from what is under the pointer, and held until the
// fingers lift (the zero-delta event) or `gestureIdleEndMs` of silence; the
// axis is the first one clearly ahead (x1.2) and is kept too:
//
//   owner    axis x                                axis y
//   strip    scrolls the hours                     cycles the strip's view
//   list     cycles the list's view                the list's own dressing
//   popup    switches the popup's view             nothing
//
// THE STRIP'S VIEW DOT FOLLOWS THE HAND: a swipe down moves the dot down one. The strip's vertical cycle
// steps to the NEXT view (its dot one down) when the hand moves down: a touchpad's fingers down (pixels, y > 0 here) or a
// mouse notch toward you (angle y < 0). Its sideways scroll is the shell's one feel: the content follows the fingers
// (`stripScrollReversed` false).
//
// The daily list's own wheel reads only a latched vertical axis the strip does
// not own, so nothing else ever reads the same event: not the undecided first
// events of a diagonal, not a sideways gesture's drifting y, not a strip notch
// the pointer carries onto the list. The owner is taken BEFORE the gesture
// grows this reader, whose geometry the pointer's position is measured in.
// `swipeToSwitchView` turns off only the popup's own view switch; the cards'
// scroll and cycles always run. A cycle step counts units against a notch
// threshold, or against a pixel threshold when the event carried only a pixel
// delta on that axis (`fromPixels`).
//
// THE DETAIL. A click on any link -- the hero's glyph, a column, a row, a
// tile -- calls `openDetail(key, anchor)`: the same key closes it, another
// sets the anchor (the item's centre in this popup's coordinates), the key,
// and opens. A key names its link: `from` is "hero", "hourly", "daily" or
// "tile". The primary never hosts the detail; the engine grows it out of
// this popup's `detailSide` and assigns `secondaryKey` to the WeatherDetail
// it builds from `secondaryComponent`.
//
// THE FLOAT (modules/common/float; `cardFloat` turns it off). The ten detail
// tiles are cards: each sways, leans towards the pointer and lifts under it,
// on the popup's ONE FloatClock. The hero, the strip and the list are part
// of the page -- hundreds of items each, and lists that must read as one
// thing -- so they never sway: they only join the deal when the popup opens
// (a transform on their hosts, never a re-layout: presence, not layout).
// The clock runs while the popup is on screen and not parked, holds still
// under a theme crossfade, deals again at every open of a recycled content,
// and at rest steps on the backdrop's own 30 Hz beat (beat()), so the sway
// costs no frame of its own; every frame only while a deal lands or the
// pointer pulls a tile. While it runs the strip and the list are held as
// layers (below) whether or not the backdrop runs; the tiles' host is not
// (its tiles move every tick, and a layer would re-render with them).
//
// Figures sit in FontMetrics-measured slots (each child measures its own,
// reading the metrics' font inside the helper so a face change re-measures).
// Theme tokens only; no colour is animated here or below.
// =============================================================================
Item {
    id: root

    // ---- Contract (§6) ----------------------------------------------------
    property var service: null
    property string viewMode: "normal"           // "mini" | "normal" | "detailed"
    // The view a recycled content goes back to as it is parked ("" keeps the one it was left on): the host's "every open on one view".
    property string resetView: ""
    property string fontFamily: "Inter"
    property string detailSide: "far"
    property bool backdropEnabled: true
    property real ambientHz: 30
    // The host's hand on the backdrop's clock: thePopup sets it false while
    // the popup is closed or hidden, so a hero nobody sees asks for no frame.
    property bool backdropRunning: true
    // The engine's: true while this content was built AHEAD of a click and is held hidden (GooeyEngine.prebuild).
    // The two clocks that run here are the hero's backdrop and the tiles' float (THE FLOAT), which both stop when the popup is not
    // on screen (`backdropRunning`, the owner's) and when it is not visible; a parked content runs nothing.
    property bool parked: false
    // What the host magnifies the popup by (the mockup's stage zoom). Only the
    // static layers read it: their textures are allocated at that scale so a
    // zoomed stage does not show them soft.
    property real renderScale: 1
    // WHILE THE BACKDROP TICKS, THE REST OF THE POPUP IS THREE TEXTURES. A
    // uniform changing 30 times a second makes Qt Quick redraw the whole
    // window each time, and this popup is ~70 carved boxes, ~65 glyph shaders
    // and a few hundred texts: measured at 1.26 ms of CPU and 0.7 ms of GPU per
    // tick with everything drawn, and the backdrop alone is a fifth of that.
    // So the hourly strip, the daily list and the tile grid are held as
    // layers while the backdrop runs -- rendered once, re-rendered only when
    // their own content changes (a scroll, a hover fade) -- and dropped at
    // rest, so a still popup is the plain scene graph (a fidelity grab of
    // it is byte for byte the unlayered picture). Cards sit on whole pixels
    // (below) so the textures are never resampled.
    property bool staticLayers: true
    // Whole pixels of room a layer keeps around its item, for the bevel a
    // carved box draws outside its own rect (ShadowBox: bevelWidth + 1), so at
    // least ceil(cardBevelWidth) + 2. A property, not a constant, so a
    // test can set it to 1 or 0 and watch the sheared
    // bevel fail it.
    property int layerSlack: 4
    // Not tied to the view: a wheel that switches the view to mini would
    // otherwise flip this INSIDE the event's delivery and destroy the layer
    // items the delivery is walking (measured: a segfault in
    // QQuickDeliveryAgentPrivate::deliverSinglePointEventUntilAccepted). A
    // view that does not show a card fades its host out and makes it
    // invisible on its own clock, and an invisible layer is not rendered.
    readonly property bool _layered: root.staticLayers && root.backdropRunning && !!root.model && (root.backdropEnabled || root.cardFloat)

    // ---- The float (THE FLOAT, above) ---------------------------------------
    property bool cardFloat: true
    // The weather's own float numbers are the lines in here (mockups/weather_popup.qml's Float tab writes them): thirteen places are
    // dealt (three wide cards, ten tiles), so they follow each other a little closer than the theme's eight.
    property FloatStyle floatStyle: FloatStyle {
        dealStaggerMs: 35
    }
    // How far the wide cards (hero, strip, list) turn as they are dealt, in
    // degrees: a card's turn moves its corners by half its width times the
    // angle, so the wide ones turn less than a tile does.
    property real wideDealTurn: 0.8
    readonly property alias floatClock: cardClock
    FloatClock {
        id: cardClock
        running: root.cardFloat && root.backdropRunning && !root.parked && root.visible
        // its own beat only when the backdrop's does not come (no backdrop, no model): the notes' rate
        restHz: 20
        bareDeals: 3
        style: root.floatStyle
    }
    // A recycled or prebuilt content is dealt again when it is shown.
    onParkedChanged: {
        if (!root.parked)
            cardClock.restartDeal();
    }
    // The rest beat is the backdrop's own tick while it runs: one beat, one frame.
    Connections {
        target: heroCard.backdrop
        function onTickCountChanged() {
            cardClock.beat();
        }
    }
    // The deal of the wide cards: how far each still has to come (FloatClock.dealLeftAt).
    readonly property real _heroDeal: root.cardFloat ? cardClock.dealLeftAt(0, root.floatStyle) : 0
    readonly property real _stripDeal: root.cardFloat ? cardClock.dealLeftAt(1, root.floatStyle) : 0
    readonly property real _listDeal: root.cardFloat ? cardClock.dealLeftAt(2, root.floatStyle) : 0

    // ---- The engine's content contract (§5) --------------------------------
    property Component secondaryComponent: Component {
        WeatherDetail {
            service: root.service
            fontFamily: root.fontFamily
            compact: root.detailStyle.compact
            chartHeight: root.detailStyle.chartHeight
            chipWidth: root.detailStyle.chipWidth
            chipGap: root.detailStyle.chipGap
            cardRadius: root.detailStyle.cardRadius
            titleSize: root.detailStyle.titleSize
            bodySize: root.detailStyle.bodySize
            figureSize: root.detailStyle.figureSize
            temperatureMinSpan: root.detailStyle.temperatureMinSpan
            pressureMinSpan: root.detailStyle.pressureMinSpan
            morphMs: root.detailStyle.morphMs
            swipeToSwitchDay: root.detailStyle.swipeToSwitchDay
            swipeNotchThreshold: root.detailStyle.swipeNotchThreshold
            swipePixelThreshold: root.detailStyle.swipePixelThreshold
            swipeStepCooldownMs: root.detailStyle.swipeStepCooldownMs
            // One number each across the popup: the device scaling, the
            // gesture's silent end and the wheel's speed.
            swipePixelToAngle: root.swipePixelToAngle
            gestureIdleEndMs: root.gestureIdleEndMs
            scrollSpeed: root.scrollSpeed
            cardBevelWidth: root.cardBevelWidth
            cardShadowWidth: root.cardShadowWidth
            cardShadowFalloff: root.cardShadowFalloff
            cardBevelColor: root.cardBevelColor
            insetBevelWidth: root.insetBevelWidth
            insetShadowWidth: root.insetShadowWidth
            insetShadowFalloff: root.insetShadowFalloff
            glyphStyle: root.glyphStyle
            glyphFlourishMs: root.glyphFlourishMs
        }
    }
    property bool secondaryOpen: false
    property point secondaryAnchor: Qt.point(0, 0)
    property string secondarySide: root.detailSide
    property bool secondaryOverhang: false
    property real secondaryInset: 0
    property var secondaryKey: null

    // The key the links highlight against: the open detail's, or nothing.
    readonly property var activeKey: root.secondaryOpen ? root.secondaryKey : null

    // A new layout is a new set of links: whatever the detail was anchored on
    // may not be drawn any more, so a view switch always closes it.
    onViewModeChanged: {
        root._ensureCards();
        root._startMorph();
        root.secondaryOpen = false;
        // A click or a swipe step writes TabSelector.currentTab itself, which
        // cuts the `currentTab: root.viewMode` binding for good: the pill would
        // stay where the selector last put it and the next swipe would step
        // from there. The truth is put back whenever the view moves.
        if (modeTabs.currentTab !== root.viewMode)
            modeTabs.currentTab = root.viewMode;
    }

    // Metric, day and hour; and the link it came from when both keys say.
    function sameKey(a, b) {
        if (!a || !b)
            return false;
        const h = function (k) { return (typeof k.hourIndex === "number") ? k.hourIndex : null; };
        if (a.metric !== b.metric || (a.dayIndex | 0) !== (b.dayIndex | 0) || h(a) !== h(b))
            return false;
        return !(a.from && b.from) || a.from === b.from;
    }
    // The links call this. `anchor` is the clicked item's centre in this
    // popup's coordinates.
    function openDetail(key, anchor) {
        if (root.secondaryOpen && root.sameKey(root.secondaryKey, key)) {
            root.secondaryOpen = false;
            return;
        }
        root.secondaryAnchor = anchor;
        root.secondaryKey = key;
        root.secondaryOpen = true;
    }
    // Escape's step back (GooeyEngine.stepBack, asked only under shell.jsonc `"escape": "detail"`): the detail goes; true when one was open
    function stepBack(): bool {
        const was = root.secondaryOpen;
        root.secondaryOpen = false;
        return was;
    }
    // The item a key is the link of -- the column, row, tile or hero glyph
    // its `from` names -- when this view draws it, else null: what a host
    // clicks, and where a probe measures. A key without `from` names no link.
    function linkItem(key) {
        if (!key)
            return null;
        const hour = typeof key.hourIndex === "number" ? key.hourIndex : null;
        switch (key.from) {
        case "hero":
            return heroCard.glyphItem;
        case "hourly":
            return root._shows("strip") && hour !== null && root.hourlyStrip ? root.hourlyStrip.columnItem(key.dayIndex | 0, hour) : null;
        case "daily":
            return root._shows("list") && root.dailyList ? root.dailyList.rowItem(key.dayIndex | 0) : null;
        case "tile":
            return root._shows("tiles") && root.tileGrid ? root.tileGrid.tileItem(key.metric) : null;
        default:
            return null;
        }
    }
    function anchorFor(key) {
        const it = root.linkItem(key);
        return it ? it.mapToItem(root, it.width / 2, it.height / 2) : Qt.point(root.width / 2, root.height / 2);
    }
    // Whether the current view draws a card ("strip", "list", "tiles").
    function _shows(card) {
        if (card === "tiles")
            return root.detailed;
        return !root.mini;
    }

    // ---- Layout knobs --------------------------------------------------------
    property real padding: 12
    property real cardPadding: 12
    property real radius: 14
    // The hero is ONE card in every view (mini's must look like the
    // others apart from its width), so mini is the detailed view's left column
    // and its padding: 480 + 2 x 12. Its text column (218 px in Audiowide) holds
    // every condition and the common observation and context lines.
    property real miniWidth: 504
    property real normalWidth: 720
    property real detailedWidth: 1180
    // The hero's and the daily list's width in the detailed view; the strip
    // and the tiles take the rest of the row.
    property real detailedLeftWidth: 480
    // The view selector shows icons in EVERY view (the words are its tips). Its
    // natural width is 126 (a 13.3 px icon advance + 14 px either side, x3); 132 gives each pill 38 px.
    property real tabWidth: 132
    property real tabIconSize: 16
    property real headerHeight: 32
    property int fadeMs: 160
    // The skeletons' breathing. Off for a still render.
    property bool skeletonPulse: true

    // ---- The carve, one set for every carved box in the popup and its detail ---
    // Three depths: the cards themselves; the boxes carved inside a card (the
    // view-title box, chips); the thin grooves and tracks.
    // Every reader falls back to these same values when it has no popup.
    //
    // THE CARVE. The depths are the plain ones (3 px inset, falloff 1, no lift). The knobs stay, so the panel can try
    // a deeper carve (2/9, falloff 0.5, a rim lifted toward the button highlight): what deepens it is the FALLOFF and the rim LIFT, not the
    // widths -- the inset is capped at Theme.border and ShadowBox's ease-out
    // keeps its depth in the first two pixels.
    property real cardBevelWidth: 1
    property real cardShadowWidth: 3
    // How the cards' inset shadow decays inward (ShadowBox.shadowFalloff):
    // below 1 it lingers past the first pixels instead of reading as a border.
    property real cardShadowFalloff: 1
    // How far the cards' bevel rim lifts from Theme.bevel toward
    // Theme.buttonBevel (the raised buttons' highlight). At 1 the rim is a
    // white line in light mode and a grey outline in dark: a border again.
    property real cardBevelLift: 0
    // The cards' bevel rim colour: a binding on theme tokens, never written
    // from the panel (the lift is the knob).
    property color cardBevelColor: Mix.c(Theme.bevel, Theme.buttonBevel, root.cardBevelLift)
    // A chance of precipitation under this percentage is not drawn, as a bar or
    // a figure, by the hourly strip or the daily list: under it the 2 px floor
    // would turn every dry hour into a dot. One number for both cards.
    property real probLabelMin: 10
    // THE BOXES INSIDE A CARD (the view-title box, the
    // detail's chips and tracks) carve like the cards, with a falloff of their
    // own; their rims read `cardBevelColor`: one rim colour for the popup.
    property real insetBevelWidth: 1
    property real insetShadowWidth: 3
    property real insetShadowFalloff: 1
    property real grooveBevelWidth: 1
    property real grooveShadowWidth: 1.5

    // ---- The backdrop's knobs, passed into the hero ----------------------------
    property real backdropStrength: 1.0
    property string backdropRenderer: "shader"
    // "v2" (the redone scenes) or "v1" (the first set, kept for comparison
    // until the bar is deployed, then deleted with its shader).
    property string backdropStyle: "v2"
    // v2's contrast limiter: the scene's luminance change against the card
    // passes unchanged up to toneKnee and is eased into toneCap above it; point
    // lights (star cores, glints) are laid over it under sparkCap.
    property real backdropToneKnee: 0.07
    property real backdropToneCap: 0.11
    property real backdropSparkCap: 0.24

    // ---- The glyph carve, one set for every glyph in the popup ----------------
    property real glyphBevelWidth: 1.25
    property real glyphShadowWidth: 0.1
    property real glyphShadowTint: 0
    property real glyphBodyTint: 1
    property real glyphBevelAlpha: 1
    property real glyphShadowEdgeAlpha: 1.0
    property real glyphShadowFalloff: 1.0
    property real glyphPartShadowShare: 0.9
    // One beat of a glyph's flourish in the popup, ms (WeatherInkPose.js; the bar's is WeatherBarButton.flourishMs). A glyph
    // flourishes when its item is picked: the hero's under the pointer, a column, a row, a tile or a chip when clicked.
    property int glyphFlourishMs: 900
    readonly property var glyphStyle: ({
        bevelWidth: root.glyphBevelWidth, shadowWidth: root.glyphShadowWidth,
        shadowTint: root.glyphShadowTint, bodyTint: root.glyphBodyTint,
        bevelAlpha: root.glyphBevelAlpha, shadowEdgeAlpha: root.glyphShadowEdgeAlpha,
        shadowFalloff: root.glyphShadowFalloff, partShadowShare: root.glyphPartShadowShare
    })

    // ---- The detail's knobs, bound into the Component above ---------------------
    property bool detailCompact: false
    property real detailChartHeight: 176
    property real detailChipWidth: 50
    property real detailChipGap: 4
    property real detailCardRadius: 14
    property int detailTitleSize: 16
    property int detailBodySize: 12
    property int detailFigureSize: 11
    // The detail chart's minimum axis spans (WeatherSeries.js has the table and
    // the reasons): a flat day is drawn flat.
    property real detailTemperatureMinSpan: 10
    property real detailPressureMinSpan: 20
    // A day change morphs every chart on one clock; a sideways swipe over the
    // detail steps the day (WheelStepper's counting, as the cards' views).
    property int detailMorphMs: 260
    property bool detailSwipeToSwitchDay: true
    property real detailSwipeNotchThreshold: 120
    property real detailSwipePixelThreshold: 1000
    property int detailSwipeStepCooldownMs: 200
    readonly property var detailStyle: ({
        compact: root.detailCompact, chartHeight: root.detailChartHeight,
        chipWidth: root.detailChipWidth, chipGap: root.detailChipGap,
        cardRadius: root.detailCardRadius, titleSize: root.detailTitleSize,
        bodySize: root.detailBodySize, figureSize: root.detailFigureSize,
        temperatureMinSpan: root.detailTemperatureMinSpan, pressureMinSpan: root.detailPressureMinSpan,
        morphMs: root.detailMorphMs, swipeToSwitchDay: root.detailSwipeToSwitchDay,
        swipeNotchThreshold: root.detailSwipeNotchThreshold, swipePixelThreshold: root.detailSwipePixelThreshold,
        swipeStepCooldownMs: root.detailSwipeStepCooldownMs
    })

    // ---- Swipe / pill tuning (passed to the TabSelector) ----------------------
    // The numbers are TabSelector's own defaults, the system update's tuned
    // ones; they live here so the mockup's panel can tune them on the popup.
    property bool swipeToSwitchView: true
    // The hourly strip's sideways sense: false = the content follows the fingers (the shell's one scroll feel), true = dx > 0
    // goes to later hours. See THE STRIP'S VIEW DOT FOLLOWS THE HAND.
    property bool stripScrollReversed: false
    property real swipePixelToAngle: 2.5
    property real swipeThreshold: 1500
    property real swipePullTaper: 2.5
    property real swipeMaxPull: 0.42
    property real swipeMomentumRate: 2400
    property int swipeCooldownMs: 320
    property real scrollSpeed: 1.0
    property int gestureIdleEndMs: 260

    // ---- The cards' views, for a host that remembers them ------------------------------
    // The engine builds this popup on open and destroys it on close, and the strip's nine
    // views and the list's seven are the user's choice. A host hands them back in
    // `stripViewStart` / `listViewStart` (the cards are built ON them, at rest) and reads
    // them off `stripViewIndex` / `listViewIndex` as they change; nothing here writes an
    // input, so a host's binding on a Start is never broken.
    property int stripViewStart: 0
    property int listViewStart: 0
    // What a card was never built to show is still the view the host remembered.
    readonly property int stripViewIndex: root.hourlyStrip ? root.hourlyStrip.viewIndex : root.stripViewStart
    readonly property int listViewIndex: root.dailyList ? root.dailyList.viewIndex : root.listViewStart

    // ---- What the children read -------------------------------------------------
    // The model the cards draw. It follows the service's, but through `_takeModel`: a change of PLACE is announced to the cards
    // first (THE PLACE MORPH, below), so they can keep what they draw and move from it. It is bound for the object's creation only
    // (a content built on a service that has its model is born with it, no skeleton to fade out of) and assigned from then on.
    property var model: root.service ? root.service.model : null
    readonly property bool loading: root.service ? !!root.service.loading : false
    readonly property bool offline: root.service ? !!root.service.offline : false
    readonly property var fmt: WM.format(root.service && root.service.config ? root.service.config.units : ({}))
    readonly property bool mini: root.viewMode === "mini"
    readonly property bool detailed: root.viewMode === "detailed"

    readonly property alias hero: heroCard
    readonly property alias modeTabs: modeTabs
    // The location link's own extent, for a harness (the tip's probe reads where the tip stands against it).
    readonly property Item locationHit: nameHit

    // ---- Size ---------------------------------------------------------------
    // Every card height is a whole pixel, and so is every sum of them: text
    // rasters the same way twice only on the grid, and a layer at a fractional
    // position is resampled.
    readonly property real _p: Math.round(root.padding)
    readonly property real _innerW: root.width - 2 * root._p
    readonly property real _heroY: root._p + Math.round(root.headerHeight) + root._p
    readonly property real _heroH: Math.round(heroCard.implicitHeight)
    readonly property real _stripH: root.hourlyStrip ? Math.round(root.hourlyStrip.implicitHeight) : 0
    readonly property real _listH: root.dailyList ? Math.round(root.dailyList.implicitHeight) : 0
    readonly property real _tilesH3: root.tileGrid ? Math.round(root.tileGrid.heightFor(3)) : 0
    readonly property real _leftW: Math.round(root.detailedLeftWidth)
    // The detailed view's two columns end on one line: the taller stack sets
    // it, and the list (left) and the tiles (right) take what their column
    // has left.
    readonly property real _colH: Math.max(root._heroH + root._p + root._listH,
                                           root._stripH + root._p + root._tilesH3)
    readonly property real _heightMini: root._heroY + root._heroH + root._p
    readonly property real _heightNormal: root._heroY + root._heroH + root._p + root._stripH + root._p + root._listH + root._p
    readonly property real _heightDetailed: root._heroY + root._colH + root._p

    // ---- THE PLACE MORPH -----------------------------------------------------------
    // A CHANGE OF PLACE IS A MORPH (feedback/weather.md, "morph transitions when changing locations"): the module already
    // morphs graphs and bars into one another, so a change of the selected location uses the same motion, for the polish
    // it adds to the feel of the module.
    //
    // When the selected place changes and both the old and the new have a model, every card MOVES from the old place's picture to
    // the new one's instead of swapping: the hourly strip's lines and bars, the daily list's ranges and bars, the tiles' bars, needle,
    // marks and moon, the hero's nowcast bars, the open detail's chart. Words swap at once (the text rule) and so do the glyphs'
    // kinds; the figures that have a bar or a line take that bar's or line's motion. ONE clock (`placeClock`, a ViewBlend over
    // `placeMs`, OutCubic -- the chart's morph clock, so the open detail's chart, which runs its own, moves in step with it) drives
    // every card through `placeE`.
    //
    // THE ORDER IS THE POINT. A card keeps what it DRAWS, not what it was last given, so a place change in the middle of a morph
    // starts from what is on screen; to do that it has to hear of the change BEFORE its inputs move. The popup is the one funnel:
    // `_takeModel` tells every built card `placeBegin()` (it snapshots its drawn picture), restarts the clock at zero and
    // only then writes `model`: at zero every card's picture is its snapshot, so no intermediate state is a real-looking picture, and
    // a card that is not built yet is simply built on the new model.
    //
    // A place with NO cache is a real wait (the service publishes no model while it fetches, and the skeleton stands in): there is
    // no old picture to move from when its data lands, so it is not a morph -- the card fades in from the skeleton. The
    // service's minute tick rebuilds the SAME place for the clock: the figures take those values at once. But
    // DATA that arrives for the place on screen -- the fresh forecast after the cache it was shown from, the next radar -- is a
    // morph too (PB.morphs, the service's `dataSerial`): otherwise the place would morph and then SNAP to the fetched
    // data. It goes through the same funnel, so a fetch that lands in the middle of a morph starts from what is on screen.
    // `placeMs` 0 turns the morph off (a switch is then one frame).
    property int placeMs: 260
    readonly property real placeE: placeClock.progress
    // True from the switch until the clock has run out; the cards read it (and `placeE`) to decide between their target and the
    // picture between.
    property bool placeMorphing: false
    property int _placeSerial: 0
    ViewBlend {
        id: placeClock
        count: 2
        target: root._placeSerial % 2
        durationMs: root.placeMs
        onTicked: {
            if (root.placeMorphing && placeClock.progress >= 1)
                root.placeMorphing = false;
        }
    }
    function _takeModel(m) {
        const old = root.model;
        if (old === m)
            return;
        const morph = root.placeMs > 0 && root._built && !!old && !!m && PB.morphs(old, m);
        if (!morph) {
            if (!m) {
                placeClock.pin(1);
                root.placeMorphing = false;
            }
            root.model = m;
            return;
        }
        const cards = [heroCard, root.hourlyStrip, root.dailyList, root.tileGrid];
        for (const c of cards) {
            if (c)
                c.placeBegin();
        }
        root._placeSerial++;
        root.placeMorphing = true;
        root.model = m;
    }
    onServiceChanged: root._takeModel(root.service ? root.service.model : null)
    Connections {
        target: root.service
        function onModelChanged() {
            root._takeModel(root.service.model);
        }
    }
    // For a harness: hold the place morph at linear time t (a still of it).
    function pinPlaceMorph(t) {
        placeClock.pin(t);
    }

    // ---- THE VIEW MORPH -------------------------------------------------------
    // A card the views share stays in place and resizes appropriately; cards do not just appear and disappear out of nowhere
    // when they were already present in the view before.
    //
    // A card both views show MOVES from where it is drawn to its new place; a
    // card the new view does not show stays where it is drawn and fades out; a
    // card the new view adds appears at its place and fades in. Between mini
    // and the others the one card they share, the hero, already follows the
    // popup's box as the host eases it (its width is the box's), so those
    // switches move nothing else.
    //
    // Between normal and detailed the hero, the strip and the list all move,
    // and the strip moves INTO the room the hero leaves. Moving in two phases,
    // horizontal then vertical, 400 ms, would keep them from ever touching but leaves a giant whitespace for a
    // considerable time: the strip gone, the list still waiting for its phase, the host's
    // box already wide and the tiles last of all (55 % of the popup empty at 160 ms,
    // 21 % still at 400); a tiny collision near the end looks better than staring at
    // that white hole. So the
    // moves run together, fast, and the cards are STACKED -- hero over
    // strip over list over tiles -- so where two meet the lower one slides
    // under the upper one, as cards do, instead of crossing it:
    //
    //   normal -> detailed   the hero narrows (0-140 ms); the strip slides
    //                        right (0-170) and rises (30-200), under the
    //                        hero's corner while it narrows; the list narrows
    //                        (0-140) and rises under the strip (40-210); the
    //                        tiles fade in from the start, under the strip
    //   detailed -> normal   the strip drops (0-140) and slides left (0-150),
    //                        under the widening hero (0-140); the list drops
    //                        (0-160) under the strip and widens (20-180)
    //
    // (at `viewMorphMs` 210; every window scales with it), each an OutCubic
    // ease of its own over one clock. The popup is at most 30 % empty at 40 ms
    // and 4 % by 160 ms going to detailed; the meetings are over by 120 ms.
    // And NO CARD IS EVER DRAWN PAST THE BOX: every rect a view shows is held a
    // padding inside the popup's live size (a strip still in the
    // right column while the host narrows the box would be cut at its right edge
    // for most of the way back), which a host easing its box as slowly as it
    // pleases never undoes. A switch in the middle of a morph starts from what
    // is drawn. The layout reads `_layoutView`, which the switch advances only
    // after it has taken the picture it starts from; the size the host eases
    // follows `viewMode` at once.
    property int viewMorphMs: 210
    readonly property int _morphMs: Math.max(1, root.viewMorphMs)
    property string _layoutView: "normal"
    property string _morphMode: ""               // "" | "widen" | "narrow"
    property var _from: ({})
    property var _frozen: ({})
    property real _mt: 0
    NumberAnimation {
        id: morphClock
        target: root
        property: "_mt"
        from: 0
        to: root._morphMs
        duration: root._morphMs
        easing.type: Easing.Linear
    }
    readonly property var _cardNames: ["hero", "strip", "list", "tiles"]
    // Per card, per axis: [start, end] of its ease, in ms at viewMorphMs 210.
    property var _windows: ({
        widen: { hero: { h: [0, 140], v: [0, 1] }, strip: { h: [0, 170], v: [30, 200] },
                 list: { h: [0, 140], v: [40, 210] }, tiles: { h: [0, 1], v: [0, 1] } },
        narrow: { hero: { h: [0, 140], v: [0, 1] }, strip: { h: [0, 150], v: [0, 140] },
                  list: { h: [20, 180], v: [0, 160] }, tiles: { h: [0, 1], v: [0, 1] } }
    })
    function _showsIn(card, view) {
        if (card === "hero")
            return true;
        if (card === "tiles")
            return view === "detailed";
        return view !== "mini";
    }
    // A card's place in a view, on the popup's live width. The strip and the
    // list keep their normal places in mini (where they fade), the tiles their
    // detailed one out of it, at the detailed width.
    function _target(card, view) {
        const p = root._p, W = root._innerW, det = view === "detailed";
        switch (card) {
        case "hero":
            return { x: p, y: root._heroY, w: det ? root._leftW : W, h: root._heroH };
        case "strip":
            return det ? { x: p + root._leftW + p, y: root._heroY, w: W - root._leftW - p, h: root._stripH }
                       : { x: p, y: root._heroY + root._heroH + p, w: W, h: root._stripH };
        case "list":
            return det ? { x: p, y: root._heroY + root._heroH + p, w: root._leftW, h: root._colH - root._heroH - p }
                       : { x: p, y: root._heroY + root._heroH + p + root._stripH + p, w: W, h: root._listH };
        default:
            return { x: p + root._leftW + p, y: root._heroY + root._stripH + p,
                     w: (det ? W : root.detailedWidth - 2 * p) - root._leftW - p, h: root._colH - root._stripH - p };
        }
    }
    function _ease(w) {
        const k = root._morphMs / 210;
        const u = Math.max(0, Math.min(1, (root._mt - w[0] * k) / Math.max(1, (w[1] - w[0]) * k)));
        return 1 - Math.pow(1 - u, 3);
    }
    // Every card's drawn rect, from ONE read of the clock and the view.
    readonly property var _drawn: {
        const view = root._layoutView, mode = root._morphMode;
        // The box's right and bottom padding lines, on whole pixels.
        const R = Math.floor(root.width - root._p), B = Math.floor(root.height - root._p);
        const out = {};
        for (const n of root._cardNames) {
            const to = root._target(n, view);
            const fr = root._frozen[n];
            const f = root._from[n];
            let r = to;
            if (fr) {
                out[n] = fr;
                continue;
            }
            if (mode !== "" && f) {
                const w = root._windows[mode][n];
                const eh = root._ease(w.h), ev = root._ease(w.v);
                r = { x: f.x + (to.x - f.x) * eh, y: f.y + (to.y - f.y) * ev,
                      w: f.w + (to.w - f.w) * eh, h: f.h + (to.h - f.h) * ev };
            }
            // Edges on whole pixels, and never past the box: the right and
            // bottom edges held on its padding lines.
            const x = Math.round(r.x), y = Math.round(r.y);
            out[n] = { x: x, y: y, w: Math.max(0, Math.min(Math.round(r.x + r.w), R) - x),
                       h: Math.max(0, Math.min(Math.round(r.y + r.h), B) - y) };
        }
        return out;
    }
    function _startMorph() {
        // Built on a view a host handed in at creation (the one it remembers): the view
        // "changes" from the default while the object is made, and there is no earlier
        // layout to move from -- a morph there would be a widening at every open in "detailed".
        if (!root._built)
            return;
        const fromView = root._layoutView, toView = root.viewMode;
        if (fromView === toView)
            return;
        const snap = root._drawn;
        const from = {}, frozen = {};
        for (const n of root._cardNames) {
            from[n] = snap[n];
            if (!root._showsIn(n, toView))
                frozen[n] = snap[n];
        }
        const pair = fromView + ">" + toView;
        morphClock.stop();
        root._mt = 0;
        root._from = from;
        root._frozen = frozen;
        root._morphMode = pair === "normal>detailed" ? "widen" : (pair === "detailed>normal" ? "narrow" : "");
        root._layoutView = toView;
        if (root._morphMode !== "")
            morphClock.restart();
    }
    property bool _built: false
    Component.onCompleted: {
        root._ensureCards();
        root._layoutView = root.viewMode;
        root._built = true;
        // The creation-time binding of `model` ends here (same value, no change): from now on it moves through `_takeModel`.
        root.model = root.model;
    }
    // Back to the state a NEW content starts in, so the engine keeps a SHOWN, closed content parked for the
    // next open and the open adopts it (a warm open takes 53-85 ms, against 180 built). A new content starts with no
    // detail open, no gesture running, the view's morph at rest and the strip and the list at their first column and row; the
    // popup's view and the cards' views are the owner's memory, which a new content is built ON, so they stay. The cycler's
    // title box and dots (shared CardViewCycler) finish their own timers, a second at most.
    function recycle() {
        root._endGesture();
        root.secondaryOpen = false;
        if (root.resetView !== "")
            root.viewMode = root.resetView;
        morphClock.stop();
        root._mt = root._morphMs;
        if (root.hourlyStrip)
            root.hourlyStrip.resetScroll();
        if (root.dailyList)
            root.dailyList.resetScroll();
    }

    // For a harness: hold the morph at `ms` into its clock (a render of one
    // frame of it, deterministic).
    function pinMorph(ms) {
        morphClock.stop();
        root._mt = ms;
    }
    // For a probe: the clock's length and whether it is still running.
    readonly property bool morphing: morphClock.running

    implicitWidth: root.mini ? root.miniWidth : (root.detailed ? root.detailedWidth : root.normalWidth)
    implicitHeight: root.mini ? root._heightMini : (root.detailed ? root._heightDetailed : root._heightNormal)

    // ---- Swipe hold contract (as SystemUpdatePopup) ---------------------------
    readonly property bool swipeGestureActive: root._gestureActive
    readonly property real gestureHoldWidth: Math.max(root.width, root.detailedWidth)
    readonly property real gestureHoldHeight: Math.max(root.height, root._heightNormal, root._heightDetailed)
    property bool _gestureActive: false
    property string _gestureOwner: ""          // "strip" | "list" | "popup"
    property string _gestureAxis: ""           // "" until one axis leads, then "x" | "y"

    // =========================================================================
    //  HEADER ROW
    // =========================================================================
    Item {
        id: header
        x: root._p
        y: root._p
        width: root._innerW
        height: root.headerHeight

        readonly property string locationName: {
            if (root.model && root.model.location && root.model.location.name)
                return root.model.location.name;
            const s = root.service;
            if (s && s.locations && s.locations.length > 0) {
                const l = s.locations[Math.max(0, Math.min(s.locations.length - 1, s.locationIndex))];
                if (l && l.name)
                    return l.name;
            }
            return "Weather";
        }
        // What the name stands for, said on hover. The place is the CURRENT location only with a geoclue fix; without
        // one it is the hometown (the saved location marked "home", else the town the first accepted fix named, else the
        // default location) and the reason the fix is missing is told in the client's own words. The agent's question
        // is the usual one: it asks, once per start, whether this client may see the location.
        readonly property string locationTip: {
            const loc = root.model ? root.model.location : null;
            const more = nameBlock.canCycle ? "\nClick for the next location." : "";
            if (!loc)
                return nameBlock.canCycle ? "Click for the next location." : "";
            if (loc.source === "geoclue" || loc.here)
                return "Current location, from geoclue." + more;
            if (loc.reason)
                return (loc.source === "home" ? "Home." : "Default location.") + " The current location has no fix yet:\n"
                    + loc.reason + "\nThe first fix after a start waits for an answer to the geoclue agent's question." + more;
            return more.length > 0 ? more.slice(1) : "";
        }
        readonly property string note: {
            if (root.loading && !root.model)
                return "";
            if (root.offline && !root.model)
                return "offline, retrying";
            if (root.offline)
                return "offline, from " + root.fmt.time(root.service ? root.service.fetchedAtMs : null);
            if (root.model)
                return "updated " + root.fmt.time(root.model.fetchedAtMs);
            return "";
        }
        readonly property real _tabW: root.tabWidth
        readonly property real _textW: header.width - header._tabW - 12

        // The location name is the link: a short fade and the hand say so.
        Item {
            id: nameBlock
            x: 0
            y: 0
            width: header._textW
            height: header.height
            readonly property bool canCycle: root.service && root.service.locations && root.service.locations.length > 1
            // Mini stacks the note under the name, and the stack's INK -- the
            // name's cap top to the note's baseline -- is centred on the
            // header, so the space above it equals the space below and it
            // sits level with the selector. Font-only reads: no loop.
            FontMetrics {
                id: nameFm
                font: nameText.font
            }
            FontMetrics {
                id: noteFm
                font: noteText.font
            }
            readonly property real _miniInkTop: nameFm.ascent - nameFm.capitalHeight
            readonly property real _miniInkBase: nameText.height - 1 + noteFm.ascent
            readonly property int _miniY: Math.round((nameBlock.height - (nameBlock._miniInkBase - nameBlock._miniInkTop)) / 2 - nameBlock._miniInkTop)
            // THE LINK'S OWN EXTENT: the name and, on its line, the note beside it (mini stacks the note under the name). The hover, the
            // hand and the tip belong to THIS and not to the whole slot the header leaves for the text: in the detailed view that slot is
            // half a popup wide, the tip centred on it would stand far to the right of the name (in normal and mini the slot is about the
            // name's width), and a pointer in the empty header would light the link and open a tip under a name it was nowhere near.
            readonly property real inkW: root.mini ? Math.max(nameText.width, noteText.visible ? noteText.width : 0)
                                                    : (noteText.visible ? noteText.x + noteText.width : nameText.width)
            property real hoverF: nameArea.containsMouse && nameBlock.canCycle ? 1 : 0
            Behavior on hoverF {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
            }

            Text {
                id: nameText
                x: 0
                // Mini stacks the note under the name; the wide views keep
                // both on one line, baseline to baseline.
                y: root.mini ? nameBlock._miniY : (parent.height - height) / 2
                width: Math.min(implicitWidth, root.mini ? nameBlock.width : nameBlock.width - noteText.width - 8)
                text: header.locationName
                elide: Text.ElideRight
                color: Mix.c(Theme.textPrimary, Theme.accent, nameBlock.hoverF)
                font.family: root.fontFamily
                font.pixelSize: 16
                font.bold: true
            }
            Text {
                id: noteText
                x: root.mini ? 0 : nameText.x + nameText.width + 8
                y: root.mini ? nameText.y + nameText.height - 1 : nameText.y + (nameText.height - height) / 2 + 1
                text: header.note
                visible: text.length > 0
                color: root.offline ? Theme.warn : Theme.textFaint
                font.family: root.fontFamily
                font.pixelSize: 12
            }
            SkeletonBar {
                x: root.mini ? 0 : nameText.x + nameText.width + 8
                y: root.mini ? nameText.y + nameText.height + 2 : nameText.y + (nameText.height - height) / 2 + 2
                width: 76
                height: 8
                visible: root.loading && !root.model
                pulse: root.skeletonPulse
                barColor: Theme.headerBox
                groundColor: Theme.surface
            }
            Item {
                id: nameHit
                x: 0
                y: 0
                width: Math.ceil(nameBlock.inkW)
                height: nameBlock.height
            }
            HoverTip {
                anchorItem: nameHit
                overlayItem: root
                side: "below"
                fontFamily: root.fontFamily
                fontPixelSize: 11
                show: nameArea.containsMouse && header.locationTip.length > 0
                text: header.locationTip
            }
            MouseArea {
                id: nameArea
                anchors.fill: nameHit
                hoverEnabled: true
                cursorShape: nameBlock.canCycle ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    if (!nameBlock.canCycle)
                        return;
                    const s = root.service;
                    s.selectLocation((s.locationIndex + 1) % s.locations.length);
                }
            }
        }

        // The tabs are one model for every view -- a model change regenerates
        // the delegates, and the swipe that switches views is a wheel event.
        // Icons in all of them; each tab's tip says its name.
        TabSelector {
            id: modeTabs
            x: header.width - width
            y: (header.height - height) / 2
            width: header._tabW
            height: 32
            swipeSelfHandled: false
            swipeThreshold: root.swipeThreshold
            swipePullTaper: root.swipePullTaper
            swipeMaxPull: root.swipeMaxPull
            swipeMomentumRate: root.swipeMomentumRate
            swipeCooldownMs: root.swipeCooldownMs
            tabs: [
                { id: "mini", label: "mini", icon: "\u{F0B6F}", tip: "mini" },                // md-card: one card
                { id: "normal", label: "normal", icon: "\u{F056A}", tip: "normal" },          // md-view_agenda: a column of cards
                { id: "detailed", label: "detailed", icon: "\u{F056E}", tip: "detailed" }     // md-view_dashboard: two columns of tiles
            ]
            currentTab: root.viewMode
            onTabChanged: id => root.viewMode = id
            fontFamily: root.fontFamily
            fontPixelSize: 12
            iconFontFamily: "Symbols Nerd Font"
            iconSize: root.tabIconSize
            labelsVisible: false
            iconsVisible: true
            overlayItem: root
        }
    }

    // =========================================================================
    //  THE CARDS
    // =========================================================================
    // The four cards sit on whole pixels (`_drawn` rounds them): text rasters
    // the same way twice only on the grid, and a layer at a fractional
    // position is resampled. A card a view does not show stays where it was
    // drawn and fades there.
    // STACKED (THE VIEW MORPH): hero over strip over list over tiles, so where
    // two meet in a move the lower one slides under the upper one.
    WeatherHero {
        id: heroCard
        popup: root
        z: 3
        x: root._drawn.hero.x
        y: root._drawn.hero.y
        width: root._drawn.hero.w
        height: root._drawn.hero.h
        transform: [
            Translate {
                y: root._heroDeal * root.floatStyle.dealRise
            },
            Rotation {
                origin.x: heroCard.width / 2
                origin.y: heroCard.height / 2
                angle: root._heroDeal * root.wideDealTurn
            }
        ]
    }

    // THE CARDS A VIEW DOES NOT SHOW ARE NOT BUILT. This popup is
    // 3300 items, and in the mini view only the hero's ~100 are seen: the strip is 1400, the list 1700, the tiles 300. A card is
    // built the first time a view shows it -- the strip and the list in normal and detailed, the tiles in detailed -- and kept,
    // so a switch back and forth never builds again; the first switch pays for it, once per session. Until then `hourlyStrip`,
    // `dailyList` and `tileGrid` are null and every reader below says so.
    // A host that reads the cards at once (a mockup's panel, a harness that measures them) builds them all from the start.
    property bool eagerCards: false
    property bool _stripEver: false
    property bool _listEver: false
    property bool _tilesEver: false
    function _ensureCards() {
        if (root.viewMode === "mini")
            return;
        // A view that shows a card needs it NOW: a build still under way in the background (below) is finished in this turn.
        root._cardsAsync = false;
        root._stripEver = true;
        root._listEver = true;
        if (root.viewMode === "detailed")
            root._tilesEver = true;
    }
    // BUILT AHEAD, IN THE BACKGROUND. The first switch out of mini built the strip and the list in its own turn: 270 ms with
    // nothing drawn (quiet profile), the one long frame of a session's first switch. So a popup that is open and at rest builds the
    // cards its view does not show yet, a little after it is shown, through asynchronous Loaders (the build is spread over frames;
    // the cards are invisible until a view shows them). A parked or hidden content builds nothing.
    property int cardsAheadMs: 700
    property bool _cardsAsync: true
    Timer {
        interval: root.cardsAheadMs
        repeat: true
        running: root.cardsAheadMs > 0 && root._built && !root.parked && root.visible && root.backdropRunning && !!root.model
                 && (!root._stripEver || !root._listEver || !root._tilesEver) && root._morphMode === ""
        // one card a beat, each once the one before it stands
        onTriggered: {
            if (!root._stripEver)
                root._stripEver = true;
            else if (!root._listEver) {
                if (root._stripCard)
                    root._listEver = true;
            } else if (root._listCard)
                root._tilesEver = true;
        }
    }
    // Each host registers its card as it is built (a Loader's `item` is a QObject to the linter); a card is never unbuilt, so nothing
    // unregisters it (a registry nulled at the popup's destruction makes every panel bound to it read `undefined` on the way out).
    property WeatherHourlyStrip _stripCard: null
    property WeatherDailyList _listCard: null
    property WeatherTiles _tilesCard: null
    // TYPED, not `var`: the mockups' Save finds where a panel row's default ships by the type of the property it is written through
    // (tools/dev/mockup_promote.py: "no alias or typed property").
    readonly property WeatherHourlyStrip hourlyStrip: root._stripCard
    readonly property WeatherDailyList dailyList: root._listCard
    readonly property WeatherTiles tileGrid: root._tilesCard

    // A layer is cut on its item's rect and a carved box draws its bevel
    // OUTSIDE that rect, so the layer sits on a host `layerSlack` larger than
    // the card on every side (layer.sourceRect does not move the effect: a
    // larger source drawn into the item's rect is a squeezed, blurred card).
    Loader {
        id: stripLoader
        anchors.fill: parent        // the loader's bounds are the popup's: pointer delivery is pruned at an ancestor's bounds
        z: 2
        active: root.eagerCards || root._stripEver
        asynchronous: root._cardsAsync && !root.eagerCards
        // The loaded item is a plain item the loader sizes to the popup; the host inside keeps its own geometry (a loader resizes
        // what it loads, and a host that took the popup's size would be a full-size layer).
        sourceComponent: Component {
            Item {
                id: stripHostLayer
                Item {
                    id: stripHost
                    // A card built by a switch fades in; one built with the popup is simply there. `settled` is the fade's
                    // target, `fade` lets the Behavior run (not at the popup's own construction).
                    property bool settled: false
                    property bool fade: false
                    Component.onCompleted: {
                        root._stripCard = hourlyStripCard;
                        if (root._built) {
                            stripHost.fade = true;
                            Qt.callLater(() => stripHost.settled = true);
                        } else {
                            stripHost.settled = true;
                            Qt.callLater(() => stripHost.fade = true);
                        }
                    }
                    x: root._drawn.strip.x - root.layerSlack
                    y: root._drawn.strip.y - root.layerSlack
                    width: hourlyStripCard.width + 2 * root.layerSlack
                    height: hourlyStripCard.height + 2 * root.layerSlack
                    opacity: root.mini || !stripHost.settled ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity {
                        enabled: stripHost.fade
                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                    }
                    layer.enabled: root._layered
                    layer.textureSize: Qt.size(Math.round(width * root.renderScale), Math.round(height * root.renderScale))
                    layer.smooth: true
                    // The deal moves the layer's quad: the texture is not drawn again.
                    transform: [
                        Translate {
                            y: root._stripDeal * root.floatStyle.dealRise
                        },
                        Rotation {
                            origin.x: stripHost.width / 2
                            origin.y: stripHost.height / 2
                            angle: -root._stripDeal * root.wideDealTurn
                        }
                    ]

                    WeatherHourlyStrip {
                        id: hourlyStripCard
                        popup: root
                        startView: root.stripViewStart
                        x: root.layerSlack
                        y: root.layerSlack
                        width: root._drawn.strip.w
                        height: root._drawn.strip.h
                    }
                }
            }
        }
    }

    Loader {
        id: listLoader
        anchors.fill: parent        // the loader's bounds are the popup's: pointer delivery is pruned at an ancestor's bounds
        z: 1
        active: root.eagerCards || root._listEver
        asynchronous: root._cardsAsync && !root.eagerCards
        // The loaded item is a plain item the loader sizes to the popup; the host inside keeps its own geometry (a loader resizes
        // what it loads, and a host that took the popup's size would be a full-size layer).
        sourceComponent: Component {
            Item {
                id: listHostLayer
                Item {
                    id: listHost
                    // A card built by a switch fades in; one built with the popup is simply there. `settled` is the fade's
                    // target, `fade` lets the Behavior run (not at the popup's own construction).
                    property bool settled: false
                    property bool fade: false
                    Component.onCompleted: {
                        root._listCard = dailyListCard;
                        if (root._built) {
                            listHost.fade = true;
                            Qt.callLater(() => listHost.settled = true);
                        } else {
                            listHost.settled = true;
                            Qt.callLater(() => listHost.fade = true);
                        }
                    }
                    x: root._drawn.list.x - root.layerSlack
                    y: root._drawn.list.y - root.layerSlack
                    width: dailyListCard.width + 2 * root.layerSlack
                    height: dailyListCard.height + 2 * root.layerSlack
                    opacity: root.mini || !listHost.settled ? 0 : 1
                    visible: opacity > 0
                    Behavior on opacity {
                        enabled: listHost.fade
                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                    }
                    layer.enabled: root._layered
                    layer.textureSize: Qt.size(Math.round(width * root.renderScale), Math.round(height * root.renderScale))
                    layer.smooth: true
                    transform: [
                        Translate {
                            y: root._listDeal * root.floatStyle.dealRise
                        },
                        Rotation {
                            origin.x: listHost.width / 2
                            origin.y: listHost.height / 2
                            angle: root._listDeal * root.wideDealTurn
                        }
                    ]

                    WeatherDailyList {
                        id: dailyListCard
                        popup: root
                        startView: root.listViewStart
                        x: root.layerSlack
                        y: root.layerSlack
                        width: root._drawn.list.w
                        height: root._drawn.list.h
                    }
                }
            }
        }
    }

    Loader {
        id: tilesLoader
        anchors.fill: parent        // the loader's bounds are the popup's: pointer delivery is pruned at an ancestor's bounds
        active: root.eagerCards || root._tilesEver
        asynchronous: root._cardsAsync && !root.eagerCards
        // The loaded item is a plain item the loader sizes to the popup; the host inside keeps its own geometry (a loader resizes
        // what it loads, and a host that took the popup's size would be a full-size layer).
        sourceComponent: Component {
            Item {
                id: tilesHostLayer
                Item {
                    id: tilesHost
                    // A card built by a switch fades in; one built with the popup is simply there. `settled` is the fade's
                    // target, `fade` lets the Behavior run (not at the popup's own construction).
                    property bool settled: false
                    property bool fade: false
                    Component.onCompleted: {
                        root._tilesCard = tileGridCard;
                        if (root._built) {
                            tilesHost.fade = true;
                            Qt.callLater(() => tilesHost.settled = true);
                        } else {
                            tilesHost.settled = true;
                            Qt.callLater(() => tilesHost.fade = true);
                        }
                    }
                    x: root._drawn.tiles.x - root.layerSlack
                    y: root._drawn.tiles.y - root.layerSlack
                    width: tileGridCard.width + 2 * root.layerSlack
                    height: tileGridCard.height + 2 * root.layerSlack
                    opacity: root.detailed && tilesHost.settled ? 1 : 0
                    visible: opacity > 0
                    Behavior on opacity {
                        enabled: tilesHost.fade
                        NumberAnimation { duration: root.fadeMs; easing.type: Easing.OutCubic }
                    }
                    // Not while the tiles float: they move every tick, and a layer of them would be drawn again with them.
                    layer.enabled: root._layered && !root.cardFloat
                    layer.textureSize: Qt.size(Math.round(width * root.renderScale), Math.round(height * root.renderScale))
                    layer.smooth: true

                    WeatherTiles {
                        id: tileGridCard
                        popup: root
                        columns: 3
                        x: root.layerSlack
                        y: root.layerSlack
                        // Out of the detailed view the grid stays where it is drawn and
                        // fades there (THE VIEW MORPH), not a share of a narrowing popup.
                        width: root._drawn.tiles.w
                        height: root._drawn.tiles.h
                    }
                }
            }
        }
    }

    // =========================================================================
    //  THE ONE WHEEL READER (see the header)
    // =========================================================================
    Timer {
        id: gestureIdleTimer
        interval: root.gestureIdleEndMs
        onTriggered: root._endGesture()
    }
    function _endGesture() {
        gestureIdleTimer.stop();
        if (root.hourlyStrip)
            root.hourlyStrip.endCycle();
        if (root.dailyList)
            root.dailyList.endCycle();
        modeTabs.applySwipe(0);
        root._gestureActive = false;
        root._gestureOwner = "";
        root._gestureAxis = "";
    }
    // The daily list reads the wheel only on a latched vertical axis the strip
    // does not own (or with no gesture latched at all): an undecided axis, a
    // sideways gesture and a strip notch that drifts onto the list each have a
    // reader already. Owner "popup" does nothing on y, so the list may read
    // there -- a notch that moves from the hero onto the list still scrolls it.
    readonly property bool listWheelEnabled: !root._gestureActive || (root._gestureAxis === "y" && root._gestureOwner !== "strip")

    // One wheel event (WheelHub's), in swipeArea's coordinates (wx, wy). The
    // area below and gestureWheel() both land here.
    function _wheel(wx, wy, ev) {
        const ad = ev.angleDelta, pd = ev.pixelDelta, phase = ev.phase;
        // Each axis in angle units (a device that sends only pixels is
        // scaled into them). `xPixels`/`yPixels` say the DEVICE reports
        // pixels -- a touchpad, which on Wayland sends angle deltas too --
        // because a cycle step is counted against the touchpad threshold
        // then, not the mouse notch's: a touchpad read as a wheel
        // whenever it also sends angles would step a view on a few millimetres of finger
        // drift.
        const xPixels = pd.x !== 0;
        const yPixels = pd.y !== 0;
        const dx = ad.x !== 0 ? ad.x : pd.x * root.swipePixelToAngle;
        const dy = ad.y !== 0 ? ad.y : pd.y * root.swipePixelToAngle;
        // Zero on both axes is the touchpad's scroll-end: the fingers lifted.
        if (dx === 0 && dy === 0) {
            // The strip's engine hears it first: the lift starts a coast when
            // the fingers were moving, and fingers put back (ScrollBegin) catch
            // one -- the next gesture's owner is not known yet, so the catch
            // goes to the strip regardless (an idle engine ignores it).
            if (root.hourlyStrip && (phase === Qt.ScrollBegin
                    || (root._gestureOwner === "strip" && root._gestureAxis === "x")))
                root.hourlyStrip.feedWheel(0, 0, phase);
            root._endGesture();
            return;
        }
        gestureIdleTimer.restart();
        if (!root._gestureActive) {
            // The owner FIRST: the next line grows this area about the
            // popup's centre, and (wx, wy) are in its geometry from
            // before that.
            root._gestureOwner = swipeArea._over(root.hourlyStrip, "strip", wx, wy) ? "strip"
                : swipeArea._over(root.dailyList, "list", wx, wy) ? "list" : "popup";
            root._gestureActive = true;
            root._gestureAxis = "";
        }
        // A two-finger read is never one axis: the one clearly ahead is
        // taken and kept for the whole gesture.
        if (root._gestureAxis === "") {
            if (Math.abs(dx) > Math.abs(dy) * 1.2)
                root._gestureAxis = "x";
            else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                root._gestureAxis = "y";
        }
        const axisX = root._gestureAxis === "x" && dx !== 0;
        const axisY = root._gestureAxis === "y" && dy !== 0;
        if (root._gestureOwner === "strip") {
            if (axisX) {
                // The strip's engine: glide / follow / coast. Qt's sign moves the content with the fingers (dx > 0 =
                // toward the start); reversed, dx > 0 goes toward later hours like the other sideways strokes.
                // (A mouse's sideways notch says which way itself: on = later.)
                const sg = root.stripScrollReversed && ev.device !== "wheel" ? -1 : 1;
                root.hourlyStrip.feedWheel(sg * pd.x, sg * ad.x, phase);
            }
            else if (axisY)
                root.hourlyStrip.cycleBy(yPixels ? dy : -dy, yPixels);   // the hand down = the next view: fingers or a notch
        } else if (root._gestureOwner === "list") {
            if (axisX)
                root.dailyList.cycleBy(ev.device === "wheel" ? 120 * ev.steps : dx, xPixels);         // the selector's sign
            // y: the list's own ScrollDressing reads it
        } else if (axisX && root.swipeToSwitchView) {
            if (ev.device === "wheel")
                modeTabs.applySteps(ev.steps);
            else
                modeTabs.applySwipe(dx);
        }
    }

    // THE STICKY GESTURE, for a host that CLIPS this content (GooeyBody is
    // `clip: true` at the box it is easing, and so is the mockup's body). A
    // swipe that shrinks the view -- detailed to mini -- often leaves the
    // pointer outside the new box, and a clipping item delivers nothing to a
    // child outside its rect (measured, Qt 6.11: `containmentMask` does not
    // lift that), so the rest of the gesture falls on the floor and one
    // cannot come back in the same motion. The host puts a catcher under
    // the body while `swipeGestureActive` and hands this every wheel that
    // lands outside it, in THIS item's coordinates; a gesture already under
    // way keeps going until the fingers lift. A forwarded wheel never starts
    // one: outside the popup there is nothing to own. Returns whether it used
    // the event.
    function gestureWheel(ev) {
        if (!root._gestureActive || !ev)
            return false;
        root._wheel(ev.x - swipeArea.x, ev.y - swipeArea.y, ev);
        return true;
    }

    WheelArea {
        id: swipeArea
        // Grown about the popup's centre while a gesture is live, so a view
        // that shrinks under the pointer keeps hearing the swipe.
        x: (root.width - width) / 2
        y: (root.height - height) / 2
        width: root._gestureActive ? root.gestureHoldWidth : root.width
        height: root._gestureActive ? root.gestureHoldHeight : root.height
        z: 200

        // Whether a point of this area is over a card the view shows.
        function _over(card, name, wx, wy) {
            if (!card || !root._shows(name))
                return false;
            const p = swipeArea.mapToItem(card, wx, wy);
            return p.x >= 0 && p.y >= 0 && p.x <= card.width && p.y <= card.height;
        }

        turned: wheel => {
            root._wheel(wheel.x, wheel.y, wheel);
            wheel.accepted = false;
        }
    }
}
