pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// KineticScroll -- moves ONE axis of a Flickable the way a browser does, with
// the feel of the ScrollFeel singleton. It owns no wheel reader: a host (most
// often ScrollDressing) hands it each wheel event's component on its axis.
//
//   a mouse NOTCH     glides there over notchMs (OutCubic). A notch arriving
//                     mid-glide adds to the target and restarts the curve from
//                     where the content IS -- never swallowed, never jumping
//                     back (Qt's own glide swallows notches).
//   touchpad FINGERS  move the content at once (x speed), and the last
//                     velocityWindowMs of motion is kept as a velocity.
//   the LIFT          (a zero-delta event; Qt's ScrollEnd) starts a FLING if
//                     the fingers were moving faster than flingMin: the
//                     velocity decays as exp(-t / momentumTau), so the coast is
//                     v0 x momentumTau long and eases out to a stop.
//   fingers put BACK  (a zero-delta ScrollBegin, or the next finger delta)
//                     catch the fling where it is.
//
// It never fights another writer: if the flick's position is not where the
// engine left it (an ensureVisible, a reveal animation, a host clamping on a
// resize), the engine stops. And it is FREE AT REST: the one FrameAnimation
// runs only while a glide or a fling is under way.
//
// Positions are the flick's contentX / contentY; `d` is in those units
// (+ = further along). `feed()` takes Qt's wheel sign (+ = towards the start).
// =============================================================================
QtObject {
    id: k

    property Flickable flick: null
    property int axis: Qt.Vertical
    readonly property bool horizontal: k.axis === Qt.Horizontal
    // A multiplier on every input. The default is the shell's (ScrollFeel);
    // a host that genuinely wants less sets its own.
    property real speed: k.horizontal ? ScrollFeel.hSpeed : ScrollFeel.speed
    property real minPos: 0
    property real maxPos: !k.flick ? 0
        : Math.max(0, k.horizontal ? k.flick.contentWidth - k.flick.width : k.flick.contentHeight - k.flick.height)

    readonly property bool moving: k._mode !== ""
    // Every position this engine writes, after it is written.
    signal moved

    // ---- input ---------------------------------------------------------------
    // ONE axis of a wheel event: its pixelDelta and angleDelta on this axis,
    // and the event's phase. Returns whether anything was done with it.
    function feed(pixelDelta: real, angleDelta: real, phase: int): bool {
        if (pixelDelta !== 0) {
            k.touch(-pixelDelta * k.speed);
            return true;
        }
        if (angleDelta !== 0) {
            k.notch(-angleDelta / 120 * ScrollFeel.notchPx * k.speed);
            return true;
        }
        // Nothing on this axis: the fingers put down (a catch) or lifted (a coast). A zero UPDATE is the other axis' event.
        if (phase === Qt.ScrollBegin)
            k.stop();
        else if (phase !== Qt.ScrollUpdate)
            k.release();
        return true;
    }

    function touch(d: real): void {
        if (k._mode !== "")
            k.stop();
        const now = Date.now();
        k._samples.push({ t: now, d: d });
        k._trim(now);
        k._write(k._pos() + d);
    }

    function notch(d: real): void {
        const from = k._pos();
        // A notch during a glide adds to where the glide was GOING.
        const base = k._mode === "glide" ? k._to : from;
        k._samples = [];
        if (ScrollFeel.notchMs <= 0) {
            k.stop();
            k._write(base + d);
            return;
        }
        k._from = from;
        k._to = k._clamp(base + d);
        k._t = 0;
        if (k._to === from) {
            k.stop();
            return;
        }
        k._start("glide");
        // The first step lands WITH the event (one 120 Hz frame's worth of the
        // curve), so the frame after the notch already shows it moving; waiting
        // for the next tick costs the LLM lists ~13 ms of notch-to-frame latency.
        k._t = k._lead;
        k._write(k._from + (k._to - k._from) * (1 - Math.pow(1 - Math.min(1, k._lead / Math.max(1, ScrollFeel.notchMs)), 3)));
    }
    readonly property real _lead: 8

    function release(): void {
        const now = Date.now();
        k._trim(now);
        const s = k._samples;
        k._samples = [];
        if (s.length < 2 || k._mode !== "")
            return;
        // The velocity over the window: the distance the fingers covered,
        // over the time from the first sample to the lift.
        let sum = 0;
        for (let i = 0; i < s.length; i++)
            sum += s[i].d;
        const span = Math.max(16, now - s[0].t);
        let v = sum / span;
        if (Math.abs(v) < ScrollFeel.flingMin)
            return;
        v = Math.max(-ScrollFeel.maxFling, Math.min(ScrollFeel.maxFling, v));
        k._v = v;
        k._start("fling");
    }

    // Immediate (programmatic, or a host's own reader that wants no motion).
    function jump(d: real): void {
        k.stop();
        k._samples = [];
        k._write(k._pos() + d);
    }

    function stop(): void {
        k._mode = "";
        k._v = 0;
        tick.running = false;
    }

    // ---- state -------------------------------------------------------------
    property string _mode: ""          // "" | "glide" | "fling"
    property real _from: 0
    property real _to: 0
    property real _t: 0                // ms into the glide
    property real _v: 0                // px/ms, the fling's velocity
    property real _last: NaN           // the position this engine last wrote
    property var _samples: []          // [{t, d}] of the fingers, newest last

    function _pos(): real {
        return !k.flick ? 0 : (k.horizontal ? k.flick.contentX : k.flick.contentY);
    }
    function _clamp(p: real): real {
        return Math.max(k.minPos, Math.min(k.maxPos, p));
    }
    function _write(p: real): void {
        if (!k.flick)
            return;
        const c = k._clamp(p);
        if (k.horizontal)
            k.flick.contentX = c;
        else
            k.flick.contentY = c;
        k._last = c;
        k.moved();
    }
    function _trim(now: real): void {
        const w = ScrollFeel.velocityWindowMs;
        let i = 0;
        while (i < k._samples.length && now - k._samples[i].t > w)
            i++;
        if (i > 0)
            k._samples = k._samples.slice(i);
    }
    function _start(mode: string): void {
        k._mode = mode;
        k._last = k._pos();
        k._tickAt = Date.now();
        tick.running = true;
    }
    // Motion advances by the WALL time between ticks, not by frameTime: frames
    // come at whatever cadence the window presents (offscreen, a scene that
    // shows nothing new is not redrawn for a while), and a glide that only
    // counts frames falls behind (measured: 115 of 120 px after 290 ms).
    property real _tickAt: 0

    property FrameAnimation _tick: FrameAnimation {
        id: tick
        running: false
        onTriggered: k._step()
    }
    // Frames are the clock, but a window that presents none for a while (hidden,
    // occluded, offscreen -- where a glide would stall after 18 ticks) must still
    // reach its target: this steps the motion only when no frame has ticked for
    // 14 ms, so it never fires while frames flow, and it runs only with the motion.
    property Timer _nudge: Timer {
        interval: 16
        repeat: true
        running: tick.running
        onTriggered: {
            if (Date.now() - k._tickAt >= 14)
                k._step();
        }
    }

    function _step(): void {
        if (!k.flick || k._mode === "") {
            k.stop();
            return;
        }
        // Someone else moved it: theirs now.
        if (Math.abs(k._pos() - k._last) > 0.5) {
            k.stop();
            return;
        }
        const now = Date.now();
        // capped: a suspend or a stalled process must not teleport a fling
        const dt = Math.max(0, Math.min(250, now - k._tickAt));
        k._tickAt = now;
        if (k._mode === "glide") {
            k._t += dt;
            const f = Math.min(1, k._t / Math.max(1, ScrollFeel.notchMs));
            const e = 1 - Math.pow(1 - f, 3);
            k._write(k._from + (k._to - k._from) * e);
            if (f >= 1)
                k.stop();
            return;
        }
        // fling: integrate the exponential decay exactly over dt
        const tau = Math.max(1, ScrollFeel.momentumTau);
        const decay = Math.exp(-dt / tau);
        const step = k._v * tau * (1 - decay);
        k._v *= decay;
        const before = k._pos();
        k._write(before + step);
        const hitEnd = k._pos() === before && step !== 0;
        if (hitEnd || Math.abs(k._v) < 0.02)
            k.stop();
    }
}
