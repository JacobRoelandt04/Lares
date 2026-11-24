pragma ComponentBehavior: Bound

import QtQuick

import "../../common/glyphs"
import "../scene"
import "../scene/CloudPlace.js" as CP

// =============================================================================
// DragController.qml -- ONE controller for everything in the air and on the label: the cloud's networks, the own hotspot, its Bluetooth devices, what is docked on the
// label (the network, the hotspot, the connected devices) and the globe's countries (through `startExternal`, or a press on a light).
//
//   press on a tag        it detaches and follows the pointer ON A SPRING (a short lag, never more than `maxLag` px behind, a slight lean with its velocity), open (its facts
//                         show); the label's matching zone glows while it is carried (`hint`: the label draws its own glow)
//   release on the label  a network / the hotspot / a country = connect(key) / startHotspot() / vpnConnect({ country }); a device = btConnect (paired) or btPair (a stranger).
//                         The label is small: either kind may be let go anywhere on it. It then HOVERS over its zone until the facts say what became of it.
//   release elsewhere     a network, the hotspot or a device STAYS where it was let go until the popup closes (the cloud keeps the offset); a country goes back
//   pull a docked one     press the label's Wi-Fi zone and pull it off: disconnect() (the docked hotspot: stopHotspot()); press a connected device's row on the label's
//                         Bluetooth zone and pull it off: btDisconnect(address) (`carriedBt`: the label hides that row while it is in the hand)
//   a click               press and release with no drag past `dragSlop` px: `activated("net:<key>" | "bt:<address>" | "hotspot" | "label" | "globe" | "country:<CODE>")`.
//                         A country's light is "country:<CODE>" (the popup connects there); the connected country's light and the sphere elsewhere are "globe". The
//                         "fastest" light is always "country:fastest": the popup raises the tunnel, or takes down the one that light raised.
//   a secured stranger    dropped on the label it HOVERS pulsing over it (the panel's password field is the owner's: `activated("net:<key>")`) until it connects (it flies
//                         onto the label), is refused its password (it shakes and stays: the field is asked again) or is given up (`giveUp(key)`: it drifts back)
//   what became of it     is read from the facts WHILE IT HOVERS, once: NetworkManager takes the connection up (`wifi.active` is it, activating counts) = it shrinks into the
//                         label, ONE flight (the service publishes many times while a connection comes up: a flight restarted by each publication shrank and snapped
//                         back to full size again and again, round 5); the attempt FAILED (the service's `cue` for it, an event: a failure the facts still carry from
//                         an earlier attempt is no news) = it shakes, then drifts back to its place in the air (the toast says why)
// Input is by arithmetic over the tags' own rectangles and the label's zones (polygons under the card's affine map): a press that hits nothing is NOT accepted, so the board's
// own input underneath gets it. The hover is a HoverHandler on the popup (an ancestor of both), which calls `hoverAt`; a tag opens once the pointer has RESTED on it a moment.
// The spring runs only while something is carried.
// =============================================================================
Item {
    id: root

    // ---- in ----
    property var service: null
    property var cloud: null                    // CloudHolo: targets() / homeOf() / setOffset() / hueOf()
    property var globe: null                    // GlobeLayer: lightAt / lightPos / containsGlobe; its own pointer area is off
    property var label: null                    // the live label (AerialLabel): btDeviceAt(lx, ly) / btDeviceSpot(address), card-local mm; it reads `hint` and `carriedBt`
    property var geo: null
    property var labelMap: null                 // the scene's label map (card-local mm <-> item px)
    property var zone: []                       // the label's Wi-Fi zone, a polygon in item px
    property var btZone: []                     // the label's Bluetooth zone
    property var labelPoly: []                  // the whole label
    property bool enabled: true
    property real renderScale: 1
    property real time: 0
    property real dragSlop: 5
    property real maxLag: 6
    property real pullOut: 14                   // px past the label a pulled thing must be let go for the disconnect
    property int restMs: 110                    // the pointer rests this long on a tag before it opens
    property int heldDeviceMs: 20000            // a device let go on the label hovers there at most this long for the facts' word

    // ---- out ----
    signal activated(string intent, point at)
    signal intent(string name, var args)        // every intent sent (a probe and the owner's log read it)
    readonly property string hoverKey: root._hoverKey
    readonly property bool hot: root._hot       // the pointer is over something of the controller's (the hand cursor)
    readonly property string carriedKind: root._carried ? root._carried.kind : ""
    readonly property string globeHover: root._globeHover
    readonly property string carriedKey: root._carried ? root._carried.key : ""
    readonly property bool dragging: root._phase === "carry"
    readonly property string heldKey: root._held ? root._held.key : ""
    readonly property string phase: root._phase
    // which zone of the label what is in the hand (or hovering over it) may land on: the label draws its own glow
    readonly property string hint: {
        const c = root._carried;
        if (!c || (root._phase !== "carry" && root._phase !== "held"))
            return "";
        return c.kind === "bt" ? "bt" : (c.kind === "net" || c.kind === "hotspot" || c.kind === "country") ? "wifi" : "";
    }
    // the connected device being pulled off the label: the label hides its row
    readonly property string carriedBt: root._carried && root._carried.kind === "btdock" ? root._carried.key : ""
    readonly property real carryX: root._cx
    readonly property real carryY: root._cy
    readonly property bool inZone: root._phase === "carry" && root._overLabel

    // ---- state ----
    property string _hoverKey: ""
    property string _restKey: ""
    property bool _hot: false
    property string _globeHover: ""
    property string _phase: "idle"              // idle | pressed | carry | back | held | docking
    property var _press: null                   // { x, y, target }
    property var _carried: null                 // { key, kind, entry, home: [x, y], grab: [dx, dy], external }
    property var _held: null
    property real _cx: 0
    property real _cy: 0
    property real _vx: 0
    property real _vy: 0
    property real _tx: 0
    property real _ty: 0
    property bool _overLabel: false
    property real _flight: 0                    // the docking flight 0..1
    property real _shake: 0
    property var _flightFrom: [0, 0]
    readonly property var _zoneCentre: root.zone.length ? CP.centreOf(root.zone) : [0, 0]
    readonly property var _btCentre: root.btZone.length ? CP.centreOf(root.btZone) : root._zoneCentre

    function _deviceOf(address: string): var {
        const ds = root.service && root.service.bt ? root.service.bt.devices || [] : [];
        for (let i = 0; i < ds.length; i++)
            if (ds[i].address === address)
                return ds[i];
        return null;
    }
    function _onLabel(x: real, y: real, slack: real): bool {
        return root.labelPoly.length > 0 && CP.distToPoly(root.labelPoly, x, y) <= slack;
    }
    function _hit(x: real, y: real): var {
        let best = null, bd = 1e9;
        const ts = root.cloud ? root.cloud.targets() : [];
        for (let i = 0; i < ts.length; i++) {
            const r = ts[i].rect;
            if (x < r.x || x > r.x + r.width || y < r.y || y > r.y + r.height)
                continue;
            const d = Math.hypot(x - (r.x + r.width / 2), y - (r.y + r.height / 2));
            if (d < bd) { bd = d; best = ts[i]; }
        }
        if (best)
            return best;
        const g = root.globe ? root.globe.lightAt(x, y) : null;
        if (g) {
            const pr = root.service ? root.service.proton : null;
            const px = pr && pr.state === "up" && pr.server ? pr.server.country : "";
            const p = root.globe.lightPos(g.code);
            // the light the tunnel hangs on: its country's, and the "fastest" light while the tunnel up is the one that light raised (the facts' `fastest`)
            const tun = (px !== "" && g.code === px) || (g.code === "fastest" && !!pr && pr.state === "up" && pr.fastest === true);
            return { key: g.code, kind: tun ? "tunnel" : "country", x: p ? p.x : g.x, y: p ? p.y : g.y,
                     entry: { kind: "net", ssid: g.name, form: "named", arc: 0, signal: 100, secured: false, known: true, publicNet: false, bands: [], bestBand: "5", sec: "" } };
        }
        if (root.globe && root.globe.containsGlobe(x, y))
            return { key: "globe", kind: "sphere", x: x, y: y, entry: null };
        const svc = root.service;
        if (!svc)
            return null;
        // a connected device's row on the label's Bluetooth zone
        if (root.btZone.length && CP.inPoly(root.btZone, x, y) && root.label && typeof root.label.btDeviceAt === "function" && root.labelMap && root.geo) {
            const lp = CP.labelPoint(root.geo, root.labelMap, x, y);
            const a = String(root.label.btDeviceAt(lp[0], lp[1]) || "");
            const d = a !== "" ? root._deviceOf(a) : null;
            if (d)
                return { key: a, kind: "btdock", x: x, y: y,
                         entry: { kind: "bt", dev: d.kind || "generic", ssid: d.name || a, form: "named", arc: "bt", paired: true, pairing: false, battery: d.battery === undefined ? -1 : d.battery, known: true } };
        }
        if (root.zone.length && CP.inPoly(root.zone, x, y)) {
            if (svc.hotspot && svc.hotspot.active)
                return { key: "hotspot", kind: "hsdock", x: x, y: y, entry: { kind: "hotspot", ssid: svc.hotspot.ssid || "Hotspot", form: "named", arc: 0, signal: 100, secured: false, known: true, publicNet: false, bands: [] } };
            const a = svc.wifi ? svc.wifi.active : null;
            if (a)
                return { key: a.key || "", kind: "dock", x: x, y: y,
                         entry: { kind: "net", ssid: a.ssid || a.key || "", form: "named", arc: 0, signal: Math.max(0, Math.min(100, Math.round(2 * ((a.dbm || -60) + 100)))), secured: true, known: true, publicNet: false,
                                  bands: a.band ? [String(a.band)] : [], bestBand: a.band ? String(a.band) : "5", sec: "" } };
        }
        return null;
    }
    function _isTag(t: var): bool {
        return !!t && (t.kind === "net" || t.kind === "bt" || t.kind === "hotspot" || t.kind === "client");
    }
    function hoverAt(x: real, y: real): void {
        if (root._phase === "carry") {
            root._hoverKey = "";
            root._restKey = "";
            root._hot = false;
            return;
        }
        const t = x < 0 ? null : root._hit(x, y);
        root._hot = !!t;
        root._globeHover = t && (t.kind === "country" || t.kind === "tunnel") ? t.key : "";
        const k = root._isTag(t) ? t.key : "";
        if (k === "") {
            root._restKey = "";
            root._hoverKey = "";
            rest.stop();
        } else if (k !== root._hoverKey && k !== root._restKey) {
            // another tag: the open one closes at once, this one opens when the pointer has rested on it
            root._hoverKey = "";
            root._restKey = k;
            rest.restart();
        }
    }
    Timer {
        id: rest
        interval: root.restMs
        onTriggered: root._hoverKey = root._restKey
    }

    // ---- the press, the drag, the release ----
    function _intentOf(t: var): string {
        if (t.kind === "dock" || t.kind === "hsdock")
            return "label";
        if (t.kind === "bt" || t.kind === "btdock")
            return "bt:" + t.key;
        if (t.kind === "hotspot" || t.kind === "client")
            return "hotspot";
        // (the "fastest" light is a toggle: lit by the tunnel it raised, its click is the popup's to answer -- down again -- and never the panel)
        if (t.kind === "tunnel" && t.key === "fastest")
            return "country:fastest";
        if (t.kind === "sphere" || t.kind === "tunnel")
            return "globe";
        if (t.kind === "country")
            return "country:" + t.key;
        return "net:" + t.key;
    }
    MouseArea {
        id: area
        anchors.fill: parent
        enabled: root.enabled
        acceptedButtons: Qt.LeftButton
        cursorShape: undefined   // a press it does not want passes through: the cursor is what lies under it (a MouseArea owns an Arrow)
        hoverEnabled: false
        preventStealing: root._phase === "carry"
        onPressed: mouse => {
            if (root._phase !== "idle" && root._phase !== "held" && root._phase !== "back") {
                mouse.accepted = false;
                return;
            }
            const t = root._hit(mouse.x, mouse.y);
            if (!t) {
                mouse.accepted = false;
                return;
            }
            root._press = { x: mouse.x, y: mouse.y, target: t };
            root._phase = "pressed";
        }
        onPositionChanged: mouse => {
            if (root._phase === "pressed") {
                if (Math.hypot(mouse.x - root._press.x, mouse.y - root._press.y) < root.dragSlop)
                    return;
                root._begin(root._press.target, root._press.x, root._press.y);
            }
            if (root._phase === "carry")
                root._move(mouse.x, mouse.y);
        }
        onReleased: mouse => {
            if (root._phase === "pressed") {
                const t = root._press.target;
                root._phase = root._held ? "held" : "idle";
                root._press = null;
                const at = t.kind === "dock" || t.kind === "hsdock" ? root._zoneCentre : [t.x, t.y];
                root.activated(root._intentOf(t), Qt.point(at[0], at[1]));
            } else if (root._phase === "carry") {
                root._release(mouse.x, mouse.y);
            }
        }
        onCanceled: {
            if (root._phase === "carry")
                root._springBack();
            else if (root._phase === "pressed")
                root._phase = root._held ? "held" : "idle";
        }
    }

    function _begin(t: var, px: real, py: real): void {
        if (t.kind === "sphere" || t.kind === "client") {      // the sphere and a hotspot's client are not carried: a drag of one is nothing
            root._phase = root._held ? "held" : "idle";
            root._press = null;
            return;
        }
        const home = [t.x, t.y];
        // (one thing is the hand's at a time: whatever still hovered over the label is let go of -- its own tag in the air shows again)
        root._held = null;
        heldDevice.stop();
        verdict.stop();
        root._carried = { key: t.key, kind: t.kind, entry: t.entry, home: home, grab: [home[0] - px, home[1] - py], external: false };
        root._cx = home[0];
        root._cy = home[1];
        root._vx = 0;
        root._vy = 0;
        root._tx = home[0];
        root._ty = home[1];
        root._overLabel = false;
        root._phase = "carry";
        root._press = null;
        root._hoverKey = "";
        root._restKey = "";
    }
    // the globe's countries: its component calls this at ITS press-and-slop with the country as `spec` { key (the code), entry (a tag's facts), home: [x, y] item px }
    function startExternal(spec: var, px: real, py: real): void {
        if (root._phase !== "idle" && root._phase !== "pressed")
            return;
        root._carried = { key: spec.key, kind: "country", entry: spec.entry, home: spec.home, grab: [spec.home[0] - px, spec.home[1] - py], external: true };
        root._cx = spec.home[0];
        root._cy = spec.home[1];
        root._vx = 0;
        root._vy = 0;
        root._tx = spec.home[0];
        root._ty = spec.home[1];
        root._phase = "carry";
        root._press = null;
    }
    // the pointer of an external drag
    function moveExternal(x: real, y: real): void {
        if (root._phase === "carry")
            root._move(x, y);
    }
    function releaseExternal(x: real, y: real): void {
        if (root._phase === "carry")
            root._release(x, y);
    }
    function _move(x: real, y: real): void {
        root._tx = x + root._carried.grab[0];
        root._ty = y + root._carried.grab[1];
        root._overLabel = root._onLabel(x, y, 8);
    }
    function _springBack(): void {
        const c = root._carried;
        if (!c) {
            root._phase = "idle";
            return;
        }
        const live = root._homeNow(c);
        root._tx = live[0];
        root._ty = live[1];
        root._phase = "back";
    }
    function _homeNow(c: var): var {
        if (c.kind === "country" || c.kind === "tunnel") {
            const p = root.globe ? root.globe.lightPos(c.key) : null;
            return p ? [p.x, p.y] : c.home;
        }
        if (c.kind === "btdock") {
            const s = root.label && typeof root.label.btDeviceSpot === "function" ? root.label.btDeviceSpot(c.key) : null;
            return s && root.labelMap && root.geo ? CP.labelPx(root.geo, root.labelMap, s[0], s[1]) : c.home;
        }
        if (c.kind === "dock" || c.kind === "hsdock")
            return c.home;
        const h = root.cloud ? root.cloud.homeOf(c.key) : null;
        return h || c.home;
    }
    function _netOf(key: string): var {
        const nets = root.service && root.service.wifi ? root.service.wifi.networks || [] : [];
        for (let i = 0; i < nets.length; i++)
            if (nets[i].key === key)
                return nets[i];
        return null;
    }
    function _send(name: string, args: var): void {
        root.intent(name, args);
        const s = root.service;
        if (!s)
            return;
        if (name === "connect")
            s.connect(args[0], args[1]);
        else if (name === "disconnect")
            s.disconnect();
        else if (name === "startHotspot")
            s.startHotspot();
        else if (name === "stopHotspot")
            s.stopHotspot();
        else if (name === "vpnConnect")
            s.vpnConnect(args[0]);
        else if (name === "vpnDisconnect")
            s.vpnDisconnect();
        else if (name === "btPair")
            s.btPair(args[0]);
        else if (name === "btConnect")
            s.btConnect(args[0]);
        else if (name === "btDisconnect")
            s.btDisconnect(args[0]);
    }
    function _release(x: real, y: real): void {
        const c = root._carried;
        const onLabel = root._onLabel(x, y, 8);
        if (c.kind === "net") {
            if (onLabel) {
                // (it HOVERS before anything is asked: a service that refuses at once cues inside the call, and the cue is for what hovers)
                const e = c.entry;
                root._held = { key: c.key, kind: "net" };
                root._park();
                const hiddenNoName = e.hidden && !e.ssid;
                if (hiddenNoName || (e.secured && !e.known)) {
                    root.activated("net:" + c.key, Qt.point(root._zoneCentre[0], root._zoneCentre[1]));    // the panel asks the name / the password
                } else {
                    root._send("connect", [c.key, {}]);
                }
                return;
            }
            root._dropHere(c, x, y);
        } else if (c.kind === "hotspot") {
            if (onLabel) {
                root._held = { key: c.key, kind: "hotspot" };
                root._park();
                root._send("startHotspot", []);
                return;
            }
            root._dropHere(c, x, y);
        } else if (c.kind === "bt") {
            if (onLabel) {
                root._held = { key: c.key, kind: "bt" };
                heldDevice.restart();
                root._park();
                root._send(c.entry.paired ? "btConnect" : "btPair", [c.key]);
                return;
            }
            root._dropHere(c, x, y);
        } else if (c.kind === "country") {
            if (onLabel) {
                if (root.globe)
                    root.globe.ask(c.key, "up");
                root._send("vpnConnect", [root.globe ? root.globe.connectArgs(c.key) : { country: c.key }]);
                root._finish();
                return;
            }
        } else if (c.kind === "tunnel") {
            // the tunnel's country pulled off the globe = the tunnel down; let go on the globe and it goes back
            if (root.globe && !root.globe.containsGlobe(x, y) && Math.hypot(x - c.home[0], y - c.home[1]) > 22) {
                root.globe.ask(c.key, "down");
                root._send("vpnDisconnect", []);
                root._finish();
                return;
            }
        } else if (c.kind === "dock" || c.kind === "hsdock") {
            if (!root._onLabel(x, y, root.pullOut)) {
                root._send(c.kind === "dock" ? "disconnect" : "stopHotspot", []);
                root.liftFrom = [root._cx, root._cy];
                liftClear.restart();
                root._finish();
                return;
            }
        } else if (c.kind === "btdock") {
            if (!root._onLabel(x, y, root.pullOut)) {
                root._send("btDisconnect", [c.key]);
                root._finish();
                return;
            }
        }
        root._springBack();
    }
    // let go where there is no target: the tag STAYS there until the popup closes (the cloud keeps the offset; the spring below settles on it)
    function _dropHere(c: var, x: real, y: real): void {
        if (root.cloud)
            root.cloud.setOffset(c.key, x + c.grab[0], y + c.grab[1]);
    }
    // where a pulled network was let go: the cloud lifts the disconnected network from there (empty = from the label)
    property var liftFrom: []
    Timer {
        id: liftClear
        interval: 4000
        onTriggered: root.liftFrom = []
    }
    function _finish(): void {
        root._carried = null;
        root._phase = root._held ? "held" : "idle";
    }
    // hover over its zone of the label, pulsing, until the facts say what became of it
    readonly property var _parkAt: root._carried && root._carried.kind === "bt" ? root._btCentre : root._zoneCentre
    function _park(): void {
        root._tx = root._parkAt[0];
        root._ty = root._parkAt[1] - 6;
        root._phase = "held";
    }
    // the owner says the attempt is given up (the password field closed with nothing): it drifts back
    function giveUp(key: string): void {
        if (!root._held || root._held.key !== key)
            return;
        root._held = null;
        verdict.stop();
        root._springBack();
    }
    Timer {
        // a device that neither connected nor failed aloud: it drifts back
        id: heldDevice
        interval: root.heldDeviceMs
        onTriggered: if (root._held && root._held.kind === "bt") root.giveUp(root._held.key)
    }
    function _watch(): void {
        const h = root._held, s = root.service;
        // ONLY WHILE IT HOVERS: a flight that has begun is not begun again by the next publication, a thing in the hand is not judged
        if (!h || !s || !root._carried || root._phase !== "held")
            return;
        if (h.kind === "hotspot") {
            if (s.hotspot && s.hotspot.active)
                root._dockNow();
            return;
        }
        if (h.kind === "bt") {
            const d = root._deviceOf(h.key);
            if (d && d.connected)
                root._dockNow();
            else if (!d)
                root.giveUp(h.key);
            return;
        }
        const a = s.wifi ? s.wifi.active : null;
        const n = root._netOf(h.key);
        if ((a && a.key === h.key) || (n && n.connected)) {
            root._dockNow();
        } else if (h.cued && n && (n.state === "failed" || n.state === "needsSecret") && root._failSig(n) !== h.before) {
            // the failure the service just cued, now in the facts (they changed since the cue: what they said before was an earlier attempt's)
            root._verdict(n);
        } else if (!n) {
            root._held = null;
            root._springBack();
        }
    }
    function _failSig(n: var): string {
        return n ? String(n.state) + "|" + String(n.failReason || "") : "";
    }
    // A password that is missing or was refused: it stays, and the panel asks (again); anything else is over
    function _verdict(n: var): void {
        const h = root._held;
        h.cued = false;
        verdict.stop();
        if (n && n.state === "needsSecret")
            root.activated("net:" + h.key, Qt.point(root._zoneCentre[0], root._zoneCentre[1]));
        else
            root._over();
    }
    // the attempt is over: it drifts back once its shake is done
    function _over(): void {
        const h = root._held;
        if (!h)
            return;
        if (shake.running)
            h.over = true;
        else
            root.giveUp(h.key);
    }
    Timer {
        // a cued failure the facts did not change for: the same failure as the attempt before, or none told at all (the helper is not running). What they say now
        // decides. (Longer than a mock's settle: its refused password lands that much after its cue.)
        id: verdict
        interval: 1500
        onTriggered: if (root._held && root._held.cued) root._verdict(root._netOf(root._held.key))
    }
    function _dockNow(): void {
        root._flightFrom = [root._cx, root._cy];
        root._flight = 0;
        root._phase = "docking";
        heldDevice.stop();
        verdict.stop();
        dockAnim.restart();
    }
    Connections {
        target: root.service
        ignoreUnknownSignals: true
        function onSerialChanged() {
            root._watch();
        }
        // a failed intent names its part: a device that was refused drifts back to the air
        function onCue(part: string) {
            const h = root._held;
            if (!h || root._phase !== "held")
                return;
            if (h.kind === "bt" && part === "bt:" + h.key) {
                root.giveUp(h.key);
            } else if (h.kind === "hotspot" && part === "hotspot") {
                shake.restart();
                root._over();
            } else if (h.kind === "net" && part === "net:" + h.key) {
                // (the facts that say WHY follow the cue: `_watch` judges them once they have changed)
                h.cued = true;
                h.before = root._failSig(root._netOf(h.key));
                shake.restart();
                verdict.restart();
            }
        }
    }
    NumberAnimation {
        id: dockAnim
        target: root
        property: "_flight"
        from: 0
        to: 1
        duration: 320
        easing.type: Easing.InOutCubic
        onFinished: {
            root._held = null;
            root._carried = null;
            root._phase = "idle";
        }
    }
    SequentialAnimation {
        id: shake
        NumberAnimation { target: root; property: "_shake"; from: 0; to: 1; duration: 60 }
        NumberAnimation { target: root; property: "_shake"; to: -1; duration: 110 }
        NumberAnimation { target: root; property: "_shake"; to: 0.6; duration: 90 }
        NumberAnimation { target: root; property: "_shake"; to: 0; duration: 80 }
        onFinished: if (root._held && root._held.over === true && root._phase === "held") root.giveUp(root._held.key)
    }

    // ---- the spring: runs only while something is carried or settling ----
    readonly property bool _moving: root._phase === "carry" || root._phase === "back" || root._phase === "held"
    FrameAnimation {
        running: root._moving
        onTriggered: root._step(Math.min(frameTime, 0.05))
    }
    function _step(dt: real): void {
        const k = 1500, cdamp = 2 * Math.sqrt(k) * 0.85;
        let tx = root._tx, ty = root._ty;
        if (root._phase === "held") {
            tx = root._parkAt[0];
            ty = root._parkAt[1] - 6 + 3 * Math.sin(root.time * 2 * Math.PI / 1.1);
        }
        root._vx += (k * (tx - root._cx) - cdamp * root._vx) * dt;
        root._vy += (k * (ty - root._cy) - cdamp * root._vy) * dt;
        root._cx += root._vx * dt;
        root._cy += root._vy * dt;
        // never more than a few px behind the hand
        if (root._phase === "carry") {
            const lx = tx - root._cx, ly = ty - root._cy, l = Math.hypot(lx, ly);
            if (l > root.maxLag) {
                root._cx = tx - lx / l * root.maxLag;
                root._cy = ty - ly / l * root.maxLag;
            }
        }
        if (root._phase === "back" && Math.hypot(tx - root._cx, ty - root._cy) < 0.6 && Math.hypot(root._vx, root._vy) < 8) {
            root._cx = tx;
            root._cy = ty;
            root._finish();
        }
    }

    // ---- what is in the hand: the same tag the cloud draws, open, leaning with its speed ----
    Item {
        id: carry
        visible: root._carried !== null
        readonly property real px: root._phase === "docking" ? root._flightFrom[0] + (root._parkAt[0] - root._flightFrom[0]) * root._flight : root._cx
        readonly property real py: root._phase === "docking" ? root._flightFrom[1] + (root._parkAt[1] - root._flightFrom[1]) * root._flight : root._cy
        readonly property real rs: root.renderScale > 0.01 ? root.renderScale : 1
        x: Math.round((carry.px - carryTag.width / 2 + (root._phase === "held" ? root._shake * 5 : 0)) * carry.rs) / carry.rs
        y: Math.round((carry.py - carryTag.height / 2) * carry.rs) / carry.rs
        width: carryTag.width
        height: carryTag.height
        z: 5
        rotation: root._phase === "carry" || root._phase === "back" ? Math.max(-10, Math.min(10, root._vx * 0.012)) : 0
        scale: root._phase === "docking" ? 1 - 0.5 * root._flight : 1
        CloudTag {
            id: carryTag
            entry: root._carried ? root._carried.entry : null
            hue: root._carried && root._carried.entry && root._carried.entry.bestBand && root.cloud ? root.cloud.hueOf(root._carried.entry.bestBand) : BarHues.aerialBand5
            btHue: BarHues.btOn
            carried: true
            target: root.inZone || root._phase === "held"
            renderScale: carry.rs
            presence: root._phase === "docking" ? 1 - root._flight : 1
            glint: root._phase === "held" ? 0.5 + 0.5 * Math.sin(root.time * 2 * Math.PI / 1.1) : 0
        }
    }

    // ---- the label is told (it draws its own drop glow and hides a carried device's row): only once the label has those properties ----
    Loader {
        active: root.label !== null && ("hint" in root.label) && ("carriedBt" in root.label)
        sourceComponent: Item {
            Binding { target: root.label; property: "hint"; value: root.hint }
            Binding { target: root.label; property: "carriedBt"; value: root.carriedBt }
        }
    }
}
