.pragma library

// =============================================================================
// LidRules.js -- reading logind's lid, as `gdbus monitor` and `busctl` print it (the pure half of LidWatcher).
//
// The bytes (gdbus 2.88):
//
//   The name org.freedesktop.login1 is owned by :1.4
//   /org/freedesktop/login1: org.freedesktop.DBus.Properties.PropertiesChanged ('org.freedesktop.login1.Manager', {'LidClosed': <true>}, @as [])
//
// and `busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed` -> `b false`.
// Manager.LidClosed is `emits-change` (busctl introspect), so no polling is needed.
//
// A line is matched WHOLE, never by substring: another interface's PropertiesChanged can carry a `LidClosed` entry of its own
// (SleepWatcher's rule for the same reason).
// =============================================================================

var CHANGED = /^\/org\/freedesktop\/login1: org\.freedesktop\.DBus\.Properties\.PropertiesChanged \('org\.freedesktop\.login1\.Manager', \{(.*)\}, @?as \[[^\]]*\]\)$/;
var OWNED = /^The name org\.freedesktop\.login1 is owned by /;

// One monitor line -> true (lid closed) | false (lid open) | null (not a lid event).
function lidOfLine(line) {
    var m = CHANGED.exec(String(line));
    if (!m)
        return null;
    var d = /(?:^|, )'LidClosed': <(true|false)>(?:,|$)/.exec(m[1]);
    return d ? d[1] === "true" : null;
}

// The monitor's header says logind is (back) on the bus: the moment to ask for the state it has now.
function isOwnedLine(line) {
    return OWNED.test(String(line));
}

// `busctl get-property` output -> true | false | null.
function lidOfGet(text) {
    var m = /^b (true|false)\s*$/.exec(String(text));
    return m ? m[1] === "true" : null;
}

// THE RESTORE'S RAMP (a slow return to the original brightness reads as more cinematic). The panel climbs from 0 to `saved` along the OSD's own perceived-brightness ladder, EVENLY IN WHAT IT LOOKS LIKE: the
// ladder position (OsdKinds.brightnessPos / brightnessRawAt, gamma 2 by default) rises in equal steps, so the first half-second is not a
// jump from black to "nearly there" as a straight raw ramp is. `Osd` is OsdKinds.js, `max` the panel's maximum, `ladder` { gamma, step,
// floorRaw } (any field missing takes OsdKinds' default), `ms` the whole ramp, `stepMs` how often the panel is written.
// -> { raws: [raw...] strictly climbing, the last one `saved`, none below the panel's own floor rung; sleepS: seconds between writes }.
// `ms` <= 0 (or a panel with nothing to climb) is one write, at once.
function rampPlan(Osd, saved, max, ladder, ms, stepMs) {
    var full = Math.round(Number(saved));
    if (!(full > 0))
        return { raws: [], sleepS: 0 };
    var m = Math.max(1, Math.round(Number(max)));
    full = Math.min(full, m);
    var o = ladder || {};
    var rungs = Osd.brightnessRungs(m, o.gamma, o.step, o.floorRaw);
    var end = Osd.brightnessPos(full, rungs);
    var n = ms > 0 ? Math.max(2, Math.round(ms / Math.max(1, stepMs))) : 1;
    var raws = [];
    for (var i = 1; i <= n; i++) {
        var r = i === n ? full : Osd.brightnessRawAt(end * i / n, rungs);
        r = Math.min(full, r);
        if (r >= 1 && (raws.length === 0 || r > raws[raws.length - 1]))
            raws.push(r);
    }
    if (raws.length === 0 || raws[raws.length - 1] !== full)
        raws.push(full);
    return { raws: raws, sleepS: ms > 0 ? Math.round(ms / raws.length) / 1000 : 0 };
}
