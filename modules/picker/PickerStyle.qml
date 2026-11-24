import QtQuick

// =============================================================================
// PickerStyle.qml -- every number of the picker, in one object.
//
// The popup owns one (the owner hands it in); its panel writes it through MockupRegistry. Sizes land on whole pixels and
// whole milliseconds. A grid tile has a PROFILE: the Emoji tab's square cells, the Symbols tab's cells (a plain symbol, an alt
// code with its caption under it), the kaomoji's wide ones and the Nerd Fonts tab's icon cells.
// =============================================================================
QtObject {
    // ---- the popup -------------------------------------------------------------------
    // Emoji columns: the popup is exactly this many cells wide (plus the box's padding and the popup's own 12).
    property int emojiCols: 12
    // The grid box's height.
    property int gridHeight: 276
    // Inside the carved box, round the grid.
    property int boxPad: 6
    property int boxRadius: 14

    // ---- the Emoji tab -------------------------------------------------------------
    property int emojiCell: 44
    property int emojiGlyph: 26
    // ---- the Symbols tab -----------------------------------------------------------
    // A symbol (math, arrows ...): the narrowest cell, so as many as fit.
    property int symbolCell: 48
    property int symbolGlyph: 22
    // An alt code: the glyph with its code(s) under it.
    property int altCellW: 64
    property int altCellH: 56
    property int altGlyph: 22
    property int altCaption: 10
    // A kaomoji: wide, one line, elided at the right.
    property int wideCellW: 258
    property int wideCellH: 34
    property int wideGlyph: 14

    // ---- the Nerd Fonts tab ----------------------------------------------------------
    // A square cell of an icon (the glyph is the installed Nerd Font's).
    property int nerdCell: 44
    property int nerdGlyph: 24
    // The category bar's cell on this tab (eleven icon sets): narrower than the other tabs' so the highlighted name has room beside it.
    property int nerdCatCell: 28

    // ---- sections and the well ----------------------------------------------------------
    // A section's header row (its label) and the air between sections.
    property int headH: 26
    property int sectionGap: 6
    // How many rows the Recent section may take.
    property int recentRows: 1
    // The Clear control at the right end of the Recent header: its plate's height (the header row holds it), and how long the Undo it
    // turns into stays on offer, draining.
    property int clearHeight: 20
    property int undoMs: 10000
    // The highlight well's corner and its inset in a cell.
    property int wellRadius: 10
    property int wellInset: 2
    // The well's glide between cells.
    property int glideMs: 140
    // Keyboard and category jumps scroll this long.
    property int scrollMs: 220
    // The fade at the grid box's ends.
    property int fadeHeight: 24

    // ---- the foot -----------------------------------------------------------------------
    // The category bar: one cell, and its height.
    property int catCell: 32
    property int catHeight: 30
    // The tray's badge on a picked tile.
    property int badgeSize: 14
    // The tone popover: one cell.
    property int toneCell: 38
    property int toneGlyph: 24

    // ---- time ---------------------------------------------------------------------------
    // Presence fades (the tray text, the empty state, the popover).
    property int presenceMs: 160
}
