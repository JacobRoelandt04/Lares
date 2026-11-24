.pragma library

// =============================================================================
// PanelBacklightRules.js -- which backlight is the LAPTOP PANEL's, with no Qt in it (PanelBacklight.qml reads sysfs and asks this).
//
// THE RULE. The panel is lit by the backlight of the GPU that DRIVES the eDP connector:
//   Hybrid      the Intel iGPU drives the panel (i915 / xe): its raw `intel_backlight` (max ~400 or more). nvidia_0 may exist in
//               this mode too (the driver registers it); it is the dGPU's and NEVER the panel's here -- writing it correlated
//               with the machine's suspend hangs (docs/idle.md), so a stray nvidia_0 is never picked while the iGPU drives the eDP.
//   dGPU-only   the NVIDIA card drives the panel: `nvidia_0` (brightnessctl: max 100). intel_backlight is not there.
// Where the driver of the eDP cannot be read (no connector listed, no `driver` link) the fallback is the backlight that is
// not NVIDIA's; with none of those, the only backlight present; with several candidates and nothing to tell them apart: none.
//
// `info`: { backlights: [{ name, type, max }], edp: [{ name, driver, connected }] }  -> { ready, device, max, driver, zeroIsBlack, why }
// Nothing found is `ready: false` with device "" -- every consumer behaves as it does with no device.
// =============================================================================

// the backlight names each driver registers
var OWNS = {
    i915: /^intel_backlight$/,
    xe: /^intel_backlight$/,
    amdgpu: /^amdgpu_bl/,
    nvidia: /^nvidia_/,
    nouveau: /^nv_backlight$/
};

// Where a panel's 0 is NOT black: the NVIDIA backlight (the user's observation, dGPU-only: brightness 0 on nvidia_0 does not
// make the panel black). Raw intel and every other device: 0 is black.
var ZERO_NOT_BLACK = /^nvidia_/;

function isNvidia(name) {
    return /^nvidia_/.test(String(name || ""));
}

// Does 0 turn this device's panel black? `overrides`: { "<device>": bool } (idle.jsonc `zeroIsBlack`), an entry of the right kind wins.
function zeroIsBlack(name, overrides) {
    var o = overrides !== null && typeof overrides === "object" ? overrides : {};
    if (typeof o[name] === "boolean")
        return o[name];
    return !ZERO_NOT_BLACK.test(String(name || ""));
}

function _none(why, driver) {
    return { ready: false, device: "", max: 0, driver: driver || "", zeroIsBlack: true, why: why };
}

function _pick(c, driver, overrides) {
    return { ready: true, device: c.name, max: c.max > 0 ? c.max : 1, driver: driver || "", zeroIsBlack: zeroIsBlack(c.name, overrides), why: "" };
}

function decide(info, overrides) {
    var bl = info && info.backlights instanceof Array ? info.backlights : [];
    var edp = info && info.edp instanceof Array ? info.edp : [];
    // THE PANEL'S CONNECTOR IS THE CONNECTED ONE: in Hybrid the NVIDIA card can list an eDP of its own (card0-eDP-2, disconnected) BEFORE
    // the Intel card's (card1-eDP-1, connected); the first connector with a driver then said "nvidia drives the panel and has no
    // backlight" and every key, the idle dim and the lid's dark had no device (2026-11-22, kernel 7.3.5). A connected eDP wins; with
    // none saying so (an old tree, a status that cannot be read) the first with a driver decides, as before.
    var driver = "";
    for (var pass = 0; pass < 2 && driver === ""; pass++) {
        for (var i = 0; i < edp.length; i++) {
            if (edp[i] && typeof edp[i].driver === "string" && edp[i].driver !== "" && (pass === 1 || edp[i].connected === true)) {
                driver = edp[i].driver;
                break;
            }
        }
    }
    var list = [];
    for (var j = 0; j < bl.length; j++)
        if (bl[j] && typeof bl[j].name === "string" && bl[j].name !== "")
            list.push(bl[j]);

    if (driver !== "") {
        var own = OWNS[driver];
        var cands = [];
        for (var k = 0; k < list.length; k++) {
            if (own ? own.test(list[k].name) : !isNvidia(list[k].name))
                cands.push(list[k]);
        }
        if (cands.length === 0)
            return _none("the " + driver + " card drives the panel and has no backlight (yet)", driver);
        return _pick(cands[0], driver, overrides);
    }

    // the driver of the eDP is unknown: never the NVIDIA one while another exists
    var others = [];
    var nv = [];
    for (var m = 0; m < list.length; m++)
        (isNvidia(list[m].name) ? nv : others).push(list[m]);
    if (others.length === 1)
        return _pick(others[0], "", overrides);
    if (others.length === 0 && nv.length === 1)
        return _pick(nv[0], "", overrides);
    if (list.length === 0)
        return _none("no backlight device", "");
    return _none("several backlights and no way to tell which is the panel's", "");
}

// The script's output ("bl <name> <type> <max>" / "edp <connector> <driver|-> <status|->") -> info.
function parseScan(text) {
    var info = { backlights: [], edp: [] };
    var lines = String(text === undefined || text === null ? "" : text).split("\n");
    for (var i = 0; i < lines.length; i++) {
        var p = lines[i].trim().split(/\s+/);
        if (p[0] === "bl" && p.length >= 4)
            info.backlights.push({ name: p[1], type: p[2], max: parseInt(p[3]) || 0 });
        else if (p[0] === "edp" && p.length >= 2)
            info.edp.push({ name: p[1], driver: p.length > 2 && p[2] !== "-" ? p[2] : "", connected: p.length > 3 && p[3] === "connected" });
    }
    return info;
}
