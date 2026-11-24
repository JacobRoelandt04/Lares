pragma ComponentBehavior: Bound

import QtQuick

import "../../common/float"
import "../../common/glyphs"
import "../../common/theme"
import "AerialCamera.js" as Cam
import "CloudPlace.js" as CP
import "GlobeMath.js" as GM

// =============================================================================
// CloudHolo.qml -- aerial's air: THE SIGNAL FAN (round 3). A standing Wi-Fi glyph on the card's white label: its origin is the label's centre (AerialGeometry
// ANCHORS.cloud) and its arcs fan up from there (AerialCamera.cloud: the radii). Everything that is in range and NOT connected hangs on it:
//
//   the near field (rBt)   Bluetooth devices that are not connected -- the connected ones are on the label
//   the two Wi-Fi arcs     the networks by signal, strong on the inner one
//   the fringe             the weak ones as dots, and saved networks that are weak today by name
//   the own hotspot        one tag at the fan's lower left end; while the hotspot is UP the fan holds its clients and three fronts are in flight
//
// WHERE each thing stands is CloudPlace.js's (seeded from its key, sticky, nothing over anything). THE FIELD (cloud.frag) draws what is not a thing: the pulse that leaves
// the label's centre, the arcs as dotted guides, the source dot. A tag GLINTS as the pulse passes its radius (computed from the pulse's own phase, no timer). Every tag is a
// FloatCard on ONE FloatClock (the notes' / the weather's float), dealt in from the inner arc out when the popup opens.
//
// THE CLOCKS: `time` is the scene's one beat (30 Hz alive, 10 Hz calm, standing still when the idle ladder says so): the pulse's phase is integrated from it and the
// float's rest ticks are taken from it (FloatClock.beat), so the cloud adds no frame of its own; a still popup draws nothing. All of it is QML above the cached board.
//
// Arrivals fade in, leavers fade out, a move along an arc glides; a connect flies the tag onto its zone of the label (`activeKey` / a device that turned connected), a
// disconnect lifts it off (`liftKey`). A tag dragged and let go on nothing STAYS there until the popup closes (`setOffset`).
// =============================================================================
Item {
    id: root

    // ---- in ----
    property var wifi: null
    property var hotspot: null
    property var bt: null
    property var cam: ({ s: 5, ox: 0, oy: 0 })
    property var geo: null
    property real renderScale: 1
    property real power: 1
    property real time: 0                       // seconds of the scene's beat
    property real live: 1                       // the scene's live layer (1 running .. 0 at rest): the pulse's strength, the float's reach
    property bool halted: false                 // still: nothing runs
    property real scanStamp: 0                  // a scan's time (the host's facts): the next front to leave the label is a stronger one
    property string hoverKey: ""
    property string carriedKey: ""
    property var wifiCentre: [0, 0]             // item px: where a network docks to / lifts from (the label's Wi-Fi zone)
    property var btCentre: [0, 0]               // ... and a device (the label's Bluetooth zone)
    property string activeKey: ""               // the docked network's key
    property string liftKey: ""                 // a key that just left the label: it arrives from `liftFrom`
    property var liftFrom: [0, 0]
    property bool open: true
    property color tint: Theme.accent           // the field's hue (the host hands the scene's accent)
    property string fontFamily: "Inter"
    // a cue (a failed intent): the tag of `shakeKey` is moved `shakeX` px by the host's one shake clock
    property string shakeKey: ""
    property real shakeX: 0
    // a GROWN globe covers the air over it (it takes the room, nothing moves for it): the tags under its disc fade while it is big. cover = (cx, cy, radius px, grow 0..1)
    property vector4d cover: Qt.vector4d(0, 0, 0, 0)

    // ---- out ----
    readonly property alias placed: root._placed
    readonly property alias tags: rep
    readonly property alias floatClock: fclock
    readonly property bool hotspotUp: !!(root.hotspot && root.hotspot.active)
    readonly property string hotspotKey: "hotspot"
    readonly property var fan: root.geo && root.width > 0 ? Cam.cloud(root.geo, root.width) : ({ rBt: 100, r: [150, 200], rFringe: 250, span: 64, top: 280 })
    readonly property var origin: {
        if (!root.geo)
            return [0, 0];
        const q = Cam.project(root.geo.ANCHORS.cloud, root.cam);
        return [q.x, q.y];
    }
    readonly property real rEnd: root.fan.rFringe + 22
    function hueOf(band: string): color {
        return band === "6" ? BarHues.aerialBand6 : band === "5" ? BarHues.aerialBand5 : BarHues.aerialBand24;
    }
    function dimAt(x: real, y: real): real {
        const c = root.cover;
        if (c.w <= 0.001 || c.z <= 0)
            return 1;
        const inside = Math.max(0, Math.min(1, (c.z + 6 - Math.hypot(x - c.x, y - c.y)) / 12));
        return 1 - 0.78 * c.w * inside;
    }

    // ---- the session offsets: a tag let go where there is no target STAYS where it was dropped (an item-px offset over its own place) until the popup closes ----
    property var _offs: ({})
    function offsetOf(key: string): var {
        return root._offs[key] || [0, 0];
    }
    // (ax, ay): where the tag's CENTRE was let go
    function setOffset(key: string, ax: real, ay: real): void {
        const e = root._placed.entries[key];
        if (!e)
            return;
        const cx = Math.max(8 + e.w / 2, Math.min(root.width - 8 - e.w / 2, ax)), cy = Math.max(8 + e.h / 2, Math.min(root.height - 8 - e.h / 2, ay));
        const next = Object.assign({}, root._offs);
        next[key] = [cx - e.x, cy - e.y];
        root._offs = next;
    }
    onOpenChanged: {
        if (root.open) {
            fclock.restartDeal();
            root.refresh();
        } else {
            // the next open places everything by its seed again: the offsets and the sticky places go
            root._offs = ({});
            root._placed = CP.empty();
            keys.clear();
            root.refresh();
        }
    }

    // ---- the placement ----
    property var _placed: CP.empty()
    function _proj(p: var): var {
        const q = Cam.project(p, root.cam);
        return [q.x, q.y];
    }
    // a name's real advance (TextMetrics, never a drawn Text), in the weight and size it is drawn at
    TextMetrics {
        id: tm
        font.family: root.fontFamily
    }
    function _measure(it: var): real {
        tm.font.pixelSize = it.kind === "bt" && !it.paired ? 10 : 11;
        tm.font.weight = it.kind === "net" && it.arc === 0 ? Font.DemiBold : Font.Normal;
        const f = tm.font.pixelSize;     // the metrics' own font is the dependency and the guarantee
        tm.text = String(it.ssid !== "" ? it.ssid : "Hidden network");
        return f > 0 ? Math.ceil(tm.advanceWidth) : 6 * String(it.ssid).length;
    }
    // what a tag keeps off: the globe at its REST size (all of it, down to its lens) and -- the near field only, the arcs stand higher -- the screw and the cables
    function _avoid(): var {
        const G = root.geo, out = [];
        const fr = GM.frameOf(G, root.cam, GM.restOf(root.cam)), r = fr.rp + 6;
        out.push({ x0: fr.cx - r, x1: fr.cx + r, y0: fr.cy - r, y1: Math.max(fr.cy + r, fr.lensY + 4) });
        const Cd = G.CARD, top = Cd.yPcb + Cd.pcb, nx = Cd.x0 + G.PCB.notch.x, nz = Cd.z0 + G.PCB.notch.y, sr = G.SCREW.head + 0.6;
        out.push(Object.assign(CP.boundsOf([[nx - sr, top, nz - sr], [nx + sr, top, nz - sr], [nx + sr, top, nz + sr], [nx - sr, top, nz + sr],
                                             [nx - sr, top + 1.2, nz - sr], [nx + sr, top + 1.2, nz + sr]].map(root._proj), 3), { bt: true }));
        // (the cables: one short arch each from its connector into its grommet behind the card)
        const M = G.MHF, E = G.CUTS.grommets;
        out.push(Object.assign(CP.boundsOf([[Cd.x0 + M.main[0], top + 3, Cd.z0 + M.main[1]], [Cd.x0 + M.aux[0], top + 3, Cd.z0 + M.aux[1]],
                                             [E[0][0], 0, E[0][1]], [E[1][0], 0, E[1][1]]].map(root._proj), 3), { bt: true }));
        return out;
    }
    readonly property bool _wifiOn: !!root.wifi && root.wifi.present !== false && root.wifi.radioOn !== false
    // (round 6, the user: shown only when it can really be started -- the Wi-Fi card shares what a CABLE brings in; with Wi-Fi as the only link there is nothing to share)
    readonly property bool hotspotShown: root._hotspotShownNow()
    // (from the facts themselves: `refresh` runs in the hotspot's change handler, before a binding on it has followed -- a cable plugged in showed no tag until the next scan)
    function _hotspotShownNow(): bool {
        const h = root.hotspot, w = root.wifi;
        return !!h && h.available === true && h.uplink === "cable" && h.active !== true && !!w && w.present !== false && w.radioOn !== false;
    }
    function _items(): var {
        // (the facts themselves, never the bindings on them: this runs from their change handlers)
        const h = root.hotspot, w = root.wifi;
        let out = [];
        if (!!h && h.active === true)
            out = CP.itemsOfClients(h);
        else if (!!w && w.present !== false && w.radioOn !== false)
            out = CP.itemsOfWifi(w);
        if (root._hotspotShownNow())
            out.push(CP.hotspotItem(root.hotspot));
        return out.concat(CP.itemsOfBt(root.bt));
    }
    function refresh(): void {
        // the placer decides by the plates' real boxes in item px: not before the camera is real (a scene still being sized hands out a negative scale)
        if (!root.geo || !(root.cam.s > 1) || !(root.width > 1))
            return;
        const F = root.fan, O = root.origin;
        const st = CP.place(root._placed, root.open ? root._items() : [], Date.now(), {
            ox: O[0], oy: O[1], rBt: F.rBt, r: F.r, rFringe: F.rFringe, span: F.span, measure: root._measure,
            bounds: { x0: 8, y0: 8, x1: root.width - 8, y1: 1e5 }, avoid: root._avoid()
        });
        if (st !== root._placed) {
            root._placed = st;
            root._syncModel();
        }
        let leaving = false;
        for (const k in st.entries)
            if (st.entries[k].gone)
                leaving = true;
        if (leaving)
            prune.restart();
    }
    Timer {
        id: prune
        interval: CP.FADE_MS + 60
        onTriggered: root.refresh()
    }
    onWifiChanged: root.refresh()
    onHotspotChanged: root.refresh()
    onBtChanged: root.refresh()
    onGeoChanged: root.refresh()
    onCamChanged: root.refresh()
    onWidthChanged: root.refresh()
    Component.onCompleted: root.refresh()
    ListModel { id: keys }
    function _syncModel(): void {
        const want = CP.keysOf(root._placed), have = {};
        for (let i = keys.count - 1; i >= 0; i--) {
            const k = keys.get(i).key;
            if (want.indexOf(k) < 0)
                keys.remove(i);
            else
                have[k] = true;
        }
        want.forEach(k => { if (!have[k]) keys.append({ key: k }); });
    }
    // the devices the facts call connected: a device that leaves the air because it CONNECTED flies onto the label
    readonly property var _btConnected: {
        const out = {}, ds = root.bt && root.bt.devices ? root.bt.devices : [];
        for (let i = 0; i < ds.length; i++)
            if (ds[i].connected)
                out[ds[i].address] = true;
        return out;
    }
    readonly property bool _btNear: {
        const es = root._placed.entries;
        for (const k in es)
            if (es[k].kind === "bt" && !es[k].gone)
                return true;
        return false;
    }
    property bool btCarried: false              // a device is in the hand (the host: the drag controller): the near field's guide shows

    // ---- the pulse's phase, integrated from the beat (the beat's time slows to a stop on the way to rest: the front never jumps) ----
    property real phase: 0
    property real _lastT: 0
    readonly property real period: CP.PULSE_PERIOD
    // THE CADENCE IS ONE CLOCK (round 6): every front leaves at the same period and travels at the same speed; a scan does not send a front of its own, it marks the next one
    // that leaves (`boost`: wider and brighter). What changes the cadence on purpose: the live layer easing to rest or back (the fronts slow down and stop, as the whole
    // popup does) and a hotspot that is up (three fronts in flight, a little quicker).
    property bool boost: false
    signal frontLeft(bool scan)                 // a front left the label (a probe times the cadence by it)
    property bool _boostNext: false
    onScanStampChanged: if (root.scanStamp > 0) root._boostNext = true
    onTimeChanged: {
        const dt = Math.max(0, Math.min(0.3, root.time - root._lastT));
        root._lastT = root.time;
        const p = root.phase + dt / (root.hotspotUp ? root.period * 0.9 : root.period);
        const left = p >= 1;
        if (left) {
            // a new front leaves the label
            root.boost = root._boostNext;
            root._boostNext = false;
        }
        root.phase = p - Math.floor(p);
        if (left)
            root.frontLeft(root.boost);
        fclock.beat();
    }

    // ---- the field ----
    readonly property real _rs: root.renderScale > 0.01 ? root.renderScale : 1
    readonly property bool fieldOn: root.power > 0.01 && (root._wifiOn || root.hotspotUp || root._btNear)
    readonly property alias field: field
    ShaderEffect {
        id: field
        anchors.fill: parent
        visible: root.fieldOn
        fragmentShader: "../shaders/cloud.frag.qsb"
        property vector4d view: Qt.vector4d(field.width, field.height, root._rs, root._radio ? 1 : 0)
        property vector4d fan: Qt.vector4d(root.origin[0], root.origin[1], root.fan.span * Math.PI / 180, root.rEnd)
        property vector4d radii: Qt.vector4d(root.fan.rBt, root.fan.r[0], root.fan.r[1], root.fan.rFringe)
        property vector4d pulse: Qt.vector4d(root.phase, CP.PULSE_TRAVEL, root.boost ? 1 : 0, root.hotspotUp ? 1 : 0)
        property vector4d tint: Qt.vector4d(root.tint.r, root.tint.g, root.tint.b, Math.max(0, Math.min(1, root.power)))
        // the guides' alpha, the near field's guide (only while something is on it or a device is in the hand), the pulse's alpha, the source dot's. With the Wi-Fi
        // radio off there is no pulse, no source and no Wi-Fi guide (view.w): the near field's guide alone stays
        property vector4d look: Qt.vector4d(root.guideAlpha, root._btNear || root.btCarried ? 1 : 0, root._radio ? root.pulseAlpha * root.live : 0, root._radio ? 0.9 : 0)
    }
    readonly property bool _radio: root._wifiOn || root.hotspotUp
    readonly property bool radioOn: root._radio             // a front is in the air only then (the label's chrome mirrors it)
    // (one pair for both modes: a tint of the accent reads on either ground, and nothing here follows Theme.mode, which moves a frame before the crossfade's picture)
    property real guideAlpha: 0.24
    property real pulseAlpha: 0.64

    // ---- the one float clock ----
    readonly property FloatStyle floatStyle: FloatStyle {
        // (the reach follows the live layer: on the way to rest every tag glides home, none stands frozen off its place)
        moveAmpMin: 1.5 * root.live
        moveAmpMax: 3.0 * root.live
        moveFreqMin: 0.35
        moveFreqMax: 0.7
        rotAmpMin: 0.4 * root.live
        rotAmpMax: 1.0 * root.live
        rotFreqMin: 0.3
        rotFreqMax: 0.7
        tiltMax: 0
        liftScale: 1.05
        dealMs: 380
        dealStaggerMs: 16
        dealRise: 10
        dealTurn: 2.5
    }
    FloatClock {
        id: fclock
        running: root.open && !root.halted && root.power > 0.01
        // the rest ticks are the scene's beats (beat()): the clock's own timer is only the fallback, slower than the beat it stands in for
        restHz: 20
        style: root.floatStyle
    }

    // ---- the tags ----
    Repeater {
        id: rep
        model: keys
        delegate: CloudTag {
            id: tag
            required property string key
            readonly property var e: root._placed.entries[tag.key] || null
            readonly property bool alive_: !!tag.e
            entry: tag.e
            clock: fclock
            style: root.floatStyle
            seed: CP.hash(tag.key) % 100000 + 1
            // the deal: the inner arc first
            order: tag.e ? (tag.e.arc === "bt" ? 0 : tag.e.arc === "fringe" ? 9 : 3 + 3 * tag.e.arc) + (CP.hash(tag.key) % 3) : 0
            hue: tag.e ? (tag.e.kind === "bt" ? BarHues.btOn : root.hueOf(tag.e.bestBand)) : "transparent"
            btHue: BarHues.btOn
            fontFamily: root.fontFamily
            renderScale: root._rs
            hovered: tag.key === root.hoverKey
            // its own place (the placer's), gliding when the placer moves it
            property real cx: tag.e ? tag.e.x : 0
            property real cy: tag.e ? tag.e.y : 0
            property bool _ready: false
            Behavior on cx {
                enabled: tag._ready && root.open
                NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
            }
            Behavior on cy {
                enabled: tag._ready && root.open
                NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
            }
            readonly property var off: root.offsetOf(tag.key)
            // docking: a network that became the active one, a device that connected, flies to its zone of the label; lifting: the other way
            readonly property bool docking: !!tag.e && tag.e.gone && (tag.e.kind === "bt" ? root._btConnected[tag.key] === true : tag.key === root.activeKey)
            readonly property var dockTo: tag.e && tag.e.kind === "bt" ? root.btCentre : root.wifiCentre
            property real dock: 0
            property real arrive: 0
            Behavior on dock {
                NumberAnimation { duration: 320; easing.type: Easing.InOutCubic }
            }
            Behavior on arrive {
                NumberAnimation { duration: 320; easing.type: Easing.OutCubic }
            }
            onDockingChanged: tag.dock = tag.docking ? 1 : 0
            Component.onCompleted: {
                tag._ready = true;
                tag.arrive = 1;
            }
            readonly property real liftIn: tag.key === root.liftKey ? (1 - tag.arrive) : 0
            readonly property real hx: tag.cx + tag.off[0]
            readonly property real hy: tag.cy + tag.off[1]
            readonly property real fx: tag.hx + (tag.dockTo[0] - tag.hx) * tag.dock + (root.liftFrom[0] - tag.hx) * tag.liftIn
            readonly property real fy: tag.hy + (tag.dockTo[1] - tag.hy) * tag.dock + (root.liftFrom[1] - tag.hy) * tag.liftIn
            readonly property real w0: tag.e ? tag.e.w : 0
            readonly property real h0: tag.e ? tag.e.h : 0
            x: Math.round((tag.fx - tag.w0 / 2 + (tag.key === root.shakeKey ? root.shakeX : 0)) * root._rs) / root._rs
            y: Math.round((tag.fy - tag.h0 / 2) * root._rs) / root._rs
            z: tag.hovered ? 5000 : (tag.e && tag.e.form !== "dot" ? 10 : 0)
            visible: tag.alive_ && tag.key !== root.carriedKey && root.power > 0.01
            scale: 1 - 0.5 * tag.dock
            dim: root.dimAt(tag.fx, tag.fy) * Math.max(0, Math.min(1, root.power))
            presence: tag.alive_ ? (tag.e.gone ? (tag.docking ? 1 - tag.dock : 0) : tag.arrive) : 0
            Behavior on presence {
                enabled: !!tag.e && tag.e.gone && !tag.docking
                NumberAnimation { duration: 160 }
            }
            glint: tag.alive_ && root.fieldOn && !root.halted ? root.live * CP.glint(root.phase, root.rEnd, Math.hypot(tag.cx - root.origin[0], tag.cy - root.origin[1]), 30) : 0
        }
    }

    // ---- what the pointer can hit: [{ key, kind, x, y (the tag's centre), rect, entry }] in item px ----
    function targets(): var {
        const out = [];
        for (let i = 0; i < rep.count; i++) {
            const t = rep.itemAt(i);
            if (!t || !t.visible || !t.e || t.e.gone || t.presence < 0.4)
                continue;
            out.push({ key: t.key, kind: t.e.kind, x: t.hx, y: t.hy, rect: Qt.rect(t.x + t.hitRect.x, t.y + t.hitRect.y, t.hitRect.width, t.hitRect.height), entry: t.e });
        }
        return out;
    }
    // where a key's tag stands (its centre, item px); null when it is not in the air
    function homeOf(key: string): var {
        const e = root._placed.entries[key];
        if (!e || e.gone)
            return null;
        const o = root.offsetOf(key);
        return [e.x + o[0], e.y + o[1]];
    }
    function tagOf(key: string): var {
        for (let i = 0; i < rep.count; i++) {
            const t = rep.itemAt(i);
            // qmllint disable missing-property
            if (t && t.key === key && t.visible && t.presence > 0.5)
                return t;
            // qmllint enable missing-property
        }
        return null;
    }
}
