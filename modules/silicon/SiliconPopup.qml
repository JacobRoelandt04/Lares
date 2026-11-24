pragma ComponentBehavior: Bound

import QtQuick

import "../common/board"
import "../common/components"
import "scene"
import "secondary"
import "popup"
import "data/SiliconFormat.js" as Fmt
import "data/SiliconModel.js" as Model
import "scene/Figures.js" as Fig
import "popup/PopupLayout.js" as Layout

// =============================================================================
// SiliconPopup.qml -- silicon's popup content (CONTRACT.md section 9): the isometric board, its overlays
// and its input, the director that moves it, and the engine's secondary (SiliconSecondary).
//
// ONE LAYOUT, 760 wide, as tall as the board (`scene.naturalHeight`), no views. From the bottom up:
//
//   SiliconScene     the board: the CPU package, the card in its slot, the pack, the DIP switch, the plug -- and the
//                    pack's and the memory's figures, printed on it (seven-segment displays, board text)
//   MotionDirector   what the machine is doing -> the scene's state, with the films' curves
//   SiliconClock     one 16 ms timer: scene time and the phases, only while shown; a theme crossfade holds it
//                    still while its picture is opaque and lets it go as the picture fades
//   SceneInput       clicks by arithmetic (IsoCamera.pick), the hand cursor, the two-finger swipe
//   two ZoneBlocks   the caption plates, flat in screen space, each hugging the top edge of ITS hologram's plane:
//                    CPU ‹ Balanced › and its tail, GPU ‹ Hybrid ›, its figures (only while its card is awake, in
//                    fixed slots) and its tail. A plate is as tall as its rows are now and stands on its foot, so a
//                    row that comes (a tail, the GPU's figures) pushes the head up, never down into the hologram.
//                    The CPU's three figures and the battery's are the board's (below).
//   ErrorTag         a battery error, beside the DIP switch for as long as it stands
//
// THE SECONDARY. ONE slot, four things that can stand in it, the first of these that is due winning: the busy-dGPU
// QUESTION ("confirm"), the RESTART card ("mux"), then the PANEL the user opened ("tuning", "gpu") -- which is still
// there, under, when the dialog over it has been answered. The two dialogs are secondaries (words, buttons and rules in
// secondary/MuxPanel, ConfirmPanel) and open at the GPU part (the panels, where the part that asked sits). WHERE the
// secondary opens -- `secondarySide`, "far" | "start" | "end" -- is one setting for all four (silicon.jsonc
// look.secondarySide; the mockup's panel). (The keep prompt after a dGPU-only restart is not here: it is a toast,
// MuxKeepPrompt, put up by SiliconMuxWatcher with no popup.)
//
// WHAT A CLICK OR A SWIPE DOES
//   the package or the CPU's hologram -> openSecondary("tuning")      the card or its slot, the GPU's hologram and, in
//                                    Integrated, the card's ghost -> openSecondary("gpu")
//   the DIP switch         -> vm.setChargeLimit(!limitOn)
//   the watts display      while the pointer is over it, the raw figure (what the pack reports, not the figure with
//                          this popup's own draw taken off) -- at once, and back on leave; a tip says what it is
//   a horizontal swipe, or an arrow, over the CPU zone -> vm.stepProfile(+-1); over the GPU zone ->
//   vm.stepGpuMode(+-1). Arrows exist while the pointer is in the zone and only where there is a step.
//   A GPU step that would block the dGPU while apps use it asks first (the "confirm" secondary).
//   Pointer activity of any kind -> vm.touch() (the idle ladder's wake).
//
// THE BOARD'S FIGURES. `Model.buildFigures` turns the battery's and the memory's facts into the display
// strings the scene prints (the grammar, the cell counts and the contract are in SiliconFormat.js), and
// `Figures.cpuFigures` the CPU's clock, usage and temperature into its three displays'.
// They are rebuilt with every poll and handed to the scene only when one of the strings moved: a `var` property takes
// every new object for a change, and a scene that redraws for one would wake a halted clock for nothing. The time since
// the pack was last full follows ONE BoundaryClock, so it advances on the boundary it shows and after a suspend (a pack
// that IS full reads 0 and has no boundary: `Model.sinceFull`). The time display always has its TIME LEFT label: with
// nothing to count it reads --:-- instead of going dark.
//
// THE WAY OUT OF dGPU-ONLY. While the panel is wired to the NVIDIA card the arrows offer all four steps; a
// step left queues one MUX request for Hybrid and remembers the mode wanted after the restart, the target keeps moving
// under it (Hybrid -> Smart -> Integrated), and stepping back to dGPU-only cancels it. Nothing about a restart hides
// behind a click nobody knows to make: once a step that queued or re-aimed a MUX request has SETTLED (the facts say
// what the step asked for, and have said it for 300 ms) the restart card (the "mux" secondary) opens by itself; "Later"
// dismisses it and a click on the card or its slot opens it again. The mode wanted after the restart is the LAST step
// asked for, and the card names it live.
//
// THE ENGINE'S CONTENT CONTRACT (bar_structure.md): `secondaryComponent`, `secondaryOpen`,
// `secondaryAnchor` (at the part that was clicked; the dialogs at the GPU part), `secondarySide` (the user's setting, "far"
// by default: the secondary opens on the popup's far face, never over it), `secondaryOverhang`, `secondaryInset`,
// `secondaryKey` ("tuning" | "gpu" | "mux" | "confirm"); and the swipe hold
// (`swipeGestureActive`, `gestureHoldWidth/Height`, `gestureWheel(ev)`) although this popup never
// resizes: a swipe that carries the pointer out of the popup is still the swipe's.
//
// THE CLOCK AND THE IDLE LADDER. The clock follows the view model's idle ladder (alive 16 ms, calm 33 ms, halt parks it on a still
// picture: SiliconClock); pointer activity of any kind, and any change of a fact the scene shows with a
// motion (the director's `watchKey`) or of a battery event, touches the ladder, so a halted popup wakes for
// what it would otherwise not play. The GPU plate and the board's figures (the CPU's three included) read the view
// model directly, never the director's tick: they keep refreshing while the scene is halted, a change costing its
// own few frames. With `entranceEnabled` the board powers on once
// the popup is mostly out (`openProgress` >= 0.6); a zone without its daemon never powers on; while a MUX
// request waits for its restart the GPU hologram breathes (all in the director and the scene).
//
// THE SCALE (DeploymentNotes.md 136): the popup is drawn `sizeScale` times larger than its popup ratio (SiliconBarOwner.sizeScale, the
// owner hands it down) -- it derives from PopupStage, which puts every child below into a ScaleRoot of that factor, so all of it is laid out in the design
// px written here (760 wide) and the root is in the engine's content units. Two kinds of numbers cross: what is TOLD to the engine in item px is
// multiplied by `stageScale` (`secondaryAnchor`) and what the engine hands back is divided (`gestureWheel`). The scene is laid out at the size the popup
// ASKS for (designWidth x the scene's natural height), never at the box's: see the scene's comment.
// =============================================================================
PopupStage {
    id: root

    // ---- in ----
    property var vm: null                 // a SiliconService or a SiliconMock (identical members)
    property int family: 0                // 0 Material, 1 Blueprint
    property real renderScale: 1          // the host's scale (the layers' texture size)
    property bool shown: true             // opening / open and on screen: the clock runs only then
    property string fontFamily: "Inter"   // the user dresses mockups in Audiowide
    // The power-on entrance: the host's popup opening, 0..1 (the owner binds it to its engine's
    // popup); a harness leaves `entranceEnabled` false and the board is simply on.
    property real openProgress: 1
    property bool entranceEnabled: false
    // THE ENGINE'S PARKED CONTENT (GooeyEngine: THE PARKED CONTENT). `parked` is written by the engine, never by this content:
    // true while it is held hidden -- built ahead of the click on a hover, kept after its popup closed, or drawn once by the prewarm. Then it runs nothing
    // and asks nothing: the clock and the sounds follow `_live` (shown and not parked), and the service is not touched (`_touch`).
    // `recycle()` puts it back to what a new one starts as, which is what lets the engine keep it after a close.
    property bool parked: false
    // Drawn ONCE, for its pipelines, by the engine's prewarm (ShellFrame.prewarmEntries): the board simply ON and the card's live patch shown. A board that
    // has not played its entrance yet is dark, and a dark board draws no hologram, no spark and no lit figure -- what the first real open would compile
    // through the engine's clip layer, all through its power-on, is compiled here instead. Never set on a content that is shown.
    property bool prewarm: false
    // The board is a theme island: it keeps moving through a light / dark switch (SiliconIsland). Off: held still behind the picture.
    property bool islandEnabled: true
    readonly property bool _live: root.shown && !root.parked

    // ---- layout knobs ----
    property real margin: 12              // the popup's padding, on every side (a plate never rises above it)
    property real plateGap: 4             // a plate's text foot stands this far above the top edge of its hologram's plane (px)
    property real cpuPlateWidth: 240
    property real gpuPlateWidth: 300
    // where the battery error's tag hangs from the DIP switch's near right corner (item px, to its top-left)
    property real errorTagDx: 6
    property real errorTagDy: 22
    property real errorTagMaxWidth: 160
    property int headSize: 16
    property int bodySize: 12
    property int figureSize: 11

    // one layout, no views: as tall as the board needs at this width (the scene's own answer, which does not read its size). The sizes are the DESIGN
    // ones, in the px every child below is laid out in; PopupStage makes them the engine's (x `sizeScale`: SiliconBarOwner.sizeScale) and puts the children
    // in a stage drawn that much larger.
    designWidth: 760
    designHeight: boardScene.naturalHeight

    // what an owner or the mockup reaches
    readonly property alias sceneItem: boardScene
    // The scene's clock (a probe reads its `gate` and `crossfadeHold`).
    readonly property alias clockItem: sceneClock
    readonly property alias director: motion
    readonly property alias clock: sceneClock
    readonly property alias input: sceneInput
    readonly property alias sounds: sounds
    readonly property alias cpuBlock: cpuPlate
    readonly property alias gpuBlock: gpuPlate
    readonly property alias gpuReadouts: gpuReadouts
    // the strings the scene is handed right now (the hover's swap included), and whether the watts tip is open
    readonly property var figures: root._shownFigures

    // ---- the engine's secondary (bar_structure.md "The secondary popup"; StocksPopup is the model) ----
    // Where every secondary opens (the panels and the three dialogs alike): the engine's "far" (away from the bar), "start" or "end"
    // (along it). The user's setting -- silicon.jsonc look.secondarySide, SiliconBarOwner hands it down, the mockup's panel overrides
    // it -- because it depends on how the shell is finally assembled.
    property string secondarySide: "far"
    // the panel the user opened ("tuning" | "gpu", "" none) and where it hangs; a dialog over it does not close it
    property string _panelKey: ""
    property point _panelAnchor: Qt.point(0, 0)
    // The contract's `secondaryKey`, `secondaryOpen`, `secondaryAnchor`, `secondaryAnchorAt` and `secondaryWidthFrom`, WRITTEN rather than bound.
    // The engine reads the whole contract in the handler of whichever member changed first, and a binding that has not followed yet answers
    // its old value: the question would open with the anchor and the length of the moment before (centred on the GPU part, half its length) and
    // then slide into the corner -- the swoop; and a close that re-aimed the child on its way in would slide it back out of the corner. So one function
    // decides all five from the facts themselves (never from a binding that is downstream of what just changed), at once, and writes the
    // aim first and the key last when it opens (first when it closes: a close must not swap the key to nothing under a child still out).
    // It is called from every fact that decides one of them: the handlers below.
    property var secondaryKey: null
    property bool secondaryOpen: false
    property point secondaryAnchor: Qt.point(0, 0)
    property real secondaryAnchorAt: 0.5
    property real secondaryWidthFrom: 0.5
    // The dialog that is due now, by precedence ("" none): read from the raw facts (the question, the restart card), never from a binding downstream of them.
    function _dialogNow() {
        return root._confirmOpen && root.shown ? "confirm" : (root._muxOpen && root.shown ? "mux" : "");
    }
    function _publishSecondary() {
        const dk = root._dialogNow();
        const due = dk !== "" ? dk : (root._panelKey !== "" ? root._panelKey : null);
        if (due === null) {
            root.secondaryOpen = false;
            root.secondaryKey = null;
            return;                       // (the aim stays what it was: it is the closing child's)
        }
        // A dialog hangs at the GPU part (the card the question is about, wherever it was asked from), a panel at the part that asked; a dialog
        // whose nearest end of the popup lies against a perpendicular bar is laid against that end instead -- see `flushEnds`.
        const g = root._gpuPart;
        const e = root.flushEnds || {};
        const corner = dk !== "" && root.secondarySide === "far"
            ? (g[0] >= root.designWidth / 2 ? (e.end === true ? "end" : "") : (e.start === true ? "start" : "")) : "";
        if (corner !== "") {
            root.secondaryAnchor = Qt.point(corner === "end" ? root.implicitWidth : 0, 0);
            root.secondaryAnchorAt = corner === "end" ? 1 : 0;
            root.secondaryWidthFrom = 0;
        } else {
            const p = dk !== "" ? Qt.point(Math.round(g[0]), Math.round(g[1])) : root._panelAnchor;
            // (in the CONTENT's units, which the engine reads: the design px of the stage, times its scale)
            root.secondaryAnchor = Qt.point(p.x * root.stageScale, p.y * root.stageScale);
            root.secondaryAnchorAt = 0.5;
            root.secondaryWidthFrom = root.defaultWidthFrom;
        }
        root.secondaryKey = due;
        root.secondaryOpen = true;
    }
    on_ConfirmOpenChanged: root._publishSecondary()
    on_MuxOpenChanged: root._publishSecondary()
    on_PanelKeyChanged: root._publishSecondary()
    on_PanelAnchorChanged: root._publishSecondary()
    onFlushEndsChanged: root._publishSecondary()
    onSecondarySideChanged: root._publishSecondary()
    onImplicitWidthChanged: root._publishSecondary()
    on_GpuPartChanged: root._publishSecondary()
    // The dialogs hang at the GPU part
    readonly property var _gpuPart: Layout.partAnchor(boardScene.geo, boardScene.cam, "gpu")
    property bool secondaryOverhang: false
    property real secondaryInset: 0
    // THE DIALOGS' CORNER. The popup borders two gooey entities (the silicon popup and a perpendicular slim bar), so a dialog is a 2D-type popup
    // that originates from the corner they make. The owner says which ends of the popup lie against a
    // perpendicular bar's face (`flushEnds`, { start, end }). A dialog hangs at the GPU part; when the end NEAREST that part is such an end, the
    // dialog is laid against that end instead of centred on the part -- anchored at the end (secondaryAnchorAt 0 | 1, the anchor at the popup's
    // edge, which is the bar's face) and opened from a point there (secondaryWidthFrom 0), so it grows in 2D out of the inner corner of bar and
    // popup, part of both from its first frame, and ends flush with the face (a box a few px off a face leaves a sliver of wallpaper). Only on the
    // "far" side: a secondary beside the popup is not in that corner. The panels (tuning, gpu) hang where they were asked.
    property var flushEnds: ({ start: false, end: false })
    // the engine's own default share of its length a child opens at (the owner hands it down; a content that declares secondaryWidthFrom must
    // always give a number)
    property real defaultWidthFrom: 0.5
    property Component secondaryComponent: Component {
        SiliconSecondary {
            vm: root.vm
            kind: root.secondaryKey !== null ? root.secondaryKey : "tuning"
            family: root.family
            renderScale: root.renderScale
            fontFamily: root.fontFamily
            confirmStep: root._confirmStep
            confirmHolders: root._confirmHolders
            onConfirmed: root._confirm()
            onCancelled: root._confirmOpen = false
            onMuxDismissed: root._muxOpen = false
        }
    }
    // `at` is where the part that asked sits (item px); without it, the kind's own part. The panels only: the dialogs open
    // by themselves, when the facts say they are due.
    function openSecondary(kind, at) {
        if (kind !== "tuning" && kind !== "gpu")
            return;
        const a = at !== undefined ? at : root._partPoint(kind);
        root._panelAnchor = Qt.point(a.x !== undefined ? a.x : a[0], a.y !== undefined ? a.y : a[1]);
        root._panelKey = kind;
    }
    // Whatever the user can put away: the panel, the question, the restart card.
    function closeSecondary() {
        root._panelKey = "";
        root._confirmOpen = false;
        root._muxOpen = false;
    }
    // Escape's step back (GooeyEngine.stepBack, asked only under shell.jsonc `"escape": "detail"`): the detail goes; true when one was open
    function stepBack(): bool {
        const was = root.secondaryOpen;
        root.closeSecondary();
        return was;
    }
    function _partPoint(intent) {
        return Layout.partAnchor(boardScene.geo, boardScene.cam, intent);
    }

    // The engine keeps the content parked after its popup closed and hands it to the next open (or the travel back): what a NEW content starts as. The secondary
    // goes (a panel, the question, the restart card), the entrance starts from dark again, the pointer's gesture and hover are over, the clock's ladder is awake.
    // The scene goes back to the facts and to dark (`motion.opening()` starts the entrance from dark, `motion.snap()` writes it), as `Component.onCompleted` does.
    function recycle() {
        root.closeSecondary();
        root._muxAsk = -1;
        root._entered = false;
        sceneInput.reset();
        sceneClock.reset();
        motion.opening();
        motion.snap();
        root._clockSnap();
    }

    // ---- the swipe hold (the engine reads these off the content) ----
    readonly property bool swipeGestureActive: sceneInput.gestureActive
    readonly property real gestureHoldWidth: root.width
    readonly property real gestureHoldHeight: root.height
    // The engine's x / y are in the content's units; the stage's input reads design px.
    function gestureWheel(ev) {
        return sceneInput.gestureWheel(ev ? Object.assign({}, ev, { x: ev.x / root.stageScale, y: ev.y / root.stageScale }) : ev);
    }

    // ======================================================================================
    // The scene, its director and its clock
    // ======================================================================================
    // LAID OUT AT THE SIZE THE POPUP ASKED FOR, never at the box's while it opens or closes. The camera is fitted by the WIDTH (`naturalHeight` is a
    // function of it) and the engine gives the content the box it is drawing: a popup that grows in width (it comes out of a 425 px cell to 760) and
    // lands with the easing's overshoot (762 for a frame) would ask for a different height at every one of those widths -- 509, 508, 507, 506 -- and the
    // engine answers every ask by aiming the box again from where it is, which RESTARTS THE OPEN'S CLOCK (GooeyEngine._contentResized): the box
    // chases its own target, 750-880 ms for an open that takes every other popup 400-450 (DeploymentNotes.md 53), and the cached board is
    // rendered AGAIN at each new size. At the asked size the question is the same on
    // every frame: one aim, one clock, one render of the board, and the growing box reveals it (the body clips) as it reveals every other popup.
    // A host that wants the board larger does not give the popup more room: it scales the popup (`sizeScale`, PopupStage), and the layers are made at the
    // scale it is drawn at (`renderScale` x `stageScale`).
    SiliconScene {
        id: boardScene
        width: root.designWidth
        height: boardScene.naturalHeight
        family: root.family
        renderScale: root.renderScale * root.stageScale
        figures: root._shownFigures
        memory: root._memory
        forceCardPatch: root.prewarm
    }
    // The board through a theme switch: cut out of the crossfade's picture, a ghost in the old palette fading over it (SiliconIsland). Declared
    // right after the scene so it is over it and under everything the popup lays on the board. Armed only for a board that is moving and laid out.
    SiliconIsland {
        id: boardIsland
        scene: boardScene
        live: root.islandEnabled && root._live && root.openProgress >= 0.999 && sceneClock.running && !sceneClock.parked && root.designWidth > 0
    }
    MotionDirector {
        id: motion
        vm: root.vm
        scene: boardScene
        entranceEnabled: root.entranceEnabled && !root.prewarm
    }
    SiliconClock {
        id: sceneClock
        scene: boardScene
        director: motion
        islandArmed: boardIsland.armed
        shown: root._live
        idleState: root.vm ? root.vm.idleState : "alive"
    }
    // Opening jumps to the facts: a popup opened on Performance does not play a lift from whatever the
    // scene last showed. (The first frame of a harness that never `shown`s it is snapped here too.)
    // A popup coming up wakes the ladder itself: `popupOpen` is the OR of the screens, so a close on one screen and an open on another
    // (or a kept content handed on) is no edge of it, and a clock started on a halted ladder parks about a second after the open.
    on_LiveChanged: {
        if (root._live && root.vm)
            root.vm.touch();
    }
    onShownChanged: {
        if (root.shown) {
            motion.opening();
            motion.snap();
        } else {
            root._confirmOpen = false;
            root._muxOpen = false;
            root._muxAsk = -1;
        }
        root._syncEntrance();
        root._publishSecondary();
    }
    onVmChanged: {
        motion.snap();
        root._clockSnap();
    }
    Component.onCompleted: {
        root._publishSecondary();
        motion.snap();
        root._syncEntrance();
        root._clockSnap();
    }

    // ---- the board's figures ----
    // Every display changes on a READING, never between two: the since-full display counts from the reading's own time,
    // so it advances on the first reading after its boundary; the figures are one fact like the others (a poll that says the same is
    // no change).
    readonly property string _figuresKey: JSON.stringify(root.vm ? Model.buildFigures(root.vm.battery, root.vm.memory, root.vm.readingAtMs) : null)
    readonly property var _figures: JSON.parse(root._figuresKey)
    readonly property string _memoryKey: JSON.stringify(root.vm ? Model.buildMemory(root.vm.memory) : null)
    readonly property var _memory: JSON.parse(root._memoryKey)
    // the CPU's clock, usage and temperature: the three strings of its displays, a fact like the others.
    // The CLOCK display changes at most once a second -- a frequency that moves at every reading is a flicker of digits nobody can read --
    // and on a READING, in the frame of the load and temperature beside it: the shown clock (`_clockHeld`) takes the reading's value on
    // readings whose serial is a multiple of K = readings in a second (4 in the mock's 250 ms tick, 1 in the service's alive beat and
    // every slower one) and keeps what it shows on the others. The first reading replaces the dashes at once. `readingSerial` is written
    // last in a build, so by then the facts are the whole reading.
    readonly property var _cpuLive: root.vm ? Fig.cpuFigures(root.vm.cpu) : null
    readonly property string _clockLive: root._cpuLive ? root._cpuLive.cpuClock : ""
    property string _clockHeld: ""
    readonly property int _clockEvery: root.vm ? Math.max(1, Math.round(1000 / root.vm.readingMs)) : 1
    function _clockSnap() {
        root._clockHeld = root._clockLive;
    }
    function _clockAsk() {
        if (root._clockHeld === "" || root._clockHeld === Fig.clockText(null) || root.vm.readingSerial % root._clockEvery === 0)
            root._clockSnap();
    }
    Connections {
        target: root.vm
        function onReadingSerialChanged() { root._clockAsk(); }
    }
    readonly property string _cpuFiguresKey: JSON.stringify(root._cpuLive ? Object.assign({}, root._cpuLive, { cpuClock: root._clockHeld !== "" ? root._clockHeld : root._clockLive }) : null)
    readonly property var _cpuFigures: JSON.parse(root._cpuFiguresKey)

    // The watts display shows the measured figure while the pointer is over it: the plate's hover moved onto the board.
    // `hoverPart` is SceneInput's, by arithmetic from the board's own geometry (the display is a part of it).
    readonly property bool _wattsHover: sceneInput.hoverPart === "segWatts"
    readonly property var _shownFigures: root._figures ? Object.assign({}, root._figures, root._cpuFigures, root._wattsHover ? { watts: root._figures.wattsRaw } : {}) : null
    readonly property var _wattsBox: Layout.partBox(boardScene.geo, boardScene.cam, "segWatts")
    readonly property string _wattsTipText: {
        const b = root.vm ? root.vm.battery : null;
        if (!b || b.present !== true)
            return "";
        const real = "Measured " + Fmt.watts(b.wattsReal, { signed: true });
        return b.overheadW >= 0.05 ? real + ". The usual figure leaves out the " + Fmt.watts(b.overheadW) + " this popup itself uses." : real + ".";
    }

    // ---- the entrance: the board powers on once the popup is mostly out ----
    // The owner binds `openProgress` to its engine popup (the body's clock while it opens, then the content's
    // presence). A bare rule would fire inside `engine.open()` with a stale value, and the content is built at
    // phase `closed` with the last run's, so it counts only while `shown`. It reads the properties themselves
    // (a handler runs before a binding that depends on the same property has followed it), and it is a LATCH
    // that lets go only when the popup has gone back (hysteresis: a wobble round 0.6 must not replay it).
    property bool _entered: false
    function _syncEntrance() {
        if (root.entranceEnabled && root.shown && root.openProgress >= 0.6) {
            if (!root._entered) {
                root._entered = true;
                motion.powerOn();
            }
        } else if (!root.shown || root.openProgress < 0.3) {
            root._entered = false;
        }
    }
    onOpenProgressChanged: root._syncEntrance()
    onEntranceEnabledChanged: root._syncEntrance()

    // ======================================================================================
    // The zones: where they are, what the pointer is over, what they can do
    // ======================================================================================
    readonly property var _regions: Layout.zoneRegions(boardScene.geo, boardScene.cam, {
        cpu: { x: cpuPlate.x, y: cpuPlate.y, w: cpuPlate.width, h: cpuPlate.height },
        gpu: { x: gpuPlate.x, y: gpuPlate.y, w: gpuPlate.width, h: gpuPlate.height }
    })
    // The pointer is read by arithmetic from ONE handler on the root: an item stacked over a link takes the
    // link's hover (Qt 6.11), a handler on an ancestor is hovered alongside whatever its children take.
    HoverHandler {
        id: hover
        // Pointer activity over the plates and the cards too, not only over the board, keeps the idle ladder alive.
        // The handler's `point` is re-delivered whenever the scene under a resting pointer changes (every frame
        // of a running clock), so only a pointer that has MOVED counts: a pointer left over the popup is not
        // activity, or the ladder would never go calm.
        property point _last: Qt.point(-1, -1)
        onPointChanged: {
            const p = hover.point.position;
            if (hover.hovered && (p.x !== hover._last.x || p.y !== hover._last.y)) {
                hover._last = p;
                root._touch();
            }
        }
    }
    readonly property string hoverZone: hover.hovered ? Layout.zoneAt(root._regions, hover.point.position.x, hover.point.position.y) : ""

    readonly property var _gpu: root.vm ? root.vm.gpu : null
    readonly property bool canPrevProfile: root.vm !== null && Model.nextProfile(root.vm.profileTarget, -1, root.vm.cpu.profiles) !== null
    readonly property bool canNextProfile: root.vm !== null && Model.nextProfile(root.vm.profileTarget, 1, root.vm.cpu.profiles) !== null
    readonly property bool canPrevGpu: root.vm !== null && Model.stepFrom(root.vm.gpuModeTarget, -1, root.vm.gpu.steps) !== null
    readonly property bool canNextGpu: root.vm !== null && Model.stepFrom(root.vm.gpuModeTarget, 1, root.vm.gpu.steps) !== null

    // ---- the steps (an arrow and a swipe are the same thing) ----
    function stepProfile(dir) {
        return root.vm ? root.vm.stepProfile(dir) : false;
    }
    // The service refuses Integrated and Smart while apps use the dGPU unless it is confirmed; the question
    // is asked HERE, before a refusal would leave a stale error under the caption: "would it be refused, and
    // would a confirmation lift the refusal" is the model's own plan, asked twice.
    function _needsConfirm(step) {
        const vm = root.vm;
        const asked = Model.planGpuMode(step, {}, vm.gpu, vm.gpuModeTarget);
        const sure = Model.planGpuMode(step, { confirmHolders: true }, vm.gpu, vm.gpuModeTarget);
        return asked.action === "refuse" && sure.action !== "refuse";
    }
    readonly property bool _askWhenBusy: !root.vm || !root.vm.config || root.vm.config.gpu.askWhenBusy
    function stepGpu(dir) {
        const vm = root.vm;
        if (!vm)
            return false;
        const to = Model.stepFrom(vm.gpuModeTarget, dir, vm.gpu.steps);
        if (to !== null && root._needsConfirm(to) && !root._askWhenBusy)
            return vm.setGpuMode(to, { confirmHolders: true });
        if (to !== null && root._needsConfirm(to)) {
            root._confirmStep = to;
            root._confirmHolders = vm.gpu.holders.slice();
            root._confirmOpen = true;
            return true;
        }
        // what this step is, asked BEFORE it is made (the facts move with it): a request for the MUX, or only a new
        // answer to "what after the restart" under one that is queued
        const plan = to !== null ? Model.planGpuMode(to, {}, vm.gpu, vm.gpuModeTarget) : null;
        const done = vm.stepGpuMode(dir);
        if (done && plan !== null && (plan.action === "mux" || plan.action === "reaim"))
            root._askMux(to);
        return done;
    }
    function stepZone(zone, dir) {
        if (zone === "cpu")
            return root.stepProfile(dir);
        if (zone === "gpu")
            return root.stepGpu(dir);
        return false;
    }
    function flipChargeLimit() {
        if (root.vm)
            root.vm.setChargeLimit(!root.vm.battery.limitOn);
    }

    // ---- touching the idle ladder: any pointer activity, at most four times a second ----
    property real _lastTouch: 0
    function _touch() {
        if (root.parked)
            return;
        const now = Date.now();
        if (now - root._lastTouch < 250)
            return;
        root._lastTouch = now;
        if (root.vm)
            root.vm.touch();
    }

    // A change of a fact the scene shows with a motion or a new look (the director's `watchKey`: the profile, the
    // GPU step, the D-state, the mains, the limit, who holds the card, a zone's daemon, a MUX request) and a
    // battery event wake a halted ladder: a halted clock plays none of them. The sensors that move all the time
    // -- loads, clocks, the pack's charge -- do not: the GPU plate and the board's displays read them from the view
    // model whatever the clock does (a change repaints on its own), and the scene shows them while it runs.
    Connections {
        target: motion
        function onWatchKeyChanged() {
            if (root.vm && !root.parked)
                root.vm.touch();
        }
    }
    Connections {
        target: root.vm
        ignoreUnknownSignals: true
        function onBatteryEvent(kind) {
            if (root.vm && !root.parked)
                root.vm.touch();
        }
    }

    // ---- the holders question's life (the "confirm" secondary) ----
    // What is asked and of whom is kept HERE, as it was when the question was raised: the secondary's content is built when it
    // opens and torn down when it closes.
    property bool _confirmOpen: false
    property int _confirmStep: 0
    property var _confirmHolders: []
    function _confirm() {
        root._confirmOpen = false;
        if (root.vm)
            root.vm.setGpuMode(root._confirmStep, { confirmHolders: true });
    }
    readonly property int _holderCount: root._gpu ? root._gpu.holders.length : 0
    on_HolderCountChanged: {
        if (root._holderCount === 0)
            root._confirmOpen = false;       // they exited: nothing left to confirm
    }
    readonly property int _gpuTarget: root.vm ? root.vm.gpuModeTarget : 0
    on_GpuTargetChanged: root._confirmOpen = false

    // ======================================================================================
    // Input (below the plates: the arrows and the card are theirs)
    // ======================================================================================
    SceneInput {
        id: sceneInput
        anchors.fill: parent
        scene: boardScene
        regions: root._regions
        onActivity: root._touch()
        onClicked: (intent, at) => {
            if (root._confirmOpen) {
                root._confirmOpen = false;   // a click elsewhere is a no
                return;
            }
            if (root._muxOpen) {
                root._muxOpen = false;
                return;
            }
            // A MUX request waits for its restart: the card asks about that, not about settings.
            if (intent === "gpu" && root.muxWanted) {
                root._muxOpen = true;
                return;
            }
            if (intent === "tuning" || intent === "gpu") {
                if (root.secondaryOpen && root.secondaryKey === intent)
                    root.closeSecondary();
                else
                    root.openSecondary(intent, at);
            } else if (intent === "limit") {
                root.flipChargeLimit();
            }
        }
        onSwiped: (zone, dir) => root.stepZone(zone, dir)
    }

    // ======================================================================================
    // The plates
    // ======================================================================================
    // Each plate stands on its FOOT: the text's last row ends `plateGap` above the top edge of its own hologram's plane (the two planes are not
    // level: the die the GPU's hangs from is 5 mm above the package's top) and the plate is as tall as its rows are now, so a tail that comes pushes
    // the head up and never down into the hologram. A plate never rises above the popup's padding.
    readonly property real _cpuFoot: Layout.holoTop(boardScene.geo, boardScene.cam, "cpuHolo") - root.plateGap
    readonly property real _gpuFoot: Layout.holoTop(boardScene.geo, boardScene.cam, "gpuHolo") - root.plateGap
    ZoneBlock {
        id: cpuPlate
        islandArmed: boardIsland.armed
        x: Math.round(Layout.anchorPx(boardScene.geo, boardScene.cam, "cpuHolo")[0] - width / 2)
        y: Math.max(root.margin, Math.round(root._cpuFoot - height))
        plateWidth: root.cpuPlateWidth
        fontFamily: root.fontFamily
        headSize: root.headSize
        tailSize: root.bodySize
        figureSize: root.figureSize
        overlayItem: overlay
        caption: root.vm ? root.vm.caption.cpu : ""
        error: root.vm ? root.vm.caption.cpuError : ""
        canPrev: root.canPrevProfile
        canNext: root.canNextProfile
        hovered: root.hoverZone === "cpu"
        onStep: dir => root.stepProfile(dir)
    }
    ZoneBlock {
        id: gpuPlate
        islandArmed: boardIsland.armed
        x: Math.round(Layout.anchorPx(boardScene.geo, boardScene.cam, "gpuHolo")[0] - width / 2)
        y: Math.max(root.margin, Math.round(root._gpuFoot - height))
        plateWidth: root.gpuPlateWidth
        fontFamily: root.fontFamily
        headSize: root.headSize
        tailSize: root.bodySize
        figureSize: root.figureSize
        overlayItem: overlay
        caption: root.vm ? root.vm.caption.gpu : ""
        error: root.vm ? root.vm.caption.gpuError : ""
        figuresShown: gpuReadouts.live
        // who is using the card, in full: the caption's tail names the first few
        tip: root._gpu && root._gpu.holders.length > 0 ? "Using the dGPU: " + root._gpu.holders.join(", ") : ""
        canPrev: root.canPrevGpu
        canNext: root.canNextGpu
        hovered: root.hoverZone === "gpu"
        onStep: dir => root.stepGpu(dir)
        ZoneReadouts {
            id: gpuReadouts
            islandArmed: boardIsland.armed
            vm: root.vm
            fontFamily: root.fontFamily
            figureSize: root.figureSize
            x: Math.round((parent.width - width) / 2)
        }
    }

    // ---- the battery's error: a tag beside the DIP switch, for as long as the error stands ----
    ErrorTag {
        id: batteryError
        islandArmed: boardIsland.armed
        readonly property var _at: Layout.dipTagPoint(boardScene.geo, boardScene.cam)
        x: Math.max(root.margin, Math.min(root.stageWidth - root.margin - width, Math.round(batteryError._at[0] + root.errorTagDx)))
        y: Math.round(batteryError._at[1] + root.errorTagDy)
        text: root.vm ? root.vm.caption.batteryError : ""
        overlayItem: overlay
        fontFamily: root.fontFamily
        pixelSize: root.figureSize
        maxWidth: root.errorTagMaxWidth
    }

    // ---- the time display's tip: why a pack above its limit is not coming down (Model.heldNote) ----
    readonly property bool _timeHover: sceneInput.hoverPart === "segTime"
    readonly property var _timeBox: Layout.partBox(boardScene.geo, boardScene.cam, "segTime")
    readonly property string _timeTipText: root.vm ? Model.heldNote(root.vm.battery) : ""
    Item {
        id: timeAnchor
        visible: false
        x: root._timeBox ? root._timeBox.x : 0
        y: root._timeBox ? root._timeBox.y : 0
        width: root._timeBox ? root._timeBox.w : 0
        height: root._timeBox ? root._timeBox.h : 0
    }
    HoverTip {
        id: timeTip
        show: root._timeHover && root._timeTipText !== ""
        anchorItem: timeAnchor
        overlayItem: overlay
        text: root._timeTipText
        fontFamily: root.fontFamily
    }

    // ---- the watts display's tip: what the swapped-in figure is ----
    Item {
        id: wattsAnchor
        visible: false
        x: root._wattsBox ? root._wattsBox.x : 0
        y: root._wattsBox ? root._wattsBox.y : 0
        width: root._wattsBox ? root._wattsBox.w : 0
        height: root._wattsBox ? root._wattsBox.h : 0
    }
    HoverTip {
        id: wattsTip
        show: root._wattsHover && root._wattsTipText !== ""
        anchorItem: wattsAnchor
        overlayItem: overlay
        text: root._wattsTipText
        fontFamily: root.fontFamily
    }

    // ---- the MUX: the restart a request waits for (the "mux" secondary) ----
    // What has to outlive the secondary that shows it is here: the restart card's open/closed (`_muxOpen`).
    property bool _muxOpen: false
    // A MUX request waits for its restart (the record is `queued`): the restart card has something to ask about. A request
    // that is gone (cancelled elsewhere, applied) leaves nothing to ask.
    readonly property bool muxWanted: !!root._gpu && root._gpu.mux.state === "queued"
    onMuxWantedChanged: {
        if (!root.muxWanted)
            root._muxOpen = false;
    }
    // The restart card OPENS BY ITSELF once a step that asked the MUX for something has settled. `_muxAsk` is the step
    // that was asked (3 dGPU-only, 0..2 the way back with that mode wanted after it), -1 when none; it is met when the
    // FACTS say so -- the request is queued, and for the way back its `afterMode` is that step -- not when a timer says
    // so (a cancel in flight still shows the old request, a refusal never shows a new one), and the card waits for the
    // facts to have said it for 300 ms (a swipe through Smart to Integrated is one card, not two). A step that never
    // comes true (the helper refused it: the caption says why) is forgotten after 8 s.
    property int _muxAsk: -1
    property real _muxAskAt: 0
    property real _muxMetSince: 0
    function _askMux(step) {
        if (step === 3 && root._gpu && root._gpu.wiring === "dgpu") {
            // back to dGPU-only from the way back is the cancel: nothing is left to restart
            root._muxAsk = -1;
            root._muxOpen = false;
            return;
        }
        root._muxAsk = step;
        root._muxAskAt = Date.now();
        root._muxMetSince = 0;
    }
    function _muxAskMet() {
        const m = root._gpu ? root._gpu.mux : null;
        if (!m || m.state !== "queued")
            return false;
        if (root._muxAsk === 3)
            return m.want === "dgpu";
        return m.want === "hybrid" && (m.afterMode !== null ? m.afterMode : 2) === root._muxAsk;
    }
    function _pollMuxAsk() {
        if (root._muxAsk < 0)
            return;
        const now = Date.now();
        if (root._muxAskMet()) {
            if (root._muxMetSince === 0)
                root._muxMetSince = now;
            if (now - root._muxMetSince >= 300) {
                root._muxAsk = -1;
                if (root.shown)
                    root._muxOpen = true;
            }
        } else {
            root._muxMetSince = 0;
            if (now - root._muxAskAt > 8000)
                root._muxAsk = -1;
        }
    }
    Timer {
        interval: 100
        repeat: true
        running: root._muxAsk >= 0
        onTriggered: root._pollMuxAsk()
    }
    // ---- the three tactile sounds ----
    SiliconSounds {
        id: sounds
        vm: root.vm
        director: motion
        active: root._live && (!root.vm || !root.vm.config || root.vm.config.sounds)
    }

    // Floating things (tips) live here, above everything, inside the popup's own bounds so the pointer
    // reaches them.
    Item {
        id: overlay
        anchors.fill: parent
        z: 10
    }
}
