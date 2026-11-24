pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"

// =============================================================================
// FigureSlot.qml -- one figure in a slot of FIXED width, so it never jitters.
//
// DownloadStats' method for a figure that changes while it is read: the slot is as wide as the widest
// value it can take (`template`, measured at the current font) and the text is pinned to the edge that
// must hold still, so a digit more or less moves nothing outside the slot. A value wider than its
// template widens the slot for as long as it lasts and never clips.
//
// Fonts with tabular figures get them switched on (Inter has them); Audiowide has none, and its "0" is
// the widest digit, which is why a template is written in zeros: a slot that fits "00.0" fits every
// value of that shape. Sizes are whole pixels, so glyphs land on the grid.
//
//   FigureSlot { text: "38 %"; template: "000 %"; align: Text.AlignRight }
// =============================================================================
Item {
    id: root

    property string text: ""
    property string template: "0"
    property int align: Text.AlignRight
    property string fontFamily: "Inter"
    property int pixelSize: 11
    property bool bold: false
    // FadeColor: the board is a theme island (SiliconIsland), and what is drawn live inside its hole brings its own old colours to the new
    property color color: figFade.value
    property bool islandArmed: false
    FadeColor { id: figFade; token: "textPrimary"; active: root.islandArmed; place: root }
    property bool tabular: true

    readonly property var _features: root.tabular ? ({ "tnum": 1 }) : ({})

    TextMetrics {
        id: tmSlot
        font.family: root.fontFamily
        font.pixelSize: root.pixelSize
        font.bold: root.bold
        font.features: root._features
        text: root.template
    }
    TextMetrics {
        id: tmText
        font: tmSlot.font
        text: root.text
    }
    FontMetrics {
        id: fm
        font: tmSlot.font
    }

    implicitWidth: Math.max(Math.ceil(tmSlot.advanceWidth), Math.ceil(tmText.advanceWidth))
    implicitHeight: Math.ceil(fm.height)

    Text {
        x: 0
        y: 0
        width: root.width
        height: root.height
        horizontalAlignment: root.align
        verticalAlignment: Text.AlignVCenter
        text: root.text
        font: tmSlot.font
        color: root.color
    }
}
