.pragma library

// =============================================================================
// SysfsParse.js -- what the silicon data layer reads out of /proc and /sys, as
// PLAIN VALUES. Pure functions: nothing here opens a file or starts a process;
// SysfsPoller / NvidiaSmi / OverheadMeter hand the text in. No Qt, loadable
// under node.
//
//   parseProcStat(text)            /proc/stat -> { all: {busy,total}, cpus: {id: {busy,total}} }
//   cpuLoads(prev, cur)            per-CPU load 0..1 between two snapshots
//   totalLoad(prev, cur)           the aggregate 0..1
//   cpuList("0-11,14")             -> [0..11, 14]
//   topologyGroups(topo)           the package's cores in the SCENE's order
//   coreLoads(groups, loads)       [{kind, load}] x cores, the order of `cores`
//   meanFreqMHz(khzList)           the clock figure
//   rc6Busy(prevMs, curMs, dtMs)   the iGPU's busy share from rc6_residency_ms
//   parseMeminfo(text)             /proc/meminfo -> { totalKiB, availableKiB, usedFraction }
//   parseFdinfo(text)              a DRM client's engine time
//   parseNvidiaSmi(text)           the one CSV line the readout asks for
//   NVIDIA_SMI_FIELDS              the --query-gpu list that line answers
//   (the display connectors moved to modules/common/system/DrmRules.js)
//
// A reader never throws and never guesses: a text that is not the shape comes
// back as null / an empty list, and the caller keeps what it had.
// =============================================================================

function toInt(s, dflt) {
    var n = parseInt(String(s === undefined || s === null ? "" : s).trim(), 10);
    return isNaN(n) ? dflt : n;
}

function toNum(s, dflt) {
    var t = String(s === undefined || s === null ? "" : s).trim();
    if (t === "" || /^\[.*\]$/.test(t) || /^n\/a$/i.test(t))
        return dflt;
    var n = Number(t);
    return isFinite(n) ? n : dflt;
}

// "0-11,14,16-17" (the kernel's cpulist format) -> sorted unique ids. Junk is dropped.
function cpuList(s) {
    var out = [];
    var seen = {};
    var parts = String(s === undefined || s === null ? "" : s).trim().split(",");
    for (var i = 0; i < parts.length; i++) {
        var m = /^\s*(\d+)(?:\s*-\s*(\d+))?\s*$/.exec(parts[i]);
        if (!m)
            continue;
        var a = parseInt(m[1], 10);
        var b = m[2] === undefined ? a : parseInt(m[2], 10);
        if (b < a || b - a > 4096)
            continue;
        for (var k = a; k <= b; k++) {
            if (!seen[k]) {
                seen[k] = true;
                out.push(k);
            }
        }
    }
    out.sort(function (x, y) { return x - y; });
    return out;
}

// --- /proc/stat -----------------------------------------------------------------
//
//   cpu  107624 2 40624 11153803 39582 17927 4287 0 0 0
//   cpu0 1609 0 897 511120 1638 368 656 0 0 0
//
// user nice system idle iowait irq softirq steal guest guest_nice. busy = everything but idle
// and iowait; guest time is already inside user and nice, so it is not added twice.
function parseProcStat(text) {
    var out = { all: null, cpus: {} };
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var m = /^cpu(\d*)\s+(.*)$/.exec(lines[i]);
        if (!m)
            continue;
        var f = m[2].trim().split(/\s+/).map(function (x) { return parseInt(x, 10); });
        if (f.length < 4 || f.some(function (x) { return isNaN(x); }))
            continue;
        var idle = f[3] + (f.length > 4 ? f[4] : 0);
        var busy = f[0] + f[1] + f[2] + (f.length > 5 ? f[5] : 0) + (f.length > 6 ? f[6] : 0) + (f.length > 7 ? f[7] : 0);
        var rec = { busy: busy, total: busy + idle };
        if (m[1] === "")
            out.all = rec;
        else
            out.cpus[m[1]] = rec;
    }
    return out;
}

function _frac(a, b) {
    var dt = b.total - a.total;
    if (!(dt > 0))
        return null;
    var v = (b.busy - a.busy) / dt;
    return v < 0 ? 0 : (v > 1 ? 1 : v);
}

// Per-CPU load 0..1 between two parseProcStat snapshots; a CPU missing from either, or with no
// time elapsed, is left out (the caller keeps its last figure).
function cpuLoads(prev, cur) {
    var out = {};
    if (!prev || !cur)
        return out;
    var ids = Object.keys(cur.cpus);
    for (var i = 0; i < ids.length; i++) {
        var a = prev.cpus[ids[i]];
        if (!a)
            continue;
        var v = _frac(a, cur.cpus[ids[i]]);
        if (v !== null)
            out[ids[i]] = v;
    }
    return out;
}

function totalLoad(prev, cur) {
    if (!prev || !cur || !prev.all || !cur.all)
        return null;
    return _frac(prev.all, cur.all);
}

// --- the package's cores ---------------------------------------------------------
//
// topo = { core: [ids], atom: [ids], l3: { id: true|false }, siblings: { id: [ids] } }
//   core / atom    sysfs devices/cpu_core/cpus and devices/cpu_atom/cpus (the hybrid PMUs)
//   l3             the CPU has cache/index3 -- the LPE cores on the SoC tile have none
//   siblings       topology/thread_siblings_list
// -> [{ kind: "P"|"E"|"LPE", cpus: [ids] }]: P cores first (one entry per sibling set,
// by lowest CPU), then E, then LPE -- the order of SceneGeometry.CORES, which is the order of
// the service's `cores` array. A CPU in neither PMU list is taken as a P core when it has an
// SMT sibling and as an E core when it has none (a kernel without the hybrid PMUs).
function topologyGroups(topo) {
    var core = (topo && topo.core) || [];
    var atom = (topo && topo.atom) || [];
    var l3 = (topo && topo.l3) || {};
    var sib = (topo && topo.siblings) || {};
    var ids = [];
    var seen = {};
    var lists = [core, atom, Object.keys(sib).map(function (k) { return parseInt(k, 10); })];
    for (var l = 0; l < lists.length; l++) {
        for (var i = 0; i < lists[l].length; i++) {
            if (!seen[lists[l][i]]) {
                seen[lists[l][i]] = true;
                ids.push(lists[l][i]);
            }
        }
    }
    ids.sort(function (x, y) { return x - y; });
    var kindOf = function (id) {
        if (core.indexOf(id) >= 0)
            return "P";
        if (atom.indexOf(id) >= 0)
            return l3[id] === false ? "LPE" : "E";
        return (sib[id] && sib[id].length > 1) ? "P" : "E";
    };
    var groups = { P: [], E: [], LPE: [] };
    var done = {};
    for (var j = 0; j < ids.length; j++) {
        var id = ids[j];
        if (done[id])
            continue;
        var kind = kindOf(id);
        var set = (kind === "P" && sib[id] && sib[id].length > 0) ? sib[id].slice() : [id];
        set.sort(function (x, y) { return x - y; });
        for (var s = 0; s < set.length; s++)
            done[set[s]] = true;
        groups[kind].push({ kind: kind, cpus: set });
    }
    return groups.P.concat(groups.E, groups.LPE);
}

// The load of each group = the mean of its CPUs' loads (a P core is two threads). A group none
// of whose CPUs has a figure yet reads 0.
function coreLoads(groups, loads) {
    var out = [];
    for (var g = 0; g < groups.length; g++) {
        var sum = 0;
        var n = 0;
        for (var i = 0; i < groups[g].cpus.length; i++) {
            var v = loads[String(groups[g].cpus[i])];
            if (typeof v === "number") {
                sum += v;
                n++;
            }
        }
        out.push({ kind: groups[g].kind, load: n > 0 ? sum / n : 0 });
    }
    return out;
}

// The mean of the policies' scaling_cur_freq (kHz) in MHz, rounded; null when none read.
function meanFreqMHz(khz) {
    var sum = 0;
    var n = 0;
    for (var i = 0; i < khz.length; i++) {
        if (typeof khz[i] === "number" && khz[i] > 0) {
            sum += khz[i];
            n++;
        }
    }
    return n > 0 ? Math.round(sum / n / 1000) : null;
}

// rc6_residency_ms counts the milliseconds the render engine spent in RC6 (asleep): the busy
// share between two reads is what it did NOT sleep. Wall time is the caller's, in ms.
function rc6Busy(prevMs, curMs, dtMs) {
    if (typeof prevMs !== "number" || typeof curMs !== "number" || !(dtMs > 0) || curMs < prevMs)
        return null;
    var v = 1 - (curMs - prevMs) / dtMs;
    return v < 0 ? 0 : (v > 1 ? 1 : v);
}

// --- /proc/meminfo ---------------------------------------------------------------------
//
//   MemTotal:       24007296 kB
//   MemAvailable:    7707952 kB
//
// -> { totalKiB, availableKiB, usedFraction } | null. "Used" is what the kernel says cannot be had without
// swapping (MemTotal - MemAvailable: the page cache is NOT used, it is there for the taking). A text without
// MemTotal and MemAvailable is no reading (the caller keeps what it had). The swap is not read: the board draws
// none.
function parseMeminfo(text) {
    var t = String(text === undefined || text === null ? "" : text);
    var kib = function (name) {
        var m = new RegExp("^" + name + ":\\s*(\\d+)\\s*kB\\s*$", "m").exec(t);
        return m ? parseInt(m[1], 10) : null;
    };
    var total = kib("MemTotal");
    var avail = kib("MemAvailable");
    if (total === null || avail === null || total <= 0)
        return null;
    avail = Math.min(avail, total);
    return {
        totalKiB: total,
        availableKiB: avail,
        usedFraction: (total - avail) / total
    };
}

// --- /proc/<pid>/fdinfo/<fd> of a DRM fd (i915 / xe) ---------------------------------
//
//   drm-driver:     i915
//   drm-client-id:  42
//   drm-engine-render:  123456789 ns
//
// -> { clientId, renderNs } | null when it is not a DRM fd. Two fds of one client show the same
// client id; the caller counts a client once.
function parseFdinfo(text) {
    var t = String(text === undefined || text === null ? "" : text);
    if (t.indexOf("drm-") < 0)
        return null;
    var id = /^drm-client-id:\s*(\d+)/m.exec(t);
    var ns = 0;
    var re = /^drm-engine-(?:render|compute):\s*(\d+)\s*ns/mg;
    var m;
    while ((m = re.exec(t)) !== null)
        ns += parseInt(m[1], 10);
    return { clientId: id ? parseInt(id[1], 10) : -1, renderNs: ns };
}

// --- nvidia-smi -----------------------------------------------------------------------
var NVIDIA_SMI_FIELDS = "utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total";

// "12, 45, 23.50, 1024, 8188" (csv,noheader,nounits). A field the driver does not answer is
// "[N/A]" / "[Not Supported]": null. Anything that is not five fields is no reading.
function parseNvidiaSmi(text) {
    var line = String(text === undefined || text === null ? "" : text).split("\n")[0].trim();
    if (line === "")
        return null;
    var f = line.split(",").map(function (x) { return x.trim(); });
    if (f.length !== 5)
        return null;
    var o = {
        util: toNum(f[0], null),
        tempC: toNum(f[1], null),
        watts: toNum(f[2], null),
        vramUsedMB: toNum(f[3], null),
        vramTotalMB: toNum(f[4], null)
    };
    if (o.util === null && o.tempC === null && o.watts === null && o.vramUsedMB === null)
        return null;
    return o;
}
