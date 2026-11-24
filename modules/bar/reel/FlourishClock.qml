import QtQuick

import "../../common/theme"
import "../../common/flourish"

// =============================================================================
// FlourishClock.qml -- ONE item's flourish clock (a reel's flourish set holds one per item: ReelFlourishes the power reel's,
// IdleFlourishes the idle reel's).
//
// A linear `t` (0 -> 1 over the flourish's length) and the `kind` playing ("" at rest). Every curve is a function of t in
// ReelFlourish.js, so one animation drives everything the flourish moves, and both views of the ring (the bar's cell and the strip)
// read the same clock: an icon straddling the seam is one picture.
//
// It runs only while a flourish plays (nothing ticks at rest), and HOLDS STILL WHILE THE THEME CROSSFADES: the crossfade is a still
// picture of the old palette, and a glyph still moving under it would be a second copy of itself (CLAUDE.md, the crossfade).
//
// THE REGISTRY (FlourishRegistry): it registers itself, as every glyph flourish does -- the OLED care's pixel shift waits while it plays,
// and the random flourishes may play it, through `demo()`: its set's demo (`owner.demo(itemId)`), the motion a hover plays, NEVER the fire
// (a power item's fire is what powers the machine off). Its set names it: `group` (the reel), `glyph` (the item's name in the config:
// the itemId unless the set says otherwise), `decorative`, `host` (the reel module: which screen), `shown` (the reel is turned to it).
// =============================================================================
QtObject {
    id: clock

    property string itemId: ""
    // "" at rest; "fire" / "hover" / "arrive" / "random" (any item but the padlock), "engage" / "cycle" / "release" (the padlock)
    property string kind: ""
    property real t: 0
    // The padlock's shackle where the motion began (1 open .. 0 shut): a motion that takes over another starts where it stood.
    property real from: 1
    readonly property bool playing: clock.kind !== ""

    // ---- the registry's names (header) ----
    property var owner: null
    property string group: ""
    property string glyph: clock.itemId
    property bool decorative: true
    property Item host: null
    property bool shown: true
    function demo(): bool {
        return !!clock.owner && clock.owner.demo(clock.itemId);
    }
    Component.onCompleted: FlourishRegistry.add(clock)
    Component.onDestruction: FlourishRegistry.remove(clock)

    signal finished(string kind)

    property NumberAnimation _anim: NumberAnimation {
        target: clock
        property: "t"
        from: 0
        to: 1
        easing.type: Easing.Linear
        onFinished: clock._end()
    }

    function play(kind: string, ms: int, from: real): void {
        clock._anim.stop();
        clock.from = from;
        clock.kind = kind;
        clock.t = 0;
        clock._anim.duration = Math.max(1, ms);
        clock._anim.start();
        clock._holdForTheme();
    }

    // A still: the clock held at t (a strip of frames, a probe). stop() ends it.
    function hold(kind: string, t: real, from: real): void {
        clock._anim.stop();
        clock.from = from;
        clock.kind = kind;
        clock.t = t;
    }

    function stop(): void {
        clock._anim.stop();
        clock.kind = "";
        clock.t = 0;
    }

    // A pause is asked only of a running animation (a paused one that is not running warns).
    function _holdForTheme(): void {
        if (clock._anim.running && Theme.crossfading && !clock._anim.paused)
            clock._anim.pause();
        else if (clock._anim.paused && !Theme.crossfading)
            clock._anim.resume();
    }
    property Connections _theme: Connections {
        target: Theme
        function onCrossfadingChanged(): void {
            clock._holdForTheme();
        }
    }

    function _end(): void {
        const k = clock.kind;
        clock.kind = "";
        clock.t = 0;
        clock.finished(k);
    }
}
