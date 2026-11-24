.pragma library

// CastParse.js -- the cast tool's JSON lines (tools/panorama/lares-cast, docs/contracts/panorama.md "Cast") as ONE reducer, pure, so CastService, CastMock
// and a node case file read the same rules. The model is plain data; every function returns a NEW object.
//
//   { state: "idle"|"connecting"|"negotiating"|"streaming"|"stopping"|"failed", device, monitor, mode: {width,height,fps}|null,
//     failure: {reason, detail}|null, retried, started (latched when streaming was first reached), ended ("" until the
//     tool's `ended`, then "stopped"|"failed"|"peer-gone") }
//
// THE FIGURES (the tool's `stats`, one set a beat) are a reducer of their own (`figures`), so a beat touches nothing of the model above:
//   null (none yet) | { age, reconnects, and of FIGURES those the cast has had: a number, or null when it is not known right now }

var RANK = { connecting: 1, negotiating: 2, streaming: 3 };

// One JSON line of the tool's stdout -> the event object, or null for anything that is not one.
function parseLine(text) {
    var s = String(text).trim();
    if (s === "" || s.charAt(0) !== "{")
        return null;
    try {
        var o = JSON.parse(s);
        return (o && typeof o === "object" && typeof o.event === "string") ? o : null;
    } catch (e) {
        return null;
    }
}

function initial() {
    return { state: "idle", device: "", monitor: "", mode: null, failure: null, retried: false, started: false, ended: "" };
}

function _copy(m) {
    return { state: m.state, device: m.device, monitor: m.monitor, mode: m.mode, failure: m.failure, retried: m.retried, started: m.started, ended: m.ended };
}

// A new cast: connecting at once (the tool's scanning is part of connecting).
function begin(deviceId, monitorName) {
    var m = initial();
    m.state = "connecting";
    m.device = deviceId;
    m.monitor = monitorName;
    return m;
}

function active(m) {
    return m.state === "connecting" || m.state === "negotiating" || m.state === "streaming" || m.state === "stopping";
}

// The user asked for a stop: stopping from now on (whatever the tool says next does not move it), the end is "stopped".
function requestStop(m) {
    if (!active(m) || m.state === "stopping")
        return m;
    var n = _copy(m);
    n.state = "stopping";
    return n;
}

function _failure(reason, detail) {
    return { reason: String(reason || "tool"), detail: String(detail || "") };
}

function reduce(m, ev) {
    var n = _copy(m);
    if (!ev || n.ended !== "")
        return n;
    switch (ev.event) {
    case "state": {
        var s = ev.state === "scanning" ? "connecting" : ev.state;
        if (s === "stopping") {
            n.state = "stopping";
        } else if (RANK[s] !== undefined && RANK[n.state] !== undefined && RANK[s] > RANK[n.state]) {
            n.state = s;
            if (s === "streaming")
                n.started = true;
        }
        break;
    }
    case "lost":                    // a stream that was up is gone: it is made again (a `retry` follows) or it has failed
    case "retry":
        if (n.state !== "stopping") {
            n.state = "connecting";
            n.mode = null;
        }
        n.retried = n.retried || ev.event === "retry";
        break;
    case "mode":
        n.mode = { width: ev.width | 0, height: ev.height | 0, fps: ev.fps | 0 };
        break;
    case "failed":
    case "error":
        n.failure = _failure(ev.reason, ev.detail);
        break;
    case "ended":
        if (n.state === "stopping")
            n.ended = "stopped";
        else if (n.failure)
            n.ended = n.failure.reason === "peer-gone" ? "peer-gone" : "failed";
        else if ((ev.code | 0) === 0)
            n.ended = "stopped";
        else {
            n.failure = _failure("tool", "the cast tool exited " + (ev.code | 0));
            n.ended = "failed";
        }
        n.state = n.ended === "stopped" ? "idle" : "failed";
        if (n.ended === "stopped")
            n.failure = null;
        break;
    }
    return n;
}

// ---- the figures ---------------------------------------------------------------------------------------------------------------------------
// What is shown, in its order (two columns: the stream's at the left, the link's at the right), with its name. `live`: it says how the stream is
// NOW, so it is not known while there is none; the others are totals of the cast and stand.
var FIGURES = [
    { key: "fps", label: "Frames sent", live: true },
    { key: "kbps", label: "Data sent", live: true },
    { key: "dropped", label: "Dropped frames", live: false },
    { key: "rttMs", label: "Round trip", live: true },
    { key: "repeated", label: "Repeated frames", live: false },
    { key: "signalDbm", label: "Signal", live: true },
    { key: "behindMs", label: "Encoder behind", live: true },
    { key: "linkMbps", label: "Link rate", live: true }
];

function _num(v) {
    return typeof v === "number" && isFinite(v) ? v : null;
}

// the same keys with nothing known: the live ones (a dead link), or every one (a new cast to the same display)
function _blank(f, all) {
    if (f === null)
        return null;
    var n = { age: all ? null : f.age, reconnects: all ? 0 : f.reconnects };
    for (var i = 0; i < FIGURES.length; i++) {
        var k = FIGURES[i].key;
        if (f[k] !== undefined)
            n[k] = all || FIGURES[i].live ? null : f[k];
    }
    return n;
}

// One event of the tool -> the figures. `begin` (the service's own word, not the tool's): a new cast, `same` to the device of the last one
function figures(f, ev) {
    if (!ev)
        return f;
    switch (ev.event) {
    case "stats": {
        var n = { age: _num(ev.age), reconnects: _num(ev.reconnects) || 0 };
        for (var i = 0; i < FIGURES.length; i++) {
            var k = FIGURES[i].key;
            if (ev[k] !== undefined)
                n[k] = _num(ev[k]);
        }
        return n;
    }
    case "begin":
        return ev.same ? _blank(f, true) : null;
    case "lost":
    case "retry":
    case "ended":
        return _blank(f, false);
    }
    return f;
}

// "30 fps": a figure's text ("–" when it is not known right now)
function figureText(key, v) {
    if (v === null || v === undefined)
        return "–";
    switch (key) {
    case "fps":
        return Math.round(v) + " fps";
    case "kbps":
        return (v / 1000).toFixed(1) + " Mbit/s";
    case "rttMs":
        return Math.max(1, Math.round(v)) + " ms";
    case "behindMs":
        return (v / 1000).toFixed(1) + " s";
    case "signalDbm":
        return Math.round(v) + " dBm";
    case "linkMbps":
        return v >= 1000 ? (v / 1000).toFixed(1) + " Gbit/s" : Math.round(v) + " Mbit/s";
    }
    return String(Math.round(v));
}

// "12:04", "1:02:03 · reconnected twice": how long the stream has been up, and how often it was made again ("" before the first set)
function ageText(f) {
    if (f === null || f === undefined || f.age === null)
        return "";
    var s = Math.max(0, Math.floor(f.age)), h = Math.floor(s / 3600), m = Math.floor(s / 60) % 60;
    var two = function (x) { return (x < 10 ? "0" : "") + x; };
    var t = (h > 0 ? h + ":" + two(m) : m) + ":" + two(s % 60);
    var n = f.reconnects || 0;
    return n === 0 ? t : t + " · reconnected " + (n === 1 ? "once" : n === 2 ? "twice" : n + " times");
}

// The tool's `scan --json` object -> {devices: [facts], info: {fluxcast, shim, protocols}} or {error: "reason: detail"}.
function parseScan(text) {
    var o = parseLine(String(text).split("\n")[0]);
    if (o === null) {
        var raw = String(text).trim();
        try {
            o = JSON.parse(raw);
        } catch (e) {
            return { error: "tool: no answer" };
        }
    }
    if (o.event === "error")
        return { error: (o.reason || "tool") + (o.detail ? ": " + o.detail : "") };
    var out = [];
    var list = o.devices || [];
    for (var i = 0; i < list.length; i++)
        out.push({ id: String(list[i].id), name: String(list[i].name || ""), protocol: String(list[i].protocol || "wfd"), capable: list[i].capable === true, note: String(list[i].note || "") });
    return { devices: out, info: { fluxcast: String(o.fluxcast || ""), shim: o.shim === true, protocols: o.protocols || [] } };
}
