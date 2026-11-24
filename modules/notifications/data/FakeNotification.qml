pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// FakeNotification.qml -- a Notification-shaped object for the in-process
// mockup (INPROC=1) and the probes: `service.receive(fake)` takes it exactly as
// the bridge takes a real one.
//
// The shape is Quickshell 0.3.1's Notification: the same
// properties with their change signals, `actions` as [{ identifier, text,
// invoke() }], `expire()` / `dismiss()` / `sendInlineReply(text)`, and
// `closed(reason)`. It also BEHAVES like one: invoking an action or sending a
// reply closes a non-resident notification with Dismissed (2), as the real
// server does -- a mockup that did not would teach the UI the wrong thing.
//
// `transient` is a reserved word in a QML declaration, so a fake says it the
// way the bus does: `hints: { transient: true }` (the real server keeps the
// hint in `hints` too, and the service reads either).
//
// Extra, for whoever plays the sender: `actionInvoked(id)`, `replied(text)`,
// `alive` (false once closed). `closeFromSender()` is the
// app withdrawing it (CloseRequested, 3); `replace(fields)` is the app sending
// a replace -- the fields change in place, one change signal each, as on the
// bus.
// =============================================================================
QtObject {
    id: root

    // NotificationUrgency: 0 low, 1 normal, 2 critical.
    // NotificationCloseReason: 1 Expired, 2 Dismissed, 3 CloseRequested.
    property int id: 0
    property bool tracked: false
    property bool lastGeneration: false
    property real expireTimeout: -1
    property string appName: ""
    property string appIcon: ""
    property string summary: ""
    property string body: ""
    property int urgency: 1
    property var actions: []
    property bool resident: false
    property string desktopEntry: ""
    property string image: ""
    property bool hasInlineReply: false
    property string inlineReplyPlaceholder: ""
    property var hints: ({})

    readonly property bool alive: root._alive

    signal closed(int reason)
    signal actionInvoked(string identifier)
    signal replied(string text)

    // Plain [{ id, label }] -> the server's action objects.
    function setActions(list) {
        const out = [];
        let reply = false;
        for (let i = 0; i < (list || []).length; i++) {
            const a = list[i];
            const act = root._makeAction(String(a.id), String(a.label === undefined ? a.id : a.label));
            if (act.identifier === "inline-reply") {
                reply = true;
                root.inlineReplyPlaceholder = act.text;
            }
            out.push(act);
        }
        root.hasInlineReply = reply;
        root.actions = out;
    }

    function expire() { root._close(1); }
    function dismiss() { root._close(2); }
    function closeFromSender() { root._close(3); }

    function sendInlineReply(text) {
        if (!root._alive || !root.hasInlineReply)
            return;
        root.replied(String(text));
        root._close(2);
    }

    function replace(fields) {
        const keys = Object.keys(fields || {});
        for (let i = 0; i < keys.length; i++) {
            if (keys[i] === "actions")
                root.setActions(fields.actions);
            else
                root[keys[i]] = fields[keys[i]];
        }
    }

    // ---- Private -------------------------------------------------------------
    property bool _alive: true
    property int _reason: 0

    function _makeAction(identifier, text) {
        return {
            identifier: identifier,
            text: text,
            invoke: function () {
                if (!root._alive)
                    return;
                root.actionInvoked(identifier);
                if (!root.resident)
                    root._close(2);
            }
        };
    }

    function _close(reason) {
        if (!root._alive)
            return;
        root._alive = false;
        root._reason = reason;
        root.tracked = false;
        root.closed(reason);
    }
}
