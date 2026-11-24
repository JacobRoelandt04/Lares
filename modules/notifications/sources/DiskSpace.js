.pragma library
.import "SourceFormat.js" as F

// =============================================================================
// DiskSpace.js -- the disk running low, as pure decisions (SOURCES.md, "Later sources").
//
// "disk space low (/ or /home under N GB)". `df -P -B1 -- <path>` says how much is free where a path is; this reads it, folds
// the paths that are on ONE filesystem into one fact (this machine's /home is a directory of /: one card, not two), and
// judges it against the user's numbers.
//
//   parseDf(text)                       -> [{ device, target, sizeBytes, availBytes }]
//   groups(entries, mounts)             -> [{ device, targets, sizeBytes, availBytes }], one per filesystem, only the
//                                          paths asked for (an entry's `target` is the path its row answered), in the order asked
//   limits(group, cfg)                  -> { low, critical } in bytes: the LOWEST a mount of the group asks for
//   judge(group, level, cfg)            -> the level now: "ok" | "low" | "critical", with hysteresis
//   text(group, level)                  -> { title, body, usedPct }
//   key(group)
//
// HYSTERESIS: a level is left only when the free space is `recover` (15 %) above the line it crossed -- a disk
// hovering at the threshold, a download that writes and deletes, does not post and withdraw. Falling is not delayed:
// a card that says "low" becomes "critical" the moment it is. Critical is for what cannot wait (a disk that is nearly
// full stops the system writing); the rest is Normal. No Qt, no clock.
// =============================================================================

var GIB = 1073741824;

// `df -P -B1`: "Filesystem 1-blocks Used Available Capacity Mounted on" and a row per mount.
function parseDf(text) {
    var out = [];
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var m = /^(\S+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(\/.*)$/.exec(lines[i].trim());
        if (m)
            out.push({ device: m[1], target: m[6], sizeBytes: Number(m[2]), availBytes: Number(m[4]) });
    }
    return out;
}

function groups(entries, mounts) {
    var want = Array.isArray(mounts) ? mounts : [];
    var byDev = {};
    var order = [];
    for (var w = 0; w < want.length; w++)
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].target !== want[w])
                continue;
            var e = entries[i];
            if (!byDev[e.device]) {
                byDev[e.device] = { device: e.device, targets: [], sizeBytes: e.sizeBytes, availBytes: e.availBytes };
                order.push(e.device);
            }
            if (byDev[e.device].targets.indexOf(e.target) < 0)
                byDev[e.device].targets.push(e.target);
        }
    return order.map(function (d) { return byDev[d]; });
}

// The numbers of the group: for each mount in it the user's own (perMount) or the common one; the group answers to
// the HIGHEST line any of its mounts asks for (a / that asks 5 GB and a /home that asks 20 GB on one disk: 20).
function limits(group, cfg) {
    var low = 0;
    var crit = 0;
    for (var i = 0; i < group.targets.length; i++) {
        var mine = cfg.perMount ? cfg.perMount[group.targets[i]] : undefined;
        var own = typeof mine === "number" && isFinite(mine) && mine > 0 ? mine : cfg.minFreeGB;
        low = Math.max(low, own);
        crit = Math.max(crit, Math.min(cfg.criticalGB, own));
    }
    return { low: low * GIB, critical: crit * GIB };
}

function judge(group, level, cfg) {
    var l = limits(group, cfg);
    var rec = 1 + cfg.recover;
    var avail = group.availBytes;
    var next = "ok";
    if (avail < l.critical)
        next = "critical";
    else if (avail < l.low)
        next = "low";
    // leaving a level takes the margin: the state does not fall back to a milder one until free is `recover` over its line
    if (level === "critical" && next !== "critical" && avail < l.critical * rec)
        next = "critical";
    if ((level === "low" || level === "critical") && next === "ok" && avail < l.low * rec)
        next = "low";
    return next;
}

function key(group) {
    return "disk:" + F.keyPart(group.device);
}

// "Low disk space" / "/ and /home: 4.2 GB free of 927 GB".
function text(group, level) {
    var used = group.sizeBytes > 0 ? Math.round((group.sizeBytes - group.availBytes) / group.sizeBytes * 100) : 0;
    var where = group.targets.join(" and ");
    return { title: level === "critical" ? "Disk almost full" : "Low disk space",
             body: where + ": " + F.gb(group.availBytes) + " free of " + F.gb(group.sizeBytes), usedPct: Math.max(0, Math.min(100, used)) };
}
