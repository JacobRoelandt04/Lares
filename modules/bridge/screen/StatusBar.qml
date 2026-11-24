pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"

// =============================================================================
// StatusBar.qml -- the strip along the top of the phone's screen, as a phone draws it: the cellular bars and their type on
// the left, nothing in the middle (the camera is under the display), the link and the battery on the right.
//
//   left   five small bars, filled from `cell.strength` (0-4 spread over the five), then `cell.type` ("LTE")
//   right  the link ("USB" and / or the Wi-Fi mark), a bolt while charging, the percent as a figure in a FIXED slot (the
//          widest it can be, right-aligned, so a number gaining a digit moves nothing), then the battery: a small carved
//          cell filled to `battery.charge`
//
// A fact the device does not have is not drawn: no placeholder, no dash. The bar's ends keep clear of the display's rounded
// corners (`style.statusInset`). Everything is drawn flat in the face's own plane -- no layer, no colour animation.
// =============================================================================
Item {
    id: bar

    // the device's record (BridgeModel's <device>), or null
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property color ground: Theme.listBox

    implicitHeight: bar.style.statusHeight

    readonly property var _cell: bar.dev ? bar.dev.cell : null
    readonly property var _battery: bar.dev ? bar.dev.battery : null
    readonly property string _link: bar.dev ? bar.dev.link : "none"
    readonly property real _filled: bar._cell ? Math.round(bar._cell.strength * bar.style.cellBars / 4) : 0
    readonly property real _charge: bar._battery ? bar._battery.charge : 0
    readonly property color _fillColor: bar._battery && bar._battery.charging ? Theme.batteryCharge : (bar._charge <= bar.style.lowPercent ? Theme.batteryLow : Theme.textMuted)

    TextMetrics {
        id: percentMetrics
        font.family: bar.fontFamily
        font.pixelSize: bar.style.statusSize
        font.features: ({ "tnum": 1 })
        text: "100%"
    }

    // ---- left -----------------------------------------------------------------------------------------------------
    Row {
        id: leftGroup
        x: bar.style.statusInset
        height: bar.height
        spacing: bar.style.statusGap
        visible: bar._cell !== null

        Item {
            id: bars
            width: bar.style.cellBars * bar.style.cellBarWidth + (bar.style.cellBars - 1) * bar.style.cellBarGap
            height: leftGroup.height
            Repeater {
                model: bar.style.cellBars
                Rectangle {
                    id: stick
                    required property int index
                    readonly property real full: bar.style.cellBarMin + (bar.style.cellBarMax - bar.style.cellBarMin) * stick.index / Math.max(1, bar.style.cellBars - 1)
                    x: stick.index * (bar.style.cellBarWidth + bar.style.cellBarGap)
                    width: bar.style.cellBarWidth
                    height: Math.round(stick.full)
                    y: Math.round((bars.height + bar.style.cellBarMax) / 2) - height
                    radius: 1
                    color: stick.index < bar._filled ? Theme.textMuted : Theme.border
                }
            }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: bar._cell !== null && bar._cell.type !== ""
            text: bar._cell ? bar._cell.type : ""
            color: Theme.textMuted
            font.family: bar.fontFamily
            font.pixelSize: bar.style.statusSize
        }
    }

    // ---- right ----------------------------------------------------------------------------------------------------
    Row {
        id: rightGroup
        x: bar.width - bar.style.statusInset - width
        height: bar.height
        spacing: bar.style.statusGap

        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: bar._link === "usb" || bar._link === "both"
            text: "USB"
            color: Theme.textMuted
            font.family: bar.fontFamily
            font.pixelSize: bar.style.statusSize
            font.bold: true
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: bar._link === "wifi" || bar._link === "both"
            text: "\u{F05A9}"
            color: Theme.textMuted
            font.family: "Symbols Nerd Font"
            font.pixelSize: bar.style.statusSize + 2
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: bar._battery !== null && bar._battery.charging
            text: "\u{F0E7}"
            color: Theme.batteryCharge
            font.family: "Symbols Nerd Font"
            font.pixelSize: bar.style.statusSize + 1
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: bar._battery !== null
            width: Math.ceil(percentMetrics.width)
            horizontalAlignment: Text.AlignRight
            text: bar._battery ? bar._battery.charge + "%" : ""
            color: Theme.textMuted
            font.family: bar.fontFamily
            font.pixelSize: bar.style.statusSize
            font.features: ({ "tnum": 1 })
        }
        Item {
            id: cell
            anchors.verticalCenter: parent.verticalCenter
            visible: bar._battery !== null
            width: bar.style.batteryWidth + bar.style.batteryNub
            height: bar.style.batteryHeight
            ShadowBox {
                id: well
                width: bar.style.batteryWidth
                height: cell.height
                baseWidth: width
                baseHeight: height
                baseRadius: bar.style.batteryRadius
                surfaceColor: bar.ground
                backgroundColor: Theme.panelSunk
                bevelColor: Theme.bevel
                shadowColor: Theme.border
                bevelWidth: 0.75
                shadowWidth: 2
            }
            Rectangle {
                x: bar.style.batteryInset
                y: bar.style.batteryInset
                height: well.height - 2 * bar.style.batteryInset
                width: Math.round((well.width - 2 * bar.style.batteryInset) * bar._charge / 100)
                radius: Math.max(0, bar.style.batteryRadius - bar.style.batteryInset)
                color: bar._fillColor
            }
            Rectangle {
                x: bar.style.batteryWidth + 1
                anchors.verticalCenter: parent.verticalCenter
                width: bar.style.batteryNub - 1
                height: Math.round(cell.height / 2)
                radius: 1
                color: Theme.border
            }
        }
    }
}
