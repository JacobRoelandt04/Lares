pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/theme"

// =============================================================================
// DevicePage.qml -- the Details page: the device's sheet (DeviceSheet: model, Android, storage, battery, link, address, key;
// "Keep wireless ready", Unpair; what the tool says is missing) behind "Details" in the device menu. It grows out of the
// device's name, as the other pages grow out of their tiles, and goes back into it.
//
// Laid out once at the size it asks for; the page chrome belongs to the page. It decides nothing (the sheet's rule).
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
    readonly property alias sheet: deviceSheet
    // the sheet's PIN field is open (the popup asks for the keys), and Escape closes it first
    readonly property bool keysWanted: deviceSheet.editing
    function cancelEdit(): bool {
        return deviceSheet.cancelEdit();
    }

    PageHeader {
        id: header
        x: page.style.padding
        y: 0
        width: page._innerW
        title: "Details"
        fontFamily: page.fontFamily
        style: page.style
        onBack: page.back()
    }
    DeviceSheet {
        id: deviceSheet
        x: page.style.padding
        y: header.y + header.height + page.style.pageGap
        width: page._innerW
        service: page.service
        dev: page.dev
        fontFamily: page.fontFamily
        style: page.style
        overlayItem: page.overlayItem
        ground: page.ground
    }
}
