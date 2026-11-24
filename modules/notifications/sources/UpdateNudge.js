.pragma library
.import "SourceFormat.js" as F

// =============================================================================
// UpdateNudge.js -- the system update's post-boot nudge, as pure decisions (SOURCES.md, "System update").
//
// The nudge: about 15 min after boot, plus a random few, after a fresh refresh; when the update count >= N
// and/or days since the last update >= D (the combination a setting); tone = facts: '42 updates . 312 MiB .
// last update 9 days ago', the counts per category in yay's colours, the updatable packages the user has
// FAVOURITED as the highlights; at most ONCE PER DAY across reboots.
//
//   dueAtMs(now, uptime, shellStart, nudge, rand, leadMs)   when the check is due
//   rule(count, staleDays, nudge)           -> { due, why }  the count and / or the days
//   mayCheck(st, bootId, todayKey)          -> { check, why } the state file's say: once per boot, once a day
//   afterCheck(st, bootId, todayKey, shown) -> the state to keep
//   title(count) / body(sizeBytes, staleDays)  the facts
//   chips(categories) / highlights(rows, n)    the rich body's data
//   rebootReasons(names, list) / rebootLine(reasons)
//
// `nudge` is the resolved `sources.update.nudge` block (SourceSettings). No Qt, no clock: every "now" is an
// argument.
// =============================================================================

// The earliest a check may come after the shell started: its screen is known, its services are up, the
// bar is drawn. A shell restarted three hours into the boot checks a minute after it is up, not at once.
var LEAD_MS = 60000;

// ---------------------------------------------------------------- when

// `uptimeMs` < 0 = the machine's uptime is unknown: the boot counts from the shell's own start.
function dueAtMs(nowMs, uptimeMs, shellStartMs, nudge, rand, leadMs) {
    var bootMs = uptimeMs >= 0 ? nowMs - uptimeMs : shellStartMs;
    var r = rand >= 0 && rand < 1 ? rand : 0;
    var at = bootMs + (nudge.afterBootMin + r * nudge.jitterMin) * 60000;
    return Math.max(at, shellStartMs + (leadMs === undefined ? LEAD_MS : leadMs));
}

// ---------------------------------------------------------------- whether

// "count" the updates alone, "days" the days since the last update alone, "either" one of them,
// "both" both. `staleDays` 0 is the service's "no run known": the days never trigger on a guess. Nothing
// to update is never a nudge, whatever the days say.
function rule(count, staleDays, nudge) {
    var byCount = count >= nudge.minCount;
    var byDays = staleDays > 0 && staleDays >= nudge.minDays;
    var due;
    switch (nudge.rule) {
    case "count":
        due = byCount;
        break;
    case "days":
        due = byDays;
        break;
    case "both":
        due = byCount && byDays;
        break;
    default:
        due = byCount || byDays;
    }
    return { due: count > 0 && due, why: byCount && byDays ? "both" : (byCount ? "count" : (byDays ? "days" : "")) };
}

// The state file keeps { checkedBoot, nudgeDay }. A boot is looked at once (a shell that restarts three
// times in an afternoon does not ask `checkupdates` three times), and one nudge is shown per local day
// however many times the machine booted.
function mayCheck(st, bootId, todayKey) {
    var s = st || {};
    if (s.nudgeDay === todayKey)
        return { check: false, why: "today" };
    if (bootId !== "" && s.checkedBoot === bootId)
        return { check: false, why: "boot" };
    return { check: true, why: "" };
}

function afterCheck(st, bootId, todayKey, shown) {
    var s = st || {};
    return { checkedBoot: bootId, nudgeDay: shown ? todayKey : (s.nudgeDay || "") };
}

// ---------------------------------------------------------------- what it says

function title(count) {
    return F.plural(count, "update") + (count === 1 ? " is" : " are") + " waiting";
}

// "312 MiB . last update 9 days ago", each part only when it is known.
function body(sizeBytes, staleDays) {
    var parts = [];
    var size = F.bytes(sizeBytes);
    if (size !== "" && sizeBytes > 0)
        parts.push(size);
    if (staleDays > 0)
        parts.push("last update " + F.daysAgo(staleDays));
    return parts.join(" · ");
}

// AvailableUpdatesService.categories ([{ key, label, official, count }], in the list's order), the
// non-empty ones.
function chips(categories) {
    var out = [];
    var list = Array.isArray(categories) ? categories : [];
    for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].count > 0)
            out.push({ key: String(list[i].key), label: String(list[i].label), count: list[i].count });
    return out;
}

// The favourites among the updates, in the list's own order (category, then name), at most `n`.
// `rows` are the model's rows ({ name, oldVer, newVer, category, isFavorite }).
function highlights(rows, n) {
    var out = [];
    var list = Array.isArray(rows) ? rows : [];
    for (var i = 0; i < list.length && out.length < n; i++) {
        var r = list[i];
        if (r && r.isFavorite === true)
            out.push({ name: String(r.name), oldVer: String(r.oldVer || ""), newVer: String(r.newVer || ""), category: String(r.category || "") });
    }
    return out;
}

// ---------------------------------------------------------------- the reboot hint

var _KERNEL = /^linux(-(lts|zen|hardened|rt|rt-lts))?$/;

// What changed that a reboot is for: the packages of the run that are in `list` (exact names), the
// kernels named "kernel" -- once each, in the order they came.
function rebootReasons(names, list) {
    var out = [];
    var want = Array.isArray(list) ? list : [];
    var all = Array.isArray(names) ? names : [];
    for (var i = 0; i < all.length; i++) {
        var n = String(all[i]);
        if (want.indexOf(n) < 0)
            continue;
        var word = _KERNEL.test(n) ? "kernel" : n;
        if (out.indexOf(word) < 0)
            out.push(word);
    }
    return out;
}

function rebootLine(reasons) {
    return reasons.length > 0 ? "Reboot recommended: " + reasons.join(", ") + " changed" : "";
}
