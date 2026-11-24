import QtQuick

import "../../common/glyphs"
import "../../common/theme"

// =============================================================================
// AerialStyle.qml -- the board's two families, each with a light and a dark palette (the toolkit's slots, the same as silicon's SiliconStyle: the family
// follows silicon's own setting, `look.family`, one switch for both scenes):
//
//   0 Material     the shell's own material: the board a raised plateau of the popup's surface, traces carved grooves
//   1 Blueprint      a drafting sheet: white paper and blue ink, a cyanotype in dark mode
//
// The board's family palettes are silicon's tokens (siliconEva*, siliconBlueprint*: one look for both boards); only what the card needs and silicon has not got is
// aerial's own (aerialPcb, aerialShield, aerialSolder, aerialPaper, aerialGold, aerialCoaxMain, aerialCoaxAux: materials, not the theme's colours, the same in every
// theme file). What each slot means is written once, in aerial_materials.glsl's header. The lit colours (ok, warn, error, accent) are the theme's own tokens.
// =============================================================================
QtObject {
    id: root

    property int family: 0
    // The palette of a SECOND, older copy of the scene (the theme island's ghost): `oldMap` is every token as it stood when the switch was asked (ThemeOld), `oldDark` the mode then.
    property var oldMap: null
    property bool oldDark: false
    readonly property bool dark: root.oldMap ? root.oldDark : Theme.mode === "dark"
    function _t(name: string): color {
        return root.oldMap ? root.oldMap[name] : Theme.tokenOf(name);
    }

    readonly property var names: ["Material", "Blueprint"]

    // palA .. palH per family (Blueprint uses five)
    readonly property var _slots: [
        [root._t("siliconEvaSurface"), root._t("siliconEvaBevel"), root._t("siliconEvaShadow"), root._t("siliconEvaGroove"),
         root._t("siliconEvaInk"), root._t("siliconEvaSunk"), root._t("siliconEvaWell"), root._t("siliconEvaMetal")],
        [root._t("siliconBlueprintPaper"), root._t("siliconBlueprintInk"), root._t("siliconBlueprintFaint"),
         root._t("siliconBlueprintGrid"), root._t("siliconBlueprintWash"), "#000000", "#000000", "#000000"]
    ]
    // palI .. palP, slot 8 (r3s2A): the displays' window, unlit segments, then the card's PCB, gold, the label's paper, the shield's tin, the solder rim and the displays' bezel; the glass
    readonly property var _slots2: [
        [root._t("siliconEvaWindow"), root._t("siliconEvaGhost"), root._t("aerialPcb"), root._t("aerialGold"),
         root._t("aerialPaper"), root._t("aerialShield"), root._t("aerialSolder"), root._t("siliconEvaBezel"),
         root._t("siliconEvaGlass")],
        [root._t("siliconBlueprintWindow"), root._t("siliconBlueprintGhost"), root._t("aerialPcb"), root._t("aerialGold"),
         root._t("aerialPaper"), root._t("aerialShield"), root._t("aerialSolder"), root._t("siliconBlueprintBezel"),
         root._t("siliconBlueprintGlass")]
    ]
    // the two coax jackets (this scene's own uniforms palQ, palR)
    readonly property vector4d coaxMain: root._v(root._t("aerialCoaxMain"))
    readonly property vector4d coaxAux: root._v(root._t("aerialCoaxAux"))

    // tuneA: x bevel (Material) / crease line (Blueprint) px, w paper grain (Blueprint, 0 = default)
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

    // what the lights are: the theme's own hues
    readonly property color ok: root._t("ok")
    readonly property color warn: root._t("warn")
    readonly property color error: root._t("error")
    readonly property color accent: root._t("accent")
    // the silk and the live label's ink: the board's own printed colour per family (Material's engraving ink, Blueprint's ink)
    readonly property color silk: root.family === 0 ? root._t("siliconEvaInk") : root._t("siliconBlueprintInk")
    readonly property color paper: root._t("aerialPaper")
    // the radios' own hues (the bar pill's ON colours, BarHues): the latches' emblems wear them while the radio is on, the cloud's Bluetooth devices too
    readonly property color wifiHue: BarHues.wifiOn
    readonly property color btHue: BarHues.btOn
    readonly property vector4d wifiHueV: root._v(root.wifiHue)
    readonly property vector4d btHueV: root._v(root.btHue)

    // THE LABEL (round 3; its dark half round 5). Material: a sticker -- dark print on pale paper in light mode, WHITE print on a dark sticker in dark mode (the user:
    // never how it is on a real card, and better). While the tunnel is up it turns to brushed chrome (aerialChrome*: the room's lights, the plate's own tone, its darks) and its
    // print to a matte roughening (`labelEtch`): bright metal with a dark roughening in light mode, dark metal with a pale frost in dark mode, so the print keeps its tone
    // through the wipe; the letters' lip (`labelLipColour`) is the plate's light edge under a dark letter and its dark edge under a pale one. Blueprint: the label is the
    // drafting sheet's own paper and ink, and the tunnel's plate is drafted (the wash, a hatch in the faint ink, a frame in the ink): its print does not change.
    readonly property bool _bp: root.family === 1
    readonly property color labelPaper: root._bp ? root._t("siliconBlueprintPaper") : root._t("aerialPaper")
    readonly property color labelInk: root._bp ? root._t("siliconBlueprintInk") : root._t("aerialLabelInk")
    readonly property color labelEtch: root._bp ? root._t("siliconBlueprintInk") : root._t("aerialChromeEtch")
    readonly property color chromeSky: root._bp ? root._t("siliconBlueprintPaper") : root._t("aerialChromeSky")
    readonly property color chromeBase: root._bp ? root._t("siliconBlueprintWash") : root._t("aerialChromeBase")
    readonly property color chromeDeep: root._bp ? root._t("siliconBlueprintFaint") : root._t("aerialChromeDeep")
    readonly property color labelHot: root._bp ? root._t("siliconBlueprintInk") : "#FFFFFF"
    readonly property color labelLipColour: root._bp ? root._t("siliconBlueprintInk") : root._t("aerialLabelLip")
    readonly property bool labelLip: !root._bp
}
