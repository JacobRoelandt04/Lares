pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// ShadowBoxLobe.qml -- a carved box (ShadowBox's carved look, same colours,
// same easings) that can grow a second, narrower lobe out of its TOP edge,
// joined to it by a smooth union (shaders/shadow_box_lobe.frag).
//
// The item IS the base box: its width and height are the box's, and the lobe
// paints above it, outside the item's bounds, like any floating thing (nothing
// above this item may clip it). `lobeHeight` is how much of the lobe shows
// above the box's top edge, 0 for none -- the host animates it (ONE property,
// the extent) and the shape follows. A lobe of no height is not drawn at all.
//
// `lobeReach` is the tallest the lobe can ever be: the effect item reserves
// that much room above the box, nothing more. Edges are whole pixels: the lobe
// is `lobeWidth` wide and centred on the box with the half pixel left to its
// left edge's rounding, never to a fractional width.
//
// With no lobe out the picture is ShadowBox's own, pixel for pixel.
// =============================================================================
Item {
    id: root

    property real baseRadius: 6
    property real sizeScale: 1.0
    property color surfaceColor: "#EAEDF5"     // the ground the box stands on
    property color bevelColor: "#EEF0F7"
    property color shadowColor: "#CED1D7"
    property color backgroundColor: "#E1E4EB"
    property real bevelWidth: 1
    property real shadowWidth: 3
    property var bevelEasing: [0.15, 0.1, 0.25, 1.0]
    property var shadowEasing: [0.15, 0.60, 0.35, 1.0]

    // ---- the lobe ----
    property real lobeWidth: 0
    property real lobeHeight: 0
    property real lobeReach: 0
    property real lobeRadius: 6
    // The joint's softness: the polynomial smooth-min's width, in px at scale 1.
    property real joinRadius: 7

    readonly property real _s: Math.max(0.2, root.sizeScale)
    readonly property real _bw: root.bevelWidth * root._s
    readonly property real _sw: root.shadowWidth * root._s
    readonly property real _margin: root._bw + 1
    readonly property real _r: Math.min(root.baseRadius * root._s, root.width / 2, root.height / 2)
    // Whole pixels on every edge: the lobe's left edge is rounded, its width and
    // its height are taken as they are (the host passes whole numbers).
    readonly property real _lobeX: Math.round((root.width - root.lobeWidth) / 2)
    readonly property bool _hasLobe: root.lobeHeight >= 1 && root.lobeWidth >= 1

    ShaderEffect {
        anchors.fill: parent
        anchors.leftMargin: -root._margin
        anchors.rightMargin: -root._margin
        anchors.bottomMargin: -root._margin
        anchors.topMargin: -(root._margin + root.lobeReach)
        fragmentShader: "shaders/shadow_box_lobe.frag.qsb"

        property real margin: root._margin
        property real headroom: root.lobeReach
        property real chipW: root.width
        property real chipH: root.height
        property real chipR: root._r
        property real hasLobe: root._hasLobe ? 1 : 0
        property real lobeX: root._lobeX
        property real lobeW: root.lobeWidth
        property real lobeTop: -root.lobeHeight
        // Down inside the box, where the union hides it.
        property real lobeBottom: root.height / 2
        property real lobeR: Math.min(root.lobeRadius * root._s, root.lobeWidth / 2)
        property real joinK: Math.max(0.5, root.joinRadius * root._s)
        property real bevelWidth: root._bw
        property real shadowWidth: root._sw
        property real edgeAlpha: 1.0
        property real falloff: 1.0
        property color surfaceColor: root.surfaceColor
        property color bevelColor: root.bevelColor
        property color shadowColor: root.shadowColor
        property color backgroundColor: root.backgroundColor
        property vector4d bevelEasing: Qt.vector4d(
            root.bevelEasing[0], root.bevelEasing[1], root.bevelEasing[2], root.bevelEasing[3])
        property vector4d shadowEasing: Qt.vector4d(
            root.shadowEasing[0], root.shadowEasing[1], root.shadowEasing[2], root.shadowEasing[3])
    }
}
