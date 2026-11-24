import QtQuick

// =============================================================================
// BridgeStyle.qml -- every number of the phone's screen and of its back, in one object: paddings, sizes, gaps, type, and the
// durations of its motions, one per line with the reason beside it. The mockup's panel targets THIS object (one slider moves
// every reader of it) and Save writes the defaults here. A reader takes `style.<name>` and never a literal; a name read that is
// not declared here is `undefined` and draws as NaN without a word, so every read has its line below.
//
// The screen is the PhoneStage's display (about 264 x 586 px at 3.7 px per mm, its corners rounded about 3 px). The popup's
// colours are the theme's tokens.
// =============================================================================
QtObject {
    id: style

    // ---- the display ------------------------------------------------------------------------------------------------
    // Space between the display's edge and the content of every screen, px. The shell's popup padding is 12; the display's rounded glass takes 2 more.
    property real padding: 14
    // How far an asleep device's display is dimmed: the share of the way from the display's ground to the deep shadow, 0 to 1. A third reads as switched off without going black.
    property real asleepDim: 0.35
    // From the status bar's foot to where the screens and pages begin, px.
    property real pageTopGap: 8

    // ---- the status bar ---------------------------------------------------------------------------------------------
    // Space between a status bar's ends and the display's edge, px. 18 clears the corners' arcs (their radius is about 21).
    property real statusInset: 18
    // From the display's top edge to the status bar, px.
    property real statusTop: 8
    // The status bar's height, px: a line of 11 px type with room above and below.
    property real statusHeight: 22
    // Space between the parts of the right-hand group (link, bolt, percent, battery) and between the cell bars and their type, px.
    property real statusGap: 6
    // The status bar's type, px. 11 is the shell's figure size.
    property real statusSize: 11

    // ---- the cell bars ----------------------------------------------------------------------------------------------
    // How many bars; the tool's strength (0 to 4) is spread over them. Five is a phone's usual.
    property int cellBars: 5
    // One bar's width, px.
    property real cellBarWidth: 3
    // The gap between bars, px.
    property real cellBarGap: 2
    // The first (shortest) bar's height, px.
    property real cellBarMin: 4
    // The last (tallest) bar's height, px; the bars in between rise evenly.
    property real cellBarMax: 11

    // ---- the battery ------------------------------------------------------------------------------------------------
    // The carved cell's body width, px.
    property real batteryWidth: 22
    // The cell's height, px: 11 sits between the percent's cap height and its line.
    property real batteryHeight: 11
    // How far the nub on the cell's right end reaches, px.
    property real batteryNub: 3
    // The body's corner radius, px.
    property real batteryRadius: 3
    // Space between the carved edge and the fill, px: the carve's shadow lives in it.
    property real batteryInset: 2
    // The charge at or under which the fill turns to the low colour, percent.
    property int lowPercent: 15

    // ---- the home indicator (the carved pill at the foot) ------------------------------------------------------------
    // The pill's width, px.
    property real indicatorWidth: 96
    // The pill's height, px.
    property real indicatorHeight: 5
    // From the display's bottom edge to the pill, px: clears the corners' arcs.
    property real indicatorBottom: 10
    // From the pill up to the last thing above it, px.
    property real indicatorGap: 10
    // The width of the pill's click area, px: wider than the pill, which is too thin to hit.
    property real indicatorHitWidth: 140
    // How far the click area reaches above the pill, px.
    property real indicatorHitUp: 10

    // ---- the home screen --------------------------------------------------------------------------------------------
    // Where the group of name, line and tiles stands in the room between the status bar and the indicator: 0 at the top, 0.5 in the middle (space above equals space below), 1 at the foot.
    property real homeBias: 0.5
    // The device's name, px bold. 16 is the shell's title size.
    property real nameSize: 16
    // Between the name and the one line under it, px.
    property real nameGap: 4
    // The one state line under the name, px. 12 is the shell's body size.
    property real stateSize: 12
    // The small chevron after a name and the page's back chevron, px. 12 reads at the size of the words beside it.
    property real chevronSize: 12
    // Between a chevron and its words, px.
    property real headerGap: 5
    // How far a heading's click area reaches past its words, px.
    property real headerHitSlack: 6
    // From the state line to the first row of tiles, px.
    property real headerToTiles: 22

    // ---- the tiles --------------------------------------------------------------------------------------------------
    // A tile's side, px. 68 puts three in the display's width with room between them.
    property real tileSize: 68
    // A tile's corner radius, px. 14 is the shell's container radius.
    property real tileRadius: 14
    // The glyph's size on a tile, px.
    property real tileGlyphSize: 28
    // The word under a tile, px. 11 is the shell's figure size.
    property real tileLabelSize: 11
    // From a tile to its label, px.
    property real tileLabelGap: 6
    // Between the two rows of tiles, from one label to the next tile, px.
    property real tileRowGap: 16

    // ---- the send figures -------------------------------------------------------------------------------------------
    // From the tiles to the figures line, px.
    property real statsGap: 12
    // The line's reserved height, px: the grid never moves when a send starts.
    property real statsHeight: 16
    // The figures' type, px.
    property real statsSize: 11

    // ---- the page frame ---------------------------------------------------------------------------------------------
    // Between the blocks of a page, and from a page's header to its first block, px. 12 is the shell's gap between a tab row and the first card.
    property real pageGap: 12
    // The back chevron and title strip's height, px.
    property real pageHeaderHeight: 34
    // From a page's last block to the room of the home indicator, px.
    property real pageBottomPad: 4

    // ---- the page type ----------------------------------------------------------------------------------------------
    // A page's title and a screen's heading, px bold. 16 is the shell's title size.
    property real titleSize: 16
    // Body text of pages, px. 12 is the shell's body size.
    property real bodySize: 12
    // Notes, reasons and small figures, px. 11 is the shell's figure size.
    property real noteSize: 11
    // The lines a page's muted note keeps room for, so a long reason never moves what is under it.
    property int noteLines: 3

    // ---- rows and buttons -------------------------------------------------------------------------------------------
    // A carved row's corner radius, px. 10 is the shell's compact radius.
    property real boxRadius: 10
    // Inside a carved row, px: the shell's card padding is 12.
    property real boxPadding: 12
    // A page's main button height, px.
    property real buttonHeight: 32
    // A button inside a row, px.
    property real smallButtonHeight: 28
    // Between buttons of one row, px.
    property real buttonGap: 8
    // Between rows of a list, px.
    property real rowGap: 8

    // ---- the Mirror page --------------------------------------------------------------------------------------------
    // The mode selector's height, px: four icons, each with its name as a tip (the user's review 2026-11-19: icons, taller).
    property real modeHeight: 44
    // The mode icons' size, px.
    property real modeIconSize: 20
    // One toggle row's height, px.
    property real toggleRowHeight: 38

    // ---- the Files page ---------------------------------------------------------------------------------------------
    // A mount row's height, px. It never changes: the room of its action (below) is reserved.
    property real fileRowHeight: 112
    // The room a row keeps for its button, or for the tool's reason when it cannot, px: a button or three lines of reason.
    property real fileActionHeight: 42
    // The storage line's height, px.
    property real storageHeight: 20

    // ---- the pairing screen -----------------------------------------------------------------------------------------
    // One phone row's height, px: a name and a key above, the buttons below.
    property real pairRowHeight: 74
    // How many phones are listed before "and N more".
    property int pairMaxRows: 4

    // ---- the device menu --------------------------------------------------------------------------------------------
    // The floating list's width, px: a name and how the phone is linked ("REDMAGIC 10S Pro  ·  On the cable and Wi-Fi" is the longest line to fit).
    property real menuWidth: 276

    // ---- the device sheet (the Details page; the names keep "back": it was the phone's back face once) ---------------
    // The small-caps labels, px.
    property real backLabelSize: 10
    // The sheet's figures and words, px.
    property real backFigureSize: 12
    // Between the sheet's rows, px.
    property real backRowGap: 8
    // The storage gauge's thickness, px.
    property real backGaugeHeight: 5
    // How many reasons the tool gave are shown under the controls.
    property int backHintGroups: 2
    // How many lines each of them keeps room for.
    property int backHintLines: 3

    // ---- motion -----------------------------------------------------------------------------------------------------
    // A tile growing into its page, and back, ms. 320 is the notes popup's.
    property int morphMs: 320
    // A presence fade, ms. 160 is the shell's.
    property int fadeMs: 160
    // A hover fade, ms. 120 is the shell's.
    property int hoverMs: 120
}
