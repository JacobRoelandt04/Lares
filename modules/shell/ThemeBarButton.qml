pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/glyphs"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "parts/SwatchPose.js" as Pose

// =============================================================================
// ThemeBarButton.qml -- the theme switch's icon: a swatch book, a fan of colour cards on one rivet (feedback/themectl.md "Icon
// overhaul + flourish": the sun and the moon it was are the weather's and the idle reel's already).
//
//   md-palette_swatch  U+F08B5   the FILLED swatch, in light mode and in dark
//
// ONE GLYPH IN BOTH MODES (feedback/general.md "Last flourishes", the second review: the outlined twin dark mode wore is gone;
// the user does not like outlined icons). The mode is the whole desktop's to show, not this icon's. The click is the host's
// (ShellFrame: left opens the theme popup, right is ThemeControl's light/dark); this only draws, and says in its ink what the
// control is doing:
//
//   a switch in progress   (`control.active` > 0: themectl's children are running)   a share of the accent
//   a switch that failed   (`control.fails` went up)                                  a share of the warn colour, for FAILED_MS
//
// Both are SUBTLE (a share of the way, not the colour) and both are eased fractions mixed with Mix.js -- never a Behavior
// on the colour, which the theme's own crossfade would drag behind everything else. The pointer takes it to its own hover hue
// (BarHues `themeHover`: the yellow family first -- no meaning of the swatch's, but the one hue nothing else in the left island
// wears, and neither of the two tints).
//
// THE FLOURISH: THE SWATCH BOOK IS FLIPPED -- it leans back, snaps shut and turns once in the air, and as the card in front
// lands the cards behind fan out from under it, a little too wide, and settle (SwatchPose.js). It plays when the pointer comes
// onto the icon (GlyphFlourish: once per entry, on the first motion after it) and in the OLED care's random turns (group
// `theme`, decorative). It keeps whatever ink the button has, and the swatch stays the filled swatch through every frame (its
// rivet a hole, a gap between two cards). This button is the one that starts a theme crossfade: the flourish's clock holds
// still through it like every flourish's (GlyphFlourish), so a right click while the book is in the air freezes it there for
// the fade and it lands when the fade is over.
// =============================================================================
BarGlyphButton {
    id: btn

    // ThemeControl (null = nothing to say).
    property var control: null
    property int failedMs: 6000
    // How far the tint takes the ink.
    property real busyShare: 0.55
    property real failedShare: 0.75

    // the glyph by its codepoint, hex: the key its outline is filed under (SwatchParts.js). The same in light and in dark.
    readonly property string glyphKey: "f08b5"
    glyph: String.fromCodePoint(parseInt(btn.glyphKey, 16))

    readonly property bool _busy: !!btn.control && btn.control.active > 0
    property real _busyF: btn._busy ? 1 : 0
    Behavior on _busyF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    // A failed run lights the warn tint for `failedMs` and lets it go; the count only ever goes up.
    property bool _failed: false
    property real _failedF: btn._failed ? 1 : 0
    Behavior on _failedF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    readonly property int _fails: btn.control ? btn.control.fails : 0
    on_FailsChanged: {
        if (btn._fails > 0) {
            btn._failed = true;
            failedTimer.restart();
        }
    }
    Timer {
        id: failedTimer
        interval: btn.failedMs
        onTriggered: btn._failed = false
    }

    ink: Mix.c3(Theme.textMuted, Theme.accent, btn.busyShare * btn._busyF, Theme.warn, btn.failedShare * btn._failedF)
    hoverInk: BarHues.themeHover

    // ---- the flourish ----
    property bool flourishEnabled: true
    readonly property alias flourish: flip
    GlyphFlourish {
        id: flip
        group: "theme"
        decorative: true
        armed: btn.flourishEnabled
        ms: Pose.LIFE
        // a second ask while it plays is ignored: a restart would snap the book back out of its turn
        overlap: "ignore"
        hoverArea: btn.area
    }
    readonly property var _pose: flip.playing ? Pose.frame(btn.glyphKey, flip.t, flip.ms, null, btn.glyphSize, btn.glyphOrigin.x, btn.glyphOrigin.y) : null
    posing: flip.playing
    parts: btn._pose ? btn._pose.parts : []
}
