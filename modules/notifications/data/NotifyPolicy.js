.pragma library
.import "../../common/components/SenderMatch.js" as SenderMatch

// =============================================================================
// NotifyPolicy.js -- every decision the notification service makes that does
// not need Qt: which rule applies, which group, how long a toast lives,
// whether it toasts at all, how the manager orders and bundles, what history
// keeps. The service (NotificationService.qml) calls these and stores the
// answers; nothing here holds state or reads the clock -- every "now" is an
// argument, so a probe can pin it.
//
//   GROUPS                                   display order of the manager
//   defaults() / merge(cfg)                  notifications.jsonc over the defaults
//   ruleFor(cfg, rec)                        the app / source rule, or {}
//   groupOf(rec, rule)                       critical | system | normal | low
//   timeoutFor(rec, cfg, rule, requestedMs)  ms, or -1 = sticky
//   breaks(rec, cfg, specBreak)              does it break through DND
//   decide(rec, ctx)                         show | hold | file | drop (+ sound, seen)
//   retoast(prev, next)                      retoast | silent | inplace
//   order(records) / bundle(records, min)    the manager's list
//   newest(records)                          a group's newest (its preview line)
//   retain(records, nowMs, cfg, protected)   history's keep / drop
//   imageKind(w, h, avatarMax)               avatar | picture
//   isIconPath(path)                         an image file that is an icon
//   staggerDeadlines(deadlines, minGapMs)    expiries never closer than minGap
//   floodCheck(history, appKey, nowMs, cfg)  one app sending too many
//   heldRelease(held, reason)                what comes back after a hold
//   dotGroup(records, lastOpenedMs)          the bar dot's colour
//
// The contract is docs/contracts/notifications.md §P; the
// behaviour is the user's (PLAN.md "Decisions"). The rules that are easy to
// get wrong, and why:
//
// DECIDE RUNS IN ONE ORDER and the first rule that fires decides. A
// synchronous (OSD) notification, and any app's whose rule says `drop: true`
// (nm-applet and blueman, whose news the OSD tells), is dropped before anything
// else looks at it: filed nowhere, never tracked, so its sender is told
// Dismissed at once (a `mute` rule files it silently in the manager instead);
// with the manager open or the source attended the user is already looking,
// so it files and counts as seen; DND files silently unless the record breaks
// through, or its rule says `breakDnd: true` (`ruleBreaks`: DND alone, no hold); a muted rule and a focused sender (unless critical) file silently.
// Only then do holds apply: LOCKED holds everything, critical included,
// because nothing may draw over the lock -- a critical comes back on its own
// at unlock (heldRelease), and it is the one held thing that still SOUNDS,
// since a sound is the only way a critical reaches someone at the lock
// screen. A screencast, a fullscreen window or an app of `dnd.holdApps` keeps everything back silently
// except a critical, which shows in full, and the shell's own QUESTION (a
// `fixed` record with `breakDnd`: "Keep these display settings?", asked with a
// countdown that undoes the change: held, it reverted behind the user's back,
// and a cast IS a share). What DND files is never held and
// therefore never replayed: only "show" and "hold" ever reach a toast.
//
// `decide`'s `sound` says whether this event may sound at all; which file
// plays (rule.sound, the sound hints, the urgency's list, missing = silent)
// is NotificationSound's. `ctx.silent` is where the caller says the sender or
// the rule asked for none (rule.sound "none", a shell spec's default "none",
// suppress-sound).
//
// TIMEOUTS. A D-Bus sender's expire_timeout is honoured but clamped to
// [clampMin, clampMax]; its 0 ("never") is honoured for normal and critical
// only -- a low notification asking to stay for ever gets the low default.
// A rule's timeoutMs overrides whatever the sender asked. A shell source's
// timeoutMs is the source's own decision and is taken as given (-1 sticky);
// only when it leaves it undefined does the source rule, then the urgency,
// decide. A timeout of 0 anywhere means "never", as in the spec -- a toast
// that expires the moment it appears is not a toast.
//
// RETENTION. Pins and records inside an undo window are EXEMPT: they are
// neither dropped nor counted, so five pins do not shrink the history to 195.
// The rest goes oldest first by count, then by age. -1 for either limit = no
// limit (the shell's "-1 = never"). Age is measured from the last update, so
// a long download that is still reporting progress is not "old".
//
// A RULE'S `group` overrides for shell sources too: `sources` take the same
// keys as `apps`, and a user who writes a group into their config means it.
// Without one, everything the shell raises is "system".
//
// Pure: no Qt, loadable under node. Every
// function returns new arrays / objects and never mutates its arguments.
// =============================================================================

var GROUPS = ["critical", "system", "normal", "low"];
var URGENCIES = ["low", "normal", "critical"];
var DAY_MS = 86400000;

var _DEFAULTS = {
    spot: { corner: "top-right" },
    screen: "focused",
    timeouts: { low: 4000, normal: 8000, critical: -1, clampMin: 3000, clampMax: 60000 },
    toasts: { max: 5, floodCount: 3, floodWindowMs: 10000, hoverResumeMinMs: 2000, swipe: { right: "file", left: "delete" } },
    manager: { openGroup: "latest", swipe: { right: "pin", left: "delete" } },
    clickFocus: true,
    bell: { ring: "always" },
    soundVolume: -1,
    retention: { count: 200, days: 7 },
    undoMs: 10000,
    idleMs: 60000,
    sounds: {
        low: [],
        normal: ["~/.local/share/sounds/notification.mp3",
                 "/usr/share/sounds/notification.mp3"],
        critical: ["~/.local/share/sounds/notification-critical.mp3",
                   "~/.local/share/sounds/notification.mp3",
                   "/usr/share/sounds/notification.mp3"]
    },
    dnd: { remember: true, hours: [], summary: true, holdApps: [], breakthroughSources: ["clock", "auth"], holdFullscreen: true, holdScreencast: true },
    // The OSD tells the network and the bluetooth news (modules/osd: Wi-Fi, VPN, wired, "connection failed", devices), so the
    // applets that told it too say nothing at all: `drop` files nothing and shows nothing. nm-applet's
    // posts carry the desktop entry and the app name below; blueman's the app name "Blueman".
    apps: {
        kitty: { focusSuppress: false },
        "org.freedesktop.network-manager-applet": { drop: true },
        "NetworkManager Applet": { drop: true },
        "nm-applet": { drop: true },
        blueman: { drop: true },
        "blueman-applet": { drop: true }
    },
    sources: {}
};

// The keys that are one of a few words; another word is the default.
var _WORDS = [
    ["toasts", "swipe", "right", ["file", "delete"]],
    ["toasts", "swipe", "left", ["file", "delete"]],
    ["manager", "swipe", "right", ["pin", "delete"]],
    ["manager", "swipe", "left", ["pin", "delete"]],
    ["manager", null, "openGroup", ["latest", "first", "none"].concat(GROUPS)],
    ["bell", null, "ring", ["always", "notDnd", "never"]]
];

// Top-level keys whose value is ONE choice and is replaced whole: a spot of
// { bar, along } merged into { corner } would be both at once.
var _WHOLE = { spot: true };

function _isObj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}

function _copy(v) {
    return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
}

function _num(v) {
    return typeof v === "number" && isFinite(v);
}

function _has(o, k) {
    return Object.prototype.hasOwnProperty.call(o, k);
}

// ---------------------------------------------------------------- config

function defaults() {
    return _copy(_DEFAULTS);
}

// `over` onto `base`, in place. Objects merge key by key, arrays and scalars
// replace. A value of the wrong type (a number where the default is an
// object, a string where it is a number) is ignored and the default stays: a
// typo must not take a whole section down. null is "not given". Keys the
// defaults do not have (an app rule, a source) are copied as they are.
function _mergeInto(base, over, top) {
    for (var k in over) {
        if (!_has(over, k))
            continue;
        var v = over[k];
        if (v === undefined || v === null)
            continue;
        if (!_has(base, k)) {
            base[k] = _copy(v);
            continue;
        }
        var b = base[k];
        if (_isObj(b)) {
            if (!_isObj(v))
                continue;
            if (top && _WHOLE[k])
                base[k] = _copy(v);
            else
                _mergeInto(b, v, false);
        } else if (Array.isArray(b)) {
            if (Array.isArray(v))
                base[k] = _copy(v);
        } else if (typeof b === typeof v) {
            base[k] = _copy(v);
        }
    }
    return base;
}

function merge(cfg) {
    var out = defaults();
    if (_isObj(cfg))
        _mergeInto(out, cfg, true);
    _WORDS.forEach(function (w) {
        var o = w[1] === null ? out[w[0]] : out[w[0]][w[1]];
        if (w[3].indexOf(o[w[2]]) < 0)
            o[w[2]] = (w[1] === null ? _DEFAULTS[w[0]] : _DEFAULTS[w[0]][w[1]])[w[2]];
    });
    return out;
}

// ---------------------------------------------------------------- rules

function _lookup(map, name) {
    if (!_isObj(map))
        return null;
    var want = SenderMatch.norm(name);
    if (want === "")
        return null;
    for (var k in map)
        if (_has(map, k) && _isObj(map[k]) && SenderMatch.norm(k) === want)
            return map[k];
    return null;
}

function ruleFor(cfg, rec) {
    if (!_isObj(cfg) || !rec)
        return {};
    var r = rec.origin === "shell"
        ? _lookup(cfg.sources, rec.sourceId)
        : (_lookup(cfg.apps, rec.desktopEntry) || _lookup(cfg.apps, rec.appName));
    return r ? _copy(r) : {};
}

// The urgency that counts: the rule's when it names a valid one.
function _urgency(rec, rule) {
    var u = (rule && URGENCIES.indexOf(rule.urgency) >= 0) ? rule.urgency : (rec ? rec.urgency : "");
    return URGENCIES.indexOf(u) >= 0 ? u : "normal";
}

function groupOf(rec, rule) {
    if (rule && GROUPS.indexOf(rule.group) >= 0)
        return rule.group;
    if (rec && rec.origin === "shell")
        return "system";
    return _urgency(rec, rule);
}

// ---------------------------------------------------------------- timeouts

function _timeouts(cfg) {
    return (cfg && _isObj(cfg.timeouts)) ? cfg.timeouts : _DEFAULTS.timeouts;
}

function _urgencyDefault(cfg, u) {
    var t = _timeouts(cfg)[u];
    if (!_num(t))
        t = _DEFAULTS.timeouts[u];
    return t > 0 ? t : -1;
}

function _given(ms) {
    return ms > 0 ? ms : -1;
}

function _clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, v));
}

function timeoutFor(rec, cfg, rule, requestedMs) {
    var u = _urgency(rec, rule);
    var ruled = !!rule && _num(rule.timeoutMs);
    if (rec && rec.origin === "shell") {
        if (_num(requestedMs))
            return _given(requestedMs);
        return ruled ? _given(rule.timeoutMs) : _urgencyDefault(cfg, u);
    }
    if (ruled)
        return _given(rule.timeoutMs);
    if (!_num(requestedMs) || requestedMs < 0)
        return _urgencyDefault(cfg, u);
    if (requestedMs === 0)
        return u === "low" ? _urgencyDefault(cfg, "low") : -1;
    var t = _timeouts(cfg);
    var lo = _num(t.clampMin) ? t.clampMin : _DEFAULTS.timeouts.clampMin;
    var hi = _num(t.clampMax) ? Math.max(lo, t.clampMax) : Math.max(lo, _DEFAULTS.timeouts.clampMax);
    return _clamp(requestedMs, lo, hi);
}

// ---------------------------------------------------------------- toasting

function breaks(rec, cfg, specBreak) {
    if (!rec)
        return false;
    if (rec.urgency === "critical" || specBreak === true)
        return true;
    if (rec.origin !== "shell")
        return false;
    var list = (cfg && _isObj(cfg.dnd) && Array.isArray(cfg.dnd.breakthroughSources))
        ? cfg.dnd.breakthroughSources : _DEFAULTS.dnd.breakthroughSources;
    var id = SenderMatch.norm(rec.sourceId);
    if (id === "")
        return false;
    for (var i = 0; i < list.length; i++)
        if (SenderMatch.norm(list[i]) === id)
            return true;
    return false;
}

function _out(toast, sound, seen, reason) {
    return { toast: toast, sound: sound, seen: seen, reason: reason };
}

function decide(rec, ctx) {
    var c = ctx || {};
    var crit = !!rec && rec.urgency === "critical";
    var voice = c.silent !== true;
    if (c.synchronous)
        return _out("drop", false, false, "synchronous");
    if (c.drop)
        return _out("drop", false, false, "drop");
    if (c.managerOpen)
        return _out("file", false, true, "manager");
    if (c.attended)
        return _out("file", false, true, "attended");
    if (c.dnd && !c.breaks && !c.ruleBreaks)
        return _out("file", false, false, "dnd");
    if (c.mute)
        return _out("file", false, false, "mute");
    if (c.focusedSender && c.focusSuppress !== false && !crit)
        return _out("file", false, false, "focused");
    if (c.hold === "locked")
        return _out("hold", crit && voice, false, "locked");
    if (c.hold) {
        if (crit)
            return _out("show", voice, false, "critical");
        if (c.breaks && rec && rec.fixed === true)
            return _out("show", voice, false, "question");
        return _out("hold", false, false, String(c.hold));
    }
    return _out("show", voice, false, c.dnd ? "breakthrough" : "show");
}

function _progress(r) {
    return _num(r.progress) && r.progress >= 0 ? r.progress : -1;
}

function _str(v) {
    return v === undefined || v === null ? "" : String(v);
}

function _json(v) {
    return JSON.stringify(v === undefined ? null : v);
}

// What else a replace can change, besides the words and the progress.
function _sameLook(a, b) {
    return _str(a.appIcon) === _str(b.appIcon)
        && _str(a.urgency) === _str(b.urgency)
        && !!a.hasDefault === !!b.hasDefault
        && _json(a.actions) === _json(b.actions)
        && _json(a.image) === _json(b.image)
        && _json(a.reply) === _json(b.reply);
}

function retoast(prev, next) {
    if (!prev || !next)
        return "retoast";
    if (_str(prev.summary) !== _str(next.summary) || _str(prev.body) !== _str(next.body))
        return "retoast";
    var onlyProgress = _progress(prev) !== _progress(next) && _sameLook(prev, next);
    return onlyProgress ? "silent" : "inplace";
}

// ---------------------------------------------------------------- the manager

function _groupIndex(g) {
    var i = GROUPS.indexOf(g);
    return i < 0 ? GROUPS.length : i;
}

function _updated(r) {
    return _num(r.updatedMs) ? r.updatedMs : (_num(r.arrivedMs) ? r.arrivedMs : 0);
}

function order(records) {
    var list = Array.isArray(records) ? records : [];
    var dec = list.map(function (r, i) { return { r: r, i: i }; });
    dec.sort(function (x, y) {
        var a = x.r, b = y.r;
        var d = _groupIndex(a.group) - _groupIndex(b.group);
        if (d !== 0)
            return d;
        var pa = a.pinned ? 1 : 0, pb = b.pinned ? 1 : 0;
        if (pa !== pb)
            return pb - pa;
        if (pa) {
            d = (_num(b.pinnedMs) ? b.pinnedMs : 0) - (_num(a.pinnedMs) ? a.pinnedMs : 0);
            if (d !== 0)
                return d;
        }
        d = _updated(b) - _updated(a);
        return d !== 0 ? d : x.i - y.i;
    });
    return dec.map(function (e) { return e.r; });
}

// The newest record of a list (a group's, for its folded preview): the
// latest update, then the latest arrival, then the LATER position in the list
// -- the store inserts a record after every record it ties with (order()),
// so of a burst that landed in one millisecond the last one received wins,
// never the first one the list happens to show on top. null for none.
function newest(records) {
    var list = Array.isArray(records) ? records : [];
    var best = null, bu = 0, ba = 0;
    for (var i = 0; i < list.length; i++) {
        var r = list[i];
        if (!r)
            continue;
        var u = _updated(r);
        var a = _num(r.arrivedMs) ? r.arrivedMs : u;
        if (best === null || u > bu || (u === bu && a >= ba)) {
            best = r;
            bu = u;
            ba = a;
        }
    }
    return best;
}

// One group's records, in display order, -> entries in display order. An app
// with at least `minSize` unpinned records becomes one bundle, standing where
// its newest record stood. Pins stay single (they sit at the top of the group
// on their own), and so does a record without an appKey.
function bundle(groupRecords, minSize) {
    var min = (_num(minSize) && minSize >= 1) ? Math.floor(minSize) : 2;
    var list = Array.isArray(groupRecords) ? groupRecords : [];
    var count = Object.create(null);
    var i, r;
    for (i = 0; i < list.length; i++) {
        r = list[i];
        if (r && !r.pinned && r.appKey)
            count[r.appKey] = (count[r.appKey] || 0) + 1;
    }
    var out = [], at = Object.create(null);
    for (i = 0; i < list.length; i++) {
        r = list[i];
        if (!r)
            continue;
        if (r.pinned || !r.appKey || count[r.appKey] < min) {
            out.push({ record: r });
            continue;
        }
        if (at[r.appKey] === undefined) {
            at[r.appKey] = out.length;
            out.push({ appKey: r.appKey, records: [] });
        }
        out[at[r.appKey]].records.push(r);
    }
    return out;
}

function _uidSet(uids) {
    var s = Object.create(null);
    if (Array.isArray(uids)) {
        for (var i = 0; i < uids.length; i++)
            s[uids[i]] = true;
    } else if (_isObj(uids)) {
        for (var k in uids)
            if (_has(uids, k) && uids[k])
                s[k] = true;
    }
    return s;
}

function retain(records, nowMs, cfg, protectedUids) {
    var list = Array.isArray(records) ? records : [];
    var ret = (cfg && _isObj(cfg.retention)) ? cfg.retention : _DEFAULTS.retention;
    var count = _num(ret.count) ? ret.count : _DEFAULTS.retention.count;
    var days = _num(ret.days) ? ret.days : _DEFAULTS.retention.days;
    var prot = _uidSet(protectedUids);
    var cand = [];
    var i;
    for (i = 0; i < list.length; i++) {
        var r = list[i];
        if (r && !r.pinned && !prot[r.uid])
            cand.push({ i: i, t: _updated(r) });
    }
    cand.sort(function (a, b) { return (a.t - b.t) || (a.i - b.i); });   // oldest first
    var gone = Object.create(null);
    var over = count >= 0 ? cand.length - Math.floor(count) : 0;
    for (i = 0; i < over; i++)
        gone[cand[i].i] = true;
    if (days >= 0) {
        var cutoff = nowMs - days * DAY_MS;
        for (i = 0; i < cand.length; i++)
            if (cand[i].t < cutoff)
                gone[cand[i].i] = true;
    }
    var keep = [], drop = [];
    for (i = 0; i < list.length; i++)
        (gone[i] ? drop : keep).push(list[i]);
    return { keep: keep, drop: drop };
}

function imageKind(w, h, avatarMax) {
    var max = _num(avatarMax) ? avatarMax : 128;
    if (!(w > 0) || !(h > 0))
        return "avatar";                 // no size yet: the small treatment
    var aspect = w / h;
    return (w <= max && h <= max && aspect >= 0.8 && aspect <= 1.25) ? "avatar" : "picture";
}

// An image FILE the sender passed that is an icon, not a picture of
// something: an icon format (svg, svgz, xpm, ico), or a file inside an icon
// directory (a path segment "icons" or "pixmaps": the icon themes, the
// pixmaps dir, ~/.local/share/icons, a script's own icons/ folder). libnotify's
// `notify-send -i X` sends X in the image-path hint with app_icon empty, so an
// icon arrives as the notification's IMAGE; a 48 px theme icon would
// read as a contact's avatar (cut to a circle) and a 512 px script icon as a
// picture band. Everything else is measured (imageKind).
function isIconPath(path) {
    var p = _str(path);
    if (p.indexOf("file://") === 0) {
        try {
            p = decodeURIComponent(p.substring(7));
        } catch (e) {
            p = p.substring(7);
        }
    }
    if (p.charAt(0) !== "/")
        return false;
    if (/\.(svgz?|xpm|ico)$/i.test(p))
        return true;
    var seg = p.split("/");
    for (var i = 0; i < seg.length - 1; i++)
        if (seg[i] === "icons" || seg[i] === "pixmaps")
            return true;
    return false;
}

// Absolute deadlines (ms; -1 or any negative = sticky, untouched). The
// earliest stays; each later one is pushed to at least minGap after the one
// before it, so the order never changes and nothing moves earlier. Ties keep
// their array order.
function staggerDeadlines(deadlines, minGapMs) {
    var d = Array.isArray(deadlines) ? deadlines.slice() : [];
    var gap = (_num(minGapMs) && minGapMs > 0) ? minGapMs : 0;
    var idx = [];
    for (var i = 0; i < d.length; i++)
        if (_num(d[i]) && d[i] >= 0)
            idx.push(i);
    idx.sort(function (a, b) { return (d[a] - d[b]) || (a - b); });
    for (var k = 1; k < idx.length; k++) {
        var floor = d[idx[k - 1]] + gap;
        if (d[idx[k]] < floor) d[idx[k]] = floor;
    }
    return d;
}

// `history`: [{ appKey, t }] of the toasts that were SHOWN. An entry counts
// while nowMs - t < floodWindowMs. With `count` already shown in the window
// and count >= floodCount, this one would be one too many.
function floodCheck(history, appKey, nowMs, cfg) {
    var t = (cfg && _isObj(cfg.toasts)) ? cfg.toasts : _DEFAULTS.toasts;
    var limit = _num(t.floodCount) ? t.floodCount : _DEFAULTS.toasts.floodCount;
    var win = _num(t.floodWindowMs) ? t.floodWindowMs : _DEFAULTS.toasts.floodWindowMs;
    var list = Array.isArray(history) ? history : [];
    var n = 0;
    for (var i = 0; i < list.length; i++) {
        var h = list[i];
        if (h && h.appKey === appKey && _num(h.t) && nowMs - h.t < win)
            n++;
    }
    return { flooded: limit > 0 && n >= limit, count: n };
}

function heldRelease(held, reason) {
    var list = Array.isArray(held) ? held : [];
    var individual = [], rest = 0;
    for (var i = 0; i < list.length; i++) {
        var r = list[i];
        if (!r)
            continue;
        if (r.urgency === "critical")
            individual.push(r.uid);
        else
            rest++;
    }
    return {
        summary: rest > 0 ? { count: rest, reason: _str(reason) } : null,
        individual: individual
    };
}

// Unseen = not flagged seen AND touched after the manager was last opened.
function dotGroup(records, lastOpenedMs) {
    var list = Array.isArray(records) ? records : [];
    var last = _num(lastOpenedMs) ? lastOpenedMs : -Infinity;
    var best = GROUPS.length;
    for (var i = 0; i < list.length; i++) {
        var r = list[i];
        if (!r || r.seen || _updated(r) <= last)
            continue;
        var g = GROUPS.indexOf(r.group);
        if (g >= 0 && g < best)
            best = g;
    }
    return best < GROUPS.length ? GROUPS[best] : "";
}
