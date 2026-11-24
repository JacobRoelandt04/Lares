pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray

// =============================================================================
// TrayService.qml -- the live system tray: Quickshell's SystemTray, as TrayModel's
// records. `live: false` never touches SystemTray (a LazyLoader holds all of it), so
// a mockup or a probe cannot take the StatusNotifierWatcher by accident.
//
//   in:  live, and TrayModel's config / appLookup
//   out: TrayModel's (rows, count, empty, attention, serial, log, record(key),
//        leftClick / middleClick / scroll / menuHandle), and
//        mock: false     the owner sets TrayMenuModel.mock from it
//
// Items come from SystemTray.items.values, diffed on its valuesChanged (an item
// arrives ~60 ms after it registers). TrayCaps reads what each one implements (and
// the IconName of one without IconPixmap) after every change of that list, and the
// rows' records pick the answers up when they land.
// =============================================================================
TrayModel {
    id: root

    property bool live: false
    readonly property bool mock: false

    capsSource: caps

    TrayCaps {
        id: caps
        live: root.live
    }

    onLiveChanged: if (!root.live) root._setItems([])

    LazyLoader {
        active: root.live
        component: Scope {
            Connections {
                target: SystemTray.items
                function onValuesChanged() {
                    root._setItems(SystemTray.items.values);
                    caps.refresh();
                }
            }
            Component.onCompleted: {
                root._setItems(SystemTray.items.values);
                caps.refresh();
            }
        }
    }
}
