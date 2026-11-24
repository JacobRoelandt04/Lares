pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// OsdBus.qml -- where the shell's ONE OsdService is found.
//
// Anything that wants the on-screen display (silicon, a module's own event)
// looks here, the way emitters look at NotificationBus: with `service` set
// the request goes to the OSD, without it `show` answers false and the caller
// keeps its own path (a notification, a log line). Only an OsdService writes
// `service` (its `registerOnBus`), and it clears it again when it goes away,
// so a stale pointer is never left behind.
//
//   show(req) -> bool   false = no service, or the kind's route is not "osd"
//                       (the caller falls back). A request without a `kind` is
//                       silicon's planned shape {source, key, glyph, title,
//                       detail, colorToken, ms} and is treated as kind
//                       "generic" (disabled in config until the user enables
//                       it, so it answers false by default).
// =============================================================================
Singleton {
    id: root

    property var service: null

    function show(req) {
        const s = root.service;
        if (!s || !req)
            return false;
        const r = Object.assign({}, req);
        if (r.kind === undefined || r.kind === null || r.kind === "")
            r.kind = "generic";
        // A bus request's source reads "bus:<who asked>".
        const who = r.source === undefined || r.source === null ? "" : String(r.source);
        r.source = who.indexOf("bus:") === 0 ? who : "bus:" + who;
        return s.show(r);
    }
}
