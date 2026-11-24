pragma ComponentBehavior: Bound

import QtQuick

import "Mix.js" as Mix
import QtQuick.Effects
import "../particles"
import "../theme"

// =============================================================================
// PhaseRail.qml
//
// The run's progress, as an engraved rail with a ball that rests in the
// notches — the same mechanism as the workspaces switcher, reused here.
//
// It stands in for a header progress bar rather than sitting beside one. Most
// of a run's phases have nothing countable to report, so such a bar would
// spend most of its life as an indeterminate stripe flying past, which says
// exactly what a ball resting in a notch says. Where a phase IS measurable
// (download, install) the rail says so with the same gesture: the ball leaves
// its notch and travels toward the next one in proportion to the step, filling
// the groove behind it. One element, two states, no redundancy.
//
// Deliberately, only whole steps move the ball. Finishing a sub-phase of
// "sync" does not creep toward "resolve", because the ball's position is a
// claim about how much of the RUN is done, and a half-filled groove would
// claim work that has not started.
//
// PARTICLES
//   idle    a slow swirl orbiting the resting ball, so a phase with no
//           measurable progress still reads as working rather than hung.
//           Only ever around a ball seated in a notch and told to stay
//           there. The ring marks a notch, so a ball creeping through a
//           step, or halted partway through one, gets none: there is no
//           notch under it to mark
//   moving  sparks thrown off backwards, as in the workspaces rail
//   chase   the swirl already in the air is yanked after the moving ball;
//           whichever particles happen to be pointing the right way trail it,
//           the rest scatter. Accelerating brightens a particle, so the ones
//           that keep up flare against their own dying fade instead of
//           quietly vanishing
// =============================================================================
Item {
    id: rail

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    // ---- Content ----
    // [{key, label}]
    property var steps: []
    property string currentKey: ""
    // 0..1 through the CURRENT step, or negative when the step has nothing
    // countable to report (the ball then rests in its notch).
    property real stepProgress: -1
    property bool failed: false
    property bool allDone: false
    property bool active: true

    // ---- Styling ----
    property color textColor:   "#5D5D5F"
    property color mutedColor:  "#8A8A8C"
    property color faintColor:  "#B8BBC2"
    property color accentColor: "#4480F4"
    property color doneColor:   "#40A02B"
    property color errorColor:  Theme.error
    property color surfaceColor: "#EAEDF5"
    // The groove the ball runs in. GrooveTrack carries its own eva-light
    // defaults, so the channel, its rim and its inset are all forwarded:
    // otherwise on a dark theme they stay light.
    property color grooveColor:       "#E1E4EB"
    property color grooveBevelColor:  "#EEF0F7"
    property color grooveShadowColor: "#CED1D7"
    property string fontFamily: "Inter"

    property real sizeScale: 1.0
    property real lineThickness: 6
    property real dotSize: 13
    property real ballSize: 15
    property real edgePadding: 20
    property int  labelSize: 10
    property real labelGap: 7
    property real minLabelWidth: 54

    // ---- Particles ----
    property bool  particlesEnabled: true

    // The canvas extends beyond the rail so the swirl is not clipped.
    //
    // The particle Canvas culls to its own bounds, and the rail's own box is
    // only as tall as the groove plus its labels — so without the margin the
    // top of every orbit is cut off just above the resting ball.
    property real  particleMargin: 46

    // Where the particles must have faded to nothing, so whatever the host
    // clips against never cuts a spark in half.
    //
    // Each edge is a distance in px OUTSIDE the rail's own bounds, in the
    // rail's coordinate space: `particleEdgeLeft: 12` puts the zero line
    // 12 px left of the rail's left edge, which is where a card clipping 12 px
    // past the rail would otherwise cut. Alpha is zero on that line and
    // reaches full `particleFadeWidth` px inward from it. A value past
    // `particleMargin` is clamped to the particle layer's own bounds, since
    // nothing is drawn beyond them anyway; a negative value pulls the line
    // inside the rail.
    //
    // One mask over the finished particle rendering, canvas and bloom
    // together (see the particle layer below), not a per-particle rule: a
    // spark's trail and its halo dim as one, and the groove, ball and labels
    // are never touched by it.
    property real  particleEdgeLeft: particleMargin
    property real  particleEdgeRight: particleMargin
    property real  particleEdgeTop: particleMargin
    property real  particleEdgeBottom: particleMargin
    property real  particleFadeWidth: 18

    // --- Idle swirl: orbits the resting ball ---
    property real  orbitRadius: 10
    property real  orbitSpeed: 18            // tangential drive
    property real  orbitRadialK: 6.5         // spring holding the orbit radius
    property real  orbitDrag: 1.1            // damps the spring so it settles
    property int   orbitSpawnMs: 75
    property int   orbitBatch: 1
    property real  orbitLifetime: 2000
    property real  orbitLifetimeVar: 1200
    property real  orbitSizeStart: 3
    property real  orbitSizeEnd: 1.3
    // Seeded in one go when a run starts, so the swirl is already in place
    // rather than streaking in from wherever the ball used to be.
    property int   orbitSeedCount: 14

    // --- Chase: the swirl is pulled after a moving ball ---
    property real  chaseStrength: 420
    property real  chaseFalloffMs: 380
    // Swirl particles carry a live arrival target — the ball itself. Reaching
    // it retires them with a fade instead of letting them oscillate around it,
    // and the distance fade starts before that so the approach reads as
    // settling rather than vanishing.
    property real  chaseArriveRadius: 7
    // How long a particle takes to fade out once it reaches the ball.
    property int   chaseArriveFadeMs: 260

    // --- Grind sparks: thrown off when the ball moves, like metal on metal ---
    // Not attracted to the ball at all: these are debris, and pulling them
    // back would read as the ball vacuuming up its own sparks. Values are the
    // workspaces rail's, which are already tuned.
    property bool  sparksEnabled: true
    // Minimum ball speed (px/ms) that sheds any spark at all. This is the
    // on/off gate; `sparkCreepIntervalMs` below sets the RATE once past it.
    //
    // Measured creep speeds on the mock, excluding the jump into each notch:
    // download peaks at 0.110 and sustains 0.020, install peaks at 0.143 and
    // sustains 0.020, hooks peaks at 0.899 but sustains only 0.005 — it moves
    // in eight discrete jumps rather than creeping. A threshold of 0.3 would
    // let hooks spark and silence download and install entirely, which is not a
    // distinction worth drawing. Set below the sustained creep so continuous
    // progress qualifies, while a genuinely parked ball (speed 0) does not.
    property real  sparkSpeedThreshold: 0.012
    property real  sparkAmountMultiplier: 3.0
    property real  sparkBaseVelocity: 0.1
    property real  sparkScatter: 100.0
    property real  sparkLifetimeBase: 700.0
    property real  sparkLifetimeVariance: 1000.0
    property int   sparkMaxHistory: 8
    property real  sparkSizeStart: 3.0
    property real  sparkSizeEnd: 1.0
    property real  sparkDrag: 2.0
    property real  sparkSwirlStr: 0.4
    property real  sparkSwirlProb: 0.4
    // Slow, measurable steps creep the ball a pixel at a time; that should
    // shed the occasional spark, not a continuous jet of them.
    property int   sparkMinIntervalMs: 0
    property int   sparkCreepIntervalMs: 220
    // Boundary between "creeping through a step" (throttled to
    // sparkCreepIntervalMs) and "travelling between notches" (every frame).
    // Measured notch travel runs 2.5–3.7 px/ms and the fastest creep is 0.9,
    // so this sits comfortably between the two populations.
    property real  sparkCreepSpeed: 1.2

    // --- Shared look ---
    // Multiplies every particle size, both types, both ends. Lets the whole
    // effect be scaled without re-balancing the four individual numbers.
    property real  particleSizeScale: 1.0
    property int   particleMaxHistory: 6
    property real  particleDrag: 1.4
    // Speed at which glow is maximal. Deliberately far above orbit speeds so
    // an idle swirl reads as almost uniform, with only the outermost ring a
    // touch brighter; a chasing particle moves many times faster and is what
    // should actually flare.
    property real  glowSpeedRef: 6000
    property real  glowMax: 2.4
    property real  glowSizeGain: 1.7
    property real  bloomBlur: 22
    property real  bloomStrength: 0.32
    property real  bloomBrightness: 0.5

    // ---- Ball and groove shading ----
    //
    // Expressed as darken/lighten FACTORS rather than absolute colours so the
    // pair still follows the run tone when it turns green on success or red on
    // failure. Overriding the colours outright would freeze them mid-run.
    //
    // The groove's filled part is darker than the ball because it is a
    // channel: it sits below the surface and takes more shadow, while the ball
    // is the raised object in it catching the light. The ball also carries a
    // neutral contact shadow rather than a coloured glow, so it reads as
    // resting IN the groove instead of hovering over it.
    // Ball length ceilings, as multiples of the ball's diameter.
    property real ballStretchMax: 2.5          // travelling between notches
    property real ballStretchMaxProgress: 1.1  // creeping through download/install
    // Extra height beyond the channel so no groove edge shows around the ball.
    property real ballGrooveBleed: 1.0

    property real fillDarken: 1.4
    property real fillShadowDarken: 1.9
    property real ballLighten: 1.12

    readonly property color grooveFillColor: Qt.darker(rail._tone, rail.fillDarken)
    readonly property color grooveFillShadowColor:
        Qt.darker(rail._tone, rail.fillShadowDarken)
    property color ballColor: Qt.lighter(rail._tone, rail.ballLighten)
    property color ballShadowColor: "#2A2C31"
    property real ballShadowOpacity: 0.55
    property real ballShadowBlur: 12

    readonly property int _count: steps && steps.length ? steps.length : 0
    readonly property int _currentIdx: {
        if (rail.allDone) return Math.max(0, rail._count - 1);
        for (let i = 0; i < rail._count; i++)
            if (rail.steps[i].key === rail.currentKey) return i;
        return -1;
    }
    // The colour the rail actually draws with. A run finishing should settle
    // into green (or red) rather than snapping, and every derived colour —
    // groove fill, ball, particles — reads from here so they change together.
    //
    // Two eased FRACTIONS, not `Behavior on _tone`. A Behavior cannot tell
    // the run's own state changes from the theme moving underneath the three
    // colours, so on a light/dark switch the whole rail would chase the
    // crossfade 900ms behind everything else. Mixed this way both ends stay live: at
    // rest the tone IS accent, done or error as the theme has it.
    property real _doneF: rail.allDone ? 1 : 0
    property real _failF: rail.failed ? 1 : 0
    Behavior on _doneF {
        NumberAnimation { duration: rail.toneFadeMs; easing.type: Easing.OutCubic }
    }
    Behavior on _failF {
        NumberAnimation { duration: rail.toneFadeMs; easing.type: Easing.OutCubic }
    }
    readonly property color _tone: Mix.c3(rail.accentColor,
                                          rail.doneColor, rail._doneF,
                                          rail.errorColor, rail._failF)
    property int toneFadeMs: 900

    // Evenly spaced stops, 0..1.
    readonly property var _stops: {
        const out = [];
        if (rail._count <= 0) return out;
        if (rail._count === 1) { out.push(0.5); return out; }
        for (let i = 0; i < rail._count; i++) out.push(i / (rail._count - 1));
        return out;
    }

    // Where the ball wants to be, 0..1 along the track.
    //
    // Resting in its notch when the step is unmeasurable; travelling toward the
    // NEXT notch in proportion when it is. The last step has nowhere to travel,
    // so it stays put.
    readonly property real _targetPos: {
        if (rail._count === 0 || rail._currentIdx < 0) return 0;
        if (rail.allDone) return 1;
        const here = rail._stops[rail._currentIdx];
        if (rail.stepProgress < 0 || rail._currentIdx >= rail._count - 1) return here;
        const next = rail._stops[rail._currentIdx + 1];
        return here + (next - here) * Math.max(0, Math.min(1, rail.stepProgress));
    }

    // Is the commanded position itself a notch?
    //
    // True while the step has nothing countable (progress negative) or its
    // count still stands at exactly 0 — install waiting on a prompt, hooks
    // about to start. False from the first tick past zero, however small: a
    // creeping ball is not resting. And false for as long as a count HALTS
    // partway (hooks sitting on a 200 s DKMS build at a frozen percent): the
    // ball is parked between notches, and a swirl around it would mark a
    // notch that is not there, so no stall fallback seats it after a silence.
    readonly property bool targetAtNotch: rail._isNotch(rail._targetPos)
    function _isNotch(p) {
        for (let i = 0; i < rail._stops.length; i++)
            if (Math.abs(p - rail._stops[i]) < 1e-6) return true;
        return false;
    }

    // Is the ball NEAR a notch — inside its own relaxation radius, so rounded
    // out (or nearly) into it?
    //
    // Loose on purpose, and only the pacing logic reads it: it tells a
    // re-spaced rail (the notch moved out from under a resting ball) apart
    // from progress, see `_considerMove`. It is NOT the seating test. Half a
    // ball diameter is 7.5 px, and a 90 ms creep that ends inside that radius
    // must not count as a fresh seating: it would re-arm the dwell, park the
    // ball, and keep the swirl running around a ball that is visibly leaving
    // — until it is more than half a diameter out.
    readonly property bool ballInSlot: {
        if (rail._stops.length === 0 || rail.width <= 0) return false;
        const r = rail._scBall / 2;
        for (let i = 0; i < rail._stops.length; i++)
            if (Math.abs(rail._ballX - groove.xAt(rail._stops[i])) < r) return true;
        return false;
    }

    // Is the ball SEATED in a notch, to the pixel?
    //
    // Sub-pixel tolerance. A move that ends ON a notch lands there exactly
    // (the animation writes its `to` value last), so this only has to absorb
    // float noise, never a creep: anything the eye could see as off-centre
    // fails it.
    readonly property bool ballInSlotTight: {
        if (rail._stops.length === 0 || rail.width <= 0) return false;
        for (let i = 0; i < rail._stops.length; i++)
            if (Math.abs(rail._ballX - groove.xAt(rail._stops[i])) < 0.75) return true;
        return false;
    }

    // Resting: seated to the pixel AND commanded to a notch. Everything that
    // asks "should the swirl be running" asks this. Both halves are needed:
    // the seat test alone swirls around a ball a pixel into its creep, and
    // the target test alone swirls around a ball still travelling to the
    // notch it has been sent to. A ball dwelling in its old notch while the
    // target waits at the next one passes both, so the ring stays through
    // the dwell and is released the moment the ball leaves.
    readonly property bool ballSettled: rail.ballInSlotTight && rail.targetAtNotch

    // ---- Pacing -----------------------------------------------------------
    //
    // Two limits keep a step change readable. A ball that has just seated in
    // a notch stays there at least `minDwellMs` before it may leave for the
    // NEXT notch, so a step that finishes in a blink (two pre-transaction
    // hooks) is still seen to have happened. While it waits it holds exactly
    // where it is; whatever the target does meanwhile is caught up with in
    // one move when the dwell is up, so the ball never replays a stale
    // sequence and never goes backwards. Progress creep is exempt: the count
    // beside the rail is already ticking, and a ball held in its notch while
    // the number says 3% would sit there swirling as if at rest. And a step
    // change never travels faster than `maxTravelPxPerMs` on average
    // (OutQuart peaks at about four times that), so a jump across half the
    // rail is a movement the eye can follow rather than a cut.
    property int  minDwellMs: 1000      // step changes only; creep is exempt
    property real maxTravelPxPerMs: 0.35
    property int  stepMoveMs: 460

    property real _seatedMs: 0          // when the ball last seated in a notch
    property bool _parked: false        // holding for the dwell

    // The ball's actual position lags the target through an animation, so a
    // step change is a travel rather than a jump — which is what throws sparks.
    property real ballPos: 0

    // ---- Seating (opt-in) ----------------------------------------------------
    //
    // A rail born into a run that is already going (a popup reopened mid-update:
    // the run lives in the service, the content is new) would start its ball at
    // notch 0 and fly it to where the run stands -- a 460 ms+ flight that throws
    // sparks along the whole rail and shows the content being "rebuilt". A host
    // that knows it was born mid-run calls `seat()` once it has handed the rail
    // ALL its facts (steps, key and progress: a ball seated on the key alone
    // flies the rest of the way when the progress lands): the ball is put on the
    // target at once, no flight, no sparks. Nothing calls it by default -- the
    // viewfinder and the OSD stops want the ball to arrive from the start.
    function seat() {
        dwellTimer.stop();
        rail._parked = false;
        if (posAnim.running) posAnim.stop();
        rail.ballPos = rail._targetPos;
    }

    on_TargetPosChanged: rail._considerMove()
    function _considerMove() {
        if (rail.allDone || rail._seatedMs <= 0) { rail._moveToTarget(); return; }
        // A re-spaced rail (a notch inserted mid-run, e.g. the AUR flip)
        // moves the notch out from under a resting ball. Following it is a
        // layout move, not progress, so it does not wait out the dwell:
        // holding would leave the ball floating between notches and then
        // send it backwards once the timer fires.
        if (!rail.ballInSlot) { rail._moveToTarget(); return; }
        // Progress creep is not a step change. The target leaving the notch
        // because the step's count started ticking is the ball's cue to
        // follow, not to hold: parked, it would swirl in its notch for a
        // second while the number beside it already says otherwise.
        // Tested on `_targetPos` directly: this handler runs BEFORE the
        // `targetAtNotch` binding has re-evaluated for the new target.
        if (!rail._isNotch(rail._targetPos)) { rail._moveToTarget(); return; }
        const waited = Date.now() - rail._seatedMs;
        if (waited >= rail.minDwellMs) { rail._moveToTarget(); return; }
        // Too soon after seating: hold here, go when the dwell is up.
        if (posAnim.running) posAnim.stop();
        rail._parked = true;
        dwellTimer.interval = Math.max(1, rail.minDwellMs - waited);
        dwellTimer.restart();
    }
    Timer {
        id: dwellTimer
        repeat: false
        onTriggered: rail._moveToTarget()
    }
    function _moveToTarget() {
        dwellTimer.stop();
        rail._parked = false;
        if (posAnim.running) posAnim.stop();
        if (Math.abs(rail._targetPos - rail.ballPos) < 1e-4) return;
        posAnim.from = rail.ballPos;
        posAnim.to = rail._targetPos;
        // Creeping progress inside a step should not animate on a 400ms clock
        // or it lags visibly behind the number next to it; a step CHANGE
        // should. The distance tells them apart, and a change is further
        // slowed to the speed cap.
        const jump = Math.abs(rail._targetPos - rail.ballPos) > 0.08;
        let ms = jump ? rail.stepMoveMs : 90;
        if (jump && rail.maxTravelPxPerMs > 0) {
            const px = Math.abs(groove.xAt(rail._targetPos) - groove.xAt(rail.ballPos));
            ms = Math.max(ms, px / rail.maxTravelPxPerMs);
        }
        posAnim.duration = ms;
        posAnim.start();
    }
    NumberAnimation {
        id: posAnim
        target: rail
        property: "ballPos"
        easing.type: Easing.OutQuart
        // Seated only when the move ended ON a commanded notch; a creep that
        // stops between notches, or short of one, is not a seating and starts
        // no dwell. The pixel test is the tight one: the loose radius would let a
        // creep that ends a few pixels out count as seating and re-arm the
        // dwell, so the ball would alternate between creeping and parking.
        onFinished: if (rail.ballInSlotTight && rail.targetAtNotch)
                        rail._seatedMs = Date.now()
    }

    readonly property real _labelBlock:
        _showLabels ? labelGap * sizeScale + labelSize * sizeScale + 3 : 0
    readonly property real _slot: _count > 0 ? width / _count : 0
    readonly property bool _showLabels: rail._slot >= rail.minLabelWidth * rail.sizeScale

    implicitHeight: groove.implicitHeight + _labelBlock

    // =====================================================================
    //  GROOVE
    // =====================================================================
    GrooveTrack {
        id: groove
        anchors.left: parent.left
        anchors.right: parent.right
        y: 0
        height: implicitHeight

        lineThickness: rail.lineThickness
        dotSize: rail.dotSize
        edgePadding: rail.edgePadding
        sizeScale: rail.sizeScale
        stops: rail._stops
        progress: rail.ballPos
        showFill: true

        surfaceColor: rail.surfaceColor
        grooveColor: rail.grooveColor
        grooveBevelColor: rail.grooveBevelColor
        grooveShadowColor: rail.grooveShadowColor
        fillColor: rail.grooveFillColor
        fillShadowColor: rail.grooveFillShadowColor
    }

    // Live ball geometry in groove coordinates.
    readonly property real _ballX: groove.xAt(rail.ballPos)
    readonly property real _ballY: groove.lineCenter
    readonly property real _scBall: rail.ballSize * rail.sizeScale
    // Relaxes to the FULL ball at a notch and compresses to the line
    // thickness between them, area conserved so narrowing stretches the
    // length. Driven by distance to the nearest notch, not by the channel's
    // own half-height: clamping to the channel would mean a notch narrower than
    // the ball could never let it round out, so it would sit permanently
    // flattened even at rest. Same relaxation curve the workspaces rail uses.
    readonly property real _ballH: {
        if (rail._stops.length === 0) return rail._scBall;
        let minDist = Infinity;
        for (let i = 0; i < rail._stops.length; i++) {
            const d = Math.abs(rail._ballX - groove.xAt(rail._stops[i]));
            if (d < minDist) minDist = d;
        }
        const relaxR = rail._scBall / 2;
        const f = Math.min(1, minDist / relaxR);
        const s = f * f * (3 - 2 * f);
        // The compressed floor overshoots the channel by `ballGrooveBleed`.
        // Matching the line thickness exactly would leave the groove's darker
        // edge visible as a hairline above and below the ball, because both
        // shapes are antialiased and each gives up part of its outermost pixel.
        const floor = rail.lineThickness * rail.sizeScale + rail.ballGrooveBleed;
        return rail._scBall - (rail._scBall - floor) * s;
    }

    // Area conservation alone gives a very long ball in the narrow channel.
    // That reads well when the ball is travelling fast between notches, and
    // silly when it is creeping through a download, so the two cases get
    // their own ceiling.
    readonly property real _stretchCeiling:
        rail.stepProgress >= 0 ? rail.ballStretchMaxProgress : rail.ballStretchMax
    readonly property real _ballW: Math.min(
        (rail._scBall * rail._scBall) / Math.max(1, rail._ballH),
        rail._scBall * rail._stretchCeiling)

    // =====================================================================
    //  PARTICLES
    // =====================================================================

    // Ball position in PARTICLE coordinates (the canvas is inset by
    // particleMargin on every side, so rail coords are offset by it).
    readonly property real _pBallX: rail._ballX + rail.particleMargin
    readonly property real _pBallY: rail._ballY + rail.particleMargin

    // Live target every swirl particle's force field and arrival test read.
    // ONE shared object, captured once by each closure, so a particle keeps
    // tracking a ball that is still moving without anything being re-emitted.
    property var _attractor: ({x: 0, y: 0, chase: 0, gen: 0,
                              threshold: rail.chaseArriveRadius})

    // Bumped whenever the ball stops resting. Every swirl particle captures
    // the generation it was born into and stops steering the moment the live
    // one moves past it, so the ring that was orbiting simply loses interest
    // and drifts off to die on its own lifetime. Particles spawned later —
    // once the ball is resting on a notch again — start from a fresh
    // generation and behave normally.
    //
    // Keyed on `ballSettled`, so it fires when the ball leaves its notch OR
    // when the target leaves first (the count ticking past zero, a frame
    // before the ball follows). Not on a step merely becoming measurable:
    // that happens while the ball is still seated at 0, and keying on it would
    // have the swirl abandoning a ring it should keep.
    onBallSettledChanged: if (!rail.ballSettled) rail._attractor.gen += 1;


    // Finishing cuts the swirl loose: emission has already stopped (allDone
    // gates the timer), and bumping the generation stops the survivors
    // steering, so they drift off and fade instead of orbiting a finished run.
    onAllDoneChanged: if (rail.allDone) rail._attractor.gen += 1;
    onFailedChanged: if (rail.failed) rail._attractor.gen += 1;

    // True once geometry exists AND the attractor has been placed on the ball.
    // Emitting before that spawns the swirl at the origin, which would streak
    // it in across the whole rail when a run starts.
    property bool _seeded: false

    // The particle layer: canvas and bloom, rendered together and faded out
    // toward the `particleEdge*` lines by one shader pass over the result.
    //
    // A layer, so the fade sees the finished picture — a spark's trail and
    // its bloom halo dim as one — and nothing else on the rail passes
    // through it. Enabled on the same gate as the bloom: an offscreen pass
    // over a blank canvas is the same idle wattage the bloom gate already
    // refuses to pay. The canvas's own `visible` is never touched: toggling it
    // gives the one opaque garbage frame a Cooperative canvas gives, and the
    // bloom's MultiEffect is what flips in and out over it.
    Item {
        id: particleLayer
        x: -rail.particleMargin
        y: -rail.particleMargin
        width: rail.width + rail.particleMargin * 2
        height: rail.height + rail.particleMargin * 2
        z: 3

        // Inset of each fade-zero line from the layer's own edge, px. The
        // layer extends `particleMargin` past the rail, and the edge is
        // measured outward from the rail, so an edge AT the margin sits on
        // the layer's boundary (inset 0) and a smaller edge moves inward.
        // Clamped at 0: an edge past the margin lands on the boundary.
        readonly property real _insetL: Math.max(0, rail.particleMargin - rail.particleEdgeLeft)
        readonly property real _insetR: Math.max(0, rail.particleMargin - rail.particleEdgeRight)
        readonly property real _insetT: Math.max(0, rail.particleMargin - rail.particleEdgeTop)
        readonly property real _insetB: Math.max(0, rail.particleMargin - rail.particleEdgeBottom)
        // Guarded so a not-yet-laid-out layer divides by 1, not 0.
        readonly property real _w: Math.max(1, particleLayer.width)
        readonly property real _h: Math.max(1, particleLayer.height)

        layer.enabled: rail.particlesEnabled && particles.hasParticles
        layer.textureSize: dev.texSize(particleLayer._w, particleLayer._h)
        layer.effect: ShaderEffect {
            // The layer's texture, handed over by the layer itself
            // (`layer.samplerName` defaults to this name).
            property var source

            // Uniforms, by name, in the layer's texture coordinates. Two
            // fade widths, one per axis: the same number of px is a
            // different fraction of a side that is not square.
            property vector4d edges: Qt.vector4d(
                particleLayer._insetL / particleLayer._w,
                particleLayer._insetT / particleLayer._h,
                1 - particleLayer._insetR / particleLayer._w,
                1 - particleLayer._insetB / particleLayer._h)
            property vector2d fade: Qt.vector2d(
                rail.particleFadeWidth / particleLayer._w,
                rail.particleFadeWidth / particleLayer._h)

            fragmentShader: "shaders/edge_fade.frag.qsb"
        }

        ParticleSystem {
            id: particles
            anchors.fill: parent
            maxParticles: 260
            // FROZEN WHILE THE THEME CROSSFADES. The switch is a still
            // picture of the frame before, faded out over the new palette --
            // "nothing steps, because nothing moves", which is true of every
            // item in the shell except this one. A swirl that keeps orbiting
            // under that picture is two swirls for the length of the fade,
            // the still one a few pixels behind the live one: exactly the
            // "two vortices around the ball". The system caps a long dt at
            // one frame, so resuming does not lurch.
            running: rail.particlesEnabled && !Theme.crossfading
            z: 3
        }

        MultiEffect {
            source: particles
            anchors.fill: parent
            blurEnabled: true
            blurMax: rail.bloomBlur
            blur: rail.bloomStrength
            brightness: rail.bloomBrightness
            z: 4
            // Gated on particles actually existing, not merely on the effect
            // being enabled. A MultiEffect keeps blurring its source every
            // frame even when that source is a blank canvas, which is pure
            // idle wattage.
            visible: rail.particlesEnabled && particles.hasParticles
        }
    }

    // Orbit + chase. The radial spring holds the ring; `orbitDrag` damps it so
    // a particle yanked after the ball settles instead of oscillating past it
    // and back several times.
    function _orbitField() {
        const attr = rail._attractor;
        const myGen = attr.gen;
        const dir = Math.random() > 0.5 ? 1 : -1;
        const speed = rail.orbitSpeed * (0.7 + Math.random() * 0.6);
        const radius = rail.orbitRadius * (0.75 + Math.random() * 0.5);
        const k = rail.orbitRadialK;
        return function (px, py) {
            // Released: coast on whatever velocity is left and fade out.
            if (attr.gen !== myGen) return {x: 0, y: 0};
            const dx = attr.x - px;
            const dy = attr.y - py;
            const dist = Math.sqrt(dx * dx + dy * dy) || 0.001;
            const ux = dx / dist, uy = dy / dist;
            const radial = (dist - radius) * k;
            let fx = -uy * speed * dir + ux * radial;
            let fy =  ux * speed * dir + uy * radial;
            if (attr.chase > 0) {
                fx += ux * attr.chase;
                fy += uy * attr.chase;
            }
            return {x: fx, y: fy};
        };
    }

    function _emitOrbit(n, spread) {
        if (!rail._seeded) return;
        for (let i = 0; i < n; i++) {
            const a = Math.random() * Math.PI * 2;
            const r = rail.orbitRadius * (spread ? (0.5 + Math.random() * 0.9)
                                                 : (0.8 + Math.random() * 0.4));
            const tangential = rail.orbitSpeed * 0.5 * (Math.random() > 0.5 ? 1 : -1);
            // Setting arrivalTarget makes `lifetime` stop being a death
            // condition — only arrival and maxLifetime are. They must therefore
            // be the same number, or the particle spends the gap between them
            // alive, invisible (its death fade already complete) and occupying
            // a slot in the pool.
            const life = rail.orbitLifetime + Math.random() * rail.orbitLifetimeVar;
            particles.emit({
                x: rail._pBallX + Math.cos(a) * r,
                y: rail._pBallY + Math.sin(a) * r,
                vx: -Math.sin(a) * tangential,
                vy:  Math.cos(a) * tangential,
                lifetime: life,
                maxLifetime: life,
                maxHistory: rail.particleMaxHistory,
                sizeStart: rail.sizeScale * rail.particleSizeScale * rail.orbitSizeStart,
                sizeEnd: rail.sizeScale * rail.particleSizeScale * rail.orbitSizeEnd,
                colorStart: rail._tone.toString(),
                colorEnd: "transparent",
                drag: rail.orbitDrag,
                deathFadeFraction: 0.35,
                // The ball itself, live. Reaching it retires the particle with
                // a fade rather than letting it orbit through the middle.
                arrivalTarget: rail._attractor,
                // No fadeStartDistance: it fades by DISTANCE to the target, and
                // an orbit sits permanently inside any band wide enough to be
                // useful — every swirl particle would be dimmed for its whole
                // life. Arrival already gets a graceful tail fade below.
                dyingFadeMs: rail.chaseArriveFadeMs,
                glowSpeedRef: rail.glowSpeedRef,
                glowMax: rail.glowMax,
                glowSizeGain: rail.glowSizeGain,
                forceField: rail._orbitField()
            }, 1);
        }
    }

    Timer {
        id: orbitTimer
        interval: rail.orbitSpawnMs
        repeat: true
        // Only while the ball is resting in a notch (`ballSettled` is the one
        // gate; nothing else decides). A measurable step has the ball
        // travelling, and a swirl around a moving target is exactly the busy
        // look the sparks already cover.
        running: rail.particlesEnabled && rail.active && !rail.allDone
                 && rail._seeded && rail.width > 0 && rail.ballSettled
                 && !Theme.crossfading
        onTriggered: rail._emitOrbit(rail.orbitBatch, false)
    }

    // Fill the ring in one go when a run begins, so opening the popup partway
    // through an update shows a swirl that is already established.
    //
    // Same gate as the timer. Opening the popup on a download at 40% must not
    // burst a ring around a creeping ball that the timer would then refuse
    // to keep, and a finished run gets no ring at all.
    function seedSwirl() {
        if (!rail._seeded || !rail.active || rail.allDone || !rail.ballSettled) return;
        rail._emitOrbit(rail.orbitSeedCount, true);
    }

    // Grind sparks: debris, with no attraction to the ball. Same force field
    // shape as the workspaces rail — a late-life swirl on a random subset.
    function _sparkField() {
        const doSwirl = Math.random() < rail.sparkSwirlProb;
        const sDir = Math.random() > 0.5 ? 1 : -1;
        const mag = rail.sparkSwirlStr;
        return function (px, py, t) {
            let fx = 0, fy = 0;
            if (doSwirl && t > 0.5 && mag > 0) {
                const sT = (t - 0.5) / 0.5;
                fx += Math.cos(t * 15 * sDir) * mag * sT * 1000;
                fy += Math.sin(t * 15 * sDir) * mag * sT * 1000;
            }
            return {x: fx, y: fy};
        };
    }

    // ---- Ball-movement sampling ----------------------------------------
    //
    // Driven by the ball MOVING, not by a clock. A FrameAnimation here would
    // run sixty times a second for the entire length of a run, including the
    // long stretches where the ball sits in a notch and nothing it computes
    // can have changed — which makes an idle rail cost real power.
    //
    // Hung off `ballPos` rather than the derived pixel position: the derived
    // one needs an underscore-prefixed change handler, which is exactly the
    // sort of name that fails silently when it is wrong.
    property real _lastX: 0
    property real _lastY: 0
    property real _lastMs: 0
    property real _chaseUntil: 0
    property real _lastSparkMs: 0

    function _sampleBall() {
        if (!rail.particlesEnabled || rail.width <= 0) return;
        const now = Date.now();
        rail._attractor.x = rail._pBallX;
        rail._attractor.y = rail._pBallY;
        rail._attractor.threshold = rail.chaseArriveRadius;

        if (!rail._seeded) {
            rail._seeded = true;
            rail._lastX = rail._pBallX;
            rail._lastY = rail._pBallY;
            rail._lastMs = now;
            rail.seedSwirl();
            return;
        }

        const dt = Math.max(1, now - rail._lastMs);
        const dx = rail._pBallX - rail._lastX;
        const dy = rail._pBallY - rail._lastY;
        const speed = Math.sqrt(dx * dx + dy * dy) / dt;

        if (speed > rail.sparkSpeedThreshold) {
            rail._chaseUntil = now + rail.chaseFalloffMs;
            const gap = speed < rail.sparkCreepSpeed
                      ? rail.sparkCreepIntervalMs : rail.sparkMinIntervalMs;
            if (rail.sparksEnabled && rail.active
                && now - rail._lastSparkMs >= gap) {
                rail._emitSparks(dx, dy, dt, speed);
                rail._lastSparkMs = now;
            }
            chaseTimer.start();
        }

        rail._lastX = rail._pBallX;
        rail._lastY = rail._pBallY;
        rail._lastMs = now;
    }

    // ---- Layout moves vs real movement ------------------------------------
    //
    // A view change resizes the popup, so the track's geometry changes and the
    // ball lands on a different PIXEL while sitting at the same position along
    // the rail. The swirl is stored in absolute coordinates, so left alone it
    // gets left behind and then chases the ball across the new layout — an
    // event the user did not cause and cannot interpret.
    //
    // The whole cloud is shifted by the same delta instead, so it arrives
    // rigid with the ball, having visibly done nothing. The delta is computed
    // for the SAME ballPos under the old and new geometry, which is what
    // separates a layout move from a real one: if the ball also travelled
    // during the switch, only the layout component is cancelled and the travel
    // still reads as travel.
    property real _prevTrackStart: 0
    property real _prevTrackSpan: 0
    property real _prevLineCenter: 0
    property bool _haveTrackGeom: false

    function _absorbLayoutShift() {
        const ts = groove.trackStart;
        const sp = groove.trackSpan;
        const cy = groove.lineCenter;
        if (!rail._haveTrackGeom) {
            rail._prevTrackStart = ts; rail._prevTrackSpan = sp;
            rail._prevLineCenter = cy; rail._haveTrackGeom = true;
            return;
        }
        if (ts === rail._prevTrackStart && sp === rail._prevTrackSpan
            && cy === rail._prevLineCenter) return;

        const t = Math.max(0, Math.min(1, rail.ballPos));
        const dx = (ts + sp * t) - (rail._prevTrackStart + rail._prevTrackSpan * t);
        const dy = cy - rail._prevLineCenter;

        rail._prevTrackStart = ts; rail._prevTrackSpan = sp; rail._prevLineCenter = cy;

        if (dx === 0 && dy === 0) return;
        particles.translateAll(dx, dy);
        // The cloud and the ball moved together, so this must not be read as
        // motion: no sparks, no chase.
        rail._lastX += dx;
        rail._lastY += dy;
        rail._attractor.x = rail._pBallX;
        rail._attractor.y = rail._pBallY;
    }

    // Watches the GROOVE's own geometry, not the rail's width.
    //
    // `onWidthChanged` fires before the groove has re-laid out, so reading its
    // track there returns the old numbers and the shift is never seen. A
    // single scalar over the values that actually matter changes only once
    // they have all settled.
    readonly property real trackGeomKey:
        groove.trackStart + groove.trackSpan * 4096 + groove.lineCenter * 16
    onTrackGeomKeyChanged: { rail._absorbLayoutShift(); rail._sampleBall(); }

    onBallPosChanged: rail._sampleBall()
    onActiveChanged: {
        if (!rail.active || !rail.particlesEnabled) return;
        rail._sampleBall();
        Qt.callLater(rail.seedSwirl);
    }

    // Decays the chase pull after the ball stops, then stops itself.
    Timer {
        id: chaseTimer
        interval: 32
        repeat: true
        running: false
        onTriggered: {
            const left = rail._chaseUntil - Date.now();
            rail._attractor.chase = (left > 0 && rail.ballSettled)
                ? rail.chaseStrength * (left / rail.chaseFalloffMs) : 0;
            if (left <= 0) { rail._attractor.chase = 0; running = false; }
        }
    }

    function _emitSparks(dx, dy, dt, speed) {
        const n = Math.floor(speed * rail.sparkAmountMultiplier) + 1;
        const vxBase = (-dx / dt) * 1000;
        const vyBase = (-dy / dt) * 1000;
        for (let i = 0; i < n; i++) {
            particles.emit({
                x: rail._pBallX,
                y: rail._pBallY,
                vx: vxBase * rail.sparkBaseVelocity + (Math.random() - 0.5) * rail.sparkScatter,
                vy: vyBase * rail.sparkBaseVelocity + (Math.random() - 0.5) * rail.sparkScatter,
                lifetime: rail.sparkLifetimeBase + Math.random() * rail.sparkLifetimeVariance,
                maxHistory: rail.sparkMaxHistory,
                sizeStart: rail.sizeScale * rail.particleSizeScale * rail.sparkSizeStart,
                sizeEnd: rail.sizeScale * rail.particleSizeScale * rail.sparkSizeEnd,
                colorStart: rail._tone.toString(),
                colorEnd: "transparent",
                drag: rail.sparkDrag,
                glowSpeedRef: rail.glowSpeedRef,
                glowMax: rail.glowMax,
                glowSizeGain: rail.glowSizeGain,
                forceField: rail._sparkField()
            }, 1);
        }
    }


    // =====================================================================
    //  BALL
    // =====================================================================
    SquishItem {
        id: ball
        anchors.fill: parent
        z: 5
        visible: rail._count > 0

        usePath: true
        // BOTH in pixels along the track, not in 0..1.
        //
        // SquishItem samples `pathFunc(trackPos + d)` with d sweeping
        // ±halfWidth in PIXELS to build the pill's contour. Handing it a 0..1
        // position would make every sample `0.4 ± 18`, which clamps to the two
        // ends of the track — so the "ball" would be a pill stretched across
        // the whole rail, drawn over the groove, never appearing to move, and
        // its drop shadow would blur a full-width box every frame.
        trackPos: groove.xAt(rail.ballPos)
        pathFunc: function (px) {
            return {x: px, y: groove.lineCenter, angle: 0};
        }
        overrideWidth: rail._ballW
        overrideHeight: rail._ballH

        color: rail.ballColor
        shadowColor: rail.ballShadowColor
        shadowOpacity: rail.ballShadowOpacity
        shadowBlur: rail.ballShadowBlur
    }

    // =====================================================================
    //  LABELS
    // =====================================================================
    Repeater {
        model: rail.steps
        delegate: Text {
            required property var modelData
            required property int index

            visible: rail._showLabels
            text: modelData.label
            // Future -> past -> current, as two fractions rather than a
            // `Behavior on color`: the three colours are themed, and a
            // Behavior would chase a light/dark switch 240ms behind the rail.
            property real pastF: (rail.allDone || index < rail._currentIdx) ? 1 : 0
            property real curF: (index === rail._currentIdx && !rail.allDone) ? 1 : 0
            Behavior on pastF {
                NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
            }
            Behavior on curF {
                NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
            }
            color: Mix.c3(rail.faintColor, rail.mutedColor, pastF,
                          rail.textColor, curF)
            font.family: rail.fontFamily
            font.pixelSize: rail.labelSize * rail.sizeScale
            font.bold: index === rail._currentIdx && !rail.allDone
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            width: rail._slot - 4
            x: groove.xAt(rail._stops[index]) - width / 2
            y: groove.implicitHeight + rail.labelGap * rail.sizeScale
        }
    }
}
