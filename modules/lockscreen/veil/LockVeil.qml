pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"

// =============================================================================
// LockVeil.qml -- the lock's veil: the host of the proposals and their ONE
// clock (contract section 7).
//
// The veil is what lies over the desktop while the session is locked: over the
// held, blurred still of the desktop on a normal lock, and alone (opaque, from
// its first frame) at boot, when nothing is behind. It is the first thing the
// user sees every morning, and the shell's whole "visual interest".
//
// THE CLOCK. A proposal is a pure function of what this host hands it: `time`
// (veil seconds), `speed`, `presence`, `pulses`, `pointer`, `still`, `dark`.
// It never runs a Timer or FrameAnimation of its own, so when this host stops,
// nothing in the veil renders another frame -- the rest is free.
//
//   awake -> the Timer ticks at `fps` and `time` advances at `speed` = 1;
//   awake goes false -> `speed` eases to 0 over restEaseMs (OutCubic: the
//     motion winds down, it does not stop dead), then the Timer stops;
//   awake again -> `speed` eases back to 1 over wakeEaseMs.
// The speed is computed inside the tick from the time of the last flip, so
// there is no second animation running beside the clock. `time` integrates
// the speed, which is what makes a wind-down look like one continuous motion
// slowing (a veil that multiplied its phase by `speed` would jump).
//
// A theme crossfade is a still picture of the frame before, so the clock holds
// while Theme.crossfading (CLAUDE.md: anything that keeps moving under it is a
// second copy of itself for the fade).
// =============================================================================
Item {
    id: root

    // ---- what to show ---------------------------------------------------------
    // One of `proposals`. Loads Veil<Name>.qml beside this file. "" = a
    // clock-only host: a mockup declares its veil itself (so the panel can
    // target it at creation) and hands it this host.
    property string proposal: "relief"
    // The lock picks one of the config's `veils` at random per lock.
    readonly property var proposals: ["relief", "gooey", "dimples", "paper", "louvres", "keycaps", "dials"]

    // 0..1: how much of the veil is shown. The lock's choreography raises it
    // once the desktop beneath has come to rest; a proposal decides HOW it
    // appears (a fade, sand raked in, wells pressing in...).
    property real presence: 1
    // The entrance's clock, LINEAR in real time: the lock eases `presence`
    // OutCubic over veilRiseMs (LockSurface), and this undoes that ease, so a
    // front driven by it moves at a constant speed instead of racing across
    // in the first 50 ms. One place for the inverse: a veil reads this, never
    // re-derives it; a mockup that animates presence eases it OutCubic too.
    readonly property real riseClock: 1 - Math.cbrt(1 - Math.max(0, Math.min(1, root.presence)))
    // Boot: nothing behind the lock. The proposal draws a full ground.
    property bool opaque: false
    // The held desktop frame, a texture provider (Image, ShaderEffectSource,
    // ScreencopyView), or null. A proposal may sample it (refraction); the
    // lock draws it beneath the veil either way.
    property Item still: null
    // Pointer over the lock surface, item px, or null.
    property var pointer: null
    // Where the shell's popup and the bar it hangs from sit over the veil,
    // item px; an empty rect = unknown. The lock feeds them from the shell's
    // `hints`, the stage from its silhouette. A proposal that wraps, avoids
    // or radiates from the popup reads these instead of assuming a place.
    property rect popupRect: Qt.rect(0, 0, 0, 0)
    property rect barRect: Qt.rect(0, 0, 0, 0)
    property real renderScale: 1

    // ---- the clock's inputs -------------------------------------------------------
    property bool awake: true
    property real fps: 60
    property int restEaseMs: 2000
    property int wakeEaseMs: 600
    // A host that must hold the veil still (a capture frame, hidden) says so.
    property bool running: true

    // ---- what a proposal reads --------------------------------------------------------
    readonly property real time: root._time
    readonly property real speed: root._speed
    readonly property var pulses: root._pulses
    readonly property bool dark: root._dark
    // The clock is stopped: nothing in the veil renders.
    readonly property bool resting: !root._ticking
    readonly property QtObject item: loader.item

    // A keystroke, a failed or accepted password, a wake: reactive proposals
    // answer with a ripple, a gust, a flash. Newest last, at most 32 (16 would cut
    // ripples off mid-flight when typing fast); a proposal draws as
    // many as it can afford and fades the oldest out instead of dropping it.
    function pulse(kind, x, y) {
        const p = root._pulses.slice(-31);
        p.push({
            kind: String(kind),
            x: (x === undefined || x === null) ? root.width / 2 : x,
            y: (y === undefined || y === null) ? root.height / 2 : y,
            t: root._time
        });
        root._pulses = p;
    }

    // For renders and probes only: put the clock at veil time `t` with speed
    // `speed` (the clock should be stopped with `running: false`), and pulses
    // at explicit veil times. A proposal is a pure function of these, so a
    // filmstrip is exact and repeatable.
    function seek(t, speed) {
        root._time = t;
        root._speed = (speed === undefined) ? 1 : speed;
    }
    function injectPulse(kind, x, y, t) {
        const p = root._pulses.slice(-31);
        p.push({ kind: String(kind), x: x, y: y, t: t });
        root._pulses = p;
    }
    function clearPulses() { root._pulses = []; }

    // ---- the clear (the unlock) ------------------------------------------------------------
    // The accepted password's `ok` starts the veil's CLEAR: each veil leaves in the way its own material
    // would, over `clearSeconds` of veil time. The lock holds the veil at full presence for unlockHoldMs
    // (600) and then fades the whole surface over unlockMs (400): a clear that is done by ~0.95 s is
    // done as the fade ends, and what is left of it at the fade's start is hidden by it. The clear
    // never delays the unlock (the lock's timers are its own); a veil only reads `clear`.
    // 0 = no ok yet, 1 = the clear is complete; linear in veil time, a veil shapes it.
    property real clearSeconds: 0.95
    readonly property real okTime: root._okTime(root._pulses)
    readonly property real clear: root.okTime < 0 ? 0 : Math.max(0, Math.min(1, (root._time - root.okTime) / Math.max(0.05, root.clearSeconds)))
    function _okTime(pulses) {
        let at = -1;
        for (const p of pulses)
            if (p.kind === "ok" && p.t > at)
                at = p.t;
        return at;
    }

    // ---- internals ---------------------------------------------------------------------
    property real _time: 0
    property real _speed: 1
    property var _pulses: []
    property bool _dark: false
    property real _last: 0          // wall ms of the previous tick, 0 = none
    property real _flipAt: 0        // wall ms when `awake` last changed
    property real _flipFrom: 1      // speed at that moment

    readonly property bool _ticking: root.running && root.visible && root.width > 0 && root.height > 0
                                     && !Theme.crossfading
                                     && (root.proposal === "" || loader.status === Loader.Ready)
                                     && (root.awake || root._speed > 0)

    onAwakeChanged: {
        root._flipAt = Date.now();
        root._flipFrom = root._speed;
    }
    on_TickingChanged: if (!root._ticking) root._last = 0

    function _step() {
        const now = Date.now();
        const dt = root._last > 0 ? Math.min(0.1, (now - root._last) / 1000) : 0;
        root._last = now;
        const dur = root.awake ? root.wakeEaseMs : root.restEaseMs;
        const target = root.awake ? 1 : 0;
        const u = dur > 0 ? Math.min(1, (now - root._flipAt) / dur) : 1;
        const e = 1 - Math.pow(1 - u, 3);
        const s = u >= 1 ? target : root._flipFrom + (target - root._flipFrom) * e;
        // Integrate at the mean of the step's two speeds: a wind-down is one
        // continuous deceleration, not a staircase.
        root._time += dt * (root._speed + s) / 2;
        root._speed = s;
    }

    function _readDark() {
        const c = Theme.surface;
        root._dark = (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) < 0.5;
    }

    Timer {
        id: tick
        interval: Math.max(8, Math.round(1000 / Math.max(1, root.fps)))
        repeat: true
        running: root._ticking
        onTriggered: root._step()
    }

    Connections {
        target: Theme
        function onSettled() { root._readDark(); }
    }

    Loader {
        id: loader
        anchors.fill: parent
        function load() {
            const n = String(root.proposal);
            if (n === "") {
                loader.source = "";
                return;
            }
            if (root.proposals.indexOf(n) < 0) {
                console.warn("LockVeil: unknown proposal", n);
                loader.source = "";
                return;
            }
            loader.setSource(Qt.resolvedUrl("Veil" + n.charAt(0).toUpperCase() + n.slice(1) + ".qml"), { host: root });
        }
    }

    onProposalChanged: loader.load()
    Component.onCompleted: {
        root._readDark();
        root._flipAt = Date.now();
        loader.load();
    }
}
