pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell

import "modules/common/mockup"
import "modules/common/theme"
import "modules/common/components/BarSpot.js" as BarSpot
import "modules/common/system"
import "modules/common/osd"
import "modules/silicon/data/SiliconModel.js" as SiliconModel
import "modules/bar/gooey"
import "modules/osd"
import "modules/osd/data"

// =============================================================================
// mockups/osd.qml -- the OSD on the REAL bar engine.
//
// RUN IT THROUGH tools/dev/osd_mockup.sh (`run` on the desktop, `smoke`, `grab`,
// `film`): private XDG dirs, so a run never writes the user's theme state or
// profiles' neighbours. The service runs with `live: false` -- no Pipewire, no
// Hyprland, no backlight: its sources simulate -- so nothing here touches the
// machine.
//
// A 1180 x 760 slice of the screen: a GooeyEngine with
//   - a 40 px TOP bar carrying two stand-in module buttons; each toggles a
//     fixed-size stand-in "thePopup" (the Host tab sizes it and says where),
//   - a slim RIGHT bar (thickness 6, reserve 0) from below the top bar to the
//     foot: the default OSD spot { bar: "right", along: 0.5 }, so the OSD is
//     vertical,
//   - an optional slim BOTTOM bar (Host tab) for a horizontal OSD,
//   - a stand-in toast lane (engine.openLane, a card the Host tab resizes),
//   - a fake FULLSCREEN window with the OsdPill at its top centre (the owner's
//     fullscreen flag follows FullscreenWatch, faked).
// The OSD itself is OsdOwner + OsdContent, exactly as the shell will wire them;
// only the host around them is stand-in.
//
// THE PANEL
//   Run      scenarios (each a short script), one button per kind, the keys,
//            the collisions, the fullscreen toggle, the recorder (scrub a dip).
//   Slot     the engine's osd* tunables (target: the engine).
//   Content  OsdStyle: time, geometry, type, levels, cards, sizes per kind and
//            orientation.
//   Kinds    per kind: route and time (the service's config, applied the way
//            osd.jsonc would be) and the owner's timing / queue.
//   Pill     OsdStyle's pill numbers.
//   Host     bars, spot, stand-ins, fullscreen mode.
//
// ENV   OSD_ACT="verb[:arg]@ms,..."   scripted steps (see act())
//       STAGE_GRAB=<png> GRAB_MS=<ms> ZOOM   (the framework's GRAB too)
// =============================================================================
MockupWindow {
    id: win

    moduleId: "osd"
    title: "OSD"
    stageLabel: "A section of the screen at 1:1 -- a top bar, a slim right bar, thePopup, the toast lane and the OSD"
    content: scene
    target: ostyle
    targets: ({
            slotParams: engine,
            ownerParams: owner,
            styleContent: ostyle,
            styleExtents: ostyle,
            stylePill: ostyle,
            kindParams: kindKnobs,
            hostParams: host
        })
    stageColor: "#1F2229"
    zoom: Number(Quickshell.env("ZOOM") || 0.8)
    panelWidth: 460
    fitContent: true

    lists: ({
            slotParams: win.slotParams,
            ownerParams: win.ownerParams,
            styleContent: win.styleContent,
            styleExtents: win.styleExtents,
            stylePill: win.stylePill,
            kindParams: win.kindParams,
            hostParams: win.hostParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Slot",
            subs: [
                { name: "Open, close", lists: ["slotParams"], groups: ["Open and close"] },
                { name: "Dip", lists: ["slotParams"], groups: ["Dip"] },
                { name: "Glide, collision", lists: ["slotParams"], groups: ["Glide", "Collision"] }
            ]
        },
        {
            name: "Content",
            subs: [
                { name: "Time, geometry", lists: ["styleContent"], groups: ["Time", "Geometry"] },
                { name: "Type", lists: ["styleContent"], groups: ["Type"] },
                { name: "Levels, lock keys", lists: ["styleContent"], groups: ["Levels", "Sparks", "Lock keys"] },
                { name: "Cards, track, capture", lists: ["styleContent"], groups: ["Cards", "Track", "Capture"] },
                { name: "Sizes (levels)", lists: ["styleExtents"], groups: ["Level (volume, mic, brightness)", "Keyboard light", "Lock keys", "Layout", "Theme"] },
                { name: "Sizes (cards)", lists: ["styleExtents"], groups: ["Track", "Bluetooth, network, vpn", "Capture", "Battery", "Power", "Generic"] }
            ]
        },
        {
            name: "Pill",
            lists: ["stylePill"]
        },
        {
            name: "Kinds",
            subs: [
                { name: "Routes, times", lists: ["kindParams"] },
                { name: "Timing, queue", lists: ["ownerParams"] }
            ]
        },
        {
            name: "Host",
            lists: ["hostParams"]
        }
    ]

    // ---- the pieces ---------------------------------------------------------------------------
    OsdService {
        id: svc
        live: false
    }
    OsdStyle {
        id: ostyle
    }
    // The compositor's fullscreen question, answered by the Run page's toggle.
    FullscreenWatch {
        id: fsw
        liveSignals: false
        fake: true
        fakeFullscreen: win.fsOn
    }
    property bool fsOn: false

    // What a probe needs of the scene.
    readonly property var refs: ({
            svc: svc,
            engine: engine,
            owner: owner,
            style: ostyle,
            pill: pillFrame.pill,
            pillFrame: pillFrame,
            host: host,
            kinds: kindKnobs,
            rec: rec,
            pose: pose
        })

    // The host's own knobs (the Host tab's target): a mockup's furniture, not the module's.
    QtObject {
        id: host
        property real rightThickness: 6
        property real bottomThickness: 6
        property bool bottomOn: false
        // The OSD's spot: a bar (index into win.barNames) and where along it.
        property int spotBar: 0
        property real spotAlong: 0.5
        property int fsMode: 0
        // The stand-ins.
        property real popupAlong: 0.5
        property real popupW: 260
        property real popupH: 300
        property int laneBar: 1
        property real laneAlong: 0.85
        property real laneW: 260
        property real laneH: 120
    }
    readonly property var barNames: ["right", "bottom", "top"]
    readonly property var barChoices: ["top", "right", "bottom"]

    // =====================================================================
    //  THE STAGE
    // =====================================================================
    Item {
        id: scene
        implicitWidth: 1180
        implicitHeight: 760

        Rectangle {
            anchors.fill: parent
            color: win.stageColor
        }

        GooeyEngine {
            id: engine
            anchors.fill: parent
            renderScale: win.stage ? win.stage.zoom : 1
            surfaceColor: Theme.surface
            barsList: [topBar, rightBar, bottomBar].filter(b => b.visible)

            GooeyBar {
                id: topBar
                engine: engine
                barId: "top"
                edge: "top"
                rawPos: 0
                rawLen: engine.w

                Repeater {
                    model: 2
                    Rectangle {
                        id: standinBtn
                        required property int index
                        objectName: "standinButton" + standinBtn.index
                        width: 78
                        height: 22
                        radius: 6
                        x: Math.round(60 + standinBtn.index * 96)
                        y: Math.round((topBar.height - height) / 2)
                        color: btnArea.containsMouse ? Theme.panelSunk : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: standinBtn.index === 0 ? "popup" : "popup 2"
                            color: Theme.textMuted
                            font.family: "Inter"
                            font.pixelSize: 11
                        }
                        MouseArea {
                            id: btnArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                const cx = standinBtn.x + standinBtn.width / 2;
                                engine.toggle("standin", "top", cx, null, null, false, standinComp, 0.5);
                            }
                        }
                    }
                }
            }
            GooeyBar {
                id: rightBar
                engine: engine
                barId: "right"
                edge: "right"
                thickness: host.rightThickness
                reserve: 0
                rawPos: topBar.thickness
                rawLen: engine.h - topBar.thickness
            }
            GooeyBar {
                id: bottomBar
                engine: engine
                visible: host.bottomOn
                barId: "bottom"
                edge: "bottom"
                thickness: host.bottomThickness
                reserve: 0
                rawPos: rightBar.thickness
                rawLen: engine.w * 0.7
            }
        }

        // The compositor's view of a fullscreen window: it covers the screen, the bars are under it.
        Rectangle {
            id: fsWindow
            anchors.fill: parent
            z: 5
            visible: win.fsOn
            color: Theme.listBox
            Text {
                anchors.centerIn: parent
                text: "a fullscreen window"
                color: Theme.textFaint
                font.family: "Inter"
                font.pixelSize: 22
            }
        }
        // The pill's window (OsdPillWindow in the shell, which is this frame and a window round it): top centre, over
        // everything, cut at its edges as a window is.
        OsdPillFrame {
            id: pillFrame
            z: 6
            clip: true
            style: ostyle
            renderScale: win.stage ? win.stage.zoom : 1
            x: Math.round((scene.width - pillFrame.width) / 2)
            y: 0
            width: pillFrame.implicitWidth
            height: pillFrame.implicitHeight
        }

        OsdOwner {
            id: owner
            engine: engine
            service: svc
            style: ostyle
            pill: pillFrame.pill
            fullscreen: fsw.fullscreen
            fullscreenMode: host.fsMode === 0 ? "pill" : "suppress"
            spot: ({ bar: win.barNames[host.spotBar], along: host.spotAlong })
        }
    }

    // ---- the stand-ins ------------------------------------------------------------------------------
    Component {
        id: standinComp
        Item {
            implicitWidth: host.popupW
            implicitHeight: host.popupH
            Text {
                anchors.centerIn: parent
                text: "thePopup"
                color: Theme.textMuted
                font.family: "Inter"
                font.pixelSize: 12
            }
        }
    }
    Component {
        id: laneComp
        Item {
            implicitWidth: host.laneW
            implicitHeight: host.laneH
            Text {
                anchors.centerIn: parent
                text: "toast lane"
                color: Theme.textMuted
                font.family: "Inter"
                font.pixelSize: 12
            }
        }
    }
    // Where a stand-in stands: BarSpot's rule, as the notification owner places its lane.
    function standinPlace(barName, along) {
        return BarSpot.placeOf({ bar: barName, along: along }, engine.barsList);
    }
    function openPopup(barName, along, w, h) {
        if (w !== undefined)
            host.popupW = w;
        if (h !== undefined)
            host.popupH = h;
        const p = win.standinPlace(barName, along);
        if (!p)
            return;
        if (engine.popupOpen)
            engine.close();
        engine.open("standin", p.barId, p.local, null, null, false, standinComp, p.alongAt);
    }
    function closePopup() {
        if (engine.popupOpen)
            engine.close();
    }
    property bool laneOn: false
    function openLane(barName, along, w, h) {
        if (w !== undefined)
            host.laneW = w;
        if (h !== undefined)
            host.laneH = h;
        const p = win.standinPlace(barName, along);
        if (!p)
            return;
        win.laneOn = true;
        engine.openLane("standin-lane", p.barId, p.local, null, null, false, laneComp, 0.5, p.alongAt);
    }
    function closeLane() {
        win.laneOn = false;
        engine.closeLane();
    }
    // The Host tab moves the stand-ins while they are out.
    function _laneFollow() {
        if (win.laneOn)
            win.openLane(win.barChoices[host.laneBar], host.laneAlong);
    }
    Connections {
        target: host
        function onLaneBarChanged() {
            win._laneFollow();
        }
        function onLaneAlongChanged() {
            win._laneFollow();
        }
    }

    // =====================================================================
    //  KINDS: route and time per kind, applied the way osd.jsonc would be
    // =====================================================================
    QtObject {
        id: kindKnobs
        property int routeVolume: 0
        property int msVolume: 0
        property int routeMic: 0
        property int msMic: 0
        property int routeBrightness: 0
        property int msBrightness: 0
        property int routeKbd: 0
        property int msKbd: 0
        property int routeLockkeys: 0
        property int msLockkeys: 0
        property int routeLayout: 0
        property int msLayout: 0
        property int routeTheme: 0
        property int msTheme: 0
        property int routeTrack: 0
        property int msTrack: 0
        property int routeBluetooth: 0
        property int msBluetooth: 0
        property int routeNetwork: 0
        property int msNetwork: 0
        property int routeVpn: 0
        property int msVpn: 0
        property int routeAutoTunnel: 0
        property int msAutoTunnel: 0
        property int routeBtLow: 0
        property int msBtLow: 0
        property int routeCapture: 0
        property int msCapture: 0
        property int routeBattery: 0
        property int msBattery: 0
        property int routePower: 0
        property int msPower: 0
        property int routeGeneric: 2
        property int msGeneric: 0
    }
    readonly property var kindIds: ["volume", "mic", "brightness", "kbd", "lockkeys", "layout", "theme",
                                    "track", "bluetooth", "network", "vpn", "autoTunnel", "btLow", "capture", "battery", "power", "generic"]
    readonly property var routeNames: ["osd", "notification", "off"]
    function _cap(k) {
        return k.charAt(0).toUpperCase() + k.slice(1);
    }
    function kindsObject() {
        const o = {};
        for (const k of win.kindIds)
            o[k] = { route: win.routeNames[kindKnobs["route" + win._cap(k)]] || "osd", ms: kindKnobs["ms" + win._cap(k)] };
        return o;
    }
    // The config the service reads, as the mockup's panel sets it (no osd.jsonc is read or written).
    function applyKinds() {
        if (svc.config && typeof svc.config.apply === "function")
            svc.config.apply({ kinds: win.kindsObject() });
    }
    Timer {
        id: kindsTimer
        interval: 60
        onTriggered: win.applyKinds()
    }
    Connections {
        target: kindKnobs
        function onRouteVolumeChanged() { kindsTimer.restart(); }
        function onMsVolumeChanged() { kindsTimer.restart(); }
        function onRouteMicChanged() { kindsTimer.restart(); }
        function onMsMicChanged() { kindsTimer.restart(); }
        function onRouteBrightnessChanged() { kindsTimer.restart(); }
        function onMsBrightnessChanged() { kindsTimer.restart(); }
        function onRouteKbdChanged() { kindsTimer.restart(); }
        function onMsKbdChanged() { kindsTimer.restart(); }
        function onRouteLockkeysChanged() { kindsTimer.restart(); }
        function onMsLockkeysChanged() { kindsTimer.restart(); }
        function onRouteLayoutChanged() { kindsTimer.restart(); }
        function onMsLayoutChanged() { kindsTimer.restart(); }
        function onRouteThemeChanged() { kindsTimer.restart(); }
        function onMsThemeChanged() { kindsTimer.restart(); }
        function onRouteTrackChanged() { kindsTimer.restart(); }
        function onMsTrackChanged() { kindsTimer.restart(); }
        function onRouteBluetoothChanged() { kindsTimer.restart(); }
        function onMsBluetoothChanged() { kindsTimer.restart(); }
        function onRouteNetworkChanged() { kindsTimer.restart(); }
        function onMsNetworkChanged() { kindsTimer.restart(); }
        function onRouteVpnChanged() { kindsTimer.restart(); }
        function onMsVpnChanged() { kindsTimer.restart(); }
        function onRouteAutoTunnelChanged() { kindsTimer.restart(); }
        function onMsAutoTunnelChanged() { kindsTimer.restart(); }
        function onRouteBtLowChanged() { kindsTimer.restart(); }
        function onMsBtLowChanged() { kindsTimer.restart(); }
        function onRouteCaptureChanged() { kindsTimer.restart(); }
        function onMsCaptureChanged() { kindsTimer.restart(); }
        function onRouteBatteryChanged() { kindsTimer.restart(); }
        function onMsBatteryChanged() { kindsTimer.restart(); }
        function onRoutePowerChanged() { kindsTimer.restart(); }
        function onMsPowerChanged() { kindsTimer.restart(); }
        function onRouteGenericChanged() { kindsTimer.restart(); }
        function onMsGenericChanged() { kindsTimer.restart(); }
    }

    // =====================================================================
    //  ACTIONS (the Run page, OSD_ACT)
    // =====================================================================
    // OSD_ACT="verb[:arg[:arg...]]@ms,..." -- the steps, by name:
    //   test:<kind>            a plausible request of that kind (service.test)
    //   power:<quiet|balanced|performance>   silicon's own request for a profile changed outside its popup,
    //   power:gpu:<0..3>  power:limit:<80|100>   a GPU step (0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU only), the charge
    //                          limit -- built by SiliconModel and sent through OsdBus, as silicon's service does
    //   vol|mic|bri|kbd:<verb> the keys: up down mute press-up release-up press-down release-down
    //                          (bri also up-fine down-fine)
    //   lock  media:<verb>     caps/num lock card; next prev toggle stop
    //   shot:<file>            a screenshot's confirmation with <file> as its thumbnail (the capture IPC, copied)
    //   volset:<0..1.5>        set the volume (a level the next key starts from; shows nothing)
//   ext:<0..1>  sink:<type>[:<name>]  caps:<on|off>   what the SYSTEM does: an app moves the volume,
//                          the output switches (speaker headphone headset hdmi bluetooth), caps lock
    //   bt:<name>              a bluetooth device connecting (key = the device, so another device dips)
    //   net:<ssid>  vpn:<name>
    //   log:<label>            print the slot's phase, blocked flag, stats and box (OSD-STATE ...)
//   dismiss                the owner's dismiss (IPC `dismiss`)
    //   popup:<bar>:<along>[:w:h]  popupx    the stand-in thePopup out / in (bar top right bottom)
    //   lane:<bar>:<along>[:w:h]   lanex     the stand-in toast lane
    //   spot:<bar>[:<along>]   the OSD's spot (right bottom top); bottom turns the bottom bar on
    //   bottom:<on|off>        the bottom slim bar
    //   fs:<on|off>            a fullscreen window (the pill takes over)
    //   rec:<arm|back|play|release>   the recorder's transport
    //   mode:<light|dark>
    Component {
        id: actTimer
        Timer {
            property string step
            running: true
            onTriggered: {
                win.act(step);
                destroy();
            }
        }
    }
    function play(script) {
        const acts = String(script || "").split(",").filter(x => x.indexOf("@") > 0);
        for (const a of acts) {
            const at = a.lastIndexOf("@");
            actTimer.createObject(win, { step: a.substring(0, at), interval: Math.max(1, Number(a.substring(at + 1))) });
        }
    }
    // What silicon's service asks of the OSD for a change made outside its popup.
    function siliconRequest(what, arg) {
        if (what === "gpu")
            return SiliconModel.osdGpu(Number(arg));
        if (what === "limit")
            return SiliconModel.osdLimit(Number(arg));
        return SiliconModel.osdProfile(what);
    }
    function act(step) {
        const parts = step.split(":");
        const verb = parts[0];
        const arg = parts.length > 1 ? parts[1] : "";
        switch (verb) {
        case "test":
            svc.test(arg);
            break;
        case "power":
            OsdBus.show(win.siliconRequest(arg, parts.length > 2 ? parts[2] : ""));
            break;
        case "vol":
            svc.volume(arg);
            break;
        case "mic":
            svc.mic(arg);
            break;
        case "bri":
            svc.brightness(arg);
            break;
        case "kbd":
            svc.kbd(arg);
            break;
        case "lock":
            svc.lockkeys();
            break;
        case "shot":
            // a path may hold a colon: everything after the verb is the file
            svc.capture("shot", step.substring(verb.length + 1), "copied");
            break;
        case "media":
            svc.media(arg);
            break;
        case "volset":
            svc.userValue("volume", Number(arg));
            break;
        case "ext":
            // an app changed the default sink's volume (shown once the 1.5 s warm-up has passed)
            svc.sources.audio.simulateOut(Number(arg), false);
            break;
        case "sink":
            // the default output switched to another device: the same kind and key, so in place
            svc.sources.audio.simulateSink(arg, parts.length > 2 ? parts[2] : arg, 0.5, false);
            break;
        case "caps":
            svc.sources.lockKeys.simulateKeys(arg === "on", false);
            break;
        case "bt":
            svc.show({ kind: "bluetooth", key: arg, source: "mock", bt: { name: arg, icon: "headphones", battery: 80, state: "connected" } });
            break;
        case "net":
            svc.show({ kind: "network", key: arg, source: "mock", net: { ssid: arg, signal: 72, state: "connected" } });
            break;
        case "vpn":
            svc.show({ kind: "vpn", key: arg, source: "mock", vpn: { name: arg, state: "up" } });
            break;
        case "log":
            console.log("OSD-STATE " + arg + " phase=" + engine.osdPhase + " blocked=" + engine.osdBlocked + " stats=" + JSON.stringify(engine.osdStats)
                        + " shown=" + (owner.shown ? owner.keyOf(owner.shown) : "-") + " box=" + JSON.stringify(engine.theOsd.box));
            break;
        case "dismiss":
            owner.dismiss();
            break;
        case "caption":
            // the dictation's live words (DictationService's payload), renewed by repeating the step
            svc.show({ kind: "caption", key: "dictation", source: "dictation", ms: 6000,
                       caption: { mode: "source", head: "Transcribing Zen", lines: ["The town was built on the old trade road, where the river bends twice.",
                                  "Its market drew people from three valleys away."], live: arg || "and the bridge was for a long time", hint: "" } });
            break;
        case "hide":
            owner.hideShown();
            break;
        case "reveal":
            owner.unhide();
            break;
        case "popup":
            win.openPopup(arg, Number(parts[2]), parts.length > 3 ? Number(parts[3]) : undefined, parts.length > 4 ? Number(parts[4]) : undefined);
            break;
        case "popupx":
            win.closePopup();
            break;
        case "lane":
            win.openLane(arg, Number(parts[2]), parts.length > 3 ? Number(parts[3]) : undefined, parts.length > 4 ? Number(parts[4]) : undefined);
            break;
        case "lanex":
            win.closeLane();
            break;
        case "spot":
            if (arg === "bottom")
                host.bottomOn = true;
            host.spotBar = Math.max(0, win.barNames.indexOf(arg));
            if (parts.length > 2)
                host.spotAlong = Number(parts[2]);
            break;
        case "bottom":
            host.bottomOn = arg === "on";
            break;
        case "fs":
            win.fsOn = arg === "on";
            break;
        case "rec":
            if (arg === "arm")
                rec.arm();
            else if (arg === "back")
                rec.play(-1);
            else if (arg === "play")
                rec.play(1);
            else
                rec.release();
            break;
        case "mode":
            Theme.setMode(arg);
            break;
        default:
            console.warn("OSD_ACT: unknown step " + step);
        }
    }
    // The sources of a service that is not live hold nothing until they are told: the first
    // reading of each (a speaker at 42 %, a screen at 55 %, the keyboard light at 2 of 3).
    // Without it a key step finds no device and does nothing.
    function seedSources() {
        const src = svc.sources;
        src.audio.simulateReady(0.42, false, "Speakers", "speaker", 0.8, false);
        src.backlight.simulateSet(220, 400);
        src.kbd.simulateSet(1, 3);
        src.lockKeys.simulateKeys(false, false);
    }
    Component.onCompleted: {
        win.seedSources();
        win.applyKinds();
        win.play(Quickshell.env("OSD_ACT") || "");
        if (win.stageGrab !== "")
            for (let i = 0; i < win.filmAt.length; i++)
                filmTimer.createObject(win, { n: i, interval: Math.max(1, win.filmAt[i]) });
    }
    // STAGE_GRAB=<png> GRAB_MS=<ms>: one grab of the stage, then quit.
    // STAGE_FILM="ms,ms,..." with STAGE_GRAB=<base>: one grab at each time of ONE run,
    // saved as <base>_<n>.png (the film runner assembles them).
    readonly property string stageGrab: Quickshell.env("STAGE_GRAB") || ""
    readonly property var filmAt: (Quickshell.env("STAGE_FILM") || "").split(",").filter(x => x !== "").map(Number)
    property int _filmDone: 0
    // (The callback lives in the window's scope: a Timer that destroys itself takes its closures along.)
    function _filmGrab(n) {
        scene.grabToImage(r => {
            r.saveToFile(win.stageGrab + "_" + n + ".png");
            win._filmDone++;
            if (win._filmDone >= win.filmAt.length)
                Qt.quit();
        });
    }
    Component {
        id: filmTimer
        Timer {
            property int n
            running: true
            onTriggered: {
                win._filmGrab(n);
                destroy();
            }
        }
    }
    Timer {
        running: win.stageGrab !== "" && win.filmAt.length === 0
        interval: Number(Quickshell.env("GRAB_MS") || 2500)
        onTriggered: scene.grabToImage(r => {
            r.saveToFile(win.stageGrab);
            Qt.quit();
        })
    }

    // ---- the recorder: the OSD's box and presence, frame by frame -------------------------------------
    // Mirrors theOsd into numbers while it runs (assignments from JS, never bindings:
    // playback writes the same properties), and plays them back through the engine's
    // osdPoseBox. The live slot is frozen while a take is played (beforeScrub).
    QtObject {
        id: pose
        property real x0: 0
        property real y0: 0
        property real x1: 0
        property real y1: 0
        property real op: 0
    }
    property bool mirroring: true
    PoseRecorder {
        id: rec
        target: pose
        props: ["x0", "y0", "x1", "y1", "op"]
        tailMs: 400
        onBeforeScrub: win.mirroring = false
        onScrubbingChanged: {
            if (!rec.scrubbing)
                win.mirroring = true;
        }
    }
    function _mirror() {
        const o = engine.theOsd;
        if (!win.mirroring || !o)
            return;
        const b = o.box;
        pose.x0 = b ? b.x0 : 0;
        pose.y0 = b ? b.y0 : 0;
        pose.x1 = b ? b.x1 : 0;
        pose.y1 = b ? b.y1 : 0;
        pose.op = o.contentOpacity;
    }
    FrameAnimation {
        running: engine.osdOpen && win.mirroring
        onTriggered: win._mirror()
    }
    Binding {
        target: engine
        property: "osdPoseBox"
        value: rec.scrubbing ? ({ x0: pose.x0, y0: pose.y0, x1: pose.x1, y1: pose.y1 }) : null
    }

    // =====================================================================
    //  RUN PAGE
    // =====================================================================
    readonly property var scenarios: [
        { name: "volume key held", short: "press, 25 Hz repeat for 2 s, release", script: "volset:0.7@0,vol:press-up@600,vol:release-up@2600",
          tip: "The key held from 70 %: the service's repeat steps the level at the keyboard's own rate and the OSD updates in place (the same kind and key never dips). The held key stops at 100 %, it never shoots into boost." },
        { name: "fresh press into boost", short: "at 100 %, each press crosses", script: "volset:1@0,vol:press-up@600,vol:release-up@660,vol:press-up@1100,vol:release-up@1160",
          tip: "A FRESH press that starts at 100 % is the user asking for boost: the level crosses 1.0 towards 150 % and the slider shows its boost zone. The same gesture held from below 100 % would have stopped there." },
        { name: "brightness steps", short: "up x3, fine down x2", script: "bri:up@0,bri:up@260,bri:up@520,bri:down-fine@900,bri:down-fine@1160",
          tip: "Perceptual steps (gamma 2, 5 %); the fine steps (Shift) are 1 %. Updates in place, no dip." },
        { name: "dip: volume to brightness", short: "a different kind dips", script: "vol:up@0,bri:up@900",
          tip: "A different kind folds into the bar, swaps at the bottom (osdSwap) and rises with the new content. The content never shows brightness before the swap." },
        { name: "dip inside the fold", short: "volume, brightness, volume at +100 ms", script: "vol:up@0,bri:up@600,vol:up@700",
          tip: "A second request lands while the box is still folding: returning to the shown kind cancels the swap, so the box rises again with the volume it had." },
        { name: "dip during the rise", short: "volume, brightness, mic mute at +190 ms", script: "vol:up@0,bri:up@600,mic:mute@790",
          tip: "A new kind during the rise dips again from where the box is, without an origin jump." },
        { name: "app changes the volume", short: "an external change shows, in place", script: "ext:0.8@1800,ext:0.55@2700",
          tip: "Another program sets the default sink's volume (after the 1.5 s warm-up the service ignores): the OSD shows it, and a second change inside its time updates in place." },
        { name: "output device switch", short: "speakers to headphones: same kind and key", script: "vol:up@0,sink:headphone:Headphones@900",
          tip: "The default output switches to another device: volume's key is always 'out', so the OSD updates in place -- the glyph and name change, nothing dips." },
        { name: "bluetooth burst", short: "three devices, then the device switch", script: "bt:Sony WH-1000XM5@0,bt:Keychron K3@250,bt:Pixel Buds@500,vol:up@1400",
          tip: "Three connect events in 500 ms: the first shows, the other two queue (FIFO, deduped by kind + key) and each takes over once the one before has been out for the minimum show. Then a volume key pre-empts at once." },
        { name: "every kind", short: "all seventeen, one after another", script: "test:volume@0,test:mic@2300,test:brightness@4600,test:kbd@6900,test:lockkeys@9200,test:layout@11500,test:theme@13800,test:track@16100,test:bluetooth@19700,test:network@23000,test:vpn@26300,test:capture@29600,test:battery@33200,test:power@36800,test:generic@40000",
          tip: "service.test(kind) for each kind, spaced past its time. Generic is routed off by default: it only shows when the Kinds tab turns it on." },
        { name: "silicon: changes outside", short: "profile, GPU mode, limit, then a repeat", script: "power:quiet@0,power:gpu:3@2300,power:limit:80@4600,power:performance@6900,power:performance@7300",
          tip: "What silicon asks of the OSD when the profile, the GPU mode or the charge limit is changed outside its popup (a key, asusctl, a terminal): kind power, the request SiliconModel builds, sent through OsdBus like the service sends it. Each is a different key, so each dips into the next once the one before has had its minimum time; the last two are the same key, so they update in place." },
        { name: "OSD beside thePopup", short: "home under the popup: it moves", script: "popup:right:0.5:260:300@0,vol:up@900",
          tip: "thePopup stands on the right bar where the OSD's home is. What matters is overlap: the OSD glides to the free spot nearest home, flush with the popup, and melts with it." },
        { name: "between popup and lane", short: "popup above, lane below, a gap between", script: "popup:right:0.22:240:200@0,lane:right:0.86:240:120@120,vol:up@1000",
          tip: "A popup near the top and the lane near the foot leave a gap; the OSD takes it if it fits, else it moves the lane, then pushes the popup." },
        { name: "no room: lane displaced", short: "the lane gives way", script: "popup:right:0.5:260:300@0,lane:right:0.12:240:140@120,vol:up@1000",
          tip: "The OSD's home and both sides of thePopup are taken: the toast lane is displaced (osdDisplaceLane) to make room." },
        { name: "no room: popup pushed", short: "the popup gives way", script: "popup:right:0.5:260:420@0,lane:right:0.5:240:140@120,vol:up@1000",
          tip: "A tall popup and the lane fill the bar: the lane gives way first, then thePopup is pushed along its bar (osdPushPopup); with both off the OSD waits (osdBlocked) and its timer runs out." },
        { name: "hop to the bottom bar", short: "the spot moves to another bar", script: "bottom:on@0,vol:up@300,spot:bottom@1200",
          tip: "The spot changes to the bottom slim bar while the OSD is out: it folds on the right bar and opens fresh on the bottom one, now horizontal." },
        { name: "fullscreen: the pill", short: "a window goes fullscreen, then back", script: "vol:up@0,fs:on@600,vol:down@1800,fs:off@3200",
          tip: "A fullscreen window: what is out moves to the top-centre pill (a dot, a capsule, full width), requests keep going to the pill, and when the window leaves the OSD returns to its bar with what time it had left." },
        { name: "suppress in fullscreen", short: "mode suppress: nothing shows", script: "fs:on@0,vol:up@400,fs:off@1500",
          tip: "With the Host tab's fullscreen mode on 'suppress' requests are dropped while a window is fullscreen. Set it first; this button does not." }
    ]

    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "Each is a short script on the live module (hover a row for what to watch)."
            }
            Repeater {
                model: win.scenarios.length
                TipRow {
                    id: scenRow
                    required property int index
                    readonly property var sc: win.scenarios[scenRow.index]
                    tip: scenRow.sc.tip
                    Layout.fillWidth: true
                    spacing: 6
                    Button {
                        Layout.preferredWidth: 190
                        text: scenRow.sc.name
                        onClicked: win.play(scenRow.sc.script)
                    }
                    Label {
                        Layout.fillWidth: true
                        text: scenRow.sc.short
                        elide: Text.ElideRight
                        color: "#6F6F72"
                        font.pixelSize: 12
                    }
                }
            }
            TipGroup {
                title: "One of each kind"
                blurb: "service.test(kind): a plausible request."
            }
            TipRow {
                tip: "One button per OSD kind: service.test(kind) sends that kind's sample request (OsdKinds.sampleRequest), as its source would."
                Flow {
                    Layout.fillWidth: true
                    spacing: 6
                    Repeater {
                        model: win.kindIds
                        Button {
                            required property string modelData
                            text: modelData
                            onClicked: svc.test(modelData)
                        }
                    }
                }
            }
            TipGroup {
                title: "silicon (kind power)"
                blurb: "The requests silicon's service sends through OsdBus for a change made outside its popup."
            }
            TipRow {
                tip: "A CPU profile changed outside the popup: the glyph is the bar button's (leaf, scales, bolt), in the profile's colour."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "profile" }
                Button { text: "quiet"; onClicked: win.act("power:quiet") }
                Button { text: "balanced"; onClicked: win.act("power:balanced") }
                Button { text: "performance"; onClicked: win.act("power:performance") }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "The GPU mode changed outside the popup (cardwire's own battery switch, a terminal): one glyph and one colour per mode."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "GPU" }
                Button { text: "Integrated"; onClicked: win.act("power:gpu:0") }
                Button { text: "Smart"; onClicked: win.act("power:gpu:1") }
                Button { text: "Hybrid"; onClicked: win.act("power:gpu:2") }
                Button { text: "dGPU only"; onClicked: win.act("power:gpu:3") }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "The charge limit changed outside the popup (asusctl, the old battery module)."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "limit" }
                Button { text: "80 %"; onClicked: win.act("power:limit:80") }
                Button { text: "off"; onClicked: win.act("power:limit:100") }
                Item { Layout.fillWidth: true }
            }
            TipGroup {
                title: "Keys"
                blurb: "What the hardware keys and IPC call. Press and release are the key's own edges: the repeat belongs to the service."
            }
            TipRow {
                tip: "Volume up / down / mute through the service, one step (or a toggle) each."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "volume" }
                Button { text: "up"; onClicked: svc.volume("up") }
                Button { text: "down"; onClicked: svc.volume("down") }
                Button { text: "mute"; onClicked: svc.volume("mute") }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "The microphone: a different kind from the speaker, so it dips."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "mic" }
                Button { text: "up"; onClicked: svc.mic("up") }
                Button { text: "down"; onClicked: svc.mic("down") }
                Button { text: "mute"; onClicked: svc.mic("mute") }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "Screen brightness in perceptual steps; fine is the Shift step."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "brightness" }
                Button { text: "up"; onClicked: svc.brightness("up") }
                Button { text: "down"; onClicked: svc.brightness("down") }
                Button { text: "fine +"; onClicked: svc.brightness("up-fine") }
                Button { text: "fine -"; onClicked: svc.brightness("down-fine") }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "The keyboard light's four stops, caps and num lock, and the media keys (MPD)."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "kbd" }
                Button { text: "up"; onClicked: svc.kbd("up") }
                Button { text: "down"; onClicked: svc.kbd("down") }
                Button { text: "lock keys"; onClicked: svc.lockkeys() }
                Button { text: "next"; onClicked: svc.media("next") }
                Item { Layout.fillWidth: true }
            }
            TipGroup {
                title: "Stand-ins"
                blurb: "What the OSD meets on its bar. The Host tab sizes and places them."
            }
            TipRow {
                tip: "thePopup stand-in on the right bar at its middle (the OSD's home), and away."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "popup" }
                Button { text: "at home"; onClicked: win.openPopup("right", 0.5) }
                Button { text: "top"; onClicked: win.openPopup("right", 0.2) }
                Button { text: "foot"; onClicked: win.openPopup("right", 0.8) }
                Button { text: "away"; onClicked: win.closePopup() }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "The toast lane stand-in at the Host tab's spot, and away."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "lane" }
                Button { text: "out"; onClicked: win.openLane(win.barChoices[host.laneBar], host.laneAlong) }
                Button { text: "away"; onClicked: win.closeLane() }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "A fullscreen window: the owner hands what is out over to the pill (or drops requests, in suppress mode), and takes it back."
                Layout.fillWidth: true
                spacing: 6
                Label { text: "fullscreen" }
                Switch {
                    checked: win.fsOn
                    onToggled: win.fsOn = checked
                }
                Button { text: "dismiss"; onClicked: owner.dismiss() }
                Item { Layout.fillWidth: true }
            }
            TipGroup {
                title: "Walk through a dip"
                blurb: "The recorder keeps the OSD's box and presence per frame; playing it back writes the frames into the engine (osdPoseBox)."
            }
            TipRow {
                tip: "arm clears and records from now (press it, then run a scenario); rewind plays the take backwards; play forwards; release gives the box back to the live slot."
                Layout.fillWidth: true
                spacing: 6
                Button { text: "arm"; onClicked: rec.arm() }
                Button { text: "rewind"; onClicked: rec.play(-1) }
                Button { text: "play"; onClicked: rec.play(1) }
                Button { text: "step -"; onClicked: rec.step(-1) }
                Button { text: "step +"; onClicked: rec.step(1) }
                Button { text: "release"; onClicked: rec.release() }
                Item { Layout.fillWidth: true }
            }
            TipRow {
                tip: "The head, in ms from the first recorded frame."
                Layout.fillWidth: true
                spacing: 6
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: Math.max(1, rec.spanMs)
                    value: rec.position
                    onMoved: rec.seek(value)
                }
                Label {
                    text: rec.frameCount + " frames  " + rec.position.toFixed(0) + " / " + rec.spanMs.toFixed(0) + " ms"
                    font.pixelSize: 11
                }
            }
            TipGroup {
                title: "State"
                blurb: "What the owner and the slot say now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                font.pixelSize: 11
                text: "shown " + (owner.shown ? owner.keyOf(owner.shown) : "-") + "   pending " + (owner.pending ? owner.keyOf(owner.pending) : "-")
                    + "   phase " + engine.osdPhase + (engine.osdBlocked ? "   BLOCKED" : "") + "   surface " + (owner.inPill ? "pill" : "bar")
                    + "\nqueue " + owner._queue.length + "   orientation " + owner.orientation
                    + "   stats " + JSON.stringify(engine.osdStats)
            }
        }
    ]

    readonly property var slotParams: [
        {
            label: "open ms",
            prop: "osdOpenMs",
            group: "Open and close",
            blurb: "The slot's own clock (theOsd), independent of thePopup's.",
            tip: "How long the OSD takes to come out of its bar, in ms. 320: a little under the popup's 400, because the OSD shows for two seconds and must not feel like an event of its own.",
            val: 320,
            from: 60,
            to: 1500,
            step: 10
        },
        {
            label: "open easing",
            prop: "osdOpenEasingIndex",
            group: "Open and close",
            tip: "The curve of the opening. OutBack (3) overshoots and settles, the metaball bounce the popups have.",
            val: 3,
            choices: ["Linear", "OutCubic", "OutQuint", "OutBack", "InOutCubic", "OutExpo", "InQuad", "InCubic", "InBack"]
        },
        {
            label: "overshoot",
            prop: "osdOvershoot",
            group: "Open and close",
            tip: "How far OutBack overshoots (Qt's unit; its own default is 1.70158). 1.15 is a hint of it: the OSD is small, a big bounce on 64 px reads as a wobble.",
            val: 1.15,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "close ms",
            prop: "osdCloseMs",
            group: "Open and close",
            tip: "How long it takes to go back into the bar. 220: leaving is quicker than arriving.",
            val: 220,
            from: 60,
            to: 1500,
            step: 10
        },
        {
            label: "close easing",
            prop: "osdCloseEasingIndex",
            group: "Open and close",
            tip: "The curve of the closing. OutCubic (1): decelerates into the bar face, no bounce on the way out.",
            val: 1,
            choices: ["Linear", "OutCubic", "OutQuint", "OutBack", "InOutCubic", "OutExpo", "InQuad", "InCubic", "InBack"]
        },
        {
            label: "fold ms",
            prop: "osdDipFoldMs",
            group: "Dip",
            blurb: "A different kind (or the same kind with another key) dips into the bar and comes back with the new content.",
            tip: "How long the OSD takes to fold into the bar when another kind arrives (the first half of a dip). 110: the content has to leave before the new one can be asked for, so this is the dip's dead time.",
            val: 110,
            from: 30,
            to: 600,
            step: 5
        },
        {
            label: "fold easing",
            prop: "osdDipFoldEasingIndex",
            group: "Dip",
            tip: "The curve of the fold. InQuad (6) starts gently and ends fast, so the swap lands on the bar face at full speed rather than creeping to it.",
            val: 6,
            choices: ["Linear", "OutCubic", "OutQuint", "OutBack", "InOutCubic", "OutExpo", "InQuad", "InCubic", "InBack"]
        },
        {
            label: "rise ms",
            prop: "osdDipRiseMs",
            group: "Dip",
            tip: "How long the new content takes to rise from the folded box (the second half). 240.",
            val: 240,
            from: 60,
            to: 1000,
            step: 10
        },
        {
            label: "rise easing",
            prop: "osdDipRiseEasingIndex",
            group: "Dip",
            tip: "The curve of the rise. OutBack (3): the same bounce as an opening.",
            val: 3,
            choices: ["Linear", "OutCubic", "OutQuint", "OutBack", "InOutCubic", "OutExpo", "InQuad", "InCubic", "InBack"]
        },
        {
            label: "width at the bottom",
            prop: "osdDipWidthTo",
            group: "Dip",
            tip: "How wide the box is, as a fraction of the old one, at the bottom of the fold. 1 keeps the width (only the depth folds); below 1 it narrows while it folds, like a tongue pulled in.",
            val: 1,
            from: 0.2,
            to: 1.5,
            step: 0.05
        },
        {
            label: "glide ms",
            prop: "osdGlideMs",
            group: "Glide",
            blurb: "Collision: what moves, and in which order -- the OSD glides first, then the lane is displaced, then thePopup is pushed, then the OSD waits.",
            tip: "How long the OSD takes to slide along its bar when a neighbour (thePopup, the toast lane) takes its place or lets it go. 300.",
            val: 300,
            from: 60,
            to: 1500,
            step: 10
        },
        {
            label: "glide easing",
            prop: "osdGlideEasingIndex",
            group: "Glide",
            tip: "The curve of the glide. OutCubic (1).",
            val: 1,
            choices: ["Linear", "OutCubic", "OutQuint", "OutBack", "InOutCubic", "OutExpo", "InQuad", "InCubic", "InBack"]
        },
        {
            label: "width from",
            prop: "osdWidthFrom",
            group: "Glide",
            tip: "How wide the box is, as a fraction of its final width, when it starts to open (a vertical OSD: how deep). 0.6: it grows out of a part of its length, not a point.",
            val: 0.6,
            from: 0.05,
            to: 1,
            step: 0.05
        },
        {
            label: "melt",
            prop: "osdMelt",
            group: "Collision",
            blurb: "What the OSD does to a neighbour on its edge: melt with it, move the toast lane, push thePopup.",
            tip: "Melt with a neighbour on the same edge (thePopup, the lane): the two surfaces join through a neck, like a toast beside a popup. Off: they sit flush, as separate bodies.",
            val: true
        },
        {
            label: "displace the lane",
            prop: "osdDisplaceLane",
            group: "Collision",
            tip: "When the OSD has no room at home, move the toast lane out of its way (the second step of the order). Off: the OSD goes straight to pushing thePopup, or waiting.",
            val: true
        },
        {
            label: "push thePopup",
            prop: "osdPushPopup",
            group: "Collision",
            tip: "When the lane cannot make room either, push thePopup along its bar (the third step). Off: the OSD waits (osdBlocked) and its timer simply runs out.",
            val: true
        },
        {
            label: "tuck px",
            prop: "osdTuckPx",
            group: "Dip",
            tip: "A card the user hid (the caption's hide button) sinks into its bar until this much of it stands out: the sliver the pointer finds it by. 3: seen, and nothing else in the way.",
            val: 3,
            from: 1,
            to: 12,
            step: 0.5
        },
        {
            label: "tuck edge bar",
            prop: "osdTuckEdgeMax",
            group: "Dip",
            tip: "On a bar no thicker than this the bar beside the sliver counts as the sliver for the hover, out to the screen's edge (a pointer thrown to the edge finds it). Thicker bars keep their modules: only the sliver. 12: the 6 px outlets, not the 40 px top bar.",
            val: 12,
            from: 0,
            to: 48,
            step: 1
        }
    ]

    readonly property var ownerParams: [
        {
            label: "resume minimum ms",
            prop: "resumeMinMs",
            group: "Timing",
            blurb: "OsdOwner: when it goes, and what waits.",
            tip: "When the pointer leaves the OSD, the clock resumes with max(what was left, this). 800: time to reach for the control again before it goes.",
            val: 800,
            from: 0,
            to: 3000,
            step: 50
        },
        {
            label: "minimum show ms",
            prop: "minShowMs",
            group: "Timing",
            tip: "An event kind (a track, a device) is shown at least this long before the next waiting event takes over. 600: long enough to read a glyph and a word.",
            val: 600,
            from: 0,
            to: 3000,
            step: 50
        },
        {
            label: "queue cap",
            prop: "queueCap",
            group: "Timing",
            tip: "How many waiting events are kept (FIFO, deduped by kind and key); past it the OLDEST is dropped. 3.",
            val: 3,
            from: 1,
            to: 8,
            step: 1
        }
    ]

    readonly property var styleContent: [
        {
            label: "value ease ms",
            prop: "valueEaseMs",
            group: "Time",
            blurb: "What the content does over time.",
            tip: "A level's displayed value eases on ONE clock when something else moved it (an app, a key). 120, OutCubic; while dragging it is direct.",
            val: 120,
            from: 0,
            to: 600,
            step: 10
        },
        {
            label: "drag hold ms",
            prop: "directHoldMs",
            group: "Time",
            tip: "How long after the last pointer change the display still counts as dragged, so the service's echo of the new value does not restart an ease. 300.",
            val: 300,
            from: 0,
            to: 1000,
            step: 25
        },
        {
            label: "wheel step",
            prop: "wheelStep",
            group: "Time",
            tip: "How much of a level's range one wheel notch (120 units) moves it. 0.04.",
            val: 0.04,
            from: 0.005,
            to: 0.2,
            step: 0.005
        },
        {
            label: "padding",
            prop: "pad",
            group: "Geometry",
            blurb: "Spacing common to every kind.",
            tip: "Padding on every side of the content. 12, the popups' padding.",
            val: 12,
            from: 4,
            to: 24,
            step: 1
        },
        {
            label: "gap",
            prop: "gap",
            group: "Geometry",
            tip: "Between a glyph and what stands next to it. 10.",
            val: 10,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "card gap",
            prop: "cardGap",
            group: "Geometry",
            tip: "Between the two halves of a card (picture / text). 12.",
            val: 12,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "card max width",
            prop: "cardMaxW",
            group: "Geometry",
            tip: "A vertical card never breaks a word: it grows to fit its longest word, up to this width; a word longer than that is not wrapped, its line elides. 140, a little over the widest of the sheet's own extents (124-128).",
            val: 140,
            from: 90,
            to: 240,
            step: 2
        },
        {
            label: "level ink padding",
            prop: "inkPadV",
            group: "Geometry",
            tip: "A vertical level: how far the INK of the glyph (top) and of the figure (foot) stands from the box's edges. 18: the padding of 12 plus the room each carries in its own box, so the two ends are equal to the pixel.",
            val: 18,
            from: 8,
            to: 32,
            step: 1
        },
        {
            label: "text font",
            prop: "textFont",
            group: "Type",
            blurb: "Sizes of the text and glyphs.",
            tip: "Words (titles, details, device names). The module default is Inter; the user dresses mockups in Audiowide.",
            val: "Inter",
            kind: "text"
        },
        {
            label: "figure font",
            prop: "figureFont",
            group: "Type",
            tip: "Figures (the percentage, a code). Audiowide has no tabular figures, so figures sit in fixed slots.",
            val: "Audiowide",
            kind: "text"
        },
        {
            label: "glyph font",
            prop: "glyphFont",
            group: "Type",
            tip: "The icon font for the glyphs. Symbols Nerd Font.",
            val: "Symbols Nerd Font",
            kind: "text"
        },
        {
            label: "glyph px",
            prop: "glyphPx",
            group: "Type",
            tip: "Size of a level's glyph. 22.",
            val: 22,
            from: 10,
            to: 40,
            step: 1
        },
        {
            label: "card glyph px",
            prop: "cardGlyphPx",
            group: "Type",
            tip: "Size of a card's glyph (theme, device, battery). 26.",
            val: 26,
            from: 10,
            to: 48,
            step: 1
        },
        {
            label: "title px",
            prop: "titlePx",
            group: "Type",
            tip: "A card's title. 14.",
            val: 14,
            from: 8,
            to: 24,
            step: 1
        },
        {
            label: "detail px",
            prop: "detailPx",
            group: "Type",
            tip: "A card's detail line. 11.",
            val: 11,
            from: 8,
            to: 20,
            step: 1
        },
        {
            label: "name px",
            prop: "namePx",
            group: "Type",
            tip: "A device's name under a level's figure. 10.",
            val: 10,
            from: 7,
            to: 16,
            step: 1
        },
        {
            label: "figure px",
            prop: "figurePx",
            group: "Type",
            tip: "A level's figure on a horizontal OSD. 16.",
            val: 16,
            from: 8,
            to: 28,
            step: 1
        },
        {
            label: "figure px (vertical)",
            prop: "figurePxV",
            group: "Type",
            tip: "A level's figure on a vertical OSD, where the room is the bar's thickness. 13.",
            val: 13,
            from: 8,
            to: 24,
            step: 1
        },
        {
            label: "code px",
            prop: "codePx",
            group: "Type",
            tip: "The layout code (US, BE). 24.",
            val: 24,
            from: 10,
            to: 40,
            step: 1
        },
        {
            label: "key px",
            prop: "keyPx",
            group: "Type",
            tip: "The lock keys' legends (Caps, Num). 12, bold: a key's own word.",
            val: 12,
            from: 7,
            to: 18,
            step: 1
        },
        {
            label: "slider scale",
            prop: "sliderScale",
            group: "Levels",
            blurb: "Volume, mic, brightness and the keyboard light.",
            tip: "GrooveSlider's own sizeScale: its ball, bars and room all follow it. 0.8.",
            val: 0.8,
            from: 0.5,
            to: 1.5,
            step: 0.05
        },
        {
            label: "glyph slot",
            prop: "glyphSlot",
            group: "Levels",
            tip: "The slot a level's glyph sits in, so the slider starts on one line whatever the glyph. 26.",
            val: 26,
            from: 12,
            to: 48,
            step: 1
        },
        {
            label: "name width",
            prop: "nameW",
            group: "Levels",
            tip: "The device name's slot under the figure on a horizontal level. 70.",
            val: 92,
            from: 30,
            to: 140,
            step: 2
        },
        {
            label: "stops line",
            prop: "stopsLine",
            group: "Levels",
            tip: "The keyboard light's rail thickness (PhaseRail's groove, the workspaces' own). 6.",
            val: 6,
            from: 2,
            to: 14,
            step: 1
        },
        {
            label: "stops dot",
            prop: "stopsDot",
            group: "Levels",
            tip: "The keyboard light's stop notches. 12: an even number keeps the rail centred on the whole pixel in the card.",
            val: 12,
            from: 4,
            to: 20,
            step: 1
        },
        {
            label: "stops ball",
            prop: "stopsBall",
            group: "Levels",
            tip: "The ball resting in the current stop. 14: a little wider than the notch it sits in, as the workspaces' ball is.",
            val: 14,
            from: 6,
            to: 24,
            step: 1
        },
        {
            label: "stops move ms",
            prop: "stopsMoveMs",
            group: "Levels",
            tip: "How long the ball takes to travel to the next stop (an OutQuart, the rail's own). 320: a key's answer, so shorter than the update popup's 460.",
            val: 320,
            from: 100,
            to: 1000,
            step: 10
        },
        {
            label: "spark speed",
            prop: "sparkSpeed",
            group: "Sparks",
            blurb: "The sparks a level's ball throws as it moves.",
            tip: "px/s a spark leaves the ball at (0.5-1.5x per spark; with drag 2.6 it travels about a third of that in px). 38: fast enough to read as flying off -- 14 (silicon's) left a dotted line behind the ball.",
            val: 38,
            from: 0,
            to: 120,
            step: 1
        },
        {
            label: "spark spread",
            prop: "sparkSpreadDeg",
            group: "Sparks",
            tip: "Half-angle, degrees, of the cone the sparks are thrown in, centred on straight back along the ball's way. 100: a wide fan, some go sideways; 0 would be the dotted line the user did not want; 180 anywhere.",
            val: 100,
            from: 0,
            to: 180,
            step: 5
        },
        {
            label: "spark life ms",
            prop: "sparkLifeMs",
            group: "Sparks",
            tip: "How long a spark lives (up to twice this). 900: the card is out for about two seconds; silicon's burst lives 2-3.2 s.",
            val: 900,
            from: 100,
            to: 2000,
            step: 10
        },
        {
            label: "spark trail",
            prop: "sparkTrail",
            group: "Sparks",
            tip: "Points of a spark's trail -- the 'stretch' the user did not want. 1: a round dot like silicon's; the rail's is 8.",
            val: 1,
            from: 1,
            to: 8,
            step: 1
        },
        {
            label: "spark size min",
            prop: "sparkSizeMin",
            group: "Sparks",
            tip: "The smallest spark, px; a spark keeps its size and only fades. 1.5: silicon's smallest dot (the old ones shrank to 0.5 -- 'too small').",
            val: 1.5,
            from: 0.6,
            to: 4,
            step: 0.1
        },
        {
            label: "spark size max",
            prop: "sparkSizeMax",
            group: "Sparks",
            tip: "The largest spark, px. 2.4: silicon's largest dot.",
            val: 2.4,
            from: 0.6,
            to: 5,
            step: 0.1
        },
        {
            label: "spark drag",
            prop: "sparkDrag",
            group: "Sparks",
            tip: "How fast a spark slows down. 2.6: they stop within a few px of the ball, as the slider's own do.",
            val: 2.6,
            from: 0.5,
            to: 6,
            step: 0.1
        },
        {
            label: "sparks per px",
            prop: "sparkPerPx",
            group: "Sparks",
            tip: "Sparks shed per px the head travels (a fraction carries over to the next change). 0.12: a 5 % step sheds one or two -- 'too plentiful' before (0.35).",
            val: 0.12,
            from: 0.02,
            to: 2,
            step: 0.01
        },
        {
            label: "sparks per change (max)",
            prop: "sparkMaxPerStep",
            group: "Sparks",
            tip: "The most sparks one change of the displayed value sheds (a change comes every frame of the 120 ms ease): a jump from 0 to 100 stays a puff, not a jet.",
            val: 2,
            from: 1,
            to: 10,
            step: 1
        },
        {
            label: "spark pool",
            prop: "sparkPool",
            group: "Sparks",
            tip: "The most sparks alive at once. 14: silicon's burst is 14; a held key cannot make a cloud.",
            val: 14,
            from: 2,
            to: 120,
            step: 1
        },
        {
            label: "key unit",
            prop: "keyU",
            group: "Lock keys",
            blurb: "Caps and num lock, drawn as the two keys they are. The card's size follows from these numbers.",
            tip: "One unit of the keyboard: a key's height and Num Lock's width. Caps Lock is 1.75 of them. 36: big enough for its legend and a chiclet's corner, and the card stays near the others' 56-60.",
            val: 36,
            from: 20,
            to: 64,
            step: 2
        },
        {
            label: "key unit (pill)",
            prop: "keyUPill",
            group: "Lock keys",
            tip: "The same unit on the fullscreen capsule, which is 44 tall: 32 leaves the capsule's corner its room and \"Num\" its key.",
            val: 32,
            from: 16,
            to: 40,
            step: 2
        },
        {
            label: "caps width (units)",
            prop: "keyCapsU",
            group: "Lock keys",
            tip: "Caps Lock's width in units. 1.75: a laptop keyboard's (the width is then made an even number of pixels so a key stands on the card's axis on the pixel grid).",
            val: 1.75,
            from: 1,
            to: 3,
            step: 0.25
        },
        {
            label: "num width (units)",
            prop: "keyNumU",
            group: "Lock keys",
            tip: "Num Lock's width in units. 1: a square key.",
            val: 1,
            from: 0.75,
            to: 2,
            step: 0.25
        },
        {
            label: "key gap",
            prop: "keyGap",
            group: "Lock keys",
            tip: "Between the two keys. 8: room for the drop shadows (5 px) not to meet.",
            val: 8,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "key radius",
            prop: "keyRadius",
            group: "Lock keys",
            tip: "The keys' corner. 6: a chiclet's, about a sixth of its height.",
            val: 6,
            from: 0,
            to: 18,
            step: 1
        },
        {
            label: "key press",
            prop: "keyPress",
            group: "Lock keys",
            tip: "How far a key that is ON sinks, as RaisedButton's pressed: the relief shrinks toward nothing and the legend drops a pixel. 0 leaves it standing proud, 1 flattens it. 0.6.",
            val: 0.6,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "layout gap",
            prop: "layoutGap",
            group: "Cards",
            blurb: "The cards that are not a level: the layout card's stack, and the glyph cards (theme, bluetooth, network, vpn, battery).",
            tip: "The stacked layout card: from the baseline of the big code to the top of the name under it. 8: the name reads as the code's caption, not as a second line of it.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "net glyph px",
            prop: "netGlyphPx",
            group: "Cards",
            tip: "The Wi-Fi / VPN glyph. 34.",
            val: 34,
            from: 16,
            to: 56,
            step: 1
        },
        {
            label: "battery width",
            prop: "batteryW",
            group: "Cards",
            tip: "The battery body. 40.",
            val: 40,
            from: 20,
            to: 80,
            step: 1
        },
        {
            label: "battery height",
            prop: "batteryH",
            group: "Cards",
            tip: "The battery body. 20.",
            val: 20,
            from: 10,
            to: 40,
            step: 1
        },
        {
            label: "cover (horizontal)",
            prop: "coverH",
            group: "Track",
            blurb: "MPD's track change.",
            tip: "The cover art's side on a horizontal OSD. 56.",
            val: 56,
            from: 24,
            to: 120,
            step: 1
        },
        {
            label: "cover (vertical)",
            prop: "coverV",
            group: "Track",
            tip: "The cover art's side on a vertical OSD. 80.",
            val: 80,
            from: 24,
            to: 160,
            step: 1
        },
        {
            label: "cover radius",
            prop: "coverRadius",
            group: "Track",
            tip: "The cover's corner. 10.",
            val: 10,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "thumb width",
            prop: "thumbW",
            group: "Capture",
            blurb: "Screenshot and recording confirmations. A screenshot's card is as big as its tile and its words.",
            tip: "The screenshot's tile on a horizontal OSD. 200: about twice the 112 it was -- the thumbnail was too small to see what was captured. The picture keeps its own proportions inside the tile.",
            val: 200,
            from: 80,
            to: 400,
            step: 2
        },
        {
            label: "thumb height",
            prop: "thumbH",
            group: "Capture",
            tip: "The tile's height on a horizontal OSD; its proportions (thumbW : thumbH) are the vertical tile's too. 125: 16 : 10, a laptop screen's.",
            val: 125,
            from: 50,
            to: 260,
            step: 1
        },
        {
            label: "thumb (vertical)",
            prop: "thumbV",
            group: "Capture",
            tip: "The tile's width on a vertical OSD (it comes out of the slim bar, so the card is this and the padding wide). 232.",
            val: 232,
            from: 80,
            to: 400,
            step: 2
        },
        {
            label: "thumb text least",
            prop: "thumbTextMinW",
            group: "Capture",
            tip: "The least width of the words beside a screenshot's tile on a horizontal OSD (the title is on one line; the file's name under it elides to the same width). 120.",
            val: 120,
            from: 60,
            to: 240,
            step: 2
        },
        {
            label: "thumb radius",
            prop: "thumbRadius",
            group: "Capture",
            tip: "The tile's corner. 8.",
            val: 8,
            from: 0,
            to: 24,
            step: 1
        },
        {
            label: "glyph tile width",
            prop: "glyphTileW",
            group: "Capture",
            tip: "The tile of a recording or a copy (no picture): horizontal width. 112, as the thumbnail tile was.",
            val: 112,
            from: 40,
            to: 200,
            step: 1
        },
        {
            label: "glyph tile height",
            prop: "glyphTileH",
            group: "Capture",
            tip: "The tile of a recording or a copy, horizontal height; its proportions are the vertical tile's too. 70.",
            val: 70,
            from: 30,
            to: 140,
            step: 1
        }
    ]

    readonly property var styleExtents: [
        {
            label: "horizontal width",
            prop: "levelHW",
            group: "Level (volume, mic, brightness)",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the level content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 360.",
            val: 360,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "levelHH",
            group: "Level (volume, mic, brightness)",
            tip: "The height of the level content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 64.",
            val: 64,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "levelVW",
            group: "Level (volume, mic, brightness)",
            tip: "The width of the level content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 64.",
            val: 64,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "levelVH",
            group: "Level (volume, mic, brightness)",
            tip: "The height of the level content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 300.",
            val: 300,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "levelPW",
            group: "Level (volume, mic, brightness)",
            tip: "The width of the level content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 280.",
            val: 280,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "levelPH",
            group: "Level (volume, mic, brightness)",
            tip: "The height of the level content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "stopsHW",
            group: "Keyboard light",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the stops content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 260.",
            val: 260,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "stopsHH",
            group: "Keyboard light",
            tip: "The height of the stops content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "stopsVW",
            group: "Keyboard light",
            tip: "The width of the stops content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "stopsVH",
            group: "Keyboard light",
            tip: "The height of the stops content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 220.",
            val: 220,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "stopsPW",
            group: "Keyboard light",
            tip: "The width of the stops content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 240.",
            val: 240,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "stopsPH",
            group: "Keyboard light",
            tip: "The height of the stops content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "lockPH",
            group: "Lock keys",
            blurb: "The lock keys' card is as big as its keys (the Levels tab); only the capsule's height is a size of its own.",
            tip: "The height of the lock content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "layoutHW",
            group: "Layout",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The widest the layout card grows on a horizontal bar: it is as wide as the code and the name on one line, and a longer name elides here. 170.",
            val: 170,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "layoutHH",
            group: "Layout",
            tip: "The height of the layout content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "layoutVW",
            group: "Layout",
            tip: "The layout card's height is its content's (the code and the wrapped name): there is no height to set. The narrowest the layout card stands on a vertical bar: it grows to its longest word (up to the card width cap, 140). 64.",
            val: 64,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "layoutPW",
            group: "Layout",
            tip: "The width of the layout content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 170.",
            val: 170,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "layoutPH",
            group: "Layout",
            tip: "The height of the layout content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "themeHW",
            group: "Theme",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the theme content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 190.",
            val: 190,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "themeHH",
            group: "Theme",
            tip: "The height of the theme content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "themeVW",
            group: "Theme",
            tip: "The width of the theme content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 64.",
            val: 64,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "themeVH",
            group: "Theme",
            tip: "The height of the theme content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 110.",
            val: 110,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "themePW",
            group: "Theme",
            tip: "The width of the theme content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 200.",
            val: 200,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "themePH",
            group: "Theme",
            tip: "The height of the theme content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "trackHW",
            group: "Track",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the track content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 308: the card has no state glyph, so this is the old 340 less the glyph (22) and its gap (10).",
            val: 308,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "trackHH",
            group: "Track",
            tip: "The height of the track content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 80.",
            val: 80,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "trackVW",
            group: "Track",
            tip: "The width of the track content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 104.",
            val: 104,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "trackVH",
            group: "Track",
            tip: "The height of the track content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 188: the card has no state glyph, so this is the old 220 less the glyph (22) and its gap (10).",
            val: 188,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "trackPW",
            group: "Track",
            tip: "The width of the track content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 272: the card has no state glyph, so this is the old 300 less the glyph (18) and its gap (10).",
            val: 272,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "trackPH",
            group: "Track",
            tip: "The height of the track content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "deviceHW",
            group: "Bluetooth, network, vpn",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the device content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 280.",
            val: 280,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "deviceHH",
            group: "Bluetooth, network, vpn",
            tip: "The height of the device content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "deviceVW",
            group: "Bluetooth, network, vpn",
            tip: "The width of the device content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 124.",
            val: 124,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "deviceVH",
            group: "Bluetooth, network, vpn",
            tip: "The height of the device content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 140.",
            val: 140,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "devicePW",
            group: "Bluetooth, network, vpn",
            tip: "The width of the device content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 280.",
            val: 280,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "devicePH",
            group: "Bluetooth, network, vpn",
            tip: "The height of the device content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "captureHW",
            group: "Capture",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the capture content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 320.",
            val: 320,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "captureHH",
            group: "Capture",
            tip: "The height of the capture content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 96.",
            val: 96,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "captureVW",
            group: "Capture",
            tip: "The width of the capture content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 128.",
            val: 128,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "captureVH",
            group: "Capture",
            tip: "The height of the capture content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 170.",
            val: 170,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "capturePW",
            group: "Capture",
            tip: "The width of the capture content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 300.",
            val: 300,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "capturePH",
            group: "Capture",
            tip: "The height of the capture content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "batteryHW",
            group: "Battery",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the battery content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 260.",
            val: 260,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "batteryHH",
            group: "Battery",
            tip: "The height of the battery content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "batteryVW",
            group: "Battery",
            tip: "The width of the battery content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 92.",
            val: 92,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "batteryVH",
            group: "Battery",
            tip: "The height of the battery content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 110.",
            val: 110,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "batteryPW",
            group: "Battery",
            tip: "The width of the battery content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 240.",
            val: 240,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "batteryPH",
            group: "Battery",
            tip: "The height of the battery content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "powerHW",
            group: "Power",
            blurb: "silicon's pills (profile, GPU mode, charge limit, the MUX's notices): a glyph in its Theme token's colour, a title and a detail.",
            tip: "The The width of the power content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 300. Wider than the generic card (260): the MUX's notice is a sentence.",
            val: 300,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "powerHH",
            group: "Power",
            tip: "The The height of the power content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "powerVW",
            group: "Power",
            tip: "The The width of the power content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 104.",
            val: 104,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "powerVH",
            group: "Power",
            tip: "The The height of the power content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 130.",
            val: 130,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "powerPW",
            group: "Power",
            tip: "The The width of the power content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 300. Wider than the generic card (260): the MUX's notice is a sentence.",
            val: 300,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "powerPH",
            group: "Power",
            tip: "The The height of the power content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal width",
            prop: "genericHW",
            group: "Generic",
            blurb: "OsdStyle.extentOf(kind, orientation): what each kind asks the slot for.",
            tip: "The width of the generic content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 260.",
            val: 260,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "horizontal height",
            prop: "genericHH",
            group: "Generic",
            tip: "The height of the generic content on a horizontal bar, in whole pixels: its implicit size, which the engine's box follows and animates. 56.",
            val: 56,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical width",
            prop: "genericVW",
            group: "Generic",
            tip: "The width of the generic content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 104.",
            val: 104,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "vertical height",
            prop: "genericVH",
            group: "Generic",
            tip: "The height of the generic content on a vertical bar, in whole pixels: its implicit size, which the engine's box follows and animates. 130.",
            val: 130,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill width",
            prop: "genericPW",
            group: "Generic",
            tip: "The width of the generic content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 260.",
            val: 260,
            from: 16,
            to: 400,
            step: 1
        },
        {
            label: "pill height",
            prop: "genericPH",
            group: "Generic",
            tip: "The height of the generic content in the fullscreen pill, in whole pixels: its implicit size, which the engine's box follows and animates. 44.",
            val: 44,
            from: 16,
            to: 400,
            step: 1
        }
    ]

    readonly property var stylePill: [
        {
            label: "dot diameter",
            prop: "pillDotD",
            group: "Motion",
            blurb: "pillT runs 0 (the dot) -> 1 (a vertical capsule) -> 2 (full width).",
            tip: "The dot the pill is born as. 14.",
            val: 14,
            from: 6,
            to: 40,
            step: 1
        },
        {
            label: "top margin",
            prop: "pillTop",
            group: "Motion",
            tip: "The gap between the screen's top edge and the pill. 12.",
            val: 12,
            from: 0,
            to: 60,
            step: 1
        },
        {
            label: "grow ms",
            prop: "pillGrowMs",
            group: "Motion",
            tip: "The CLOSE: the capsule shrinking back to the dot (pillT 1 to 0). 200.",
            val: 200,
            from: 40,
            to: 1200,
            step: 10
        },
        {
            label: "widen ms",
            prop: "pillWidenMs",
            group: "Motion",
            tip: "The CLOSE: the capsule narrowing (pillT 2 to 1). 260.",
            val: 260,
            from: 40,
            to: 1200,
            step: 10
        },
        {
            label: "open grow ms",
            prop: "pillOpenGrowMs",
            group: "Motion",
            tip: "The OPEN: the dot growing down into a capsule. Shorter than the close, the user is waiting for the content. 130.",
            val: 130,
            from: 40,
            to: 1200,
            step: 10
        },
        {
            label: "open widen ms",
            prop: "pillOpenWidenMs",
            group: "Motion",
            tip: "The OPEN: the capsule widening to full width, running over the growth's end. 190.",
            val: 190,
            from: 40,
            to: 1200,
            step: 10
        },
        {
            label: "open lead ms",
            prop: "pillOpenLeadMs",
            group: "Motion",
            tip: "How long after the growth began the widening starts: the overlap that keeps it one motion. 50.",
            val: 50,
            from: 0,
            to: 400,
            step: 10
        },
        {
            label: "content at",
            prop: "pillFadeAt",
            group: "Motion",
            tip: "The share of the widening done when the content starts to fade in. The widest kind needs 0.93 (tools/dev/osd_pill_open_probe.sh). 0.94.",
            val: 0.94,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "content fade in ms",
            prop: "pillFadeInMs",
            group: "Motion",
            tip: "The content's presence fade in. 120.",
            val: 120,
            from: 40,
            to: 800,
            step: 10
        },
        {
            label: "swap ms",

            prop: "pillSwapMs",
            group: "Motion",
            tip: "Width and height easing to another kind's size while it is out. 260.",
            val: 260,
            from: 40,
            to: 1200,
            step: 10
        },
        {
            label: "fade ms",
            prop: "pillFadeMs",
            group: "Motion",
            tip: "The content's presence fade out (in: its own row), and the ball brightening. 160.",
            val: 160,
            from: 40,
            to: 800,
            step: 10
        },
        {
            label: "shadow",
            prop: "pillShadow",
            group: "Relief",
            blurb: "A raised ShadowBox with a stronger shadow.",
            tip: "The drop shadow's spread: the pill floats over arbitrary content, so it is stronger than a button's 5. 9.",
            val: 9,
            from: 0,
            to: 24,
            step: 0.5
        },
        {
            label: "bevel",
            prop: "pillBevel",
            group: "Relief",
            tip: "The highlight inside the edge. 1.5, a button's.",
            val: 1.5,
            from: 0,
            to: 6,
            step: 0.25
        },
        {
            label: "shadow alpha",
            prop: "pillShadowAlpha",
            group: "Relief",
            tip: "The shadow's strength. 1.",
            val: 1.0,
            from: 0,
            to: 1.5,
            step: 0.05
        },
        {
            label: "padding",
            prop: "pillPad",
            group: "Content",
            blurb: "What is in the pill.",
            tip: "Left and right inset of the content inside the capsule (a capsule's corner takes room). 16.",
            val: 16,
            from: 4,
            to: 40,
            step: 1
        },
        {
            label: "glyph px",
            prop: "pillGlyphPx",
            group: "Content",
            tip: "The glyph. 18.",
            val: 18,
            from: 8,
            to: 36,
            step: 1
        },
        {
            label: "text px",
            prop: "pillTextPx",
            group: "Content",
            tip: "Words. 12.",
            val: 12,
            from: 8,
            to: 24,
            step: 1
        },
        {
            label: "figure px",
            prop: "pillFigurePx",
            group: "Content",
            tip: "A level's figure. 14.",
            val: 14,
            from: 8,
            to: 28,
            step: 1
        },
        {
            label: "cover",
            prop: "pillCover",
            group: "Content",
            tip: "The track's cover. 36.",
            val: 36,
            from: 16,
            to: 80,
            step: 1
        },
        {
            label: "ball on screen",
            prop: "pillBallShow",
            group: "Ball",
            blurb: "A hidden pill (the caption's hide button): the dot, risen half off the screen's top, fading to faint.",
            tip: "How much of the ball's diameter stays below the screen's top edge once it has risen. 0.4: less than half -- seen, out of the way.",
            val: 0.4,
            from: 0.1,
            to: 1,
            step: 0.05
        },
        {
            label: "rise ms",
            prop: "pillBallLiftMs",
            group: "Ball",
            tip: "The ball rising to its place (and coming back down when the pointer reaches it). 260: the resize standard.",
            val: 260,
            from: 0,
            to: 1000,
            step: 10
        },
        {
            label: "faint",
            prop: "pillBallFaint",
            group: "Ball",
            tip: "The ball's presence at the end of its fade. 0.18: very transparent over a film, still there to aim at.",
            val: 0.18,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "fade ms",
            prop: "pillBallFadeMs",
            group: "Ball",
            tip: "How long the risen ball takes to fade to faint. 3000: slow enough that the eye does not jump to it.",
            val: 3000,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "hover pad",
            prop: "pillBallHoverPad",
            group: "Ball",
            tip: "How far past the ball (on the sides and below; above it the screen ends) the pointer already counts as on it. 8: a 14 px ball is a small target across.",
            val: 8,
            from: 0,
            to: 30,
            step: 1
        }
    ]

    readonly property var kindParams: [
        {
            label: "route",
            prop: "routeVolume",
            group: "volume",
            blurb: "osd.jsonc: kinds.volume -- the speaker's level.",
            tip: "Where the speaker's level goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msVolume",
            group: "volume",
            tip: "How long the speaker's level stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 2000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeMic",
            group: "mic",
            blurb: "osd.jsonc: kinds.mic -- the microphone.",
            tip: "Where the microphone goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msMic",
            group: "mic",
            tip: "How long the microphone stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 2000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeBrightness",
            group: "brightness",
            blurb: "osd.jsonc: kinds.brightness -- the screen's brightness.",
            tip: "Where the screen's brightness goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msBrightness",
            group: "brightness",
            tip: "How long the screen's brightness stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 2000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeKbd",
            group: "kbd",
            blurb: "osd.jsonc: kinds.kbd -- the keyboard light.",
            tip: "Where the keyboard light goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msKbd",
            group: "kbd",
            tip: "How long the keyboard light stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 2000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeLockkeys",
            group: "lockkeys",
            blurb: "osd.jsonc: kinds.lockkeys -- caps and num lock.",
            tip: "Where caps and num lock goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msLockkeys",
            group: "lockkeys",
            tip: "How long caps and num lock stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 2000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeLayout",
            group: "layout",
            blurb: "osd.jsonc: kinds.layout -- the keyboard layout code.",
            tip: "Where the keyboard layout code goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msLayout",
            group: "layout",
            tip: "How long the keyboard layout code stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 2000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeTheme",
            group: "theme",
            blurb: "osd.jsonc: kinds.theme -- the theme's name and mode.",
            tip: "Where the theme's name and mode goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msTheme",
            group: "theme",
            tip: "How long the theme's name and mode stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 2000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeTrack",
            group: "track",
            blurb: "osd.jsonc: kinds.track -- MPD's track change.",
            tip: "Where MPD's track change goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msTrack",
            group: "track",
            tip: "How long MPD's track change stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3500 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeBluetooth",
            group: "bluetooth",
            blurb: "osd.jsonc: kinds.bluetooth -- a Bluetooth device connecting or leaving.",
            tip: "Where a Bluetooth device connecting or leaving goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msBluetooth",
            group: "bluetooth",
            tip: "How long a Bluetooth device connecting or leaving stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeNetwork",
            group: "network",
            blurb: "osd.jsonc: kinds.network -- Wi-Fi up or lost.",
            tip: "Where Wi-Fi up or lost goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msNetwork",
            group: "network",
            tip: "How long Wi-Fi up or lost stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeVpn",
            group: "vpn",
            blurb: "osd.jsonc: kinds.vpn -- a VPN up or down.",
            tip: "Where a VPN up or down goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msVpn",
            group: "vpn",
            tip: "How long a VPN up or down stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeAutoTunnel",
            group: "autoTunnel",
            blurb: "osd.jsonc: kinds.autoTunnel -- the tunnel aerial raised by itself on a Public network.",
            tip: "Where the auto-tunnel card goes: osd (this OSD, the default: it is a card only), notification (a toast through DesktopNotifier) or off.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msAutoTunnel",
            group: "autoTunnel",
            tip: "How long the auto-tunnel card stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3500 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeBtLow",
            group: "btLow",
            blurb: "osd.jsonc: kinds.btLow -- a Bluetooth device's battery at 20 % / 10 %.",
            tip: "Where the low-battery card goes: osd (this OSD, the default: it is a card only), notification (a toast through DesktopNotifier) or off.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msBtLow",
            group: "btLow",
            tip: "How long the low-battery card stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3500 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeCapture",
            group: "capture",
            blurb: "osd.jsonc: kinds.capture -- a screenshot or recording confirmation.",
            tip: "Where a screenshot or recording confirmation goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msCapture",
            group: "capture",
            tip: "How long a screenshot or recording confirmation stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3500 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeBattery",
            group: "battery",
            blurb: "osd.jsonc: kinds.battery -- battery low / full.",
            tip: "Where battery low / full goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msBattery",
            group: "battery",
            tip: "How long battery low / full stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 4000 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routePower",
            group: "power",
            blurb: "osd.jsonc: kinds.power -- silicon's pills: the CPU profile, the GPU mode and the charge limit changed outside its popup, and what the MUX flow has to tell.",
            tip: "Where silicon's pills go: osd (this OSD), notification (a toast through DesktopNotifier) or off (silicon then posts a desktop notification itself). Every kind defaults to osd.",
            val: 0,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msPower",
            group: "power",
            tip: "How long a power pill stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3000 ms). The request's own ms wins over both: silicon's profile, GPU and limit pills ask for 2000.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        },
        {
            label: "route",
            prop: "routeGeneric",
            group: "generic",
            blurb: "osd.jsonc: kinds.generic -- a third party's request through OsdBus.",
            tip: "Where a third party's request through OsdBus goes: osd (this OSD), notification (a toast through DesktopNotifier) or off. Generic is off by default: nothing replaces a notification until the user decides at deploy.",
            val: 2,
            choices: ["osd", "notification", "off"]
        },
        {
            label: "ms",
            prop: "msGeneric",
            group: "generic",
            tip: "How long a third party's request through OsdBus stays (0 = the OSD-wide dismiss time, then the kind's own fallback of 3500 ms). The request's own ms wins over both.",
            val: 0,
            from: 0,
            to: 10000,
            step: 100
        }
    ]


    readonly property var hostParams: [
        {
            label: "right bar thickness",
            prop: "rightThickness",
            group: "Bars",
            blurb: "The slim bars the OSD comes out of.",
            tip: "The slim right bar's thickness (reserve 0: windows keep their place). 6, the slim bar of the shell. The OSD and every popup take its face from it.",
            val: 6,
            from: 2,
            to: 40,
            step: 1
        },
        {
            label: "bottom bar on",
            prop: "bottomOn",
            group: "Bars",
            tip: "A slim bar along the foot, where a horizontal OSD comes out. Off by default: the spot names the right bar.",
            val: false
        },
        {
            label: "bottom bar thickness",
            prop: "bottomThickness",
            group: "Bars",
            tip: "The bottom bar's thickness. 6.",
            val: 6,
            from: 2,
            to: 40,
            step: 1
        },
        {
            label: "OSD bar",
            prop: "spotBar",
            group: "The OSD's spot",
            blurb: "osd.jsonc's spot: a bar and where along it (a corner is along 0 or 1).",
            tip: "The bar the OSD comes out of. Right: vertical. Bottom or top: horizontal (the bottom bar turns on with it). A bar that is not there falls back to the default corner.",
            val: 0,
            choices: ["right", "bottom", "top"]
        },
        {
            label: "OSD along",
            prop: "spotAlong",
            group: "The OSD's spot",
            tip: "Where along that bar the OSD's middle stands, 0 to 1 from the bar's start on the screen (its top or left end). 0.5: the middle.",
            val: 0.5,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "fullscreen mode",
            prop: "fsMode",
            group: "Fullscreen",
            blurb: "What the OSD does while a window is fullscreen.",
            tip: "pill: a top-centre pill instead of the bar's OSD. suppress: nothing is shown. The fullscreen window itself is the Run tab's toggle.",
            val: 0,
            choices: ["pill", "suppress"]
        },
        {
            label: "popup width",
            prop: "popupW",
            group: "thePopup stand-in",
            blurb: "The popup the mockup stands on the bar, for the OSD to meet.",
            tip: "The stand-in popup's width. 260.",
            val: 260,
            from: 80,
            to: 600,
            step: 1
        },
        {
            label: "popup height",
            prop: "popupH",
            group: "thePopup stand-in",
            tip: "The stand-in popup's height. 300: on the right bar that is its length along the bar, the OSD's own 300 plus a little.",
            val: 300,
            from: 80,
            to: 700,
            step: 1
        },
        {
            label: "lane bar",
            prop: "laneBar",
            group: "Toast lane stand-in",
            blurb: "A stand-in for the notifications' toast stack.",
            tip: "The bar the lane stands on.",
            val: 1,
            choices: ["top", "right", "bottom"]
        },
        {
            label: "lane along",
            prop: "laneAlong",
            group: "Toast lane stand-in",
            tip: "Where along its bar the lane stands, 0 to 1. 0.85: near the foot of the right bar.",
            val: 0.85,
            from: 0,
            to: 1,
            step: 0.01
        },
        {
            label: "lane width",
            prop: "laneW",
            group: "Toast lane stand-in",
            tip: "The card's width. 260.",
            val: 260,
            from: 80,
            to: 600,
            step: 1
        },
        {
            label: "lane height",
            prop: "laneH",
            group: "Toast lane stand-in",
            tip: "The card's height; the lane follows it while it is out. 120.",
            val: 120,
            from: 40,
            to: 600,
            step: 1
        }
    ]
}
