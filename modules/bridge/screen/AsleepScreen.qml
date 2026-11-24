pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"
import "../../common/components"
import "../../common/components/RelTime.js" as RelTime
import "../data/BridgeModel.js" as Model

// =============================================================================
// AsleepScreen.qml -- a paired device that is not in reach (not on the cable, not on this Wi-Fi, no adb): the display is
// dimmed (the popup sets a darker ground for it), and the screen says so plainly:
//
//     <name>               a click opens the device menu, as on the home screen
//     Not in reach
//     Last seen 9 h ago    (a relative time from ONE BoundaryClock that asks only while this screen is shown)
//     [ Look again ]       asks KDE Connect to look (`service.refresh()`)
//
// A quiet hint under it carries the tool's own words when a cable is there but the device still cannot be used. When another
// phone is waiting to be paired, one quiet line says so and opens the pairing page.
// =============================================================================
Item {
    id: screen

    property var service: null
    property var dev: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    property Item overlayItem: null
    property color ground: Theme.listBox
    property real roomTop: 0
    property real roomHeight: height

    readonly property alias nameItem: heading

    signal menuRequested(Item anchor)
    signal pairRequested

    readonly property real _innerW: screen.width - 2 * screen.style.padding
    readonly property var _can: Model.canOf(screen.dev, "mirror")
    readonly property bool _cable: screen.dev !== null && screen.dev.usb !== null
    readonly property string _hint: screen._cable && !screen._can.ok ? (screen._can.why + (screen._can.hint !== "" ? ". " + screen._can.hint : "")) : ""
    readonly property int _waiting: screen.service ? screen.service.pairing.length : 0

    BoundaryClock {
        id: clock
    }
    // The wall can be ahead of a clock that has not ticked (a screen shown again): never read it bare.
    readonly property var _rel: RelTime.format(screen.dev ? screen.dev.lastSeen * 1000 : 0, Math.max(clock.now, Date.now()), { justNow: "just now", suffix: " ago" })
    on_RelChanged: clock.request(screen._rel.nextMs)
    Component.onCompleted: clock.request(screen._rel.nextMs)

    readonly property real _groupH: screen.style.nameSize + 6 + 2 * (screen.style.bodySize + 6) + screen.style.pageGap + screen.style.buttonHeight
    readonly property real _groupY: Math.round(screen.roomTop + Math.max(0, screen.roomHeight - screen._groupH) / 2)

    DeviceName {
        id: heading
        x: screen.style.padding
        y: screen._groupY
        width: screen._innerW
        name: screen.dev ? screen.dev.name : ""
        more: screen.service !== null && screen.service.count > 1
        fontFamily: screen.fontFamily
        style: screen.style
        onOpened: screen.menuRequested(heading)
    }
    Text {
        id: reach
        x: screen.style.padding
        y: heading.y + Math.ceil(heading.height) + 6
        width: screen._innerW
        horizontalAlignment: Text.AlignHCenter
        text: "Not in reach"
        color: Theme.textMuted
        font.family: screen.fontFamily
        font.pixelSize: screen.style.bodySize
    }
    Text {
        id: seen
        x: screen.style.padding
        y: reach.y + Math.ceil(reach.implicitHeight) + 6
        width: screen._innerW
        horizontalAlignment: Text.AlignHCenter
        visible: screen.dev !== null && screen.dev.lastSeen > 0
        text: "Last seen " + screen._rel.text
        color: Theme.textFaint
        font.family: screen.fontFamily
        font.pixelSize: screen.style.bodySize
    }
    ScreenButton {
        id: again
        x: Math.round((screen.width - width) / 2)
        y: seen.y + Math.ceil(seen.implicitHeight) + screen.style.pageGap
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
    Text {
        id: hint
        x: screen.style.padding
        y: again.y + again.height + screen.style.pageGap
        width: screen._innerW
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
        visible: screen._hint !== ""
        text: screen._hint
        color: Theme.textFaint
        font.family: screen.fontFamily
        font.pixelSize: screen.style.noteSize
    }
    QuietButton {
        id: waiting
        x: screen.style.padding
        y: (hint.visible ? hint.y + hint.height : again.y + again.height) + screen.style.pageGap
        width: screen._innerW
        alignment: Text.AlignHCenter
        visible: screen._waiting > 0
        text: screen._waiting === 1 ? "1 phone wants to pair" : screen._waiting + " phones want to pair"
        fontFamily: screen.fontFamily
        fontPixelSize: screen.style.noteSize
        onClicked: screen.pairRequested()
    }
}
