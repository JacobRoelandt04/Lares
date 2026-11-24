.pragma library

// =============================================================================
// UpowerParse.js -- UPower's charge history, as silicon reads it. Pure, no Qt; tools/dev/fixtures/silicon/upower/ keeps a REAL
// answer byte for byte.
//
// WHY. The kernel keeps no "when was the pack last full". The service records the moment itself, but only while it runs.
// UPower is a daemon that runs all day and keeps the pack's charge history -- a week or more of points, each
// with the pack's STATE -- and answers it to anyone, read-only:
//
//   gdbus call --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower/devices/battery_BAT0
//        --method org.freedesktop.UPower.Device.GetHistory charge <seconds back> <points>
//
// WHAT THE REAL ANSWER IS (captured on this machine, UPower 1.91.4; the interface document is wrong about the order):
//   ([(uint32 1791479632, 100.0, uint32 4), (1791478939, 99.0, 1), (1791478549, 98.0, 1), ...],)
//   * an array of (time in seconds, charge in %, state); the first tuple carries `uint32` annotations and the rest do
//     not (GVariant prints a type once, where it cannot be told from the first element);
//   * with a time span it comes NEWEST FIRST, with a span of 0 ("all") OLDEST FIRST: nothing here relies on the order;
//   * the states: 0 unknown, 1 charging, 2 discharging, 3 empty, 4 fully-charged, 5 pending-charge, 6 pending-discharge;
//   * the points are UPower's RAW items while there are no more of them than the `points` asked for (about one per
//     percent); with fewer asked, it merges neighbours and a merged point may lose its state (a newest point of state 0
//     where the raw one was 4), so silicon asks for more than a week can hold;
//   * an upowerd start leaves a (0.0, state 0) item beside the pack's own: state 0 says nothing about the pack;
//   * a history that is empty is `(@a(udu) [],)`; an error is a line on stderr and exit 1 (`Error: GDBus.Error:...`).
//
//   historyArgv(gdbus, batteryPath, secondsBack, points)   the one command line that is ever run
//   deviceName(batteryPath)                                /sys/class/power_supply/BAT0 -> battery_BAT0
//   parseHistory(text)                                     gdbus's printed answer -> { ok, items [{ ms, pct, state }], why }
//   lastFull(items)                                        -> { found, reachedMs, leftMs, ms }
//   failureWhy(code, stderr)                               a stated reason for a call that did not answer
// =============================================================================

var DEST = "org.freedesktop.UPower";
var DEVICE_IFACE = "org.freedesktop.UPower.Device";
var DEVICES = "/org/freedesktop/UPower/devices/";

var STATE_UNKNOWN = 0;
var STATE_FULL = 4;
var STATE_PENDING_CHARGE = 5;
// A pack held at the charge limit is "pending-charge" at the limit's percentage (80: the firmware stops and restarts charging
// at 80/80, docs/silicon.md, the battery notes); a pending-charge point lower down is a plug-in that has not started charging yet (a captured week
// has exactly one, 77.0, followed 72 s later by a charging point at 78): a threshold of 75 would count it as a full pack.
// 78 is the limit less two for the percentage's own rounding, and clears it.
var HELD_MIN_PCT = 78;

// UPower's object name for a battery: its sysfs name, anything that is not a letter, a digit or `_` made `_`
// (UPower does the same to build the path), after `battery_`. "" for no name.
function deviceName(batteryPath) {
    var p = String(batteryPath === undefined || batteryPath === null ? "" : batteryPath).replace(/\/+$/, "");
    var base = p.substring(p.lastIndexOf("/") + 1).replace(/[^A-Za-z0-9_]/g, "_");
    return base === "" ? "" : "battery_" + base;
}

// The only call silicon ever makes to UPower: a read. null when there is no battery to ask about.
function historyArgv(gdbus, batteryPath, secondsBack, points) {
    var name = deviceName(batteryPath);
    if (name === "")
        return null;
    return [gdbus, "call", "--system", "--dest", DEST, "--object-path", DEVICES + name,
            "--method", DEVICE_IFACE + ".GetHistory", "charge", String(Math.round(secondsBack)), String(Math.round(points))];
}

// gdbus's printed answer -> the points, in the order given. `ok` is false for anything that is not that array.
var _TUPLE = /\(\s*(?:uint32\s+)?(\d+)\s*,\s*(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)\s*,\s*(?:uint32\s+)?(\d+)\s*\)/g;
function parseHistory(text) {
    var t = String(text === undefined || text === null ? "" : text);
    if (!/^\s*\(\s*(?:@a\(udu\)\s*)?\[/.test(t))
        return { ok: false, items: [], why: "UPower's answer was not a history" };
    var items = [];
    var m;
    _TUPLE.lastIndex = 0;
    while ((m = _TUPLE.exec(t)) !== null)
        items.push({ ms: parseInt(m[1], 10) * 1000, pct: parseFloat(m[2]), state: parseInt(m[3], 10) });
    return { ok: true, items: items, why: "" };
}

// A point at which UPower had the pack full: fully-charged, or pending-charge near the limit (held there).
function isFull(it) {
    return it.state === STATE_FULL || (it.state === STATE_PENDING_CHARGE && it.pct >= HELD_MIN_PCT);
}

// When the pack was last full, from the points (any order).
//   reachedMs  the newest point at which it was full
//   leftMs     the first real point AFTER that (state 0 is no observation of the pack): the pack stopped being full by
//              then, at the latest -- 0 when nothing came after it
//   ms         the moment to count from: leftMs when there is one, else reachedMs. A pack that sat full for four hours
//              and was then unplugged was last full when it was unplugged, not when it first got there: UPower writes a
//              point on a CHANGE, so the full point stands for the whole stretch and the point after it ends it.
//   found      whether the history had the pack full at all (ms is 0 when not)
function lastFull(items) {
    var list = items || [];
    var reached = 0;
    var i;
    for (i = 0; i < list.length; i++) {
        if (isFull(list[i]) && list[i].ms > reached)
            reached = list[i].ms;
    }
    if (reached === 0)
        return { found: false, reachedMs: 0, leftMs: 0, ms: 0 };
    var left = 0;
    for (i = 0; i < list.length; i++) {
        if (list[i].state !== STATE_UNKNOWN && list[i].ms > reached && (left === 0 || list[i].ms < left))
            left = list[i].ms;
    }
    return { found: true, reachedMs: reached, leftMs: left, ms: left > 0 ? left : reached };
}

// gdbus failed: why, in a line (what the user could be told). `stderr` is gdbus's, whatever it said.
function failureWhy(code, stderr) {
    var first = String(stderr === undefined || stderr === null ? "" : stderr).split("\n")[0].trim();
    var detail = first.replace(/^Error:\s*/, "").replace(/^GDBus\.Error:/, "").replace(/^[\w.]+:\s*/, "").trim();
    if (/ServiceUnknown|not activatable|not provided by any/.test(first))
        return "UPower is not running" + (detail !== "" ? " (" + detail + ")" : "");
    if (/does not support getting history/.test(first))
        return "UPower keeps no charge history for this battery";
    if (/UnknownMethod|Object does not exist|UnknownObject/.test(first))
        return "UPower does not know this battery";
    if (/NoReply|Timeout|timed out/i.test(first))
        return "UPower did not answer";
    return detail !== "" ? "UPower: " + detail : "UPower's call failed (exit " + code + ")";
}
