pragma ComponentBehavior: Bound

import QtQuick
import "UpowerParse.js" as Up
import "../../common/system"

// =============================================================================
// UpowerHistory.qml -- when UPower's charge history last had the pack full. The kernel has no such value;
// UPower, which runs all day, keeps the pack's charge history with its states and answers it read-only (UpowerParse.js
// has the call, the answer and what it means). This is the one reader of it:
//
//   lastFullMs   the moment to count the since-full display from: the point that ended the newest full stretch, else the
//                newest full point itself (UpowerParse.lastFull); 0 = the history never had the pack full, or has not been read
//   ok / why     the last ask got an answer (an EMPTY history is an answer) / why it could not: gdbus not installed,
//                UPower not running, no history for this battery, no answer in time. "" while nothing has been asked
//   changed()    lastFullMs, ok or why moved
//
// WHEN IT ASKS. Never on a timer of its own: at start and after a battery event (`refresh(true)`, `refreshSoon()`, the
// service's), and for the popup at most every `minGapMs` (10 min) while it is open (`refresh(false)` on opening, and a
// timer that runs only while open). One ask at a time, in a ProcLane; an ask that finds one in flight is made when that
// one ends if it was forced. A call that fails keeps the last good answer and says why.
//
// QUIET. gdbus is looked for with `command -v` before it is started: a Process whose program does not exist reports
// neither a start nor an exit and warns in the log, so a missing binary is a stated reason instead. The call is only the
// read UpowerParse.historyArgv builds, on the system bus (UPower is nowhere else); a probe's `gdbus` is a stub that
// answers from a fixture, byte for byte as the real one does.
// =============================================================================
Item {
    id: root

    property string gdbus: "gdbus"
    property string batteryPath: ""            // /sys/class/power_supply/BAT0 -> UPower's battery_BAT0
    property bool popupOpen: false
    property int secondsBack: 604800           // a week; UPower keeps about that much or more
    property int points: 5000                  // more than a week can hold, so UPower returns its raw points (see UpowerParse)
    property int minGapMs: 600000              // popup-driven asks come no closer than this
    property int eventDelayMs: 2000            // after a battery event UPower has the point written within a moment
    property int timeoutMs: 8000

    readonly property real lastFullMs: root._ms
    readonly property bool ok: root._ok
    readonly property string why: root._why
    readonly property bool busy: lane.busy || root._checking
    // for the probes: the asks made so far
    readonly property int asks: root._asks

    signal changed

    // Ask now (`force`), or if the last ask is older than `minGapMs`. -> whether an ask was started.
    function refresh(force) {
        if (!root._ready) {
            // (a parent's Component.onCompleted runs before its children's: the ask is made once this one has completed)
            root._early = root._early === "force" || force === true ? "force" : "ask";
            return false;
        }
        const now = Date.now();
        // (a tenth of slack: the periodic timer fires `minGapMs` after the ask that started it, give or take a few ms)
        if (force !== true && root._lastAskMs > 0 && now - root._lastAskMs < root.minGapMs * 0.9)
            return false;
        if (root._inFlight) {
            if (force === true)
                root._again = true;
            return false;
        }
        root._start(now);
        return true;
    }

    // A battery event happened (full, chargeStop): ask once UPower has had time to write it.
    function refreshSoon() {
        soon.restart();
    }

    // ---- Private -----------------------------------------------------------------
    property bool _ready: false
    property string _early: ""                 // "" | "ask" | "force": what was asked before this item had completed
    property bool _inFlight: false
    property bool _checking: false
    property bool _again: false
    property real _lastAskMs: 0
    property int _asks: 0
    property real _ms: 0
    property bool _ok: false
    property string _why: ""

    ProcLane { id: lane; timeoutMs: root.timeoutMs }

    Timer { id: soon; interval: root.eventDelayMs; onTriggered: root.refresh(true) }
    Timer {
        interval: root.minGapMs
        repeat: true
        running: root.popupOpen && root._ready
        onTriggered: root.refresh(false)
    }

    onPopupOpenChanged: {
        if (root.popupOpen)
            root.refresh(false);
    }
    onBatteryPathChanged: {
        if (root._ready)
            root.refresh(true);
    }
    Component.onCompleted: {
        root._ready = true;
        const early = root._early;
        root._early = "";
        if (early !== "")
            root.refresh(early === "force");
    }

    function _start(now) {
        const argv = Up.historyArgv(root.gdbus, root.batteryPath, root.secondsBack, root.points);
        root._lastAskMs = now;
        if (argv === null) {
            root._settle(false, "There is no battery to ask UPower about", null);
            return;
        }
        root._inFlight = true;
        root._asks++;
        root._checking = true;
        lane.run(["sh", "-c", "command -v \"$1\" > /dev/null 2>&1", "sh", root.gdbus], function (res) {
            root._checking = false;
            if (res.code !== 0) {
                root._settle(false, "gdbus is not installed (" + root.gdbus + "), so UPower's charge history cannot be read", null);
                return;
            }
            lane.run(argv, function (r) {
                if (r.timedOut) {
                    root._settle(false, "UPower did not answer in " + (root.timeoutMs / 1000) + " s", null);
                } else if (r.code !== 0) {
                    root._settle(false, Up.failureWhy(r.code, r.err), null);
                } else {
                    const p = Up.parseHistory(r.out);
                    root._settle(p.ok, p.why, p.ok ? Up.lastFull(p.items) : null);
                }
            });
        });
    }

    function _settle(ok, why, full) {
        root._inFlight = false;
        const ms = full !== null ? full.ms : root._ms;       // a failed ask keeps the last good answer
        const moved = ms !== root._ms || ok !== root._ok || (ok ? "" : why) !== root._why;
        root._ms = ms;
        root._ok = ok;
        root._why = ok ? "" : why;
        if (moved)
            root.changed();
        if (root._again) {
            root._again = false;
            Qt.callLater(function () { root.refresh(true); });
        }
    }
}
