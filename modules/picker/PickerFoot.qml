pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/PickerModel.js" as Model

// =============================================================================
// PickerFoot.qml -- the line under the grid: the category bar, the caption, the tone button.
//
//   category bar   a TabSelector of one glyph per category (a tip names it): a click jumps the grid there, and the pill follows
//                  the section at the top of the grid. With nothing to follow (a search page) no pill stands (currentTab "").
//   caption        what the highlighted cell is: its name, and for an alt code `Alt+130 (CP437)   Alt+0233 (CP1252)`, for a Nerd icon
//                  its full name and code point. While the tray holds picks it says what Enter pastes instead (the text swaps at once,
//                  as every text does). Where the tone button is away (every tab but Emoji) the caption runs to the foot's end.
//   tone button    a raised button showing a hand in the tone in force: it opens the same popover a right-click on an emoji does.
//                  Only the Emoji tab has it (presence fades).
//
// The foot holds no state about the picker: the popup says what to show and hears what the user did.
// =============================================================================
Item {
    id: foot

    property var cats: []
    property string currentCat: ""
    property string caption: ""
    property string trayText: ""
    property int trayCount: 0
    property bool toneVisible: true
    property int tone: 0
    property var tones: []
    property string fontFamily: "Inter"
    property string catFontFamily: "Inter"
    // One category cell's width (the popup says: the Nerd tab's is narrower).
    property real catCell: foot.style ? foot.style.catCell : 32
    property PickerStyle style: null
    property Item overlayItem: null
    property color surfaceColor: Theme.surface

    signal catPicked(string id)
    signal toneClicked

    readonly property real _catW: foot.cats.length * foot.catCell
    readonly property real _toneW: 36
    readonly property real _gap: 12
    implicitHeight: foot.style ? foot.style.catHeight : 30

    TabSelector {
        id: bar
        objectName: "pickerCats"
        x: 0
        y: 0
        width: foot._catW
        height: foot.height
        trackSurfaceColor: foot.surfaceColor
        fontFamily: foot.catFontFamily
        fontPixelSize: 15
        slotPaddingAlong: 4
        visible: foot.cats.length > 0
        swipeEnabled: false
        overlayItem: foot.overlayItem
        tipSide: "above"
        tabs: foot.cats.map(c => ({ id: c.id, label: c.glyph, tip: c.label }))
        onTabChanged: id => foot.catPicked(id)
    }
    // The selector writes its own currentTab on a click, which would cut a plain binding (CLAUDE.md): a Binding element.
    Binding {
        target: bar
        property: "currentTab"
        value: foot.currentCat
    }

    Text {
        id: caption
        objectName: "pickerCaption"
        x: foot._catW + foot._gap
        width: Math.max(0, foot.width - foot._catW - foot._gap - (foot.toneVisible ? foot._gap + foot._toneW : 0))
        anchors.verticalCenter: parent.verticalCenter
        elide: Text.ElideRight
        text: foot.trayCount > 0 ? foot.trayText + "   Enter pastes " + foot.trayCount : foot.caption
        font.family: foot.fontFamily
        font.pixelSize: 12
        font.bold: foot.trayCount > 0
        color: foot.trayCount > 0 ? Theme.accent : Theme.textMuted
    }

    RaisedButton {
        id: toneBtn
        objectName: "pickerToneButton"
        x: foot.width - foot._toneW
        y: Math.round((foot.height - height) / 2)
        width: foot._toneW
        height: foot.height - 2
        minWidth: foot._toneW
        horizontalPadding: 4
        text: Model.toned("👋", foot.tone, foot.tones)
        fontFamily: "Noto Color Emoji"
        fontPixelSize: 15
        bold: false
        surfaceColor: foot.surfaceColor
        plateauColor: Theme.buttonPlateau
        plateauHoverColor: Theme.buttonPlateauHover
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        opacity: foot.toneVisible ? 1 : 0
        visible: opacity > 0
        enabled: foot.toneVisible
        Behavior on opacity {
            NumberAnimation {
                duration: foot.style ? foot.style.presenceMs : 160
                easing.type: Easing.OutCubic
            }
        }
        onClicked: foot.toneClicked()
    }
}
