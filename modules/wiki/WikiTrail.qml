pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "WikiGlyphs.js" as Glyphs

// =============================================================================
// WikiTrail.qml -- the way home from a rabbit hole: a small raised chip at the
// hero's top-left, "<  Parent title", shown only while there is a trail
// (`wanted`, from `service.canBack(tab)`). A click walks one step back.
//
// The chip is a RaisedButton (its plateau, its hover fraction, its press) with
// the words laid over its label slot: the button has no elide, and the words
// are a glyph in Symbols Nerd Font beside a title in the card's face, so the
// label stays empty and the chip is sized from measured advances. Its presence
// is ONE eased fraction: it fades in and out, and the title it shows is held
// through the fade-out (the trail is empty by then).
// =============================================================================
RaisedButton {
    id: chip

    property var service: null
    property string tab: ""
    property WikiStyle style: WikiStyle {}
    // The parent card's title, and whether there is a parent at all.
    property string parentTitle: ""
    property bool wanted: false
    property Item overlayItem: null

    readonly property bool hovered: hover.hovered

    property real presenceF: chip.wanted ? 1 : 0
    Behavior on presenceF {
        NumberAnimation {
            duration: chip.style.chipFadeMs
            easing.type: Easing.OutCubic
        }
    }
    property string _title: ""
    onParentTitleChanged: if (chip.parentTitle !== "") chip._title = chip.parentTitle
    Component.onCompleted: chip._title = chip.parentTitle

    readonly property real _textRoom: Math.max(0, chip.style.chipMaxWidth - 2 * chip.style.chipPad
                                               - Math.ceil(glyphM.advanceWidth) - chip.style.chipGap)
    readonly property real _textW: Math.min(Math.ceil(titleM.advanceWidth), chip._textRoom)

    visible: chip.presenceF > 0
    opacity: chip.presenceF
    text: ""
    minWidth: 0
    horizontalPadding: 0
    width: Math.round(2 * chip.style.chipPad + Math.ceil(glyphM.advanceWidth) + chip.style.chipGap + chip._textW)
    implicitHeight: chip.style.chipHeight
    radius: chip.style.chipRadius
    shadowWidth: chip.style.buttonShadow
    bevelWidth: chip.style.buttonBevel
    shadowToAlpha: true
    surfaceColor: Theme.listBox
    plateauColor: Theme.buttonPlateau
    plateauHoverColor: Theme.buttonPlateauHover
    bevelColor: Theme.buttonBevel
    shadowColor: Theme.buttonShadow
    enabled: chip.wanted
    onClicked: {
        if (chip.service)
            chip.service.back(chip.tab);
    }

    TextMetrics {
        id: glyphM
        font.family: Glyphs.FONT_FAMILY
        font.pixelSize: chip.style.chipTextSize
        text: Glyphs.markChar("back")
    }
    TextMetrics {
        id: titleM
        font.family: chip.fontFamily
        font.pixelSize: chip.style.chipTextSize
        text: chip._title
    }
    HoverHandler {
        id: hover
    }

    Text {
        id: glyph
        x: chip.style.chipPad
        y: Math.round((chip.height - height) / 2)
        text: Glyphs.markChar("back")
        color: Theme.textMuted
        font.family: Glyphs.FONT_FAMILY
        font.pixelSize: chip.style.chipTextSize
    }
    Text {
        id: title
        x: chip.style.chipPad + Math.ceil(glyphM.advanceWidth) + chip.style.chipGap
        y: Math.round((chip.height - height) / 2)
        width: chip._textW
        text: chip._title
        elide: Text.ElideRight
        color: Theme.textPrimary
        font.family: chip.fontFamily
        font.pixelSize: chip.style.chipTextSize
    }
}
