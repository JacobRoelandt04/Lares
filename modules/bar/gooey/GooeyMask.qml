import QtQuick
import Quickshell

// =============================================================================
// GooeyMask.qml -- the input region of a gooey engine's window.
//
//     PanelWindow { mask: GooeyMask { engine: engine } ... }
//
// One sub-region per mask proxy the engine keeps (every bar that takes input --
// GooeyBar.inputMask false leaves a bar out --, both primaries, the children, the
// lane and the OSD). The engine sizes the proxies: a body at rest is its exact box, a
// body in motion the union of where it came from and where it is going, which
// holds still for the whole transition -- so the compositor is told twice per
// animation instead of every frame, and a closed popup leaves no invisible
// rectangle behind that eats clicks. `Region.regions` is read-only from QML,
// hence a fixed pool rather than a Repeater.
// =============================================================================
Region {
    id: root

    property var engine

    Region { item: root.engine ? root.engine.maskItems[0] : null }
    Region { item: root.engine ? root.engine.maskItems[1] : null }
    Region { item: root.engine ? root.engine.maskItems[2] : null }
    Region { item: root.engine ? root.engine.maskItems[3] : null }
    Region { item: root.engine ? root.engine.maskItems[4] : null }
    Region { item: root.engine ? root.engine.maskItems[5] : null }
    Region { item: root.engine ? root.engine.maskItems[6] : null }
    Region { item: root.engine ? root.engine.maskItems[7] : null }
    Region { item: root.engine ? root.engine.maskItems[8] : null }
    Region { item: root.engine ? root.engine.maskItems[9] : null }
    Region { item: root.engine ? root.engine.maskItems[10] : null }
    Region { item: root.engine ? root.engine.maskItems[11] : null }
    Region { item: root.engine ? root.engine.maskItems[12] : null }
    Region { item: root.engine ? root.engine.maskItems[13] : null }
    Region { item: root.engine ? root.engine.maskItems[14] : null }
    Region { item: root.engine ? root.engine.maskItems[15] : null }
}
