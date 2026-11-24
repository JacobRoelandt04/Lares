pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../common/components"
import "../common/components/JsonComments.js" as JsonComments
import "../common/system"

// =============================================================================
// SessionService.qml -- session restore, the shell's part (docs/session.md, docs/contracts/session.md). ONE per shell.
//
// Everything that knows a window or a process is the tool's (tools/session/lares-session: the snapshot, the policy, the
// restore); this service only says WHEN, and talks to the user:
//
//   at its start        `lares-session begin`, once: the tool decides from its own record of the previous session
//                         none          nothing (also: a shell restart inside a running session, Hyprland's safe mode)
//                         auto          `lares-session restore` at once -- under the boot lock too: the windows stand ready at
//                                       the unlock (only when the config asks for it)
//                         ask           a toast, Restore / Discard, of normal urgency, that stays until answered (after a
//                                       log-out, a reboot, a power-off)
//                         ask-critical  the same toast, critical: the last session did not end cleanly, and whatever ran
//                                       in it may be why (a restore then runs no command by itself: the tool's `clean`)
//                       An ask waits for the session unlocked and the focused screen's frame on the glass (the gate of
//                       SiliconMuxWatcher): nobody reads a toast under the lock.
//   while it runs       `lares-session watch`, one long-lived child: it keeps the rolling picture current, which is what
//                       an ask after a crash offers. It starts AFTER `begin` has answered: begin freezes the previous
//                       session's rolling picture, and a watcher started first would have written over it.
//   at the end          the power reel runs `lares-session end <reason>` before logout / reboot / poweroff
//                       (ReelActions reads `endTool`; empty while the feature is off).
//   while it restores   ONE changing toast ("5 of 13 windows are ready / Waiting for Zen Browser"): the tool prepares the
//                       windows out of sight and shows them at once, so the toast is the only sign until then
//   at the unlock       `lares-session refocus`, once, when a restore made under the lock said the focus is owed
//   after a restore     ONE low toast, always, the status toast's closing: what needs the user (commands typed and waiting for
//                       Enter, an app that did not come back, a hook that claimed nothing), else "10 windows are back" (quieter:
//                       it stays 6 s, not 12). A restore that ends with no word is a status toast that just vanishes: the user
//                       (2026-11-15) read the missing closing toast as a fault.
//
// The switch is config/session.jsonc `"enabled"` (off as shipped); it is read hot, but a session that started with it
// off decides nothing when it is turned on (the next session does): `begin` belongs to a session's start.
//
// A mock (`live: false`) starts nothing: every call the live service would make is recorded in `calls`, and a probe
// hands the answers in (`decided`, `restored`).
// =============================================================================
Item {
    id: root

    property bool live: false
    property string configPath: ""
    // The gate of an ask: not under the lock, not before the focused screen is on the glass.
    property bool locked: false
    property bool shown: true
    property var notifier: null

    property string tool: RepoRoot.dir + "/tools/session/lares-session"
    property string python: "python3"
    property var launcher: ["setpriv", "--pdeathsig", "TERM", "--"]

    // ---- the config (read hot) ----------------------------------------------------------------------------
    readonly property bool enabled: root._cfg.enabled === true
    // A preset load that closes other windows asks first (the presets' card).
    readonly property bool confirmReplace: !root._cfg.presets || root._cfg.presets.confirmReplace !== false
    // The toast that closes a restore: "always" | "needs" (what needs the user alone) | "off".
    readonly property string resultToast: ["needs", "off"].indexOf(root._cfg.resultToast) >= 0 ? root._cfg.resultToast : "always"
    property var _cfg: ({})
    function _apply(text: string): void {
        let o = {};
        if (text.length > 0) {
            try {
                o = JSON.parse(JsonComments.strip(text));
            } catch (e) {
                console.warn("SessionService: session.jsonc does not parse: " + e);
                o = {};
            }
        }
        root._cfg = (o && typeof o === "object") ? o : {};
    }
    ConfigFile {
        id: cfgFile
        path: root.configPath
        watchChanges: root.live
        onLoaded: root._apply(cfgFile.text())
        onLoadFailed: root._apply("")
    }

    // ---- what the reel reads ------------------------------------------------------------------------------
    // The tool the power reel runs before the session ends ("" = no save step).
    readonly property string endTool: root.enabled ? root.tool : ""
    readonly property string endPython: root.python

    // ---- state, for the probes and the IPC ------------------------------------------------------------------
    // "off" | "starting" | "idle" | "asking" | "restoring"
    readonly property string phase: root._phase
    property string _phase: "off"
    readonly property var decision: root._decision
    property var _decision: null
    readonly property var lastResult: root._result
    property var _result: null
    property var calls: []
    function _record(what: string): void {
        const c = root.calls.slice();
        c.push(what);
        root.calls = c;
    }
    function status(): string {
        return JSON.stringify({ enabled: root.enabled, live: root.live, phase: root._phase, decision: root._decision,
            result: root._result, watching: watcher.running, calls: root.calls });
    }

    // ---- the start ------------------------------------------------------------------------------------------
    property bool _begun: false
    function _maybeBegin(): void {
        if (root._begun || !root.enabled)
            return;
        root._begun = true;
        root._phase = "starting";
        root._record("begin");
        if (root.live)
            beginProc.running = true;
    }
    onEnabledChanged: {
        // Turned on in a session that started with it off: no decision (that was the start's), the watcher and the end step only.
        if (root.enabled && root._started && !root._begun) {
            root._begun = true;
            root._record("late");
            root._decision = { decision: "none", cause: "turned on in a running session" };
            root._phase = "idle";
        } else if (!root.enabled && root._begun) {
            root._phase = "off";
        } else if (root.enabled && root._begun && root._phase === "off") {
            root._phase = "idle";
        }
    }
    // The first look is one turn after the build: the config has been read, the notifier's slots exist.
    property bool _started: false
    Timer {
        id: startLook
        interval: 0
        running: true
        onTriggered: {
            root._apply(cfgFile.text());
            root._maybeBegin();
            root._started = true;
        }
    }

    Process {
        id: beginProc
        command: [root.python, root.tool, "begin"]
        stdout: StdioCollector {
            id: beginOut
        }
        onExited: code => {
            let d = null;
            const lines = beginOut.text.trim().split("\n");
            try {
                d = JSON.parse(lines[lines.length - 1]);
            } catch (e) {
                d = null;
            }
            if (!d || typeof d !== "object") {
                console.warn("SessionService: `lares-session begin` gave no answer (exit " + code + ")");
                d = { decision: "none", cause: "the tool gave no answer" };
            }
            root.decided(d);
        }
    }

    // `begin`'s answer (a probe calls this in a mock).
    function decided(d: var): void {
        root._decision = d;
        const what = String(d.decision || "none");
        if (what === "auto") {
            root.restore();
        } else if (what === "ask" || what === "ask-critical") {
            root._phase = "asking";
            root._askDue = true;
            askLook.restart();
        } else {
            root._phase = root.enabled ? "idle" : "off";
        }
    }

    // ---- the ask --------------------------------------------------------------------------------------------
    readonly property bool _ready: !root.locked && root.shown
    property bool _askDue: false
    on_ReadyChanged: askLook.restart()
    Timer {
        id: askLook
        interval: 0
        onTriggered: root._postAsk()
    }
    function _postAsk(): void {
        if (!root._askDue || !root._ready || !root.notifier || !root._decision)
            return;
        root._askDue = false;
        const d = root._decision;
        const critical = d.decision === "ask-critical";
        // (critical is the toast's urgency; whether commands may run is the tool's `clean`: only an unclean end forbids it)
        const body = String(d.cause || "") + (d.summary ? "\n" + d.summary : "")
            + (d.clean === false ? "\nNothing is run by itself: commands are typed and wait for Enter." : "");
        root._record("ask " + d.decision);
        root.notifier.notify("restore", {
            title: "Restore the last session?",
            body: body,
            urgency: critical ? "critical" : "normal",
            actions: [{ id: "restore", label: "Restore" }, { id: "discard", label: "Discard" }],
            timeoutMs: 0
        });
    }
    Connections {
        target: root.notifier
        function onAction(key, id) {
            if (key !== "restore" || root._phase !== "asking")
                return;
            root.notifier.withdraw("restore");
            if (id === "restore") {
                root.restore();
                // The click is answered in the same turn its ask goes: the toast stack hands the ask's room straight to
                // this one (NotificationToast, THE HAND-OVER) instead of closing the lane and opening it again when the
                // tool's first step comes (a Python start later).
                if (!root._progress)
                    root._progress = { done: 0, total: 0, waiting: [], reveal: false, preparing: true };
                root._postProgress();
            } else if (id === "discard") {
                root._record("answer discard");
                root._phase = "idle";
                if (root.live)
                    answerProc.running = true;
            }
        }
    }
    Process {
        id: answerProc
        command: [root.python, root.tool, "answer", "discard"]
    }

    // ---- the restore ----------------------------------------------------------------------------------------
    function restore(): bool {
        if (root._phase === "restoring")
            return false;
        root._presetName = "";
        root._phaseAfter = "";
        root._restoreArgs = ["restore", "--json", "--progress"];
        root._phase = "restoring";
        root._record("restore");
        if (root.live)
            restoreProc.running = true;
        return true;
    }

    // ---- a preset's load (modules/presets): the same engine, toasts and result, on `lares-session preset load` ----------------
    //   mode "replace": what is open and not in the preset closes (the popup asked first); "add": nothing closes.
    // A preset is manual: it runs whether the feature is on or not, and it leaves a login's pending ask where it was (the ask
    // stays answerable after the load: the phase goes back to "asking").
    property string _presetName: ""
    property string _phaseAfter: ""
    property var _restoreArgs: ["restore", "--json", "--progress"]
    function loadPreset(name: string, mode: string): bool {
        if (root._phase === "restoring" || root._phase === "starting" || (mode !== "replace" && mode !== "add") || String(name) === "")
            return false;
        root._phaseAfter = root._phase === "asking" ? "asking" : "";
        root._presetName = String(name);
        root._restoreArgs = ["preset", "load", String(name), "--" + mode, "--json", "--progress"];
        root._phase = "restoring";
        root._record("preset load " + name + " " + mode);
        // the click's own answer, at once: the tool's first count comes a Python start later
        root._progress = { done: 0, total: 0, waiting: [], reveal: false, preparing: true };
        root._postProgress();
        if (root.live)
            restoreProc.running = true;
        return true;
    }
    Process {
        id: restoreProc
        // No pdeathsig: a restore outlives a shell that restarts under it (the tool records its own end).
        command: [root.python, root.tool].concat(root._restoreArgs)
        // One JSON line per step, the result's last (a slice of the parser is not always one line: cut it again).
        stdout: SplitParser {
            onRead: slice => {
                const lines = String(slice).split("\n");
                for (let i = 0; i < lines.length; i++) {
                    if (lines[i].trim() === "")
                        continue;
                    let d = null;
                    try {
                        d = JSON.parse(lines[i]);
                    } catch (e) {
                        d = null;
                    }
                    if (!d || typeof d !== "object")
                        continue;
                    if (d.event === "result") {
                        root._gotResult = true;
                        root.restored(d);
                    } else {
                        root.progressed(d);
                    }
                }
            }
        }
        onExited: code => {
            if (!root._gotResult)
                root.restored({ restored: 0, planned: 0, failed: [{ name: "restore", why: "the restore tool stopped without an answer (exit " + code + ")" }],
                    typed: 0, ran: 0, unclaimed: 0, skipped: [], later: [] });
            root._gotResult = false;
        }
    }
    property bool _gotResult: false

    // ---- while it restores: one changing toast ------------------------------------------------------------------
    // The windows are prepared OUT OF SIGHT (the tool's staging workspaces) and shown at once, so for a few seconds
    // nothing moves on the screen: this toast is the only sign. `live`: one record, updated in place, the user may hide it.
    // Not under the lock (nobody reads it there); posted when the lock goes while a restore still runs.
    property var _progress: null
    function progressed(d: var): void {
        if (root._phase !== "restoring")
            return;
        if (d.event === "start")
            root._progress = { done: 0, total: Number(d.total || 0), waiting: [], reveal: false };
        else if (d.event === "progress")
            root._progress = { done: Number(d.done || 0), total: Number(d.total || 0), waiting: d.waiting || [], reveal: false };
        else if (d.event === "reveal" && root._progress)
            root._progress = { done: root._progress.done, total: root._progress.total, waiting: [], reveal: true };
        progressLook.restart();
    }
    function progressWords(p: var): string {
        if (!p)
            return "";
        if (p.total <= 0)
            return "Preparing the windows";
        let s = p.done + " of " + p.total + (p.total === 1 ? " window is ready" : " windows are ready");
        const w = [];
        for (let i = 0; i < p.waiting.length && i < 3; i++)
            w.push(String(p.waiting[i]));
        if (w.length > 0)
            s += "\nWaiting for " + w.join(", ") + (p.waiting.length > 3 ? " and " + (p.waiting.length - 3) + " more" : "");
        return s;
    }
    Timer {
        id: progressLook
        interval: 0
        onTriggered: root._postProgress()
    }
    // Posted (or updated in place) when it can be read. With no count yet only as the click's own answer (`preparing`): an
    // `auto` restore's toast waits for the tool's first count, and a count of nothing changes nothing.
    function _postProgress(): void {
        if (!root._progress || root._phase !== "restoring" || !root._ready || !root.notifier)
            return;
        if (root._progress.total <= 0 && root._progress.preparing !== true)
            return;
        if (!root._progressUp)
            root._record("progress");
        root._progressUp = true;
        root.notifier.notify("progress", { live: true, title: root._presetName !== "" ? "Loading " + root._presetName : "Restoring the session",
            body: root.progressWords(root._progress),
            urgency: "low", timeoutMs: 0 });
    }
    property bool _progressUp: false

    // What needs the user after a restore, in one line each; "" when nothing does.
    function resultWords(r: var): string {
        const parts = [];
        const typed = Number(r.typed || 0), lost = Number(r.unclaimed || 0);
        if (typed - lost > 0)
            parts.push((typed - lost) === 1 ? "1 command is typed and waits for Enter" : (typed - lost) + " commands are typed and wait for Enter");
        const failed = r.failed || [];
        for (let i = 0; i < failed.length && i < 3; i++)
            parts.push(String(failed[i].name) + ": " + String(failed[i].why));
        if (failed.length > 3)
            parts.push((failed.length - 3) + " more did not come back");
        const later = r.later || [];
        for (let i = 0; i < later.length && i < 3; i++)
            parts.push(String(later[i].name) + " is still starting: its window opens on workspace " + String(later[i].workspace));
        const skipped = (r.skipped || []).filter(s => s.why !== "already open" && s.why !== "the app is already running");
        if (skipped.length > 0)
            parts.push(skipped.length === 1 ? String(skipped[0].name) + " is not restored (" + String(skipped[0].why) + ")"
                : skipped.length + " windows are not restored");
        if (lost > 0)
            parts.push(lost + (lost === 1 ? " command was" : " commands were") + " not taken by a shell: is session-hook.bash sourced in ~/.bashrc?");
        // a preset's replace: a window that would not close (an "unsaved changes" dialog is up in it)
        const kept = r.kept || [];
        for (let i = 0; i < kept.length && i < 3; i++)
            parts.push(String(kept[i]["class"] || kept[i].title || "A window") + ": did not close (it may be asking to save)");
        if (kept.length > 3)
            parts.push((kept.length - 3) + " more did not close");
        return parts.join("\n");
    }

    // The closing words when nothing needs the user: how many windows are back (nothing was missing: everything was open).
    function confirmWords(r: var): string {
        if (r.preset !== undefined) {
            const made = Number(r.restored || 0), moved = Number(r.reused || 0), closed = Number(r.closed || 0);
            const bits = [];
            if (made > 0)
                bits.push(made === 1 ? "1 window opened" : made + " windows opened");
            if (moved > 0)
                bits.push(moved === 1 ? "1 moved into place" : moved + " moved into place");
            if (closed > 0)
                bits.push(closed === 1 ? "1 closed" : closed + " closed");
            return bits.length > 0 ? bits.join(", ") : "Everything was already in place";
        }
        const n = Number(r.restored || 0);
        if (n > 0)
            return n === 1 ? "1 window is back" : n + " windows are back";
        return "Everything was already open";
    }

    // The restore's result line (a probe calls this in a mock).
    function restored(r: var): void {
        root._result = r;
        root._phase = root._phaseAfter !== "" ? root._phaseAfter : (root.enabled ? "idle" : "off");
        root._phaseAfter = "";
        root._tellTitle = root._presetName !== "" ? root._presetName + " is loaded" : "Session restored";
        root._progress = null;
        // Under the lock Hyprland gives no window the focus: the tool says it is owed, and it is given at the unlock.
        if (r.refocus === true) {
            root._refocusDue = true;
            refocusLook.restart();
        }
        // What needs the user, else the plain confirmation (a restore must not end by its toast just going) -- unless `resultToast`
        // asks for less.
        const needs = root.resultWords(r);
        root._tell = needs !== "" ? needs : root.confirmWords(r);
        if (root.resultToast === "off" || (root.resultToast === "needs" && needs === ""))
            root._tell = "";
        root._tellMs = needs !== "" ? 12000 : 6000;
        // The result takes the progress toast's place in ONE turn (posted, then the progress withdrawn): the stack
        // hands the room over instead of closing the lane between the two (NotificationToast, THE HAND-OVER).
        root._postTell();
        if (root._progressUp && root.notifier)
            root.notifier.withdraw("progress");
        root._progressUp = false;
        tellLook.restart();
    }
    // The result is told like an ask: when somebody can read it.
    property string _tell: ""
    property string _tellTitle: "Session restored"
    property int _tellMs: 12000
    Timer {
        id: tellLook
        interval: 0
        onTriggered: root._postTell()
    }
    function _postTell(): void {
        if (root._tell === "" || !root._ready || !root.notifier)
            return;
        const words = root._tell;
        root._tell = "";
        root._record("tell");
        root.notifier.notify("result", { title: root._tellTitle, body: words, urgency: "low", timeoutMs: root._tellMs });
    }
    onLockedChanged: {
        if (!root.locked) {
            tellLook.restart();
            refocusLook.restart();
            progressLook.restart();
        }
    }
    property bool _refocusDue: false
    Timer {
        id: refocusLook
        interval: 0
        onTriggered: {
            if (!root._refocusDue || root.locked)
                return;
            root._refocusDue = false;
            root._record("refocus");
            if (root.live)
                refocusProc.running = true;
        }
    }
    Process {
        id: refocusProc
        command: [root.python, root.tool, "refocus"]
    }
    onShownChanged: {
        if (root.shown) {
            tellLook.restart();
            progressLook.restart();
        }
    }

    // ---- the watcher ----------------------------------------------------------------------------------------
    SupervisedStream {
        id: watcher
        // after `begin`: it froze the previous session's rolling picture, which this child rewrites
        enabled: root.live && root.enabled && root._decision !== null
        what: "SessionService: the session watcher"
        command: root.launcher.concat([root.python, "-u", root.tool, "watch"])
    }
    readonly property bool watching: watcher.running
}
