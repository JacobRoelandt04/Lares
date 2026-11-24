pragma ComponentBehavior: Bound

import QtQuick

import ".."
import "../../common/components"
import "../data/BridgeModel.js" as Model

// =============================================================================
// DeviceMenu.qml -- the list of devices, a FloatingMenu in the popup's overlay (it floats over the phone, above the stage):
// every device with how it is linked ("REDMAGIC 10S Pro  On the cable"), a ball in the current one's slot, then "Details"
// (the current device's sheet) and "Pair another". A pick of a device is `service.select(key)`; the other two ask the
// screen for their page.
//
//   service         a BridgeService (null: an empty menu that only offers "Pair another")
//   overlayItem     where the menu floats
//   openAt(x, y)    in overlayItem coordinates; the rows are read once, as the menu opens (a menu is a snapshot of the moment)
//   open            the menu is up
//   pairRequested() "Pair another" was picked;   detailsRequested() "Details" was
//   handleEscape()  closes it; true when it was open
//
// The rows are FACTS (id, label, check, checked): a Repeater's model compared by value must never hold a themed colour.
// =============================================================================
Item {
    id: menu

    property var service: null
    property Item overlayItem: null
    property string fontFamily: "Inter"
    property BridgeStyle style: BridgeStyle {}
    readonly property bool open: floating.open

    signal pairRequested
    signal detailsRequested

    visible: false

    function _rows(): var {
        const out = [];
        const svc = menu.service;
        if (svc) {
            for (let i = 0; i < svc.devices.count; i++) {
                const d = svc.devices.get(i).rec.d;
                out.push({ id: "d:" + d.key, label: d.name + "  ·  " + Model.linkWords(d), check: "radio", checked: d.key === svc.currentKey });
            }
            if (out.length > 0) {
                out.push({ separator: true });
                out.push({ id: "details", label: "Details" });
            }
        }
        out.push({ id: "pair", label: "Pair another" });
        return out;
    }
    function openAt(x: real, y: real): void {
        floating.rows = menu._rows();
        floating.openAt(x, y);
    }
    function close(): void {
        floating.open = false;
    }
    function handleEscape(): bool {
        if (!floating.open)
            return false;
        floating.open = false;
        return true;
    }

    FloatingMenu {
        id: floating
        overlayItem: menu.overlayItem
        fontFamily: menu.fontFamily
        menuWidth: menu.style.menuWidth
        onTriggered: id => {
            if (id === "pair") {
                menu.pairRequested();
            } else if (id === "details") {
                menu.detailsRequested();
            } else if (menu.service && id.indexOf("d:") === 0) {
                menu.service.select(id.slice(2));
            }
        }
    }
}
