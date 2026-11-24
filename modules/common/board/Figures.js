.pragma library

// =============================================================================
// Figures.js -- the board toolkit's 7-segment figures: the display strings a scene is handed as the cell CODES the shaders read (seg7.glsl, under
// modules/common/board/shaders, says what a code is). A scene's own figures file (silicon's: the CPU's three strings, the time label, `describe`)
// builds on these. No Qt here: it runs under node.
//
// The grammar (the data layer writes it): characters `0-9`, `-`, space, `d`, `h`; a `.`
// right after a character lights THAT cell's decimal point (it takes no cell); a `:` is only in a colon display, between
// its 2nd and 3rd cell (it lights the colon). Anything else draws a blank cell. A string is right-aligned into
// its display's fixed cells (figures never jitter); one longer than its display shows `--`; no string (null, "")
// is an unlit display.
//
//   parse(str)                       { cells: [{ ch, dp }], colon }
//   pack(str, cells, hasColon)       a display's four cell codes (a 3-cell display leaves the fourth blank)
//   packText(str, cells)             a printed figure: digits and the minus only
//   code4(a) / uncode4(c)            four codes (each < 16) in ONE number, so a figure that did not change is a property that did not change
//   BLANK MINUS DP COLON             the code alphabet's constants
// =============================================================================

var BLANK = 11;          // a cell with nothing lit
var MINUS = 10;
var DP = 16;             // added to a code: the decimal point after the cell is lit
var COLON = 32;          // added to cell 1's code: the colon between cell 1 and cell 2 is lit

// the cells of `str`: [{ ch, dp }], and whether it holds a colon
function parse(str) {
    var cells = [], colon = false, s = String(str === null || str === undefined ? "" : str).toLowerCase();
    for (var i = 0; i < s.length; i++) {
        var c = s.charAt(i);
        if (c === ".") {
            if (cells.length)
                cells[cells.length - 1].dp = true;       // a point takes no cell; with nothing before it, it is nothing
        } else if (c === ":") {
            colon = true;
        } else if (c >= "0" && c <= "9") {
            cells.push({ ch: c.charCodeAt(0) - 48, dp: false });
        } else if (c === "-") {
            cells.push({ ch: MINUS, dp: false });
        } else if (c === "d") {
            cells.push({ ch: 12, dp: false });
        } else if (c === "h") {
            cells.push({ ch: 13, dp: false });
        } else {
            cells.push({ ch: BLANK, dp: false });        // a space, or anything the alphabet does not have
        }
    }
    return { cells: cells, colon: colon };
}

// a display's four cell codes (a 3-cell display leaves the fourth blank). `cells`: its digits; `hasColon`: whether it can show one
function pack(str, cells, hasColon) {
    var out = [BLANK, BLANK, BLANK, BLANK];
    var p = parse(str);
    if (!p.cells.length && !p.colon)
        return out;
    var list = p.cells, colon = p.colon && hasColon;
    if (list.length > cells) {
        // too long for its display: `--`, right-aligned, nothing else lit
        list = [{ ch: MINUS, dp: false }, { ch: MINUS, dp: false }].slice(Math.max(0, 2 - cells));
        colon = false;
    }
    var lead = cells - list.length;
    for (var i = 0; i < list.length; i++)
        out[lead + i] = list[i].ch + (list[i].dp ? DP : 0);
    if (colon)
        out[1] += COLON;
    return out;
}

// a printed figure (the condition, the cycles): digits and the minus only, no point or colon, four cells
function packText(str, cells) {
    var a = pack(str, cells, false);
    for (var i = 0; i < a.length; i++)
        a[i] = a[i] % DP;
    return a;
}

// four codes (each < 16) in ONE number, so a figure that did not change is a property that did not change (the cached board
// must not render again because the watts ticked): c0 + 16 c1 + 256 c2 + 4096 c3
function code4(a) {
    return a[0] + 16 * a[1] + 256 * a[2] + 4096 * a[3];
}
function uncode4(c) {
    return [c % 16, Math.floor(c / 16) % 16, Math.floor(c / 256) % 16, Math.floor(c / 4096) % 16];
}
