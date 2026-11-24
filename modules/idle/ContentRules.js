.pragma library

// =============================================================================
// ContentRules.js -- who is asking the screen to stay on, with no Qt in it.
//
// `feed(state, line)` reads dbus-monitor's default output, a line at a time, for the two messages that say who holds org.freedesktop.ScreenSaver: the
// `Inhibit` / `UnInhibit` calls (a browser's video, a player: hypridle owns that name and answers them) and NameOwnerChanged (a holder that died never says
// UnInhibit). A holder is its sender, so the cookie in between need not be read. state = { holders: { sender: { n, app } }, wait } and it is never written in place.
// =============================================================================

function start() {
    return { holders: {}, wait: null };
}

function _sender(line) {
    var m = /\bsender=(\S+)/.exec(line);
    return m ? m[1] : "";
}

function _with(state, holders, wait) {
    return { holders: holders, wait: wait };
}

function _copy(o) {
    var c = {};
    for (var k in o)
        c[k] = o[k];
    return c;
}

function feed(state, line) {
    var s = String(line);
    // a message's header starts in the first column, its arguments are indented
    if (/^(method call|signal|method return|error) /.test(s)) {
        var member = /\bmember=(\w+)/.exec(s);
        var iface = /\binterface=([\w.]+)/.exec(s);
        var name = member ? member[1] : "";
        var fromIface = iface ? iface[1] : "";
        var holders = state.holders;
        if (s.indexOf("method call ") === 0 && fromIface === "org.freedesktop.ScreenSaver") {
            var who = _sender(s);
            if (name === "Inhibit" && who !== "") {
                holders = _copy(holders);
                holders[who] = { n: (holders[who] ? holders[who].n : 0) + 1, app: holders[who] ? holders[who].app : "" };
                return _with(state, holders, { what: "app", who: who });
            }
            if (name === "UnInhibit" && holders[who]) {
                holders = _copy(holders);
                if (holders[who].n > 1)
                    holders[who] = { n: holders[who].n - 1, app: holders[who].app };
                else
                    delete holders[who];
                return _with(state, holders, null);
            }
        }
        if (s.indexOf("signal ") === 0 && name === "NameOwnerChanged")
            return _with(state, holders, { what: "owner", seen: 0, name: "" });
        return _with(state, holders, null);
    }
    var w = state.wait;
    var arg = /^\s+string "(.*)"\s*$/.exec(s);
    if (w === null || !arg)
        return state;
    if (w.what === "app") {
        var hs = _copy(state.holders);
        if (hs[w.who])
            hs[w.who] = { n: hs[w.who].n, app: arg[1] };
        return _with(state, hs, null);
    }
    // NameOwnerChanged: name, old owner, new owner
    if (w.seen === 0)
        return _with(state, state.holders, { what: "owner", seen: 1, name: arg[1] });
    if (w.seen === 1)
        return _with(state, state.holders, { what: "owner", seen: 2, name: w.name });
    if (arg[1] === "" && state.holders[w.name]) {
        var left = _copy(state.holders);
        delete left[w.name];
        return _with(state, left, null);
    }
    return _with(state, state.holders, null);
}

// THE IGNORE LIST (idle.jsonc `contentIgnore`): the names of programs whose request to keep the screen on is not content. A program such as SDL's calls
// org.freedesktop.ScreenSaver.Inhibit for its whole life whatever it shows ("Playing a game": FreeRDP's SDL client, `sdl-freerdp3`), so the name it gives is
// the only thing that tells a remote desktop from a game. ONE list answers the three sources: the D-Bus holder's application name, a window's class
// and logind's `who`. A name matches EXACTLY (trimmed, case-insensitive): "sdl" must not swallow every SDL game.
function _key(name) {
    return String(name === undefined || name === null ? "" : name).trim().toLowerCase();
}

function ignores(list, name) {
    var k = _key(name);
    if (k === "" || !(list instanceof Array))
        return false;
    for (var i = 0; i < list.length; i++) {
        if (_key(list[i]) === k)
            return true;
    }
    return false;
}

// Split holders' names by the list: { kept: [...], ignored: [...] } (both in the order given).
function sift(list, names) {
    var kept = [];
    var ignored = [];
    for (var i = 0; i < names.length; i++)
        (ignores(list, names[i]) ? ignored : kept).push(names[i]);
    return { kept: kept, ignored: ignored };
}

// The holders' names, for the log.
function apps(state) {
    var out = [];
    for (var k in state.holders)
        out.push(state.holders[k].app || k);
    return out.sort();
}

// `hyprctl -j clients`: a window holding the idle off (a zwp inhibitor on a visible surface, or an idle_inhibit window rule). The shell's own inhibitor is on a layer, so it is
// never in this list: that is what makes this read different from an IdleMonitor's.
function windowHolds(json) {
    var list;
    try {
        list = JSON.parse(json);
    } catch (e) {
        return [];
    }
    if (!(list instanceof Array))
        return [];
    return list.filter(function (c) { return c && c.inhibitingIdle === true; }).map(function (c) { return String(c.class || c.title || "window"); });
}

// logind's ListInhibitors, as `busctl --json=short call ... ListInhibitors` prints it ({ "data": [[ [what, who, why, mode, uid, pid],
// ... ]] }): who holds a BLOCKING `idle` inhibitor (`systemd-inhibit --what=idle`), the shell's own excepted -- its hard mode holds
// one (who "lares"), and a hold of the shell's counted as content would hold the mode up by itself.
function logindWho(text) {
    var d;
    try {
        d = JSON.parse(String(text));
    } catch (e) {
        return [];
    }
    var rows = d && d.data && d.data[0];
    if (!rows || typeof rows.length !== "number")
        return [];
    var out = [];
    for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        if (!r || r.length < 4 || r[3] !== "block" || String(r[0]).split(":").indexOf("idle") < 0)
            continue;
        var who = String(r[1]);
        if (/^lares\b/.test(who))
            continue;
        out.push(who);
    }
    return out;
}

function logindHolds(text) {
    return logindWho(text).length > 0;
}
