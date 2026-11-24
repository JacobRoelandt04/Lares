pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.UPower

// =============================================================================
// BtBatteryParts.qml -- UPower's view of the Bluetooth devices' batteries, by address (read only).
//
// BlueZ publishes one Battery1 per device and Quickshell hands it as `battery`; UPower mirrors it and adds
// what BlueZ lacks: whether it charges, and -- for headsets that report them -- a left bud, a right bud and a
// case as devices of their own. A device is ours when its native path holds the Bluetooth device's address
// as BlueZ spells it in a D-Bus path (`dev_02_AE_00_00_0B_02`); the role is read from the model / path words
// "left", "right", "case", else it is the device's main figure.
//
// Quickshell's `percentage` is 0..1 as far as its docs recall (unverified here: no UPower answer in the tool sandbox), so a
// value up to 1 is scaled and a larger one is taken as percent already.
// `byAddr` is { "AA:BB:CC:DD:EE:FF": { main, left, right, case } }, each { pct, charging }; it follows
// UPower's percentages and states (every read in the binding is a dependency). The host builds this only
// while a device is connected. UNPROVEN ON HARDWARE: no earbuds with split reports were at hand; the
// fixtures (tools/dev/bt_battery_probe.sh) hold the shape.
// =============================================================================
Item {
    id: root

    readonly property var byAddr: {
        const out = {};
        // qmllint disable missing-property
        const list = UPower.devices ? UPower.devices.values : [];
        // qmllint enable missing-property
        for (let i = 0; i < list.length; i++) {
            const d = list[i];
            const path = String(d.nativePath || "");
            const m = /dev_([0-9A-Fa-f]{2}(?:_[0-9A-Fa-f]{2}){5})/.exec(path);
            if (!m || !d.ready)
                continue;
            const addr = m[1].replace(/_/g, ":").toUpperCase();
            const words = (String(d.model || "") + " " + path).toLowerCase();
            const role = /\bleft\b|_left|\(l\)/.test(words) ? "left"
                : /\bright\b|_right|\(r\)/.test(words) ? "right"
                : /\bcase\b|_case/.test(words) ? "case" : "main";
            const e = out[addr] || (out[addr] = {});
            e[role] = { pct: d.percentage <= 1 ? d.percentage * 100 : d.percentage, charging: d.state === UPowerDeviceState.Charging };
        }
        return out;
    }
}
