.pragma library

// =============================================================================
// SourceSettings.js -- the notification sources' keys in notifications.jsonc.
//
// Each source of the shell's own (system update, battery, stocks, ...) reads
//
//     "sources": { "<id>": { "enabled": true, ...its own keys... } }
//
// from the user's notifications.jsonc -- the SAME object the rule keys of
// NotifyPolicy live in (mute, urgency, group, timeoutMs, sound, history,
// focusSuppress), so one block per source holds both what the source DOES and
// how the manager treats what it says. The rule keys are NotifyPolicy's and are
// copied through untouched; the others are defined here, with their defaults and
// their limits, in ONE table (DEFAULTS / LIMITS), documented key by key in
// .examples/notifications.jsonc.
//
//   resolve(sources)             -> { settings: { id: {...} }, problems: [string] }
//   resolveWith(defaults, limits, sources, items)   the same over any table
//   settingsOf(settings, id)     one source's block; an id this table does not know gets
//                                { enabled: true } and whatever the file gave it
//   defaults()                   a deep copy of the table
//
// THE RULES, as NotifyPolicy.merge has them: a value of the wrong type is ignored
// and the default stays (a typo must not take a section down); a number outside
// its limits, and a string outside its list, likewise -- and each of them is a
// line in `problems`, which NotificationConfig reports through `lastError` so the
// user is told which key and why. A key the table does not know is kept as it
// is. `enabled` is every source's switch (default true).
//
// An array of objects (battery.levels) is validated item by item by the table's
// ITEMS function for that path: it returns the item cleaned, or null (the item is
// dropped and named); an array that ends up empty is the default.
//
// Pure: no Qt, no clock. Loadable under node.
// =============================================================================

var DEFAULTS = {};
var LIMITS = {};
var ITEMS = {};

function _isObj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function _copy(v) {
    return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
}

function _has(o, k) {
    return Object.prototype.hasOwnProperty.call(o, k);
}

function defaults() {
    return _copy(DEFAULTS);
}

function _problem(problems, path, why, def) {
    problems.push(path + ": " + why + (def === undefined ? "" : " -- the default " + JSON.stringify(def) + " stays"));
}

function _mergeInto(base, over, path, problems, limits, items) {
    for (var k in over) {
        if (!_has(over, k))
            continue;
        var v = over[k];
        if (v === undefined || v === null)
            continue;
        var p = path + "." + k;
        if (!_has(base, k)) {
            base[k] = _copy(v);
            continue;
        }
        var b = base[k];
        if (_isObj(b)) {
            if (!_isObj(v)) {
                _problem(problems, p, "not an object");
                continue;
            }
            _mergeInto(b, v, p, problems, limits, items);
        } else if (Array.isArray(b)) {
            var fn = items ? items[p.substring(p.indexOf(".") + 1)] : null;
            if (fn && typeof v === "number")      // one value is a list of one
                v = [v];
            if (!Array.isArray(v)) {
                _problem(problems, p, "not a list", b);
                continue;
            }
            if (!fn) {
                base[k] = _copy(v);
                continue;
            }
            var out = [];
            for (var i = 0; i < v.length; i++) {
                var item = fn(v[i], i);
                if (item === null || item === undefined)
                    _problem(problems, p + "[" + i + "]", "not a valid entry, dropped");
                else
                    out.push(item);
            }
            if (out.length > 0)
                base[k] = out;
            else if (v.length > 0)
                _problem(problems, p, "no valid entry", b);
            else
                base[k] = [];
        } else if (typeof b === "number") {
            var lim = limits[p.substring(p.indexOf(".") + 1)];
            if (typeof v !== "number" || !isFinite(v))
                _problem(problems, p, "not a number", b);
            else if (lim && (v < lim[0] || v > lim[1]))
                _problem(problems, p, v + " is not between " + lim[0] + " and " + lim[1], b);
            else
                base[k] = v;
        } else if (typeof b === "boolean") {
            if (typeof v !== "boolean")
                _problem(problems, p, "not true or false", b);
            else
                base[k] = v;
        } else if (typeof b === "string") {
            var list = limits[p.substring(p.indexOf(".") + 1)];
            if (typeof v !== "string")
                _problem(problems, p, "not a string", b);
            else if (list && list.indexOf(v) < 0)
                _problem(problems, p, "\"" + v + "\" is none of " + list.join(", "), b);
            else
                base[k] = v;
        }
    }
    return base;
}

// `sources` is notifications.jsonc's "sources" object (or anything: a non-object is "no file").
function resolveWith(defaultsTable, limits, sources, items) {
    var over = _isObj(sources) ? sources : {};
    var settings = {};
    var problems = [];
    for (var id in defaultsTable) {
        if (!_has(defaultsTable, id))
            continue;
        var base = _copy(defaultsTable[id]);
        if (!_has(base, "enabled"))
            base.enabled = true;
        if (_has(over, id) && over[id] !== null && over[id] !== undefined) {
            if (_isObj(over[id]))
                _mergeInto(base, over[id], "sources." + id, problems, limits || {}, items || {});
            else
                _problem(problems, "sources." + id, "not an object");
        }
        settings[id] = base;
    }
    for (var other in over) {
        if (_has(over, other) && !_has(settings, other) && _isObj(over[other])) {
            var s = _copy(over[other]);
            if (_has(s, "enabled") && typeof s.enabled !== "boolean")
                _problem(problems, "sources." + other + ".enabled", "not true or false", true);
            if (typeof s.enabled !== "boolean")
                s.enabled = true;
            settings[other] = s;
        }
    }
    return { settings: settings, problems: problems };
}

function resolve(sources) {
    return resolveWith(DEFAULTS, LIMITS, sources, ITEMS);
}

function settingsOf(settings, id) {
    if (_isObj(settings) && _isObj(settings[id]))
        return settings[id];
    return { enabled: true };
}

// =============================================================================
// The table. One block per source, added with the source (.examples/notifications.jsonc documents each key).
// =============================================================================

// ---- update: the system update (UpdateNotifier)
DEFAULTS.update = {
    enabled: true,
    // The post-boot nudge: `afterBootMin` + a random share of `jitterMin` minutes after the BOOT, once a day
    // at most. `rule` says how the two thresholds combine: "either" (the updates number at least minCount OR
    // the last update is at least minDays old), "both", "count" alone, "days" alone.
    nudge: { enabled: true, afterBootMin: 15, jitterMin: 4, minCount: 20, minDays: 7, rule: "either", highlights: 3, timeoutMs: 30000 },
    // A run that begins / waits for an answer / ends while the popup is shut.
    started: true,
    asks: true,
    finished: true,
    // The packages whose update asks for a reboot ("linux" and the other kernels read as "kernel").
    rebootPackages: ["linux", "linux-lts", "linux-zen", "linux-hardened", "linux-rt", "linux-rt-lts", "systemd", "mesa"]
};
LIMITS["update.nudge.afterBootMin"] = [0, 1440];
LIMITS["update.nudge.jitterMin"] = [0, 240];
LIMITS["update.nudge.minCount"] = [1, 100000];
LIMITS["update.nudge.minDays"] = [1, 3650];
LIMITS["update.nudge.rule"] = ["either", "both", "count", "days"];
LIMITS["update.nudge.highlights"] = [0, 8];
LIMITS["update.nudge.timeoutMs"] = [-1, 3600000];

// ---- battery: the low-charge levels, the charge limit, the fast drain (BatteryNotifier)
DEFAULTS.battery = {
    enabled: true,
    // Highest first or not (they are sorted): each level that the charge falls to, while discharging, replaces the
    // card of the one before (ONE key) until charging starts. `hibernate` puts the Hibernate button on the card
    // (a dud until the machine can hibernate: see `hibernate` below). `timeoutMs` absent = the urgency's own.
    // 15 % is the OSD's (its battery card; the two would duplicate each other): a toast says it at 8 and 3 % -- add
    // { "pct": 15, "urgency": "normal" } to have both.
    levels: [
        { pct: 8, urgency: "critical", hibernate: true, timeoutMs: 60000, breakDnd: false },
        { pct: 3, urgency: "critical", hibernate: true, timeoutMs: -1, breakDnd: true }
    ],
    // What the Hibernate button does: "dud" says it is not set up yet (the machine has no resume device), "systemctl"
    // runs `systemctl hibernate`.
    hibernate: "dud",
    // "Charged to 80 %": the pack reached its target (the charge limit, or 100). Off: the OSD's battery card says it.
    limitReached: false,
    // The discharge stays `factor` times above the usual (and at least `minW` watts) for `minutes`: a runaway
    // process. The usual is eased over `tauMin` minutes and kept across restarts; nothing fires in the first
    // `warmupMin` minutes of learning.
    fastDrain: { enabled: true, factor: 2, minW: 15, minutes: 5, tauMin: 30, warmupMin: 10 }
};
LIMITS["battery.hibernate"] = ["dud", "systemctl"];
LIMITS["battery.fastDrain.factor"] = [1.2, 20];
LIMITS["battery.fastDrain.minW"] = [1, 300];
LIMITS["battery.fastDrain.minutes"] = [1, 120];
LIMITS["battery.fastDrain.tauMin"] = [1, 600];
LIMITS["battery.fastDrain.warmupMin"] = [0, 240];
ITEMS["battery.levels"] = function (it) {
    if (!_isObj(it) || typeof it.pct !== "number" || !isFinite(it.pct) || it.pct < 1 || it.pct > 99 || Math.floor(it.pct) !== it.pct)
        return null;
    var urgency = it.urgency === undefined ? "normal" : it.urgency;
    if (["low", "normal", "critical"].indexOf(urgency) < 0)
        return null;
    var out = { pct: it.pct, urgency: urgency, hibernate: it.hibernate === true, breakDnd: it.breakDnd === true };
    if (typeof it.timeoutMs === "number" && isFinite(it.timeoutMs) && it.timeoutMs >= -1)
        out.timeoutMs = it.timeoutMs;
    if (typeof it.title === "string" && it.title.length > 0)
        out.title = it.title;
    return out;
};

// ---- stocks: the sudden-move alert (StocksNotifier); its thresholds are stocks.jsonc's (`sudden`, per symbol too)
DEFAULTS.stocks = {
    enabled: true,
    // The `sudden` alert kind: a stock that moves fast while its market is open.
    sudden: true,
    // Which stocks: "portfolio" (the ones you hold and the watchlist), "holdings" (held only), "all" (every
    // stock the popup has a quote for; currencies are never judged).
    scope: "portfolio"
};
LIMITS["stocks.scope"] = ["portfolio", "holdings", "all"];

// ---- screenshot: a shot taken (ScreenshotNotifier)
DEFAULTS.screenshot = {
    enabled: true,
    // "auto": the OSD's capture card already shows the shot, so this card is FILED silently while the OSD routes its card
    // to the screen (it waits in the manager with its buttons), stays out when the OSD posts a notification of its own,
    // and toasts where the OSD says nothing. "always" toasts too (a second popup over the same picture), "never" files.
    toast: "auto"
};
LIMITS["screenshot.toast"] = ["auto", "always", "never"];

// ---- usb: a removable drive plugged in, taken out (UsbNotifier)
DEFAULTS.usb = {
    enabled: true,
    // The card's Mount button (and a body click on a drive nothing has mounted): `udisksctl mount -b` on each filesystem, which udisks
    // puts under /run/media/<user> where yazi's mount plugin can unmount it. false: no Mount button.
    mount: true,
    // Mount opens the drive too (false: it mounts it, and the card offers Open).
    openAfterMount: true,
    // What Open runs, detached; `{path}` is the first mount point. The default is the Super+E window (yazi in kitty).
    openCommand: ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", "{path}"],
    // A card when a drive vanishes while it was still mounted (its files may be damaged).
    unsafeWarn: true,
    // How long "can be removed" stays once the drive has gone, seconds (0: it goes with the drive).
    safeSec: 10,
    // How long the devices must be quiet after udisks speaks before they are looked at, ms.
    debounceMs: 600
};
LIMITS["usb.debounceMs"] = [100, 10000];
LIMITS["usb.safeSec"] = [0, 3600];

// ---- calendar: reminders (CalendarNotifier)
DEFAULTS.calendar = {
    enabled: true,
    // Minutes before an appointment: one or several (the file's plain number is a list of one).
    leadMin: [10],
    // An all-day appointment is announced at this time of its day ("09:00"); "" not at all.
    allDayAt: "",
    // Only these calendars' ids; [] all of them.
    calendars: [],
    // How long the card stays (-1: until you act).
    timeoutMs: 30000
};
ITEMS["calendar.leadMin"] = function (v) {
    return typeof v === "number" && v >= 1 && v <= 1440 ? v : null;
};
ITEMS["calendar.calendars"] = function (v) {
    return typeof v === "string" && v !== "" ? v : null;
};
LIMITS["calendar.timeoutMs"] = [-1, 3600000];

// ---- disk: low free space (DiskNotifier)
DEFAULTS.disk = {
    enabled: true,
    // The paths that are looked at (absolute); paths on one filesystem make one card.
    mounts: ["/", "/home"],
    // Free space under this is Normal; under `criticalGB` it is Critical (GB of 1024^3 bytes, as `df -h` prints them).
    minFreeGB: 5,
    criticalGB: 1,
    // A mount of its own: { "/home": 20 }.
    perMount: {},
    pollMin: 5,
    // A level is left when the free space is this share above its line.
    recover: 0.15
};
ITEMS["disk.mounts"] = function (it) {
    return typeof it === "string" && it.charAt(0) === "/" ? it : null;
};
LIMITS["disk.minFreeGB"] = [0.1, 100000];
LIMITS["disk.criticalGB"] = [0.05, 100000];
LIMITS["disk.pollMin"] = [0.05, 1440];
LIMITS["disk.recover"] = [0, 1];

// ---- units: failed systemd units (UnitsNotifier)
DEFAULTS.units = {
    enabled: true,
    system: true,
    user: true,
    pollSec: 60,
    // Units not to hear about: names or `*` globs ("sddm.service", "user@*"). geoclue.service is D-Bus activated on demand
    // by the weather's location client and about a quarter of its starts hang past systemd's 90 s start timeout: a failed
    // unit the user can do nothing about (the weather asks again and the next start works). The user's own list REPLACES
    // this one (the rule of every list here: `[]` is "nothing ignored"), so a list that wants it too names it.
    ignore: ["geoclue.service"],
    // Lines of the journal "Show log" puts on the card (the newest at the foot).
    logLines: 8,
    // What "Copy log" copies: the last this many lines of the unit's journal -- the whole log, as far as one reads
    // (the card has room for logLines; the copy is not limited by it).
    copyLines: 2000
};
ITEMS["units.ignore"] = function (it) {
    return typeof it === "string" && it.trim() !== "" ? it.trim() : null;
};
LIMITS["units.pollSec"] = [5, 3600];
LIMITS["units.logLines"] = [1, 40];
LIMITS["units.copyLines"] = [1, 100000];

// ---- thermal: the CPU too hot to run at full speed (ThermalNotifier; power-limit throttling is not this card's)
DEFAULTS.thermal = {
    enabled: true,
    pollSec: 15,
    // A poll is hot when the CPU spent this share of it thermally throttled (the kernel's throttled time, the longest of
    // the logical CPUs' views of it); hot in every poll for `sustainSec` seconds says it. At most one card per `cooldownMin`
    // minutes, taken away after `quietMin` minutes that were not hot.
    minFraction: 0.25,
    sustainSec: 60,
    cooldownMin: 15,
    quietMin: 2,
    // The kernel's times live here: <root>/cpu*/thermal_throttle/*_throttle_total_time_ms.
    root: "/sys/devices/system/cpu"
};
LIMITS["thermal.pollSec"] = [1, 300];
LIMITS["thermal.minFraction"] = [0.01, 1];
LIMITS["thermal.sustainSec"] = [5, 3600];
LIMITS["thermal.cooldownMin"] = [0, 1440];
LIMITS["thermal.quietMin"] = [0.5, 1440];
