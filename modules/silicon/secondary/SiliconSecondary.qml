pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// SiliconSecondary.qml -- the popup's secondary (CONTRACT.md section 9): the CPU tuning panel
// ("tuning", TuningPanel), the GPU settings ("gpu", GpuPanel) and the two dialogs -- the restart a MUX request waits for ("mux", MuxPanel)
// and the question a GPU step that would block busy apps asks ("confirm", ConfirmPanel) -- sized by its own implicit size per kind. One honest layout per kind, no views. The engine
// places and draws the box; this is what stands in it, on the popup's surface, 12 px from its edge.
//
// THE FIXED API (the popup binds these): `vm` (a SiliconService or a SiliconMock -- identical
// members), `kind`, `family`, `renderScale`, and its implicit size. `family` and `renderScale` are
// carried for the host's wiring only: the panels are the shell's own material (carved cards, raised
// buttons) in Theme tokens, and the scene's two board families do not reach them.
// The dialogs take what the popup keeps for them: `confirmStep` / `confirmHolders` (what is asked
// and of whom, as it was when the question was raised -- the engine tears this content down when it closes), and
// answer with `confirmed()`, `cancelled()` and `muxDismissed()`, which the popup handles (it closes the secondary, or
// does what was confirmed).
//
// THE ENGINE'S SECONDARY CONTRACT (GooeyEngine "THE CONTENT CONTRACT", the model is NetworkDetail):
// the engine assigns `secondaryKey` -- "tuning" | "gpu" | "mux" | "confirm" -- while this content is faded out (on load
// and between the fade out and the fade in of a swap), and keeps `secondaryCutout` set to the part
// of this box the primary covers when the secondary is inset. The kind that is SHOWN follows the key
// once the engine has set one, so a swap from one panel to the other happens while nothing is
// visible; a host that sets `kind` and no key (a probe, a mockup) gets that kind. The cutout is
// reserved as a band on the edge it touches and ADDED to the implicit size, so the part the primary
// does not cover is the panel at its own size (StockDetail's rule).
//
// The service is told the pointer is here (`vm.touch()`, at most every 200 ms): the popup's idle
// ladder must not halt the scene while somebody works its panel. A HoverHandler on this root is the
// ancestor of every control, so it takes nobody's hover.
// =============================================================================
Item {
    id: root

    property var vm: null                 // a SiliconService or a SiliconMock
    property string kind: "tuning"        // "tuning" | "gpu" | "mux" | "confirm"
    property int family: 0
    property real renderScale: 1

    // what the dialogs are given and answer with (see the header)
    property int confirmStep: 0
    property var confirmHolders: []
    signal confirmed()
    signal cancelled()
    signal muxDismissed()

    // the user dresses mockups in Audiowide
    property string fontFamily: "Inter"

    // assigned by the engine (see the header)
    property var secondaryKey: null
    property rect secondaryCutout: Qt.rect(0, 0, 0, 0)

    readonly property var kinds: ["tuning", "gpu", "mux", "confirm"]
    readonly property string shownKind: root.kinds.indexOf(root.secondaryKey) >= 0
        ? root.secondaryKey : (root.kinds.indexOf(root.kind) >= 0 ? root.kind : "tuning")
    readonly property Item panel: loader.item as Item
    readonly property alias overlayItem: overlayLayer

    readonly property SecondaryStyle look: SecondaryStyle {
        fontFamily: root.fontFamily
    }

    // ---- the part the primary covers: a band on the edge the cutout touches ---------------------------
    readonly property var _band: {
        const r = root.secondaryCutout;
        const b = { top: 0, bottom: 0, left: 0, right: 0 };
        if (!(r.width > 0) || !(r.height > 0))
            return b;
        // A band that does not start at an edge ends at the opposite one. Not measured against this
        // item's own size: that size is made of the band (a loop through the engine).
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

    Loader {
        id: loader
        x: root._left
        y: root._top
        sourceComponent: root.shownKind === "gpu" ? gpuPanel
            : root.shownKind === "mux" ? muxPanel
            : root.shownKind === "confirm" ? confirmPanel : tuningPanel
    }

    Component {
        id: tuningPanel
        TuningPanel {
            vm: root.vm
            look: root.look
            overlay: overlayLayer
            width: implicitWidth
            height: implicitHeight
        }
    }
    Component {
        id: gpuPanel
        GpuPanel {
            vm: root.vm
            look: root.look
            overlay: overlayLayer
            width: implicitWidth
            height: implicitHeight
        }
    }
    Component {
        id: muxPanel
        MuxPanel {
            vm: root.vm
            look: root.look
            width: implicitWidth
            height: implicitHeight
            onDismissed: root.muxDismissed()
        }
    }
    Component {
        id: confirmPanel
        ConfirmPanel {
            look: root.look
            step: root.confirmStep
            holders: root.confirmHolders
            width: implicitWidth
            height: implicitHeight
            onConfirmed: root.confirmed()
            onCancelled: root.cancelled()
        }
    }

    // The floating layer: hover tips are parented here (one that is inside a block is clipped by
    // whatever scrolls, and painted under the next block).
    Item {
        id: overlayLayer
        anchors.fill: parent
        z: 100
    }

    property real _lastTouch: 0
    function _touch() {
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
