.pragma library

// =============================================================================
// DdcParse.js -- the two ddcutil answers Panorama reads, as plain values. Pure: no Qt.
//
//   parseDetect(text)    `ddcutil detect --terse` -> [{ bus, connector, valid, model, mfg, serial }]
//   parseGetvcp(text)    `ddcutil getvcp 10 --brief` -> { ok: true, cur, max } | { ok: false, error }
//   connectorOf(dir)     "card1-DP-1" -> "DP-1" (Hyprland's output name)
//   neverDdc(name)       an internal panel (eDP / LVDS / DSI): backlight is not DDC's; a cast display (LARES-CAST-n) has no DDC either
//   parseBusMap(text)    the sysfs script's "card1-DP-1 i2c-5" lines -> { 5: "DP-1" }
//   resolveDisplays(list, outputs, busMap)
//                        { map: { "DP-1": block }, unresolved: [block] }: a block names its connector, else the bus's sysfs
//                        connector, else its EDID model / serial against the one output that carries them (the NVIDIA driver
//                        prints no "DRM connector" line for some displays)
//   signature(outputs)   a key of the output set (names only) the client compares to decide on a new detect
//
// A block of `detect --terse` starts at a header at column 0 ("Display 1", "Invalid display", "Phantom display") and runs
// on indented lines:
//     Display 1
//        I2C bus:          /dev/i2c-5
//        DRM connector:    card1-DP-1
//        Monitor:          DEL:DELL U2723QE:7ZQ4PX3         (MFG:MODEL:SERIAL, any may be empty)
// Only a "Display N" block is `valid` (the laptop's panel answers "Invalid display": no DDC channel). A bus is the number
// of /dev/i2c-N, -1 when the block names none.
// =============================================================================

function connectorOf(dir) {
    return String(dir || "").replace(/^card\d+-/, "");
}

function neverDdc(name) {
    return /^(eDP|LVDS|DSI)(-|$)/.test(String(name)) || /^LARES-CAST-[0-9]+$/.test(String(name));
}

function parseDetect(text) {
    var out = [];
    var cur = null;
    String(text === undefined || text === null ? "" : text).split("\n").forEach(function (raw) {
        var line = raw.replace(/\r$/, "");
        if (line.trim() === "")
            return;
        if (!/^\s/.test(line)) {
            cur = { bus: -1, connector: "", valid: /^Display\s+\d+/.test(line), model: "", mfg: "", serial: "" };
            out.push(cur);
            return;
        }
        if (!cur)
            return;
        var m = /^\s+([^:]+):\s*(.*)$/.exec(line);
        if (!m)
            return;
        var key = m[1].trim(), val = m[2].trim();
        if (key === "I2C bus") {
            var b = /i2c-(\d+)/.exec(val);
            cur.bus = b ? parseInt(b[1], 10) : -1;
        } else if (key === "DRM connector") {
            cur.connector = /^\(?unknown\)?$/i.test(val) ? "" : connectorOf(val);
        } else if (key === "Monitor") {
            var p = val.split(":");
            cur.mfg = (p[0] || "").trim();
            cur.model = (p[1] || "").trim();
            cur.serial = p.slice(2).join(":").trim();
        }
    });
    return out;
}

// "VCP 10 C 50 100" (continuous: current, maximum). "VCP 10 ND" = not supported by the display. Anything else, or stderr text,
// is an error with the tool's own words.
function parseGetvcp(text) {
    var t = String(text === undefined || text === null ? "" : text).trim();
    var m = /VCP\s+[0-9A-Fa-f]{2}\s+C\s+(\d+)\s+(\d+)/.exec(t);
    if (m)
        return { ok: true, cur: parseInt(m[1], 10), max: parseInt(m[2], 10) };
    if (/VCP\s+[0-9A-Fa-f]{2}\s+ND\b/.test(t))
        return { ok: false, error: "not supported by the display" };
    var e = /VCP\s+[0-9A-Fa-f]{2}\s+ERR\s*(.*)$/m.exec(t);
    if (e)
        return { ok: false, error: e[1].trim() || "the display did not answer" };
    var line = t.split("\n").filter(function (l) { return l.trim() !== ""; })[0];
    return { ok: false, error: line ? line.trim() : "no answer" };
}

function parseBusMap(text) {
    var map = {};
    String(text === undefined || text === null ? "" : text).split("\n").forEach(function (line) {
        var m = /^\s*(\S+)\s+i2c-(\d+)\s*$/.exec(line);
        if (m)
            map[parseInt(m[2], 10)] = connectorOf(m[1]);
    });
    return map;
}

function _norm(s) {
    return String(s === undefined || s === null ? "" : s).toLowerCase().replace(/[^a-z0-9]/g, "");
}

// outputs: [{ name, description, make, model, serial }] (any field may be missing)
function resolveDisplays(list, outputs, busMap) {
    var map = {};
    var unresolved = [];
    var outs = (outputs || []).filter(function (o) { return o && o.name && !neverDdc(o.name); });
    var rest = [];
    (list || []).forEach(function (d) {
        if (!d.valid)
            return;
        var c = d.connector;
        if (c === "" && busMap && busMap[d.bus] !== undefined)
            c = busMap[d.bus];
        if (c !== "" && !map[c])
            map[c] = Object.assign({}, d, { connector: c });
        else if (c === "")
            rest.push(d);
    });
    rest.forEach(function (d) {
        var model = _norm(d.model), serial = _norm(d.serial);
        var tokens = String(d.model || "").split(/\s+/).map(_norm).filter(function (t) { return t !== ""; });
        var cands = outs.filter(function (o) {
            if (map[o.name])
                return false;
            var hay = _norm((o.make || "") + (o.model || "") + (o.description || ""));
            return model !== "" && tokens.every(function (t) { return hay.indexOf(t) >= 0; });
        });
        if (cands.length > 1 && serial !== "")
            cands = cands.filter(function (o) { return _norm((o.serial || "") + (o.description || "")).indexOf(serial) >= 0; });
        if (cands.length === 1)
            map[cands[0].name] = Object.assign({}, d, { connector: cands[0].name });
        else
            unresolved.push(d);
    });
    return { map: map, unresolved: unresolved };
}

function signature(outputs) {
    return (outputs || []).map(function (o) { return o && o.name ? String(o.name) : ""; }).filter(function (n) { return n !== ""; }).sort().join(",");
}
