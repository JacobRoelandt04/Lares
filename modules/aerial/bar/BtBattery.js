.pragma library

// =============================================================================
// BtBattery.js -- what the bar's battery stripe shows of the connected Bluetooth devices. Pure.
//
// THE RULES (one each):
//   - SEVERAL DEVICES: the stripe shows the LOWEST charge among the connected devices that report one
//     (the one that will die first is the one worth a glance); `count` says how many report.
//   - EARBUDS (a left and/or right bud reported): the device's charge is the LOWER of the buds. The case
//     never counts, and a device that reports only a case reports nothing.
//   - NO REPORT (not connected, `batteryAvailable` false and no UPower part): the device is not counted;
//     with no counted device `shown` is false and the stripe collapses (the host fades its presence).
//   - CHARGING: only UPower knows (`state` Charging); the stripe is then the charging colour, whatever the
//     level. The charging flag is that of the part the figure comes from.
//   - LEVEL: "crit" at or below CRIT percent, "low" at or below LOW, else "ok" (the host maps the level to
//     theme tokens: error / warn / the glyph's own hue).
//
// Inputs. `devices`: the Bluetooth model's devices ({ addr, connected, batteryAvailable, batteryPct 0..100 }).
// `parts`: UPower's view by upper-case address, { "AA:BB:..": { main, left, right, case } } where each is
// { pct: 0..100, charging: bool } (BtBatteryParts.qml); null/{} when UPower knows none.
// =============================================================================

var LOW = 20;
var CRIT = 10;

function _part(p) {
    return p && isFinite(p.pct) ? { pct: Math.max(0, Math.min(100, Number(p.pct))), charging: !!p.charging } : null;
}

// One device's figure: { pct, charging, name } or null when it reports none.
function deviceFigure(d, parts) {
    if (!d || !d.connected)
        return null;
    var u = parts && d.addr ? parts[String(d.addr).toUpperCase()] : null;
    var l = u ? _part(u.left) : null;
    var r = u ? _part(u.right) : null;
    var fig = null;
    if (l || r) {
        fig = (l && r) ? (r.pct < l.pct ? r : l) : (l || r);
    } else {
        var um = u ? _part(u.main) : null;
        if (d.batteryAvailable === true)
            fig = { pct: Math.max(0, Math.min(100, Number(d.batteryPct) || 0)), charging: um ? um.charging : false };
        else if (um)
            fig = um;
    }
    return fig ? { pct: fig.pct, charging: fig.charging, name: d.name || "" } : null;
}

function levelOf(pct) {
    return pct <= CRIT ? "crit" : pct <= LOW ? "low" : "ok";
}

function summary(devices, parts) {
    var rows = [];
    var low = null;
    var n = devices ? devices.length : 0;
    for (var i = 0; i < n; i++) {
        var f = deviceFigure(devices[i], parts);
        if (!f)
            continue;
        rows.push(f);
        if (!low || f.pct < low.pct)
            low = f;
    }
    if (!low)
        return { shown: false, pct: 0, fraction: 0, charging: false, level: "ok", count: 0, name: "", rows: rows };
    return { shown: true, pct: Math.round(low.pct), fraction: low.pct / 100, charging: low.charging,
             level: levelOf(low.pct), count: rows.length, name: low.name, rows: rows };
}

// The same rules on the SERVICE's device records (`bt.devices[]`: { address, name, connected, battery (-1 unknown), parts: { left, right,
// case, charging } | null }): the service has already taken the lower bud and left the case out of `battery` (AerialModel.btBattery), so
// this is the lowest connected figure; charging is the parts' flag (only UPower knows it).
function summaryOfDevs(devs) {
    var rows = [];
    var low = null;
    var n = devs ? devs.length : 0;
    for (var i = 0; i < n; i++) {
        var d = devs[i];
        if (!d || !d.connected || typeof d.battery !== "number" || !(d.battery >= 0))
            continue;
        var f = { pct: Math.max(0, Math.min(100, d.battery)), charging: !!(d.parts && d.parts.charging), name: d.name || "" };
        rows.push(f);
        if (!low || f.pct < low.pct)
            low = f;
    }
    if (!low)
        return { shown: false, pct: 0, fraction: 0, charging: false, level: "ok", count: 0, name: "", rows: rows };
    return { shown: true, pct: Math.round(low.pct), fraction: low.pct / 100, charging: low.charging,
             level: levelOf(low.pct), count: rows.length, name: low.name, rows: rows };
}
