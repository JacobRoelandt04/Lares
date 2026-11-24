pragma ComponentBehavior: Bound

import QtQuick

import "../common/theme"
import "../common/glyphs"
import "../common/components"
import "../common/components/Mix.js" as Mix
import "bar/BridgePose.js" as Pose
import "bar/BridgeTraffic.js" as Traffic

// =============================================================================
// BridgeBarButton.qml -- the bridge's icon: A DRAWBRIDGE, md-bridge U+F0618 (the user's idea, 2026-11-21). The left tower is this
// computer, the right one the phone.
//
// THE SHAPE IS THE STATE (BridgePose.js moves the font's own outline; at rest, down, it IS the font's glyph):
//
//   no phone around         both leaves RAISED, bare (the cable and its suspenders folded down onto them), in the faint ink
//   the phone in reach      the bridge DOWN, in the plain bar ink -- over Wi-Fi and on the cable alike (the user is connected
//                           nine times in ten: that state takes no colour and no mark)
//   the phone asks to pair  the PHONE's leaf down alone, in the warn hue, until the request is answered
//
// WHAT CROSSES IS WHAT HAPPENS (BridgeTraffic.js): a car is one dot on the deck, and it drives the way the data goes.
//
//   a file send             a convoy to the phone while the job runs
//   the clipboard, sent     one car to the phone;   a screenshot: one car from it
//   a cast or a mirror      one car at a time from the phone, for as long as it runs (also with the popup closed), in the ACCENT
//   storage mounted         a car PARKED at the phone's tower
//   something failed        the car stops at mid span in the error red and backs off the way it came
//   the phone made to ring  no car: two thin waves off the phone's tower
//
// Colour is for the rare things only (a cast, a failure, a pairing request); the pointer takes the glyph to its hover hue
// (`bridgeHover`), and so does a file held over it. All inks are mixed from eased fractions (Mix.js), never a `Behavior on color`.
//
// MOTION. The leaves' lifts are two eased fractions: coming down they land on the pier and BOUNCE (OutBounce: never through the
// deck), going up they overshoot their stop a little and settle. The first line a service delivers is the state
// the shell starts in, not news: it is taken without a motion. THE FLOURISH (GlyphFlourish: the pointer's entry, the OLED care's
// random turns; group `bridge`, decorative) is a SALUTE: a bridge that is down swings its leaves up, drops them and they bounce
// on the pier; a raised one dips them and bounces off its stop (BridgePose.bow), and the WHOLE glyph hops with them (jump; cars ride
// along). It never reaches the other state and never
// shows a car, so it cannot be read as news. The same clock plays the deck's sag when the cable goes in. Each is sized to read
// at 15 px (the user, 2026-11-21: the first salute was "barely visible").
//
// WHAT A LONG RUN COSTS. A bar repaint is a whole-window frame, and a cast lasts an hour: its car moves a WHOLE DEVICE PIXEL at a
// time, on one timer (a handful of frames a second, none at rest). Short traffic runs on a clock that exists only while a car is
// on the deck. Everything holds still while the theme crossfades.
//
// `service` is a BridgeService (null = raised and faint); it is read for `ready`, `serial`, `current` ({ key, present, link,
// mounts }), `jobs` ([{ id, device, kind, phase }]), `pairing` ([{ byPeer }]), `casting` / `castKey` and its `acted` signal.
// The click is the host's: a left click calls `owner.toggle()`. A FILE dropped on the glyph is `filesDropped(paths)`.
// =============================================================================
BarGlyphButton {
    id: btn

    // a BridgeService (or anything that has what is read above); null = nothing to say
    property var service: null
    // anything with toggle(): a left click calls it
    property var owner: null
    property bool flourishEnabled: true
    // a harness: false takes every state at once (no leaf or car on its way), and a cast's car stands at `holdCastStep`
    property bool motion: true
    property int holdCastStep: -1
    // the pose's numbers (BridgePose.DEFAULTS) a mockup may override
    property var look: null

    // local file paths (strings) dropped on the glyph
    signal filesDropped(var paths)

    // ---- the facts ----
    readonly property var _cur: btn.service ? btn.service.current : null
    readonly property bool present: !!btn._cur && btn._cur.present === true
    readonly property bool wired: btn.present && (btn._cur.link === "usb" || btn._cur.link === "both")
    // the popup's cast runs for the current device, or a mirror of it is starting or running
    readonly property bool casting: {
        const cur = btn._cur, svc = btn.service;
        if (!cur || !svc || !btn.present)
            return false;
        if (svc.casting === true && svc.castKey === cur.key)
            return true;
        const js = svc.jobs || [];
        for (let i = 0; i < js.length; i++)
            if (js[i].kind === "mirror" && js[i].device === cur.key && (js[i].phase === "starting" || js[i].phase === "running"))
                return true;
        return false;
    }
    readonly property bool sending: {
        const cur = btn._cur, js = btn.service ? (btn.service.jobs || []) : [];
        for (let i = 0; cur && btn.present && i < js.length; i++)
            if (js[i].kind === "send" && js[i].device === cur.key && (js[i].phase === "starting" || js[i].phase === "running"))
                return true;
        return false;
    }
    readonly property bool mounted: {
        const m = btn._cur && btn.present ? (btn._cur.mounts || {}) : {};
        return (!!m.usb && m.usb.state === "mounted") || (!!m.wifi && m.wifi.state === "mounted");
    }
    // a phone asks to pair and none is connected: its leaf comes down alone
    readonly property bool pairAsked: {
        const ps = btn.service ? (btn.service.pairing || []) : [];
        for (let i = 0; !btn.present && i < ps.length; i++)
            if (ps[i].byPeer === true)
                return true;
        return false;
    }

    // ---- the leaves: 0 down, 1 raised. Down they land and bounce on the pier; up they overshoot and settle. ----
    property real _upL: btn.present ? 0 : 1
    property real _upR: btn.present || btn.pairAsked ? 0 : 1
    Behavior on _upL {
        enabled: btn._seeded && btn.motion
        NumberAnimation {
            duration: btn.present ? 760 : 560
            easing.type: btn.present ? Easing.OutBounce : Easing.OutBack
            easing.overshoot: 1.3
        }
    }
    Behavior on _upR {
        enabled: btn._seeded && btn.motion
        NumberAnimation {
            duration: btn.present || btn.pairAsked ? 760 : 560
            easing.type: btn.present || btn.pairAsked ? Easing.OutBounce : Easing.OutBack
            easing.overshoot: 1.3
        }
    }
    property real _presentF: btn.present ? 1 : 0
    Behavior on _presentF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    property real _pairF: btn.pairAsked ? 1 : 0
    Behavior on _pairF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    property real _dragF: drop.containsDrag ? 1 : 0
    Behavior on _dragF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    glyph: String.fromCodePoint(0xF0618)
    ink: Mix.c(Mix.c(Mix.c(Theme.textFaint, Theme.textMuted, btn._presentF), Theme.warn, btn._pairF), BarHues.bridgeHover, btn._dragF)
    hoverInk: BarHues.bridgeHover

    onClicked: button => {
        if (button === Qt.LeftButton && btn.owner)
            btn.owner.toggle();
    }

    // ---- the flourish: the salute (and the deck's sag as the cable goes in) ----
    readonly property alias flourish: salute
    readonly property alias traffic: trafficGlyph
    GlyphFlourish {
        id: salute
        group: "bridge"
        decorative: true
        armed: btn.flourishEnabled
        ms: salute.why === "cable" ? Pose.DEFAULTS.settleMs : Pose.DEFAULTS.bowMs
        // a second ask while it plays is ignored: a restart would snap the leaves back
        overlap: "ignore"
        hoverArea: btn.area
    }
    function _play(up: real): real {
        if (!salute.playing)
            return 0;
        return salute.why === "cable" ? Pose.settle(salute.t, salute.ms, btn.look) : Pose.bow(salute.t, salute.ms, up > 0.5, btn.look);
    }
    readonly property real liftL: btn._upL + btn._play(btn._upL)
    readonly property real liftR: btn._upR + btn._play(btn._upR)
    // the whole glyph's hop (px, up positive): the salute lifts the bridge off the bar with its leaves and bounces it down with them
    readonly property real jumpPx: salute.playing ? Pose.jump(salute.t, salute.ms, salute.why === "cable", btn.look) * btn.glyphSize : 0
    posing: btn.liftL !== 0 || btn.liftR !== 0 || btn.jumpPx !== 0
    readonly property var _pose: btn.posing ? Pose.frame(btn.liftL, btn.liftR, btn.look, btn.glyphSize, btn.glyphOrigin.x, btn.glyphOrigin.y - btn.jumpPx, btn._upL, btn._upR) : null
    parts: btn._pose ? btn._pose.parts : []

    // ---- the traffic ----
    DeviceScale {
        id: dev
    }
    // ms on the traffic's own clock: it runs only while something short is on the deck (a car, a failure, the waves)
    property real _now: 0
    property var _cars: []                  // [{ dir, born }]: one crossing each
    property real _failBorn: -1
    property int _failDir: 1
    property real _ringBorn: -1
    readonly property bool _short: btn._cars.length > 0 || btn._failBorn >= 0 || btn._ringBorn >= 0
    NumberAnimation {
        id: trafficClock
        target: btn
        property: "_now"
        from: 0
        to: 3600000
        duration: 3600000
        running: btn._short && !Theme.crossfading
    }
    on_ShortChanged: {
        // nothing short is left: the clock goes back, so the next car is born at 0
        if (!btn._short)
            btn._now = 0;
    }
    on_NowChanged: {
        // what has finished leaves (the list is replaced only when it changes: a binding reads it)
        if (btn._cars.length > 0 && btn._now - btn._cars[0].born >= Traffic.CROSS_MS)
            btn._cars = btn._cars.filter(c => btn._now - c.born < Traffic.CROSS_MS);
        if (btn._failBorn >= 0 && btn._now - btn._failBorn >= Traffic.FAIL_MS)
            btn._failBorn = -1;
        if (btn._ringBorn >= 0 && btn._now - btn._ringBorn >= Traffic.RING_MS)
            btn._ringBorn = -1;
    }
    // One car across: +1 to the phone, -1 from it. Only over a bridge that is down, and never over a failure.
    function car(dir: int): void {
        if (!btn.present || btn._failBorn >= 0 || btn._cars.length >= 4)
            return;
        btn._cars = btn._cars.concat([{ dir: dir, born: btn._now + 1 }]);
    }
    function fail(dir: int): void {
        if (!btn.present || btn._failBorn >= 0)
            return;
        btn._cars = [];
        btn._failDir = dir;
        btn._failBorn = btn._now + 1;
    }
    function ring(): void {
        if (btn.present && btn._ringBorn < 0)
            btn._ringBorn = btn._now + 1;
    }
    // a send: a car, and another every GAP_MS while the job runs
    Timer {
        id: convoy
        interval: Traffic.GAP_MS
        repeat: true
        triggeredOnStart: true
        running: btn.sending && !Theme.crossfading
        onTriggered: btn.car(1)
    }
    // a cast: one car at a time from the phone, a whole device pixel a step, then a rest as long as half a crossing
    readonly property int _castSteps: Math.max(4, Math.round((Traffic.TO - Traffic.FROM) / 2048 * btn.glyphSize * dev.value))
    property int _castStep: -1
    // how often the cast's car moves, ms (what a long run costs: one repaint each)
    readonly property int castStepMs: castRun.interval
    Timer {
        id: castRun
        interval: Math.round(1700 / btn._castSteps)
        repeat: true
        running: btn.casting && btn.holdCastStep < 0 && !Theme.crossfading
        onTriggered: btn._castStep = btn._castStep >= Math.round(btn._castSteps * 1.5) ? 0 : btn._castStep + 1
    }
    onCastingChanged: {
        if (!btn.casting)
            btn._castStep = -1;
    }
    // the parked car drives in as a mount lands and out as it goes
    property real _parkF: btn.mounted ? 1 : 0
    Behavior on _parkF {
        enabled: btn._seeded && btn.motion
        NumberAnimation {
            duration: 420
            easing.type: Easing.OutCubic
        }
    }
    // the cars' places now (font units), and the waves: what the probe reads, and what is drawn
    readonly property var carXs: {
        const xs = [];
        if (!btn.present)
            return xs;
        if (btn._failBorn >= 0)
            xs.push(Traffic.failing(btn._now - btn._failBorn, btn._failDir));
        for (let i = 0; i < btn._cars.length; i++)
            xs.push(Traffic.crossing(btn._now - btn._cars[i].born, btn._cars[i].dir));
        if (btn.casting && btn.holdCastStep >= 0)
            xs.push(Traffic.longX(btn.holdCastStep, btn._castSteps, -1));
        else if (btn._castStep >= 0)
            xs.push(Traffic.longX(btn._castStep, btn._castSteps, -1));
        if (btn._parkF > 0)
            xs.push(Traffic.parked(btn._parkF));
        return xs.filter(x => x !== null);
    }
    readonly property string _trafficPath: Traffic.emit(btn.carXs, btn._ringBorn >= 0 ? Traffic.ring(btn._now - btn._ringBorn) : null,
                                                        btn.glyphSize, btn.glyphOrigin.x, btn.glyphOrigin.y - btn.jumpPx)
    // over the bridge, in its place (the same glyph laid out, never shown: only its parts): the cars may take another ink
    PosedGlyph {
        id: trafficGlyph
        anchors.centerIn: parent
        visible: btn._trafficPath !== ""
        text: btn.glyph
        family: btn.family
        pixelSize: btn.glyphSize
        posing: true
        parts: [btn._trafficPath]
        // a failure is red; a cast's cars (with nothing else on the deck) are the accent; the rest is the bridge's own ink
        color: btn._failBorn >= 0 ? Theme.error
             : (btn.casting && btn._cars.length === 0 && btn._ringBorn < 0 ? Theme.accent : btn.glyphItem.color)
    }

    // ---- news, read from the service itself once per accepted line (never from the bindings above, which have not followed) ----
    // `_seeded` is false until the first line: that line is the state the shell starts in, not news.
    property bool _seeded: false
    property string _lastKey: ""
    property bool _lastWired: false
    readonly property var _failedSeen: ({})
    function _take(): void {
        const svc = btn.service;
        if (!svc || svc.ready !== true)
            return;
        const cur = svc.current;
        const key = cur ? String(cur.key || "") : "";
        const present = !!cur && cur.present === true;
        const wired = present && (cur.link === "usb" || cur.link === "both");
        // a job of this phone that has just failed (each job once; the first line's are not news)
        const js = svc.jobs || [];
        for (let i = 0; i < js.length; i++) {
            const j = js[i];
            if (j.phase !== "failed" || btn._failedSeen[j.id] === true)
                continue;
            btn._failedSeen[j.id] = true;
            if (btn._seeded && j.device === key && present)
                btn.fail(j.kind === "send" ? 1 : -1);
        }
        // the cable went into a phone that was already here: the deck takes the weight
        if (btn._seeded && key === btn._lastKey && key !== "" && wired && !btn._lastWired && btn._upL === 0)
            salute.play("cable");
        btn._lastKey = key;
        btn._lastWired = wired;
        // (the leaves follow `present` by themselves; they are let move from the second line on)
        if (!btn._seeded)
            seedTimer.restart();
    }
    Timer {
        id: seedTimer
        interval: 0
        onTriggered: btn._seeded = true
    }
    Connections {
        target: btn.service
        ignoreUnknownSignals: true
        function onSerialChanged(): void {
            btn._take();
        }
        // a one-shot's end: what went across, or that it did not
        function onActed(key: string, action: string, ok: bool, why: string): void {
            const cur = btn.service.current;
            if (!cur || key !== cur.key)
                return;
            const toPhone = action === "send" || action === "clip";
            if (!ok) {
                if (["send", "clip", "shot", "mirror", "mountUsb", "mountWifi"].indexOf(action) >= 0)
                    btn.fail(toPhone ? 1 : -1);
            } else if (action === "clip") {
                btn.car(1);
            } else if (action === "shot") {
                btn.car(-1);
            } else if (action === "ring") {
                btn.ring();
            }
        }
    }
    onServiceChanged: {
        btn._seeded = false;
        btn._take();
    }

    // ---- a file dropped on the glyph ----
    // The DropArea is the button's whole square (the decoration item is the glyph's alone).
    DropArea {
        id: drop
        x: (parent.width - btn.width) / 2
        y: (parent.height - btn.height) / 2
        width: btn.width
        height: btn.height
        keys: []
        function _local(urls): var {
            const paths = [];
            for (let i = 0; i < urls.length; i++) {
                const u = urls[i].toString();
                if (u.indexOf("file://") === 0)
                    paths.push(decodeURIComponent(u.substring(7)));
            }
            return paths;
        }
        onEntered: drag => {
            drag.accepted = drag.hasUrls && drop._local(drag.urls).length > 0;
        }
        onDropped: d => {
            const paths = d.hasUrls ? drop._local(d.urls) : [];
            if (paths.length === 0)
                return;
            d.accept();
            btn.filesDropped(paths);
        }
    }
}
