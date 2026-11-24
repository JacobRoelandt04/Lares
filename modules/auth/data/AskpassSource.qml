pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// AskpassSource.qml -- sudo's askpass, as AuthBroker requests.
//
// An AskpassServer (the socket sudo's helper asks on, the verification and the
// settle watch) is bound to the shell's AuthBroker. One sudo is one broker
// request for as long as it lives, whoever asked: a polkit-like conversation
// whose prompt is open from the start, because sudo starts its helper at once
// -- under howdy `workaround = native` ~30 ms in, beside the face scan -- and
// does not wait for it when the face wins. So the OUTCOME comes from the
// processes (AskpassServer's `sudoSettled`), not from the helper:
//
//   a request          opens a record, prompt open at once; face `scanning`
//                      until `faceUntil` under native (like PolkitSource: a
//                      failed face says nothing), `none` otherwise -- under
//                      `off` the helper only starts after the scan is over
//   a retry            a wrong password ends the helper and sudo asks again
//                      with a NEW request from the SAME sudo pid: the record
//                      goes failed, failCount + 1, the prompt open again.
//                      Only an answered record counts: a request that follows
//                      no answer (a helper that died, sudo asking again) is not
//                      a wrong password
//   moved-on           sudo runs its command: authenticated, by the face or by
//                      the password -> "ok" (face `ok` when the scan was still
//                      claimed and nothing was answered)
//   gone               sudo exited: "cancelled". An honest close -- a quick
//                      `sudo true` and a third wrong try both end that way and
//                      cannot be told apart
//   helper lost        the helper died or the answer window ran out with sudo
//                      still there (or the server stopped serving): "cancelled"
//
// The client says what is being asked in `describe` (a function(request) ->
// { body, detail }); `title` is the same for every request of this source. A
// wrong password reads as the lockscreen's does ("Wrong password, 2 attempts",
// from failCount); there is no lockout to count down to (deny = 0).
//
// With no `broker` there is nobody to ask: the request is answered "" at once
// and `declined` says why (the client shows it).
// =============================================================================
Scope {
    id: root

    property var broker: null
    property var server: null
    property string title: "Authentication required"
    property var describe: null
    // Bound by the owner from HowdyConfig (as PolkitSource's are).
    property string howdyMode: "absent"
    property int faceTimeoutMs: 4000
    property int faceMarginMs: 1500

    // A request met no broker and was answered "".
    signal declined(var request, string reason)

    // The broker's record id of the sudo whose request `requestId` is, or "".
    function recordFor(requestId) {
        const e = root._entryOf(requestId);
        return e ? e.id : "";
    }

    // sudoPid -> { id: broker record, reqId: the server's standing request,
    //              answered: the reqId an answer went down, closing }
    property var _open: ({})

    function _entryOf(requestId) {
        for (const k in root._open)
            if (root._open[k].reqId === String(requestId))
                return root._open[k];
        return null;
    }

    function _scanPatch() {
        if (root.howdyMode !== "native")
            return { face: "none", faceUntil: 0 };
        faceClock.interval = root.faceTimeoutMs + root.faceMarginMs;
        faceClock.restart();
        return { face: "scanning", faceUntil: Date.now() + root.faceTimeoutMs + root.faceMarginMs };
    }

    function _userOf(prompt) {
        const m = /password for (\S+?):?\s*$/i.exec(String(prompt || ""));
        return m ? m[1] : "";
    }

    function _described(r) {
        let d = null;
        if (typeof root.describe === "function") {
            try { d = root.describe(r); } catch (e) { d = null; }
        }
        return d || {};
    }

    function _forget(pid) {
        delete root._open[pid];
        if (Object.keys(root._open).length === 0)
            faceClock.stop();
    }

    // The record ends and the sudo is forgotten.
    function _end(pid, outcome) {
        const e = root._open[pid];
        if (!e)
            return;
        e.closing = true;
        root._forget(pid);
        if (root.broker)
            root.broker.finish(e.id, outcome);
    }

    function _onRequested(r) {
        if (!root.broker) {
            if (root.server)
                root.server.cancel(r.id);
            root.declined(r, "no authentication broker is running to ask in");
            return;
        }
        const e = root._open[r.sudoPid];
        const rec = e ? root.broker.record(e.id) : null;
        if (e && rec) {
            // sudo asks again.
            const patch = Object.assign({ prompt: r.prompt, echo: false }, root._scanPatch());
            if (rec.state === "checking" || e.answered !== "") {
                patch.state = "failed";
                patch.failCount = rec.failCount + 1;
            }
            e.reqId = r.id;
            e.answered = "";
            root.broker.update(e.id, patch);
            return;
        }
        if (e)
            root._forget(r.sudoPid);
        const d = root._described(r);
        const pid = r.sudoPid;
        const entry = { id: "", reqId: r.id, answered: "", closing: false };
        root._open[pid] = entry;
        entry.id = root.broker.open(Object.assign({
            source: "askpass", title: root.title,
            body: String(d.body || ""), detail: String(d.detail || ""),
            user: root._userOf(r.prompt), prompt: r.prompt, echo: false
        }, root._scanPatch()), {
            respond: secret => {
                const cur = root._open[pid];
                if (!cur || !root.server)
                    return;
                cur.answered = cur.reqId;
                root.server.answer(cur.reqId, secret);
            },
            cancel: () => {
                const cur = root._open[pid];
                if (cur && root.server)
                    root.server.cancel(cur.reqId);
                root._end(pid, "cancelled");
            }
        });
    }

    function _onSettled(pid, how) {
        const e = root._open[pid];
        if (!e)
            return;
        if (how === "moved-on") {
            const rec = root.broker ? root.broker.record(e.id) : null;
            // Nothing was answered and the scan was still claimed: the face won.
            if (rec && rec.face === "scanning" && e.answered === "")
                root.broker.update(e.id, { face: "ok", faceUntil: 0 });
            root._end(pid, "ok");
        } else {
            root._end(pid, "cancelled");
        }
    }

    // The server's request went away. An answer, a cancel from the UI and a
    // settle account for themselves; what remains -- the helper died, the
    // window ran out, the server stopped -- ends the record.
    function _reconcile() {
        const cur = root.server ? root.server.request : null;
        const pids = Object.keys(root._open);
        for (let k = 0; k < pids.length; k++) {
            const e = root._open[pids[k]];
            if (!e || e.closing)
                continue;
            if (cur && cur.id === e.reqId)
                continue;
            if (e.answered === e.reqId)
                continue;
            root._end(pids[k], "cancelled");
        }
    }

    Connections {
        target: root.server
        ignoreUnknownSignals: true
        function onRequested(request) { root._onRequested(request); }
        function onSudoSettled(sudoPid, how) { root._onSettled(sudoPid, how); }
        function onRequestChanged() {
            if (root.server && root.server.request === null)
                Qt.callLater(root._reconcile);
        }
    }

    // native: a silent scan stops being claimed at howdy's timeout.
    Timer {
        id: faceClock
        repeat: false
        onTriggered: {
            for (const k in root._open) {
                const rec = root.broker ? root.broker.record(root._open[k].id) : null;
                if (rec && rec.face === "scanning")
                    root.broker.update(rec.id, { face: "none", faceUntil: 0 });
            }
        }
    }

    Component.onDestruction: {
        if (!root.broker)
            return;
        for (const k in root._open)
            root.broker.finish(root._open[k].id, "cancelled");
    }
}
