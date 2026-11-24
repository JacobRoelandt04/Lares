"use strict";
// aerial_facts_cases.js -- AerialFacts' two displays and their engraved units (RATE - kb/s | Mb/s | Gb/s, DATA - MiB | GiB | TiB): the figure is always four cells, the unit changes
// where they would overflow, and a rounding that reaches the next decade is that decade. `node tools/dev/aerial_facts_cases.js` ends in AERIAL_FACTS_CASES RESULT PASS|FAIL.
// ARM=nounit (an env var for the node run: the units never change) must FAIL; the label's arms are named where its cases are.
// Also holds the dead-helper words (label idle line, AerialPill's warn fault): ARMs nohelperword, helperlast, nohelperwarn, helperhealthy.
const fs = require("fs");
const path = require("path");
let pillSrc = fs.readFileSync(path.join(__dirname, "..", "..", "modules/aerial/bar/AerialPill.js"), "utf8").replace(/^\.pragma.*$/m, "");
let src = fs.readFileSync(path.join(__dirname, "..", "..", "modules/aerial/scene/AerialFacts.js"), "utf8").replace(/^\.pragma.*$/m, "");
// the arms: a fault patched into the source this run evaluates (the file is never written); an anchor that is gone fails the run by itself
const ARMS = {
    nounit: ['unit = "Gb/s";', 'unit = "Mb/s";'],
    allbt: ["if (!d || !d.connected || d.blocked)", "if (!d || d.blocked)"],
    nocoming: ['lineB: coming ? "connecting…" : [', 'lineB: [' ],
    // the dead-helper arms: each removes exactly one half of commit eef271f7 (3rd member "pill" patches AerialPill.js)
    nohelperword: ['helper.state === "failed" ? "Network helper not running"', 'false ? "Network helper not running"'],
    helperlast: ['label.idle = label.docked ? "" : (helperWord !== "" ? helperWord : (air.on ? "airplane mode" : (wifi.present !== false && wifi.radioOn === false ? "Wi-Fi is off" : "")));',
                 'label.idle = label.docked ? "" : (air.on ? "airplane mode" : (wifi.present !== false && wifi.radioOn === false ? "Wi-Fi is off" : (helperWord !== "" ? helperWord : "")));'],
    nohelperwarn: ['fault: helperFailed ? "warn" : netOn ? worst : "",', 'fault: netOn ? worst : "",', "pill"],
    helperhealthy: ['var helperFailed = !!f.helper && f.helper.state === "failed";', 'var helperFailed = !!f.helper;', "pill"],
    novia: ['    } else if (plugged) {\n        label = { docked: true, name: "Wired", lineA: jack.speedMbps ? jack.speedMbps + " Mb/s" : "", lineB: jack.ip4 || "", via: "", hint: false };\n        tunnelled = true;',
            '    } else if (plugged) {\n        label = { docked: true, name: "Wired", lineA: jack.speedMbps ? jack.speedMbps + " Mb/s" : "", lineB: jack.ip4 || "", via: "", hint: false };']
};
if (process.env.ARM) {
    const arm = ARMS[process.env.ARM];
    if (!arm || (arm[2] === "pill" ? pillSrc : src).split(arm[0]).length !== 2) {
        console.log("AERIAL_FACTS_CASES RESULT FAIL (arm " + process.env.ARM + ": its anchor is gone)");
        process.exit(2);
    }
    if (arm[2] === "pill") {
        if (pillSrc.split(arm[0]).length !== 2) {
            console.log("AERIAL_FACTS_CASES RESULT FAIL (arm " + process.env.ARM + ": its anchor is gone)");
            process.exit(2);
        }
        pillSrc = pillSrc.replace(arm[0], arm[1]);
    } else
        src = src.replace(arm[0], arm[1]);
}
const F = new Function(src + ";return { ratesFigure: ratesFigure, usageFigure: usageFigure, cellsText: cellsText, describe: describe, labelDevices: labelDevices, deviceSub: deviceSub };")();
const P = new Function(pillSrc + ";return { of: of };")();
let bad = 0;
function eq(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        bad++;
        console.log("  FAIL " + name + ": got " + JSON.stringify(got) + " want " + JSON.stringify(want));
    }
}
const r = (v) => { const x = F.ratesFigure(v, true); return [F.cellsText(x.cells), x.unit]; };
const MIB = 1048576, GIB = 1073741824;
const u = (b) => { const x = F.usageFigure(b, true); return [F.cellsText(x.cells), x.unit]; };
eq("rate 0", r(0), ["d000", "kb/s"]);
eq("rate 0.5", r(0.5), ["d500", "kb/s"]);
eq("rate 0.9996 is 1.00 Mb/s", r(0.9996), ["d1.00", "Mb/s"]);
eq("rate 9.99", r(9.99), ["d9.99", "Mb/s"]);
eq("rate 9.996 is 10.0", r(9.996), ["d10.0", "Mb/s"]);
eq("rate 99.96 is 100", r(99.96), ["d100", "Mb/s"]);
eq("rate 999.4", r(999.4), ["d999", "Mb/s"]);
eq("rate 999.5 -> Gb/s", r(999.5), ["d1.00", "Gb/s"]);
eq("rate 12000 -> 12.0 Gb/s", r(12000), ["d12.0", "Gb/s"]);
eq("rate unknown", F.ratesFigure(5, false).cells.length, 4);
eq("usage 0", u(0), ["   0", "MiB"]);
eq("usage 9999 MiB", u(9999 * MIB), ["9999", "MiB"]);
eq("usage 10000 MiB -> GiB", u(10000 * MIB), ["9.766", "GiB"]);
eq("usage 12.06 GiB", u(12345 * MIB), ["12.06", "GiB"]);
eq("usage 931 GiB", u(1e12), ["931.3", "GiB"]);
eq("usage 999.96 GiB rounds up", u(999.96 * GIB), ["1000", "GiB"]);
eq("usage 10000 GiB -> TiB", u(10000 * GIB), ["9.766", "TiB"]);
eq("describe carries the units", F.describe(null, 0).units, { rates: "Mb/s", usage: "MiB" });
eq("describe: 12 Gb/s link", F.describe({ rates: { rxBps: 1.5e9, atMs: 1, iface: "w" } }, 0).units.rates, "Gb/s");
// ---- the label (round 3): the connected devices on it, the tunnel ----
// ARM=allbt (every device, connected or not, is printed on the label) and ARM=novia (a cable's tunnel prints no "via") must FAIL.
const DEVS = [
    { address: "CC:00", name: "Mouse", kind: "mouse", connected: true, battery: 55 },
    { address: "AA:01", name: "Earbuds", kind: "earbuds", connected: true, battery: 74, parts: { left: 74, right: 80, case: 100, charging: false } },
    { address: "BB:02", name: "Pixel 8", kind: "phone", connected: false, paired: true },
    { address: "AA:00", name: "Keys", kind: "keyboard", connected: true, blocked: true },
    { address: "DD:03", name: "", kind: undefined, connected: true }
];
const lab = (f) => F.describe(f, 0).label;
eq("label: no facts, nothing on it", [lab(null).bt, lab(null).vpn, lab(null).docked], [[], false, false]);
const lb = lab({ bt: { devices: DEVS } }).bt;
eq("label: only the connected, unblocked devices", lb.map((d) => d.address), ["AA:01", "CC:00", "DD:03"]);
eq("label: by address, whatever the service's order", lab({ bt: { devices: DEVS.slice().reverse() } }).bt.map((d) => d.address), ["AA:01", "CC:00", "DD:03"]);
eq("label: a device's facts", lb[0], { address: "AA:01", name: "Earbuds", kind: "earbuds", battery: 74, parts: { left: 74, right: 80, case: 100, charging: false } });
eq("label: no name is the address, no kind is generic, no battery is -1", lb[2], { address: "DD:03", name: "DD:03", kind: "generic", battery: -1, parts: null });
eq("label: the sub-line, parts", F.deviceSub(lb[0]), "L 74 · R 80 · case 100");
eq("label: the sub-line, a kind", [F.deviceSub(lb[1]), F.deviceSub(lb[2])], ["mouse", "device"]);
const WIFI = { active: { ssid: "Home-5G", band: "5", channel: 36, standard: "Wi-Fi 6", dbm: -54, rateMbps: 1201 } };
const UP = { state: "up", server: { country: "NL", name: "NL#42" } };
eq("label: tunnelled Wi-Fi", [lab({ wifi: WIFI, proton: UP }).vpn, lab({ wifi: WIFI, proton: UP }).via], [true, "via NL · NL#42"]);
eq("label: no tunnel, no via", [lab({ wifi: WIFI }).vpn, lab({ wifi: WIFI }).via], [false, ""]);
eq("label: a tunnel going up is not up", lab({ wifi: WIFI, proton: { state: "connecting", server: UP.server } }).vpn, false);
eq("label: a tunnelled cable prints via too", lab({ wired: { jacks: [{ kind: "rj45", carrier: true, speedMbps: 1000 }] }, proton: UP }).via, "via NL · NL#42");
eq("label: the own hotspot is not tunnelled, the plate still is", [lab({ hotspot: { active: true, ssid: "laptop" }, proton: UP }).via, lab({ hotspot: { active: true, ssid: "laptop" }, proton: UP }).vpn], ["", true]);
// ---- a network still coming up is on the label already (round 5: a dropped tag shrinks into the label at once): the second line says so. ARM=nocoming must FAIL.
const COMING = { active: { key: "Home-5G", ssid: "Home-5G", band: "5", channel: 36, standard: "", dbm: 0, rateMbps: 0 }, networks: [{ key: "Home-5G", state: "connecting" }] };
eq("label: a network coming up says so", [lab({ wifi: COMING }).docked, lab({ wifi: COMING }).lineB], [true, "connecting…"]);
eq("label: connected, the link's figures", lab({ wifi: Object.assign({ networks: [{ key: "Home-5G", state: "connected" }] }, { active: Object.assign({ key: "Home-5G" }, WIFI.active) }) }).lineB, "-54 dBm · 1201 Mb/s");
// ---- a dead network helper is SAID (commit eef271f7): the label's idle line and the pill's warn fault; a healthy or absent helper says nothing.
// ARMs nohelperword (no words), helperlast (airplane / Wi-Fi off outrank it), nohelperwarn (the pill stays calm), helperhealthy (any helper record counts as dead) must FAIL.
const DEAD = { state: "failed", error: "the network helper exited (1)" };
eq("helper dead: the label says so", lab({ helper: DEAD }).idle, "Network helper not running: the network helper exited (1)");
eq("helper dead, no error text: the bare words", lab({ helper: { state: "failed" } }).idle, "Network helper not running");
eq("helper dead outranks airplane mode and Wi-Fi off", [lab({ helper: DEAD, airplane: { on: true } }).idle.indexOf("Network helper not running"), lab({ helper: DEAD, wifi: { present: true, radioOn: false } }).idle.indexOf("Network helper not running")], [0, 0]);
eq("helper healthy: no helper words", [lab({ helper: { state: "running" } }).idle, lab({}).idle, lab({ helper: { state: "starting" } }).idle], ["", "", ""]);
eq("helper healthy keeps airplane's own word", lab({ helper: { state: "running" }, airplane: { on: true } }).idle, "airplane mode");
eq("pill: a dead helper warns, with the net half off", [P.of({ helper: DEAD }).fault, P.of({ helper: DEAD }).helperFailed], ["warn", true]);
eq("pill: a healthy helper does not warn", [P.of({ helper: { state: "running" } }).fault, P.of({ helper: { state: "running" } }).helperFailed, P.of({}).fault], ["", false, ""]);
console.log("AERIAL_FACTS_CASES RESULT " + (bad ? "FAIL (" + bad + ")" : "PASS"));
process.exit(bad ? 1 : 0);
