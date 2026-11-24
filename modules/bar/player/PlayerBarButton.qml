pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

import "../../common/theme"
import "../../common/glyphs"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "../../common/components/GlyphOutline.js" as Ease
import "../../audio/airplay"

// =============================================================================
// PlayerBarButton.qml -- the player's icon: md-album, U+F0025, STILL.
//
// The ink says the state and nothing moves at rest:
//
//   playing                 the player's ON hue (BarHues `playerOn`), as every bar glyph wears its own while it is on
//   anything else           the muted ink (paused, stopped, no player: the disc is the same full shape; the sound
//                           already says when something is playing, so the icon needs no separate paused look)
//
// The pointer takes it to its own hover hue (`playerHover`), which is not the on hue.
//
// THE FLOURISH, on a NEW TRACK (the song changes while the player is playing: the previous song was a song, so the
// shell starting on a running player is not one, and neither is stopping or resuming) and when the pointer comes onto the
// disc (GlyphFlourish: once per pointer entry, never restarted by it mid-spin; a new track mid-spin starts it over). A short WINDUP (the disc turns a
// little one way, `windupMs`), then a COASTING SPIN the other way that eases out (`coastMs`, OutCubic, `turns` whole turns,
// so it comes to rest upright), with a few faint MOTION LINES: short arcs round the disc that turn with it and fade as the
// spin slows (their opacity follows the spin's speed, (1 - u)^2 under an OutCubic).
//
// AIRPLAY. The flourish says "the song you hear changed", so while mpd plays into an AirPlay speaker it waits the sink's buffer
// (AirplayDelay.delayMs; 0 otherwise) after mpd's own song change. Every change waits, a skip made from the popup too: the sound it
// asked for is just as late. A newer change replaces the pending flourish; pausing or stopping drops it.
//
// An album is a symmetric disc, so a spin can only be seen in its lines: they differ in length and radius on purpose.
//
// NOTHING RUNS AT REST. The flourish is the bar glyphs' one flourish clock (GlyphFlourish), which runs only while it plays;
// there is no FrameAnimation and no timer (CLAUDE.md: a FrameAnimation behind a shared service wakes every window). The spin
// and the lines are functions of that clock (the windup's and the coast's easings, each on its share of it), and the clock
// holds still while the theme crossfades (a still picture of the old palette must not have a second copy of the lines moving
// under it).
//
// `player` is MpdService | PlayerMockRun (null = a still disc at rest).
// =============================================================================
BarGlyphButton {
    id: btn

    property var player: null

    // The flourish's numbers.
    property real windupDeg: 28
    property int windupMs: 150
    property int coastMs: 900
    property int turns: 2
    property real lineRadius: 3.2          // px beyond the glyph's own radius
    property real lineWidth: 1.2
    property real lineAlpha: 0.6

    glyph: String.fromCodePoint(0xF0025)

    readonly property bool _connected: !!btn.player && btn.player.connected === true
    readonly property string _state: btn.player ? String(btn.player.playState || "stop") : "stop"
    readonly property bool playing: btn._connected && btn._state === "play"

    property real _playF: btn.playing ? 1 : 0
    Behavior on _playF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    ink: Mix.c(Theme.textMuted, BarHues.playerOn, btn._playF)
    hoverInk: BarHues.playerHover

    // ---- the flourish ----------------------------------------------------------------------------------------------
    GlyphFlourish {
        id: spin
        // the OLED care's name for it (FlourishRegistry): it says a new song began, so it plays at random only when switched on
        group: "player"
        ms: btn.windupMs + btn.coastMs
        overlap: "restart"
        hoverArea: btn.area
    }
    readonly property alias flourishClock: spin
    readonly property bool flourishing: spin.playing
    // The windup's share of the clock, then the coast's: the turn and the lines' presence read off one clock.
    readonly property real _w: btn.windupMs / Math.max(1, btn.windupMs + btn.coastMs)
    readonly property real _spin: {
        if (!spin.playing)
            return 0;
        const u = spin.u;
        if (u < btn._w)
            return btn.windupDeg * Ease.inOutQuad(u / btn._w);
        return btn.windupDeg + (-360 * btn.turns - btn.windupDeg) * Ease.outCubic((u - btn._w) / (1 - btn._w));
    }
    readonly property real _lines: {
        if (!spin.playing)
            return 0;
        const u = spin.u;
        if (u < btn._w)
            return 0.35 * Ease.outQuad(u / btn._w);
        const v = (u - btn._w) / (1 - btn._w);
        return v < 0.1 ? 0.35 + 0.65 * Ease.outQuad(v / 0.1) : 1 - Ease.outQuad((v - 0.1) / 0.9);
    }
    glyphRotation: btn._spin

    // The id of the song that was current, to tell a NEW track from the first one the shell hears of.
    property int _lastSong: -1
    Connections {
        target: btn.player
        ignoreUnknownSignals: true
        function onSongIdChanged(): void {
            const id = btn.player.songId;
            const was = btn._lastSong;
            btn._lastSong = id;
            if (was >= 0 && id >= 0 && id !== was && btn.playing) {
                if (AirplayDelay.delayMs > 0) {
                    lag.interval = AirplayDelay.delayMs;
                    lag.restart();
                } else {
                    lag.stop();
                    btn.flourish();
                }
            }
        }
    }
    // the flourish waiting for the sound; a song that stops being played is no new track anybody hears
    Timer {
        id: lag
        onTriggered: if (btn.playing) btn.flourish()
    }
    onPlayingChanged: if (!btn.playing) lag.stop()
    // The song already current when the player arrives (the shell's service appears after the button on a slow start) is the
    // "was", not a new track.
    function _seed(): void {
        btn._lastSong = btn.player && btn.player.songId !== undefined ? btn.player.songId : -1;
    }
    onPlayerChanged: btn._seed()
    Component.onCompleted: btn._seed()

    function flourish(): void {
        spin.play("song");
    }

    // The motion lines: arcs round the disc, turning with it (they are in the glyph's rotated square). Unequal on purpose.
    Shape {
        id: lines
        readonly property real pad: 8
        x: -lines.pad
        y: -lines.pad
        width: Math.ceil(btn.glyphSize) + 2 * lines.pad
        height: width
        visible: btn._lines > 0.002
        opacity: btn._lines * btn.lineAlpha
        preferredRendererType: Shape.CurveRenderer
        readonly property real cx: width / 2
        readonly property real cy: height / 2
        readonly property real r: btn.glyphSize / 2 + btn.lineRadius

        component Arc: ShapePath {
            id: arc
            property real from: 0
            property real sweep: 30
            property real radius: lines.r
            strokeColor: btn.ink
            strokeWidth: btn.lineWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathAngleArc {
                centerX: lines.cx
                centerY: lines.cy
                radiusX: arc.radius
                radiusY: arc.radius
                startAngle: arc.from
                sweepAngle: arc.sweep
            }
        }
        Arc { from: 20; sweep: 40; radius: lines.r }
        Arc { from: 150; sweep: 26; radius: lines.r + 1.4 }
        Arc { from: 255; sweep: 14; radius: lines.r + 0.4 }
    }
}
