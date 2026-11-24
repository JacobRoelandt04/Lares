import QtQuick

import "data/OsdKinds.js" as Kinds

// =============================================================================
// OsdStyle.qml -- every look and motion number of the OSD's content and its
// fullscreen pill. A QtObject: the mockup's Content / Pill tabs target these
// property names, and OsdContent falls back to a built-in instance when no
// host hands one in.
//
// PROPERTIES
//   time        valueEaseMs  directHoldMs  wheelStep
//   geometry    pad  gap  cardGap  cardMaxW  inkPadV
//   type        textFont  figureFont  glyphFont  glyphPx  cardGlyphPx  titlePx
//               detailPx  namePx  figurePx  figurePxV  codePx  keyPx
//   levels      sliderScale  glyphSlot  nameW  stopsLine  stopsDot  stopsBall  stopsMoveMs
//   sparks      sparkSpeed  sparkSpreadDeg  sparkLifeMs  sparkTrail  sparkSizeMin  sparkSizeMax  sparkDrag  sparkPerPx  sparkMaxPerStep  sparkPool
//   lock keys   keyU  keyUPill  keyCapsU  keyNumU  keyGap  keyRadius  keyPress  (+ lockPH)
//   cards       netGlyphPx  batteryW  batteryH  layoutGap
//   track       coverH  coverV  coverRadius
//   capture     thumbW  thumbH  thumbV  thumbTextMinW  thumbRadius  glyphTileW  glyphTileH
//   pill        pillDotD  pillTop  pillGrowMs  pillWidenMs  pillSwapMs
//               pillOpenGrowMs  pillOpenWidenMs  pillOpenLeadMs  pillFadeAt  pillFadeInMs
//               pillFadeMs  pillShadow  pillBevel  pillShadowAlpha  pillPad
//               pillGlyphPx  pillTextPx  pillFigurePx  pillCover
//   ball        pillBallShow  pillBallLiftMs  pillBallFaint  pillBallFadeMs  pillBallHoverPad   (a hidden pill: the dot, half off the top)
//   caption     captionW  captionPW  captionLines  captionPLines  captionLineH  captionHeadH  captionPx  captionHeadPx  captionGap
//   extents     <family><H|V|P><W|H> for the families level stops layout
//               theme track device capture battery power generic -- H = horizontal
//               bar, V = vertical bar, P = pill; W/H = width/height. Read
//               through extentOf(kind, orientation) -> {w, h}. The lock keys' card is
//               not in the table: its size is a consequence of the keys (extentOf
//               computes it from keyU, keyGap and the padding), so there is one set
//               of numbers for it.
//
// The numbers are set by eye; padding is 12
// on every side (CLAUDE.md), the pill's is wider because a capsule's corner
// takes room from the content.
// =============================================================================
QtObject {
    id: s

    // ---- time -------------------------------------------------------------
    // A level's displayed value eases on ONE clock when something else moved
    // it (an app, a key); it is direct while the pointer drags.
    property int valueEaseMs: 120
    // How long after the last pointer change the display still counts as
    // "being dragged" (the service's echo must not restart an ease).
    property int directHoldMs: 300
    // A wheel notch (120 units) moves a level by this much of its range.
    property real wheelStep: 0.04

    // ---- geometry ---------------------------------------------------------
    property real pad: 12
    // Between a glyph and what stands next to it.
    property real gap: 10
    // Between the two halves of a card (picture / text).
    property real cardGap: 12
    // A vertical card's width grows to fit its longest word, up to this; past it
    // the line elides (a word is never broken).
    property real cardMaxW: 140
    // A vertical level: the INK of its glyph and of its figure stand this far
    // from the box's top and bottom edges (the glyph and the figure each carry
    // some empty room in their own boxes, so the pad of 12 alone leaves the
    // two ends unequal).
    property real inkPadV: 18

    // ---- type -------------------------------------------------------------
    property string textFont: "Inter"
    property string figureFont: "Audiowide"
    property string glyphFont: "Symbols Nerd Font"
    property real glyphPx: 22
    property real cardGlyphPx: 26
    property real titlePx: 14
    property real detailPx: 11
    property real namePx: 10
    property real figurePx: 16
    property real figurePxV: 13
    property real codePx: 24
    property real keyPx: 12

    // ---- levels (volume, mic, brightness) and the stops (kbd light) --------
    // GrooveSlider's own sizeScale: its ball, bars and room all follow it.
    property real sliderScale: 0.8
    property real glyphSlot: 26
    // The device name's slot under the figure on a horizontal level.
    property real nameW: 92
    // The keyboard light's rail (PhaseRail, the workspaces' own): the groove, a notch per stop, the ball in
    // the current one, and how long the ball takes to travel to the next.
    property real stopsLine: 6
    property real stopsDot: 12
    property real stopsBall: 14
    property int stopsMoveMs: 320

    // ---- sparks (OsdSparks: the ball of a level, or the head of the pill's fill, while it moves) -----------
    // THE SILICON BAR BUTTON'S CHARGE BURST: a very subtle particle count, size and shape, like the silicon charge events on the bar:
    // tiny ROUND dots, 1.5-2.4 px that keep their size and only fade (modules/silicon/bar/SiliconSparks.js:
    // size 1.5-2.4, speed 8-20 px/s, drag 2.6, lives 2-3.2 s, 14 to a burst, no trail). A spark shrunk to 0.5 px is too small, a
    // 3-point trail reads as stretched, and shedding up to 3 per frame of the ease is too many.
    // A SPARK FLIES OFF IN A DIRECTION OF ITS OWN, or the particles read as a dotted line left behind by the ball: each one is
    // thrown at a random angle within `sparkSpreadDeg` either side of "straight back along the
    // head's way", at a speed of its own (0.5-1.5x `sparkSpeed`), so a few sparks fan out of the ball instead of trailing it in a line.
    // px/s of the spark at launch (0.5-1.5x per spark); with drag 2.6 it travels about a third of that in px: 38 reads as flying off
    property real sparkSpeed: 38
    // half-angle, degrees, of the cone the sparks are thrown in, centred on straight back (180 = anywhere)
    property real sparkSpreadDeg: 100
    // a spark lives this long, up to twice it (ms); the card is out for ~2 s
    property real sparkLifeMs: 900
    // points of the trail: 1 is a round dot, anything more is a streak (the rail's is 8)
    property int sparkTrail: 1
    // a spark's size is drawn between these (px) and kept to its end
    property real sparkSizeMin: 1.5
    property real sparkSizeMax: 2.4
    property real sparkDrag: 2.6
    // sparks shed per px the head travels (a fraction carries over to the next change, so a small step still sheds one now
    // and then), and the most one change sheds
    property real sparkPerPx: 0.12
    property int sparkMaxPerStep: 2
    // the most sparks alive at once (silicon's burst is 14): a held key cannot make a cloud
    property int sparkPool: 14

    // ---- lock keys ----------------------------------------------------------
    // The card draws the two keys as keys: a unit is a key's height and Num Lock's width, Caps Lock is
    // keyCapsU units wide (1.75: a laptop keyboard's), and a chiclet's corner.
    property real keyU: 36
    // The capsule is 44 tall: its keys are smaller (and "Num" must still fit its key).
    property real keyUPill: 32
    property real keyCapsU: 1.75
    property real keyNumU: 1
    // The keys the card shows, in order (osd.jsonc lockkeys.keys; the shell's style is told it): its size follows.
    property var lockKeys: ["caps", "num"]
    // The shown keys' widths, in order, at unit `u`.
    function lockKeyWidths(u) {
        const ks = s.lockKeys && s.lockKeys.length > 0 ? s.lockKeys : ["caps", "num"];
        const out = [];
        for (let i = 0; i < ks.length; i++)
            out.push(s.keyWidth(ks[i] === "caps" ? s.keyCapsU : s.keyNumU, u));
        return out;
    }
    property real keyGap: 8
    property real keyRadius: 6
    // How far a key that is ON sinks (RaisedButton's pressed: the relief shrinks, the legend drops a pixel).
    property real keyPress: 0.6

    // ---- cards --------------------------------------------------------------
    // The layout card, stacked: from the baseline of its big code to the top of the name under it.
    property real layoutGap: 8
    property real netGlyphPx: 34
    property real batteryW: 40
    property real batteryH: 20

    // ---- track --------------------------------------------------------------
    property real coverH: 56
    property real coverV: 80
    property real coverRadius: 10

    // ---- capture ------------------------------------------------------------
    // A screenshot's tile (the card is as big as it and its words: OsdCapture fitW / fitH): thumbW x thumbH on a
    // horizontal bar, thumbV wide at the same proportions on a vertical one, and the least the text beside it is
    // given. Large enough to see what was screenshotted (112 x 70, 104 wide, is too small).
    property real thumbW: 200
    property real thumbH: 125
    property real thumbV: 232
    property real thumbTextMinW: 120
    property real thumbRadius: 8
    // The tile of a recording or a copy, which has no picture to show: the glyph's.
    property real glyphTileW: 112
    property real glyphTileH: 70

    // ---- pill ---------------------------------------------------------------
    // The dot it is born as.
    property real pillDotD: 14
    // Gap between the screen's top edge and the pill (the window's margin).
    property real pillTop: 12
    // THE CLOSE: the capsule narrows (pillWidenMs), then shrinks to the dot (pillGrowMs).
    property int pillGrowMs: 200
    property int pillWidenMs: 260
    // THE OPEN is one motion (OsdPill): the dot grows down into a capsule in pillOpenGrowMs, and the widening starts
    // pillOpenLeadMs after the growth began -- while it is still easing in, so the speed never drops to nothing between the two
    // (the old open stood still at the corner for a frame: OutCubic ends at speed 0 and the next began at 3x its average).
    // Shorter than the close: what the user is waiting for is the content (the open was ~620 ms to it, now ~300).
    property int pillOpenGrowMs: 130
    property int pillOpenWidenMs: 190
    property int pillOpenLeadMs: 50
    // The content's fade starts when this share of the widening is done: the capsule's ends are then past the widest ink of
    // any pill kind with 2 px to spare (measured: tools/dev/osd_pill_open_probe.sh).
    property real pillFadeAt: 0.94
    property int pillFadeInMs: 120
    // A different kind while it is out: W and H ease on this.
    property int pillSwapMs: 260
    // The content's presence fade, in and out.
    property int pillFadeMs: 160
    // Relief: it floats over arbitrary content, so a stronger drop shadow.
    property real pillShadow: 9
    property real pillBevel: 1.5
    property real pillShadowAlpha: 1.0
    // Left and right inset of the content inside the capsule.
    property real pillPad: 16
    property real pillGlyphPx: 18
    property real pillTextPx: 12
    property real pillFigurePx: 14
    property real pillCover: 36
    // THE BALL (a pill the user hid, OsdPill): it collapses to the dot it is born as, which rises until only this share of it
    // is below the screen's top edge, then fades over pillBallFadeMs to pillBallFaint. It is hovered over its own box plus
    // pillBallHoverPad on every side that is on screen: the top edge makes it easy to reach up and down, not across.
    property real pillBallShow: 0.4
    property int pillBallLiftMs: 260
    property real pillBallFaint: 0.18
    property int pillBallFadeMs: 3000
    property real pillBallHoverPad: 8

    // The pill's window, in design px: as wide as the widest pill of EVERY kind and as tall as the tallest, plus the drop shadow's
    // reach (`reach`) round it, the top margin above (OsdPillWindow). Every kind counts -- a kind left out is cut straight by the
    // window's edge whenever it is the larger (the caption was: 520 x 92 in a 330 x 83 window).
    function pillWindowExtent() {
        const reach = Math.ceil(s.pillShadow + s.pillBevel) + 4;
        let w = 0, h = 0;
        for (const k of Kinds.kindIds()) {
            const e = s.extentOf(k, "pill");
            w = Math.max(w, e.w);
            h = Math.max(h, e.h);
        }
        return { w: Math.ceil(w) + 2 * reach, h: Math.ceil(s.pillTop + h) + reach, reach: reach };
    }

    // ---- caption (the dictation's live words: a window take, a voice ask; kinds/OsdCaption.qml) ----------
    // Its size is a consequence of these, like the lock keys' (captionExtent): a fixed width and a fixed number of lines, so it never
    // resizes while the words come in. The pill's is wider and shorter: it stands over a fullscreen video.
    property real captionW: 380
    property real captionPW: 520
    property int captionLines: 4
    property int captionPLines: 3
    // Every line of words is this tall (Text.FixedHeight): they scroll by whole lines on whole pixels.
    property real captionLineH: 16
    // The head: its glyph's square, what the take does now, and the gap after the glyph and under the head.
    property real captionHeadH: 14
    property real captionPx: 12
    property real captionHeadPx: 11
    property real captionGap: 6

    // ---- extents (w x h, whole pixels) --------------------------------------
    property real levelHW: 360
    property real levelHH: 64
    property real levelVW: 64
    property real levelVH: 300
    property real levelPW: 280
    property real levelPH: 44

    property real stopsHW: 260
    property real stopsHH: 56
    property real stopsVW: 56
    property real stopsVH: 220
    property real stopsPW: 240
    property real stopsPH: 44

    // The lock keys' card is as big as its keys (lockExtent); only the capsule's height is a number of its own.
    property real lockPH: 44

    // The layout card is as big as its words (OsdLayoutCode fitW / fitH): layoutHW is the widest it grows on a
    // horizontal bar (a longer name elides there), layoutVW the narrowest on a vertical one (it grows to its
    // longest word), and its height is the code and the wrapped name -- there is no layoutVH.
    property real layoutHW: 170
    property real layoutHH: 56
    property real layoutVW: 64
    property real layoutPW: 170
    property real layoutPH: 44

    property real themeHW: 190
    property real themeHH: 56
    property real themeVW: 64
    property real themeVH: 110
    property real themePW: 200
    property real themePH: 44

    // No state glyph on the card: each size is the size with a glyph less the glyph and its gap (22 + 10 on the bars, 18 + 10 in the pill;
    // 32 off the vertical card's height), so the text keeps the room it has with one.
    property real trackHW: 308
    property real trackHH: 80
    property real trackVW: 104
    property real trackVH: 188
    property real trackPW: 272
    property real trackPH: 56

    property real deviceHW: 280
    property real deviceHH: 56
    property real deviceVW: 124
    property real deviceVH: 140
    property real devicePW: 280
    property real devicePH: 44

    property real captureHW: 320
    property real captureHH: 96
    property real captureVW: 128
    property real captureVH: 170
    property real capturePW: 300
    property real capturePH: 56

    property real batteryHW: 260
    property real batteryHH: 56
    property real batteryVW: 92
    property real batteryVH: 110
    property real batteryPW: 240
    property real batteryPH: 44

    // The power kind (silicon: profile, GPU mode, charge limit, the MUX's notices): a glyph, a title and a
    // detail like the generic card, a little wider because the MUX's notice is a sentence.
    property real powerHW: 300
    property real powerHH: 56
    property real powerVW: 104
    property real powerVH: 130
    property real powerPW: 300
    property real powerPH: 44

    property real genericHW: 260
    property real genericHH: 56
    property real genericVW: 104
    property real genericVH: 130
    property real genericPW: 260
    property real genericPH: 44

    // Every extent BY NAME: the wiring check (tools/dev/mockup_wiring_check.py) finds a
    // property's readers by its name, and a lookup built from strings
    // (s[fam + o + "W"]) hides all forty of them.
    readonly property var extents: ({
        levelHW: s.levelHW, levelHH: s.levelHH, levelVW: s.levelVW, levelVH: s.levelVH, levelPW: s.levelPW, levelPH: s.levelPH,
        stopsHW: s.stopsHW, stopsHH: s.stopsHH, stopsVW: s.stopsVW, stopsVH: s.stopsVH, stopsPW: s.stopsPW, stopsPH: s.stopsPH,
        lockPH: s.lockPH,
        layoutHW: s.layoutHW, layoutHH: s.layoutHH, layoutVW: s.layoutVW, layoutPW: s.layoutPW, layoutPH: s.layoutPH,
        themeHW: s.themeHW, themeHH: s.themeHH, themeVW: s.themeVW, themeVH: s.themeVH, themePW: s.themePW, themePH: s.themePH,
        trackHW: s.trackHW, trackHH: s.trackHH, trackVW: s.trackVW, trackVH: s.trackVH, trackPW: s.trackPW, trackPH: s.trackPH,
        deviceHW: s.deviceHW, deviceHH: s.deviceHH, deviceVW: s.deviceVW, deviceVH: s.deviceVH, devicePW: s.devicePW, devicePH: s.devicePH,
        captureHW: s.captureHW, captureHH: s.captureHH, captureVW: s.captureVW, captureVH: s.captureVH, capturePW: s.capturePW, capturePH: s.capturePH,
        batteryHW: s.batteryHW, batteryHH: s.batteryHH, batteryVW: s.batteryVW, batteryVH: s.batteryVH, batteryPW: s.batteryPW, batteryPH: s.batteryPH,
        powerHW: s.powerHW, powerHH: s.powerHH, powerVW: s.powerVW, powerVH: s.powerVH, powerPW: s.powerPW, powerPH: s.powerPH,
        genericHW: s.genericHW, genericHH: s.genericHH, genericVW: s.genericVW, genericVH: s.genericVH, genericPW: s.genericPW, genericPH: s.genericPH
    })

    function familyOf(kind) {
        switch (kind) {
        case "volume":
        case "mic":
        case "brightness":
            return "level";
        case "kbd":
            return "stops";
        case "lockkeys":
            return "lock";
        case "layout":
            return "layout";
        case "theme":
            return "theme";
        case "track":
            return "track";
        case "bluetooth":
        case "network":
        case "vpn":
        case "autoTunnel":
        case "btLow":
            return "device";
        case "capture":
            return "capture";
        case "battery":
            return "battery";
        case "power":
            return "power";
        case "caption":
            return "caption";
        default:
            return "generic";
        }
    }

    // A key's width: `units` of a unit `u`, on whole PIXELS and an even one, so a key centred on a card's axis
    // (the stacked pair) stands on the pixel grid.
    function keyWidth(units, u) {
        return 2 * Math.round(units * u / 2);
    }
    // The lock keys' card: the padding round the pair of keys (the capsule takes its own height).
    function lockExtent(orientation) {
        const pill = orientation === "pill";
        const u = pill ? s.keyUPill : s.keyU;
        const pad = pill ? s.pillPad : s.pad;
        const ws = s.lockKeyWidths(u);
        const n = ws.length;
        if (orientation === "v")
            return { w: 2 * pad + Math.max.apply(null, ws), h: 2 * pad + n * u + (n - 1) * s.keyGap };
        return { w: 2 * pad + ws.reduce((a, b) => a + b, 0) + (n - 1) * s.keyGap, h: pill ? s.lockPH : 2 * pad + u };
    }

    // The caption's card: its head and its lines inside the padding (the pill's padding across is the capsule's).
    function captionExtent(orientation) {
        const pill = orientation === "pill";
        const lines = pill ? s.captionPLines : s.captionLines;
        return { w: pill ? s.captionPW : s.captionW, h: 2 * s.pad + s.captionHeadH + s.captionGap + lines * s.captionLineH };
    }

    // The content's implicit size: {w, h}.
    function extentOf(kind, orientation) {
        const fam = s.familyOf(kind);
        if (fam === "lock")
            return s.lockExtent(orientation);
        if (fam === "caption")
            return s.captionExtent(orientation);
        const o = orientation === "v" ? "V" : orientation === "pill" ? "P" : "H";
        return { w: Number(s.extents[fam + o + "W"]), h: Number(s.extents[fam + o + "H"]) };
    }
}
