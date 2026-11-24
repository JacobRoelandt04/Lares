pragma ComponentBehavior: Bound

import QtQuick

import "../theme"

// =============================================================================
// BoardClock.qml -- a board scene's one clock (silicon's, aerial's), in the toolkit. A scene's own clock is `BoardClock { onAdvance: ... }`: the pacing, the idle
// ladder's live layer, the theme hold and the parking are here; what moves on its own -- the phases the shaders read -- is the scene's, in its `advance`.
//
// One Timer, running only while the popup is `shown` and the idle ladder has not parked it. Each tick it
//
//   1. hands the frame to the director (`director.tick(dt)`: the motions and the eased live values),
//   2. advances the scene's `time`,
//   3. emits `advance(dt, tempo)`: the scene INTEGRATES the phases its shaders read (a pulse train's cycles, a flow's mm). A phase is the sum of rate x dt, never
//      tempo x time: a change of load changes the SPEED of what is already in flight and never jumps a phase. `tempo` is the live layer (0 at rest).
//
// `dt` is measured from the wall clock and capped at `maxStep` (a stalled frame or a resume must not
// make the motions leap). `step(dt)` is the whole tick, public: a harness that films the popup (one
// shot per frame at a fixed step) sets `manual` and calls it, so a film is exact whatever the machine's
// frame times are, while the real run uses the timer.
//
// FRAME PACING. A tick is one frame, and the frames of a 120 Hz panel are 8.33 ms apart: a Timer of 16 ms
// (62.5 Hz) is not a multiple of that, so its updates would drift across the compositor's frame events -- now a frame shown a period
// early, now a period late, the uneven 8 / 17 / 25 ms. The clock keeps to the display's own grid instead (the long comment at
// "the pace" says how it reads it): ticks `n` periods apart, `n` = intervalMs / period rounded (2 on 120 Hz, 1 on 60, 4 / 2
// for calm), each half a period before the event its frame is shown at; `dt` is the whole periods between the frames, so what
// moves advances by what the eye sees. Offscreen there is no grid: an open loop at 60 Hz.
//
// THE IDLE LADDER (`idleState` is the view model's): alive ticks every `aliveMs` (16), calm every
// `calmMs` (33), and halt STOPS the timer -- a halted clock presents no frame at all. Not abruptly, though:
// `live` (0..1) is the scene's own motion -- the particles, the holograms' flicker and scan, the pulse
// trains on the traces, the MUX breath, all multiplied by it -- and on the way to halt it eases to 0 over
// `restSeconds` while the tempo of `time` and the phases follows it down, so the last frame is a still
// picture with nothing frozen mid-flight; only then does the timer stop (`parked`), and only when the
// director has nothing left that will change by itself (`director.animating`: a card that waits for the
// apps that use the dGPU does not count). A wake (`idleState` leaves halt) restarts the timer and eases
// `live` back over `wakeSeconds`: the same ramp and the same tempo, so no particle jumps and no
// brightness steps from one frame to the next. The timer's first tick after a park measures from the
// wake, never from the last frame before the halt.
//
// THE THEME CROSSFADE: THE BOARD IS AN ISLAND (SiliconIsland): it is cut out of the picture and a ghost in the old palette fades over it,
// so with `islandArmed` the gate below is 1 for the whole fade and the board does not stand still at all. What follows is the rule for a switch the island
// does not take (it is off, the clock was halted at the ask, the popup was opening): the hold.
//
// THE HOLD. A switch is a still picture of the frame before, faded out over the new palette
// (Theme's snapshot host), and anything that keeps moving under that picture is a second copy of itself while it is
// opaque (CLAUDE.md). The picture is only a second copy while it is OPAQUE enough to read: it fades as
// `Theme.fadeProgress` rises, so the board is held still while the progress is under `crossfadeHold` (the picture is
// then more than 60 % of what is on screen) and is let go as the picture goes: `_gate` is 0 until the hold, then a
// smoothstep to 1 at the end of the fade, and every step is taken at `dt x _gate` -- a motion that starts from rest and
// accelerates under a fading ghost of itself, which never shows one. The gate scales the step, it does not stop the
// timer: the grid the frames are paced on is kept through the switch, and nothing is recalibrated at its end.
//
// The entrance (`scene.power`) is the director's, the moments a sound marks are its signals.
// =============================================================================
Item {
    id: root

    visible: false

    // ---- in ----
    property var scene: null              // the scene whose `time` and `live` it advances (and whose phases `advance` integrates)
    property var director: null
    property bool shown: false
    property bool manual: false
    property string idleState: "alive"    // the view model's idle ladder: "alive" | "calm" | "halt"
    property int aliveMs: 16              // the interval asked for: rounded to whole vsyncs, 16 is 60 frames a second
    property int calmMs: 33               // ... and 33 is 30
    property real restSeconds: 1.0        // the way to halt: the live layer eases to rest over this
    property real wakeSeconds: 0.4        // ... and back, on a wake
    property real maxStep: 0.1
    // The part of a theme crossfade (its progress, 0..1) the board is held still for: the picture over it is that opaque
    // still. 0.4 is the picture at 60 %; 0 would never hold, 1 holds the whole fade.
    property real crossfadeHold: 0.4
    // The scene is a theme island (SiliconIsland) for this switch: its own picture is cut out of the crossfade's, so nothing is held.
    property bool islandArmed: false

    // out
    // one tick has been played: `dt` is the (capped) step it took. A probe's instrument: it is emitted even when the
    // tempo is nothing and the scene's time did not move.
    signal ticked(real dt)
    // the scene's own integration: `dt` is the step (capped, gated), `tempo` the live layer's share of it (the scene has had `time` and `live` written)
    signal advance(real dt, real tempo)
    readonly property int intervalMs: root.idleState === "alive" ? root.aliveMs : root.calmMs
    readonly property real live: root._live
    readonly property bool parked: root._parked
    // the clock has stopped itself: halted, at rest, nothing left to move
    property bool _parked: false
    readonly property bool running: root.shown && !root.manual && !root._parked
    // How much of a step the crossfade lets through: 1 at rest, 0 while its picture is opaque, then rising to 1 as it fades.
    readonly property real gate: {
        if (!Theme.crossfading || root.islandArmed)
            return 1;
        const u = Math.max(0, Math.min(1, (Theme.fadeProgress - root.crossfadeHold) / Math.max(1e-3, 1 - root.crossfadeHold)));
        return u * u * (3 - 2 * u);
    }
    // the display's frame period (ms) as the clock knows it, and the interval it really ticks at (a whole number of them)
    readonly property real vsyncMs: root._vs
    readonly property real pacedMs: root._vsyncs() * root._vs

    // The ladder's live layer: a linear progress (one clock) and the curve it is shaped by. Ease in and out,
    // so a ramp starts and ends without a step: the largest change from one frame to the next is 1.5 x the
    // linear one.
    property real _p: 1
    property real _live: 1
    function _shape(p) {
        return p * p * (3 - 2 * p);
    }

    // The tick, as a function: the timer calls it, a film calls it.
    function step(dtSeconds) {
        const sc = root.scene;
        if (!sc)
            return;
        const dt = Math.max(0, Math.min(root.maxStep, dtSeconds)) * root.gate;
        if (root.director)
            root.director.tick(dt);
        // the live layer follows the ladder; the tempo of everything that moves on its own follows the live
        // layer, so what slows to a stop is exactly what has faded out
        const goal = root.idleState === "halt" ? 0 : 1;
        const secs = goal === 0 ? root.restSeconds : root.wakeSeconds;
        const stepP = dt / Math.max(1e-3, secs);
        root._p = Math.abs(goal - root._p) <= stepP ? goal : root._p + (goal > root._p ? stepP : -stepP);
        root._live = root._shape(root._p);
        sc.live = root._live;
        const tempo = root._live;
        sc.time += dt * tempo;
        root.advance(dt, tempo);
        // at rest and nothing left to move: this was the last frame, a still picture
        if (goal === 0 && root._p <= 0 && !(root.director && root.director.animating))
            root._parked = true;
        root.ticked(dt);
    }

    // A new clock's state: awake, the ladder's live layer full, not parked (a content kept after its popup closed starts its next open as a fresh one does).
    function reset() {
        root._p = 1;
        root._live = 1;
        root._parked = false;
        if (root.scene)
            root.scene.live = 1;
    }

    // a wake: the ladder leaves halt (or the popup opens on a ladder that is not at halt)
    onIdleStateChanged: {
        if (root.idleState !== "halt")
            root._parked = false;
    }

    // ---- the pace ----
    // THE GRID. The compositor shows a committed frame at the first of its frame events (callbacks) after the commit, and the
    // window's frameSwapped stamps the commit. A tick made at time t is rendered at once and committed at t + r (r: a few ms of
    // polish, sync and render) -- UNLESS the previous frame's callback has not arrived yet, when the commit waits for it and lands
    // ON the event. Nothing else a client can read says where the events are, so the clock reads them from those waits:
    //   free      a tick right after every swap (the first frames after a start): each commit waits, so the swaps are one period
    //             apart and ARE the events -- the period is read from them, and the lattice's phase from the last
    //   paced     a tick every n periods (n = intervalMs / period rounded: 2 on a 120 Hz panel, 1 on 60, 4 / 2 for calm), placed
    //             HALF A PERIOD before the event its frame is shown at (so the commit has the same room either side of it: a
    //             16 ms Timer, which is no multiple of the period, drifts across the events and shows a frame now a period early,
    //             now a period late -- the uneven 8 / 17 / 25 ms), `dt` the whole periods between the frames
    //   sync      every `_resyncMs`, one extra tick right after a paced swap: it waits for that frame's callback, so its swap is an
    //             event again, and the lattice is corrected from it
    // Times are wall milliseconds (Date.now()). `_lastPres` is the event the last tick's frame is shown at.
    property real _last: 0
    property real _vs: 1000 / 60          // the period: 60 Hz until read
    property real _lastPres: 0
    property real _tickAt: 0              // when the last tick was made
    property real _lag: 3                 // r: how long after a tick its commit lands when nothing makes it wait (a moving mean)
    property real _syncAt: 0
    property string _mode: "free"         // "free" | "paced"
    property bool _awaiting: false
    property bool _syncing: false
    property bool _known: false           // the period has been read
    readonly property var _free: ({ stamps: [] })
    // a window with no display (offscreen) has no events to read: an open loop at 60 Hz
    readonly property bool _display: Qt.platform.pluginName !== "offscreen"
    readonly property var _win: root.Window.window
    readonly property var _rates: [48, 50, 60, 72, 75, 90, 100, 120, 144, 165, 180]
    readonly property int _calibrationSwaps: 44
    readonly property int _calibrationSkip: 8        // the first frames of a start are slow (pipelines, layouts): not read
    readonly property int _relockSwaps: 4
    readonly property real _resyncMs: 4000
    readonly property real _callbackLag: 0.5         // a swap that waited lands this long after its event

    function _vsyncs() {
        return Math.max(1, Math.round(root.intervalMs / root._vs));
    }

    function _restart() {
        root._free.stamps = [];
        root._awaiting = false;
        root._syncing = false;
        if (root._display) {
            root._mode = "free";
        } else {
            root._mode = "paced";
            root._vs = 1000 / 60;
            root._known = true;
            root._lastPres = Date.now() - root._vs;       // the first tick (made at once) is the one at `now`
        }
    }

    // The period from the free-run's swap stamps: each gap is one period (a commit that waited) or a few (a slow frame), or less than
    // one (a commit that had no reason to wait: the first after a pause). The period is the mean of the gaps within 1.5 ms of a low
    // one -- the tenth smallest of those over 5.5 ms -- snapped to a refresh rate a panel has when it is within 5 % of one.
    function _calibrated() {
        const st = root._free.stamps.slice(root._calibrationSkip);
        const gaps = [];
        for (let i = 1; i < st.length; i++)
            if (st[i] - st[i - 1] > 5.5)
                gaps.push(st[i] - st[i - 1]);
        if (gaps.length < 8)
            return false;
        const sorted = gaps.slice().sort((a, b) => a - b);
        const low = sorted[Math.floor(sorted.length / 10)];
        const near = gaps.filter(g => Math.abs(g - low) <= 1.5);
        const mean = near.reduce((a, b) => a + b, 0) / near.length;
        root._vs = mean;
        for (const r of root._rates) {
            if (Math.abs(1000 / mean - r) <= 0.05 * r)
                root._vs = 1000 / r;
        }
        root._known = true;
        return true;
    }

    function _tick(dtMs) {
        const now = Date.now();
        root._tickAt = now;
        root._awaiting = true;
        root._last = now;
        root.step(Math.max(0, dtMs) / 1000);
        if (!root.running)
            return;
        if (!root._display) {
            // offscreen: an open loop, armed here and nowhere else. A Timer started after the frame's commit (in `_swapped`) renders
            // a frame of its own there: popup-alive took 1.06-1.08 frames a tick that way, 1.02 with one start inside the tick
            pace.interval = Math.max(1, Math.round(root._lastPres + root._vsyncs() * root._vs - now));
            pace.restart();
            return;
        }
        // with no swap to answer (a hidden window): the next tick comes by itself
        pace.interval = Math.max(1, Math.round(3 * root._vsyncs() * root._vs));
        pace.restart();
    }

    // arm the next paced tick: its frame is shown n periods after the last one's, and the commit is made half a period before that
    function _arm() {
        const at = root._lastPres + root._vsyncs() * root._vs - 0.5 * root._vs - root._lag;
        pace.interval = Math.max(1, Math.round(at - Date.now()));
        pace.restart();
    }

    // the window committed a frame
    function _swapped() {
        const now = Date.now();
        if (!root._awaiting || !root.running || !root._display)
            return;
        root._awaiting = false;
        if (root._mode === "free") {
            root._free.stamps.push(now);
            const need = root._known ? root._relockSwaps : root._calibrationSwaps;
            if (root._free.stamps.length >= need && (root._known || root._calibrated())) {
                // this swap waited for a callback: it is an event, and its frame is shown at the next
                root._lastPres = now - root._callbackLag + root._vs;
                root._syncAt = now;
                root._mode = "paced";
                root._arm();
                return;
            }
            if (root._free.stamps.length > 3 * need) {      // a display that never makes a commit wait: give the guess up
                root._known = true;
                root._lastPres = now + root._vs;
                root._mode = "paced";
                root._arm();
                return;
            }
            pace.interval = 1;
            pace.restart();
            return;
        }
        if (root._syncing) {
            // the sync frame's commit waited for the callback of the frame before it: an event. Read the lattice from it
            root._syncing = false;
            let e = (now - root._callbackLag) - (root._lastPres - root._vs);
            e -= Math.round(e / root._vs) * root._vs;
            if (Math.abs(e) < 0.4 * root._vs)
                root._lastPres += 0.5 * e;
            root._syncAt = now;
            root._arm();
            return;
        }
        const sample = now - root._tickAt;
        // (an unblocked commit: the previous frame's callback came long before this tick, so its time is the render's own, at 2x
        // a stage's four times the pixels it is 8 ms and more)
        if (sample > 0.3 && sample < 0.9 * root._vs * root._vsyncs())
            root._lag = 0.7 * root._lag + 0.3 * sample;
        if (now - root._syncAt > root._resyncMs) {
            root._syncing = true;
            pace.interval = 1;
            pace.restart();
            return;
        }
        root._arm();
    }

    onRunningChanged: {
        if (root.running) {
            root._last = Date.now();
            root._restart();
            pace.interval = 1;
            pace.restart();
        } else {
            pace.stop();
        }
    }
    Component.onCompleted: root._restart()

    Timer {
        id: pace
        repeat: false
        onTriggered: {
            if (root._mode === "free") {
                root._tick(root._known ? root._vs : Math.max(1, Date.now() - root._last));
            } else if (root._syncing) {
                root._lastPres += root._vs;                 // the sync frame is shown one event after the last
                root._tick(root._vs);
            } else if (!root._display) {
                // no grid to keep: the wall's own step (and a first tick after a wake measures from the wake)
                root._lastPres += root._vsyncs() * root._vs;
                root._tick(Date.now() - root._last);
            } else {
                let pres = root._lastPres + root._vsyncs() * root._vs;
                // a tick that comes late (a stall, a resume): the frame is shown at the first event of the lattice after now, never a
                // burst of ticks catching a backlog up
                const now = Date.now();
                if (pres < now - root._vs)
                    pres += Math.ceil((now - pres) / root._vs) * root._vs;
                const dt = pres - root._lastPres;
                root._lastPres = pres;
                root._tick(dt);
            }
        }
    }
    Connections {
        target: root._win
        ignoreUnknownSignals: true
        function onFrameSwapped() {
            root._swapped();
        }
    }
}
