.pragma library

// =============================================================================
// ReelItems.js -- what the two reels in the left island offer.
//
// [{ id, glyph, label, tint }] as IconReel wants them. `tint` names a ROLE of the bar's hue table (BarHues: "power.sleep"),
// never a colour: the table gives every option of a reel its own colour in whatever theme is on (sleep blue, power off red,
// reboot yellow, hibernate cyan, log out magenta, lock green; idle allowed blue, soft cyan, normal green, hard yellow),
// and a theme whose palette would make two of them alike gets the neighbouring slot for the second.
// The glyphs are Material Design Nerd Font codepoints (the codes mockups/power.qml used), built with
// String.fromCodePoint so no tool can mangle a private-use character in this file.
//
// WHAT EACH ONE DOES is ReelActions.qml's: the reel only emits `activated`.
// =============================================================================

function _g(n) {
    return String.fromCodePoint(n);
}

var POWER = [
    { id: "sleep", glyph: _g(0xF0904), label: "Sleep", tint: "power.sleep" },
    { id: "poweroff", glyph: _g(0xF0425), label: "Power off", tint: "power.poweroff" },
    { id: "reboot", glyph: _g(0xF0709), label: "Reboot", tint: "power.reboot" },
    { id: "hibernate", glyph: _g(0xF0717), label: "Hibernate", tint: "power.hibernate" },
    { id: "logout", glyph: _g(0xF0343), label: "Log out", tint: "power.logout" },
    { id: "lock", glyph: _g(0xF033E), label: "Lock", tint: "power.lock" }
];

// The item the power reel rests on when the shell starts unless power.jsonc names another: a right click fires the selected item, and
// Lock is the one that costs nothing. The ring is circular, so
// resting on Lock leaves the order of the list as it is (Sleep follows Lock, Log out comes before it).
var POWER_REST = "lock";

// The idle set's glyphs: sleep, a setting sun, a coffee cup, the infinity sign -- md-sleep, md-weather_sunset_down,
// md-coffee, md-infinity.
var IDLE = [
    { id: "off", glyph: _g(0xF04B2), label: "Idle allowed: dim, then sleep", tint: "idle.off", rank: 0 },
    { id: "soft", glyph: _g(0xF059B), label: "Soft: dim, never blank", tint: "idle.soft", rank: 1 },
    { id: "normal", glyph: _g(0xF0176), label: "Normal: no idle actions", tint: "idle.normal", rank: 2 },
    { id: "hard", glyph: _g(0xF06E4), label: "Hard: no sleep at all", tint: "idle.hard", rank: 3 }
];

// The power reel's items by their ids, in that order (power.jsonc "items"): an id that is none, or a second copy, is left out; Lock is
// always there, last when the list does not name it; a list that names nothing is all of them.
function powerItems(ids) {
    const out = [];
    for (let i = 0; ids && i < ids.length; i++) {
        const k = indexOf(POWER, ids[i]);
        if (k >= 0 && out.indexOf(POWER[k]) < 0)
            out.push(POWER[k]);
    }
    if (out.length === 0)
        return POWER;
    if (indexOf(out, "lock") < 0)
        out.push(POWER[indexOf(POWER, "lock")]);
    return out;
}

// The idle reel's items: the modes on offer (IdleService.offered, idle.jsonc "items"), in the ladder's order.
function idleItems(ids) {
    const out = [];
    for (let i = 0; i < IDLE.length; i++)
        if (!ids || ids.indexOf(IDLE[i].id) >= 0)
            out.push(IDLE[i]);
    return out.length > 0 ? out : IDLE;
}

function indexOf(list, id) {
    for (let i = 0; i < list.length; i++)
        if (list[i].id === id)
            return i;
    return -1;
}
