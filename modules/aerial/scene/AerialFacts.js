.pragma library

// =============================================================================
// AerialFacts.js -- what the board shows of the service's facts (docs/contracts/aerial.md section 2), as plain numbers and strings. Pure: no Qt, runs under node.
//
//   describe(facts, nowMs) -> { units: { rates: "kb/s"|"Mb/s"|"Gb/s", usage: "MiB"|"GiB"|"TiB" } (the engraved units), wifiOn, wifiLocked, btOn, btLocked, airplane, plugged, speedMbps, active (the carrying link is busy), led: { intensity[8], colour[8] },
//                              rates: [4 cell codes], usage: [4 cell codes], beacon: { on, ring }, btnLit,
//                              label: { docked, name, lineA, lineB, via, hint, vpn, bt: [{ address, name, kind, battery, parts }] } }
// THE LABEL (round 3): `bt` is the CONNECTED Bluetooth devices, the label's upper zone (by address: a stable order, so a row keeps its place while the others come and go);
// `vpn` the tunnel is up (the label turns to chrome); `via` is printed for whatever is docked but the own hotspot.
//
// The LEDs (the glow's indices): 0 the beacon, 1 the jack's green, 2 its amber, 3..7 the pads LINK ADDR GATEWAY DNS NET. A colour: 0 off, 1 ok, 2 warn, 3 error, 4 accent.
// The cell codes are seg7.glsl's: 0-9 a digit, 10 the minus, 11 blank, 12 `d`, 13 `h`, + 16 for the decimal point after the cell.
// No fact is invented: a pad whose test has not run is dark, a figure the service does not know is blank dashes.
// =============================================================================

var BLANK = 11, MINUS = 10, DP = 16, D = 12;
var PADS = ["link", "addr", "gateway", "dns", "net"];

function _digit(n) { return Math.max(0, Math.min(9, Math.floor(n))); }

// The rate display: `d` (or `h` while the up leg runs) then three digits, and the engraved unit that goes with them (RATE - kb/s | Mb/s | Gb/s). The unit changes where the three
// digits would overflow, so the figure is always three significant digits: under 1 Mb/s whole kb/s (0..999), 1..999 Mb/s as 1.23 / 12.3 / 123, from 1000 Mb/s Gb/s as 1.23 / 12.3 / 123.
// -> { cells: [4 codes], unit }
function ratesFigure(mbps, known, prefix) {
    var p = prefix === undefined ? D : prefix;
    if (!known)
        return { cells: [p, MINUS, MINUS, MINUS], unit: "Mb/s" };
    var v = Math.max(0, mbps), unit = "Mb/s";
    if (v < 1 && Math.round(v * 1000) < 1000) {
        var k = Math.round(v * 1000);
        return { cells: [p, _digit(k / 100), _digit((k % 100) / 10), _digit(k % 10)], unit: "kb/s" };
    }
    if (v >= 999.5) {
        v = v / 1000;
        unit = "Gb/s";
    }
    if (v < 10 && Math.round(v * 100) >= 1000)         // a rounding that reaches the next decade is that decade
        v = 10;
    if (v < 100 && Math.round(v * 10) >= 1000)
        v = 100;
    var cells;
    if (v < 10) {
        var t = Math.min(999, Math.round(v * 100));
        cells = [p, _digit(t / 100) + DP, _digit((t % 100) / 10), _digit(t % 10)];
    } else if (v < 100) {
        var u = Math.round(v * 10);
        cells = [p, _digit(u / 100), _digit((u % 100) / 10) + DP, _digit(u % 10)];
    } else {
        var w = Math.min(999, Math.round(v));
        cells = [p, _digit(w / 100), _digit((w % 100) / 10), _digit(w % 10)];
    }
    return { cells: cells, unit: unit };
}
// The data display: today's total in binary units, four digits, and the engraved unit (DATA - MiB | GiB | TiB). MiB as a whole number up to 9999 (blank-padded), then GiB, then TiB: from
// 10 000 of a unit the next one, as 1.234 / 12.34 / 123.4 / 1234. -> { cells: [4 codes], unit }
function usageFigure(bytes, known) {
    if (!known)
        return { cells: [MINUS, MINUS, MINUS, MINUS], unit: "MiB" };
    var v = Math.max(0, bytes) / 1048576, unit = "MiB";
    if (Math.round(v) >= 10000) {
        v = v / 1024;
        unit = "GiB";
        if (v >= 9999.5) {
            v = v / 1024;
            unit = "TiB";
        }
    }
    if (unit === "MiB") {
        var m = Math.round(v);
        return { cells: [m >= 1000 ? _digit(m / 1000) : BLANK, m >= 100 ? _digit((m % 1000) / 100) : BLANK, m >= 10 ? _digit((m % 100) / 10) : BLANK, _digit(m % 10)], unit: unit };
    }
    if (v < 10 && Math.round(v * 1000) >= 10000)
        v = 10;
    if (v < 100 && Math.round(v * 100) >= 10000)
        v = 100;
    if (v < 1000 && Math.round(v * 10) >= 10000)
        v = 1000;
    if (v < 10) {
        var a = Math.round(v * 1000);
        return { cells: [_digit(a / 1000) + DP, _digit((a % 1000) / 100), _digit((a % 100) / 10), _digit(a % 10)], unit: unit };
    }
    if (v < 100) {
        var b = Math.round(v * 100);
        return { cells: [_digit(b / 1000), _digit((b % 1000) / 100) + DP, _digit((b % 100) / 10), _digit(b % 10)], unit: unit };
    }
    if (v < 1000) {
        var c = Math.round(v * 10);
        return { cells: [_digit(c / 1000), _digit((c % 1000) / 100), _digit((c % 100) / 10) + DP, _digit(c % 10)], unit: unit };
    }
    var w = Math.min(9999, Math.round(v));
    return { cells: [_digit(w / 1000), _digit((w % 1000) / 100), _digit((w % 100) / 10), _digit(w % 10)], unit: unit };
}
// the cells alone (SpeedDisplay.js takes the rates' cells for a speed test's result) and the unit that goes with them
function ratesCells(mbps, known, prefix) {
    return ratesFigure(mbps, known, prefix).cells;
}
function ratesUnit(mbps, known) {
    return ratesFigure(mbps, known, D).unit;
}
function usageCells(bytes, known) {
    return usageFigure(bytes, known).cells;
}
// the codes of a cell array packed in one number (what a cached uniform would see change): not needed by the glow, which is live; the probe reads the strings
function cellsText(cells) {
    return cells.map(function (c) {
        var ch = c % 16;
        var s = ch <= 9 ? String(ch) : (ch === MINUS ? "-" : (ch === D ? "d" : (ch === 13 ? "h" : " ")));
        return s + (c >= 16 ? "." : "");
    }).join("");
}

function _padLed(p) {
    if (!p)
        return [0, 1];
    if (p.state === "ok")
        return [1, 1];
    if (p.state === "warn")
        return [1, 2];
    if (p.state === "fail")
        return [1, 3];
    if (p.state === "testing")
        return [0.55, 4];
    return [0, 1];
}

function macOf(m) {
    return String(m || "").replace(/[^0-9A-Fa-f]/g, "").toUpperCase();
}

// the label's Bluetooth zone: the connected devices, by address (a blocked one is not shown anywhere)
function labelDevices(bt) {
    var out = [];
    ((bt && bt.devices) || []).forEach(function (d) {
        if (!d || !d.connected || d.blocked)
            return;
        var p = d.parts || null;
        out.push({
            address: String(d.address || ""), name: String(d.name || d.address || ""), kind: d.kind || "generic",
            battery: d.battery === undefined || d.battery === null ? -1 : d.battery,
            parts: p ? { left: p.left === undefined ? -1 : p.left, right: p.right === undefined ? -1 : p.right, "case": p["case"] === undefined ? -1 : p["case"], charging: !!p.charging } : null
        });
    });
    out.sort(function (x, y) { return x.address < y.address ? -1 : (x.address > y.address ? 1 : 0); });
    return out;
}
// a device kind's glyph (Symbols Nerd Font, md-*: earbuds, headphones, speaker, cellphone, laptop, mouse, keyboard, gamepad, watch, bluetooth)
var KIND_GLYPH = { earbuds: 0xF184F, headset: 0xF02CE, speaker: 0xF04C3, phone: 0xF011C, computer: 0xF0322, mouse: 0xF037D, keyboard: 0xF030C, gamepad: 0xF0297, watch: 0xF0589, generic: 0xF00AF };
function glyphOf(kind) {
    return String.fromCodePoint(KIND_GLYPH[kind] || KIND_GLYPH.generic);
}
// the sub-line under a single device's name: its parts when the device reports them ("L 74 · R 80 · case 100"), else what it is
var KIND_WORD = { earbuds: "earbuds", headset: "headset", speaker: "speaker", phone: "phone", computer: "computer", mouse: "mouse", keyboard: "keyboard", gamepad: "gamepad", watch: "watch", generic: "device" };
function deviceSub(d) {
    var p = d && d.parts, out = [];
    if (p) {
        if (p.left >= 0) out.push("L " + Math.round(p.left));
        if (p.right >= 0) out.push("R " + Math.round(p.right));
        if (p["case"] >= 0) out.push("case " + Math.round(p["case"]));
        if (p.charging) out.push("charging");
    }
    return out.length ? out.join(" · ") : (KIND_WORD[d ? d.kind : ""] || "device");
}

function describe(facts, nowMs) {
    var f = facts || {};
    var wifi = f.wifi || {}, bt = f.bt || {}, wired = f.wired || { jacks: [] }, hot = f.hotspot || {}, proton = f.proton || {}, health = f.health || { pads: [] };
    var rates = f.rates || {}, usage = f.usage || {}, speed = f.speed || {}, air = f.airplane || {}, helper = f.helper || {};
    var jack = null;
    (wired.jacks || []).forEach(function (j) {
        if (!jack && j.kind === "rj45")
            jack = j;
    });
    var plugged = !!(jack && jack.carrier);
    var active = (rates.rxBps || 0) + (rates.txBps || 0) > 20000;
    var led = { intensity: [0, 0, 0, 0, 0, 0, 0, 0], colour: [1, 1, 1, 1, 1, 1, 1, 1] };
    // the jack: green = link, amber = activity (on the cable only)
    var cableCarries = plugged && (!wifi.active || (rates.iface && jack && rates.iface === jack.iface));
    led.intensity[1] = plugged ? 1 : 0;
    led.intensity[2] = cableCarries && active ? 1 : 0;
    led.colour[1] = 1;
    led.colour[2] = 2;
    var padById = {};
    (health.pads || []).forEach(function (p) { padById[p.id] = p; });
    PADS.forEach(function (id, i) {
        var l = _padLed(padById[id]);
        led.intensity[3 + i] = l[0];
        led.colour[3 + i] = l[1];
    });
    // the beacon: lit while the adapter is visible; the ring is the share of the window left
    var until = bt.visibleUntilMs || 0, total = Math.max(1000, (f.config && f.config.visibleSeconds ? f.config.visibleSeconds : 180) * 1000);
    var beaconOn = !!bt.discoverable && until > nowMs;
    var ring = beaconOn ? Math.max(0.02, Math.min(1, (until - nowMs) / total)) : 0;
    led.intensity[0] = beaconOn ? 1 : 0;
    led.colour[0] = 4;
    var speedLive = speed.state === "down" || speed.state === "up" || speed.state === "latency";
    var downMbps = speed.state === "up" ? (speed.liveMbps || 0) : (speedLive ? (speed.liveMbps || 0) : (rates.rxBps || 0) * 8 / 1e6);
    var known = !!(rates.atMs || rates.iface);
    var rateFig = speed.state === "done" && speed.result ? ratesFigure(speed.result.downMbps, true, D) : ratesFigure(downMbps, known, speed.state === "up" ? 13 : D);
    var usageKnown = usage.todayBytes !== undefined && (usage.days || []).length + (usage.byNetwork || []).length > 0 || (usage.todayBytes || 0) > 0;
    var usageFig = usageFigure(usage.todayBytes || 0, usageKnown);
    // the label: what is docked
    var label = { docked: false, name: "", lineA: "", lineB: "", via: "", hint: true };
    var a = wifi.active, tunnelled = false;
    if (hot.active && hot.ssid) {
        label = { docked: true, name: hot.ssid, lineA: "hotspot · " + (hot.band || "") + (hot.band ? " GHz" : ""), lineB: (hot.clients || []).length + " connected", via: "", hint: false };
    } else if (a) {
        var rate = a.rateMbps ? Math.round(a.rateMbps) + " Mb/s" : "";
        // a network that is still coming up is docked already (a dropped tag has shrunk into the label): the second line says so until the link's figures are there
        var coming = (wifi.networks || []).some(function (n) { return n.key === a.key && n.state === "connecting"; });
        label = {
            docked: true, name: a.ssid || a.key || "",
            lineA: [a.band ? a.band + " GHz" : "", a.channel ? "ch " + a.channel : "", a.standard || ""].filter(function (x) { return x !== ""; }).join(" · "),
            lineB: coming ? "connecting…" : [a.dbm ? a.dbm + " dBm" : "", rate].filter(function (x) { return x !== ""; }).join(" · "),
            via: "", hint: false
        };
        tunnelled = true;
    } else if (plugged) {
        label = { docked: true, name: "Wired", lineA: jack.speedMbps ? jack.speedMbps + " Mb/s" : "", lineB: jack.ip4 || "", via: "", hint: false };
        tunnelled = true;
    }
    label.vpn = proton.state === "up";
    if (label.vpn && tunnelled && proton.server)
        label.via = "via " + (proton.server.country || "") + (proton.server.name ? " · " + proton.server.name : "");
    label.bt = labelDevices(bt);
    // nothing docked and nothing CAN be: the zone says why instead of asking for a drop (airplane: the card is out of its slot; the Wi-Fi latch is off)
    // (a dead helper first: every board fact is then stale, and a click only fails)
    var helperWord = helper.state === "failed" ? "Network helper not running" + (helper.error ? ": " + String(helper.error).replace(/\s+/g, " ").slice(0, 48) : "") : "";
    label.idle = label.docked ? "" : (helperWord !== "" ? helperWord : (air.on ? "airplane mode" : (wifi.present !== false && wifi.radioOn === false ? "Wi-Fi is off" : "")));
    return {
        wifiOn: !!wifi.radioOn && !wifi.hardBlocked, wifiLocked: !!wifi.hardBlocked,
        btOn: !!bt.powered && !bt.hardBlocked, btLocked: !!bt.hardBlocked,
        airplane: !!air.on, plugged: plugged, speedMbps: jack ? jack.speedMbps || 0 : 0, active: active,
        led: led, rates: rateFig.cells, usage: usageFig.cells, units: { rates: rateFig.unit, usage: usageFig.unit },
        beacon: { on: beaconOn, ring: ring }, btnLit: !!bt.discovering,
        label: label,
        wfm: macOf(wifi.permMac || wifi.mac), bdm: macOf(bt.address),
        padStates: PADS.map(function (id) { return padById[id] ? padById[id].state : "unknown"; })
    };
}
