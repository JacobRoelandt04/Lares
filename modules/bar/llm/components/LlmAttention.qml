pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../../../common/notify"
import "LlmVoicePolicy.js" as Voice

// =============================================================================
// LlmAttention.qml
//
// The notification behind a confirmation nobody has answered. LlmService is
// blind to visibility -- nothing in it may ever read the popup -- so it only
// says WHEN: `confirmOverdue` at confirmNotifyMs, and
// `confirmIsOverdue` for as long as the request stands. This item, created by
// the host beside the service with `attended` bound to the popup's
// visibility, ANDs the two: it notifies ONCE per request id at the first
// moment `service.confirmIsOverdue && !attended` holds -- at 15 s if the
// popup is already closed, or the moment it closes if 15 s have passed --
// and never while the popup is open, where the panel itself is the prompt.
//
// TYPED CHATS: the notification is `notify-send -a LLM -u normal -t 0 -p -A show=Show`:
// the process waits for the user, its first stdout line is the id, a later
// `show` line means the Show action was clicked and `showRequested()` goes to
// the host (which opens the popup; the panel is already there). It carries
// NO Run and NO Allow: the answer is given in front of the verbatim command,
// nowhere else. On `confirmResolved` (any decision) the notification is
// replaced away -- `notify-send -r <id> -t 1 "Answered"` -- and the waiter,
// if still alive 500 ms later, is killed: it is our own process, not the
// daemon's. `enabled: false` is for the day the shell's own notification
// manager consumes confirmOverdue itself.
//
// WITH THE SHELL'S NOTIFICATION SERVICE (NotificationBus.service) the same
// moments post in process instead -- source "llm", key "confirm", sticky,
// the Show action calling showRequested() -- and an answer is withdrawn
// rather than replaced. The bus also carries one thing the notify-send path
// does not: `service.answerCompleted` while the popup is NOT attended posts a
// low "answer" notice whose Open asks for `openConversation(convId)`.
// Without the bus the notify-send path above is the whole behaviour.
//
// A SPOKEN ASK (LlmService.voiceAsk) RUNS IN THE BACKGROUND AND OPENS NO CHAT (the user, 2026-11-13: "silent and running in the
// background"), so everything it has to say comes through here, as toasts, and each ask has at most TWO of them:
//   ITS ANSWER, ONCE (`voiceAnswered`): the answer's first four lines, the title the ask's words, normal timeout, kept in the
//     manager, with "Open chat" (which opens THAT conversation, with the keyboard: the user clicked). An answer that is one block,
//     one command or one short value is put on the clipboard first -- through `wl-copy`'s stdin, the road the dictation's and
//     the clipboard module's writes take, never `Quickshell.clipboardText` --, `--sensitive` for a private conversation so the
//     clipboard history keeps no copy, and once wl-copy has exited 0 the SAME toast says "Copied" and shows the value: one
//     toast, not a "Copied" and an "answer ready". A copy that fails posts the answer's toast without "Copied". A turn that ends
//     with no answer (the server said no, the approval went unanswered for `voiceConfirmDropMs`) says why in its one toast; a
//     Stop pressed in a chat posts none. The generic "answer" notice below is not posted for a spoken turn.
//   ITS APPROVAL, WHEN A CALL NEEDS ONE (`confirmRequested` with `req.spoken`): the typed rule above (no Run in a notification)
//     is changed on purpose for a spoken ask (the user, 2026-11-13: a call for approval with no chat open must be answerable) --
//     a sticky toast with the exact command, in the folder it runs in, and Run / Deny / Open chat. Run and Deny go through
//     `service.answerConfirm`, the panel's own path; nothing runs without the click; a toast whose request is gone (answered in
//     the panel, the turn ended) does nothing and says so; an answer anywhere withdraws it. A command too long to show whole is
//     offered only Deny and Open chat (the toast must never ask for a Run the user cannot read). It is posted at once and not
//     after 15 s, and not when the chat is open on that very conversation (its panel is the prompt; the popup shows a spoken
//     approval only for the conversation it is on). Typed chats keep the rule above, unchanged.
// =============================================================================
Item {
    id: root

    property var  service: null
    property bool attended: false       // the host binds the popup's visibility
    // `enabled` (frozen API) is the Item's own: false once a notification
    // manager consumes confirmOverdue itself.
    // For the probe: the program to spawn (a PATH-shadowed stub in tests).
    property string notifySend: "notify-send"
    // The clipboard's writer (the text goes in on its stdin).
    property var copyCommand: ["wl-copy"]

    signal showRequested()
    signal openConversation(string convId)

    property string _notifiedFor: ""
    property string _nid: ""            // the daemon's id for our notification
    property int    _spawns: 0

    function _consider() {
        if (!root.enabled || !root.service || root.attended) return;
        const req = root.service.pendingConfirm;
        if (!req || !root.service.confirmIsOverdue) return;
        // A spoken ask's approval has its own toast (below) when there is a bus to post it on.
        if (req.spoken && NotificationBus.service) return;
        if (root._notifiedFor === req.id) return;
        root._notify(req);
    }

    onAttendedChanged: { root._consider(); root._considerSpoken(); }
    onEnabledChanged: { root._consider(); root._considerSpoken(); }

    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onConfirmOverdue(req) { root._consider(); }
        function onConfirmIsOverdueChanged() { root._consider(); }
        function onConfirmRequested(req) { root._considerSpoken(); }
        function onActiveIdChanged() { root._considerSpoken(); }
        function onConfirmResolved(id, decision) { root._answered(id); root._askAnswered(id); }
        // The request is gone and nobody said how (a turn reset under it): the notification for it must not stand for ever, and its id
        // must not stay "already told" -- a model that sends no call ids is given the same synthesised one in every turn.
        function onPendingConfirmChanged() {
            const pc = root.service ? root.service.pendingConfirm : null;
            if (root._notifiedFor !== "" && (!pc || pc.id !== root._notifiedFor))
                root._answered(root._notifiedFor);
            if (root._askToastFor !== "" && (!pc || pc.id !== root._askToastFor))
                root._askAnswered(root._askToastFor);
            root._considerSpoken();
        }
        function onAnswerCompleted(convId, title, preview) { root._answer(convId, title, preview); }
        function onAnswerFailed(convId, message) { root._forget(convId); }
        function onVoiceAnswered(convId, title, text, copyText, incognito, problem) {
            root._voiceAnswered(convId, title, text, copyText, incognito, problem);
        }
    }

    // ---- a spoken ask's approval: a toast the user can answer with no chat open (see the header) ---------------------
    property string _askToastFor: ""        // the request id whose toast is up
    property string _askOpenedFor: ""       // ...whose "Open chat" was just clicked: not posted again while the chat comes up

    // Run is offered only for a command that shows whole in the toast (one line, at most this long).
    readonly property int askRunMaxChars: 100

    function _considerSpoken() {
        const bus = NotificationBus.service;
        const svc = root.service;
        if (!bus || !svc || !root.enabled) return;
        const req = svc.pendingConfirm;
        if (!req || !req.spoken || root._askToastFor === req.id || root._askOpenedFor === req.id) return;
        // The chat is open on this very conversation: its panel is the prompt.
        if (root.attended && svc.activeId === req.convId) return;
        root._postAsk(req);
    }

    // Text for a notification body: shown as typed (the body is markup-light; a `<b>` in a command must stay a `<b>`).
    function _plain(t) {
        return String(t === undefined || t === null ? "" : t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function _postAsk(req) {
        const bus = NotificationBus.service;
        const detail = String(req.detail || "");
        const fits = detail.length > 0 && detail.length <= root.askRunMaxChars && detail.indexOf("\n") < 0;
        const mins = Math.max(1, Math.round((root.service ? root.service.voiceConfirmDropMs : 600000) / 60000));
        const lines = [];
        lines.push(fits ? root._plain(detail) : "Too long to show here: open the chat to read it whole.");
        if (req.cwd) lines.push("in " + root._plain(req.cwd));
        if (req.reason) lines.push(root._plain(root._oneLine(req.reason, 120)));
        lines.push("Dropped if not answered in " + mins + " min.");
        const title = String(req.title || "run this?");
        const acts = [];
        if (fits) acts.push({ id: "run", label: "Run" });
        acts.push({ id: "deny", label: "Deny" });
        acts.push({ id: "open", label: "Open chat" });
        root._askToastFor = req.id;
        bus.post({
            source: "llm", key: "confirm", appName: "LLM",
            title: title.charAt(0).toUpperCase() + title.substring(1),
            body: lines.join("\n"),
            urgency: "normal", timeoutMs: -1, sound: "none", persist: false,
            actions: acts,
            onAction: id => root._askAction(req, id)
        });
    }

    function _askAction(req, id) {
        const svc = root.service;
        if (id === "open") {
            // The record is consumed by the click; the chat opening is the prompt now, and a chat closed unanswered brings it back.
            root._askToastFor = "";
            root._askOpenedFor = req.id;
            _openTimer.restart();
            root.openConversation(req.convId);
            return;
        }
        const pc = svc ? svc.pendingConfirm : null;
        if (!pc || pc.id !== req.id) {
            root._said("Already answered", "That ask is gone, so nothing ran.");
            return;
        }
        root._askToastFor = "";
        svc.answerConfirm(req.id, id === "run" ? "yes" : "no");
    }

    function _askAnswered(id) {
        if (root._askToastFor !== id) return;
        root._askToastFor = "";
        const bus = NotificationBus.service;
        if (bus) bus.withdraw("llm", "confirm");
    }

    // The chat had time to come up: judge the approval again (its panel, or its toast back).
    Timer {
        id: _openTimer
        interval: 3000
        onTriggered: {
            root._askOpenedFor = "";
            root._considerSpoken();
        }
    }

    function _said(title, body) {
        const bus = NotificationBus.service;
        if (!bus) return;
        bus.post({ source: "llm", key: "said", appName: "LLM", title: title, body: body, urgency: "low", sound: "none" });
    }

    // ---- a spoken ask's answer: ONE toast (see the header) ------------------------------------------------------------
    // The convIds whose end the spoken path owns: the generic "answer" notice is not posted for them.
    property var _voiceDone: ({})
    function _forget(convId) {
        if (!root._voiceDone[convId]) return;
        const rest = Object.assign({}, root._voiceDone);
        delete rest[convId];
        root._voiceDone = rest;
    }

    property var _copyQueue: []
    function _voiceAnswered(convId, title, text, copyText, incognito, problem) {
        const held = Object.assign({}, root._voiceDone);
        held[convId] = true;
        root._voiceDone = held;
        if (problem === "stopped") return;
        if (problem !== "") {
            root._toastVoice(convId, problem === "dropped" ? "Dropped" : "No answer",
                             (title ? title + "\n" : "")
                             + (problem === "dropped" ? "Nobody answered its approval in time, so the ask was dropped." : problem));
            return;
        }
        if (String(copyText || "").length > 0) {
            root._copyQueue = root._copyQueue.concat([{ convId: convId, title: title, text: text, copyText: String(copyText), incognito: !!incognito }]);
            root._pumpCopy();
            return;
        }
        root._toastVoice(convId, title || "Answer", Voice.toastBody(text).body);
    }
    function _pumpCopy() {
        if (_copier.running || root._copyQueue.length === 0) return;
        const c = root._copyQueue[0];
        root._copyQueue = root._copyQueue.slice(1);
        _copier.job = c;
        _copier.pending = c.copyText;
        _copier.command = root.copyCommand.concat(c.incognito ? ["--sensitive"] : []);
        _copier.stdinEnabled = true;
        _copier.running = true;
    }
    function _copied(ok) {
        const c = _copier.job;
        _copier.job = null;
        _copier.pending = "";
        if (c) {
            // "Copied" and the value when the clipboard holds it; else the answer as an answer.
            if (ok) root._toastVoice(c.convId, "Copied", Voice.toastBody(c.copyText).body);
            else root._toastVoice(c.convId, c.title || "Answer", Voice.toastBody(c.text).body);
        }
        root._pumpCopy();
    }
    function _toastVoice(convId, title, body) {
        const text = body.length > 0 ? body : "No text came back.";
        const bus = NotificationBus.service;
        if (bus) {
            bus.post({ source: "llm", key: "voice-" + convId, appName: "LLM", title: title, body: root._plain(text),
                       urgency: "normal", sound: "none",
                       actions: [{ id: "open", label: "Open chat" }],
                       onAction: id => { if (id === "open") root.openConversation(convId); } });
            return;
        }
        if (_toaster.running) return;
        _toaster.command = [root.notifySend, "-a", "LLM", "-u", "normal", "--", title, text];
        _toaster.running = true;
    }
    Process {
        id: _copier
        property var job: null
        property string pending: ""
        running: false
        onStarted: {
            _copier.write(_copier.pending);
            // Closing the write channel is wl-copy's EOF.
            _copier.stdinEnabled = false;
        }
        onExited: (code, status) => root._copied(code === 0 && status === 0)
    }
    Process {
        id: _toaster
        running: false
    }

    function _oneLine(s, n) {
        const t = String(s || "").replace(/\s+/g, " ").trim();
        return t.length > n ? t.substring(0, n - 1) + "…" : t;
    }

    function _notify(req) {
        const bus = NotificationBus.service;
        if (bus) {
            root._notifiedFor = req.id;
            bus.post({
                source: "llm", key: "confirm", appName: "LLM",
                title: "Waiting for your OK",
                body: root._oneLine(req.title, 80) + " — " + root._oneLine(req.detail, 160),
                urgency: "normal", timeoutMs: -1,
                actions: [{ id: "show", label: "Show" }],
                onAction: id => { if (id === "show") root.showRequested(); },
                sound: "none"
            });
            return;
        }
        if (_waiter.running) return;
        root._notifiedFor = req.id;
        root._nid = "";
        root._spawns++;
        _waiterOut.reset();
        _waiter.command = [root.notifySend, "-a", "LLM", "-u", "normal", "-t", "0", "-p", "-A", "show=Show", "--",
                           "Waiting for your OK",
                           root._oneLine(req.title, 80) + " — " + root._oneLine(req.detail, 160)];
        _waiter.running = true;
    }

    function _answered(id) {
        if (root._notifiedFor !== id) return;
        root._notifiedFor = "";
        const bus = NotificationBus.service;
        if (bus) {
            bus.withdraw("llm", "confirm");
            return;
        }
        if (root._nid.length > 0) {
            _replacer.command = [root.notifySend, "-r", root._nid, "-t", "1", "--", "Answered"];
            _replacer.running = true;
        }
        if (_waiter.running) _reaper.restart();
    }

    // A TYPED answer finished while the popup is not in front: the bus only.
    function _answer(convId, title, preview) {
        // A spoken ask has its one toast (`_voiceAnswered`).
        if (root._voiceDone[convId]) {
            root._forget(convId);
            return;
        }
        const bus = NotificationBus.service;
        if (!bus || !root.enabled || root.attended) return;
        bus.post({
            source: "llm", key: "answer", appName: "LLM",
            title: title || "Answer ready", body: preview || "",
            urgency: "low",
            actions: [{ id: "open", label: "Open" }],
            onAction: id => { if (id === "open") root.openConversation(convId); }
        });
    }

    Process {
        id: _waiter
        running: false
        stdout: StdioCollector {
            id: _waiterOut
            waitForEnd: false
            property int consumed: 0
            function reset() { consumed = 0; }
            onTextChanged: {
                // Complete lines only, each read once: the collector's text
                // is cumulative, so the cursor moves to the last newline.
                const t = _waiterOut.text;
                const end = t.lastIndexOf("\n");
                if (end < _waiterOut.consumed) return;
                const lines = t.substring(_waiterOut.consumed, end).split("\n");
                _waiterOut.consumed = end + 1;
                for (let i = 0; i < lines.length; i++) {
                    const l = lines[i].trim();
                    if (l.length === 0) continue;
                    if (root._nid.length === 0 && /^\d+$/.test(l)) root._nid = l;
                    else if (l === "show") root.showRequested();
                }
            }
        }
    }
    Connections {
        target: _waiter
        function onExited() { _reaper.stop(); }
    }

    Process {
        id: _replacer
        running: false
    }

    // Our own waiter, still alive 500 ms after the answer: kill it.
    Timer {
        id: _reaper
        interval: 500
        repeat: false
        onTriggered: { if (_waiter.running) _waiter.signal(9); }
    }
}
