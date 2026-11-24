.pragma library

// =============================================================================
// CardwireParse.js -- silicon's reading and writing of cardwire's D-Bus, as PLAIN VALUES.
// Pure functions: nothing here starts a process, reads a file or touches a bus.
//
// TWO SOURCES, both read with plain tools (`busctl monitor` is denied on this machine):
//
//   busctl --system --json=short get-property|call ...
//       {"type":"u","data":1}                          a property: `data` IS the value
//       {"type":"au","data":[[0,1,3]]}                 a method call: `data` is the ARRAY
//       {"type":"s","data":["D3cold\n"]}               OF RETURN VALUES (one here)
//     -> parseReply(text) then one of the typed readers below.
//
//   gdbus monitor --system --dest org.opengamingcollective.cardwire     (GVariant text)
//       /org/opengamingcollective/cardwire/Gpu/1: ...Gpu.PowerStateChanged ('D0',)
//     -> monitorEvent(line) (parseGVariant for the argument tuple).
//
// `bus` below is "system" (the shell) or "session" (a test's PRIVATE bus: busctl --user,
// gdbus --session); nothing else is ever named, so a test cannot reach the system bus by
// accident.
//
// EVERY reader is total: a reply that is not the expected shape comes back as
// { ok: false, why }, never as a throw and never as a guess.
//
// FACTS (cardwire 0.12.3, as measured):
//   * Mode u: 0 Integrated, 1 Hybrid, 2 Manual, 3 Smart. AvailableModes here [0,1,3]; in dGPU-only
//     wiring cardwire refuses 0 and 3 and the list shrinks.
//   * Gpu.PowerState is a METHOD returning the raw sysfs text -- "D3cold\n" -- while the
//     PowerStateChanged SIGNAL prints the Rust enum's Debug name: 'D0', 'D3Cold', 'D3Hot'.
//     powerStateName() reads both into D0 | D1 | D2 | D3hot | D3cold.
//   * GetAppPolicies a{s(sasasu)}: binary name -> (display name, desktop file ids, icon names,
//     policy u). Policy 0 Blocked, 1 Allowed. It lists EVERY app the daemon has seen (kitty,
//     quickshell, ...), in a different order on every call: sort by name, and filter (below).
//   * Lsof a{sas}: device node -> process NAMES (the kernel's 15-char comm). cardwired and
//     nvidia-persistenced hold the nodes themselves; Hyprland and code hold /dev/nvidiactl
//     without using the dGPU; and the session (Hyprland, Xwayland, Xorg, systemd, systemd-logind)
//     holds the card's own nodes while it sleeps. Who USES the card is derived
//     (lsofHolders), not raw.
//   * GetDevice: 12 values "ssuubbbbssbs" -- name, pci, render minor, card minor, default,
//     discrete, ?, ?, vendor, driver, blocked, ?. Where the busctl JSON puts them (flat, or as
//     one struct) is accepted both ways.
// =============================================================================

var BUS = "org.opengamingcollective.cardwire";
var OBJ = "/org/opengamingcollective/cardwire";

var MODE_NAMES = ["integrated", "hybrid", "manual", "smart"];

// Config's properties and the D-Bus type each carries (all read-write on the bus). The keys
// silicon's contract names (CONTRACT section 2, `gpu.config`) map onto them.
var CONFIG_TYPES = {
    AutoApplyGpuState: "b",
    BatteryAutoSwitch: "b",
    BatteryAutoSwitchMode: "u",
    ExperimentalNvidiaBlock: "b",
    ExternalDisplayAutoSwitch: "b"
};
var CONFIG_KEYS = {
    batteryAutoSwitch: "BatteryAutoSwitch",
    batteryAutoSwitchMode: "BatteryAutoSwitchMode",
    externalDisplayAutoSwitch: "ExternalDisplayAutoSwitch",
    nvidiaBlock: "ExperimentalNvidiaBlock"
};

// Processes that hold the dGPU's nodes as plumbing, not as users ("nvidia-persiste" is
// nvidia-persistenced cut to the kernel's 15-character comm).
var INFRA_HOLDERS = ["cardwired", "nvidia-persiste", "nvidia-persistenced"];

// SESSION PLUMBING. With the dGPU runtime-SUSPENDED, cardwire's `Gpu Lsof` shows the NVIDIA card's nodes held by Hyprland and
// Xwayland (/dev/dri/card0), Xorg (renderD129, /dev/nvidia0), systemd and systemd-logind (card0). They hold the card WHILE
// IT SLEEPS, so holding it keeps nothing awake -- and cardwire blocks only NEW opens, so a switch to Integrated or Smart cuts
// nothing running off (the session stays intact with all five up). They are never users:
// the warning, the caption's "in use by" and nvidia-smi's gate all read `holders`, and a Steam game or anything else that
// opens the card for work still lands in it. Matched on the lowercased kernel comm (all five are under 15 characters).
var SESSION_HOLDERS = ["hyprland", "xwayland", "xorg", "systemd", "systemd-logind"];

// WHO MAY HOLD THE dGPU WITHOUT BEING ASKED ABOUT (the list is in the silicon config, so a program that should not count is added
// there, not here). The default of silicon.jsonc's
// `gpu.ignoredHolders`: the daemons, the session, and the watchers -- btop and nvidia-smi only LOOK at the card, which keeps it out of D3cold
// for as long as they run, and switching to Integrated or Smart cuts nothing off it (cardwire blocks only NEW opens). The service hands
// the file's list to `lsofHolders`; with none given this is the list. Matched on the lowercased kernel comm, the WHOLE name (a name that
// only starts like one of these is a user).
//
// NVIDIA-SMI AND QUICKSHELL ARE SILICON'S OWN. The shell asks nvidia-smi on the stats beat while the card is awake and has a user, and
// reads the holders on that same beat: the Lsof catches the shell's own query holding /dev/nvidia0, so if "nvidia-smi" counted as a user
// the gate that lets the next query run would stay open after the last real user had gone, and every beat's query would catch the next --
// a loop that keeps the card awake, "in use by nvidia-smi", with a step to Integrated or Smart refused until confirmed (the card's blocked
// animation waits for that, and it never comes). A query the shell makes is not a user whoever's name it wears, and the shell itself
// (quickshell, the session's own plumbing, like Hyprland) is not one either.
var IGNORED_HOLDERS = INFRA_HOLDERS.concat(SESSION_HOLDERS, ["btop", "nvidia-smi", "quickshell"]);

function modeName(n) {
    return (n >= 0 && n < MODE_NAMES.length) ? MODE_NAMES[n] : "unknown";
}

// --- argv builders (the ONLY argv lists the data layer ever starts for cardwire) ----------

function gpuPath(index) {
    return OBJ + "/Gpu/" + index;
}

function _busctl(bus) {
    return ["busctl", bus === "session" ? "--user" : "--system", "--json=short"];
}

function getPropertyArgv(bus, path, iface, prop) {
    return _busctl(bus).concat(["get-property", BUS, path, iface, prop]);
}

function callArgv(bus, path, iface, method, sig, args) {
    var a = _busctl(bus).concat(["call", BUS, path, iface, method]);
    if (sig)
        a = a.concat([sig], (args || []).map(String));
    return a;
}

function setPropertyArgv(bus, path, iface, prop, sig, value) {
    return _busctl(bus).concat(["set-property", BUS, path, iface, prop, sig, String(value)]);
}

// The passive monitor: pdeathsig so it dies with the shell however the shell dies.
function monitorArgv(bus) {
    return ["setpriv", "--pdeathsig", "TERM", "--", "gdbus", "monitor",
            bus === "session" ? "--session" : "--system", "--dest", BUS];
}

function modeArgv(bus) { return getPropertyArgv(bus, OBJ, BUS + ".Mode", "Mode"); }
function availableModesArgv(bus) { return callArgv(bus, OBJ, BUS + ".Mode", "AvailableModes"); }
function policiesArgv(bus) { return callArgv(bus, OBJ, BUS + ".SmartPolicy", "GetAppPolicies"); }
function blockedLogArgv(bus) { return callArgv(bus, OBJ, BUS + ".Logger", "ProcessBlocked"); }
function deviceArgv(bus, gpu) { return callArgv(bus, gpuPath(gpu), BUS + ".Gpu", "GetDevice"); }
function powerArgv(bus, gpu) { return callArgv(bus, gpuPath(gpu), BUS + ".Gpu", "PowerState"); }
function lsofArgv(bus, gpu) { return callArgv(bus, gpuPath(gpu), BUS + ".Gpu", "Lsof"); }
function configArgv(bus, prop) { return getPropertyArgv(bus, OBJ, BUS + ".Config", prop); }

// The writes. `mode` is cardwire's own number; `key` a contract key (CONFIG_KEYS); a policy is
// 0 Blocked | 1 Allowed. A value that is not what the call takes gives null, never an argv.
function setModeArgv(bus, mode) {
    if (typeof mode !== "number" || mode < 0 || mode !== Math.floor(mode))
        return null;
    return setPropertyArgv(bus, OBJ, BUS + ".Mode", "Mode", "u", mode);
}

function setConfigArgv(bus, key, value) {
    var prop = CONFIG_KEYS[key];
    if (!prop || !CONFIG_TYPES.hasOwnProperty(prop))
        return null;
    if (CONFIG_TYPES[prop] === "b")
        return typeof value === "boolean" ? setPropertyArgv(bus, OBJ, BUS + ".Config", prop, "b", value ? "true" : "false") : null;
    return (typeof value === "number" && value >= 0 && value === Math.floor(value))
        ? setPropertyArgv(bus, OBJ, BUS + ".Config", prop, "u", value) : null;
}

function setPolicyArgv(bus, app, allowed) {
    if (typeof app !== "string" || app === "")
        return null;
    return callArgv(bus, OBJ, BUS + ".SmartPolicy", "SetAppPolicy", "si", [app, allowed ? 1 : 0]);
}

// --- busctl ------------------------------------------------------------------------------

// The text busctl printed -> { ok, type, data } | { ok: false, why }
function parseReply(text) {
    var o;
    var s = String(text === undefined || text === null ? "" : text);
    try {
        o = JSON.parse(s);
    } catch (e) {
        return { ok: false, why: "not JSON (" + e.message + "): " + s.slice(0, 80) };
    }
    if (!o || typeof o !== "object" || typeof o.type !== "string" || !("data" in o))
        return { ok: false, why: "no type/data in: " + s.slice(0, 80) };
    return { ok: true, type: o.type, data: o.data };
}

// A method call's single return value (data is the array of returns), or fail.
function _ret1(r, type) {
    if (!r || !r.ok)
        return { ok: false, why: r ? r.why : "no reply" };
    if (r.type !== type)
        return { ok: false, why: "type " + r.type + ", wanted " + type };
    if (!Array.isArray(r.data) || r.data.length !== 1)
        return { ok: false, why: "a call's data should be a 1-element array of returns" };
    return { ok: true, value: r.data[0] };
}

// A property's value (data IS the value), or fail.
function _prop(r, type) {
    if (!r || !r.ok)
        return { ok: false, why: r ? r.why : "no reply" };
    if (r.type !== type)
        return { ok: false, why: "type " + r.type + ", wanted " + type };
    return { ok: true, value: r.data };
}

// get-property ... Mode Mode   {"type":"u","data":1}
function readMode(r) {
    var p = _prop(r, "u");
    if (!p.ok)
        return p;
    if (typeof p.value !== "number" || p.value < 0 || p.value !== Math.floor(p.value))
        return { ok: false, why: "Mode is not a small integer: " + p.value };
    return { ok: true, mode: p.value, name: modeName(p.value) };
}

// call ... AvailableModes      {"type":"au","data":[[0,1,3]]}
function readAvailableModes(r) {
    var p = _ret1(r, "au");
    if (!p.ok)
        return p;
    if (!Array.isArray(p.value) || !p.value.every(function (x) { return typeof x === "number"; }))
        return { ok: false, why: "AvailableModes is not an array of integers" };
    return { ok: true, modes: p.value.slice(), names: p.value.map(modeName) };
}

// call ... GetAppPolicies      {"type":"a{s(sasasu)}","data":[{"code":["Visual Studio Code ...",["code-url-handler"],["vscode"],0], ...}]}
// -> every app the daemon knows, sorted by display name (then id: names can repeat).
function readAppPolicies(r) {
    var p = _ret1(r, "a{s(sasasu)}");
    if (!p.ok)
        return p;
    var d = p.value;
    if (!d || typeof d !== "object" || Array.isArray(d))
        return { ok: false, why: "GetAppPolicies is not a dictionary" };
    var apps = [];
    var keys = Object.keys(d);
    for (var i = 0; i < keys.length; i++) {
        var v = d[keys[i]];
        if (!Array.isArray(v) || v.length !== 4 || typeof v[0] !== "string"
                || !Array.isArray(v[1]) || !Array.isArray(v[2]) || typeof v[3] !== "number")
            return { ok: false, why: "app '" + keys[i] + "' is not (s, as, as, u)" };
        apps.push({ id: keys[i], name: v[0], desktopIds: v[1].slice(), icons: v[2].slice(), policy: v[3] });
    }
    apps.sort(function (a, b) {
        var an = a.name.toLowerCase(), bn = b.name.toLowerCase();
        return an < bn ? -1 : an > bn ? 1 : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
    });
    return { ok: true, apps: apps };
}

// The apps silicon lists (`gpu.policies`): only those the user CHOSE (policy 1, Allowed: every
// app starts at 0) or that were BLOCKED at least once (`blocked`: ids and comms seen in the
// daemon's log or its live signal). GetAppPolicies lists every app the daemon has ever seen,
// kitty and quickshell among them; none of those is a choice anybody made. Order is kept.
function filterPolicies(apps, blocked) {
    var seen = {};
    (blocked || []).forEach(function (b) { seen[String(b).toLowerCase()] = true; });
    return (apps || []).filter(function (a) {
        return a.policy === 1 || seen[a.id.toLowerCase()] === true
            || a.desktopIds.some(function (d) { return seen[String(d).toLowerCase()] === true; });
    });
}

// "D3cold\n" (the method), "D3Cold" (the signal), " d0 " -> "D3cold" | "D0" | ...
function powerStateName(raw) {
    var k = String(raw === undefined || raw === null ? "" : raw).replace(/^\s+|\s+$/g, "").toLowerCase();
    var canon = { d0: "D0", d1: "D1", d2: "D2", d3hot: "D3hot", d3cold: "D3cold" };
    return canon.hasOwnProperty(k) ? canon[k] : "";
}

// call ... Gpu PowerState      {"type":"s","data":["D3cold\n"]}
function readPowerState(r) {
    var p = _ret1(r, "s");
    if (!p.ok)
        return p;
    var name = powerStateName(p.value);
    if (name === "")
        return { ok: false, why: "unknown power state: " + JSON.stringify(p.value) };
    return { ok: true, raw: p.value, state: name, awake: name === "D0" };
}

// Who is USING the dGPU: the names on ITS OWN nodes -- its DRM card, its render node and its
// /dev/nvidiaN, as the helper's status resolves them from the PCI device (never hard-coded: a
// kernel may renumber them) -- minus the names in `ignored` (the config's list; IGNORED_HOLDERS when none is
// given: the daemons, INFRA_HOLDERS, the session's own processes, SESSION_HOLDERS, and the harmless watchers).
// /dev/nvidiactl never counts, whatever the caller hands over: Hyprland and VS Code hold it without using the card.
// Sorted, unique. With no nodes known there is no answer, and no answer is no holders (nvidia-smi then never
// runs: asking would wake the card).
function lsofHolders(devices, nodes, ignored) {
    var seen = {};
    var out = [];
    var list = nodes || [];
    var skip = (Array.isArray(ignored) ? ignored : IGNORED_HOLDERS).map(function (x) { return String(x).toLowerCase(); });
    for (var i = 0; i < list.length; i++) {
        if (typeof list[i] !== "string" || list[i] === "" || list[i] === "/dev/nvidiactl")
            continue;
        var names = (devices && devices[list[i]]) || [];
        for (var j = 0; j < names.length; j++) {
            var n = names[j];
            if (skip.indexOf(String(n).toLowerCase()) >= 0 || seen[n])
                continue;
            seen[n] = true;
            out.push(n);
        }
    }
    out.sort();
    return out;
}

// call ... Gpu Lsof            {"type":"a{sas}","data":[{"/dev/nvidia0":["cardwired","nvidia-persiste"], ...}]}
function readLsof(r, nodes, ignored) {
    var p = _ret1(r, "a{sas}");
    if (!p.ok)
        return p;
    var d = p.value;
    if (!d || typeof d !== "object" || Array.isArray(d))
        return { ok: false, why: "Lsof is not a dictionary" };
    var devices = {};
    var keys = Object.keys(d);
    for (var i = 0; i < keys.length; i++) {
        if (!Array.isArray(d[keys[i]]) || !d[keys[i]].every(function (x) { return typeof x === "string"; }))
            return { ok: false, why: "Lsof entry '" + keys[i] + "' is not an array of strings" };
        devices[keys[i]] = d[keys[i]].slice();
    }
    return { ok: true, devices: devices, holders: lsofHolders(devices, nodes, ignored) };
}

// call ... Gpu GetDevice       {"type":"ssuubbbbssbs","data":[name, pci, render, card, default, discrete, ...]}
// (or the same twelve as ONE struct: type "(ssuubbbbssbs)", data [[...]]).
function readGetDevice(r) {
    if (!r || !r.ok)
        return { ok: false, why: r ? r.why : "no reply" };
    var v = null;
    if (r.type === "ssuubbbbssbs" && Array.isArray(r.data) && r.data.length === 12)
        v = r.data;
    else if (r.type === "(ssuubbbbssbs)" && Array.isArray(r.data) && r.data.length === 1
             && Array.isArray(r.data[0]) && r.data[0].length === 12)
        v = r.data[0];
    if (v === null)
        return { ok: false, why: "GetDevice is not ssuubbbbssbs" };
    return {
        ok: true, name: v[0], pci: v[1], renderMinor: v[2], cardMinor: v[3],
        isDefault: v[4] === true, isDiscrete: v[5] === true, vendor: v[8], driver: v[9], blocked: v[10] === true
    };
}

// call ... Logger ProcessBlocked   {"type":"a((tu)usus)","data":[[[[secs,nanos],pid,comm,gpu,app], ...]]}
function readBlockedLog(r) {
    var p = _ret1(r, "a((tu)usus)");
    if (!p.ok)
        return p;
    if (!Array.isArray(p.value))
        return { ok: false, why: "ProcessBlocked is not an array" };
    var log = [];
    for (var i = 0; i < p.value.length; i++) {
        var e = p.value[i];
        if (!Array.isArray(e) || e.length !== 5 || !Array.isArray(e[0]) || e[0].length !== 2
                || typeof e[1] !== "number" || typeof e[2] !== "string" || typeof e[3] !== "number" || typeof e[4] !== "string")
            return { ok: false, why: "entry " + i + " of ProcessBlocked is not ((tu)usus)" };
        log.push({ secs: e[0][0], nanos: e[0][1], pid: e[1], comm: e[2], gpuId: e[3], appId: e[4] });
    }
    return { ok: true, log: log };
}

// The id a blocked process is listed under: the Wayland app id when it has one, else its comm.
function blockedId(entry) {
    return entry.appId !== "" ? entry.appId : entry.comm;
}

// get-property ... Config <key>
function readConfig(key, r) {
    if (!CONFIG_TYPES.hasOwnProperty(key))
        return { ok: false, why: "unknown Config property " + key };
    var p = _prop(r, CONFIG_TYPES[key]);
    if (!p.ok)
        return p;
    if (CONFIG_TYPES[key] === "b" && typeof p.value !== "boolean")
        return { ok: false, why: key + " is not a boolean: " + p.value };
    if (CONFIG_TYPES[key] === "u" && typeof p.value !== "number")
        return { ok: false, why: key + " is not a number: " + p.value };
    return { ok: true, key: key, value: p.value };
}

// busctl's stderr for a refused write ("Call failed: mode 3 (Smart) is not available...") -> the
// plain words a caption can show.
function errorText(stderr, code) {
    var t = String(stderr === undefined || stderr === null ? "" : stderr).trim().split("\n")[0].trim();
    t = t.replace(/^Call failed:\s*/i, "").replace(/^Failed to set property [^:]*:\s*/i, "");
    return t !== "" ? t : "cardwire answered with an error (exit " + code + ")";
}

// --- GVariant text (what gdbus prints) ---------------------------------------
//
// ('D0',)                                   -> ["D0"]
// ('iface', {'Mode': <uint32 3>}, @as [])    -> ["iface", {Mode: 3}, []]
// ((uint64 17, uint32 4242, 'x'),)           -> [[17, 4242, "x"]]
// Numbers lose their width (uint32 3 -> 3), variants unwrap, `@type` annotations
// are skipped, a dictionary becomes an object, `true`/`false`/`nothing` are
// what they say. Never throws: { ok, value } or { ok: false, why, at }.

var _NUM_WORDS = ["byte", "int16", "uint16", "int32", "uint32", "int64", "uint64", "double", "handle"];

function parseGVariant(src) {
    var s = String(src === undefined || src === null ? "" : src);
    var i = 0;

    function fail(why) {
        var e = new Error(why);
        e.gvAt = i;
        throw e;
    }
    function ws() {
        while (i < s.length && /\s/.test(s.charAt(i)))
            i++;
    }
    function expect(ch) {
        ws();
        if (s.charAt(i) !== ch)
            fail("expected '" + ch + "', found '" + s.charAt(i) + "'");
        i++;
    }
    function str(q) {
        i++;
        var out = "";
        while (i < s.length && s.charAt(i) !== q) {
            var c = s.charAt(i++);
            if (c !== "\\") {
                out += c;
                continue;
            }
            var e = s.charAt(i++);
            var map = { n: "\n", t: "\t", r: "\r", a: "\x07", b: "\b", f: "\f", v: "\v", "\\": "\\", "'": "'", "\"": "\"" };
            if (map.hasOwnProperty(e))
                out += map[e];
            else if (e === "u" || e === "U") {
                var n = e === "u" ? 4 : 8;
                var hex = s.substr(i, n);
                if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length !== n)
                    fail("bad \\" + e + " escape");
                out += String.fromCodePoint(parseInt(hex, 16));
                i += n;
            } else
                fail("bad escape \\" + e);
        }
        if (s.charAt(i) !== q)
            fail("unterminated string");
        i++;
        return out;
    }
    function list(close) {
        var out = [];
        ws();
        if (s.charAt(i) === close) {
            i++;
            return out;
        }
        for (;;) {
            out.push(value());
            ws();
            if (s.charAt(i) === ",") {
                i++;
                ws();
                if (s.charAt(i) === close) {       // the 1-tuple's trailing comma
                    i++;
                    return out;
                }
                continue;
            }
            if (s.charAt(i) === close) {
                i++;
                return out;
            }
            fail("expected ',' or '" + close + "'");
        }
    }
    function dict() {
        i++;
        var out = {};
        ws();
        if (s.charAt(i) === "}") {
            i++;
            return out;
        }
        for (;;) {
            var k = value();
            expect(":");
            out[String(k)] = value();
            ws();
            if (s.charAt(i) === ",") {
                i++;
                continue;
            }
            expect("}");
            return out;
        }
    }
    function value() {
        ws();
        if (i >= s.length)
            fail("unexpected end");
        var c = s.charAt(i);
        if (c === "(") {
            i++;
            return list(")");
        }
        if (c === "[") {
            i++;
            return list("]");
        }
        if (c === "{")
            return dict();
        if (c === "<") {
            i++;
            var v = value();
            expect(">");
            return v;
        }
        if (c === "'" || c === "\"")
            return str(c);
        if (c === "@") {                           // @as [] / @a{sv} {} : the type is not needed
            i++;
            while (i < s.length && !/\s/.test(s.charAt(i)))
                i++;
            return value();
        }
        var rest = s.slice(i);
        var m = /^(true|false|nothing)(?![A-Za-z0-9_])/.exec(rest);
        if (m) {
            i += m[0].length;
            return m[1] === "true" ? true : m[1] === "false" ? false : null;
        }
        m = /^(just)\s+/.exec(rest);
        if (m) {
            i += m[0].length;
            return value();
        }
        m = /^([a-z0-9]+)\s+(?=['"0-9\-])/.exec(rest);
        if (m && (_NUM_WORDS.indexOf(m[1]) >= 0 || m[1] === "objectpath" || m[1] === "signature")) {
            i += m[0].length;
            return value();
        }
        m = /^-?(?:0[xX][0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][+\-]?\d+)?|inf|nan)/.exec(rest);
        if (m) {
            i += m[0].length;
            return /^-?0[xX]/.test(m[0]) ? parseInt(m[0], 16) : Number(m[0]);
        }
        fail("unexpected '" + c + "'");
        return null;
    }

    try {
        var out = value();
        ws();
        if (i < s.length)
            fail("trailing text");
        return { ok: true, value: out };
    } catch (e) {
        return { ok: false, why: e.message, at: e.gvAt === undefined ? i : e.gvAt };
    }
}

// One line of `gdbus monitor` -> an event (a plain object with `kind`), never a throw:
//   header      Monitoring signals from all objects owned by <name>
//   owner       The name <name> is owned by :1.13
//   ownerLost   The name <name> does not have an owner
//   gpuPower    PowerStateChanged  { gpu, state: D0|D1|D2|D3hot|D3cold, awake }
//   mode        PropertiesChanged on .Mode   { mode, name }
//   config      PropertiesChanged on .Config { changes: {Key: value}, invalidated }
//   processBlocked  Logger.ProcessBlockedChanged { log: {secs, nanos, pid, comm, gpuId, appId} }
//               LogEntry ((tu)usus) in cardwire 0.12.3 (interface/logger.rs: timestamp as
//               SystemTime = (secs u64, nanos u32), pid, comm, gpu_id, wayland_app_id)
//   newApp      SmartPolicy.NewAppAdded { app: {id, name, desktopIds, icons, policy} }
//               (s(sasasu)) (interface/smart.rs: (lookup name, DbusAppMetadata), the
//               Options as 0/1-element arrays like GetAppPolicies)
//   Both are typed from the SOURCE.
//   signal      any other signal { path, iface, member, args }
//   other       anything else (kept whole)  /  bad  a signal whose arguments did not parse
function monitorEvent(line) {
    var l = String(line === undefined || line === null ? "" : line).replace(/\s+$/, "");
    var m = /^Monitoring signals from all objects owned by (\S+)$/.exec(l);
    if (m)
        return { kind: "header", name: m[1] };
    m = /^The name (\S+) is owned by (\S+)$/.exec(l);
    if (m)
        return { kind: "owner", name: m[1], owner: m[2] };
    m = /^The name (\S+) does not have an owner$/.exec(l);
    if (m)
        return { kind: "ownerLost", name: m[1] };
    m = /^(\/\S*): ([A-Za-z0-9_.]+)\.([A-Za-z0-9_]+) (\(.*\))$/.exec(l);
    if (!m)
        return { kind: "other", line: l };
    var path = m[1], iface = m[2], member = m[3];
    var a = parseGVariant(m[4]);
    if (!a.ok || !Array.isArray(a.value))
        return { kind: "bad", line: l, why: a.ok ? "arguments are not a tuple" : a.why };
    var args = a.value;
    var gpu = /\/Gpu\/(\d+)$/.exec(path);

    if (iface === BUS + ".Gpu" && member === "PowerStateChanged") {
        var st = powerStateName(args[0]);
        if (st === "" || !gpu)
            return { kind: "bad", line: l, why: "PowerStateChanged without a known state or Gpu/N path" };
        return { kind: "gpuPower", gpu: Number(gpu[1]), state: st, awake: st === "D0" };
    }
    if (iface === "org.freedesktop.DBus.Properties" && member === "PropertiesChanged" && args.length === 3) {
        var target = String(args[0]);
        var changed = args[1] && typeof args[1] === "object" ? args[1] : {};
        var inval = Array.isArray(args[2]) ? args[2] : [];
        if (target === BUS + ".Mode") {
            if (typeof changed.Mode === "number")
                return { kind: "mode", mode: changed.Mode, name: modeName(changed.Mode), invalidated: inval };
            return { kind: "mode", mode: null, name: "", invalidated: inval };
        }
        if (target === BUS + ".Config")
            return { kind: "config", changes: changed, invalidated: inval };
    }
    if (iface === BUS + ".Logger" && member === "ProcessBlockedChanged") {
        var e = args.length === 1 ? args[0] : null;
        if (!Array.isArray(e) || e.length !== 5 || !Array.isArray(e[0]) || e[0].length !== 2
                || typeof e[1] !== "number" || typeof e[2] !== "string" || typeof e[3] !== "number" || typeof e[4] !== "string")
            return { kind: "bad", line: l, why: "ProcessBlockedChanged is not ((tu)usus)" };
        return { kind: "processBlocked", log: { secs: e[0][0], nanos: e[0][1], pid: e[1], comm: e[2], gpuId: e[3], appId: e[4] } };
    }
    if (iface === BUS + ".SmartPolicy" && member === "NewAppAdded") {
        var n = args.length === 1 ? args[0] : null;
        var md = Array.isArray(n) && n.length === 2 ? n[1] : null;
        if (md === null || typeof n[0] !== "string" || !Array.isArray(md) || md.length !== 4 || typeof md[0] !== "string"
                || !Array.isArray(md[1]) || !Array.isArray(md[2]) || typeof md[3] !== "number")
            return { kind: "bad", line: l, why: "NewAppAdded is not (s(sasasu))" };
        return { kind: "newApp", app: { id: n[0], name: md[0], desktopIds: md[1].slice(), icons: md[2].slice(), policy: md[3] } };
    }
    return { kind: "signal", path: path, iface: iface, member: member, args: args };
}
