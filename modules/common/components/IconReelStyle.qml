pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// IconReelStyle.qml
//
// Every number an IconReel and its views are drawn and animated by, in one
// object. Not a convenience: a bar carries several reels (the power menu and
// the idle inhibitor, on each bar), they are one material, and a per-instance
// copy of forty values is four places to change a padding. A reel makes its
// own if none is handed to it, so a lone one still works.
//
// It is also what the mockup's control panel writes to. One target, one set
// of sliders, every reel on screen moving together -- which is the only way
// to tell whether a value is right, since being right means being right in
// the bar AND hanging off it, horizontally AND vertically.
// =============================================================================
QtObject {
    id: style

    // ---- The strip ------------------------------------------------------
    // Across the axis. Also the popup's width, so the popup's corner radius
    // (the engine's maxR) at half of this is the half-round end.
    property real thickness: 40
    // The bar's own thickness: the length of the cell the selected icon sits
    // in. The engine's `thickness`, normally.
    property real barCell: 40
    property real cellPitch: 36
    property real iconPixelSize: 21
    property string iconFamily: "Symbols Nerd Font"
    // How far past the LAST icon's centre the strip runs, in cells. This is
    // where the popup ends: at the last icon, not past it, so the ring reads
    // as continuing rather than as a list that stopped. Half a glyph is the
    // most that fits before the popup's own clip cuts it instead of the fog.
    property real tailFraction: 0.3
    // How far past the bar's outer edge an icon travels before it wraps to
    // the far end, in cells. It has to be out of sight when it jumps.
    property real wrapLead: 0.6

    // ---- The turn -------------------------------------------------------
    property int stepMs: 260
    // 0 is the shell's OutCubic. Above 0 the reel overshoots and comes back,
    // which reads as a detent clicking home.
    property real stepOvershoot: 0
    // How fast the fog at the bar's edge reaches full as the reel starts
    // moving, per cell still to travel.
    property real motionGain: 2.4

    // ---- The swipe ------------------------------------------------------
    // A TWO-FINGER SWIPE ARRIVES AS A WHEEL, on the axis it was made on --
    // see docs/contracts/gestures.md. These are the same shape and the same
    // defaults as TabSelector's, so the reel resists like the rest of the
    // shell rather than like its own invention.
    //
    // Accumulated wheel units per step. A swipe is thousands of them; the
    // natural failure mode is a flick of a few millimetres skipping two
    // items, which on a power menu is the wrong thing armed.
    property real swipeThreshold: 700
    // (A mouse's notch is one icon whatever this says -- power.md's "on wheel scroll, one icon down": IconReel.notch.)
    // How far the ring is allowed to be pulled out of its slot while the
    // gesture is under way, in cells.
    property real swipeMaxPull: 0.05
    // How sharply the pull tapers. Most of the travel early, then resistance,
    // so the distance left to the threshold reads as effort.
    property real swipePullTaper: 3.0
    // Accumulated units per second above which a swipe is carrying enough
    // momentum to cross more than one item.
    property real swipeMomentumRate: 600
    // Minimum spacing between committed steps, so one long swipe steps once
    // at a time rather than racing through the ring.
    property int swipeCooldownMs: 100
    // The spring the ring uses to come home when the gesture ends.
    property int swipeReturnMs: 320
    // Fallback only. A touchpad sends a zero-delta wheel event when the
    // fingers lift (libinput's scroll-end, which Qt forwards) and THAT is
    // what releases the pull. This exists so a device that never sends one
    // cannot strand the ring mid-pull; it is far longer than anyone holds
    // still mid-gesture.
    property int swipeIdleResetMs: 6000

    // ---- Fog ------------------------------------------------------------
    // At the far end, permanent: what the last icon dissolves into and what
    // an icon coming round the ring appears out of.
    property real fogLength: 30
    // At the bar's edge, only while the reel is turning. At rest the icon in
    // the bar is exact.
    property real outerFogLength: 15
    // How far short of the far TIP the fog is already solid. ZERO by default:
    // above zero the fade reaches full a measurable distance inside the strip,
    // and against the rounded end that reads as the icon being cut off by a
    // straight line. The peeking it would guard against is handled by
    // geometry instead -- a glyph is scaled to the outline's own half-width at
    // its depth -- so the fade can run all the way to the tip and simply
    // dissolve there.
    property real fogClearance: 0

    // How far the bar's cell reaches PAST the bar's inner edge, into the
    // popup. The two views abut there, and at a fractional device scale their
    // clip edges can fall either side of the same pixel row -- which drops it,
    // and a white hairline shows through an icon crossing the join. They
    // overlap by a pixel instead; both draw the same ring at the same place,
    // so the overlap is invisible.
    //
    // It works because the engine draws its bars' modules ABOVE the popups'
    // content (GooeyEngine's barLayer over hostLayer); under the content it
    // would cover nothing. It is a guard
    // against rounding, not what makes the join watertight: with it at 0 the
    // seam check passes too, including with the engine's content clip forced
    // on.
    property real seamOverlap: 1

    // How far INSIDE thePopup's outline the icons are cut. Tolerance on the
    // mask: better a shade early than a shade late, because an icon that close
    // to the outline has all but gone into the fog anyway, while one drawn a
    // shade late is ink lying on the wallpaper.
    property real maskInset: 1

    // ---- Ink (the hover is the bar's one clock: BarHues.hoverMs) ----------------
    property int pressMs: 90
    property int flashMs: 420

    // ---- The popup ------------------------------------------------------
    // Long enough that crossing the module on the way somewhere else does
    // not open it; short enough that arriving deliberately feels immediate.
    property int openDelayMs: 90
    // The pointer crosses from the bar's cell into the popup through a frame
    // in which neither has it. Without a grace the reel closes under the
    // pointer on the way in.
    property int closeGraceMs: 160
    // The fraction of its final WIDTH thePopup starts at. The gooey default
    // is 0.5 -- it inflates sideways as it comes out -- and that is wrong
    // here: the strip's content is anchored to the bar and must stand still
    // while the popup grows, and a popup whose x and width are two animations
    // makes the content jitter sideways by half a pixel when they disagree.
    // 1 slides it out at full width, which is also what a strip should do.
    property real popupWidthFrom: 1.0

    // ---- The reason (the idle reel's side popup: ReelReason) ----------------
    // The tray label's look, which the user named as the model: the cause bold at the body size, one line, the label's padding.
    property string reasonFamily: "Inter"
    property int reasonTitleSize: 12
    property real reasonPadX: 12
    property real reasonPadY: 7

    // ---- Sparks ---------------------------------------------------------
    property bool particlesEnabled: true
    property int particleCount: 5
    property real particleSpeed: 150
    property real particleScatter: 40
    property int particleLifetimeMs: 520
    property real particleSizeStart: 1.6
    property real particleSizeEnd: 0.4
    property real particleDrag: 2.2
    property int burstCount: 9
    property real burstSpeed: 95
}
