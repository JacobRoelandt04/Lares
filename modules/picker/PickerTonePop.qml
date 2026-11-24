pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/components"
import "data/PickerModel.js" as Model

// =============================================================================
// PickerTonePop.qml -- the skin-tone popover: six cells (no tone and the five Fitzpatrick tones) each showing `base` in that tone.
//
// A raised plate (it stands on the popup, like a button) with one carved well under the cell the pointer or the arrows are on, and
// an accent dot under the tone in force. Picking a cell is the ONE global tone (PickerService.setTone): the host writes it and
// closes the popover. It fades in and out (`style.presenceMs`, one fraction); the host places it (`x`, `y`) and puts it in its
// overlay layer, where a clipping ancestor cannot cut it.
//
//   open        shown / hidden
//   base        the data character of the emoji the popover was opened on
//   selected    the tone in force (0..5)
//   focusIdx    the cell under the pointer / the arrows
//   chosen(t)   a cell was clicked or Enter was pressed on it
// =============================================================================
Item {
    id: pop

    property bool open: false
    property string base: ""
    property var tones: []
    property int selected: 0
    property int focusIdx: 0
    property PickerStyle style: null

    signal chosen(int tone)

    readonly property real _cell: pop.style ? pop.style.toneCell : 38
    readonly property real _pad: 8
    implicitWidth: Math.round(6 * pop._cell + 2 * pop._pad)
    implicitHeight: Math.round(pop._cell + 2 * pop._pad + 6)
    width: implicitWidth
    height: implicitHeight

    property real f: pop.open ? 1 : 0
    Behavior on f {
        NumberAnimation {
            duration: pop.style ? pop.style.presenceMs : 160
            easing.type: Easing.OutCubic
        }
    }
    opacity: pop.f
    visible: pop.f > 0

    function step(d) {
        pop.focusIdx = Math.max(0, Math.min(5, pop.focusIdx + d));
    }
    function chooseFocused() {
        pop.chosen(pop.focusIdx);
    }

    ShadowBox {
        anchors.fill: parent
        baseWidth: width
        baseHeight: height
        baseRadius: 12
        raised: true
        shadowToAlpha: true
        surfaceColor: Theme.surface
        bevelColor: Theme.buttonBevel
        shadowColor: Theme.buttonShadow
        backgroundColor: Theme.buttonPlateau
        bevelWidth: 1.5
        shadowWidth: 5
    }

    Repeater {
        model: 6
        delegate: Item {
            id: cell
            required property int index
            x: Math.round(pop._pad + cell.index * pop._cell)
            y: pop._pad
            width: Math.round(pop._pad + (cell.index + 1) * pop._cell) - cell.x
            height: pop._cell

            ShadowBox {
                visible: pop.focusIdx === cell.index
                anchors.fill: parent
                anchors.margins: 2
                baseWidth: width
                baseHeight: height
                baseRadius: 9
                surfaceColor: "transparent"
                backgroundColor: Theme.panelSunk
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                bevelWidth: 1
                shadowWidth: 3
            }
            Text {
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: Model.toned(pop.base, cell.index, pop.tones)
                font.family: "Noto Color Emoji"
                font.pixelSize: pop.style ? pop.style.toneGlyph : 24
            }
            // The tone in force.
            Rectangle {
                visible: pop.selected === cell.index
                x: Math.round((cell.width - width) / 2)
                y: cell.height + 2
                width: 6
                height: 6
                radius: 3
                color: Theme.accent
            }
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: pop.focusIdx = cell.index
                onClicked: pop.chosen(cell.index)
            }
        }
    }
}
