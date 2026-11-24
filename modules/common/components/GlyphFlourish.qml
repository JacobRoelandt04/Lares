pragma ComponentBehavior: Bound

import QtQuick

import "../theme"
import "../flourish"
import "../system"

// =============================================================================
// GlyphFlourish.qml -- THE FLOURISH CONTRACT of a bar glyph: one clock, the asks that play it, and the pointer's rule.
//
// A bar glyph's flourish is a short motion of the glyph itself: the bell rings, the archive box opens, the vinyl spins, the CPU
// profile's glyph sways. Each plays on its own EVENTS (a notification, a new song, a profile change) and on the POINTER: the
// user's rule for every glyph flourish is that hovering the glyph plays it. This object is the part they share; the motion is
// the host's own (a pure function of this clock: BellPose.js, ArchivePose.js, SiliconGlyphPose.js, SiliconGpuPose.js, the player's spin).
//
//   play(why)     plays it ("hover", "notification", "song", "profile", ...: the host's word, kept in `why`); armed only
//   playing       a play is in progress: the clock runs
//   u             0..1 through the latest kick of the play; 1 at rest
//   t, kicks      for a host whose plays OVERLAP: ms on the run's clock (0 at the first kick) and the run's kicks, oldest first
//   overlap       what an EVENT does while a play is in progress:
//                   "restart"  from the top (the motion jumps to its start: a host whose new event is a new picture anyway)
//                   "extend"   a new kick on the same run, which ends `ms` after it: the host takes the strongest of its kicks
//                              (a re-strike lifts the motion where it stands, never a jump and never a pile-up)
//                   "ignore"   nothing
//   hoverArea     the host's MouseArea. ONE PLAY PER POINTER ENTRY, and only once the pointer MOVES after it: a surface or an
//                 item that comes up under a resting pointer brings an enter with no motion, and Qt re-delivers a resting
//                 pointer's hover (CLAUDE.md): neither is the user hovering. Measured in the WINDOW's frame, so a button that
//                 slides under a resting pointer is no motion either. A hover never restarts a play in progress, and the
//                 entry it came with is spent.
//   pointerAt(inside, wx, wy)
//                 the same rule for a host whose MouseArea is SHARED (a pill's two halves under one area that finds the half by
//                 arithmetic): the host says on every pointer event whether the pointer is on THIS glyph's part and where it
//                 is in the window. Coming onto the part is the entry; the first motion after it plays.
//
// ONE CLOCK, AND ONLY WHILE IT PLAYS: `t` runs linearly on the animation clock from the first kick to the last kick + `ms`;
// at rest nothing ticks and nothing asks for a frame. The run STARTS one turn after the ask, so the host's bindings have
// followed the event that asked (a profile's glyph and its length). It holds still while the theme crossfades: a still
// picture of the old palette must not have a second, moving copy of the glyph under it (CLAUDE.md, the crossfade).
// `held` (a harness): play() starts no run, and the harness writes `t`.
//
// THE REGISTRY (FlourishRegistry): every one registers itself, so the OLED care sees it -- a step of the pixel shift waits while any
// flourish on its screen plays, and the random flourishes (FlourishScheduler) may play it. The host names it:
//   group        the module ("bell", "update", "player", "silicon"); "" plays at random never
//   decorative   its motion means nothing, so it is in the random pool unless the config says otherwise (the archive); false for one
//                whose motion says something happened (a new notification, a song, a profile): it plays at random only when switched on
//   host         an Item it lives under (which screen it is on): the hover area unless the host says otherwise
//   demo()       a play as a hover plays it ("random"), only where a hover would play (`hoverPlays`, `armed`) and none is in progress
// =============================================================================
QtObject {
    id: fl

    property bool armed: true
    property int ms: 900
    property string overlap: "restart"
    // the kicks an "extend" run keeps (the strongest is always the newest once its attack is through)
    property int maxKicks: 3
    property MouseArea hoverArea: null
    property bool hoverPlays: true
    // how far (window px) the pointer must move after an entry for it to count
    property real hoverMove: 1
    property bool held: false

    // ---- the registry's names (header) ----
    property string group: ""
    property string glyph: ""
    property bool decorative: false
    property Item host: fl.hoverArea
    property bool shown: true
    function demo(): bool {
        if (!fl.armed || !fl.hoverPlays || fl._on)
            return false;
        return fl.play("random");
    }
    Component.onCompleted: FlourishRegistry.add(fl)
    Component.onDestruction: {
        FlourishRegistry.remove(fl);
        if (fl._on)
            InkWhole.hold(false);
    }

    // ---- the clock ----
    property real t: 0
    property var kicks: []
    property string why: ""
    readonly property bool playing: fl._on
    readonly property real lastKick: fl.kicks.length > 0 ? fl.kicks[fl.kicks.length - 1] : 0
    readonly property real u: fl._on ? Math.max(0, Math.min(1, (fl.t - fl.lastKick) / Math.max(1, fl.ms))) : 1

    signal played(string why)
    signal finished()

    function play(why) {
        if (!fl.armed)
            return false;
        const w = String(why || "");
        if (w === "hover" && !FlourishRegistry.hoverPlays)
            return false;
        if (fl._on && fl.overlap === "ignore")
            return false;
        if (fl._on && fl.overlap === "extend") {
            const k = fl.kicks.slice(Math.max(0, fl.kicks.length - fl.maxKicks + 1));
            k.push(fl.t);
            fl.kicks = k;
            fl.why = w;
            fl.played(w);
            fl._go();
            return true;
        }
        fl._run.stop();
        fl.t = 0;
        fl.kicks = [0];
        fl.why = w;
        fl._on = true;
        fl.played(w);
        Qt.callLater(fl._go);
        return true;
    }

    function stop() {
        fl._run.stop();
        fl._settle();
    }

    onArmedChanged: if (!fl.armed && fl._on) fl.stop()

    property bool _on: false
    // a flourish can throw ink past its bar (a wave, a puff): the visible region keeps the whole window while one plays (InkWhole)
    on_OnChanged: InkWhole.hold(fl._on)

    function _go() {
        if (!fl._on || fl.held)
            return;
        const end = fl.lastKick + fl.ms;
        fl._run.stop();
        if (fl.t >= end) {
            fl._settle();
            fl.finished();
            return;
        }
        fl._run.from = fl.t;
        fl._run.to = end;
        fl._run.duration = Math.max(1, Math.round(end - fl.t));
        fl._run.start();
        fl._holdForTheme();
    }

    function _settle() {
        fl._on = false;
        fl.t = 0;
        fl.kicks = [];
    }

    property NumberAnimation _run: NumberAnimation {
        target: fl
        property: "t"
        easing.type: Easing.Linear
        onFinished: {
            fl._settle();
            fl.finished();
        }
    }

    // A pause is asked only of a running animation (a paused one that is not running warns).
    function _holdForTheme() {
        if (fl._run.running && Theme.crossfading && !fl._run.paused)
            fl._run.pause();
        else if (fl._run.paused && !Theme.crossfading)
            fl._run.resume();
    }
    property Connections _theme: Connections {
        target: Theme
        function onCrossfadingChanged() {
            fl._holdForTheme();
        }
    }

    // ---- the pointer: an entry, then a motion ----
    property bool _entered: false
    property point _entryAt: Qt.point(0, 0)
    property bool _onPart: false
    function pointerAt(inside: bool, wx: real, wy: real): void {
        const came = inside && !fl._onPart;
        fl._onPart = inside;
        if (came || !inside) {
            fl._entered = came;
            fl._entryAt = Qt.point(wx, wy);
        } else if (fl._entered && Math.abs(wx - fl._entryAt.x) + Math.abs(wy - fl._entryAt.y) >= fl.hoverMove) {
            // the entry is spent (`came` is false here)
            fl._entered = came;
            if (fl.hoverPlays && !fl._on)
                fl.play("hover");
        }
    }
    property Connections _pointer: Connections {
        target: fl.hoverArea
        function onContainsMouseChanged() {
            const a = fl.hoverArea;
            fl._entered = a.containsMouse;
            if (a.containsMouse)
                fl._entryAt = a.mapToItem(null, a.mouseX, a.mouseY);
        }
        function onPositionChanged(mouse) {
            if (!fl._entered)
                return;
            const p = fl.hoverArea.mapToItem(null, mouse.x, mouse.y);
            if (Math.abs(p.x - fl._entryAt.x) + Math.abs(p.y - fl._entryAt.y) < fl.hoverMove)
                return;
            fl._entered = false;
            if (fl.hoverPlays && !fl._on)
                fl.play("hover");
        }
    }
}
