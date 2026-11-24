.pragma library

// =============================================================================
// TuningModel.js -- the words and the small rules of the CPU tuning panel. Pure, no Qt.
//
//   eppTabs(choices)          the four energy steps a person is offered, thriftiest first
//                             (`default` is an alias of balance_performance on this CPU and is
//                             never offered: CONTRACT section 7)
//   govTabs(names)            the kernel's governors, in the order a person reads them
//   governorHint(name, names, hasEpp)   ONE honest line of what a governor does here
//   governorTip(names, hasEpp)          the longer explanation, for the hover tip
//   modeTabs(cwModes)         cardwire's modes in the scene's step order, for the GPU panel
//
// WHERE THE GOVERNOR WORDS COME FROM (docs.kernel.org/admin-guide/pm/):
//   intel_pstate "Active Mode": it bypasses the governors layer and offers TWO algorithms named
//   powersave and performance, which "generally do not work in the same way as the generic
//   governors they share the names with" -- its powersave "roughly corresponds to schedutil and
//   ondemand". With HWP: performance "will write 0 to the processor's Energy-Performance Preference
//   ... which means that the processor's internal P-state selection logic is expected to focus
//   entirely on performance", rejects any other EPP, and restricts the P-state range to its upper
//   boundary; powersave sets the EPP "to whatever value it was previously set to via sysfs", which
//   "usually causes the processor's internal P-state selection logic to be less performance-focused".
//   cpufreq "Governors": generic performance requests the highest frequency within the limit, generic
//   powersave the lowest; userspace "does not do anything by itself" (a program sets the speed
//   through scaling_setspeed); schedutil follows the scheduler's own utilisation numbers; ondemand
//   selects frequencies proportional to the measured load; conservative does the same "in relatively
//   small steps, one step at a time".
//   The generic ones appear only in the passive mode ("intel_cpufreq"), where the list is the
//   kernel's full one; the active mode lists exactly powersave and performance.
// =============================================================================

var EPP_ORDER = ["power", "balance_power", "balance_performance", "performance"];
// The labels split on the space, so a four-slot selector keeps the kernel's own words at a size a
// slot of ~80 px holds.
var EPP_LABEL = {
    power: "Power",
    balance_power: "Balance\npower",
    balance_performance: "Balance\nperformance",
    performance: "Performance"
};

var GOV_ORDER = ["powersave", "performance", "schedutil", "ondemand", "conservative", "userspace"];
// Governors that exist only as the kernel's generic ones (never in intel_pstate's active mode).
var GENERIC_ONLY = ["schedutil", "ondemand", "conservative", "userspace"];

function _title(s) {
    var t = String(s === undefined || s === null ? "" : s).replace(/[_-]+/g, " ").trim();
    return t === "" ? "" : t.charAt(0).toUpperCase() + t.slice(1);
}

// The four steps the kernel offers, thriftiest first. A name this file does not know is not offered
// (a number, a vendor's extra): the panel states four steps and means them.
function eppTabs(choices) {
    var c = choices || [];
    return EPP_ORDER.filter(function (e) { return c.indexOf(e) >= 0; })
        .map(function (e) { return { id: e, label: EPP_LABEL[e] }; });
}

function eppName(id) {
    return EPP_LABEL.hasOwnProperty(id) ? EPP_LABEL[id].replace("\n", " ") : _title(id);
}

// The kernel's governors, the known ones in reading order, then any other the kernel lists.
function orderedGovernors(names) {
    var n = names || [];
    return GOV_ORDER.filter(function (g) { return n.indexOf(g) >= 0; })
        .concat(n.filter(function (g) { return GOV_ORDER.indexOf(g) < 0; }));
}

function govTabs(names) {
    return orderedGovernors(names).map(function (g) { return { id: g, label: _title(g) }; });
}

// true when the list can only be the generic governors' (passive mode): intel_pstate's own active
// mode never lists anything but powersave and performance.
function isGeneric(names) {
    var n = names || [];
    return n.some(function (g) { return GENERIC_ONLY.indexOf(g) >= 0; });
}

// One line, at most ~50 characters: a 330 px column at the figure size holds ~59 of them in Inter and
// ~51 in Audiowide (the user's dress for mockups), and a hint that elides says less than it should.
function governorHint(name, names, hasEpp) {
    var generic = isGeneric(names);
    switch (name) {
    case "performance":
        if (generic)
            return "Holds the highest speed the limits allow.";
        return hasEpp ? "Holds the top speed and locks the preference."
                      : "Always the top speed the limits allow.";
    case "powersave":
        if (generic)
            return "Holds the lowest speed the limits allow.";
        return hasEpp ? "The CPU picks its speed, guided by the preference."
                      : "Adapts the speed to the load.";
    case "schedutil":
        return "Follows the scheduler's own load figures.";
    case "ondemand":
        return "Picks a speed proportional to the measured load.";
    case "conservative":
        return "Like ondemand, but in small steps.";
    case "userspace":
        return "Does nothing itself: a program sets the speed.";
    default:
        return "";
    }
}

// The hover tip of the governor row: the thing the one-line hints cannot say.
function governorTip(names, hasEpp) {
    if (isGeneric(names))
        return "The kernel's scaling governors for this CPU.\nThe line below the choice says what it does.";
    return "intel_pstate's own two, not the generic\n"
        + "governors the names suggest. powersave lets the\n"
        + "CPU choose its speed" + (hasEpp ? ", steered by the\nenergy preference" : "")
        + "; performance holds the\ntop speed" + (hasEpp ? " and fixes the preference" : "") + ".";
}

// cardwire's modes (its own numbers: 0 Integrated, 1 Hybrid, 2 Manual, 3 Smart) in the scene's step
// order, Integrated, Smart, Hybrid -- the order the popup's zone is read in. Manual belongs to
// desktops and is never offered. `current` is kept in the list even when the daemon no longer offers
// it, so the selector always has a selected tab.
function modeTabs(cwModes, current) {
    var order = [0, 3, 1];
    var label = { 0: "Integrated", 3: "Smart", 1: "Hybrid" };
    var m = (cwModes || []).slice();
    if (typeof current === "number" && m.indexOf(current) < 0 && label.hasOwnProperty(current))
        m.push(current);
    return order.filter(function (k) { return m.indexOf(k) >= 0; })
        .map(function (k) { return { id: String(k), label: label[k] }; });
}
