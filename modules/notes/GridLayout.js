.pragma library

// =============================================================================
// GridLayout.js -- a grid of flexible tiles, pure: the notes grid's
// geometry, shared (the launcher lays its rows out with it).
//
// Tiles flex between `minTile` and `maxTile` wide at a fixed aspect; the
// column count is the most that fit, with HYSTERESIS so a width wobbling
// around a boundary (a live resize held still, a scrollbar appearing) does not
// flip the grid back and forth: a column is added when it fits, and only
// dropped once the tiles would be `hysteresis` px under the minimum.
//
// The margins are `pad` on both sides, always, and the width between them is
// spread over the columns EXACTLY: the tile width is fractional and each
// tile's edges are rounded on their own, so every tile sits on whole pixels
// and, as the popup widens, every edge moves one way only. (Whole tile widths
// centred in the leftover would move the whole grid 1 px left and right on every
// step of a resize.) Only a single column capped at `maxTile` is centred.
// =============================================================================

function columns(width, o, prevCols) {
    var inner = width - 2 * o.pad;
    var fit = Math.max(1, Math.floor((inner + o.gap) / (o.minTile + o.gap)));
    if (prevCols > 0 && fit < prevCols) {
        var w = (inner - (prevCols - 1) * o.gap) / prevCols;
        if (w >= o.minTile - o.hysteresis)
            return prevCols;
    }
    return fit;
}

function tileWidth(width, o, cols) {
    var w = (width - 2 * o.pad - (cols - 1) * o.gap) / cols;
    return Math.floor(Math.max(40, Math.min(o.maxTile, w)));
}

function tileHeight(tileW, o) {
    return Math.round(tileW * o.aspect);
}

// The rect of display cell `i` (0 is the + tile): whole pixels.
function cell(i, g) {
    var col = i % g.cols;
    var row = Math.floor(i / g.cols);
    var x0 = Math.round(g.x0 + col * (g.tileWf + g.gap));
    var x1 = Math.round(g.x0 + col * (g.tileWf + g.gap) + g.tileWf);
    return {
        x: x0,
        y: g.pad + row * (g.tileH + g.gap),
        w: x1 - x0,
        h: g.tileH
    };
}

// Everything a frame needs from one width.
function geometry(width, o, prevCols) {
    var cols = columns(width, o, prevCols);
    var free = (width - 2 * o.pad - (cols - 1) * o.gap) / cols;
    var tileWf = Math.max(40, Math.min(o.maxTile, free));
    var used = cols * tileWf + (cols - 1) * o.gap;
    return {
        cols: cols,
        tileWf: tileWf,
        tileW: Math.round(tileWf),
        tileH: Math.round(tileWf * o.aspect),
        gap: o.gap,
        pad: o.pad,
        x0: tileWf < free ? Math.round((width - used) / 2) : o.pad
    };
}

function contentHeight(count, g) {
    var rows = Math.max(1, Math.ceil(count / g.cols));
    return 2 * g.pad + rows * g.tileH + (rows - 1) * g.gap;
}

// The display cell under a point, or -1.
function cellAt(x, y, count, g) {
    var col = Math.floor((x - g.x0 + g.gap / 2) / (g.tileW + g.gap));
    var row = Math.floor((y - g.pad + g.gap / 2) / (g.tileH + g.gap));
    if (col < 0 || col >= g.cols || row < 0)
        return -1;
    var i = row * g.cols + col;
    return i < count ? i : -1;
}
