.pragma library

// =============================================================================
// PowerFloor.js -- the rule of a FLOOR hold (PowerBus.hold(source, profile, reason, "floor")): when does a profile
// need raising, and when is it already "the floor or better"?
//
// A loaded model may sit at the Balanced CPU profile for as long as it is loaded, but going to Balanced only makes sense
// from quiet (or balanced modified to be lower power): going from performance to balanced would make no sense. So a floor
// of Balanced:
//
//   quiet                       -> raised (Quiet is below Balanced, tweaked or not)
//   balanced, STOCK             -> left alone
//   balanced, TWEAKED LOWER     -> raised to stock Balanced ("modified to be lower power": see belowStock)
//   balanced, tweaked higher    -> left alone (it is already more than the floor)
//   performance                 -> left alone, always
//
// belowStock(cpu, stock): the live values of the CPU (SiliconModel.buildFacts' `cpu`) against what the profile itself
// applies (the config's row for it, `config.profiles[name]`): ANY knob the profile writes that now reads lower than it would
// write is a lower-power tweak. A knob the profile leaves alone (null) counts against the firmware's own ceiling for the two
// that have one (the maximum performance, the power caps) and not at all for EPP, turbo and the governor, as in
// SiliconModel.linkedPatch. The governor is not ranked: powersave and performance are not "lower" and "higher" in the sense
// the user means.
// =============================================================================

var RANK = { quiet: 0, balanced: 1, performance: 2 };
// Energy preference from the thriftiest to the keenest (SiliconModel.EPP_ORDER).
var EPP_ORDER = ["power", "balance_power", "balance_performance", "performance"];

function belowStock(cpu, stock) {
    if (!cpu || !stock)
        return false;
    var f = cpu.features || {};
    if (f.epp && stock.epp && !cpu.eppLocked) {
        var a = EPP_ORDER.indexOf(cpu.epp), b = EPP_ORDER.indexOf(stock.epp);
        if (a >= 0 && b >= 0 && a < b)
            return true;
    }
    if (f.turbo && stock.turbo === true && cpu.turbo === false)
        return true;
    if (f.maxPerfPct && typeof cpu.maxPerfPct === "number") {
        var top = typeof stock.maxPerfPct === "number" ? stock.maxPerfPct : (cpu.maxPerfRange ? cpu.maxPerfRange.max : null);
        if (typeof top === "number" && cpu.maxPerfPct < top)
            return true;
    }
    if (f.caps) {
        var ceil = cpu.capCeilW || {};
        var w1 = typeof stock.pl1W === "number" ? stock.pl1W : ceil.pl1;
        var w2 = typeof stock.pl2W === "number" ? stock.pl2W : ceil.pl2;
        if (typeof w1 === "number" && typeof cpu.pl1W === "number" && cpu.pl1W < w1 - 0.5)
            return true;
        if (typeof w2 === "number" && typeof cpu.pl2W === "number" && cpu.pl2W < w2 - 0.5)
            return true;
    }
    return false;
}

// Does a floor at `floor` need to raise a machine now at `current` (a profile name; "" = not known)?
// `lowered`: the machine is at its Balanced but tweaked lower (belowStock).
function needsRaising(current, floor, lowered) {
    if (RANK[floor] === undefined || RANK[current] === undefined)
        return false;
    if (RANK[current] < RANK[floor])
        return true;
    return current === floor && lowered === true;
}
