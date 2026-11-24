pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/glyphs"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix
import "ArchivePose.js" as Pose

// =============================================================================
// SystemUpdateIcon.qml -- the system update in the bar.
//
// IDLE: the archive glyph (Nerd Font U+F187), a plain glyph button's in everything but its
// shape, NO ground behind it. THE GLYPH'S COLOUR IS THE AMOUNT (no dot, no count -- the quiet view
// has the count): the muted ink below `accentAt` (1: nothing to apply), the accent below `warnAt` (30), the warn
// colour below `errorAt` (150), the error colour from there. After a run that FAILED it is red
// whatever the count: something is waiting to be looked at. The pointer, and the popup being ours,
// take it to its own hover hue (BarHues `updateHover`), which is none of those levels, so a hover
// shows on every level.
//
// WHILE A RUN GOES it morphs into an assembly in silicon's bar style (SiliconBarFace): one carved
// pill with the archive glyph on the left (in the run's colour, the mark's and the bar's), the WHOLE RUN's percentage in a fixed digit slot, a mark for the
// phase on the right (the card's own glyph for it: download, disk, cog -- a question in the warn colour
// while yay waits to be answered, an exclamation in the error colour while the run is failing), and under
// them a slot-less progress bar (no groove: just the fill) stepped in whole pixels, so a long download costs
// one frame per pixel and not an animation per reading (the engine has no damage regions).
// When the run ends the assembly stays a moment on its last figure -- 100 and a check, or where it stopped
// and an exclamation -- and folds back into the glyph.
//
// WIDTH. The item's implicit width is the assembly's the moment a run begins (the glyph then slides to its
// place and the pill fades in inside it) and the glyph's only after the pill has faded out: drawn wider
// than its slot it would lie over its neighbours. The island's length follows the width however it
// follows it.
//
// THE FLOURISH (feedback/system_update.md "The bar icon flourish"): the pointer coming onto the idle glyph tosses its lid off
// while two papers rise out of the box, staggered in place and in time, drop back in, and the lid falls back on with a bounce
// (ArchivePose.js; GlyphFlourish: once per pointer entry, never restarted mid-play). Only the idle glyph plays it: in a run the
// glyph is part of the assembly (a per-step sequence for the run is a proposal for the user's verdict, not built). At rest the
// glyph is the plain Text (PosedGlyph) and nothing ticks.
//
// NOTHING ANIMATES A COLOUR. Hover (the bar's one hover clock), the level's presence and amount, the
// mark's state and the morph are eased FRACTIONS mixed into themed colours (Mix.js): at rest every value
// IS a Theme token.
//
// Inputs are plain values (the owner binds them from the service): the icon holds no parser and reads
// no file. `percent` and `mark` are the service's whole-run progress (SystemUpdateProgress.js).
// =============================================================================
Item {
    id: root

    // ---- the facts ----
    property int updatesAvailable: 0
    // The level's colour steps: muted below accentAt, accent below warnAt, warn below errorAt, error from there.
    property int accentAt: 1
    property int warnAt: 30
    property int errorAt: 150
    property bool running: false
    property int percent: 0                // the whole run, 0..100
    property string mark: "download"       // download | disk | cog | ask | fail
    property string outcome: ""            // what the last run left: "" | "ok" | "failed"
    property bool active: false            // the popup is open and ours
    property string orientation: "horizontal"
    property string fontFamily: "Audiowide"
    readonly property bool hovered: area.containsMouse
    signal clicked()

    // ---- the look ----
    readonly property string glyphFamily: "Symbols Nerd Font"
    readonly property string glyphArchive: ""
    property real glyphSize: 16
    property int padAlong: 8               // idle: the glyph's room each side (32 px wide, like the bell)
    property int padAcross: 4
    property int fadeMs: 160               // a state's colour coming and going (the level, the mark)
    property int morphMs: 220
    property int endHoldMs: 1500           // how long a finished run stays on its last figure

    // ---- the assembly's geometry (silicon's face: padX 9, padY 3, a 5 px gap after the glyph, 6 before the mark) ----
    readonly property int hPadX: 9
    readonly property int hPadY: 3
    readonly property int figureGap: 5
    readonly property int markGap: 6
    readonly property int markBox: 12
    readonly property int trackH: 3
    readonly property int faceOutside: 6   // the item's room round the pill, along the bar
    FontMetrics {
        id: fm
        font.family: root.fontFamily
        font.pixelSize: 11
        font.bold: true
    }
    // The widest figure is "100"; "%" is its own advance. Read with the metrics' font first (a method call in
    // a binding captures nothing: CLAUDE.md).
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
    readonly property int faceW: 2 * Math.ceil((2 * root.hPadX + root.glyphSize + root.figureGap + root.digitsW + root.pctW + root.markGap + root.markBox) / 2)
    readonly property int faceH: root.hPadY + Math.ceil(root.glyphSize) + 2 + root.trackH + root.hPadY

    // ---- what is shown: a run, and the moment after it ----
    property bool _held: false
    Timer {
        id: holdTimer
        interval: root.endHoldMs
        onTriggered: root._held = false
    }
    onRunningChanged: {
        if (root.running) {
            holdTimer.stop();
            root._held = false;
        } else if (root._shown) {
            // the run just ended: stay on the last figure
            root._held = true;
            holdTimer.restart();
        }
    }
    readonly property bool _shown: root.running || root._held
    property real asmF: root._shown ? 1 : 0
    Behavior on asmF {
        NumberAnimation {
            duration: root.morphMs
            easing.type: Easing.OutCubic
        }
    }

    // The slot: the assembly's the moment a run begins, the glyph's once the pill has gone.
    implicitWidth: root._shown || root.asmF > 0.001 ? root.faceW + 2 * root.faceOutside : Math.ceil(root.glyphSize + 2 * root.padAlong)
    implicitHeight: root._shown || root.asmF > 0.001 ? root.faceH + 2 * root.padAcross : Math.ceil(root.glyphSize + 2 * root.padAcross)

    // ---- the states, as eased fractions ----
    readonly property bool _ended: !root.running && root._held
    readonly property bool _okEnd: root._ended && root.outcome === "ok"
    readonly property bool _badEnd: root._ended && root.outcome === "failed"
    // The pointer (the glyph's hue and the pill's shade), and the popup being ours (the glyph's hue only: silicon's rule, only the
    // pointer is announced on the pill): each a fraction on the bar's one hover clock.
    property real hoverF: root.hovered ? 1 : 0
    Behavior on hoverF {
        GlyphHoverEase {}
    }
    property real activeF: root.active ? 1 : 0
    Behavior on activeF {
        GlyphHoverEase {}
    }
    property real askF: root.running && root.mark === "ask" ? 1 : 0
    property real failF: (root.running && root.mark === "fail") || root._badEnd ? 1 : 0
    property real doneF: root._okEnd ? 1 : 0
    Behavior on askF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on failF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on doneF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    // The run's colour: the accent, the warn colour while yay asks, the error colour while it fails, the ok colour at the end.
    readonly property color runColour: Mix.c(Mix.c(Mix.c(Theme.accent, Theme.warn, root.askF), Theme.error, root.failF), Theme.ok, root.doneF)

    // The level on the glyph: its presence, and the amount's colour in two steps (accent -> warn -> error), all fractions.
    readonly property bool _levelWanted: !root._shown && (root.updatesAvailable >= Math.max(1, root.accentAt) || root.outcome === "failed")
    property real levelF: root._levelWanted ? 1 : 0
    Behavior on levelF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    property real warnF: root.updatesAvailable >= root.warnAt ? 1 : 0
    property real errF: root.updatesAvailable >= root.errorAt || root.outcome === "failed" ? 1 : 0
    Behavior on warnF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    Behavior on errF {
        NumberAnimation {
            duration: root.fadeMs
            easing.type: Easing.OutCubic
        }
    }
    readonly property color levelColour: Mix.c(Mix.c(Theme.accent, Theme.warn, root.warnF), Theme.error, root.errF)

    // ---- the flourish ----
    property bool flourishEnabled: true
    property int flourishMs: 880
    readonly property alias flourish: lidFlourish
    GlyphFlourish {
        id: lidFlourish
        // the OLED care's name for it (FlourishRegistry): a motion that means nothing, so the random flourishes play it (the idle glyph only:
        // a demo plays where a hover would)
        group: "update"
        decorative: true
        armed: root.flourishEnabled
        ms: root.flourishMs
        overlap: "ignore"
        hoverArea: area
        // the idle glyph only: in a run it is the assembly's
        hoverPlays: !root._shown && root.asmF < 0.001
    }

    // ---- the pill's shade (silicon's: a step from the list box's fill toward the border, deeper under the pointer) ----
    readonly property real hoverDepth: 0.4
    readonly property color pillFill: Mix.c(Theme.listBox, Theme.border, root.hoverDepth * root.hoverF)
    readonly property color pillEdge: Mix.c(Theme.border, Theme.shadowDeep, root.hoverF)

    // ---- the assembly's pill ----
    Item {
        id: face
        width: root.faceW
        height: root.faceH
        x: Math.round((root.width - root.faceW) / 2)
        y: Math.round((root.height - root.faceH) / 2)
        opacity: root.asmF
        visible: root.asmF > 0.001

        ShadowBox {
            anchors.fill: parent
            baseRadius: Math.min(face.width, face.height) / 2
            bevelWidth: 0                       // no lit rim outside the edge: nothing is highlighted at rest
            shadowWidth: 2.5
            surfaceColor: "transparent"
            backgroundColor: root.pillFill
            bevelColor: Theme.bevel
            shadowColor: root.pillEdge
        }

        // the figure: right-aligned in a slot the width of "100", so it never moves what stands beside it
        Text {
            id: figure
            readonly property int slotX: root.hPadX + Math.ceil(root.glyphSize) + root.figureGap
            readonly property real rowCentre: root.hPadY + Math.ceil(root.glyphSize) / 2
            x: figure.slotX + root.digitsW - Math.ceil(figure.implicitWidth)
            y: Math.round(figure.rowCentre + root.capH / 2 - figure.baselineOffset)
            text: String(Math.max(0, Math.min(100, root.percent)))
            color: BarText.ink
            font: fm.font
        }
        Text {
            x: figure.slotX + root.digitsW
            y: figure.y
            text: "%"
            color: Theme.textMuted
            font: fm.font
        }

        // the phase mark: the card's glyph for the phase, the question / the exclamation / the check when it is those
        Text {
            id: markText
            x: root.faceW - root.hPadX - root.markBox + Math.round((root.markBox - markText.implicitWidth) / 2)
            y: root.hPadY + Math.round((Math.ceil(root.glyphSize) - markText.implicitHeight) / 2)
            text: root._okEnd ? "" : root._badEnd ? ""
                  : root.mark === "ask" ? "" : root.mark === "fail" ? ""
                  : root.mark === "disk" ? "" : root.mark === "cog" ? "" : ""
            color: root.runColour
            font.family: root.glyphFamily
            font.pixelSize: 11
        }

        // the slot-less progress bar: no groove, the fill alone, whole pixels
        Rectangle {
            id: fillBar
            readonly property int trackLen: root.faceW - 2 * root.hPadX
            readonly property int fillPx: Math.round(Math.max(0, Math.min(100, root.percent)) / 100 * fillBar.trackLen)
            x: root.hPadX
            y: root.hPadY + Math.ceil(root.glyphSize) + 2
            width: fillBar.fillPx
            height: root.trackH
            radius: root.trackH / 2
            antialiasing: true
            visible: fillBar.fillPx > 0
            color: root.runColour
        }
    }

    // ---- the glyph: one element that moves from the middle of the idle slot to the left of the pill ----
    PosedGlyph {
        id: glyph
        objectName: "updateGlyph"
        readonly property real idleX: (root.width - glyph.implicitWidth) / 2
        readonly property real idleY: (root.height - glyph.implicitHeight) / 2
        readonly property real asmX: face.x + root.hPadX + (Math.ceil(root.glyphSize) - glyph.implicitWidth) / 2
        readonly property real asmY: face.y + root.hPadY + (Math.ceil(root.glyphSize) - glyph.implicitHeight) / 2
        x: Math.round(glyph.idleX + (glyph.asmX - glyph.idleX) * root.asmF)
        y: Math.round(glyph.idleY + (glyph.asmY - glyph.idleY) * root.asmF)
        text: root.glyphArchive
        family: root.glyphFamily
        pixelSize: root.glyphSize
        // at rest the level (or the muted ink), during a run the run's colour, under the pointer the hover hue
        color: Mix.c(Mix.c(Mix.c(Theme.textMuted, root.levelColour, root.levelF), root.runColour, root.asmF),
                     BarHues.updateHover, Math.max(root.hoverF, root.activeF))
        posing: lidFlourish.playing
        parts: lidFlourish.playing ? Pose.path(lidFlourish.u, null, glyph.pixelSize, glyph.origin.x, glyph.origin.y) : []
    }

    MouseArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
