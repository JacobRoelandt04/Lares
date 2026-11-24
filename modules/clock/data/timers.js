.pragma library

// =============================================================================
// timers.js -- the clock's timers as pure functions of state and time.
//
// Everything here takes a snapshot and a time (ms, the service's clock) and
// returns a NEW snapshot; nothing reads the wall clock or mutates its input.
// TimerService owns the state, the ticking, the disk and the side effects.
//
// Times are absolute epochs, so a timer survives a shell restart and a
// suspend: whatever should have happened in between is worked out on the
// next evaluation, and marked late.
// =============================================================================

// ---- Alarms ----------------------------------------------------------------
// An alarm is { hour, minute, days } in LOCAL time. `days` is a bitmask by
// Date.getDay() (Sunday = bit 0 .. Saturday = bit 6); 0 is a one-shot, which
// rings at the next hour:minute to come.
//
// The next time it rings strictly after `fromMs`. Built from local calendar
// fields, so a DST change moves nothing: 07:00 is 07:00 on both sides of it.
// A time the spring-forward skips (02:30 on that night) rings just after the
// gap, at 03:30: Qt's JS engine resolves a missing local time BACKWARDS (to
// 01:30, measured), which would ring an hour early, so the result is checked
// and moved forward by what it came out short.
function nextOccurrence(alarm, fromMs) {
    const from = new Date(fromMs);
    for (let k = 0; k < 9; k++) {
        let c = new Date(from.getFullYear(), from.getMonth(), from.getDate() + k,
                         alarm.hour, alarm.minute, 0, 0);
        const want = alarm.hour * 60 + alarm.minute, got = c.getHours() * 60 + c.getMinutes();
        if (got !== want) {
            const short = ((want - got) % 1440 + 1440) % 1440;
            if (short > 0 && short < 720)
                c = new Date(c.getTime() + short * 60000);
        }
        if (c.getTime() <= fromMs)
            continue;
        if (alarm.days && !(alarm.days & (1 << c.getDay())))
            continue;
        return c.getTime();
    }
    return -1;
}

// ---- Countdown -------------------------------------------------------------
// { state: "idle" | "running" | "paused" | "done", setMs, totalMs,
//   startedAt, endsAt, remainMs, doneAt }
function countdownFresh(setMs) {
    return { state: "idle", setMs: setMs || 0, totalMs: 0, startedAt: 0, endsAt: 0, remainMs: 0, doneAt: 0 };
}

function countdownStart(c, now) {
    if (c.state === "running" || c.setMs <= 0)
        return c;
    if (c.state === "paused")
        return countdownResume(c, now);
    return Object.assign({}, c, { state: "running", totalMs: c.setMs, startedAt: now,
                                  endsAt: now + c.setMs, remainMs: c.setMs, doneAt: 0 });
}

function countdownPause(c, now) {
    if (c.state !== "running")
        return c;
    return Object.assign({}, c, { state: "paused", remainMs: Math.max(0, c.endsAt - now) });
}

function countdownResume(c, now) {
    if (c.state !== "paused")
        return c;
    const endsAt = now + c.remainMs;
    return Object.assign({}, c, { state: "running", endsAt: endsAt, startedAt: endsAt - c.totalMs });
}

// +ms while it runs (or is paused): the end moves out and the total grows, so
// the bar's fill steps back rather than jumping ahead.
function countdownAdd(c, ms, now) {
    if (c.state === "running")
        return Object.assign({}, c, { endsAt: c.endsAt + ms, totalMs: c.totalMs + ms });
    if (c.state === "paused")
        return Object.assign({}, c, { remainMs: c.remainMs + ms, totalMs: c.totalMs + ms });
    return c;
}

function countdownRemaining(c, now) {
    if (c.state === "running") return Math.max(0, c.endsAt - now);
    if (c.state === "paused") return c.remainMs;
    if (c.state === "done") return 0;
    return c.setMs;
}

// { c, ended: { at } | null }
function countdownAdvance(c, now) {
    if (c.state !== "running" || now < c.endsAt)
        return { c: c, ended: null };
    return { c: Object.assign({}, c, { state: "done", remainMs: 0, doneAt: c.endsAt }),
             ended: { at: c.endsAt } };
}

// ---- Pomodoro --------------------------------------------------------------
// Four sessions -- the bar's four pieces -- each a focus followed by a short
// break, the last followed by the long break instead, which ends the cycle.
//
// { state: "idle" | "running" | "paused" | "waiting",
//   phase: "focus" | "short" | "long", session: 0..3,
//   phaseMs, startedAt, endsAt, remainMs,
//   pieces: [{ focus: 0|1, brk: 0|1 } x 4],   what is complete
//   next: { phase, session } | null }        what "waiting" waits to start
//
// cfg: { focusMs, shortMs, longMs, advanceMode: "wait" | "auto" | "breaksAuto" }
function pomoFresh() {
    return { state: "idle", phase: "focus", session: 0, phaseMs: 0, startedAt: 0, endsAt: 0,
             remainMs: 0, pieces: _emptyPieces(), next: null };
}

function _emptyPieces() {
    return [{ focus: 0, brk: 0 }, { focus: 0, brk: 0 }, { focus: 0, brk: 0 }, { focus: 0, brk: 0 }];
}

function _clonePieces(p) {
    return p.map(x => ({ focus: x.focus, brk: x.brk }));
}

function phaseLength(cfg, phase) {
    return phase === "focus" ? cfg.focusMs : phase === "short" ? cfg.shortMs : cfg.longMs;
}

function _startPhase(p, cfg, phase, session, at) {
    const len = phaseLength(cfg, phase);
    return Object.assign({}, p, { state: "running", phase: phase, session: session, phaseMs: len,
                                  startedAt: at, endsAt: at + len, remainMs: len, next: null });
}

// What follows a phase: a focus is followed by its short break (the long
// one after the fourth), a short break by the next focus, the long break by
// nothing -- the cycle is over.
function nextPhase(phase, session) {
    if (phase === "focus")
        return session < 3 ? { phase: "short", session: session } : { phase: "long", session: 3 };
    if (phase === "short")
        return { phase: "focus", session: session + 1 };
    return null;
}

function autoStarts(cfg, next) {
    if (cfg.advanceMode === "auto")
        return true;
    if (cfg.advanceMode === "breaksAuto")
        return next.phase !== "focus";
    return false;
}

// Start: a fresh cycle from idle, the pending phase from waiting, the
// current phase again from paused.
function pomoStart(p, cfg, now) {
    if (p.state === "idle")
        return _startPhase(Object.assign({}, p, { pieces: _emptyPieces() }), cfg, "focus", 0, now);
    if (p.state === "waiting" && p.next)
        return _startPhase(p, cfg, p.next.phase, p.next.session, now);
    if (p.state === "paused")
        return pomoResume(p, now);
    return p;
}

function pomoPause(p, now) {
    if (p.state !== "running")
        return p;
    return Object.assign({}, p, { state: "paused", remainMs: Math.max(0, p.endsAt - now) });
}

function pomoResume(p, now) {
    if (p.state !== "paused")
        return p;
    const endsAt = now + p.remainMs;
    return Object.assign({}, p, { state: "running", endsAt: endsAt, startedAt: endsAt - p.phaseMs });
}

// The current phase completes at `at`: its piece is marked, and the next
// phase starts right there (chained from the exact end, so a machine that
// slept through two phases lands where it would have been) or waits.
function _complete(p, cfg, at) {
    const pieces = _clonePieces(p.pieces);
    if (p.phase === "focus")
        pieces[p.session].focus = 1;
    else if (p.phase === "short")
        pieces[p.session].brk = 1;
    const nx = nextPhase(p.phase, p.session);
    if (!nx)
        return Object.assign(pomoFresh(), {});
    const done = Object.assign({}, p, { pieces: pieces });
    if (autoStarts(cfg, nx))
        return _startPhase(done, cfg, nx.phase, nx.session, at);
    return Object.assign({}, done, { state: "waiting", next: nx, startedAt: 0, endsAt: 0, remainMs: 0 });
}

// { p, ended: [{ phase, session, at, next }] } -- every phase that ended by
// `now`, oldest first.
function pomoAdvance(p, cfg, now) {
    const ended = [];
    let guard = 0;
    while (p.state === "running" && now >= p.endsAt && guard++ < 16) {
        const at = p.endsAt;
        const was = { phase: p.phase, session: p.session, at: at };
        p = _complete(p, cfg, at);
        was.next = p.state === "waiting" ? p.next : (p.state === "running" ? { phase: p.phase, session: p.session } : null);
        ended.push(was);
    }
    return { p: p, ended: ended };
}

// Skip: the phase ends now, as if it had run out (its piece is marked).
function pomoSkip(p, cfg, now) {
    if (p.state !== "running" && p.state !== "paused")
        return p;
    return _complete(p, cfg, now);
}

// ---- Stopwatch -------------------------------------------------------------
// { state: "idle" | "running" | "paused", startedAt, accumMs }
function stopwatchFresh() {
    return { state: "idle", startedAt: 0, accumMs: 0 };
}

function stopwatchElapsed(s, now) {
    return s.accumMs + (s.state === "running" ? Math.max(0, now - s.startedAt) : 0);
}

// ---- The bar ---------------------------------------------------------------
// Is anything IN PROGRESS that the Timers tab shows: a countdown running or paused, a pomodoro in a session (running, paused, or
// waiting for the next phase to be started), a stopwatch running or paused. A finished countdown is not (it is done, the bar's
// full groove stays until it is dismissed); an alarm is armed, not running.
function inProgress(countdown, pomo, stopwatch) {
    const c = countdown ? countdown.state : "idle";
    const p = pomo ? pomo.state : "idle";
    const s = stopwatch ? stopwatch.state : "idle";
    return c === "running" || c === "paused" || p === "running" || p === "paused" || p === "waiting"
        || s === "running" || s === "paused";
}

// The tab the clock popup opens on (clock.md "Default tab"): the
// Timers tab when a timer FINISHED and nobody has looked at it since (`finishedUnseen`: told once -- the owner clears it as it opens
// there, so the next open is back to the rule); otherwise the calendar, unless a timer is in progress AND the Timers tab is the one
// the popup was last left on -- so a pomodoro running does not drag the popup to the Timers tab for ever: change to the calendar
// before closing and it opens there. The Screen tab is never a default. That is `mode` "auto" (clock.jsonc `open`); "calendar" and
// "timers" open on that tab, "last" on the one it was left on. A timer that finished unseen wins whatever the mode.
function openTab(lastTab, timerInProgress, finishedUnseen, mode) {
    if (finishedUnseen === true)
        return "timers";
    if (mode === "calendar" || mode === "timers")
        return mode;
    if (mode === "last")
        return lastTab || "calendar";
    return lastTab === "timers" && timerInProgress ? "timers" : "calendar";
}

// WHICH VIEW OF THE TIMERS CARD THE POPUP OPENS ON (the timer type counts, not only the tab: a pomodoro
// started, the popup closed and opened again opens on the pomodoro, not on the regular timer). The card's views, by index: the countdown, the pomodoro, the stopwatch, the alarms. The view of the timer
// that FINISHED and has not been looked at, when one did (`finishedKind`: "countdown" | "pomodoro" | "alarm", "" for none); else of
// the timer in progress that was started (or resumed) most recently -- `touched` is { countdown, pomodoro, stopwatch }: the service's
// time of each one's last start, 0 for none; equal times (a service that was restored from a file knows none) go to the pomodoro,
// then the countdown, then the stopwatch; -1 when nothing is in progress (the card keeps the view it has).
var KIND_VIEW = { countdown: 0, pomodoro: 1, stopwatch: 2, alarm: 3 };
function openView(finishedKind, countdown, pomo, stopwatch, touched) {
    if (finishedKind && KIND_VIEW[finishedKind] !== undefined)
        return KIND_VIEW[finishedKind];
    const live = [];
    const c = countdown ? countdown.state : "idle", p = pomo ? pomo.state : "idle", s = stopwatch ? stopwatch.state : "idle";
    const t = touched || {};
    if (p === "running" || p === "paused" || p === "waiting")
        live.push({ view: 1, at: t.pomodoro || 0, rank: 0 });
    if (c === "running" || c === "paused")
        live.push({ view: 0, at: t.countdown || 0, rank: 1 });
    if (s === "running" || s === "paused")
        live.push({ view: 2, at: t.stopwatch || 0, rank: 2 });
    if (live.length === 0)
        return -1;
    live.sort(function (a, b) { return b.at - a.at || a.rank - b.rank; });
    return live[0].view;
}

// What the Workspaces groove shows: a running pomodoro wins, otherwise the countdown. Tones: 0 countdown, 1 focus, 2 break.
//
// THE FOUR SESSIONS RUN ROUND THE CLOCK, EVERY ONE LEFT TO RIGHT (1 to 2; 2 to 3
// bottom (same as ball); 2 to 3 top (also from left to right); 3 to 4). The groove's pieces are Workspaces' own numbering (its
// `_subPieces`): 0 the left line (workspace 1 to 2), 1 the upper track, 2 the right line (3 to 4), 3 the lower track -- the ball's own path
// from 2 to 3. Session k fills RAIL_PIECE[k]: the left line, the lower track, the upper track, the right line. (No piece is
// reversed: the lower track fills left to right too.) `pomo.pieces[k]` is the SESSION's own record (what it completed) and keeps its index; only what is drawn is mapped.
var RAIL_PIECE = [0, 3, 1, 2];
function barFills(countdown, pomo, now) {
    const out = [];
    if (pomo && pomo.state !== "idle") {
        for (let i = 0; i < 4; i++) {
            const pc = pomo.pieces[i];
            const draining = (pomo.state === "running" || pomo.state === "paused") && pomo.phase === "long";
            if (draining)
                continue;
            if (pc.focus > 0)
                out.push({ piece: RAIL_PIECE[i], tone: 1, to1: pc.focus });
            if (pc.brk > 0)
                out.push({ piece: RAIL_PIECE[i], tone: 2, to1: pc.brk });
        }
        if (pomo.state === "running" || pomo.state === "paused") {
            const running = pomo.state === "running";
            const frac = running ? 0 : 1 - pomo.remainMs / Math.max(1, pomo.phaseMs);
            if (pomo.phase === "long") {
                // The whole line clears over the long break, every piece at once.
                for (let i = 0; i < 4; i++) {
                    const pc = pomo.pieces[i];
                    for (const tone of [1, 2]) {
                        if ((tone === 1 ? pc.focus : pc.brk) <= 0)
                            continue;
                        out.push(running
                            ? { piece: RAIL_PIECE[i], tone: tone, to0: 1, to1: 0, t0: pomo.startedAt, t1: pomo.endsAt }
                            : { piece: RAIL_PIECE[i], tone: tone, to1: 1 - frac });
                    }
                }
            } else {
                const tone = pomo.phase === "focus" ? 1 : 2;
                const s = pomo.session;
                out.push(running
                    ? { piece: RAIL_PIECE[s], tone: tone, to0: 0, to1: 1, t0: pomo.startedAt, t1: pomo.endsAt }
                    : { piece: RAIL_PIECE[s], tone: tone, to1: frac });
            }
        }
        return out;
    }
    if (countdown) {
        if (countdown.state === "running")
            out.push({ piece: -1, tone: 0, to0: 0, to1: 1, t0: countdown.startedAt, t1: countdown.endsAt });
        else if (countdown.state === "paused")
            out.push({ piece: -1, tone: 0, to1: 1 - countdown.remainMs / Math.max(1, countdown.totalMs) });
        else if (countdown.state === "done")
            out.push({ piece: -1, tone: 0, to1: 1 });
    }
    return out;
}
