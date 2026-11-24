pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Wayland

import "../../common/components"
import "../../common/components/JsonComments.js" as JsonComments
import "../../common/system"

// =============================================================================
// BreakClock.qml -- the shell's ONE break nudge (created on first read: ClockBarOwner hands it to its Workspaces as `breakSource`), whatever the number of
// screens. It follows the compositor's idle notification (IdleMonitor, ext-idle-notify, `respectInhibitors: false` -- a
// playing video holds an inhibitor and is not a break), the Sleep singleton's resume and a host-written `locked`, and hands
// the rail `fills` and `filled()` (BreakModel has the rules).
//
// config/breaks.jsonc (hand-edited, read hot; .examples/breaks.jsonc): enabled, durationMin, pauseMin, idleGraceSec, rewindPower,
// stepSec, stepEaseMs, hiddenMin. The IdleMonitor's timeout is idleGraceSec (an idle shorter than that is use); the longer spans
// are rewound by BreakModel's curve, whatever caused them (idle, lock, suspend).
// `live: false` (a mock, a probe) starts no IdleMonitor and reads no file; `apply(obj)` stands in for the file.
// =============================================================================
Singleton {
    id: root

    // Off in a mock shell (SHELL_SERVICES=mock) and under LARES_BREAK_LIVE=0: no IdleMonitor, no fill at all, so no pixel gate sees it.
    property bool live: Quickshell.env("SHELL_SERVICES") !== "mock" && Quickshell.env("LARES_BREAK_LIVE") !== "0"
    // Written by the shell: the session is locked (a lock is an idle span from the lock to the unlock).
    property bool locked: false
    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/quickshell/config/breaks.jsonc"

    readonly property var fills: model.fills
    readonly property bool full: model.full
    signal filled

    property var _raw: ({})
    readonly property bool enabled: root._raw.enabled !== false
    readonly property real durationMin: root._num(root._raw.durationMin, 50, 1, 600)
    readonly property real pauseMin: root._num(root._raw.pauseMin, 5, 0.1, 120)
    readonly property real idleGraceSec: root._num(root._raw.idleGraceSec, 30, 1, 3600)
    readonly property real rewindPower: root._num(root._raw.rewindPower, 2, 0.25, 8)
    readonly property real stepSec: root._num(root._raw.stepSec, 60, 1, 3600)
    readonly property real stepEaseMs: root._num(root._raw.stepEaseMs, 700, 0, 5000)
    readonly property real hiddenMin: root._num(root._raw.hiddenMin, 10, 0, root.durationMin * 0.9)
    function _num(v, d, lo, hi): real {
        return (typeof v === "number" && isFinite(v)) ? Math.max(lo, Math.min(hi, v)) : d;
    }
    function apply(obj): void {
        root._raw = obj || {};
    }
    function _parse(txt): void {
        const t = (txt === undefined || txt === null) ? "" : String(txt);
        if (t.trim().length === 0) {
            root._raw = {};
            return;
        }
        try {
            const o = JSON.parse(JsonComments.strip(t));
            if (o && typeof o === "object" && !Array.isArray(o))
                root._raw = o;
        } catch (e) {
            console.warn("BreakClock: breaks.jsonc does not parse -- the previous settings are kept");
        }
    }

    ConfigFile {
        id: cfg
        path: root.configPath
        watchChanges: root.live
        onLoaded: if (root.live) root._parse(cfg.text())
        onLoadFailed: if (root.live) root._raw = {}
    }

    BreakModel {
        id: model
        armed: root.enabled && root.live
        durationS: root.durationMin * 60
        pauseS: root.pauseMin * 60
        graceS: root.idleGraceSec
        rewindPower: root.rewindPower
        stepS: root.stepSec
        easeMs: root.stepEaseMs
        hiddenS: root.hiddenMin * 60
        locked: root.locked
        idle: monitor.isIdle
        onFilled: root.filled()
    }
    IdleMonitor {
        id: monitor
        enabled: root.live
        timeout: root.idleGraceSec
        respectInhibitors: false
    }
    Connections {
        target: Sleep.watcher
        ignoreUnknownSignals: true
        function onAboutToSleep() { model.sleepBegan(); }
        function onResumed() { model.resume(); }
    }
    Component.onCompleted: if (root.live) root._parse(cfg.text())
}
