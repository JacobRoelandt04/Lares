pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// ThemeCurtains.qml -- one ThemeCurtain per screen, for ThemeControl. A file of its own, loaded by a LazyLoader only when the curtain is
// configured on (and there is a compositor to capture from), because a PanelWindow cannot be LOADED without a layer-shell backend:
// any harness that runs offscreen (every mock render and probe that holds a ThemeControl) would fail with "No PanelWindow backend
// loaded" at the type, curtain or not, were the windows declared in ThemeControl itself.
//
// `controller` is the ThemeControl (set by a Binding after the load; every read tolerates null until then). LARESLOCK-HOP is the lock's own
// headless output and gets none.
// =============================================================================
Scope {
    id: root

    property var controller: null
    readonly property var instances: curtains.instances

    Variants {
        id: curtains
        model: root.controller ? Quickshell.screens.filter(s => s.name !== "LARESLOCK-HOP") : []
        ThemeCurtain {
            id: curtain
            required property var modelData
            screen: modelData
            armed: root.controller ? root.controller.curtainArmed && root.controller.overlayOn(modelData.name) : false
            style: root.controller && root.controller.curtainStyleNow !== "" ? root.controller.curtainStyleNow : "radial"
            progress: root.controller ? root.controller.curtainProgress : 0
            seed: root.controller ? root.controller.curtainSeed : 0
            originX: root.controller && root.controller.curtainCursor ? root.controller.curtainCursor.x - modelData.x : NaN
            originY: root.controller && root.controller.curtainCursor ? root.controller.curtainCursor.y - modelData.y : NaN
            onReadyChanged: if (root.controller) root.controller.curtainsChanged()
            onFailedChanged: if (root.controller) root.controller.curtainsChanged()
            onFailedCapture: if (root.controller) root.controller.curtainsChanged()
        }
    }
}
