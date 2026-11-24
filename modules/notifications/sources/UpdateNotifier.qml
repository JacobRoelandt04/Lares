pragma ComponentBehavior: Bound

import QtQuick

import "SourceGlyphs.js" as G
import "SourceFormat.js" as F
import "UpdateNudge.js" as Nudge
import "UpdatePrompt.js" as Prompt

// =============================================================================
// UpdateNotifier.qml -- the system update tells you what it needs (source "update"; SOURCES.md).
//
// It listens to the SystemUpdateService (`updates`) and says, through one SourcePoster:
//
//   nudge   about 15 minutes after the BOOT, plus a random few, after a fresh look at what is waiting:
//           when the updates number at least N and / or the last update is at least D days old (the
//           combination is a setting), a card with the facts -- "42 updates are waiting", "312 MiB . last
//           update 9 days ago", the count per category in yay's colours, the packages the user has
//           FAVOURITED as the highlights -- and two buttons. Update now opens the update popup and starts the
//           run (no second confirmation: the click is the confirmation); Later takes the card away. At
//           most one a day across reboots, and one look per boot: sources.json remembers.
//   run     "Update started" when a run begins with the popup shut; replaced, when it ends, by "Update
//           complete" (how many packages, and "Reboot recommended: kernel, mesa changed" when the kernel,
//           systemd or mesa did) or "Update failed" (the first error), which stays until it is seen.
//   ask     the run waits for an ANSWER: a critical card with the prompt's own words. A plain yes / no
//           (pacman's "Proceed with installation?", yay's "skip the above package?") has Yes and No on the
//           card, the tool's default accented, and the click writes the answer into the run; anything more
//           (a list of packages, a diff, an editor) opens the popup at the prompt. It goes when the prompt
//           does.
//
// ONLY WHILE THE POPUP IS SHUT. The popup shows all of it; a card would say it twice. Posts are held back while
// any screen's update popup is open (`updates.popupOpen`), and opening the popup takes the nudge and the
// question's card away -- the question closed behind the popup is asked again by the card when the popup
// closes. `updates` is injected; this source builds no service and writes no property of it.
//
// Settings (sources.update; SourceSettings): enabled; nudge { enabled, afterBootMin, jitterMin, minCount,
// minDays, rule, highlights, timeoutMs }; started, asks, finished (each can be switched off);
// rebootPackages.
// =============================================================================
SourceBase {
    id: src

    sourceId: "update"
    appName: "System update"
    glyph: G.update
    keys: ["nudge", "run", "ask"]

    // The SystemUpdateService (null: this source is off).
    property var updates: null
    ready: !!src.updates
    attended: !!src.updates && src.updates.popupOpen === true

    // ---- the probes' seams (the shell sets none of them) -----------------------------------------------
    // The least wait after the shell's start before the first look; how long a refresh may take before the
    // nudge gives up; how long a question must stand before its card appears; a run that begins this soon after
    // the shell did is a run it re-attached to, not one just begun.
    property int nudgeLeadMs: Nudge.LEAD_MS
    property int refreshWaitMs: 90000
    property int askDebounceMs: 300
    property int startGraceMs: 8000
    // The repository download size of what is waiting, in bytes, on one line: pacman's own print of the
    // temporary database `checkupdates` keeps (read-only; AUR and Flatpak sizes are not known before the run).
    property var sizeCommand: ["bash", "-c",
        "pacman -Sup --dbpath \"${CHECKUPDATES_DB:-${TMPDIR:-/tmp}/checkup-db-${UID}}\" --print-format '%s' 2>/dev/null | awk '{ s += $1 } END { print s + 0 }'"]

    // ====================================================================================================
    //  the nudge
    // ====================================================================================================
    property double _startedMs: 0
    property double _dueMs: 0
    property bool _nudgeRan: false
    property var _afterRefresh: null

    function _armNudge() {
        if (!src.active || src._nudgeRan || !src.settings.nudge.enabled)
            return;
        if (src._dueMs <= 0)
            src._dueMs = Nudge.dueAtMs(Date.now(), src.host.uptimeMs(), src._startedMs, src.settings.nudge, Math.random(), src.nudgeLeadMs);
        src.host.clock.request(src._dueMs);
    }
    function _nudgeTick() {
        if (!src.active || src._nudgeRan || src._dueMs <= 0)
            return;
        if (Date.now() >= src._dueMs)
            src._nudge();
        else
            src._armNudge();
    }
    Connections {
        target: src.host ? src.host.clock : null
        function onNowChanged() {
            src._nudgeTick();
        }
    }

    // The look: today's nudge not shown yet, this boot not looked at yet, nothing running and no popup open.
    function _nudge() {
        src._nudgeRan = true;
        const day = F.dayKey(Date.now());
        const st = src.host.state.get("update");
        if (!Nudge.mayCheck(st, src.host.bootId, day).check)
            return;
        if (src.updates.popupOpen === true || src.updates.runActive === true)
            return;
        src._refreshThen(() => src._decide(day));
    }

    // A FRESH look first: refresh() (a refresh already out is waited for), then `fn` once it has landed -- or,
    // when it never does, nothing: a count read from the cache is not a fact to nudge by.
    function _refreshThen(fn) {
        src._afterRefresh = fn;
        waitTimer.restart();
        if (!src.updates.avail.refreshing)
            src.updates.avail.refresh();
    }
    Connections {
        target: src.updates ? src.updates.avail : null
        ignoreUnknownSignals: true
        function onRefreshFinished(count) {
            const fn = src._afterRefresh;
            if (!fn)
                return;
            src._afterRefresh = null;
            waitTimer.stop();
            if (src.updates.avail.lastError === "")
                fn();
        }
    }
    Timer {
        id: waitTimer
        interval: src.refreshWaitMs
        onTriggered: src._afterRefresh = null
    }

    function _decide(day) {
        const avail = src.updates.avail;
        const days = src.updates.staleDays;
        const verdict = Nudge.rule(avail.totalCount, days, src.settings.nudge);
        const st = src.host.state.get("update");
        if (!verdict.due) {
            src.host.state.put("update", Nudge.afterCheck(st, src.host.bootId, day, false));
            return;
        }
        src.host.exec.run(src.sizeCommand, (code, out) => {
            const bytes = code === 0 ? parseFloat(String(out).trim()) : NaN;
            src._postNudge(day, isFinite(bytes) ? bytes : 0);
        }, 20000);
    }

    function _postNudge(day, sizeBytes) {
        // The world may have moved while the size was read.
        if (!src.active || src.updates.popupOpen === true || src.updates.runActive === true)
            return;
        const avail = src.updates.avail;
        const rows = [];
        const model = avail.updates;
        for (let i = 0; i < model.count && rows.length < 400; i++) {
            const r = model.get(i);
            if (r.isFavorite === true)
                rows.push({ name: r.name, oldVer: r.oldVer, newVer: r.newVer, category: r.category, isFavorite: true });
        }
        const n = avail.totalCount;
        const hl = Nudge.highlights(rows, src.settings.nudge.highlights);
        src.post("nudge", {
            title: Nudge.title(n),
            body: Nudge.body(sizeBytes, src.updates.staleDays),
            urgency: "normal",
            timeoutMs: src.settings.nudge.timeoutMs,
            bodyComponent: nudgeBody,
            bodyProps: { chips: Nudge.chips(avail.categories), highlights: hl },
            actions: [
                { id: "now", label: "Update now", run: () => src.updateNow() },
                { id: "later", label: "Later", run: () => {} }
            ],
            onDefault: () => src.host.open("update")
        });
        src.host.state.put("update", Nudge.afterCheck(src.host.state.get("update"), src.host.bootId, day, true));
    }
    Component {
        id: nudgeBody
        UpdateNudgeBody {}
    }

    // "Update now": the popup on the focused screen AND the run, with no second confirmation.
    function updateNow() {
        src.host.open("update");
        src.updates.startUpdate();
    }

    // ====================================================================================================
    //  the run: started, finished
    // ====================================================================================================
    property bool _wasRunning: false

    Connections {
        target: src.updates
        ignoreUnknownSignals: true
        function onRunningChanged() {
            src._runChanged();
        }
        function onPopupOpenChanged() {
            src._popupChanged();
        }
    }
    function _runChanged() {
        if (!src.active)
            return;
        const now = src.updates.running === true;
        if (now === src._wasRunning)
            return;
        src._wasRunning = now;
        if (now) {
            src._runStarted();
        } else {
            // The parser reads the exit on the same signal: what it holds is the run's own a turn later.
            endTimer.restart();
        }
    }
    // An undo (pacman -U from the snapshots page) is the user's own act in front of the popup: it has no
    // "started" and no "complete" card of the update's (`runKind` on the service: the run in force).
    readonly property bool _isUpdate: src.updates && src.updates.runKind !== "undo"
    function _runStarted() {
        src.withdraw("run");
        if (!src._isUpdate)
            return;
        if (!src.settings.started || src.updates.popupOpen === true || Date.now() - src._startedMs < src.startGraceMs)
            return;
        const n = src.updates.avail.totalCount;
        src.post("run", {
            title: "Update started",
            body: n > 0 ? F.plural(n, "package") : "",
            urgency: "low",
            actions: [{ id: "open", label: "Open", run: () => src.host.open("update") }],
            onDefault: () => src.host.open("update")
        });
    }
    Timer {
        id: endTimer
        interval: 0
        onTriggered: src._runEnded()
    }
    function _runEnded() {
        src.withdraw("ask");
        const p = src.updates.parser;
        if (p.exitCode < 0)
            return;
        if (!src._isUpdate) {
            src.withdraw("run");
            return;
        }
        if (!src.settings.finished || src.updates.popupOpen === true) {
            src.withdraw("run");
            return;
        }
        const ok = p.exitCode === 0 && p.phase === "COMPLETE" && p.errorCount === 0;
        if (ok) {
            const names = [];
            for (let i = 0; i < p.packages.count && i < 2000; i++)
                names.push(p.packages.get(i).name);
            const line = Nudge.rebootLine(Nudge.rebootReasons(names, src.settings.rebootPackages));
            const total = Math.max(p.totalPackages, p.packages.count);
            src.post("run", {
                title: "Update complete",
                body: [total > 0 ? F.plural(total, "package") + " updated" : "", line].filter(s => s !== "").join("\n"),
                urgency: "normal",
                timeoutMs: line !== "" ? 20000 : undefined
            });
        } else {
            let why = "exit status " + p.exitCode;
            if (p.errors.count > 0) {
                const e = p.errors.get(0);
                why = String(e.reason || why);
                if (why.length > 140)
                    why = why.substring(0, 139) + "…";
            }
            src.post("run", {
                title: "Update failed",
                body: why,
                urgency: "normal",
                timeoutMs: -1,
                actions: [{ id: "open", label: "Open", run: () => src.host.open("update") }],
                onDefault: () => src.host.open("update")
            });
        }
    }

    // ====================================================================================================
    //  the ask: the run waits for an answer
    // ====================================================================================================
    property string _askKey: ""            // the question on the card now (kind + words), "" none
    property string _answeredKey: ""       // the question answered from the card, until it has closed
    property string _answeredPhase: ""

    function _popupChanged() {
        if (!src.active)
            return;
        if (src.updates.popupOpen === true) {
            // The popup shows the question, the run, and what is waiting: no card says it again.
            src.withdraw("nudge");
            src.withdraw("ask");
            src.withdraw("run");
            src._askKey = "";
        }
        src._askSoon();
    }
    function _askSoon() {
        if (src.active)
            askTimer.restart();
    }
    Timer {
        id: askTimer
        interval: src.askDebounceMs
        onTriggered: src._askSync()
    }
    Connections {
        target: src.updates ? src.updates.parser : null
        ignoreUnknownSignals: true
        function onAwaitingUserInputChanged() { src._askSoon(); }
        function onCurrentPromptKindChanged() { src._askSoon(); }
        function onPhaseChanged() { src._askSoon(); }
    }
    Connections {
        target: src.updates ? src.updates.backend : null
        ignoreUnknownSignals: true
        function onAwaitingInputChanged() { src._askSoon(); }
        function onLastPromptChanged() { src._askSoon(); }
        function onPasswordPromptChanged() { src._askSoon(); }
        function onRunningChanged() { src._askSoon(); }
    }

    // The question as the run holds it now, or null.
    function _question() {
        const p = src.updates.parser;
        const b = src.updates.backend;
        return Prompt.classify({
            parserKind: p.currentPromptKind, parserText: p.currentPromptText, parserDefault: p.currentPromptDefault,
            phase: p.phase, answeredPhase: src._answeredPhase, running: b.running === true,
            backendAwaiting: b.awaitingInput === true, backendPassword: b.passwordPrompt === true, backendLastPrompt: b.lastPrompt
        });
    }
    function _askSync() {
        const q = src.updates.backend.running === true ? src._question() : null;
        const key = q ? q.kind + "|" + q.title : "";
        if (key === "") {
            src._answeredKey = "";
            if (src._askKey !== "") {
                src._askKey = "";
                src.withdraw("ask");
            }
            return;
        }
        if (!src.settings.asks || src.updates.popupOpen === true || key === src._askKey || key === src._answeredKey)
            return;
        src._askKey = key;
        src._postAsk(q);
    }
    function _postAsk(q) {
        const p = src.updates.parser;
        let body = "";
        if (q.kind === "pacman_proceed") {
            const parts = [];
            if (p.totalPackages > 0)
                parts.push(F.plural(p.totalPackages, "package"));
            if (p.totalDownloadBytes > 0)
                parts.push(F.bytes(p.totalDownloadBytes) + " to download");
            body = parts.join(" · ");
        } else if (q.yesno && p.currentPromptContext && p.currentPromptContext.length > 0) {
            body = String(p.currentPromptContext[p.currentPromptContext.length - 1]);
        } else if (!q.yesno) {
            body = "yay is waiting for your answer";
        }
        const spec = {
            title: q.title, body: body, urgency: "critical", timeoutMs: -1,
            onDefault: () => src.host.open("update")
        };
        if (q.yesno) {
            spec.bodyComponent = askBody;
            spec.bodyProps = { def: q.def, answer: yes => src._answer(q, yes) };
        } else {
            spec.actions = [{ id: "open", label: "Open update", run: () => src.host.open("update") }];
        }
        src.post("ask", spec);
    }
    Component {
        id: askBody
        UpdateAskBody {}
    }

    // Yes or No from the card: written into the run as the popup's own buttons write it.
    function _answer(q, yes) {
        const p = src.updates.parser;
        const b = src.updates.backend;
        src._answeredKey = q.kind + "|" + q.title;
        src._answeredPhase = p.phase;
        if (q.kind === "pacman_proceed" && yes && p.phase === "AUR_INSTALL" && p.resetAurForInstall)
            p.resetAurForInstall();
        if (q.kind === "yay_skip_dep" && yes && p.skipContextPackages)
            p.skipContextPackages();
        b.submit(Prompt.answer(q.kind, yes));
        // The card goes a turn later: it is the card's own click that is being handled.
        Qt.callLater(() => {
            src._askKey = "";
            src.withdraw("ask");
        });
    }

    // ====================================================================================================
    onActivated: {
        src._startedMs = Date.now();
        src._dueMs = 0;
        src._nudgeRan = false;
        src._wasRunning = src.updates.running === true;
        src._armNudge();
        src._askSoon();
    }
    onDeactivated: {
        waitTimer.stop();
        endTimer.stop();
        askTimer.stop();
        src._afterRefresh = null;
        src._askKey = "";
    }
    // A switch in notifications.jsonc (the nudge turned on, its numbers changed) is read on the next boundary.
    onSettingsChanged: {
        if (src.active)
            src._armNudge();
    }
}
