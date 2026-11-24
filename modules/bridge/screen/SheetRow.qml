pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"

// =============================================================================
// SheetRow.qml -- one line of the device sheet: a small-caps label on the left, a figure on the right, in the theme's inks
// (handed in by DeviceSheet).
//
//   label, value     the words; a row whose `shown` is false takes no room and draws nothing
//   shown            the fact exists. Absent facts are left out, never drawn as a dash
//   gauge            0..1, or -1 for none: a thin gauge under the row (the storage)
//   labelInk, valueInk, gaugeInk, gaugeFill     the inks
//
// The height is a GEOMETRY, not only a visibility: a Column hears a size change from a child under a hidden ancestor, and
// hears nothing from a `visible` that flips there.
// =============================================================================
Item {
    id: row

    property string label: ""
    property string value: ""
    property bool shown: true
    property real gauge: -1
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property color labelInk: Theme.textMuted
    property color valueInk: Theme.textPrimary
    property color gaugeInk: Theme.border
    property color gaugeFill: Theme.textMuted

    readonly property real _line: Math.ceil(row.style.backFigureSize + 5)
    readonly property real _gaugeRoom: row.gauge >= 0 ? row.style.backGaugeHeight + 4 : 0

    visible: row.shown
    width: parent ? parent.width : 0
    height: row.shown ? row._line + row._gaugeRoom : 0

    Text {
        id: labelText
        anchors.verticalCenter: valueText.verticalCenter
        text: row.label
        color: row.labelInk
        font.family: row.fontFamily
        font.pixelSize: row.style.backLabelSize
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.6
    }
    Text {
        id: valueText
        x: labelText.implicitWidth + 8
        y: Math.round((row._line - implicitHeight) / 2)
        width: row.width - x
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        text: row.value
        color: row.valueInk
        font.family: row.fontFamily
        font.pixelSize: row.style.backFigureSize
        font.features: ({ "tnum": 1 })
    }
    // the gauge: a thin carved groove, filled to the share
    Rectangle {
        visible: row.gauge >= 0
        y: row._line + 2
        width: row.width
        height: row.style.backGaugeHeight
        radius: height / 2
        color: row.gaugeInk
        Rectangle {
            width: Math.max(height, Math.round(parent.width * Math.max(0, Math.min(1, row.gauge))))
            height: parent.height
            radius: height / 2
            color: row.gaugeFill
        }
    }
}
