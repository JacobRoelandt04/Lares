.pragma library

// =============================================================================
// FailedUnits.js -- the failed systemd units, as pure decisions (SOURCES.md, "Later sources").
//
// "failed systemd units (system or user; the action shows the journal tail)". `systemctl [--user] --failed --no-legend
// --plain` lists them; this reads that, says which are NEW (announced once per boot), and builds the command that
// shows a unit's journal tail.
//
//   parse(text, scope)               -> [{ unit, scope, description }]
//   ignored(unit, patterns)          a unit the user does not want to hear about (names or `*` globs)
//   memory(state, bootId)            the announced map that is still true: this boot's, else none
//   fresh(known, announced, okScopes) -> { added: [u], removed: [key], announced }
//   key(u)                           "system:foo.service"
//   tailCommand(unit, scope, lines)  the journalctl argv
//   copyCommand(unit, scope, lines)  that journal's last `lines` lines piped into wl-copy (a clipboard that is never empty)
//   title(u) / body(u) / tail(text, lines)
//
// ONCE PER BOOT: a unit that has been failed since the boot is told once (the shell restarting does not say it again),
// and a unit that recovers and fails again is told again. The memory is the caller's (sources.json) and carries the
// boot id. No Qt, no clock.
// =============================================================================

// "foo.service loaded failed failed Foo daemon" (a leading bullet from a terminal's output is tolerated).
function parse(text, scope) {
    var out = [];
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var l = lines[i].replace(/^[\s●*]+/, "");
        var m = /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*(.*)$/.exec(l);
        if (!m || m[3] !== "failed")
            continue;
        out.push({ unit: m[1], scope: scope === "user" ? "user" : "system", description: m[5].trim() });
    }
    return out;
}

function _glob(pat) {
    var re = String(pat).replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*").replace(/\?/g, ".");
    return new RegExp("^" + re + "$");
}

function ignored(unit, patterns) {
    var list = Array.isArray(patterns) ? patterns : [];
    for (var i = 0; i < list.length; i++)
        if (_glob(list[i]).test(unit))
            return true;
    return false;
}

function key(u) {
    return u.scope + ":" + u.unit;
}

// What the state file remembers is true only for the boot it was written in (a unit failed since an earlier boot is a
// new failure, and a boot id that cannot be read remembers nothing).
function memory(state, bootId) {
    return bootId !== "" && state && state.boot === bootId && state.announced && typeof state.announced === "object" ? state.announced : {};
}

// `known` = every failed unit now (both scopes); `announced` = { key: true } told this boot; `okScopes` = { system: bool,
// user: bool } which of the two lists could be read this time (a list that could not be read says nothing: its units are
// neither recovered nor new). -> the ones not told yet, the keys that are no longer failed, and the announced map.
function fresh(known, announced, okScopes) {
    var out = { added: [], removed: [], announced: {} };
    var now = {};
    for (var i = 0; i < known.length; i++) {
        var k = key(known[i]);
        now[k] = true;
        if (announced && announced[k]) {
            out.announced[k] = true;
        } else {
            out.added.push(known[i]);
            out.announced[k] = true;
        }
    }
    for (var a in (announced || {})) {
        if (!Object.prototype.hasOwnProperty.call(announced, a) || now[a])
            continue;
        if (okScopes && okScopes[a.split(":")[0]] === false)
            out.announced[a] = true;
        else
            out.removed.push(a);
    }
    return out;
}

function tailCommand(unit, scope, lines) {
    var argv = ["journalctl"];
    if (scope === "user")
        argv.push("--user");
    return argv.concat(["-u", unit, "-n", String(lines), "--no-pager", "-o", "cat"]);
}

// The whole log for the clipboard: the same journalctl, read into a variable (no argument carries it: a journal outgrows one),
// and handed to wl-copy only when it said something -- an unreadable or empty journal must not clear what the user had copied.
function copyCommand(unit, scope, lines) {
    return ["sh", "-c", 'out=$("$@") || exit 1; [ -n "$out" ] || exit 1; printf "%s\\n" "$out" | wl-copy', "sh"].concat(tailCommand(unit, scope, lines));
}

function _short(unit) {
    return unit.replace(/\.service$/, "");
}

function title(u) {
    return _short(u.unit) + " failed";
}

function body(u) {
    var d = u.description !== "" ? u.description : "systemd unit " + u.unit;
    return u.scope === "user" ? d + " (user)" : d;
}

// The last `lines` lines of the journal, each cut to a line a card can hold, blank ones gone.
function tail(text, lines) {
    var all = String(text === undefined || text === null ? "" : text).split("\n").map(function (l) { return l.trim(); }).filter(function (l) { return l !== ""; });
    return all.slice(Math.max(0, all.length - lines)).map(function (l) { return l.length > 160 ? l.substring(0, 157) + "..." : l; });
}
