pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../common/theme"
import "../../common/components"
import ".."

// =============================================================================
// HintRows.qml -- what the popup tells (PanoramaModel.diagnose, the "not set up" note): one carved row each with a
// severity stripe (info: accent, warn, error), a title, a body, a command in the terminal face with a Copy button, and an action
// button where the hint has one ("enable" on a display that is connected and off). Rows are FACTS (a Repeater on a count; the
// delegate reads its row by index).
//   hints  [{ id, severity, title, body, command, action, output }]
//   actionRequested(action, output)
// =============================================================================
Item {
    id: root

    property var hints: []
    property PanoramaStyle style: PanoramaStyle {}
    property string fontFamily: "Inter"
    property color ground: Theme.surface

    signal actionRequested(string action, string output)

    implicitWidth: 300
    implicitHeight: col.height

    Column {
        id: col
        width: root.width
        spacing: root.style.hintGap
        Repeater {
            model: root.hints.length
            delegate: Item {
                id: row
                required property int index
                readonly property var h: root.hints[row.index] ?? ({ id: "", severity: "info", title: "", body: "", command: "", action: "", output: "" })
                readonly property color stripe: row.h.severity === "error" ? Theme.error : (row.h.severity === "warn" ? Theme.warn : Theme.accent)
                readonly property real pad: root.style.hintPad
                readonly property real inner: row.width - 2 * row.pad - root.style.hintStripe - 8
                readonly property bool hasCmd: row.h.command !== ""
                readonly property bool hasAct: row.h.action !== ""
                width: col.width
                height: Math.ceil(row.pad * 2 + title.implicitHeight + body.implicitHeight + 2 + (row.hasCmd ? root.style.commandHeight + 6 : 0))

                ShadowBox {
                    anchors.fill: parent
                    baseRadius: root.style.cardRadius
                    bevelWidth: 1
                    shadowWidth: 3
                    surfaceColor: root.ground
                    backgroundColor: Theme.listBox
                    bevelColor: Theme.bevel
                    shadowColor: Theme.border
                }
                Rectangle {
                    x: row.pad
                    y: row.pad
                    width: root.style.hintStripe
                    height: parent.height - 2 * row.pad
                    radius: width / 2
                    color: row.stripe
                }
                Text {
                    id: title
                    x: row.pad + root.style.hintStripe + 8
                    y: row.pad
                    width: row.inner - (row.hasAct ? act.width + 8 : 0)
                    text: row.h.title
                    elide: Text.ElideRight
                    color: Theme.textPrimary
                    font.family: root.fontFamily
                    font.pixelSize: root.style.bodySize
                    font.bold: true
                }
                Text {
                    id: body
                    x: title.x
                    y: row.pad + title.implicitHeight + 2
                    width: row.inner
                    text: row.h.body
                    wrapMode: Text.WordWrap
                    color: Theme.textMuted
                    font.family: root.fontFamily
                    font.pixelSize: root.style.bodySize
                }
                PanoButton {
                    id: act
                    visible: row.hasAct
                    ground: Theme.listBox
                    anchors.right: parent.right
                    anchors.rightMargin: row.pad
                    y: row.pad - 4
                    height: 24
                    accent: true
                    text: row.h.action === "enable" ? "Turn on" : row.h.action
                    onClicked: root.actionRequested(row.h.action, row.h.output)
                }
                Item {
                    visible: row.hasCmd
                    x: title.x
                    y: parent.height - row.pad - root.style.commandHeight
                    width: row.inner
                    height: root.style.commandHeight
                    ShadowBox {
                        anchors.fill: parent
                        baseRadius: 8
                        bevelWidth: 1
                        shadowWidth: 2
                        surfaceColor: Theme.listBox
                        backgroundColor: Theme.panelSunk
                        bevelColor: Theme.bevel
                        shadowColor: Theme.border
                    }
                    Text {
                        x: 8
                        width: parent.width - copy.width - 20
                        anchors.verticalCenter: parent.verticalCenter
                        text: row.h.command
                        elide: Text.ElideRight
                        color: Theme.textPrimary
                        font.family: "Consolas"
                        font.bold: true
                        font.pixelSize: 12
                    }
                    PanoButton {
                        id: copy
                        ground: Theme.panelSunk
                        anchors.right: parent.right
                        anchors.rightMargin: 3
                        anchors.verticalCenter: parent.verticalCenter
                        height: 20
                        minWidth: 44
                        radius: 6
                        fontPixelSize: 11
                        shadowWidth: 3
                        text: "Copy"
                        onClicked: Quickshell.clipboardText = row.h.command
                    }
                }
            }
        }
    }
}
