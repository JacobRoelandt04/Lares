pragma ComponentBehavior: Bound

import QtQuick

import "../../common/components/Mix.js" as Mix
import "SceneGeometry.js" as Geo
import "IsoCamera.js" as Cam
import "Figures.js" as Fig
import "MotionScripts.js" as Motion

// =============================================================================
// SiliconScene.qml -- the isometric board and everything drawn on it, as one item.
//
// Layers, back to front (CONTRACT section 6):
//   board        BoardLayer, the still picture, held as a layer, with a HOLE over the CPU zone: it never holds the package
//   patch        BoardLayer over that hole, the whole scene there; a layer too, it renders again only as the package lifts and turns
//   glow         live light: cores, tiles, cells, trace light (GlowLayer)
//   particles 0  sparks behind the hologram planes
//   holograms    the CPU's symbol, the GPU's fractal or the integrated beam
//   particles 1  sparks in front of them
// Every number the layers share (camera, turns, lifts) lives HERE, once.
// =============================================================================
Item {
    id: root

    implicitWidth: 760
    implicitHeight: root.naturalHeight

    // ---- look ----
    property int family: 0
    readonly property bool dark: root.style.dark       // the theme's mode (SiliconStyle)
    property real renderScale: 1
    // The palette of the theme island's GHOST (SiliconIsland): every token as it stood when a switch was asked, and the mode then. Null is
    // the live theme, which is every scene that is not that older copy.
    property var oldMap: null
    property bool oldDark: false
    readonly property SiliconStyle style: SiliconStyle {
        family: root.family
        oldMap: root.oldMap
        oldDark: root.oldDark
    }
    property real lightAngle: 128         // deg: 0 from the right, 90 from above (Lighting.js)
    property real lightElevation: 0.52    // toward the eye
    property real shadowStrength: 0.62

    // ---- state the scene shows (the service's facts, eased by the clock) ----
    // A profile change lifts the CPU package, turns it and sets it down. Its turn in quarter turns:
    // profile k rests at k, a change passes through the fractions -- clockwise as the profile goes up.
    property real pkgQuarter: 0
    property real pkgRise: 0             // 0 at rest .. 1 lifted all the way (SceneGeometry PKG.lift)
    readonly property real pkgLift: root.pkgRise * root.geo.PKG.lift
    property real cardLift: 0            // mm
    property real cardDissolve: 0        // 0..1
    property real plugIn: 1              // 0 out .. 1 in
    property real hdmiIn: 0              // the HDMI cable in the card's port: 0 out (and faded) .. 1 seated (MotionDirector's, from `display.hdmi`)
    property real lever: 0               // 0 "80" .. 1 "100"
    property bool patchOff: false        // gates: no hole, no patch -- the board itself draws the package in its pose (the truth)
    property real patchNudge: 0          // gates' ARM only: px the patch is moved off its place
    // The patch is drawn this many DEVICE px beyond the hole it fills, and out there only what is opaque (silicon_board.frag): the board leaves a
    // hole and the patch fills it, and a layer is ONE TEXTURE drawn over a rect that is rarely whole device pixels -- at the shell's 1.25 the patch's
    // foot lands on 442.5, its quad loses a row when it is drawn inside another layer (the engine's clip layer, all through an open), a bilinear
    // read mixes the hole's transparent edge into the row beside it -- so without the margin the two leave a row or a column of the surface open along the
    // patch's edge: thin lines of void across the growing board. 0 = no margin.
    property real patchMargin: 2
    property real holeGrow: 0            // gates' ARM only: px the board's hole is grown past the patch's rect (negative: cut short)
    property bool forceCardPatch: false  // gates: the board with the card absent and the patch drawing it, at rest (they must make the seated picture)
    property bool cardPatchOff: false    // gates: no card patch -- the board itself draws the moving card (the truth)
    property int cardSettleMs: 120       // how long the card must be back in its seat before the cached board shows it there
    property real cardPatchNudge: 0      // gates' ARM only: px the card's patch is moved off its place
    property bool cardPatchRaw: false    // gates' ARM only: the card's patch draws the ground as well
    property real cardRectPad: 6         // the card's rect grows by this many px all round (gates' ARM only: negative, to cut it short)

    // ---- what the scene shows: the service's facts, eased by the clock (CONTRACT section 6) ----
    property real time: 0                // s, the scene clock
    property real power: 1               // 0..1: the power-on sequence (the entrance)
    // How alive the scene's OWN motion is, 0..1 (the idle ladder's, SiliconClock eases it): the particles,
    // the holograms' flicker and scan, the pulse trains along the traces and the MUX breath are all
    // multiplied by it, so a halted popup (0) is a still picture with nothing frozen mid-flight.
    property real live: 1
    // A zone without its daemon never powers on (the director eases them from the facts): the CPU's when the
    // silicon helper is not answering, the GPU's when cardwire is not running. Its hologram and its sparks
    // take the lower of this and `power`; the board and the other zone are as usual.
    property real cpuZone: 1
    property real gpuZone: 1
    readonly property real cpuPower: Math.min(root.power, root.cpuZone)
    readonly property real gpuPower: Math.min(root.power, root.gpuZone)
    // The MUX request that waits for its restart: the GPU hologram breathes, a slow brightness pulse
    // (`muxBreath` is the amplitude 0..1 the director eases in and out; 1.6 s a breath, well under 3 Hz, one
    // hologram and never the whole field)
    property real muxBreath: 0
    property real muxBreathS: 1.6
    property real muxBreathDepth: 0.45
    // the holograms' lens discs and rings (the projector's base) at this share of full strength;
    // the idle ladder's `live` takes them out at halt. A tunable like the breath's two: the mockup's Motion tab (sceneParams) offers it.
    property real lensStrength: 0.5
    // the holograms' additions, one switch each (1 on; the mockup's Holograms group offers them): the leaf's dew drop,
    // the scales' plinth, the shock's scope trace, the fractals' armillary, the beam's data stream
    property real fxPlinth: 1
    property real fxTrace: 1
    property real fxOrbits: 1
    property real fxStream: 1
    // the poles' particle field: its charge* / discharge* properties are the mockup's Particles tab's (a drop-in leaves them at their defaults)
    readonly property alias poleField: poleField
    readonly property real breathFactor: 1 - root.muxBreath * root.live * root.muxBreathDepth * 0.5 * (1 - Math.cos(2 * Math.PI * root.time / root.muxBreathS))
    // CPU
    property int profile: 1              // 0 Quiet, 1 Balanced, 2 Performance
    property color cpuColour: root.style.profileColour(root.profile)
    // the hologram's symbol is the profile's index: 0 the leaf, 1 the scales, 2 the shock
    property int cpuSymbol: root.profile
    property int cpuNextProfile: -1      // during a change: the profile it is changing to
    readonly property int cpuNextSymbol: root.cpuNextProfile >= 0 ? root.cpuNextProfile : root.cpuSymbol
    property real cpuDerez: 0
    readonly property color cpuNextColour: root.cpuNextProfile >= 0 ? root.style.profileColour(root.cpuNextProfile) : root.cpuColour
    property real cpuLoad: 0.3
    property var cores: [0.62, 0.35, 0.18, 0.44, 0.08, 0.21, 0.30, 0.12, 0.05, 0.40, 0.22, 0.09, 0.15, 0.03, 0.55, 0.26]
    property real cpuPhase: 0            // cycles of the pulse train toward the CPU
    property real tweak: 0               // 0..1: tuning differs from the profile's
    // GPU
    property int gpuMode: 2              // 0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only
    property color gpuColour: root.style.gpuColour(root.gpuMode)
    property int gpuSymbol: Math.max(0, root.gpuMode - 1)
    property int gpuNextMode: -1         // during a change: the mode it is changing to
    readonly property int gpuNextSymbol: root.gpuNextMode >= 0 ? Math.max(0, root.gpuNextMode - 1) : root.gpuSymbol
    property real gpuDerez: 0
    readonly property color gpuNextColour: root.gpuNextMode >= 0 ? root.style.gpuColour(root.gpuNextMode) : root.gpuColour
    property real dgpuAwake: 0           // 0..1, eased
    property real gpuUtil: 0
    property real gpuPhase: 0
    property real beam: root.gpuMode === 0 ? 1 : 0     // the integrated silhouette's presence
    property real igpuBusy: 0.12
    // battery
    property real fill: 0.72             // 0..1
    property real flowW: -11             // > 0 charging, < 0 discharging
    property real flowPhase: 0           // mm travelled by the charge flow
    property color chargeColour: root.style.profileColour(0)
    property real eventAge: -1           // s since the last battery event (< 0 none)
    property int eventKind: 0            // 0 full, 1 low, 2 charge start, 3 charge stop
    property color eventColour: root.chargeColour
    property bool limitOn: root.lever < 0.5
    // The charge limit's lock: ONE fraction, 0 disengaged .. 1 locked, and every piece of the lock is a pure function of it
    // (MotionScripts.lockPose). The director plays it (after the lever has landed at "80" on the way in, with the lever on the way
    // out); a scene without a director follows the lever's own fact. Written by the director, so this binding is the default only.
    property real lock: root.limitOn ? 1 : 0
    readonly property var lockPose: Motion.lockPose(root.lock, root.geo.LOCK.shackleOpen)
    // The board's figures as display strings (the contract): null before the first reading. `{ watts, time, timeMode,
    // sinceFull, condition, cycles, ram }`; Figures.js is the grammar. The popup binds it; an unlit display is a null / empty string.
    property var figures: null
    // The memory the RAM shows, `{ usedFraction }` (the RAM part draws it)
    property var memory: null
    // What the RAM shows: the memory's fact (read at the stats cadence, a fill moves a hair at a time: no easing, and a halted popup's figure
    // change costs its own few frames). The display's light is the iGPU's except in dGPU-only.
    readonly property real ramUsed: root.memory ? Math.max(0, Math.min(1, root.memory.usedFraction)) : 0
    readonly property real displayDgpu: root.gpuMode === 3 ? 1 : 0
    // what the displays are told: four cell codes each in SceneGeometry.SEG7's order, the printed figures and the time label. The
    // cached board takes each printed figure as ONE number, so a watts tick that changes none of them leaves the board alone.
    readonly property var _figs: Fig.describe(root.figures, root.geo.SEG7)
    readonly property real _condCode: Fig.code4(root._figs.condition)
    readonly property real _cycCode: Fig.code4(root._figs.cycles)
    readonly property int _timeLabel: root._figs.timeLabel
    function _fig4(i: int): vector4d {
        const a = root._figs.displays[i] || [11, 11, 11, 11];
        return Qt.vector4d(a[0], a[1], a[2], a[3]);
    }

    // the colours the live light and the particles carry: a change crossfades with its de-rez
    // (one clock: the de-rez fraction; Mix.c, never a Behavior on a colour)
    readonly property color cpuLive: Mix.c(root.cpuColour, root.cpuNextColour, root.cpuDerez)
    readonly property color gpuLive: Mix.c(root.gpuColour, root.gpuNextColour, root.gpuDerez)
    // the card's own colour: the dGPU mode it belongs to, whichever way it is going (leaving for or
    // returning from Integrated), so its dust never turns colour mid-flight when the mode flips
    readonly property color cardColour: root.style.gpuColour(root.gpuMode !== 0 ? root.gpuMode : (root.gpuNextMode > 0 ? root.gpuNextMode : 2))

    // THE PACKAGE'S PATCH. The cached board holds no package: the patch's rect is a hole in it (`hole` below) and the patch draws that
    // rect whole, the package in its pose. The board's package uniforms are constants, so nothing a profile change does renders it again -- not at
    // the move, and not when the turn crosses its half (a board that held the package at its nearest quarter would render once per step).
    readonly property bool pkgMoving: Math.abs(root.pkgQuarter - Math.round(root.pkgQuarter)) > 1e-4 || root.pkgRise > 1e-4
    readonly property vector4d holeRect: root.patchOff ? Qt.vector4d(0, 0, 0, 0)
        : Qt.vector4d(root.patchRect.x - root.holeGrow, root.patchRect.y - root.holeGrow, root.patchRect.x + root.patchRect.w + root.holeGrow, root.patchRect.y + root.patchRect.h + root.holeGrow)

    // THE CARD'S PATCH. A board that took the card's lift and dissolve as uniforms would render the whole board again on EVERY frame while the card
    // leaves or comes back (a GPU mode change to or from Integrated, a second or so) -- about 5 ms of GPU at 1x and 20
    // at a 2x stage. So the board shows the card either SEATED or ABSENT (`_seated`): the moment the card
    // starts to move the board is rendered once with it absent, and a live patch over the card's footprint draws the card moving (the
    // shader's card mode, frame.z = 2: whatever the card changes is redrawn, ground left to the board); the card out and gone the patch
    // goes and the board needs nothing; the card back it waits `cardSettleMs` still, takes its seat in one render, and the patch goes.
    // (A board that held the card where it stood would keep its edge pixels where the card overhangs the board's edge.)
    property bool _seated: true
    readonly property bool cardPatchShown: (!root._seated || root.forceCardPatch) && root.cardDissolve < 0.9999 && !root.cardPatchOff
    onCardLiftChanged: root._cardMoved()
    onCardDissolveChanged: root._cardMoved()
    function _cardMoved() {
        if (root.cardLift > 1e-4 || root.cardDissolve > 1e-4) {
            root._seated = false;
            cardSettle.stop();
        } else if (!root._seated) {
            cardSettle.restart();
        }
    }
    Timer {
        id: cardSettle
        interval: root.cardSettleMs
        onTriggered: root._seated = true
    }

    // ---- camera ----
    readonly property var geo: JSON.parse(Geo.json())
    // the 760 x 560 fit, by the WIDTH alone (the scale and the board's top do not move when the popup's bottom plate goes), and the
    // popup height that holds the board with the camera's bottom margin: the popup binds its height to `naturalHeight`, so nothing here
    // may read this item's own height
    readonly property var _fit: Cam.fitNatural(root.geo, root.width, { l: 14, r: 14, t: 12, b: 14 }, 60)
    readonly property var cam: ({ s: root._fit.s, ox: root._fit.ox, oy: root._fit.oy })
    readonly property int naturalHeight: root._fit.height
    readonly property var light3: Cam.lightDir(root.lightAngle, root.lightElevation)
    readonly property var patchRect: {
        // held inside the scene: a low lamp throws the lifted package's shadow a long way
        const r = Cam.patchRect(root.geo, root.cam, 6, root.light3);
        const x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
        return { x: x0, y: y0, w: Math.max(0, Math.min(Math.ceil(root.width), r.x + r.w) - x0), h: Math.max(0, Math.min(Math.ceil(root.height), r.y + r.h) - y0) };
    }
    // the patch's quad: its core (the hole) and the margin, held inside the scene
    readonly property var patchBox: {
        const r = root.patchRect, m = Math.max(0, root.patchMargin) / (root.renderScale > 0.01 ? root.renderScale : 1);
        const x0 = Math.max(0, r.x - m), y0 = Math.max(0, r.y - m);
        const x1 = Math.min(Math.ceil(root.width), r.x + r.w + m), y1 = Math.min(Math.ceil(root.height), r.y + r.h + m);
        return { x: x0, y: y0, w: Math.max(0, x1 - x0), h: Math.max(0, y1 - y0) };
    }
    readonly property var cardRect: {
        const r = Cam.cardRect(root.geo, root.cam, root.cardRectPad, root.light3);
        const x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
        return { x: x0, y: y0, w: Math.max(0, Math.min(Math.ceil(root.width), r.x + r.w) - x0), h: Math.max(0, Math.min(Math.ceil(root.height), r.y + r.h) - y0) };
    }
    readonly property bool _cardMeetsPatch: root.cardRect.x < root.patchRect.x + root.patchRect.w && root.patchRect.x < root.cardRect.x + root.cardRect.w
        && root.cardRect.y < root.patchRect.y + root.patchRect.h && root.patchRect.y < root.cardRect.y + root.cardRect.h
    // the CPU's hologram stands on the die, so it rides the package's lift and turn as the iGPU's beam does (at the resting
    // die's height its foot ring would float off the lifted package through every profile change)
    readonly property var cpuHoloAnchor: Cam.pkgPoint(root.geo, root.geo.ANCHORS.cpuHolo, root.turnRad(root.pkgQuarter), root.pkgLift)
    readonly property var cpuHoloRect: Cam.holoRect(root.cpuHoloAnchor, root.cam, Cam.HOLO.w, Cam.HOLO.base, Cam.HOLO.h, 10, Cam.lensReach(root.geo, root.geo.LENS.cpu), Cam.CONE_INK.cpu)
    readonly property var gpuHoloRect: Cam.holoRect(root.geo.ANCHORS.gpuHolo, root.cam, Cam.HOLO.w, Cam.HOLO.base, Cam.HOLO.h, 10, Cam.lensReach(root.geo, root.geo.LENS.gpu), Cam.CONE_INK.gpu)
    // the beam: from the graphics tile -- where the package's turn and lift have it -- to the die of the card's ghost, which hangs
    // over the card's place in its slot (the real card without its I/O bracket)
    readonly property var igpuAnchor: Cam.pkgPoint(root.geo, root.geo.ANCHORS.igpuTile, root.turnRad(root.pkgQuarter), root.pkgLift)
    readonly property var cardCentre: [(root.geo.CARD.x0 + root.geo.CARD.x1) / 2, root.geo.CARD.rest + 1, (root.geo.CARD.z0 + root.geo.CARD.z1) / 2]       // the card's dust
    readonly property var beamTarget: Cam.ghostDie(root.geo)
    readonly property var beamRect: Cam.beamRect(root.geo, root.cam, root.igpuAnchor, root.beamTarget)

    function turnRad(q) {
        return -q * Math.PI / 2;
    }

    BoardLayer {
        id: board
        anchors.fill: parent
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        offsetX: 0
        offsetY: 0
        // the package is the patch's (the hole); only the truth (`patchOff`) has the board draw it
        hole: root.holeRect
        pkgTurn: root.patchOff ? root.turnRad(root.pkgQuarter) : 0
        pkgLift: root.patchOff ? root.pkgLift : 0
        cardLift: root.cardPatchOff ? root.cardLift : (root._seated && !root.forceCardPatch ? 0 : Cam.CARD_LIFT_MAX)
        cardDissolve: root.cardPatchOff ? root.cardDissolve : (root._seated && !root.forceCardPatch ? 0 : 1)
        plugIn: root.plugIn
        hdmiIn: root.hdmiIn
        lever: root.lever
        lightDir: root.light3
        shadowStrength: root.shadowStrength
        colours: root.style.palette
        colours2: root.style.palette2
        tune: root.style.tune
        r3s1Latch: root.style.latch
        lockBar: root.lockPose.bar
        lockShackle: root.lockPose.shackle
        lockDim: root.lockPose.dim
        lockAlpha: root.lockPose.alpha
        condCode: root._condCode
        cycCode: root._cycCode
        timeLabel: root._timeLabel
    }

    BoardLayer {
        id: cardPatch
        // the card leaving or coming back, live over its footprint: the cached board under it keeps the card where it stood
        visible: root.cardPatchShown
        cached: false
        cardPatch: !root.cardPatchRaw
        x: root.cardRect.x + root.cardPatchNudge
        y: root.cardRect.y
        width: root.cardRect.w
        height: root.cardRect.h
        offsetX: root.cardRect.x
        offsetY: root.cardRect.y
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        // the card's patch sits over the board's pixels (it leaves the ground to them); the package is not the board's to draw
        hole: root.holeRect
        pkgTurn: root.patchOff ? root.turnRad(root.pkgQuarter) : 0
        pkgLift: root.patchOff ? root.pkgLift : 0
        cardLift: root.cardLift
        cardDissolve: root.cardDissolve
        plugIn: root.plugIn
        hdmiIn: root.hdmiIn
        lever: root.lever
        lightDir: root.light3
        shadowStrength: root.shadowStrength
        colours: root.style.palette
        colours2: root.style.palette2
        tune: root.style.tune
        r3s1Latch: root.style.latch
        lockBar: root.lockPose.bar
        lockShackle: root.lockPose.shackle
        lockDim: root.lockPose.dim
        lockAlpha: root.lockPose.alpha
        condCode: root._condCode
        cycCode: root._cycCode
        timeLabel: root._timeLabel
    }

    BoardLayer {
        id: patch
        // the package in its pose, whole, over the board's hole. A layer at rest (it costs nothing per frame); drawn straight into the window while
        // the package moves, because a layer whose content changes every tick asks for a second frame per tick (measured: 75 fps presented against 63)
        visible: !root.patchOff
        cached: !root.pkgMoving
        patch: true
        x: root.patchBox.x + root.patchNudge
        y: root.patchBox.y
        width: root.patchBox.w
        height: root.patchBox.h
        offsetX: root.patchBox.x
        offsetY: root.patchBox.y
        // its core, where it draws all of what is there (its margin only what is opaque)
        hole: root.holeRect
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        pkgTurn: root.turnRad(root.pkgQuarter)
        pkgLift: root.pkgLift
        // the card is the board's and its own patch's: where their rects do not meet (the default light) the board's values, so a card on the move
        // does not render this layer again every frame; where they do (a low lamp throws the card's shadow into the package's rect) the patch
        // draws the card as it is, over the card patch's transparent hole
        cardLift: root.cardPatchOff || root._cardMeetsPatch ? root.cardLift : (root._seated && !root.forceCardPatch ? 0 : Cam.CARD_LIFT_MAX)
        cardDissolve: root.cardPatchOff || root._cardMeetsPatch ? root.cardDissolve : (root._seated && !root.forceCardPatch ? 0 : 1)
        plugIn: root.plugIn
        hdmiIn: root.hdmiIn
        lever: root.lever
        lightDir: root.light3
        shadowStrength: root.shadowStrength
        colours: root.style.palette
        colours2: root.style.palette2
        tune: root.style.tune
        r3s1Latch: root.style.latch
        lockBar: root.lockPose.bar
        lockShackle: root.lockPose.shackle
        lockDim: root.lockPose.dim
        lockAlpha: root.lockPose.alpha
        condCode: root._condCode
        cycCode: root._cycCode
        timeLabel: root._timeLabel
    }

    GlowLayer {
        anchors.fill: parent
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        pkgTurn: root.turnRad(root.pkgQuarter)
        pkgLift: root.pkgLift
        cardLift: root.cardLift
        cardDissolve: root.cardDissolve
        plugIn: root.plugIn
        lever: root.lever
        lightDir: root.light3
        cores: root.cores
        igpuBusy: root.igpuBusy
        dgpuAwake: root.dgpuAwake
        fill: root.fill
        flowW: root.flowW
        cpuPhase: root.cpuPhase
        gpuPhase: root.gpuPhase
        flowPhase: root.flowPhase
        time: root.time
        powerOn: root.power
        pulse: root.live
        eventAge: root.eventAge
        eventKind: root.eventKind
        lockBar: root.lockPose.bar
        lockShackle: root.lockPose.shackle
        lockDim: root.lockPose.dim
        lockAlpha: root.lockPose.alpha
        figA: root._fig4(0)
        figB: root._fig4(1)
        figC: root._fig4(2)
        figD: root._fig4(3)
        figE: root._fig4(4)
        figF: root._fig4(5)
        figG: root._fig4(6)
        ramUsed: root.ramUsed
        displayDgpu: root.displayDgpu
        colours2: root.style.palette2
        cpuColour: root.cpuLive
        gpuColour: root.gpuLive
        chargeColour: root.chargeColour
        eventColour: root.eventColour
    }

    // ---- particles on the board, and the sparks behind the hologram planes ----
    component Field: ParticleField {
        anchors.fill: parent
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        time: root.time
        power: root.power
        brightness: root.live
        pkgTurn: root.turnRad(root.pkgQuarter)
        pkgLift: root.pkgLift
    }
    Field {
        // the pack's poles: the swirl out of the (-) terminal while discharging, the funnel into the (+) one while charging
        id: poleField
        emitter: "traces"
        flowW: root.flowW
        chargeColour: root.chargeColour
        colour: root.cpuLive
    }
    Field {
        emitter: "card"
        anchor: root.cardCentre
        cardDissolve: root.cardDissolve
        cardLift: root.cardLift
        colour: root.cardColour
    }
    readonly property var cpuSparkAnchor: [root.geo.ANCHORS.cpuHolo[0], root.geo.ANCHORS.cpuHolo[1] + root.pkgLift, root.geo.ANCHORS.cpuHolo[2]]
    Field {
        emitter: "cpu"
        pass: 0
        power: root.cpuPower
        anchor: root.cpuSparkAnchor
        energy: root.cpuLoad
        colour: root.cpuLive
    }
    Field {
        emitter: "gpu"
        pass: 0
        power: root.gpuPower
        anchor: root.geo.ANCHORS.gpuHolo
        energy: root.gpuUtil * root.dgpuAwake
        colour: root.gpuLive
    }

    // ---- the holograms ----
    component Holo: HoloLayer {
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        time: root.time
        power: root.power
        live: root.live
        lensStrength: root.lensStrength
        fxPlinth: root.fxPlinth
        fxTrace: root.fxTrace
        fxOrbits: root.fxOrbits
        fxStream: root.fxStream
        tweakColour: root.style.tweakColour
    }
    Holo {
        kind: "beam"
        x: root.beamRect.x
        y: root.beamRect.y
        width: root.beamRect.w
        height: root.beamRect.h
        anchor: root.igpuAnchor
        target: root.beamTarget
        colour: root.gpuColour
        presence: root.beam
        energy: root.igpuBusy
    }
    Holo {
        kind: "cpu"
        power: root.cpuPower
        x: root.cpuHoloRect.x
        y: root.cpuHoloRect.y
        width: root.cpuHoloRect.w
        height: root.cpuHoloRect.h
        anchor: root.cpuHoloAnchor
        symbol: root.cpuSymbol
        nextSymbol: root.cpuNextSymbol
        derez: root.cpuDerez
        colour: root.cpuColour
        nextColour: root.cpuNextColour
        tweak: root.tweak
        energy: root.cpuLoad
    }
    Holo {
        kind: "gpu"
        power: root.gpuPower
        x: root.gpuHoloRect.x
        y: root.gpuHoloRect.y
        width: root.gpuHoloRect.w
        height: root.gpuHoloRect.h
        anchor: root.geo.ANCHORS.gpuHolo
        symbol: root.gpuSymbol
        nextSymbol: root.gpuNextSymbol
        derez: root.gpuDerez
        colour: root.gpuColour
        nextColour: root.gpuNextColour
        energy: root.gpuUtil
        // seated and allowed: shown; Integrated (the card out) hides it; asleep (D3cold) it dims; a MUX
        // request waiting for its restart makes it breathe, a factor of its own so a sleeping card breathes too
        presence: (1 - root.beam) * (1 - root.cardDissolve)
        awake: root.dgpuAwake
        breath: root.breathFactor
    }

    // ---- the sparks in front of the hologram planes ----
    Field {
        emitter: "cpu"
        pass: 1
        power: root.cpuPower
        anchor: root.cpuSparkAnchor
        energy: root.cpuLoad
        colour: root.cpuLive
    }
    Field {
        emitter: "gpu"
        pass: 1
        power: root.gpuPower
        anchor: root.geo.ANCHORS.gpuHolo
        energy: root.gpuUtil * root.dgpuAwake
        colour: root.gpuLive
    }
}
