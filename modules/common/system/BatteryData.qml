pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

// =============================================================================
// BatteryData.qml
//
// The battery as numbers: /sys/class/power_supply/BAT0/uevent polled once a
// second, smoothed watts for the time estimate, and four transition signals
// for the event animations.
//
// `polling: false` makes this a MOCK: nothing is read, every property is
// writable from outside, and the signals can be emitted by hand. The mockup's
// mock source is exactly that.
//
// The charge limit is NOT here: ChargeLimitData owns that file, and two
// objects polling the same sysfs file on two cadences would cost two reads a
// poll to learn one number.
// =============================================================================
Item {
    id: root

    // ---- Configuration ----------------------------------------------------
    property string batteryPath: "/sys/class/power_supply/BAT0"
    property int pollIntervalMs: 1000
    property bool polling: true

    // The timestamp of the last time the battery reached full, as unix ms in a
    // plain text file. Read on startup, written when a charge reaches 100.
    property string lastFullStatePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/lares/battery/last-full"

    // Smoothing for the time estimate: the last N watt samples, with a
    // SUSTAINED spike left out. Opening the popup is itself a spike (the
    // particles cost power), and an estimate that drops the moment you look at
    // it is an estimate of the popup, not of the battery.
    property int smoothingWindow: 30
    property real spikeThresholdW: 8
    property int spikeMinDurationMs: 20000

    property int lowChargeThreshold: 15

    // ---- Raw state --------------------------------------------------------
    property int percent: 0
    property string status: ""
    property int cycleCount: 0
    property real energyNowWh: 0
    property real energyFullWh: 0
    property real energyFullDesignWh: 0
    property real powerNowW: 0

    // ---- Derived ----------------------------------------------------------
    readonly property bool isCharging: root.status === "Charging"
    readonly property bool isDischarging: root.status === "Discharging"
    readonly property bool isFull: root.status === "Full" || (root.percent >= 100 && !root.isDischarging)
    // Positive while charging, negative while discharging, 0 otherwise.
    readonly property real condition: root.energyFullDesignWh > 0 ? (root.energyFullWh / root.energyFullDesignWh) : 1.0

    property real smoothedWatts: 0
    readonly property real estimatedTimeSec: {
        if (root.smoothedWatts <= 0.1)
            return -1;
        if (root.isCharging && root.energyFullWh > 0)
            return ((root.energyFullWh - root.energyNowWh) * 3600) / root.smoothedWatts;
        if (root.isDischarging && root.energyNowWh > 0)
            return (root.energyNowWh * 3600) / root.smoothedWatts;
        return -1;
    }

    property real lastFullTimestampMs: 0
    // The clock the "hours ago" figure is read against. `Date.now()` inside a
    // binding is a method call, not a property, so the binding captures
    // nothing and the figure would stand still from the moment it was computed. A
    // property ticked by the poll is the dependency; a mock ticks it by hand.
    property real now: Date.now()

    // ---- Events -----------------------------------------------------------
    signal eventFullyCharged
    signal eventLowCharge
    signal eventChargingStarted
    signal eventChargingStopped

    // ---- Internal ---------------------------------------------------------
    property var _wattsHistory: []
    property real _spikeStartTime: 0
    property bool _inSpike: false
    property int _lastPercent: -1

    // READ, DO NOT FORK. sysfs through a FileView is a read(), where a `cat`
    // per poll would be ~115,000 processes a day for a file that barely moves
    // (2.2 % of a core with the mockup idle). This uevent reports a size (4096)
    // and reads whole.
    // `blockLoading` because the text is read straight after `reload()`.
    FileView {
        id: ueventFile
        path: root.batteryPath + "/uevent"
        blockLoading: true
        // no battery on this machine: no status, and no warning at every poll
        printErrors: false
    }
    FileView {
        id: lastFullFile
        path: root.lastFullStatePath
        blockLoading: true
        printErrors: false
    }

    Timer {
        interval: root.pollIntervalMs
        running: root.polling
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            ueventFile.reload();
            const t = ueventFile.text();
            if (t.length > 0)
                root._parseUevent(t);
            root.now = Date.now();
        }
    }

    Component.onCompleted: {
        const v = parseInt(lastFullFile.text().trim(), 10);
        if (!isNaN(v) && v > 0)
            root.lastFullTimestampMs = v;
    }

    function _parseUevent(body) {
        const kv = {};
        const lines = body.split("\n");
        for (let i = 0; i < lines.length; i++) {
            const idx = lines[i].indexOf("=");
            if (idx >= 0)
                kv[lines[i].substring(0, idx)] = lines[i].substring(idx + 1);
        }

        const prevStatus = root.status;
        root.status = kv.POWER_SUPPLY_STATUS || "";
        root.percent = parseInt(kv.POWER_SUPPLY_CAPACITY || "0", 10);
        root.cycleCount = parseInt(kv.POWER_SUPPLY_CYCLE_COUNT || "0", 10);
        root.energyNowWh = parseInt(kv.POWER_SUPPLY_ENERGY_NOW || "0", 10) / 1e6;
        root.energyFullWh = parseInt(kv.POWER_SUPPLY_ENERGY_FULL || "0", 10) / 1e6;
        root.energyFullDesignWh = parseInt(kv.POWER_SUPPLY_ENERGY_FULL_DESIGN || "0", 10) / 1e6;
        root.powerNowW = parseInt(kv.POWER_SUPPLY_POWER_NOW || "0", 10) / 1e6;

        root._updateSmoothedWatts();
        root._handleTransitions(prevStatus);
    }

    function _updateSmoothedWatts() {
        const w = root.powerNowW;
        const baseline = root._wattsHistory.length > 0 ? root.smoothedWatts : w;
        if (w - baseline > root.spikeThresholdW) {
            if (!root._inSpike) {
                root._inSpike = true;
                root._spikeStartTime = Date.now();
            }
            if (Date.now() - root._spikeStartTime < root.spikeMinDurationMs)
                return;
        } else {
            root._inSpike = false;
        }

        const h = root._wattsHistory;
        h.push(w);
        if (h.length > root.smoothingWindow)
            h.shift();
        let sum = 0;
        for (let i = 0; i < h.length; i++)
            sum += h[i];
        root.smoothedWatts = sum / h.length;
    }

    function _handleTransitions(prevStatus) {
        if (prevStatus !== "" && prevStatus !== root.status) {
            if (root.status === "Charging")
                root.eventChargingStarted();
            else if (prevStatus === "Charging")
                root.eventChargingStopped();
        }

        // Fully charged: the percent has to CROSS into 100 with next to no
        // power flowing. Gating on the status alone would replay the animation on
        // every Full <-> Not charging flap the charge limit causes at 100 %.
        if (root._lastPercent >= 0 && root._lastPercent < 100 && root.percent >= 100 && Math.abs(root.powerNowW) < 0.5) {
            root.lastFullTimestampMs = Date.now();
            Quickshell.execDetached(["sh", "-c", "mkdir -p \"$(dirname \"$1\")\" && echo \"$2\" > \"$1\"", "sh", root.lastFullStatePath, root.lastFullTimestampMs.toString()]);
            root.eventFullyCharged();
        }

        if (root._lastPercent >= 0 && root._lastPercent > root.lowChargeThreshold && root.percent <= root.lowChargeThreshold)
            root.eventLowCharge();
        root._lastPercent = root.percent;
    }

    function formatTime(sec) {
        if (sec < 0)
            return "—";
        const h = Math.floor(sec / 3600);
        const m = Math.floor((sec % 3600) / 60);
        return h > 0 ? (h + "h " + m + "m") : (m + "m");
    }
}
