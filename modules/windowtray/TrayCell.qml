pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "../common/scroll"

// =============================================================================
// TrayCell.qml -- one tray item in the strip: its icon, drawn as INK by
// default (the icon's shape in the shell's glyph ink -- legible in both modes
// whatever the icon theme ships: Papirus' panel icons are light-on-dark),
// and the hit area of its pitch.
//
// It performs nothing: every button and the wheel go to the owner, which
// knows what the item implements. The ink is a FRACTION eased and mixed into
// themed colours (Mix.js); the record's status picks the resting ink.
//   attention  warn     (the item asks for the user)
//   passive    faint    (the item says it is not important now)
//   active     muted
// Under the pointer, and while its label or menu is out, it goes to accent.
// =============================================================================
Item {
    id: cell

    required property var rec
    required property int index
    property var owner: null
    property var style: null
    property real renderScale: 1

    readonly property string key: cell.rec ? cell.rec.key : ""
    readonly property bool lit: !!cell.owner && cell.owner.sideOpen && cell.owner.sideItemKey === cell.key
    readonly property bool hovered: area.containsMouse

    property real hoverF: cell.hovered || cell.lit ? 1 : 0
    Behavior on hoverF {
        NumberAnimation {
            duration: cell.style ? cell.style.hoverMs : 120
            easing.type: Easing.OutCubic
        }
    }

    readonly property color restInk: !cell.rec ? Theme.textMuted
        : cell.rec.status === "attention" ? Theme.warn
        : cell.rec.status === "passive" ? Theme.textFaint : Theme.textMuted

    TrayInk {
        readonly property real s: cell.style ? cell.style.trayIconSize : 18
        x: Math.round((cell.width - s) / 2)
        y: Math.round((cell.height - s) / 2)
        width: s
        height: s
        size: s
        source: cell.rec ? cell.rec.iconSource : ""
        mode: cell.style ? cell.style.trayIconMode : "ink"
        ink: Mix.c(cell.restInk, Theme.accent, cell.hoverF)
        renderScale: cell.renderScale
    }

    WheelArea {
        id: area
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onContainsMouseChanged: {
            if (cell.owner)
                cell.owner.cellHover(cell.key, cell.index, area.containsMouse);
        }
        onClicked: mouse => {
            if (cell.owner)
                cell.owner.cellClicked(cell.key, mouse.button);
        }
        turned: wheel => {
            if (cell.owner)
                cell.owner.cellWheel(cell.key, wheel);
        }
    }
}
