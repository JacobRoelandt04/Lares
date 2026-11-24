.pragma library

// =============================================================================
// ShellLayout.js -- the shell's geometry, as pure functions (node-tested:
// tools/dev/shell_layout_cases.js). No Qt in here.
//
//   bars(cfg, W, H, lengths, hide, SLIM, ratio, shift)   the engine's bars of one screen, in track order, `hide` of the way to hidden,
//                                      the islands' free ends `shift` along the edge (THE OLED SHIFT, below)
//   windowReserve(edgeReserve, slim, border, k, shown)   what the shell takes from the compositor's work area, compositor px
//   lengthsFor(cfg, name, W, widths)   the three island lengths of an output (in BAR units: see THE BAR'S RATIO)
//   place(ids, widths, length, o)      where a zone's modules stand in its island
//   budget(list, slots)        the engine's body arithmetic for the layout
//   SHADOW_PRESETS, BORDER_WIDTH   the shell's edge (below): what `shadow` and `border` mean in shell.jsonc
//
// THE LAYOUT (PLAN.md "The layout"). A 40 px main bar along the top as three
// ISLANDS (topL, topC, topR: the left one from the screen's left edge, the
// centre one centred, the right one to the screen's right edge) -- or one
// continuous bar (`top`) -- and three 6 px slim bars (right, bottom, left):
// outlets for popups, as wide as Hyprland's gaps_out (6 px), taking no space of their own from the
// engine (reserve 0: windowReserve, below, gives the compositor theirs) and none of the pointer's (inputMask false). The right
// and left bars run from under the main bar to the bottom bar's face; the
// bottom bar runs the whole edge.
//
// ISLAND LENGTHS. An island's length is a number the config gives per output, keyed
// by connector name; that island is
// then FIXED and the window title fades inside its slot. A length the config leaves out
// is the width its modules need (their measured widths + padding + gaps), so a default
// fits -- and THE LEFT ISLAND FOLLOWS THE WINDOW TITLE:
// the title's slot is the width the title button asks for (`widths.windowtray`: its
// mark, the peeking icons, the title as it will stand, its end), at most `titleSlot`,
// which is the CAP. Nothing measured (a node test, a layout asked before the button
// exists), the slot is the cap. The ease is ShellFrame's one clock
// (`lengthsMs`); this file only says where the lengths are going.
//
// THE BAR'S RATIO (shell.jsonc `scale.bar`, a ratio on the global scale). The main bar and its modules live in BAR
// UNITS -- the design px the layout above is written in: 40 thick, island lengths and module widths in them, the screen `W / ratio` wide --
// and are drawn `ratio` times larger in the frame: thickness TOP x ratio, the reserve the same, every island `ratio` times its length.
// ShellFrame lays the modules out in a row scaled by the ratio (ZoneRow), so everything that is measured (`lengthsFor`, `centreAt`,
// `place`) stays in bar units and only the bars' own records (`bars`, `maskUnion`) are converted, here, to the frame's. The outlets are
// the compositor's gap (SLIM, in the FRAME's px) and never scale with it. Ratio 1 is every number unscaled, to the bit.
//
// THE OLED SHIFT (OledShift, docs/oledcare.md). Every few minutes the bars' content steps a whole device pixel through a 3 x 3 orbit, and
// an island's FREE ends -- the ends that stand in the open, not on a screen corner -- step along the edge with it (`shift`, the step's x in
// the frame's px), so the clear room between an end and the module beside it (`inkGap` of ink, THE SPACING RULE) is the same at every one
// of the nine places: the left island's right end, both ends of the centre island (which translates), the right island's left end. The
// ends on the screen's corners, the bars' thickness and so the reserve (the windows' gaps), the slim bars and the continuous bar (which has
// no free end) never move. The voids between two islands keep their width (both their ends move by the same step). 0 is every number of
// the shown layout, to the bit.
// =============================================================================

var TOP = 40;            // the main bar's thickness
var SLIM = 6;            // an outlet bar's thickness (Hyprland's gaps_out)
// What the bars toggle eases every bar to: NOTHING. A
// bar with no area is no body of the engine's (GooeyEngine.layout skips it), so a hidden shell draws no bar at all.
var HIDDEN = 0;

// THE SHELL'S EDGE (DeploymentNotes.md "Shell presentation": a shadow round everything
// that is the shell, and the waybar's borders). `shadow` is a word -- off | halo -- or an object { mode, color } (a bare object, and
// `true`, are a halo); the halo's numbers -- reach, strength, spread, softness, blend -- are ShellConfig.qml's constants (shadowReach ...),
// tuned on mockups/shell.qml's Layout tab, not keys of the file. `border` is false, true, a width in px or { width, color }. The shadow is a HALO: one band of the same thickness all round the outline (a
// gradient at the same thickness across the board; "drop" is no preset: off).
// reach: px past the surface's edge where the shadow is gone; strength: its alpha at the edge; spread: px the shape it falls from
// is grown by (shrunk below 0); softness: 0 .. 1, how much of the reach the fall takes (1 all of it; less holds it dark nearer the
// edge); blend: the px over
// which concave corners and narrow gaps round off in the shadow. A colour is a Theme token's name ("shellShadow", "accent") or
// "#rrggbb"; null is the theme's (Theme.shellShadow for the shadow, Theme.shellBorder for the ring), so dark mode has its own --
// a token keeps that, a hex does not. The shadow's alpha is `strength`, whatever the colour's own.
var SHADOW_MODES = ["off", "halo"];
// The waybar's: `box-shadow: inset 0 0 0 3px` (style-evalight.css / style-evadark.css, .modules-left/centre/right).
var BORDER_WIDTH = 3;

var ISLAND_IDS = ["topL", "topC", "topR"];
var ZONES = ["left", "centre", "right"];
// Module ids the file may still spell as they were: `network` is aerial (round 10: the module was rebuilt and renamed; a user's `zones` keeps working).
var ID_ALIAS = { network: "aerial" };
// A module id that is gone from the shell and that a user's file may still name: dropped without a word, nothing else moves (`presets` became the Presets tab of
// the panorama popup, 2026-11-21: one button, one popup). It is no key of NOMINAL, so `merge` never lets it into a zone.

// The modules of a zone, in order (PLAN.md "top-bar order": session / time / machine).
var ZONE_DEFAULTS = {
    left: ["power", "idle", "theme", "notes", "llm", "windowtray"],
    centre: ["weather", "clock", "stocks"],
    right: ["player", "volume", "aerial", "bridge", "panorama", "silicon", "update", "notifications"]
};
// THE MODULES THAT CAN BE SWITCHED OFF (shell.jsonc `modules`: `{ "silicon": false }`). Off, a module is not loaded: its button is in no zone, its
// popup and its keys do nothing and its service is not built (ShellServices.moduleOn). The clock (the workspaces, and what the lock's popup hangs
// from), the window title with the tray and the bell (the notification server) are the shell itself and are not on the list; the launcher needs no
// switch (it is a key that is not bound), the OSD, dictation and session restore have files of their own.
var MODULES = ["power", "idle", "theme", "notes", "llm", "weather", "stocks", "player", "volume", "aerial", "bridge", "panorama", "silicon", "update",
               "clipboard", "picker", "wiki", "screentime"];
// `modules` as shell.jsonc says it: { off: { id: true }, problems: [words] }. Only an exact `false` switches a module off; a value that is neither true
// nor false, or a name that is no module (or one that cannot be switched), is a problem and changes nothing. The picker pastes through the
// clipboard, so it goes with it.
function modulesOf(v) {
    const r = { off: {}, problems: [] };
    if (v === undefined || v === null)
        return r;
    if (typeof v !== "object" || v instanceof Array) {
        r.problems.push("modules must be an object of module names, each true or false");
        return r;
    }
    for (const k of Object.keys(v)) {
        const id = ID_ALIAS[k] !== undefined ? ID_ALIAS[k] : k;
        if (MODULES.indexOf(id) < 0)
            r.problems.push(NOMINAL[id] !== undefined || id === "launcher" ? "modules: \"" + k + "\" cannot be switched off" : "modules: \"" + k + "\" is no module");
        else if (v[k] === false)
            r.off[id] = true;
        else if (v[k] !== true)
            r.problems.push("modules: \"" + k + "\" must be true or false, not " + JSON.stringify(v[k]));
    }
    if (r.off.clipboard)
        r.off.picker = true;
    return r;
}

// The module that takes the island's remainder (the title's slot; the workspaces' groove).
var FLEX = { left: "windowtray", centre: "clock", right: "" };
// What the title's slot is squeezed to at the least when the screen is too small for the islands. Its CAP is `titleSlot`
// (ShellConfig.qml): a title wider than that fades out inside it.
var TITLE_MIN = 120;
// THE WORKSPACES' GROOVE: in a 40 px bar the clock's slot is FITTED to 64 x 18 px at every scale, and the
// groove is 2 * pitch + 64 + 100 * scale wide, pitch being the px between the two dots of one half (`workspacesScale`,
// `workspacesPitch`, `workspacesWidth`: ShellConfig.qml's constants).
var CLOCK_SLOT_W = 64;
var CLOCK_SLOT_H = 18;
function workspacesWidth(cfg) {
    return cfg.workspacesWidth > 0 ? cfg.workspacesWidth : Math.round(2 * cfg.workspacesPitch + CLOCK_SLOT_W + 100 * cfg.workspacesScale);
}
// At the least: pitch 32, two dots to a half.
function workspacesMin(cfg) {
    return Math.round(2 * 32 + CLOCK_SLOT_W + 100 * cfg.workspacesScale);
}
// The least a flex module is given. The title's slot is given what the title wants when that is under TITLE_MIN: the island
// follows the title, so a short title is a short slot, not one padded to 120.
function flexMin(cfg, id, widths) {
    return id === "windowtray" ? Math.min(TITLE_MIN, widthOf(id, widths, cfg)) : id === "clock" ? Math.min(workspacesMin(cfg), workspacesWidth(cfg)) : 0;
}

// The nominal width of each module (px): what the real items measure to, for a node
// test and for a layout asked before the items exist. tools/dev/shell_probe.sh compares
// them with the real ones.
// THE MARGIN A WIDENING MODULE GROWS INTO. The aerial pill (the network and Bluetooth glyphs) grows into the gap either side of it while
// the bar shows its traffic (AerialBarButton `reach`), so a module's slot -- and the island's length --
// never moves. The gap is the number that pays for it: `inkGap - TRAFFIC_REACH` stays clear (8 at 22 and a reach of 14). THE REACH is what three figures need in the shell's face: the pair draws them
// in Audiowide (ShellFrame hands it `fontFamily`), whose digits are wider than Inter's, and at 8 the "1" stands on the wifi glyph and the
// arrows on the bluetooth one -- AerialBarButton.reach must say the same number (14). Every gap in the shell is this one number.
var TRAFFIC_REACH = 14;

// THE SPACING RULE: ONE
// number, `inkGap`, is the clear space between the INK of two neighbouring modules AND between the ink of an island's end modules and the
// island's edge. Every button draws its glyph with some room of its own inside its box (a 28 px button 5-6 px each side, the power reel's
// 40 px 12, the weather's temperature slot 24 on the right, the groove nothing), so a gap between BOXES is a different gap between glyphs
// at every pair, from 12 to 42 px. INK is that room, [left, right], measured per module off a render. A module not listed has none. (The groove: its first ball's glow shows 4 px BEFORE its box
// and its last dot's carve ends 3 px inside it.) `inkGap` itself is ShellConfig.qml's constant.
var INK = {
    power: [12, 13], idle: [9, 10], theme: [5, 5], notes: [6, 6], llm: [6, 6], windowtray: [10, 10],
    weather: [7, 24], clock: [-4, 3], stocks: [6, 6],
    player: [6, 5], volume: [0, 0], aerial: [0, 0], bridge: [7, 8], panorama: [6, 6], silicon: [6, 6], update: [8, 6], notifications: [9, 9]
};
function inkOf(id) {
    return INK[id] || [0, 0];
}
// The box-to-box gap that puts the ink of `a` and `b` (neighbours, in this order) `cfg.inkGap` apart. NEGATIVE when the two boxes' own
// empty room is more than the gap (the weather's slot keeps 24 px free for a wider temperature, and the groove's box starts inside it): the
// boxes overlap by that much empty space and the ink never does.
function gapBetween(cfg, a, b) {
    return cfg.inkGap - inkOf(a)[1] - inkOf(b)[0];
}
// The room an island leaves before its first module's box and after its last's: the ink that far from the island's edge.
function padBefore(cfg, id) {
    return cfg.inkGap - inkOf(id)[0];
}
function padAfter(cfg, id) {
    return cfg.inkGap - inkOf(id)[1];
}

var NOMINAL = {
    power: 40, idle: 40, theme: 28, notes: 28, llm: 28, windowtray: 340,
    weather: 73, clock: 267, stocks: 90,
    player: 28, volume: 52, aerial: 52, bridge: 28, panorama: 28, silicon: 108, update: 32, notifications: 32
};

// THE CONSTANTS. The spacing rule's `inkGap`, the least void, the title's cap, the groove's scale, pitch and width, the joint's
// overrides and the halo's numbers are no keys of shell.jsonc: they are ShellConfig.qml's property defaults (tuned on mockups/shell.qml's
// Layout tab, written there by Save), handed in as `c` -- { inkGap, minVoid, titleSlot, workspacesScale, workspacesPitch, workspacesWidth,
// jointRounding, jointBorder, shadowReach, shadowStrength, shadowSpread, shadowSoftness, shadowBlend } -- and clamped here as the file's
// numbers were. A joint override below 0 asks Hyprland (null).
function _consts(c) {
    const k = c && typeof c === "object" ? c : {};
    const over = v => (typeof v === "number" && isFinite(v) && v >= 0 ? Math.min(64, v) : null);
    return {
        inkGap: Math.max(0, Math.min(80, _num(k.inkGap, 0))),
        // The least clear space between two islands (and between an island and a corner).
        minVoid: Math.max(0, _num(k.minVoid, 0)),
        titleSlot: Math.max(TITLE_MIN, _num(k.titleSlot, TITLE_MIN)),
        // The workspaces' groove: the scale of its drawing, the pitch of its dots, and its width (0: fitted to the two).
        workspacesScale: Math.max(0.4, Math.min(1, _num(k.workspacesScale, 0.4))),
        workspacesPitch: Math.max(24, Math.min(200, _num(k.workspacesPitch, 24))),
        workspacesWidth: _num(k.workspacesWidth, 0) >= 100 ? Math.round(Number(k.workspacesWidth)) : 0,
        // The halo (THE SHELL'S EDGE, above): reach px past the edge (0 .. 96), its alpha at the edge (0 .. 1), the px the shape it falls from
        // grows (-32 .. 32), how much of the reach the fall takes (0.05 .. 1), the px over which concave corners round off in it (0 .. 64).
        halo: { reach: _clamp(k.shadowReach, 0, 96, 0), strength: _clamp(k.shadowStrength, 0, 1, 0), spread: _clamp(k.shadowSpread, -32, 32, 0),
                softness: _clamp(k.shadowSoftness, 0.05, 1, 1), blend: _clamp(k.shadowBlend, 0, 64, null) },
        // THE JOINT (HyprJoint): the radius of the bars' joints is Hyprland's rounding + border_size + the shell's ring, asked of Hyprland; a
        // number is used instead of what Hyprland says for that one (compositor px), null asks.
        joint: { rounding: over(k.jointRounding), border: over(k.jointBorder) }
    };
}

function defaults(c) {
    const k = _consts(c);
    return {
        topMode: "islands",
        // The face of the shell's own text (the weather's figure, the title; handed to the modules that take one).
        font: "Audiowide",
        inkGap: k.inkGap,
        minVoid: k.minVoid,
        // "centred": the centre island is centred on the screen; "equal": the two voids are equal.
        centre: "centred",
        titleSlot: k.titleSlot,
        workspacesScale: k.workspacesScale,
        workspacesPitch: k.workspacesPitch,
        workspacesWidth: k.workspacesWidth,
        zones: { left: ZONE_DEFAULTS.left.slice(), centre: ZONE_DEFAULTS.centre.slice(), right: ZONE_DEFAULTS.right.slice() },
        // islands[output] = { left, centre, right } in px; "default" for any output not named.
        islands: {},
        // Where notes and the LLM open: a bar and where along it (0 = its start on the screen: the top of a side bar).
        outlets: { notes: { bar: "left", along: 0 }, llm: { bar: "left", along: 0 } },
        // THE SHELL'S EDGE (above): off, and a ring's width in px (0 is none).
        shadow: { mode: "off", reach: 0, strength: 0, spread: 0, softness: 1, color: null, blend: null },
        border: { width: 0, color: null },
        joint: k.joint
    };
}

function _num(v, d) {
    const n = Number(v);
    return isFinite(n) ? n : d;
}

// A number from a config value: only a number or a numeric string counts (Number(null) is 0, which would turn a
// `null` into a reach of nothing), anything else is `d`; then held to lo..hi.
function _clamp(v, lo, hi, d) {
    const n = typeof v === "number" || (typeof v === "string" && v.trim() !== "") ? Number(v) : NaN;
    return isFinite(n) ? Math.max(lo, Math.min(hi, n)) : d;
}

// A colour as shell.jsonc may say it (header of SHADOW_PRESETS): "#rgb" / "#rrggbb" / "#aarrggbb", or the name of a Theme token
// (letters and digits). Anything else is null: the theme's own.
function colourOf(v) {
    if (typeof v !== "string")
        return null;
    const t = v.trim();
    return /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(t) || /^[a-zA-Z][a-zA-Z0-9]*$/.test(t) ? t : null;
}

// `shadow` in any of its forms (header of SHADOW_PRESETS): { mode, reach, strength, spread, softness, color, blend }. A word that
// is not a preset, or a reach or strength of nothing, is off.
function shadowOf(v, halo) {
    let mode = "off", o = null;
    if (typeof v === "string")
        mode = v;
    else if (v === true)
        mode = "halo";
    else if (v && typeof v === "object" && !Array.isArray(v)) {
        o = v;
        mode = typeof v.mode === "string" ? v.mode : "halo";
    }
    if (SHADOW_MODES.indexOf(mode) < 0 || mode === "off" || !halo)
        return { mode: "off", reach: 0, strength: 0, spread: 0, softness: 1, color: null, blend: null };
    const s = { mode: mode, reach: halo.reach, strength: halo.strength, spread: halo.spread, softness: halo.softness, color: o ? colourOf(o.color) : null,
                blend: halo.blend };
    if (!(s.reach > 0) || !(s.strength > 0))
        return { mode: "off", reach: 0, strength: 0, spread: 0, softness: 1, color: null, blend: null };
    return s;
}

// `border` in any of its forms: { width, color } (0 is none; color as colourOf, null the theme's).
function borderOf(v) {
    let w = 0, c = null;
    if (v === true || v === "on")
        w = BORDER_WIDTH;
    else if (typeof v === "number")
        w = v;
    else if (v && typeof v === "object" && !Array.isArray(v)) {
        w = v.width === undefined ? BORDER_WIDTH : _clamp(v.width, 0, 12, 0);
        c = colourOf(v.color);
    }
    w = Math.max(0, Math.min(12, w));
    return { width: w > 0 ? w : 0, color: w > 0 ? c : null };
}

// A config object (parsed JSON, any shape) over the defaults, with the constants `c` (above). Never throws; anything
// that is not what it should be is the default. `off` (modulesOf: the modules that are switched off, read once as the shell starts): they stand in no zone.
function merge(inp, c, off) {
    const d = defaults(c);
    const o = inp && typeof inp === "object" && !Array.isArray(inp) ? inp : {};
    if (o.topMode === "continuous" || o.topMode === "islands")
        d.topMode = o.topMode;
    if (typeof o.font === "string" && o.font.length > 0)
        d.font = o.font;
    if (o.centre === "equal" || o.centre === "centred")
        d.centre = o.centre;
    d.shadow = shadowOf(o.shadow, _consts(c).halo);
    d.border = borderOf(o.border);
    if (o.zones && typeof o.zones === "object") {
        const seen = {};
        const zones = { left: [], centre: [], right: [] };
        for (const z of ZONES) {
            const list = Array.isArray(o.zones[z]) ? o.zones[z] : d.zones[z];
            for (const id0 of list) {
                const id = typeof id0 === "string" && ID_ALIAS[id0] !== undefined ? ID_ALIAS[id0] : id0;
                if (typeof id === "string" && NOMINAL[id] !== undefined && !seen[id]) {
                    seen[id] = true;
                    zones[z].push(id);
                }
            }
        }
        // A module the file leaves out is still in the shell: back in its own zone, at the end.
        for (const z of ZONES)
            for (const id of ZONE_DEFAULTS[z])
                if (!seen[id]) {
                    seen[id] = true;
                    zones[z].push(id);
                }
        d.zones = zones;
    }
    if (o.islands && typeof o.islands === "object" && !Array.isArray(o.islands)) {
        for (const k in o.islands) {
            const e = o.islands[k];
            if (!e || typeof e !== "object")
                continue;
            const r = {};
            for (const z of ZONES)
                if (e[z] !== undefined && isFinite(Number(e[z])) && Number(e[z]) > 0)
                    r[z] = Math.round(Number(e[z]));
            d.islands[k] = r;
        }
    }
    if (o.outlets && typeof o.outlets === "object") {
        for (const k of ["notes", "llm"]) {
            const e = o.outlets[k];
            if (e && typeof e === "object" && typeof e.bar === "string")
                d.outlets[k] = { bar: e.bar, along: Math.max(0, Math.min(1, _num(e.along, 0))) };
        }
    }
    if (off)
        for (const z of ZONES)
            d.zones[z] = d.zones[z].filter(id => off[id] !== true);
    return d;
}

// The workspaces ({ id, screen }) of one screen, and of the always shown ids the ones that are on no other screen.
function workspacesOn(list, screen) {
    return list.filter(w => w.screen === screen);
}
function workspacesKept(ids, list, screen) {
    return ids.filter(id => !list.some(w => w.id === id && w.screen !== "" && w.screen !== screen));
}

// Which of the outputs `names` get the bars (shell.jsonc bars.outputs): "all", "internal" (a laptop's own panel), or a list of names, "!" before
// one leaving it out (a list of nothing but those is all the others). None of them there: all of them.
function barOutputs(names, want) {
    let out = names;
    if (want === "internal") {
        out = names.filter(n => /^(eDP|LVDS|DSI)-/.test(n));
    } else if (want !== null && typeof want === "object" && want.length !== undefined) {
        const no = want.filter(w => w.charAt(0) === "!").map(w => w.substring(1));
        const yes = want.filter(w => w.charAt(0) !== "!");
        out = names.filter(n => no.indexOf(n) < 0 && (yes.length === 0 || yes.indexOf(n) >= 0));
    }
    return out.length > 0 ? out : names;
}

// The zone a module id belongs to in this config, or "".
function zoneOf(cfg, id) {
    for (const z of ZONES)
        if (cfg.zones[z].indexOf(id) >= 0)
            return z;
    return "";
}

// The width of one module: the measured one when there is one, else the nominal.
function widthOf(id, widths, cfg) {
    if (id === "windowtray") {
        // the title's slot follows the title (the header): what the button asks for, at most the cap
        const t = widths ? Number(widths.windowtray) : NaN;
        return isFinite(t) && t > 0 ? Math.min(Math.ceil(t), cfg.titleSlot) : cfg.titleSlot;
    }
    if (id === "clock")
        return workspacesWidth(cfg);
    const w = widths ? Number(widths[id]) : NaN;
    return isFinite(w) && w > 0 ? w : NOMINAL[id];
}

// What a zone's modules need: the room before the first, their widths, the gaps between their ink, the room after the last.
function naturalLength(cfg, zone, widths) {
    const ids = cfg.zones[zone];
    if (ids.length === 0)
        return 0;
    let sum = padBefore(cfg, ids[0]) + padAfter(cfg, ids[ids.length - 1]);
    for (let i = 0; i < ids.length; i++) {
        sum += widthOf(ids[i], widths, cfg);
        if (i > 0)
            sum += gapBetween(cfg, ids[i - 1], ids[i]);
    }
    return Math.ceil(sum);
}

// How much too long a set of lengths is for a screen: > 0 is the deficit in px. Centred: the centre
// island sits in the middle, so its voids are (W - C) / 2 - left and - right and the wider side decides;
// equal: the voids are the same, whatever is left over.
function _deficit(cfg, L, W) {
    if (cfg.centre === "equal")
        return L.left + L.centre + L.right + 2 * cfg.minVoid - W;
    return L.centre + 2 * (Math.max(L.left, L.right) + cfg.minVoid) - W;
}

// The three island lengths of an output: the config's (this output's, else "default"'s), each
// missing one the natural length; then made to fit the screen -- the voids at least minVoid -- by
// taking the deficit from the flex modules first (the workspaces' groove, then the title's slot),
// and only then from all three evenly. `widths` are the modules' measured widths.
function lengthsFor(cfg, name, W, widths) {
    const own = cfg.islands[name] || {};
    const def = cfg.islands["default"] || {};
    const L = {};
    for (const z of ZONES)
        L[z] = Math.round(own[z] || def[z] || naturalLength(cfg, z, widths));
    // The least an island can be: its other modules and padding, and its flex module at its least.
    const least = z => {
        const f = FLEX[z];
        return f ? naturalLength(cfg, z, widths) - widthOf(f, widths, cfg) + flexMin(cfg, f, widths) : L[z];
    };
    let d = _deficit(cfg, L, W);
    // The centre island's groove first, then the left island's title slot (the wider side of the
    // default config, so the one that decides a centred layout).
    for (const z of ["centre", "left"]) {
        if (d <= 0)
            break;
        // Centred, the left island counts twice (its void and the mirror of it): half the deficit
        // is enough -- and it only helps while it is the wider side.
        if (z === "left" && cfg.centre === "centred" && L.left < L.right)
            continue;
        const need = z === "left" && cfg.centre === "centred" ? Math.ceil(d / 2) : d;
        L[z] -= Math.max(0, Math.min(need, L[z] - least(z)));
        d = _deficit(cfg, L, W);
    }
    if (d > 0) {
        const f = Math.max(0.2, 1 - d / (L.left + L.centre + L.right));
        for (const z of ZONES)
            L[z] = Math.floor(L[z] * f);
    }
    return L;
}

// The left edge (screen px) of the centre island and the two voids it leaves.
function centreAt(cfg, W, L) {
    if (cfg.centre === "equal") {
        const x = Math.round(L.left + (W - L.left - L.right - L.centre) / 2);
        return { x: x, voidLeft: x - L.left, voidRight: W - L.right - (x + L.centre) };
    }
    const x = Math.round((W - L.centre) / 2);
    return { x: x, voidLeft: x - L.left, voidRight: W - L.right - (x + L.centre) };
}

// THE ISLAND LENGTHS ON THEIR WAY. The lengths `t` (0 .. 1, already eased by the
// animation that drives it) of the way from `from` to `to`, whole pixels on every frame -- an island's edges stay on
// the pixel grid -- and exactly `to` at 1, exactly `from` at 0.
function lengthsAt(from, to, t) {
    const out = {};
    const k = t >= 1 ? 1 : (t > 0 ? t : 0);
    for (const z of ZONES)
        out[z] = k >= 1 ? to[z] : (k <= 0 ? from[z] : Math.round(from[z] + (to[z] - from[z]) * k));
    return out;
}

// Do two sets of island lengths say the same.
function sameLengths(a, b) {
    for (const z of ZONES)
        if (!a || !b || a[z] !== b[z])
            return false;
    return true;
}

// The input region the islands need while their lengths move: for each island (barId), the rect (screen px) that
// covers where it stands at every one of `lengthsList` and whatever `held` (a former answer of this function, or
// null) already covered, as tall as the bars at their shown thickness. Held still for the whole of a move, the
// compositor is told once at its start and once at its end instead of every frame (popups' masks do the same:
// GooeyMask.qml). A continuous top bar has no islands: {}. `lengthsList` are in bar units, the rects in the frame's
// (THE BAR'S RATIO: `ratio`, default 1), with the free ends `shift` along the edge (THE OLED SHIFT, the header; default 0).
function maskUnion(held, cfg, W, H, lengthsList, ratio = 1, shift = 0) {
    const out = {};
    if (cfg.topMode === "continuous")
        return out;
    const k = ratio > 0 ? ratio : 1;
    for (const L of lengthsList) {
        for (const b of bars(cfg, W, H, L, 0, 6, k, shift)) {
            if (b.edge !== "top")
                continue;
            const r = { x0: b.rawPos, y0: 0, x1: b.rawPos + b.rawLen, y1: TOP * k };
            const o = out[b.barId] || (held && held[b.barId]) || r;
            out[b.barId] = { x0: Math.min(o.x0, r.x0), y0: Math.min(o.y0, r.y0), x1: Math.max(o.x1, r.x1), y1: Math.max(o.y1, r.y1) };
        }
    }
    return out;
}

// A bar record, the fields a GooeyBar takes.
function _bar(barId, edge, rawPos, rawLen, thickness, reserve, inputMask) {
    return { barId: barId, edge: edge, rawPos: rawPos, rawLen: rawLen, thickness: thickness, reserve: reserve, inputMask: inputMask };
}

// THE OLED SHIFT on the three island records (bars, above): each free end `s` along the edge, the corner ends where they are. An island
// with no length is no body and stays so (a step must not make a sliver of one).
function _freeEnds(out, W, s) {
    if (!(typeof s === "number" && isFinite(s) && s !== 0))
        return;
    for (const b of out) {
        if (!(b.rawLen > 0))
            continue;
        if (b.barId === "topL") {
            b.rawLen = Math.max(0, b.rawLen + s);
        } else if (b.barId === "topC") {
            b.rawPos += s;
        } else if (b.barId === "topR") {
            b.rawPos += s;
            b.rawLen = Math.max(0, W - b.rawPos);
        }
    }
}

// A bar's thickness when the bars toggle is `hide` of the way to hidden (0 shown .. 1 hidden).
function thicknessAt(thickness, hide) {
    const k = hide > 0 ? Math.min(1, hide) : 0;
    return thickness + (HIDDEN - thickness) * k;
}

// The bars of one screen (W x H, the frame's px), in the order the engine's track wants them:
// the top edge's, then right, bottom, left. `lengths` is lengthsFor()'s answer.
// `SLIM` (the sixth parameter shadows the module's constant on purpose) is the outlet bars' thickness in the frame's px: Hyprland's
// gaps_out is 6 COMPOSITOR px, so inside a frame scaled by k it is 6 / k (ShellFrame.slim); 6 in an unscaled one.
// `ratio` (THE BAR'S RATIO, the header): `lengths` are in BAR units and come back in the frame's, times it, with the main bar's
// thickness and reserve; the outlets do not follow it. 1 (the default) is the layout of an unscaled bar.
//
// THE BARS TOGGLE (Super+F2): `hide` is how far every bar has eased to nothing (0: shown, the default; 1:
// hidden). Every bar's thickness follows it, and the side bars' SPAN follows the thickness of the bars they
// hang between -- from the top bars' current face to the bottom bar's -- so a side bar stays joined to both
// all the way down and nothing detaches or shortens while the shell goes. Spans along the top and bottom edges do not change; the reserve and the input mask are the
// frame's own rules (ShellFrame: the reserve is released at the start of a hide and restored when a show has
// finished; the input goes half-way), so the records here carry the shown ones.
//
// `shift` (THE OLED SHIFT, the header; frame px, default 0): the islands' free ends stand that far along the edge -- the left island
// longer by it, the centre island moved by it, the right island starting by it later (and shorter). An island with no length stays none.
function bars(cfg, W, H, lengths, hide, SLIM = 6, ratio = 1, shift = 0) {
    const out = [];
    const k = ratio > 0 ? ratio : 1;
    const top = thicknessAt(TOP * k, hide), slim = thicknessAt(SLIM, hide);
    if (cfg.topMode === "continuous") {
        out.push(_bar("top", "top", 0, W, top, TOP * k, true));
    } else {
        const L = lengths;
        const c = centreAt(cfg, W / k, L);
        out.push(_bar("topL", "top", 0, L.left * k, top, TOP * k, true));
        out.push(_bar("topC", "top", c.x * k, L.centre * k, top, TOP * k, true));
        out.push(_bar("topR", "top", W - L.right * k, L.right * k, top, TOP * k, true));
        _freeEnds(out, W, shift);
    }
    out.push(_bar("right", "right", top, H - top - slim, slim, 0, false));
    out.push(_bar("bottom", "bottom", 0, W, slim, 0, false));
    out.push(_bar("left", "left", top, H - top - slim, slim, 0, false));
    return out;
}

// THE ROOM THE SHELL TAKES FROM THE COMPOSITOR. The border grows the bars
// OUTWARD (a ring just outside the surface), so a bar's drawn edge is its thickness + the ring's width from the screen's edge, and the room it
// reserves must be that: the main bar's reserve + the ring on the top edge, and the outlets (not the compositor's own `gaps_out` of 6) their thickness + the ring on the other three. The windows then sit snug against the ring with Hyprland's `gaps_out` at 0
// on every side. `edgeReserve` is the engine's ({ top, right, bottom, left }, the frame's px: the main bar's, 0 when the bars are away), `slim`
// the outlets' thickness in the frame's px (6 / k), `border` the ring's width in the frame's px (the config's, not the hide's), `k` the
// frame's scale, `shown` whether the bars are up (the reserve is released at the start of a hide and restored when a show has finished,
// ShellFrame.reserveOn). Answers COMPOSITOR px, whole (an exclusive zone is an integer), rounded UP: a ring of 3.75 px must not lie under the
// window's own border.
function windowReserve(edgeReserve, slim, border, k, shown) {
    const kk = k > 0 ? k : 1;
    const w = border > 0 ? border : 0;
    const px = v => Math.ceil(v * kk - 1e-6);
    const r = edgeReserve || {};
    const out = { top: 0, right: 0, bottom: 0, left: 0 };
    if (r.top > 0)
        out.top = px(r.top + w);
    if (shown)
        for (const e of ["right", "bottom", "left"])
            out[e] = px(slim + w);
    return out;
}

// The module ids of the top bar that stand in a bar: islands -> zone's island; continuous -> "top".
function barOfZone(cfg, zone) {
    if (cfg.topMode === "continuous")
        return "top";
    return zone === "left" ? "topL" : zone === "centre" ? "topC" : "topR";
}

// Where a zone's modules stand. `ids` in order, `widths` the measured ones, `length` the island's length. Returns [{ id, x, width }]:
// the ink of the first module `inkGap` from the island's edge, `inkGap` between the ink of neighbours (gapBetween); the flex
// module takes what the others leave (never under its least); with no flex module the leftover is shared out among the gaps.
function place(ids, widths, length, o) {
    const flex = o.flex || "";
    if (ids.length === 0)
        return [];
    const cfg = o.cfg;
    const padL = padBefore(cfg, ids[0]), padR = padAfter(cfg, ids[ids.length - 1]);
    const w = ids.map(id => (id === flex ? 0 : widthOf(id, widths, cfg)));
    const gaps = ids.map((id, i) => (i > 0 ? gapBetween(cfg, ids[i - 1], id) : 0));
    const fixed = w.reduce((a, b) => a + b, 0);
    const inner = length - padL - padR - gaps.reduce((a, b) => a + b, 0);
    let flexW = 0, extra = 0;
    const fi = flex ? ids.indexOf(flex) : -1;
    if (fi >= 0) {
        flexW = Math.max(flexMin(cfg, flex, widths), inner - fixed);
        w[fi] = flexW;
    } else {
        extra = ids.length > 1 ? Math.max(0, inner - fixed) / (ids.length - 1) : 0;
    }
    const out = [];
    let x = padL;
    for (let i = 0; i < ids.length; i++) {
        x += gaps[i] + (i > 0 ? extra : 0);
        out.push({ id: ids[i], x: Math.round(x), width: Math.round(w[i]) });
        x += w[i];
    }
    return out;
}

// Does everything in a zone stand inside its island, in order, with no ink on ink? (the "islands fit their modules" check; the boxes
// may overlap by their own empty room, so the ink is what is compared)
function fits(placed, length) {
    for (const p of placed)
        if (p.x < -0.5 || p.x + p.width > length + 0.5)
            return false;
    for (let i = 1; i < placed.length; i++)
        if (placed[i].x + inkOf(placed[i].id)[0] < placed[i - 1].x + placed[i - 1].width - inkOf(placed[i - 1].id)[1] - 0.5)
            return false;
    return true;
}

// The engine's body arithmetic for a layout (E1.md): every bar with an area is a body, and so
// is each live slot -- the primary, the spare (a popup closing in place while another opens),
// three child levels, the lane, the OSD. GooeyField draws 12.
function budget(list, slots) {
    const s = slots || { primary: 1, spare: 1, children: 3, lane: 1, osd: 1 };
    const barsN = list.filter(b => b.rawLen > 0 && b.thickness > 0).length;
    const total = barsN + s.primary + s.spare + s.children + s.lane + s.osd;
    return { bars: barsN, slots: total - barsN, total: total, max: 12, fits: total <= 12 };
}

// How many input rects the layout asks of the compositor's mask: the bars that take input, plus
// the slots' rects (primary, spare, three children, lane, OSD) and the catch-all. GooeyMask has 16.
function maskRects(list, slots) {
    const s = slots || { primary: 1, spare: 1, children: 3, lane: 1, osd: 1 };
    return list.filter(b => b.inputMask !== false && b.rawLen > 0 && b.thickness > 0).length
        + s.primary + s.spare + s.children + s.lane + s.osd + 1;
}
