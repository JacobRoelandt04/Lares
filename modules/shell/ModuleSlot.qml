import QtQuick

// =============================================================================
// ModuleSlot.qml -- where one module stands in the top bar.
//
// The module is declared once, in the frame, and placed by the layout: this item takes the zone's
// row for its module (the island it belongs to in the config, or the continuous bar's), the x the
// layout gave it and the width. Moving a module to another zone, or switching between islands and
// the continuous bar, is a change of `parent` and `x` -- the module is not rebuilt. A module that is
// switched off (shell.jsonc `modules`) stands in no zone and is not shown.
// =============================================================================
Item {
    id: slot

    required property var host
    required property string moduleId

    parent: slot.host.rowFor(slot.moduleId)
    x: slot.host.xOf(slot.moduleId)
    y: 0
    width: slot.host.wOf(slot.moduleId)
    height: slot.host.topThickness
    visible: slot.host.moduleOn(slot.moduleId)

    // The part of the slot that is the button (a child of the slot): the slot itself, the clock's box in the workspaces' groove.
    property Item clickBox: slot

    // The clicks shell.jsonc `clicks` names (BarClicks): a catcher over the button, for those buttons of the mouse alone. Everything else --
    // the left click, the hover, the wheel, a drop -- goes through to the button.
    MouseArea {
        id: catcher
        readonly property bool inBox: slot.clickBox !== slot
        x: catcher.inBox ? slot.clickBox.x : 0
        y: catcher.inBox ? slot.clickBox.y : 0
        z: 10
        width: slot.clickBox.width
        height: slot.clickBox.height
        acceptedButtons: slot.host.barClicks.buttonsOf(slot.moduleId)
        visible: catcher.acceptedButtons !== Qt.NoButton
        cursorShape: undefined
        onClicked: mouse => slot.host.barClicks.click(slot.moduleId, mouse.button, catcher, mouse.x, mouse.y)
    }
}
