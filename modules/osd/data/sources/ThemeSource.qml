pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "../../../common/theme"

// =============================================================================
// ThemeSource.qml -- the theme, shown when it changes.
//
//   signal request(var req)    one partial CONTRACT section 1 request
//
// `Theme.announcedName` and `Theme.announcedMode` are the truth (the shell follows
// ~/.config/theme/state.json, so a switch from the clock, a script or another
// shell all land here; under the live curtain they move when the switch arrives,
// ahead of the palette, and the card opens in the old colours). The FIRST load is the baseline and says nothing: the
// theme becomes `ready` once its file is read and that reading is not a
// switch. After it, a change of the name, the mode or both is ONE request --
// a pair switch writes both in one cascade, which a 0 ms timer folds -- shown
// as "<name> <mode>" ("eva dark").
//
// `live: false` does not touch the Theme singleton: simulateReady(name, mode)
// is the baseline and simulateTheme(name, mode) a switch.
// =============================================================================
Item {
    id: root

    property bool live: true

    signal request(var req)

    property bool _primed: false
    property string _name: ""
    property string _mode: ""
    property string _wantName: ""
    property string _wantMode: ""

    function _observe(name, mode) {
        root._wantName = name;
        root._wantMode = mode;
        if (!root._primed) {
            root._primed = true;
            root._name = name;
            root._mode = mode;
            return;
        }
        fold.restart();
    }

    function simulateReady(name, mode) {
        root._observe(name, mode);
    }
    function simulateTheme(name, mode) {
        root._observe(name, mode);
        fold.stop();
        root._fire();
    }

    function _fire() {
        if (root._wantName === root._name && root._wantMode === root._mode)
            return;
        root._name = root._wantName;
        root._mode = root._wantMode;
        root.request({
            kind: "theme",
            key: "theme",
            source: "external",
            theme: { name: root._name, mode: root._mode }
        });
    }

    Timer {
        id: fold
        interval: 0
        onTriggered: root._fire()
    }

    LazyLoader {
        active: root.live
        component: Scope {
            id: scope
            readonly property bool ready: Theme.ready
            readonly property string name: Theme.announcedName
            readonly property string mode: Theme.announcedMode
            function look() {
                if (scope.ready && scope.name.length > 0)
                    root._observe(scope.name, scope.mode);
            }
            onReadyChanged: scope.look()
            onNameChanged: scope.look()
            onModeChanged: scope.look()
            Component.onCompleted: scope.look()
        }
    }
}
