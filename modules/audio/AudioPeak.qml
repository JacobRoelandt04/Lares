pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Services.Pipewire

// =============================================================================
// AudioPeak.qml -- one row's level: a PwNodePeakMonitor while `active`, nothing at all otherwise.
//
// THE MONITOR IS A CAPTURE STREAM ON THE REAL GRAPH (application.name "Quickshell Peak Detect", stream.monitor, not passive), about
// 23 readings a second. So it exists only while the Loader is active: the popup's content is destroyed on close, and even inside an open popup a row's
// monitor runs only on its own tab and only where it wakes nothing (AudioRow `meterWanted`). A closed popup holds no capture stream.
//
// In a mock there is no node to monitor: `world.levelOf(node)` answers, and no Pipewire object is ever made.
// =============================================================================
Item {
    id: root

    property var node: null
    property bool active: false
    property var world: null                   // AudioWorld

    function read(): real {
        if (!root.active || !root.node)
            return 0;
        if (root.world)
            return root.world.levelOf(root.node);
        return root._live;
    }

    property real _live: 0
    onActiveChanged: {
        if (!root.active)
            root._live = 0;
    }
    Loader {
        active: root.active && !root.world && !!root.node
        sourceComponent: Item {
            PwNodePeakMonitor {
                node: root.node
                enabled: true
                onPeakChanged: root._live = peak
            }
        }
    }
}
