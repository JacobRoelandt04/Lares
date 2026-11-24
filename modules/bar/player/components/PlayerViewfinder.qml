pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects

import "../../../common/components/Mix.js" as Mix
import "../../../common/particles"
import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// PlayerViewfinder.qml
//
// The audio player's scrub bar: one engraved groove, a notch at each end, and
// a ball the user can actually take hold of. The playhead IS the ball, so
// where the ball is IS where the record is — the vinyl's rotation reads
// `displayPosition` off this component and nothing else.
//
// A FORK of PhaseRail, not a wrapper. It shares the rail's vocabulary
// (GrooveTrack, SquishItem in path mode, the edge-faded particle layer, the
// spark* knobs) because the shell is one material, but almost every LAW is
// different, and a two-step PhaseRail would be wrong in five places:
//
//   TWO SLOTS, NO NOTCHES BETWEEN.  `_stops` is [0, 1]: start and end. The
//   dots are the ends of the track, not milestones, so nothing about the
//   ball's shape is a function of where the notches are.
//
//   THE BALL IS DRAGGED, NOT COMMANDED.  PhaseRail's whole position pipeline
//   (dwell, notch seating, travel pacing) exists so a run's steps are seen;
//   here the user's finger owns the ball outright while it is down, and
//   `position` owns it the rest of the time. There is no dwell, no seating,
//   and no way for the ball to be somewhere the user did not put it.
//
//   SPARKS ARE PAID PER PIXEL, NOT PER SPEED SAMPLE.  A 10-minute track and
//   a 2-minute track throw the SAME number of sparks for the same movement,
//   even though the 10-minute ball crawls where the 2-minute ball runs.
//   PhaseRail emits `floor(speed*mult)+1` per sample, so the slow ball would
//   get a fifth of the particles for the same journey -- the wrong law here.
//   Travel is accumulated in pixels, `scrubSparkPerPx` converts it to sparks,
//   and the FRACTIONAL LEFTOVER IS CARRIED, so a thousand one-pixel steps and
//   one thousand-pixel step pay exactly the same. Speed still shapes a spark
//   -- it sets the velocity it is thrown with -- it just does not decide how
//   many there are.
//
//   THE BALL LIES IN THE GROOVE AND ONLY EVER GETS LONGER.  Across the
//   rail it is PhaseRail's ball exactly: round inside a slot, relaxed to
//   the groove's own thickness away from one, so between the two ends it
//   is flush with the channel's top and bottom edges. Along the rail the
//   scrub adds length to that and nothing else, so vertically it always
//   stays flush with the edges above and below. Two slots
//   instead of N notches also turns PhaseRail's per-frame scan over every
//   stop into a min() of two numbers.
//
//   THE BALL CAN BE ABSENT.  `ballVisible` is the host's "nothing is
//   playing", set with the same flag the track's skeleton goes up with. The
//   playhead then scales to nothing out of the centre of the groove over
//   `ballShowMs`, and comes back the same way — one fraction on both axes,
//   on the shadow's blur AND on the fill's two colours, so it grows out of
//   the channel rather than unrolling along it and takes the progress with
//   it. The groove stays: it is already the skeleton's shade, so the ball is
//   the only thing that goes -- but the FILL goes with it, because
//   GrooveTrack's fill is a clip whose hard edge is invisible only while the
//   ball sits on it, and at progress 0 that clip would still cover the left
//   half of the start dot in accent blue.
//
//   NO IDLE VORTEX.  There is no orbit field, no swirl seed, no chase timer
//   and no attractor: a resting playhead is not "working on something", it is
//   paused, and a swirl would say otherwise. Nothing here wakes a timer
//   while the ball is still.
//
//   ONE DRAW FOR A SPARK AND ITS GLOW.  The canvas is drawn ONCE, into
//   `bloomWrap`'s layer, and the blur is that layer's own effect: the colour
//   and the glow are the same pixels of the same texture on the same quad.
//   Painting the canvas as itself and laying a blurred copy over it through a
//   sibling MultiEffect's own capture would be two draws with two geometries,
//   which can come apart (a spark with no glow beside a glow with no spark);
//   one draw cannot. The edge fade stays outside it, so a spark
//   and its halo dim together at the card's clip.
//
// THREE EMISSION REGIMES, one rate each, all per-pixel:
//   scrub    the finger is on the ball          `scrubSparkPerPx`
//   sweep    the ball is travelling on its own  × `newTrackSparkScale`
//            (a click-seek, or a new track walking it end to end -- quieter
//            than a scrub of the same length)
//   play     the ball is creeping with the      `playSparkPerPx` ×
//            music                              (`playSparkFloor` + the rest
//                                               bought with `loudness`)
//
//   Playback pays a floor, and loudness is the modulation on top of it, not
//   the switch: a rate multiplied by the loudness alone is zero for a host
//   with no level tap, and a whole track would play without one spark.
//
//   Note what per-pixel means for playback: crossing a 320 px rail at the
//   default 1.4/px is ~450 sparks for the WHOLE track — about one a second
//   on a four-minute track at silence and twice that at a peak, whether that
//   track takes two minutes or ten. Being a rate per PIXEL is what makes the
//   ten-minute track's sparks further apart in TIME than the two-minute
//   one's; that is the law (both tracks generate the same amount of
//   particles), not an oversight.
//
// AND A FOURTH, WHICH IS THE MUSIC ITSELF:
//   music    the track is playing                  `musicSparkPerSec` ..
//                                                  `musicPeakSparkPerSec`
//                                                  per SECOND, plus a burst
//                                                  on every `beatSeq`
//
//   Bought with TIME, not with pixels, and that is deliberate: the music
//   wants a baseline of sparse particles even when quiet, and more and maybe
//   faster particles when a beat or loud part has just landed. A per-pixel
//   budget cannot deliver that at any setting -- a four-minute track buys
//   about one spark a second in total, so the loudest bar in the song has
//   nothing to multiply -- and a beat is an instant rather than a distance.
//   The travel budget above is untouched by it, so the parity law holds for
//   every gesture the user makes; only the music, which the user does not
//   make, pays by the clock. See THE MUSIC'S BUDGET for the numbers and the
//   ceiling.
//
// LOUDNESS IS TAKEN AS GIVEN. It is one clock and it belongs to whoever taps
// the audio (`PlayerLevelTap`, which owns the envelope, the running floor and
// ceiling, and the onset detector). Smoothing it a second time here would put
// two clocks on one motion. What arrives is NORMALISED -- how loud this
// moment is against the recent past, not an absolute RMS -- because an
// absolute one measures 0.2 to 0.3 all song and 0.005 at low volume, and
// neither can make a beat visible.
//
// The host must react to `seekRequested` (once per click, once per drag, on
// release) and may follow `scrubbing` continuously. Until the host answers, the
// ball SHOWS the place that was asked for: `_pendingSec` holds the target so a
// still-playing track's own position ticks cannot drag the ball back out from
// under a seek that is in flight. That latch is bounded three ways (the
// position arriving, the track changing, and a real timer): a source that
// never moves its position again — a paused daemon that ignored the seek —
// would otherwise leave the ball parked wherever it had been asked to go, for
// ever.
//
// WHERE THE BALL IS, IS A FUNCTION. See the POSITION PIPELINE section: the
// drawn place is `_targetPos + _travelOffset`, the first a pure function of
// (position, duration, drag, seek-in-flight) and the second the one owned
// exception, always on its way to zero. Nothing stores where the ball got to.
// =============================================================================
Item {
    id: rail

    // Device px per design px here (the nearest ScaleRoot's, else the window's): the layers below are made at the glass's resolution.
    DeviceScale {
        id: dev
    }

    // ======================================================================
    //  CONTENT
    // ======================================================================
    property real position: 0        // seconds into the track
    property real duration: 0        // seconds; 0 means there is no track
    property bool playing: false
    // 0..1, how loud the music is right now against the recent past --
    // `PlayerLevelTap.level`, which is normalised for exactly this. It raises
    // BOTH budgets: the playback rate per pixel (which still pays
    // `playSparkFloor` of itself with no loudness at all, so a host with no
    // tap still gets a rail that sparks) and the music's own rate per second.
    // Hand it a SMOOTHED value, never a raw RMS window.
    property real loudness: 0
    // False takes the rail out of the user's hands entirely: no drag, no
    // click, no hand cursor. It still reports progress truthfully, because
    // that is a different claim from "you may move this".
    property bool seekable: true

    // Is there a playhead at all? The host sets this false with the same flag
    // it puts the track's skeleton up with: nothing is playing, so there is
    // nothing for a playhead to point at, and the groove alone -- which is
    // already the skeleton's own shade -- is the honest picture. The user:
    // "the ball in the rail should also not be visible. This would look more
    // in line with the rest of the skeleton since the rail is already a
    // similar shade of the skeleton."
    property bool ballVisible: true

    // ======================================================================
    //  WHAT THE HOST MUST REACT TO
    // ======================================================================
    // Exactly one per gesture, on release (a click) or on the end of a drag.
    signal seekRequested(real seconds)
    // Continuous while the finger is down, so a host can paint an elapsed
    // figure that follows the ball rather than the daemon.
    signal scrubbing(real seconds)

    readonly property bool dragging: rail._dragging
    // What the ball is SHOWING right now — the contract the vinyl's rotation
    // is driven by. While the finger is down that is the drag; otherwise it
    // is the host's own position, deliberately NOT the ball's animated place,
    // so a host that never animates the record still tracks the daemon.
    readonly property real displayPosition: rail._dragging
        ? rail._dragFrac * rail.duration : rail.position

    // ======================================================================
    //  LOOK
    // ======================================================================
    property real sizeScale: 1.2
    property real lineThickness: 7
    property real dotSize: 11
    property real ballSize: 13
    property real edgePadding: 20

    property color accentColor: Theme.accent
    // The hover/grab lift. Nothing announces the affordance but the pointer:
    // a short colour fade and the hand cursor, exactly as everywhere else.
    property color accentHoverColor: Theme.accentHover
    property color grooveColor: Theme.panelSunk
    property color grooveBevelColor: Theme.bevel
    property color grooveShadowColor: Theme.border
    // The carve itself, in px before the list scale: GrooveTrack's own knobs,
    // forwarded so a host can tune the edge the ball runs in. The
    // COLOURS are theme tokens and are tuned as theme rows (Popup tab) --
    // a component-local hex is how a dark theme gets broken.
    property real grooveBevelWidth: 2
    property real grooveShadowWidth: 3
    property color surfaceColor: Theme.surface
    property color ballShadowColor: Theme.ballShadow
    property real ballShadowOpacity: 0.55
    property real ballShadowBlur: 12

    // Darken/lighten FACTORS rather than absolute colours, so the pair keeps
    // following the tone (and therefore the theme) instead of freezing.
    property real fillDarken: 1.4
    property real fillShadowDarken: 1.9
    property real ballLighten: 1.12

    property int hoverFadeMs: 160
    // The ball's coming and going. 160 ms is the shell's presence fade, and
    // the ball scales up from the centre, simply and quickly -- one fraction,
    // one easing, no overshoot and no bounce.
    property int ballShowMs: 160

    // The rail's single live colour. One eased fraction and one mix, never a
    // `Behavior on color`: a Behavior downstream of Theme cannot tell a hover
    // from the theme crossfading underneath it, and arrives a fade late.
    property real _liftF: (rail.seekable && (input.containsMouse || rail._dragging)) ? 1 : 0
    Behavior on _liftF {
        NumberAnimation { duration: rail.hoverFadeMs; easing.type: Easing.OutCubic }
    }
    // The ball's presence, as a fraction of its full size. Scaling BOTH axes
    // by one number is what makes it grow out of the centre of the groove
    // rather than unroll from one end, and it is one clock, so the shadow
    // (which is drawn from the same contour) comes and goes with it.
    property real _showF: rail.ballVisible ? 1 : 0
    Behavior on _showF {
        NumberAnimation { duration: rail.ballShowMs; easing.type: Easing.OutCubic }
    }

    readonly property color _tone: Mix.c(rail.accentColor, rail.accentHoverColor, rail._liftF)
    readonly property color _fillTone: Qt.darker(rail._tone, rail.fillDarken)
    readonly property color _fillShadowTone: Qt.darker(rail._tone, rail.fillShadowDarken)
    // THE FILL GOES WITH THE BALL, on the ball's own clock.
    //
    // GrooveTrack's fill is a clip over a second copy of the engraving, and
    // the clip's edge is a HARD cut that is only invisible because the ball
    // sits exactly on it (GrooveTrack says so itself). Take the ball away and
    // the cut is on show -- and at `progress` 0, where the host puts the rail
    // when nothing is playing, the clip is still `trackStart` wide, so the
    // LEFT HALF OF THE START DOT stays accent blue. A hard blue half-disc is
    // the opposite of a rail that is already a similar shade to the skeleton,
    // which is the reason the ball is hidden.
    //
    // So the fill's two colours cross to the channel's two on `_showF`: no
    // playhead, no progress, and the whole rail is the plain groove. One
    // clock (the ball's), one mix, no `Behavior on color`, and at full
    // presence `Mix.c` returns the accent end exactly -- so a rail with a
    // ball in it keeps the accent fill bit for bit.
    readonly property color grooveFillColor:
        Mix.c(rail.grooveColor, rail._fillTone, rail._showF)
    readonly property color grooveFillShadowColor:
        Mix.c(rail.grooveShadowColor, rail._fillShadowTone, rail._showF)
    property color ballColor: Qt.lighter(rail._tone, rail.ballLighten)

    // ======================================================================
    //  BALL SHAPE
    //
    //  One law per axis, and they do not talk to each other.
    //
    //  ACROSS the rail: PhaseRail's ball, with the two ENDS as its notches.
    //  Full diameter inside a slot, relaxing over half a diameter to the
    //  groove's own thickness away from one, so anywhere between the ends it
    //  lies flush with the channel's top and bottom edges. Nothing else
    //  touches this axis — in particular the scrub does not, so vertically
    //  the ball always stays flush with the edges above and below.
    //
    //  ALONG the rail: first as long as area conservation makes it (a ball
    //  squeezed into a 7 px channel has to go somewhere), and the scrub then
    //  multiplies THAT by one eased fraction off the measured speed. So a
    //  fast drag lengthens a pill that is already long, and a ball parked in
    //  an end slot is a circle however it got there.
    // ======================================================================
    property real ballStretchMax: 3        // multiples of the resting length, at full speed
    property real ballStretchSpeedRef: 0.8   // px/ms that reaches the ceiling
    property int  ballStretchMs: 130         // the one clock the stretch moves on
    // The ceiling on the area-conserving flatten by itself, in diameters,
    // before any scrub stretch. PhaseRail's number.
    property real ballFlatStretchMax: 1.1
    // The flattened ball overshoots the channel by this much. Matching the
    // groove's thickness exactly leaves the groove's darker edge showing as a
    // hairline above and below the ball, because both shapes are antialiased
    // and each gives up part of its outermost pixel. PhaseRail's number, for
    // PhaseRail's reason.
    property real ballGrooveBleed: 1.0

    readonly property real _scBall: rail.ballSize * rail.sizeScale
    // Never wider than the ball itself: a groove thicker than the ball would
    // otherwise INFLATE it in the middle of the rail instead of flattening it.
    readonly property real _grooveH: Math.min(
        rail._scBall, rail.lineThickness * rail.sizeScale + rail.ballGrooveBleed)
    // Distance to the nearer end of the track, in px. Two stops, so this is a
    // min() of two numbers rather than PhaseRail's scan over `_stops`.
    readonly property real _endDist: Math.min(
        Math.abs(rail._ballX - groove.trackStart),
        Math.abs(groove.trackEnd - rail._ballX))
    readonly property real _ballH: {
        const relaxR = Math.max(0.001, rail._scBall / 2);
        const f = Math.min(1, rail._endDist / relaxR);
        const s = f * f * (3 - 2 * f);       // smoothstep, PhaseRail's curve
        return rail._scBall - (rail._scBall - rail._grooveH) * s;
    }
    // The length it rests at, area conserved against that flatten and capped.
    readonly property real _restW: Math.min(
        (rail._scBall * rail._scBall) / Math.max(1, rail._ballH),
        rail._scBall * rail.ballFlatStretchMax)
    readonly property real _ballW: rail._restW * (1 + rail._stretchF * (rail.ballStretchMax - 1))

    // The shape law above says what the ball IS; these two say what is drawn,
    // which is that shape scaled by its presence. Never exactly zero: at 0
    // `SquishItem` reads `overrideWidth`/`overrideHeight` as "not overridden"
    // and falls back to its own velocity-derived size, which would leave a
    // full 14 px ball sitting where it had just finished disappearing. A
    // thousandth of a pixel is under the contour builder's own 0.1 px floor,
    // so it draws nothing at all.
    readonly property real _drawH: Math.max(0.001, rail._ballH * rail._showF)
    readonly property real _drawW: Math.max(0.001, rail._ballW * rail._showF)

    property real _stretchF: 0
    // ONE threshold with two consumers, and it is a SHAPE threshold, not a
    // timer's convenience.
    //
    // 0.01, not 0, and not the Behavior's own epsilon: playback creep samples
    // a speed of ~0.002 px/ms. A residual stretch of 0.01 is 0.09 px of a
    // 15 px ball -- nothing to see. Below it the stretch is written as a clean
    // ZERO rather than as the small number it computes to, because `dt` is an
    // INTEGER millisecond off Date.now() while `dist` is a float frame delta,
    // so the quotient jitters a few percent EVERY FRAME. Every one of those
    // writes re-targeted the Behavior below, which moved `_ballW`, which moved
    // `_drawW`, which is the ball's `overrideWidth` -- so the ball's outline
    // differed every frame, for ever, by less than a tenth of a pixel, and the
    // canvas that draws it could never once be told it had nothing to redraw.
    readonly property real _stretchFloor: 0.01
    Behavior on _stretchF {
        NumberAnimation { duration: rail.ballStretchMs; easing.type: Easing.OutCubic }
    }

    // Speed is only sampled when the ball MOVES, so a ball that stops with
    // the finger still down would keep its last stretch for ever. This runs
    // only while there is a stretch to give back, and stops itself.
    Timer {
        id: relaxTimer
        interval: 48
        repeat: true
        // The same floor the stretch itself is snapped to, so this cannot
        // wake for a value the sampler has already decided is nothing.
        running: rail._stretchF > rail._stretchFloor
        onTriggered: if (Date.now() - rail._lastMs >= relaxTimer.interval) rail._stretchF = 0
    }

    // ======================================================================
    //  PARTICLES
    //
    //  The canvas, its overscan, the per-edge fade lines and the bloom gate
    //  are PhaseRail's — they are not rail-specific and they are the proven
    //  idle-wattage shape. There is nothing orbit-related.
    // ======================================================================
    property bool particlesEnabled: true
    property bool sparksEnabled: true
    // The pool. A full-rail fling at the default rate is ~105 sparks in the
    // air at once; `emit` silently DROPS when the pool is full, so this is
    // sized for the worst gesture rather than the usual one. Read once, at
    // construction — a host setting it later changes nothing.
    property int maxParticles: 700

    // The particle Canvas culls to its own bounds, so it is grown past the
    // rail on every side; the fade below turns that boundary into a fade
    // rather than a cut.
    property real particleMargin: 46
    // Where the sparks must have reached zero, as a distance in px OUTSIDE
    // the rail's own bounds — the host sets these to wherever its card clips.
    property real particleEdgeLeft: rail.particleMargin
    property real particleEdgeRight: rail.particleMargin
    property real particleEdgeTop: rail.particleMargin
    property real particleEdgeBottom: rail.particleMargin
    property real particleFadeWidth: 18

    // ---- Rates: sparks per PIXEL of travel, one per regime ----------------
    property real scrubSparkPerPx: 0.35
    // The playback rate at FULL loudness. Measured, not guessed: at 1.4 a
    // 320 px rail throws about one spark a second at silence and two at a
    // peak on a four-minute track, which is one or two in the air at any
    // moment -- present, not busy.
    property real playSparkPerPx: 1.4
    // The share of that rate playback pays whatever the music is doing.
    // Loudness buys the rest. At 0 the rate is the loudness alone, and a host
    // with no level tap wired would play a whole track without a spark.
    property real playSparkFloor: 0.5
    // The end-to-end sweep of a new track is quieter than a scrub of the
    // same length: the user did not do it.
    property real newTrackSparkScale: 0.35
    // One frame with a very large jump in it must not eat the whole pool.
    property int  sparkMaxPerSample: 12

    // ---- The music's own budget ------------------------------------------
    //
    //  A rail that only pays for TRAVEL cannot show a beat. At the default
    //  1.4 sparks per pixel a four-minute track buys about one spark a
    //  second, so the loudest bar in the song is multiplying a budget with
    //  nothing in it and the effect reads as flat. What the music wants is a
    //  baseline of sparse particles even when quiet, and more and maybe faster
    //  ones when a beat or a loud part has just landed.
    //
    //  So playback has a SECOND budget, bought with TIME instead of pixels,
    //  and that is the one the music modulates:
    //
    //    baseline   `musicSparkPerSec` a second, always, while a track plays
    //               -- the sparse thing that never stops
    //    loudness   rising to `musicPeakSparkPerSec` as `loudness` reaches 1,
    //               along `musicRateGamma` so the middle of the range stays
    //               sparse and only a genuinely loud passage is busy
    //    onsets     `beatSeq` counting up throws a burst at once, bigger and
    //               FASTER the stronger the beat
    //    ceiling    and none of it emits while `musicMaxInAir` sparks are
    //               already alive, because the rail is not the centrepiece --
    //               the record is
    //
    //  The travel budget above is untouched: a scrub costs the same sparks on
    //  a two-minute track as on a ten-minute one, which is the parity law.
    //  Time buys the music's sparks because a beat is an instant, not a
    //  distance.
    property bool musicSparksEnabled: true
    // TUNED BY LOOKING, because the arithmetic is no guide to what a number
    // looks like. A spark lives 0.7-1.7 s, so what the eye counts is
    // RATE x 1.2 -- and the travel budget already spends 1.0-1.5 a second
    // during playback, before the music spends anything. Too much attracts all
    // the attention:
    //   3.0 peak / 5 per beat / 18 ceiling: 10 sparks a second, the ceiling
    //     hit on nearly every frame, a permanent cloud round the ball.
    //   2.2 / 4 / 12: 7 a second, still a halo in every frame of the tile.
    //   0.5 / 3 / 10, with the tap's onsets thinned to ~1.1 a second: about
    //     2 sparks in the air through a quiet passage and 5-6 through a loud
    //     one, and a beat lands as a puff of three rather than as more of the
    //     same stream.
    //   0.2 / 2.2 (the default): calmer through a quiet passage and a bigger
    //     puff on a loud one.
    property real musicSparkPerSec: 0.2
    property real musicPeakSparkPerSec: 2.2
    // >1 bends the rate away from the middle, so "loud" reads as an event
    // rather than as the normal state. The tap's own distribution is already
    // bottom-heavy (median 0.10, p75 0.83 on a real track), so a steeper curve
    // here bends an already-bent number twice. Tuned by eye in the mockup.
    property real musicRateGamma: 1.9
    // How much faster a spark leaves at full loudness, and at a full beat, as
    // a fraction of the scatter. A beat throws more particles and faster ones;
    // this is the faster.
    property real musicSpeedGain: 0.5
    property real beatSpeedGain: 1.0
    // The burst on an onset, at full strength. A weak beat still throws a
    // third of it -- a beat that shows nothing is not a beat.
    property int  musicBeatSparks: 3
    // The ceiling on everything the music buys: no music spark is emitted
    // while this many are already in the air. Travel is not capped by it --
    // a scrub is the user's own gesture and answers to their hand.
    property int  musicMaxInAir: 10
    // How often the time budget is paid out. The tap itself only updates at
    // 15.6 Hz, and the remainder is carried, so a slower clock than the
    // sampler costs nothing but wakeups.
    property int  musicSampleMs: 100

    // ---- The beat feed ---------------------------------------------------
    //
    //  `beatSeq` counting up IS the beat; `beatStrength` is how big that one
    //  was, 0..1. A counter rather than a pulse because a beat is an EVENT,
    //  and an event carried by a level is an event that can be missed between
    //  two samples or seen twice. A host with no beat detector leaves both at
    //  zero and gets the loudness curve alone, which is a complete behaviour.
    property int beatSeq: 0
    property real beatStrength: 0

    // ---- Spark shape: PhaseRail's vocabulary and its tuned numbers -------
    property real sparkBaseVelocity: 0.1
    property real sparkScatter: 110
    property real sparkLifetimeBase: 700.0
    property real sparkLifetimeVariance: 1000.0
    property int  sparkMaxHistory: 6
    property real sparkSizeStart: 3.0
    property real sparkSizeEnd: 1.0
    property real sparkDrag: 2.6
    property real sparkSwirlStr: 0.4
    property real sparkSwirlProb: 0.4

    property real particleSizeScale: 1.0
    property real glowSpeedRef: 2600
    property real glowMax: 2.6
    property real glowSizeGain: 0.7
    property real bloomBlur: 6
    property real bloomStrength: 0.32
    property real bloomBrightness: 0.8

    // Total sparks emitted since load. Written by the rail, read by the
    // probe: an emission law that cannot be counted cannot be proved.
    property int sparkCount: 0

    // ======================================================================
    //  POSITION PIPELINE
    //
    //  ONE LAW:   _ballPos = _targetPos + _travelOffset
    //
    //  `_targetPos` is a pure function of (position, duration, drag state,
    //  seek-in-flight). `_travelOffset` is the ONE thing here that remembers
    //  anything: the gap between where the ball is drawn and where it
    //  belongs. It is only ever written by `travelAnim`, it is always
    //  animated to exactly zero, and a guard timer zeroes it if it is ever
    //  left non-zero with nothing animating it. So there is no state the ball
    //  can be stranded in — whatever happens, one travel later it is showing
    //  (position, duration) again.
    //
    //  THE BALL'S POSITION IS NEVER STORED AND MOVED FROM A HANDLER
    //  (`on_TargetPosChanged`), which misses what a binding cannot:
    //    · A value that never changes never moves a stored ball, so a rail
    //      born showing 0.5 (a popup reopened on a half-played track) would
    //      keep the 0 its property defaults to. A binding cannot miss a value
    //      it was born with.
    //    · A track change that arrives as two separate property writes could
    //      leave a stored ball mid-journey to an intermediate place. The
    //      offset form re-aims without moving the ball, so an intermediate
    //      target is one frame of a curve, never a seam.
    //    · A pending seek retired only inside `on_PosFracChanged`, which a
    //      source that never moves its position again never calls, would leave
    //      the ball stuck at 60% after a seek a paused daemon ignored. The
    //      answer window is a real timer.
    // ======================================================================
    // How long a seek waits to be honoured before the rail gives up on the
    // host and follows `position` again.
    property int seekAnswerMs: 2000
    // How close `position` has to land for a seek to count as answered.
    property real seekSettleSec: 1.5
    // Optional, and empty means unused. Anything that identifies the track —
    // MPD's file path or song id will do. A new track normally announces
    // itself by changing `duration` and `position` at once, but two tracks of
    // the same length do not change the duration, so a host with an identity
    // to hand should pass it: any change of it is a new track.
    property string trackKey: ""
    // A position change bigger than this is a JUMP (a seek, or a new track)
    // and the ball travels to it; anything smaller is playback creep and the
    // ball simply is there. Expressed in SECONDS so the same music reads the
    // same way on a two-minute track and a ten-minute one.
    property real travelSeekSec: 1.5
    // A full-rail sweep, in ms; shorter journeys take proportionally less,
    // down to `travelMinMs`, so a click next to the ball is not a 420 ms crawl.
    property int travelMs: 420
    property int travelMinMs: 140
    // Past which a press is a drag rather than a click.
    property real dragDeadzone: 3
    // The fastest the ball can be MEASURED moving, in px/ms, before the sample
    // is treated as a re-seat instead. A flung ball crosses a 500 px rail in
    // about 150 ms (3.3 px/ms) and a hand-drag is slower still; 20 is an order
    // of magnitude clear of anything real, and two orders under the half a
    // million pixels a second that two samples in one event turn produce.
    property real speedCeiling: 20

    readonly property real _posFrac: rail.duration > 0
        ? Math.max(0, Math.min(1, rail.position / rail.duration)) : 0

    property bool _dragging: false
    property bool _pressed: false
    property real _pressX: 0
    property real _dragFrac: 0

    // A seek asked for and not yet confirmed by the host; -1 is none.
    property real _pendingSec: -1

    // Where the ball is told to be, 0..1. A pure function of its inputs.
    readonly property real _targetPos: {
        if (rail._dragging) return rail._dragFrac;
        if (rail._pendingSec >= 0 && rail.duration > 0)
            return Math.max(0, Math.min(1, rail._pendingSec / rail.duration));
        return rail._posFrac;
    }

    // The one owned exception, and the whole of the rail's memory.
    property real _travelOffset: 0

    // The ball's ACTUAL position, 0..1 — a binding, never assigned.
    readonly property real _ballPos:
        Math.max(0, Math.min(1, rail._targetPos + rail._travelOffset))

    // ---- the seek latch, bounded three ways ------------------------------
    function _requestSeek(seconds) {
        rail._pendingSec = seconds;
        // A second seek gets a whole window of its own: the timer's `running`
        // binding is already true, so without this it would run out the
        // FIRST seek's clock.
        answerTimer.restart();
    }
    function _clearPending() {
        if (rail._pendingSec < 0) return;
        rail._pendingSec = -1;
        answerTimer.stop();
    }

    // (1) The host answered: its position landed where we asked.
    on_PosFracChanged: {
        if (rail._pendingSec < 0) return;
        if (Math.abs(rail.position - rail._pendingSec) <= rail.seekSettleSec)
            rail._clearPending();
    }
    // (2) A pending seek is a number of seconds into THE TRACK IT WAS ASKED
    // ON, so a new track answers it by making it meaningless. Both of the
    // things a track change always moves are watched, and `trackKey` covers
    // the one case that moves neither.
    onDurationChanged: rail._clearPending()
    onTrackKeyChanged: rail._clearPending()
    // (3) And the host may simply not answer — a paused daemon that refused
    // the seek never moves its position again, and waiting for that move
    // would last for ever. This is the timer that ends it.
    Timer {
        id: answerTimer
        interval: rail.seekAnswerMs
        // Armed by the latch itself rather than only by `_requestSeek`, so a
        // pending seek can never exist without a clock running it out.
        running: rail._pendingSec >= 0
        onTriggered: rail._pendingSec = -1
    }

    // ---- the travel -------------------------------------------------------
    // The fraction of the rail below which a move is creep rather than a
    // jump. With no track everything is creep, so an empty rail never
    // animates anything.
    readonly property real _creepFrac: rail.duration > 0
        ? Math.min(0.25, rail.travelSeekSec / rail.duration) : 1

    // Where the target was when the ball was last aimed. Kept because
    // `_ballPos` has already re-evaluated by the time the handler runs, so
    // the place the ball was DRAWN has to be reconstructed from the previous
    // target and the offset still in flight.
    property real _lastTarget: 0

    // Until the rail has been told once what it is showing, nothing is a
    // journey: a popup opened on a half-played track SHOWS half rather than
    // sweeping to it, and everything the host sets in the same turn as the
    // track itself lands as one snap. Losing the track disarms it, so a
    // module whose source only answers a moment after the popup opens shows
    // the truth the moment it arrives instead of sweeping to it from the
    // start. A track that merely CHANGES leaves the rail armed, so the
    // new-track sweep still happens.
    property bool _armed: false
    readonly property bool _hasTrack: rail.duration > 0
    on_HasTrackChanged: {
        if (rail._hasTrack) {
            rail._openGrace();
            Qt.callLater(rail._arm);
        } else {
            rail._armed = false;
        }
    }

    // THE OPEN'S GRACE: THE POSITION THAT IS CORRECTED AFTER THE POPUP OPENS IS NOT A SEEK. A popup is built on `position` = the
    // player's `elapsed` as it stood when nobody looked (a clock that was not running), and the open itself corrects it: the first
    // holder of the clock catches it up by the unwatched time, and the status read that follows seats it again. Both land AFTER the arm
    // below, so each looked like a seek -- the ball flew to the true place, sparking the whole way (or, snapped, was billed the jump).
    // Through the grace a jump of the target snaps the ball and is never read as motion; the playhead's own creep is too small to
    // matter for this long. It ends `openGraceQuietMs` after the LAST jump (the catch-up and the seat are two), no sooner than
    // `openGraceMs` after the open and no later than `openGraceMaxMs`; a seek after that is a seek again.
    property int openGraceMs: 400
    property int openGraceQuietMs: 250
    property int openGraceMaxMs: 1500
    property bool _grace: false
    property real _graceStartMs: 0
    property real _graceUntilMs: 0
    function _openGrace() {
        const now = Date.now();
        rail._grace = true;
        rail._graceStartMs = now;
        rail._graceUntilMs = now + rail.openGraceMs;
        graceTimer.interval = rail.openGraceMs;
        graceTimer.restart();
    }
    // A jump of the target inside the grace: the grace lasts until the quiet has passed after it.
    function _graceJumped() {
        const now = Date.now();
        const until = Math.min(rail._graceStartMs + rail.openGraceMaxMs, Math.max(rail._graceUntilMs, now + rail.openGraceQuietMs));
        rail._graceUntilMs = until;
        graceTimer.interval = Math.max(1, until - now);
        graceTimer.restart();
    }
    Timer {
        id: graceTimer
        onTriggered: rail._grace = false
    }
    Component.onCompleted: rail._openGrace()
    // Re-tested rather than assumed: a track that came and went inside one
    // turn must not leave a deferred arm behind it.
    function _arm() { rail._armed = rail._hasTrack; }

    on_TargetPosChanged: {
        const prev = rail._lastTarget;
        rail._lastTarget = rail._targetPos;
        // The finger owns the ball outright, and a rail that has not been
        // told anything yet has nowhere to travel from.
        const d = rail._targetPos - prev;
        // The open's own corrections of the position snap (see `_openGrace`), armed or not.
        if (rail._grace && Math.abs(d) > rail._creepFrac)
            rail._graceJumped();
        if (rail._dragging || !rail._armed || rail._grace) { rail._snapToTarget(); return; }
        // Creep. The ball follows the target for free, and any travel still
        // in flight keeps running underneath it — which is what makes a seek
        // that lands mid-journey one motion instead of two.
        if (Math.abs(d) <= rail._creepFrac) return;
        rail._travelFrom((prev + rail._travelOffset) - rail._targetPos);
    }

    function _snapToTarget() {
        travelAnim.stop();
        rail._travelOffset = 0;
    }

    // Hold the ball exactly where it is drawn, then ease the gap to nothing.
    // Re-aiming mid-travel therefore never moves the ball by a pixel.
    function _travelFrom(off) {
        travelAnim.stop();
        // Written so a NaN takes the snap branch rather than starting an
        // animation that can never finish.
        if (!(Math.abs(off) > 1e-4)) { rail._travelOffset = 0; return; }
        rail._travelOffset = off;
        // THE BALL DID NOT MOVE, SO THE SAMPLER MUST NOT THINK IT DID.
        //
        // `_targetPos` jumping is what brings us here, and the jump re-evaluates
        // `_ballPos` -- which fires `_sampleBall` -- BEFORE this handler runs to
        // put the offset back. So the sampler has just been billed the whole
        // rail for a ball that is drawn in exactly the same place, and it would
        // be billed it a second time on the next sample measured from there.
        // The offset is seated first and the anchor re-seated after, which is
        // the same thing `_absorbLayoutShift` does when the LAYOUT moves the
        // ball and the cloud together: "this must not be read as motion".
        rail._lastX = rail._pBallX;
        rail._lastY = rail._pBallY;
        rail._lastMs = Date.now();
        travelAnim.duration = Math.max(rail.travelMinMs, rail.travelMs * Math.abs(off));
        travelAnim.start();
    }

    NumberAnimation {
        id: travelAnim
        target: rail
        property: "_travelOffset"
        to: 0
        easing.type: Easing.OutCubic
        onFinished: rail._stretchF = 0
    }

    // The dead man's handle on the rail's only memory: if the offset is ever
    // left non-zero with nothing animating it, the ball is back on its target
    // within a frame or two. It runs ONLY in that state, so in every normal
    // one it never wakes — and it is what makes "the travel always
    // terminates" a property of the file rather than of its callers.
    Timer {
        interval: 64
        running: rail._travelOffset !== 0 && !travelAnim.running
        onTriggered: rail._travelOffset = 0
    }

    implicitHeight: groove.implicitHeight

    // ======================================================================
    //  GROOVE
    //
    //  Centred rather than pinned to the top: there are no labels under it,
    //  so a host that gives the rail more height than it asks for gets that
    //  height as HIT AREA around the groove — which is the only way to
    //  fatten a 17 px drag target, since Qt Quick prunes pointer delivery at
    //  the rail's own bounds and a MouseArea hanging outside them would
    //  receive nothing.
    // ======================================================================
    readonly property var _stops: [0, 1]

    // How far the groove's ends sit inside the item, in px -- the CENTRE of
    // each end slot, which is what `xAt(0)` and `xAt(1)` return and therefore
    // what a seek's arithmetic is done in. The padding is not optional: it is
    // the room the two end slots need, and a slot cut in half by the card's
    // edge is exactly what it prevents.
    readonly property real grooveInset: rail.edgePadding * rail.sizeScale

    // How far the OUTER EDGE of an end slot sits inside the item, in px.
    //
    // This is the measure a host lines the rail up with, not `grooveInset`.
    // A slot is a circle centred on the groove's end, so its edge is half a
    // slot further out than that centre, and hanging the item out by
    // `grooveInset` puts the two half-circles PAST whatever the groove's ends
    // were meant to be level with, out beyond the texts above. A host that wants the
    // rail flush with something outside it (the left edge of the elapsed
    // figure, the right edge of the total) hangs the item out by THIS on each
    // side. At the popup's own scale it is 20 - 13/2 = 13.5 px.
    //
    // The CARVED edge, not the bevel. The light rim GrooveTrack lays outside
    // that edge (`grooveBevelWidth`, 2 px unscaled) is the lip of the surface
    // the slot is cut into rather than part of the slot, and in light mode it
    // is 4/255 off that surface (#EEF0F7 against #EAEDF5). A host that wants
    // even the rim inside the figures uses `endSlotInset - 2 * sizeScale`.
    //
    // Signed, and deliberately not clamped at zero: a slot wider than twice
    // the padding would hang OUTSIDE the item, and a host told "zero" there
    // would line the figures up with a half-circle that is not where it says.
    readonly property real endSlotInset:
        rail.grooveInset - rail.dotSize * rail.sizeScale / 2

    GrooveTrack {
        id: groove
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: groove.implicitHeight

        lineThickness: rail.lineThickness
        dotSize: rail.dotSize
        edgePadding: rail.edgePadding
        sizeScale: rail.sizeScale
        stops: rail._stops
        progress: rail._ballPos
        showFill: true

        surfaceColor: rail.surfaceColor
        grooveColor: rail.grooveColor
        grooveBevelColor: rail.grooveBevelColor
        grooveShadowColor: rail.grooveShadowColor
        grooveBevelWidth: rail.grooveBevelWidth
        grooveShadowWidth: rail.grooveShadowWidth
        fillColor: rail.grooveFillColor
        fillShadowColor: rail.grooveFillShadowColor
    }

    readonly property real _ballX: groove.xAt(rail._ballPos)
    readonly property real _lineY: groove.y + groove.lineCenter

    // Ball position in PARTICLE coordinates (the canvas is inset by
    // particleMargin on every side).
    readonly property real _pBallX: rail._ballX + rail.particleMargin
    readonly property real _pBallY: rail._lineY + rail.particleMargin

    // ======================================================================
    //  PARTICLE LAYER
    // ======================================================================
    Item {
        id: particleLayer
        x: -rail.particleMargin
        y: -rail.particleMargin
        width: rail.width + rail.particleMargin * 2
        height: rail.height + rail.particleMargin * 2
        z: 3

        // Inset of each fade-zero line from the layer's own edge. The edge is
        // measured outward from the RAIL, and the layer already extends
        // `particleMargin` past it, so an edge at the margin sits on the
        // layer's boundary and a smaller one moves inward.
        readonly property real _insetL: Math.max(0, rail.particleMargin - rail.particleEdgeLeft)
        readonly property real _insetR: Math.max(0, rail.particleMargin - rail.particleEdgeRight)
        readonly property real _insetT: Math.max(0, rail.particleMargin - rail.particleEdgeTop)
        readonly property real _insetB: Math.max(0, rail.particleMargin - rail.particleEdgeBottom)
        readonly property real _w: Math.max(1, particleLayer.width)
        readonly property real _h: Math.max(1, particleLayer.height)

        layer.enabled: rail.particlesEnabled && particles.hasParticles
        layer.textureSize: dev.texSize(particleLayer._w, particleLayer._h)
        layer.effect: ShaderEffect {
            // The layer's own texture (`layer.samplerName` defaults to this).
            property var source

            property vector4d edges: Qt.vector4d(
                particleLayer._insetL / particleLayer._w,
                particleLayer._insetT / particleLayer._h,
                1 - particleLayer._insetR / particleLayer._w,
                1 - particleLayer._insetB / particleLayer._h)
            // Two fade widths, one per axis: the same number of px is a
            // different fraction of a side that is not square.
            property vector2d fade: Qt.vector2d(
                rail.particleFadeWidth / particleLayer._w,
                rail.particleFadeWidth / particleLayer._h)

            fragmentShader: "../../../common/components/shaders/edge_fade.frag.qsb"
        }

        // The bloom is a LINK IN THE CHAIN, never a second draw.
        //
        // A sibling `MultiEffect { source: particles }` would draw the canvas
        // once as itself and a second time as a captured, blurred, brightened
        // copy laid over it — two draws of one burst, each carried by its own
        // geometry, which come apart (a glow with no spark in it beside the
        // spark in the correct position with no glow). Colour and glow cannot
        // be in two places if they are the same pixels, so the canvas is drawn
        // exactly ONCE, into this wrapper's layer, and the blur is that
        // layer's own effect.
        //
        // `autoPaddingEnabled` is off for the same reason:
        // with it on the effect grows its own rect past the texture it was
        // handed, which is exactly how a blurred copy ends up mapped
        // somewhere its source is not. The wrapper already carries
        // `particleMargin` of clear air on every side and the fade outside it
        // reaches zero well before that boundary, so nothing is lost to it.
        Item {
            id: bloomWrap
            anchors.fill: parent
            z: 3

            // Gated on particles actually existing, not on the effect being
            // enabled: a MultiEffect keeps blurring a blank canvas every
            // frame otherwise. The canvas's own `visible` is never touched —
            // a Cooperative canvas gives one opaque garbage frame when it is.
            layer.enabled: rail.particlesEnabled && particles.hasParticles
            layer.textureSize: dev.texSize(bloomWrap.width, bloomWrap.height)
            layer.effect: MultiEffect {
                blurEnabled: true
                blurMax: rail.bloomBlur
                blur: rail.bloomStrength
                brightness: rail.bloomBrightness
                autoPaddingEnabled: false
            }

            ParticleSystem {
                id: particles
                anchors.fill: parent
                maxParticles: rail.maxParticles
                // HELD STILL WHILE THE THEME CROSSFADES: the switch is a still picture of
                // the frame before, and sparks that go on flying under it are a second set
                // a few pixels ahead of the first (a swirl reads as two vortices).
                // The system caps a long dt at one frame, so resuming does not lurch.
                running: rail.particlesEnabled && !Theme.crossfading
            }
        }
    }

    // ======================================================================
    //  EMISSION
    // ======================================================================
    // Sparks per pixel of travel, by regime. Zero means the accumulator is
    // thrown away rather than banked, so a passage that emits nothing at all
    // (paused, or the sparks switched off) does not save up its travel and
    // dump it in one burst when it starts again.
    function _sparkRate() {
        if (!rail.particlesEnabled || !rail.sparksEnabled) return 0;
        // A ball that is not there throws nothing. Without this a host that
        // hides the playhead while the source is still reporting a position
        // would go on shedding sparks from an invisible thing.
        if (rail._showF <= 0.01) return 0;
        if (rail._dragging) return rail.scrubSparkPerPx;
        if (travelAnim.running) return rail.scrubSparkPerPx * rail.newTrackSparkScale;
        if (!rail.playing) return 0;
        const floor = Math.max(0, Math.min(1, rail.playSparkFloor));
        const loud = Math.max(0, Math.min(1, rail.loudness));
        return rail.playSparkPerPx * (floor + (1 - floor) * loud);
    }

    // Debris, with no attraction to the ball — the same late-life swirl on a
    // random subset that every spark in the shell has.
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

    // The tone at alpha zero, as a colour rather than the string
    // "transparent": the particle parser only understands #RRGGBB and
    // #AARRGGBB and falls back to OPAQUE WHITE on anything else, which is
    // why PhaseRail's sparks actually lerp toward white.
    readonly property color _sparkFade: Qt.rgba(rail._tone.r, rail._tone.g, rail._tone.b, 0)

    // ONE emitter for both budgets. It takes the velocity to throw from --
    // backwards along the travel for a spark bought with distance, nothing at
    // all for one bought with time, since a beat has no direction -- and a
    // scale on the scatter, which is the "faster particles" a loud moment
    // buys. A second emit function would be a second place for the spark's
    // shape to drift.
    function _emitSparks(vxBase, vyBase, n, velScale) {
        const scatter = rail.sparkScatter * velScale;
        // Hoisted out of the loop: PhaseRail re-stringifies and re-parses the
        // tone for every single particle, and a per-pixel emitter runs hotter
        // than it does.
        const c0 = rail._tone.toString();
        const c1 = rail._sparkFade.toString();
        for (let i = 0; i < n; i++) {
            particles.emit({
                x: rail._pBallX,
                y: rail._pBallY,
                vx: vxBase * rail.sparkBaseVelocity + (Math.random() - 0.5) * scatter,
                vy: vyBase * rail.sparkBaseVelocity + (Math.random() - 0.5) * scatter,
                lifetime: rail.sparkLifetimeBase + Math.random() * rail.sparkLifetimeVariance,
                maxHistory: rail.sparkMaxHistory,
                sizeStart: rail.sizeScale * rail.particleSizeScale * rail.sparkSizeStart,
                sizeEnd: rail.sizeScale * rail.particleSizeScale * rail.sparkSizeEnd,
                colorStart: c0,
                colorEnd: c1,
                drag: rail.sparkDrag,
                glowSpeedRef: rail.glowSpeedRef,
                glowMax: rail.glowMax,
                glowSizeGain: rail.glowSizeGain,
                forceField: rail._sparkField()
            }, 1);
        }
        rail.sparkCount += n;
    }

    // ---- Ball-movement sampling -----------------------------------------
    //
    // Driven by the ball moving, never by a clock: a resting playhead costs
    // nothing at all.
    property real _lastX: 0
    property real _lastY: 0
    property real _lastMs: 0
    property real _travelAccum: 0     // px of travel bought but not yet paid out
    property bool _seeded: false

    function _sampleBall() {
        // NOT gated on `particlesEnabled`. The stretch is a law about the
        // ball's SHAPE, not about sparks, and one switch must not quietly do
        // two things: a host (or the control panel) that turns the sparks off
        // would otherwise freeze the squish with them. Keeping the sample warm
        // while they are off is also what stops re-enabling them from paying
        // out every pixel travelled meanwhile as one burst from a stale
        // `_lastMs`. `_sparkRate()` already returns 0 while they are off, so
        // nothing is emitted either way.
        if (rail.width <= 0) return;
        const now = Date.now();
        const px = rail._pBallX;
        const py = rail._pBallY;

        if (!rail._seeded || rail._grace) {
            rail._seeded = true;
            rail._lastX = px; rail._lastY = py; rail._lastMs = now;
            return;
        }

        const dt = Math.max(1, now - rail._lastMs);
        const dx = px - rail._lastX;
        const dy = py - rail._lastY;
        const dist = Math.sqrt(dx * dx + dy * dy);
        rail._lastX = px; rail._lastY = py; rail._lastMs = now;
        if (dist <= 0) return;

        // A SAMPLE FASTER THAN ANY REAL GESTURE IS A RE-SEAT, NOT A MOVE.
        //
        // `dt` is a whole millisecond at best, so two samples in the same event
        // turn measure a rail's width in 1 ms -- half a million pixels a second,
        // where the fastest thing a hand does on this rail is a few thousand.
        // Billed as motion it would buy two dozen sparks and throw them at
        // twenty times a scrub's speed, as a full-rail return would look. The
        // anchor has already been moved above, so letting this one go
        // costs nothing: the next sample measures from where the ball now is.
        if (rail.speedCeiling > 0 && dist / dt > rail.speedCeiling)
            return;

        const speed = dist / dt;                       // px/ms
        const stretch = Math.min(1, speed / Math.max(0.001, rail.ballStretchSpeedRef));
        // Snapped to zero under the floor -- see `_stretchFloor`. A real fling,
        // a drag and a click-to-seek travel are all orders of magnitude above
        // it and reach full stretch.
        rail._stretchF = stretch > rail._stretchFloor ? stretch : 0;

        const rate = rail._sparkRate();
        if (rate <= 0) { rail._travelAccum = 0; return; }

        // The whole law, in three lines: buy sparks with distance, spend
        // whole ones, CARRY THE REMAINDER. A thousand one-pixel steps and one
        // thousand-pixel step therefore cost the same.
        rail._travelAccum += dist * rate;
        let n = Math.floor(rail._travelAccum);
        if (n <= 0) return;
        rail._travelAccum -= n;
        if (n > rail.sparkMaxPerSample) n = rail.sparkMaxPerSample;
        // The ball's own speed still shapes how hard a spark is thrown; it
        // just does not decide how many there are.
        rail._emitSparks((-dx / dt) * 1000, (-dy / dt) * 1000, n, 1);
    }

    on_BallPosChanged: rail._sampleBall()

    // ======================================================================
    //  THE MUSIC'S EMISSION
    //
    //  Everything below is gated on ONE function, so the timer, the rate and
    //  the beat cannot disagree about whether the music may spark at all.
    // ======================================================================
    function _musicGate() {
        return rail.particlesEnabled && rail.sparksEnabled && rail.musicSparksEnabled
            && rail.playing && rail._showF > 0.01;
    }

    // Sparks per SECOND, the baseline plus what the loudness buys.
    function _musicRate() {
        if (!rail._musicGate()) return 0;
        const loud = Math.max(0, Math.min(1, rail.loudness));
        const base = Math.max(0, rail.musicSparkPerSec);
        const peak = Math.max(base, rail.musicPeakSparkPerSec);
        return base + (peak - base) * Math.pow(loud, Math.max(0.01, rail.musicRateGamma));
    }

    // How many sparks are alive. The pool's own count, which is what a
    // ceiling has to be measured against and what a probe needs to prove one.
    function liveSparkCount() {
        return particles._system ? particles._system.getActiveParticles().length : 0;
    }

    // The ceiling lives here, in the one place every music spark passes
    // through: the room left under `musicMaxInAir`, never a second cap.
    function _emitMusic(n, velScale) {
        const room = Math.min(rail.musicMaxInAir - rail.liveSparkCount(), rail.sparkMaxPerSample);
        if (room <= 0) return;
        rail._emitSparks(0, 0, Math.min(n, room), velScale);
    }

    property real _musicAccum: 0
    property real _musicLastMs: 0

    Timer {
        id: musicClock
        interval: Math.max(16, rail.musicSampleMs)
        repeat: true
        // Not gated on `loudness`, which changes 15 times a second: the gate
        // is the things that decide whether there is music to spark for at
        // all, and the rate is read on the tick.
        running: rail.visible && rail.particlesEnabled && rail.sparksEnabled
                 && rail.musicSparksEnabled && rail.playing && rail._showF > 0.01
                 && !Theme.crossfading
        onRunningChanged: if (!musicClock.running) {
            rail._musicLastMs = 0;
            rail._musicAccum = 0;
        }
        onTriggered: {
            const now = Date.now();
            const dt = rail._musicLastMs === 0
                     ? musicClock.interval
                     : Math.max(1, Math.min(500, now - rail._musicLastMs));
            rail._musicLastMs = now;
            const rate = rail._musicRate();
            if (rate <= 0) { rail._musicAccum = 0; return; }
            // The same law the travel budget is paid by: buy with the clock,
            // spend whole sparks, CARRY THE REMAINDER -- so a rate under one
            // a second is a spark every few ticks rather than nothing at all.
            rail._musicAccum += rate * dt / 1000;
            const n = Math.floor(rail._musicAccum);
            if (n <= 0) return;
            rail._musicAccum -= n;
            rail._emitMusic(n, 1 + rail.musicSpeedGain * Math.max(0, Math.min(1, rail.loudness)));
        }
    }

    // The beat itself: a burst, at once, thrown faster the harder it landed.
    // It does not go through the clock -- a beat that waited for the next
    // tick would be up to `musicSampleMs` late, which is exactly the lag the
    // eye reads as "not with the music".
    onBeatSeqChanged: {
        if (!rail._musicGate()) return;
        const s = Math.max(0, Math.min(1, rail.beatStrength));
        const n = Math.round(rail.musicBeatSparks * (0.35 + 0.65 * s));
        if (n <= 0) return;
        rail._emitMusic(n, 1 + rail.beatSpeedGain * s);
    }

    // ---- Layout moves are not movement -----------------------------------
    //
    // The popup resizes between its view modes, so the track's geometry
    // changes and the ball lands on a different PIXEL while sitting at the
    // same place along the rail. Left alone the spark cloud is stranded and
    // then chases the ball across the new layout — an event the user did not
    // cause. The whole cloud is shifted by the same delta instead, computed
    // for the SAME position under old and new geometry, so a ball that also
    // travelled during the switch still reads as having travelled.
    property real _prevTrackStart: 0
    property real _prevTrackSpan: 0
    property real _prevLineY: 0
    property bool _haveTrackGeom: false

    function _absorbLayoutShift() {
        const ts = groove.trackStart;
        const sp = groove.trackSpan;
        const cy = rail._lineY;
        if (!rail._haveTrackGeom) {
            rail._prevTrackStart = ts; rail._prevTrackSpan = sp;
            rail._prevLineY = cy; rail._haveTrackGeom = true;
            return;
        }
        if (ts === rail._prevTrackStart && sp === rail._prevTrackSpan
            && cy === rail._prevLineY) return;

        const t = Math.max(0, Math.min(1, rail._ballPos));
        const dx = (ts + sp * t) - (rail._prevTrackStart + rail._prevTrackSpan * t);
        const dy = cy - rail._prevLineY;

        rail._prevTrackStart = ts; rail._prevTrackSpan = sp; rail._prevLineY = cy;

        if (dx === 0 && dy === 0) return;
        particles.translateAll(dx, dy);
        // Cloud and ball moved together: this must not be read as motion.
        rail._lastX += dx;
        rail._lastY += dy;
    }

    // Watches the GROOVE's settled geometry, not the rail's width:
    // `onWidthChanged` fires before the groove has re-laid out, so reading
    // its track there returns the old numbers and the shift is never seen.
    readonly property real trackGeomKey:
        groove.trackStart + groove.trackSpan * 4096 + rail._lineY * 16
    onTrackGeomKeyChanged: { rail._absorbLayoutShift(); rail._sampleBall(); }

    // ======================================================================
    //  BALL
    // ======================================================================
    SquishItem {
        id: ball
        anchors.fill: parent
        z: 5

        usePath: true
        // In PIXELS along the track, not 0..1: SquishItem samples
        // `pathFunc(trackPos ± halfWidth)` in pixels to build the contour,
        // and a 0..1 position clamps every sample to the track's ends.
        //
        // `rail._ballX`, not a second `groove.xAt(rail._ballPos)`: the sparks
        // spawn at `_ballX` too, and the spawn point and the ball must be in
        // the same place. Two copies of one
        // expression are two things that can be evaluated against different
        // geometry; one property cannot.
        trackPos: rail._ballX
        pathFunc: function (px) {
            return {x: px, y: rail._lineY, angle: 0};
        }
        overrideWidth: rail._drawW
        overrideHeight: rail._drawH

        color: rail.ballColor
        shadowColor: rail.ballShadowColor
        shadowOpacity: rail.ballShadowOpacity
        // The blur scales with the ball. A fixed 12 px blur around a pill
        // shrinking to nothing leaves a soft grey smudge behind on the groove
        // for the last few frames -- the shadow of a ball that is no longer
        // there.
        shadowBlur: rail.ballShadowBlur * rail._showF
    }

    // ======================================================================
    //  INPUT
    //
    //  One MouseArea over the whole rail, the way GrooveSlider does it, so
    //  the ball, the groove and the space around them are one target. A press
    //  commits to nothing: it becomes a DRAG past `dragDeadzone` (the ball
    //  jumps to the pointer and follows it), and a CLICK otherwise (the ball
    //  travels to the point, animated, and one seek is asked for).
    // ======================================================================
    function _fracFromX(mx) {
        const sp = groove.trackSpan;
        if (sp <= 0) return 0;
        return Math.max(0, Math.min(1, (mx - groove.trackStart) / sp));
    }

    function _onPress(mx) {
        rail._pressed = true;
        rail._pressX = mx;
    }

    function _onMove(mx) {
        if (!rail._pressed) return;
        if (!rail._dragging) {
            if (Math.abs(mx - rail._pressX) < rail.dragDeadzone) return;
            // The gesture is a scrub: the ball is the finger's from here on.
            // `_dragging` is raised BEFORE the in-flight seek is abandoned, so
            // the target never passes through the daemon's position on its way
            // to the pointer and the ball never twitches toward it.
            rail._dragFrac = rail._fracFromX(mx);
            rail._dragging = true;
            rail._clearPending();
        } else {
            rail._dragFrac = rail._fracFromX(mx);
        }
        rail.scrubbing(rail._dragFrac * rail.duration);
    }

    // Ends the gesture and asks for exactly one seek — at the pointer for a
    // drag, at the press point for a click. `_pendingSec` is set BEFORE
    // `_dragging` is cleared, so the target moves once, not twice.
    function _commit(mx) {
        if (!rail._pressed) return;
        const wasDrag = rail._dragging;
        const frac = rail._fracFromX(wasDrag ? mx : rail._pressX);
        const sec = frac * rail.duration;
        rail._pressed = false;
        // The latch is armed BEFORE the drag is released, so the target moves
        // once and not twice: clearing `_dragging` first would put the
        // daemon's stale position in the target for one evaluation and start
        // a travel back toward it.
        rail._requestSeek(sec);
        rail._dragging = false;
        rail.seekRequested(sec);
    }

    // A grab taken away from us (the popup closing under the pointer, a
    // gesture handler upstream claiming the press). A scrub that already
    // happened is committed — snapping the ball back to a place the user had
    // left would be a lie — but a press that never became one asks for
    // nothing: the user pressed and the window took it away, which is not a
    // seek.
    function _cancel() {
        if (!rail._dragging) { rail._pressed = false; return; }
        rail._commit(groove.trackStart + rail._dragFrac * groove.trackSpan);
    }

    MouseArea {
        id: input
        anchors.fill: parent
        z: 10
        enabled: rail.seekable && rail.duration > 0
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: input.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor

        onPressed: mouse => rail._onPress(mouse.x)
        onPositionChanged: mouse => { if (input.pressed) rail._onMove(mouse.x); }
        onReleased: mouse => rail._commit(mouse.x)
        onCanceled: rail._cancel()
    }
}
