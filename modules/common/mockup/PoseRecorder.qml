pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// PoseRecorder.qml
//
// A flight recorder for a mockup: it writes down a handful of an object's
// numeric properties every frame, and can then play those frames back --
// forwards, backwards, one at a time, or scrubbed to any moment.
//
// It exists because a QML animation cannot be looked at. `Animation` has
// `paused`, and nothing else: no seek, no reverse, no current time. So a
// choreography made of SequentialAnimations can be watched at full speed or
// slowed down, and that is all -- you cannot stop on the frame where the sweep
// overshoots and step back three frames to see what it did.
//
// Recording the RESULT sidesteps that completely. What plays back is not a
// re-derivation of the animation, it is the exact frames the animation
// produced, so what you scrub through is what you saw. It also costs the
// animation nothing: no easing has to be reimplemented, no timeline has to be
// kept in step with the one that ships, and the module under the recorder is
// the module as it ships.
//
// The cost, stated plainly: you can only scrub what has already happened. Run
// the sequence once, then walk through it.
//
// THE CLOCK FOLLOWS THE POSE. A recorder is a frame clock, and a running frame
// clock is the most expensive thing a mockup can leave switched on: Qt Quick
// renders a frame for as long as ANY animation is running, whether or not a
// pixel changed. Recording a pose that is not moving therefore costs a full
// repaint of the whole window, forever -- on the audio player it was 7% of a
// cpu thread and 49 of the 72 frames a second the mockup drew while sitting
// there doing nothing. So the clock is started by the pose CHANGING (every
// watched property's own change signal) and stops `tailMs` after the last
// change. What is recorded is the same frames as before; what is not recorded
// is the dead air, where every frame would have been a copy of the one before
// it. Timestamps stay on a WALL clock so that dead air is still a GAP of its
// true length: `spanMs` is the sequence's real duration including any hold in
// it, a scrub interpolates across the hold between two identical poses, and
// playback takes exactly as long as the animation did. (`elapsedTime` cannot
// be used for this: a FrameAnimation restarts it from zero every time it is
// started, so a stopping clock would send the history backwards in time and
// take the prune with it.)
//
//   PoseRecorder {
//       id: rec
//       target: popup.vinyl
//       props: ["spinDeg", "tiltX", "discHeight", "sleeveX"]
//       onBeforeScrub: popup.vinyl.freeze()   // stop what is writing the pose
//   }
//
// Two rules for `props`:
//
//   - NUMBERS only. Frames are interpolated between samples so a scrub lands
//     between them, and there is no sensible interpolation of a string.
//   - Nothing a BINDING drives. Playback assigns, and an assignment from JS
//     onto a bound property destroys that binding for good. Pose properties an
//     animation writes are exactly right; a colour bound to a theme token is
//     exactly wrong.
//
// `beforeScrub` fires once when playback takes the pose over, and is the host's
// chance to stop whatever else is writing it. Without it the recorder and the
// animation both write the same properties and the result is neither.
// =============================================================================
Item {
    id: rec

    // ======================================================================
    // PUBLIC API
    // ======================================================================
    property var target: null
    property var props: []
    // How much history to keep. Twenty seconds covers the record's longest
    // sequence twice over, at about 60 numbers a frame -- a few hundred KB.
    property real historySec: 20
    // Recording stops on its own the moment playback takes over.
    property bool recording: true
    // How long the clock keeps running after the last change it saw. Long
    // enough that a sequence which pauses mid-flight (an animation's own
    // PauseAnimation, a value that holds for a couple of frames) is recorded
    // as one take rather than cut into pieces; short enough that an idle
    // mockup is idle within a third of a second.
    property int tailMs: 300
    // A pause in the recording longer than this is stored as this long: the
    // wall clock keeps its true gaps by default (0), which is right for a pose
    // that merely holds, and wrong for a take whose animation was PAUSED --
    // playback would sit still for as long as the pause lasted. Default off;
    // the launcher's flourish sets it (its transport pauses the animation).
    property int maxGapMs: 0

    // Both read `_rev` first, deliberately. The frame buffer is a JS array
    // mutated in place -- pushing into it does NOT notify, and assigning the
    // same reference back does not either, so a binding on `_frames.length`
    // reads zero for the whole run and every control hung off it stays dead.
    // One counter bumped per recorded frame is what makes them live.
    readonly property int frameCount: {
        rec._rev;
        return rec._frames.length;
    }
    readonly property real spanMs: {
        rec._rev;
        return rec._frames.length < 2 ? 0 : rec._frames[rec._frames.length - 1].t - rec._frames[0].t;
    }
    // Where the head is, in ms from the first recorded frame. Writable: this
    // IS the scrub.
    property real position: 0
    readonly property int frameIndex: {
        rec._rev;
        return rec._indexAt(rec.position);
    }
    readonly property bool scrubbing: rec._scrubbing
    readonly property bool playing: playClock.running

    property real speed: 1.0
    // 1 plays forward, -1 rewinds. Nothing else is meaningful.
    property int direction: 1

    signal beforeScrub

    // ======================================================================
    // TRANSPORT
    // ======================================================================
    // Throws the history away and records from now. What you press before the
    // thing you want to look at.
    function arm() {
        rec._frames = [];
        rec._skew = 0;
        rec._lastRaw = 0;
        rec._rev++;
        rec._scrubbing = false;
        rec.position = 0;
        playClock.stop();
        rec.recording = true;
        rec._poke();
    }

    // Hands the pose back to whatever owns it and starts recording again.
    function release() {
        playClock.stop();
        rec._scrubbing = false;
        rec.recording = true;
        rec._poke();
    }

    function seek(ms) {
        rec._takeOver();
        rec.position = Math.max(0, Math.min(rec.spanMs, ms));
        rec._apply(rec.position);
    }

    function step(frames) {
        rec._takeOver();
        playClock.stop();
        const i = Math.max(0, Math.min(rec._frames.length - 1, rec.frameIndex + frames));
        if (rec._frames.length === 0)
            return;
        rec.position = rec._frames[i].t - rec._frames[0].t;
        rec._apply(rec.position);
    }

    function play(dir) {
        if (rec._frames.length < 2)
            return;
        rec._takeOver();
        rec.direction = dir < 0 ? -1 : 1;
        // Playing forward from the end, or back from the start, is a replay
        // rather than a no-op: it is what the button means.
        if (rec.direction > 0 && rec.position >= rec.spanMs - 1e-3)
            rec.position = 0;
        if (rec.direction < 0 && rec.position <= 1e-3)
            rec.position = rec.spanMs;
        playClock.start();
    }

    function pause() {
        playClock.stop();
    }

    // The value of one recorded property at the head, for a readout.
    function valueAt(name) {
        const i = rec.props.indexOf(name);
        if (i < 0 || rec._frames.length === 0)
            return 0;
        return rec._sample(rec.position, i);
    }

    // ======================================================================
    // INTERNALS
    // ======================================================================
    property var _frames: []
    // The wall time squeezed out of long gaps (maxGapMs), and the last raw stamp.
    property real _skew: 0
    property real _lastRaw: 0
    property int _rev: 0
    property bool _scrubbing: false

    function _takeOver() {
        if (rec._scrubbing)
            return;
        rec._scrubbing = true;
        rec.recording = false;
        // The host stops whatever else is writing the pose. Both writing it is
        // the one way this tool can lie about what it recorded.
        rec.beforeScrub();
    }

    function _indexAt(ms) {
        const f = rec._frames;
        if (f.length === 0)
            return 0;
        const t = f[0].t + ms;
        // Linear from the end: a scrub moves by a frame or two at a time, and
        // the head is nearly always already where the answer is.
        let i = f.length - 1;
        while (i > 0 && f[i].t > t)
            i--;
        return i;
    }

    function _sample(ms, propIdx) {
        const f = rec._frames;
        if (f.length === 0)
            return 0;
        const i = rec._indexAt(ms);
        if (i >= f.length - 1)
            return f[f.length - 1].v[propIdx];
        const t = f[0].t + ms;
        const span = f[i + 1].t - f[i].t;
        const u = span > 0 ? Math.max(0, Math.min(1, (t - f[i].t) / span)) : 0;
        return f[i].v[propIdx] + (f[i + 1].v[propIdx] - f[i].v[propIdx]) * u;
    }

    function _apply(ms) {
        if (!rec.target || rec._frames.length === 0)
            return;
        for (let p = 0; p < rec.props.length; ++p)
            rec.target[rec.props[p]] = rec._sample(ms, p);
    }

    // ---- is the pose moving? ---------------------------------------------
    //
    // Connected to each watched property's own change signal, which is the
    // only way to know a pose moved WITHOUT a clock that costs what the clock
    // costs. Rewired whenever the target or the property list changes, and the
    // old wiring is taken down first: a recorder repointed at a second object
    // would otherwise be woken by the first one forever.
    property bool _moving: false
    property var _wiredTarget: null
    property var _wiredProps: []
    // ONE function object, made once and kept. `rec._poke` is a fresh wrapper
    // on every property lookup, so `disconnect(rec._poke)` would be handed a
    // different object than `connect(rec._poke)` was and would match nothing --
    // silently, leaving the old target wired to wake this recorder forever.
    property var _pokeFn: null
    Timer {
        id: tail
        interval: rec.tailMs
        onTriggered: rec._moving = false
    }
    function _poke() {
        rec._moving = true;
        tail.restart();
    }
    function _rewire() {
        if (!rec._pokeFn)
            return;                        // before Component.onCompleted
        const old = rec._wiredTarget;
        if (old)
            for (const p of rec._wiredProps) {
                const sig = old[p + "Changed"];
                if (sig)
                    sig.disconnect(rec._pokeFn);
            }
        rec._wiredTarget = rec.target;
        rec._wiredProps = rec.props.slice();
        if (rec.target)
            for (const p of rec._wiredProps) {
                const sig = rec.target[p + "Changed"];
                if (sig)
                    sig.connect(rec._pokeFn);
            }
        // A rewire is itself a reason to record: the first frames of whatever
        // the new target is doing are the ones worth having.
        rec._poke();
    }
    onTargetChanged: rec._rewire()
    onPropsChanged: rec._rewire()
    Component.onCompleted: {
        rec._pokeFn = function () {
            rec._poke();
        };
        rec._rewire();
    }

    // ---- the recorder ----------------------------------------------------
    FrameAnimation {
        id: recClock
        running: rec.recording && rec._moving && !rec._scrubbing && rec.target !== null && rec.props.length > 0
        onTriggered: {
            const v = [];
            for (let p = 0; p < rec.props.length; ++p) {
                const x = rec.target[rec.props[p]];
                v.push(typeof x === "number" ? x : 0);
            }
            const f = rec._frames;
            // Sampled INSIDE the frame callback, so this is the frame's own
            // moment to within a fraction of a millisecond -- and it keeps
            // running while the clock does not, which is what makes a hold in
            // a sequence a gap of its true length rather than a splice.
            const now = Date.now();
            if (rec.maxGapMs > 0 && f.length > 0 && now - rec._lastRaw > rec.maxGapMs)
                rec._skew += now - rec._lastRaw - rec.maxGapMs;
            rec._lastRaw = now;
            f.push({
                t: now - rec._skew,
                v: v
            });
            const cutoff = f[f.length - 1].t - rec.historySec * 1000;
            let drop = 0;
            while (drop < f.length && f[drop].t < cutoff)
                drop++;
            if (drop > 0)
                f.splice(0, drop);
            rec._rev++;
            // The head follows the tail while recording, so pressing pause and
            // then stepping starts from the last frame rather than from zero.
            rec.position = rec.spanMs;
        }
    }

    // ---- playback --------------------------------------------------------
    FrameAnimation {
        id: playClock
        running: false
        onTriggered: {
            const dt = frameTime * 1000 * Math.max(0.01, rec.speed) * rec.direction;
            let p = rec.position + dt;
            if (p >= rec.spanMs) {
                p = rec.spanMs;
                playClock.stop();
            } else if (p <= 0) {
                p = 0;
                playClock.stop();
            }
            rec.position = p;
            rec._apply(p);
        }
    }

    // A scrub written straight into `position` (a slider) must move the pose
    // too, without going through seek().
    onPositionChanged: if (rec._scrubbing && !playClock.running)
        rec._apply(rec.position)
}
