.pragma library
.import "../../common/board/Figures.js" as Core

// =============================================================================
// Figures.js -- silicon's figures: the display strings the popup hands the scene (the contract, `SiliconScene.figures`) as the cell CODES the shaders
// read. The grammar, the packing and the code alphabet are the board toolkit's (modules/common/board/Figures.js; seg7.glsl says what a code is); what is
// here is silicon's: the time display's printed label, the CPU's three strings and `describe`, which reads silicon's `figures` object.
// No Qt here: it runs under node.
// =============================================================================

var BLANK = Core.BLANK;
var MINUS = Core.MINUS;
var DP = Core.DP;
var COLON = Core.COLON;
function parse(str) {
    return Core.parse(str);
}
function pack(str, cells, hasColon) {
    return Core.pack(str, cells, hasColon);
}
function packText(str, cells) {
    return Core.packText(str, cells);
}
function code4(a) {
    return Core.code4(a);
}
function uncode4(c) {
    return Core.uncode4(c);
}

// the time display's printed label: 0 none, 1 TIME LEFT, 2 TO FULL, 3 TO 80 (SceneGeometry.MODE_LABELS)
function modeCode(mode) {
    return mode === "left" ? 1 : (mode === "full" ? 2 : (mode === "limit" ? 3 : 0));
}

// ---- the CPU's three displays ---------------------------------------------------------------------------------------
// The package's clock, usage and temperature as the strings its three 3-cell displays take (SceneGeometry.SEG7: segClock `cpuClock`, segLoad `cpuLoad`,
// segTemp `cpuTemp`; the sensors are the view model's `cpu.clockMHz / loadPct / tempC`, null until they have answered). A sensor that has not answered is
// dashes, never a dark display (a dark one says there is nothing to say; this one is only waiting), and a value is clamped to what its cells can hold.
//   clockText(mhz)   3.42   0.80   (GHz, two decimals: the point takes no cell; 9.99 at most)         unknown  -.--
//   loadText(pct)    100    38    6                                                                       unknown  ---
//   tempText(c)      105    65                                                                           unknown  ---
function _num(v) {
    return typeof v === "number" && isFinite(v);
}
function clockText(mhz) {
    if (!_num(mhz) || mhz <= 0)
        return "-.--";
    return Math.min(9.99, mhz / 1000).toFixed(2);
}
function loadText(pct) {
    return _num(pct) ? String(Math.max(0, Math.min(100, Math.round(pct)))) : "---";
}
function tempText(c) {
    return _num(c) ? String(Math.max(0, Math.min(999, Math.round(c)))) : "---";
}
// the three strings, keyed as the displays' `key`s are, from the view model's `cpu` (null before the first reading)
function cpuFigures(cpu) {
    var c = cpu || {};
    return { cpuClock: clockText(c.clockMHz), cpuLoad: loadText(c.loadPct), cpuTemp: tempText(c.tempC) };
}

// everything the scene's displays are told, from `figures` (null before the first reading): every display's codes in
// SceneGeometry.SEG7's order (watts, time, sinceFull, ram, then the CPU's clock, usage and temperature), the printed figures and the time label. An empty `timeMode`
// blanks the time display and prints no label for it (no dashes: there is no time to be unknown).
function describe(figures, seg7) {
    var f = figures || {};
    var out = { displays: [], condition: packText(f.condition, 4), cycles: packText(f.cycles, 4), timeLabel: modeCode(f.timeMode) };
    for (var i = 0; i < seg7.length; i++) {
        var d = seg7[i], str = f[d.key];
        if (d.key === "time" && out.timeLabel === 0)
            str = "";
        out.displays.push(pack(str, d.cells, d.colon));
    }
    return out;
}
