pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components/Mix.js" as Mix
import "WikiVeilPick.js" as Pick

// =============================================================================
// WikiVeil.qml -- the picture of an article that has none: a slow pattern in
// the card's own material, on the floor of the picture well.
//
// WHICH ONE. `seedKey` is the article's id; WikiVeilPick.js turns it into a
// pattern (contours, links, ripples, maze, cells), four seed numbers and a
// starting time, so an article is always the same picture and nothing is kept.
// `pattern` set to a name forces one (the sheets), and so does the style's
// `only` for every veil that reads that style (the mockup's panel).
//
// ONE SHADER, ONE CLOCK. Each pattern is one fragment shader
// (shaders/wiki_veil_<name>.frag over shaders/wiki_veil.glsl) and a pure
// function of `time`. The clock is ONE Timer at `style.fps` that runs only while
// `running`, the item is visible and has a size, and the theme is not
// crossfading (a crossfade is a still picture of the frame before: whatever
// keeps moving under it is drawn twice). Stopped, a veil asks for no frame. A
// thumbnail never runs (`running: false`): it is the picture at its start.
//
// COLOUR. The ground is the host's (`groundColor`: the well's floor); bevel
// and shadow are Theme tokens; `hue` (the family's) goes only into the
// deepest shade, by `style.hueShare`. Nothing here animates a colour.
//
// THE PLATE. `plateRadius` > 0 leaves a flat disc at the centre for a subject's
// carved logo (LogoRelief is transparent past its own bevel, so it needs a
// plain floor under it), with a fine ring where the pattern starts again.
// =============================================================================
Item {
    id: root

    objectName: "wikiVeil"
    property string seedKey: ""
    // "" = the key decides; a name of `patterns` forces that one.
    property string pattern: ""
    property color hue: Theme.shadowDeep
    property color groundColor: Theme.listBox
    // The host's say: on show, live, the shell not idle. A thumbnail says false.
    property bool running: true
    // Item px per pattern px: a thumbnail draws the middle of the picture smaller.
    property real zoom: 1
    // The veil's own rounded mask (a thumbnail's; the hero's well rounds itself).
    property real cornerRadius: 0
    property real plateRadius: 0
    property WikiVeilStyle style: WikiVeilStyle {}

    readonly property var patterns: Pick.NAMES
    readonly property var pick: Pick.of(root.seedKey)
    readonly property string shown: Pick.NAMES.indexOf(root.pattern) >= 0 ? root.pattern
                                    : (Pick.NAMES.indexOf(root.style.only) >= 0 ? root.style.only : root.pick.pattern)
    readonly property real time: root.pick.t0 + root._time
    readonly property bool ticking: root.running && root.visible && root.width > 0 && root.height > 0 && !Theme.crossfading

    // For renders and probes: put the veil `seconds` after its start.
    function seek(seconds: real): void {
        root._time = seconds;
    }

    // `c` carried `k` times further from `from`, and `dark` times that on a dark `from` (plain
    // arithmetic on two tokens: it follows both through a theme switch, with no mode read).
    function _lifted(c: color, from: color, k: real, dark: real): color {
        const lum = 0.2126 * from.r + 0.7152 * from.g + 0.0722 * from.b;
        const kk = k * (1 + (dark - 1) * (1 - lum) * (1 - lum));
        const f = (a, b) => Math.max(0, Math.min(1, a + (a - b) * kk));
        return Qt.rgba(f(c.r, from.r), f(c.g, from.g), f(c.b, from.b), 1);
    }

    property real _time: 0
    // Wall ms of the previous tick, 0 = none (a `real`: an int overflows).
    property real _last: 0
    onSeedKeyChanged: root._time = 0
    onTickingChanged: {
        if (!root.ticking)
            root._last = 0;
    }
    Timer {
        interval: Math.max(8, Math.round(1000 / Math.max(1, root.style.fps)))
        repeat: true
        running: root.ticking
        onTriggered: {
            const now = Date.now();
            // A stall is not played back: a late tick advances a tenth of a second at most.
            const dt = root._last > 0 ? Math.max(0, Math.min(0.1, (now - root._last) / 1000)) : 0;
            root._last = now;
            root._time += dt * root.style.speed;
        }
    }

    ShaderEffect {
        id: fx
        anchors.fill: parent
        blending: root.cornerRadius > 0
        visible: root.width > 0 && root.height > 0
        // A computed path (and so Qt.resolvedUrl, and `source` declared for the built-in
        // shader Qt may load for an instant before the bindings land).
        fragmentShader: Qt.resolvedUrl("shaders/wiki_veil_" + root.shown + ".frag.qsb")
        property var source: null

        readonly property var _p: root.style.params(root.shown)

        property real time: root.time
        property vector2d size: Qt.vector2d(root.width, root.height)
        property vector4d seed: Qt.vector4d(root.pick.seed[0], root.pick.seed[1], root.pick.seed[2], root.pick.seed[3])
        property vector4d frame: Qt.vector4d(Math.max(0.05, root.zoom), root.cornerRadius, root.style.relief, 0)
        // The light a carved logo has (LogoRelief): from straight above (y runs down). The logo
        // stands on this floor, and a maze's two diagonals must take the light alike.
        property vector4d light: Qt.vector4d(0, -1, root.style.litGain, root.style.shadowGain)
        property vector4d clearing: Qt.vector4d(root.width / 2, root.height / 2, root.plateRadius,
                                                root.plateRadius > 0 ? root.style.plateFade * root.zoom : 0)
        property vector4d grade: Qt.vector4d(root.style.ambient, 0, 0, 0)
        property vector4d p0: fx._p[0]
        property vector4d p1: fx._p[1]
        property color cGround: root.groundColor
        property color cBevel: root._lifted(Theme.bevel, root.groundColor, root.style.bevelLift, root.style.bevelLiftDark)
        property color cShadow: Theme.border
        property color cDeep: Mix.c(Theme.shadowDeep, root.hue, root.style.hueShare)
    }
}
