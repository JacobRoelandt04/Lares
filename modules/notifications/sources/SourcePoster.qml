pragma ComponentBehavior: Bound

import QtQuick

import "../../common/notify"
import "../../common/components"

// =============================================================================
// SourcePoster.qml -- how one source says something (SOURCES.md, "How a module
// notifies"). Every post of the shell's own sources goes through here:
//
//     post(key, { title, body, urgency, timeoutMs, actions: [{ id, label, run, icon? }],  (icon: a glyph, an icon-only button)
//                   onDefault, bodyComponent, bodyProps, image, progress, icon,
//                   sound, breakDnd, resident, persist })
//     update(uid, patch)   a record this source posted, changed in place (false: gone)
//     withdraw(key) / withdrawAll() / has(key)
//     attended      the source's own popup is open: its posts file silently
//     signal acted(key, id)  an action ran (after its `run`)
//
// WITH THE SHELL'S SERVICE (NotificationBus.service) it is `service.post(spec)` as the
// source `sourceId`, the source's `appName` and glyph on the card, group System (every shell
// post is), one KEY per fact that replaces itself. WITHOUT it (a mockup, a probe with no
// service) the same call is a DesktopNotifier -- notify-send, as the timers' and the stocks'
// always were -- so a source works in a bare mockup; what notify-send cannot carry (a rich
// body, a progress rail, a picture, a body click) is dropped there, never half-done.
//
// The post is the source's WHOLE spec every time: a key that is posted again replaces its
// record (NotifyPolicy.retoast: new words toast again, a progress that only moved is
// silent), so a source never has to remember what it said, only what is true now.
//
// `timeoutMs` stays undefined unless the fact itself demands a time (sticky = -1, or a
// source's own setting): then the user's `sources.<id>.timeoutMs` rule and the urgency's
// default decide (NotifyPolicy.timeoutFor). `sound` defaults to "default": the urgency's
// sound from the config's `sounds` (low has none, so a low post is silent).
// =============================================================================
Item {
    id: root
    visible: false

    property string sourceId: ""
    property string appName: ""
    // The glyph the card draws in its icon column (SourceGlyphs).
    property string glyph: ""
    // The keys this source posts under: the fallback's pool of waiters.
    property var keys: []
    // The source's own popup is open on the relevant view (NotificationService.attend).
    property bool attended: false

    readonly property var bus: NotificationBus.service

    signal acted(string key, string id)

    // The uid the service gave the key's record ("" without a service).
    function post(key, spec) {
        const s = spec || {};
        const acts = Array.isArray(s.actions) ? s.actions : [];
        root._handlers[key] = acts;
        root._live[key] = true;
        const bus = root.bus;
        if (bus) {
            return bus.post({
                source: root.sourceId, key: key, appName: root.appName,
                icon: s.icon !== undefined ? s.icon : root.glyph,
                title: s.title === undefined ? "" : s.title, body: s.body === undefined ? "" : s.body,
                urgency: s.urgency === undefined ? "normal" : s.urgency,
                timeoutMs: s.timeoutMs,
                actions: acts.map(a => ({ id: a.id, label: a.label, icon: a.icon, run: typeof a.run === "function" ? a.run : undefined })),
                onAction: id => root.acted(key, id),
                onDefault: typeof s.onDefault === "function" ? s.onDefault : undefined,
                bodyComponent: s.bodyComponent, bodyProps: s.bodyProps,
                image: s.image, progress: s.progress,
                sound: s.sound === undefined ? "default" : s.sound,
                breakDnd: s.breakDnd === true, resident: s.resident === true, persist: s.persist !== false, kept: s.kept === true
            });
        }
        // No service: notify-send. A time of the urgency's own, as the service would give it.
        const u = s.urgency === undefined ? "normal" : s.urgency;
        let ms = s.timeoutMs;
        if (ms === undefined)
            ms = u === "critical" ? 0 : (u === "low" ? 4000 : 8000);
        else if (ms < 0)
            ms = 0;
        root._notifier.notify(key, {
            title: s.title === undefined ? "" : s.title, body: s.body === undefined ? "" : s.body,
            urgency: u, timeoutMs: ms,
            actions: acts.map(a => ({ id: a.id, label: a.label }))
        });
        return "";
    }

    // A later change to a record this source posted (the service's `update`: the words, the progress, `bodyProps` -- a
    // loaded rich body is re-fed). False when the record is gone (or there is no service).
    function update(uid, patch) {
        return !!root.bus && uid !== "" && root.bus.update(uid, patch);
    }

    function withdraw(key) {
        delete root._handlers[key];
        delete root._live[key];
        if (root.bus)
            root.bus.withdraw(root.sourceId, key);
        else
            root._notifier.withdraw(key);
    }

    function withdrawAll() {
        const ks = Object.keys(root._live);
        for (let i = 0; i < ks.length; i++)
            root.withdraw(ks[i]);
    }

    // Posted through this component and not withdrawn through it (the user may have removed the record).
    function has(key) {
        return root._live[key] === true;
    }

    property var _handlers: ({})
    property var _live: ({})

    function _fire(key, id) {
        const acts = root._handlers[key] || [];
        for (let i = 0; i < acts.length; i++)
            if (acts[i].id === id && typeof acts[i].run === "function") {
                acts[i].run();
                break;
            }
        root.acted(key, id);
    }

    function _attend() {
        if (root.bus && root.sourceId !== "")
            root.bus.attend(root.sourceId, root.attended);
    }
    onAttendedChanged: root._attend()
    Connections {
        target: NotificationBus
        function onServiceChanged() { root._attend(); }
    }

    property DesktopNotifier _notifier: DesktopNotifier {
        appName: root.appName
        sourceId: root.sourceId
        keys: root.keys.length > 0 ? root.keys : ["spare"]
        onAction: (key, id) => root._fire(key, id)
    }

    Component.onCompleted: root._attend()
}
