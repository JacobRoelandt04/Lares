pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../data/BridgeModel.js" as Model

// =============================================================================
// FilesPage.qml -- the Files page, the page that grows out of the Files tile: the phone's storage on this computer, by the
// cable (the mount most visits want) or by Wi-Fi. Two carved rows (FilesRow: state in words, the mount point as a link, ONE
// action), then, when the device's facts have them, the storage figures, and a quiet "Send files" row.
//
// The page decides nothing about availability: a row's action is there when the tool's `can.mountUsb` / `can.mountWifi` says
// the device can, and says the tool's `why` and `hint` when it cannot.
//
// The storage line is two figures in fixed slots (the widest a figure can be, right-aligned), so a free figure changing a digit
// moves nothing. Laid out once at the size it asks for; the page chrome belongs to the page.
// =============================================================================
Item {
    id: page

    property var service: null
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    property color ground: Theme.listBox

    signal back

    readonly property real _innerW: page.width - 2 * page.style.padding
    readonly property var _facts: page.dev ? page.dev.facts : null
    readonly property bool _haveStorage: page._facts !== null && page._facts.storageTotal > 0
    readonly property var _canSend: Model.canOf(page.dev, "send")

    TextMetrics {
        id: slot
        font.family: page.fontFamily
        font.pixelSize: page.style.noteSize
        font.features: ({ "tnum": 1 })
        text: "000.0 GiB"
    }

    PageHeader {
        id: header
        x: page.style.padding
        y: 0
        width: page._innerW
        title: "Files"
        fontFamily: page.fontFamily
        style: page.style
        onBack: page.back()
    }
    FilesRow {
        id: cable
        x: page.style.padding
        y: header.y + header.height + page.style.pageGap
        width: page._innerW
        which: "usb"
        title: "Cable"
        service: page.service
        dev: page.dev
        fontFamily: page.fontFamily
        style: page.style
        overlayItem: page.overlayItem
        ground: page.ground
    }
    FilesRow {
        id: wifi
        x: page.style.padding
        y: cable.y + cable.height + page.style.pageGap
        width: page._innerW
        which: "wifi"
        title: "Wi-Fi"
        service: page.service
        dev: page.dev
        fontFamily: page.fontFamily
        style: page.style
        overlayItem: page.overlayItem
        ground: page.ground
    }

    // ---- storage ----------------------------------------------------------------------------------------------------
    Item {
        id: storage
        x: page.style.padding
        y: wifi.y + wifi.height + page.style.pageGap
        width: page._innerW
        height: page.style.storageHeight
        visible: page._haveStorage
        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Storage"
            color: Theme.textMuted
            font.family: page.fontFamily
            font.pixelSize: page.style.noteSize
        }
        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0
            Text {
                width: Math.ceil(slot.width)
                horizontalAlignment: Text.AlignRight
                text: page._facts ? Model.bytesWords(page._facts.storageFree) : ""
                color: Theme.textPrimary
                font.family: page.fontFamily
                font.pixelSize: page.style.noteSize
                font.features: ({ "tnum": 1 })
            }
            Text {
                text: " free of "
                color: Theme.textMuted
                font.family: page.fontFamily
                font.pixelSize: page.style.noteSize
            }
            Text {
                width: Math.ceil(slot.width)
                horizontalAlignment: Text.AlignRight
                text: page._facts ? Model.bytesWords(page._facts.storageTotal) : ""
                color: Theme.textPrimary
                font.family: page.fontFamily
                font.pixelSize: page.style.noteSize
                font.features: ({ "tnum": 1 })
            }
        }
    }

    // ---- send ---------------------------------------------------------------------------------------------------------
    QuietButton {
        id: send
        x: page.style.padding
        y: (page._haveStorage ? storage.y + storage.height : wifi.y + wifi.height) + page.style.pageGap
        text: "Send files"
        fontFamily: page.fontFamily
        fontPixelSize: page.style.bodySize
        available: page._canSend.ok
        overlayItem: page.overlayItem
        tip: page._canSend.ok ? "" : (page._canSend.why + (page._canSend.hint !== "" ? ". " + page._canSend.hint : ""))
        onClicked: {
            if (page.service && page.dev)
                page.service.pickAndSend(page.dev.key);
        }
    }
}
