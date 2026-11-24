pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../common/notify"
import "../../common/system"
import "timers.js" as T

// =============================================================================
// TimerService.qml -- the clock's countdown, pomodoro, stopwatch and alarms.
//
// Lives OUTSIDE the popup (thePopup's Loader destroys the content on every
// close), in the clock's bar-side owner, and is handed to the popup as
// `timers`. An Item, never a pragma Singleton (see NetworkService's header).
//
// State is snapshots -- `countdown`, `pomodoro`, `stopwatch`, each ONE object
// replaced whole, so a reader never sees half a change -- and two ListModels,
// `alarms` and `laps`. The logic is timers.js; this file owns the time, the
// disk and the side effects:
//
//   - one Timer, armed only while something has a deadline, for the nearest
//     one (at most 15 s ahead, so a resume from suspend is noticed within
//     15 s -- the Timer runs on the monotonic clock, which stops in suspend);
//   - every evaluation re-derives everything from the clock, so whatever
//     should have happened while the machine slept or the shell was down
//     happens now, marked late: a countdown finishes "at 14:05", an alarm
//     reads "missed at 07:00" (only within missedWindowMs), a pomodoro in
//     auto mode lands in the phase it would be in. Late means SILENT: a
//     notification, no sound. No sleep inhibitor.
//   - JSON under $XDG_STATE_HOME/lares/clock/timers.json, absolute
//     epochs, so everything survives a shell restart.
//   - THE NOTIFICATION AND THE TIMER ARE ONE ASK: stopping a
//     ringing timer withdraws its notification (`_unring`), and dismissing the notification -- a swipe,
//     a delete, a clear, a click on its body -- stops the timer as the Stop button does (`_noteGone`).
//     The notification is the shell's own (NotificationBus.service) or notify-send's; the second half
//     reads the service's `recordRemoved` and, one turn later, whether the record is still there --
//     a turn later because an ACTION removes its record BEFORE it runs its callback (Snooze must still
//     find the alarm ringing). With notify-send there is no way to hear a dismissal.
//   - A RESUME FROM SUSPEND is taken at once (`Sleep.watcher`): the ticker is a monotonic Timer and
//     stands still while the machine sleeps, so what came due meanwhile waited up to 15 s.
//
// `notifier` and `sound` are anything with the DesktopNotifier / SoundPlayer
// API, or null. A mockup hands in its own, so it never rings alongside the
// live shell, and runs with persist: false.
// =============================================================================
Item {
    id: svc

    // ---- Wiring -------------------------------------------------------------
    property var clock: null            // TimerClock; null = the wall clock
    property bool persist: true
    property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/clock"
    property var notifier: null
    property var sound: null
    // The popup is open on the timers: they are being watched, so nothing
    // pops up (the sound still plays).
    property bool attended: false

    // ---- Settings (persisted) ------------------------------------------------
    // What a right-click on a duration puts back, and where each starts before the user has set it (clock.jsonc focusMin / shortMin /
    // longMin, read as the shell starts).
    property real defaultFocusMs: 25 * 60000
    property real defaultShortMs: 5 * 60000
    property real defaultLongMs: 30 * 60000
    property real focusMs: svc.defaultFocusMs
    property real shortMs: svc.defaultShortMs
    property real longMs: svc.defaultLongMs
    // "wait": every phase waits to be started; "auto": each starts when the
    // last ends; "breaksAuto": breaks start by themselves, focus waits.
    property string advanceMode: "wait"

    // ---- Settings (clock.jsonc timers, never written to timers.json) ----------
    property real snoozeMs: 9 * 60000
    // The countdown's time in a new session (countdownMin, read as the shell starts).
    property real defaultCountdownMs: 5 * 60000
    // Each kind's sound: a file name of the player's soundDir, a path ("~/" the home) or "none". One that is not there plays the
    // default instead: the file is checked when the setting changes (`soundCheck`), never at the ring, where pw-play would exit at once
    // and the loop retry it every 600 ms until `ringMaxMs`.
    readonly property var defaultSounds: ({ countdown: "alarm-clock-elapsed.oga", pomodoro: "complete.oga", alarm: "alarm-clock-elapsed.oga" })
    property var sounds: svc.defaultSounds
    // 0..1; below 0 the sound server's stream level
    property real volume: -1
    // do-not-disturb is on (the notifications' state), and whether the sounds play under it; the card is shown either way
    property bool dnd: false
    property bool soundUnderDnd: true
    // The timer's presets, ms, ascending. The card adds the dial's time with
    // its + and removes one by a right-click.
    property var presets: [60000, 300000, 600000, 1500000, 2700000]
    readonly property int maxPresets: 6

    // ---- Tolerances ----------------------------------------------------------
    // Finishing this much after its time is "late" (silent).
    property int lateToleranceMs: 5000
    // An alarm overdue by more than this is not reported at all (one due within the minute always rings).
    property real missedWindowMs: 12 * 3600000
    // A ringing countdown or alarm stops sounding after this.
    property int ringMaxMs: 60000

    // ---- State -----------------------------------------------------------------
    property var countdown: T.countdownFresh(svc.defaultCountdownMs)
    property var pomodoro: T.pomoFresh()
    property var stopwatch: T.stopwatchFresh()
    // { countdown?: {...}, pomodoro?: {...}, alarm?: { id, at, missed } }
    property var ringing: ({})
    // The enabled alarm that rings next: { id, at } or null.
    property var nextAlarm: null
    // What the Workspaces groove shows; reassigned on state changes only.
    property var barFills: []
    // When each timer was last started or resumed (the service's own time; 0: not since this service began): which of several timers
    // in progress is the one the Timers tab opens on (T.openView). Replaced whole, so a binding on it hears it.
    property var touched: ({ countdown: 0, pomodoro: 0, stopwatch: 0 })
    function _touch(kind) {
        const t = Object.assign({}, svc.touched);
        t[kind] = svc.now();
        svc.touched = t;
    }
    // Something is in progress that the Timers tab shows (T.inProgress): the clock popup's default tab reads it.
    readonly property bool inProgress: T.inProgress(svc.countdown, svc.pomodoro, svc.stopwatch)
    // Bumped whenever the alarm list changes, for bindings that walk it.
    property int alarmSerial: 0
    readonly property alias alarms: alarmModel
    readonly property alias laps: lapModel

    signal finished(string kind, var info)
    // A click on a ring's toast: the host opens the clock popup on the Timers tab, on the view of `kind`.
    signal openRequested(string kind)

    ListModel {
        id: alarmModel
    }
    ListModel {
        id: lapModel
    }

    function now() {
        return svc.clock ? svc.clock.now() : Date.now();
    }
    function _cfg() {
        return { focusMs: svc.focusMs, shortMs: svc.shortMs, longMs: svc.longMs, advanceMode: svc.advanceMode };
    }

    // =========================================================================
    //  Countdown
    // =========================================================================
    function setCountdown(ms) {
        if (svc.countdown.state === "running" || svc.countdown.state === "paused")
            return;
        svc.countdown = T.countdownFresh(Math.max(0, Math.round(ms)));
        svc._changed();
    }
    function start() {
        svc._touch("countdown");
        svc._unring("countdown");
        svc.countdown = T.countdownStart(svc.countdown.state === "done"
            ? T.countdownFresh(svc.countdown.setMs) : svc.countdown, svc.now());
        svc._changed();
    }
    function pause() {
        svc.countdown = T.countdownPause(svc.countdown, svc.now());
        svc._changed();
    }
    function resume() {
        svc._touch("countdown");
        svc.countdown = T.countdownResume(svc.countdown, svc.now());
        svc._changed();
    }
    function reset() {
        svc._unring("countdown");
        svc.countdown = T.countdownFresh(svc.countdown.setMs);
        svc._changed();
    }
    function addTime(ms) {
        svc.countdown = T.countdownAdd(svc.countdown, ms, svc.now());
        svc._changed();
    }
    function remainingMs() {
        return T.countdownRemaining(svc.countdown, svc.now());
    }
    function canAddPreset(ms) {
        return ms > 0 && svc.presets.indexOf(ms) < 0 && svc.presets.length < svc.maxPresets;
    }
    function addPreset(ms) {
        if (!svc.canAddPreset(ms))
            return false;
        svc.presets = svc.presets.concat([ms]).sort((a, b) => a - b);
        svc._save();
        return true;
    }
    function removePreset(ms) {
        const next = svc.presets.filter(x => x !== ms);
        if (next.length === svc.presets.length)
            return;
        svc.presets = next;
        svc._save();
    }

    // =========================================================================
    //  Pomodoro
    // =========================================================================
    function pomoStart() {
        svc._touch("pomodoro");
        svc._unring("pomodoro");
        svc.pomodoro = T.pomoStart(svc.pomodoro, svc._cfg(), svc.now());
        svc._changed();
    }
    function pomoPause() {
        svc.pomodoro = T.pomoPause(svc.pomodoro, svc.now());
        svc._changed();
    }
    function pomoResume() {
        svc._touch("pomodoro");
        svc.pomodoro = T.pomoResume(svc.pomodoro, svc.now());
        svc._changed();
    }
    function pomoSkip() {
        svc._unring("pomodoro");
        svc.pomodoro = T.pomoSkip(svc.pomodoro, svc._cfg(), svc.now());
        svc._changed();
    }
    function pomoReset() {
        svc._unring("pomodoro");
        svc.pomodoro = T.pomoFresh();
        svc._changed();
    }
    function pomoRemainingMs() {
        const p = svc.pomodoro;
        if (p.state === "running") return Math.max(0, p.endsAt - svc.now());
        if (p.state === "paused") return p.remainMs;
        if (p.state === "waiting" && p.next) return T.phaseLength(svc._cfg(), p.next.phase);
        return svc.focusMs;
    }
    onFocusMsChanged: svc._save()
    onShortMsChanged: svc._save()
    onLongMsChanged: svc._save()
    onAdvanceModeChanged: svc._save()

    // =========================================================================
    //  Stopwatch
    // =========================================================================
    function swStart() {
        const s = svc.stopwatch;
        if (s.state === "running")
            return;
        svc._touch("stopwatch");
        svc.stopwatch = { state: "running", startedAt: svc.now(), accumMs: s.accumMs };
        svc._changed();
    }
    function swPause() {
        const s = svc.stopwatch;
        if (s.state !== "running")
            return;
        svc.stopwatch = { state: "paused", startedAt: 0, accumMs: T.stopwatchElapsed(s, svc.now()) };
        svc._changed();
    }
    function swLap() {
        if (svc.stopwatch.state !== "running")
            return;
        const total = T.stopwatchElapsed(svc.stopwatch, svc.now());
        const prev = lapModel.count > 0 ? lapModel.get(0).totalMs : 0;
        lapModel.insert(0, { n: lapModel.count + 1, lapMs: total - prev, totalMs: total });
        svc._changed();
    }
    function swReset() {
        svc.stopwatch = T.stopwatchFresh();
        lapModel.clear();
        svc._changed();
    }
    function swElapsed() {
        return T.stopwatchElapsed(svc.stopwatch, svc.now());
    }

    // =========================================================================
    //  Alarms -- { aid, hour, minute, label, days, enabled, armedFor, snoozeUntil }
    // =========================================================================
    property int _alarmCounter: 0

    function _alarmIndex(id) {
        for (let i = 0; i < alarmModel.count; i++)
            if (alarmModel.get(i).aid === id)
                return i;
        return -1;
    }
    function addAlarm(hour, minute, label, days) {
        svc._alarmCounter += 1;
        const id = "a" + Date.now().toString(36) + svc._alarmCounter;
        const a = { aid: id, hour: hour, minute: minute, label: label || "", days: days || 0,
                    enabled: true, armedFor: 0, snoozeUntil: 0 };
        a.armedFor = T.nextOccurrence(a, svc.now());
        alarmModel.append(a);
        svc._alarmsChanged();
        return id;
    }
    function updateAlarm(id, fields) {
        const i = svc._alarmIndex(id);
        if (i < 0)
            return;
        const a = Object.assign({}, alarmModel.get(i), fields);
        if (fields.hour !== undefined || fields.minute !== undefined || fields.days !== undefined || fields.enabled)
            Object.assign(a, { armedFor: T.nextOccurrence(a, svc.now()), snoozeUntil: 0 });
        alarmModel.set(i, a);
        svc._alarmsChanged();
    }
    function removeAlarm(id) {
        const i = svc._alarmIndex(id);
        if (i < 0)
            return;
        if (svc.ringing.alarm && svc.ringing.alarm.id === id)
            svc._unring("alarm");
        alarmModel.remove(i);
        svc._alarmsChanged();
    }
    function setAlarmEnabled(id, on) {
        svc.updateAlarm(id, { enabled: !!on });
    }
    function snooze() {
        const r = svc.ringing.alarm;
        if (!r)
            return;
        const i = svc._alarmIndex(r.id);
        svc._unring("alarm");
        if (i >= 0) {
            alarmModel.setProperty(i, "snoozeUntil", svc.now() + svc.snoozeMs);
            alarmModel.setProperty(i, "enabled", true);
        }
        svc._alarmsChanged();
    }
    function _alarmsChanged() {
        svc.alarmSerial += 1;
        svc._changed();
    }

    // =========================================================================
    //  Ringing
    // =========================================================================
    // Stop what `kind` is sounding and showing. For a finished countdown this
    // is also its dismissal: the bar's full groove clears.
    function dismiss(kind) {
        svc._unring(kind);
        if (kind === "countdown" && svc.countdown.state === "done") {
            svc.countdown = T.countdownFresh(svc.countdown.setMs);
            svc._changed();
        }
    }
    function _unring(kind) {
        if (!svc.ringing[kind])
            return;
        const r = Object.assign({}, svc.ringing);
        delete r[kind];
        svc.ringing = r;
        delete svc._posted[kind];
        if (svc.sound)
            svc.sound.stop(kind);
        if (svc.notifier)
            svc.notifier.withdraw(kind);
    }
    function _ring(kind, info, spec, loop) {
        const r = Object.assign({}, svc.ringing);
        r[kind] = info;
        svc.ringing = r;
        const play = svc._soundPlays[kind] ?? svc.defaultSounds[kind];
        if (svc.sound && !info.late && !info.missed && play !== "none" && (svc.soundUnderDnd || !svc.dnd))
            svc.sound.play(kind, play, { loop: loop, maxMs: svc.ringMaxMs, volume: svc.volume >= 0 ? svc.volume : undefined });
        if (svc.notifier && !svc.attended) {
            // A click on the toast's body is its `default` action (no button): it opens the clock on the Timers tab.
            const open = { id: "default", label: "Open timers", run: () => svc.openRequested(kind) };
            svc.notifier.notify(kind, Object.assign({}, spec, { actions: [open].concat(spec.actions || []) }));
            // Only one the service really recorded can be dismissed (a post its policy dropped is not on it; a post is synchronous).
            if (svc._noteLive(kind))
                svc._posted[kind] = true;
            else
                delete svc._posted[kind];
        }
    }

    // ---- the notification dismissed = the timer dismissed ----------------------------------------------------------------------
    // Kinds whose notification this service posted and that still ring. Mutated in place: nothing binds it.
    property var _posted: ({})
    // Is the notification posted for `kind` still on the shell's service? True when that cannot be told (no shell service, a notifier
    // that is not the shell's adapter): a dismissal nobody can hear is not one.
    function _noteLive(kind) {
        const bus = NotificationBus.service;
        const src = svc.notifier ? svc.notifier.sourceId : undefined;
        if (!bus || !bus.store || !src)
            return true;
        const all = bus.store.all();
        for (let i = 0; i < all.length; i++)
            if (all[i].sourceId === src && all[i].key === kind && !all[i].closed)
                return true;
        return false;
    }
    // One turn after a record left the service: every kind still ringing whose notification is gone was dismissed by the user (what we
    // withdrew ourselves is no longer ringing, and an action has run its callback by now).
    function _noteGone() {
        for (const kind of Object.keys(svc._posted)) {
            if (svc.ringing[kind] && !svc._noteLive(kind))
                svc.dismiss(kind);
        }
    }
    Connections {
        target: NotificationBus.service
        ignoreUnknownSignals: true
        function onRecordRemoved(uid: string) {
            if (Object.keys(svc._posted).length > 0)
                Qt.callLater(svc._noteGone);
        }
    }

    // ---- a resume from suspend ----------------------------------------------------------------------------------------------
    Connections {
        target: Sleep.watcher
        ignoreUnknownSignals: true
        function onResumed() {
            svc.evaluate();
        }
    }

    function _hhmm(ms) {
        return Qt.formatDateTime(new Date(ms), "HH:mm");
    }
    function _dur(ms) {
        const m = Math.round(ms / 60000);
        return m >= 60 ? (Math.floor(m / 60) + " h" + (m % 60 ? " " + (m % 60) + " min" : "")) : m + " min";
    }

    Connections {
        target: svc.notifier
        ignoreUnknownSignals: true
        function onAction(key, id) {
            if (key === "countdown") {
                if (id === "again") svc.start();
                else svc.dismiss("countdown");
            } else if (key === "pomodoro") {
                if (id === "start") svc.pomoStart();
                else svc.dismiss("pomodoro");
            } else if (key === "alarm") {
                if (id === "snooze") svc.snooze();
                else svc.dismiss("alarm");
            }
        }
    }

    // =========================================================================
    //  Evaluation -- everything re-derived from the clock
    // =========================================================================
    function evaluate() {
        const now = svc.now();
        let dirty = false;

        const c = T.countdownAdvance(svc.countdown, now);
        if (c.ended) {
            svc.countdown = c.c;
            dirty = true;
            const late = now - c.ended.at > svc.lateToleranceMs;
            const info = { late: late, at: c.ended.at, totalMs: c.c.totalMs };
            svc._ring("countdown", info, {
                title: "Timer done",
                body: svc._dur(c.c.totalMs) + " timer" + (late ? " — ended at " + svc._hhmm(c.ended.at) : ""),
                urgency: "critical",
                actions: [{ id: "stop", label: "Stop" }, { id: "again", label: "Restart" }]
            }, true);
            svc.finished("countdown", info);
        }

        const p = T.pomoAdvance(svc.pomodoro, svc._cfg(), now);
        if (p.ended.length > 0) {
            svc.pomodoro = p.p;
            dirty = true;
            for (let i = 0; i < p.ended.length; i++) {
                const e = p.ended[i];
                svc.finished("pomodoro", { phase: e.phase, session: e.session, at: e.at,
                                           late: now - e.at > svc.lateToleranceMs, piece: e.session });
            }
            const e = p.ended[p.ended.length - 1];
            const late = now - e.at > svc.lateToleranceMs;
            svc._ring("pomodoro", { phase: e.phase, session: e.session, late: late },
                      svc._pomoNote(e, p.p, late), false);
        }

        for (let i = 0; i < alarmModel.count; i++) {
            const a = alarmModel.get(i);
            if (!a.enabled)
                continue;
            const due = a.snoozeUntil > 0 ? a.snoozeUntil : a.armedFor;
            if (due <= 0 || now < due)
                continue;
            dirty = true;
            const over = now - due;
            const oneShot = !a.days && a.snoozeUntil <= 0;
            alarmModel.setProperty(i, "snoozeUntil", 0);
            alarmModel.setProperty(i, "armedFor", T.nextOccurrence(a, now));
            if (oneShot)
                alarmModel.setProperty(i, "enabled", false);
            if (over > Math.max(svc.missedWindowMs, 60000))
                continue;
            const missed = over > 60000;
            const info = { id: a.aid, at: due, missed: missed };
            svc._ring("alarm", info, {
                title: a.label || "Alarm",
                body: missed ? "Missed at " + svc._hhmm(due) : svc._hhmm(due),
                urgency: "critical",
                actions: missed ? [{ id: "stop", label: "Dismiss" }]
                                : [{ id: "stop", label: "Stop" }, { id: "snooze", label: "Snooze " + Math.round(svc.snoozeMs / 60000) + " min" }]
            }, true);
            svc.finished("alarm", info);
        }
        if (dirty) {
            svc.alarmSerial += 1;
            svc._changed();
        } else {
            svc._arm();
        }
    }

    function _pomoNote(e, p, late) {
        const n = e.session + 1;
        const at = late ? " (" + svc._hhmm(e.at) + ")" : "";
        if (e.phase === "focus") {
            const nx = T.nextPhase(e.phase, e.session);
            const brk = nx.phase === "long" ? "long break" : "break";
            if (p.state === "waiting")
                return { title: "Focus " + n + " of 4 done" + at, body: "Time for a " + svc._dur(T.phaseLength(svc._cfg(), nx.phase)) + " " + brk,
                         actions: [{ id: "start", label: "Start " + brk }] };
            return { title: "Focus " + n + " of 4 done" + at, body: svc._dur(T.phaseLength(svc._cfg(), nx.phase)) + " " + brk + " started", actions: [] };
        }
        if (e.phase === "short") {
            if (p.state === "waiting")
                return { title: "Break over" + at, body: "Focus " + (n + 1) + " of 4 is next", actions: [{ id: "start", label: "Start focus" }] };
            return { title: "Break over" + at, body: "Focus " + (n + 1) + " of 4 started", actions: [] };
        }
        return { title: "Pomodoro complete" + at, body: "Four sessions done", actions: [] };
    }

    // One ticker: to the nearest deadline, at most 15 s ahead. A far
    // deadline repeats at 15 s rather than re-arming (a restarted Timer
    // presents a frame).
    readonly property int _maxTick: 15000
    Timer {
        id: ticker
        onTriggered: svc.evaluate()
    }
    function _nearestDeadline() {
        let best = -1;
        const take = t => {
            if (t > 0 && (best < 0 || t < best))
                best = t;
        };
        if (svc.countdown.state === "running")
            take(svc.countdown.endsAt);
        if (svc.pomodoro.state === "running")
            take(svc.pomodoro.endsAt);
        for (let i = 0; i < alarmModel.count; i++) {
            const a = alarmModel.get(i);
            if (a.enabled)
                take(a.snoozeUntil > 0 ? a.snoozeUntil : a.armedFor);
        }
        return best;
    }
    function _arm() {
        const d = svc._nearestDeadline();
        if (d < 0) {
            ticker.stop();
            return;
        }
        const wait = svc.clock ? svc.clock.realDelay(d - svc.now()) : d - svc.now();
        if (wait >= svc._maxTick) {
            if (!ticker.running || !ticker.repeat || ticker.interval !== svc._maxTick) {
                ticker.repeat = true;
                ticker.interval = svc._maxTick;
                ticker.restart();
            }
            return;
        }
        ticker.repeat = false;
        ticker.interval = Math.max(20, Math.ceil(wait));
        ticker.restart();
    }
    Connections {
        target: svc.clock
        ignoreUnknownSignals: true
        function onJumped() {
            svc.evaluate();
        }
        function onScaleChanged() {
            svc._arm();
        }
    }

    // Publish what the state implies, re-arm, persist.
    function _changed() {
        let best = null;
        for (let i = 0; i < alarmModel.count; i++) {
            const a = alarmModel.get(i);
            if (!a.enabled)
                continue;
            const at = a.snoozeUntil > 0 ? a.snoozeUntil : a.armedFor;
            if (at > 0 && (!best || at < best.at))
                best = { id: a.aid, at: at };
        }
        svc.nextAlarm = best;
        svc.barFills = T.barFills(svc.countdown, svc.pomodoro, svc.now());
        svc._arm();
        svc._save();
    }

    // =========================================================================
    //  Disk
    // =========================================================================
    // ---- the sounds' files ---------------------------------------------------------------------------------------------------------
    // kind -> what its ring plays: a file the check found, "none", or (missing) the default; until the first check answers, the defaults
    property var _soundPlays: ({})
    readonly property var _soundAsked: {
        const out = {};
        for (const k of Object.keys(svc.defaultSounds)) {
            const v = String(svc.sounds && svc.sounds[k] !== undefined ? svc.sounds[k] : svc.defaultSounds[k]);
            out[k] = v === "none" ? "none" : v.indexOf("~/") === 0 ? (Quickshell.env("HOME") || "") + v.slice(1) : v;
        }
        return out;
    }
    function _soundPath(v) {
        return v.indexOf("/") === 0 ? v : svc.sound.soundDir + v;
    }
    on_SoundAskedChanged: Qt.callLater(svc._checkSounds)
    onSoundChanged: Qt.callLater(svc._checkSounds)
    function _checkSounds() {
        if (!svc.sound)
            return;
        if (soundCheck.running) {
            soundCheck.again = true;
            return;
        }
        const asked = svc._soundAsked;
        const kinds = Object.keys(asked).filter(k => asked[k] !== "none");
        const plays = {};
        for (const k of Object.keys(asked))
            if (asked[k] === "none")
                plays[k] = "none";
        if (kinds.length === 0) {
            svc._soundPlays = plays;
            return;
        }
        soundCheck.asked = asked;
        soundCheck.kinds = kinds;
        soundCheck.plays = plays;
        soundCheck.command = ["sh", "-c", 'for f do if [ -f "$f" ] && [ -r "$f" ]; then echo 1; else echo 0; fi; done', "sh"]
            .concat(kinds.map(k => svc._soundPath(asked[k])));
        soundCheck.running = true;
    }
    Process {
        id: soundCheck
        property var asked: ({})
        property var kinds: []
        property var plays: ({})
        property bool again: false
        running: false
        stdout: StdioCollector {
            id: soundSeen
        }
    }
    Connections {
        target: soundCheck
        function onExited() {
            const seen = soundSeen.text.split("\n");
            const plays = Object.assign({}, soundCheck.plays);
            soundCheck.kinds.forEach((k, i) => {
                plays[k] = seen[i] === "1" ? soundCheck.asked[k] : svc.defaultSounds[k];
                if (seen[i] !== "1")
                    console.warn("TimerService: clock.jsonc timers.sounds." + k + " \"" + soundCheck.asked[k] + "\" is not there -- the default plays");
            });
            svc._soundPlays = plays;
            if (soundCheck.again) {
                soundCheck.again = false;
                svc._checkSounds();
            }
        }
    }

    property bool _loaded: false
    property bool _dirReady: false
    property string _selfWrite: ""
    readonly property string _path: svc.persist ? svc.stateDir + "/timers.json" : ""

    function _serialize() {
        const al = [];
        for (let i = 0; i < alarmModel.count; i++) {
            const a = alarmModel.get(i);
            al.push({ aid: a.aid, hour: a.hour, minute: a.minute, label: a.label, days: a.days,
                      enabled: a.enabled, armedFor: a.armedFor, snoozeUntil: a.snoozeUntil });
        }
        const lp = [];
        for (let i = 0; i < lapModel.count; i++) {
            const l = lapModel.get(i);
            lp.push({ n: l.n, lapMs: l.lapMs, totalMs: l.totalMs });
        }
        return JSON.stringify({
            version: 1,
            settings: { focusMs: svc.focusMs, shortMs: svc.shortMs, longMs: svc.longMs,
                        advanceMode: svc.advanceMode, presets: svc.presets },
            countdown: svc.countdown, pomodoro: svc.pomodoro, stopwatch: svc.stopwatch,
            alarms: al, laps: lp
        }, null, 1);
    }
    function _ingest(txt) {
        if (!txt || txt.length === 0 || txt === svc._selfWrite)
            return;
        let d;
        try {
            d = JSON.parse(txt);
        } catch (e) {
            return;
        }
        if (!d || d.version !== 1)
            return;
        const st = d.settings || {};
        svc._ingesting = true;
        if (st.focusMs > 0) svc.focusMs = st.focusMs;
        if (st.shortMs > 0) svc.shortMs = st.shortMs;
        if (st.longMs > 0) svc.longMs = st.longMs;
        if (st.advanceMode) svc.advanceMode = st.advanceMode;
        if (Array.isArray(st.presets)) svc.presets = st.presets.filter(x => x > 0).slice(0, svc.maxPresets);
        // THE SET TIME IS THE SESSION'S: it persists within one session only,
        // defaulting to 5 minutes in a new session. What the dial was left at is not read back; a countdown that is IN PROGRESS
        // (running, or paused with time left) is, with the time it was set to, because it is a timer that is running and not a setting.
        // A finished or idle one is dropped: the dial starts at its default again. (The presets and the pomodoro's lengths are the
        // user's own settings, kept.)
        if (d.countdown && (d.countdown.state === "running" || d.countdown.state === "paused")) svc.countdown = d.countdown;
        if (d.pomodoro) svc.pomodoro = d.pomodoro;
        if (d.stopwatch) svc.stopwatch = d.stopwatch;
        alarmModel.clear();
        for (const a of d.alarms || [])
            alarmModel.append(a);
        lapModel.clear();
        for (const l of d.laps || [])
            lapModel.append(l);
        svc._ingesting = false;
        svc.alarmSerial += 1;
        svc._changed();
        svc.evaluate();
    }
    property bool _ingesting: false

    function _save() {
        if (!svc.persist || svc._ingesting || !svc._loaded)
            return;
        writeTimer.restart();
    }
    function flush() {
        if (!svc.persist || !svc._loaded)
            return;
        if (!svc._dirReady) {
            writeTimer.restart();
            return;
        }
        writeTimer.stop();
        const txt = svc._serialize();
        if (txt === svc._selfWrite)
            return;
        svc._selfWrite = txt;
        file.setText(txt);
    }
    Timer {
        id: writeTimer
        interval: 300
        onTriggered: svc.flush()
    }
    FileView {
        id: file
        path: svc._path
        // blockLoading makes text() a synchronous read (Theme.qml relies on
        // the same): the saved state is read in onCompleted, before the first
        // evaluation. onLoaded is not waited for -- it may fire before any
        // handler is connected, or not at all for a first run.
        blockLoading: true
        atomicWrites: true
        printErrors: false
        watchChanges: false
    }
    Process {
        id: mkdir
        command: ["mkdir", "-p", svc.stateDir]
        running: false
    }
    Connections {
        target: mkdir
        function onExited() {
            svc._dirReady = true;
        }
    }

    Component.onCompleted: {
        Qt.callLater(svc._checkSounds);
        if (svc.persist)
            svc._ingest(file.text());
        // From here on, changes are saved.
        svc._loaded = true;
        if (svc.persist)
            mkdir.running = true;
        else
            svc._dirReady = true;
        svc._changed();
    }
    Component.onDestruction: {
        if (writeTimer.running)
            svc.flush();
    }
}
