pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"
import "../../common/components/Mix.js" as Mix

// =============================================================================
// SiliconBarFace.qml -- the bar button's face: ONE carved pill holding everything, the way the
// audio and network buttons are one pill. MIRRORED AROUND THE FIGURE (feedback/silicon.md "Bar dgpu indicator"): the profile glyph, the figure, the GPU's
// glyph in a box of the same size, one gap either side, as the CPU and the GPU sit apart on the popup's board. Under them runs a thin carved
// track, the charge lying in it (with the charge limit on the track is scaled to the limit, so it fills at 80 %). On a side bar the
// same stack: profile glyph, figure, track, GPU glyph, in a narrow capsule.
//
// THE POINTER'S ZONES. The button has ONE MouseArea; which glyph the pointer is on is arithmetic here (`zoneAt`), so each glyph's
// flourish plays for a pointer on THAT glyph (feedback/silicon.md "GPU mode icon redesign") and the figure and the track play nothing.
//
// THE PILL'S SHADE. At rest nothing about the pill is lit: no bevel rim outside
// its edge, and the edge itself is the soft inset the audio and network pills have (`border`, not a
// hard `shadowDeep` line). Under the pointer the whole inset sinks one shade -- the sunk
// fill deeper and the edge down to `shadowDeep` -- as ONE eased fraction (the button's `hoverF`) mixing
// themed colours, nothing else about the button moves. The track's empty groove lies a step deeper than
// the fill it is carved into, and follows the fill when that deepens.
//
// The figure sits in a slot as wide as "100" (and a muted "%" after it where there is room), so it never moves what stands beside it. Inside the slot
// the digits and the "%" stand CENTRED for the digits they have, placed by the widest digits of that count and not by the text's own width: a charge
// changing from 81 to 80 moves nothing, and only 100 -> 99 and 10 -> 9 shift the pair (half a digit), where the symmetry would otherwise
// stand a whole digit off. A charge that changes ROLLS, as the clock's figures do (DigitCells, each figure in its own exact
// advance, so it sets as the plain Text did); a change of the digit count (100 -> 99, 10 -> 9) swaps at once. A tweaked profile wears a small dot on its
// glyph's corner in the tweak hue.
//
// Laid out in the SCREEN frame; SiliconBarButton counter-rotates it against its bar, so the
// glyph and the figure stand upright on every edge.
// =============================================================================
Item {
    id: face

    required property var host
    readonly property bool v: face.host.vertical

    // what a geometry probe measures: the glyph's box, the figure, and what it is centred on
    // (the glyph's row on a top bar, the pill's axis on a side bar)
    readonly property Item glyphItem: glyph
    readonly property Item pillItem: pill

    readonly property int glyphBox: 14
    readonly property int trackH: 4

    // ---- the pill's shade ----
    // A STEP is the way from a box's fill toward `border`: the theme draws that about 8 L* below `listBox` in
    // both modes (light #E5E8EF -> #CED1D7, dark #282C34 -> #181A1F), which is why one fraction serves both,
    // where the tokens between them are ordered differently (headerBox is the deeper in light, panelSunk in dark).
    //   hover   0.4 of a step: the fill goes 3.2 L* deeper in light, 3.3 in dark.
    //   groove  0.65 of a step below whatever the fill is now: 5.3 L* at rest in light, 5.6 in dark.
    readonly property real hoverDepth: 0.4
    readonly property real grooveDepth: 0.65
    readonly property color pillFill: Mix.c(Theme.listBox, Theme.border, face.hoverDepth * face.host.hoverF)
    readonly property color pillEdge: Mix.c(Theme.border, Theme.shadowDeep, face.host.hoverF)
    readonly property color grooveFill: Mix.c(face.pillFill, Theme.border, face.grooveDepth)

    FontMetrics {
        id: fm
        font.family: face.host.fontFamily
        font.pixelSize: 11
        font.bold: true
    }
    // What the system matched: a face with no bold of its own (Audiowide) comes back in its Regular style, and a bold Qt
    // synthesizes lays a Text out one pixel wider than its advances (UndoDrainButton). The figure keeps the room a plain Text of
    // it had: the cells are its exact advances, so the pixel is added where the figure is placed.
    FontInfo {
        id: matched
        font: fm.font
    }
    readonly property int _synthBold: fm.font.bold && !/bold|black|heavy/i.test(matched.styleName) ? 1 : 0
    // The widest figure is "100"; "%" is its own advance. Read with the metrics' font first.
    readonly property int digitsW: {
        const f = fm.font;
        return Math.ceil(fm.advanceWidth("100")) + 1;
    }
    readonly property int pctW: {
        const f = fm.font;
        return Math.ceil(fm.advanceWidth("%")) + 1;
    }
    readonly property real capH: {
        const f = fm.font;
        return fm.capitalHeight;
    }
    // the digits' room for a figure of 1, 2 and 3 digits (the widest digit's, not this figure's)
    readonly property var digitsFor: {
        const f = fm.font;
        return [0, Math.ceil(fm.advanceWidth("0")) + 1, Math.ceil(fm.advanceWidth("00")) + 1, face.digitsW];
    }

    // ---- horizontal: padX glyph gap figure % gap GPU glyph padX, the track under the row ----
    readonly property int hPadX: 9
    readonly property int hGap: 6
    readonly property int hPadY: 3
    readonly property int hRow: face.glyphBox                 // the row's height
    readonly property int hW: 2 * Math.ceil((2 * face.hPadX + 2 * face.glyphBox + 2 * face.hGap + face.digitsW + face.pctW) / 2)
    readonly property int hH: face.hPadY + face.hRow + 2 + face.trackH + face.hPadY

    // ---- vertical: a capsule, one axis: glyph, figure, track, GPU glyph ----
    readonly property int vW: 30
    readonly property int vPadY: 7
    readonly property int vFigureTop: face.vPadY + face.glyphBox + 3
    readonly property int vFigureH: Math.ceil(face.capH)
    readonly property int vTrackY: face.vFigureTop + face.vFigureH + 4
    readonly property int vGpuY: face.vTrackY + face.trackH + 3
    readonly property int vH: 2 * Math.ceil((face.vGpuY + face.glyphBox + face.vPadY) / 2)

    implicitWidth: face.v ? face.vW : face.hW
    implicitHeight: face.v ? face.vH : face.hH

    ShadowBox {
        id: pill
        anchors.fill: parent
        baseRadius: Math.min(face.width, face.height) / 2
        bevelWidth: 0                       // no lit rim outside the edge: nothing is highlighted at rest
        shadowWidth: 2.5
        surfaceColor: "transparent"
        backgroundColor: face.pillFill
        bevelColor: Theme.bevel             // no bevel is drawn; bound all the same, so no component default can show
        shadowColor: face.pillEdge
    }

    // ---- the glyph ----
    SiliconBarGlyph {
        id: glyph
        x: face.v ? Math.round((face.width - face.glyphBox) / 2) : face.hPadX
        y: face.v ? face.vPadY : face.hPadY
        profile: face.host.profile
        color: face.host.profileHue
        pixelSize: 14
        box: face.glyphBox
        // the flourish bends the glyph's own outline (SiliconGlyphPose.js); at rest it is the plain Text
        flexing: flourish.playing
        flexU: flourish.u
        flexStrength: flourish.strength
    }
    // the profile glyph's flourish (SiliconBarFlourish: its clock and its events; the glyph draws the pose)
    readonly property alias flourishItem: flourish
    SiliconBarFlourish {
        id: flourish
        armed: face.host.flourishEnabled
        loadEnabled: face.host.flourishLoad
        kind: face.host.profile
        ms: face.host.flourishMs
        load: face.host.cpuLoad
        loadLook: ({ holdMs: face.host.flourishHoldMs })
    }
    // the tweak dot, on the glyph's top-right corner
    Rectangle {
        id: tweakDot
        property real tweakF: face.host.tweaked ? 1 : 0
        x: glyph.x + face.glyphBox - 3
        y: glyph.y - 1
        width: 5
        height: 5
        radius: 2.5
        antialiasing: true
        color: face.host.tweakHue
        visible: tweakDot.tweakF > 0.001
        opacity: tweakDot.tweakF
        Behavior on tweakF {
            NumberAnimation {
                duration: 160
                easing.type: Easing.OutCubic
            }
        }
    }

    // ---- the figure: right-aligned in a slot the width of "100" (centred on a side bar), a cell per digit (the clock's roll) ----
    // The roll: the clock's (ClockBarButton rollMs / rollStaggerMs).
    readonly property int rollMs: 320
    readonly property int rollStaggerMs: 50
    DigitCells {
        id: figure
        objectName: "siliconFigure"
        readonly property int slotX: face.hPadX + face.glyphBox + face.hGap
        // where the digits end and the "%" starts: the pair stands centred in the slot for the digits this figure has
        readonly property int room: face.digitsFor[Math.max(1, Math.min(3, figure.text.length))]
        readonly property int digitsEnd: figure.slotX + Math.round((face.digitsW - figure.room) / 2) + figure.room
        readonly property real rowCentre: face.v ? face.vFigureTop + face.vFigureH / 2 : face.hPadY + face.hRow / 2
        // the cells' width glides with a roll; the right edge (the "%") stays, and a side bar's figure stays centred -- each where
        // the plain Text of the same digits stood (its laid-out width: the exact advances and a synthesized bold's pixel, rounded up)
        readonly property int textWidth: Math.ceil(figure.implicitWidth + face._synthBold)
        x: face.v ? Math.round((face.width - figure.textWidth) / 2)
                  : figure.digitsEnd - figure.textWidth
        y: Math.round(figure.rowCentre + face.capH / 2 - fm.ascent)
        text: String(Math.round(Math.max(0, Math.min(100, face.host.percent))))
        color: BarText.ink
        fontFamily: fm.font.family
        pixelSize: fm.font.pixelSize
        bold: fm.font.bold
        proportional: true
        exactAdvances: true
        glide: true
        rolling: face.host.liveMotion
        rollMs: face.rollMs
        staggerMs: face.rollStaggerMs
    }
    Text {
        id: percentSign
        visible: !face.v
        x: figure.digitsEnd
        y: figure.y
        text: "%"
        color: Theme.textMuted
        font: fm.font
    }

    // ---- the GPU's glyph: the profile glyph's box, mirrored ----
    readonly property alias gpuItem: gpuGlyph
    SiliconBarGpu {
        id: gpuGlyph
        x: face.v ? Math.round((face.width - face.glyphBox) / 2) : face.width - face.hPadX - face.glyphBox
        y: face.v ? face.vGpuY : face.hPadY
        box: face.glyphBox
        pixelSize: 14
        // not drawn until the mode is a fact, and not live: the facts arriving snap in (no flourish for a first value), then it fades in
        opacity: face.host.gpuKnown ? 1 : 0
        Behavior on opacity {
            NumberAnimation { duration: 160 }
        }
        mode: face.host.gpuMode
        inUse: face.host.gpuInUse
        pending: face.host.muxPending
        known: face.host.gpuKnown
        breathF: face.host.breathF
        breath: face.host.breath
        live: face.host.liveMotion && face.host.gpuKnown
        flourish: face.host.flourishEnabled && face.host.gpuFlourish
        ms: face.host.flourishMs
        fadeAlpha: face.host.gpuFadeAlpha
        litMs: face.host.gpuLitMs
    }

    // ---- the pointer's zones ----
    // Which glyph a point of the face is on: 0 the profile glyph, 1 the GPU's, -1 neither. A glyph's zone is its box, out to the
    // pill's end on its own side and half the gap toward what stands next to it, the whole way across the pill.
    function zoneAt(fx: real, fy: real): int {
        const along = face.v ? fy : fx;
        const half = face.v ? 1.5 : face.hGap / 2;
        if (along < (face.v ? glyph.y : glyph.x) + face.glyphBox + half)
            return 0;
        return along >= (face.v ? gpuGlyph.y : gpuGlyph.x) - half ? 1 : -1;
    }

    // ---- the track ----
    SiliconBarCell {
        id: track
        x: face.v ? Math.round((face.width - length) / 2) : face.hPadX
        y: face.v ? face.vTrackY : face.hPadY + face.hRow + 2
        length: face.v ? face.width - 12 : face.width - 2 * face.hPadX
        thickness: face.trackH
        radius: 2
        pad: 1
        bevelWidth: 0.5
        shadowWidth: 1
        fillBevelWidth: 0.3
        fillShadowWidth: 0.5
        fillRadiusOffset: 0
        grooveColor: face.grooveFill
        grooveShadow: Theme.border
        percent: face.host.percent
        fillColor: face.host.fillColour
        fullPercent: face.host.limitOn ? face.host.limitPercent : 100
        pulseProgress: face.host.pulseProgress
        pulseColor: face.host.pulseColour
    }

    // ---- the event ring, round the whole pill ----
    Rectangle {
        readonly property real s: 1 + 5 * (1 - Math.pow(1 - face.host.pulseProgress, 3))
        visible: face.host.pulseProgress < 1
        x: -s
        y: -s
        width: face.width + 2 * s
        height: face.height + 2 * s
        radius: Math.min(width, height) / 2
        antialiasing: true
        color: "transparent"
        border.width: 1.5
        border.color: face.host.pulseColour
        opacity: 0.9 * Math.pow(1 - face.host.pulseProgress, 1.4)
    }
}
