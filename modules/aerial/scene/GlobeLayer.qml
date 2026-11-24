pragma ComponentBehavior: Bound

import QtQuick

import "../../common/glyphs"
import "../../common/theme"
import "GlobeMath.js" as GM

// =============================================================================
// GlobeLayer.qml -- the VPN globe over the board's lens: the hologram sphere (globe.frag: hairlines, the land as dots from assets/landmask.png, the beam from the lens), Proton's
// country lights at their real coordinates, the "fastest" light at the globe's foot, and the hover label. Mount it with `anchors.fill: scene` (the scene's own frame: an input
// area never hears what lies outside its ancestor). The API is in docs/agent_added_files_and_folders/aerial_progress/G.md.
//
// COST: the picture changes only when the turn steps (a quarter-ish device pixel of the rim's travel per step, ~8 steps a second, each one whole-window frame) and only while
// alive: `halted` stops the one Timer, so a still globe is 0 frames. The lights are plain Rectangles under one tick of the turn; nothing animates by itself.
// THE HUE is BarHues' role "aerial.globe" (the theme's own terminal colours); the ink is deepened on the light theme and brightened on the dark one, as every hologram here.
// =============================================================================
Item {
    id: root

    // ---- in ----
    property var cam: ({ s: 4.2, ox: 0, oy: 0 })
    property var geo: null
    property int family: 0
    property bool dark: false
    property real renderScale: 1
    property var catalog: null
    property var proton: null
    property real power: 1
    property bool halted: false
    property real tempo: 1                   // the scene's live layer: the turn slows to a stop with it
    property bool spinning: true
    property real turn: -0.17                // rad; longitude ~10 E faces the viewer
    property string dragged: ""
    property bool interactive: true
    // ---- the size and the gestures (R2-H) ----
    // At rest the globe stands 1.3 x its ROUND-1 radius on screen (GlobeMath.restOf); while it is USED (the pointer rests on it after a motion, a swipe turns it: `held`) it grows to 2 x that, EASED over 260 ms, from its foot on the
    // lens: it takes the air over it and shoves nothing (the top is kept under the popup's edge). `tilt` is 0 (the pole leans to the viewer as before) .. 1 (the south pole leans to the viewer),
    // moved live by a vertical swipe and settled on one of the two by `settleTilt`; `rotateBy` is the horizontal swipe's progress.
    property bool pointerOver: false
    property bool held: false                // a gesture is live or coasting: the spin waits and the globe stays grown
    property real restFactor: root.geo ? GM.restOf(root.cam) : 1
    property real grownFactor: root.geo ? GM.grownOf(root.cam) : 1
    property real topMargin: 4               // px kept between the grown rim and the item's top edge
    property real tilt: 0
    readonly property real tiltRad: root.tilt * GM.TILT_MAX
    readonly property bool grown: root.pointerOver || root.held
    property real grow: root.grown ? 1 : 0
    Behavior on grow {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
    }
    property real lensLit: 1                 // the beam's strength (the lens's own glow is the scene's)
    property real dotSpacing: 6              // deg between the dot rows
    property real hairlineStep: 30           // deg between the hairlines
    property real turnRate: 0.052            // rad / s (one turn in two minutes)

    // a probe's marker (lat, lon, radius px; on)
    property vector4d probeMark: Qt.vector4d(0, 0, 0, 3)

    // ---- a request in flight (round 6, the user: "clicking a dot needs instant feedback that the request is being handled") ----
    // `ask(code, way)` is called where a light's click or drop asks the service ("up": a tunnel through it, "down": the tunnel taken down); that light pulses until the facts
    // answer -- up through that light, down, failed -- or a minute has passed. A failure's cue (`answered()`) ends it too.
    property string pending: ""
    property string _pendWay: ""
    property bool _pendSawBusy: false
    property real _pendT: 0
    function ask(code: string, way: string): void {
        root.pending = code;
        root._pendWay = way;
        root._pendSawBusy = false;
        pendLimit.restart();
        root._pendCheck();
    }
    function answered(): void {
        root.pending = "";
        pendLimit.stop();
    }
    function _pendCheck(): void {
        if (root.pending === "")
            return;
        const p = root.proton, st = p ? p.state : "down";
        if (st === "connecting" || st === "disconnecting")
            root._pendSawBusy = true;
        let done = st === "failed";
        if (root._pendWay === "up")
            done = done || (st === "up" && (root.pending === "fastest" ? p.fastest === true : !!p.server && p.server.country === root.pending)) || (st === "down" && root._pendSawBusy);
        else
            done = done || st === "down";
        if (done)
            root.answered();
    }
    onProtonChanged: root._pendCheck()
    Timer {
        id: pendLimit
        interval: 60000
        onTriggered: root.answered()
    }
    NumberAnimation on _pendT {
        running: root.pending !== "" && !root.halted
        from: 0
        to: 1
        duration: 1100
        loops: Animation.Infinite
    }

    // ---- out ----
    property string hoverCode: ""
    signal partActivated(string intent)
    signal lightClicked(string code)

    // ---- the globe's place ----
    readonly property real _factor: root.geo ? GM.fitFactor(root.geo, root.cam, root.restFactor + (root.grownFactor - root.restFactor) * root.grow, root.topMargin, root.restFactor) : 1
    readonly property var _fr: root.geo ? GM.frameOf(root.geo, root.cam, root._factor) : { cx: 0, cy: 0, rp: 1, lensX: 0, lensY: 0 }
    readonly property real _ext: Math.ceil(root._fr.rp + 5)
    readonly property real _rs: root.renderScale > 0.01 ? root.renderScale : 1
    readonly property color hue: {
        const c = BarHues.choice;      // the held choice: this binding follows it and the token both
        return c ? BarHues.tint("aerial.globe") : Theme.accent;
    }
    readonly property color ink: root.dark ? Qt.tint(root.hue, Qt.rgba(1, 1, 1, 0.34)) : Qt.rgba(root.hue.r * 0.62, root.hue.g * 0.62, root.hue.b * 0.62, 1)

    // ---- the turn: stepped in device pixels of the rim, one Timer, none while halted ----
    readonly property real _step: 0.4 / (Math.max(root._fr.rp, 8) * root._rs)
    property real _raw: root.turn
    Timer {
        id: spin
        interval: 60
        repeat: true
        running: root.spinning && !root.halted && !root.held && root.power > 0.01 && root.visible
        property real last: 0
        onRunningChanged: spin.last = Date.now()
        onTriggered: {
            const now = Date.now();
            root.rotateBy(Math.min(0.25, (now - spin.last) / 1000) * root.turnRate * root.tempo);
            spin.last = now;
        }
    }
    // the horizontal swipe's progress: `rad` of turn (+ moves the surface to the right), stepped like the spin (whole device pixels of the rim)
    function rotateBy(rad: real): void {
        root._raw += rad;
        const t = Math.floor(root._raw / root._step) * root._step;
        if (t !== root.turn)
            root.turn = t;
    }
    NumberAnimation {
        id: tiltAnim
        target: root
        property: "tilt"
        duration: 260
        easing.type: Easing.InOutCubic
    }
    // the vertical swipe: live progress, then ONE of the two states
    function tiltLive(v: real): void {
        tiltAnim.stop();
        root.tilt = Math.max(0, Math.min(1, v));
    }
    function settleTilt(state: int): void {
        tiltAnim.stop();
        tiltAnim.to = state;
        tiltAnim.start();
    }
    // the pointer: the host (a HoverHandler on the stage) tells where it moved; x < 0 = it left
    function pointerAt(px: real, py: real): void {
        root.pointerOver = px >= 0 && root.containsGlobe(px, py);
    }

    // ---- the sphere ----
    Image {
        id: maskImg
        source: "assets/landmask.png"
        visible: false
        smooth: true
        mipmap: false
        asynchronous: false
    }
    ShaderEffect {
        id: sphere
        x: Math.floor(root._fr.cx - root._ext)
        y: Math.floor(root._fr.cy - root._ext)
        width: Math.ceil(root._fr.cx + root._ext) - sphere.x
        height: Math.ceil(root._fr.lensY + 3) - sphere.y
        visible: root.power > 0.003
        // The ROOT rule does not bite here (this is not the file's root); the literal paths resolve against this file.
        vertexShader: Qt.resolvedUrl("../shaders/globe.vert.qsb")
        fragmentShader: Qt.resolvedUrl("../shaders/globe.frag.qsb")
        property var source: null
        property var mask: maskImg
        property vector4d view: Qt.vector4d(sphere.width, sphere.height, root._fr.rp, root.family)
        property vector4d centre: Qt.vector4d(root._fr.cx - sphere.x, root._fr.cy - sphere.y, root.turn, root.dark ? 1 : 0)
        property vector4d look: Qt.vector4d(root.dotSpacing, 0.95, root.hairlineStep, root._rs)
        property vector4d hue: Qt.vector4d(root.hue.r, root.hue.g, root.hue.b, root.power)
        property vector4d beam: Qt.vector4d(root._fr.lensY - sphere.y, 2.2 * root.cam.s * 0.7, root._fr.rp * 0.55, root.lensLit)
        property vector4d mark: root.probeMark
        property vector4d tilt: Qt.vector4d(root.tiltRad, 0, 0, 0)
    }

    // ---- the lights ----
    readonly property var _countries: (root.catalog && root.catalog.countries) ? root.catalog.countries : []
    readonly property int _count: root._countries.length
    readonly property real _maxServers: {
        let m = 1;
        for (let i = 0; i < root._countries.length; i++)
            m = Math.max(m, root._countries[i].servers || 0);
        return m;
    }
    readonly property string _exit: (root.proton && root.proton.state === "up" && root.proton.server) ? (root.proton.server.country || "") : ""
    // every light's place now (the one array a tick rewrites): { x, y, front, size }
    readonly property var _lights: {
        const out = [], fr = root._fr, cs = root._countries;
        for (let i = 0; i < cs.length; i++) {
            const p = GM.project(fr, cs[i].lat, cs[i].lon, root.turn, root.tiltRad);
            out.push({ x: p.x, y: p.y, depth: p.depth, size: GM.sizeOf(cs[i].servers, root._maxServers) });
        }
        return out;
    }
    readonly property var _foot: root.geo ? GM.footPoint(root.geo, root.cam) : { x: 0, y: 0 }

    function _indexOf(code: string): int {
        for (let i = 0; i < root._countries.length; i++)
            if (root._countries[i].code === code)
                return i;
        return -1;
    }
    function project(lat: real, lon: real): var {
        const p = GM.project(root._fr, lat, lon, root.turn, root.tiltRad);
        return { x: p.x, y: p.y, depth: p.depth, front: p.depth > 0 };
    }
    function containsGlobe(px: real, py: real): bool {
        const dx = px - root._fr.cx, dy = py - root._fr.cy;
        return dx * dx + dy * dy <= (root._fr.rp + 2) * (root._fr.rp + 2);
    }
    function lightPos(code: string): var {
        if (code === "fastest")
            return Qt.point(root._foot.x, root._foot.y);
        const i = root._indexOf(code);
        return i < 0 ? null : Qt.point(root._lights[i].x, root._lights[i].y);
    }
    function lightFront(code: string): bool {
        if (code === "fastest")
            return true;
        const i = root._indexOf(code);
        return i >= 0 && root._lights[i].depth > 0.05;
    }
    // the FRONT-facing light nearest the point, within its pick radius; "fastest" is always pickable
    function lightAt(px: real, py: real): var {
        let best = null, bestD = 1e9;
        const dxf = px - root._foot.x, dyf = py - root._foot.y;
        if (dxf * dxf + dyf * dyf <= 36) {
            bestD = dxf * dxf + dyf * dyf;
            best = { code: "fastest", name: "Fastest", x: root._foot.x, y: root._foot.y };
        }
        for (let i = 0; i < root._lights.length; i++) {
            const L = root._lights[i];
            if (L.depth <= 0.05)
                continue;
            const dx = px - L.x, dy = py - L.y, d2 = dx * dx + dy * dy, r = Math.max(5, L.size / 2 + 3);
            if (d2 <= r * r && d2 < bestD) {
                bestD = d2;
                best = { code: root._countries[i].code, name: root._countries[i].name, x: L.x, y: L.y };
            }
        }
        return best;
    }
    // the "fastest" light is lit: the tunnel that is up is the one it raised
    readonly property bool fastestLit: fastest.lit
    // what a light asks of the service: a country's code, or NOTHING for the "fastest" light (Proton picks: `protonvpn connect` with no country -- "fastest" is this
    // globe's own word for that light and no country name: sent as one, Proton answers "Invalid country name 'fastest'", round 4)
    function connectArgs(code: string): var {
        return code === "fastest" || code === "" ? ({}) : ({ country: code });
    }
    function _labelFor(code: string): string {
        if (code === "fastest")
            return "Fastest server";
        const i = root._indexOf(code);
        if (i < 0)
            return "";
        const c = root._countries[i];
        return c.name + (c.minLoad !== undefined && c.minLoad !== null ? "  ·  lowest load " + Math.round(c.minLoad) + " %" : "");
    }

    Repeater {
        model: root._count
        delegate: Item {
            id: lt
            required property int index
            readonly property var pos: root._lights[lt.index] || { x: 0, y: 0, depth: -1, size: 2 }
            readonly property string code: root._countries[lt.index].code
            readonly property bool front: lt.pos.depth > 0.05
            readonly property bool isExit: root._exit !== "" && lt.code === root._exit
            readonly property bool carried: root.dragged === lt.code
            readonly property bool hot: root.hoverCode === lt.code
            readonly property real d: (lt.isExit ? 1.7 : 1) * lt.pos.size * (lt.hot ? 1.3 : 1)
            x: lt.pos.x
            y: lt.pos.y
            visible: root.power > 0.003
            Rectangle {      // the exit's halo
                visible: lt.isExit && lt.front
                width: lt.d * 2.4
                height: width
                radius: width / 2
                x: -width / 2
                y: -height / 2
                color: root.ink
                opacity: 0.22 * root.power
            }
            Repeater {      // round 6: the asked light pulses until the tunnel answers (two rings half a period apart: a steady pulse)
                model: lt.code === root.pending && lt.front ? 2 : 0
                delegate: Rectangle {
                    required property int index
                    readonly property real u: (root._pendT + 0.5 * index) % 1
                    width: lt.d * (1.4 + 2.2 * u)
                    height: width
                    radius: width / 2
                    x: -width / 2
                    y: -height / 2
                    color: "transparent"
                    border.width: 1.2
                    border.color: root.ink
                    opacity: 0.85 * (1 - u) * (1 - u) * root.power
                }
            }
            Rectangle {      // the light itself (a carried one leaves a faint ring)
                width: lt.d
                height: width
                radius: width / 2
                x: -width / 2
                y: -height / 2
                color: lt.carried ? "transparent" : root.ink
                border.width: lt.carried ? 1 : 0
                border.color: root.ink
                opacity: (lt.carried ? 0.4 : (lt.front ? (lt.isExit ? 1.0 : 0.62 + 0.3 * Math.min(1, lt.pos.depth * 2)) : 0.13)) * root.power
            }
        }
    }
    // the "fastest" light: a ring with a dot, at the globe's foot. It is a toggle: while the tunnel that is up is the one it raised (the facts' `fastest`) it is LIT --
    // the dot fills the ring, with the exit's halo -- and its click takes the tunnel down
    Item {
        id: fastest
        x: root._foot.x
        y: root._foot.y
        visible: root.power > 0.003
        readonly property bool carried: root.dragged === "fastest"
        readonly property bool hot: root.hoverCode === "fastest"
        readonly property bool lit: !!root.proton && root.proton.state === "up" && root.proton.fastest === true
        Repeater {      // round 6: the asked light pulses until the tunnel answers (two rings half a period apart: a steady pulse)
                model: root.pending === "fastest" ? 2 : 0
                delegate: Rectangle {
                    required property int index
                    readonly property real u: (root._pendT + 0.5 * index) % 1
                    width: 8 * (1.4 + 2.2 * u)
                    height: width
                    radius: width / 2
                    x: -width / 2
                    y: -height / 2
                    color: "transparent"
                    border.width: 1.2
                    border.color: root.ink
                    opacity: 0.85 * (1 - u) * (1 - u) * root.power
                }
            }
        Rectangle {      // lit: the halo an exit has
            visible: fastest.lit && !fastest.carried
            width: 19
            height: 19
            radius: 9.5
            x: -9.5
            y: -9.5
            color: root.ink
            opacity: 0.22 * root.power
        }
        Rectangle {
            width: fastest.hot ? 10 : 8
            height: width
            radius: width / 2
            x: -width / 2
            y: -height / 2
            color: "transparent"
            border.width: 1
            border.color: root.ink
            opacity: (fastest.carried ? 0.35 : 0.85) * root.power
        }
        Rectangle {
            width: fastest.lit ? 6 : 3
            height: width
            radius: width / 2
            x: -width / 2
            y: -height / 2
            color: root.ink
            opacity: (fastest.carried ? 0 : 1) * root.power
        }
    }

    // ---- the hover label ----
    Rectangle {
        id: tip
        readonly property string text: root._labelFor(root.hoverCode)
        readonly property var at: root.hoverCode !== "" ? root.lightPos(root.hoverCode) : null
        visible: tip.text !== "" && tip.at !== null && root.dragged === ""
        z: 5
        radius: 5
        color: Theme.surface
        border.width: 1
        border.color: Theme.border
        width: tipText.implicitWidth + 12
        height: tipText.implicitHeight + 6
        x: tip.at ? Math.max(2, Math.min(root.width - tip.width - 2, tip.at.x - tip.width / 2)) : 0
        y: tip.at ? Math.max(2, tip.at.y - tip.height - 9) : 0
        Text {
            id: tipText
            anchors.centerIn: parent
            text: tip.text
            color: Theme.textPrimary
            font.pixelSize: 11
        }
    }

    // ---- the pointer: only over the disc and the foot light, so the board under it keeps its own ----
    MouseArea {
        id: pointer
        anchors.fill: parent
        enabled: root.interactive
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        cursorShape: pointer.containsMouse ? Qt.PointingHandCursor : Qt.ArrowCursor
        containmentMask: QtObject {
            function contains(point: point): bool {
                return root.containsGlobe(point.x, point.y) || root.lightAt(point.x, point.y) !== null;
            }
        }
        onPositionChanged: mouse => {
            const l = root.lightAt(mouse.x, mouse.y);
            root.hoverCode = l ? l.code : "";
        }
        onExited: root.hoverCode = ""
        onClicked: mouse => {
            if (root.dragged !== "")
                return;
            const l = root.lightAt(mouse.x, mouse.y);
            if (l)
                root.lightClicked(l.code);
            else
                root.partActivated("globe");
        }
    }
}
