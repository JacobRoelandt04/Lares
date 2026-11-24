.pragma library

// =============================================================================
// RowGeometry.js -- where the marks at an app row's right end sit, in the
// row's own coordinates, for the row that draws them (AppRow) and the grid
// that hit-tests them (LauncherGrid: one pointer layer over every row, so a
// mark is found by arithmetic -- a HoverHandler on a row would take the
// grid's hover, CLAUDE.md). One set of numbers, so the two cannot drift.
//
//   | icon  name ...  |gap| link |inset| star |inset|
//
// The star's slot is always kept (the name never re-elides when a favourite
// is toggled); the chain glyph's only on a link (the name reserves
// room for it only on links). `t` is the LauncherTune, or null for the
// defaults.
// =============================================================================

// The chain glyph is 10 px (notes' link glyph); its slot is a little wider
// so the glyph can be centred in it on whole pixels.
var LINK_SLOT = 12;

function _inset(t) {
    return t ? t.rowInset : 6;
}
function _star(t) {
    return t ? t.starSize : 12;
}
function _gap(t) {
    return t ? t.iconGap : 10;
}

// The star's slot: its left edge; it ends one row inset from the row's end.
function starX(w, t) {
    return w - _inset(t) - _star(t);
}
// The chain glyph's slot, one row inset before the star's.
function linkX(w, t) {
    return starX(w, t) - _inset(t) - LINK_SLOT;
}
// Where the name must end: an icon gap before the first mark's slot.
function nameRight(w, t, isLink) {
    return (isLink ? linkX(w, t) : starX(w, t)) - _gap(t);
}

// The hit bands, in the row's x (the whole row's height): 4 px of slack
// round the star, and the link's band ends where the star's begins, so a
// point is on one of them at most.
function onStar(lx, w, t) {
    return lx >= starX(w, t) - 4 && lx <= w - _inset(t) + 4;
}
function onLink(lx, w, t) {
    return lx >= linkX(w, t) - 4 && lx < starX(w, t) - 4;
}
