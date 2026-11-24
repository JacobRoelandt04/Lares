pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"

// =============================================================================
// PairingScreen.qml -- where a phone is made known to this computer. Two uses, one body:
//
//   the SCREEN, when no device is paired at all: "No phone paired", one muted line, the phones that are in reach and asking
//   a PAGE (`asPage`), reached from the device menu's "Pair another": the same rows under the page chrome
//
// The rows are `service.pairing`: reachable devices KDE Connect has not paired. Each is a carved row with the name, the
// verification key in figures (what the phone must show too) and its button: "Pair", or "Accept" and "Reject" when the phone
// asked first (`byPeer`). "Look again" asks KDE Connect to look (`service.refresh()`). With KDE Connect not running or not
// installed the screen says that instead -- no row can come until it does.
//
// The service is the only one that talks to KDE Connect; this screen shows `service.pairing` and `service.env`.
// =============================================================================
Item {
    id: screen

    property var service: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    property color ground: Theme.listBox
    property bool asPage: false
    // the room the screen centres in (the screen's own, below the status bar and above the home indicator)
    property real roomTop: 0
    property real roomHeight: height

    signal back

    readonly property real _innerW: screen.width - 2 * screen.style.padding
    // with no service there is nothing to say about KDE Connect: the plain "no phone" screen
    readonly property string _kdc: screen.service ? screen.service.env.kdeconnect : "running"
    readonly property var _rows: screen.service && screen._kdc === "running" ? screen.service.pairing : []
    readonly property int _shown: Math.min(screen._rows.length, screen.style.pairMaxRows)

    // as a page the chrome already says what this is: the title speaks only when KDE Connect cannot be reached
    readonly property string _title: screen._kdc === "missing" ? "KDE Connect is missing" : (screen._kdc === "down" ? "KDE Connect is not running"
        : (screen.asPage ? "" : "No phone paired"))
    readonly property string _line: screen._kdc === "missing" ? "sudo pacman -S kdeconnect"
        : (screen._kdc === "down" ? "" : (screen._rows.length > 0 ? "" : "Open KDE Connect on the phone"))

    readonly property real _headH: (screen._title !== "" ? Math.ceil(title.implicitHeight) + screen.style.pageGap / 2 : 0) + (screen._line !== "" ? Math.ceil(line.implicitHeight) : 0)
    readonly property real _rowsH: screen._shown * screen.style.pairRowHeight + Math.max(0, screen._shown - 1) * screen.style.rowGap
    readonly property real _bodyH: screen._headH + (screen._shown > 0 ? screen.style.pageGap + screen._rowsH : 0) + screen.style.pageGap + screen.style.buttonHeight
    // as a page the body starts under the chrome; as the screen it is centred in its room
    readonly property real _bodyY: screen.asPage ? header.y + header.height + screen.style.pageGap
        : Math.round(screen.roomTop + Math.max(0, screen.roomHeight - screen._bodyH) / 2)

    PageHeader {
        id: header
        visible: screen.asPage
        x: screen.style.padding
        y: 0
        width: screen._innerW
        title: "Pair another"
        fontFamily: screen.fontFamily
        style: screen.style
        onBack: screen.back()
    }

    Text {
        id: title
        x: screen.style.padding
        y: screen._bodyY
        width: screen._innerW
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: screen._title
        color: Theme.textPrimary
        font.family: screen.fontFamily
        font.pixelSize: screen.style.titleSize
        font.bold: true
    }
    Text {
        id: line
        x: screen.style.padding
        y: title.y + (screen._title !== "" ? Math.ceil(title.implicitHeight) + screen.style.pageGap / 2 : 0)
        width: screen._innerW
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: screen._line
        color: Theme.textMuted
        font.family: screen.fontFamily
        font.pixelSize: screen.style.bodySize
    }

    Column {
        id: rows
        x: screen.style.padding
        y: line.y + Math.ceil(line.implicitHeight) + screen.style.pageGap
        width: screen._innerW
        spacing: screen.style.rowGap
        visible: screen._shown > 0
        Repeater {
            model: screen._shown
            Item {
                id: row
                required property int index
                readonly property var rec: screen._rows[row.index]
                width: rows.width
                height: screen.style.pairRowHeight
                ShadowBox {
                    anchors.fill: parent
                    baseWidth: row.width
                    baseHeight: row.height
                    baseRadius: screen.style.boxRadius
                    surfaceColor: screen.ground
                    backgroundColor: Theme.panelSunk
                    bevelColor: Theme.bevel
                    shadowColor: Theme.border
                    bevelWidth: 1
                    shadowWidth: 3
                }
                Text {
                    x: screen.style.boxPadding
                    y: screen.style.boxPadding - 2
                    width: row.width - 2 * screen.style.boxPadding - keyText.implicitWidth - 8
                    elide: Text.ElideRight
                    text: row.rec ? row.rec.name : ""
                    color: Theme.textPrimary
                    font.family: screen.fontFamily
                    font.pixelSize: screen.style.bodySize
                    font.bold: true
                }
                Text {
                    id: keyText
                    x: row.width - screen.style.boxPadding - implicitWidth
                    y: screen.style.boxPadding - 1
                    text: row.rec ? row.rec.verificationKey : ""
                    color: Theme.textMuted
                    font.family: screen.fontFamily
                    font.pixelSize: screen.style.noteSize
                    font.features: ({ "tnum": 1 })
                }
                Row {
                    x: row.width - screen.style.boxPadding - width
                    y: row.height - screen.style.boxPadding + 2 - height
                    spacing: screen.style.buttonGap
                    ScreenButton {
                        visible: row.rec !== undefined && row.rec !== null && row.rec.byPeer
                        height: screen.style.smallButtonHeight
                        implicitHeight: screen.style.smallButtonHeight
                        fontFamily: screen.fontFamily
                        fontPixelSize: screen.style.noteSize + 1
                        surfaceColor: Theme.panelSunk
                        text: "Reject"
                        onClicked: {
                            if (screen.service && row.rec)
                                screen.service.reject(row.rec.key);
                        }
                    }
                    ScreenButton {
                        height: screen.style.smallButtonHeight
                        implicitHeight: screen.style.smallButtonHeight
                        fontFamily: screen.fontFamily
                        fontPixelSize: screen.style.noteSize + 1
                        surfaceColor: Theme.panelSunk
                        accent: true
                        text: row.rec && row.rec.byPeer ? "Accept" : "Pair"
                        onClicked: {
                            if (!screen.service || !row.rec)
                                return;
                            if (row.rec.byPeer)
                                screen.service.accept(row.rec.key);
                            else
                                screen.service.pair(row.rec.key);
                        }
                    }
                }
            }
        }
    }
    Text {
        id: more
        x: screen.style.padding
        y: rows.y + rows.height + 4
        width: screen._innerW
        horizontalAlignment: Text.AlignHCenter
        visible: screen._rows.length > screen._shown
        text: "and " + (screen._rows.length - screen._shown) + " more"
        color: Theme.textFaint
        font.family: screen.fontFamily
        font.pixelSize: screen.style.noteSize
    }
    ScreenButton {
        id: again
        x: Math.round((screen.width - width) / 2)
        y: (screen._shown > 0 ? rows.y + rows.height : line.y + Math.ceil(line.implicitHeight)) + screen.style.pageGap + (more.visible ? more.height + 4 : 0)
        height: screen.style.buttonHeight
        implicitHeight: screen.style.buttonHeight
        minWidth: 120
        fontFamily: screen.fontFamily
        fontPixelSize: screen.style.bodySize
        surfaceColor: screen.ground
        text: "Look again"
        onClicked: {
            if (screen.service)
                screen.service.refresh();
        }
    }
}
