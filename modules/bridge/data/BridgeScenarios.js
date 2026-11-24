.pragma library

// =============================================================================
// BridgeScenarios.js -- the bridge's mock: named SEQUENCES OF `watch` LINES in exactly the contract's schema
// (docs/contracts/bridge.md section 3), so the mock runs THE REAL PARSER (BridgeModel.parseLine), and `react`, the obvious outcome
// of an action played on a line. Pure (no Qt; loads under node with the pragma line cut), deterministic: every time in a
// scenario is a number derived from the line's serial, never the wall clock.
//
//   names()                         the scenarios' keys
//   lines(name)                     -> [JSON text, ...] (the tool's lines, serial 1, 2, ...) or null for an unknown name
//   react(line, action, key, args)  -> the next line (an object) after `action` on the line; `action` is the service's verb
//                                      (mirror stop mount unmount send shot ring clip key pair accept reject unpair arm disarm
//                                      set select facts usbcalm refresh ack). An action that changes nothing returns the line with its
//                                      serial raised, like a tool that printed an unchanged state.
//   step(line)                      -> the line after a running send moved on (figures, then done), or null when none runs
//
// The `can` map is recomputed from what the device has (adb up, a cable with MTP, a reachable KDE Connect): these are the MOCK's
// rules, a stand-in for the tool's `caps`; the real service never reads them (it only shows the tool's `can`).
// =============================================================================

var NOW = 1794912345;     // seconds: "now" of the scenarios

var NO_ADB_WHY = "adb is not connected";
var NO_ADB_HINT = "Plug it in once, or pair it for Wireless debugging (Details)";

function _clone(o) {
    return JSON.parse(JSON.stringify(o));
}

function _caps(d) {
    var adbUp = !!(d.adb && d.adb.state === "device");
    var unauth = !!(d.adb && d.adb.state === "unauthorized");
    var kdc = d.kdc || null;
    var reach = !!(kdc && kdc.paired && kdc.reachable);
    function ok(via) {
        return { ok: true, why: "", hint: "", via: via || "" };
    }
    function no(why, hint) {
        return { ok: false, why: why, hint: hint || "", via: "" };
    }
    var needAdb = unauth ? no("Not allowed yet", "Accept the prompt on the phone")
                         : no(NO_ADB_WHY, NO_ADB_HINT);
    var needKdc = kdc && !kdc.reachable ? no("Out of reach", "Same Wi-Fi as this computer")
                                        : no("Not paired");
    var plugins = kdc && kdc.plugins ? kdc.plugins : [];
    return {
        mirror: adbUp ? ok(d.adb.transport) : needAdb,
        mountUsb: d.usb && d.usb.mtpIface ? ok() : no("No cable"),
        mountWifi: reach && plugins.indexOf("sftp") >= 0 ? ok() : needKdc,
        send: adbUp ? ok("adb") : (reach ? ok("kdeconnect") : no("Out of reach")),
        shot: adbUp ? ok() : needAdb,
        ring: reach ? ok() : needKdc,
        clip: reach ? ok() : needKdc,
        key: adbUp ? ok() : needAdb,
        pair: kdc && !kdc.paired && kdc.reachable ? ok() : no("Already paired", ""),
        unpair: kdc && kdc.paired ? ok() : no("Not paired", ""),
        arm: adbUp && d.usb && d.adb.transport === "usb" ? ok() : no("No cable"),
        facts: adbUp ? ok() : needAdb,
        usbcalm: adbUp ? ok() : needAdb,
        unlock: !adbUp ? needAdb : (d.pin === "set" ? ok(d.adb.transport) : (d.pin === "failed"
            ? no("The PIN failed last time", "Set it again on the Details page") : no("No PIN kept", "Set it on the Details page")))
    };
}

function _recan(d) {
    d.can = _caps(d);
    return d;
}

// The user's phone, from one base. `o` overrides: link, adb (null | "usb" | "tcp" | "unauthorized"), mtp, kdcReachable, seen.
function _phone(o) {
    var link = o.link || "wifi";
    var wifi = link === "wifi" || link === "both";
    var usb = link === "usb" || link === "both";
    var kdcReach = o.kdcReachable !== undefined ? o.kdcReachable : wifi;
    var adbState = o.adb === "unauthorized" ? "unauthorized" : (o.adb ? "device" : "");
    var d = {
        key: "kdc:redmagic10pro", name: "REDMAGIC 10S Pro", type: "phone", skin: "redmagic-10s-pro-moonlight",
        present: link !== "none", link: link, lastSeen: o.seen || NOW,
        kdc: { id: "redmagic10pro", paired: true, pairState: 3, reachable: kdcReach, links: kdcReach ? ["LAN"] : [],
               addresses: kdcReach ? ["192.168.0.240"] : [], plugins: ["battery", "clipboard", "findmyphone", "ping", "share", "sftp"],
               verificationKey: "305BAF9E", pairRequested: false, pairRequestedByPeer: false },
        battery: link === "none" ? null : { charge: 81, charging: usb },
        cell: kdcReach ? { strength: 3, type: "LTE" } : null,
        usb: usb ? { serial: "FY25A0000", vendor: "18d1", product: "4ee1", adbIface: true, mtpIface: o.mtp !== false } : null,
        adb: adbState !== "" ? { serial: "FY25A0000", transport: o.adb === "tcp" ? "tcp" : "usb", state: adbState,
                                 address: o.adb === "tcp" ? "192.168.0.240:5555" : "" } : null,
        prefs: { keepWireless: false, mode: "mirror", screenOff: false, record: false, castAudio: false, usbUnlockMtp: false },
        mounts: { usb: { point: "/mnt/android", state: "unmounted", mine: false },
                  wifi: { point: "/run/user/1000/redmagic10pro", state: "unmounted", mine: false } },
        facts: null,
        pin: o.pin || "none",
        can: {}
    };
    return _recan(d);
}

function _pixel() {
    var d = {
        key: "kdc:pixel6pro", name: "Pixel 6 Pro", type: "phone", skin: "generic", present: false, link: "none", lastSeen: NOW - 86400 * 9,
        kdc: { id: "pixel6pro", paired: true, pairState: 3, reachable: false, links: [], addresses: [], plugins: ["battery", "share"],
               verificationKey: "7D21C0AB", pairRequested: false, pairRequestedByPeer: false },
        battery: null, cell: null, usb: null, adb: null,
        prefs: { keepWireless: false, mode: "mirror", screenOff: false, record: false },
        mounts: { usb: { point: "/mnt/android", state: "unmounted", mine: false },
                  wifi: { point: "/run/user/1000/pixel6pro", state: "unmounted", mine: false } },
        facts: null, can: {}
    };
    return _recan(d);
}

function _env(adbServer, kdc) {
    return { kdeconnect: kdc || "running", adbServer: adbServer || "down",
             have: { adb: true, scrcpy: "3.1", aft: true, sshfs: false, fusermount: true } };
}

function _line(serial, devices, o) {
    var x = o || {};
    return { v: 1, serial: serial, env: x.env || _env(x.adbServer, x.kdeconnect), current: x.current !== undefined ? x.current : (devices.length > 0 ? devices[0].key : ""),
             devices: devices, pairing: x.pairing || [], jobs: x.jobs || [] };
}

function _job(id, kind, d, o) {
    var x = o || {};
    return { id: id, kind: kind, device: d.key, mode: x.mode !== undefined ? x.mode : (kind === "mirror" ? "mirror" : ""), via: x.via || "",
             phase: x.phase || "running", started: x.started || NOW - 120, ended: x.ended !== undefined ? x.ended : null,
             code: x.code !== undefined ? x.code : null, reason: x.reason || "",
             files: x.files || 0, file: x.file || 0, name: x.name || "", done: x.done || 0, total: x.total || 0, rate: x.rate || 0 };
}

// ---- the scenarios ---------------------------------------------------------------------------------------------------

var BUILD = {
    none: function () {
        return [_line(1, [], { adbServer: "down" })];
    },
    pairing: function () {
        return [_line(1, [_pixel()], {
            pairing: [{ key: "kdc:redmagic10pro", name: "REDMAGIC 10S Pro", type: "phone", byPeer: true, verificationKey: "305BAF9E" }]
        })];
    },
    asleep: function () {
        return [_line(1, [_phone({ link: "none", seen: NOW - 3600 * 9 }), _pixel()])];
    },
    wifi: function () {
        return [_line(1, [_phone({ link: "wifi" }), _pixel()])];
    },
    wired: function () {
        return [_line(1, [_phone({ link: "usb", adb: "usb" }), _pixel()], { adbServer: "up" })];
    },
    mirroring: function () {
        var d = _phone({ link: "usb", adb: "usb" });
        return [_line(1, [d, _pixel()], { adbServer: "up", jobs: [_job("m-18", "mirror", d, { mode: "mirror", via: "usb" })] })];
    },
    mounted: function () {
        var d = _phone({ link: "usb", adb: "usb" });
        d.mounts.usb.state = "mounted";
        d.mounts.usb.mine = true;
        return [_line(1, [d, _pixel()], { adbServer: "up", jobs: [_job("k-3", "mount", d, { via: "mtp" })] })];
    },
    transfer: function () {
        var d = _phone({ link: "both", adb: "usb" });
        var a = _line(1, [d, _pixel()], { adbServer: "up" });
        var b = _clone(a);
        b.serial = 2;
        b.jobs = [_job("s-7", "send", d, { via: "adb", phase: "starting", files: 3, file: 0, name: "IMG_2041.jpg", done: 0, total: 12058624 })];
        return [a, b];
    },
    error: function () {
        var d = _phone({ link: "usb", adb: "unauthorized", kdcReachable: false });
        var a = _line(1, [d, _pixel()], {
            adbServer: "up", kdeconnect: "down",
            jobs: [_job("m-17", "mirror", d, { mode: "mirror", via: "usb", phase: "failed", ended: NOW - 40, code: 1, reason: "adb: device unauthorized" })]
        });
        return [a];
    }
};

function names() {
    return ["none", "pairing", "asleep", "wifi", "wired", "mirroring", "mounted", "transfer", "error"];
}

// The tool's lines: the scenario's states, then (the error scenario) a fault line, which the parser must refuse.
function lines(name) {
    if (!Object.prototype.hasOwnProperty.call(BUILD, name))
        return null;
    var out = BUILD[name]().map(function (l) {
        return JSON.stringify(l);
    });
    if (name === "error")
        out.push(JSON.stringify({ v: 1, error: "the adb server did not answer" }));
    return out;
}

// ---- reactions ------------------------------------------------------------------------------------------------------

function _find(l, key) {
    for (var i = 0; i < l.devices.length; i++)
        if (l.devices[i].key === key)
            return l.devices[i];
    return null;
}

function _liveJob(l, key, kind) {
    for (var i = 0; i < l.jobs.length; i++) {
        var j = l.jobs[i];
        if (j.device === key && j.kind === kind && (j.phase === "starting" || j.phase === "running"))
            return j;
    }
    return null;
}

function _base(p) {
    var s = String(p);
    return s.slice(s.lastIndexOf("/") + 1);
}

function _size(p) {
    return 1000000 + _base(p).length * 250000;
}

function react(line, action, key, args) {
    var l = _clone(line);
    l.serial = (typeof l.serial === "number" ? l.serial : 0) + 1;
    var a = args || {};
    var t = NOW + l.serial * 30;
    var d = _find(l, key);
    var j = null, i;
    switch (action) {
    case "mirror":
        if (d && !_liveJob(l, key, "mirror"))
            l.jobs.push(_job("m-" + l.serial, "mirror", d, { mode: a.mode || d.prefs.mode, via: d.adb && d.adb.transport === "tcp" ? "tcp" : "usb", started: t }));
        break;
    case "stop":
        for (i = 0; i < l.jobs.length; i++)
            if (l.jobs[i].id === a.id && (l.jobs[i].phase === "starting" || l.jobs[i].phase === "running")) {
                j = l.jobs[i];
                j.phase = "done";
                j.ended = t;
                j.code = 0;
                var owner = _find(l, j.device);
                if (owner && j.kind === "mount") {
                    owner.mounts.usb.state = "unmounted";
                    owner.mounts.usb.mine = false;
                }
            }
        break;
    case "ack":
        l.jobs = l.jobs.filter(function (x) {
            return !(x.id === a.id && (x.phase === "done" || x.phase === "failed"));
        });
        break;
    case "mount":
        if (d && a.which === "usb") {
            d.mounts.usb.state = "mounted";
            d.mounts.usb.mine = true;
            if (!_liveJob(l, key, "mount"))
                l.jobs.push(_job("k-" + l.serial, "mount", d, { via: "mtp", started: t }));
        } else if (d && a.which === "wifi") {
            d.mounts.wifi.state = "mounted";
            d.mounts.wifi.mine = true;
        }
        break;
    case "unmount":
        if (d && a.which === "usb") {
            d.mounts.usb.state = "unmounted";
            d.mounts.usb.mine = false;
            j = _liveJob(l, key, "mount");
            if (j) {
                j.phase = "done";
                j.ended = t;
                j.code = 0;
            }
        } else if (d && a.which === "wifi") {
            d.mounts.wifi.state = "unmounted";
            d.mounts.wifi.mine = false;
        }
        break;
    case "send": {
        var paths = a.paths || [];
        if (d && paths.length > 0 && d.adb && d.adb.state === "device") {
            var total = 0;
            for (i = 0; i < paths.length; i++)
                total += _size(paths[i]);
            l.jobs.push(_job("s-" + l.serial, "send", d, { via: "adb", phase: "starting", started: t, files: paths.length, file: 0, name: _base(paths[0]), total: total }));
        }
        break;
    }
    case "pair":
    case "accept":
        for (i = 0; i < l.pairing.length; i++)
            if (l.pairing[i].key === key) {
                var p = l.pairing[i];
                var np = _phone({ link: "wifi" });
                np.key = p.key;
                np.name = p.name;
                np.type = p.type;
                np.skin = "generic";
                np.kdc.id = p.key.replace(/^kdc:/, "");
                np.kdc.verificationKey = p.verificationKey;
                np.kdc.addresses = ["192.168.0.241"];
                np.lastSeen = t;
                _recan(np);
                l.pairing.splice(i, 1);
                l.devices = l.devices.filter(function (x) {
                    return x.key !== np.key;
                });
                l.devices.unshift(np);
                if (l.current === "")
                    l.current = np.key;
                break;
            }
        if (d && d.kdc && !d.kdc.paired) {
            d.kdc.paired = true;
            d.kdc.pairState = 3;
            _recan(d);
        }
        break;
    case "reject":
        l.pairing = l.pairing.filter(function (x) {
            return x.key !== key;
        });
        break;
    case "unpair":
        if (d && d.kdc) {
            d.kdc.paired = false;
            d.kdc.pairState = 0;
            d.kdc.reachable = false;
            d.kdc.links = [];
            d.kdc.addresses = [];
            d.present = !!(d.usb || d.adb);
            d.link = d.usb ? "usb" : "none";
            d.cell = null;
            _recan(d);
        }
        break;
    case "arm":
        if (d && d.adb) {
            d.adb.transport = "tcp";
            d.adb.address = "192.168.0.240:5555";
            _recan(d);
        }
        break;
    case "disarm":
        if (d && d.adb) {
            d.adb.transport = "usb";
            d.adb.address = "";
            _recan(d);
        }
        break;
    case "set":
        if (d && d.prefs && Object.prototype.hasOwnProperty.call(d.prefs, a.name))
            d.prefs[a.name] = a.value;
        break;
    case "select":
        if (d)
            l.current = key;
        break;
    case "pin":
        if (d) {
            d.pin = a.op === "set" ? "set" : "none";
            _recan(d);
        }
        break;
    case "unlock":
        break;
    case "facts":
        if (d)
            d.facts = { model: "NX789J", android: "15", storageTotal: 512 * 1024 * 1024 * 1024, storageFree: 311 * 1024 * 1024 * 1024,
                        batteryHealth: "Good", batteryTempC: 31.5, usbUnlocked: d.facts && d.facts.usbUnlocked ? d.facts.usbUnlocked : "mtp", at: t };
        break;
    // the phone's USB at an unlock: off = none (the bridge's default), on = the phone's own File transfer (the user's choice, kept)
    case "usbcalm":
        if (d && d.prefs) {
            d.prefs.usbUnlockMtp = a.on === true;
            if (d.facts)
                d.facts.usbUnlocked = a.on === true ? "mtp" : "none";
        }
        break;
    }
    return l;
}

// A running send moves on: starting -> running with the first file, then a sixth of the total a step, done at the end.
function step(line) {
    var l = _clone(line);
    var j = null;
    for (var i = 0; i < l.jobs.length; i++)
        if (l.jobs[i].kind === "send" && (l.jobs[i].phase === "starting" || l.jobs[i].phase === "running")) {
            j = l.jobs[i];
            break;
        }
    if (!j)
        return null;
    l.serial = (typeof l.serial === "number" ? l.serial : 0) + 1;
    var t = NOW + l.serial * 30;
    var total = j.total > 0 ? j.total : 6000000;
    j.total = total;
    var inc = Math.ceil(total / 6);
    j.done = Math.min(total, j.done + inc);
    j.phase = "running";
    j.rate = Math.round(total / 3);
    j.file = Math.max(1, Math.min(j.files || 1, Math.ceil(j.done / total * (j.files || 1))));
    if (j.done >= total) {
        j.phase = "done";
        j.ended = t;
        j.code = 0;
        j.file = j.files;
        j.rate = 0;
    }
    return l;
}
