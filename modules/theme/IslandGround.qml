pragma ComponentBehavior: Bound

import QtQuick
import "../common/theme"
import "../common/components"

// =============================================================================
// IslandGround.qml -- the OLD ground of a ThemeIsland, for a thing whose moving parts have the same colours on both sides of a theme switch.
//
// Silicon's board differs by palette in every pixel, so it needs a whole second scene (SiliconIsland's ghost). A thing whose moving parts are DATA (the theme popup's cards and
// strands: a pair's own colours, which no switch touches) only needs the ground under them to go by the line: this, a flat quad in the old surface, laid UNDER those parts and
// over the live new ground. Old side of the line: the old ground, the moving parts on it. New side: the live ground, the same moving parts. One copy of them, so nothing is doubled.
//
//     Loader {
//         active: island.armed && old.map !== null
//         x: island.snapRect.x; y: island.snapRect.y; width: island.snapRect.width; height: island.snapRect.height
//         sourceComponent: Component { IslandGround { island: myIsland; ground: old.map.surface } }
//     }
//
// THE RECT MUST BE THE HOLE'S (`snap: true`): the quad is cut by the hole's own test, so it ends exactly where the old picture begins, at the corners too.
// =============================================================================
ShaderEffect {
    id: g

    required property ThemeIsland island
    property color ground: "transparent"

    readonly property var w: g.island.wipe
    // (Theme.fadeProgress: the popup may move, and this is re-read every frame of a run)
    readonly property point at: {
        void Theme.fadeProgress;
        return g.mapToItem(null, 0, 0);
    }
    readonly property point end: {
        void Theme.fadeProgress;
        return g.mapToItem(null, g.width, g.height);
    }
    readonly property real _dpr: g.Window.window && g.Window.window.devicePixelRatio > 0 ? g.Window.window.devicePixelRatio : 1

    property vector2d size: g.Window.window ? Qt.vector2d(g.Window.window.width, g.Window.window.height) : Qt.vector2d(1, 1)
    property vector2d origin: g.w ? Qt.vector2d(g.w.originX, g.w.originY) : Qt.vector2d(0, 0)
    property real progress: g.w ? g.w.progress : 0
    property real soft: g.w ? g.w.soft : 1
    property real seed: g.w ? g.w.seed : 0
    property real style: g.w ? g.w.styleIndex : 0
    property real px1: 1 / g._dpr
    property real radius: g.island.width > 0 ? g.island.radius * (g.end.x - g.at.x) / g.width : 0
    property real cut: g.w ? 1 : 0
    property vector4d place: Qt.vector4d(g.at.x, g.at.y, g.end.x - g.at.x, g.end.y - g.at.y)

    // The plain fade: the picture's own clock. Under the line it is whole, and the line cuts it.
    opacity: g.w ? 1 : 1 - Theme.fadeProgress
    // The ROOT of this file: a literal path would resolve against the file that instantiates it, so the path is a Qt.resolvedUrl, and
    // `source` is declared for Qt's built-in shader, which samples it and which the effect can hold before that binding lands.
    property var source: null
    fragmentShader: Qt.resolvedUrl("../common/components/shaders/curtain_ground.frag.qsb")
}
