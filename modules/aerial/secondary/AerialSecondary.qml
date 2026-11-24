pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// AerialSecondary.qml -- the popup's secondary (the engine's "secondary", GooeyEngine "THE CONTENT CONTRACT"): ONE panel per kind,
// loaded by the key, sized by its own implicit size. The engine places and draws the box; this is what stands in it, 12 px from its
// edge, on the popup's surface. The pattern is silicon's SiliconSecondary.
//
// THE FIXED API (the popup binds these)
//   vm            an AerialService or an AerialMock (identical members; the panels read facts and call intents only)
//   secondaryKey  assigned by the engine while this content is faded out: "<kind>" or "<kind>:<target>" -- the target is whatever
//                 follows the FIRST colon (a network's key, a Bluetooth address "AA:BB:..", a wired interface, a pad id)
//   kind / targetKey   the same two, for a host that sets them itself (a probe, the mockup); the engine's key wins once it has set one
//   family, renderScale   carried for the host's wiring only (the panels are the shell's own material in Theme tokens)
//   fontFamily    the user dresses mockups in Audiowide
//   secondaryCutout   the part of this box the primary covers; reserved as a band on the edge it touches and ADDED to the implicit size
//   dismissed()   a panel asks to be closed: the answer "no" to a pairing, a field's own Escape -- the popup closes the secondary
//   keyboardWanted   a field of the panel wants the keys NOW (a password, a PIN, an address): the POPUP asks the compositor for them
//                 (a secondary's fields are the popup's to ask for; the engine asks the primary only)
//   handleEscape()   true: the panel took the key for what it is in the middle of (the saved list's typed search); false: nothing to take,
//                 and the engine closes the popup with the panel, or puts the panel away first (AerialPopup.stepBack)
//
// KINDS    network (a Wi-Fi network: targetKey its key, "" the docked one)   saved (the memory chip)   wired (the jack: the interface)
//          hotspot   vpn (the globe)   bt (a device: its address)   pad (a test pad: its id)   usage (the usage display)
//
// The service is told the pointer is here (`vm.touch()`, at most every 200 ms): the popup's idle ladder must not halt the scene while
// somebody works a panel.
// =============================================================================
Item {
    id: root

    property var vm: null
    property string kind: "network"
    property string targetKey: ""
    property int family: 0
    property real renderScale: 1
    property string fontFamily: "Inter"

    // assigned by the engine
    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)

    signal dismissed()

    readonly property var kinds: ["network", "saved", "wired", "hotspot", "vpn", "bt", "pad", "usage"]
    readonly property string _key: root.secondaryKey === null || root.secondaryKey === undefined ? "" : String(root.secondaryKey)
    readonly property int _colon: root._key.indexOf(":")
    readonly property string _keyKind: root._colon >= 0 ? root._key.slice(0, root._colon) : root._key
    readonly property string shownKind: root.kinds.indexOf(root._keyKind) >= 0 ? root._keyKind : (root.kinds.indexOf(root.kind) >= 0 ? root.kind : "network")
    readonly property string shownTarget: root.kinds.indexOf(root._keyKind) >= 0 ? (root._colon >= 0 ? root._key.slice(root._colon + 1) : "") : root.targetKey
    readonly property var panel: loader.item
    readonly property bool keyboardWanted: !!root.panel && root.panel.wantsKeys === true

    readonly property PanelStyle look: PanelStyle {
        fontFamily: root.fontFamily
    }

    // ---- the part the primary covers: a band on the edge the cutout touches ----------------------------------------------------------
    readonly property var _band: {
        const r = root.secondaryCutout;
        const b = { top: 0, bottom: 0, left: 0, right: 0 };
        if (!(r.width > 0) || !(r.height > 0))
            return b;
        // A band that does not start at an edge ends at the opposite one. Not measured against this item's own size (a loop through the engine).
        const across = r.width >= r.height;
        if (across && r.y <= 0.5)
            b.top = r.y + r.height;
        else if (across)
            b.bottom = r.height;
        else if (r.x <= 0.5)
            b.left = r.x + r.width;
        else
            b.right = r.width;
        return b;
    }
    readonly property real _top: Math.ceil(root._band.top)
    readonly property real _bottom: Math.ceil(root._band.bottom)
    readonly property real _left: Math.ceil(root._band.left)
    readonly property real _right: Math.ceil(root._band.right)

    implicitWidth: root._left + (root.panel ? root.panel.implicitWidth : 0) + root._right
    implicitHeight: root._top + (root.panel ? root.panel.implicitHeight : 0) + root._bottom

    function handleEscape(): bool {
        return !!root.panel && typeof root.panel.handleEscape === "function" ? root.panel.handleEscape() : false;
    }

    Loader {
        id: loader
        x: root._left
        y: root._top
        sourceComponent: {
            switch (root.shownKind) {
            case "saved": return savedPanel;
            case "wired": return wiredPanel;
            case "hotspot": return hotspotPanel;
            case "vpn": return vpnPanel;
            case "bt": return btPanel;
            case "pad": return padPanel;
            case "usage": return usagePanel;
            }
            return networkPanel;
        }
    }

    Component {
        id: networkPanel
        NetworkPanel {
            vm: root.vm
            look: root.look
            targetKey: root.shownTarget
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }
    Component {
        id: savedPanel
        SavedPanel {
            vm: root.vm
            look: root.look
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }
    Component {
        id: wiredPanel
        WiredPanel {
            vm: root.vm
            look: root.look
            targetKey: root.shownTarget
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }
    Component {
        id: hotspotPanel
        HotspotPanel {
            vm: root.vm
            look: root.look
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }
    Component {
        id: vpnPanel
        VpnPanel {
            vm: root.vm
            look: root.look
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }
    Component {
        id: btPanel
        BtDevicePanel {
            vm: root.vm
            look: root.look
            targetKey: root.shownTarget
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }
    Component {
        id: padPanel
        PadPanel {
            vm: root.vm
            look: root.look
            targetKey: root.shownTarget !== "" ? root.shownTarget : "net"
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }
    Component {
        id: usagePanel
        UsagePanel {
            vm: root.vm
            look: root.look
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.dismissed()
        }
    }

    property real _lastTouch: 0
    function _touch(): void {
        const now = Date.now();
        if (now - root._lastTouch < 200)
            return;
        root._lastTouch = now;
        if (root.vm && typeof root.vm.touch === "function")
            root.vm.touch();
    }
    HoverHandler {
        onPointChanged: root._touch()
    }
}
