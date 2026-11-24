pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/components"

// =============================================================================
// ChoiceList.qml -- a one-of-many choice: the shell's SlotRail (a groove with a slot at each option and a ball in the chosen one)
// with the option's words beside its slot. The list asks (`chosen(key)`); the host holds the fact and moves `current`, so a refused
// write leaves the ball where it was. `options` is [{ key, label, hint? }]; a hint is a muted line under the label.
// =============================================================================
Item {
    id: list

    property PanelStyle look: null
    property var options: []
    property string current: ""
    property color ground: Theme.listBox
    property real rowHeight: 26

    signal chosen(string key)

    readonly property real _railW: rail.implicitWidth
    width: parent ? parent.width : 0
    implicitHeight: list.options.length * list.rowHeight

    SlotRail {
        id: rail
        objectName: "choiceRail"
        width: implicitWidth
        height: list.height
        ground: list.ground
        currentKey: list.current
        stops: list.options.map((o, i) => ({ key: o.key, y: (i + 0.5) * list.rowHeight, top: i * list.rowHeight, height: list.rowHeight }))
    }

    Repeater {
        model: list.options.length
        delegate: Item {
            id: opt
            required property int index
            readonly property var o: list.options[opt.index]
            y: opt.index * list.rowHeight
            width: list.width
            height: list.rowHeight
            PText {
                look: list.look
                x: list._railW + 8
                width: parent.width - x
                anchors.verticalCenter: parent.verticalCenter
                text: opt.o ? opt.o.label : ""
                elide: Text.ElideRight
                tone: opt.o && opt.o.key === list.current ? 0 : 1
            }
            MouseArea {
                objectName: "choice_" + (opt.o ? opt.o.key : "")
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: list.chosen(opt.o.key)
            }
        }
    }
}
