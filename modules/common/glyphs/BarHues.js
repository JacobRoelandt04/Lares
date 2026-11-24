.pragma library

// =============================================================================
// BarHues.js -- which terminal colour each bar glyph wears, and the arithmetic that picks it in whatever theme is on.
//
// THE TABLE names a hue FAMILY per role, by what the glyph means (the sky is cyan, Bluetooth is blue, the bell is brass), never a
// colour: the colour is the theme's own terminal palette (Theme.ansi*, the kitty colours both seed themes carry, eight hues in two
// shades). A family is two slots, `ansiX` and `ansiBrightX`, and which is tried first depends on the role:
//   an ON colour or a reel option   the one that READS BETTER AS A COLOUR ON THE BAR: the larger of min(contrast on the surface / 3,
//                                   distance from the muted ink / 22) -- legible, and never mistaken for the muted ink an off glyph
//                                   wears (gruvbox's dark half: the saturated normal blue, not the grey-green bright one, which
//                                   beside the beige muted ink read as off)
//   a HOVER                         the one with more contrast on the surface: the pointer LIGHTS a glyph (in a dark theme the
//                                   brighter shade, in kitty's light palettes the "bright" slot, which they make the darker)
//
// A ROLE MAY NOT LAND ON A COLOUR IT MUST BE TOLD FROM (`reserve`): a hover is never one of its own glyph's state colours (the
// update's levels, the bell's unread colours, the LLM's "generating"), never the warn or the error colour (a pointer must not read
// as an alarm), and an on-colour of a pair is never its partner's. A candidate within `T_RESERVE` (CIEDE2000) of any of them is
// passed over for the next: the family's other shade, then the next family on the role's list. That is the "neighbour slot"
// when a theme duplicates a value (eva light's ansiBlue IS its accent, everbox's cyan IS its accent and its multilib colour): no
// theme is special-cased, the arithmetic finds the clash. A candidate whose contrast against the surface is under
// `MIN_CONTRAST` is passed over too. When nothing qualifies, the candidate farthest from what it must avoid wins.
//
// "@key" in a reserve is an earlier role's answer (the order of the table is the order of resolution); `group` reserves every
// earlier member of the same group (a reel's options, each distinct from the others).
//
// `resolve(pal)` takes the palette as { token: [r, g, b] (0..1) } and answers { role: token name }. It is pure: the singleton
// (BarHues.qml) reads the theme's tokens and holds the answer; tools/dev/bar_hues_table.sh runs the same function in node on
// every theme on disk and prints the table (`resolveVerbose`: the roles that found no qualifying slot, and how close each came).
// =============================================================================

var FAMILIES = ["red", "yellow", "green", "cyan", "blue", "magenta"];

// Differences in CIEDE2000 units: 2.3 is a just-noticeable difference, ~10 is "a different shade", 15+ "a different colour".
var T_RESERVE = 15;
var T_GROUP = 12;
// WCAG contrast against the surface below which a slot is not used while another qualifies (the themes' own status colours
// go down to 1.96: eva light's multilib cyan).
var MIN_CONTRAST = 1.5;

// Every role keeps off the warn and the error colour and off the muted ink (the rest and the off state of every glyph).
var GLOBAL = ["warn", "error", "textMuted"];
var W_CONTRAST = 3;
var W_INK = 22;

var TABLE = [
    // ---- the left island ----
    { role: "theme.hover", prefs: ["yellow", "magenta"], reserve: GLOBAL.concat(["accent"]) },          // the swatch (no hue of its own: the island's free one)
    { role: "notes.hover", prefs: ["cyan", "blue"], reserve: GLOBAL },
    { role: "llm.on", prefs: ["magenta", "cyan"], reserve: GLOBAL.concat(["accent"]) },                // a model is loaded
    { role: "llm.hover", prefs: ["blue", "cyan"], reserve: GLOBAL.concat(["accent", "@llm.on"]) },
    // ---- the centre island ----
    { role: "weather.hover", prefs: ["cyan", "blue"], reserve: GLOBAL },                                // the sky
    { role: "stocks.hover", prefs: ["yellow", "magenta"], reserve: GLOBAL.concat(["stockGain", "stockLoss", "accent"]) },  // gold
    // ---- the right island ----
    { role: "player.on", prefs: ["magenta", "blue"], reserve: GLOBAL },                                 // playing
    { role: "player.hover", prefs: ["cyan", "blue"], reserve: GLOBAL.concat(["@player.on"]) },
    { role: "speaker.on", prefs: ["green", "cyan"], reserve: GLOBAL },                                  // the audio pair: neighbours
    { role: "mic.on", prefs: ["yellow", "green"], reserve: GLOBAL.concat(["@speaker.on"]) },
    { role: "audio.hover", prefs: ["blue", "magenta"], reserve: GLOBAL.concat(["@speaker.on", "@mic.on"]) },
    { role: "wifi.on", prefs: ["cyan", "blue"], reserve: GLOBAL },                                      // the network pair: neighbours
    { role: "bt.on", prefs: ["blue", "cyan"], reserve: GLOBAL.concat(["@wifi.on"]) },
    { role: "net.hover", prefs: ["yellow", "magenta"], reserve: GLOBAL.concat(["@wifi.on", "@bt.on"]) },
    { role: "bridge.hover", prefs: ["magenta", "yellow"], reserve: GLOBAL.concat(["accent", "warn"]) },                          // the pointer on the bridge (its other inks: faint, plain, the warn hue of a pairing request)
    { role: "panorama.on", prefs: ["cyan", "blue"], reserve: GLOBAL.concat(["accent"]) },                // the displays mirror (the muted ink is every other state)
    { role: "panorama.hover", prefs: ["yellow", "green"], reserve: GLOBAL.concat(["accent", "@panorama.on"]) },
    { role: "update.hover", prefs: ["magenta", "cyan"], reserve: GLOBAL.concat(["accent", "ok"]) },    // never a level's colour
    { role: "bell.hover", prefs: ["yellow", "magenta"], reserve: GLOBAL.concat(["accent", "catMultilib"]) },  // brass; never unread's
    // ---- the reels: every option its own colour (ReelItems.js names these roles) ----
    { role: "power.sleep", prefs: ["blue"], group: "power" },
    { role: "power.poweroff", prefs: ["red"], group: "power" },
    { role: "power.reboot", prefs: ["yellow"], group: "power" },
    { role: "power.hibernate", prefs: ["cyan"], group: "power" },
    { role: "power.logout", prefs: ["magenta"], group: "power" },
    { role: "power.lock", prefs: ["green"], group: "power" },
    { role: "idle.off", prefs: ["blue"], group: "idle" },
    { role: "idle.soft", prefs: ["cyan"], group: "idle" },
    { role: "idle.normal", prefs: ["green"], group: "idle" },
    { role: "idle.hard", prefs: ["yellow"], group: "idle" },
    // ---- aerial's dome: a hue per Wi-Fi band, distinct from each other, from Bluetooth's and from the muted ink (the user's words: no new theme token) ----
    { role: "aerial.band24", prefs: ["green", "yellow"], group: "aerial", reserve: GLOBAL.concat(["@bt.on"]) },
    { role: "aerial.band5", prefs: ["cyan", "blue"], group: "aerial", reserve: GLOBAL.concat(["@bt.on"]) },
    { role: "aerial.band6", prefs: ["magenta", "red"], group: "aerial", reserve: GLOBAL.concat(["@bt.on"]) }
];

// aerial globe
TABLE.push({ role: "aerial.globe", prefs: ["cyan", "blue"], reserve: GLOBAL });             // the VPN globe, its lights and the tunnel: a hologram, so the sky's family

// Every token a resolution reads: the twelve hue slots, the surface and every token a reserve names.
function tokens() {
    const out = ["surface", "textMuted"];
    for (let i = 0; i < FAMILIES.length; i++) {
        const F = FAMILIES[i].charAt(0).toUpperCase() + FAMILIES[i].slice(1);
        out.push("ansi" + F, "ansiBright" + F);
    }
    for (let i = 0; i < TABLE.length; i++) {
        const r = TABLE[i].reserve || [];
        for (let j = 0; j < r.length; j++)
            if (r[j].charAt(0) !== "@" && out.indexOf(r[j]) < 0)
                out.push(r[j]);
    }
    return out;
}

// ---- colour arithmetic (sRGB 0..1 in) ----------------------------------------------------------------------------------------

function _lin(c) {
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}
function luminance(rgb) {
    return 0.2126 * _lin(rgb[0]) + 0.7152 * _lin(rgb[1]) + 0.0722 * _lin(rgb[2]);
}
function contrast(a, b) {
    const la = luminance(a), lb = luminance(b);
    return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}
function lab(rgb) {
    const r = _lin(rgb[0]), g = _lin(rgb[1]), b = _lin(rgb[2]);
    const X = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047;
    const Y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
    const Z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883;
    const f = t => t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116;
    const fx = f(X), fy = f(Y), fz = f(Z);
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
}
// CIEDE2000 between two Lab triples.
function de2000(p, q) {
    const rad = Math.PI / 180;
    const L1 = p[0], a1 = p[1], b1 = p[2], L2 = q[0], a2 = q[1], b2 = q[2];
    const C1 = Math.hypot(a1, b1), C2 = Math.hypot(a2, b2), Cb = (C1 + C2) / 2;
    const G = 0.5 * (1 - Math.sqrt(Math.pow(Cb, 7) / (Math.pow(Cb, 7) + Math.pow(25, 7))));
    const a1p = (1 + G) * a1, a2p = (1 + G) * a2;
    const C1p = Math.hypot(a1p, b1), C2p = Math.hypot(a2p, b2);
    const h1p = ((Math.atan2(b1, a1p) / rad) + 360) % 360, h2p = ((Math.atan2(b2, a2p) / rad) + 360) % 360;
    const dLp = L2 - L1, dCp = C2p - C1p;
    let dh = h2p - h1p;
    if (C1p * C2p === 0)
        dh = 0;
    else if (dh > 180)
        dh -= 360;
    else if (dh < -180)
        dh += 360;
    const dHp = 2 * Math.sqrt(C1p * C2p) * Math.sin(dh * rad / 2);
    const Lbp = (L1 + L2) / 2, Cbp = (C1p + C2p) / 2;
    let hbp;
    if (C1p * C2p === 0)
        hbp = h1p + h2p;
    else if (Math.abs(h1p - h2p) <= 180)
        hbp = (h1p + h2p) / 2;
    else if (h1p + h2p < 360)
        hbp = (h1p + h2p + 360) / 2;
    else
        hbp = (h1p + h2p - 360) / 2;
    const T = 1 - 0.17 * Math.cos((hbp - 30) * rad) + 0.24 * Math.cos(2 * hbp * rad) + 0.32 * Math.cos((3 * hbp + 6) * rad)
        - 0.20 * Math.cos((4 * hbp - 63) * rad);
    const dth = 30 * Math.exp(-Math.pow((hbp - 275) / 25, 2));
    const RC = 2 * Math.sqrt(Math.pow(Cbp, 7) / (Math.pow(Cbp, 7) + Math.pow(25, 7)));
    const SL = 1 + 0.015 * Math.pow(Lbp - 50, 2) / Math.sqrt(20 + Math.pow(Lbp - 50, 2));
    const SC = 1 + 0.045 * Cbp, SH = 1 + 0.015 * Cbp * T;
    const RT = -Math.sin(2 * dth * rad) * RC;
    return Math.sqrt(Math.pow(dLp / SL, 2) + Math.pow(dCp / SC, 2) + Math.pow(dHp / SH, 2) + RT * (dCp / SC) * (dHp / SH));
}

// ---- the resolution -----------------------------------------------------------------------------------------------------------

function _cap(f) {
    return f.charAt(0).toUpperCase() + f.slice(1);
}

// pal: { token: [r, g, b] } with every name `tokens()` lists. Answers { role: token name }.
function resolve(pal) {
    return resolveVerbose(pal).choice;
}

// The same, with what a table wants: { choice: {role: token}, fallback: [roles that took the least bad slot],
// margin: {role: the nearest avoided colour's distance over its threshold (>= 1 qualifies)} }.
function resolveVerbose(pal) {
    const labs = {};
    const labOf = name => labs[name] || (labs[name] = lab(pal[name]));
    const out = {};
    const fallback = [];
    const margin = {};
    const groups = {};
    const ink = labOf("textMuted");
    const reads = n => Math.min(contrast(pal[n], pal.surface) / W_CONTRAST, de2000(labOf(n), ink) / W_INK);
    for (let i = 0; i < TABLE.length; i++) {
        const e = TABLE[i];
        const avoid = [];
        const res = e.reserve || [];
        for (let j = 0; j < res.length; j++) {
            const n = res[j].charAt(0) === "@" ? out[res[j].slice(1)] : res[j];
            if (n && pal[n])
                avoid.push(labOf(n));
        }
        const mates = e.group ? (groups[e.group] || (groups[e.group] = [])) : [];
        const hover = /\.hover$/.test(e.role);
        // the role's own families first, each shade by contrast; then every other family, so a group always finds a colour
        const fams = e.prefs.slice();
        if (e.group)
            for (let j = 0; j < FAMILIES.length; j++)
                if (fams.indexOf(FAMILIES[j]) < 0)
                    fams.push(FAMILIES[j]);
        const cands = [];
        for (let j = 0; j < fams.length; j++) {
            const F = _cap(fams[j]);
            const pair = ["ansi" + F, "ansiBright" + F].filter(n => !!pal[n]);
            pair.sort(hover ? (x, y) => contrast(pal[y], pal.surface) - contrast(pal[x], pal.surface) : (x, y) => reads(y) - reads(x));
            for (let k = 0; k < pair.length; k++)
                cands.push(pair[k]);
        }
        let pick = "", pickD = 0, best = "", bestD = -1;
        for (let j = 0; j < cands.length && !pick; j++) {
            const L = labOf(cands[j]);
            let d = 1e9;
            for (let k = 0; k < avoid.length; k++)
                d = Math.min(d, de2000(L, avoid[k]) / T_RESERVE);
            for (let k = 0; k < mates.length; k++)
                d = Math.min(d, de2000(L, labOf(mates[k])) / T_GROUP);
            if (d >= 1 && contrast(pal[cands[j]], pal.surface) >= MIN_CONTRAST) {
                pick = cands[j];
                pickD = d;
            } else if (d > bestD) {
                bestD = d;
                best = cands[j];
            }
        }
        out[e.role] = pick || best;
        margin[e.role] = pick ? pickD : bestD;
        if (!pick)
            fallback.push(e.role);
        if (e.group)
            mates.push(out[e.role]);
    }
    return { choice: out, fallback: fallback, margin: margin };
}
