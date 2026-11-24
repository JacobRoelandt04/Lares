pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/components"

// =============================================================================
// PlayerFidelityChip.qml
//
// The one mark that says how good the file being played actually is: a small
// carved chip reading `24-BIT 96kHZ FLAC`, in the tier's ink.
//
// THE CHIP READS THE FORMAT ITSELF (`24-BIT 96kHZ FLAC`; a lossy file has no bit
// depth, so `320kBPS 44.1kHZ AAC`), which is the FACT rather than this shell's
// grading of it. The grading is the ink.
//
// NO TIP. The numbers are on the chip and the grading word is the colour, so a tip
// would only repeat both. The chip is a mark and only a mark: no bubble, no overlay
// to reparent into, no delay, no second reading of the same fact.
//
// NO LIFT ON HOVER. The chip cannot be clicked, a fill that rose toward the surface
// would be a wash on a badge, and nothing announces an affordance that is not there.
// The one thing hover does is the bitrate lobe, for the one fact the chip does not
// say.
//
// THE BITRATE LOBE. While the pointer is on the chip it grows a second, narrower lobe
// ABOVE it, like a gooey popup hanging from the chip as from a bar and narrower than
// it: the same carved material (ShadowBoxLobe: one smooth union, so the joint is a
// fillet and the inset shadow follows the outline round it), holding the bitrate in
// the chip's ink. The hover starts it at once (no delay); the shape eases on the
// shell's resize curve. The lobe is as wide as the figure's SHAPE ("1997kBPS",
// "320kBPS": cells of the widest digit) and never as its digits, while the figure
// itself is drawn in its own advances, centred in that room. A lossy file has no bit
// depth to say, so its chip says only the rate and codec and the bitrate is on the
// lobe like a lossless file's. The figure is the fidelity object's `bitrate`, which
// is mpd's own and changes when mpd's status is read -- this file has no clock. With
// no bitrate (stopped, a queue row) there is no lobe.
//
// It takes a whole fidelity object (from MpdFidelity.js) rather than a sample
// rate and a bit depth, so the classification lives in one place and the chip
// only shows what it was told:
//
//     { tier: "max", label: "24-BIT 96kHZ FLAC", ... }
//
// Only `tier`, `label` and `bitrate` are read; the object's other fields
// (`tierLabel`, `detail`) belong to the service and are not this chip's business.
//
// ONE MARK. The tier is in the INK of the label and nowhere else: no coloured
// fill, no dot, no second badge. The scale runs accent (max, hires) -> ok
// (lossless) -> muted (high) -> faint (low, unknown), which is a ranking a
// reader gets without a legend: the good ones are the shell's live colour, the
// ordinary one is body text, the poor one recedes. The chip's own material is
// the neutral one -- carved into whatever it stands on, header-box fill, the
// same box every other small container in this shell is.
//
// Not the inset shadow, which is where a CATEGORY's colour lives in this
// shell. A category header is 40 px of box around a title; this is a 40 px box
// that IS its title, and a tinted carve at that size reads as a smudge while
// the ink reads as a value.
//
// A null `fidelity` (or one with no label) collapses the chip to nothing:
// implicit size 0, no box, no ink. A host can leave it bound to a service that
// has not answered yet and nothing appears.
//
// UNLESS `skeleton` IS SET, which is the nothing-is-playing state: then the
// chip keeps the size a `skeletonLabel`-long label would give it and draws one
// static silhouette of its own box. Static, not pulsing -- nothing is loading,
// so a pulse would be a claim that something is on its way (SkeletonBar with
// `pulse: false`, which is the shell's skeleton at rest).
//
// Sized through implicitWidth/implicitHeight; paints no background of its own
// beyond its box.
// =============================================================================
Item {
    id: chip

    // ---- Contract ----
    property var fidelity: null
    property real listScale: 1.0
    property string fontFamily: "Inter"

    // Nothing is playing. The chip holds the room a label would need and draws
    // a still silhouette in it. `skeletonLabel` is only ever MEASURED, never
    // drawn: it is the shape a lossless file's label has, which is the widest
    // of the two forms and therefore the honest perimeter to reserve.
    property bool skeleton: false
    property string skeletonLabel: "24-BIT 96kHZ FLAC"

    // The bitrate lobe. `lobeEnabled` off is the chip with no lobe; `hoverForce`
    // holds the lobe out as if the pointer were on the chip (a render harness
    // and a mockup's panel; the shell never sets it).
    property bool lobeEnabled: true
    property bool hoverForce: false
    readonly property bool hovered: hov.hovered || chip.hoverForce
    // Whether the lobe is OUT (`_ext`, below, is how far).
    readonly property bool lobeWanted: chip.lobeEnabled && chip._shows && chip.hovered && chip._bitrate > 0
    property color skeletonColor: Theme.headerBox

    // ---- Palette (Theme defaults; a host may override every one) ----
    property color surfaceColor: Theme.surface     // the fill the chip stands on
    property color chipColor: Theme.headerBox      // a shade darker than that fill
    property color bevelColor: Theme.bevel
    property color shadowColor: Theme.border
    property color accentColor: Theme.accent
    property color okColor: Theme.ok
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint

    // ---- Tuning ----
    property real chipRadius: 6
    property real padH: 8
    property real padV: 4
    property real bevelWidth: 1
    property real shadowWidth: 3
    property real fontPixelSize: 10
    property real lobePadH: 7
    property real lobePadV: 3
    property real lobeRadius: 6
    property real lobeJoin: 7
    // The lobe's shape eases on the shell's resize curve (260 ms OutCubic).
    property int lobeMs: 260
    // A badge is letter-spaced: at 10 px bold the word needs air to read as a
    // label rather than a word in a sentence.
    property real letterSpacing: 0.8
    // The SKELETON's dissolve, and nothing else's.
    property int fadeMs: 160

    // ---- Derived -------------------------------------------------------------
    readonly property real _s: Math.max(0.2, chip.listScale)
    readonly property int _bitrate: chip.fidelity && chip.fidelity.bitrate > 0 ? Math.round(chip.fidelity.bitrate) : 0
    readonly property string _tier: chip.fidelity && chip.fidelity.tier ? String(chip.fidelity.tier) : "unknown"
    readonly property string _label: chip.fidelity && chip.fidelity.label ? String(chip.fidelity.label) : ""
    readonly property bool _has: chip._label.length > 0
    // A REAL chip: a label, and no `skeleton`. The host's word wins over a
    // label -- `skeleton` is the host saying nothing is playing, and a host
    // that leaves last track's fidelity object bound (which is every host that
    // binds it rather than clearing it) would otherwise show a file's format
    // under a silhouette of its title. The block's strings are suppressed by
    // the same rule.
    readonly property bool _shows: chip._has && !chip.skeleton
    // Something is drawn: a chip, or the silhouette of one.
    readonly property bool _any: chip._shows || chip.skeleton

    readonly property color tierColor: {
        const t = chip._tier;
        if (t === "max" || t === "hires") return chip.accentColor;
        if (t === "lossless")             return chip.okColor;
        if (t === "high")                 return chip.mutedColor;
        return chip.faintColor;            // low, unknown, and anything unmapped
    }

    // ---- Size ----------------------------------------------------------------
    // Measured with FontMetrics, never read back off the label's own width:
    // the label is what this sizes, and reading it here closes a binding loop.
    // Qt adds `letterSpacing` after the LAST character too, so the measured
    // advance carries one trailing gap; it comes off the width here and the
    // label is nudged half of it left, which is what centres the word.
    FontMetrics {
        id: fm
        font.family: chip.fontFamily
        font.pixelSize: chip.fontPixelSize * chip._s
        font.bold: true
        font.letterSpacing: chip.letterSpacing * chip._s
    }
    readonly property real _labelWidth: {
        const f = fm.font;
        const s = chip._shows ? chip._label : (chip.skeleton ? chip.skeletonLabel : "");
        return s.length > 0
            ? Math.max(0, Math.ceil(fm.advanceWidth(s) - chip.letterSpacing * chip._s))
            : 0;
    }
    implicitWidth: chip._any ? chip._labelWidth + chip.padH * 2 * chip._s : 0
    implicitHeight: chip._any ? Math.ceil(fm.height) + chip.padV * 2 * chip._s : 0

    // The words it keeps while it goes back in: a stop zeroes the bitrate, and a
    // lobe emptied as it retracts is a lobe that blinks.
    property string _lobeText: ""
    on_BitrateChanged: if (chip._bitrate > 0) chip._lobeText = chip._bitrate + "kBPS"
    Component.onCompleted: if (chip._bitrate > 0) chip._lobeText = chip._bitrate + "kBPS"
    // Most of the chip's width, never all of it: the joint needs a shoulder.
    readonly property real _lobeWTarget: Math.max(0, Math.min(
        Math.ceil(figureSlot.implicitWidth + chip.lobePadH * 2 * chip._s),
        chip.implicitWidth - 2 * chip.chipRadius * chip._s))
    readonly property real _lobeFullH: Math.ceil(fm.height) + chip.lobePadV * 2 * chip._s
    // ONE fraction, one clock: 0 in, 1 out. Everything the lobe is -- its
    // height, the fade of its words -- is a function of it.
    property real _ext: chip.lobeWanted ? 1 : 0
    Behavior on _ext {
        NumberAnimation {
            duration: chip.lobeMs
            easing.type: Easing.OutCubic
        }
    }
    // A lobe of another shape (a figure gaining a digit) eases to it too.
    property real _lobeW: chip._lobeWTarget
    Behavior on _lobeW {
        enabled: chip._ext > 0.01
        NumberAnimation {
            duration: chip.lobeMs
            easing.type: Easing.OutCubic
        }
    }

    ShadowBoxLobe {
        id: box
        anchors.fill: parent
        visible: chip._shows
        sizeScale: chip._s
        baseRadius: chip.chipRadius
        surfaceColor: chip.surfaceColor
        backgroundColor: chip.chipColor
        bevelColor: chip.bevelColor
        shadowColor: chip.shadowColor
        bevelWidth: chip.bevelWidth
        shadowWidth: chip.shadowWidth
        lobeReach: Math.ceil(chip._lobeFullH)
        lobeRadius: chip.lobeRadius
        joinRadius: chip.lobeJoin
        // Whole pixels, so every edge of the lobe sits on the grid.
        lobeWidth: Math.round(chip._lobeW)
        lobeHeight: Math.round(chip._ext * chip._lobeFullH)
    }

    // The pointer is on the CHIP, never on the lobe: a lobe that took the hover
    // would hold itself out under a pointer that had left the chip for it, and
    // the figure is not something to press.
    HoverHandler {
        id: hov
        enabled: chip._shows && chip.lobeEnabled
    }

    // The figure. Its words fade in on the lobe's second half so they never
    // stand outside the shape that is still growing.
    DigitCells {
        id: figure
        x: Math.round((chip.width - figure.implicitWidth) / 2 - chip.letterSpacing * chip._s / 2)
        y: Math.round(-chip._lobeFullH + (chip._lobeFullH - figure.implicitHeight) / 2)
        opacity: Math.max(0, Math.min(1, (chip._ext - 0.5) * 2))
        visible: opacity > 0
        text: chip._lobeText
        fontFamily: chip.fontFamily
        pixelSize: chip.fontPixelSize * chip._s
        bold: true
        color: chip.tierColor
        separatorGap: chip.letterSpacing * chip._s / 2
        // each digit in its own advance (Audiowide's "1" in a "0"-wide cell read "1 997": the clock's kerning fault, feedback/clock.md);
        // the lobe's width comes from figureSlot below, so a VBR figure changing every status read never moves the lobe
        proportional: true
    }
    // The room the lobe reserves: the same figure in cells as wide as the widest digit (DigitCells' own rule for a host that must not
    // move when a digit changes) -- never drawn, only measured; the drawn figure is centred in it on whole pixels.
    DigitCells {
        id: figureSlot
        visible: false
        text: chip._lobeText
        fontFamily: chip.fontFamily
        pixelSize: chip.fontPixelSize * chip._s
        bold: true
        separatorGap: chip.letterSpacing * chip._s / 2
    }

    Text {
        id: label
        visible: chip._shows
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: -chip.letterSpacing * chip._s / 2
        text: chip._label
        color: chip.tierColor
        font: fm.font
    }

    // The silhouette. One bar the whole box, at the box's own radius: the
    // perimeter of the chip that will be there, not a bar inside a chip that
    // is not. It FADES out (showing, 160 ms) where the real box appears at
    // once, so the ghost dissolves under it rather than being cut.
    SkeletonBar {
        anchors.fill: parent
        // No `visible` gate: the bar's own presence fade is `showing`, and a
        // visible:false would cut the ghost the instant a track arrives
        // instead of letting it dissolve. At rest it is a 0x0 item.
        showing: chip.skeleton
        pulse: false
        barColor: chip.skeletonColor
        groundColor: chip.surfaceColor
        radius: chip.chipRadius * chip._s
        fadeMs: chip.fadeMs
    }
}
