.pragma library

.import "../../common/glyphs/BarHues.js" as Hues

// =============================================================================
// AnswerKinds.js -- what the answer row knows about each kind of answer, pure.
//
// GLYPHS: one Symbols Nerd Font codepoint per kind, written as an escape and named by the font's own glyph name
// (`name` is the Nerd Fonts name without its prefix, `tools/dev/launcher_answers_ui_probe.sh` checks every pair against the
// installed font's cmap and glyphnames.json, as the bar glyphs are). A kind the child invents falls back to `math`.
//
// NEAREST TOKEN: the colour kind names the theme token its swatch is nearest to, by CIEDE2000 (BarHues' own, the
// shell's one perceptual distance) over the SETTLED palette; the caller passes the palette it read on `Theme.settled`.
// =============================================================================

var GLYPHS = {
    math: { name: "fa-calculator", ch: "\uF1EC" },
    currency: { name: "fa-dollar", ch: "\uF155" },
    base: { name: "fa-hashtag", ch: "\uF292" },
    time: { name: "fa-clock_o", ch: "\uF017" },
    unit: { name: "fa-ruler", ch: "\uEE0E" },
    date: { name: "fa-calendar", ch: "\uF073" },
    zone: { name: "fa-globe", ch: "\uF0AC" },
    colour: { name: "fa-tint", ch: "\uF043" },
    percent: { name: "fa-percent", ch: "\uF295" },
    ratio: { name: "fa-balance_scale", ch: "\uF24E" },
    resolution: { name: "fa-desktop", ch: "\uF108" }
};

function glyphOf(kind) {
    return (GLYPHS[kind] || GLYPHS.math).ch;
}

function esc(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// "#rrggbb" -> [r, g, b] in 0..1, or null.
function rgbOf(hex) {
    const m = /^#([0-9a-fA-F]{2})([0-9a-fA-F]{2})([0-9a-fA-F]{2})/.exec(String(hex));
    return m ? [parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255] : null;
}

// palette: [{ name, rgb: [r, g, b] }]; the name of the nearest, with its distance.
function nearest(hex, palette) {
    const c = rgbOf(hex);
    if (!c || !palette || palette.length === 0)
        return null;
    const L = Hues.lab(c);
    let best = null, bd = 1e9;
    for (let i = 0; i < palette.length; i++) {
        const d = Hues.de2000(L, Hues.lab(palette[i].rgb));
        if (d < bd) {
            bd = d;
            best = palette[i].name;
        }
    }
    return { name: best, distance: bd };
}

// An alt's line: its label faint, then the value; a value that already starts with its label ("rgb" / "rgb(68 128 244)") needs no label.
function altText(alt, faint) {
    const l = String(alt.label || ""), v = String(alt.value);
    // A label the value already says (it starts with it, or ends with it as its unit: "1.8 m", "06:00 UTC") is left out.
    const lv = v.toLowerCase(), ll = l.toLowerCase();
    if (l === "" || lv.indexOf(ll) === 0 || lv.endsWith(" " + ll))
        return esc(v);
    return "<font color=\"" + faint + "\">" + esc(l) + "</font>  " + esc(v);
}
