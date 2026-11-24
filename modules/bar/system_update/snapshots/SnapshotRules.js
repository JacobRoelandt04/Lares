.pragma library

// =============================================================================
// SnapshotRules.js -- when a snapshot is wanted and what it is called, with no Qt in it. The twin of
// tools/snapshot/root/snaprules.py (docs/contracts/snapshots.md section 4): both are held to ONE table,
// tools/dev/snapshot_rule_cases.json, which tools/dev/snapshot_cases.py runs through python and through node.
//
//   wants(names, settings)  -> { want, count, critical[] }   names = the packages the transaction upgrades or installs
//   notable(critical)       -> at most 4 names, in the critical list's order
//   title(record)           -> "Before 112 packages: linux, mesa" / "Manual" / "Before the restore of 2026-11-22"
//   matches(pattern, name)  -> `*` is the only wildcard, the whole name, case sensitive
//
// `settings` is the object the root tool's `status` reports under `settings`; a missing key takes the default below.
// =============================================================================

var DEFAULT_MIN_PACKAGES = 40
var DEFAULT_CRITICAL = [
    "linux", "linux-lts", "linux-zen", "linux-hardened", "linux-firmware", "nvidia*", "mesa", "glibc", "gcc-libs",
    "systemd", "systemd-libs", "grub", "mkinitcpio", "pacman", "pam", "sudo", "polkit", "sddm", "hyprland",
    "aquamarine", "quickshell*", "qt6-base", "qt6-declarative", "openssl", "util-linux", "e2fsprogs", "dbus",
    "wayland", "bash", "coreutils", "python"
]
var NOTABLE_MAX = 4
var TITLE_MAX = 60

function matches(pattern, name) {
    var parts = pattern.split("*")
    if (parts.length === 1)
        return pattern === name
    var first = parts[0], last = parts[parts.length - 1]
    if (name.indexOf(first) !== 0 || name.length - last.length < first.length
            || name.slice(name.length - last.length) !== last)
        return false
    var pos = first.length, end = name.length - last.length
    for (var i = 1; i < parts.length - 1; i++) {
        var at = name.indexOf(parts[i], pos)
        if (at < 0 || at + parts[i].length > end)
            return false
        pos = at + parts[i].length
    }
    return true
}

function _globs(settings) {
    var rule = (settings && settings.rule) || {}
    var list = (rule.critical !== undefined ? rule.critical : DEFAULT_CRITICAL).concat(rule.criticalAlso || [])
    var seen = {}, out = []
    for (var i = 0; i < list.length; i++) {
        if (!seen[list[i]]) {
            seen[list[i]] = true
            out.push(list[i])
        }
    }
    return out
}

function wants(names, settings) {
    var seenName = {}, uniq = []
    for (var i = 0; i < names.length; i++) {
        if (names[i] && !seenName[names[i]]) {
            seenName[names[i]] = true
            uniq.push(names[i])
        }
    }
    uniq.sort(function (a, b) { return a < b ? -1 : a > b ? 1 : 0 })   // code point order, as python's sorted()
    var globs = _globs(settings), crit = [], taken = {}
    for (var g = 0; g < globs.length; g++) {
        for (var n = 0; n < uniq.length; n++) {
            if (!taken[uniq[n]] && matches(globs[g], uniq[n])) {
                taken[uniq[n]] = true
                crit.push(uniq[n])
            }
        }
    }
    var rule = (settings && settings.rule) || {}
    var minPackages = rule.minPackages !== undefined ? rule.minPackages : DEFAULT_MIN_PACKAGES
    return { want: uniq.length >= minPackages || crit.length > 0, count: uniq.length, critical: crit }
}

function notable(critical) {
    return critical.slice(0, NOTABLE_MAX)
}

function _pad(n) {
    return (n < 10 ? "0" : "") + n
}

function _date(unix) {
    var d = new Date(unix * 1000)
    return d.getFullYear() + "-" + _pad(d.getMonth() + 1) + "-" + _pad(d.getDate())
}

function title(record) {
    if (record.reason === "manual")
        return "Manual"
    if (record.reason === "undo") {
        // `undoneTime`: the date of the snapshot that was undone (the root tool's `list` fills it from the record's note)
        return record.undoneTime ? "Before undoing the update of " + _date(record.undoneTime) : "Before an undo"
    }
    if (record.reason === "rescue")
        return "Before the restore of " + _date(record.time || 0)
    var head = "Before " + (record.count || 0) + " packages"
    var shown = notable(record.critical || [])
    while (shown.length > 0) {
        var t = head + ": " + shown.join(", ")
        if (t.length <= TITLE_MAX)
            return t
        shown = shown.slice(0, shown.length - 1)
    }
    return head
}
