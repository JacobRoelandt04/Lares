pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// AuraEvents.qml -- WHICH EVENTS LIGHT THE AURA.
//
// The aura (GooeyEngine.playAura, ShellServices.playAura) is rare on purpose: it means "something finished or changed that you
// did not just do yourself". Exactly these events play it, and nothing else:
//
//   a  an LLM answer that took a minute or more     island  siri    LlmService.turnStarted -> answerCompleted, wall time >= llmMinMs
//                                                                   (a stopped turn and an errored one are not an arrival)
//   b  a system update that ends with its popup     all     ok      SystemUpdateService.running falls, the parser has an exit;
//      NOT open (the popup already says it)                 error   `ok` as the UpdateNotifier reads it (exit 0, COMPLETE, no errors)
//   c  a timer or an alarm fires                    island  accent  TimerService.finished("countdown" | "alarm"); a pomodoro
//                                                                   phase is not (it comes every few minutes)
//   d  the screen starts / stops being shared       all     cool    NotificationHolds.screencast: a portal session or a recorder's
//      or recorded                                                  process, so only what the user started (THE SCREEN SHARE there: a grab
//                                                                   of the shell's own or a screenshot is neither); never warn -- the
//                                                                   user starts a recording on purpose and would not be shouted at
//
// There is no battery event here.
// DND SUPPRESSES EVERY ONE (the effect asks to be acknowledged, which DND forbids), and nothing plays unless
// shell.jsonc's shadow block says `"aura": true` (`armed`, the host binds ShellConfig.auraEnabled).
//
// The host injects the sources (null = that event is off, as for every shell-hosted piece) and `play(palette, group)`, the
// hook (ShellServices.playAura). Every ASK is logged in `plays` (event, palette, group, the hook's answer), oldest first, so a probe
// reads what was asked without an engine: a window-less mock shell has none to draw it.
// =============================================================================
Item {
    id: root
    visible: false

    property bool armed: false
    // function (palette, group) -> the hook's answer (a string); null: nothing to call
    property var play: null

    // The sources (each may be null).
    property var llm: null              // LlmService: turnStarted, answerCompleted, lastStats, lastError
    property var updates: null          // SystemUpdateService: running, popupOpen, parser
    property var timers: null           // TimerService: finished(kind, info)
    property var notifications: null    // NotificationService: dnd, holds.screencast

    // Which events there are (shell.jsonc shadow.auraEvents): `llm` is the least seconds of an answer, false is never.
    property var events: ({ llm: 60, update: true, timer: true, screencast: true })
    // An answer that took this long (wall time from the ask to the answer) earns the aura.
    property int llmMinMs: typeof root.events.llm === "number" ? Math.round(root.events.llm * 1000) : 60000

    readonly property var plays: root._plays
    property var _plays: []
    readonly property bool _dnd: !!root.notifications && root.notifications.dnd === true

    function _ask(event, palette, group) {
        if (!root.armed || root._dnd || typeof root.play !== "function" || root.events[event] === false)
            return;
        const answer = root.play(palette, group);
        // the log is kept to what a probe reads; a new array so a binding on `plays` hears it
        root._plays = root._plays.concat([{ event: event, palette: palette, group: group, answer: String(answer) }]).slice(-40);
    }

    // ---- a: the LLM ------------------------------------------------------------------------------------------------
    property double _turnAt: 0
    Connections {
        target: root.llm
        ignoreUnknownSignals: true
        function onTurnStarted(convId) {
            root._turnAt = Date.now();
        }
        function onAnswerCompleted(convId, title, preview) {
            const at = root._turnAt;
            root._turnAt = 0;
            const l = root.llm;
            if (at <= 0 || Date.now() - at < root.llmMinMs)
                return;
            if ((l.lastStats && l.lastStats.doneReason === "cancelled") || String(l.lastError || "") !== "" || String(preview) === "")
                return;
            root._ask("llm", "siri", "island");
        }
    }

    // ---- b: the system update ------------------------------------------------------------------------------------------
    property bool _wasRunning: false
    Connections {
        target: root.updates
        ignoreUnknownSignals: true
        function onRunningChanged() {
            const now = root.updates.running === true;
            if (now === root._wasRunning)
                return;
            root._wasRunning = now;
            // The parser reads the exit on the same signal: what it holds is the run's own a turn later (the UpdateNotifier's rule).
            if (!now)
                endTimer.restart();
        }
    }
    Timer {
        id: endTimer
        interval: 0
        onTriggered: {
            const u = root.updates;
            const p = u ? u.parser : null;
            // (an undo of the snapshots page is no update: the aura marks updates)
            if (!p || p.exitCode < 0 || u.popupOpen === true || u.runKind === "undo")
                return;
            const ok = p.exitCode === 0 && p.phase === "COMPLETE" && p.errorCount === 0;
            root._ask("update", ok ? "ok" : "error", "all");
        }
    }

    // ---- c: a timer or an alarm ---------------------------------------------------------------------------------------
    Connections {
        target: root.timers
        ignoreUnknownSignals: true
        function onFinished(kind, info) {
            if (kind === "countdown" || kind === "alarm")
                root._ask("timer", "accent", "island");
        }
    }

    // ---- d: the screen is shared / recorded ---------------------------------------------------------------------------
    Connections {
        target: root.notifications ? root.notifications.holds : null
        ignoreUnknownSignals: true
        function onScreencastChanged() {
            // (a share that stood when the shell came up was not started now)
            if (!root.notifications.holds.castsPending)
                root._ask("screencast", "cool", "all");
        }
    }
}
