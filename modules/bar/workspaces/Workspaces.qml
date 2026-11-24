pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Hyprland

import "../../common/particles"
import "../../common/theme"
import "../../common/components"
import "../../common/components/CarvedPath.js" as CarvedPath
import "../../common/scroll"

// ==========================================================================
// Workspaces.qml
//
// Reusable Hyprland workspace indicator. Renders a horizontal (or vertical)
// "chasm" groove with one dot per workspace and an elastic ball on the
// currently active workspace. When a clock divides the line, two curved
// side tracks connect the two halves; each corner is shaped by a
// configurable CSS-style cubic-bezier curve. The clock itself has NO container
// (DeploymentNotes.md 126): the groove opens round `clockSlot` and the host's
// button stands there, its figures drawn straight on the surface.
//
// All internal coordinates live in the horizontal reference frame. Vertical
// orientation is achieved by rotating an inner canvas 90°, so every bit of
// math below assumes "along" = x, "across" = y.
//
// IN A BAR WITH SCREENS. `focusSource` (a FocusedScreen, modules/common/system)
// and `screenName` make the ball sit on the workspace THIS bar's monitor shows,
// right from the first frame, and make a click focus that monitor and then the
// workspace. Without a source it follows Hyprland.focusedWorkspace
// (null until an event on Hyprland 0.56). `clockSlot` is where the host puts the
// clock button.
// (The source is named `focusSource`: an Item's `focus` is FINAL.)
//
// THE SWIPE (DeploymentNotes.md 124). A two-finger swipe ALONG the strip, anywhere
// over the module -- the clock's slot included, the host's button there lets a wheel
// through -- steps the workspaces with the tab selector's sticky feel: SwipeSteps,
// the shell's one engine. Fingers moving left to right go to the next workspace on
// the right (positive angle = forward, as the tab selector's). A slow swipe stops
// where it is meant to, one workspace a step; a flick carries across several; the
// ball leans toward the next dot while the fingers are down and springs back when
// they lift short of it. A swipe is a wheel: a MouseArea that never accepts, never a
// WheelHandler (gestures.md).
// ==========================================================================
Item {
    id: root

    // ======================================================================
    // PUBLIC API
    // ======================================================================

    // ---- Which workspace is the active one, and how a click gets there ----
    // The shell's FocusedScreen (null: Hyprland.focusedWorkspace) and the
    // monitor THIS bar is on ("": the focused monitor's workspace).
    property var focusSource: null
    property string screenName: ""
    // How a click reaches Hyprland: null sends it through Quickshell (`Hyprland.dispatch`);
    // a probe hands in `function (luaExpression) { ... }` instead.
    property var dispatcher: null

    // ---- Orientation (set at initialisation, not animated) --------------
    property string orientation: "horizontal"    // "horizontal" | "vertical"

    // ---- General scale: multiplies every intrinsic size -----------------
    property real sizeScale: 1.5

    // ---- Core geometry (all scaled by sizeScale at use sites) -----------
    property real lineThickness: 6
    property real dotSize: 12
    property real ballSize: 14
    property real edgePadding: 18                // empty space at the line ends

    // ---- Clock divider --------------------------------------------------
    property bool showClock: true
    property real clockSize: 60                  // along-axis size of the clock
    // THE ROOM THE CLOCK ASKS FOR ON TOP OF ITS SLOT: hovering the clock brings its seconds in, and
    // the assembly gives the room -- the slot widens by this (same units as `clockSize`) and the dots on either side move out, the
    // module's own length unchanged. The host animates it; everything drawn along the groove reads the layout, so the dots, the
    // corners, the fills and the ball follow in the same frame (the ball is a rail coordinate: ANIMATION STATE).
    property real clockExtra: 0
    property real clockCross: 16                 // cross-axis size of the clock
    property real clockGap: 32                   // gap between last dot and clock
    property real trackSeparation: 14            // distance main-line → side track
    property bool invertTracks: false

    // ---- Split + cubic-bezier corners -----------------------------------
    // splitOffset pushes the bezier start past the last dot. Default 0 means
    // the bezier begins right at the last dot. Value is clamped so the curve
    // never intrudes into the clock area.
    property real splitOffset: 10
    property real cornerExtent: 24               // along-axis span of each corner

    // CSS cubic-bezier(x1, y1, x2, y2) control points for each corner, in
    // normalized [0..1] coordinates of the curve's own bounding box.
    property var bezierTopLeft:     [0.5, 0.0, 0.5, 1.0]
    property var bezierTopRight:    [0.5, 0.0, 0.5, 1.0]
    property var bezierBottomLeft:  [0.5, 0.0, 0.5, 1.0]
    property var bezierBottomRight: [0.5, 0.0, 0.5, 1.0]

    // ---- Workspace filtering --------------------------------------------
    // Canonical list of IDs to always show. Hyprland lazily creates &
    // destroys workspaces, so using only the live list causes dots to
    // appear/disappear. This explicit list stabilises the layout.
    property var workspaceIds: [1, 2, 3, 4]

    // ---- Animation ------------------------------------------------------
    property int animationDuration: 400

    // ---- Swipe ------------------------------------------------------------
    // False: the module ignores a swipe altogether. The feel is SwipeSteps'.
    property alias swipeEnabled: swipe.enabled
    // The ball's lean toward the next workspace, in dot pitches (signed), and whether a
    // gesture is under way: what a probe reads.
    readonly property real swipePull: swipe.pull
    readonly property bool swiping: swipe.active

    // ---- Colors ---------------------------------------------------------
    property color grooveColor: Theme.panelSunk
    property color ballColor: Theme.accent

    // ---- Particle Effects (Sparks) --------------------------------------
    property bool  sparksEnabled: true
    property real  sparksSpeedThreshold: 0.3      // Minimum ball speed to emit sparks
    property real  sparksAmountMultiplier: 3.0    // Higher = more sparks per speed unit
    property real  sparksBaseVelocity: 0.1        // How much of ball's velocity is inherited backwards
    property real  sparksScatter: 100.0           // Random scatter velocity range
    property real  sparksLifetimeBase: 700.0      // Base milliseconds of life
    property real  sparksLifetimeVariance: 1000.0  // Random extra milliseconds
    property int   sparksMaxHistory: 8            // Trail length
    property real  sparksSizeStart: 3.0           // Multiplied by sizeScale
    property real  sparksSizeEnd: 1.0             // Multiplied by sizeScale
    property color sparksColorStart: ballColor
    property color sparksColorEnd: "transparent"
    property real  sparksDrag: 2.0                // Air resistance
    property real  sparksSwirlStr: 0.4           // Swirl strength at end of life
    property real  sparksSwirlProb: 0.4           // Probability of swirl happening
    property real  sparksBloomBlur: 24.0          // Blur amount for bloom
    property real  sparksBloomStrength: 0.3       // Bloom multiplier
    property real  sparksBloomBrightness: 0.85     // Overall brightness of bloom layer
    // THE PARTICLES' ROOM. A jump from one end to the other (more speed, so more momentum) sends the sparks past the
    // module's own rect, where they would be cut, so the canvas may be larger than the module: `particleReachX` px more on EACH side
    // (symmetric about the module, so the room is the same either way), `particleReachDown` px more below it -- over
    // whatever is under the bar. Nothing is cut hard: over the last `particleEdgeFade` px of the sides and the foot
    // a spark fades out; the top stays hard (the screen's edge). Both reaches 0 is the module's own rect. A horizontal
    // module only (the vertical one's canvas is rotated: its sides are not the screen's). Px of THIS item.
    property real particleReachX: 0
    property real particleReachDown: 0
    property real particleEdgeFade: 24
    readonly property real _reachX: root.isHorizontal ? Math.max(0, root.particleReachX) : 0
    readonly property real _reachDown: root.isHorizontal ? Math.max(0, root.particleReachDown) : 0

    // ---- Groove inset shadow & bevel -----------------------------------
    property real  grooveShadowWidth: 3
    property real  grooveBevelWidth:  2
    property color surfaceColor:      Theme.surface
    property color grooveBevelColor:  Theme.bevel
    property color grooveShadowColor: Theme.border
    property var   grooveGradientEasing: [0.15,0.60,0.35,1]
    property var   grooveBevelEasing: [0.15, 0.1, 0.25, 1.0]

    // ---- Progress fills --------------------------------------------------
    // What a host (the clock's timers) wants shown IN the groove: its inset
    // shadow recoloured up to a moving end -- the rail's own background stays as it
    // is, the way a notification toast shows its time left -- the carve itself
    // untouched, the end a convex head -- no ball on it. The module knows nothing
    // about timers; a fill is a fact:
    //   { piece, tone, from, to0, to1, t0, t1, reverse }
    //   piece    0 left line, 1 upper track, 2 right line, 3 lower track (the
    //            loop around the clock, clockwise); -1 the whole bar by x --
    //            the left line, then both tracks together, then the right
    //            line. Without the clock split the four pieces are quarters.
    //   tone     index into fillToneColors; a higher tone draws over a lower
    //   from     where the fill starts, 0..1 of the piece
    //   to0/to1  where its end is at t0 / t1 (ms, fillClock's time); linear in
    //            between, held outside; t0 === t1 is a static end
    //   reverse  the piece fills from its far end
    // A fraction of 1 reaches the groove's own round cap at the bar's outer
    // ends, so a full fill ends as the groove does.
    property var fills: []
    // { now() } -- the host's clock, so a mockup can run time faster. Null is
    // the wall clock.
    property var fillClock: null
    // Tone 3 is the BREAK NUDGE's (breakSource): drawn UNDER the timers' tones, so a running timer keeps the groove.
    property var fillToneColors: [Theme.timerRun, Theme.timerFocus, Theme.timerBreak, Theme.warn]
    readonly property int breakTone: 3
    // The fill's inset shadow is its tone darkened by this ...
    property real fillShadowDarken: 1.35
    // ... and shown at this strength: 1 is that colour as it is, 0 the groove's own inset (no fill at all), in between the groove's
    // shadow turned that share of the way toward it. The full inset alone is too noticeable. The one number to turn for how loudly a timer
    // shows in the rail.
    property real fillStrength: 0.5
    // IN DARK MODE the strength is this many times more, because the timer colours read a bit too subtle on the dark ground. The shade is blended linearly from the
    // groove's own inset toward the tone's, so 1.12 times the strength is exactly 12 % more colour in the rail on the dark ground and nothing on
    // the light one. A share, not a second palette: the tokens (`timerRun` ...) are the timers card's too.
    property real fillDarkBoost: 1.12
    readonly property real _fillStrengthNow: Math.min(1, root.fillStrength * (Theme.mode === "dark" ? root.fillDarkBoost : 1))
    // How far into the groove the colour reaches: a multiple of the groove's own inset width. 1 is the inset exactly as the groove
    // carves it, without widening the range -- the colour at the edge, easing out to the rail's own by the line's middle;
    // above 1 the ease is stretched past the line's middle, so the colour reaches further in and the rail's own shows
    // less of itself, smoothly -- the one number to turn if the inset alone proves too faint to read at a glance.
    property real fillShadowWiden: 1.0
    // Depth of the convex head as a fraction of the half line: 1 is a
    // semicircle -- a capsule's end -- and 0 a straight cut.
    property real fillHeadBulge: 1.0
    // A moving fill repaints when its head has moved this far (px), and never
    // more often than fillMaxHz: the bar shares a window with every popup, so
    // each repaint redraws the whole window.
    property real fillQuantumPx: 0.5
    property int fillMaxHz: 10
    // The cap while a break beat's head glides (it only lasts the beat's ease, `stepEaseMs`).
    property int fillEaseMaxHz: 30
    // ... and it repaints per this many px of glide (the beat's head covers some px in under a second: a pixel a step reads smooth).
    property real fillEaseQuantumPx: 1
    // A fill that LEAVES -- a finished timer dismissed, a run reset or restarted, a pomodoro cleared -- is not
    // cut: its last picture fades out over this long (DeploymentNotes.md 128). 0 cuts.
    property int fillFadeMs: 160
    // Completion: a calm dust rising off a piece when what filled it is done.
    property int burstCount: 40
    property real burstLifetimeMs: 1600
    property real burstRise: 18                 // px/s, the drift away from the groove
    // THE FULL BURST (a break is due, a timer is done): the dust above, once more as a second, finer wave a beat later, and the piece's
    // fill flashing at full strength for burstFlashMs (its last picture, one canvas whose opacity does the fade: no repaint per frame).
    // 0 flash = the dust alone.
    property int burstFlashMs: 1100
    property real burstFlashStrength: 1.0
    property real burstSecondWave: 0.6          // the second wave's share of burstCount; 0 = one wave
    property int burstSecondDelayMs: 220
    // ---- the break nudge ----------------------------------------------------
    // { fills, filled() } -- the shell's one BreakClock (ClockBarOwner hands it over); a mockup hands its own, null shows none. The fill is drawn
    // like a timer's, under it; `filled` plays the burst over the whole bar in the nudge's tone.
    property var breakSource: null
    readonly property var _breakFills: root.breakSource && root.breakSource.fills ? root.breakSource.fills : []
    on_BreakFillsChanged: root._refreshFills(true)
    Connections {
        target: root.breakSource
        ignoreUnknownSignals: true
        function onFilled() { root.burst(-1, root.breakTone); }
    }
    // How many times the fill canvases have painted -- read by the probe. An
    // object mutated in place, so counting is not itself a dependency.
    readonly property var fillStats: ({ paints: 0, refreshes: 0, ghosts: 0, wakes: 0 })

    // ---- Ball drop shadow (CSS-style control) --------------------------
    property color ballShadowColor:       Theme.accent
    property real  ballShadowOpacity:     0.55
    property real  ballShadowBlur:        0.4   // 0..1, MultiEffect convention
    property real  ballShadowOffsetX:     0
    property real  ballShadowOffsetY:     0

    // ======================================================================
    // SCALED INTERNAL SIZES
    // ======================================================================
    readonly property real scLine: lineThickness * sizeScale
    readonly property real scDot: dotSize * sizeScale
    readonly property real scBall: ballSize * sizeScale
    readonly property real scPad: edgePadding * sizeScale
    readonly property real scClockSize: (clockSize + clockExtra) * sizeScale
    readonly property real scClockCross: clockCross * sizeScale
    readonly property real scClockGap: clockGap * sizeScale
    readonly property real scTrackSep: trackSeparation * sizeScale
    // THE SPLIT CLOSES (on a lock the two split rails converge into one rail, masking the clock like an eye closing): 0 is the groove as it is, 1 the two tracks lying ON the line, one rail, the clock hidden between them. The host
    // drives it with ONE eased fraction (ShellFrame.eyeF). Only what is DRAWN follows it (the tracks' centre lines: `_pointOn`, the carve, the fills,
    // the ball on a track): the dots' places come from the nominal separation (`_slotReach`), so no slot moves while the lids come together.
    property real lockMerge: 0
    // ... and then THE SLOTS SPREAD (all but the outer ball slots are distributed evenly on the rail as a whole): with
    // the clock hidden nothing needs the room any more. 0 the split's places, 1 every slot on its even place between the two outer ones, which do not move
    // (`dotPositions`: the carve, the fills, the ball and the hit targets all read it). The host's second fraction on the same clock (ShellFrame.eyeSlotsF).
    property real lockSpread: 0
    readonly property real scTrackSepNow: root.scTrackSep * (1 - Math.max(0, Math.min(1, root.lockMerge)))
    // Where the lids are: the clock is shown between the tracks' centre lines (they, drawn above it, cover the cut), so a host clips it to this half height.
    readonly property real clockBandHalf: root.scTrackSepNow
    readonly property real scCornerExt: cornerExtent * sizeScale

    // ======================================================================
    // IMPLICIT SIZING
    // ======================================================================
    readonly property real _crossNeeded: showClock
        ? Math.max(scClockCross, scBall, scLine + 2 * scTrackSep + scLine)
        : Math.max(scBall, scLine)

    implicitWidth: orientation === "horizontal" ? 500 : _crossNeeded + 16
    implicitHeight: orientation === "horizontal" ? _crossNeeded + 16 : 500

    readonly property bool isHorizontal: orientation === "horizontal"
    // "lineLength" is the long axis of the component; "lineCross" the short.
    readonly property real lineLength: isHorizontal ? width : height
    readonly property real lineCross: isHorizontal ? height : width
    readonly property real lineCenter: lineCross / 2

    // ======================================================================
    // WORKSPACE DATA (stabilised)
    // ======================================================================
    property var allWorkspaces: Hyprland.workspaces ? Hyprland.workspaces.values : []

    property var workspaceList: {
        let seen = {};
        let list = [];
        for (let i = 0; i < root.workspaceIds.length; i++) {
            let id = root.workspaceIds[i];
            if (!seen[id]) {
                seen[id] = true;
                list.push({ id: id });
            }
        }
        for (let i = 0; i < allWorkspaces.length; i++) {
            let w = allWorkspaces[i];
            // Numbered workspaces only: a slot is a number to ask for. A special workspace is no slot, whatever it reads (-98 / -99 up to Hyprland
            // 0.56, -1 on 0.57 where it has no id: that one would stand as a ghost slot in front of workspace 1), nor is a named one.
            if (w && w.id > 0 && !seen[w.id]) {
                seen[w.id] = true;
                list.push({ id: w.id });
            }
        }
        list.sort(function (a, b) { return a.id - b.id; });
        return list;
    }

    property int activeWorkspaceId: root.focusSource ? root.focusSource.activeWorkspaceOf(root.screenName)
                                                     : (Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1)

    // ======================================================================
    // LAYOUT
    // ======================================================================
    readonly property int totalDots: workspaceList.length
    readonly property int leftCount: showClock ? Math.ceil(totalDots / 2) : totalDots
    readonly property int rightCount: showClock ? Math.floor(totalDots / 2) : 0

    readonly property real centerLine: lineLength / 2
    readonly property real clockHalf: scClockSize / 2
    readonly property real leftSectionStart: scPad
    readonly property real leftSectionEnd: showClock
        ? centerLine - clockHalf - scClockGap
        : lineLength - scPad
    readonly property real rightSectionStart: showClock
        ? centerLine + clockHalf + scClockGap
        : 0
    readonly property real rightSectionEnd: lineLength - scPad

    // Where the clock sits, in THIS item's coordinates (either orientation): the host puts its clock
    // button here. Empty without the clock split.
    readonly property rect clockSlot: {
        if (!root.showClock || root.lineLength <= 0)
            return Qt.rect(0, 0, 0, 0);
        const w = root.scClockSize, h = root.scClockCross;
        return root.isHorizontal
            ? Qt.rect(root.centerLine - w / 2, root.lineCenter - h / 2, w, h)
            : Qt.rect(root.lineCross / 2 - h / 2, root.centerLine - w / 2, h, w);
    }

    // Clamped split offset – cannot push past half the clock-plus-gap span.
    readonly property real _maxSplitOffset:
        Math.max(0, clockHalf + scClockGap - scCornerExt - 4)
    readonly property real _splitOffset:
        Math.max(0, Math.min(splitOffset * sizeScale, _maxSplitOffset))

    // Where the straight main lines end and the bezier corners begin.
    readonly property real leftSplitPos: leftSectionEnd + _splitOffset
    readonly property real rightSplitPos: rightSectionStart - _splitOffset

    // THE SLOTS NEXT TO THE CLOCK SIT WHERE THE THREE RAILS LEAVE THEM EVENLY. The
    // groove forks at the split (`leftSplitPos`): the straight line goes on as two tracks, and the workspaces beside the clock are
    // round slots where the line and both tracks meet, three rails on one circle. The rule for where on the fork the slot
    // belongs: the same share of the round slot shows through each of the three spaces between two rails (the line and the upper
    // track, the two tracks -- the side of the clock's hole -- and the lower track and the line), so the ball, which sits in the
    // slot's middle, is centred among its rails. A slot on the fork's tip (where the tracks have just parted) would have the ball
    // leaning toward the clock: the tracks there are still one merged groove, and the open arc facing the clock is the wide one.
    // `_slotReach` finds, on the corner's own curves, the distance from the split at which the three arcs are equal, so it follows
    // every config (scale, track separation, corner, curve) -- and it does NOT depend on where the split is, so the clock giving room
    // for its seconds moves the slots and never re-solves it.
    //
    // The solve: a slot `u` px from the split is a circle of the dot's radius, the rails are bands of the line's width round their
    // centre lines (the line, ending at the split, and the two tracks); the circle's rim is walked in 2 degree steps and the runs
    // of rim no rail covers are the arcs. `bz` is a corner's curve, `mirror` the right corner (its offset runs the other way: from
    // the flat track back to the line).
    function _slotReach(bzUp, bzDown, mirror) {
        const hl = root.scLine / 2, rD = root.scDot / 2, sep = root.scTrackSep, ext = Math.max(1, root.scCornerExt);
        const step = 0.5;
        const xmax = ext + 2 * rD + 2 * hl + 4;
        const n = Math.ceil(xmax / step) + 1;
        // a track's centre line, as its distance from the line, at distance v from the split toward the clock
        const curve = bz => {
            const ys = new Array(n);
            for (let i = 0; i < n; i++) {
                const v = i * step;
                const f = v / ext;
                ys[i] = f >= 1 ? sep : sep * (mirror ? 1 - root._bezierEval(1 - f, bz[0], bz[1], bz[2], bz[3])
                                                     : root._bezierEval(f, bz[0], bz[1], bz[2], bz[3]));
            }
            return ys;
        };
        const ups = curve(bzUp), dns = curve(bzDown);
        const near = (ys, sgn, px, py) => {
            // is (px, py) within the band's half width of the polyline (x = i * step, y = sgn * ys[i])?
            const i0 = Math.max(0, Math.floor((px - hl) / step)), i1 = Math.min(n - 1, Math.ceil((px + hl) / step));
            for (let i = i0; i <= i1; i++) {
                const dx = i * step - px, dy = sgn * ys[i] - py;
                if (dx * dx + dy * dy <= hl * hl)
                    return true;
            }
            return false;
        };
        const NP = 180;
        const arcs = u => {
            const cov = new Array(NP);
            let any = false, all = true;
            for (let k = 0; k < NP; k++) {
                const a = 2 * Math.PI * k / NP;
                const px = u + rD * Math.cos(a), py = rD * Math.sin(a);
                // the line ends at the split (x = 0): left of it only the line is there
                const c = (px <= 0 && Math.abs(py) <= hl) || near(ups, -1, px, py) || near(dns, 1, px, py);
                cov[k] = c;
                any = any || c;
                all = all && c;
            }
            if (!any || all)
                return [];
            // runs of uncovered rim, cyclic from a covered sample
            const s0 = cov.indexOf(true);
            const out = [];
            let run = 0;
            for (let k = 1; k <= NP; k++) {
                if (!cov[(s0 + k) % NP]) {
                    run++;
                } else if (run > 0) {
                    out.push(run);
                    run = 0;
                }
            }
            return out.map(r => r * 2 * Math.PI / NP * rD);
        };
        const score = u => {
            const g = arcs(u);
            return g.length === 3 ? Math.max(g[0], g[1], g[2]) - Math.min(g[0], g[1], g[2]) : 1000 + Math.abs(g.length - 3);
        };
        // a coarse walk from the split to the corner's end, then the neighbourhood of the best step at a tenth of a pixel
        let best = 0, bestScore = Infinity;
        for (let u = 0; u <= ext; u += 1) {
            const sc = score(u);
            if (sc < bestScore) {
                bestScore = sc;
                best = u;
            }
        }
        const lo = Math.max(0, best - 1), hi = Math.min(ext, best + 1);
        for (let u = lo; u <= hi + 1e-9; u += 0.1) {
            const sc = score(u);
            if (sc < bestScore) {
                bestScore = sc;
                best = u;
            }
        }
        return best;
    }
    // How far from the split toward the clock the last slot of the left half / the first of the right half stand. No clock: 0.
    readonly property real _leftSlotReach: root.showClock ? root._slotReach(root.bezierTopLeft, root.bezierBottomLeft, false) : 0
    readonly property real _rightSlotReach: root.showClock ? root._slotReach(root.bezierTopRight, root.bezierBottomRight, true) : 0
    readonly property real _leftSlotEnd: root.showClock ? Math.min(root.leftSplitPos + root._leftSlotReach, root.centerLine - 1)
                                                        : root.leftSectionEnd
    readonly property real _rightSlotStart: root.showClock ? Math.max(root.rightSplitPos - root._rightSlotReach, root.centerLine + 1)
                                                           : root.rightSectionStart

    // Dot positions: first dot sits at leftSectionStart, last left dot on the
    // split's left tip, right-section mirrors (first right dot on the right
    // tip, last at rightSectionEnd). If either side has a single
    // dot, it anchors to the outer end so the line reads symmetrically.
    readonly property var dotPositions: {
        let positions = [];
        let n = totalDots;
        if (n === 0 || lineLength <= 0) return positions;

        function spread(start, end, count, anchorStart) {
            let out = [];
            if (count <= 0) return out;
            if (count === 1) {
                out.push(anchorStart ? start : end);
                return out;
            }
            let step = (end - start) / (count - 1);
            for (let i = 0; i < count; i++) out.push(start + i * step);
            return out;
        }

        if (!showClock) {
            let xs = spread(leftSectionStart, leftSectionEnd, n, true);
            for (let i = 0; i < xs.length; i++) positions.push(xs[i]);
            return positions;
        }

        let lxs = spread(leftSectionStart, root._leftSlotEnd, leftCount, true);
        for (let i = 0; i < lxs.length; i++) positions.push(lxs[i]);
        let rxs = spread(root._rightSlotStart, rightSectionEnd, rightCount, false);
        for (let i = 0; i < rxs.length; i++) positions.push(rxs[i]);
        const spreadF = Math.max(0, Math.min(1, root.lockSpread));
        if (spreadF > 0 && n > 2) {
            const a = positions[0], b = positions[n - 1];
            for (let i = 1; i < n - 1; i++)
                positions[i] += (a + (b - a) * i / (n - 1) - positions[i]) * spreadF;
        }
        return positions;
    }

    // Convenience bindings – fine for visuals that are read OUTSIDE of the
    // `onActiveWorkspaceIdChanged` signal handler path (ball `visible`, etc.).
    // Do NOT rely on these from within the reconcile path: QML does not
    // guarantee that derived bindings are re-evaluated before a changed-signal
    // handler runs, so reading them right after `activeWorkspaceId` changes
    // can return values from the *previous* workspace. The reconcile helpers
    // below use `_lookupIndexFor()` to compute fresh values instead.
    readonly property int activeIndex: _lookupIndexFor(activeWorkspaceId)

    function _lookupIndexFor(id) {
        let list = workspaceList;
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === id) return i;
        }
        return -1;
    }
    // ======================================================================
    // ANIMATION STATE
    //
    // THE BALL LIVES IN RAIL COORDINATES. Its place is
    // `ballRail`: a number in INDEX space -- 2 is the third workspace's slot, 2.5 half-way from it to the next -- and the pixel is
    // read from the CURRENT layout (`_posOf`) every time anything asks. The clock giving room for its seconds, a resize, a
    // changed pitch: the dots move and the ball, which is between them by the same fraction as before, goes with them in the same
    // frame. A pixel kept at a snap would have to be made good after a layout moved under a travelling or leaning ball, by a
    // deferred snap -- a teleport, with the track forgotten on the way.
    // ======================================================================
    property real progress: 1.0
    property real ballRail: -1000
    readonly property real ballPos: root._posOf(root.ballRail)
    property var animPath: []                     // waypoints of the trip, in index space
    property string crossingTrack: "main"        // "main" | "upper" | "lower"
    // The trip in the air is a CROSSING (one half of the groove to the other): its track is the trip's and a lean takes none until it has landed.
    // A trip between neighbours is not, and the lean may take its track while the ball is still on its way (`_leanTrack`).
    property bool tripCrosses: false
    // We track the active *workspace ID* (not the dot index) so the ball
    // stays glued to the right workspace even when the workspace list
    // grows or shrinks underneath us; `_lastIndex` is where that ID stood, to tell a list that moved it.
    property int _lastAnimatedId: -1
    property int _lastIndex: -1

    // The pixel (along the groove) of rail coordinate `r`: the dots are the whole numbers, a fraction is that share of the way to
    // the next dot (past either end, the end segment's pitch goes on: the swipe's lean past the last workspace). A whole number is
    // its dot EXACTLY (a + 1 * (b - a) is not always b).
    function _posOf(r) {
        const d = root.dotPositions, n = d.length;
        if (n === 0 || r < -100)
            return -1000;
        const w = Math.round(r);
        if (Math.abs(r - w) < 1e-9 && w >= 0 && w < n)
            return d[w];
        if (n === 1)
            return d[0];
        const i = Math.max(0, Math.min(n - 2, Math.floor(r)));
        return d[i] + (r - i) * (d[i + 1] - d[i]);
    }

    // ---- Particle Tracking ----------------------------------------------
    property real _lastBallX: -1000
    property real _lastBallY: -1000
    property real _lastEmitTime: 0

    onProgressChanged: {
        if (progress === 0 || progress === 1) {
            _lastBallX = -1000;
        }
        ballRail = _interpolatePath(progress, animPath);
        if (progress >= 1)
            root._leanTrack();
    }

    // where the ball's centre is (what the sparks leave from), at the place it has -- not at the swipe's lean
    readonly property var ballXY: root._ballCentreAt(root.ballPos)

    onBallXYChanged: {
        if (!progressAnim.running) return;

        let now = Date.now();
        if (_lastBallX === -1000) {
            _lastBallX = ballXY.along;
            _lastBallY = ballXY.across;
            _lastEmitTime = now;
            return;
        }

        let dt = Math.max(1, now - _lastEmitTime);
        let dx = ballXY.along - _lastBallX;
        let dy = ballXY.across - _lastBallY;

        let speed = Math.sqrt(dx*dx + dy*dy) / dt;

        if (speed > root.sparksSpeedThreshold && root.sparksEnabled) {
            let emCount = Math.floor(speed * root.sparksAmountMultiplier) + 1;
            let spSwirl = root.sparksSwirlStr;
            let spSwirlProb = root.sparksSwirlProb;

            for (let i = 0; i < emCount; i++) {
                let doSwirl = Math.random() < spSwirlProb;
                let swirlDir = Math.random() > 0.5 ? 1 : -1;

                let vxBase = (-dx / dt) * 1000;
                let vyBase = (-dy / dt) * 1000;

                particles.emit({
                    x: ballXY.along + root._reachX,
                    y: ballXY.across,
                    vx: vxBase * root.sparksBaseVelocity + (Math.random() - 0.5) * root.sparksScatter,
                    vy: vyBase * root.sparksBaseVelocity + (Math.random() - 0.5) * root.sparksScatter,
                    lifetime: root.sparksLifetimeBase + Math.random() * root.sparksLifetimeVariance,
                    maxHistory: root.sparksMaxHistory,
                    sizeStart: root.sizeScale * root.sparksSizeStart,
                    sizeEnd: root.sizeScale * root.sparksSizeEnd,
                    colorStart: root.sparksColorStart.toString(),
                    colorEnd: root.sparksColorEnd.toString(),
                    drag: root.sparksDrag,
                    forceField: (function(swirlMag, swirlEnabled, sDir) {
                        return function(px, py, t) {
                            var fx = 0;
                            var fy = 0;
                            if (swirlEnabled && t > 0.5 && swirlMag > 0) {
                                const sT = (t - 0.5) / 0.5;
                                fx += Math.cos(t * 15 * sDir) * swirlMag * sT * 1000;
                                fy += Math.sin(t * 15 * sDir) * swirlMag * sT * 1000;
                            }
                            return { x: fx, y: fy };
                        };
                    })(spSwirl, doSwirl, swirlDir)
                }, 1);
            }
        }

        _lastBallX = ballXY.along;
        _lastBallY = ballXY.across;
        _lastEmitTime = now;
    }
    // WHERE THE BALL IS DRAWN: its place, plus the swipe's lean (see THE SWIPE). At rest
    // and with no gesture it is `ballPos`.
    readonly property real ballDrawRail: root._leanedRail(root.ballRail, swipe.pull)
    readonly property real ballDrawPos: root._posOf(root.ballDrawRail)
    readonly property var ballShape: root._roundShape(root._ballShapeAt(root.ballDrawPos), root._roundF)
    // AT REST THE BALL IS ROUND. Once nothing moves the ball -- no move animation, no fingers pulling it -- its shape eases to round over
    // 160 ms; the next motion takes its own shape back at once (at a dot that shape is round anyway). This rule is about the
    // SQUISH (the width and height asked for). A ball bent at rest beside the clock after a
    // trip across it would be the OUTLINE following the side track under a ball that rests on the fork; that is handled where the
    // path is made (`_frameFor`, "THE BALL'S OWN PATH").
    readonly property bool _ballStill: root.progress >= 1 && root.swipePull === 0
    property real _roundF: 1
    on_BallStillChanged: {
        if (root._ballStill) {
            roundEase.restart();
        } else {
            roundEase.stop();
            root._roundF = 0;
        }
    }
    NumberAnimation {
        id: roundEase
        target: root
        property: "_roundF"
        to: 1
        duration: 160
        easing.type: Easing.OutCubic
    }
    function _roundShape(s, f) {
        if (f <= 0)
            return s;
        return { w: s.w + (root.scBall - s.w) * f, h: s.h + (root.scBall - s.h) * f };
    }

    // ======================================================================
    // PATH / BEZIER MATH
    // ======================================================================
    function _interpolatePath(p, path) {
        if (!path || path.length === 0) return root.activeIndex;
        if (path.length === 1) return path[0];

        let segs = path.length - 1;
        let segT = p * segs;
        let segIdx = Math.min(Math.floor(segT), segs - 1);
        let localT = segT - segIdx;

        // f(t) = 0.4·t + 0.6·smoothstep(t)  → slows near every waypoint
        // without actually stopping there.
        let smooth = localT * localT * (3 - 2 * localT);
        let easedT = 0.4 * localT + 0.6 * smooth;

        let a = path[segIdx];
        let b = path[segIdx + 1];
        return a + (b - a) * easedT;
    }

    // Evaluate a CSS cubic-bezier(x1, y1, x2, y2) at normalized x.
    // Endpoints are fixed at (0,0) and (1,1). Uses Newton's method.
    function _bezierEval(x, x1, y1, x2, y2) {
        if (x <= 0) return 0;
        if (x >= 1) return 1;
        let t = x;
        for (let i = 0; i < 8; i++) {
            let t2 = t * t;
            let mt = 1 - t;
            let mt2 = mt * mt;
            let bx = 3 * mt2 * t * x1 + 3 * mt * t2 * x2 + t2 * t;
            let dbx = 3 * mt2 * x1 + 6 * mt * t * (x2 - x1) + 3 * t2 * (1 - x2);
            if (Math.abs(dbx) < 1e-6) break;
            let dt = (bx - x) / dbx;
            t -= dt;
            if (Math.abs(dt) < 1e-5) break;
        }
        t = Math.max(0, Math.min(1, t));
        let t2 = t * t;
        let mt = 1 - t;
        let mt2 = mt * mt;
        return 3 * mt2 * t * y1 + 3 * mt * t2 * y2 + t2 * t;
    }

    // The point at along-line position `linePos` on `track` ("main" |
    // "upper" | "lower"): on the main line it is the line itself; on a side
    // track the corners are the bezier curves the groove is drawn with, so a
    // point here lies on the drawn centreline. Pure -- the fills use it for
    // tracks nobody is crossing.
    function _pointOn(linePos, track) {
        let along = linePos;
        let across = lineCenter;

        if (showClock && track !== "main") {
            let trackAcross = (track === "upper")
                ? (lineCenter - scTrackSepNow)
                : (lineCenter + scTrackSepNow);

            let cl = leftSplitPos;
            let cr = rightSplitPos;
            let entryEnd = cl + scCornerExt;
            let exitStart = cr - scCornerExt;

            if (linePos > cl && linePos < entryEnd) {
                // Left corner: bezier from (cl, lineCenter) → (entryEnd, trackAcross)
                let f = (linePos - cl) / scCornerExt;
                let bz = (track === "upper") ? bezierTopLeft : bezierBottomLeft;
                let y = _bezierEval(f, bz[0], bz[1], bz[2], bz[3]);
                across = lineCenter + (trackAcross - lineCenter) * y;
            } else if (linePos >= entryEnd && linePos <= exitStart) {
                across = trackAcross;
            } else if (linePos > exitStart && linePos < cr) {
                // Right corner: bezier from (exitStart, trackAcross) → (cr, lineCenter)
                // Parameterized so f=0 is at exitStart, f=1 is at cr.
                let f = (linePos - exitStart) / scCornerExt;
                let bz = (track === "upper") ? bezierTopRight : bezierBottomRight;
                let y = _bezierEval(f, bz[0], bz[1], bz[2], bz[3]);
                across = trackAcross + (lineCenter - trackAcross) * y;
            }
        }

        return { along: along, across: across };
    }

    // THE BALL'S OWN PATH. The ball is a pill whose
    // centre line is the groove's own centre line on the rail it is on -- the main line, or the upper / lower track of a crossing
    // (`crossingTrack`: which one is the TRIP's; a swipe's lean takes the track only when its step crosses). One source of truth:
    // `_pointOn`, the curve the groove is drawn with. Two things make it more than that, both a function of where the ball is and of
    // nothing it has to remember (`_frameFor`):
    //
    //   THE CENTRE LEAVES ITS SLOT ONTO THE RAIL. A slot is a round slot where three rails meet (`_slotReach`), not a point of any
    //   one rail: at the slot the ball's centre is the slot's centre (the line's), and over `scBall / 2` of travel it comes onto the
    //   rail's centre line and stays on it -- so the ball is in its groove all the way (a scaled-down copy of the track, a
    //   fraction of the track's offset, would leave it hanging in the hole between the tracks while it is a fraction of
    //   the way off its slot).
    //
    //   THE OUTLINE TAKES THE RAIL'S CURVATURE AS THE BALL LEAVES ITS ROUND: the pill's centre line is the tangent-less shape of the
    //   rail relative to the ball's centre, in the share `b` (0 at the slot, 1 a quarter of a ball's width away): a ball at rest is a straight
    //   pill -- round, however sharply the rails fork beside it -- and one on its way bends exactly as the groove does. `b` is about
    //   the shape only; the centre is on the rail either way.
    //
    // Off a crossing (the main line, or any x outside the span between the two slots) the rail is the line: nothing bends.
    function _railOffset(x, track) {
        return root._pointOn(x, track).across - root.lineCenter;
    }
    function _frameFor(xc, track) {
        if (!root.showClock || track === "main")
            return { track: "main", yc: 0, qc: 0, b: 0 };
        const tl = root._leftSlotEnd, tr = root._rightSlotStart;
        if (xc <= tl || xc >= tr)
            return { track: track, yc: 0, qc: root._railOffset(xc, track), b: 0 };
        const q = root._railOffset(xc, track);
        const ease = f => {
            const c = Math.max(0, Math.min(1, f));
            return c * c * (3 - 2 * c);
        };
        const reach = root.scBall / 2;
        // the centre: the rail's, less what the slot's own centre is off it, a share that fades over `reach` of travel from either slot
        const yc = q - root._railOffset(tl, track) * (1 - ease((xc - tl) / reach)) - root._railOffset(tr, track) * (1 - ease((tr - xc) / reach));
        // the outline's curvature: a quarter of a ball's width from the nearer slot -- the ball is as long as it is stretched, and it
        // stretches over `scBall / 2` (`_ballShapeAt`): a pill of that length that is still straight stands out of the fork
        const b = ease(Math.min(xc - tl, tr - xc) / (root.scBall / 4));
        return { track: track, yc: yc, qc: q, b: b };
    }
    // The point of the ball's path at along-line position `x`, for a ball whose centre is at `xc` (`frame`: its `_frameFor`).
    function _ballPointAt(x, frame) {
        if (frame.track === "main")
            return { along: x, across: root.lineCenter };
        return { along: x, across: root.lineCenter + frame.yc + frame.b * (root._railOffset(x, frame.track) - frame.qc) };
    }
    function _ballCentreAt(xc) {
        const f = root._frameFor(xc, root.crossingTrack);
        return root._ballPointAt(xc, f);
    }
    readonly property var _ballFrame: root._frameFor(root.ballDrawPos, root.crossingTrack)

    // Tangent angle (in degrees) of the ball's path at the given line position, for the ball at `_ballFrame`: what the outline
    // rotates by through the corners. 0 where the path is flat -- a ball at rest is not tilted.
    function _ballAngleAt(x, frame) {
        if (frame.track === "main" || frame.b === 0)
            return 0;
        const delta = 0.5;
        const p1 = root._ballPointAt(x - delta, frame);
        const p2 = root._ballPointAt(x + delta, frame);
        const dx = p2.along - p1.along;
        const dy = p2.across - p1.across;
        if (Math.abs(dx) < 1e-3 && Math.abs(dy) < 1e-3)
            return 0;
        return Math.atan2(dy, dx) * 180 / Math.PI;
    }

    function _ballShapeAt(linePos) {
        if (dotPositions.length === 0) return { w: scBall, h: scBall };

        let minDist = Infinity;
        for (let i = 0; i < dotPositions.length; i++) {
            let d = Math.abs(linePos - dotPositions[i]);
            if (d < minDist) minDist = d;
        }

        // When the ball is on the flat part of a side track, there are no
        // dots to relax to – force max compression.
        if (showClock && crossingTrack !== "main") {
            let cl = leftSplitPos;
            let cr = rightSplitPos;
            if (linePos > cl + scCornerExt && linePos < cr - scCornerExt) {
                minDist = Math.max(minDist, scDot);
            }
        }

        let relaxR = scBall / 2;
        let f = Math.min(1, minDist / relaxR);
        let s = f * f * (3 - 2 * f);              // smoothstep

        let h = scBall - (scBall - scLine) * s;
        // Ellipse area conservation: w · h = scBall² ⇒ stretching along
        // motion equals squishing perpendicular.
        let w = (scBall * scBall) / Math.max(h, 0.001);

        return { w: w, h: h };
    }

    // ======================================================================
    // ANIMATION TRIGGER
    //
    // _reconcile() is the single source of truth: it's called whenever the
    // active workspace ID *or* the list of workspaces changes. The handler decides
    // whether to snap silently (the list shifted under a static workspace) or
    // to animate (the user actually switched workspace). Tracking by ID
    // (not index) keeps the ball glued to the right workspace even when the
    // list grows or shrinks underneath us. A change of LAYOUT is not here: the ball
    // is a rail coordinate (see ANIMATION STATE), and the dots moving is a thing it
    // follows by being read from them.
    // ======================================================================
    onActiveWorkspaceIdChanged: _reconcile()
    // Deferred: the list is a binding evaluated lazily, and a reconcile run right there writes what the ball's bindings read.
    // Later, it also coalesces the several changes a Hyprland event makes into one.
    onWorkspaceListChanged: Qt.callLater(root._reconcile)
    // Not laid out yet: nothing to be on (and a read of `activeWorkspaceId` at creation, before the host's own value is applied, runs
    // its default binding and starts Hyprland's connection in a harness that has none). Asked again when it is.
    onLineLengthChanged: Qt.callLater(root._reconcile)

    function _reconcile() {
        if (lineLength <= 0) return;
        if (activeWorkspaceId < 0) return;

        const idx = _lookupIndexFor(activeWorkspaceId);
        if (idx < 0) return;                  // active workspace not in our list yet

        // First sighting → snap silently.
        if (_lastAnimatedId < 0) {
            _snapToActive();
            return;
        }

        // The user switched workspaces → animate from where the last trip ended.
        if (activeWorkspaceId !== _lastAnimatedId) {
            _kickAnimation();
            return;
        }

        // Same workspace, but the list moved it (a workspace opened before it) → snap silently to its new slot so the
        // ball stays attached to its workspace. A trip in the air is made good when it lands (below).
        if (!progressAnim.running && idx !== _lastIndex) {
            _snapToActive();
        }
    }

    function _snapToActive() {
        let idx = _lookupIndexFor(activeWorkspaceId);
        progressAnim.stop();
        animPath = [idx];
        ballRail = idx;
        progress = 1;
        _lastAnimatedId = activeWorkspaceId;
        _lastIndex = idx;
        // A lean in the air keeps the track its step takes (the layout moving or a list changing must not turn it).
        root.tripCrosses = false;
        if (root.swipePull === 0)
            crossingTrack = "main";
        else
            root._leanTrack();
    }

    // A TRIP THAT IS INTERRUPTED RESTARTS FROM THE WORKSPACE IT WAS ON. A new trip started from wherever the ball is
    // would go wrong for a ball in the middle of a crossing (on a side track, between the two halves): it is neither side of the clock, so the trip
    // would be judged "not a crossing", take the main line and cut straight through the clock's hole. So the ball is TELEPORTED to the
    // workspace the change was made from -- where the interrupted trip was going; at rest, where it already is -- and the new trip
    // is a whole, true one from there: no queue, so nothing builds up, and the ball is always on a track it knows. The jump draws no
    // sparks: the emission follows the ball's own speed and re-seeds from where the new trip starts (`_lastBallX`, below), so a jump
    // is not a speed.
    function _kickAnimation() {
        const from = _lookupIndexFor(_lastAnimatedId);
        const to = _lookupIndexFor(activeWorkspaceId);
        // The old trip ends BEFORE anything of the new one is written: the track and the path change under the ball, and with the
        // old animation still running a write in between would show as a jump the sparks follow.
        progressAnim.stop();
        _lastBallX = -1000;
        if (from < 0 || from === to) {
            _snapToActive();
            return;
        }

        const dir = (to >= from) ? 1 : -1;
        // one half of the groove to the other: the step between the last slot of the left half and the first of the right
        const crossing = showClock && ((from < leftCount && to >= leftCount) || (from >= leftCount && to < leftCount));

        if (crossing) {
            crossingTrack = (dir > 0)
                ? (invertTracks ? "upper" : "lower")
                : (invertTracks ? "lower" : "upper");
        } else {
            crossingTrack = "main";
        }
        tripCrosses = crossing;
        if (!crossing)
            root._leanTrack();

        // A TRIP ACROSS THE CLOCK STARTS WHERE THE LEANED BALL IS. The fingers drew the ball `pull` of the way along the step; a trip between
        // neighbours is drawn as its rail plus that pull, which springs home, so it carries on from there by itself. A crossing's rail
        // takes no pull (`_leanedRail`: the lean would carry it past the slot it lands on), so the lean drops at the first frame -- the ball
        // jumped back to the slot it had left -- unless the trip begins where the ball is drawn. A pull against the step (the spring's
        // overshoot, a keybind in the middle of a gesture) is no lean of this step.
        const lean = (crossing && swipe.pull * dir > 0) ? Math.min(Math.abs(swipe.pull), 1) * dir : 0;

        // every slot on the way, one after the other: the trip eases in and out of each
        const waypoints = [from + lean];
        for (let i = from + dir; i !== to; i += dir)
            waypoints.push(i);
        waypoints.push(to);
        animPath = waypoints;
        _lastAnimatedId = activeWorkspaceId;
        _lastIndex = to;
        progress = 0;
        progressAnim.start();
    }

    NumberAnimation {
        id: progressAnim
        target: root
        property: "progress"
        from: 0
        to: 1
        duration: root.animationDuration
        easing.type: Easing.OutQuart
    }

    // A trip that ended while the layout moved under it (the dots shifted during the ball's run) is made good once it is over.
    Connections {
        target: progressAnim
        function onRunningChanged() {
            if (!progressAnim.running)
                Qt.callLater(root._reconcile);
        }
    }

    Component.onCompleted: _reconcile()

    // ======================================================================
    // FOCUSING A WORKSPACE (what a click on a dot does)
    //
    // Hyprland's config is Lua, and `Hyprland.dispatch(x)` is `hl.dispatch(x)`:
    // it takes a Lua EXPRESSION (a bare `workspace 2` is a syntax error that
    // only warns and does nothing). A workspace is shown on the FOCUSED monitor,
    // and one table cannot name both -- `focus({ monitor, workspace })` does the
    // monitor and ignores the workspace -- so a click is two dispatches, monitor
    // first. The monitor's focus WARPS the pointer to its centre, so it is sent
    // only when this bar's monitor is not the focused one already (a click on a
    // bar normally comes from a pointer that is on its monitor, which
    // focus-follows-mouse has focused). Focusing the workspace a monitor
    // already shows changes nothing (no go-back toggle with
    // binds:workspace_back_and_forth off), so no guard.
    // ======================================================================
    function _luaFocusMonitor(monitorName) {
        return 'hl.dsp.focus({ monitor = "' + String(monitorName).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '" })';
    }
    function _luaFocusWorkspace(id) {
        return "hl.dsp.focus({ workspace = " + Math.floor(id) + " })";
    }
    function _send(luaExpression) {
        if (root.dispatcher)
            root.dispatcher(luaExpression);
        else
            Hyprland.dispatch(luaExpression);
    }
    function _focusedMonitorName() {
        if (root.focusSource)
            return root.focusSource.name;
        return Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : "";
    }
    // The ONE place the two forms are sent from. A monitor "" leaves the monitor alone; a workspace < 1
    // (a special or named workspace has no number to ask for) leaves the workspace alone.
    function _focus(monitorName, workspaceId) {
        if (monitorName !== "")
            root._send(root._luaFocusMonitor(monitorName));
        if (workspaceId >= 1)
            root._send(root._luaFocusWorkspace(workspaceId));
    }
    // Focus workspace `id` on this bar's monitor.
    function focusWorkspace(id) {
        const mon = root.screenName;
        root._focus(mon !== "" && root._focusedMonitorName() !== mon ? mon : "", id);
    }

    // ======================================================================
    // THE SWIPE
    //
    // `swipe` counts the wheel units and says when a workspace is stepped to; the
    // reader below feeds it. A step is a CLICK on the dot it lands on (`focusWorkspace`:
    // the monitor first only when it is not the focused one), and the ball then travels
    // as for any switch. The compositor answers a step a few milliseconds late, which
    // the engine allows for (it counts from where it ordered) -- a flick across three
    // workspaces sends three.
    //
    // THE LEAN. While the fingers are down the engine's rubber band is a fraction of
    // a dot pitch toward the next workspace; the ball is drawn that far along its
    // line (and stretches as it does between two dots), and springs home when the
    // fingers lift short of a step. It leans only within its own half of the groove, and a dot's width onto the corner toward the clock:
    // across the clock the ball takes the side track, which nothing leans along.
    // ======================================================================
    SwipeSteps {
        id: swipe
        count: root.workspaceList.length
        index: root.activeIndex
        onStepped: (dir, to) => {
            const ws = root.workspaceList[to];
            if (ws)
                root.focusWorkspace(ws.id);
        }
    }

    // The ball that leans toward the clock takes, as it begins to, the side track its next travel would: `crossingTrack` is the
    // track of the LAST travel and would otherwise bend a lean to the right onto the track the ball came back along. ONLY for a
    // step that crosses -- from the last slot of the left half to the right, or back: a lean toward a neighbour in its own half
    // is on the main line whatever the last trip did (going from 2 to 1, the lean toward 1 would otherwise take the upper track
    // because it leans to the left, and the back of the ball would curve toward the wrong split).
    //
    // IT IS ASKED WHEN THE BALL LANDS TOO. The lean builds while the ball is still
    // in the air, and a lean that is steady when the ball lands -- fingers resting -- never changes `swipePull` again, so nothing would ask: the ball
    // would stand leaning toward the clock with the track of its LAST trip ("main" after a step between neighbours) and be drawn straight along the
    // line through the clock's hole, between the two tracks, until the next change of the pull. So the track is asked when a trip between
    // NEIGHBOURS begins, whenever the pull changes (in the air too: that trip's own track is the main line, which the lean leaves on its way to the
    // clock), at the landing (`progress` reaching 1) and at a snap. A trip ACROSS the clock keeps its own track until it has landed (`tripCrosses`).
    //
    // (Keeping a travelling ball out of the hole instead would hold it at the slot beside the clock for as long as the
    // trip's OutQuart tail lasts -- 270 ms in which `progress` is not 1 and the ball has long landed -- while the fingers go on.)
    onSwipePullChanged: root._leanTrack()
    function _leanTrack() {
        if (!root.showClock || (root.tripCrosses && root.progress < 1) || root.swipePull === 0)
            return;
        // read fresh: from `_kickAnimation` (a change handler of the workspace) the derived `activeIndex` is still the previous slot's
        const i = root._lookupIndexFor(root.activeWorkspaceId);
        const toRight = root.swipePull > 0;
        const crosses = toRight ? i === root.leftCount - 1 : i === root.leftCount;
        root.crossingTrack = crosses ? (toRight ? (root.invertTracks ? "upper" : "lower") : (root.invertTracks ? "lower" : "upper")) : "main";
    }

    // THE LEAN IS THE SAME SHARE OF ITS STEP WHEREVER THE STEP GOES. Leaning at most a dot's width onto the corner would be
    // 11 px of a 95 px step: the ball would reach it a third of the way through the swipe and stand still against it while the fingers
    // went on, which is a wall. It leans `pull` of the way across, as every other dot leans `pull` of the way to the next -- which
    // in rail coordinates is no arithmetic at all: the lean is `pull` slots, and the pixel is read from the layout as it stands.
    // A ball between the two halves (on its way across) takes no lean, nor does one in the air on a crossing's track.
    function _leanedRail(r, pull) {
        if (pull === 0 || r < -100)
            return r;
        const d = root.dotPositions, n = d.length;
        if (n < 2)
            return r;
        if (root.showClock) {
            // `crossingTrack` outlives the crossing: it is the track the LAST travel took
            if (root.tripCrosses && root.progress < 1)
                return r;
            if (root.leftCount > 0 && root.rightCount > 0 && r > root.leftCount - 1 + 1e-6 && r < root.leftCount - 1e-6)
                return r;
        }
        // as far as half a dot past the first / last slot
        const lo = -(root.scDot / 2) / Math.max(1, d[1] - d[0]);
        const hi = n - 1 + (root.scDot / 2) / Math.max(1, d[n - 1] - d[n - 2]);
        return Math.max(lo, Math.min(hi, r + pull));
    }

    // THE STEP ACROSS THE CLOCK TAKES MORE TRAVEL: the steps between neighbours are a dot pitch long and the one across
    // the clock more than twice that, and the engine counts the same units for each -- so the long step would come as soon as the short
    // ones do. The threshold the engine reads is `swipeCrossFactor` times its own for a gesture that would take that step.
    // (The engine's own number is read once; this host never writes a literal of it.)
    property real swipeCrossFactor: 2.0
    property real _swipeBase: 0
    function _stepThreshold(dir) {
        if (root._swipeBase <= 0)
            root._swipeBase = swipe.threshold;
        // a gesture that has begun keeps its direction (the units held), a new one takes its first delta's
        const d = swipe.accum !== 0 ? (swipe.accum > 0 ? 1 : -1) : dir;
        const from = swipe._base();
        const across = root.showClock && ((d > 0 && from === root.leftCount - 1) || (d < 0 && from === root.leftCount));
        swipe.threshold = root._swipeBase * (across ? Math.max(1, root.swipeCrossFactor) : 1);
    }

    // One wheel event (WheelHub's), as the reader hears it. A MOUSE: one notch is one workspace, rolled or tilted, whatever the threshold
    // says. FINGERS: the axis a gesture is on is picked once one is clearly ahead (1.2x) and kept until
    // the fingers lift -- a two-finger scroll is never one axis, and a vertical one with a
    // few degrees of drift must not creep the ball. A zero delta on both axes is the
    // fingers lifting (libinput's scroll-end), which is what releases the band.
    property string _swipeAxis: ""           // "" until one leads | "along" | "across"
    function _swipeWheel(ev) {
        const ad = ev.angleDelta, pd = ev.pixelDelta;
        if (ev.device === "wheel") {
            swipe.notch(ev.steps);
            return;
        }
        const along = root.isHorizontal ? ad.x : ad.y;
        const across = root.isHorizontal ? ad.y : ad.x;
        const pAlong = root.isHorizontal ? pd.x : pd.y;
        const pAcross = root.isHorizontal ? pd.y : pd.x;
        // The tab selector's reading: the angle where there is one, else the pixels, scaled.
        const dx = along !== 0 ? along : pAlong * 2.5;
        const dy = across !== 0 ? across : pAcross * 2.5;
        if (dx === 0 && dy === 0) {
            root._swipeAxis = "";
            swipeAxisIdle.stop();
            swipe.feed(0);
            return;
        }
        swipeAxisIdle.restart();
        if (root._swipeAxis === "") {
            if (Math.abs(dx) > Math.abs(dy) * 1.2)
                root._swipeAxis = "along";
            else if (Math.abs(dy) > Math.abs(dx) * 1.2)
                root._swipeAxis = "across";
            else
                return;
        }
        if (root._swipeAxis !== "along" || dx === 0)
            return;
        root._stepThreshold(dx > 0 ? 1 : -1);
        swipe.feed(dx);
    }
    // For a device that never sends the lift: the next gesture picks its axis afresh.
    Timer {
        id: swipeAxisIdle
        interval: 260
        onTriggered: root._swipeAxis = ""
    }

    // The reader: takes no buttons and never accepts the event, so it only observes -- the
    // dots under it keep their clicks and the wheel still reaches whatever is behind.
    WheelArea {
        id: swipeArea
        anchors.fill: parent
        turned: wheel => {
            root._swipeWheel(wheel);
            wheel.accepted = false;
        }
    }

    // ======================================================================
    // THE CARVE (modules/common/components/CarvedPath.js)
    // ======================================================================
    function _carveGeometry() {
        return {
            bw: root.grooveBevelWidth * root.sizeScale,
            sw: root.grooveShadowWidth * root.sizeScale,
            halfLine: root.scLine / 2,
            halfDot: root.scDot / 2
        };
    }
    readonly property var _groovePalette: ({
            surface: root.surfaceColor,
            bevel: root.grooveBevelColor,
            shadow: root.grooveShadowColor,
            core: root.grooveColor,
            bevelEasing: root.grooveBevelEasing,
            shadowEasing: root.grooveGradientEasing
        })

    // Adds the groove's centreline to the current path: the straight line
    // (or its two halves and the two side tracks around the clock).
    function _traceGroove(ctx) {
        // With the lids shut the tracks lie on each other, and two identical strokes in one path ADD their antialiased edges: the closed stretch would come out
        // 0.6 px thicker than the line beside it, a step at each old split tip once the slots have left them. One rail is one line.
        if (!root.showClock || root.scTrackSepNow <= 0) {
            ctx.moveTo(root.leftSectionStart, root.lineCenter);
            ctx.lineTo(root.rightSectionEnd, root.lineCenter);
            return;
        }
        ctx.moveTo(root.leftSectionStart, root.lineCenter);
        ctx.lineTo(root.leftSplitPos, root.lineCenter);
        ctx.moveTo(root.rightSplitPos, root.lineCenter);
        ctx.lineTo(root.rightSectionEnd, root.lineCenter);

        let co = root.scCornerExt;
        let cl = root.leftSplitPos;
        let cr = root.rightSplitPos;
        let cy = root.lineCenter;

        let tsTop = root.scTrackSepNow * -1;
        ctx.moveTo(cl, cy);
        ctx.bezierCurveTo(
            cl + root.bezierTopLeft[0] * co, cy + root.bezierTopLeft[1] * tsTop,
            cl + root.bezierTopLeft[2] * co, cy + root.bezierTopLeft[3] * tsTop,
            cl + co, cy + tsTop
        );
        ctx.lineTo(cr - co, cy + tsTop);
        ctx.bezierCurveTo(
            cr - co + root.bezierTopRight[0] * co, cy + tsTop + root.bezierTopRight[1] * (-tsTop),
            cr - co + root.bezierTopRight[2] * co, cy + tsTop + root.bezierTopRight[3] * (-tsTop),
            cr, cy
        );

        let tsBot = root.scTrackSepNow * +1;
        ctx.moveTo(cl, cy);
        ctx.bezierCurveTo(
            cl + root.bezierBottomLeft[0] * co, cy + root.bezierBottomLeft[1] * tsBot,
            cl + root.bezierBottomLeft[2] * co, cy + root.bezierBottomLeft[3] * tsBot,
            cl + co, cy + tsBot
        );
        ctx.lineTo(cr - co, cy + tsBot);
        ctx.bezierCurveTo(
            cr - co + root.bezierBottomRight[0] * co, cy + tsBot + root.bezierBottomRight[1] * (-tsBot),
            cr - co + root.bezierBottomRight[2] * co, cy + tsBot + root.bezierBottomRight[3] * (-tsBot),
            cr, cy
        );
    }

    // ======================================================================
    // PROGRESS FILLS
    //
    // Painted as a MASK first (the filled stretch of each piece, its convex
    // head, the dots it has passed), then `source-in` the surface over the
    // whole canvas, then `source-in` the carve in the tone's palette: the
    // result is the groove itself, recoloured, cut to the mask, with exactly
    // one antialiased edge -- the head. (`destination-in` does nothing in Qt's
    // canvas: QPainter only composites where the new shape paints.)
    // ======================================================================
    function _fillNowMs() {
        return root.fillClock ? root.fillClock.now() : Date.now();
    }

    // The sub-pieces a piece is made of, each with its x range. An end that
    // is the bar's outer end is extended to where the GROOVE ends there: the slot at the end is a dot, wider than the line, so the
    // groove's outer end is the dot's edge and not the line's round cap (a stretch starting at the cap, 2-3 px inside the dot,
    // would leave the dot's own left edge before the start of the fill, so a fill that had hardly begun would already colour that
    // side of the first slot). A fraction of 0 is nothing and of 1 the whole groove, round cap and dot
    // and all.
    function _subPieces(piece) {
        const hl = root.scLine / 2;
        const ext = Math.max(hl, root.scDot / 2 + root.grooveBevelWidth * root.sizeScale);
        const L0 = root.leftSectionStart, R1 = root.rightSectionEnd;
        const main = (a, b, oa, ob) => ({ track: "main", x0: a - (oa ? ext : 0), x1: b + (ob ? ext : 0) });
        if (!root.showClock) {
            if (piece < 0)
                return [main(L0, R1, true, true)];
            const q = (R1 - L0) / 4;
            return [main(L0 + piece * q, L0 + (piece + 1) * q, piece === 0, piece === 3)];
        }
        const sl = root.leftSplitPos, sr = root.rightSplitPos;
        // The straight lines run on to the slots beside the clock (the split's tips, a few px past where the fork begins): the dot
        // there is the last of its line, and a full line colours it. Over that stretch the line's band lies inside
        // the two tracks' merged groove, which is also what the tracks' pieces cover from `sl`.
        const ll = Math.max(sl, root._leftSlotEnd), rr = Math.min(sr, root._rightSlotStart);
        const upper = { track: "upper", x0: sl, x1: sr };
        const lower = { track: "lower", x0: sl, x1: sr };
        switch (piece) {
        case 0: return [main(L0, ll, true, false)];
        case 1: return [upper];
        case 2: return [main(rr, R1, false, true)];
        case 3: return [lower];
        }
        return [main(L0, ll, true, false), upper, lower, main(rr, R1, false, true)];
    }

    // The fills as they stand at `now`: per entry, the covered x interval and
    // which end carries the head.
    function _fillFrame(now) {
        const out = [];
        const list = (root.fills || []).concat(root._breakFills);
        for (let i = 0; i < list.length; i++) {
            const f = list[i];
            let to = f.to1;
            if (f.t1 > f.t0) {
                const u = Math.max(0, Math.min(1, (now - f.t0) / (f.t1 - f.t0)));
                // `ease: "outCubic"` is the break nudge's beat: the head glides to its place instead of creeping.
                to = f.to0 + (f.to1 - f.to0) * (f.ease === "outCubic" ? 1 - Math.pow(1 - u, 3) : u);
            }
            else if (f.t0 === f.t1 && f.to0 !== undefined)
                to = now < f.t0 ? f.to0 : f.to1;
            const a = Math.max(0, Math.min(1, f.from || 0)), b = Math.max(0, Math.min(1, to));
            if (b <= a)
                continue;
            const subs = root._subPieces(f.piece);
            const x0 = subs[0].x0, x1 = subs[subs.length - 1].x1;
            const xs = f.reverse ? x1 - b * (x1 - x0) : x0 + a * (x1 - x0);
            const xe = f.reverse ? x1 - a * (x1 - x0) : x0 + b * (x1 - x0);
            out.push({ tone: f.tone || 0, piece: f.piece, subs: subs, xs: xs, xe: xe, reverse: !!f.reverse,
                       head: b < 1 });
        }
        return out;
    }

    // The head's centre point and tangent angle (radians) on a track.
    function _frameAt(x, track) {
        const p = root._pointOn(x, track);
        const q1 = root._pointOn(x - 0.5, track), q2 = root._pointOn(x + 0.5, track);
        return { x: p.along, y: p.across, a: Math.atan2(q2.across - q1.across, q2.along - q1.along) };
    }

    // The x span of dot `cx` the mask covers for a stretch [a, b] of sub-piece
    // `sp` (heads at its low / high end), or null when the dot is not on the
    // stretch at all. A stretch's own ends cut nothing -- but only the dots
    // that actually meet the stretch: a dot past its end is not on it.
    function _dotSpan(sp, a, b, headLo, headHi, cx, rDot, dDepth) {
        if (cx + rDot <= a || cx - rDot >= b)
            return null;
        const lo = headLo ? a + dDepth : (a <= sp.x0 + 1e-6 ? cx - rDot : a);
        const hi = headHi ? b - dDepth : (b >= sp.x1 - 1e-6 ? cx + rDot : b);
        const tipHi = headHi ? b : hi, tipLo = headLo ? a : lo;
        if (Math.min(tipHi, cx + rDot) <= Math.max(tipLo, cx - rDot))
            return null;
        return [lo, hi];
    }

    function _maskEntry(ctx, e) {
        const hl = root.scLine / 2;
        const bw = root.grooveBevelWidth * root.sizeScale;
        const depth = Math.max(0, root.fillHeadBulge) * hl;
        const rDot = root.scDot / 2 + bw;
        for (let k = 0; k < e.subs.length; k++) {
            const sp = e.subs[k];
            const a = Math.max(e.xs, sp.x0), b = Math.min(e.xe, sp.x1);
            if (b <= a)
                continue;
            // Which ends of this stretch are the fill's head: the moving end,
            // where it falls inside this sub-piece.
            const headHi = e.head && !e.reverse && e.xe <= sp.x1 + 1e-6;
            const headLo = e.head && e.reverse && e.xs >= sp.x0 - 1e-6;
            let s0 = headLo ? a + depth : a, s1 = headHi ? b - depth : b;
            // The body: a butt-capped band as wide as the carve with its rim.
            ctx.lineWidth = 2 * (hl + bw);
            ctx.lineCap = "butt";
            if (s1 > s0) {
                ctx.beginPath();
                if (sp.track === "main") {
                    ctx.moveTo(s0, root.lineCenter);
                    ctx.lineTo(s1, root.lineCenter);
                } else {
                    const n = Math.max(1, Math.ceil(s1 - s0));
                    for (let j = 0; j <= n; j++) {
                        const p = root._pointOn(s0 + (s1 - s0) * j / n, sp.track);
                        if (j === 0) ctx.moveTo(p.along, p.across);
                        else ctx.lineTo(p.along, p.across);
                    }
                }
                ctx.stroke();
            }
            // The convex head, in the tangent frame of the point it grows from.
            const heads = [];
            if (headHi) heads.push({ c: b - depth, dir: 1 });
            if (headLo) heads.push({ c: a + depth, dir: -1 });
            for (const h of heads) {
                if (depth <= 0.01)
                    continue;
                const fr = root._frameAt(h.c, sp.track);
                ctx.save();
                ctx.translate(fr.x, fr.y);
                ctx.rotate(fr.a);
                ctx.beginPath();
                ctx.ellipse(-depth, -hl, 2 * depth, 2 * hl);
                ctx.fill();
                ctx.restore();
            }
            // The dots on this stretch: whole when passed; while the head
            // crosses one, cut by the same bulge at the dot's size, so the
            // wider part of the carve keeps a convex edge too. A stretch's own
            // ends (the bar's outer end, a junction) cut nothing.
            if (sp.track !== "main")
                continue;
            const dDepth = Math.max(0, root.fillHeadBulge) * rDot;
            const cy = root.lineCenter;
            const dots = root.dotPositions;
            for (let j = 0; j < dots.length; j++) {
                const cx = dots[j];
                // Both curves end on the same tip as the line's head.
                const span = root._dotSpan(sp, a, b, headLo, headHi, cx, rDot, dDepth);
                if (!span)
                    continue;
                const lo = span[0], hi = span[1];
                // THE DOT IS PAINTED ONCE PER PIECE OF ITS CLIP (the stretch's rect, then each head's ellipse), never through one clip path
                // holding both: a canvas clip is the path's NONZERO fill, and Qt draws the rect and the ellipse in opposite directions, so
    // where they overlap the winding is 0 -- a hole in the clip. The line's band covers the dot's middle rows, so the hole
    // shows only at the slot's top and bottom rows, and only while the front crosses the dot: the pixel's colour falls to
    // nothing and comes back when the rect has left the ellipse behind.
                const clips = [(c) => c.rect(lo, cy - rDot, Math.max(0, hi - lo), 2 * rDot)];
                if (headHi && dDepth > 0.01)
                    clips.push((c) => c.ellipse(hi - dDepth, cy - rDot, 2 * dDepth, 2 * rDot));
                if (headLo && dDepth > 0.01)
                    clips.push((c) => c.ellipse(lo - dDepth, cy - rDot, 2 * dDepth, 2 * rDot));
                for (const shape of clips) {
                    ctx.save();
                    ctx.beginPath();
                    shape(ctx);
                    ctx.clip();
                    ctx.beginPath();
                    ctx.arc(cx, cy, rDot, 0, Math.PI * 2);
                    ctx.fill();
                    ctx.restore();
                }
            }
        }
    }

    // `entries` is a leaving fill's last picture (a ghost); without it the canvas shows what is shown now.
    function _paintFill(ctx, tone, w, h, entries, strength) {
        const frame = entries !== undefined ? entries : root._fillShown;
        if (entries === undefined)
            root.fillStats.paints += 1;
        let any = false;
        ctx.fillStyle = "#ffffff";
        ctx.strokeStyle = "#ffffff";
        for (let i = 0; i < frame.length; i++) {
            if (frame[i].tone !== tone)
                continue;
            root._maskEntry(ctx, frame[i]);
            any = true;
        }
        if (!any)
            return;
        ctx.globalCompositeOperation = "source-in";
        ctx.fillStyle = root.surfaceColor;
        ctx.fillRect(0, 0, w, h);
        const tint = root.fillToneColors[tone];
        const dots = root.dotPositions;
        // ONLY THE INSET TAKES THE COLOUR: the carve is painted again over the filled stretch with the groove's own core and the
        // tone's shade as its shadow, so the rail's background under the fill is the very colour it was.
        const geo = root._carveGeometry();
        geo.sw *= Math.max(0.01, root.fillShadowWiden);
        CarvedPath.paintCarve(ctx, geo, {
            surface: root.surfaceColor,
            bevel: root.grooveBevelColor,
            shadow: CarvedPath.lerpColor(root.grooveShadowColor, Qt.darker(tint, root.fillShadowDarken), Math.max(0, strength === undefined ? root._fillStrengthNow : strength)),
            core: root.grooveColor,
            bevelEasing: root.grooveBevelEasing,
            shadowEasing: root.grooveGradientEasing
        }, function (ctx, rLine, rDot) {
            if (rLine > 0) {
                ctx.lineWidth = rLine * 2;
                ctx.beginPath();
                root._traceGroove(ctx);
                ctx.stroke();
            }
            if (rDot > 0) {
                ctx.beginPath();
                for (let j = 0; j < dots.length; j++) {
                    ctx.moveTo(dots[j] + rDot, root.lineCenter);
                    ctx.arc(dots[j], root.lineCenter, rDot, 0, Math.PI * 2);
                }
                ctx.fill();
            }
        });
    }

    // Calm dust off a piece (-1: the whole bar) in a tone's colour: particles
    // spread along the piece's own path -- the tracks included -- drifting
    // slowly off it and fading. Nothing like the ball's sparks: no speed, no
    // trail, no swirl.
    // The full burst: the flash of the piece's fill, the dust, and a finer second wave a beat later.
    function burst(piece, tone) {
        const p = piece === undefined ? -1 : piece;
        root._flash(p, tone || 0);
        root._dust(p, tone, root.burstCount, 1);
        if (root.burstSecondWave > 0) {
            root._wave = { piece: p, tone: tone };
            secondWave.interval = Math.max(1, root.burstSecondDelayMs);
            secondWave.restart();
        }
    }
    property var _wave: null
    Timer {
        id: secondWave
        repeat: false
        onTriggered: if (root._wave)
            root._dust(root._wave.piece, root._wave.tone, Math.round(root.burstCount * root.burstSecondWave), 1.6)
    }
    function _dust(piece, tone, count, rise) {
        const subs = root._subPieces(piece);
        const col = root.fillToneColors[tone || 0] || root.fillToneColors[0];
        const lens = subs.map(sp => Math.max(0, Math.min(sp.x1, root.rightSectionEnd) - Math.max(sp.x0, root.leftSectionStart)));
        const total = lens.reduce((a, b) => a + b, 0);
        if (total <= 0)
            return;
        for (let i = 0; i < count; i++) {
            let r = Math.random() * total, k = 0;
            while (k < subs.length - 1 && r > lens[k]) {
                r -= lens[k];
                k++;
            }
            const sp = subs[k];
            const p = root._pointOn(Math.max(sp.x0, root.leftSectionStart) + r, sp.track);
            const up = Math.random() < 0.5 ? -1 : 1;
            dust.emit({
                x: p.along + root._reachX + (Math.random() - 0.5) * 2,
                y: p.across + up * root.scLine * 0.3 * Math.random(),
                vx: (Math.random() - 0.5) * 10,
                vy: up * (6 + Math.random() * root.burstRise * rise),
                lifetime: root.burstLifetimeMs * (0.7 + Math.random() * 0.5),
                maxHistory: 1,
                sizeStart: root.sizeScale * 2.2,
                sizeEnd: root.sizeScale * 0.6,
                colorStart: col.toString(),
                colorEnd: "transparent",
                drag: 1.2,
                deathFadeFraction: 0.5
            }, 1);
        }
    }

    // What the fill canvases are showing, and the scheduler that moves it.
    // Only a moving end asks for another paint, at the moment it will have
    // moved fillQuantumPx; nothing runs while every fill is still, and
    // nothing moves while the theme crossfades (the fade is a still picture
    // of the frame before; anything moving under it shows twice).
    property var _fillShown: []

    function _refreshFills(force) {
        if (Theme.crossfading && !force) {
            fillTimer.stop();
            return;
        }
        const now = root._fillNowMs();
        const frame = root._fillFrame(now);
        // Which tones moved: only their canvases repaint. Counted over the
        // TONES, not the canvases: fills set at construction arrive before
        // the canvases exist, and must still be remembered for their first
        // paint.
        const moved = [];
        for (let t = 0; t < root.fillToneColors.length; t++) {
            const cur = frame.filter(e => e.tone === t);
            const old = root._fillShown.filter(e => e.tone === t);
            let m = force ? (cur.length > 0 || old.length > 0) : cur.length !== old.length;
            for (let i = 0; !m && i < cur.length; i++) {
                if (Math.abs(cur[i].xs - old[i].xs) >= root.fillQuantumPx
                        || Math.abs(cur[i].xe - old[i].xe) >= root.fillQuantumPx
                        || cur[i].head !== old[i].head)
                    m = true;
            }
            if (m)
                moved.push(t);
        }
        if (moved.length > 0) {
            // What was shown and this frame no longer has fades out, one picture per tone.
            root._fadeOut(root._fillShown.filter(old => !frame.some(e => e.piece === old.piece && e.tone === old.tone)));
            root._fillShown = frame;
            root.fillStats.refreshes += 1;
            for (const t of moved) {
                const c = fillCanvases.itemAt(t);
                if (c)
                    c.requestPaint();
            }
        }
        root._scheduleFills(now);
    }

    // THE FADE OF A LEAVING FILL. Its last picture is painted ONCE into a canvas of its own and the
    // canvas's opacity does the fade (a scene-graph property: no repaint per frame, and a repaint is
    // a redraw of the whole window), above the groove and below the live fills. One canvas per tone
    // that left something; a ListModel keeps the delegates of a second removal from restarting the
    // first one's fade. A piece with nothing in it (a drain at its end) leaves no ghost.
    property var _ghostEntries: ({})
    property int _ghostSerial: 0
    function _fadeOut(entries) {
        if (root.fillFadeMs <= 0)
            return;
        const byTone = {};
        for (const e of entries) {
            if (e.xe - e.xs < 1)
                continue;
            (byTone[e.tone] = byTone[e.tone] || []).push(e);
        }
        for (const t in byTone) {
            const gid = ++root._ghostSerial;
            root._ghostEntries[gid] = byTone[t];
            ghostModel.append({ gid: gid, tone: Number(t), strength: -1, ms: root.fillFadeMs, over: false });
        }
    }
    function _ghostDone(gid) {
        for (let i = 0; i < ghostModel.count; i++) {
            if (ghostModel.get(i).gid === gid) {
                ghostModel.remove(i);
                break;
            }
        }
        delete root._ghostEntries[gid];
    }
    // The burst's flash: what a tone shows now, painted once at full strength and faded over the live fills.
    function _flash(piece, tone) {
        if (root.burstFlashMs <= 0)
            return;
        const es = root._fillShown.filter(e => e.tone === tone && (piece < 0 || e.piece === piece || e.piece < 0));
        if (es.length === 0)
            return;
        const gid = ++root._ghostSerial;
        root._ghostEntries[gid] = es;
        ghostModel.append({ gid: gid, tone: tone, strength: Math.min(1, root.burstFlashStrength), ms: root.burstFlashMs, over: true });
    }
    ListModel {
        id: ghostModel
    }

    function _scheduleFills(now) {
        const list = (root.fills || []).concat(root._breakFills);
        let wait = -1;
        let eased = false;
        for (let i = 0; i < list.length; i++) {
            const f = list[i];
            if (!(f.t1 > f.t0) || now >= f.t1 || f.to0 === f.to1)
                continue;
            if (now < f.t0) {
                const d = f.t0 - now;
                wait = wait < 0 ? d : Math.min(wait, d);
                continue;
            }
            const subs = root._subPieces(f.piece);
            const span = subs[subs.length - 1].x1 - subs[0].x0;
            let d;
            if (f.ease === "outCubic") {
                // The instant the glide has moved one more quantum, solved exactly (no early wake that paints nothing).
                eased = true;
                const u = Math.max(0, Math.min(1, (now - f.t0) / (f.t1 - f.t0)));
                const next = 1 - Math.pow(1 - u, 3) + root.fillEaseQuantumPx / Math.max(1e-9, Math.abs(f.to1 - f.to0) * span);
                d = next >= 1 ? f.t1 - now : (1 - Math.pow(1 - next, 1 / 3) - u) * (f.t1 - f.t0);
            } else {
                const pxPerMs = Math.abs(f.to1 - f.to0) * span / (f.t1 - f.t0);
                d = Math.min(f.t1 - now, root.fillQuantumPx / Math.max(1e-9, pxPerMs));
            }
            wait = wait < 0 ? d : Math.min(wait, d);
        }
        if (wait < 0) {
            fillTimer.stop();
            return;
        }
        // The host's clock may run faster than the wall clock (a mockup).
        const scale = root.fillClock && root.fillClock.scale ? root.fillClock.scale : 1;
        fillTimer.interval = Math.max(Math.ceil(1000 / Math.max(1, eased ? root.fillEaseMaxHz : root.fillMaxHz)), Math.ceil(wait / scale));
        fillTimer.restart();
    }

    Timer {
        id: fillTimer
        repeat: false
        onTriggered: {
            root.fillStats.wakes += 1;
            root._refreshFills(false);
        }
    }
    onFillsChanged: root._refreshFills(true)
    onFillToneColorsChanged: root._refreshFills(true)
    onFillHeadBulgeChanged: root._refreshFills(true)
    onFillShadowDarkenChanged: root._refreshFills(true)
    onFillStrengthChanged: root._refreshFills(true)
    on_FillStrengthNowChanged: root._refreshFills(true)
    onLockMergeChanged: root._refreshFills(true)
    onFillShadowWidenChanged: root._refreshFills(true)
    Connections {
        target: Theme
        function onCrossfadingChanged() {
            if (!Theme.crossfading)
                root._refreshFills(true);
        }
    }

    // ======================================================================
    // RENDERING
    //
    // All drawing happens inside an inner `canvas` Item in horizontal coords.
    // For vertical orientation we rotate the canvas 90° around its center.
    // ======================================================================
    Item {
        id: canvas
        anchors.centerIn: parent
        width: root.lineLength
        height: root.lineCross
        rotation: root.isHorizontal ? 0 : 90

        // ------------------------------------------------------------------
        // PARTICLES
        // ------------------------------------------------------------------
        ParticleSystem {
            id: particles
            // the module's rect plus its reach (see `particleReachX`)
            x: -root._reachX
            y: 0
            width: canvas.width + 2 * root._reachX
            height: canvas.height + root._reachDown
            fadeLeft: root._reachX > 0 ? root.particleEdgeFade : 0
            fadeRight: root._reachX > 0 ? root.particleEdgeFade : 0
            fadeBottom: root._reachDown > 0 ? root.particleEdgeFade : 0
            maxParticles: 500
            z: 3 // above the clock/dots, but below the ball
            // Still while the theme crossfades: the fade is a picture of the
            // frame before, and anything moving under it shows twice.
            running: !Theme.crossfading
        }

        // The completion dust: its own layer, without the sparks' bloom (which
        // washes a colour out to white).
        ParticleSystem {
            id: dust
            x: particles.x
            y: particles.y
            width: particles.width
            height: particles.height
            fadeLeft: particles.fadeLeft
            fadeRight: particles.fadeRight
            fadeBottom: particles.fadeBottom
            maxParticles: 200
            z: 3
            running: !Theme.crossfading
        }

        MultiEffect {
            source: particles
            anchors.fill: particles
            blurEnabled: true
            blurMax: root.sparksBloomBlur
            blur: root.sparksBloomStrength
            brightness: root.sparksBloomBrightness
            z: 4
            // Only while there is something to bloom: an idle blur pass over
            // an empty layer still costs a render every time the bar redraws.
            visible: root.sparksEnabled && particles.hasParticles
        }

        // ------------------------------------------------------------------
        // GROOVE + DOTS
        //
        // Renders the combined shape of the main groove and the workspace dots.
        // It uses a dynamic union technique: drawing the shape from largest
        // (outer bevel) to smallest (innermost core), perfectly combining the
        // shadows and handling intersections seamlessly.
        // ------------------------------------------------------------------
        ScaledCanvas {
            id: grooveCanvas
            anchors.fill: parent
            antialiasing: true
            // Immediate, as in GrooveTrack: Cooperative hands the paint
            // to the render thread and shows it a frame late, which under a
            // theme switch is a frame of groove in the old palette.
            renderStrategy: Canvas.Immediate

            readonly property string _paintKey: [
                root.scLine, root.scTrackSepNow, root.scCornerExt, root.scDot,
                root.lineCenter, root.leftSectionStart, root.leftSplitPos,
                root.rightSplitPos, root.rightSectionEnd,
                root.showClock ? 1 : 0,
                JSON.stringify(root.bezierTopLeft),
                JSON.stringify(root.bezierTopRight),
                JSON.stringify(root.bezierBottomLeft),
                JSON.stringify(root.bezierBottomRight),
                JSON.stringify(root.grooveGradientEasing),
                JSON.stringify(root.grooveBevelEasing),
                root.grooveBevelWidth, root.grooveShadowWidth, root.sizeScale,
                root.surfaceColor, root.grooveBevelColor, root.grooveShadowColor, root.grooveColor,
                JSON.stringify(root.dotPositions)
            ].join("|")
            
            on_PaintKeyChanged: requestPaint()

            onDraw: (ctx, cw, ch) => {
                let dots = root.dotPositions;
                CarvedPath.paintCarve(ctx, root._carveGeometry(), root._groovePalette, function (ctx, rLine, rDot) {
                    if (rLine > 0) {
                        ctx.lineWidth = rLine * 2;
                        ctx.beginPath();
                        root._traceGroove(ctx);
                        ctx.stroke();
                    }
                    if (rDot > 0) {
                        ctx.beginPath();
                        for (let j = 0; j < dots.length; j++) {
                            ctx.moveTo(dots[j] + rDot, root.lineCenter);
                            ctx.arc(dots[j], root.lineCenter, rDot, 0, Math.PI * 2);
                        }
                        ctx.fill();
                    }
                });
            }
        }

        // ------------------------------------------------------------------
        // PROGRESS FILLS -- one canvas per tone, a higher tone over a lower
        // one (a break refills the session's piece over its focus colour).
        // Never hidden: an empty fill paints nothing.
        // ------------------------------------------------------------------
        Repeater {
            id: fillCanvases
            model: root.fillToneColors.length
            delegate: ScaledCanvas {
                id: fillCanvas
                required property int index
                anchors.fill: parent
                antialiasing: true
                renderStrategy: Canvas.Immediate
                z: fillCanvas.index === root.breakTone ? 0.9 : 1
                onDraw: (ctx, cw, ch) => root._paintFill(ctx, fillCanvas.index, cw, ch)
                Component.onCompleted: requestPaint()
                Connections {
                    target: grooveCanvas
                    function on_PaintKeyChanged() {
                        root._fillShown = root._fillFrame(root._fillNowMs());
                        fillCanvas.requestPaint();
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // LEAVING FILLS -- the last picture of what was taken away, fading out
        // (see THE FADE OF A LEAVING FILL). Held still while the theme crossfades.
        // ------------------------------------------------------------------
        Repeater {
            model: ghostModel
            delegate: ScaledCanvas {
                id: ghost
                required property int gid
                required property int tone
                required property real strength
                required property int ms
                required property bool over
                objectName: "fillGhost"
                anchors.fill: parent
                antialiasing: true
                renderStrategy: Canvas.Immediate
                z: ghost.over ? 1.5 : 0.5
                onDraw: (ctx, cw, ch) => {
                    root.fillStats.ghosts += 1;
                    root._paintFill(ctx, ghost.tone, cw, ch, root._ghostEntries[ghost.gid] || [], ghost.strength < 0 ? undefined : ghost.strength);
                }
                Component.onCompleted: requestPaint()
                NumberAnimation on opacity {
                    from: 1
                    to: 0
                    duration: ghost.ms
                    easing.type: Easing.OutCubic
                    paused: Theme.crossfading
                    onFinished: root._ghostDone(ghost.gid)
                }
            }
        }

        // ------------------------------------------------------------------
        // DOT HIT-TARGETS – the dots themselves are drawn inside
        // `grooveCanvas`; this Repeater only provides input handlers at
        // each dot position so clicks focus that workspace (focusWorkspace).
        // ------------------------------------------------------------------
        Repeater {
            model: root.dotPositions.length

            Item {
                id: dotItem
                required property int index
                readonly property real along: root.dotPositions[index]
                readonly property var wsRef: root.workspaceList[index]

                x: along - root.scDot / 2
                y: root.lineCenter - root.scDot / 2
                width: root.scDot
                height: root.scDot

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -4
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        if (dotItem.wsRef)
                            root.focusWorkspace(dotItem.wsRef.id);
                    }
                }
            }
        }

        // ------------------------------------------------------------------
        // BALL – the SquishItem wrapper for kinetic deformation.
        // It tracks its position along the complex paths and natively squishes/kinks.
        // ------------------------------------------------------------------
        
        SquishItem {
            id: ballWrapper
            visible: root.activeIndex >= 0
            z: 5

            // Emulate the Canvas boundaries by filling the horizontal canvas
            anchors.fill: parent

            usePath: true
            trackPos: root.ballDrawPos
            pathFunc: function(pos) {
                // the outline's points follow the rail by the frame of where the BALL is (see _frameFor), not of where each point is
                const f = root._ballFrame;
                const xy = root._ballPointAt(pos, f);
                return { x: xy.along, y: xy.across, angle: root._ballAngleAt(pos, f) };
            }

            overrideWidth: root.ballShape.w
            overrideHeight: root.ballShape.h

            color: root.ballColor
            shadowColor: root.ballShadowColor
            shadowOpacity: root.ballShadowOpacity
            shadowBlur: root.ballShadowBlur * 30
            shadowOffsetX: root.ballShadowOffsetX * root.sizeScale
            shadowOffsetY: root.ballShadowOffsetY * root.sizeScale
        }
    }
}
