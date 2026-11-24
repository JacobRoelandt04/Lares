.pragma library

// =============================================================================
// OsdPointer.js -- which monitor is the pointer on. Pure: no Qt.
//
//   logicalRect(m)        { name, x, y, width, height } in LAYOUT coordinates. `m` is an output record (FocusedScreen.outputs: x, y, width,
//                         height in PIXELS, scale, transform) or already a logical rect (no scale / transform field: taken as is). The
//                         logical size is pixels / scale, width and height swapped for the quarter turns (transform 1, 3, 5, 7)
//   monitorAt(rects, x, y) the name of the monitor whose logical rect holds the point, "" when none. Half open: a rect owns
//                         [x, x + width) x [y, y + height), so a point exactly on a shared edge belongs to the monitor that STARTS there
//                         (negative coordinates are ordinary numbers). Overlapping rects (a mirror): the first listed wins
//   parseCursor(text)     `hyprctl -j cursorpos` -> { x, y } | null
// =============================================================================

function logicalRect(m) {
    if (!m)
        return null;
    var w = Number(m.width), h = Number(m.height);
    if (m.scale !== undefined || m.transform !== undefined) {
        var sc = Number(m.scale) > 0 ? Number(m.scale) : 1;
        var t = Number(m.transform || 0);
        if (t % 2 === 1) {
            var s = w;
            w = h;
            h = s;
        }
        w = w / sc;
        h = h / sc;
    }
    return { name: String(m.name), x: Number(m.x), y: Number(m.y), width: w, height: h };
}

function monitorAt(rects, x, y) {
    if (!rects || !isFinite(x) || !isFinite(y))
        return "";
    for (var i = 0; i < rects.length; i++) {
        var r = logicalRect(rects[i]);
        if (r && r.width > 0 && r.height > 0 && x >= r.x && x < r.x + r.width && y >= r.y && y < r.y + r.height)
            return r.name;
    }
    return "";
}

function parseCursor(text) {
    try {
        var o = JSON.parse(String(text));
        if (o && isFinite(o.x) && isFinite(o.y))
            return { x: Number(o.x), y: Number(o.y) };
    } catch (e) {
    }
    return null;
}
