pragma ComponentBehavior: Bound

import QtQuick

import "../../common/board"
import "../../common/components"
import "../../common/theme"
import "../scene"
import "../secondary"
import "SpeedDisplay.js" as Speed
import "../scene/AerialCamera.js" as Cam
import "../scene/AerialLayout.js" as Layout
import "../scene/AerialFacts.js" as Facts
import "../scene/CloudPlace.js" as CP

// =============================================================================
// AerialPopup.qml -- the board scene on the toolkit's PopupStage at its asked size (silicon's: 760 design px wide, the owner's `sizeScale`), with the input by arithmetic
// (BoardInput: the pick of the parts as they are drawn RIGHT NOW) and the hand cursor over what answers a click: NOTHING else announces an affordance (no hover fade; the
// parts' material and silkscreen say what is a part). A failure is told by a toast (the service's); here the part it names gives ONE short physical cue (`cue(part)`: the
// label, a tag of the cloud and the globe shake, a DIP lever springs back, a pad's LED blinks twice) and nothing stays. It SHOWS the service's facts (`service`, an
// AerialService or its mock: the contract's members) and asks it for nothing: a click emits `partActivated(intent)` -- what it does is the owner's (stage 4), a mockup's own.
//
// WHAT A CLICK DOES (L1): the board's own parts the owner answers (screw, DIPs, scan, beacon, pads: AerialBarOwner._answer) and the popup answers the rest ITSELF -- the
// parts and holograms that have a detail panel open it beside the scene through the engine's secondary contract (`AerialSecondary`, stream P's panels), the rates display
// asks and runs the speed test (two clicks). ONE slot, with a precedence: a Bluetooth pairing question (the service's `bt.prompt`: the device's panel opens by itself) wins
// over a pending password (a secured stranger dropped on the label, held by the DragController) which wins over a browse (a click on a part). A second click on the part
// that opened the panel closes it; Escape goes ONE step a press (`handleEscape`: the panel's own first -- the saved list's search clears --, then the panel, then the popup:
// navigate OR close, never both). The detail opens on the LEFT of the popup (`look.secondarySide` "start") and joins along its long edge as stocks' detail does. The fields
// of a panel are the POPUP's to ask the keyboard for (the engine asks the primary only): `keyboardFocusRequest` follows the panel's `keyboardWanted` -- a field that is only an
// OPTION (the saved list's search) asks once the pointer has MOVED into the panel or a key opened it, never because it appeared under a resting pointer (HoverArm).
//
// THE LIFE (L1): the power-on (~600 ms on one clock, `enter`: the card's lights, the cloud dealt in from its inner arc out, the globe, the label typed), the idle ladder (aerial's own
// times: alive -> calm after 10 s without the pointer -> still after 30 s; a network event or a motion wakes it), whatever keeps moving holds still through a theme
// crossfade, the mechanical sounds (AerialSounds). `parked` / `prewarm` / `recycle()` are the engine's (GooeyEngine: THE PARKED CONTENT).
//
// DROP-IN: self-contained, sized through implicitWidth / implicitHeight (the design size x sizeScale), no assumption about the host beyond what it exposes.
// =============================================================================
PopupStage {
    id: root

    // ---- in ----
    property var service: null
    property int family: 0                      // 0 Material, 1 Blueprint (silicon's own setting: one switch for both scenes)
    property real renderScale: 1
    property bool animate: true
    property bool halted: false
    property real power: 1                      // the host's master level (airplane fades the holograms by itself); the power-on multiplies it
    property bool open: true
    // THE ENGINE'S PARKED CONTENT: written by the engine, never here -- true while the content is held hidden (built ahead of the click on a hover, kept after its popup
    // closed, drawn once by the prewarm). Parked it runs nothing and asks nothing.
    property bool parked: false
    // Drawn ONCE by the engine's prewarm: the board simply ON (no power-on: a dark board draws no hologram, no lit figure -- what the first real open would compile through
    // the engine's clip layer is compiled here instead). Never set on a content that is shown.
    property bool prewarm: false
    // false: the board is simply on (a harness, a gate): no power-on
    property bool entranceEnabled: true
    property bool soundsEnabled: true
    property string fontFamily: "Inter"
    // where the secondary opens (config aerial.jsonc look.secondarySide: "start" the left of a horizontal bar's popup (the default) | "end" | "far"): the side the user asked for;
    // `secondarySide` is the one the engine reads, the same unless the screen has no room for the panel on that side
    property string sidePreference: root.service && root.service.config && root.service.config.look && root.service.config.look.secondarySide ? String(root.service.config.look.secondarySide) : "start"
    property int haltAfterMs: 30000
    property int armMs: 5000                    // the speed test's second click must come within this
    property var oldMap: null
    property bool oldDark: false

    // ---- out ----
    signal partActivated(string intent, point at)
    readonly property alias scene: boardScene
    readonly property string hoverIntent: Layout.intentFor(boardScene.geo, input.hoverPart)

    designWidth: Cam.DESIGN_WIDTH
    designHeight: boardScene.naturalHeight

    // the facts, as one object read at one serial (the service bumps `serial` LAST)
    readonly property var _facts: {
        const s = root.service;
        if (!s)
            return null;
        const dep = s.serial;
        return { wifi: s.wifi, bt: s.bt, wired: s.wired, hotspot: s.hotspot, proton: s.proton, health: s.health, rates: s.rates, usage: s.usage, speed: s.speed, airplane: s.airplane, helper: s.helper, config: s.config, dep: dep };
    }
    property real nowMs: Date.now()
    Timer {
        // the beacon's ring counts down: a tick a second while it shows, nothing else
        running: root._live && root.state_.beacon.on && !root._still
        interval: 1000
        repeat: true
        onTriggered: root.nowMs = Date.now()
    }
    readonly property var _described: Facts.describe(root._facts, root.nowMs)
    // what the displays say of the speed test, and the label printed by the power-on: laid over the facts' own picture (the cells of a display are the facts' unless the test is asked)
    property real displayNow: Date.now()
    property real openedAtMs: 0
    property real doneAtMs: 0
    property bool _confirmedLocal: false
    readonly property var _speed: root.service ? root.service.speed : null
    readonly property bool speedShown: Speed.shown(root._speed, root.openedAtMs)
    readonly property int _printStep: Math.floor(Math.max(0, Math.min(1, (root.enter - 0.55) / 0.4)) * 12)
    readonly property real capMB: root.service && root.service.config && root.service.config.speedTest ? root.service.config.speedTest.capMB : 200
    readonly property string askText: Speed.askText(root._speed, root.capMB, root._confirmedLocal)
    // the question, engraved where the rates' name is while it is asked ("RUN? 200 MB", the refusal's reason): the board's silk is text, the cells are not
    readonly property string _engraving: Speed.engraving(root._speed, root.capMB, root._confirmedLocal)
    readonly property var state_: {
        const d = root._described;
        const sp = root._speed;
        const shown = root.speedShown;
        const typed = root._printStep < 12;
        if (!shown && !typed)
            return d;
        const out = Object.assign({}, d);
        if (shown) {
            out.rates = Speed.ratesCells(sp, root.capMB, d.rates, root.displayNow, Facts, root.displayNow - root.doneAtMs);
            out.usage = Speed.usageCells(sp, d.usage, Facts);
            // the engraved units follow what the displays say (`ms` over a latency figure, the figure's own rate unit over a result)
            out.units = Speed.units(sp, d.units, Facts, root.displayNow - root.doneAtMs);
        }
        if (typed) {
            const k = root._printStep / 12, l = d.label;
            const cut = t => String(t || "").slice(0, Math.ceil(String(t || "").length * k));
            out.label = Object.assign({}, l, { name: cut(l.name), lineA: cut(l.lineA), lineB: cut(l.lineB), via: cut(l.via) });
        }
        return out;
    }

    AerialScene {
        id: boardScene
        width: Cam.DESIGN_WIDTH
        family: root.family
        renderScale: root.renderScale * root.stageScale
        oldMap: root.oldMap
        oldDark: root.oldDark
        animate: root.animate
        halted: root._hard || !root._live
        resting: root._halt
        power: root.power * root.sceneP
        nowMs: root.nowMs
        state: root.state_
        silkTexts: root._engraving !== "" ? ({ rates: root._engraving }) : ({})
    }

    // ======================================================================================
    // The life: shown, the power-on, the idle ladder, the theme hold
    // ======================================================================================
    // shown and not parked: only then does anything run (a parked content runs nothing and asks nothing)
    readonly property bool _live: root.open && !root.parked
    // RUNNING OR SAVING POWER, as silicon (round 4; aerial's instance of the shared ladder, silicon's times): the popup runs at its one rate until `haltAfterMs` (30 s)
    // without the pointer, then the scene's own motion eases to rest over a second (AerialScene's live layer) and no clock runs: 0 frames. The ladder's middle rung
    // ("calm") is not used here: a slower beat read as a low frame rate. A pointer motion, a press, a network event (what the facts say of the link, the devices, the
    // hotspot, the tunnel) and anything that is being worked (a panel open, a hologram carried) wake it. The host's `halted` flag is an override (a mockup's switch).
    IdleLadder {
        id: ladder
        open: root._live
        haltAfterMs: root.haltAfterMs
    }
    readonly property bool _halt: ladder.level === "halt"
    // a still picture AT ONCE: the host's switch, and a theme crossfade (a still picture of the frame before: whatever kept moving under it would be a second copy)
    readonly property bool _hard: root.halted || Theme.crossfading
    // nothing runs: that, or the ladder's halt once the scene has come to rest
    readonly property bool _still: root._hard || (root._halt && boardScene.atRest)
    function touch(): void {
        ladder.touch();
    }
    readonly property string _eventKey: {
        const s = root.service;
        if (!s)
            return "";
        const w = s.wifi, b = s.bt, h = s.hotspot, p = s.proton;
        return [root._activeKey, h && h.active ? "hs" : "", p ? p.state : "", s.airplane && s.airplane.on ? "air" : "",
                b && b.devices ? b.devices.map(d => d.address + (d.connected ? "+" : "") + (d.pairing ? "p" : "")).join(",") : "", b && b.prompt ? "prompt" : "",
                w ? w.radioOn : "", b ? b.powered : ""].join("|");
    }
    on_EventKeyChanged: if (root._live) ladder.touch()
    Timer {
        // somebody is working the popup (a panel is open, a hologram is carried or held): it does not go still under their hands
        running: root._live && (root.secondaryOpen || dragCtl.phase !== "idle" || globeLayer.pending !== "")
        interval: 4000
        repeat: true
        onTriggered: ladder.touch()
    }
    on_LiveChanged: {
        if (root._live) {
            root.openedAtMs = Date.now();
            root._confirmedLocal = false;
            boardScene.wake();
            if (!root.prewarm)
                root._playEntrance();
        } else {
            root.closeSecondary();
            armTimer.stop();
        }
        root._publishSecondary();
    }

    // THE POWER-ON, one clock (`enter`, 0..1, ~600 ms): the card's lights come up first, the cloud comes up over the label (its field fades in on this clock; its tags are dealt
    // in from the inner arc out by the cloud's own float clock), the globe spins up (its fade is its spin), the label is typed. Every part reads its own stretch of the one clock
    // (`_seg`); a harness, a prewarm and a snap (`entranceEnabled: false`, `animate: false`) are simply on.
    property real enter: 1
    property int powerOnMs: 600
    function _seg(a: real, b: real): real {
        const t = Math.max(0, Math.min(1, (root.enter - a) / (b - a)));
        return t * t * (3 - 2 * t);
    }
    readonly property real sceneP: root._seg(0, 0.45)
    readonly property real cloudP: root._seg(0.15, 0.90)
    readonly property real globeP: root._seg(0.35, 0.95)
    readonly property bool entering: enterAnim.running
    function _playEntrance(): void {
        enterAnim.stop();
        if (!root.entranceEnabled || !root.animate || root.prewarm) {
            root.enter = 1;
            return;
        }
        root.enter = 0;
        enterAnim.restart();
    }
    NumberAnimation {
        id: enterAnim
        target: root
        property: "enter"
        from: 0
        to: 1
        duration: root.powerOnMs
        easing.type: Easing.Linear
    }
    // The engine keeps the content parked after its popup closed and hands it to the next open: what a NEW content starts as. The secondary goes, the hand is let go of, the
    // entrance starts from dark again, the ladder is awake.
    function recycle(): void {
        root.closeSecondary();
        armTimer.stop();
        root._pendingKey = "";
        root._speedReset();
        enterAnim.stop();
        root.enter = root.prewarm || !root.entranceEnabled ? 1 : 0;
        boardScene.wake();
        ladder.touch();
    }
    Component.onCompleted: {
        if (root._live) {
            root.openedAtMs = Date.now();
            root._playEntrance();
        } else {
            root.enter = root.prewarm || !root.entranceEnabled || !root.animate ? 1 : 0;
        }
        root._publishSecondary();
    }

    // ---- the mechanical sounds ----
    AerialSounds {
        id: sounds
        scene: boardScene
        drag: dragCtl
        active: root._live && root.soundsEnabled
    }
    readonly property alias sounds: sounds
    readonly property alias ladder: ladder

    // ---- the air: THE SIGNAL FAN (CloudHolo: the networks, the own hotspot and the Bluetooth devices that are not connected, standing on the label's centre), one drag
    // controller. QML above the cached board, never inside it. Its clock is the SCENE's one beat (`boardScene.time`: 30 Hz alive, 10 Hz calm, nothing when still), so the
    // cloud's pulse and its float add no frame of their own. ----
    readonly property var _zone: CP.zonePoly(boardScene.geo, boardScene.labelMap, boardScene.geo.LABEL_ZONE)
    readonly property var _btZone: CP.zonePoly(boardScene.geo, boardScene.labelMap, boardScene.geo.LABEL_BT)
    readonly property var _labelPoly: CP.zonePoly(boardScene.geo, boardScene.labelMap, { x0: boardScene.geo.LABEL.x0, x1: boardScene.geo.LABEL.x1, y0: boardScene.geo.LABEL.y0, y1: boardScene.geo.LABEL.y1 })
    readonly property var _zoneCentre: CP.centreOf(root._zone)
    readonly property var _btCentre: CP.centreOf(root._btZone)
    readonly property string _activeKey: root.service && root.service.wifi && root.service.wifi.active ? root.service.wifi.active.key : ""
    property string _prevActive: ""
    property string liftKey: ""
    on_ActiveKeyChanged: {
        if (root._activeKey === "" && root._prevActive !== "") {
            root.liftKey = root._prevActive;
            liftReset.restart();
        }
        root._prevActive = root._activeKey;
    }
    Timer {
        id: liftReset
        interval: 1500
        onTriggered: root.liftKey = ""
    }
    // a scan makes the NEXT regular front a stronger one (round 6: it was a front of its own, on another clock and at another speed -- "the intervals seem inconsistent")
    readonly property real _scanStamp: root.service && root.service.wifi ? (root.service.wifi.lastScanMs || 0) : 0
    CloudHolo {
        id: cloudLayer
        anchors.fill: boardScene
        wifi: root.service ? root.service.wifi : null
        hotspot: root.service ? root.service.hotspot : null
        bt: root.service ? root.service.bt : null
        cam: boardScene.cam
        geo: boardScene.geo
        renderScale: root.renderScale * root.stageScale
        power: root.power * root.cloudP * (1 - boardScene.airplaneT)
        time: boardScene.time
        live: boardScene.live
        halted: root._still || !root._live || !root.animate
        scanStamp: root.animate && root._live ? root._scanStamp : 0
        tint: boardScene.style.accent
        fontFamily: root.fontFamily
        hoverKey: dragCtl.hoverKey
        carriedKey: dragCtl.carriedKey
        btCarried: dragCtl.carriedKind === "bt" || dragCtl.carriedKind === "btdock"
        wifiCentre: root._zoneCentre
        btCentre: root._btCentre
        activeKey: root._activeKey
        liftKey: root.liftKey
        cover: Qt.vector4d(globeLayer._fr.cx, globeLayer._fr.cy, globeLayer._fr.rp, globeLayer.grow)
        liftFrom: dragCtl.liftFrom.length ? dragCtl.liftFrom : root._zoneCentre
        open: root.open
        shakeKey: root._shakeWho.indexOf("net:") === 0 ? root._shakeWho.slice(4) : root._shakeWho.indexOf("bt:") === 0 ? root._shakeWho.slice(3) : ""
        shakeX: root._shakeX
    }

    // ---- the room in the label's chrome (the tunnel up): the pointer leads it, and the cloud's front is mirrored in it ----
    // A reflection reads as one only when something in it moves. The pointer moves the room a little (a head that moves sees a mirror's picture shift): `lead`, -1..1 each
    // way about the label's centre over `leadReach` design px. A pointer that comes in FAR from where the room stands does not take it there at once: the room sets off
    // slowly and gathers speed until it has caught the pointer (one clock, an ease-in; the bridge's light does the same), and from then on it is the pointer's. Nothing
    // of it runs while the label is paper (no uniform changes, no frame).
    property real leadReach: 260
    property int leadCatchMs: 420
    property real _leadAimX: 0
    property real _leadAimY: 0
    property real _leadFromX: 0
    property real _leadFromY: 0
    property real _leadCatch: 1
    readonly property real leadX: Math.round((root._leadFromX + (root._leadAimX - root._leadFromX) * root._leadCatch) * 64) / 64
    readonly property real leadY: Math.round((root._leadFromY + (root._leadAimY - root._leadFromY) * root._leadCatch) * 64) / 64
    NumberAnimation {
        id: leadCatch
        target: root
        property: "_leadCatch"
        from: 0
        to: 1
        duration: root.leadCatchMs
        easing.type: Easing.InQuad
    }
    function _leadTo(x: real, y: real): void {
        if (!(boardScene.labelItem.chrome > 0) || !root.animate)
            return;
        const o = cloudLayer.origin;
        const ax = Math.max(-1, Math.min(1, (x - o[0]) / root.leadReach)), ay = Math.max(-1, Math.min(1, (y - o[1]) / root.leadReach));
        if (!leadCatch.running && Math.hypot(ax - root.leadX, ay - root.leadY) > 0.45) {
            root._leadFromX = root.leadX;
            root._leadFromY = root.leadY;
            root._leadCatch = 0;
            leadCatch.restart();
        }
        root._leadAimX = ax;
        root._leadAimY = ay;
    }
    Binding { target: boardScene; property: "lead"; value: Qt.vector2d(root.leadX, root.leadY) }
    Binding { target: boardScene; property: "pulseRadius"; value: cloudLayer.fieldOn && cloudLayer.radioOn ? CP.pulseRadius(cloudLayer.phase, cloudLayer.rEnd) : -1 }
    Binding { target: boardScene; property: "pulseStrength"; value: cloudLayer.pulseAlpha * Math.max(0, Math.min(1, cloudLayer.power)) }

    // ---- the VPN's globe (stream G's layer; the pointer is routed by the drag controller, so the globe's own area is off) ----
    GlobeLayer {
        id: globeLayer
        anchors.fill: boardScene
        cam: boardScene.cam
        geo: boardScene.geo
        family: root.family
        dark: boardScene.dark
        renderScale: root.renderScale * root.stageScale
        catalog: root.service ? root.service.catalog : null
        proton: root.service ? root.service.proton : null
        // (airplane: the globe dims with everything else -- no tunnel without a link -- but stays, its panel is still a click away)
        power: root.power * root.globeP * (1 - 0.6 * boardScene.airplaneT)
        halted: root._still
        tempo: boardScene.live
        interactive: false
        dragged: dragCtl.carriedKind === "country" || dragCtl.carriedKind === "tunnel" ? dragCtl.carriedKey : ""
        hoverCode: dragCtl.globeHover
        held: globeGesture.held
        transform: Translate { x: root._shakeWho === "globe" ? root._shakeX : 0 }
    }

    // ---- the input, by arithmetic ----
    BoardInput {
        id: input
        anchors.fill: boardScene
        pickPart: (x, y) => boardScene.pickPart(x, y)
        intentFor: (part, x, y) => Layout.intentFor(boardScene.geo, part)
        anchorFor: intent => {
            const p = Layout.anchorPoint(boardScene.geo, intent, boardScene.pickState());
            if (!p)
                return [0, 0];
            const q = Cam.project(p, boardScene.cam);
            return [q.x, q.y];
        }
        zoneFor: (x, y) => ""
        onClicked: (intent, at) => root._clicked(intent, at)
        onActivity: ladder.touch()
    }

    // ---- the drag: one controller for every hologram; a press on nothing of its own falls through to the board's input above ----
    DragController {
        id: dragCtl
        anchors.fill: boardScene
        service: root.service
        cloud: cloudLayer
        globe: globeLayer
        label: boardScene.labelItem
        geo: boardScene.geo
        labelMap: boardScene.labelMap
        zone: root._zone
        btZone: root._btZone
        labelPoly: root._labelPoly
        renderScale: root.renderScale * root.stageScale
        time: boardScene.time
        enabled: root.open
        onActivated: (intent, at) => root._clicked(intent, at)
        onPhaseChanged: {
            if (dragCtl.phase !== "held" && root._pendingKey !== "" && dragCtl.heldKey === "")
                root._pendingResolved();
            ladder.touch();
        }
    }
    GlobeGesture {
        id: globeGesture
        anchors.fill: boardScene
        globe: globeLayer
        enabled: root.open && dragCtl.phase === "idle"
        onActivity: ladder.touch()
    }
    HoverHandler {
        // on the stage (an ancestor of the board's input and the controller): a handler over a link would take the link's hover
        id: holoHover
        property real _lx: -1
        property real _ly: -1
        cursorShape: dragCtl.dragging ? Qt.ClosedHandCursor : dragCtl.hot ? Qt.PointingHandCursor : Qt.ArrowCursor
        onPointChanged: {
            // a hover acts only after a MOTION: a resting pointer's re-delivered point is not one
            const x = holoHover.point.position.x, y = holoHover.point.position.y;
            if (x === holoHover._lx && y === holoHover._ly)
                return;
            holoHover._lx = x;
            holoHover._ly = y;
            dragCtl.hoverAt(x, y);
            globeLayer.pointerAt(x, y);
            root._leadTo(x, y);
            ladder.touch();
        }
        onHoveredChanged: if (!holoHover.hovered) { dragCtl.hoverAt(-1, -1); globeLayer.pointerAt(-1, -1); }
    }
    readonly property alias drag: dragCtl
    readonly property alias cloud: cloudLayer
    readonly property alias globe: globeLayer
    readonly property alias globeGesture: globeGesture


    // ======================================================================================
    // The cue: what a failed intent does to the part it names (the toast says what went wrong; this is the part flinching)
    // ======================================================================================
    // ONE short physical cue, on one animation clock (`_shakeT`, the render loop's: never a timer racing the frame): the label, a dot or a device figure and the globe shake a few
    // px, damped (~300 ms); a DIP lever is shoved and falls back onto the pose the facts put it at; a pad's LED blinks twice (both in the scene). A part the popup knows no cue for
    // does nothing. Nothing persists: every offset is zero again when the clock ends.
    property real _shakeT: 1
    property string _shakeWho: ""                       // what shakes: "label" | "globe" | "net:<key>" | "bt:<address>" (a tag of the cloud)
    property real _shakeAmp: 3                          // px at the first swing
    readonly property real _shakeX: {
        if (root._shakeWho === "" || root._shakeT >= 1)
            return 0;
        const rs = root.renderScale * root.stageScale > 0.01 ? root.renderScale * root.stageScale : 1;
        return Math.round(root._shakeAmp * (1 - root._shakeT) * Math.sin(root._shakeT * 2 * Math.PI * 3) * rs) / rs;
    }
    NumberAnimation {
        id: shakeAnim
        target: root
        property: "_shakeT"
        from: 0
        to: 1
        duration: 300
        onFinished: root._shakeWho = ""
    }
    Binding {
        target: boardScene.labelItem
        property: "x"
        value: root._shakeX
        when: root._shakeWho === "label"
    }
    // what shakes is told by name: the label's item takes the offset through the Binding above, a tag of the cloud through the cloud's `shakeKey` / `shakeX`, the globe
    // through its own Translate
    function _shake(who: string, amp: real): void {
        root._shakeWho = who;
        root._shakeAmp = amp;
        shakeAnim.restart();
    }
    function _cue(part: string): void {
        // (a tunnel request that failed: the asked light stops pulsing, whatever else the cue does)
        if (part === "globe")
            globeLayer.answered();
        if (!root._live || !root.animate || root.entering)
            return;
        ladder.touch();
        if (part === "label" || part === "hotspot") {
            root._shake("label", 3);
        } else if (part.indexOf("net:") === 0 || part.indexOf("bt:") === 0) {
            // its tag in the air; a thing that is not there (the docked network, a connected device: both are on the label) shakes the label
            root._shake(cloudLayer.tagOf(part.slice(part.indexOf(":") + 1)) ? part : "label", 3);
        } else if (part === "globe") {
            root._shake("globe", 2.5);
        } else if (part === "dip.wifi") {
            boardScene.cueDip("wifi");
        } else if (part === "dip.bt") {
            boardScene.cueDip("bt");
        } else if (part.indexOf("pad.") === 0) {
            boardScene.cuePad(part.slice(4));
        }
    }

    // ======================================================================================
    // The clicks, the secondary and the speed test
    // ======================================================================================
    // A click on a part / hologram, in the stage's design px. The owner answers the board's own switches (it hears `partActivated` for every intent); the popup answers
    // the rest: a panel, or the speed test.
    function _clicked(intent: string, at: point): void {
        ladder.touch();
        root._byKey = false;
        if (intent === "") {
            root._clickedAway();
            return;
        }
        // A COUNTRY'S LIGHT on the globe connects there (Proton's own pick of a server for it); the country the tunnel already runs through opens the VPN panel instead
        if (intent.indexOf("country:") === 0) {
            const code = intent.slice(8), s = root.service, p = s ? s.proton : null;
            // THE "FASTEST" LIGHT IS A TOGGLE (round 5): while the tunnel up is the one it raised (the facts' `fastest`), its click takes the tunnel down -- it does not
            // go looking for another fastest server. Any other time it raises one (also over a tunnel through a chosen country: that is a switch).
            if (code === "fastest" && s && p && p.state === "up" && p.fastest === true) {
                root.partActivated(intent, at);
                if (root._pendingKey !== "")
                    root._dropPending();
                globeLayer.ask("fastest", "down");
                s.vpnDisconnect();
                return;
            }
            if (!(p && p.state === "up" && p.server && p.server.country === code)) {
                root.partActivated(intent, at);
                if (root._pendingKey !== "")
                    root._dropPending();
                if (s && !(p && (p.state === "connecting" || p.state === "disconnecting"))) {
                    globeLayer.ask(code, "up");
                    s.vpnConnect(globeLayer.connectArgs(code));
                }
                return;
            }
            intent = "globe";
        }
        root.partActivated(intent, at);
        const key = root._keyOf(intent);
        // anything but the pending password's own hologram lets the pending go (it drifts back)
        if (root._pendingKey !== "" && key !== root._pendingKey)
            root._dropPending();
        if (intent === "rates") {
            root._clickRates();
            return;
        }
        if (key === "")
            return;
        if (intent.indexOf("net:") === 0 && dragCtl.heldKey === intent.slice(4)) {
            // a secured stranger dropped on the label: the password is asked first, and it wins over a browse
            root._pendingKey = key;
            root._pendingAnchor = root._anchorOfKey(key, at);
        } else if (root._panelKey === key) {
            root.closeSecondary();
            return;
        } else {
            root._panelKey = key;
            root._panelAnchor = root._anchorOfKey(key, at);
        }
        root._publishSecondary();
    }
    // A part opened by a KEY (a keyboard path of the owner): its panel's field takes the keys at once, the pointer need not move into it first
    property bool _byKey: false
    function openByKey(intent: string): void {
        root._clicked(intent, Qt.point(0, 0));
        root._byKey = root.secondaryOpen;
    }
    // the panel key an intent opens ("" = none): stream P's keys (AerialSecondary)
    function _keyOf(intent: string): string {
        const s = root.service;
        if (intent === "label") {
            if (s && s.hotspot && s.hotspot.active)
                return "hotspot";
            return "network:" + (root._activeKey);
        }
        if (intent.indexOf("net:") === 0)
            return "network:" + intent.slice(4);
        if (intent.indexOf("bt:") === 0)
            return intent;
        if (intent === "hotspot")
            return "hotspot";
        if (intent === "globe")
            return "vpn";
        if (intent === "mem")
            return "saved";
        if (intent === "usage")
            return "usage";
        if (intent === "jack") {
            const jacks = s && s.wired && s.wired.jacks ? s.wired.jacks : [];
            const j = jacks.find(x => x.kind === "rj45") || jacks[0];
            return "wired:" + (j ? j.iface : "");
        }
        if (intent.indexOf("pad.") === 0)
            return "pad:" + intent.slice(4);
        return "";
    }
    // where a panel hangs: the hologram's / the part's place (design px)
    function _anchorOfKey(key: string, at: point): point {
        const kind = key.indexOf(":") >= 0 ? key.slice(0, key.indexOf(":")) : key;
        let intent = "";
        if (kind === "network" || kind === "hotspot")
            return Qt.point(root._zoneCentre[0], root._zoneCentre[1]);
        if (kind === "bt") {
            // its tag in the air, or its row on the label (a connected device), else the label's Bluetooth zone
            const h = cloudLayer.homeOf(key.slice(3));
            if (h)
                return Qt.point(h[0], h[1]);
            const lab = boardScene.labelItem;
            const sp = typeof lab.btDeviceSpot === "function" ? lab.btDeviceSpot(key.slice(3)) : null;
            const q = sp ? CP.labelPx(boardScene.geo, boardScene.labelMap, sp[0], sp[1]) : root._btCentre;
            return Qt.point(q[0], q[1]);
        } else if (kind === "vpn") {
            intent = "globe";
        } else if (kind === "saved") {
            intent = "mem";
        } else if (kind === "wired") {
            intent = "jack";
        } else if (kind === "pad") {
            intent = "pad." + key.slice(4);
        } else if (kind === "usage") {
            intent = "usage";
        }
        if (intent === "globe") {
            // the globe's own place: the lens cap's projection is the lenses; the globe's centre is where its hologram stands
            const g = Layout.anchorPoint(boardScene.geo, "globe", boardScene.pickState());
            if (g) {
                const q = Cam.project(g, boardScene.cam);
                return Qt.point(q.x, q.y);
            }
        }
        const p = Layout.anchorPoint(boardScene.geo, intent, boardScene.pickState());
        if (!p)
            return at;
        const q = Cam.project(p, boardScene.cam);
        return Qt.point(q.x, q.y);
    }

    // ---- the one secondary slot ----
    // The five aim / key members of the engine's content contract are WRITTEN, not bound (the engine reads the whole contract in the handler of whichever changed first):
    // one function decides all of them from the raw facts and writes the aim first and the key LAST (first when it closes). Silicon's pattern (SiliconPopup._publishSecondary).
    property string _panelKey: ""               // a browse: the part the user clicked
    property point _panelAnchor: Qt.point(0, 0)
    property string _pendingKey: ""             // a secured stranger's password: the label's network panel with the field focused
    property point _pendingAnchor: Qt.point(0, 0)
    property var secondaryKey: null
    property bool secondaryOpen: false
    property point secondaryAnchor: Qt.point(0, 0)
    property real secondaryAnchorAt: 0.5
    property real secondaryWidthFrom: 0.5
    // THE DETAIL JOINS ALONG ITS LONG EDGE as stocks' does: the side the screen has room for, centred on the clicked part's y (anchor point 0.5, clamped to the popup's
    // edge span by the engine), overhanging the popup's ends only when it is taller than the popup (its NATURAL height, which the engine cannot move), a flush join (inset 0)
    property string _sideNow: "start"
    readonly property string secondarySide: root._sideNow
    property real _detailH: 0
    readonly property real detailWidth: 360                 // PanelStyle.panelWidth, design px: what the side is judged by before the panel exists
    readonly property bool _detailLonger: root._detailH > root.implicitHeight + 0.5
    readonly property bool secondaryOverhang: root._detailLonger
    readonly property real secondaryInset: 0
    // the slot's key by precedence: a pairing question, a pending password, a browse ("" none). Read from the raw facts.
    // (a question the user put away -- Escape on its panel -- stays away until BlueZ asks another: `_promptMuted`)
    property string _promptMuted: ""
    function _promptRaw(): string {
        const s = root.service;
        return s && s.bt && s.bt.prompt && s.bt.prompt.address ? "bt:" + s.bt.prompt.address + "#" + (s.bt.prompt.rid !== undefined ? s.bt.prompt.rid : "") : "";
    }
    function _promptKey(): string {
        const r = root._promptRaw();
        return r === "" || r === root._promptMuted ? "" : r.slice(0, r.indexOf("#"));
    }
    function _dueKey(): string {
        if (!root._live)
            return "";
        const pk = root._promptKey();
        return pk !== "" ? pk : (root._pendingKey !== "" ? root._pendingKey : root._panelKey);
    }
    // the side the panel has room on: the preferred one unless the screen's edge is nearer than the panel is wide there (then the other, when it has more). Read at the OPEN
    // only (a panel that stands does not hop sides when the popup moves)
    function _fitSide(pref: string): string {
        if (pref !== "start" && pref !== "end")
            return pref;
        const win = root.Window.window;
        if (!win || !(win.width > 0))
            return pref;
        const x0 = root.mapToItem(null, 0, 0).x;
        const left = x0, right = win.width - (x0 + root.implicitWidth);
        const need = root.detailWidth * root.stageScale;
        if (pref === "start")
            return left >= need || left >= right ? "start" : "end";
        return right >= need || right >= left ? "end" : "start";
    }
    function _publishSecondary(): void {
        const due = root._dueKey();
        if (due === "") {
            root.secondaryOpen = false;
            root.secondaryKey = null;
            return;                                // (the aim stays what it was: it is the closing child's)
        }
        let at;
        if (due === root._promptKey() && due !== root._pendingKey && due !== root._panelKey)
            at = root._anchorOfKey(due, Qt.point(0, 0));
        else
            at = due === root._pendingKey ? root._pendingAnchor : root._panelAnchor;
        // (in the CONTENT's units, which the engine reads: the design px of the stage, times its scale)
        root.secondaryAnchor = Qt.point(at.x * root.stageScale, at.y * root.stageScale);
        if (!root.secondaryOpen) {
            root._sideNow = root._fitSide(root.sidePreference);
            root._detailH = 0;
        }
        root.secondaryAnchorAt = 0.5;
        root.secondaryWidthFrom = root.defaultWidthFrom;
        root.secondaryKey = due;
        root.secondaryOpen = true;
    }
    property real defaultWidthFrom: 0.5
    on_PanelKeyChanged: root._publishSecondary()
    on_PendingKeyChanged: root._publishSecondary()
    onSidePreferenceChanged: if (!root.secondaryOpen) root._sideNow = root.sidePreference
    onImplicitWidthChanged: root._publishSecondary()
    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onCue(part: string): void {
            root._cue(part);
        }
        function onSerialChanged(): void {
            // a pairing question arrives (or goes) with the facts
            if (root._promptRaw() === "")
                root._promptMuted = "";
            if (root._promptKey() !== root._lastPrompt) {
                root._lastPrompt = root._promptKey();
                root._publishSecondary();
            }
        }
    }
    property string _lastPrompt: ""
    // Whatever the user can put away: the panel, the pending password (a hologram on its way home), the speed test's question.
    function closeSecondary(): void {
        const was = root._pendingKey !== "";
        if (root._promptKey() !== "" && root.secondaryKey === root._promptKey() && root._pendingKey === "" && root._panelKey !== root._promptKey())
            root._promptMuted = root._promptRaw();
        root._panelKey = "";
        root._byKey = false;
        if (was)
            root._dropPending();
        root._publishSecondary();
    }
    // a secured stranger's password given up (Escape, a click away, the panel dismissed): the hologram drifts back to where it came from, unless the attempt is under way
    function _dropPending(): void {
        const k = root._pendingKey;
        root._pendingKey = "";
        if (k === "")
            return;
        const net = k.slice(8);
        const n = root.service && root.service.wifi && root.service.wifi.networks ? root.service.wifi.networks.find(x => x.key === net) : null;
        if (!n || n.state !== "connecting")
            dragCtl.giveUp(net);
    }
    // the held hologram resolved by the service (it docked, or it failed away): the password panel stays as a browse when it docked
    function _pendingResolved(): void {
        const k = root._pendingKey;
        root._pendingKey = "";
        if (k !== "" && root._activeKey === k.slice(8)) {
            root._panelKey = k;
            root._panelAnchor = root._pendingAnchor;
        }
    }
    // a click on nothing: the pending password is given up
    function _clickedAway(): void {
        if (root._pendingKey !== "")
            root._dropPending();
    }
    // Escape: what the open panel is in the middle of goes first (the saved list's search clears: its `handleEscape()` answers true); else
    // false, and the engine decides (GooeyEngine.escapeDetailFirst): the popup closes with its panel, or `stepBack()` puts the panel away first
    function handleEscape(): bool {
        if (root.secondaryOpen) {
            const sec = root._liveSecondary();
            if (sec && sec.handleEscape())
                return true;
        }
        return false;
    }
    function stepBack(): bool {
        if (!root.secondaryOpen)
            return false;
        root.closeSecondary();
        return true;
    }
    // the newest live secondary content (the engine builds one per open; a fading one may still stand beside it)
    function _liveSecondary(): var {
        let best = null, id = -1;
        for (const k of Object.keys(root._secs)) {
            if (Number(k) > id) {
                id = Number(k);
                best = root._secs[k];
            }
        }
        return best;
    }
    // THE KEYBOARD for a secondary's fields: the engine asks the primary's content only, so the popup asks while a panel wants the keys
    property var _wants: ({})
    property var _secs: ({})
    property bool _secKeys: false
    function _wantsKeys(id: int, on: bool): void {
        if (on)
            root._wants[id] = true;
        else
            delete root._wants[id];
        root._secKeys = Object.keys(root._wants).length > 0;
    }
    readonly property string keyboardFocusRequest: root._secKeys && root.secondaryOpen ? "onDemand" : "none"
    readonly property var _ids: ({ n: 0 })
    property Component secondaryComponent: Component {
        AerialSecondary {
            id: sec
            property int serialId: 0
            vm: root.service
            family: root.family
            renderScale: root.renderScale
            fontFamily: root.fontFamily
            kind: "network"
            onDismissed: root.closeSecondary()
            // a field that is only an OPTION (the saved list's search) is asked for the keys once the pointer has MOVED into the panel (HoverArm: a panel that appeared under a
            // resting pointer takes nothing from the app being typed in), or at once when a key opened it; a field the user must type into (a password, a PIN, an address) asks at once
            readonly property bool optionalKeys: sec.shownKind === "saved" && !!sec.panel && sec.panel.page === "list"
            // (once the pointer has moved in, the request stays while the panel does: OnDemand gives the keys only to a click or a motion anyway)
            property bool _moved: false
            readonly property bool wantsNow: sec.keyboardWanted && (!sec.optionalKeys || root._byKey || sec._moved)
            HoverArm {
                id: keyArm
                target: sec
                active: sec.optionalKeys
                onArmedChanged: if (keyArm.armed) sec._moved = true
            }
            onWantsNowChanged: root._wantsKeys(sec.serialId, sec.wantsNow)
            // the panel's natural size: where the detail sits and whether it overhangs are judged by it (never by the live one, which holds the engine's cutout band)
            readonly property real nat: sec.panel ? sec.panel.implicitHeight : 0
            onNatChanged: root._detailH = sec.nat
            Component.onCompleted: {
                sec.serialId = ++root._ids.n;
                root._secs[sec.serialId] = sec;
                root._detailH = sec.nat;
                root._wantsKeys(sec.serialId, sec.wantsNow);
            }
            Component.onDestruction: {
                delete root._secs[sec.serialId];
                root._wantsKeys(sec.serialId, false);
            }
        }
    }
    readonly property bool secondaryWantsKeys: root._secKeys

    // ---- the speed test on the rates display: a click asks ("RUN? 200 MB", blinking), a second click within `armMs` runs it ----
    // A refusal (a public or a metered network) shows its reason beside the display and needs one more confirm (the service's: armed + refused, a click confirms, the next runs).
    function _clickRates(): void {
        const s = root.service;
        if (!s || !s.speed)
            return;
        const st = s.speed.state;
        if (st === "latency" || st === "down" || st === "up")
            return;                                // it is running: a click on the display does nothing
        if (st === "armed") {
            if (s.speed.refused !== "" && !root._confirmedLocal)
                root._confirmedLocal = true;
            else
                armTimer.stop();
            s.runSpeedTest();
            if (root._confirmedLocal && s.speed.state === "armed")
                armTimer.restart();
            return;
        }
        root._confirmedLocal = false;
        root.displayNow = Date.now();
        s.armSpeedTest();
        armTimer.restart();
    }
    function _speedReset(): void {
        root._confirmedLocal = false;
        root.doneAtMs = 0;
        const s = root.service;
        if (s && s.speed && s.speed.state === "armed" && typeof s.cancelSpeedTest === "function")
            s.cancelSpeedTest();
    }
    Timer {
        // the question is forgotten if the second click does not come
        id: armTimer
        interval: root.armMs
        onTriggered: root._speedReset()
    }
    // the displays blink while the question stands, and alternate down / up after a result (a beat of their own, only while it is the display's business)
    readonly property string _speedState: root._speed ? root._speed.state : "idle"
    on_SpeedStateChanged: {
        if (root._speedState === "done")
            root.doneAtMs = Date.now();
        root.displayNow = Date.now();
    }
    Timer {
        running: root._live && !root._still && root.speedShown && (root._speedState === "armed" || (root._speedState === "done" && root.displayNow - root.doneAtMs < 9500))
        interval: 175
        repeat: true
        onTriggered: root.displayNow = Date.now()
    }
}
