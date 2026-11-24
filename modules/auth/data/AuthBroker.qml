pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../../common/auth"

// =============================================================================
// AuthBroker.qml -- every request the shell is asked to authenticate.
//
// A SOURCE (PolkitSource; sudo's askpass) opens a request with what
// to show and how to answer it, keeps it current with update(), and ends it
// with finish(). The UI (the auth toast) reads `current` and answers
// through submit() / cancel(). One request is live at a time -- `current`, the
// oldest open one -- and the rest wait behind it.
//
// A record is a new object on every change, so a binding on it re-evaluates:
//   { id, source, title, body, detail, iconName, user, identities, identityIndex,
//     prompt   ""  = no PAM prompt open, else its text
//     echo     the prompt wants its answer shown
//     face     "none" | "scanning" | "ok" | "failed"
//     faceUntil  epoch ms after which a silent scan stops being claimed (native)
//     state    "idle" | "checking" | "failed" | "ok" | "cancelled"
//     message, isError   the stack's own words (howdy, pam_unix, polkit)
//     failCount
//     held     an Enter is waiting for the prompt to open }
//
// HELD ANSWERS. Under howdy `workaround = off` the prompt opens only after the
// face scan (measured): a password typed and entered during the scan
// is kept here -- in memory, for that one request -- and answered the moment a
// prompt opens, as the lockscreen holds its Enter. Under `native` the prompt is
// open from the start and nothing waits. A held answer dies with its request.
// =============================================================================
Scope {
    id: root

    // Write this broker into AuthBus (the shell's one; a probe's own is off).
    property bool registerOnBus: true
    // How long a request that succeeded stays (so its "ok" can be seen), and
    // one that ended in an error (so its message can be read).
    property int okHoldMs: 700
    property int errorHoldMs: 4000

    readonly property var current: root._list.length > 0 ? root._list[0] : null
    readonly property var requests: root._list
    readonly property int count: root._list.length

    signal opened(var record)
    signal changed(var record)
    signal closed(string id, string outcome)

    property var _list: []
    property var _handlers: ({})
    property var _held: ({})
    property var _removeAt: ({})
    property int _seq: 0

    // spec: { source, title, body, detail, iconName, user, identities,
    //         identityIndex, prompt, echo, face, faceUntil, message, isError }
    // handlers: { respond(secret), cancel(), selectIdentity(index) }
    function open(spec, handlers) {
        const s = spec || {};
        root._seq++;
        const id = String(s.source || "auth") + ":" + root._seq;
        const rec = {
            id: id, source: String(s.source || ""),
            title: String(s.title || ""), body: String(s.body || ""),
            detail: String(s.detail || ""), iconName: String(s.iconName || ""),
            user: String(s.user || ""),
            identities: Array.isArray(s.identities) ? s.identities.slice() : [],
            identityIndex: s.identityIndex === undefined ? 0 : Number(s.identityIndex),
            prompt: String(s.prompt || ""), echo: !!s.echo,
            face: String(s.face || "none"), faceUntil: Number(s.faceUntil || 0),
            state: "idle", message: String(s.message || ""), isError: !!s.isError,
            failCount: 0, held: false
        };
        root._handlers[id] = handlers || {};
        root._list = root._list.concat([rec]);
        root.opened(rec);
        return id;
    }

    function _index(id) {
        for (let i = 0; i < root._list.length; i++)
            if (root._list[i].id === id)
                return i;
        return -1;
    }

    function record(id) {
        const i = root._index(id);
        return i < 0 ? null : root._list[i];
    }

    function _replace(i, rec) {
        const next = root._list.slice();
        next[i] = rec;
        root._list = next;
        root.changed(rec);
    }

    function update(id, patch) {
        const i = root._index(id);
        if (i < 0)
            return;
        const prev = root._list[i];
        const rec = Object.assign({}, prev, patch || {});
        rec.id = prev.id;
        rec.source = prev.source;
        const opening = prev.prompt.length === 0 && rec.prompt.length > 0;
        const held = Object.prototype.hasOwnProperty.call(root._held, id);
        if (opening && held) {
            // The prompt the held Enter was waiting for.
            const secret = root._held[id];
            delete root._held[id];
            rec.held = false;
            root._replace(i, root._answered(rec));
            // Not from inside the source's own change notification (the
            // prompt opening): a real AuthFlow would be re-entered.
            Qt.callLater(() => root._respond(id, secret));
            return;
        }
        root._replace(i, rec);
    }

    // The record as it reads once an answer has gone down the open prompt.
    function _answered(rec) {
        return Object.assign({}, rec, { prompt: "", state: "checking", message: "", isError: false });
    }

    function _respond(id, secret) {
        const h = root._handlers[id];
        if (h && typeof h.respond === "function")
            h.respond(secret);
    }

    // The UI's Enter. Answered at once when a prompt is open, else held.
    function submit(id, secret) {
        const i = root._index(id);
        if (i < 0)
            return;
        const rec = root._list[i];
        if (rec.state === "ok" || rec.state === "cancelled")
            return;
        const s = String(secret === undefined || secret === null ? "" : secret);
        if (rec.prompt.length > 0) {
            root._replace(i, root._answered(rec));
            root._respond(id, s);
        } else {
            root._held[id] = s;
            root._replace(i, Object.assign({}, rec, { held: true }));
        }
    }

    // The UI's cancel: the source is told and ends the request with finish().
    function cancel(id) {
        const i = root._index(id);
        if (i < 0)
            return;
        delete root._held[id];
        const h = root._handlers[id];
        root._replace(i, Object.assign({}, root._list[i], { state: "cancelled", held: false, prompt: "" }));
        if (h && typeof h.cancel === "function")
            h.cancel();
    }

    function selectIdentity(id, index) {
        const i = root._index(id);
        if (i < 0)
            return;
        const h = root._handlers[id];
        root._replace(i, Object.assign({}, root._list[i], { identityIndex: Number(index) }));
        if (h && typeof h.selectIdentity === "function")
            h.selectIdentity(Number(index));
    }

    // outcome: "ok" (stays okHoldMs as ok), "error" (stays errorHoldMs as
    // failed, with the message the source set), anything else (goes now).
    function finish(id, outcome) {
        const i = root._index(id);
        if (i < 0)
            return;
        delete root._held[id];
        const out = String(outcome || "cancelled");
        const hold = out === "ok" ? root.okHoldMs : out === "error" ? root.errorHoldMs : 0;
        if (hold > 0) {
            root._replace(i, Object.assign({}, root._list[i], { state: out === "ok" ? "ok" : "failed", prompt: "", held: false }));
            root._removeAt[id] = { at: Date.now() + hold, outcome: out };
            root._arm();
            return;
        }
        root._remove(id, out);
    }

    function _remove(id, outcome) {
        const i = root._index(id);
        if (i < 0)
            return;
        delete root._handlers[id];
        delete root._held[id];
        delete root._removeAt[id];
        const next = root._list.slice();
        next.splice(i, 1);
        root._list = next;
        root.closed(id, outcome);
    }

    function _arm() {
        let soonest = 0;
        for (const id in root._removeAt)
            if (soonest === 0 || root._removeAt[id].at < soonest)
                soonest = root._removeAt[id].at;
        if (soonest === 0)
            return;
        sweep.interval = Math.max(1, soonest - Date.now());
        sweep.restart();
    }

    Timer {
        id: sweep
        repeat: false
        onTriggered: {
            const now = Date.now();
            const due = [];
            for (const id in root._removeAt)
                if (root._removeAt[id].at <= now + 5)
                    due.push({ id: id, outcome: root._removeAt[id].outcome });
            for (let k = 0; k < due.length; k++)
                root._remove(due[k].id, due[k].outcome);
            root._arm();
        }
    }

    Component.onCompleted: if (root.registerOnBus) AuthBus.broker = root
    Component.onDestruction: if (AuthBus.broker === root) AuthBus.broker = null
}
