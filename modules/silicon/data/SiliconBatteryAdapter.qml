pragma ComponentBehavior: Bound

import QtQuick

import "PowerMath.js" as Pm

// =============================================================================
// SiliconBatteryAdapter.qml -- silicon's battery, in the shape of BatteryData.
//
// The shell has ONE battery reader: silicon's service (`facts.battery`, the reading beat,
// the kernel's cached knobs). BatteryData reads the battery's uevent once a second, which
// the kernel answers with an ACPI call into the embedded controller (~3 ms; the EC rule in
// CLAUDE.md), so nothing in the assembled shell builds one. The OSD's BatterySource
// (the low / full card) and the lock's info band are handed this instead of a BatteryData,
// and read the same members:
//
//   percent                   0..100, 0 with no pack
//   status                    the kernel's word ("Charging", "Discharging", "Full",
//                             "Not charging"); "" with no pack (the lock's cell is then gone)
//   isCharging / isDischarging / isFull
//                             isFull is BatteryData's (status "Full", or 100 and not
//                             discharging) OR the pack standing AT ITS TARGET: plugged in
//                             and held at the charge limit ("Not charging" at 80), which the
//                             band should call full rather than "On battery"
//   chargeStalled             the kernel says Charging and nothing reaches the pack (PowerMath `stalled`): `acpi`'s "charging at zero rate".
//                             isCharging stays the kernel's word; a reader that warns about a low pack asks this too.
//   powerNowW                 the flow's size, watts, positive
//   estimatedTimeSec          seconds to full while charging, left while discharging, -1 with
//                             no estimate (silicon's smoothed figure, in seconds)
//   targetPercent             the charge the pack stops at: 100, or the limit while it is on. A reader that
//                             draws a level or holds a line takes it from here, so everything outside the
//                             popup is scaled the way the bar's track is
//   lowLine                   the charge that counts as low: PowerMath's, 15 % of the target (12 at 80) or silicon.jsonc's battery.lowAt
//   signal eventLowCharge     the pack crossed that line
//   signal eventFullyCharged  it reached its target
//   signal eventChargingStarted / eventChargingStopped
//   signal reading            ONE publication of the facts, sent after every member above is written and
//                             after the held events went out: what a reader that wants EVERY reading listens
//                             to (the battery notifications' drain average, which eases the draw by the time
//                             between readings) instead of polling or of a change signal that equal readings
//                             never send.
//
// `silicon` is a SiliconService or a SiliconMock (the same members). No sysfs read of its own.
//
// THE EVENTS WAIT FOR THE FACTS. silicon says `batteryEvent(kind)` BEFORE it publishes the
// reading the event came from (the service queues its compute behind the event), and what
// reads these signals -- the OSD's card -- asks `percent` at once: it would show the reading
// before the crossing. So the members are written from `silicon.battery` in ONE function, on
// every change of it, and an event waits for that: it is emitted right after the next
// publication, in the same call, so `percent` is the crossing's own. A publication that never
// comes (nothing changed) does not lose it: `settleMs` later it goes out anyway.
// =============================================================================
Item {
    id: root

    property var silicon: null
    // silicon.jsonc battery.lowAt: the charge that counts as low, of the target
    readonly property int lowAt: root.silicon && root.silicon.config ? root.silicon.config.battery.lowAt : 15
    // The longest an event waits for the facts to follow it.
    property int settleMs: 250

    readonly property alias percent: root._percent
    readonly property alias status: root._status
    readonly property alias powerNowW: root._powerNowW
    readonly property alias estimatedTimeSec: root._estimatedTimeSec
    readonly property bool isCharging: root._status === "Charging"
    readonly property bool isDischarging: root._status === "Discharging"
    readonly property bool chargeStalled: root._stalled
    readonly property bool isFull: root._status === "Full" || (root._percent >= 100 && !root.isDischarging) || root._atTarget
    readonly property int targetPercent: root._targetPercent
    readonly property int lowLine: Pm.lowLine({ limitPct: root._targetPercent, lowChargeThreshold: root.lowAt })

    signal eventLowCharge
    signal eventFullyCharged
    signal eventChargingStarted
    signal eventChargingStopped
    signal reading

    property int _percent: 0
    property string _status: ""
    property real _powerNowW: 0
    property bool _stalled: false
    property real _estimatedTimeSec: -1
    property bool _atTarget: false
    property int _targetPercent: 100
    property var _held: []

    // One writer: every member from one read of the facts, then whatever event was waiting.
    function _refresh() {
        const b = root.silicon ? root.silicon.battery : null;
        const present = !!b && b.present === true;
        root._percent = present ? Math.round(Number(b.pct) || 0) : 0;
        root._status = present ? String(b.status || "") : "";
        root._powerNowW = present ? Math.abs(Number(b.wattsReal) || 0) : 0;
        root._atTarget = present && b.atTarget === true;
        root._stalled = present && b.stalled === true;
        root._targetPercent = present && b.limitOn === true && Number(b.limitPct) > 0 ? Number(b.limitPct) : 100;
        let t = -1;
        if (present && root._status === "Charging" && b.minutesToFull !== null && b.minutesToFull !== undefined)
            t = Number(b.minutesToFull) * 60;
        else if (present && root._status === "Discharging" && b.minutesLeft !== null && b.minutesLeft !== undefined)
            t = Number(b.minutesLeft) * 60;
        root._estimatedTimeSec = t > 0 ? t : -1;
        root._flush();
        root.reading();
    }

    function _flush() {
        settle.stop();
        if (root._held.length === 0)
            return;
        const kinds = root._held;
        root._held = [];
        for (const k of kinds) {
            if (k === "low")
                root.eventLowCharge();
            else if (k === "full")
                root.eventFullyCharged();
            else if (k === "chargeStart")
                root.eventChargingStarted();
            else if (k === "chargeStop" || k === "chargeDone")
                root.eventChargingStopped();
        }
    }

    onSiliconChanged: root._refresh()
    Component.onCompleted: root._refresh()

    Connections {
        target: root.silicon
        ignoreUnknownSignals: true
        function onBatteryChanged() {
            root._refresh();
        }
        function onBatteryEvent(kind) {
            root._held = root._held.concat([String(kind)]);
            settle.restart();
        }
    }

    // The event that no publication followed.
    Timer {
        id: settle
        interval: root.settleMs
        onTriggered: root._flush()
    }
}
