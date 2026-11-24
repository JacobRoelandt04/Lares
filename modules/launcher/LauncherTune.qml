import QtQuick

// =============================================================================
// LauncherTune.qml -- every number the launcher popup is built with, in one
// object.
//
// The bar owner holds one (the popup's content is rebuilt on every open, so
// its knobs cannot live in it); the mockup's control panel writes the same
// object, and its `val:` entries are these defaults. Nothing here is state:
// what the user chose (sort, layout, favourites, frecency) lives in the
// service's files; what the machine is (columns, rows, the scripts root, the
// icon theme) in launcher.jsonc.
// =============================================================================
QtObject {
    // ---- Type ------------------------------------------------------------------------------------------
    // The module's face is Inter; the mockup dresses it in Audiowide.
    property string fontFamily: "Inter"
    property real nameSize: 12

    // ---- Geometry ----------------------------------------------------------------------------------------
    // The popup's own padding and the row inset, the shell's two numbers.
    property real padding: 12
    property real rowInset: 6
    // A row is the icon and a rowInset above and below it.
    property real iconSize: 40
    // Gap from the icon to its name.
    property real iconGap: 10
    // Width of the single list; each column's width in the multi-column
    // layout (the popup is then columns x columnWidth + gaps + padding).
    property real listWidth: 420
    property real columnWidth: 300
    property real columnGap: 12
    property real wellRadius: 10
    // The header row above the list.
    property real headerHeight: 32
    // How many rows the popup is tall and how many columns the Columns
    // layout has; -1 (or 0): launcher.jsonc's (rows 9, columns 2 by default).
    // The service clamps them (1..40, 1..8).
    property int rows: -1
    property int columns: -1

    // ---- The wiki teaser (one line at the foot) ---------------------------------------------------
    // With a wiki service injected (LauncherBarOwner.wiki) the popup's foot
    // carries one line, "Today: <the day's Discover article>", a link that
    // closes the launcher and opens the clock popup's wiki card. Off, or no
    // service: nothing is built and the popup has no teaser line.
    // The slot is STATIC -- a padding and this height, whether or not there is
    // an article today and whatever is typed -- so the popup never resizes
    // through it. WikiTeaser is 18 px high (its own contract), and the
    // row's inset keeps its glyph on the icons' left edge.
    property bool wikiTeaser: true
    property real teaserHeight: 18

    // ---- Icons and the favourite star ---------------------------------------------------------------
    // The icon is the icon theme's, drawn as it is (AppIcon); what is tuned is the size (iconSize, below), the
    // star at the favourite row's end, and the lit rim of the flourish's ball (bevelPx: the launched icon's plate
    // closed into a circle, FlourishPose.ballRadius).
    property real bevelPx: 3
    property real starSize: 12

    // ---- The quick answer's row (AnswerRow) ---------------------------------------------------------------
    // One row with the app rows' geometry (row height, inset, icon slot, gap), in the list's first slot while an answer exists.
    // The value is the figure face; the expr and detail one smaller line under it; up to three alts at the right.
    property real answerValueSize: 16
    property real answerSubSize: 11
    // Between the value's line and the line under it.
    property real answerLineGap: 2
    // The kind's glyph (Symbols Nerd Font) in the icon's slot.
    property real answerGlyphSize: 18
    // The colour kind's carved swatch, in the same slot.
    property real answerSwatch: 28
    property real answerSwatchRadius: 8
    // The alts' column: its share of the row's width (a fixed slot, so the main text never re-elides as alts come and go with
    // a different length), and the height each line takes beyond the text.
    property real answerAltShare: 0.42
    property real answerAltGap: 1
    // The row's presence fade; the house number.
    property int answerFadeMs: 160
    // How long the expr slot says "Copied" after Shift+Enter.
    property int answerCopiedMs: 1200

    // ---- Motion -------------------------------------------------------------------------------------------
    // The highlight well glides between rows on one clock.
    property int glideMs: 120
    // A sort change reflows the rows on screen; a query places them.
    property int reflowMs: 220
    // The folder morph (notes' group morph) and its two-finger back.
    property int morphMs: 320
    property real swipeBackUnits: 900
    property real swipeBackSign: 1
    // Hover on the slim bar: how long the pointer rests before it opens,
    // and how long it may be away before a hover-opened launcher closes.
    property int hoverOpenMs: 250
    property int hoverCloseMs: 400
    // A row's context menu closes once the list has scrolled this far under
    // it (the menu's row is leaving).
    property real menuScrollClosePx: 40

    // ---- The confirm flourish (ConfirmFlourish, FlourishPose.js) ----------------------------
    // A launch's row lifts out of the closing launcher and is THROWN: it flies up, reaches
    // its apex with no speed at all, falls back (becoming a ball on the way) into its bar and splashes -- one
    // parabola, no pause at the top, no waiting for the launched window (launcher.jsonc `"flourish": "off"`: the launcher closes plainly). Easings are the engine's indices (GooeyGeometry.EASING_NAMES: 0
    // Linear, 1 OutCubic, 2 OutQuint, 3 OutBack, 4 InOutCubic, 5 OutExpo,
    // 6 InQuad, 7 InCubic, 8 InBack).
    // The icon grows at the centre, from iconSize to confirmIconPx, during the
    // rise; the ball forms round the icon as it is then.
    property bool confirmGrowIcon: true
    property real confirmIconPx: 56
    // The resting card: padding round the icon and the title, the gap between
    // them, its corner radius.
    property real confirmPadPx: 12
    property real confirmTitleGapPx: 8
    property real confirmRadiusPx: 20
    // 1 LIFT: the row slides out of its cell through the fading launcher and
    // compacts into the card (the face's morph rides this clock), its foot a
    // little inside the launcher's free face when it ends.
    property int confirmLiftMs: 280
    property int confirmLiftEasing: 4
    // THE NECK between the card and the launcher (FlourishPose.neck, the
    // engine's setFlourishNeck): how deep the card's foot still is in the
    // launcher when the rise begins; where the waist sits between the card's
    // foot and the launcher's face (0 at the card, 1 at the launcher); the
    // share of the card's travel at which it pinches and the launcher's close
    // is let go; the waist's radius at the start and at the pinch; the radii
    // of the card's and the launcher's capsule ends as shares of THEIR
    // widths; the blend radii (the card onto the neck, the launcher onto it --
    // the wide curves --, the two capsules at the waist, the two sides where
    // they meet); how long each half takes to retract into its body once it
    // has pinched.
    property real confirmNeckInsetPx: 6
    property real confirmNeckMidFrac: 0.6
    property real confirmDetachFrac: 0.35
    property real confirmNeckQStartPx: 26
    property real confirmNeckQPinchPx: 2
    property real confirmNeckRUFrac: 0.4
    property real confirmNeckRLFrac: 0.15
    property real confirmNeckKA: 24
    property real confirmNeckKB: 80
    property real confirmNeckKMid: 16
    property real confirmNeckKJoin: 6
    // The radius each half's tip grows to as it retracts: a snapped strand
    // balls up into a rounded nub, never a point.
    property real confirmNeckBulbPx: 14
    property int confirmNeckRetractMs: 280
    // The curve of that retraction (the engine's easing indices). 0 Linear: the tips part the moment the strand snaps (an ease-in
    // holds them together for a third of the time, so the pinch would look late) and the motion fills the
    // whole set time (OutCubic lands most of it in the first third, so 600 ms looks like 200).
    property int confirmNeckRetractEasing: 0
    // The card coming out of the launcher: the one blend between the two while
    // the card's foot is still inside, k = K p / (p + G) for p px out (a real
    // popup's fillet along its bar's face: 24 / 28 / 31 / 33 px at
    // 5 / 10 / 20 / 40 px out), and how far the foot must clear the face for
    // the neck's own blends to take over from it.
    property real confirmNeckEmergeK: 45
    property real confirmNeckEmergeGrowPx: 2.3
    property real confirmNeckEmergeFadePx: 12
    // The launcher's own close, held while the row lifts out and let go at
    // the pinch: its length here is the most it takes -- it is cut short so that it is over a moment before the ball
    // lands (ConfirmFlourish._release), since the ball falls where the launcher's body was.
    property int confirmHostCloseMs: 400
    // Ms after the confirm before that close is let go (0: at the pinch).
    property int confirmHostCloseDelayMs: 0
    // The close is not let go before the strand's recoil is over: the card's stub is drawn between the card and the launcher's body, and
    // a launcher that closes under a stub still retracting pulls on it (and takes it away with its body). On: the close waits for the
    // recoil, whatever the delay says.
    property bool confirmHostAfterRecoil: true
    property int confirmHostCloseEasing: 3
    property real confirmHostOvershoot: 1.2
    // 2 RISE: from the face up to the apex (x drifts at a constant pace from the row's centre to the anchor, over the
    // rise and the fall together). The card is PULLED out until the pinch, which comes at detachFrac of the rise's clock
    // AND of its travel (the neck is drawn until then), then flies free, slowed by gravity to no speed at all at the apex
    // (FlourishPose.riseE: the pull and the coast agree in speed at the pinch only when their shares are the same).
    // THE GRAVITY (px/s^2) is the one number of the throw: the rise's clock and the fall's follow from it and the
    // geometry (FlourishPose.throwOf), so no launcher height and no preset can make the card drop like a stone. It says
    // how long the card hangs: under a speed s for 2 s / g, 125 ms under 200 px/s at 3200 (57 at 7000), and within 8 px of
    // the apex for 2 sqrt(16 / g) s, 141 ms. 3200 is 9.81 m/s^2 with the screen's 1296 design px standing for a 4 m window
    // (FlourishPresets.js, THE HANG). The speeds are the apex's, not the gravity's.
    property real confirmGravity: 3200
    // The apex: kept this far clear of the launcher's face, so a tall launcher and a short one are the same throw (the
    // height is what gives the launch its speed), and at least this much past the screen's centre.
    property real confirmRestClearPx: 500
    property real confirmRestOffsetPx: 70
    // 3 FALL: nothing is tuned; the same gravity takes the card from the apex's zero speed to the bar. The card stays
    // whole through the first confirmBallStart of the fall (it hangs at the apex there), then closes round the icon into
    // a circle over confirmBallMs; its outline culls the title with this feather at its widest (none at either end).
    property real confirmBallStart: 0.3
    property int confirmBallMs: 260
    property int confirmBallEasing: 4
    property real confirmBallMarginPx: 3
    property real confirmCullFeatherPx: 6
    // 4 IMPACT: the ball merges (the smooth group with the bar, this blend radius) and sinks into the bar, shrinking to this
    // share of itself. The sink's easing starts at three times its average speed, so 110 ms for its ~90 px carries on at the
    // speed the ball lands with (about 2600 px/s): the ball goes INTO the bar, it is not caught by it (a 220 ms sink would halve
    // the speed in the frame of the contact, a drop with no impact).
    property int confirmSinkMs: 110
    property int confirmSinkEasing: 1
    property real confirmSinkShrink: 0.6
    property real confirmMergeK: 24
    // The bar's ripple (GooeyRipple.js): the impact's wave amplitude, the
    // bulge's height and width, how fast it comes in, the packets' speed,
    // damping and wavelength, and when it is over.
    property real confirmRippleA: 5
    property real confirmRippleB: 10
    property real confirmRippleBulgeW: 32
    property real confirmRippleOnset: 0.02
    property real confirmRippleSpeed: 560
    property real confirmRippleDamping: 2.5
    property real confirmRippleWavelength: 30
    property real confirmRippleTend: 1.2
    // The splash: beads thrown from either side of the impact (each lands
    // with a ripple of its own: a ripple holds three sources, the impact's
    // and two), their radius, sideways and upward speeds, and the delay
    // after the contact. They fly on the throw's own gravity: a height is vy^2 / (2 g), 90 px at 760 and 3200.
    property int confirmDroplets: 2
    property real confirmDropletPx: 6.5
    property real confirmDropletVx: 150
    property real confirmDropletVy: 760
    property int confirmDropletDelayMs: 30
    // SKIP AHEAD (a popup opening while it plays): the ball forms where the
    // card is and drops at once; a reopen of the launcher waits for the
    // merge, at most this long.
    property int confirmSkipBallMs: 100
    property int confirmSkipFallMs: 180
    property int confirmSkipSinkMs: 140
    property int confirmReopenHoldMaxMs: 700
    // Shift+Enter: no flourish, a pulse of the row.
    property int confirmPulseMs: 160
    property real confirmPulseScale: 1.03
}
