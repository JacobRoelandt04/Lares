.pragma library

// =============================================================================
// AirplayRules.js -- the pure half of AirplayWatch: what config/airplay.jsonc says, which sink is an AirPlay (RAOP) one, what its
// module's arguments say about latency and interface, and the delay the player's displays take. No PipeWire, no process.
//
// THE SINK'S NAME. PipeWire's raop-discover makes one `libpipewire-module-raop-sink` per speaker and the sink node is
// `raop_sink.<hostname>.<ip>.<port>` (`raop_sink.Speaker-0B01.local.192.168.0.103.7000`). The module's own arguments (pw-dump
// Module, `info.args`, an object when PipeWire could parse them) carry `raop.ip`, `raop.port`, `raop.hostname`, `raop.ifindex`, and
// the latency the user configured: `raop.latency.ms` (the buffer, 3000 here) and `sess.latency.msec` (the RTP session's, 479).
// =============================================================================

var DEFAULTS = { powersave: true, graceSec: 60, delay: "auto", delayExtraMs: 0 };

function _num(v, lo, hi, dflt) {
    const n = typeof v === "number" ? v : (typeof v === "string" && v.trim() !== "" ? Number(v) : NaN);
    return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : dflt;
}

// text of config/airplay.jsonc, comments already stripped (an empty or broken one is the defaults)
function parseConfig(obj) {
    const o = obj && typeof obj === "object" ? obj : {};
    let delay = "auto";
    if (typeof o.delay === "number" || (typeof o.delay === "string" && o.delay !== "auto" && o.delay.trim() !== ""))
        delay = _num(o.delay, 0, 60000, "auto");
    return {
        powersave: o.powersave !== false,
        graceSec: _num(o.graceSec, 0, 3600, DEFAULTS.graceSec),
        delay: delay,
        delayExtraMs: _num(o.delayExtraMs, -60000, 60000, DEFAULTS.delayExtraMs)
    };
}

function isRaop(name) {
    return typeof name === "string" && name.indexOf("raop_sink.") === 0;
}

// raop_sink.<hostname>.<ip>.<port> -> { host, ip, port } (null when the name does not have that shape)
function sinkKey(name) {
    if (!isRaop(name))
        return null;
    const m = /^raop_sink\.(.+)\.(\d{1,3}(?:\.\d{1,3}){3})\.(\d+)$/.exec(name);
    return m ? { host: m[1], ip: m[2], port: Number(m[3]) } : null;
}

// `pw-dump Module` (a JSON array) -> every raop-sink module as { host, ip, port, ifindex, latencyMs, raopMs, sessMs }
function parseModules(text) {
    let all;
    try {
        all = JSON.parse(text);
    } catch (e) {
        return [];
    }
    if (!(all instanceof Array))
        return [];
    const out = [];
    for (let i = 0; i < all.length; i++) {
        const o = all[i];
        const info = o && o.info;
        if (!info || info.name !== "libpipewire-module-raop-sink")
            continue;
        let a = info.args;
        if (typeof a === "string") {
            try {
                a = JSON.parse(a);
            } catch (e) {
                a = null;
            }
        }
        if (!a || typeof a !== "object")
            continue;
        const raop = _num(a["raop.latency.ms"], 0, 600000, 0);
        const sess = _num(a["sess.latency.msec"], 0, 600000, 0);
        out.push({
            host: String(a["raop.hostname"] || ""),
            ip: String(a["raop.ip"] || ""),
            port: _num(a["raop.port"], 0, 65535, 0),
            ifindex: _num(a["raop.ifindex"], 0, 1 << 30, 0),
            raopMs: raop,
            sessMs: sess,
            latencyMs: raop + sess
        });
    }
    return out;
}

// the module of a sink by its name: the same ip and port, and the hostname when both name one
function moduleFor(modules, sinkName) {
    const k = sinkKey(sinkName);
    if (!k)
        return null;
    for (let i = 0; i < modules.length; i++) {
        const m = modules[i];
        if (m.ip === k.ip && m.port === k.port && (m.host === "" || m.host === k.host))
            return m;
    }
    return null;
}

// "<name> <ifindex>" lines -> the name of an interface index ("" when none)
function ifaceOf(listing, ifindex) {
    const lines = String(listing).split("\n");
    for (let i = 0; i < lines.length; i++) {
        const p = lines[i].trim().split(/\s+/);
        if (p.length === 2 && Number(p[1]) === ifindex && /^[A-Za-z0-9._][A-Za-z0-9._-]{0,14}$/.test(p[0]))
            return p[0];
    }
    return "";
}

// `iw dev <if> get power_save`: "Power save: on" -> "on" | "off" | "" (anything else)
function parsePowerSave(text) {
    const m = /Power save:\s*(on|off)\b/i.exec(String(text));
    return m ? m[1].toLowerCase() : "";
}

// What the player's displays wait for: the sink's latency while mpd's own stream goes into it, 0 otherwise; a number in the
// config replaces the sink's own, the extra is added to either and the total never goes below 0.
function delayMs(cfg, latencyMs, mpdInto) {
    if (!mpdInto)
        return 0;
    const base = cfg.delay === "auto" ? latencyMs : Number(cfg.delay);
    return Math.max(0, Math.round(base + cfg.delayExtraMs));
}

// The helper's answer (stdout) -> { ok, powerSave, missing, why }. An older helper says "unknown command 'wifi-powersave'".
function parseHelperAnswer(text) {
    let a = null;
    try {
        a = JSON.parse(String(text).trim().split("\n").pop());
    } catch (e) {
        a = null;
    }
    if (!a || typeof a !== "object")
        return { ok: false, powerSave: "", missing: false, why: "no answer" };
    if (a.ok === true && a.wifi && (a.wifi.powerSave === "on" || a.wifi.powerSave === "off"))
        return { ok: true, powerSave: a.wifi.powerSave, missing: false, why: "" };
    const why = String(a.why || "refused");
    return { ok: false, powerSave: "", missing: /unknown command/.test(why), why: why };
}
