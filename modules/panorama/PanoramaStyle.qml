import QtQuick

import "../common/float"

// =============================================================================
// PanoramaStyle.qml -- every number of the Panorama popup, its side popup and the identify card: what mockups/panorama.qml's panel
// reaches and its Save writes. Layout numbers are the shell's (CLAUDE.md "Layout numbers"): padding 12, a card's radius 14, a tile's 10.
// =============================================================================
QtObject {
    id: root

    property string fontFamily: "Inter"
    property string titleFamily: "Inter"

    // ---- the popup -------------------------------------------------------------------------------------------------------------------------
    property real padding: 12
    property real gap: 12
    property real popupWidth: 460
    property real cardRadius: 14
    property real titleSize: 16
    property real bodySize: 12
    property real figureSize: 11
    property int fadeMs: 160
    property int resizeMs: 260

    // ---- the canvas ------------------------------------------------------------------------------------------------------------------------
    property real canvasHeight: 250                // the card at its lowest (a wide desk); it grows with a tall arrangement
    property real canvasMaxHeight: 420             // ... up to this (a stack of three displays)
    property real canvasPad: 14                    // between the card's edge and the layout's bounding box
    property real slackFrac: 0.08                  // room round the layout so a tile can be carried past its edge
    property real maxScale: 0.16                   // canvas px per logical px at most: a lone laptop is not drawn life size
    property real tileGap: 8                       // the visible gap between two tiles, canvas px (drawn only: the logical edges still touch)
    property int dropEaseMs: 260                   // a tile settling after the drop (and every resize of one)
    property int liftMs: 140                       // carved -> raised when picked up
    property real dragSlop: 5                      // px of travel before a press is a drag
    property real dragOpacity: 0.6                 // the carried card follows the hand, this solid
    property real outlineWidth: 2                  // the outline of the place it will take
    property real outlineOpacity: 0.9
    property real ghostOffset: 12                  // the mirror ghost's step behind the laptop's tile

    // ---- a tile ------------------------------------------------------------------------------------------------------------------------------
    property real tileRadius: 10
    property real tilePadding: 8
    property real tileShadow: 3
    property real tileBevel: 1
    property real tileLabelSize: 12
    property real tileDetailMinH: 62               // below this height only the label shows (the figures come and go as a presence fade)
    property real tileLiftShadow: 5
    property real ghostOpacity: 0.55

    // ---- the parked row (a display that is off) -------------------------------------------------------------------------------------------
    property real parkedHeight: 40
    property real chipHeight: 26
    property real chipWidth: 132
    property real chipGap: 8

    // ---- cast (a TV found by the scan waits in the parked row as a chip; docs/contracts/panorama.md section 10) ------------------------------
    property real castRowHeight: 80                // the parked row's height while a cast device is listed: ROOM for the chip's confirm step (no jump)
    property real castChipWidth: 176               // a cast chip at rest (name elided)
    property real castChipPad: 10                  // inside a chip, round its glyph and words
    property real castMarkSize: 14                 // the cast mark in a casting tile's corner and a chip's glyph, px
    property real castConfirmGap: 8                // between the confirm step's words and its button
    property real castFigureRow: 18                // a row of the detail's stream figures

    // ---- the float (the tiles' Balatro sway, one FloatClock for the popup; gentler than the theme popup's) -----------------------------
    property real floatRestHz: 20                  // ticks a second while only the slow sway moves (every tick is a frame of the whole window)
    property real floatSway: 1.4                   // px: the largest sway of a tile (the smallest is a third of it)
    property real floatRot: 0.45                   // degrees: the largest turn
    property real floatTilt: 6                     // degrees a tile leans towards the pointer
    property real floatLift: 1.03                  // the lift under the pointer
    property int floatDealMs: 420                  // a tile dealt in when the popup opens
    property int floatDealStaggerMs: 50
    property real floatDealRise: 12                // px a tile is dealt in from below
    property real faceScale: 2                     // a tile's face is held as a texture this many times the glass while the clock runs
    readonly property FloatStyle floatStyle: FloatStyle {
        moveAmpMin: root.floatSway / 3
        moveAmpMax: root.floatSway
        rotAmpMin: root.floatRot / 2
        rotAmpMax: root.floatRot
        tiltMax: root.floatTilt
        liftScale: root.floatLift
        dealMs: root.floatDealMs
        dealStaggerMs: root.floatDealStaggerMs
        dealRise: root.floatDealRise
        dealTurn: 2
    }

    // ---- hints -------------------------------------------------------------------------------------------------------------------------------
    property real hintStripe: 4
    property real hintGap: 8
    property real hintPad: 12
    property real commandHeight: 26

    // ---- the apply bar -----------------------------------------------------------------------------------------------------------------------
    property real buttonHeight: 28

    // ---- the side popup ------------------------------------------------------------------------------------------------------------------------
    property real sideWidth: 360
    property real sideRow: 24                      // a toggle's row
    property real sideGroupGap: 12                 // between two blocks
    property real captionGap: 6                    // a caption over its control
    property real segHeight: 28                    // a segmented choice, a dropdown's button
    property real segMaxTabs: 5                    // more options than this and a choice is a dropdown
    property real menuRow: 26                      // a dropdown menu's row
    property real menuMaxRows: 10                  // ... and how many it shows (the largest first)
    property real chipGapSide: 8                   // between the workspace chips

    // ---- the identify card -----------------------------------------------------------------------------------------------------------------------
    property real identifyRing: 5
    property real identifyCardW: 260
    property real identifyCardH: 92
    property real identifyNameSize: 16
}
