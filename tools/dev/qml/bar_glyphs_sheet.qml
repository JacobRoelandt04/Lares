pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/bar/audio"
import "modules/bar/llm"
import "modules/aerial/bar"
import "modules/bar/player"
import "modules/bar/reel"
import "modules/bar/system_update/components"
import "modules/notes"
import "modules/notifications"
import "modules/shell"
import "modules/silicon"
import "modules/stocks"
import "modules/weather"
import "modules/shell/ReelItems.js" as ReelItems

// =============================================================================
// bar_glyphs_sheet.qml -- every bar glyph in every state it can show, one PNG per cell, for the before/after sheet of the bar
// glyphs' overhaul (tools/dev/bar_glyphs_sheet.sh runs it on an old tree and on this one, in each theme and mode, and composes).
//
// The buttons are the modules' own, fed by stand-ins of the services they read, each in a cell on the bar's surface. A step sets
// a state (and, for a hover, moves the pointer onto the glyph through QtTest, which drives the WINDOW: the button's own
// MouseArea answers), waits for the fades, and grabs the cell. Written for both trees: a property the old tree does not have
// is set only where it exists (`_set`).
//
//   OUT_DIR    where the cells go (<name>.png) -- required
//   STEP_MS    how long a step waits before its grab (default 700: every fade here is 260 ms or less)
//   NO_BRIDGE  1: the tree has no modules/bridge (an old BEFORE tree): the bridge cell is left empty and loaded by nothing
//   FILM=1     instead of the states: the hover fade frame by frame (film_hover_<n>.png) and one roll of each figure
//              (film_<figure>_<n>.png), one grab per rendered frame
//
// Prints `GLYPHS_SHEET cell <name>` per grab and `GLYPHS_SHEET RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 1500
        implicitHeight: 360
        visible: true
        color: Theme.surface

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property int stepMs: Number(Quickshell.env("STEP_MS") || 700)
        readonly property bool film: Quickshell.env("FILM") === "1"

        readonly property bool noBridge: Quickshell.env("NO_BRIDGE") === "1"
        // a tree without modules/panorama (an old BEFORE tree), or one whose shell does not import it yet (Quickshell resolves a file by
        // URL only under a directory a scanned file imports): the panorama cells stay empty, and their steps set nothing (`pano`), so a
        // missing button never throws inside a step -- which stopped the whole sheet at the first one (the next grab is never armed)
        function pano(props) {
            if (!panoLoader.item)
                return;
            for (const k in props)
                panoLoader.item[k] = props[k];
        }
        readonly property bool noPano: Qt.createComponent(Qt.resolvedUrl("../../../modules/panorama/bar/PanoramaBarButton.qml"), Component.PreferSynchronous).status === Component.Error

        function _set(obj, prop, val) {
            if (obj && (prop in obj))
                obj[prop] = val;
        }

        // ---- stand-ins --------------------------------------------------------------------------------------------------
        QtObject {
            id: themeCtl
            property int active: 0
            property int fails: 0
        }
        component LlmSvc: QtObject {
            readonly property string model: "stand-in"
            property var backend: ({ loaded: {} })
            property bool generating: false
            property var pendingConfirm: null
        }
        QtObject {
            id: llmStand
            property bool attended: true
            readonly property LlmSvc service: LlmSvc {}
        }
        QtObject {
            id: mpd
            property bool connected: true
            property string playState: "stop"
            property int songId: 1
        }
        QtObject {
            id: notesOwner
            property bool popupMine: false
            function toggle() {}
        }
        QtObject {
            id: bellSvc
            property bool dnd: false
            property string holdReason: ""
            property string dotGroup: ""
        }
        QtObject {
            id: bellOwner
            readonly property var service: bellSvc
            property bool popupMine: false
            property bool laneHeld: false
            readonly property var style: null
            function toggle() {}
        }
        QtObject {
            id: weatherSvc
            property var model: ({ current: { kind: "clear", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] })
            readonly property var config: ({ units: {} })
        }
        QtObject {
            id: stocksSvc
            property var portfolio: ({ anyHeldOpen: true, dayPct: 1.23 })
            readonly property var daySpark: ({ v: [10, 10.4, 10.2, 10.9, 11.3, 11.1, 11.8, 12.0], base: 10 })
        }
        QtObject {
            id: stocksOwner
            readonly property var svc: stocksSvc
            property bool popupMine: false
            function toggle() {}
        }
        // the bridge's service as the button reads it: ready, the current device ({ key, present, link, mounts }) and the jobs
        QtObject {
            id: bridgeStand
            property bool ready: true
            property int serial: 0
            property var current: null
            property var jobs: []
            property var pairing: []
        }
        function bridgeDevice(link, mounts) {
            return { key: "kdc:stand-in", present: link !== "none", link: link,
                mounts: { usb: { state: mounts === "usb" ? "mounted" : "unmounted" }, wifi: { state: mounts === "wifi" ? "mounted" : "unmounted" } } };
        }
        // the pill's stand-in service: the facts the pill reads, set a state at a time
        AerialPillStand {
            id: netStand
        }
        function setNet(o) {
            netStand.net(o);
        }
        function setBt(o) {
            netStand.setBt(o);
        }
        IconReel {
            id: powerReel
            visible: false
            items: ReelItems.POWER
        }
        IconReel {
            id: idleReel
            visible: false
            items: ReelItems.IDLE
        }

        // ---- the cells ----------------------------------------------------------------------------------------------------
        component Cell: Item {
            id: cell
            default property alias content: holder.data
            property real w: 64
            property real h: 44
            width: cell.w
            height: cell.h
            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }
            Item {
                id: holder
                anchors.fill: parent
            }
        }

        Flow {
            x: 8
            y: 8
            width: win.width - 16
            spacing: 6

            Cell {
                id: cTheme
                ThemeBarButton {
                    id: bTheme
                    control: themeCtl
                    anchors.centerIn: parent
                    Component.onCompleted: win._set(bTheme, "flourishEnabled", false)
                }
            }
            Cell {
                id: cNotes
                NotesBarButton {
                    id: bNotes
                    owner: notesOwner
                    anchors.centerIn: parent
                    // the cells are the icon's STATES: its flourish (a hover plays it) is the strip's
                    Component.onCompleted: win._set(bNotes, "flourishEnabled", false)
                }
            }
            Cell {
                id: cLlm
                LlmBarButton {
                    id: bLlm
                    llm: llmStand
                    anchors.centerIn: parent
                    Component.onCompleted: win._set(bLlm, "flourishEnabled", false)
                }
            }
            Cell {
                id: cWeather
                w: 96
                WeatherBarButton {
                    id: bWeather
                    // the cells are the icon's STATES: its flourish (a hover plays it) is the strip's (weather_ink_strip.qml). Set where
                    // the tree has it (an old tree's button has none).
                    Component.onCompleted: win._set(bWeather, "flourishEnabled", false)
                    service: weatherSvc
                    fontFamily: "Audiowide"
                    x: 8
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
            Cell {
                id: cStocks
                w: 120
                StocksBarButton {
                    id: bStocks
                    owner: stocksOwner
                    fontFamily: "Audiowide"
                    anchors.centerIn: parent
                    Component.onCompleted: win._set(bStocks, "flourishEnabled", false)
                }
            }
            Cell {
                id: cPlayer
                PlayerBarButton {
                    id: bPlayer
                    player: mpd
                    anchors.centerIn: parent
                }
            }
            Cell {
                id: cAudio
                w: 72
                AudioBarButton {
                    id: bAudio
                    anchors.centerIn: parent
                    outputVolume: 0.5
                    inputVolume: 0.5
                }
            }
            Cell {
                id: cNet
                w: 72
                AerialBarButton {
                    id: bNet
                    anchors.centerIn: parent
                    fontFamily: "Audiowide"
                    service: netStand
                }
            }
            // The bridge: a Loader, so a tree without modules/bridge (the BEFORE tree) just has an empty cell.
            Cell {
                id: cBridge
                Loader {
                    id: bridgeLoader
                    anchors.centerIn: parent
                    active: !win.noBridge
                    source: "modules/bridge/BridgeBarButton.qml"
                    onLoaded: {
                        // the cells are the icon's STATES: its flourish (a hover plays it) is the strip's
                        bridgeLoader.item.flourishEnabled = false;
                        // ... and each state is taken at once, a cast's car held at mid span (a sheet repeats to the pixel)
                        if ("motion" in bridgeLoader.item) {
                            bridgeLoader.item.motion = false;
                            bridgeLoader.item.holdCastStep = 5;
                        }
                        bridgeLoader.item.service = bridgeStand;
                    }
                }
            }
            // The panorama: a Loader too (the BEFORE tree has no modules/panorama).
            Cell {
                id: cPano
                Loader {
                    id: panoLoader
                    anchors.centerIn: parent
                    active: !win.noPano
                    source: "modules/panorama/bar/PanoramaBarButton.qml"
                    onLoaded: panoLoader.item.flourishEnabled = false
                }
            }
            Cell {
                id: cSilicon
                w: 120
                SiliconBarButton {
                    id: bSilicon
                    anchors.centerIn: parent
                    fontFamily: "Audiowide"
                    liveMotion: false
                    flourishEnabled: false
                    percent: 81
                    profile: 1
                    gpuMode: 1
                }
            }
            Cell {
                id: cSiliconSide
                w: 48
                h: 92
                // a side bar's frame: turned a quarter, the button's face standing upright in it
                Item {
                    anchors.centerIn: parent
                    rotation: 90
                    SiliconBarButton {
                        id: bSiliconSide
                        x: -width / 2
                        y: -height / 2
                        fontFamily: "Audiowide"
                        liveMotion: false
                        flourishEnabled: false
                        vertical: true
                        barRotation: 90
                        percent: 81
                        profile: 1
                        gpuMode: 1
                    }
                }
            }
            Cell {
                id: cUpdate
                w: 120
                SystemUpdateIcon {
                    id: bUpdate
                    anchors.centerIn: parent
                    fontFamily: "Audiowide"
                }
            }
            Cell {
                id: cBell
                NotificationsBarButton {
                    id: bBell
                    owner: bellOwner
                    anchors.centerIn: parent
                }
            }
            // The reels: each option's glyph in the colour the bar's selected icon takes under the pointer (IconReel.tintOf).
            Cell {
                id: cPower
                w: 6 * 30 + 8
                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    Repeater {
                        model: ReelItems.POWER.length
                        Text {
                            required property int index
                            text: ReelItems.POWER[index].glyph
                            font.family: "Symbols Nerd Font"
                            font.pixelSize: 21
                            color: powerReel.tintOf(ReelItems.POWER[index])
                        }
                    }
                }
            }
            Cell {
                id: cIdle
                w: 4 * 30 + 8
                Row {
                    anchors.centerIn: parent
                    spacing: 6
                    Repeater {
                        model: ReelItems.IDLE.length
                        Text {
                            required property int index
                            text: ReelItems.IDLE[index].glyph
                            font.family: "Symbols Nerd Font"
                            font.pixelSize: 21
                            color: idleReel.tintOf(ReelItems.IDLE[index])
                        }
                    }
                }
            }
        }

        TestCase {
            id: tc
            name: "glyphsheet"
            when: false
        }

        // ---- the steps ----------------------------------------------------------------------------------------------------
        function centreOf(item, fx) {
            const p = item.mapToItem(win.contentItem, item.width * (fx === undefined ? 0.5 : fx), item.height / 2);
            return Qt.point(Math.round(p.x), Math.round(p.y));
        }
        function park() {
            tc.mouseMove(win.contentItem, win.width - 3, win.height - 3);
        }
        function hover(item, fx) {
            const p = win.centreOf(item, fx);
            tc.mouseMove(win.contentItem, p.x - 3, p.y);
            tc.mouseMove(win.contentItem, p.x, p.y);
        }
        function resetAll() {
            themeCtl.active = 0;
            llmStand.service.backend = { loaded: {} };
            llmStand.service.generating = false;
            llmStand.service.pendingConfirm = null;
            mpd.playState = "stop";
            notesOwner.popupMine = false;
            bellSvc.dnd = false;
            bellSvc.holdReason = "";
            bellSvc.dotGroup = "";
            bellOwner.popupMine = false;
            weatherSvc.model = { current: { kind: "clear", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] };
            stocksSvc.portfolio = { anyHeldOpen: true, dayPct: 1.23 };
            stocksOwner.popupMine = false;
            bAudio.outputMuted = false;
            bAudio.inputMuted = false;
            bNet.popupOpen = false;
            win.setNet({ radio: true, connected: true, bars: 3 });
            win.setBt({ on: true });
            bridgeStand.current = win.bridgeDevice("none", "");
            bridgeStand.jobs = [];
            bridgeStand.pairing = [];
            if (panoLoader.item) {
                panoLoader.item.panes = 1;
                panoLoader.item.mirroring = false;
            }
            bUpdate.updatesAvailable = 0;
            bUpdate.outcome = "";
            bUpdate.running = false;
            bUpdate.active = false;
            bSilicon.active = false;
            bSilicon.percent = 81;
            bSilicon.profile = 1;
            win.gpu(1, false);
            win._set(bSilicon, "muxPending", false);
            win._set(bSilicon, "gpuKnown", true);
        }
        // silicon's GPU: the mode (0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only) and whether its card is in use
        function gpu(mode, inUse) {
            win._set(bSilicon, "gpuMode", mode);
            win._set(bSilicon, "gpuInUse", inUse);
            win._set(bSiliconSide, "gpuMode", mode);
            win._set(bSiliconSide, "gpuInUse", inUse);
        }
        readonly property var steps: [
            // theme
            { n: "theme_rest", c: cTheme },
            { n: "theme_hover", c: cTheme, h: bTheme },
            { n: "theme_busy", c: cTheme, f: () => themeCtl.active = 1 },
            // notes
            { n: "notes_rest", c: cNotes },
            { n: "notes_hover", c: cNotes, h: bNotes },
            { n: "notes_active", c: cNotes, f: () => notesOwner.popupMine = true },
            // llm
            { n: "llm_none", c: cLlm },
            { n: "llm_loaded", c: cLlm, f: () => llmStand.service.backend = { loaded: { "stand-in": { size: 1 } } } },
            { n: "llm_generating", c: cLlm, f: () => { llmStand.service.backend = { loaded: { "stand-in": { size: 1 } } }; llmStand.service.generating = true; } },
            { n: "llm_needsyou", c: cLlm, f: () => { llmStand.service.backend = { loaded: { "stand-in": { size: 1 } } }; llmStand.service.pendingConfirm = { tool: "x" }; } },
            { n: "llm_hover", c: cLlm, f: () => llmStand.service.backend = { loaded: { "stand-in": { size: 1 } } }, h: bLlm },
            // weather
            { n: "weather_rest", c: cWeather },
            { n: "weather_hover", c: cWeather, h: bWeather },
            { n: "weather_warn", c: cWeather, f: () => weatherSvc.model = { current: { kind: "clear", intensity: 1, night: false, shower: false, temp: -3 }, warnings: [{ level: 2 }] } },
            { n: "weather_7", c: cWeather, f: () => weatherSvc.model = { current: { kind: "clear", intensity: 1, night: false, shower: false, temp: 7 }, warnings: [] } },
            { n: "weather_m12", c: cWeather, f: () => weatherSvc.model = { current: { kind: "clear", intensity: 1, night: false, shower: false, temp: -12 }, warnings: [] } },
            // the conditions (the icon itself; the figure stays)
            { n: "weather_partly", c: cWeather, f: () => weatherSvc.model = { current: { kind: "partly", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_night", c: cWeather, f: () => weatherSvc.model = { current: { kind: "clear", intensity: 1, night: true, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_cloudy", c: cWeather, f: () => weatherSvc.model = { current: { kind: "cloudy", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_rain", c: cWeather, f: () => weatherSvc.model = { current: { kind: "rain", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_heavyrain", c: cWeather, f: () => weatherSvc.model = { current: { kind: "rain", intensity: 2, night: false, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_shower", c: cWeather, f: () => weatherSvc.model = { current: { kind: "rain", intensity: 1, night: false, shower: true, temp: 12 }, warnings: [] } },
            { n: "weather_snow", c: cWeather, f: () => weatherSvc.model = { current: { kind: "snow", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_thunder", c: cWeather, f: () => weatherSvc.model = { current: { kind: "thunder", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_fog", c: cWeather, f: () => weatherSvc.model = { current: { kind: "fog", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] } },
            { n: "weather_rain_hover", c: cWeather, h: bWeather, f: () => weatherSvc.model = { current: { kind: "rain", intensity: 1, night: false, shower: false, temp: 12 }, warnings: [] } },
            // stocks
            { n: "stocks_gain", c: cStocks },
            { n: "stocks_loss", c: cStocks, f: () => stocksSvc.portfolio = { anyHeldOpen: true, dayPct: -0.87 } },
            { n: "stocks_big", c: cStocks, f: () => stocksSvc.portfolio = { anyHeldOpen: true, dayPct: -12.34 } },
            { n: "stocks_hover", c: cStocks, h: bStocks },
            { n: "stocks_closed", c: cStocks, f: () => stocksSvc.portfolio = { anyHeldOpen: false, dayPct: 0 } },
            { n: "stocks_closedhover", c: cStocks, f: () => stocksSvc.portfolio = { anyHeldOpen: false, dayPct: 0 }, h: bStocks },
            // player
            { n: "player_stopped", c: cPlayer },
            { n: "player_playing", c: cPlayer, f: () => mpd.playState = "play" },
            { n: "player_hover", c: cPlayer, f: () => mpd.playState = "play", h: bPlayer },
            // audio
            { n: "audio_on", c: cAudio },
            { n: "audio_outmuted", c: cAudio, f: () => bAudio.outputMuted = true },
            { n: "audio_inmuted", c: cAudio, f: () => bAudio.inputMuted = true },
            { n: "audio_hoverout", c: cAudio, h: bAudio, hx: 0.25 },
            { n: "audio_hoverin", c: cAudio, h: bAudio, hx: 0.75 },
            // network
            { n: "net_on", c: cNet },
            { n: "net_btconnected", c: cNet, f: () => win.setBt({ on: true, connected: true }) },
            { n: "net_looking", c: cNet, f: () => win.setNet({ radio: true, connected: false }) },
            { n: "net_off", c: cNet, f: () => { win.setNet({ radio: false }); win.setBt({ on: false }); } },
            { n: "net_airplane", c: cNet, f: () => { win.setNet({ radio: false, airplane: true }); win.setBt({ on: true, blocked: true }); } },
            { n: "net_degraded", c: cNet, f: () => win.setNet({ radio: true, connected: true, bars: 2, portal: true }) },
            { n: "net_wired", c: cNet, f: () => win.setNet({ wired: true, wiredDevice: true, noWifi: true }) },
            { n: "net_unplugged", c: cNet, f: () => win.setNet({ wiredDevice: true, noWifi: true }) },
            // aerial's four states: a tunnel up (a padlock on the glyph), the hotspot on, a Public network with no tunnel (the open padlock, warn), a failed pad (the error ink)
            { n: "net_vpn", c: cNet, f: () => win.setNet({ radio: true, connected: true, bars: 3, vpn: true }) },
            { n: "net_hotspot", c: cNet, f: () => win.setNet({ radio: true, connected: false, hotspot: true }) },
            { n: "net_public", c: cNet, f: () => win.setNet({ radio: true, connected: true, bars: 3, publicNet: true }) },
            { n: "net_fault", c: cNet, f: () => win.setNet({ radio: true, connected: true, bars: 3, fault: "error" }) },
            { n: "net_open", c: cNet, f: () => bNet.popupOpen = true },
            { n: "net_hovernet", c: cNet, h: bNet, hx: 0.25 },
            { n: "net_hoverbt", c: cNet, h: bNet, hx: 0.75 },
            // bridge (a drawbridge): no device (raised, faint), over Wi-Fi and on the cable (down, the plain ink, alike), a phone asking to
            // pair (its leaf down alone, the warn hue), a cast (a car in the accent, held at mid span), storage mounted (a car parked), hovered
            { n: "bridge_none", c: cBridge },
            { n: "bridge_wifi", c: cBridge, f: () => bridgeStand.current = win.bridgeDevice("wifi", "") },
            { n: "bridge_wired", c: cBridge, f: () => bridgeStand.current = win.bridgeDevice("usb", "") },
            { n: "bridge_pair", c: cBridge, f: () => bridgeStand.pairing = [{ key: "kdc:new", byPeer: true }] },
            { n: "bridge_mirror", c: cBridge, f: () => { bridgeStand.current = win.bridgeDevice("usb", ""); bridgeStand.jobs = [{ id: "m", kind: "mirror", device: "kdc:stand-in", phase: "running" }]; } },
            { n: "bridge_mounted", c: cBridge, f: () => bridgeStand.current = win.bridgeDevice("wifi", "wifi") },
            { n: "bridge_hover_none", c: cBridge, h: bridgeLoader },
            { n: "bridge_hover_wifi", c: cBridge, h: bridgeLoader, f: () => bridgeStand.current = win.bridgeDevice("wifi", "") },
            { n: "bridge_hover_wired", c: cBridge, h: bridgeLoader, f: () => bridgeStand.current = win.bridgeDevice("usb", "") },
            // panorama: the displays in use as screens with windows on them (one, two, three, "+"), the mirror mark, the pointer
            { n: "pano_1", c: cPano },
            { n: "pano_2", c: cPano, f: () => win.pano({ panes: 2 }) },
            { n: "pano_3", c: cPano, f: () => win.pano({ panes: 3 }) },
            { n: "pano_4", c: cPano, f: () => win.pano({ panes: 4 }) },
            { n: "pano_mirror", c: cPano, f: () => win.pano({ mirroring: true }) },
            { n: "pano_2_mirror", c: cPano, f: () => win.pano({ panes: 2, mirroring: true }) },
            { n: "pano_4_mirror", c: cPano, f: () => win.pano({ panes: 4, mirroring: true }) },
            { n: "pano_hover_2", c: cPano, h: panoLoader, f: () => win.pano({ panes: 2 }) },
            // silicon
            { n: "silicon_rest", c: cSilicon },
            { n: "silicon_hover", c: cSilicon, h: bSilicon },
            { n: "silicon_open", c: cSilicon, f: () => bSilicon.active = true },
            // the GPU's mode, its card idle and in use (Integrated has no card; dGPU-only's is always in use)
            { n: "silicon_gpu_integrated", c: cSilicon, f: () => win.gpu(0, false) },
            { n: "silicon_gpu_smart_idle", c: cSilicon, f: () => win.gpu(1, false) },
            { n: "silicon_gpu_smart_use", c: cSilicon, f: () => win.gpu(1, true) },
            { n: "silicon_gpu_hybrid_idle", c: cSilicon, f: () => win.gpu(2, false) },
            { n: "silicon_gpu_hybrid_use", c: cSilicon, f: () => win.gpu(2, true) },
            { n: "silicon_gpu_dgpu", c: cSilicon, f: () => win.gpu(3, true) },
            // Integrated chosen with apps still on the card; a MUX switch waiting for its restart (the breath's low point); not known yet
            { n: "silicon_gpu_leaving", c: cSilicon, f: () => { win.gpu(2, true); win.gpu(0, true); } },
            { n: "silicon_gpu_pending", c: cSilicon, f: () => { win.gpu(2, false); win._set(bSilicon, "muxPending", true); } },
            { n: "silicon_gpu_unknown", c: cSilicon, f: () => win._set(bSilicon, "gpuKnown", false) },
            // the two ladders side by side at their ends
            { n: "silicon_quiet_integrated", c: cSilicon, f: () => { bSilicon.profile = 0; win.gpu(0, false); } },
            { n: "silicon_perf_dgpu", c: cSilicon, f: () => { bSilicon.profile = 2; win.gpu(3, true); } },
            // the same pill as a side bar holds it (a capsule: profile glyph, figure, track, GPU glyph)
            { n: "side_silicon_integrated", c: cSiliconSide, f: () => win.gpu(0, false) },
            { n: "side_silicon_smart_use", c: cSiliconSide, f: () => win.gpu(1, true) },
            { n: "side_silicon_hybrid_idle", c: cSiliconSide, f: () => win.gpu(2, false) },
            { n: "side_silicon_dgpu", c: cSiliconSide, f: () => win.gpu(3, true) },
            { n: "silicon_79", c: cSilicon, f: () => bSilicon.percent = 79 },
            { n: "silicon_100", c: cSilicon, f: () => bSilicon.percent = 100 },
            { n: "silicon_7", c: cSilicon, f: () => bSilicon.percent = 7 },
            // update
            { n: "update_none", c: cUpdate },
            { n: "update_few", c: cUpdate, f: () => bUpdate.updatesAvailable = 12 },
            { n: "update_many", c: cUpdate, f: () => bUpdate.updatesAvailable = 60 },
            { n: "update_lots", c: cUpdate, f: () => bUpdate.updatesAvailable = 200 },
            { n: "update_failed", c: cUpdate, f: () => { bUpdate.updatesAvailable = 3; bUpdate.outcome = "failed"; } },
            { n: "update_hover", c: cUpdate, f: () => bUpdate.updatesAvailable = 60, h: bUpdate },
            { n: "update_active", c: cUpdate, f: () => { bUpdate.updatesAvailable = 60; bUpdate.active = true; } },
            // bell
            { n: "bell_rest", c: cBell },
            { n: "bell_normal", c: cBell, f: () => bellSvc.dotGroup = "normal" },
            { n: "bell_critical", c: cBell, f: () => bellSvc.dotGroup = "critical" },
            { n: "bell_system", c: cBell, f: () => bellSvc.dotGroup = "system" },
            { n: "bell_low", c: cBell, f: () => bellSvc.dotGroup = "low" },
            { n: "bell_dnd", c: cBell, f: () => bellSvc.dnd = true },
            { n: "bell_held", c: cBell, f: () => bellSvc.holdReason = "fullscreen" },
            { n: "bell_hover", c: cBell, f: () => bellSvc.dotGroup = "critical", h: bBell },
            { n: "bell_active", c: cBell, f: () => { bellSvc.dotGroup = "normal"; bellOwner.popupMine = true; } },
            // reels
            { n: "reel_power", c: cPower },
            { n: "reel_idle", c: cIdle }
        ]

        property int _i: -1
        property int _grabbed: 0
        function next() {
            win._i++;
            if (win._i >= win.steps.length) {
                console.log("GLYPHS_SHEET RESULT " + (win._grabbed === win.steps.length ? "PASS" : "FAIL") + " cells=" + win._grabbed + "/" + win.steps.length);
                quitTimer.start();
                return;
            }
            const st = win.steps[win._i];
            win.park();
            win.resetAll();
            if (st.f)
                st.f();
            if (st.h)
                win.hover(st.h, st.hx);
            grabTimer.restart();
        }
        Timer {
            id: grabTimer
            interval: win.stepMs
            onTriggered: {
                const st = win.steps[win._i];
                const ok = st.c.grabToImage(r => {
                    r.saveToFile(win.outDir + "/" + st.n + ".png");
                    win._grabbed++;
                    console.log("GLYPHS_SHEET cell " + st.n);
                    win.next();
                });
                if (!ok) {
                    console.log("GLYPHS_SHEET grab refused " + st.n);
                    win.next();
                }
            }
        }

        // ---- the films: the hover fade, one grab per frame; one roll of each figure ------------------------------------------
        property var _film: null
        property int _frame: 0
        function filmNext(list) {
            if (list.length === 0) {
                console.log("GLYPHS_SHEET RESULT PASS films");
                quitTimer.start();
                return;
            }
            const f = list.shift();
            win.park();
            win.resetAll();
            if (f.setup)
                f.setup();
            settleTimer.after = () => {
                win._film = { name: f.name, cell: f.cell, frames: f.frames, rest: list };
                win._frame = 0;
                f.act();
                win._grabFrame();
            };
            settleTimer.restart();
        }
        Timer {
            id: settleTimer
            property var after: null
            interval: win.stepMs
            onTriggered: settleTimer.after()
        }
        function _grabFrame() {
            const fm = win._film;
            fm.cell.grabToImage(r => {
                r.saveToFile(win.outDir + "/film_" + fm.name + "_" + String(win._frame).padStart(2, "0") + ".png");
                win._frame++;
                if (win._frame < fm.frames)
                    win._grabFrame();
                else
                    win.filmNext(fm.rest);
            });
        }
        readonly property var films: [
            { name: "hover", cell: cNotes, frames: 16, act: () => win.hover(bNotes) },
            { name: "hoverbell", cell: cBell, frames: 16, setup: () => bellSvc.dotGroup = "critical", act: () => win.hover(bBell) },
            { name: "weather", cell: cWeather, frames: 28, act: () => weatherSvc.model = { current: { kind: "clear", intensity: 1, night: false, shower: false, temp: 13 }, warnings: [] } },
            { name: "stocks", cell: cStocks, frames: 28, act: () => stocksSvc.portfolio = { anyHeldOpen: true, dayPct: 1.46 } },
            { name: "silicon", cell: cSilicon, frames: 28, setup: () => { win._set(bSilicon, "liveMotion", true); }, act: () => bSilicon.percent = 79 }
        ]

        Timer {
            id: quitTimer
            interval: 50
            onTriggered: Qt.quit()
        }
        Timer {
            running: true
            interval: 1200
            onTriggered: {
                // every button's own size: an overhaul of colours moves no box (the weather's bold figure is the one that may)
                const sizes = { theme: bTheme, notes: bNotes, llm: bLlm, weather: bWeather, stocks: bStocks, player: bPlayer,
                    audio: bAudio, network: bNet, silicon: bSilicon, update: bUpdate, bell: bBell };
                if (bridgeLoader.item)
                    sizes.bridge = bridgeLoader.item;
                if (panoLoader.item)
                    sizes.panorama = panoLoader.item;
                for (const k in sizes)
                    console.log("GLYPHS_SHEET size " + k + " " + sizes[k].implicitWidth + "x" + sizes[k].implicitHeight);
                if (win.outDir === "") {
                    console.log("GLYPHS_SHEET RESULT FAIL (no OUT_DIR)");
                    quitTimer.start();
                } else if (win.film) {
                    win.filmNext(win.films.slice());
                } else {
                    win.next();
                }
            }
        }
    }
}
