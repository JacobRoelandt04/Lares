pragma ComponentBehavior: Bound

import QtQuick

import "../components"
import "../theme"

// =============================================================================
// BoardIsland.qml -- the board keeps moving through a theme switch (the toolkit's; silicon's SiliconIsland and aerial's are this with their ghost scene).
//
// A light/dark switch shows a still picture of the frame before, faded out over the new palette, and what keeps moving under
// it is a second copy of itself (CLAUDE.md), so everything is held still for the fade. The board is not: it is a THEME ISLAND (ThemeIsland): a rect of it is cut out of
// the picture, and what shows through is live.
//
// WHY A GHOST, NOT A MIX OF COLOURS. The board's shaders branch on dark and light (the families' own looks, the lights and the
// glows differ by branch), so a palette mixed halfway is neither. What is exact is two whole pictures crossfaded: the live scene
// (the new palette, the one in the window) and, over it, a GHOST -- a second scene given every input of the first (one
// binding each: the scene is a pure function of its inputs and `time`, particles included: "a film that sets time per frame draws
// what the live scene draws") but the OLD palette and mode (ThemeOld: the tokens as they stood at the ask), laid on the popup's
// old surface and drawn as ONE layer at opacity 1 - Theme.fadeProgress, the picture's own clock. Over the hole that is
// mix(old scene, new scene, progress) at every pixel, which is what the picture over the rest of the popup shows, and both halves
// move with the one `time`.
//
// WHEN. Armed at the ask (`live` then: the popup is shown, laid out and the clock is going), held until the fade is over: the ghost
// is built at the ask (a Loader) and destroyed when the fade ends, so a popup at rest carries nothing of this. It is on screen
// from the start at full opacity -- over the live scene, which still has the old palette until the commit, so the picture taken
// of it is the same picture -- and its first render (the board's cached layers) lands in the frames before the commit, which the
// picture hides.
//
// THE HOLE is the scene's rect inset `inset` px: the popup's rounded corners and the outer fade of the board's shadow stay in the
// picture (static), and the ghost's opaque ground never reaches past the popup's edge. What else is drawn live inside it (the
// plates' text, the chevrons) carries its own FadeColors.
// =============================================================================
Item {
    id: root

    // ---- in ----
    property var scene: null              // the live scene (a width, a height and a renderScale are all this reads)
    // The ghost: a Component whose root is a COPY of the scene -- every input of the live one bound to it, `oldMap` / `oldDark` its palette (below), `x` / `y` -
    // `ghostX` / `ghostY`, its size the live scene's. Declared by the deriving file, which sees the ids there.
    property Component ghostContent: null
    // The popup can run its board through a switch: set while it is shown, laid out and its clock is going.
    property bool live: false
    property real inset: 16

    // ---- out ----
    readonly property bool armed: island.armed
    // what the ghost's content reads: the old palette (ThemeOld: the tokens as they stood at the ask) and where the hole's rect sits in the scene
    readonly property var oldMap: old.map
    readonly property bool oldDark: old.dark
    readonly property real ghostX: ghostLoader.x
    readonly property real ghostY: ghostLoader.y

    x: 0
    y: 0
    width: root.scene ? root.scene.width : 0
    height: root.scene ? root.scene.height : 0
    // Never takes the pointer; the board's input is SceneInput's.
    enabled: false

    ThemeOld {
        id: old
        enabled: root.live
    }

    ThemeIsland {
        id: island
        x: root.inset
        y: root.inset
        width: Math.max(0, root.width - root.inset * 2)
        height: Math.max(0, root.height - root.inset * 2)
        radius: 0
        snap: true
        live: root.live && root.scene !== null && island.width > 0
    }

    Loader {
        id: ghostLoader
        active: island.armed && old.map !== null
        // the hole's rect once it has been put on whole device pixels (ThemeIsland.snap): the ghost must end where the hole does
        x: island.snapRect.x
        y: island.snapRect.y
        width: island.snapRect.width
        height: island.snapRect.height
        sourceComponent: ghostComp
    }

    Component {
        id: ghostComp
        // ONE layer: the ghost and the old ground it lies on fade out together, over the live scene.
        Item {
            id: group
            layer.enabled: true
            // whole device pixels (the rect was snapped to them): rounded, never ceiled, or float dust makes it one px larger and resampled
            layer.textureSize: Qt.size(Math.max(1, Math.round(group.width * root.scene.renderScale)),
                                       Math.max(1, Math.round(group.height * root.scene.renderScale)))
            layer.smooth: true
            // the plain fade, or (the live curtain) whole, and cut by the curtain's own line
            layer.effect: island.wipe ? island.wipeEffect : null
            opacity: island.wipe ? 1 : 1 - Theme.fadeProgress

            // the popup's own surface, as it was
            Rectangle {
                anchors.fill: parent
                color: old.map ? old.map["surface"] : "transparent"
            }
            // The scene, at its own place in the scene's coordinates (the group is the hole's rect).
            Loader {
                id: ghost
                x: -ghostLoader.x
                y: -ghostLoader.y
                width: root.scene.width
                height: root.scene.height
                sourceComponent: root.ghostContent
            }
        }
    }
}
