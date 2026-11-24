pragma ComponentBehavior: Bound

import QtQuick

import "AerialGeometry.js" as Geo
import "AerialCamera.js" as Cam
import "AerialFacts.js" as Facts

// =============================================================================
// AerialScene.qml -- aerial's board as the popup draws it: the cached board layer, ONE live patch over whatever is moving (the card tilting out with its screw, a DIP
// lever, the button, the plug: the union of their rects, which is also the board's hole), the live label and the silk laid over it, and the live light on top. It shows the
// facts the popup hands it (`state`, AerialFacts.describe) and eases between them on its own clocks; it asks the service for nothing.
//
// THE SCHEME (CLAUDE.md "cached layer + hole + live patch"): the board is a layer that renders again only when a uniform changes. While something moves, the board
// holds every moving group where it stood and leaves the patch's rect transparent (`hole`); the patch draws the SAME scene, whole, in that rect, uncached, with the live
// poses. When everything has settled the patch hides and the board takes the final poses in the same frame. A light (LEDs, lit segments, the beacon's ring) is never in a
// layer: GlowLayer is a live shader over the whole scene. The label is QML under the card's affine map (the shield plane), so it tilts with the card, crisp.
// 0 frames when still: nothing here runs a clock unless something blinks (the beacon, a searching button, a pad under test) or a pose is easing.
// =============================================================================
Item {
    id: root

    implicitWidth: Cam.DESIGN_WIDTH
    implicitHeight: root.naturalHeight

    // ---- in ----
    property int family: 0
    property real renderScale: 1
    property var oldMap: null
    property bool oldDark: false
    readonly property AerialStyle style: AerialStyle {
        family: root.family
        oldMap: root.oldMap
        oldDark: root.oldDark
    }
    readonly property bool dark: root.style.dark
    property real lightAngle: 128
    property real lightElevation: 0.52
    property real shadowStrength: 0.62
    // what the board shows (AerialFacts.describe): null = the board at rest, everything off
    property var state: null
    property var silkTexts: ({})            // engraved names that replace a label whole (the popup: the speed test's question on RATE)
    property bool animate: true             // false snaps every pose (a popup that opens, a gate)
    property bool halted: false             // a still picture at once: no clock runs (a theme crossfade, a closed popup, a harness)
    property bool resting: false            // the idle ladder's halt: the scene's own motion eases to rest (`live`), and then no clock runs
    property real nowMs: Date.now()         // the beacon's ring reads it (the host's clock)
    property real power: 1                  // the entrance 0..1 (the lights come up)
    property real patchMargin: 2

    // ---- the poses (eased) ----
    readonly property var _s: root.state || Facts.describe(null, 0)
    property real airplaneT: root._s.airplane ? 1 : 0           // 0 seated .. 1 the card up: the screw lifts first, the card follows
    property real dipWifiPose: root._s.wifiOn ? 1 : 0
    property real dipBtPose: root._s.btOn ? 1 : 0
    property real plugPose: root._s.plugged ? 1 : 0
    property real btnPose: 0                                    // 0 up .. 1 pressed (the host presses it: a click)
    // THE CUES (a failed intent, `cueDip` / `cuePad`): a lever is shoved toward the other end and falls back onto the pose the facts put it at (an offset ON the eased pose,
    // so nothing is written to a bound property), a pad's LED blinks twice in the error colour. A moment, never a state: both end at zero by themselves.
    property real dipCueW: 0
    property real dipCueB: 0
    property real _kickW: 0
    property real _kickB: 0
    property real padCue: 0                                     // 0..1 over the blinks
    property int padCueIdx: -1
    readonly property real dipWShown: root.dipWifiPose + root.dipCueW
    readonly property real dipBShown: root.dipBtPose + root.dipCueB
    Behavior on airplaneT {
        enabled: root.animate
        NumberAnimation { id: airAnim; duration: 760; easing.type: Easing.InOutCubic }
    }
    Behavior on dipWifiPose {
        enabled: root.animate
        NumberAnimation { id: dwAnim; duration: 150; easing.type: Easing.OutCubic }
    }
    Behavior on dipBtPose {
        enabled: root.animate
        NumberAnimation { id: dbAnim; duration: 150; easing.type: Easing.OutCubic }
    }
    Behavior on plugPose {
        enabled: root.animate
        NumberAnimation { id: plAnim; duration: 420; easing.type: Easing.InOutCubic }
    }
    Behavior on btnPose {
        enabled: root.animate
        NumberAnimation { id: btAnim; duration: 90; easing.type: Easing.OutCubic }
    }
    readonly property real screwShare: 0.35
    readonly property real screwLift: Math.min(1, root.airplaneT / root.screwShare) * root.geo.SCREW.lift
    readonly property real cardTilt: Math.max(0, (root.airplaneT - root.screwShare) / (1 - root.screwShare)) * root.geo.CARD.tilt
    readonly property real btnDown: root.btnPose * root.geo.BTN.travel

    readonly property bool cardMoving: airAnim.running || (root.airplaneT > 0.0005 && root.airplaneT < 0.9995)
    readonly property bool dipMoving: dwAnim.running || dbAnim.running || cueWAnim.running || cueBAnim.running
    readonly property bool btnMoving: btAnim.running
    readonly property bool plugMoving: plAnim.running
    readonly property bool anyMoving: root.cardMoving || root.dipMoving || root.btnMoving || root.plugMoving

    // what the cached board shows: the settled poses, held while anything moves (its hole is the patch's rect)
    property real _bAir: 0
    property real _bDipW: 0
    property real _bDipB: 0
    property real _bPlug: 1
    property real _bBtn: 0
    function _settle() {
        root._bAir = root.airplaneT;
        root._bDipW = root.dipWifiPose;
        root._bDipB = root.dipBtPose;
        root._bPlug = root.plugPose;
        root._bBtn = root.btnPose;
    }
    onAnyMovingChanged: {
        if (!root.anyMoving)
            root._settle();
    }
    Component.onCompleted: root._settle()
    function snap() {
        root._settle();
    }

    // ---- geometry and camera ----
    readonly property var geo: JSON.parse(Geo.json())
    readonly property var _fit: Cam.fitNatural(root.geo, root.width, { l: 14, r: 14, t: 12, b: 14 })
    readonly property var cam: ({ s: root._fit.s, ox: root._fit.ox, oy: root._fit.oy })
    readonly property int naturalHeight: root._fit.height
    readonly property var light3: Cam.lightDir(root.lightAngle, root.lightElevation)

    function _clip(r: var): var {
        const x0 = Math.max(0, r.x), y0 = Math.max(0, r.y);
        return { x: x0, y: y0, w: Math.max(0, Math.min(Math.ceil(root.width), r.x + r.w) - x0), h: Math.max(0, Math.min(Math.ceil(root.height), r.y + r.h) - y0) };
    }
    readonly property var _rects: ({
        card: root._clip(Cam.cardRect(root.geo, root.cam, 6, root.light3)),
        dip: root._clip(Cam.dipRect(root.geo, root.cam, 6, root.light3)),
        btn: root._clip(Cam.btnRect(root.geo, root.cam, 6, root.light3)),
        plug: root._clip(Cam.plugRect(root.geo, root.cam, 6, root.light3))
    })
    // the patch: the union of the rects of what is moving (also the board's hole)
    readonly property var patchRect: {
        const rs = [];
        if (root.cardMoving) rs.push(root._rects.card);
        if (root.dipMoving) rs.push(root._rects.dip);
        if (root.btnMoving) rs.push(root._rects.btn);
        if (root.plugMoving) rs.push(root._rects.plug);
        if (!rs.length)
            return { x: 0, y: 0, w: 0, h: 0 };
        let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
        rs.forEach(r => { x0 = Math.min(x0, r.x); y0 = Math.min(y0, r.y); x1 = Math.max(x1, r.x + r.w); y1 = Math.max(y1, r.y + r.h); });
        return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    }
    readonly property var patchBox: {
        const r = root.patchRect, m = Math.max(0, root.patchMargin) / (root.renderScale > 0.01 ? root.renderScale : 1);
        const x0 = Math.max(0, r.x - m), y0 = Math.max(0, r.y - m);
        const x1 = Math.min(Math.ceil(root.width), r.x + r.w + m), y1 = Math.min(Math.ceil(root.height), r.y + r.h + m);
        return { x: x0, y: y0, w: Math.max(0, x1 - x0), h: Math.max(0, y1 - y0) };
    }
    readonly property vector4d holeRect: root.anyMoving ? Qt.vector4d(root.patchRect.x, root.patchRect.y, root.patchRect.x + root.patchRect.w, root.patchRect.y + root.patchRect.h) : Qt.vector4d(0, 0, 0, 0)

    // the pick's frames of RIGHT NOW (what is drawn where)
    function pickState(): var {
        return { tilt: root.cardTilt, screwLift: root.screwLift, dipW: root.dipWShown, dipB: root.dipBShown, btnDown: root.btnDown, plugIn: root.plugPose };
    }
    function pickPart(x: real, y: real): string {
        return Cam.pickPart(root.geo, root.cam, x, y, root.pickState());
    }
    function boardPoint(p: var): var {
        return Cam.project(p, root.cam);
    }

    // ---- the cached board ----
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
        hole: root.holeRect
        cardTilt: (root.anyMoving ? root._bAir : root.airplaneT) > 0 ? Math.max(0, ((root.anyMoving ? root._bAir : root.airplaneT) - root.screwShare) / (1 - root.screwShare)) * root.geo.CARD.tilt : 0
        screwLift: Math.min(1, (root.anyMoving ? root._bAir : root.airplaneT) / root.screwShare) * root.geo.SCREW.lift
        btnDown: (root.anyMoving ? root._bBtn : root.btnPose) * root.geo.BTN.travel
        plugIn: root.anyMoving ? root._bPlug : root.plugPose
        dipWifi: root.anyMoving ? root._bDipW : root.dipWifiPose
        dipBt: root.anyMoving ? root._bDipB : root.dipBtPose
        lightDir: root.light3
        shadowStrength: root.shadowStrength
        colours: root.style.palette
        colours2: root.style.palette2
        tune: root.style.tune
        coaxMain: root.style.coaxMain
        coaxAux: root.style.coaxAux
        labelHole: !root.labelBaked
        ratesVariant: root.ratesVariant
        usageVariant: root.usageVariant
        hueWifi: root.style.wifiHueV
        hueBt: root.style.btHueV
    }

    // ---- the live patch over what moves ----
    BoardLayer {
        id: patch
        visible: root.anyMoving
        cached: false
        cardPatch: true
        x: root.patchBox.x
        y: root.patchBox.y
        width: root.patchBox.w
        height: root.patchBox.h
        offsetX: root.patchBox.x
        offsetY: root.patchBox.y
        hole: root.holeRect
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        cardTilt: root.cardTilt
        screwLift: root.screwLift
        btnDown: root.btnDown
        plugIn: root.plugPose
        dipWifi: root.dipWShown
        dipBt: root.dipBShown
        lightDir: root.light3
        shadowStrength: root.shadowStrength
        colours: root.style.palette
        colours2: root.style.palette2
        tune: root.style.tune
        coaxMain: root.style.coaxMain
        coaxAux: root.style.coaxAux
        labelHole: !root.labelBaked
        ratesVariant: root.ratesVariant
        usageVariant: root.usageVariant
        hueWifi: root.style.wifiHueV
        hueBt: root.style.btHueV
    }
    // gates' ARM only: the label drawn into the board (`bakedlabel`)
    property bool labelBaked: false

    // ---- the silk (the names, the courtyards, the engraved units) is the BOARD's own: carved / inked by its shader from the baked silkscreen, so parts hide it and shadows
    // fall on it. Here only WHICH variant of the two unit labels shows (AerialGeometry SILK_VARIANTS): the facts' unit, or a whole text the popup asks for (the speed
    // test's question on RATE) ----
    function _variant(key: string, name: string): int {
        const list = root.geo.SILK_VARIANTS[key];
        const asked = root.silkTexts[key];
        const text = asked ? String(asked) : name + " - " + (root._s.units ? root._s.units[key] : "");
        const i = list.indexOf(text);
        return i >= 0 ? i : 0;
    }
    readonly property int ratesVariant: root._variant("rates", "RATE")
    readonly property int usageVariant: root._variant("usage", root._s.units && root._s.units.usage === "ms" ? "PING" : "DATA")

    // ---- the two coax cables (tubes, not boxes): over the board and the silk, under the label and every hologram ----
    readonly property alias coaxLayer: coax
    CoaxLayer {
        id: coax
        anchors.fill: parent
        geo: root.geo
        cam: root.cam
        cardTilt: root.cardTilt
        mainColour: root.style._t("aerialCoaxMain")
        auxColour: root.style._t("aerialCoaxAux")
        power: root.power
    }

    // ---- the live label, on the shield's plane (it tilts with the card) ----
    // what the popup knows and the label's chrome mirrors: where the pointer leads the room (-1..1 each way) and the cloud's front (its radius in this item's px, < 0 none)
    property vector2d lead: Qt.vector2d(0, 0)
    property real pulseRadius: -1
    property real pulseStrength: 0
    readonly property alias labelItem: liveLabel
    readonly property alias boardLayer: board
    readonly property alias patchLayer: patch
    readonly property alias glowLayer: glow
    readonly property var labelMap: Cam.labelMap(root.geo, root.cam, root.cardTilt)
    readonly property real _rs: root.renderScale > 0.01 ? root.renderScale : 1
    AerialLabel {
        id: liveLabel
        kPx: 20
        visible: !root.labelBaked
        family: root.family
        dark: root.dark
        animate: root.animate
        paper: root.style.labelPaper
        ink: root.style.labelInk
        etch: root.style.labelEtch
        chromeSky: root.style.chromeSky
        chromeBase: root.style.chromeBase
        chromeDeep: root.style.chromeDeep
        hot: root.style.labelHot
        lipColour: root.style.labelLipColour
        pulseColour: root.style.accent
        plateInk: root.style.labelInk
        lip: root.style.labelLip
        btHue: root.style.btHue
        accent: root.style.accent
        lowColour: root.style.error
        wfm: root._s.wfm || "F44EE394DA40"
        bdm: root._s.bdm || "F44EE394DA44"
        label: root._s.label
        labelW: root.geo.LABEL.x1 - root.geo.LABEL.x0
        labelH: root.geo.LABEL.y1 - root.geo.LABEL.y0
        radius: root.geo.LABEL.radius
        originX: root.geo.LABEL.x0
        originY: root.geo.LABEL.y0
        // the three bands, from the label's own corner (AerialGeometry LABEL_HEAD / LABEL_BT / LABEL_ZONE are card-local)
        function _band(z: var): var {
            return [z.x0 - root.geo.LABEL.x0, z.y0 - root.geo.LABEL.y0, z.x1 - root.geo.LABEL.x0, z.y1 - root.geo.LABEL.y0];
        }
        head: liveLabel._band(root.geo.LABEL_HEAD)
        btZone: liveLabel._band(root.geo.LABEL_BT)
        zone: liveLabel._band(root.geo.LABEL_ZONE)
        // the plate's clock (the front's ripple), the lamp's side in the label's plane (card x is the board's x, card y its z) and one DEVICE px in the label's mm
        time: root.time
        live: root.live
        // the room in the chrome: the plate's axes on screen, the card's tilt, the pointer's lead and the cloud's front (the last two are the popup's)
        axes: Qt.vector4d(root.labelMap.a, root.labelMap.c, root.labelMap.b, root.labelMap.d)
        tilt: root.cardTilt
        lead: root.lead
        pulseRadius: root.pulseRadius
        pulseStrength: root.pulseStrength
        pulseSpan: root.geo.CLOUD.span * Math.PI / 180
        lampSide: {
            const lx = root.light3[0], lz = root.light3[2], n = Math.hypot(lx, lz);
            return n > 1e-4 ? Qt.vector2d(lx / n, lz / n) : Qt.vector2d(-0.5, -0.87);
        }
        devPx: 1 / Math.max(0.01, Math.hypot(root.labelMap.a, root.labelMap.c) * root._rs)
        transformOrigin: Item.TopLeft
        x: 0
        y: 0
        // the corner lands on a whole DEVICE pixel (the renderScale law): the map's translation is rounded in device px
        readonly property real k: 1 / liveLabel.kPx
        readonly property real tx: Math.round(root.labelMap.tx * root._rs) / root._rs
        readonly property real ty: Math.round(root.labelMap.ty * root._rs) / root._rs
        transform: Matrix4x4 {
            matrix: Qt.matrix4x4(root.labelMap.a * liveLabel.k, root.labelMap.b * liveLabel.k, 0, liveLabel.tx,
                                 root.labelMap.c * liveLabel.k, root.labelMap.d * liveLabel.k, 0, liveLabel.ty,
                                 0, 0, 1, 0, 0, 0, 0, 1)
        }
    }

    // ---- the live light ----
    // the beacon blinks (1.2 s), a pad under test breathes (0.9 s), the searching button holds a ring; a clock runs only while one of them does
    // The dimmed pulse trains run along the copper while the popup is alive (`pulses`, the idle ladder's `halted` stops them: 0 frames when still). One 30 Hz beat for all of it
    // (a running FrameAnimation would present every vsync): `time` advances by the real interval, and a beat renders the glow once.
    //
    // RUNNING OR AT REST, nothing between (round 4: "the silicon is binary ... same timings, same mechanism"; a slower middle rung read as a low frame rate). The mechanism
    // is silicon's (BoardClock): when the idle ladder halts (`resting`), the LIVE LAYER (`live`, 1 .. 0) eases to rest over `restSeconds` -- the tempo of `time` follows it,
    // and whatever moves on its own is multiplied by it (the copper's pulses, the cloud's pulse and float, the globe's turn), so the last frame is a still picture with
    // nothing frozen mid-flight -- and only then does the beat stop (`atRest`: 0 frames). A wake eases it back over `wakeSeconds`. The times are silicon's.
    property bool pulses: true
    property real restSeconds: 1.0
    property real wakeSeconds: 0.4
    property real _p: 1
    readonly property real live: root._p * root._p * (3 - 2 * root._p)
    readonly property bool blinking: root._s.beacon.on || root._s.btnLit || root._s.padStates.indexOf("testing") >= 0
    readonly property bool _wants: root.blinking || (root.pulses && root.power > 0)
    readonly property bool atRest: root.resting && (root._p <= 0 || !root._wants)
    readonly property bool clockOn: root._wants && !root.halted && !(root.resting && root._p <= 0)
    property real time: 0
    property real _lastBeat: 0
    onClockOnChanged: root._lastBeat = 0
    // a new open starts fully alive (a content kept after its popup closed went to rest with it)
    function wake(): void {
        root._p = 1;
    }
    Timer {
        interval: 33
        repeat: true
        running: root.clockOn
        onTriggered: {
            const t = Date.now();
            const dt = root._lastBeat > 0 ? Math.min(0.25, (t - root._lastBeat) / 1000) : 0.033;
            root._lastBeat = t;
            const goal = root.resting ? 0 : 1;
            if (root._p !== goal) {
                const stepP = dt / Math.max(1e-3, goal === 0 ? root.restSeconds : root.wakeSeconds);
                root._p = Math.abs(goal - root._p) <= stepP ? goal : root._p + (goal > root._p ? stepP : -stepP);
            }
            root.time += dt * root.live;
        }
    }
    function _blink(i: int, v: real): real {
        if (v <= 0)
            return 0;
        if (i === 0)
            return v * (0.35 + 0.65 * (0.5 + 0.5 * Math.cos(root.time * 2 * Math.PI / 1.2)));
        if (root._s.led.colour[i] === 4)
            return v * (0.55 + 0.45 * (0.5 + 0.5 * Math.cos(root.time * 2 * Math.PI / 0.9)));
        return v;
    }
    // a pad's cue: lit, dark, lit, dark over the cue's clock, in the error colour, then the facts' own LED again
    function _cueGate(i: int): bool {
        return i === 3 + root.padCueIdx && root.padCueIdx >= 0 && root.padCue > 0 && root.padCue < 1;
    }
    readonly property var ledNow: {
        const out = [];
        for (let i = 0; i < 8; i++)
            out.push(root._cueGate(i) ? (Math.floor(root.padCue * 4) % 2 === 0 ? 1 : 0) * root.power : root._blink(i, root._s.led.intensity[i]) * (root.power));
        return out;
    }
    readonly property var ledColourNow: root.padCueIdx >= 0 && root.padCue > 0 && root.padCue < 1 ? root._s.led.colour.map((c, i) => i === 3 + root.padCueIdx ? 3 : c) : root._s.led.colour
    function cueDip(which: string): void {
        if (!root.animate)
            return;
        if (which === "wifi") {
            root._kickW = root._s.wifiOn ? -0.6 : 0.6;
            cueWAnim.restart();
        } else if (which === "bt") {
            root._kickB = root._s.btOn ? -0.6 : 0.6;
            cueBAnim.restart();
        }
    }
    function cuePad(id: string): void {
        const i = Facts.PADS.indexOf(id);
        if (i < 0 || !root.animate)
            return;
        root.padCueIdx = i;
        padCueAnim.restart();
    }
    SequentialAnimation {
        id: cueWAnim
        NumberAnimation { target: root; property: "dipCueW"; to: root._kickW; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "dipCueW"; to: 0; duration: 380; easing.type: Easing.OutBounce }
    }
    SequentialAnimation {
        id: cueBAnim
        NumberAnimation { target: root; property: "dipCueB"; to: root._kickB; duration: 70; easing.type: Easing.OutQuad }
        NumberAnimation { target: root; property: "dipCueB"; to: 0; duration: 380; easing.type: Easing.OutBounce }
    }
    NumberAnimation {
        id: padCueAnim
        target: root
        property: "padCue"
        from: 0
        to: 1
        duration: 520
    }
    GlowLayer {
        id: glow
        anchors.fill: parent
        family: root.family
        dark: root.dark
        renderScale: root.renderScale
        pxPerMm: root.cam.s
        originX: root.cam.ox
        originY: root.cam.oy
        lightDir: root.light3
        cardTilt: root.cardTilt
        screwLift: root.screwLift
        btnDown: root.btnDown
        plugIn: root.plugPose
        dipWifi: root.dipWShown
        dipBt: root.dipBShown
        intensity: root.ledNow
        colour: root.ledColourNow
        okColour: root.style.ok
        warnColour: root.style.warn
        errorColour: root.style.error
        accentColour: root.style.accent
        segColour: root.style.accent
        figRates: Qt.vector4d(root._s.rates[0], root._s.rates[1], root._s.rates[2], root._s.rates[3])
        figUsage: Qt.vector4d(root._s.usage[0], root._s.usage[1], root._s.usage[2], root._s.usage[3])
        beaconRing: root._s.beacon.ring
        beaconStrength: root._s.beacon.on ? 1 : 0
        btnLit: root._s.btnLit ? 1 : 0
        lensLit: 0
        power: root.power
        time: root.time
        pulse: root.pulses ? 0.34 * root.live : 0
        colours2: root.style.palette2
    }
}
