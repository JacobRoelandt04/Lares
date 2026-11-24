pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import "../particles"
import "../scroll"

// ===========================================================================
// GrooveSlider.qml
//
// Generic value slider with kinetic ball + perpendicular-drag mute mechanic.
// Used by audio (volume) and brightness modules. No service bindings — caller
// drives `value`/`muted`/`allowBoost` and listens for user* signals.
//
// ARCHITECTURE
// ------------
// The bar is a CHANNEL with two parallel edges, not a thin rod. Bar thickness
// must be >= ball diameter (auto-clamped). Ball nests INSIDE the channel with
// small clearance.
//
// Two bars are rendered: the "active" bar (containing the ball, fat) and the
// "inactive" bar (the mute indicator when not muted, or the main indicator
// when muted — thin). Their thicknesses swap with animation when `muted`
// flips.
//
// MUTE DRAG
// ---------
// On press inside the slider:
//   * After a small axis-decision deadzone (6 px), drag locks to "volume"
//     (along-axis dominant) or "mute" (cross-axis dominant). Lock affects
//     the snap threshold only — perpendicular movement still bends the bar
//     in either mode (no flat axis-lock).
//   * Cursor cross offset relative to the bar at press time, after subtracting
//     `crossOffsetDeadzone`, drives THREE quantities each frame:
//        - bend amount of the active bar at ball position (Gaussian profile)
//        - ball cross offset (1:1 with cursor — no lag)
//        - ball squish depth on the side facing the destination
//     Split: `ballSquishStrength` portion of drag becomes squish; the
//     remainder becomes bar bend.
//   * Edge influence: only the edge facing the destination bulges fully.
//     The far edge bulges by `edgeInfluence` × bend (default 0.15).
//   * Snap fires when the cursor's penetration into the bar (the drag less
//     the ball's clearance in the channel) reaches the track separation less
//     that clearance:
//        - "mute" mode → at that threshold
//        - "volume" mode → at 1.3 x that (an along-axis drag has to go further
//          to break through)
//   * After a snap, cursor's CURRENT position becomes the new origin so the
//     user can keep dragging in the same hold to re-snap.
//
// SNAP RECOVERY
// -------------
// Spring-animated `_bendDistance`, `_ballCrossOffset`, `_squishDepth` settle
// back to 0 with bouncy damping. The ball's SquishItem-derived velocity squish
// + angular-momentum tail naturally produce the jiggle/ripple recovery.
//
// MUTE OPT-OUT (`muteEnabled: false`)
// ----------------------------------
// A slider that has nothing to mute -- a settings slider in a menu -- opts out
// of the whole mechanic: no mute track is painted, no snap zone or
// breakthrough exists, no thickness swap runs, `muted` stops meaning anything,
// and the ball's cross-axis travel is soft-limited SYMMETRICALLY (the same
// asymptote the outer-edge drag already used) instead of running on toward a
// second axis. What is left is the material: the ball bends the one bar,
// squishes against it, and springs back. `neededCross` (and so the implicit
// size) shrinks to that travel, so a host can ask the slider how much room it
// needs rather than guessing.
//
// AND THE SAME ALONG THE LINE. The bar's end is a capsule whose
// radius is the LOCAL half-thickness, and the ball bends the bar deepest
// exactly where it stands -- so a ball held at one end of the groove opens
// that end cap to (scFat + bend)/2, well past `edgePadding`, and the Canvas
// (which paints into a texture of its own size, unlike an Item) cuts what
// runs off: a flat-ended bar and a half-ball, as in the pdf menu.
// `neededEndPad` is the room that ink actually needs beyond
// each end of the groove; with the mute mechanic OFF the groove is inset by
// at least that much, so the extremes stay inside the width the host gave.
// It is DEFAULT-INERT: with `muteEnabled` true (the audio slider) the inset
// is `edgePadding` alone, to the pixel.
//
// VERTICAL ORIENTATION
// --------------------
// Inner canvas is rotated 90° for vertical. The MouseArea lives INSIDE the
// rotated canvas, so all mouse coords (and all math here) are in the
// horizontal frame: `mx` = along-axis, `my` = cross-axis.
// ===========================================================================
Item {
    id: root

    // Device px per design px here (the nearest ScaleRoot's, else the window's).
    DeviceScale {
        id: dev
    }

    // ======================================================================
    // PUBLIC API — sizes
    // ======================================================================
    property string orientation: "horizontal"      // "horizontal" | "vertical"
    property real sizeScale: 1.5
    // Device px per design px: the groove's canvas is made at that many times its size (ScaledCanvas). Found by default (the nearest
    // ScaleRoot's); a host that knows better hands one.
    property real renderScale: dev.value

    // Bar thickness (active bar = `barFatThickness`; inactive = `barThinThickness`).
    // The fat one must contain the ball, so it's auto-clamped to >= ballSize.
    property real barFatThickness: 0               // 0 → ballSize * fatRatio
    property real barFatRatio: 1.4                 // applied when barFatThickness == 0
    property real barThinThickness: 4              // visual indicator only when inactive

    property real ballSize: 14
    property real edgePadding: 18
    property real trackSeparation: 0               // 0 → auto from bar thicknesses

    // Mute-bar position relative to main:
    //   horizontal → "below" | "above"
    //   vertical   → "right" | "left"
    property string muteSide: orientation === "horizontal" ? "below" : "right"
    readonly property int _muteSign: {
        if (orientation === "horizontal") return muteSide === "above" ? -1 : 1;
        return muteSide === "left" ? -1 : 1;
    }

    // ======================================================================
    // PUBLIC API — value + state
    // ======================================================================
    property real value: 0.5                       // 0..maxValue (clamped)
    property bool muted: false
    // False: no mute at all (see the header). Default true -- the audio and
    // brightness sliders keep the mechanic.
    property bool muteEnabled: true
    // `muted` only means something while the mechanic exists; everything
    // geometric reads THIS, so a host that leaves `muted` true with the
    // mechanic off still gets one plain bar.
    readonly property bool _muteActive: muteEnabled && muted
    property bool allowBoost: false
    property real boostMaxValue: 1.5
    property real maxValue: 1.0                    // animated by spring

    // ======================================================================
    // PUBLIC API — animation tuning
    // ======================================================================
    property int barThicknessSwapDuration: 600     // fat ↔ thin swap on mute
    // How much of the groove the slope of a swelling bar spreads over (a fraction of its length): the thickening is a
    // swell with a long soft front, not a step that sweeps along. See BAR THICKNESS.
    property real barWavefrontSpan: 0.35
    property real boostSpringStiffness: 2.4
    property real boostSpringDamping: 0.18
    property real recoverySpringStiffness: 3.2
    property real recoverySpringDamping: 0.20

    // ======================================================================
    // PUBLIC API — drag tuning
    // ======================================================================
    property real axisDecisionDeadzone: 6          // px before axis lock
    property real crossOffsetDeadzone: 4           // px before bend/squish kicks in
    property real edgeInfluence: 0.15              // 0..1, far edge follow factor
    property real ballSquishStrength: 0.65         // 0..1 fraction of drag → squish
    property real bendSigmaScale: 0.12             // sigma fraction of lineLength
    property real bendSigmaMin: 1.4                // floor: ballSize * this (then * sizeScale)
    property real unmuteBendSigmaMultiplier: 1.6   // wider sigma during unmute snap

    // ======================================================================
    // PUBLIC API — colors (light palette default)
    // ======================================================================
    property color surfaceColor: "#EAEDF5"
    property color grooveColor: "#E1E4EB"
    property color grooveBevelColor: "#EEF0F7"
    property color grooveShadowColor: "#CED1D7"
    property color ballColor: "#4480F4"
    property color ballMutedColor: "#AAADB4"
    property color muteBarColor: "#CED1D7"
    property color muteBarBevelColor: "#EEF0F7"
    property color muteBarShadowColor: "#AAADB4"

    property real grooveShadowWidth: 3
    property real grooveBevelWidth: 0.5            // small bevel — minimises visible gap between ball flat and bar outer edge

    property color ballShadowColor: ballColor
    property color ballMutedShadowColor: "#7A7B80"
    property real ballShadowOpacity: 0.55
    property real ballShadowBlur: 14

    // ======================================================================
    // PUBLIC API — particle defaults
    // ======================================================================
    property bool sparksEnabled: true
    property real sparksSpeedThreshold: 0.7
    property real sparksAmountMultiplier: 0.8
    property real sparksBaseVelocity: 0.06
    property real sparksScatter: 50
    property real sparksLifetimeBase: 350
    property real sparksLifetimeVariance: 500
    property int sparksMaxHistory: 5
    property real sparksSizeStart: 1.8
    property real sparksSizeEnd: 0.6
    property color sparksColorStart: ballColor
    property color sparksColorEnd: "transparent"
    property real sparksDrag: 2.6
    property real sparksSwirlStr: 0.4
    property real sparksSwirlProb: 0.4
    property real sparksBloomBlur: 18.0
    property real sparksBloomStrength: 0.25
    property real sparksBloomBrightness: 0.85

    property int muteBurstCount: 14
    property real muteBurstSpeed: 230
    property real muteBurstLifetime: 600
    property color muteBurstColor: "#FFFFFF"
    property color unmuteBurstColorStart: "#FFFFFF"
    property color unmuteBurstColorEnd: ballColor

    property int fidgetCount: 10
    property real fidgetSpeed: 130
    property real fidgetLifetime: 520
    property real fidgetBallShrink: 0.85
    property int fidgetShrinkDuration: 220

    // ======================================================================
    // SIGNALS
    // ======================================================================
    signal userChangedValue(real newValue)
    signal userToggledMute()
    signal userToggledBoost()

    // ======================================================================
    // SCALED INTERNALS
    // ======================================================================
    readonly property real _autoFatThickness: ballSize * barFatRatio
    readonly property real _effFat:
        Math.max(barFatThickness > 0 ? barFatThickness : _autoFatThickness, ballSize)
    readonly property real _effThin:
        Math.max(0.5, barThinThickness)            // can be smaller than ball — purely indicator
    readonly property real _autoTrackSep:
        (_effFat + _effThin) * 0.5 + 14            // gap so bars don't overlap + bend room
    readonly property real _effTrackSep:
        Math.max(trackSeparation > 0 ? trackSeparation : _autoTrackSep,
                 (_effFat + _effThin) * 0.5 + 2)

    readonly property real scFat: _effFat * sizeScale
    readonly property real scThin: _effThin * sizeScale
    readonly property real scBall: ballSize * sizeScale
    readonly property real scPad: edgePadding * sizeScale
    readonly property real scTrackSep: _effTrackSep * sizeScale
    readonly property real scDeadzoneCross: crossOffsetDeadzone * sizeScale
    readonly property real scAxisDeadzone: axisDecisionDeadzone * sizeScale
    readonly property real scBallShadowBlur: ballShadowBlur

    readonly property bool isHorizontal: orientation === "horizontal"
    readonly property real lineLength: isHorizontal ? width : height
    readonly property real lineCross: isHorizontal ? height : width
    readonly property real lineCenter: lineCross / 2

    // ---- ROOM ALONG THE LINE ----------------------------------------------
    // The bar's cap at one end is a half-circle of the channel's LOCAL
    // half-thickness there, and the channel is at its thickest where the ball
    // stands: near edge pushed out by `bend`, far edge pulled by
    // `bend * edgeInfluence`, so the opening is scFat + bend*(1-edgeInfluence).
    // The deepest bend the ball can reach is the cross-travel limit, so the
    // widest cap the slider can ever draw is half of that -- plus the bevel,
    // which is painted OUTSIDE the channel.
    readonly property real _endCapMax:
        (scFat + _crossTravelLimit * (1 - edgeInfluence)) * 0.5
        + grooveBevelWidth * sizeScale
    // The ball at that same end, at its widest: SquishItem's velocity squish
    // elongates it by up to `maxSquishRatio` (0.5 on this ball), so 1.5 x the
    // radius is the bound on its half-extent along the line.
    readonly property real _ballHalfMax: scBall * 0.5 * 1.5
    // What the two of them need beyond each end of the groove. A host that
    // wants the FULL travel can add this as a margin instead; the slider
    // itself only guarantees nothing is cut inside the width it was given.
    readonly property real neededEndPad: Math.max(_endCapMax, _ballHalfMax)
    // Default-inert: only a slider with the mute mechanic off insets past
    // `edgePadding`, so the audio slider's geometry is unchanged.
    readonly property real _effEndPad:
        muteEnabled ? scPad : Math.max(scPad, neededEndPad)
    readonly property real grooveStart: _effEndPad
    readonly property real grooveEnd: lineLength - _effEndPad
    readonly property real grooveSpan: Math.max(1, grooveEnd - grooveStart)

    readonly property real _normProgress:
        Math.max(0, Math.min(1, value / Math.max(0.001, maxValue)))
    readonly property real ballAlong: grooveStart + grooveSpan * _normProgress

    // The soft asymptote on cross-axis drag: the ball approaches it and never
    // reaches it, so it is a true bound on how far the ball can travel off the
    // line. ONE source: `_onMove` compresses against this and `neededCross`
    // sizes against it.
    readonly property real _crossTravelLimit: scFat * 0.5 + scBall * 0.4
    // How much room the slider needs ACROSS the line so nothing it draws is
    // clipped: both bars and the space between them while the mute mechanic
    // exists, otherwise the one bar plus the ball at its bent extreme.
    // `scBall * 0.5` is only the ball's RESTING radius, and a fast drag
    // elongates it -- measured: a 4 px/step pull to the cross limit puts ink
    // 8.8 px above the row and into the title over it. `_ballHalfMax` is the
    // squished half-extent, the same bound the along-axis pad uses.
    readonly property real neededCross: muteEnabled
        ? scFat + scTrackSep + scThin + 16
        : 2 * (_crossTravelLimit + _ballHalfMax) + 8

    implicitWidth: isHorizontal ? 320 : neededCross
    implicitHeight: isHorizontal ? neededCross : 320

    // ======================================================================
    // BAR THICKNESS — a swell that spreads from the ball
    //
    // Each bar carries three numbers: `fat` (how thick its swollen part is:
    // scFat for the active bar, scThin for the other), `grow` (0..1: how far
    // the swell has spread) and `ctr` (where it began, as a FRACTION of the
    // groove's length).
    //
    //   thickness(x) = fat + (thin − fat) · smoothstep(clamp((d − start) / ramp, 0, 1))
    //     d      the distance from where the swell began
    //     reach  the groove's FARTHEST end from there, read from the groove as it is NOW
    //     core   0.7 of a ball: the ball stands in the full channel from the first frame
    //     start  core + (reach − core) · grow     where the full channel ends
    //     ramp   barWavefrontSpan of the groove's length (never less than a ball): the
    //            slope from the full channel down to the thin one
    //
    // Transitions:
    //   inactive → active ("grow"): fat = scFat at once, ctr = the ball, grow
    //     runs 0 → 1 over barThicknessSwapDuration (an in-out ease). The full
    //     channel spreads from the ball behind a long soft front; at grow = 1
    //     `start` is the groove's far end, so every point is full.
    //   active → inactive ("shrink"): fat eases scFat → scThin while grow
    //     stays 1: the whole bar thins uniformly.
    //
    // WHY IT IS A FRACTION OF THE GROOVE AND NOT A DISTANCE. A swell that is a radius in
    // pixels, animated to `lineLength * 1.2` as it is at the moment of the mute, breaks
    // when the groove grows afterwards -- the OSD's content is laid out at the popup's
    // animated box while it opens, so a mute inside the opening sees a short groove: the
    // swell is full for 1.2 of the short length and THIN BEYOND IT, for good (a thickened
    // groove that terminates in a thin end). `reach` is asked of the geometry on
    // every evaluation, so a groove that grows while the swell runs, or after it, is full
    // end to end; and the front is a slope as long as a third of the groove (a smoothstep
    // 0.6 of a ball wide, 7 px, would be a step that sweeps the groove).
    // ======================================================================
    property real _mainFat: scFat
    property real _mainGrow: 1                        // initially fully fat
    property real _mainCtr: 0.5
    property real _muteFat: scThin
    property real _muteGrow: 0
    property real _muteCtr: 0.5

    NumberAnimation {
        id: mainShrinkAnim
        target: root
        property: "_mainFat"
        duration: root.barThicknessSwapDuration
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: mainGrowAnim
        target: root
        property: "_mainGrow"
        from: 0
        to: 1
        duration: root.barThicknessSwapDuration
        easing.type: Easing.InOutSine
    }
    NumberAnimation {
        id: muteShrinkAnim
        target: root
        property: "_muteFat"
        duration: root.barThicknessSwapDuration
        easing.type: Easing.OutCubic
    }
    NumberAnimation {
        id: muteGrowAnim
        target: root
        property: "_muteGrow"
        from: 0
        to: 1
        duration: root.barThicknessSwapDuration
        easing.type: Easing.InOutSine
    }

    function _barThicknessAtX(x, fat, grow, ctrFrac) {
        if (fat <= scThin)
            return scThin;                          // not swollen: nothing to spread
        const ctr = ctrFrac * lineLength;
        const reach = Math.max(ctr - grooveStart, grooveEnd - ctr, 0);
        const core = scBall * 0.7;
        const ramp = Math.max(scBall, lineLength * barWavefrontSpan);
        const start = core + (Math.max(reach, core) - core) * grow;
        const u = Math.max(0, Math.min(1, (Math.abs(x - ctr) - start) / ramp));
        if (u <= 0)
            return fat;                             // inside the full channel: exactly `fat`, as at rest it always was
        return fat + (scThin - fat) * (u * u * (3 - 2 * u));
    }
    function _mainThicknessAtX(x) {
        return _barThicknessAtX(x, _mainFat, _mainGrow, _mainCtr);
    }
    function _muteThicknessAtX(x) {
        return _barThicknessAtX(x, _muteFat, _muteGrow, _muteCtr);
    }
    function _activeThicknessAtX(x) {
        return _muteActive ? _muteThicknessAtX(x) : _mainThicknessAtX(x);
    }
    // Where the ball is along the groove, as a fraction of its length: where a swell begins.
    function _ballFraction() {
        return lineLength > 0 ? ballAlong / lineLength : 0.5;
    }

    // ======================================================================
    // BEND / SNAP RUNTIME STATE (signed in canvas-y for ballCrossOffset;
    // unsigned magnitudes for bendDistance + squishDepth)
    // ======================================================================
    readonly property int _bendSign: _muteActive ? -_muteSign : _muteSign
    readonly property real _activeBarCenterY:
        _muteActive ? lineCenter + _muteSign * scTrackSep : lineCenter
    readonly property real _activeHalfThickness:
        _activeThicknessAtX(ballAlong) * 0.5

    // Live drag values — written imperatively from `_onMove`. Spring-animated
    // back to 0 by the relax animations on release / snap.
    //
    // Foil-coupling model:
    //
    //   rawPen = cursor's would-be overlap into bar at rest (= effDrag - clearance)
    //   _fb    = ball-flatten depth via saturating formula
    //              f_b = P²/(P + R·(1−r)/r), capped at ballR·0.98
    //   _bendDistance = rawPen − _fb (the residual; the bar gives way)
    //   _contactHalfWidth = chord half-width on the ball at flatten depth _fb
    //
    // Both the bar's near edge AND the SquishItem wallFunc are derived from
    // the SAME geometry — guarantees zero gap, volume-preserving lateral
    // bulge handled by SquishItem's built-in contour math.
    property real _bendDistance: 0     // unsigned, bar bend amount at ball position
    property real _ballCrossOffset: 0  // signed canvas-y, ball offset from active bar centerline
    property real _fb: 0               // unsigned, ball flatten depth (foil's f_b)

    // Contact chord half-width on the ball, in canvas-x units. Outside this
    // tangent range the bar releases its grip on the ball and curves smoothly
    // back to rest via Gaussian falloff.
    readonly property real _contactHalfWidth: {
        if (_fb <= 0.05) return 0;
        let R = scBall * 0.5;
        return Math.sqrt(Math.max(0, 2 * R * _fb - _fb * _fb));
    }

    // Catch-rebound state — used during snap recovery. Mirror of the
    // pre-snap drag mechanic but applied
    // to the FAR edge of the new active bar:
    //   _catchBend bulges the FAR edge in -bendSign direction
    //   _catchFb flattens the ball on its FAR side (-bendSign direction)
    // Animated by `catchSeqAnim` in onMutedChanged.
    property real _catchBend: 0
    property real _catchFb: 0
    readonly property real _catchHalfWidth: {
        if (_catchFb <= 0.05) return 0;
        let R = scBall * 0.5;
        return Math.sqrt(Math.max(0, 2 * R * _catchFb - _catchFb * _catchFb));
    }

    // Sigma multiplier briefly raised during unmute snap.
    property real _bendSigmaMultiplier: 1.0

    // Effective bend Gaussian sigma at this frame.
    readonly property real _bendSigma:
        Math.max(bendSigmaMin * sizeScale * ballSize / 14,
                 lineLength * bendSigmaScale) * _bendSigmaMultiplier

    // ======================================================================
    // DRAG STATE MACHINE
    // ======================================================================
    property string _dragMode: "idle"   // "idle" | "pressing" | "volume" | "mute"
    property real _pressX: 0
    property real _pressY: 0
    property real _crossOriginY: 0      // current cross-axis origin (resets on snap)
    property bool _pressOnBall: false

    // Cached pre-snap ball cross position so we can render visual continuity
    // across the muted flip.
    property real _preSnapBallCanvasY: 0

    // Set true once the component has stable geometry (lineLength > 0). Until
    // then, onMutedChanged early-returns so the snap animation doesn't fire
    // with bogus lineLength=0 leaving the bar stuck thin around bumpCenter.
    property bool _initialized: false

    // Diagnostic logging — enable per-instance via `debugLog: true` to dump
    // drag math + collision state every 100 ms during a press.
    property bool debugLog: false
    property real _lastDebugT: 0

    // Velocity-derived ball squish (SquishItem internal) is always on, so
    // the ball wobbles during slide / radial inertia. Kept as a property so it
    // can be toggled.
    property bool _squishVelEnabled: true

    // ======================================================================
    // RELAX ANIMATIONS (used on release without snap, and on snap recovery)
    // ======================================================================
    SpringAnimation {
        id: bendRelaxAnim
        target: root
        property: "_bendDistance"
        to: 0
        spring: root.recoverySpringStiffness
        damping: root.recoverySpringDamping
        mass: 1.0
        epsilon: 0.05
    }
    SpringAnimation {
        id: ballOffsetRelaxAnim
        target: root
        property: "_ballCrossOffset"
        to: 0
        spring: root.recoverySpringStiffness
        damping: root.recoverySpringDamping
        mass: 1.0
        epsilon: 0.05
    }
    SpringAnimation {
        id: fbRelaxAnim
        target: root
        property: "_fb"
        to: 0
        spring: 4.0
        damping: 0.28
        mass: 1.0
        epsilon: 0.05
    }
    NumberAnimation {
        id: sigmaSettleAnim
        target: root
        property: "_bendSigmaMultiplier"
        to: 1.0
        duration: 600
        easing.type: Easing.OutQuart
    }
    SpringAnimation {
        id: catchBendRelaxAnim
        target: root
        property: "_catchBend"
        to: 0
        spring: root.recoverySpringStiffness
        damping: root.recoverySpringDamping
        mass: 1.0
        epsilon: 0.05
    }
    SpringAnimation {
        id: catchFbRelaxAnim
        target: root
        property: "_catchFb"
        to: 0
        spring: 4.0
        damping: 0.28
        mass: 1.0
        epsilon: 0.05
    }

    // ======================================================================
    // CATCH REBOUND ANIMATION.
    //
    // After snap fires:
    //   Phase 1 (instant) — ball appears at near-side INSIDE the new bar
    //                        (the side it arrived through). bend/fb cleared.
    //   Phase 2 (fast)    — ball traverses to far-side inside; catchBend +
    //                        catchFb grow with InQuad easing so they peak at
    //                        the impact moment.
    //   Phase 3 (springy) — everything (ball offset, catchBend, catchFb)
    //                        eases back to 0 with bouncy OutBack overshoot.
    // ======================================================================
    SequentialAnimation {
        id: catchSeqAnim
        // Phase 2 — traverse from near-side inside the new bar to the far
        // inside (impact point). Bend + flatten ramp up to peak at impact.
        ParallelAnimation {
            id: catchPhase2
            NumberAnimation {
                id: catchBallTraversalAnim
                target: root
                property: "_ballCrossOffset"
                duration: 110
                easing.type: Easing.OutQuad
            }
            NumberAnimation {
                id: catchBendImpactAnim
                target: root
                property: "_catchBend"
                duration: 110
                easing.type: Easing.InQuad
            }
            NumberAnimation {
                id: catchFbImpactAnim
                target: root
                property: "_catchFb"
                duration: 110
                easing.type: Easing.InQuad
            }
        }
        // Phase 2b — ball continues past the bar's outer edge into "nothing"
        // (rebound momentum). Bend + flatten relax to 0 since ball is no
        // longer in contact with the bar.
        ParallelAnimation {
            id: catchPhase2b
            NumberAnimation {
                id: catchBallOvershootAnim
                target: root
                property: "_ballCrossOffset"
                duration: 130
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root
                property: "_catchBend"
                to: 0
                duration: 130
                easing.type: Easing.OutCubic
            }
            NumberAnimation {
                target: root
                property: "_catchFb"
                to: 0
                duration: 130
                easing.type: Easing.OutCubic
            }
        }
        // Phase 3 — ball spring-settles back to the new bar's center with
        // bouncy oscillation.
        ParallelAnimation {
            id: catchPhase3
            NumberAnimation {
                target: root
                property: "_ballCrossOffset"
                to: 0
                duration: 480
                easing.type: Easing.OutBack
                easing.overshoot: 1.5
            }
        }
    }

    // ======================================================================
    // BOOST RESCALE — spring-animated maxValue
    // ======================================================================
    Behavior on maxValue {
        SpringAnimation {
            spring: root.boostSpringStiffness
            damping: root.boostSpringDamping
            mass: 1.0
            epsilon: 0.001
        }
    }
    onAllowBoostChanged: maxValue = allowBoost ? boostMaxValue : 1.0

    // ======================================================================
    // INPUT HANDLING — coords are in canvas-frame (mx=along, my=across)
    // ======================================================================
    function _hitOnBall(mx, my) {
        let bx = ballAlong;
        let by = _activeBarCenterY + _ballCrossOffset;
        let dx = mx - bx, dy = my - by;
        let r = scBall / 2 + 4;
        return (dx * dx + dy * dy) <= r * r;
    }

    function _hitOnGroove(mx, my, centerY, halfT) {
        if (mx < grooveStart - 4 || mx > grooveEnd + 4) return false;
        return Math.abs(my - centerY) <= halfT + 3;
    }

    function _valueFromAlong(alongPos) {
        let raw = (alongPos - grooveStart) / grooveSpan;
        return Math.max(0, Math.min(1, raw)) * maxValue;
    }

    // ======================================================================
    // SHARED BAR-EDGE GEOMETRY
    //
    // Single source of truth used both by the bar Canvas painter AND by the
    // ball's SquishItem wallFunc. Returns canvas-y position of the active
    // bar's edge at along-axis position `absX`.
    //
    //   isNearEdge=true  → edge facing the destination (where the ball sits)
    //   isNearEdge=false → edge facing away
    //
    // Profile:
    //   * Inside contact region (|s| < contactHalfWidth): flat at the ball's
    //     contact line (= ballCenterY + bendSign·(ballR − f_b)).
    //   * Outside contact region: smooth Gaussian transition back to the bar's
    //     rest edge over distance `_bendSigma`.
    //   * Far edge has no contact region; it follows a pure Gaussian peak of
    //     bend × edgeInfluence at the ball position.
    //
    // The far edge contributes to the bar shape (volume swelling on the back
    // side) but doesn't directly contact the ball.
    // ======================================================================
    function _activeBarEdgeYAt(absX, isNearEdge) {
        let s = absX - ballAlong;
        let absS = Math.abs(s);
        let cy = _activeBarCenterY;
        // Position-dependent half-thickness so the bar widens as the
        // propagation wave reaches each x.
        let halfT = _activeThicknessAtX(absX) * 0.5;
        let dir = _bendSign;
        let R = scBall * 0.5;
        let bend = _bendDistance;
        let fb = _fb;
        let halfW = _contactHalfWidth;
        let catchBend = _catchBend;
        let catchHalfW = _catchHalfWidth;
        let sigma = Math.max(1, _bendSigma);
        let sigma2 = sigma * sigma;

        // FAR edge — Gaussian peak from regular bend (edgeInfluence weight)
        // PLUS catch bulge in -dir direction (flat at catch contact line,
        // Gaussian falloff outside).
        if (!isNearEdge) {
            let restY_far = cy - dir * halfT;
            let g_bend = bend > 0 ? Math.exp(-(s * s) / sigma2) : 0;
            let regular = restY_far + dir * bend * edgeInfluence * g_bend;
            if (catchBend <= 0.05) return regular;
            // Far edge under catch impact: flat at -dir·catchBend in contact
            // region, Gaussian outside.
            if (catchHalfW > 0.5 && absS < catchHalfW) {
                return regular - dir * catchBend;
            }
            let s_out_c = catchHalfW > 0.5 ? (absS - catchHalfW) : absS;
            let g_c = Math.exp(-(s_out_c * s_out_c) / sigma2);
            return regular - dir * catchBend * g_c;
        }

        // NEAR edge — flat at ball contact line, Gaussian outside.
        let restY = cy + dir * halfT;
        let contactY = restY + dir * bend;

        if (halfW > 0.5 && absS < halfW) {
            return contactY;
        }
        let s_out = halfW > 0.5 ? (absS - halfW) : absS;
        let g = bend > 0 ? Math.exp(-(s_out * s_out) / sigma2) : 0;
        return restY + dir * bend * g;
    }

    function _onPress(mx, my, button) {
        if (button === Qt.RightButton && _hitOnBall(mx, my)) {
            userToggledBoost();
            return;
        }
        if (muteEnabled && button === Qt.MiddleButton && _hitOnBall(mx, my)) {
            userToggledMute();
            return;
        }
        if (button !== Qt.LeftButton) return;

        // Click on the OTHER bar's centerline → toggle mute (quick-mute
        // affordance). There is no other bar without the mechanic.
        if (muteEnabled) {
            let otherCY = _muteActive ? lineCenter
                                      : lineCenter + _muteSign * scTrackSep;
            let otherHalfT = (_muteActive ? _mainThicknessAtX(mx)
                                          : _muteThicknessAtX(mx)) * 0.5;
            if (!_hitOnBall(mx, my)
                    && _hitOnGroove(mx, my, otherCY, otherHalfT)) {
                userToggledMute();
                return;
            }
        }

        // Begin drag.
        _dragMode = "pressing";
        _pressX = mx;
        _pressY = my;
        _crossOriginY = my;
        _pressOnBall = _hitOnBall(mx, my);

        bendRelaxAnim.stop();
        ballOffsetRelaxAnim.stop();
        fbRelaxAnim.stop();
        catchBendRelaxAnim.stop();
        catchFbRelaxAnim.stop();
        sigmaSettleAnim.stop();

        // Press on active bar (not on ball) → jump ball to position first.
        if (!_pressOnBall
                && _hitOnGroove(mx, my, _activeBarCenterY, _activeHalfThickness)) {
            let newValue = _valueFromAlong(mx);
            value = newValue;
            userChangedValue(newValue);
            _emitClickJumpBurst();
        }
    }

    function _onMove(mx, my) {
        if (_dragMode === "idle") return;

        let dAlong = mx - _pressX;
        let dAcross = my - _pressY;

        if (_dragMode === "pressing") {
            let dist2 = dAlong * dAlong + dAcross * dAcross;
            if (dist2 < scAxisDeadzone * scAxisDeadzone) return;
            _dragMode = (Math.abs(dAlong) >= Math.abs(dAcross))
                ? "volume" : "mute";
        }

        // Always update value from along position.
        let newValue = _valueFromAlong(mx);
        value = newValue;
        userChangedValue(newValue);

        // Signed cross-axis drag: positive = toward destination bar (where
        // mute/unmute snap will fire), negative = toward outer edge (no
        // functional effect, just visual freedom).
        let toward = (my - _crossOriginY) * _bendSign;
        let signedRaw = (Math.abs(toward) > scDeadzoneCross)
            ? (toward - Math.sign(toward) * scDeadzoneCross)
            : 0;

        // Soft asymptotic limit on outer-edge drag (signedRaw < 0).
        //   compressed = softLimit * (1 − exp(−|raw| / softLimit))
        // Behaves linearly for small drags (compressed ≈ raw) and
        // asymptotes toward `softLimit` for huge cursor distances. So the
        // ball can be pulled to the outer edge, but extra cursor travel
        // past that yields diminishing returns — never escapes off into
        // infinity.
        // With the mute mechanic OFF there is nothing to snap to, so the
        // TOWARD direction gets the same asymptote: the ball bends the bar to
        // a bounded extreme in both directions instead of running on forever.
        if (signedRaw < 0 || !root.muteEnabled) {
            let sign = signedRaw < 0 ? -1 : 1;
            let absRaw = Math.abs(signedRaw);
            let softLimit = root._crossTravelLimit;
            let compressed = softLimit * (1 - Math.exp(-absRaw / softLimit));
            signedRaw = sign * compressed;
        }
        let effDrag = Math.abs(signedRaw);

        // Don't fight a running relax animation if the user is barely moving
        // perpendicular — let the spring play out so the bounce doesn't get
        // killed by sub-threshold cursor jitter.
        let isRelaxing = ballOffsetRelaxAnim.running
                      || bendRelaxAnim.running
                      || fbRelaxAnim.running
                      || catchSeqAnim.running
                      || catchBendRelaxAnim.running
                      || catchFbRelaxAnim.running;
        if (isRelaxing && effDrag < scAxisDeadzone) {
            // Snap can still fire even during relax if the user pushes hard.
            return;
        }
        // Cursor drag takes priority — stop any running snap-recovery /
        // catch sequence so the ball follows the cursor immediately instead
        // of fighting two parallel animation sources.
        bendRelaxAnim.stop();
        ballOffsetRelaxAnim.stop();
        fbRelaxAnim.stop();
        catchBendRelaxAnim.stop();
        catchFbRelaxAnim.stop();
        catchSeqAnim.stop();

        // FOIL-STYLE COUPLING — no bend cap: the ball moves as far as the cursor pulls.
        //   rawPen = how far the ball would overlap the bar's rest near edge
        //            if the bar didn't bend. Ball nests inside fat channel
        //            with `clearance`, so rawPen only kicks in once the
        //            ball pushes past it.
        //   f_b    = ball-flatten depth via saturating formula, capped at
        //            ballR·0.98 so SquishItem's wallFunc skip never fires.
        //   bend   = rawPen − f_b. Grows freely so the ball can travel as far
        //            as the cursor pulls — accept that the bar may visually
        //            overlap the inactive bar's space at extreme drags.
        let ballR = scBall * 0.5;
        let clearance = scFat * 0.5 - ballR;        // >= 0 for fat bar
        let rawPen = Math.max(0, effDrag - clearance);
        let r = ballSquishStrength;                  // 0..1 split factor
        let fbRaw;
        if (r >= 0.999)        fbRaw = rawPen;
        else if (r <= 0.001)   fbRaw = 0;
        else                   fbRaw = (rawPen * rawPen) / (rawPen + ballR * (1 - r) / r);
        let fb = Math.min(fbRaw, ballR * 0.98);
        let bend = rawPen - fb;

        // Apply bend/flatten to the appropriate edge:
        //   signedRaw > 0 (toward destination) → near edge (_bendDistance/_fb)
        //   signedRaw < 0 (toward outer edge)  → far edge (_catchBend/_catchFb)
        if (signedRaw >= 0) {
            _bendDistance = bend;
            _fb = fb;
            _catchBend = 0;
            _catchFb = 0;
        } else {
            _bendDistance = 0;
            _fb = 0;
            _catchBend = bend;
            _catchFb = fb;
        }
        _ballCrossOffset = _bendSign * signedRaw;   // signed: + toward dest, − toward outer

        if (debugLog && (Date.now() - _lastDebugT) > 100) {
            _lastDebugT = Date.now();
            console.log("[GrooveSlider] effDrag=" + effDrag.toFixed(2)
                + " rawPen=" + rawPen.toFixed(2)
                + " fb=" + fb.toFixed(2)
                + " bend=" + bend.toFixed(2)
                + " halfW=" + _contactHalfWidth.toFixed(2)
                + " ballOff=" + _ballCrossOffset.toFixed(2)
                + " ballR=" + ballR.toFixed(2)
                + " clearance=" + clearance.toFixed(2));
        }

        // Snap only fires when dragging TOWARD destination (signedRaw > 0).
        // Outer-edge drag does nothing functional — ball just visually moves
        // there for tactile freedom.
        if (muteEnabled && signedRaw > 0) {
            let snapRawPen = scTrackSep - clearance;
            let modeMul = (_dragMode === "volume") ? 1.3 : 1.0;
            if (rawPen >= snapRawPen * modeMul) _fireMuteSnap(mx, my);
        }
    }

    function _onRelease(mx, my, button) {
        if (button !== Qt.LeftButton) {
            _dragMode = "idle";
            return;
        }
        let mode = _dragMode;
        _dragMode = "idle";

        if (mode === "pressing" && _pressOnBall) {
            _emitFidget();
            return;
        }
        // Spring back any residual bend / ball flatten / ball offset
        // (toward-destination or outer-edge drag — relax both).
        bendRelaxAnim.restart();
        ballOffsetRelaxAnim.restart();
        fbRelaxAnim.restart();
        if (!catchSeqAnim.running) {
            catchBendRelaxAnim.restart();
            catchFbRelaxAnim.restart();
        }
    }

    // A mouse's notch is 5 % (rolled up: more); fingers move it with them, the same 5 % a notch's worth of angle. Sideways is nobody's.
    function _onWheel(ev) {
        const n = ev.device === "wheel" ? ev.notches.y : ev.angleDelta.y / 120;
        if (n === 0)
            return;
        let newValue = Math.max(0, Math.min(maxValue, value + n * maxValue * 0.05));
        if (newValue === value) return;
        value = newValue;
        userChangedValue(newValue);
    }

    // ======================================================================
    // SNAP FIRE
    //
    // Fires when |effDrag| >= threshold. Caches the ball's pre-snap canvas-y
    // position so the rendered ball stays put across the muted flip, then
    // springs the residual cross offset to 0 on the new bar.
    // ======================================================================
    function _fireMuteSnap(currentMx, currentMy) {
        _preSnapBallCanvasY = _activeBarCenterY + _ballCrossOffset;

        let isUnmute = muted; // we're about to flip away from `muted` state
        if (isUnmute) {
            _bendSigmaMultiplier = unmuteBendSigmaMultiplier;
            sigmaSettleAnim.restart();
        }

        _emitMuteBurst(!muted);
        userToggledMute();
        // Caller flips `muted` → `onMutedChanged` runs → finalises post-snap state.

        // Reset cross origin so further drag in the same hold can re-snap.
        _crossOriginY = currentMy;
        _pressX = currentMx; // also reset along origin (less surprising)
        _pressY = currentMy;
    }

    onMutedChanged: {
        // First muted change happens during initial property-binding evaluation
        // (when lineLength is still 0). Defer until the component's geometry
        // is stable — onLineLengthChanged will set _initialized = true and
        // call _setSteadyThicknessState() which positions both bars correctly.
        if (!_initialized) return;
        // No mechanic, no swap and no rebound: `muted` is inert here.
        if (!muteEnabled) return;

        // Stop any in-flight relaxation / catch animations.
        bendRelaxAnim.stop();
        ballOffsetRelaxAnim.stop();
        fbRelaxAnim.stop();
        catchSeqAnim.stop();

        // 1) Trigger BAR THICKNESS PROPAGATION on both bars.
        //
        // Old active bar (becoming inactive) shrinks UNIFORMLY: fat animates
        // scFat → scThin while grow stays as it is.
        //
        // New active bar (becoming fat) SWELLS from the ball: fat snaps to
        // scFat, ctr = where the ball is (a fraction of the groove), and grow
        // runs 0 → 1 -- the ball stands in the full channel from frame 1
        // (BAR THICKNESS).
        mainShrinkAnim.stop(); mainGrowAnim.stop();
        muteShrinkAnim.stop(); muteGrowAnim.stop();

        if (muted) {
            // Main: was active fat → becoming inactive thin (uniform shrink).
            mainShrinkAnim.from = _mainFat;
            mainShrinkAnim.to = scThin;
            mainShrinkAnim.start();
            // Mute: was inactive thin → becoming active fat (the swell).
            _muteFat = scFat;
            _muteCtr = _ballFraction();
            _muteGrow = 0;
            muteGrowAnim.start();
        } else {
            muteShrinkAnim.from = _muteFat;
            muteShrinkAnim.to = scThin;
            muteShrinkAnim.start();
            _mainFat = scFat;
            _mainCtr = _ballFraction();
            _mainGrow = 0;
            mainGrowAnim.start();
        }

        // 2) Trigger CATCH REBOUND.
        //
        // Phase 2  — ball appears at near-inside (where it arrived through),
        //            traverses to far-inside with bend + flatten peaking at
        //            the impact point against the bar's outer (far) edge.
        // Phase 2b — ball continues past the bar's outer edge into the empty
        //            space beyond. Bend + flatten relax to 0 since ball is
        //            past the bar.
        // Phase 3  — spring back to center with bouncy overshoot.
        let halfT_target = scFat * 0.5;
        let R = scBall * 0.5;
        let edgeInside = Math.max(2, halfT_target - R - 1.0);
        let nearInside = _bendSign * edgeInside;
        let farInside = -_bendSign * edgeInside;
        // Past outer: ball center pokes a small distance beyond the bar's
        // outer edge into "nothing" — subtle rebound past the groove.
        let farPastOuter = -_bendSign * (halfT_target + R * 0.2);

        _bendDistance = 0;
        _fb = 0;
        _catchBend = 0;
        _catchFb = 0;
        _ballCrossOffset = nearInside;

        catchBallTraversalAnim.from = nearInside;
        catchBallTraversalAnim.to = farInside;
        catchBendImpactAnim.from = 0;
        catchBendImpactAnim.to = scBall * 0.45;
        catchFbImpactAnim.from = 0;
        catchFbImpactAnim.to = scBall * 0.18;

        catchBallOvershootAnim.from = farInside;
        catchBallOvershootAnim.to = farPastOuter;

        catchSeqAnim.start();
    }

    // Snap both bars to their steady-state thickness (no animation) — used
    // for first-load init once geometry is stable.
    function _setSteadyThicknessState() {
        if (_muteActive) {
            _muteFat = scFat;
            _muteGrow = 1;
            _muteCtr = 0.5;
            _mainFat = scThin;
            _mainGrow = 0;
        } else {
            _mainFat = scFat;
            _mainGrow = 1;
            _mainCtr = 0.5;
            _muteFat = scThin;
            _muteGrow = 0;
        }
    }

    // Initialise boost on first load. Thickness state init is deferred to
    // onLineLengthChanged so it gets the actual geometry.
    Component.onCompleted: {
        maxValue = allowBoost ? boostMaxValue : 1.0;
        if (lineLength > 0) {
            _setSteadyThicknessState();
            _initialized = true;
        }
    }
    onLineLengthChanged: {
        if (!_initialized && lineLength > 0) {
            _setSteadyThicknessState();
            _initialized = true;
        }
    }

    // ======================================================================
    // PARTICLES — slide sparks (continuous), mute burst, fidget, jump
    // ======================================================================
    property real _lastSparkAlong: -1000
    property real _lastSparkAcross: -1000
    property real _lastSparkTime: 0
    // Exponentially-smoothed velocity used for spark emission direction. Each
    // emit reads this rather than the raw delta so abrupt direction changes
    // (mute snap, sharp drag reversal) ease into the new direction across a
    // few frames instead of robotically pivoting 90°.
    property real _smoothVx: 0
    property real _smoothVy: 0
    property real sparksDirectionSmoothing: 0.18   // EMA alpha; lower = smoother

    onBallAlongChanged: _maybeEmitSparks()
    on_BallCrossOffsetChanged: _maybeEmitSparks()

    function _maybeEmitSparks() {
        if (!sparksEnabled) return;
        let bx = ballAlong;
        let by = _activeBarCenterY + _ballCrossOffset;
        let now = Date.now();
        if (_lastSparkAlong < -500) {
            _lastSparkAlong = bx;
            _lastSparkAcross = by;
            _lastSparkTime = now;
            _smoothVx = 0;
            _smoothVy = 0;
            return;
        }
        let dt = Math.max(1, now - _lastSparkTime);
        let dx = bx - _lastSparkAlong;
        let dy = by - _lastSparkAcross;
        let speed = Math.sqrt(dx * dx + dy * dy) / dt;

        // Update smoothed velocity (in px/ms units, will be scaled below).
        let alpha = sparksDirectionSmoothing;
        _smoothVx = _smoothVx * (1 - alpha) + (dx / dt) * alpha;
        _smoothVy = _smoothVy * (1 - alpha) + (dy / dt) * alpha;

        if (speed > sparksSpeedThreshold) {
            let count = Math.floor(speed * sparksAmountMultiplier);
            for (let i = 0; i < count; i++) {
                let doSwirl = Math.random() < sparksSwirlProb;
                let dir = Math.random() > 0.5 ? 1 : -1;
                let vxBase = -_smoothVx * 1000;
                let vyBase = -_smoothVy * 1000;
                slideParticles.emit({
                    x: bx,
                    y: by,
                    vx: vxBase * sparksBaseVelocity + (Math.random() - 0.5) * sparksScatter,
                    vy: vyBase * sparksBaseVelocity + (Math.random() - 0.5) * sparksScatter,
                    lifetime: sparksLifetimeBase + Math.random() * sparksLifetimeVariance,
                    maxHistory: sparksMaxHistory,
                    sizeStart: sizeScale * sparksSizeStart,
                    sizeEnd: sizeScale * sparksSizeEnd,
                    colorStart: sparksColorStart.toString(),
                    colorEnd: sparksColorEnd.toString(),
                    drag: sparksDrag,
                    forceField: (function (mag, on, sd) {
                        return function (px, py, t) {
                            if (!on || mag <= 0 || t <= 0.5) return { x: 0, y: 0 };
                            let s = (t - 0.5) / 0.5;
                            return {
                                x: Math.cos(t * 15 * sd) * mag * s * 1000,
                                y: Math.sin(t * 15 * sd) * mag * s * 1000
                            };
                        };
                    })(sparksSwirlStr, doSwirl, dir)
                }, 1);
            }
        }
        _lastSparkAlong = bx;
        _lastSparkAcross = by;
        _lastSparkTime = now;
    }

    function _emitFidget() {
        let bx = ballAlong, by = _activeBarCenterY + _ballCrossOffset;
        for (let i = 0; i < fidgetCount; i++) {
            let ang = (Math.PI * 2 * i) / fidgetCount + Math.random() * 0.4;
            let speed = fidgetSpeed * (0.7 + Math.random() * 0.6);
            burstParticles.emit({
                x: bx, y: by,
                vx: Math.cos(ang) * speed,
                vy: Math.sin(ang) * speed,
                lifetime: fidgetLifetime,
                maxHistory: 3,
                sizeStart: 2.2 * sizeScale,
                sizeEnd: 0.5 * sizeScale,
                colorStart: ballColor.toString(),
                colorEnd: "transparent",
                drag: 3.5
            }, 1);
        }
        _fidgetShrinkAnim.restart();
    }

    function _emitMuteBurst(targetMuted) {
        let bx = ballAlong, by = _activeBarCenterY + _ballCrossOffset;
        let cs = targetMuted ? muteBurstColor.toString()
                             : unmuteBurstColorStart.toString();
        let ce = targetMuted ? "transparent"
                             : unmuteBurstColorEnd.toString();
        for (let i = 0; i < muteBurstCount; i++) {
            let ang = (Math.PI * 2 * i) / muteBurstCount + Math.random() * 0.3;
            let speed = muteBurstSpeed * (0.7 + Math.random() * 0.6);
            burstParticles.emit({
                x: bx, y: by,
                vx: Math.cos(ang) * speed,
                vy: Math.sin(ang) * speed,
                lifetime: muteBurstLifetime,
                maxHistory: 3,
                sizeStart: 2.4 * sizeScale,
                sizeEnd: 0.6 * sizeScale,
                colorStart: cs,
                colorEnd: ce,
                drag: 2.8
            }, 1);
        }
    }

    function _emitClickJumpBurst() {
        let bx = ballAlong, by = _activeBarCenterY + _ballCrossOffset;
        for (let i = 0; i < 5; i++) {
            let ang = Math.random() * Math.PI * 2;
            let speed = 60 * (0.7 + Math.random() * 0.6);
            burstParticles.emit({
                x: bx, y: by,
                vx: Math.cos(ang) * speed,
                vy: Math.sin(ang) * speed,
                lifetime: 320,
                maxHistory: 2,
                sizeStart: 1.2 * sizeScale,
                sizeEnd: 0.4 * sizeScale,
                colorStart: ballColor.toString(),
                colorEnd: "transparent",
                drag: 4.0
            }, 1);
        }
    }

    // Fidget shrink anim — brief scale-down then bounce-back.
    property real _fidgetShrink: 1.0
    SequentialAnimation {
        id: _fidgetShrinkAnim
        NumberAnimation {
            target: root; property: "_fidgetShrink"
            to: root.fidgetBallShrink
            duration: root.fidgetShrinkDuration / 2
            easing.type: Easing.OutCubic
        }
        NumberAnimation {
            target: root; property: "_fidgetShrink"
            to: 1.0
            duration: root.fidgetShrinkDuration / 2
            easing.type: Easing.OutBack
            easing.overshoot: 1.4
        }
    }

    // ======================================================================
    // RENDERING — inner canvas in horizontal frame, rotated for vertical
    // ======================================================================
    Item {
        id: canvas
        anchors.centerIn: parent
        width: root.lineLength
        height: root.lineCross
        rotation: root.isHorizontal ? 0 : 90

        // -------- SLIDE SPARK LAYER + BLOOM --------
        ParticleSystem {
            id: slideParticles
            anchors.fill: parent
            maxParticles: 500
            z: 3
        }
        MultiEffect {
            source: slideParticles
            anchors.fill: slideParticles
            blurEnabled: true
            blurMax: root.sparksBloomBlur
            blur: root.sparksBloomStrength
            brightness: root.sparksBloomBrightness
            z: 4
            visible: root.sparksEnabled
        }

        // -------- BURST PARTICLE LAYER --------
        ParticleSystem {
            id: burstParticles
            anchors.fill: parent
            maxParticles: 200
            z: 6
        }

        // -------- BAR CHANNELS --------
        ScaledCanvas {
            id: barCanvas
            anchors.fill: parent
            antialiasing: true
            renderStrategy: Canvas.Cooperative
            renderScale: root.renderScale

            readonly property string _paintKey: [
                root.lineLength, root.lineCross, root.lineCenter,
                root.grooveStart, root.grooveEnd, root.scTrackSep,
                root._mainFat, root._mainGrow, root._mainCtr,
                root._muteFat, root._muteGrow, root._muteCtr, root.barWavefrontSpan,
                root._muteSign, root._bendSign, root._muteActive, root.muteEnabled,
                root._bendDistance, root._fb, root._contactHalfWidth,
                root._catchBend, root._catchFb, root._catchHalfWidth,
                root._bendSigma, root.ballAlong,
                root.edgeInfluence,
                root.grooveBevelWidth, root.grooveShadowWidth, root.sizeScale,
                root.surfaceColor, root.grooveBevelColor, root.grooveShadowColor, root.grooveColor,
                root.muteBarColor, root.muteBarBevelColor, root.muteBarShadowColor
            ].join("|")
            on_PaintKeyChanged: requestPaint()

            onDraw: (ctx, cw, ch) => {
                ctx.lineCap = "round";
                ctx.lineJoin = "round";
                ctx.antialiasing = true;

                let bw = root.grooveBevelWidth * root.sizeScale;
                let sw = root.grooveShadowWidth * root.sizeScale;
                let sigma = Math.max(1, root._bendSigma);
                let sigma2 = sigma * sigma;
                let N = 80;
                let dxStep = (root.grooveEnd - root.grooveStart) / N;

                let bezBevel = [0.15, 0.1, 0.25, 1.0];
                let bezShadow = [0.15, 0.60, 0.35, 1.0];

                function lerpColor(c1, c2, f) {
                    return Qt.rgba(
                        c1.r + (c2.r - c1.r) * f,
                        c1.g + (c2.g - c1.g) * f,
                        c1.b + (c2.b - c1.b) * f,
                        c1.a + (c2.a - c1.a) * f);
                }
                function ease(x, eb) {
                    if (x <= 0) return 0;
                    if (x >= 1) return 1;
                    let t = x;
                    for (let i = 0; i < 8; i++) {
                        let t2 = t * t, mt = 1 - t, mt2 = mt * mt;
                        let bx = 3 * mt2 * t * eb[0] + 3 * mt * t2 * eb[2] + t2 * t;
                        let dbx = 3 * mt2 * eb[0] + 6 * mt * t * (eb[2] - eb[0]) + 3 * t2 * (1 - eb[2]);
                        if (Math.abs(dbx) < 1e-6) break;
                        let dt = (bx - x) / dbx;
                        t -= dt;
                        if (Math.abs(dt) < 1e-5) break;
                    }
                    t = Math.max(0, Math.min(1, t));
                    let t2 = t * t, mt = 1 - t, mt2 = mt * mt;
                    return 3 * mt2 * t * eb[1] + 3 * mt * t2 * eb[3] + t2 * t;
                }

                function drawBar(centerY, thicknessFn, bendAmt, bendDir, isActive, fillCol, bevelCol, shadowCol) {
                    // thicknessFn(x) — sample bar thickness per along-axis x
                    // (so propagation wave widens the bar progressively).
                    // Active bar uses the shared _activeBarEdgeYAt helper for
                    // both edges (ensures the bar edge matches the ball's
                    // wallFunc exactly, zero gap). Inactive bar uses a
                    // simpler Gaussian profile around ballAlong; bend on
                    // inactive should be ~0 anyway so curves disappear.

                    function nearEdgeY(x) {
                        if (isActive) return root._activeBarEdgeYAt(x, true);
                        let halfT = thicknessFn(x) * 0.5;
                        let dx = x - root.ballAlong;
                        let g = bendAmt > 0 ? Math.exp(-(dx * dx) / sigma2) : 0;
                        return centerY + bendDir * halfT + bendDir * bendAmt * g;
                    }
                    function farEdgeY(x) {
                        if (isActive) return root._activeBarEdgeYAt(x, false);
                        let halfT = thicknessFn(x) * 0.5;
                        let dx = x - root.ballAlong;
                        let g = bendAmt > 0 ? Math.exp(-(dx * dx) / sigma2) : 0;
                        return centerY - bendDir * halfT
                             + bendDir * bendAmt * root.edgeInfluence * g;
                    }

                    // Sample each edge at N+1 positions.
                    let nearPts = new Array(N + 1);
                    let farPts = new Array(N + 1);
                    for (let j = 0; j <= N; j++) {
                        let x = root.grooveStart + j * dxStep;
                        nearPts[j] = { x: x, y: nearEdgeY(x) };
                        farPts[j] = { x: x, y: farEdgeY(x) };
                    }
                    // Top = smaller y (visually upper), Bot = larger y.
                    let topPts, botPts;
                    if (bendDir > 0) { topPts = farPts; botPts = nearPts; }
                    else             { topPts = nearPts; botPts = farPts; }

                    // Concentric polygons from outermost (d=-bw) to innermost (d=sw).
                    let dVals = [];
                    dVals.push(-bw);
                    for (let d = -bw + 0.4; d <= sw; d += 0.4) dVals.push(d);
                    if (dVals[dVals.length - 1] < sw - 0.01) dVals.push(sw);

                    for (let i = 0; i < dVals.length; i++) {
                        let d = dVals[i];
                        let color;
                        if (d < 0) {
                            let f = (d + bw) / Math.max(0.001, bw);
                            f = ease(f, bezBevel);
                            color = lerpColor(root.surfaceColor, bevelCol, f);
                        } else if (d < sw) {
                            let f = d / Math.max(0.001, sw);
                            f = ease(f, bezShadow);
                            color = lerpColor(shadowCol, fillCol, f);
                        } else {
                            color = fillCol;
                        }
                        // Topshift: d > 0 inset (top moves down by d); d < 0 outset (top moves up by |d|).
                        let topShift = d;
                        let botShift = -d;

                        ctx.fillStyle = color;
                        ctx.beginPath();
                        // Top edge L→R, then arc the right end down (CW
                        // through +x), then bot edge R→L, then arc the left
                        // end up (CW through -x). Both caps half-circles whose
                        // radius is the local channel half-thickness at that
                        // x, so the cap exactly matches the channel opening.
                        ctx.moveTo(topPts[0].x, topPts[0].y + topShift);
                        for (let j = 1; j <= N; j++) {
                            ctx.lineTo(topPts[j].x, topPts[j].y + topShift);
                        }
                        let topYR = topPts[N].y + topShift;
                        let botYR = botPts[N].y + botShift;
                        if (botYR > topYR + 0.5) {
                            ctx.arc(topPts[N].x, (topYR + botYR) * 0.5,
                                    (botYR - topYR) * 0.5,
                                    -Math.PI / 2, Math.PI / 2, false);
                        } else {
                            ctx.lineTo(botPts[N].x, botYR);
                        }
                        for (let j = N; j >= 0; j--) {
                            ctx.lineTo(botPts[j].x, botPts[j].y + botShift);
                        }
                        let topYL = topPts[0].y + topShift;
                        let botYL = botPts[0].y + botShift;
                        if (botYL > topYL + 0.5) {
                            ctx.arc(topPts[0].x, (topYL + botYL) * 0.5,
                                    (botYL - topYL) * 0.5,
                                    Math.PI / 2, -Math.PI / 2, false);
                        } else {
                            ctx.lineTo(topPts[0].x, topYL);
                        }
                        ctx.closePath();
                        ctx.fill();
                    }
                }

                // Render main bar then mute bar (or vice versa — order picked by which is active so
                // the active bar's bend renders ABOVE the inactive bar's static rect, in case of overlap).
                let mainBendAmt = root._muteActive ? 0 : root._bendDistance;
                let muteBendAmt = root._muteActive ? root._bendDistance : 0;
                let mainBendDir = root._muteSign;        // main's destination is the mute bar
                let muteBendDir = -root._muteSign;       // mute's destination is the main bar

                let mainThickFn = function (x) { return root._mainThicknessAtX(x); };
                let muteThickFn = function (x) { return root._muteThicknessAtX(x); };

                if (!root.muteEnabled) {
                    // One bar, and it is the only thing there is to draw.
                    drawBar(root.lineCenter, mainThickFn,
                            mainBendAmt, mainBendDir, true,
                            root.grooveColor, root.grooveBevelColor, root.grooveShadowColor);
                } else if (root._muteActive) {
                    // Inactive (main) first, active (mute) above.
                    drawBar(root.lineCenter, mainThickFn,
                            mainBendAmt, mainBendDir, false,
                            root.grooveColor, root.grooveBevelColor, root.grooveShadowColor);
                    drawBar(root.lineCenter + root._muteSign * root.scTrackSep,
                            muteThickFn,
                            muteBendAmt, muteBendDir, true,
                            root.grooveColor, root.grooveBevelColor, root.grooveShadowColor);
                } else {
                    drawBar(root.lineCenter + root._muteSign * root.scTrackSep,
                            muteThickFn,
                            muteBendAmt, muteBendDir, false,
                            root.muteBarColor, root.muteBarBevelColor, root.muteBarShadowColor);
                    drawBar(root.lineCenter, mainThickFn,
                            mainBendAmt, mainBendDir, true,
                            root.grooveColor, root.grooveBevelColor, root.grooveShadowColor);
                }
            }
        }

        // -------- BALL --------
        SquishItem {
            id: ball
            x: root.ballAlong - baseWidth / 2
            y: (root._activeBarCenterY + root._ballCrossOffset) - baseHeight / 2
            baseWidth: root.scBall * root._fidgetShrink
            baseHeight: root.scBall * root._fidgetShrink

            // Velocity-squish axis lock during normal slide.
            // SquishItem derives squish direction from trackX/trackY changes.
            // During drag, the ball moves perpendicular with the cursor — if
            // we let SquishItem see that, diagonal cursor motion squishes the
            // ball diagonally (looks weird in a horizontal groove). So during
            // drag we override trackY to the bar centerline only — SquishItem
            // sees pure along-axis motion → squish stays along the groove.
            // During snap recovery (relax animations running), trackY follows
            // the actual ball position so the spring-driven cross motion
            // produces the natural jiggle/wobble landing tail.
            trackX: root.ballAlong
            trackY: (ballOffsetRelaxAnim.running
                    || bendRelaxAnim.running
                    || fbRelaxAnim.running)
                ? (root._activeBarCenterY + root._ballCrossOffset)
                : root._activeBarCenterY

            color: root._muteActive ? root.ballMutedColor : root.ballColor
            shadowColor: root._muteActive ? root.ballMutedShadowColor : root.ballShadowColor
            shadowOpacity: root.ballShadowOpacity
            shadowBlur: root.scBallShadowBlur
            // pressure 0 = ball fully flattens to wallFunc; bar's drawn near
            // edge sits where wallFunc returns, so ball edge meets bar edge
            // exactly (no protrusion / gap regardless of bend depth).
            pressure: 0.0
            // Velocity squish always on — gives the wobble / radial inertia
            // / wavy edges during slide: noticeable elongation under fast
            // drag, angular-momentum tail after a sharp turn.
            overrideWidth: root._squishVelEnabled ? 0 : (root.scBall * root._fidgetShrink)
            overrideHeight: root._squishVelEnabled ? 0 : (root.scBall * root._fidgetShrink)
            maxSquishRatio: 0.5          // elongation cap under fast drag
            recoverySpringStiffness: 2.4
            recoverySpringDamping: 0.14  // very bouncy recovery — wobblier
            maxSpeedThreshold: 24.0      // saturate squish at slightly lower speed

            collisions: {
                let cols = [];
                let bendSign = root._bendSign;
                // Normal near-side flatten (active during pre-snap drag).
                if (root._fb > 0.2) {
                    cols.push({
                        dir: bendSign > 0 ? 90 : -90,
                        depth: root._fb
                    });
                }
                // Catch far-side flatten (active during snap rebound).
                if (root._catchFb > 0.2) {
                    cols.push({
                        dir: bendSign > 0 ? -90 : 90,
                        depth: root._catchFb
                    });
                }
                if (root.debugLog && cols.length > 0) {
                    console.log("[GrooveSlider.collisions] fb=" + root._fb.toFixed(2)
                        + " catchFb=" + root._catchFb.toFixed(2)
                        + " halfW=" + root._contactHalfWidth.toFixed(2)
                        + " catchHalfW=" + root._catchHalfWidth.toFixed(2));
                }
                return cols;
            }
            z: 7
        }

        // -------- INPUT LAYER --------
        WheelArea {
            id: input
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
            cursorShape: Qt.PointingHandCursor
            z: 10

            onPressed: function (mouse) {
                root._onPress(mouse.x, mouse.y, mouse.button);
            }
            onPositionChanged: function (mouse) {
                if (!input.pressed) return;
                root._onMove(mouse.x, mouse.y);
            }
            onReleased: function (mouse) {
                root._onRelease(mouse.x, mouse.y, mouse.button);
            }
            turned: wheel => {
                root._onWheel(wheel);
                wheel.accepted = true;
            }
        }
    }
}
