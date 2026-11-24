pragma ComponentBehavior: Bound

import QtQuick
import "TrayText.js" as TrayText

// =============================================================================
// TrayRecord.qml -- one tray item, as the bar reads it. TrayService and TrayMock
// both create these, one per item, and keep each by identity for the item's whole
// life: the strip's delegate binds to a record's properties, so an icon that
// animates (nm-applet's connecting dots) changes ONE `iconSource`, never the model.
//
//   key            item.id made unique ("id", "id#2"): the row key everywhere
//   item           the SystemTrayItem (or the mock's)
//   name           TrayText.nameOf, live
//   statusText     TrayText.statusTextOf, live ("" when the tooltip says nothing new)
//   iconSource     item.icon -- except for an item in NeedsAttention that has no attention
//                  icon of its own (nm-applet's AttentionIconName is ""): Quickshell's icon
//                  is then the missing-icon checkerboard, and this is the normal icon,
//                  image://icon/<IconName read by TrayCaps>
//   status         "passive" | "active" | "attention"
//   hasMenu, onlyMenu
//   canActivate    a left click has something to do: not only a menu, and Activate
//                  implemented (or not known yet: the SNI default)
//   caps           { activate, secondary, scroll, iconPixmap, attentionIcon, known } (TrayCaps)
//
// Inputs the creator keeps current: `config` (WindowTrayConfig.config: the renames),
// `appLookup` (AppLookup), `caps`, `iconName`. Every read of `item` is guarded: the
// item can be destroyed under a record that has not been removed yet.
// =============================================================================
QtObject {
    id: rec

    property string key: ""
    property var item: null
    property var config: null
    property var appLookup: null
    property var caps: ({ activate: true, secondary: true, scroll: true, iconPixmap: true, attentionIcon: true, known: false })
    property string iconName: ""

    // A mock item cannot declare a property called `id` (a QML object answers `.id` with its
    // own QML id), so it says `trayId`; a SystemTrayItem has no such property.
    readonly property string itemId: rec.item ? String((rec.item.trayId !== undefined ? rec.item.trayId : rec.item.id) || "") : ""
    readonly property string name: TrayText.nameOf({
        id: rec.itemId,
        title: rec.item ? rec.item.title : "",
        tooltipTitle: rec.item ? rec.item.tooltipTitle : ""
    }, { rename: rec.config ? rec.config.trayRename : null },
        rec.appLookup && rec.itemId !== "" ? rec.appLookup.app(rec.itemId).name : "")
    readonly property string statusText: TrayText.statusTextOf({
        tooltipTitle: rec.item ? rec.item.tooltipTitle : "",
        tooltipDescription: rec.item ? rec.item.tooltipDescription : ""
    }, rec.name)
    readonly property string iconSource: {
        if (!rec.item)
            return "";
        if (rec.item.status === 2 && rec.caps.known === true && rec.caps.attentionIcon === false && rec.iconName !== "")
            return rec.iconName.charAt(0) === "/" ? "file://" + rec.iconName : "image://icon/" + rec.iconName;
        return String(rec.item.icon || "");
    }
    readonly property string status: {
        const s = rec.item ? rec.item.status : 0;
        return s === 2 ? "attention" : (s === 1 ? "active" : "passive");
    }
    readonly property bool hasMenu: rec.item ? !!rec.item.hasMenu : false
    readonly property bool onlyMenu: rec.item ? !!rec.item.onlyMenu : false
    readonly property bool canActivate: !rec.onlyMenu && rec.caps.activate !== false
}
