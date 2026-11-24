pragma ComponentBehavior: Bound

import QtQuick

import "SourceGlyphs.js" as G
import "ThermalThrottle.js" as Thermal

// =============================================================================
// ThermalNotifier.qml -- the CPU is too hot to run at full speed, for a long while (source "thermal"; SOURCES.md, "Later sources").
//
// The kernel keeps, for every logical CPU, the milliseconds it was thermally throttled (sysfs
// `thermal_throttle/{core,package}_throttle_total_time_ms`; reading them is free, unlike an ACPI call into the embedded
// controller). Every `pollSec` seconds all of them are read, file by file; the first reading is the baseline. A poll is HOT
// when the longest view of the throttled time covers `minFraction` of it; hot in every poll for `sustainSec` seconds is a
// card, "The CPU is too hot to run at full speed" with how long and what share, at most one per `cooldownMin` minutes, taken
// away after `quietMin` minutes that were not hot. The EVENT counts are not read: each logical CPU counts the package's
// events on its own, so one blip is ~22 events (ThermalThrottle.js). Power-limit throttling -- a profile's or a charger's
// ceiling -- is not this card's, and no power-limit counter is read. Its button opens silicon's popup, where the temperatures
// and the profile are. `root` is the sysfs directory (a probe's fake tree).
// =============================================================================
SourceBase {
    id: src

    sourceId: "thermal"
    appName: "Thermal"
    glyph: G.thermal
    keys: ["thermal"]

    property int pollMs: src.settings.pollSec * 1000
    // The clock the polls are timed by (the probes' seam).
    property var nowFn: function () { return Date.now(); }
    property var _st: Thermal.newState()

    Timer {
        interval: Math.max(50, src.pollMs)
        running: src.active
        repeat: true
        triggeredOnStart: true
        onTriggered: src._poll()
    }

    function _poll() {
        if (!src.active)
            return;
        // `grep -H ""` names each file, so each is judged by itself (a CPU taken offline and back is not heat)
        src.host.exec.run(["sh", "-c", "cd \"$1\" 2>/dev/null && grep -H \"\" cpu[0-9]*/thermal_throttle/*_throttle_total_time_ms 2>/dev/null", "sh", src.settings.root], (code, out) => {
            if (src.active)
                src._read(Thermal.parse(out));
        });
    }

    function _read(times) {
        const s = src.settings;
        const r = Thermal.step(src._st, times, src.nowFn(), s);
        if (r.clear)
            src.withdraw("thermal");
        if (r.fire) {
            const t = Thermal.text(r.share, r.runSec);
            src.post("thermal", {
                title: t.title, body: t.body, urgency: "normal",
                actions: [{ id: "open", label: "Open", run: () => src.host.open("silicon") }],
                onDefault: () => src.host.open("silicon")
            });
        }
    }

    onActivated: {
        src._st = Thermal.newState();
    }
}
