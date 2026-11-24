.pragma library

// =============================================================================
// LevelMorph.js -- the arithmetic of a level morph, pure: a tile growing into
// the page it opens (a note, a notes group, a launcher folder) and shrinking
// back into its place, the way a phone opens an app.
//
// One clock drives all of it (MorphClock: `mt` linear, `me` its OutCubic);
// everything here is a function of `me` and the direction, so a swipe that
// scrubs the clock scrubs the whole picture with it.
//
//   fractions(dir, me)  what each layer shows on this frame:
//     recede   the page left behind: fades out over the first 60 % of an open,
//              back in over the last 60 % of a back
//     zoom     that page's scale: 6 % towards the tile as it opens
//     arrive   the page arrived at, inside the card: 30-75 % of an open, gone
//              in the first 30 % of a back (scaled with the card, so it is
//              whole from its first frame -- never cut mid-word)
//     faceF    the tile's own face on the card: out in the first 30 % of an
//              open, in over the last 30 % of a back (never with `arrive`)
//     dir other than "open"/"back" (no morph): the resting picture.
//   cardRect(tile, full, dir, me)  the card: from the tile to the full page on
//              an open, the other way on a back; `s` is the scale of the page
//              inside it (card width over the page's)
//   zoomRect(r, focus, z)          r scaled by z about `focus`
//   lerpSize(a, b, e, vertical)    a popup size on the way from a to b, lerped
//              by its EDGES along the bar and rounded: a box on half pixels
//              makes everything in it shimmer (EdgeResize.js). `shift` is the
//              offset along the bar; `vertical` for a bar on the left/right.
//
// Rects are { x, y, w, h } in whatever space the caller works in.
// =============================================================================

function clamp01(v) {
    return Math.max(0, Math.min(1, v));
}

function lerp(a, b, t) {
    return a + (b - a) * t;
}

function lerpRect(a, b, t) {
    return {
        x: lerp(a.x, b.x, t),
        y: lerp(a.y, b.y, t),
        w: lerp(a.w, b.w, t),
        h: lerp(a.h, b.h, t)
    };
}

function zoomRect(r, focus, z) {
    return {
        x: focus.x + (r.x - focus.x) * z,
        y: focus.y + (r.y - focus.y) * z,
        w: r.w * z,
        h: r.h * z
    };
}

function fractions(dir, me) {
    if (dir !== "open" && dir !== "back")
        return {
            recede: 1,
            zoom: 1,
            arrive: 1,
            faceF: 0
        };
    const open = dir === "open";
    return {
        recede: open ? 1 - clamp01(me / 0.6) : clamp01((me - 0.4) / 0.6),
        zoom: 1 + 0.06 * (open ? me : 1 - me),
        arrive: open ? clamp01((me - 0.3) / 0.45) : 1 - clamp01(me / 0.3),
        faceF: open ? 1 - clamp01(me / 0.3) : clamp01((me - 0.7) / 0.3)
    };
}

function cardRect(tile, full, dir, me) {
    const r = dir === "open" ? lerpRect(tile, full, me) : lerpRect(full, tile, me);
    r.s = r.w / Math.max(1, full.w);
    return r;
}

function lerpSize(a, b, e, vertical) {
    const al = vertical ? a.h : a.w, bl = vertical ? b.h : b.w;
    const sa = a.shift || 0, sb = b.shift || 0;
    const a0 = Math.round(lerp(sa - al / 2, sb - bl / 2, e));
    const a1 = Math.round(lerp(sa + al / 2, sb + bl / 2, e));
    const out = Math.round(lerp(vertical ? a.w : a.h, vertical ? b.w : b.h, e));
    return vertical ? {
        w: out,
        h: a1 - a0,
        shift: (a0 + a1) / 2
    } : {
        w: a1 - a0,
        h: out,
        shift: (a0 + a1) / 2
    };
}
