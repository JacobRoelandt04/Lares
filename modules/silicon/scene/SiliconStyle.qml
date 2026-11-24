import QtQuick

import "../../common/theme"

// =============================================================================
// SiliconStyle.qml -- the board's two families, each with a light and a dark palette. The user
// switches between them (the mockup's panel, then silicon.jsonc):
//
//   0 Material     the shell's own material: the board a raised plateau of the popup's
//                    surface, traces carved grooves that carry the light
//   1 Blueprint      a drafting sheet: white paper and blue ink, a cyanotype in dark mode
//
// What each palette slot means is written once, in board_materials.glsl's header. Every colour is a
// Theme token (siliconEva*, siliconBlueprint*, profile*, gpu*, profileTweak; themes/eva.json holds
// both modes), so the theme's mode decides light or dark -- `dark` is read from it, and the shaders'
// dark branches follow.
// =============================================================================
QtObject {
    id: root

    property int family: 0
    // The palette of a SECOND, older copy of the scene (the theme island's ghost: SiliconIsland): `oldMap` is every token as it stood
    // when the switch was asked (ThemeOld), `oldDark` the mode then. Null: the live tokens, which is every scene but that one.
    property var oldMap: null
    property bool oldDark: false
    readonly property bool dark: root.oldMap ? root.oldDark : Theme.mode === "dark"
    function _t(name: string): color {
        return root.oldMap ? root.oldMap[name] : Theme.tokenOf(name);
    }

    readonly property var names: ["Material", "Blueprint"]

    // palA .. palH per family (Blueprint uses five; the rest are unused)
    readonly property var _slots: [
        [root._t("siliconEvaSurface"), root._t("siliconEvaBevel"), root._t("siliconEvaShadow"), root._t("siliconEvaGroove"),
         root._t("siliconEvaInk"), root._t("siliconEvaSunk"), root._t("siliconEvaWell"), root._t("siliconEvaMetal")],
        [root._t("siliconBlueprintPaper"), root._t("siliconBlueprintInk"), root._t("siliconBlueprintFaint"),
         root._t("siliconBlueprintGrid"), root._t("siliconBlueprintWash"), "#000000", "#000000", "#000000"]
    ]

    // The SECOND palette, palI .. palP (board_materials.glsl names the slots): the displays' window, unlit segments and bezel are
    // the family's own; the lock's amber, gold, the memory hue and the ribbon's film and conductors are shared.
    // Slot 8 (the shaders' r3s2A) is the smoked glass over the displays' window (the family's own tint).
    readonly property var _slots2: [
        [root._t("siliconEvaWindow"), root._t("siliconEvaGhost"), root._t("siliconLock"), root._t("siliconGold"),
         root._t("siliconMemory"), root._t("siliconRibbonFilm"), root._t("siliconRibbonCopper"), root._t("siliconEvaBezel"),
         root._t("siliconEvaGlass")],
        [root._t("siliconBlueprintWindow"), root._t("siliconBlueprintGhost"), root._t("siliconLock"), root._t("siliconGold"),
         root._t("siliconMemory"), root._t("siliconRibbonFilm"), root._t("siliconRibbonCopper"), root._t("siliconBlueprintBezel"),
         root._t("siliconBlueprintGlass")]
    ]

    // The display connector's flip-lock bar, the family's own tone -- the shaders' `r3s1Latch` (its own uniform, not a slot of the palette)
    readonly property vector4d latch: root._v(root.family === 0 ? root._t("siliconEvaLatch") : root._t("siliconBlueprintLatch"))

    // tuneA: x bevel (Material) / crease line (Blueprint) px, w paper grain (Blueprint, 0 = default)
    // (y is free; tuneB is not wired by the scene and the shaders do not read it)
    readonly property var _tune: [
        [Qt.vector4d(1.8, 0.0, 0.0, 0.0), Qt.vector4d(1.8, 0.0, 0.0, 0.0)],
        [Qt.vector4d(1.1, 0.0, 0.0, 0.0), Qt.vector4d(1.1, 0.0, 0.0, 0.0)]
    ]

    function _v(colour) {
        const c = Qt.color(colour);
        return Qt.vector4d(c.r, c.g, c.b, 1);
    }

    readonly property var palette: root._slots[Math.max(0, Math.min(1, root.family))].map(root._v)
    readonly property var palette2: root._slots2[Math.max(0, Math.min(1, root.family))].map(root._v)
    readonly property vector4d tune: root._tune[Math.max(0, Math.min(1, root.family))][root.dark ? 1 : 0]

    // the popup surface the scene stands on (for harnesses that draw it)
    readonly property color ground: root._t("surface")

    // The profile and GPU-mode colours (CONTRACT section 1):
    // Quiet / Balanced / Performance, and Integrated / Smart / Hybrid / dGPU-only.
    function profileColour(k) {
        return [root._t("profileQuiet"), root._t("profileBalanced"), root._t("profilePerformance")][Math.max(0, Math.min(2, k))];
    }
    function gpuColour(m) {
        return [root._t("gpuIntegrated"), root._t("gpuSmart"), root._t("gpuHybrid"), root._t("gpuDgpu")][Math.max(0, Math.min(3, m))];
    }
    readonly property color tweakColour: root._t("profileTweak")
}
