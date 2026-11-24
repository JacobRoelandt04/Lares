pragma ComponentBehavior: Bound

import QtQuick

import "../../common/board"
import "../scene/IsoCamera.js" as Cam
import "PopupLayout.js" as Layout

// =============================================================================
// SceneInput.qml -- silicon's input layer: a BoardInput (modules/common/board/BoardInput.qml: the one MouseArea, the hover, the hand cursor, the two-finger
// swipe) with silicon's picks. A click is turned into a board part by `IsoCamera.pick`, with the frames the parts are in RIGHT NOW (the package as it is
// turned and lifted, the card as it is lifted out, the plug, the DIP lever), the same boxes and the same camera the shaders draw with.
//
//   click   a part -> `clicked(intent, at)`: "tuning" (the package), "gpu" (the card or its slot), "limit" (the DIP switch), or "" for anything else; `at`
//           is where the part is, item px (what a secondary hangs from). The card, once it has dissolved into Integrated, is not drawn any more but its
//           PLACE is: the pick takes it SEATED in its slot, so the region is the same one as in every other mode (the card's volume, the slot, the
//           latch), and the lifted ghost, which is drawn nowhere, is not a thing to click. A HOLOGRAM answers too, where nothing of the board does: the
//           CPU's plane and its column opens the tuning, the GPU's the GPU settings, and in Integrated the card's ghost (the beam's hologram) does --
//           each only while it is drawn (PopupLayout.holoIntentAt).
//   swipe   over the CPU's or the GPU's zone (`regions`, PopupLayout.zoneRegions).
// =============================================================================
BoardInput {
    id: root

    property var scene: null                  // the SiliconScene (geo, cam, and the frames of its moving parts)
    regions: ({ cpu: [], gpu: [] })
    pickReady: root.scene !== null

    function _frames() {
        const sc = root.scene;
        return {
            pkgLift: sc.pkgLift,
            pkgTurn: sc.turnRad(sc.pkgQuarter),
            // a dissolved card is gone from the picture, not from its place: picked SEATED (lift 0), where it sits in every
            // other mode. (Lifted out of reach, it would leave the thin slot and the latch as the whole region in
            // Integrated: smaller and more scattered than in any other mode.)
            cardLift: sc.cardDissolve > 0.5 ? 0 : sc.cardLift,
            plugIn: sc.plugIn,
            hdmiIn: sc.hdmiIn,
            lever: sc.lever
        };
    }
    // how much of each hologram is drawn now: the zone's power (a zone without its daemon, and the power-on before it reaches it, draw none), the GPU's plane
    // leaves with the card (Integrated: the beam's ghost of the card is what is drawn)
    function _holoPresence() {
        const sc = root.scene;
        return { cpu: sc.cpuPower, gpu: sc.gpuPower * (1 - sc.beam) * (1 - sc.cardDissolve), beam: sc.power * sc.beam };
    }

    pickPart: (x, y) => Cam.pick(root.scene.geo, root.scene.cam, x, y, root._frames())
    intentFor: (part, x, y) => {
        const sc = root.scene;
        const i = Layout.intentOf(sc.geo, part);
        return i !== "" ? i : Layout.holoIntentAt(sc.geo, sc.cam, x, y, root._holoPresence());
    }
    anchorFor: intent => Layout.partAnchor(root.scene.geo, root.scene.cam, intent)
    zoneFor: (x, y) => Layout.zoneAt(root.regions, x, y)
}
