.pragma library

// =============================================================================
// BridgeModel.js -- the bridge's data rules, pure (no Qt, loads under node with the pragma line cut).
//
// The tool (tools/bridge/lares-bridge) prints one JSON object per line on `watch` (docs/contracts/bridge.md section 3). This file
// is everything the service does to such a line that needs no object:
//
//   parseLine(text)        -> { ok: true, line } | { ok: false, error }   total: never throws. A line that is not JSON, not an
//                             object, of another version, or the tool's own `{"v":1,"error":"..."}` is an error, not a state.
//   normalise(raw)         -> the line with every field of <device> / <job> present at its NEUTRAL value (null for an absent
//                             sub-object, "" / 0 / false otherwise), so the QML never reads `undefined`. Unknown extra fields
//                             are dropped; duplicate device keys keep the first.
//   diffKeys(old, new)     -> { added, removed, reordered, changed }: what a row model must do to follow
//   busyOf(jobs)           -> a send job is starting or running (the idle cause)
//   actKey(action, which)  -> the `can` / `acts` key an action of the service stands for ("" = not tracked)
//   argvOf(action, key, a) -> the tool's argv for an action (after the program), or null when the request is malformed
//   timeoutOf(action)      -> how long a one-shot may take, ms
//   canOf(d, ak)           -> d.can[ak] (neutral when absent)
//   words: linkWords, stateLine, bytesWords, sendBody, sendClosing, failureWords, recordToast
//          Facts of the line put into words. A REASON is never made up here: `can.<x>.why` / `.hint` and a job's `reason`
//          come from the tool and are only passed through.
//   parseConfig(obj)       -> config/bridge.jsonc (section 7) with every value defaulted / clamped
// =============================================================================

var ACTIONS = ["mirror", "mountUsb", "mountWifi", "send", "shot", "ring", "clip", "key", "pair", "unpair", "arm", "facts", "unlock", "usbcalm"];
var TYPES = ["phone", "tablet", "desktop", "laptop", "tv"];
var LINKS = ["none", "wifi", "usb", "both"];
var MOUNT_STATES = ["unmounted", "mounting", "mounted", "stale"];
var PHASES = ["starting", "running", "done", "failed"];
var PREFS = ["keepWireless", "mode", "screenOff", "record", "wifiDebug", "castAudio"];
var PAIR_STATES = ["waiting", "paired", "failed", "expired"];
var MODES = ["mirror", "desktop", "camera", "audio"];
var KEYS = ["power", "volup", "voldown"];
// the unlock PIN in the keyring: none kept, kept, or failed its one try (it is not tried again until it is set again)
var PIN_STATES = ["none", "set", "failed"];

// ---- tiny coercions ---------------------------------------------------------------------------------------------------

function _obj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v) ? v : {};
}
function _isObj(v) {
    return v !== null && typeof v === "object" && !Array.isArray(v);
}
function _str(v, d) {
    return typeof v === "string" ? v : (d === undefined ? "" : d);
}
function _bool(v, d) {
    return typeof v === "boolean" ? v : (d === undefined ? false : d);
}
function _num(v, d) {
    return typeof v === "number" && isFinite(v) ? v : (d === undefined ? 0 : d);
}
function _int(v, d, lo, hi) {
    var n = typeof v === "number" && isFinite(v) ? Math.round(v) : d;
    if (lo !== undefined && n < lo)
        n = lo;
    if (hi !== undefined && n > hi)
        n = hi;
    return n;
}
function _oneOf(v, list, d) {
    return typeof v === "string" && list.indexOf(v) >= 0 ? v : d;
}
function _strs(v) {
    var out = [];
    if (v && typeof v.length === "number" && typeof v !== "string") {
        for (var i = 0; i < v.length; i++)
            if (typeof v[i] === "string")
                out.push(v[i]);
    }
    return out;
}

// ---- the line -----------------------------------------------------------------------------------------------------

function _can(c) {
    var src = _obj(c);
    var out = {};
    for (var i = 0; i < ACTIONS.length; i++) {
        var e = _obj(src[ACTIONS[i]]);
        out[ACTIONS[i]] = { ok: _bool(e.ok), why: _str(e.why), hint: _str(e.hint), via: _str(e.via) };
    }
    return out;
}

function _mount(m) {
    var e = _obj(m);
    // open: where "Open" goes and what the row shows (over Wi-Fi the phone's storage inside the mount, not its whole tree)
    return { point: _str(e.point), state: _oneOf(e.state, MOUNT_STATES, "unmounted"), mine: _bool(e.mine), open: _str(e.open, _str(e.point)) };
}

function _device(raw) {
    var d = _obj(raw);
    var kdc = null, battery = null, cell = null, usb = null, adb = null, facts = null;
    if (_isObj(d.kdc)) {
        var k = d.kdc;
        kdc = {
            id: _str(k.id), paired: _bool(k.paired), pairState: _int(k.pairState, 0, 0, 3), reachable: _bool(k.reachable),
            links: _strs(k.links), addresses: _strs(k.addresses), plugins: _strs(k.plugins), verificationKey: _str(k.verificationKey),
            pairRequested: _bool(k.pairRequested), pairRequestedByPeer: _bool(k.pairRequestedByPeer)
        };
    }
    if (_isObj(d.battery))
        battery = { charge: _int(d.battery.charge, 0, 0, 100), charging: _bool(d.battery.charging) };
    if (_isObj(d.cell))
        cell = { strength: _int(d.cell.strength, 0, 0, 4), type: _str(d.cell.type) };
    if (_isObj(d.usb))
        usb = { serial: _str(d.usb.serial), vendor: _str(d.usb.vendor), product: _str(d.usb.product), adbIface: _bool(d.usb.adbIface), mtpIface: _bool(d.usb.mtpIface) };
    if (_isObj(d.adb))
        adb = { serial: _str(d.adb.serial), transport: _oneOf(d.adb.transport, ["usb", "tcp"], "usb"),
                state: _oneOf(d.adb.state, ["device", "unauthorized", "offline"], "offline"), address: _str(d.adb.address) };
    if (_isObj(d.facts)) {
        var f = d.facts;
        facts = {
            model: _str(f.model), android: _str(f.android), storageTotal: _num(f.storageTotal), storageFree: _num(f.storageFree),
            batteryHealth: typeof f.batteryHealth === "string" || typeof f.batteryHealth === "number" ? f.batteryHealth : "",
            batteryTempC: typeof f.batteryTempC === "number" && isFinite(f.batteryTempC) ? f.batteryTempC : null,
            // "none" | "mtp" | "ptp" | ...: what the phone's USB does at an unlock ("" = not read)
            usbUnlocked: _str(f.usbUnlocked),
            at: _num(f.at)
        };
    }
    var p = _obj(d.prefs), m = _obj(d.mounts);
    var key = _str(d.key);
    return {
        key: key,
        name: _str(d.name, key),
        type: _oneOf(d.type, TYPES, "phone"),
        skin: _str(d.skin, "generic") === "" ? "generic" : _str(d.skin, "generic"),
        present: _bool(d.present),
        link: _oneOf(d.link, LINKS, "none"),
        lastSeen: _num(d.lastSeen),
        kdc: kdc,
        battery: battery,
        cell: cell,
        usb: usb,
        adb: adb,
        // keepWireless is on unless the line says false (the tool's default since 2026-11-19)
        prefs: { keepWireless: p.keepWireless !== false, mode: _oneOf(p.mode, MODES, "mirror"), screenOff: _bool(p.screenOff), record: _bool(p.record),
                 wifiDebug: _bool(p.wifiDebug), castAudio: _bool(p.castAudio), usbUnlockMtp: _bool(p.usbUnlockMtp) },
        mounts: { usb: _mount(m.usb), wifi: _mount(m.wifi) },
        facts: facts,
        pin: _oneOf(d.pin, PIN_STATES, "none"),
        can: _can(d.can)
    };
}

function _job(raw) {
    var j = _obj(raw);
    return {
        id: _str(j.id),
        kind: _str(j.kind),
        device: _str(j.device),
        mode: _str(j.mode),
        via: _str(j.via),
        phase: _oneOf(j.phase, PHASES, "running"),
        started: _num(j.started),
        ended: typeof j.ended === "number" && isFinite(j.ended) ? j.ended : null,
        code: typeof j.code === "number" && isFinite(j.code) ? Math.round(j.code) : null,
        reason: _str(j.reason),
        files: _num(j.files), file: _num(j.file), name: _str(j.name),
        done: _num(j.done), total: _num(j.total), rate: _num(j.rate)
    };
}

function _pairing(raw) {
    var p = _obj(raw);
    return { key: _str(p.key), name: _str(p.name, _str(p.key)), type: _oneOf(p.type, TYPES, "phone"), byPeer: _bool(p.byPeer), verificationKey: _str(p.verificationKey) };
}

function _env(raw) {
    var e = _obj(raw), h = _obj(e.have);
    return {
        kdeconnect: _oneOf(e.kdeconnect, ["running", "down", "missing"], "down"),
        adbServer: _oneOf(e.adbServer, ["up", "down"], "down"),
        have: {
            adb: !!h.adb,
            scrcpy: typeof h.scrcpy === "string" ? h.scrcpy : (h.scrcpy === true ? "present" : ""),
            aft: !!h.aft, sshfs: !!h.sshfs, fusermount: !!h.fusermount
        }
    };
}

// A whole accepted line. Total: anything that is not a line comes out as an empty one.
function normalise(raw) {
    var l = _obj(raw);
    var devices = [], seen = {};
    var src = l.devices && typeof l.devices.length === "number" && typeof l.devices !== "string" ? l.devices : [];
    for (var i = 0; i < src.length; i++) {
        var d = _device(src[i]);
        if (d.key === "" || seen[d.key])
            continue;
        seen[d.key] = true;
        devices.push(d);
    }
    var pairing = [], pseen = {};
    var ps = l.pairing && typeof l.pairing.length === "number" && typeof l.pairing !== "string" ? l.pairing : [];
    for (var a = 0; a < ps.length; a++) {
        var p = _pairing(ps[a]);
        if (p.key === "" || pseen[p.key])
            continue;
        pseen[p.key] = true;
        pairing.push(p);
    }
    var jobs = [], jseen = {};
    var js = l.jobs && typeof l.jobs.length === "number" && typeof l.jobs !== "string" ? l.jobs : [];
    for (var b = 0; b < js.length; b++) {
        var j = _job(js[b]);
        if (j.id === "" || jseen[j.id])
            continue;
        jseen[j.id] = true;
        jobs.push(j);
    }
    var wp = null;
    if (_isObj(l.wifiPair) && _str(l.wifiPair.name) !== "")
        wp = { key: _str(l.wifiPair.key), name: _str(l.wifiPair.name), state: _oneOf(l.wifiPair.state, PAIR_STATES, "waiting"),
               reason: _str(l.wifiPair.reason), png: _str(l.wifiPair.png) };
    return { v: 1, serial: _int(l.serial, 0, 0), env: _env(l.env), current: _str(l.current), devices: devices, pairing: pairing, jobs: jobs,
             wifiPair: wp };
}

// text -> { ok: true, line } | { ok: false, error }. Never throws.
function parseLine(text) {
    var t = text === undefined || text === null ? "" : String(text).trim();
    if (t === "")
        return { ok: false, error: "an empty line" };
    var o = null;
    try {
        o = JSON.parse(t);
    } catch (e) {
        return { ok: false, error: "not JSON: " + t.slice(0, 80) };
    }
    if (!_isObj(o))
        return { ok: false, error: "not an object: " + t.slice(0, 80) };
    if (o.error !== undefined && o.error !== null)
        return { ok: false, error: "the tool says: " + String(o.error) };
    if (o.v !== 1)
        return { ok: false, error: "a line of version " + String(o.v) + " is not understood" };
    return { ok: true, line: normalise(o) };
}

// ---- rows -----------------------------------------------------------------------------------------------------------

// What following a new key list takes: the keys to add, the keys to remove, and whether the keys that stay changed their
// relative order.
function diffKeys(oldKeys, newKeys) {
    var o = oldKeys || [], n = newKeys || [];
    var inOld = {}, inNew = {};
    var i;
    for (i = 0; i < o.length; i++)
        inOld[o[i]] = true;
    for (i = 0; i < n.length; i++)
        inNew[n[i]] = true;
    var added = [], removed = [], keptOld = [], keptNew = [];
    for (i = 0; i < n.length; i++)
        if (!inOld[n[i]])
            added.push(n[i]);
        else
            keptNew.push(n[i]);
    for (i = 0; i < o.length; i++)
        if (!inNew[o[i]])
            removed.push(o[i]);
        else
            keptOld.push(o[i]);
    var reordered = keptOld.join("\u0000") !== keptNew.join("\u0000");
    return { added: added, removed: removed, reordered: reordered, changed: added.length > 0 || removed.length > 0 || reordered };
}

function busyOf(jobs) {
    var j = jobs || [];
    for (var i = 0; i < j.length; i++)
        if (j[i].kind === "send" && (j[i].phase === "starting" || j[i].phase === "running"))
            return true;
    return false;
}

function isLive(job) {
    return job.phase === "starting" || job.phase === "running";
}

function canOf(d, ak) {
    var c = d && d.can && d.can[ak] ? d.can[ak] : null;
    return c || { ok: false, why: "", hint: "", via: "" };
}

// ---- actions ---------------------------------------------------------------------------------------------------------

// The key of `can` / `acts` an action stands for ("" = a call nobody waits on: stop, ack, set, select, refresh).
function actKey(action, which) {
    switch (action) {
    case "mirror":
        return "mirror";
    case "mount":
    case "unmount":
        return which === "wifi" ? "mountWifi" : (which === "usb" ? "mountUsb" : "");
    case "send":
    case "pickAndSend":
        return "send";
    case "shot":
    case "ring":
    case "clip":
    case "pair":
    case "unpair":
    case "arm":
    case "facts":
    case "unlock":
    case "usbcalm":
        return action;
    case "disarm":
        return "arm";
    case "key":
        return "key";
    }
    return "";
}

function idleActs() {
    var a = {};
    for (var i = 0; i < ACTIONS.length; i++)
        a[ACTIONS[i]] = { state: "idle", why: "", hint: "", at: 0 };
    return a;
}

// A path the tool takes: absolute, or a file: URL (decoded). Anything else is refused (a name that starts with "-" would be an
// option to the tool).
function cleanPath(p) {
    var s = typeof p === "string" ? p : "";
    if (s.indexOf("file://") === 0) {
        try {
            s = decodeURIComponent(s.slice(7));
        } catch (e) {
            return "";
        }
    }
    return s.charAt(0) === "/" ? s : "";
}

// The tool's argv (after its path) for an action of the service. `a` carries the action's own arguments. null = malformed.
function argvOf(action, key, a) {
    var o = a || {};
    var k = typeof key === "string" ? key : "";
    switch (action) {
    case "mirror": {
        if (k === "")
            return null;
        var v = ["mirror", k];
        var mode = _oneOf(o.mode, MODES, "");
        if (mode !== "")
            v.push("--mode", mode);
        if (o.screenOff === true)
            v.push("--screen-off");
        if (o.record === true)
            v.push("--record");
        return v;
    }
    case "stop":
        return typeof o.id === "string" && o.id !== "" ? ["stop", o.id] : null;
    case "ack":
        return typeof o.id === "string" && o.id !== "" ? ["ack", o.id] : null;
    case "mount":
    case "unmount":
        return k !== "" && (o.which === "usb" || o.which === "wifi") ? [action, k, o.which] : null;
    case "send": {
        var paths = [], src = o.paths && typeof o.paths.length === "number" ? o.paths : [];
        for (var i = 0; i < src.length; i++) {
            var c = cleanPath(src[i]);
            if (c !== "")
                paths.push(c);
        }
        if (k === "" || paths.length === 0)
            return null;
        var s = ["send", k];
        if (o.via === "adb" || o.via === "kdeconnect")
            s.push("--via", o.via);
        return s.concat(paths);
    }
    case "shot":
    case "ring":
    case "clip":
    case "pair":
    case "accept":
    case "reject":
    case "unpair":
    case "arm":
    case "disarm":
    case "facts":
    case "select":
        return k !== "" ? [action, k] : null;
    // castprep walks the transport; with `unlock` (a PIN is kept) it types the PIN first, which may take ~8 s; with `hold` (a Mirror)
    // it keeps the phone's screen on until castend; with `record` it names the file the cast records into
    case "castprep":
        return k !== "" ? [action, k].concat(o.unlock === true ? ["--unlock"] : [], o.hold === true ? ["--hold"] : [], o.record === true ? ["--record"] : []) : null;
    // the cast ended: the hold goes back, and with `sleep` an awake phone is put to sleep; `all` (no device): every hold left
    case "castend":
        return o.all === true ? ["castend", "--all"] : (k !== "" ? (o.sleep === true ? ["castend", k, "--sleep"] : ["castend", k]) : null);
    // the USB function at unlock: off (none) is the bridge's default, on is the way back (the phone's "File transfer")
    case "usbcalm":
        return k !== "" ? ["usbcalm", k, o.on === true ? "on" : "off"] : null;
    case "wifipair":
        return k !== "" ? (o.cancel === true ? ["wifipair", k, "cancel"] : ["wifipair", k]) : null;
    case "unlock":
        return k !== "" ? (o.auto === true ? ["unlock", k, "--auto"] : ["unlock", k]) : null;
    // the PIN itself never rides in argv: `set` reads it on stdin (ActionRunner opts.stdin)
    case "pin":
        return k !== "" && (o.op === "set" || o.op === "forget") ? ["pin", k, o.op] : null;
    case "key":
        return k !== "" && KEYS.indexOf(o.name) >= 0 ? ["key", k, o.name] : null;
    case "refresh":
        return ["refresh"];
    case "set": {
        if (k === "" || PREFS.indexOf(o.name) < 0)
            return null;
        var val = o.value;
        if (o.name === "mode" && MODES.indexOf(val) < 0)
            return null;
        if (o.name !== "mode" && typeof val !== "boolean")
            return null;
        return ["set", k, o.name, JSON.stringify(val)];
    }
    }
    return null;
}

// How long a one-shot may take (ms): a mirror resolves a transport and starts scrcpy, a mount waits for the device.
function timeoutOf(action) {
    switch (action) {
    case "mirror":
    case "castprep":
        return 45000;
    case "castend":
        return 20000;
    case "unlock":
    case "usbcalm":
    case "mount":
    case "unmount":
    case "arm":
    case "facts":
    case "shot":
    case "send":
        return 30000;
    }
    return 15000;
}

// ---- words ----------------------------------------------------------------------------------------------------------

function linkWords(d) {
    var l = d && d.link ? d.link : "none";
    if (l === "usb")
        return "On the cable";
    if (l === "wifi")
        return "On Wi-Fi";
    if (l === "both")
        return "On the cable and Wi-Fi";
    return "Not in reach";
}

function bytesWords(n) {
    var v = Number(n);
    if (!isFinite(v) || v <= 0)
        return "0 B";
    if (v < 1024)
        return Math.round(v) + " B";
    var units = ["KiB", "MiB", "GiB", "TiB"];
    var u = -1;
    while (v >= 1024 && u < units.length - 1) {
        v /= 1024;
        u++;
    }
    var s = v >= 100 ? String(Math.round(v)) : v.toFixed(1);
    if (s.slice(-2) === ".0")
        s = s.slice(0, -2);
    return s + " " + units[u];
}

function _plural(n, one, many) {
    return n + " " + (n === 1 ? one : many);
}

function _viaWords(via) {
    if (via === "usb" || via === "mtp")
        return "USB";
    if (via === "tcp")
        return "Wi-Fi";
    if (via === "adb")
        return "the cable";
    return via === "kdeconnect" ? "KDE Connect" : "";
}

function _modeWords(mode) {
    return mode === "desktop" ? "Desktop mode" : (mode === "camera" ? "Camera" : (mode === "audio" ? "Audio" : "Mirroring"));
}

// The body of a send's progress toast. Before anything moved: plain totals ("3 files, 11.5 MiB"), never "0 / 3".
function sendBody(j) {
    var files = Math.max(0, Math.round(j.files));
    var tot = j.total > 0 ? bytesWords(j.total) : "";
    if (j.done <= 0) {
        if (files <= 0)
            return "Preparing";
        return _plural(files, "file", "files") + (tot !== "" ? ", " + tot : "");
    }
    var parts = [];
    if (files > 1 && j.file > 0)
        parts.push("File " + Math.min(Math.round(j.file), files) + " of " + files);
    parts.push(j.total > 0 ? bytesWords(j.done) + " of " + tot : bytesWords(j.done));
    if (j.rate > 0)
        parts.push(bytesWords(j.rate) + "/s");
    return parts.join(" \u00b7 ");
}

// The closing toast of a send job that ended: { title, body, urgency, timeoutMs }. `hint` is `can.send.hint` of its device (the
// tool's words for what to do), used only for a failure.
function sendClosing(j, name, hint) {
    if (j.phase === "done") {
        var n = Math.max(1, Math.round(j.files));
        var body = j.total > 0 ? bytesWords(j.total) : "";
        return { title: _plural(n, "file", "files") + " sent to " + name, body: body, urgency: "low", timeoutMs: 6000 };
    }
    return failureWords("Could not send to " + name, j.reason !== "" ? j.reason : "The transfer ended without a word", hint);
}

// A failure as a toast: the title says what, the body is the tool's reason and, under it, its hint.
function failureWords(title, reason, hint) {
    var body = _str(reason);
    if (_str(hint) !== "")
        body += (body !== "" ? "\n" : "") + hint;
    return { title: title, body: body, urgency: "normal", timeoutMs: 12000 };
}

// The end of a recording cast (lares-cast's `record` event) as a toast, or null: where the file went, or why it was not finished and
// which part is kept (a stream any player opens); `empty` (no picture came) says nothing.
function recordToast(ev) {
    var e = ev || {};
    var skipped = Number(e.dropped) > 0 ? _plural(Math.round(Number(e.dropped)), "frame", "frames") + " skipped: the disk fell behind" : "";
    if (_str(e.path) !== "")
        return { title: "Recording saved", body: e.path + (skipped !== "" ? "\n" + skipped : ""), urgency: "low", timeoutMs: 6000 };
    if (_str(e.error) === "")
        return null;
    return failureWords("Could not save the recording", e.error, _str(e.kept) !== "" ? "What was recorded is kept in " + e.kept : "");
}

// A job that ended in a way worth a toast, or null (a mirror or a mount that ended by itself says nothing).
function endedToast(j, name, d) {
    if (j.kind === "send")
        return sendClosing(j, name, j.phase === "failed" ? canOf(d, "send").hint : "");
    if (j.phase !== "failed")
        return null;
    if (j.kind === "mirror")
        return failureWords("Could not mirror " + name, j.reason !== "" ? j.reason : "The mirror ended without a word", canOf(d, "mirror").hint);
    if (j.kind === "mount")
        return failureWords("Could not mount " + name, j.reason !== "" ? j.reason : "The mount ended without a word",
            canOf(d, j.via === "mtp" ? "mountUsb" : "mountWifi").hint);
    return null;
}

// One short line about a device: what runs, else how it is linked.
function stateLine(d, jobs) {
    if (!d)
        return "";
    var js = jobs || [];
    var mine = [];
    for (var i = 0; i < js.length; i++)
        if (js[i].device === d.key)
            mine.push(js[i]);
    var m, i2;
    for (i2 = 0; i2 < mine.length; i2++) {
        m = mine[i2];
        if (m.kind === "mirror" && isLive(m))
            return m.phase === "starting" ? _modeWords(m.mode) + " starting" : _modeWords(m.mode) + " over " + _viaWords(m.via);
    }
    for (i2 = 0; i2 < mine.length; i2++) {
        m = mine[i2];
        if (m.kind === "send" && isLive(m))
            return m.done <= 0 || m.files <= 1 || m.file <= 0 ? "Sending " + _plural(Math.max(1, Math.round(m.files)), "file", "files")
                : "Sending " + Math.min(Math.round(m.file), Math.round(m.files)) + " of " + Math.round(m.files);
    }
    for (i2 = 0; i2 < mine.length; i2++) {
        m = mine[i2];
        if (m.kind === "mount" && isLive(m))
            return m.phase === "starting" ? "Mounting storage" : "Storage mounted";
    }
    if (d.mounts && (d.mounts.usb.state === "mounted" || d.mounts.wifi.state === "mounted"))
        return "Storage mounted";
    for (i2 = 0; i2 < mine.length; i2++) {
        m = mine[i2];
        if (m.phase === "failed")
            return m.kind === "send" ? "Sending failed" : (m.kind === "mount" ? "Mounting failed" : "Mirroring failed");
    }
    if (d.kdc && !d.kdc.paired && d.present)
        return "Not paired";
    return linkWords(d);
}

// ---- config/bridge.jsonc ---------------------------------------------------------------------------------------------

function configDefaults() {
    return {
        files: { usbMount: "/mnt/android", open: ["kitty", "-o", "background_opacity=0.75", "--title", "yazi", "yazi", "{path}"], sendDir: "/sdcard/Download",
                 pickDir: "~" },
        mirror: {
            usb: { maxSize: 0, bitRate: "", maxFps: 0 },
            wifi: { maxSize: 1600, bitRate: "6M", maxFps: 60 },
            recordDir: "~/Videos", extraArgs: []
        },
        adb: { start: "onDemand", idleKillS: 300, port: 5555 },
        shots: { dir: "~/Pictures/Screenshots" },
        flip: { onOpen: true },
        // reloadOnResize: a resized cast restarts its stream at the new size (sharper), holding the last frame meanwhile
        // desktopScale: laptop px per Android dp; desktopMinDp / desktopMinPx: the virtual screen's short side never fewer dp / px
        // unlock: when the kept PIN unlocks a locked phone ("start+touch" | "start" | "touch" | "never"); keys: Qt's key names that are the phone's
        // Back / Home / Recents ("" = none); sleepAtEnd: a phone the cast lit goes back to sleep at its end; holdMin: the screen timeout a Mirror holds
        cast: { closeAfterS: 120, reloadOnResize: true, desktopScale: 1.0, desktopMinDp: 320, desktopMinPx: 640, unlock: "start+touch",
                keys: { back: "Left", home: "Down", recents: "Right" }, sleepAtEnd: true, holdMin: 30 },
        relight: true,
        // the key held for the free look: "alt" | "ctrl" | "shift" | "off"
        lookKey: "alt",
        devices: {}
    };
}

function _real(v, d, lo, hi) {
    var n = typeof v === "number" && isFinite(v) ? v : d;
    return n < lo ? lo : (n > hi ? hi : n);
}

function _bitRate(v, d) {
    return typeof v === "string" && (v === "" || /^[0-9]+[KkMm]?$/.test(v)) ? v : d;
}

function _link(o, d) {
    var e = _obj(o);
    return { maxSize: _int(e.maxSize, d.maxSize, 0, 16384), bitRate: _bitRate(e.bitRate, d.bitRate), maxFps: _int(e.maxFps, d.maxFps, 0, 240) };
}

// cast.keys: each of back / home / recents a key name (a text; "" = none), the default where it is not a text.
function _navKeys(o, d) {
    var e = _obj(o), out = {};
    for (var k in d)
        out[k] = typeof e[k] === "string" ? e[k] : d[k];
    return out;
}

// The user's object -> the settings. A value of the wrong kind is the default, a number out of range is clamped, an unknown
// key is dropped; a missing key never fails.
function parseConfig(raw) {
    var d = configDefaults();
    var o = _obj(raw);
    var f = _obj(o.files), m = _obj(o.mirror), a = _obj(o.adb), s = _obj(o.shots), fl = _obj(o.flip), c = _obj(o.cast);
    // files.open: any list of texts; `{path}` is replaced where it stands (in an element too), and added at the end when no element names it
    // (openArgv; the tool's argv.open_argv is the same rule)
    var open = _strs(f.open);
    if (open.length === 0)
        open = d.files.open;
    var devs = {};
    var dv = _obj(o.devices);
    for (var k in dv) {
        if (!Object.prototype.hasOwnProperty.call(dv, k))
            continue;
        var e = _obj(dv[k]);
        devs[k] = { skin: _str(e.skin), hidden: _bool(e.hidden) };
    }
    return {
        files: {
            usbMount: _str(f.usbMount) !== "" ? f.usbMount : d.files.usbMount,
            open: open,
            sendDir: _str(f.sendDir) !== "" ? f.sendDir : d.files.sendDir,
            pickDir: _str(f.pickDir) !== "" ? f.pickDir : d.files.pickDir
        },
        mirror: {
            usb: _link(m.usb, d.mirror.usb),
            wifi: _link(m.wifi, d.mirror.wifi),
            recordDir: _str(m.recordDir) !== "" ? m.recordDir : d.mirror.recordDir,
            extraArgs: _strs(m.extraArgs)
        },
        adb: {
            start: _oneOf(a.start, ["onDemand", "onPlug"], d.adb.start),
            idleKillS: _int(a.idleKillS, d.adb.idleKillS, 0, 86400),
            port: _int(a.port, d.adb.port, 1, 65535)
        },
        shots: { dir: _str(s.dir) !== "" ? s.dir : d.shots.dir },
        flip: { onOpen: _bool(fl.onOpen, d.flip.onOpen) },
        cast: {
            closeAfterS: _int(c.closeAfterS, d.cast.closeAfterS, 5, 86400), reloadOnResize: _bool(c.reloadOnResize, d.cast.reloadOnResize),
            desktopScale: _real(c.desktopScale, d.cast.desktopScale, 0.5, 3.0),
            desktopMinDp: _int(c.desktopMinDp, d.cast.desktopMinDp, 240, 1200),
            desktopMinPx: _int(c.desktopMinPx, d.cast.desktopMinPx, 320, 2400),
            unlock: _oneOf(c.unlock, ["start+touch", "start", "touch", "never"], d.cast.unlock),
            keys: _navKeys(c.keys, d.cast.keys),
            sleepAtEnd: _bool(c.sleepAtEnd, d.cast.sleepAtEnd),
            holdMin: _real(c.holdMin, d.cast.holdMin, 1, 240)
        },
        relight: _bool(o.relight, d.relight),
        lookKey: _oneOf(o.lookKey, ["alt", "ctrl", "shift", "off"], d.lookKey),
        devices: devs
    };
}

// ---- the desktop's virtual screen -------------------------------------------------------------------------------------

function round8(x) {
    return Math.max(8, Math.round(x / 8) * 8);
}

// The screen a Desktop cast makes on the phone, from the room the page gives it (DEVICE px; `dpr` the window's real ratio):
// laptop-sized (one Android dp ~ one laptop logical px, never narrower than cast.desktopMinDp), and never under cast.desktopMinPx
// pixels on the short side (the phone's secondary launcher lays out in pixels and its icons melt below ~600). Whole multiples of
// 8, the long side at most 2400. -> { w, h, dpi, k } where k = w / roomW (a later resize keeps it).
function desktopScreen(roomW, roomH, dpr, cast) {
    var c = cast || {};
    var scale = typeof c.desktopScale === "number" && c.desktopScale > 0 ? c.desktopScale : 1;
    var minDp = typeof c.desktopMinDp === "number" ? c.desktopMinDp : 320;
    var minPx = typeof c.desktopMinPx === "number" ? c.desktopMinPx : 640;
    var rw = roomW > 0 ? roomW : 1, rh = roomH > 0 ? roomH : 2;
    var r = dpr > 0 ? dpr : 1;
    var short = Math.min(rw, rh);
    var dpShort = Math.max(minDp, (short / r) / scale);
    var k = Math.max(1, minPx / short);
    var w = round8(rw * k), h = round8(rh * k);
    var long = Math.max(w, h);
    if (long > 2400) {
        var f = 2400 / long;
        w = round8(w * f);
        h = round8(h * f);
    }
    var dpi = Math.max(120, Math.min(640, Math.round(160 * Math.min(w, h) / dpShort)));
    return { w: w, h: h, dpi: dpi, k: w / rw };
}

// "why. hint" (the trailing stop of why dropped), or whichever of the two there is.
function words(why, hint) {
    var w = _str(why).replace(/[.\s]+$/, "");
    var h = _str(hint);
    return w !== "" && h !== "" ? w + ". " + h : (w !== "" ? w : h);
}

// The `files.open` argv with {path} replaced.
function openArgv(open, path) {
    var out = [], named = false;
    for (var i = 0; i < open.length; i++) {
        named = named || String(open[i]).indexOf("{path}") >= 0;
        out.push(String(open[i]).split("{path}").join(path));
    }
    if (!named)
        out.push(path);
    return out;
}

// A file: URL for a thumbnail.
function fileUrl(path) {
    var parts = String(path).split("/");
    for (var i = 0; i < parts.length; i++)
        parts[i] = encodeURIComponent(parts[i]);
    return "file://" + parts.join("/");
}
