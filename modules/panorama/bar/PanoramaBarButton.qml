pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/glyphs"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "PanoramaPanes.js" as Pose

// =============================================================================
// PanoramaBarButton.qml -- the panorama's bar glyph (docs/contracts/panorama.md section 6; PLAN decision 9): ALWAYS in the machine
// island, ONE monitor of a constant size whose screen is divided into the displays in use (one, two, three; past three a "+" cut
// into the last column) and, while the displays mirror, a mirror mark cut into the first; windows are tiled on every screen that carries
// no mark. No key, no right click, no swipe: a left click is `clicked(Qt.LeftButton)` and the host toggles the popup.
//
// THE GLYPH IS DRAWN BY PanoramaPanes.js, never by the font: the button names md-monitor (U+F0379) as its text only for that glyph's
// box (the same em as every bar glyph, so the island's size is fixed), and the pose is always on. THE INK'S BOX NEVER CHANGES with the
// count or the flourish (PanoramaPanes.js `INK`): a display comes by a gap opening inside the monitor's screen.
//
// THE INK is one hue: `hueOff` (the muted ink) at rest, `hueOn` (mirroring: something unusual is on) and the pointer's `hueHover`, all
// eased fractions mixed with Mix.js (never a Behavior on a colour).
//
// THE MOTION: ONE clock for the count (`_count`, linear), the gaps open or close from it, one pane after another (OutBack, in the pose),
// and the windows move with their screens; the "+" and the mirror mark each ease their own fact (`_plus`, `_mirror`, 260 ms OutCubic).
// The random OLED-care flourish (GlyphFlourish group "panorama", decorative) melts the windows away and deals them in again (a mark
// dips and springs back); a hover plays it too, and `deal()` plays it for the host (a preset that was loaded).
//
// A CAST BEING MADE (`working`, the owner's word: PanoramaService.castWorking; the user's call, 2026-11-22) takes the hover hue and deals over and
// over until it is over. EACH TURN PLAYS WHOLE: the stream that comes up, a failure, a stop only mean that no further one is started, and the ink
// eases back when the turn in the air has landed (`_inked`). Between two turns the glyph rests `breathMs` (its windows stand, which is what says
// that each turn is one thing, and the OLED care's pixel step, which waits while a flourish plays, gets its moment). The turns are the flourish's
// own runs: one clock, only while one plays, held through a theme crossfade. A hover, the OLED care and the preset's deal start nothing meanwhile.
//
// What the host passes: `panes`, `mirroring`; `hueOn` / `hueHover` when the host has BarHues roles for them (the defaults are the
// theme's accent), `flourishEnabled`; the owner writes `working`.
// =============================================================================
BarGlyphButton {
    id: btn

    // displays in use (enabled and not mirroring): 1, 2, 3; more is drawn as three and a "+"
    property int panes: 1
    property bool mirroring: false
    // a cast is being made or made again
    property bool working: false
    // a cast is going on, from the click to its end: the glyph keeps the hover hue (no turns: those are `working`'s)
    property bool casting: false
    property int breathMs: 320
    property bool flourishEnabled: true
    // the hues: muted at rest, `hueOn` while mirroring, `hueHover` under the pointer
    property color hueOff: Theme.textMuted
    property color hueOn: Theme.accent
    property color hueHover: Theme.accent

    readonly property int shown: Math.max(1, Math.min(3, btn.panes))
    readonly property bool plus: btn.panes > 3

    // ---- the eased facts ----
    property real _count: btn.shown
    Behavior on _count {
        NumberAnimation {
            duration: 420
            easing.type: Easing.Linear
        }
    }
    property real _plus: btn.plus ? 1 : 0
    Behavior on _plus {
        NumberAnimation {
            duration: 260
            easing.type: Easing.OutCubic
        }
    }
    property real _mirror: btn.mirroring ? 1 : 0
    Behavior on _mirror {
        NumberAnimation {
            duration: 260
            easing.type: Easing.OutCubic
        }
    }

    // the hue of a cast: from its first moment to its end (and to the end of the last turn it started)
    readonly property bool _inked: btn.working || btn.casting || (blink.playing && blink.why === "cast")
    property real _work: btn._inked ? 1 : 0
    Behavior on _work {
        GlyphHoverEase {}
    }

    // the glyph's text is only its box: the pose is always on
    glyph: String.fromCodePoint(0xF0379)
    ink: Mix.c(Mix.c(btn.hueOff, btn.hueOn, btn._mirror), btn.hueHover, btn._work)
    hoverInk: btn.hueHover
    posing: true
    pointerCursor: true

    // a play as a hover plays it, through the flourish's demo path (armed, not already playing); true when it started
    function deal(): bool {
        return blink.demo();
    }

    // ---- the flourish ----
    readonly property alias flourish: blink
    GlyphFlourish {
        id: blink
        group: "panorama"
        decorative: true
        armed: btn.flourishEnabled
        ms: Pose.LIFE
        // a second ask while it plays is ignored: a restart would snap the dealt tiles back mid-run
        overlap: "ignore"
        hoverArea: btn.area
        // while the turns go on by themselves nothing else starts one
        hoverPlays: !btn.working
        onFinished: btn._breathe()
    }
    // the turns of a cast being made: one at once, the next a breath after one has ended -- whoever asked for it (a hover's that was in the air)
    onWorkingChanged: btn._turn()
    function _turn(): void {
        if (btn.working && !breath.running)
            blink.play("cast");
    }
    function _breathe(): void {
        if (btn.working)
            breath.restart();
    }
    Timer {
        id: breath
        interval: btn.breathMs
        onTriggered: btn._turn()
    }
    readonly property var _pose: Pose.frame({ count: btn._count, plus: btn._plus, mirror: btn._mirror },
                                            blink.playing ? blink.t : 0, blink.ms, null, btn.glyphSize, btn.glyphOrigin.x, btn.glyphOrigin.y)
    parts: btn._pose.parts
    shades: btn._pose.shades
}
