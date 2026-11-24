import QtQuick

// =============================================================================
// ScaleRoot.qml -- a coordinate system magnified by `factor`.
//
//     ScaleRoot {
//         factor: 1.25
//         hostWidth: window.width          // the room it has, in ITS PARENT'S px
//         hostHeight: window.height
//         Frame { anchors.fill: parent }   // laid out in design px: hostWidth / factor wide
//     }
//
// The children are laid out in DESIGN px -- the root is `hostWidth / factor` wide, so a frame that fills it fills the host --
// and drawn `factor` times larger, from the top left. Pointer, hover, wheel and keyboard land on the right controls and the
// input regions (Region { item }) map through the transform, and the engine's own
// geometry (radii, fillets, snap distances, gaps) follows for nothing, which is why the SHELL's global scale is this and not a
// scale on each popup.
//
// `deviceScale` is what a magnified picture needs to know: DEVICE px per design px inside this root -- the pixel ratio of the
// window the root is in times its factor, times any root above. DeviceScale finds it from anywhere below.
// =============================================================================
Item {
    id: root

    // The Item scale the children are drawn at.
    property real factor: 1
    // The room it has in its parent's px.
    property real hostWidth: root.parent ? root.parent.width : 0
    property real hostHeight: root.parent ? root.parent.height : 0

    // Device px per design px inside.
    readonly property real deviceScale: above.value * root.factor

    width: root.hostWidth / Math.max(0.01, root.factor)
    height: root.hostHeight / Math.max(0.01, root.factor)
    scale: root.factor
    transformOrigin: Item.TopLeft

    // Asked from the parent: the search must never pass through this root's own `deviceScale`.
    DeviceScale {
        id: above
        from: root.parent
    }
}
