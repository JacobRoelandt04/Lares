pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/bar/player"
import "modules/bar/system_update/components"
import "modules/notifications"
import "modules/notes"
import "modules/bar/llm"
import "modules/bridge"
import "modules/panorama/bar"
import "modules/silicon"
import "modules/bar/audio"
import "modules/aerial/bar"
import "modules/shell"
import "modules/stocks"
import "modules/bar/system_update/components/ArchivePose.js" as Archive
import "modules/common/components/GlyphOutline.js" as O

// =============================================================================
// glyph_flourish_strip.qml -- the bar glyphs' flourishes frame by frame, on a HELD clock (GlyphFlourish `held`: the harness writes
// `t`), one PNG per frame of each real button in a cell of the bar's surface (tools/dev/glyph_flourish_strip.sh composes them).
//
//   MODE=strip   (default) bell, bell-sleep, a bell burst (three strikes), the archive box, the vinyl, silicon's three profile
//                glyphs and its four GPU mode glyphs (lit; the bulb once more with its card idle, so faded),
//                then THE PILLS (the audio pill's and the networking pill's halves, each in its states: the speaker's levels
//                and muted (as this machine mutes: no wave; and with its waves), headphones on and muted, a headset, the
//                microphone on and muted; the Wi-Fi fan's levels, off and alert, the wire with and
//                without a link, the plane, Bluetooth plain, connected and off); the note's peel and the chat star's kindling;
//                the theme button's swatch book (the filled swatch, in both modes); the bridge button's drawbridge (the salute of a raised one, of one that is down, and the cable's sag);
//                the panorama button's deal at every count and while the displays mirror
//   MODE=story   the system update's PER-STEP SEQUENCE, a proposal (not built into the icon): the real icon in its run state per
//                step, its glyph posed by ArchivePose.compose from the step's held state (the harness sets the PosedGlyph's parts)
//   MODE=film    the pointer on LIVE clocks, one grab per rendered frame: for each glyph an entry that does not move (rest
//                frames), a motion (it plays), the pointer resting on it (no replay), a leave and a new entry with motion (it
//                plays again); and the bell's burst (three notifications 60 ms apart). Frames film_<glyph>_<n>_<phase>.png
//   OUT_DIR      where the frames go (required); FRAMES (default 16) frames per flourish
//   ONLY         one strip by name (bell, box, ...); SPAN (default 1) the share of the run the frames cover (0.4: its start, finer)
//   SET=pills    the pills' strips only; PILLSCALE (default 1) draws the two pills that many times larger (a true render at
//                that size, not a magnified grab)
//   SET=pano     the panorama button's strips only (with ONLY-like frame counts: FRAMES)
//   THEMESCALE   (default 1) draws the theme and the panorama button that many times larger, likewise a true render (ONLY=theme, or
//                SET=pano, with it)
//
// Prints `FLOURISH_STRIP frame <name> <n>` and `FLOURISH_STRIP RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: Math.max(760, 16 + 2 * (64 * win.pillScale + 6), 16 + 128 * win.themeScale + 112)
        implicitHeight: 148 + 44 * win.pillScale + 44 * win.themeScale
        visible: true
        color: Theme.surface

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property string mode: Quickshell.env("MODE") || "strip"
        readonly property int frames: Number(Quickshell.env("FRAMES") || 16)
        readonly property string only: Quickshell.env("ONLY") || ""
        readonly property real span: Number(Quickshell.env("SPAN") || 1)
        readonly property string set: Quickshell.env("SET") || ""
        readonly property real pillScale: Math.max(1, Number(Quickshell.env("PILLSCALE") || 1))
        readonly property real themeScale: Math.max(1, Number(Quickshell.env("THEMESCALE") || 1))

        // ---- stand-ins ----
        QtObject {
            id: mpd
            property bool connected: true
            property string playState: "play"
            property int songId: 1
        }
        QtObject {
            id: bellSvc
            property bool dnd: false
            property string holdReason: ""
            property string dotGroup: ""
            property var recs: ({})
            readonly property var store: QtObject {
                function get(uid) {
                    return bellSvc.recs[uid] || null;
                }
            }
            signal recordAdded(string uid)
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
            id: stocksSvc
            property var portfolio: ({ anyHeldOpen: true, dayPct: 1.23 })
            readonly property var daySpark: ({ v: [10, 10.4, 10.2, 10.9, 11.3, 11.1, 11.8, 12.0, 11.7, 12.3, 12.1, 12.6], base: 10 })
        }
        QtObject {
            id: stocksOwner
            readonly property var svc: stocksSvc
            property bool popupMine: false
            function toggle() {}
        }
        function stocks(live: bool, pct: real, style: string): void {
            stocksSvc.portfolio = { anyHeldOpen: live, dayPct: pct };
            bStocks.flourishStyle = style;
        }

        // the pill's stand-in service: the facts the pill reads
        AerialPillStand {
            id: netSvc
        }
        function setNet(via: string, bars: int, radio: bool, portal: bool): void {
            const wired = via === "wired" || via === "socket";
            netSvc.net({ radio: radio, connected: wired ? false : bars >= 0 && radio, bars: Math.max(0, bars), portal: portal,
                         wired: via === "wired", wiredDevice: wired, noWifi: wired });
        }
        function btModel(on: bool, connected: bool): var {
            return { on: on, connected: connected };
        }

        component Cell: Item {
            id: cell
            default property alias content: holder.data
            property real w: 64
            width: cell.w
            height: 44
            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }
            Item {
                id: holder
                anchors.fill: parent
            }
        }

        Row {
            x: 8
            y: 8
            spacing: 6
            Cell {
                id: cBell
                NotificationsBarButton {
                    id: bBell
                    owner: bellOwner
                    anchors.centerIn: parent
                }
            }
            Cell {
                id: cUpdate
                w: 120
                SystemUpdateIcon {
                    id: bUpdate
                    anchors.centerIn: parent
                    fontFamily: "Audiowide"
                    updatesAvailable: 12
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
                id: cSilicon
                w: 120
                SiliconBarButton {
                    id: bSilicon
                    anchors.centerIn: parent
                    fontFamily: "Audiowide"
                    liveMotion: false
                    percent: 81
                    profile: 1
                    gpuMode: 1
                }
            }
            Cell {
                id: cSparkle
                LlmBarButton {
                    id: bSparkle
                    anchors.centerIn: parent
                }
            }
            Cell {
                id: cNotes
                NotesBarButton {
                    id: bNotes
                    anchors.centerIn: parent
                }
            }
            Cell {
                id: cBridge
                BridgeBarButton {
                    id: bBridge
                    anchors.centerIn: parent
                    service: bridgeSvc
                    motion: false
                }
                // the bridge's service as the button reads it: no phone (raised), or one in reach (down), on Wi-Fi or the cable
                QtObject {
                    id: bridgeSvc
                    property bool ready: true
                    property int serial: 0
                    property var current: null
                    property var jobs: []
                    property var pairing: []
                    property bool casting: false
                    property string castKey: ""
                    signal acted(string key, string action, bool ok, string why)
                    function phone(link) {
                        bridgeSvc.current = link === "" ? null : { key: "kdc:a", present: true, link: link, mounts: {} };
                        bridgeSvc.serial++;
                    }
                }
            }
        }
        // the pills, a row of their own (PILLSCALE draws them larger)
        Row {
            x: 8
            y: 60
            spacing: 6
            Cell {
                id: cAudio
                w: 64 * win.pillScale
                height: 44 * win.pillScale
                AudioBarButton {
                    id: bAudio
                    scale: win.pillScale
                    anchors.centerIn: parent
                }
            }
            Cell {
                id: cNet
                w: 64 * win.pillScale
                height: 44 * win.pillScale
                AerialBarButton {
                    id: bNet
                    scale: win.pillScale
                    anchors.centerIn: parent
                    service: netSvc
                }
            }
        }
        // the theme button, a row of its own (THEMESCALE draws it larger)
        Row {
            x: 8
            y: 68 + 44 * win.pillScale
            Cell {
                id: cTheme
                w: 64 * win.themeScale
                height: 44 * win.themeScale
                ThemeBarButton {
                    id: bTheme
                    scale: win.themeScale
                    anchors.centerIn: parent
                }
            }
            Cell {
                id: cPano
                w: 64 * win.themeScale
                height: 44 * win.themeScale
                PanoramaBarButton {
                    id: bPano
                    scale: win.themeScale
                    anchors.centerIn: parent
                }
            }
            Cell {
                id: cStocks
                w: 100
                StocksBarButton {
                    id: bStocks
                    owner: stocksOwner
                    fontFamily: "Audiowide"
                    anchors.centerIn: parent
                }
            }
        }
        function audio(type: string, vol: real, muted: bool, micMuted: bool): void {
            bAudio.outputDeviceType = type;
            bAudio.outputVolume = vol;
            bAudio.outputMuted = muted;
            bAudio.inputMuted = micMuted;
        }
        function net(via: string, bars: int, radio: bool, portal: bool, airplane: bool): void {
            win.setNet(via, bars, radio, portal);
            if (airplane)
                netSvc.net({ radio: false, connected: false, airplane: true });
        }
        function pill(n, c, fl, f) {
            return { n: n, c: c, fl: fl, f: f, end: () => fl().ms, set: "pills" };
        }
        readonly property var pillStrips: [
            win.pill("spkhigh", cAudio, () => bAudio.outputFlourish, () => win.audio("speaker", 0.9, false, false)),
            win.pill("spkmed", cAudio, () => bAudio.outputFlourish, () => win.audio("speaker", 0.4, false, false)),
            win.pill("spklow", cAudio, () => bAudio.outputFlourish, () => win.audio("speaker", 0, false, false)),
            win.pill("spkmuted", cAudio, () => bAudio.outputFlourish, () => win.audio("speaker", 0, true, false)),
            win.pill("spkmutedhigh", cAudio, () => bAudio.outputFlourish, () => win.audio("speaker", 0.9, true, false)),
            win.pill("headphones", cAudio, () => bAudio.outputFlourish, () => win.audio("headphone", 0.5, false, false)),
            win.pill("headphonesmuted", cAudio, () => bAudio.outputFlourish, () => win.audio("headphone", 0.5, true, false)),
            win.pill("headset", cAudio, () => bAudio.outputFlourish, () => win.audio("headset", 0.5, false, false)),
            win.pill("mic", cAudio, () => bAudio.inputFlourish, () => win.audio("speaker", 0.9, false, false)),
            win.pill("micmuted", cAudio, () => bAudio.inputFlourish, () => win.audio("speaker", 0.9, false, true)),
            win.pill("wifi4", cNet, () => bNet.netFlourish, () => win.net("wifi", 4, true, false, false)),
            win.pill("wifi2", cNet, () => bNet.netFlourish, () => win.net("wifi", 2, true, false, false)),
            win.pill("wifi1", cNet, () => bNet.netFlourish, () => win.net("wifi", 1, true, false, false)),
            win.pill("wifisearch", cNet, () => bNet.netFlourish, () => win.net("wifi", -1, true, false, false)),
            win.pill("wifioff", cNet, () => bNet.netFlourish, () => win.net("wifi", -1, false, false, false)),
            win.pill("wifialert", cNet, () => bNet.netFlourish, () => win.net("wifi", 2, true, true, false)),
            win.pill("wired", cNet, () => bNet.netFlourish, () => win.net("wired", -1, true, false, false)),
            win.pill("wiredoff", cNet, () => bNet.netFlourish, () => win.net("socket", -1, true, false, false)),
            win.pill("plane", cNet, () => bNet.netFlourish, () => win.net("wifi", -1, false, false, true)),
            win.pill("bluetooth", cNet, () => bNet.btFlourish, () => netSvc.setBt(win.btModel(true, false))),
            win.pill("btconnected", cNet, () => bNet.btFlourish, () => netSvc.setBt(win.btModel(true, true))),
            win.pill("btoff", cNet, () => bNet.btFlourish, () => netSvc.setBt(win.btModel(false, false)))
        ]

        // ---- the strips: a held clock written frame by frame ----
        // each: the cell, the clock, its run's length (ms), its kicks, and what to set first
        function stk(n, live, pct, style) {
            return { n: n, c: cStocks, fl: () => bStocks.flourish, f: () => win.stocks(live, pct, style), end: () => bStocks.flourish.ms, frames: 28 };
        }
        // the panorama's: so many displays in use, mirroring or not
        function pano(n, panes, mirroring) {
            return {
                n: n, c: cPano, fl: () => bPano.flourish, set: "pano", frames: 22, end: () => bPano.flourish.ms,
                settleMs: 700, f: () => {
                    bPano.panes = panes;
                    bPano.mirroring = mirroring;
                }
            };
        }
        readonly property var panoStrips: [
            win.pano("pano1", 1, false), win.pano("pano2", 2, false), win.pano("pano3", 3, false), win.pano("pano4", 4, false),
            win.pano("panomirror", 1, true), win.pano("pano2mirror", 2, true), win.pano("pano3mirror", 3, true), win.pano("pano4mirror", 4, true)
        ]
        readonly property var strips: win.ownStrips.concat(win.pillStrips, win.panoStrips)
        readonly property var ownStrips: [
            { n: "bell", c: cBell, fl: () => bBell.flourish, end: () => bBell.flourishMs },
            { n: "bellsleep", c: cBell, fl: () => bBell.flourish, end: () => bBell.flourishMs, f: () => bellSvc.dnd = true },
            { n: "bellburst", c: cBell, fl: () => bBell.flourish, kicks: [0, 180, 300], end: () => 300 + bBell.flourishMs, frames: 24 },
            { n: "box", c: cUpdate, fl: () => bUpdate.flourish, end: () => bUpdate.flourishMs, frames: 20 },
            { n: "player", c: cPlayer, fl: () => bPlayer.flourishClock, end: () => bPlayer.windupMs + bPlayer.coastMs },
            { n: "leaf", c: cSilicon, fl: () => bSilicon.face.flourishItem.glyphClock, f: () => bSilicon.profile = 0, end: () => bSilicon.face.flourishItem.glyphClock.ms },
            { n: "scales", c: cSilicon, fl: () => bSilicon.face.flourishItem.glyphClock, f: () => bSilicon.profile = 1, end: () => bSilicon.face.flourishItem.glyphClock.ms },
            { n: "bolt", c: cSilicon, fl: () => bSilicon.face.flourishItem.glyphClock, f: () => bSilicon.profile = 2, end: () => bSilicon.face.flourishItem.glyphClock.ms },
            { n: "feather", c: cSilicon, fl: () => bSilicon.face.gpuItem.flourishClock, f: () => win.gpu(0, false), end: () => bSilicon.face.gpuItem.flourishClock.ms, frames: 24 },
            { n: "bulb", c: cSilicon, fl: () => bSilicon.face.gpuItem.flourishClock, f: () => win.gpu(1, true), end: () => bSilicon.face.gpuItem.flourishClock.ms, frames: 20 },
            { n: "bulbidle", c: cSilicon, fl: () => bSilicon.face.gpuItem.flourishClock, f: () => win.gpu(1, false), end: () => bSilicon.face.gpuItem.flourishClock.ms, frames: 20 },
            { n: "layers", c: cSilicon, fl: () => bSilicon.face.gpuItem.flourishClock, f: () => win.gpu(2, true), end: () => bSilicon.face.gpuItem.flourishClock.ms, frames: 20 },
            { n: "fire", c: cSilicon, fl: () => bSilicon.face.gpuItem.flourishClock, f: () => win.gpu(3, true), end: () => bSilicon.face.gpuItem.flourishClock.ms, frames: 24 },
            { n: "notes", c: cNotes, fl: () => bNotes.flourish, end: () => bNotes.flourishMs, frames: 26 },
            { n: "sparkle", c: cSparkle, fl: () => bSparkle.flourish, end: () => bSparkle.flourish.ms, frames: 26 },
            { n: "theme", c: cTheme, fl: () => bTheme.flourish, end: () => bTheme.flourish.ms, frames: 26 },
            { n: "bridge", c: cBridge, fl: () => bBridge.flourish, end: () => bBridge.flourish.ms, frames: 26 },
            { n: "bridgedown", c: cBridge, fl: () => bBridge.flourish, f: () => bridgeSvc.phone("wifi"), end: () => bBridge.flourish.ms, frames: 26 },
            { n: "bridgecable", c: cBridge, fl: () => bBridge.flourish, f: () => bridgeSvc.phone("usb"), why: "cable", end: () => bBridge.flourish.ms, frames: 20 },
            win.stk("stocks_gain", true, 1.23, "both"),
            win.stk("stocks_loss", true, -0.87, "both"),
            win.stk("stocks_closed", false, 0, "both"),
            win.stk("stocks_gain_ripple", true, 1.23, "ripple"),
            win.stk("stocks_gain_arrow", true, 1.23, "arrow")
        ]

        property int _s: -1
        property int _f: 0
        property int _grabbed: 0
        property int _wanted: 0
        property var _clock: null
        property var _story: null

        // the GPU mode's glyph, its card in use (lit) or idle (faded)
        function gpu(mode: int, inUse: bool): void {
            bSilicon.gpuMode = mode;
            bSilicon.gpuInUse = inUse;
        }
        function resetAll() {
            bellSvc.dnd = false;
            win.gpu(1, false);
            bUpdate.running = false;
            win.audio("speaker", 0.9, false, false);
            win.net("wifi", 4, true, false, false);
            netSvc.setBt(win.btModel(true, false));
            win.stocks(true, 1.23, "both");
            bridgeSvc.phone("");
        }

        function nextStrip() {
            if (win._clock) {
                win._clock.stop();
                win._clock.held = false;
                win._clock = null;
            }
            win._s++;
            if (win._s >= win.strips.length)
                return win.finish();
            win.resetAll();
            const st = win.strips[win._s];
            if ((win.only !== "" && st.n !== win.only) || (win.set !== "" && st.set !== win.set))
                return win.nextStrip();
            if (st.f)
                st.f();
            settle.interval = st.settleMs || 400;
            // a turn for the bindings (a profile's glyph, the dnd glyph) before the clock is held
            settle.after = () => {
                const fl = st.fl();
                fl.held = true;
                fl.play(st.why || "strip");
                if (st.kicks)
                    fl.kicks = st.kicks.slice();
                win._clock = fl;
                win._f = 0;
                win.stripFrame();
            };
            settle.restart();
        }
        function stripFrame() {
            const st = win.strips[win._s];
            const n = win.only !== "" ? win.frames : (st.frames || win.frames);
            if (win._f >= n)
                return win.nextStrip();
            win._clock.t = st.end() * win.span * win._f / (n - 1);
            win._wanted++;
            const name = st.n + "_" + String(win._f).padStart(2, "0");
            grabLater.after = () => st.c.grabToImage(r => {
                r.saveToFile(win.outDir + "/" + name + ".png");
                win._grabbed++;
                console.log("FLOURISH_STRIP frame " + st.n + " " + win._f);
                win._f++;
                win.stripFrame();
            });
            grabLater.restart();
        }

        // ---- the storyboard: the system update's per-step sequence (a proposal) ----
        // In a run the glyph stands in the assembly's pill, which leaves it ~4 px above the box and the pill's rounded end to its
        // left: the lid cannot be tossed there. It SLIDES: `s` font units to the left, then rocks on the box's left rim corner
        // `deg` up (its right end up, its left end down over the pill's end), lifted `lift`: as compose's {dx, dy, rot}.
        function slide(s, deg, lift) {
            const m = O.turn(945 - s, 1264 + lift, 118, 1087 + lift, deg * Math.PI / 180);
            return { dx: m[0] - 945, dy: m[1] - 1264, rot: deg };
        }
        // the run's one paper is b, under the open right end (a would stand under the lid)
        function pose(lid, bf, box) {
            return { lid: lid, a: { f: 0, rot: 0 }, b: { f: bf, rot: 7 * Math.min(1, bf) }, box: box || null };
        }
        readonly property var rest: ({ dx: 0, dy: 0, rot: 0 })
        readonly property var open: win.slide(900, 9, 30)
        readonly property var opening: win.slide(980, 12, 40)
        // each step: what the icon shows (mark, percent) and two frames -- the action mid-way, and the pose held for the step
        readonly property var story: [
            { n: "0_idle", run: false, mid: win.pose(win.rest, 0), held: win.pose(win.rest, 0) },
            { n: "1_sync", mark: "download", pct: 3, mid: win.pose({ dx: 0, dy: 300, rot: 2 }, 0), held: win.pose({ dx: 0, dy: 190, rot: 0 }, 0) },
            { n: "2_resolve", mark: "download", pct: 8, mid: win.pose(win.opening, 0), held: win.pose(win.open, 0) },
            { n: "3_sources", mark: "download", pct: 14, mid: win.pose(win.open, 0.65), held: win.pose(win.open, 0.45) },
            { n: "4_download", mark: "download", pct: 38, mid: win.pose(win.open, 1.15), held: win.pose(win.open, 1) },
            { n: "5_install", mark: "disk", pct: 62, mid: win.pose(win.open, 0.3), held: win.pose(win.open, 0) },
            { n: "6_hooks", mark: "cog", pct: 84, mid: win.pose({ dx: -120, dy: 90, rot: 0 }, 0, { dx: 0, dy: 0, rot: -5 }), held: win.pose({ dx: 0, dy: 90, rot: 0 }, 0) },
            { n: "7_aur", mark: "cog", pct: 90, mid: win.pose(win.opening, 0.95), held: win.pose(win.open, 0.8) },
            { n: "8_done", end: "ok", mark: "download", pct: 100, mid: win.pose({ dx: 0, dy: 60, rot: 0 }, 0), held: win.pose(win.rest, 0) },
            { n: "9_ask", mark: "ask", pct: 40, mid: win.pose(win.open, 1, { dx: 0, dy: 0, rot: -10 }), held: win.pose(win.open, 1, { dx: 0, dy: 0, rot: -7 }) },
            { n: "10_fail", mark: "fail", pct: 55, mid: win.pose({ dx: 180, dy: 160, rot: -8 }, 0.2), held: win.pose({ dx: 260, dy: -40, rot: -12 }, 0) }
        ]
        function findGlyph(item) {
            for (let i = 0; i < item.children.length; ++i) {
                const c = item.children[i];
                if (c.objectName === "updateGlyph")
                    return c;
                const d = win.findGlyph(c);
                if (d)
                    return d;
            }
            return null;
        }
        property int _k: -1
        property int _which: 0
        function nextStory() {
            win._k++;
            if (win._k >= win.story.length * 2)
                return win.finish();
            const step = win.story[Math.floor(win._k / 2)];
            const held = win._k % 2 === 1;
            bUpdate.mark = step.mark || "download";
            bUpdate.percent = step.pct || 0;
            // the run's end: the assembly stays a moment on 100 and the check (the icon's own end hold)
            bUpdate.outcome = step.end || "";
            bUpdate.running = step.run !== false && !step.end;
            const g = win.findGlyph(bUpdate);
            const st = held ? step.held : step.mid;
            g.posing = true;
            g.parts = Archive.compose(st, null, g.pixelSize, g.origin.x, g.origin.y);
            win._wanted++;
            const name = "story_" + step.n + (held ? "_held" : "_mid");
            // the run's assembly morphs in (220 ms): the first step waits for it, the rest are already there
            settle.after = () => cUpdate.grabToImage(r => {
                r.saveToFile(win.outDir + "/" + name + ".png");
                win._grabbed++;
                console.log("FLOURISH_STRIP frame " + name);
                win.nextStory();
            });
            settle.restart();
        }

        Timer {
            id: settle
            property var after: null
            interval: 400
            onTriggered: settle.after()
        }
        Timer {
            id: grabLater
            property var after: null
            interval: 30
            onTriggered: grabLater.after()
        }

        // ---- the film: live clocks, the pointer through QtTest on the window, a grab per frame ----
        TestCase {
            id: tc
            name: "flourishfilm"
            when: false
        }
        function centre(item, dx) {
            const p = item.mapToItem(win.contentItem, item.width / 2 + (dx || 0), item.height / 2);
            return Qt.point(Math.round(p.x), Math.round(p.y));
        }
        function move(p) {
            tc.mouseMove(win.contentItem, p.x, p.y);
        }
        property int _sn: 0
        function arrive() {
            bellSvc.recs[++win._sn] = { arrivedMs: Date.now() };
            bellSvc.recordAdded(String(win._sn));
        }
        // each glyph: its cell and button; each act: what to do, then how many frames to grab under a phase name
        // `rest`: the glyph's clock -- the resting phase grabs until it has stopped (and four frames more), so the re-entry
        // comes after the play (a re-entry mid-play is ignored: that is the rule, and the burst shows it)
        function filmOf(name, cell, btn, clock) {
            return [
                { n: name, c: cell, ph: "rest", act: () => win.move(Qt.point(win.width - 3, 3)), grabs: 4 },
                { n: name, c: cell, ph: "entry", act: () => win.move(win.centre(btn)), grabs: 6 },
                { n: name, c: cell, ph: "motion", act: () => win.move(win.centre(btn, 2)), grabs: 44 },
                { n: name, c: cell, ph: "resting", act: () => {}, grabs: 4, until: clock },
                { n: name, c: cell, ph: "away", act: () => win.move(Qt.point(win.width - 3, 3)), grabs: 2 },
                { n: name, c: cell, ph: "again", act: () => { win.move(win.centre(btn)); win.move(win.centre(btn, 2)); }, grabs: 16 }
            ];
        }
        readonly property var film: win.filmOf("bell", cBell, bBell, () => bBell.flourish)
            .concat(win.filmOf("box", cUpdate, bUpdate, () => bUpdate.flourish))
            .concat(win.filmOf("player", cPlayer, bPlayer, () => bPlayer.flourishClock))
            .concat(win.filmOf("silicon", cSilicon, bSilicon, () => bSilicon.face.flourishItem.glyphClock))
            .concat(win.filmOf("notes", cNotes, bNotes, () => bNotes.flourish))
            .concat(win.filmOf("sparkle", cSparkle, bSparkle, () => bSparkle.flourish))
            .concat(win.filmOf("theme", cTheme, bTheme, () => bTheme.flourish))
            .concat(win.filmOf("bridge", cBridge, bBridge, () => bBridge.flourish))
            .concat([
                { n: "burst", c: cBell, ph: "rest", act: () => win.move(Qt.point(win.width - 3, 3)), grabs: 30 },
                { n: "burst", c: cBell, ph: "n1", act: () => win.arrive(), grabs: 4 },
                { n: "burst", c: cBell, ph: "n2", act: () => win.arrive(), grabs: 4 },
                { n: "burst", c: cBell, ph: "n3", act: () => win.arrive(), grabs: 52 }
            ])
        property int _a: -1
        property int _g: 0
        property int _fn: 0
        function nextAct() {
            win._a++;
            if (win._a >= win.film.length)
                return win.finish();
            const a = win.film[win._a];
            if (win._a > 0 && win.film[win._a - 1].n !== a.n)
                win._fn = 0;
            a.act();
            win._g = 0;
            win.filmFrame();
        }
        function filmFrame() {
            const a = win.film[win._a];
            if (win._g >= a.grabs && !(a.until && a.until().playing))
                return win.nextAct();
            if (a.until && a.until().playing)
                win._g = 0;
            win._wanted++;
            const name = "film_" + a.n + "_" + String(win._fn).padStart(3, "0") + "_" + a.ph;
            a.c.grabToImage(r => {
                r.saveToFile(win.outDir + "/" + name + ".png");
                win._grabbed++;
                win._g++;
                win._fn++;
                win.filmFrame();
            });
        }

        function finish() {
            console.log("FLOURISH_STRIP RESULT " + (win._grabbed === win._wanted && win._grabbed > 0 ? "PASS" : "FAIL") + " frames=" + win._grabbed + "/" + win._wanted);
            quitTimer.start();
        }
        Timer {
            id: quitTimer
            interval: 50
            onTriggered: Qt.quit()
        }
        Timer {
            running: true
            interval: 1200
            onTriggered: {
                if (win.outDir === "") {
                    console.log("FLOURISH_STRIP RESULT FAIL (no OUT_DIR)");
                    quitTimer.start();
                } else if (win.mode === "film") {
                    win.nextAct();
                } else if (win.mode === "story") {
                    win.nextStory();
                } else {
                    win.nextStrip();
                }
            }
        }
    }
}
