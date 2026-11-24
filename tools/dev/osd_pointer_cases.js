// node tools/dev/osd_pointer_cases.js -- OsdPointer.js: the pointer's monitor; OsdKinds.js: what is an event, what the user did, the config's merge
const fs = require("fs");
const src = fs.readFileSync(__dirname + "/../../modules/osd/data/OsdPointer.js", "utf8").replace(/^\.pragma library/m, "");
const P = new Function(src + "; return { logicalRect, monitorAt, parseCursor };")();
let fails = 0;
const ck = (n, ok, d) => { if (!ok) fails++; console.log("OSDPTR " + (ok ? "ok  " : "FAIL") + " " + n + (ok ? "" : "  [" + JSON.stringify(d) + "]")); };
const L = { name: "eDP-1", x: 0, y: 0, width: 2880, height: 1620, scale: 1.5, transform: 0 };   // logical 1920 x 1080
const E = { name: "DP-1", x: 1920, y: 0, width: 2560, height: 1440, scale: 1, transform: 0 };
const rects = [L, E];
ck("logical size = pixels / scale", JSON.stringify(P.logicalRect(L)) === JSON.stringify({ name: "eDP-1", x: 0, y: 0, width: 1920, height: 1080 }), P.logicalRect(L));
ck("inside the laptop", P.monitorAt(rects, 100, 100) === "eDP-1", 0);
ck("inside the external", P.monitorAt(rects, 3000, 700) === "DP-1", 0);
ck("a point ON the shared edge belongs to the monitor that starts there", P.monitorAt(rects, 1920, 500) === "DP-1" && P.monitorAt(rects, 1919, 500) === "eDP-1", 0);
ck("the far edge is outside (half open)", P.monitorAt(rects, 4480, 10) === "" && P.monitorAt(rects, 4479, 10) === "DP-1", 0);
ck("below the laptop (taller external): the external only past x", P.monitorAt(rects, 100, 1080) === "" && P.monitorAt(rects, 2000, 1100) === "DP-1", 0);
const left = [{ name: "DP-2", x: -1920, y: -200, width: 1920, height: 1080, scale: 1, transform: 0 }, L];
ck("negative coordinates", P.monitorAt(left, -1, -200) === "DP-2" && P.monitorAt(left, -1921, 0) === "" && P.monitorAt(left, 0, -200) === "" && P.monitorAt(left, 0, 0) === "eDP-1", 0);
const R = { name: "DP-3", x: 0, y: 0, width: 1920, height: 1080, scale: 1, transform: 1 };
ck("transform 1 swaps width and height", P.monitorAt([R], 1000, 1500) === "DP-3" && P.monitorAt([R], 1079, 1919) === "DP-3" && P.monitorAt([R], 1080, 10) === "" && P.monitorAt([R], 10, 1920) === "", P.logicalRect(R));
ck("transform 3 swaps too, 2 does not", P.logicalRect(Object.assign({}, R, { transform: 3 })).width === 1080 && P.logicalRect(Object.assign({}, R, { transform: 2 })).width === 1920, 0);
ck("already logical rects (no scale field) are taken as is", P.monitorAt([{ name: "A", x: 0, y: 0, width: 100, height: 50 }], 99, 49) === "A", 0);
ck("garbage is no monitor", P.monitorAt(null, 1, 1) === "" && P.monitorAt(rects, NaN, 1) === "", 0);
ck("cursorpos json", JSON.stringify(P.parseCursor('{"x": 12, "y": -3}')) === '{"x":12,"y":-3}' && P.parseCursor("nope") === null && P.parseCursor('{"x":1}') === null, 0);
const K = new Function(fs.readFileSync(__dirname + "/../../modules/osd/data/OsdKinds.js", "utf8").replace(/^\.pragma library/m, "")
    + "; return { eventOf, byUser, mergeConfig, sampleRequest };")();
const S = (kind, over) => Object.assign(K.sampleRequest(kind), over);
ck("the events' words", JSON.stringify([
    K.eventOf(S("volume", { source: "key" })), K.eventOf(S("volume", { source: "external", event: "device" })), K.eventOf(S("mic", { source: "external" })),
    K.eventOf(S("track", { source: "key" })), K.eventOf(S("track", { source: "external" })), K.eventOf(S("track", { source: "external", event: "key" })),
    K.eventOf(S("network", {})), K.eventOf(S("network", { net: { ssid: "", signal: 0, state: "lost", via: "wired" } })), K.eventOf(S("vpn", {})),
    K.eventOf(S("bluetooth", {})), K.eventOf(S("battery", {})), K.eventOf(S("capture", {})), K.eventOf(S("theme", {}))
]) === JSON.stringify(["key", "device", "external", "key", "change", "key", "connected", "wired", "up", "connected", "low", "shot", ""]), 0);
ck("fullscreen \"keys\": the keys, a media key's track, a capture, the dictation's words; no news", JSON.stringify(
    ["volume", "theme", "capture", "caption"].map(k => K.byUser(S(k, { source: "external" }))).concat([K.byUser(S("track", { source: "key" }))],
    ["track", "network", "vpn", "bluetooth", "battery", "power", "btLow"].map(k => K.byUser(S(k, { source: "external" }))))
) === JSON.stringify([true, true, true, true, true, false, false, false, false, false, false, false]), 0);
const dflt = K.mergeConfig({});
ck("the new keys' defaults", dflt.screen === "focused" && dflt.fullscreen === "pill" && dflt.brightness.target === "pointer" && dflt.media.keys === "mpd"
    && dflt.capture.click === "edit" && dflt.capture.editCommand.length === 0 && dflt.kinds.track.events === undefined, dflt);
const bad = K.mergeConfig({ screen: 5, fullscreen: "no", brightness: { target: "x" }, media: { keys: 1 }, capture: { openCommand: [], editCommand: [""], name: "a/b.png", click: 0 }, kinds: { track: { events: "key" }, theme: { events: ["key"] } } });
ck("a bad value is the default", JSON.stringify(bad) === JSON.stringify(dflt), bad);
ck("events: the kind's own words alone", JSON.stringify(K.mergeConfig({ kinds: { track: { events: ["key", "nope"] } } }).kinds.track.events) === '["key"]', 0);
console.log("OSDPTR RESULT " + (fails === 0 ? "PASS" : "FAIL"));
process.exit(fails ? 1 : 0);
