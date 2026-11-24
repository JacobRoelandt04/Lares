pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.Polkit

// =============================================================================
// PolkitSource.qml -- the shell's polkit agent, as AuthBroker requests.
//
// Quickshell's PolkitAgent queues polkit's requests itself and exposes ONE
// AuthFlow at a time (`flow`); each becomes one broker request for as long as
// it lives. polkit runs its helper on the `polkit-1` PAM stack, which begins
// with pam_howdy, so the face line follows howdy (measured):
//
//   off      the prompt opens only after the scan. `scanning` until howdy
//            speaks ("Identified face ..." -> ok, "Failure, ..." -> failed) or
//            the prompt opens (no word from howdy: it was skipped -> none).
//   native   the prompt is open from the start and a failed face says
//            NOTHING, so the line claims `scanning` only until faceUntil
//            (howdy's timeout + the camera's start), then drops to none.
//
// A wrong password fails the SESSION, not the flow: Quickshell starts the next
// session itself (same cookie), and howdy scans again -- failCount++, face
// scanning again. The flow ends in isCompleted: successful -> finish "ok",
// otherwise "cancelled".
//
// polkitd allows ONE agent per session (refused while polkit-gnome
// holds it), so `enabled` is the deploy's switch. `agent` defaults to the real
// one; a probe hands in a fake with the same properties and signals.
// =============================================================================
Scope {
    id: root

    property var broker: null
    property bool enabled: true
    // Bound by the owner from HowdyConfig.
    property string howdyMode: "absent"
    property int faceTimeoutMs: 4000
    // The camera's start on top of howdy's own timeout (3975 ms to
    // a face cold against 919 warm).
    property int faceMarginMs: 1500
    // A probe's fake agent; null = the real PolkitAgent.
    property var fakeAgent: null
    // Sessions that fail with NO answer given are not wrong passwords: the
    // helper or a module broke, and Quickshell restarts the session at once,
    // for ever (howdy cannot reach the camera inside polkit's sandboxed helper
    // -- `Unknown line ... from helper` -- and the request then loops every
    // ~250 ms while pkexec hangs). EVERY such session is
    // a failed login to pam_faillock: the loop locks the account (deny = 3)
    // within a second. So the FIRST one ends the request with an error. A
    // session failing before any answer has no innocent cause here: under
    // howdy native the prompt waits for a password whatever the face does.
    property int helperLoopMax: 1
    property int helperLoopWindowMs: 3000

    readonly property var agent: root.fakeAgent ? root.fakeAgent : realAgent.item
    readonly property bool registered: root.fakeAgent ? true : (realAgent.item ? realAgent.item.isRegistered : false)
    readonly property var flow: root.agent ? root.agent.flow : null

    property var _flow: null
    property string _id: ""
    property var _unanswered: []

    LazyLoader {
        id: realAgent
        active: root.enabled && root.fakeAgent === null
        PolkitAgent {}
    }

    onFlowChanged: root._attach(root.flow)
    onBrokerChanged: {
        const f = root.flow;
        root._flow = null;
        root._id = "";
        root._attach(f);
    }

    function _faceUsable() {
        return root.howdyMode === "off" || root.howdyMode === "native" || root.howdyMode === "input";
    }

    function _names(list) {
        const out = [];
        const l = list || [];
        for (let i = 0; i < l.length; i++) {
            const it = l[i];
            out.push(it ? String(it.displayName || it.name || it.id || "") : "");
        }
        return out;
    }

    // A fresh scan: the session just started (the flow's first, or the one
    // Quickshell starts after a wrong password).
    function _scanPatch() {
        if (!root._faceUsable())
            return { face: "none", faceUntil: 0 };
        if (root.howdyMode === "native") {
            const until = Date.now() + root.faceTimeoutMs + root.faceMarginMs;
            faceClock.interval = root.faceTimeoutMs + root.faceMarginMs;
            faceClock.restart();
            return { face: "scanning", faceUntil: until };
        }
        return { face: "scanning", faceUntil: 0 };
    }

    function _attach(f) {
        if (root._flow === f)
            return;
        // The agent moved on: this is how a flow usually ENDS (see _outcomeOf),
        // and also how one abandoned mid-way goes.
        if (root._id.length > 0 && root.broker)
            root.broker.finish(root._id, root._outcomeOf(root._flow));
        root._id = "";
        root._flow = f;
        root._unanswered = [];
        faceClock.stop();
        if (!f || !root.broker)
            return;
        const ids = root._names(f.identities);
        const sel = f.selectedIdentity;
        const selName = root._names([sel])[0];
        const idx = Math.max(0, ids.indexOf(selName));
        const spec = Object.assign({
            source: "polkit", title: "Authentication required",
            body: String(f.message || ""), detail: String(f.actionId || ""),
            iconName: String(f.iconName || ""), user: selName,
            identities: ids, identityIndex: idx,
            prompt: f.isResponseRequired ? String(f.inputPrompt || "Password:") : "",
            echo: !!f.responseVisible
        }, root._scanPatch());
        root._id = root.broker.open(spec, {
            respond: secret => { if (root._flow === f) f.submit(secret); },
            cancel: () => { if (root._flow === f) f.cancelAuthenticationRequest(); },
            selectIdentity: i => {
                const l = f.identities || [];
                if (root._flow === f && i >= 0 && i < l.length)
                    f.selectedIdentity = l[i];
            }
        });
        if (String(f.supplementaryMessage || "").length > 0)
            root._message();
    }

    function _rec() {
        return root.broker && root._id.length > 0 ? root.broker.record(root._id) : null;
    }

    function _prompt() {
        const f = root._flow;
        const rec = root._rec();
        if (!f || !rec)
            return;
        if (f.isResponseRequired) {
            const patch = { prompt: String(f.inputPrompt || "Password:"), echo: !!f.responseVisible };
            // off: the prompt opening IS howdy giving up; with no word from it,
            // it never ran (skipped: lid, ssh, disabled).
            if (root.howdyMode !== "native" && rec.face === "scanning")
                patch.face = "none";
            if (rec.state === "checking" || rec.state === "failed")
                patch.state = rec.state === "failed" ? "failed" : "idle";
            root.broker.update(root._id, patch);
        } else if (rec.prompt.length > 0) {
            root.broker.update(root._id, { prompt: "" });
        }
    }

    function _message() {
        const f = root._flow;
        const rec = root._rec();
        if (!f || !rec)
            return;
        const m = String(f.supplementaryMessage || "");
        const patch = { message: m, isError: !!f.supplementaryIsError };
        if (/Identified face/i.test(m)) {
            patch.face = "ok";
            faceClock.stop();
        } else if (/^Failure, /i.test(m) || /image too dark|not possible to open camera/i.test(m)) {
            patch.face = "failed";
            faceClock.stop();
        }
        root.broker.update(root._id, patch);
    }

    function _failed() {
        const rec = root._rec();
        if (!rec)
            return;
        if (rec.state !== "checking") {
            // nothing was answered: not a wrong password (see helperLoopMax)
            const now = Date.now();
            root._unanswered = root._unanswered.filter(t => now - t < root.helperLoopWindowMs).concat([now]);
            if (root._unanswered.length >= root.helperLoopMax) {
                root._giveUp(root._unanswered.length);
                return;
            }
            root.broker.update(root._id, Object.assign({ prompt: "" }, root._scanPatch()));
            return;
        }
        root._unanswered = [];
        root.broker.update(root._id, Object.assign({
            state: "failed", failCount: rec.failCount + 1, prompt: ""
        }, root._scanPatch()));
    }

    function _giveUp(n) {
        const f = root._flow;
        const id = root._id;
        root._id = "";
        faceClock.stop();
        root.broker.update(id, {
            state: "failed", prompt: "", face: "none", isError: true,
            message: "Authentication failed before a password was given (polkit's helper; see the journal)"
        });
        root.broker.finish(id, "error");
        if (f)
            f.cancelAuthenticationRequest();
    }

    // The flow's end, judged AT ONCE from the flow's own state. Quickshell
    // 0.3.1's agent has its own slot on the flow's isCompletedChanged
    // (agentimpl.cpp) that deleteLater()s the flow and moves the agent's `flow`
    // on (to null, or to the next queued request). QML handlers run before
    // ordinary connections, so onIsCompletedChanged hears the end first -- but
    // only for that moment: anything deferred from it finds the agent moved on,
    // and _attach takes the move-on for an abandoned flow (a face win would
    // close "cancelled"). isSuccessful does not land after isCompleted: flow.cpp
    // sets the two in ONE property group, so both are there when the first
    // notification runs. _attach judges the same way, should the move-on ever
    // come first.
    function _outcomeOf(f) {
        return f && f.isCompleted && f.isSuccessful ? "ok" : "cancelled";
    }

    function _completed() {
        const f = root._flow;
        if (!f || root._id.length === 0 || !f.isCompleted)
            return;
        const id = root._id;
        root._id = "";
        faceClock.stop();
        if (root.broker)
            root.broker.finish(id, root._outcomeOf(f));
    }

    Connections {
        target: root._flow
        ignoreUnknownSignals: true
        function onIsResponseRequiredChanged() { root._prompt(); }
        function onInputPromptChanged() { root._prompt(); }
        function onSupplementaryMessageChanged() { root._message(); }
        function onAuthenticationFailed() { root._failed(); }
        function onIsCompletedChanged() { root._completed(); }
    }

    // native: a silent scan stops being claimed at howdy's timeout.
    Timer {
        id: faceClock
        repeat: false
        onTriggered: {
            const rec = root._rec();
            if (rec && rec.face === "scanning")
                root.broker.update(root._id, { face: "none", faceUntil: 0 });
        }
    }
}
