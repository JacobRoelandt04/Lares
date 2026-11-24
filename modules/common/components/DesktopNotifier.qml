pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "../notify"

// =============================================================================
// DesktopNotifier.qml -- a notification with actions, one per KEY.
//
//   notify(key, { title, body, urgency, actions: [{ id, label }], timeoutMs,
//                 icon, bodyComponent, bodyProps })       (the last three: the shell's service only -- a glyph in the icon
//                                                        column and a rich body; the notify-send path ignores them)
//   withdraw(key)
//   signal action(string key, string id)
//
// This is the interface; notify-send is the backend without the shell's own
// notification service (docs/notifications.md),
// which implements the same three things, so the modules that notify do not
// change. The pattern is LlmAttention's: `notify-send -p -A`
// prints the daemon's id, then blocks and prints the action a click chose.
//
// A new notify() on a key replaces that key's notification. The pool of
// waiters is one per key (the clock's by default); an unknown key uses the
// LAST one, the spare. A host with its own keys sets `keys` once, before it
// notifies: the pool is rebuilt when the list's length changes.
//
// THE SHELL'S OWN NOTIFICATIONS. When a NotificationService is up
// (NotificationBus.service), this is an ADAPTER: notify() posts in process
// as source `sourceId` (appName lowercased by default) with the same key --
// a sticky `timeoutMs: 0` becomes -1, no sound -- and an action (a button, or
// a body click on a notification that has `default`, `open` or `show`) comes
// back through the same `action(key, id)` signal; withdraw() withdraws the
// record; `attended` (the host binds its popup's visibility) makes the
// service file this source's posts silently while the user is looking.
// Without the bus the notify-send path is used: a notify() with no
// `timeoutMs` passes no `-t` (the urgency's own time, as on the bus path);
// `-t 0` would make the notification stick.
// =============================================================================
Item {
    id: root

    property string appName: "Clock"
    property string notifySend: "notify-send"
    property string gdbus: "gdbus"
    // With the bus: the source this notifier posts as, and whether the user
    // is looking at it (its posts then file silently).
    property string sourceId: root.appName.toLowerCase()
    property bool attended: false

    signal action(string key, string id)

    property var keys: ["countdown", "pomodoro", "alarm", "spare"]

    function _slot(key) {
        const i = root.keys.indexOf(key);
        return slots.itemAt(i >= 0 ? i : root.keys.length - 1);
    }

    function notify(key, spec) {
        const bus = NotificationBus.service;
        if (bus) {
            bus.post({
                source: root.sourceId, key: key, appName: root.appName,
                title: spec.title || "", body: spec.body || "",
                urgency: spec.urgency || "normal",
                timeoutMs: spec.timeoutMs === 0 ? -1 : spec.timeoutMs,
                live: spec.live === true,                  // a changing toast the user may hide (NotificationService, LIVE)
                actions: spec.actions || [],
                onAction: id => root.action(key, id),
                // a click on the card's body (the shell's own toasts open their module this way)
                onDefault: typeof spec.onDefault === "function" ? spec.onDefault : null,
                icon: spec.icon, bodyComponent: spec.bodyComponent, bodyProps: spec.bodyProps,
                sound: "none"
            });
            return;
        }
        const s = root._slot(key);
        if (s)
            s.show(key, spec);
    }

    function withdraw(key) {
        const bus = NotificationBus.service;
        if (bus) {
            bus.withdraw(root.sourceId, key);
            return;
        }
        const s = root._slot(key);
        if (s)
            s.close();
    }

    function _attend() {
        const bus = NotificationBus.service;
        if (bus)
            bus.attend(root.sourceId, root.attended);
    }
    onAttendedChanged: root._attend()
    Connections {
        target: NotificationBus
        function onServiceChanged() { root._attend(); }
    }

    Repeater {
        id: slots
        model: root.keys.length
        delegate: Item {
            id: slot
            required property int index
            property string key: ""
            property string nid: ""
            property var pending: null

            function show(key, spec) {
                slot.key = key;
                if (waiter.running) {
                    // Replace: close the shown one first; the new one goes up
                    // when its waiter has exited.
                    slot.pending = spec;
                    slot._closeShown();
                    return;
                }
                slot._spawn(spec);
            }

            function _spawn(spec) {
                slot.nid = "";
                out.consumed = 0;
                // A time the caller gave goes on as it is (0 is sticky); none given is the urgency's own time -- the daemon's -- and not
                // `-t 0`, which makes a plain post stick on this path while the service (the bus path above) gives it its urgency's time.
                const cmd = [root.notifySend, "-a", root.appName, "-u", spec.urgency || "normal"];
                if (spec.timeoutMs !== undefined)
                    cmd.push("-t", String(spec.timeoutMs));
                cmd.push("-p");
                const acts = spec.actions || [];
                for (let i = 0; i < acts.length; i++)
                    cmd.push("-A", acts[i].id + "=" + acts[i].label);
                cmd.push("--", spec.title || "", spec.body || "");
                waiter.command = cmd;
                waiter.running = true;
            }

            // Withdraw: the shown one AND one still queued behind it -- a
            // dismissed notification must not appear half a second later.
            function close() {
                slot.pending = null;
                slot._closeShown();
            }
            function _closeShown() {
                if (slot.nid.length > 0) {
                    closer.command = [root.gdbus, "call", "--session",
                                      "--dest", "org.freedesktop.Notifications",
                                      "--object-path", "/org/freedesktop/Notifications",
                                      "--method", "org.freedesktop.Notifications.CloseNotification",
                                      slot.nid];
                    closer.running = true;
                }
                if (waiter.running)
                    reaper.restart();
            }

            Process {
                id: waiter
                running: false
                stdout: StdioCollector {
                    id: out
                    waitForEnd: false
                    property int consumed: 0
                    onTextChanged: {
                        const t = out.text;
                        const end = t.lastIndexOf("\n");
                        if (end < out.consumed)
                            return;
                        const lines = t.substring(out.consumed, end).split("\n");
                        out.consumed = end + 1;
                        for (let i = 0; i < lines.length; i++) {
                            const l = lines[i].trim();
                            if (l.length === 0)
                                continue;
                            if (slot.nid.length === 0 && /^\d+$/.test(l))
                                slot.nid = l;
                            else
                                root.action(slot.key, l);
                        }
                    }
                }
            }
            Connections {
                target: waiter
                function onExited() {
                    reaper.stop();
                    slot.nid = "";
                    if (slot.pending) {
                        const spec = slot.pending;
                        slot.pending = null;
                        slot._spawn(spec);
                    }
                }
            }
            Process {
                id: closer
                running: false
            }
            Timer {
                id: reaper
                interval: 500
                onTriggered: {
                    if (waiter.running)
                        waiter.signal(9);
                }
            }
        }
    }
}
