pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// SleepVeils.qml -- one SleepVeil per output, for SleepFade. A file of its own, loaded by a LazyLoader only the first time a fade is
// wanted, because a PanelWindow cannot be LOADED without a layer-shell backend: every harness that runs offscreen and holds an
// IdleService would fail with "No PanelWindow backend loaded" were the windows declared in SleepFade itself (ThemeCurtains' reason).
//
// `fade` is the SleepFade (set by a Binding after the load; every read tolerates null). LARESLOCK-HOP, the lock's own headless output, gets
// none.
// =============================================================================
Scope {
    id: root

    property var fade: null
    readonly property var instances: veils.instances

    Variants {
        id: veils
        model: root.fade ? Quickshell.screens.filter(s => s.name !== "LARESLOCK-HOP") : []
        SleepVeil {
            required property var modelData
            screen: modelData
            fade: root.fade
        }
    }
}
