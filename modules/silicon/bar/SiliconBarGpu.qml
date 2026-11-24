pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "SiliconGpuPose.js" as Pose

// =============================================================================
// SiliconBarGpu.qml -- the GPU in the bar: ONE glyph that says the MODE, the same size as the profile glyph and on the far side
// of the figure from it, as the two sit apart on the popup's board (feedback/silicon.md "GPU mode icon redesign"). The set is
// the CPU profile's cousin, glyph for glyph in the hue the two ladders already share:
//
//   0 Integrated  md-feather    (the leaf's green)     light: the big card is off
//   1 Smart       md-lightbulb  (its own cyan)         the card for the apps on the list
//   2 Hybrid      md-layers     (the scales' blue)     both, one over the other
//   3 dGPU-only   md-fire       (the bolt's orange)    everything on the big card
//
// WHAT EACH FACT DRAWS:
//   IN USE       the mode's hue at full. Something real is on the card (`gpu.inUse`: the session's own plumbing does not count,
//                and awake with nobody on it is idle). dGPU-only is always this: the card IS the display -- and so is a card that
//                drives an external display on its HDMI connector.
//   IDLE         the same glyph at `fadeAlpha`. Asleep and awake-with-nobody-on-it read the same.
//   INTEGRATED   the feather at full strength: the iGPU is always the one drawing. Chosen with apps still on the card
//                (cardwire blocks only NEW opens, so they run on), the mode they came from stays, lit, until the last has
//                gone, as the popup's card waits half-seated.
//   MUX PENDING  the glyph in dGPU-only's hue, breathing on the host's stepped clock (an opacity and a scale).
//   NOT KNOWN    the host draws nothing (its opacity) and nothing here moves: a first mode is no event.
//
// THE FLOURISH is the glyph's own motion (SiliconGpuPose.js: the feather is caught by a gust, the bulb has its idea, the stack opens, the
// fire flares), on the bar glyphs' one flourish contract (GlyphFlourish): it plays when the pointer comes onto THIS glyph (the
// host feeds `flourishClock.pointerAt`: the button's one MouseArea finds the glyph by arithmetic), when a mode's glyph arrives
// ("mode"), and when the card wakes ("wake", a little harder). Going idle only fades. While it plays the plain Text gives way
// to the glyph's posed outline (PosedGlyph); at rest nothing ticks and nothing asks for a frame.
//
// NOTHING ANIMATES A COLOUR. `ink` and `presence` are Mix.js of Theme tokens by eased fractions; the picture at rest is the token.
//
// A harness sets `live: false`: the light then follows its fact at once.
// =============================================================================
Item {
    id: gpu

    // ---- the facts ----
    property int mode: 2                    // 0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only
    property bool inUse: false              // the card is working, not merely awake
    property bool pending: false            // a MUX switch waits for its restart
    property bool known: true               // the mode is a fact: before it, no flourish (the host does not draw this at all)
    property real breathF: 0                // 0 steady .. 1 breathing (the host's, eased)
    property real breath: 1                 // 0 exhaled .. 1 inhaled (the host's stepped clock)

    // ---- the look ----
    property int box: 14
    property int pixelSize: 14
    property real fadeAlpha: 0.42           // the glyph with nobody on the card

    // ---- the motion ----
    property bool live: true
    property bool flourish: true
    property int ms: 900                    // one flourish (the bulb's; the others run their own share of it, Pose.time)
    property int litMs: 420

    // ---- derived ----
    // the last mode that had the card: it stays, lit, while Integrated still has apps on it
    property int _lastMode: 2
    readonly property int shownMode: gpu.mode === 0 && gpu.inUse ? gpu._lastMode : gpu.mode
    // md-feather F06D3, md-lightbulb F0335, md-layers F0328, md-fire F0238 (tools/dev/flourish_parts.py holds the font to them)
    readonly property var _glyphs: [0xF06D3, 0xF0335, 0xF0328, 0xF0238]
    readonly property string text: String.fromCodePoint(gpu._glyphs[Math.max(0, Math.min(3, gpu.shownMode))])
    readonly property var hues: SiliconBarHues {}
    readonly property color ink: Mix.c(gpu.hues.gpu(gpu.shownMode), gpu.hues.gpu(3), gpu.breathF)
    // a breath is the glyph's own alpha: a pending switch is not "faded", or the bottom of the breath would be next to nothing
    readonly property real _light: Math.max(gpu.lit, gpu.breathF)
    readonly property real presence: gpu.shownMode === 0 ? 1 : gpu.fadeAlpha + (1 - gpu.fadeAlpha) * gpu._light
    readonly property real _breathAlpha: 1 - gpu.breathF * (1 - (0.42 + 0.58 * gpu.breath))
    readonly property real _breathScale: 1 - gpu.breathF * (1 - (0.94 + 0.09 * gpu.breath))
    // a probe's reading: something is on its way (a flourish, the light)
    readonly property bool moving: clock.playing || gpu.lit !== (gpu.inUse ? 1 : 0)

    implicitWidth: gpu.box
    implicitHeight: gpu.box

    // ---- the light: one eased fraction ----
    property real lit: gpu.inUse ? 1 : 0
    Behavior on lit {
        enabled: gpu.live
        NumberAnimation {
            duration: gpu.litMs
            easing.type: Easing.InOutQuad
        }
    }

    // ---- the flourish ----
    readonly property alias flourishClock: clock
    property real strength: 1
    GlyphFlourish {
        id: clock
        group: "silicon"
        glyph: "gpu"
        host: gpu
        shown: gpu.known
        armed: gpu.flourish && gpu.known
        ms: Math.round(gpu.ms * Pose.time(gpu.shownMode))
        overlap: "restart"
        // `why`: "hover" | "mode" | "wake" | "random" -- how hard it plays
        onPlayed: why => gpu.strength = why === "wake" ? 1.2 : 1
    }
    // Events count only once the facts have stood for a turn: the values a build binds are no events, and neither is the mode
    // that lands in the turn the facts become known (whichever of the two the host's bindings write first).
    property bool _ready: false
    function _arm(): void {
        gpu._ready = gpu.known;
    }
    onKnownChanged: {
        gpu._ready = false;
        if (gpu.known)
            Qt.callLater(gpu._arm);
    }
    Component.onCompleted: {
        if (gpu.mode > 0)
            gpu._lastMode = gpu.mode;
        Qt.callLater(gpu._arm);
    }
    onModeChanged: {
        if (gpu.mode > 0)
            gpu._lastMode = gpu.mode;
    }
    onShownModeChanged: {
        if (gpu._ready)
            clock.play("mode");
    }
    // the card wakes under the glyph that stands (in Integrated the glyph itself changes: that is the mode's play)
    onInUseChanged: {
        if (gpu._ready && gpu.inUse && gpu.mode !== 0)
            clock.play("wake");
    }

    // ---- the picture ----
    readonly property var pose: clock.playing ? Pose.pose(gpu.shownMode, clock.t, clock.ms, gpu.strength, null, posed.pixelSize,
                                                          posed.origin.x, posed.origin.y) : null
    readonly property alias glyphItem: posed
    Item {
        width: gpu.box
        height: gpu.box
        opacity: gpu.presence * gpu._breathAlpha
        scale: gpu._breathScale
        transformOrigin: Item.Center

        // Placed by its INK, as the profile glyph is (SiliconBarGlyph): every Material glyph of this font is centred on 614 / 2048 em
        // above the baseline and on half its advance.
        PosedGlyph {
            id: posed
            x: Math.round(gpu.box / 2 - posed.implicitWidth / 2)
            y: Math.round(gpu.box / 2 + 0.2998 * gpu.pixelSize - posed.origin.y)
            text: gpu.text
            pixelSize: gpu.pixelSize
            color: gpu.ink
            posing: clock.playing
            parts: gpu.pose ? gpu.pose.parts : []
            shades: gpu.pose ? gpu.pose.shades : []
        }
    }
}
