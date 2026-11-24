pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components"
import "../gooey"

// =============================================================================
// ReelBarModule.qml -- an IconReel mounted in a gooey bar.
//
// This is the module: the ring, its cell in the bar, and the rule that hangs
// the rest of it out of the bar in thePopup. It is NOT a drop-in for thePopup
// the way a normal module's content is -- the reel is half in the bar and half
// in the popup, and it is the join between them that the whole design is
// about. So the module owns both ends:
//
//   the bar cell   an IconReelView over a in [0, barCell], in the bar's own
//                  rotated frame, glyphs counter-rotated to stay upright
//   the strip      an IconReelView over a from barCell outward, handed to the
//                  engine as a content Component and loaded while this module
//                  owns the reel slot
//
// The strip is the engine's REEL SLOT (GooeyEngine: THE REEL SLOT), a body of its own beside
// thePopup: hovering a reel never closes or moves the popup that is out. The tray's strip uses the
// same slot (WindowTrayOwner): from a reel's cell to the title the strip travels, as between reels. The engine draws
// everything between the cell and the strip: the curve that grows out of the bar's edge, the
// half-round far end (the strip is `thickness` wide and the engine's maxR is half of that, so
// the end IS a half circle), and the strip travelling along the bar when the pointer moves to
// another reel's cell.
//
// The pointer opens it. Leaving closes it, after a grace, because the pointer
// crosses from the bar's cell into the popup through a frame in which neither
// of them has it.
//
// It knows nothing about what an item DOES: `activated` goes to the host.
// =============================================================================
Item {
    id: mod

    // ---- The bar it is mounted in ----
    property var engine: null              // GooeyEngine
    property GooeyBar bar: null            // the GooeyBar this sits in
    property string barId: ""
    // Unique per module; the engine keys thePopup's ownership on it.
    property string ownerId: ""

    // ---- The ring ----
    property alias items: reelState.items
    property alias leftClickActivates: reelState.leftClickActivates
    // Firing the selected item throws a radial burst of sparks (the power reel); the idle reel's selected icon IS the mode in force, so
    // its reel says false (the sparks a turn throws stay).
    property alias burstOnActivate: reelState.burstOnActivate
    // The items' flourishes (ReelFlourishes), or null. The selected item's plays when the pointer arrives on the bar's cell (the user's
    // rule for every glyph flourish: hover shows it, without firing anything), every other item's when the pointer moves onto it in
    // the open strip (it says the icon can be clicked: feedback/reel.md "Flourish on hover"), and an item plays as the user turns it
    // INTO the cell (a scroll, a swipe, a click on the strip: ReelFlourishes.arrive). None of these fires anything: only `activated` does.
    property alias flourishes: reelState.flourishes
    // Typed, and owned here rather than aliased through the ring: the
    // module reads the popup's own timings off it, and a bar hands the
    // same one to every reel on it.
    // (No numbers of its own: the shell hands every reel its ONE style and never reads this one, so a value kept here would be a mockup's alone --
    // a swipe feel tuned here would never reach the shell.)
    property IconReelStyle style: IconReelStyle {
    }
    readonly property alias reel: reelState
    // The cell in the bar, as an item: what the window's input region is while the session is locked (ShellScreen).
    readonly property Item cellItem: barCell

    // Holds it open without the pointer, for a render or a still.
    property bool pinnedOpen: false
    // Shut to the pointer: it opens for nothing and the strip it has out goes (the power reel while the session is locked --
    // the lock's popup takes the place the reel had been translated into, and the idle reel stays the one thing that answers).
    property bool blocked: false
    onBlockedChanged: {
        if (!mod.blocked)
            return;
        openTimer.stop();
        mod.closePopup();
    }

    // ---- Held by something else (the idle reel while the auto layer holds the mode: ReelFollow) ----
    // The selected icon keeps its colour while the auto layer holds the mode (IconReel.autoHeld).
    property alias autoHeld: reelState.autoHeld
    // The lowest item plain input may go to ("" none; IdleService.floorMode): under it the ring refuses with a shake. Ctrl passes it.
    property alias floorId: reelState.floorId
    signal refusedStep(int index, var item)
    // Out by itself (ReelFollow's cinematic travel): the strip opens as if hovered, and closes when it lets go and nothing else wants it.
    property bool autoOpen: false
    // The pointer is on a side popup the strip has out (the idle reel's reason, ReelReason): the strip stays, as it does under the
    // pointer, and the side popup with it.
    property bool sideHovered: false
    // THE KEYS FOR CTRL. Wayland tells a client the keyboard's modifiers only on the surface that HAS the keyboard, and the bar's
    // window has none: a Ctrl+click on it reads no Ctrl (measured in the nested Hyprland, tools/dev/reel_film.sh TRACE=1). So while
    // the ring is held, a pointer that MOVED onto the cell asks for the keyboard (`wantsKeys`: the host's HyprlandFocusGrab on the
    // bar's window), and keeps it while it stays on the cell or the strip; the keys go back when it leaves both. Never for a pointer
    // that only rests where the strip came out by itself (a video's viewer keeps the keys).
    readonly property bool wantsKeys: reelState.floorActive && (keysArm.armed || mod._keysHeld)
    // armed once, held across the cell and the strip (the arm's own hover is the cell's only)
    property bool _keysHeld: false
    HoverArm {
        id: keysArm
        target: barCell
        active: reelState.floorActive
        releaseOnOutsidePress: false
    }
    Connections {
        target: keysArm
        function onArmedChanged(): void {
            if (keysArm.armed)
                mod._keysHeld = true;
        }
    }
    onPopupHoveredChanged: mod._keysLeave()
    Connections {
        target: barCell
        function onHoveredChanged(): void {
            mod._keysLeave();
        }
    }
    Connections {
        target: reelState
        function onFloorActiveChanged(): void {
            if (!reelState.floorActive)
                mod._keysHeld = false;
        }
    }
    function _keysLeave(): void {
        if (!barCell.hovered && !mod.popupHovered)
            mod._keysHeld = false;
    }

    signal activated(int index, var item)
    signal selectionChanged(int index, var item)

    width: mod.style.thickness
    // Its bar's own thickness: the cell fills the bar across. In THIS module's units: a bar drawn `barRatio` times larger (the shell's
    // `scale.bar`; GooeyEngine: THE RATIOS) lays its modules out in bar units, so its thickness is `barRatio` times the height here.
    height: (mod.bar ? mod.bar.thickness : mod.engine ? mod.engine.thickness : mod.style.barCell) / (mod.engine && mod.engine.barRatio > 0 ? mod.engine.barRatio : 1)

    // The bar carries its edge as a rotation, and every child of it turns
    // with the bar. The glyphs undo exactly that much.
    readonly property real barRotation: mod.bar ? mod.bar.rotation : 0
    readonly property string barEdge: mod.bar ? mod.bar.edge : "top"

    IconReel {
        id: reelState
        style: mod.style
        // Only the bar's cell can arm an icon, so its hover is the ring's.
        pointerOnBarCell: barCell.hovered
        // The selected icon wears its colour for as long as this reel's strip is out, wherever the pointer is.
        open: mod.reelOpen
        onActivated: (index, item) => mod.activated(index, item)
        onRefusedStep: (index, item) => mod.refusedStep(index, item)
        onSelectionChanged: (index, item) => {
            mod.selectionChanged(index, item);
            // ONE TURN LATER, and only the icon the ring is on then: a turn that commits several steps at once (a fast flick's momentum)
            // passes the ones between in a blur, and only the one it lands on plays (Qt.callLater runs a function asked twice once)
            if (reelState.flourishes)
                Qt.callLater(mod._arrive);
        }
    }

    // The user turned an icon into the cell: it plays as it arrives (a demo, like a hover: nothing fires).
    function _arrive(): void {
        if (reelState.flourishes && reelState.selectedItem)
            reelState.flourishes.arrive(reelState.selectedItem.id);
    }

    // The flourish set's registry names (FlourishClock): this module is where its clocks live (which screen), and only the item the ring is
    // turned to is on show -- the OLED care's random flourishes play only what is in the bar's cell.
    Binding {
        target: reelState.flourishes
        property: "host"
        value: mod
        when: !!reelState.flourishes
    }
    Binding {
        target: reelState.flourishes
        property: "selectedId"
        value: reelState.selectedItem ? reelState.selectedItem.id : ""
        when: !!reelState.flourishes
    }

    // The pointer arrived on the cell (an entry and a motion, IconReelView.pointerArrived): the selected icon plays.
    Connections {
        target: barCell
        function onPointerArrived(): void {
            if (reelState.flourishes && reelState.selectedItem)
                reelState.flourishes.hover(reelState.selectedItem.id);
        }
    }

    // ---- The cell in the bar --------------------------------------------
    // Inside a GooeyBar the local frame is always top-like -- x along the
    // bar, y inward -- whatever edge the bar is on, because the bar item
    // itself carries the rotation. So this view is always "top".
    IconReelView {
        id: barCell
        objectName: "reelBarCell"
        x: 0
        y: 0
        width: mod.width
        // A pixel past the bar's inner edge, into the popup: see seamOverlap.
        height: mod.height + mod.style.seamOverlap
        reel: reelState
        edge: "top"
        aFrom: 0
        glyphRotation: -mod.barRotation
        // The bar's frame is rotated; a wheel event's deltas are not.
        screenVertical: mod.barEdge === "top" || mod.barEdge === "bottom"
        fogNear: mod.style.outerFogLength
        fogFar: 0
    }

    // ---- The rest of the ring, in thePopup -------------------------------
    property IconReelView popupView: null
    readonly property bool popupHovered: mod.popupView ? mod.popupView.hovered : false

    Component {
        id: popupComp

        IconReelView {
            id: pv
            // The strip CONTINUES the bar's cell: the ring runs straight
            // through from the cell into it, so the engine rests it on this
            // module's centre and nowhere else (GooeyEngine: THE WALL and THE
            // BAR'S END would move it off the cell beside a side bar or at the
            // bar's end).
            readonly property bool continuesBarCell: true
            reel: reelState
            edge: mod.barEdge
            aFrom: mod.style.barCell
            fogNear: 0
            fogFar: mod.style.fogLength
            fogClearance: mod.style.fogClearance
            // the strip continues the bar's cell, so it is laid out under the BAR's ratio (GooeyBody.ratio): its textures are made at that scale
            renderScale: mod.engine ? mod.engine.barRenderScale : 1
            maskInset: mod.style.maskInset
            // The strip's corner as it is at this instant, not at rest.
            cutRadius: mod.engine ? mod.engine.reelRadius : 0
            // It may hang over a popup: it paints its own ground
            opaque: true
                // The popup's own end radius: the engine's, capped at half the
            // strip, which at the default 40 / 20 is the half circle.
            farRadius: mod.engine
                ? Math.min(mod.engine.maxR, mod.style.thickness / 2) : 0
            // Only one view of a ring draws its sparks. This one: it is where
            // the ring is, and where there is room for them to travel.
            sparks: true
            // the pointer moved onto an icon of the strip: it plays its hover (the selected one is the bar cell's, which has its own)
            onPointerOnIcon: index => {
                if (reelState.flourishes && index !== reelState.selectedIndex && !reelState.traveling && reelState.items[index])
                    reelState.flourishes.hover(reelState.items[index].id);
            }
            Component.onCompleted: mod.popupView = pv
            Component.onDestruction: {
                if (mod.popupView === pv)
                    mod.popupView = null;
            }
        }
    }

    // ---- Opening ---------------------------------------------------------
    readonly property bool wantOpen: mod.pinnedOpen || mod.autoOpen || barCell.hovered
        || mod.popupHovered || mod.sideHovered || reelState.gestureLive

    onWantOpenChanged: {
        if (mod.wantOpen) {
            closeTimer.stop();
            openTimer.restart();
        } else {
            openTimer.stop();
            closeTimer.restart();
        }
    }

    Timer {
        id: openTimer
        interval: mod.style.openDelayMs
        onTriggered: mod.openPopup()
    }
    Timer {
        id: closeTimer
        interval: mod.style.closeGraceMs
        onTriggered: mod.closePopup()
    }

    // This reel's strip is out: the engine's reel slot is up and it is this module's (a binding; `ownsPopup()` is the same fact for a call).
    readonly property bool reelOpen: !!mod.engine && mod.engine.reelOpen && mod.engine.reelOwnerId === mod.ownerId

    // The engine's reel slot is someone else's: another reel's strip or the tray's (GooeyEngine: THE REEL SLOT), out or on its way in.
    // A strip that comes out by itself waits for it to have gone (ReelFollow): it never interrupts one, closing or not.
    function slotTaken(): bool {
        return !!mod.engine && mod.engine.reelPhase !== "closed" && mod.engine.reelOwnerId !== mod.ownerId;
    }
    // May the strip come out by itself: nothing blocks it, and the engine's reel slot is free or already this reel's (another
    // reel's strip under the user's pointer, or the tray's, is never taken away).
    function canAutoOpen(): bool {
        return !!mod.engine && !!mod.bar && !mod.blocked && !mod.slotTaken();
    }

    // Where a side popup of the strip sits level with the strip's `slot` (cells from the bar's cell: 1 is the first icon in the strip),
    // in the strip content's own coordinates, on its END face (the engine's side "end": right of a strip that hangs down, below one that
    // runs sideways) -- the point GooeyEngine.openChild takes as `anchor`. From the style alone where the strip's view is not built yet.
    function sideAnchor(slot: int): point {
        const st = mod.style;
        const vertical = mod.barEdge === "top" || mod.barEdge === "bottom";
        const pv = mod.popupView;
        const len = pv ? (vertical ? pv.height : pv.width) : reelState.popupLength;
        const across = pv ? (vertical ? pv.width : pv.height) : st.thickness;
        // the slot's centre from the strip's near edge (the strip begins where the bar's cell ends)
        const a = st.barCell / 2 + slot * st.cellPitch - st.barCell;
        const along = mod.barEdge === "top" || mod.barEdge === "left" ? a : len - a;
        return vertical ? Qt.point(across, along) : Qt.point(along, across);
    }

    function ownsPopup() {
        return !!mod.engine && mod.engine.reelOpen
            && mod.engine.reelOwnerId === mod.ownerId;
    }

    function openPopup() {
        if (!mod.engine || !mod.bar || mod.blocked || mod.ownsPopup())
            return;
        // Where this module sits along the bar. Read at the moment of
        // opening rather than bound: a mapToItem in a binding does not track
        // the layout that moved it.
        const centre = mod.mapToItem(mod.bar, mod.width / 2, 0).x;
        mod.engine.openReel(mod.ownerId, mod.barId, centre,
            mod.style.thickness, reelState.popupLength, popupComp,
            mod.style.popupWidthFrom);
    }

    function closePopup() {
        if (!mod.engine || !mod.ownsPopup())
            return;
        mod.engine.closeReel();
    }
}
