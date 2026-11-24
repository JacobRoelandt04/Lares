.pragma library

// =============================================================================
// WikiGlyphs.js -- the wiki module's glyph vocabulary. Pure; no colour ever
// appears here (a hue is a Theme token the delegate resolves).
//
//   markChar(name, marks)    the character of a mark: generated, edited, more,
//                            less, knew, save, next, back, installed, otd
//   familyChar(hex)          a family's `glyph` (a hex codepoint in Symbols
//                            Nerd Font, as families.json holds it) -> character
//
// MARKS mirrors families.json "marks" (the file is the source of truth; the
// table is here because a pragma-library script has no file access and a mark
// is needed before any data has loaded). `markChar(name, families.marks)` reads
// the loaded file's table instead and falls back to this one for a name the
// file lacks. `tools/wiki/check_glyphs.py` proves the font has every
// codepoint of both tables.
// =============================================================================

var FONT_FAMILY = "Symbols Nerd Font";

var MARKS = {
    generated: "f51b",
    edited:    "f040",
    more:      "f067",
    less:      "f068",
    knew:      "f00c",
    save:      "f0c7",
    next:      "f054",
    back:      "f053",
    installed: "f487",
    otd:       "f073"
};

function familyChar(hex) {
    if (typeof hex !== "string" || hex === "")
        return "";
    if (/^[0-9a-fA-F]{3,6}$/.test(hex)) {
        const cp = parseInt(hex, 16);
        return cp <= 0x10FFFF ? String.fromCodePoint(cp) : "";
    }
    return hex;
}

function markChar(name, marks) {
    const own = marks && Object.prototype.hasOwnProperty.call(marks, name) ? marks[name] : "";
    if (own !== "")
        return familyChar(own);
    return Object.prototype.hasOwnProperty.call(MARKS, name) ? familyChar(MARKS[name]) : "";
}
