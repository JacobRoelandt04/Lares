pragma ComponentBehavior: Bound

import QtQuick
import "AerialModel.js" as Model

// =============================================================================
// AerialToasts.qml -- every aerial error as ONE notification toast (round 2: nothing persists in the popup).
//
// Built by AerialService and AerialMock (the same member, so the two post alike). `notifier` is a DesktopNotifier the shell hands
// down (ShellServices): null = no toasts (a mockup, a probe that does not look). Never a second notification server.
//
//   post(rec)    the failure's toast: the words of `Model.toastWords` (what went wrong, the way out, an action when there is one),
//                under the KEY "fail-<error id>", so a REPEAT of the same error REPLACES its toast and never piles up.
//                A repeat with the SAME words while the error still stands and within `quietMs` is not told again (a toast the
//                user dismissed stays gone for that failure); different words, a cleared error or a later one are told.
//   sync(errors) the cause is gone (pruned, dismissed): its toast is withdrawn and its memory forgotten.
//
// A shell post's action click CONSUMES the record before its callback, so the action runs from the notifier's `action` signal
// and the toast is not expected to survive it. Actions: "portal" -> host.openPortal().
// =============================================================================
Item {
    id: root
    visible: false

    property var notifier: null
    // the service (or its mock): the facts the words read, and the intent an action runs
    property var host: null
    property int quietMs: 60000
    // what was told: { id: { text, atMs } }; a plain object mutated in place (nothing binds it)
    property var _told: ({})
    // the toasts a probe counts: every notify() call, newest last (a var object: not a dependency)
    property var log: ({ posts: [], withdraws: [] })
    // A toast's body was clicked: the host opens the network popup.
    signal openRequested

    function _facts() {
        const h = root.host;
        return h ? { health: h.health, bt: h.bt, wifi: h.wifi, proton: h.proton } : {};
    }

    function post(rec: var): void {
        const now = Date.now();
        const was = root._told[rec.id];
        root._told[rec.id] = { text: rec.text, atMs: was && was.text === rec.text && now - was.atMs < root.quietMs ? was.atMs : now };
        if (was && was.text === rec.text && now - was.atMs < root.quietMs)
            return;
        const w = Model.toastWords(rec, root._facts());
        // a click on the toast's body opens the network popup, as every module's toast opens its own
        const spec = { title: w.title, body: w.body, urgency: "normal", onDefault: () => root.openRequested() };
        if (w.action === "portal")
            spec.actions = [{ id: "portal", label: "Open the login page" }];
        root.log.posts.push({ key: w.key, title: w.title, body: w.body, action: w.action });
        if (root.notifier)
            root.notifier.notify(w.key, spec);
    }

    function sync(errors: var): void {
        const have = {};
        const es = errors || [];
        for (let i = 0; i < es.length; i++)
            have[es[i].id] = true;
        for (const id in root._told) {
            if (have[id] === true)
                continue;
            delete root._told[id];
            root.log.withdraws.push(Model.toastKey(id));
            if (root.notifier)
                root.notifier.withdraw(Model.toastKey(id));
        }
    }

    Connections {
        target: root.notifier
        function onAction(key: string, id: string): void {
            if (key.indexOf("fail-") === 0 && id === "portal" && root.host)
                root.host.openPortal();
        }
    }
}
