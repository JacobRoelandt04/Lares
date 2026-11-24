.pragma library

.import "AerialCamera.js" as Cam

// =============================================================================
// AerialLayout.js -- what a click on a part means (an intent name: docs/contracts/aerial.md section 2's `part` ids) and where each part's secondary hangs from.
// `intentFor(G, part)` maps a picked part to its intent ("" for nothing); `anchorPoint(G, intent)` is the board point (mm) a secondary hangs from -- the camera projects it.
// The drop zone and the hologram regions are stage 3's. No Qt here.
// =============================================================================

var PAD_OF = { padLink: "link", ledLink: "link", padAddr: "addr", ledAddr: "addr", padGateway: "gateway", ledGateway: "gateway", padDns: "dns", ledDns: "dns", padNet: "net", ledNet: "net" };

function intentFor(G, part) {
    if (!part)
        return "";
    if (PAD_OF[part])
        return "pad." + PAD_OF[part];
    return G.INTENTS[part] || "";
}

function _mid(p) {
    return [(p.min[0] + p.max[0]) / 2, (p.min[1] + p.max[1]) / 2, (p.min[2] + p.max[2]) / 2];
}
function _part(G, name) {
    for (var i = 0; i < G.PARTS.length; i++)
        if (G.PARTS[i].name === name)
            return G.PARTS[i];
    return null;
}
// the part a secondary hangs from (its box's top middle). The card is not here: its body is the stage, not a button, and no intent maps to it.
var HOME = { label: "label", screw: "screw", "dip.wifi": "dipWifi", "dip.bt": "dipBt", mem: "mem", "bt.scan": "btnBase", beacon: "beacon", jack: "jack", rates: "segRates", usage: "segUsage", globe: "lensCap",
             "pad.link": "padLink", "pad.addr": "padAddr", "pad.gateway": "padGateway", "pad.dns": "padDns", "pad.net": "padNet" };
function anchorPoint(G, intent, st) {
    var p = _part(G, HOME[intent] || "");
    if (!p)
        return null;
    if (!st) {
        var m = _mid(p);
        return [m[0], p.max[1], m[2]];
    }
    // where the part is drawn now: its box's corners through its group's frame (the card tilted, the screw lifted, a lever slid), the top middle
    var cs = Cam.cornersOf(G, p, st), top = -1e9, sx = 0, sz = 0, n = 0;
    cs.forEach(function (c) { top = Math.max(top, c[1]); });
    cs.forEach(function (c) { if (c[1] > top - 1e-6) { sx += c[0]; sz += c[2]; n++; } });
    return [sx / n, top, sz / n];
}
// every intent the board has (the probe hits each one)
function intents() {
    return Object.keys(HOME);
}
