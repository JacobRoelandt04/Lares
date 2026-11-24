pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// BreakModel.qml -- the break nudge's rules, with no machine in them: how much USE the user has banked, as ONE progress fill for the
// workspaces rail (the Workspaces `fills` fact, tone `tone`) and ONE signal when it is full.
//
// CREDIT is seconds of use. It grows only while the user is active, and progress = credit / durationS.
//   - IDLE, LOCK and SUSPEND are one kind of thing, an idle SPAN. An idle shorter than `graceS` is use. The host's IdleMonitor fires
//     after graceS of no input: the span began graceS ago, so the credit given since then is taken back and accruing stops. When
//     input returns (idle false, unlock, resume) the span's length i = now - start rewinds the credit by
//         rewind(i) = clamp((i - graceS) / (pauseS - graceS), 0, 1) ^ rewindPower     of the FULL rail (durationS)
//     a span of pauseS or more empties even a full rail; small idles cost little and the cost grows faster the longer it is.
//     Causes that overlap (idle, then lock, then suspend) are ONE span from the earliest start, counted once.
//   - THE DRAWN FILL MOVES ONLY ON ITS OWN BEAT: every `stepS` it is set to the current progress and EASES there (`easeMs`, OutCubic),
//     published as a fact {t0, t1, ease} the rail draws by itself. Between beats nothing runs: one single-shot timer is re-armed per
//     beat (and stopped in a span, at full and when disarmed). A rewind is shown at once when the user returns (it eases too).
//   - HIDDEN ZONE: below `hiddenS` of credit nothing is drawn; the beat that first finds it above eases the fill in from the rail's
//     start, a rewind below it eases it back to the start.
//   - FULL: `filled()` once when the DRAWN fill lands on full; again only after the fill has gone below `refullBelow` (0.9) of the rail.
//   - `armed: false` is no fill at all.
// Inputs the host writes: `idle`, `locked`, `sleepBegan()`, `resume()`. `clock` is { now() [, scale] }; null = the wall clock.
// =============================================================================
Item {
    id: root

    property bool armed: true
    property real durationS: 3000
    property real pauseS: 300
    property real graceS: 30
    property real rewindPower: 2
    property real stepS: 60
    property real easeMs: 700
    property real hiddenS: 600
    // The share of the rail the drawn fill must have gone below before a full may be announced again.
    property real refullBelow: 0.9
    // The rail's tone for this fill (Workspaces.breakTone).
    property int tone: 3
    property var clock: null

    // Inputs.
    property bool idle: false
    property bool locked: false

    // Outputs.
    readonly property var fills: root._fills
    readonly property bool full: root._full
    signal filled

    // Counting for the probe, mutated in place (a property would be a dependency): beats, publishes, lands.
    readonly property var stats: ({ beats: 0, publishes: 0, lands: 0 })

    // The next wake-up of the one timer in ms of ITS clock (0 = nothing is armed): what a probe reads for "nothing runs between beats".
    readonly property int nextWakeMs: beat.running ? beat.interval : 0

    function nowMs(): real {
        return root.clock ? root.clock.now() : Date.now();
    }
    // The rewind share of the full rail for an idle span of `spanS` seconds.
    function rewindShare(spanS: real): real {
        const span = Math.max(root.pauseS - root.graceS, 1e-6);
        const x = Math.max(0, Math.min(1, (spanS - root.graceS) / span));
        return Math.pow(x, root.rewindPower);
    }
    // Credit in seconds at `now`.
    function creditAt(now: real): real {
        if (!root._accruing)
            return root._credit;
        return Math.min(root.durationS, root._credit + Math.max(0, now - root._mark) / 1000);
    }
    // 0..1 at `now`, for a reader that wants the number (the mockup, the probe).
    function progressAt(now: real): real {
        return root.creditAt(now) / root.durationS;
    }
    // Where the DRAWN head is at `now` (0 = hidden).
    function drawnAt(now: real): real {
        const f = root._fact;
        if (!f)
            return 0;
        const u = f.t1 > f.t0 ? Math.max(0, Math.min(1, (now - f.t0) / (f.t1 - f.t0))) : 1;
        return f.to0 + (f.to1 - f.to0) * (1 - Math.pow(1 - u, 3));
    }

    // The machine is about to suspend: a span begins now.
    function sleepBegan(): void {
        if (!root.armed)
            return;
        root._sleeping = true;
        root._spanSync(root.nowMs());
    }
    // The machine woke. With no `sleepBegan` heard the sleep is the gap since the last accounting, which is all the wall clock can say.
    function resume(): void {
        if (!root.armed)
            return;
        if (!root._sleeping) {
            root._sleeping = true;
            root._spanSync(root._mark);
        }
        root._sleeping = false;
        root._spanSync(0);
    }
    // The mockup's "jump to": stand at `share` of the rail now.
    function seek(share: real): void {
        if (!root.armed || root._inSpan)
            return;
        const now = root.nowMs();
        root._settle(now);
        root._credit = Math.max(0, Math.min(1, share)) * root.durationS;
        root._fullAt = root._credit >= root.durationS ? now : 0;
        root._publish(now);
        root._arm();
    }

    property real _credit: 0
    property real _mark: 0
    property real _fullAt: 0
    property bool _sleeping: false
    property bool _inSpan: false
    property real _spanStart: 0
    property bool _full: false
    property bool _announced: false
    property bool _pendingLand: false
    property var _fact: null
    property var _fills: []
    readonly property bool _accruing: root.armed && !root._inSpan

    // Bank the use since the last accounting (capped at full: the instant it was reached is kept).
    function _settle(now: real): void {
        if (root._accruing && now > root._mark) {
            const room = root.durationS - root._credit;
            const dt = (now - root._mark) / 1000;
            if (dt >= room) {
                if (root._fullAt <= 0)
                    root._fullAt = root._mark + room * 1000;
                root._credit = root.durationS;
            } else {
                root._credit += dt;
            }
        }
        root._mark = now;
    }
    // Take back the credit given in [fromMs, toMs] (none after the rail was full).
    function _takeBack(fromMs: real, toMs: real): void {
        const hi = root._fullAt > 0 ? Math.min(toMs, root._fullAt) : toMs;
        root._credit = Math.max(0, root._credit - Math.max(0, hi - fromMs) / 1000);
        if (root._credit < root.durationS)
            root._fullAt = 0;
    }
    // A cause came or went: open, extend or close the ONE span. `startMs` is where the cause's span began.
    function _spanSync(startMs: real): void {
        if (!root.armed)
            return;
        const now = root.nowMs();
        if (root.idle || root.locked || root._sleeping) {
            if (!root._inSpan) {
                root._settle(now);
                root._inSpan = true;
                root._spanStart = startMs;
                root._takeBack(startMs, now);
                beat.stop();
            } else if (startMs > 0 && startMs < root._spanStart) {
                root._takeBack(startMs, root._spanStart);
                root._spanStart = startMs;
            }
        } else if (root._inSpan) {
            const spanS = (now - root._spanStart) / 1000;
            root._inSpan = false;
            root._mark = now;
            root._credit = Math.max(0, root._credit - root.rewindShare(spanS) * root.durationS);
            if (root._credit < root.durationS)
                root._fullAt = 0;
            root._publish(now);
            root._arm();
        }
    }

    // Set the drawn target from the credit (callers have settled) and ease the head there from where it is drawn now.
    function _publish(now: real): void {
        const c = root._credit;
        const target = c >= root.hiddenS && c > 0 ? Math.min(1, c / root.durationS) : 0;
        if (target < root.refullBelow) {
            root._announced = false;
            root._full = false;
        }
        if (target < 1)
            root._pendingLand = false;
        const f = root._fact;
        if ((f && Math.abs(f.to1 - target) < 1e-9) || (!f && target === 0))
            return;
        const drawn = root.drawnAt(now);
        root._fact = { piece: -1, tone: root.tone, from: 0, to0: drawn, to1: target, t0: now, t1: now + Math.max(0, root.easeMs), ease: "outCubic" };
        root._fills = target > 0 || drawn > 0 ? [root._fact] : [];
        root.stats.publishes += 1;
        if (target >= 1 && !root._announced)
            root._pendingLand = true;
    }
    // ONE single-shot, for the next beat, or for the instant the drawn fill lands on full.
    function _arm(): void {
        beat.stop();
        if (!root._accruing)
            return;
        const now = root.nowMs();
        let wait = -1;
        if (root._pendingLand && root._fact)
            wait = Math.max(0, root._fact.t1 - now);
        else if (root._credit < root.durationS)
            wait = Math.min(root.stepS, root.durationS - root.creditAt(now)) * 1000;
        if (wait < 0)
            return;
        const scale = root.clock && root.clock.scale ? root.clock.scale : 1;
        beat.interval = Math.max(1, Math.ceil(wait / scale));
        beat.start();
    }
    function _onBeat(): void {
        const now = root.nowMs();
        if (root._pendingLand) {
            if (now < root._fact.t1 - 0.5) {
                root._arm();
                return;
            }
            root._pendingLand = false;
            root._full = true;
            root._announced = true;
            root.stats.lands += 1;
            root.filled();
            root._arm();
            return;
        }
        root.stats.beats += 1;
        root._settle(now);
        root._publish(now);
        root._arm();
    }
    Timer {
        id: beat
        repeat: false
        onTriggered: root._onBeat()
    }

    function _restart(): void {
        beat.stop();
        const now = root.nowMs();
        root._credit = 0;
        root._fullAt = 0;
        root._mark = now;
        root._inSpan = false;
        root._sleeping = false;
        root._full = false;
        root._announced = false;
        root._pendingLand = false;
        root._fact = null;
        root._fills = [];
        if (!root.armed)
            return;
        if (root.idle || root.locked)
            root._spanSync(now);
        else
            root._arm();
    }

    onArmedChanged: root._restart()
    onIdleChanged: root._spanSync(root.nowMs() - root.graceS * 1000)
    onLockedChanged: root._spanSync(root.nowMs())
    onDurationSChanged: if (root.armed && !root._inSpan) {
        const now = root.nowMs();
        root._settle(now);
        root._publish(now);
        root._arm();
    }
    onHiddenSChanged: if (root.armed && !root._inSpan) {
        const now = root.nowMs();
        root._settle(now);
        root._publish(now);
    }
    onStepSChanged: if (root.armed)
        root._arm()
    Component.onCompleted: root._restart()
}
