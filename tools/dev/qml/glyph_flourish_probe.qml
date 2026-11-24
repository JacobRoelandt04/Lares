pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/bar/player"
import "modules/bar/system_update/components"
import "modules/notifications"
import "modules/notifications/data"
import "modules/notes"
import "modules/bar/llm"
import "modules/notes/parts/NotePeelPose.js" as NotePose
import "modules/bar/llm/parts/SparklePose.js" as SparklePose
import "modules/silicon"
import "modules/weather"
import "modules/stocks"
import "modules/stocks/parts/StocksPose.js" as StocksPose
import "modules/common/glyphs"
import "modules/shell"
import "modules/bridge"
import "modules/bridge/bar/BridgePose.js" as BridgePose
import "modules/bridge/bar/BridgeTraffic.js" as BridgeTraffic
import "modules/panorama/bar"
import "modules/panorama/bar/PanoramaPanes.js" as PanoPose
import "modules/shell/parts/SwatchPose.js" as SwatchPose
import "modules/silicon/bar/SiliconGpuPose.js" as GpuPose
import "modules/silicon/bar/SiliconGlyphPose.js" as ProfilePose

// =============================================================================
// glyph_flourish_probe.qml -- the bar glyphs' flourish contract on the real buttons (GlyphFlourish), with live clocks:
//
//   rest      after load nothing plays and no flourish clock's animation runs (offscreen frames are no clock: every Timer start
//             renders one and an animation that changes nothing stops rendering after ~0.7 s, so the gate is the clocks' state)
//   entry     a pointer that comes onto the bell and does not move plays nothing; its first motion plays it ONCE; motions
//             while it plays and after it, with no leave, play nothing more; a leave and a new entry with motion play it again
//   slide     the bell slid under a resting pointer plays nothing (no motion in the window's frame)
//   burst     three new notifications in 120 ms: ONE run, three kicks, its clock never goes back, it ends `ms` after the last
//   undo      a record that comes back with an old arrival stamp (an undo) plays nothing
//   dnd       a new notification under do-not-disturb plays the bell (bell-sleep posed)
//   real      the REAL NotificationService (no server, no bus, nothing kept, do not disturb so nothing sounds): a post rings
//             the bell; a clear and its undo bring the record back through the same signal and ring nothing
//   box       the archive box plays on an idle hover and not on a hover during a run
//   player    the vinyl plays on hover; a new song while it spins starts it over ("song")
//   silicon   EACH GLYPH OF THE PILL PLAYS FOR A POINTER ON IT, and only it: on the figure neither plays; on the profile glyph only
//             the profile's; on the GPU mode's glyph only the GPU's, once per entry; the same on a side bar, where the face
//             stands counter-rotated in its button (the zones are found in the face's frame)
//   profile   the profile's three flourishes (SiliconGlyphPose): both ends are the font's outline and the motion dies into it; the
//             scales' weight flies one way over the pivot and the beam stands tipped under it; the bolt's ink sinks out and the
//             charge comes in from above and lands fat and low
//   gpu       the GPU mode's four flourishes (SiliconGpuPose): each one's first and last instant are the font's own outline
//             with nothing thrown; a millisecond inside either end it is still that picture (nothing has jumped) and nothing
//             is thrown yet; mid-run the glyph has moved, the bulb's rays and the fire's embers are out, and no ember ever
//             lies over the flame's ink
//   weather   the ink icon plays on hover, for its own length (the icon's beats), its outline posed while it does; with the
//             carved set chosen (no flourish) a hover plays nothing
//   notes     the note's peel (NotePeelPose): its first and its last instant are the font's own outline (path for path) with NO
//             sheet underneath at the first (at rest the icon is one clean note) and nothing left of the old sheet at the last;
//             between them the sheet underneath is there and paler; a hover plays it once and a second ask while it plays is
//             ignored. OUT_DIR: grabs of the glyph at rest (the Text), posed at the first and at the last instant, which the
//             runner compares
//   sparkle   the chat star's flourish (SparklePose): its first and its last instant are the font's own outline, corner for corner
//             (the quarter turn is counted off), with no spark out at either; between them both sparks are out; a hover plays
//             the real button once
//   swatch    the theme button's flourish (SwatchPose) on its glyph, the filled swatch: its first and its last instant are the
//             font's own outline, path for path, all three cards; mid-turn the book is shut (no card behind shows) and on
//             landing the fan is wider than it rests; at EVERY sample no card behind lies over the card in front or its rivet,
//             and the card in front keeps its own ink there (inked, with a hole for a rivet): the swatch is never filled in.
//             The real button: the filled glyph, a hover plays it once, it holds still (the same path) through a theme
//             crossfade and ends at rest; and at the script's end a switch to dark KEEPS the filled glyph (one glyph in both
//             modes)
//   pano      the panorama button's pose (PanoramaPanes): ONE monitor of a constant size, its screen cut into the displays by gaps
//             (one to three columns, the "+" cut into the last, the mirror mark into the first), windows tiled on every screen
//             with no mark. The ink's box is the same (1 font unit) for every count at rest and through the count's spring, the
//             "+" and the mirror's ease, and never exceeded at any sample of the deal flourish; the rest picture is exactly what a
//             run's first and last instant emit (a millisecond inside either end within 0.15 px); the run's length is derived
//             from its parts and EVERY state's run differs from its rest. THE WINDOWS STAND AT REST (three on a lone screen, two
//             on a narrower one, none on a marked one, every ring and tile wide enough to see) and are gone in the middle of the
//             run, the screens solid and a mark still there; no hole ever overlaps another, a tile is inside its ring, a ring
//             inside its screen; the count's spring moves the windows and never swaps them. The real button plays it on a hover
//             (group "panorama") and on the host's deal(), refused while it plays
//   bridge    the bridge button's drawbridge (BridgePose, BridgeTraffic): down it is the font's own outline; raised, the leaves part
//             and are bare: four strokes with a pixel at 15 px between any two, kept through its salute, nothing popping on the way;
//             path for path (RETURNED, not computed); a millisecond inside either end it is still that picture (within 0.05 px:
//             nothing has jumped); at EVERY sample the emitted path is the phone turned about its own middle line (its centre
//             stays on the rest's, its width never exceeds the rest's, it comes down to an edge and both the screened front and
//             the slab back are shown, it rises no higher than its hop). The real button: the four inks (faint with no device,
//             muted over Wi-Fi, the wired hue on the cable, the accent in use), a hover plays it once, the first line a service
//             delivers plays nothing, a device that arrives plays it ("arrive"), one that comes onto the cable plays it
//             ("cable"), one that goes back to Wi-Fi or another device that becomes current (already there) plays nothing
//   theme     a play holds still while the theme crossfades and finishes after it (Theme's crossfade state is forced: its
//             private _switching and _hosted, the two facts `crossfading` is made of)
//
// The pointer is QtTest's on the WINDOW (the buttons' own MouseAreas answer). Prints `FLOURISH_PROBE <check> ok|FAIL ...` and
// `FLOURISH_PROBE RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 580
        implicitHeight: 200
        visible: true
        color: Theme.surface

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
            property int _n: 0
            // a new record, or (ageMs) one an undo brings back
            function arrive(ageMs) {
                const uid = "r" + (++bellSvc._n);
                const r = Object.assign({}, bellSvc.recs);
                r[uid] = { uid: uid, arrivedMs: Date.now() - (ageMs || 0) };
                bellSvc.recs = r;
                bellSvc.recordAdded(uid);
            }
        }
        NotificationService {
            id: realSvc
            serverEnabled: false
            registerOnBus: false
            persist: false
            liveSignals: false
            ipcEnabled: false
            configPath: ""
            sleepWatcher: null
        }
        QtObject {
            id: realOwner
            readonly property var service: realSvc
            property bool popupMine: false
            property bool laneHeld: false
            readonly property var style: null
            function toggle() {}
        }
        // the bridge's service as the button reads it
        QtObject {
            id: bridgeSvc
            property bool ready: false
            property int serial: 0
            property var current: null
            property var jobs: []
            property var pairing: []
            signal acted(string key, string action, bool ok, string why)
        }
        function phoneDevice(key, link, mount) {
            return { key: key, present: link !== "none", link: link,
                mounts: { usb: { state: "unmounted" }, wifi: { state: mount ? "mounted" : "unmounted" } } };
        }
        // a line from the service: what it says, then the serial that says it is whole
        function phoneLine(cur, jobs, pairing) {
            bridgeSvc.current = cur;
            bridgeSvc.jobs = jobs || [];
            bridgeSvc.pairing = pairing || [];
            bridgeSvc.ready = true;
            bridgeSvc.serial++;
        }
        QtObject {
            id: bellOwner
            readonly property var service: bellSvc
            property bool popupMine: false
            property bool laneHeld: false
            readonly property var style: null
            function toggle() {}
        }

        Item {
            id: row
            x: 10
            y: 30
            width: 500
            height: 50
            NotificationsBarButton {
                id: bBell
                owner: bellOwner
                x: 0
                y: 10
            }
            NotificationsBarButton {
                id: bReal
                owner: realOwner
                x: 440
                y: 10
            }
            SystemUpdateIcon {
                id: bUpdate
                x: 80
                y: 10
                fontFamily: "Audiowide"
                updatesAvailable: 12
            }
            PlayerBarButton {
                id: bPlayer
                player: mpd
                x: 240
                y: 10
            }
            WeatherBarButton {
                id: bWeather
                x: 150
                y: 8
                service: QtObject {
                    property var model: ({ current: { kind: "rain", intensity: 1, night: false, shower: true, temp: 12 }, warnings: [] })
                    property var config: ({ units: ({}) })
                }
            }
            NotesBarButton {
                id: bNotes
                x: 40
                y: 10
            }
            LlmBarButton {
                id: bLlm
                // above the row: nothing of the row's lies over it
                x: 200
                y: -26
            }
            ThemeBarButton {
                id: bTheme
                // above the row too, clear of the star
                x: 280
                y: -26
            }
            BridgeBarButton {
                id: bBridge
                service: bridgeSvc
                // above the row: clear of the star and the swatch
                x: 360
                y: -26
            }
            PanoramaBarButton {
                id: bPano
                // above the row: clear of the star, the swatch and the phone
                x: 440
                y: -26
            }
            SiliconBarButton {
                id: bSilicon
                x: 320
                y: 6
                fontFamily: "Audiowide"
                liveMotion: false
                percent: 81
                profile: 1
            }
            // the same button as a side bar holds it: the bar's frame turned a quarter, the face standing upright in it
            Item {
                x: 530
                y: 25
                rotation: 90
                SiliconBarButton {
                    id: bSiliconV
                    x: -width / 2
                    y: -height / 2
                    width: implicitWidth
                    height: implicitHeight
                    fontFamily: "Audiowide"
                    liveMotion: false
                    vertical: true
                    barRotation: 90
                    percent: 81
                    profile: 1
                }
            }
        }

        // ---- the stocks button: three faces (a gain, a loss, closed), each on its own stand-in service ----
        component StkSvc: QtObject {
            property var portfolio: ({ anyHeldOpen: true, dayPct: 1.23 })
            readonly property var daySpark: ({ v: [10, 10.4, 10.2, 10.9, 11.3, 11.1, 11.8, 12.0, 11.7, 12.3, 12.1, 12.6], base: 10 })
        }
        component StkOwner: QtObject {
            property var svc: null
            property bool popupMine: false
            function toggle() {}
        }
        StkSvc {
            id: gainSvc
        }
        StkSvc {
            id: lossSvc
            portfolio: ({ anyHeldOpen: true, dayPct: -0.87 })
        }
        StkSvc {
            id: closedSvc
            portfolio: ({ anyHeldOpen: false, dayPct: 0 })
        }
        StkOwner {
            id: gainOwner
            svc: gainSvc
        }
        StkOwner {
            id: lossOwner
            svc: lossSvc
        }
        StkOwner {
            id: closedOwner
            svc: closedSvc
        }
        Item {
            x: 10
            y: 120
            StocksBarButton {
                id: bStkGain
                // a bar's height: the arrow has the room above the line it has on the desktop
                height: 40
                owner: gainOwner
                fontFamily: "Audiowide"
                x: 0
            }
            StocksBarButton {
                id: bStkLoss
                // a bar's height: the arrow has the room above the line it has on the desktop
                height: 40
                owner: lossOwner
                fontFamily: "Audiowide"
                x: 150
            }
            StocksBarButton {
                id: bStkClosed
                // a bar's height: the arrow has the room above the line it has on the desktop
                height: 40
                owner: closedOwner
                fontFamily: "Audiowide"
                x: 300
            }
        }
        Connections {
            target: bStkGain.flourish
            function onPlayed(why) {
                win.note("stocksGain", why);
            }
        }
        Connections {
            target: bStkLoss.flourish
            function onPlayed(why) {
                win.note("stocksLoss", why);
            }
        }
        Connections {
            target: bStkClosed.flourish
            function onPlayed(why) {
                win.note("stocksClosed", why);
            }
        }
        function find(item, name) {
            if (item.objectName === name)
                return item;
            const kids = item.children;
            for (let i = 0; i < kids.length; i++) {
                const f = win.find(kids[i], name);
                if (f)
                    return f;
            }
            return null;
        }
        // how far the sparkline's drawn points stand from their placed ones: [min dy, max dy] (px), and whether the warp is bound
        function stkDy(spark) {
            let lo = 0, hi = 0;
            const runs = spark._runs, placed = spark._placed;
            for (let a = 0; a < runs.length; a++)
                for (let i = 0; i < runs[a].length; i++) {
                    const d = runs[a][i].y - placed[a][i].y;
                    lo = Math.min(lo, d);
                    hi = Math.max(hi, d);
                }
            return [lo, hi];
        }
        // a HELD play of one face, sampled: what the drawn line, the arrow, the dots and the width did
        function stkRun(btn, svc, live, pct, style) {
            svc.portfolio = { anyHeldOpen: live, dayPct: pct };
            btn.flourishStyle = style;
            const fl = btn.flourish;
            const lineS = win.find(btn, live ? "stocksSpark" : "stocksSkelSpark");
            const otherS = win.find(btn, live ? "stocksSkelSpark" : "stocksSpark");
            const arrow = win.find(btn, "stocksArrow");
            const dots = [0, 1, 2].map(i => win.find(btn, "stocksDot" + i));
            const r = { lo: 0, hi: 0, arrows: 0, y0: null, y1: null, inside: true, width: true, other: true, dotLo: 0, dotHi: 0, peaks: [-1, -1, -1], first: null, last: null, life: 0 };
            fl.held = true;
            fl.play("probe");
            const life = fl.ms;
            r.life = life;
            const w0 = btn.implicitWidth;
            const N = 120;
            const best = [0, 0, 0];
            for (let i = 0; i <= N; i++) {
                fl.t = life * i / N;
                const d = win.stkDy(lineS);
                if (i === 0)
                    r.first = d.slice();
                if (i === N)
                    r.last = d.slice();
                r.lo = Math.min(r.lo, d[0]);
                r.hi = Math.max(r.hi, d[1]);
                if (btn.implicitWidth !== w0)
                    r.width = false;
                if (otherS.warp !== null)
                    r.other = false;
                if (arrow.visible) {
                    r.arrows++;
                    if (r.y0 === null)
                        r.y0 = arrow.y;
                    r.y1 = arrow.y;
                    if (arrow.y < 0 || arrow.y + arrow.height > btn.height)
                        r.inside = false;
                }
                for (let k = 0; k < 3; k++) {
                    const h = dots[k] ? dots[k].hop : 0;
                    r.dotLo = Math.min(r.dotLo, h);
                    r.dotHi = Math.max(r.dotHi, h);
                    if (h < best[k]) {
                        best[k] = h;
                        r.peaks[k] = i;
                    }
                }
                if (i === 70 && live) {
                    // a fetch that turns the day over mid-play: the lump stays what it was
                    svc.portfolio = { anyHeldOpen: true, dayPct: -pct };
                }
            }
            fl.stop();
            fl.held = false;
            svc.portfolio = { anyHeldOpen: live, dayPct: pct };
            return r;
        }
        function stkAtRest(btn) {
            const a = win.find(btn, "stocksSpark"), b = win.find(btn, "stocksSkelSpark");
            return a.warp === null && b.warp === null && !btn.flourish.playing && !btn.flourish._run.running;
        }

        TestCase {
            id: tc
            name: "flourishprobe"
            when: false
        }

        // ---- the record: plays per clock, the bell clock's t over the burst, frames ----
        property var plays: ({ bell: [], real: [], box: [], player: [], silicon: [], gpu: [], siliconV: [], gpuV: [], weather: [], notes: [], llm: [], theme: [], bridge: [], panorama: [], stocksGain: [], stocksLoss: [], stocksClosed: [] })
        Connections {
            target: bTheme.flourish
            function onPlayed(why) {
                win.note("theme", why);
            }
        }
        // ---- the swatch's judge: is (x, y) inked by these contours under the winding rule (their on-curve points' polygons) ----
        function swatchWinding(contours, x, y) {
            let w = 0;
            for (const c of contours) {
                for (let i = 0; i < c.length; ++i) {
                    const a = c[i], b = c[(i + 1) % c.length];
                    const x0 = a[a.length - 2], y0 = a[a.length - 1], x1 = b[b.length - 2], y1 = b[b.length - 1];
                    if ((y0 <= y) !== (y1 <= y) && x0 + (y - y0) * (x1 - x0) / (y1 - y0) > x)
                        w += y1 > y0 ? 1 : -1;
                }
            }
            return w;
        }
        function swatchMiddle(c) {
            let x = 0, y = 0;
            for (const sg of c) {
                x += sg[sg.length - 2];
                y += sg[sg.length - 1];
            }
            return [x / c.length, y / c.length];
        }
        // over a whole run of `key`: how many samples have a card behind over the front card's middle or its rivet, how many have
        // the front card's own ink wrong there (it is inked, its rivet a hole), the widest fan
        function swatchRun(key) {
            const L = SwatchPose.LIFE;
            let over = 0, style = 0, wide = 0, shut = 0;
            for (let i = 0; i <= 160; ++i) {
                const st = SwatchPose.state(key, L * i / 160, L, null);
                const f = SwatchPose.fan(key, st);
                const front = f[2];
                let big = front[0], rivet = front[0];
                for (const c of front) {
                    if (c.length > big.length)
                        big = c;
                    if (c.length === 9)
                        rivet = c;
                }
                const m = win.swatchMiddle(big), r = win.swatchMiddle(rivet);
                if (win.swatchWinding(f[0], m[0], m[1]) !== 0 || win.swatchWinding(f[1], m[0], m[1]) !== 0
                        || win.swatchWinding(f[0], r[0], r[1]) !== 0 || win.swatchWinding(f[1], r[0], r[1]) !== 0)
                    over++;
                if (win.swatchWinding(front, m[0], m[1]) === 0 || win.swatchWinding(front, r[0], r[1]) !== 0)
                    style++;
                wide = Math.max(wide, st.openMid, st.openBack);
                if (f[0].length === 0 && f[1].length === 0)
                    shut++;
            }
            return { over: over, style: style, wide: wide, shut: shut };
        }
        Connections {
            target: bBridge.flourish
            function onPlayed(why) {
                win.note("bridge", why);
            }
        }
        Connections {
            target: bPano.flourish
            function onPlayed(why) {
                win.note("panorama", why);
            }
        }
        Connections {
            target: bLlm.flourish
            function onPlayed(why) {
                win.note("llm", why);
            }
        }
        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        function grab(item, name) {
            if (win.outDir !== "")
                item.grabToImage(r => r.saveToFile(win.outDir + "/" + name + ".png"));
        }
        Connections {
            target: bNotes.flourish
            function onPlayed(why) {
                win.note("notes", why);
            }
        }
        function note(k, why) {
            win.plays[k].push(why);
        }
        Connections {
            target: bBell.flourish
            function onPlayed(why) {
                win.note("bell", why);
            }
        }
        Connections {
            target: bReal.flourish
            function onPlayed(why) {
                win.note("real", why);
            }
        }
        Connections {
            target: bUpdate.flourish
            function onPlayed(why) {
                win.note("box", why);
            }
        }
        Connections {
            target: bPlayer.flourishClock
            function onPlayed(why) {
                win.note("player", why);
            }
        }
        Connections {
            target: bSilicon.face.flourishItem
            function onPlayed(why) {
                win.note("silicon", why);
            }
        }
        Connections {
            target: bSilicon.face.gpuItem.flourishClock
            function onPlayed(why) {
                win.note("gpu", why);
            }
        }
        Connections {
            target: bSiliconV.face.flourishItem
            function onPlayed(why) {
                win.note("siliconV", why);
            }
        }
        Connections {
            target: bSiliconV.face.gpuItem.flourishClock
            function onPlayed(why) {
                win.note("gpuV", why);
            }
        }
        // the numbers of an emitted path, in order (two paths of one outline have as many)
        function nums(d) {
            const m = String(d).match(/-?\d+\.\d+/g);
            return m ? m.map(Number) : [];
        }
        // how far (px) two emitted paths of one outline stand apart at their worst point; -1 when they are not the same outline
        function apart(a, b) {
            const x = win.nums(a), y = win.nums(b);
            if (x.length !== y.length || x.length === 0)
                return -1;
            let w = 0;
            for (let i = 0; i < x.length; ++i)
                w = Math.max(w, Math.abs(x[i] - y[i]));
            return w;
        }
        // is (px, py) inside the polygon of an emitted contour's points (its curves' control points with them: a little more than its ink)
        function inside(d, px, py) {
            const v = win.nums(d);
            let odd = false;
            for (let i = 0, j = v.length - 2; i < v.length; j = i, i += 2) {
                if ((v[i + 1] > py) !== (v[j + 1] > py) && px < (v[j] - v[i]) * (py - v[i + 1]) / (v[j + 1] - v[i + 1]) + v[i])
                    odd = !odd;
            }
            return odd;
        }
        // is (px, py) in the ink of a pose: in any of its parts, a part's contours taken even-odd (a hole is a contour)
        function inkAt(parts, px, py) {
            for (let i = 0; i < parts.length; ++i) {
                const cs = String(parts[i]).split("Z");
                let odd = false;
                for (let j = 0; j < cs.length; ++j) {
                    if (cs[j].trim() !== "" && win.inside(cs[j], px, py))
                        odd = !odd;
                }
                if (odd)
                    return true;
            }
            return false;
        }
        // a pose's ink on an off-lattice grid over its box: { n: samples in ink, cy: their mean height, map: one flag per sample }
        function inkOf(parts, size) {
            const r = { n: 0, cy: 0, map: [] };
            for (let y = -0.25 * size; y < 1.25 * size; y += size / 41.3) {
                for (let x = -0.25 * size; x < 1.25 * size; x += size / 41.3) {
                    const on = win.inkAt(parts, x, y);
                    r.map.push(on);
                    if (on) {
                        r.n++;
                        r.cy += y;
                    }
                }
            }
            r.cy = r.n > 0 ? r.cy / r.n : 0;
            return r;
        }
        function inkDiff(a, b) {
            let d = 0;
            for (let i = 0; i < a.map.length; ++i)
                d += a.map[i] !== b.map[i] ? 1 : 0;
            return d;
        }
        Connections {
            target: bWeather.flourish
            function onPlayed(why) {
                win.note("weather", why);
            }
        }
        property var burst: ({ on: false, back: 0, last: -1, maxKicks: 0 })
        Connections {
            target: bBell.flourish
            function onTChanged() {
                const b = win.burst;
                if (!b.on || !bBell.flourish.playing)
                    return;
                if (bBell.flourish.t < b.last - 0.001)
                    b.back++;
                b.last = bBell.flourish.t;
                b.maxKicks = Math.max(b.maxKicks, bBell.flourish.kicks.length);
            }
        }

        property var held: ({ t: 0 })
        property int fails: 0
        property real mid: 0
        property real far: 0
        property int pathChanges: 0
        property int stepChanges: 0
        Connections {
            target: bBridge
            function onCarXsChanged() {
                win.pathChanges++;
            }
            function on_CastStepChanged() {
                win.stepChanges++;
            }
        }
        function check(name, ok, detail) {
            console.log("FLOURISH_PROBE " + name + " " + (ok ? "ok" : "FAIL") + " " + (detail || ""));
            if (!ok)
                win.fails++;
        }
        function centre(item, dx) {
            const p = item.mapToItem(win.contentItem, item.width / 2 + (dx || 0), item.height / 2);
            return Qt.point(Math.round(p.x), Math.round(p.y));
        }
        function move(x, y) {
            tc.mouseMove(win.contentItem, x, y);
        }
        function park() {
            win.move(win.width - 3, 3);
        }

        // ---- the script: steps with waits (real clocks) ----
        property var steps: []
        property int _i: -1
        function run(list) {
            win.steps = list;
            win._i = -1;
            win.nextStep();
        }
        function nextStep() {
            win._i++;
            if (win._i >= win.steps.length) {
                console.log("FLOURISH_PROBE RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " fails=" + win.fails);
                quitTimer.start();
                return;
            }
            const s = win.steps[win._i];
            const wait = s() || 0;
            stepTimer.interval = Math.max(1, wait);
            stepTimer.restart();
        }
        Timer {
            id: stepTimer
            onTriggered: win.nextStep()
        }

        readonly property var script: [
            () => {
                win.park();
                return 1500;
            },
            () => {
                const clocks = [bBell.flourish, bUpdate.flourish, bPlayer.flourishClock, bSilicon.face.flourishItem.glyphClock, bSilicon.face.gpuItem.flourishClock,
                                bSiliconV.face.flourishItem.glyphClock, bSiliconV.face.gpuItem.flourishClock, bWeather.flourish];
                const playing = clocks.filter(c => c.playing).length;
                const running = clocks.filter(c => c._run.running).length;
                win.check("rest", playing === 0 && running === 0, "playing=" + playing + " animations running=" + running);
                // entry with no motion
                const p = win.centre(bBell);
                win.move(p.x, p.y);
                return 400;
            },
            () => {
                win.check("entry_still", win.plays.bell.length === 0, "plays=" + win.plays.bell.length);
                const p = win.centre(bBell, 2);
                win.move(p.x, p.y);
                return 60;
            },
            () => {
                win.check("entry_motion", win.plays.bell.length === 1 && win.plays.bell[0] === "hover", "plays=" + JSON.stringify(win.plays.bell));
                // motions while it plays
                const p = win.centre(bBell, -2);
                win.move(p.x, p.y);
                return 80;
            },
            () => {
                const p = win.centre(bBell, 1);
                win.move(p.x, p.y);
                return bBell.flourishMs + 300;
            },
            () => {
                // after it, still inside: a motion is no new entry
                const p = win.centre(bBell, 3);
                win.move(p.x, p.y);
                return 200;
            },
            () => {
                win.check("once_per_entry", win.plays.bell.length === 1 && !bBell.flourish.playing, "plays=" + win.plays.bell.length);
                // leave, come back, move: a new entry
                win.park();
                return 100;
            },
            () => {
                const p = win.centre(bBell);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 60;
            },
            () => {
                win.check("reentry", win.plays.bell.length === 2, "plays=" + win.plays.bell.length);
                bBell.flourish.stop();
                // slide: the pointer rests beside the bell; the bell slides under it
                win.park();
                return 100;
            },
            () => {
                const p = win.centre(bBell, 30);
                win.move(p.x, p.y);
                return 100;
            },
            () => {
                bBell.x = 30;
                return 400;
            },
            () => {
                win.check("slide", win.plays.bell.length === 2, "plays=" + win.plays.bell.length + " hovered=" + bBell.flourish.hoverArea.containsMouse);
                bBell.x = 0;
                win.park();
                return 200;
            },
            () => {
                // the burst: three notifications in 120 ms
                win.burst.on = true;
                win.burst.last = -1;
                bellSvc.arrive(0);
                return 60;
            },
            () => {
                bellSvc.arrive(0);
                return 60;
            },
            () => {
                bellSvc.arrive(0);
                return 30;
            },
            () => {
                const fl = bBell.flourish;
                win.check("burst_one_run", fl.playing && fl.kicks.length === 3 && win.plays.bell.length === 5,
                          "kicks=" + JSON.stringify(fl.kicks.map(k => Math.round(k))) + " plays=" + win.plays.bell.length);
                return fl.lastKick + fl.ms - fl.t + 400;
            },
            () => {
                win.burst.on = false;
                win.check("burst_continuous", win.burst.back === 0 && win.burst.maxKicks === 3 && !bBell.flourish.playing,
                          "clock went back " + win.burst.back + " times, kicks " + win.burst.maxKicks);
                // an undo brings a record back: no news
                bellSvc.arrive(60000);
                return 100;
            },
            () => {
                win.check("undo_quiet", win.plays.bell.length === 5 && !bBell.flourish.playing, "plays=" + win.plays.bell.length);
                bellSvc.dnd = true;
                bellSvc.arrive(0);
                return 50;
            },
            () => {
                win.check("dnd_rings", win.plays.bell.length === 6 && bBell.flourish.why === "notification", "plays=" + win.plays.bell.length);
                bBell.flourish.stop();
                bellSvc.dnd = false;
                // the real service: a post under do not disturb (filed, silent) rings the bell
                realSvc.dnd = true;
                realSvc.post({ source: "probe", title: "one", body: "a post" });
                return 50;
            },
            () => {
                win.check("real_post_rings", win.plays.real.length === 1 && win.plays.real[0] === "notification",
                          "plays=" + JSON.stringify(win.plays.real) + " records=" + realSvc.store.all().length);
                bReal.flourish.stop();
                return 600;
            },
            () => {
                // the clear and its undo: the record comes back through recordAdded with its old arrival stamp
                const token = realSvc.clearAll();
                const back = realSvc.undo(token);
                win.check("real_undo_quiet", back && realSvc.store.all().length === 1 && win.plays.real.length === 1,
                          "undone=" + back + " records=" + realSvc.store.all().length + " plays=" + win.plays.real.length);
                // the box during a run: no flourish
                bUpdate.running = true;
                return 500;
            },
            () => {
                const p = win.centre(bUpdate);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 100;
            },
            () => {
                win.check("box_run_quiet", win.plays.box.length === 0, "plays=" + win.plays.box.length);
                win.park();
                bUpdate.running = false;
                return bUpdate.endHoldMs + 700;
            },
            () => {
                const p = win.centre(bUpdate);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 60;
            },
            () => {
                win.check("box_hover", win.plays.box.length === 1 && bUpdate.flourish.playing, "plays=" + win.plays.box.length);
                win.park();
                const p = win.centre(bPlayer);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 200;
            },
            () => {
                const fl = bPlayer.flourishClock;
                const tBefore = fl.t;
                mpd.songId = 2;
                win.check("player", win.plays.player.length === 2 && win.plays.player[0] === "hover" && win.plays.player[1] === "song"
                          && fl.playing && tBefore > 0, "plays=" + JSON.stringify(win.plays.player) + " t before the song " + Math.round(tBefore));
                // ---- silicon's pill: each glyph for a pointer on it. First the figure, between them: neither plays ----
                win.park();
                const p = win.centre(bSilicon);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 60;
            },
            () => {
                win.check("silicon_figure", win.plays.silicon.length === 0 && win.plays.gpu.length === 0,
                          "on the figure: profile plays=" + JSON.stringify(win.plays.silicon) + " gpu plays=" + JSON.stringify(win.plays.gpu));
                // on to the profile glyph, never leaving the button: coming onto the glyph is its entry
                const p = win.centre(bSilicon.face.glyphItem);
                win.move(p.x, p.y);
                win.move(p.x + 1, p.y + 1);
                return 60;
            },
            () => {
                win.check("silicon", win.plays.silicon.length === 1 && win.plays.silicon[0] === "hover" && bSilicon.face.flourishItem.playing
                          && win.plays.gpu.length === 0, "profile plays=" + JSON.stringify(win.plays.silicon) + " gpu plays=" + JSON.stringify(win.plays.gpu));
                const p = win.centre(bSilicon.face.gpuItem);
                win.move(p.x, p.y);
                win.move(p.x + 1, p.y + 1);
                return 60;
            },
            () => {
                const g = bSilicon.face.gpuItem;
                win.check("silicon_gpu", win.plays.gpu.length === 1 && win.plays.gpu[0] === "hover" && g.flourishClock.playing && g.glyphItem.posing
                          && win.plays.silicon.length === 1, "gpu plays=" + JSON.stringify(win.plays.gpu) + " posing=" + g.glyphItem.posing
                          + " profile plays=" + win.plays.silicon.length);
                return g.flourishClock.ms + 300;
            },
            () => {
                // still on the glyph after its run: a motion is no new entry
                const g = bSilicon.face.gpuItem, p = win.centre(g);
                win.move(p.x - 1, p.y);
                win.move(p.x + 2, p.y);
                win.held.gpuOnce = win.plays.gpu.length === 1 && !g.flourishClock.playing && !g.glyphItem.posing;
                return 120;
            },
            () => {
                win.check("silicon_gpu_once", win.held.gpuOnce && win.plays.gpu.length === 1, "plays=" + win.plays.gpu.length + " at rest after the run: " + win.held.gpuOnce);
                // the card wakes: the glyph that stands plays, harder; a mode's glyph arriving plays too
                bSilicon.gpuInUse = true;
                return 60;
            },
            () => {
                const g = bSilicon.face.gpuItem;
                win.check("silicon_gpu_wake", win.plays.gpu.length === 2 && win.plays.gpu[1] === "wake" && g.strength > 1 && g.flourishClock.playing,
                          "plays=" + JSON.stringify(win.plays.gpu) + " strength " + g.strength);
                bSilicon.gpuMode = 3;
                return 60;
            },
            () => {
                const g = bSilicon.face.gpuItem;
                win.check("silicon_gpu_mode", win.plays.gpu.length === 3 && win.plays.gpu[2] === "mode" && g.shownMode === 3 && g.text.codePointAt(0) === 0xF0238
                          && g.flourishClock.ms === Math.round(bSilicon.flourishMs * GpuPose.time(3)),
                          "plays=" + JSON.stringify(win.plays.gpu) + " shows " + g.shownMode + " for " + g.flourishClock.ms + " ms");
                // Integrated chosen with the card still in use: the mode it came from stays, lit; the feather arrives when the card is let go
                bSilicon.gpuMode = 0;
                return 60;
            },
            () => {
                const g = bSilicon.face.gpuItem;
                win.held.stays = g.shownMode === 3 && win.plays.gpu.length === 3;
                bSilicon.gpuInUse = false;
                return 60;
            },
            () => {
                const g = bSilicon.face.gpuItem;
                win.check("silicon_gpu_leaves", win.held.stays && g.shownMode === 0 && g.text.codePointAt(0) === 0xF06D3 && g.presence === 1
                          && win.plays.gpu.length === 4 && win.plays.gpu[3] === "mode",
                          "stayed while in use: " + win.held.stays + "; then shows " + g.shownMode + " presence " + g.presence + " plays=" + JSON.stringify(win.plays.gpu));
                // ---- the side bar's: the face stands counter-rotated in its button ----
                win.park();
                const p = win.centre(bSiliconV);
                win.move(p.x, p.y);
                win.move(p.x, p.y + 2);
                return 60;
            },
            () => {
                win.held.sideFigure = win.plays.siliconV.length === 0 && win.plays.gpuV.length === 0;
                const p = win.centre(bSiliconV.face.gpuItem);
                win.move(p.x, p.y);
                win.move(p.x + 1, p.y + 1);
                return 60;
            },
            () => {
                win.held.sideGpu = win.plays.gpuV.length === 1 && win.plays.siliconV.length === 0;
                const p = win.centre(bSiliconV.face.glyphItem);
                win.move(p.x, p.y);
                win.move(p.x + 1, p.y + 1);
                return 60;
            },
            () => {
                const a = win.centre(bSiliconV.face.glyphItem), b = win.centre(bSiliconV.face.gpuItem);
                win.check("silicon_side", win.held.sideFigure && win.held.sideGpu && win.plays.siliconV.length === 1 && win.plays.gpuV.length === 1
                          && Math.abs(a.x - b.x) <= 1 && b.y - a.y > 30,
                          "figure quiet: " + win.held.sideFigure + " gpu alone: " + win.held.sideGpu + " profile plays=" + win.plays.siliconV.length
                          + " gpu plays=" + win.plays.gpuV.length + "; the glyphs stand " + (b.y - a.y) + " px apart down the capsule");
                // ---- the GPU mode's four poses ----
                const px = 14, ox = 3, oy = 12;
                const bad = [];
                let moved = 0, thrown = 0, onInk = 0, embers = 0;
                for (let m = 0; m < 4; ++m) {
                    const L = Math.round(900 * GpuPose.time(m));
                    const rest = GpuPose.rest(m, px, ox, oy);
                    for (const f of [1, 1.2]) {
                        const a = GpuPose.pose(m, 0, L, f, null, px, ox, oy), z = GpuPose.pose(m, L, L, f, null, px, ox, oy);
                        if (a.parts.join("|") !== rest.parts.join("|") || z.parts.join("|") !== rest.parts.join("|"))
                            bad.push("mode " + m + ": an end is not the font's outline");
                        for (const t of [1, L - 1]) {
                            const n = GpuPose.pose(m, t, L, f, null, px, ox, oy);
                            for (let i = 0; i < n.parts.length; ++i) {
                                if (i >= rest.parts.length) {
                                    if (n.parts[i] !== "")
                                        bad.push("mode " + m + ": something is thrown " + (t === 1 ? "1 ms in" : "1 ms from the end"));
                                } else {
                                    const d = win.apart(n.parts[i], rest.parts[i]);
                                    if (d < 0 || d > 0.05)
                                        bad.push("mode " + m + " part " + i + ": " + d.toFixed(3) + " px off its rest " + (t === 1 ? "1 ms in" : "1 ms from the end"));
                                }
                            }
                        }
                    }
                    let far = 0, out = false;
                    for (let t = 15; t < L; t += 15) {
                        const n = GpuPose.pose(m, t, L, 1, null, px, ox, oy);
                        for (let i = 0; i < rest.parts.length; ++i)
                            far = Math.max(far, win.apart(n.parts[i], rest.parts[i]));
                        for (let i = rest.parts.length; i < n.parts.length; ++i) {
                            if (n.parts[i] === "")
                                continue;
                            out = true;
                            if (m === 3) {
                                // an ember: its middle is the mean of its points; the flame is the first contour of part 0
                                const v = win.nums(n.parts[i]);
                                let ex = 0, ey = 0;
                                for (let q = 0; q < v.length; q += 2) {
                                    ex += v[q] * 2 / v.length;
                                    ey += v[q + 1] * 2 / v.length;
                                }
                                embers++;
                                if (win.inside(n.parts[0].split("Z")[0], ex, ey))
                                    onInk++;
                            }
                        }
                    }
                    if (far > 0.5)
                        moved++;
                    if (out)
                        thrown++;
                }
                win.check("gpu_rest", bad.filter(b => b.indexOf("an end") >= 0).length === 0, bad.filter(b => b.indexOf("an end") >= 0).join("; ") || "four glyphs, both ends, both strengths");
                win.check("gpu_near", bad.filter(b => b.indexOf("an end") < 0).length === 0, bad.filter(b => b.indexOf("an end") < 0).slice(0, 4).join("; ") || "within 0.05 px of rest a millisecond inside each end, nothing thrown");
                win.check("gpu_moves", moved === 4 && thrown === 2, "glyphs that move: " + moved + " of 4; that throw something (the bulb, the fire): " + thrown);
                win.check("gpu_embers", embers > 20 && onInk === 0, "ember samples " + embers + ", over the flame's ink " + onInk);
                // ---- the profile's three poses (SiliconGlyphPose): the leaf, the scales and their weight, the bolt's charge ----
                const PX = 96, OX = 0, OY = 72;
                const ends = [], near = [];
                for (let kd = 0; kd < 3; ++kd) {
                    const rest = ProfilePose.rest(kd, PX, OX, OY), restInk = win.inkOf(rest, PX);
                    const L = Math.round(900 * ProfilePose.time(kd));
                    for (const f of [0.65, 1, 1.3]) {
                        if (ProfilePose.path(kd, 0, f, PX, OX, OY).join("|") !== rest.join("|") || ProfilePose.path(kd, 1, f, PX, OX, OY).join("|") !== rest.join("|"))
                            ends.push("glyph " + kd + " strength " + f);
                        for (const u of [1 / L, 1 - 1 / L]) {
                            const d = win.inkDiff(win.inkOf(ProfilePose.path(kd, u, f, PX, OX, OY), PX), restInk);
                            if (d > 0.012 * restInk.n)
                                near.push("glyph " + kd + " strength " + f + (u < 0.5 ? " 1 ms in: " : " 1 ms from the end: ") + d + " of " + restInk.n + " samples");
                        }
                    }
                }
                win.check("profile_rest", ends.length === 0 && ProfilePose.rest(1, PX, OX, OY)[4] === "", ends.join("; ") || "three glyphs, both ends, three strengths: the font's outline, no weight");
                win.check("profile_near", near.length === 0, near.slice(0, 4).join("; ") || "within 1.2 % of the rest's ink a millisecond inside each end");
                // the scales: the weight is thrown from the left pan over the pivot into the right one, and the beam STANDS tipped
                const SC = ProfilePose.SCALES, toDeg = 180 / Math.PI;
                let over = 0, tipped = 0, tipN = 0, flightOk = true, lastX = -1e9;
                for (let u = SC.go + 0.01; u < SC.land; u += 0.01) {
                    const w = ProfilePose.weightAt(u, 1);
                    flightOk = flightOk && w[0] > lastX && ProfilePose.weightR(u) > 0 && ProfilePose.path(1, u, 1, PX, OX, OY)[4] !== "";
                    lastX = w[0];
                    if (w[1] - ProfilePose.weightR(u) > 1424)
                        over++;
                }
                for (let u = SC.land + 0.1; u <= SC.melt0; u += 0.01) {
                    tipN++;
                    if (ProfilePose.beamAngle(u, 1) * toDeg <= -10)
                        tipped++;
                }
                const w0 = ProfilePose.weightAt(SC.go, 1), w1 = ProfilePose.weightAt(SC.land, 1);
                win.check("scales_weight", flightOk && over >= 8 && w0[0] < SC.px - 400 && w1[0] > SC.px + 400 && ProfilePose.weightR(SC.melt1) === 0,
                          "one way, left to right: " + flightOk + "; clear above the pivot's bulb for " + over + " of its flight's hundredths; from x " + w0[0].toFixed(0) + " to " + w1[0].toFixed(0));
                win.check("scales_tip", tipN > 10 && tipped === tipN && ProfilePose.beamAngle(SC.load, 1) * toDeg >= 4 && ProfilePose.beamAngle(SC.flick, 1) * toDeg <= -4,
                          "right pan down 10 degrees or more for " + tipped + " of " + tipN + " hundredths after the landing; left down " + (ProfilePose.beamAngle(SC.load, 1) * toDeg).toFixed(1)
                          + " under the weight, up " + (-ProfilePose.beamAngle(SC.flick, 1) * toDeg).toFixed(1) + " at the flick");
                // the bolt: its ink runs off DOWNWARD and nearly all of it goes; the charge comes in from ABOVE and lands whole
                const BO = ProfilePose.BOLT, boltRest = win.inkOf(ProfilePose.rest(2, PX, OX, OY), PX);
                let least = 1, sinks = true, lastCy = boltRest.cy;
                for (let u = 0.02; u < 1; u += 0.02) {
                    const k = win.inkOf(ProfilePose.path(2, u, 1, PX, OX, OY), PX);
                    least = Math.min(least, k.n / boltRest.n);
                    if (u > 0.05 && u < BO.strike0) {
                        // the grid's own noise: a step's long level edge crossing a row of samples moves the mean up to 1.2 px of the 96
                        sinks = sinks && k.cy >= lastCy - 2.5;
                        lastCy = k.cy;
                    }
                }
                const early = win.inkOf(ProfilePose.path(2, BO.drainEnd + 0.02, 1, PX, OX, OY), PX), landed = win.inkOf(ProfilePose.path(2, BO.hit, 1, PX, OX, OY), PX);
                win.check("bolt_drains", sinks && lastCy > boltRest.cy + 0.04 * PX && least < 0.2, "its ink sinks while it runs off: " + sinks + ", " + (lastCy - boltRest.cy).toFixed(1) + " px by the time the charge comes; least ink " + (least * 100).toFixed(0) + " % of the bolt");
                win.check("bolt_strikes", early.n > 0 && early.cy < boltRest.cy - 0.1 * PX && landed.n > 1.1 * boltRest.n && landed.cy > boltRest.cy,
                          "the charge alone: " + early.n + " samples, " + (boltRest.cy - early.cy).toFixed(1) + " px above the bolt's middle; landed: "
                          + (landed.n / boltRest.n * 100).toFixed(0) + " % of the bolt's ink, " + (landed.cy - boltRest.cy).toFixed(1) + " px low");
                win.park();
                const p = win.centre(bWeather);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 200;
            },
            () => {
                const fl = bWeather.flourish;
                // a shower: the sun behind the cloud turns for one beat (the button's 900 ms), the drops for less
                win.check("weather", win.plays.weather.length === 1 && win.plays.weather[0] === "hover" && fl.playing && fl.t > 0
                          && fl.ms > 600 && fl.ms < 1000, "plays=" + JSON.stringify(win.plays.weather) + " t " + Math.round(fl.t) + " ms " + fl.ms);
                win.park();
                return 1300;
            },
            () => {
                win.check("weather_ends", !bWeather.flourish.playing && !bWeather.flourish._run.running, "playing=" + bWeather.flourish.playing);
                WeatherGlyphSet.set = "carved";
                return 100;
            },
            () => {
                const p = win.centre(bWeather);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 200;
            },
            () => {
                win.check("weather_carved", win.plays.weather.length === 1 && !bWeather.flourish.playing, "plays=" + JSON.stringify(win.plays.weather));
                WeatherGlyphSet.set = "ink";
                win.park();
                return 1500;
            },
            () => {
                // ---- the stocks button: hover plays once, a hover mid-play is ignored, then the held plays ----
                win.check("stocks_rest", win.stkAtRest(bStkGain) && win.stkAtRest(bStkLoss) && win.stkAtRest(bStkClosed), "a warp bound or a clock running at rest");
                win.park();
                const p = win.centre(bStkGain);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 200;
            },
            () => {
                const fl = bStkGain.flourish;
                win.check("stocks_hover", win.plays.stocksGain.length === 1 && win.plays.stocksGain[0] === "hover" && fl.playing && fl.t > 0
                          && fl.ms > 500 && fl.ms < 1200 && fl.group === "stocks" && fl.decorative, "plays=" + JSON.stringify(win.plays.stocksGain) + " t " + Math.round(fl.t) + " ms " + fl.ms);
                win.park();
                const p = win.centre(bStkGain);
                win.move(p.x, p.y);
                win.move(p.x + 3, p.y);
                return 100;
            },
            () => {
                win.check("stocks_midplay", win.plays.stocksGain.length === 1, "a hover mid-play played again: " + JSON.stringify(win.plays.stocksGain));
                win.park();
                return bStkGain.flourish.ms + 400;
            },
            () => {
                win.check("stocks_ends", win.stkAtRest(bStkGain), "playing=" + bStkGain.flourish.playing + " warp bound or clock running");
                const amp = bStkGain.flourishAmp;
                const g = win.stkRun(bStkGain, gainSvc, true, 1.23, "both");
                const l = win.stkRun(bStkLoss, lossSvc, true, -0.87, "both");
                const c = win.stkRun(bStkClosed, closedSvc, false, 0, "both");
                const gr = win.stkRun(bStkGain, gainSvc, true, 1.23, "ripple");
                const ga = win.stkRun(bStkGain, gainSvc, true, 1.23, "arrow");
                const f = v => v.map(x => Math.round(x * 100) / 100).join("/");
                win.check("stocks_range", [g, l, c, gr].every(r => Math.max(-r.lo, r.hi) <= amp + 1e-6) && Math.max(-g.lo, g.hi) > 0.5 * amp
                          && Math.max(-l.lo, l.hi) > 0.5 * amp && ga.lo === 0 && ga.hi === 0,
                          "gain " + g.lo.toFixed(2) + ".." + g.hi.toFixed(2) + " loss " + l.lo.toFixed(2) + ".." + l.hi.toFixed(2) + " closed " + c.lo.toFixed(2) + ".." + c.hi.toFixed(2) + " arrow-only " + ga.lo + ".." + ga.hi + " (amp " + amp + ")");
                win.check("stocks_direction", g.hi <= 1e-9 && g.lo < -0.5 * amp && l.lo >= -1e-9 && l.hi > 0.5 * amp && c.lo < -0.5 * amp && c.hi > 0.5 * amp,
                          "a gain bulges UP (dy <= 0), a loss dips DOWN, closed both: gain " + f([g.lo, g.hi]) + " loss " + f([l.lo, l.hi]) + " closed " + f([c.lo, c.hi]));
                win.check("stocks_modehold", g.hi <= 1e-9 && g.lo < -0.5 * amp, "the day turned over mid-play and the lump followed: gain " + f([g.lo, g.hi]));
                win.check("stocks_arrow", g.arrows > 3 && l.arrows > 3 && c.arrows === 0 && gr.arrows === 0 && ga.arrows > 3,
                          "arrow frames: gain " + g.arrows + " loss " + l.arrows + " closed " + c.arrows + " ripple-only " + gr.arrows + " arrow-only " + ga.arrows);
                win.check("stocks_arrow_way", g.y0 !== null && l.y0 !== null && g.y1 < g.y0 && l.y1 > l.y0 && g.inside && l.inside && ga.inside,
                          "an arrow leaves the tip UP on a gain and DOWN on a loss, inside the face: gain " + g.y0 + " -> " + g.y1 + " loss " + l.y0 + " -> " + l.y1);
                win.check("stocks_width", g.width && l.width && c.width && gr.width && ga.width, "implicitWidth moved during a play");
                win.check("stocks_zero", [g, l, c, gr, ga].every(r => r.first[0] === 0 && r.first[1] === 0 && r.last[0] === 0 && r.last[1] === 0) && g.other && c.other,
                          "the line is the plain line at both ends: " + f(g.first) + " " + f(g.last) + " " + f(c.first) + " " + f(c.last));
                win.check("stocks_dots", c.dotLo < -1 && c.dotLo >= -bStkClosed.flourishHop - 1e-6 && c.dotHi === 0 && c.peaks[0] > 0 && c.peaks[0] < c.peaks[1] && c.peaks[1] < c.peaks[2] && g.dotLo === 0,
                          "the dots hop up in turn (peaks at " + c.peaks.join(",") + " of 120), a live face's never: " + f([c.dotLo, c.dotHi]) + " live " + f([g.dotLo, g.dotHi]));
                const L = StocksPose.life("gain", "both", null);
                win.check("stocks_pose", StocksPose.dy(10, 22, 0, "gain", "both", null) === 0 && StocksPose.dy(10, 22, L, "gain", "both", null) === 0 && StocksPose.arrow(0, "gain", "both", null) === null
                          && StocksPose.arrow(L, "gain", "both", null) === null && StocksPose.arrow(100, "closed", "both", null) === null, "life " + L);
                win.check("stocks_rest_after", win.stkAtRest(bStkGain) && win.stkAtRest(bStkLoss) && win.stkAtRest(bStkClosed), "a warp bound or a clock running after the plays");
                win.park();
                return 100;
            },
            () => {
                // ---- the note's peel ----
                const g = bNotes.glyphItem;
                const rest = NotePose.rest(g.pixelSize, g.origin.x, g.origin.y);
                const a = NotePose.frame(0, bNotes.flourishMs, null, g.pixelSize, g.origin.x, g.origin.y);
                const z = NotePose.frame(bNotes.flourishMs, bNotes.flourishMs, null, g.pixelSize, g.origin.x, g.origin.y);
                const m = NotePose.frame(bNotes.flourishMs * 0.25, bNotes.flourishMs, null, g.pixelSize, g.origin.x, g.origin.y);
                // the first instant: the top sheet is the font's outline and there is NO sheet underneath (no path, no ink)
                win.check("notes_rest", a.parts[2] === rest[0] && a.parts[3] === rest[1] && a.parts[0] === "" && a.parts[1] === "" && a.shades[0] === 0,
                          "top " + (a.parts[2] === rest[0]) + " flap " + (a.parts[3] === rest[1]) + " under '" + a.parts[0].slice(0, 12) + "' ink " + a.shades[0]);
                // the last: the new note is the font's outline in the full ink and the old sheet is gone
                win.check("notes_end", z.parts[0] === rest[0] && z.parts[1] === rest[1] && z.shades[0] === 1 && z.parts[2] === "" && z.parts[3] === "",
                          "note " + (z.parts[0] === rest[0]) + " flap " + (z.parts[1] === rest[1]) + " ink " + z.shades[0] + " old '" + z.parts[2].slice(0, 12) + "'");
                // between: the sheet underneath shows in the uncovered triangle, paler than the one being peeled
                win.check("notes_block", m.parts[0] !== "" && m.shades[0] > 0.2 && m.shades[0] < 0.8 && m.shades[2] === 1, "under ink " + m.shades[0]);
                win.grab(bNotes, "notes_text");
                return 150;
            },
            () => {
                const fl = bNotes.flourish;
                fl.held = true;
                fl.play("probe");
                fl.t = 0;
                return 150;
            },
            () => {
                win.check("notes_posed", bNotes.glyphItem.posing && bNotes.glyphItem.parts.length === 4, "posing=" + bNotes.glyphItem.posing);
                win.grab(bNotes, "notes_first");
                return 150;
            },
            () => {
                bNotes.flourish.t = bNotes.flourishMs;
                return 150;
            },
            () => {
                win.grab(bNotes, "notes_last");
                return 150;
            },
            () => {
                const fl = bNotes.flourish;
                fl.stop();
                fl.held = false;
                win.plays.notes = [];
                win.park();
                const p = win.centre(bNotes);
                win.move(p.x, p.y);
                return 300;
            },
            () => {
                const still = win.plays.notes.length;
                const p = win.centre(bNotes, 2);
                win.move(p.x, p.y);
                win.held.notesStill = still;
                return 200;
            },
            () => {
                const fl = bNotes.flourish;
                const again = fl.play("again");
                win.check("notes_hover", win.held.notesStill === 0 && win.plays.notes.length === 1 && win.plays.notes[0] === "hover" && fl.playing
                          && fl.t > 0 && again === false && fl.decorative && fl.group === "notes",
                          "still=" + win.held.notesStill + " plays=" + JSON.stringify(win.plays.notes) + " t " + Math.round(fl.t) + " a second ask " + again);
                win.park();
                return bNotes.flourishMs + 400;
            },
            () => {
                const fl = bNotes.flourish;
                win.check("notes_ends", !fl.playing && !fl._run.running && !bNotes.glyphItem.posing && win.plays.notes.length === 1,
                          "playing=" + fl.playing + " plays=" + win.plays.notes.length);
                return 10;
            },
            () => {
                // ---- the chat star's flourish (the pose) ----
                const L = SparklePose.LIFE;
                const rest = SparklePose.rest(18, 5, 20);
                const a = SparklePose.frame(0, L, null, 18, 5, 20), z = SparklePose.frame(L, L, null, 18, 5, 20);
                const m = SparklePose.frame(L * 0.52, L, null, 18, 5, 20);
                win.check("sparkle_rest", a.parts[0] === rest && a.parts[1] === "" && a.parts[2] === "", "star " + (a.parts[0] === rest) + " sparks '" + a.parts[1] + a.parts[2] + "'");
                win.check("sparkle_end", z.parts[0] === rest && z.parts[1] === "" && z.parts[2] === "", "star " + (z.parts[0] === rest) + " sparks '" + (z.parts[1] + z.parts[2]).slice(0, 12) + "'");
                win.check("sparkle_sparks", m.parts[1] !== "" && m.parts[2] !== "" && m.parts[0] !== rest, "out: " + (m.parts[1] !== "") + " " + (m.parts[2] !== ""));
                // the real button: a hover plays it once, the star posed while it does
                win.park();
                const p = win.centre(bLlm);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 200;
            },
            () => {
                const fl = bLlm.flourish;
                win.check("sparkle_hover", win.plays.llm.length === 1 && win.plays.llm[0] === "hover" && fl.playing && fl.t > 0 && bLlm.posing
                          && bLlm.parts.length === 3 && fl.play("again") === false && fl.decorative && fl.group === "llm",
                          "plays=" + JSON.stringify(win.plays.llm) + " t " + Math.round(fl.t) + " posing=" + bLlm.posing);
                win.park();
                return fl.ms + 400;
            },
            () => {
                const fl = bLlm.flourish;
                win.check("sparkle_ends", !fl.playing && !fl._run.running && !bLlm.posing && win.plays.llm.length === 1, "playing=" + fl.playing);
                return 10;
            },
            () => {
                // ---- the theme button's swatch (the pose): the filled swatch, the one glyph of both modes ----
                const L = SwatchPose.LIFE;
                const key = "f08b5";
                const rest = SwatchPose.rest(key, 18, 5, 20);
                const a = SwatchPose.frame(key, 0, L, null, 18, 5, 20).parts, z = SwatchPose.frame(key, L, L, null, 18, 5, 20).parts;
                const m = SwatchPose.frame(key, L * 0.4, L, null, 18, 5, 20).parts;
                const same = (p) => p.length === 3 && p[0] === rest[0] && p[1] === rest[1] && p[2] === rest[2];
                win.check("swatch_rest_filled", same(a) && rest[0] !== "" && rest[1] !== "" && rest[2] !== "", "back " + (a[0] === rest[0]) + " mid " + (a[1] === rest[1]) + " front " + (a[2] === rest[2]));
                win.check("swatch_end_filled", same(z), "back " + (z[0] === rest[0]) + " mid " + (z[1] === rest[1]) + " front " + (z[2] === rest[2]));
                win.check("swatch_shut_filled", m[0] === "" && m[1] === "" && m[2] !== "" && m[2] !== rest[2], "behind: '" + (m[0] + m[1]).slice(0, 12) + "'");
                const run = win.swatchRun(key);
                win.check("swatch_front_filled", run.over === 0 && run.style === 0 && run.shut > 20,
                          "samples with a card behind over the front card " + run.over + ", with the front card's own ink wrong " + run.style + ", shut " + run.shut + " of 161");
                win.check("swatch_fan_filled", run.wide > 1.15 && run.wide < 2.2, "widest fan " + run.wide.toFixed(2) + " of its rest spread");
                // the real button: the filled glyph, and a hover plays it once
                win.check("swatch_glyph", Theme.mode === "light" && bTheme.glyphKey === "f08b5" && bTheme.glyph.codePointAt(0) === 0xF08B5 && !bTheme.posing,
                          Theme.mode + " " + bTheme.glyphKey);
                win.park();
                const p = win.centre(bTheme);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 200;
            },
            () => {
                const fl = bTheme.flourish;
                win.check("swatch_hover", win.plays.theme.length === 1 && win.plays.theme[0] === "hover" && fl.playing && fl.t > 0 && bTheme.posing
                          && bTheme.parts.length === 3 && fl.play("again") === false && fl.decorative && fl.group === "theme",
                          "plays=" + JSON.stringify(win.plays.theme) + " t " + Math.round(fl.t) + " posing=" + bTheme.posing);
                win.park();
                // this button starts the crossfade: its own flourish holds still through one
                Theme._hosted = true;
                Theme._switching = true;
                return 40;
            },
            () => {
                win.held.swatchT = bTheme.flourish.t;
                win.held.swatchPath = bTheme.parts.join("|");
                return 300;
            },
            () => {
                const fl = bTheme.flourish;
                win.check("swatch_hold", Theme.crossfading && fl.playing && win.held.swatchT > 0 && fl.t === win.held.swatchT && bTheme.parts.join("|") === win.held.swatchPath,
                          "crossfading=" + Theme.crossfading + " t " + Math.round(win.held.swatchT) + " -> " + Math.round(fl.t));
                Theme._switching = false;
                Theme._hosted = false;
                return fl.ms + 400;
            },
            () => {
                const fl = bTheme.flourish;
                win.check("swatch_ends", !fl.playing && !fl._run.running && !bTheme.posing && win.plays.theme.length === 1, "playing=" + fl.playing + " plays=" + win.plays.theme.length);
                return 10;
            },
            () => {
                // ---- the panorama button's pose: ONE monitor of a constant size, its screen cut into the displays; the deal ----
                const px = 18, ox = 5, oy = 20, k = px / 2048;
                const L = PanoPose.LIFE, I = PanoPose.INK;
                const states = [
                    ["1", { count: 1, plus: 0, mirror: 0 }], ["2", { count: 2, plus: 0, mirror: 0 }], ["3", { count: 3, plus: 0, mirror: 0 }],
                    ["3+", { count: 3, plus: 1, mirror: 0 }], ["1m", { count: 1, plus: 0, mirror: 1 }], ["3+m", { count: 3, plus: 1, mirror: 1 }],
                    ["2m", { count: 2, plus: 0, mirror: 1 }]
                ];
                const box = function (parts) {
                    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
                    for (const d of parts) {
                        const v = win.nums(d);
                        for (let i = 0; i + 1 < v.length; i += 2) {
                            x0 = Math.min(x0, v[i]);
                            x1 = Math.max(x1, v[i]);
                            y0 = Math.min(y0, v[i + 1]);
                            y1 = Math.max(y1, v[i + 1]);
                        }
                    }
                    return [x0, y0, x1, y1];
                };
                // the ink's box in this frame's pixels, and how far a drawn box is from it (font units: 1 unit = k px)
                const want = [ox + I.x0 * k, oy - I.y1 * k, ox + I.x1 * k, oy - I.y0 * k];
                const off = function (b) {
                    return Math.max(Math.abs(b[0] - want[0]), Math.abs(b[1] - want[1]), Math.abs(b[2] - want[2]), Math.abs(b[3] - want[3])) / k;
                };
                const over = function (b) {
                    return Math.max(want[0] - b[0], want[1] - b[1], b[2] - want[2], b[3] - want[3]) / k;
                };
                const badRest = [], badNear = [], out = [], gone = [], drift = [], still = [], tiles = [], holes = [], pops = [];
                // the contours of an emitted part: a screen is one, a window two, the "+" one, the mirror mark three
                const contours = function (d) {
                    return d === "" ? 0 : d.split("Z").length - 1;
                };
                // what is on the screens at the run's clock `x`, held to: rings apart, a tile in its ring, a ring in its screen, no ring
                // beside a mark
                const apart = function (s, x, name) {
                    for (const p of PanoPose.screens(s, x, null)) {
                        const w = p.windows;
                        for (let i = 0; i < w.length; ++i) {
                            const h = w[i].hole, t = w[i].tile;
                            if (h[0] < p.pane.x0 || h[1] < p.pane.y0 || h[2] > p.pane.x1 || h[3] > p.pane.y1)
                                holes.push(name + " x " + x + " a ring out of its screen");
                            if (t && (t[0] < h[0] || t[1] < h[1] || t[2] > h[2] || t[3] >= h[3]))
                                holes.push(name + " x " + x + " a tile out of its ring");
                            for (let j = i + 1; j < w.length; ++j) {
                                const o = w[j].hole;
                                if (Math.min(h[2], o[2]) - Math.max(h[0], o[0]) > 0.01 && Math.min(h[3], o[3]) - Math.max(h[1], o[1]) > 0.01)
                                    holes.push(name + " x " + x + " rings " + i + " and " + j + " overlap");
                            }
                        }
                        if (p.mark > 0 && w.length > 0)
                            holes.push(name + " x " + x + " a ring beside a mark of " + p.mark.toFixed(2));
                    }
                };
                const clear = PanoPose._dealAt(PanoPose.DEFAULTS) - 1;
                for (const st of states) {
                    let dealt = 0;
                    const rest = PanoPose.rest(st[1], px, ox, oy);
                    const a = PanoPose.frame(st[1], 0, L, null, px, ox, oy), z = PanoPose.frame(st[1], L, L, null, px, ox, oy);
                    for (let i = 0; i < 4; ++i)
                        if (a.parts[i] !== rest.parts[i] || z.parts[i] !== rest.parts[i])
                            badRest.push(st[0] + " part " + i);
                    if (a.parts.length !== 4 || a.shades.length !== 0)
                        badRest.push(st[0] + " shape");
                    // THE BOX IS THE SAME in every state at rest (to a font unit)
                    if (off(box(rest.parts)) > 1)
                        drift.push(st[0] + " rest box is " + off(box(rest.parts)).toFixed(1) + " units off the ink box");
                    for (const t of [1, L - 1]) {
                        const n = PanoPose.frame(st[1], t, L, null, px, ox, oy);
                        for (let i = 0; i < 4; ++i) {
                            const d = win.apart(n.parts[i], rest.parts[i]);
                            if (rest.parts[i] === "" ? n.parts[i] !== "" : (d < 0 || d > 0.15))
                                badNear.push(st[0] + " " + (t === 1 ? "1 ms in" : "1 ms from the end") + " part " + i + " " + d.toFixed(3) + " px");
                        }
                    }
                    // THE WINDOWS: there at rest, by the contours emitted, gone at the clear instant; a mark is there at both
                    const mid = PanoPose.frame(st[1], clear, L, null, px, ox, oy);
                    const scr = PanoPose.screens(st[1], 0, null);
                    for (let i = 0; i < st[1].count; ++i) {
                        const mark = i === 2 && st[1].plus ? 1 : (i === 0 && st[1].mirror ? 3 : 0);
                        const wins = mark ? 0 : (st[1].count === 1 ? 3 : 2);
                        if (contours(rest.parts[i]) !== 1 + mark + 2 * wins || scr[i].windows.length !== wins)
                            tiles.push(st[0] + " pane " + i + " rests with " + contours(rest.parts[i]) + " contours, not " + (1 + mark + 2 * wins));
                        if (contours(mid.parts[i]) !== 1 + mark)
                            tiles.push(st[0] + " pane " + i + " is not clear at " + clear + " ms: " + contours(mid.parts[i]) + " contours");
                        for (const w of scr[i].windows)
                            if (!w.tile || w.tile[0] - w.hole[0] < 80 || w.tile[1] - w.hole[1] < 80 || w.tile[2] - w.tile[0] < 160 || w.tile[3] - w.tile[1] < 160)
                                tiles.push(st[0] + " pane " + i + " a window under two thirds of a pixel: " + JSON.stringify(w));
                        if (mark && PanoPose.screens(st[1], clear, null)[i].mark < 0.5)
                            tiles.push(st[0] + " pane " + i + " its mark is gone at " + clear + " ms");
                    }
                    for (let x = 0; x <= L; x += 4)
                        apart(st[1], x, st[0]);
                    // every sample of the run: inside the ink's box (and a present pane never vanishes)
                    for (let t = 5; t < L; t += 5) {
                        const n = PanoPose.frame(st[1], t, L, null, px, ox, oy);
                        const b = box(n.parts);
                        if (over(b) > 0.5)
                            out.push(st[0] + " t " + t + " pokes " + over(b).toFixed(1) + " units out");
                        for (let i = 0; i < 3; ++i)
                            if (rest.parts[i] !== "" && n.parts[i] === "")
                                gone.push(st[0] + " t " + t + " pane " + i + " vanishes");
                        if (n.parts.join("|") !== rest.parts.join("|"))
                            dealt++;
                    }
                    if (dealt < 20)
                        still.push(st[0] + " moves in " + dealt + " samples");
                }
                // the count's spring (and the "+" and the mirror's ease): every sample inside the box, and the row always spans it
                const sweep = [];
                for (let c = 1; c <= 3.001; c += 0.02)
                    for (const m of [0, 1])
                        sweep.push([c.toFixed(2) + (m ? "m" : ""), { count: c, plus: 0, mirror: m }]);
                for (let q = 0; q <= 1.001; q += 0.02)
                    sweep.push(["+" + q.toFixed(2), { count: 3, plus: q, mirror: 0 }], ["m" + q.toFixed(2), { count: 2, plus: 0, mirror: q }]);
                for (const sw of sweep) {
                    const b = box(PanoPose.frame(sw[1], 0, L, null, px, ox, oy).parts);
                    if (over(b) > 0.5)
                        out.push("count " + sw[0] + " pokes " + over(b).toFixed(1) + " units out");
                    if (off(b) > 1)
                        drift.push("count " + sw[0] + " box " + off(b).toFixed(1) + " units off");
                    // the same states with a deal under way
                    for (const x of [0, 200, 420, 500, 560, 640, 760])
                        apart(sw[1], x, "count " + sw[0]);
                }
                // the count's spring moves the first screen's windows: its stack's left edge never jumps (a millisecond of the spring a step)
                let was = null;
                for (let c = 1; c <= 3.0001; c += 0.0025) {
                    const w = PanoPose.screens({ count: c, plus: 0, mirror: 0 }, 0, null)[0].windows;
                    const x = w.length > 0 ? w[w.length - 1].hole[0] : -1;
                    if (was !== null && Math.abs(x - was) > 60)
                        pops.push("count " + c.toFixed(3) + " the stack jumps " + Math.round(x - was) + " units");
                    was = x;
                }
                win.check("pano_rest", badRest.length === 0, badRest.slice(0, 4).join("; ") || "the first and last instant are the rest, in " + states.length + " states");
                win.check("pano_life", PanoPose.LIFE === PanoPose._total(PanoPose.DEFAULTS) && still.length === 0, "life " + L + " ms; " + (still.join("; ") || "every state's run differs from its rest"));
                win.check("pano_tiles", tiles.length === 0, tiles.slice(0, 3).join("; ") || "the windows stand at rest and are gone at " + clear + " ms, the marks there at both");
                win.check("pano_holes", holes.length === 0, holes.length + " " + (holes.slice(0, 3).join("; ") || "overlaps: every ring apart, in its screen, its tile in it, none beside a mark"));
                win.check("pano_morph", pops.length === 0, pops.slice(0, 3).join("; ") || "the windows move with the count's spring and are never swapped");
                win.check("pano_near", badNear.length === 0, badNear.slice(0, 4).join("; ") || "within 0.15 px of rest a millisecond inside each end");
                win.check("pano_inbox", out.length === 0, out.slice(0, 3).join("; ") || "every sample of the deal and of the count's spring inside the ink's box");
                win.check("pano_count", gone.length === 0, gone.slice(0, 3).join("; ") || "no pane vanishes in the deal");
                win.check("pano_width", drift.length === 0, drift.slice(0, 3).join("; ") || "the ink's box is the same (1 unit) for one, two, three, three and a plus, mirroring, and through the spring");
                // the real button: the muted ink, the pose always on (no font outline), four parts
                win.park();
                win.check("pano_button", Qt.colorEqual(bPano.ink, Theme.textMuted) && bPano.posing && bPano.parts.length === 4 && bPano.flourish.group === "panorama" && bPano.flourish.decorative,
                          "ink " + bPano.ink + " posing=" + bPano.posing + " parts=" + bPano.parts.length);
                const p = win.centre(bPano);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 200;
            },
            () => {
                const fl = bPano.flourish;
                win.check("pano_hover", win.plays.panorama.length === 1 && win.plays.panorama[0] === "hover" && fl.playing && fl.t > 0 && fl.play("again") === false,
                          "plays=" + JSON.stringify(win.plays.panorama) + " t " + Math.round(fl.t));
                win.park();
                return fl.ms + 400;
            },
            () => {
                const fl = bPano.flourish;
                win.check("pano_ends", !fl.playing && !fl._run.running && win.plays.panorama.length === 1, "playing=" + fl.playing);
                // the host's deal(): a play through the flourish's demo path, refused while it plays
                const d1 = bPano.deal(), d2 = bPano.deal();
                win.check("pano_deal", d1 && !d2 && fl.playing, "deal " + d1 + " again " + d2 + " playing " + fl.playing);
                fl.stop();
                bPano.panes = 3;
                bPano.mirroring = true;
                return 700;
            },
            () => {
                // the eased facts have landed: the picture is the rest picture of three panes and the mirror mark
                const want = PanoPose.rest({ count: 3, plus: 0, mirror: 1 }, bPano.glyphSize, bPano.glyphOrigin.x, bPano.glyphOrigin.y);
                win.check("pano_state", bPano.parts.join("|") === want.parts.join("|") && Qt.colorEqual(bPano.ink, bPano.hueOn),
                          "parts " + (bPano.parts.join("|") === want.parts.join("|")) + " ink " + bPano.ink + " on " + bPano.hueOn);
                bPano.panes = 1;
                bPano.mirroring = false;
                return 700;
            },
            () => {
                // ---- the bridge button's drawbridge (the pose, from what it EMITS) ----
                const px = 18, ox = 5, oy = 20;
                const D = BridgePose.DEFAULTS;
                const rest = BridgePose.rest(px, ox, oy);
                const a = BridgePose.frame(0, 0, null, px, ox, oy);
                win.check("bridge_rest", a.parts.length === 1 && a.parts[0] === rest && rest.split("Z").length === 7 && a.shades.length === 0,
                          "down, the picture is the font's outline and its five windows: " + (a.parts[0] === rest) + ", " + (rest.split("Z").length - 1) + " contours");
                const box = function (ds) {
                    let x0 = 1e9, x1 = -1e9, y0 = 1e9, y1 = -1e9;
                    for (const d of ds) {
                        const v = win.nums(d);
                        for (let i = 0; i + 1 < v.length; i += 2) {
                            x0 = Math.min(x0, v[i]);
                            x1 = Math.max(x1, v[i]);
                            y0 = Math.min(y0, v[i + 1]);
                            y1 = Math.max(y1, v[i + 1]);
                        }
                    }
                    return [x0, y0, x1, y1];
                };
                const rb = box([rest]);
                // a hair off rest it is the two leaves, and they stand where the rest does
                const near = BridgePose.frame(0.002, 0.002, null, px, ox, oy);
                const nb = box(near.parts);
                const off = Math.max(Math.abs(nb[0] - rb[0]), Math.abs(nb[1] - rb[1]), Math.abs(nb[2] - rb[2]), Math.abs(nb[3] - rb[3]));
                win.check("bridge_near", near.parts.length === 2 && off < 0.05, "a hair off rest: " + near.parts.length + " leaves, their ink box " + off.toFixed(3) + " px off the rest's");
                // raised: the tips part, nothing leaves the glyph's own box, the two leaves are mirrors
                const up = BridgePose.frame(1, 1, null, px, ox, oy);
                const ub = box(up.parts), lb = box([up.parts[0]]), rtb = box([up.parts[1]]);
                const gap15 = (BridgePose.tip(1, null, true)[0] - BridgePose.tip(1, null, false)[0]) * 15 / 2048;
                const inside = ub[0] >= rb[0] - 0.01 && ub[2] <= rb[2] + 0.01 && ub[1] >= rb[1] - 0.01 && ub[3] <= rb[3] + 0.01;
                const mirror = Math.abs((lb[0] - rb[0]) - (rb[2] - rtb[2])) < 0.01 && Math.abs(lb[1] - rtb[1]) < 0.01;
                win.check("bridge_raised", gap15 > 3 && inside && mirror && rtb[0] - lb[2] > 2,
                          "raised: the tips " + gap15.toFixed(2) + " px apart at 15 px (needs > 3), clear ink between the leaves " + (rtb[0] - lb[2]).toFixed(2) + " px, inside the glyph's box " + inside + ", mirrors " + mirror);
                // raised it is FOUR STROKES (tower, leaf, leaf, tower) along every row over the deck, and every gap between two of them is
                // over a pixel at 15 px (the V's foot, where a leaf leaves the deck, aside)
                const u = px / 2048;
                const strokes = function (parts, rowY) {        // [from, to] of each run of ink along a row (font units)
                    const out = [];
                    let on = -1;
                    for (let x = -40.3; x < 1940; x += 6.1) {
                        const ink = win.inkAt(parts, ox + x * u, oy - rowY * u);
                        if (ink && on < 0)
                            on = x;
                        if (!ink && on >= 0) {
                            out.push([on, x]);
                            on = -1;
                        }
                    }
                    return out;
                };
                const one15 = 2048 / 15;
                let worst = 1e9, bad = "";
                for (let y = 640.7; y < 850; y += 34) {
                    const s = strokes(up.parts, y);
                    if (s.length !== 4)
                        bad = s.length + " strokes at " + Math.round(y);
                    for (let i = 1; i < s.length; ++i)
                        worst = Math.min(worst, s[i][0] - s[i - 1][1]);
                }
                win.check("bridge_strokes", bad === "" && worst > one15, "raised: " + (bad === "" ? "four strokes in every row" : bad) + ", the narrowest gap " + (worst / one15).toFixed(2) + " px at 15 px (needs 1)");
                // the salute of a raised bridge keeps its leaves bare (the fold is the state's); one that is down keeps its cable over the
                // deck at the top of its salute
                const dip = BridgePose.frame(1 - D.bowUp, 1 - D.bowUp, null, px, ox, oy, 1, 1);
                let dipBad = "";
                for (const y of [560.7, 620.7, 680.7]) {
                    const n = strokes(dip.parts, y).length;
                    if (n !== 4)
                        dipBad = n + " strokes at " + Math.round(y);
                }
                const lift = BridgePose.frame(D.bowDown, D.bowDown, null, px, ox, oy, 0, 0);
                let runs = 0, was = false;
                for (let y = 300.7; y < 1100; y += 6.1) {
                    const ink = win.inkAt(lift.parts, ox + 650 * u, oy - y * u);
                    runs += ink && !was ? 1 : 0;
                    was = ink;
                }
                win.check("bridge_held", dipBad === "" && runs >= 2, "a raised bridge's dip: " + (dipBad === "" ? "bare leaves" : dipBad) + "; a lowered one's lift keeps its cable over the deck (" + runs + " strokes down its middle, needs 2)");
                // the whole way up nothing pops: the leaves' outlines move by a fraction of a pixel a step, and the step that lets the
                // folded cable go changes no ink
                let stepMax = 0, stepAt = 0, swaps = 0, swapInk = -1;
                for (let i = 1, was = BridgePose.frame(0.002, 0.002, null, px, ox, oy).parts; i <= 110; ++i) {
                    const now = BridgePose.frame(i / 100, i / 100, null, px, ox, oy).parts;
                    const a = win.nums(was[0]), b = win.nums(now[0]);
                    if (a.length !== b.length) {
                        swaps++;
                        const back = BridgePose.frame(D.foldTo - 1e-6, D.foldTo - 1e-6, null, px, ox, oy).parts;
                        swapInk = win.inkDiff(win.inkOf(back, px), win.inkOf(BridgePose.frame(D.foldTo, D.foldTo, null, px, ox, oy).parts, px));
                    } else {
                        for (let j = 0; j < a.length; ++j) {
                            if (Math.abs(a[j] - b[j]) > stepMax) {
                                stepMax = Math.abs(a[j] - b[j]);
                                stepAt = i / 100;
                            }
                        }
                    }
                    was = now;
                }
                win.check("bridge_morph", stepMax < 0.25 && swaps === 1 && swapInk >= 0 && swapInk <= 3, "up in hundredths: at most " + stepMax.toFixed(3) + " px a step (at " + stepAt + ", needs < 0.25), the cable let go of "
                          + swaps + " time, " + swapInk + " samples of ink changed by it (needs <= 3)");
                // the salute reads at 15 px (a quarter turn or more down, a third raised) and never reaches the other state; it never
                // passes through the rest (a leaf does not swing through its pier) and BOUNCES there (it leaves the rest again at
                // least twice after the drop); it is nothing at both ends; the sag is downwards and under a quarter
                let hiDown = 0, loUp = 0, loDown = 0, hiUp = 0, sag = 0, hops = 0, last = 0, falling = false;
                for (let t = 0; t <= D.bowMs; t += 2) {
                    const dn = BridgePose.bow(t, D.bowMs, false, null), up = BridgePose.bow(t, D.bowMs, true, null);
                    hiDown = Math.max(hiDown, dn);
                    loDown = Math.min(loDown, dn);
                    loUp = Math.min(loUp, up);
                    hiUp = Math.max(hiUp, up);
                    if (falling && dn > last && last < 0.02 * D.bowDown)
                        hops++;
                    falling = dn < last;
                    last = dn;
                }
                for (let t = 0; t <= D.settleMs; t += 4)
                    sag = Math.min(sag, BridgePose.settle(t, D.settleMs, null));
                const ends = BridgePose.bow(0, D.bowMs, false, null) === 0 && BridgePose.bow(D.bowMs, D.bowMs, false, null) === 0 && BridgePose.settle(D.settleMs, D.settleMs, null) === 0;
                win.check("bridge_salute", ends && hiDown > 0.4 && hiDown < 0.7 && loUp < -0.25 && loUp > -0.5 && loDown >= 0 && hiUp <= 0 && hops >= 2
                          && sag < -0.1 && sag > -0.25,
                          "down it lifts " + hiDown.toFixed(2) + " of the way up, raised it dips " + (-loUp).toFixed(2) + " of the way down (neither near the other state), through the pier "
                          + Math.min(loDown, -hiUp).toFixed(3) + " (needs 0), bounces " + hops + " (needs 2), the sag " + (-sag).toFixed(3));
                // the whole glyph hops with the salute (up to the share asked, never under the bar, nothing at both ends) and sinks a
                // little with the cable's weight
                let jHi = 0, jLo = 0, cLo = 0;
                for (let t = 0; t <= D.bowMs; t += 2) {
                    jHi = Math.max(jHi, BridgePose.jump(t, D.bowMs, false, null));
                    jLo = Math.min(jLo, BridgePose.jump(t, D.bowMs, false, null));
                }
                for (let t = 0; t <= D.settleMs; t += 2)
                    cLo = Math.min(cLo, BridgePose.jump(t, D.settleMs, true, null));
                win.check("bridge_jump", Math.abs(jHi - D.jump) < 0.01 && jLo >= 0 && cLo < -0.03 && cLo >= -D.sink - 1e-9 && BridgePose.jump(0, D.bowMs, false, null) === 0
                          && BridgePose.jump(D.bowMs, D.bowMs, false, null) === 0,
                          "the glyph hops " + jHi.toFixed(3) + " of its size (asked " + D.jump + "), under the bar " + jLo.toFixed(3) + ", sinks " + (-cLo).toFixed(3) + " with the cable");
                // a car: out of one tower and into the other, the way the data goes; a failure never passes mid span
                const T = BridgeTraffic;
                let okTo = true, okFrom = true, prev = -1e9, prevB = 1e9, far = 0;
                for (let t = 10; t < T.CROSS_MS; t += 10) {
                    const x = T.crossing(t, 1), y = T.crossing(t, -1);
                    okTo = okTo && x > prev && x >= T.FROM && x <= T.TO;
                    okFrom = okFrom && y < prevB && y >= T.FROM && y <= T.TO;
                    prev = x;
                    prevB = y;
                }
                for (let t = 10; t < T.FAIL_MS; t += 10)
                    far = Math.max(far, T.failing(t, 1));
                const carBox = box([T.emit([T.MID], null, px, ox, oy)]);
                const deckTopPx = oy - 484 * px / 2048;
                const onDeck = carBox[3] <= deckTopPx + 0.5 && carBox[3] >= deckTopPx - 0.5 && carBox[2] - carBox[0] > 1.2 && carBox[2] - carBox[0] < 2.2;
                win.check("bridge_cars", okTo && okFrom && T.crossing(0, 1) === null && T.crossing(T.CROSS_MS, 1) === null && far <= T.MID + 1 && far > T.MID - 200
                          && T.failing(T.FAIL_MS, 1) === null && onDeck && T.longX(0, 10, -1) === T.TO && T.longX(10, 10, -1) === T.FROM,
                          "to the phone runs right " + okTo + ", from it left " + okFrom + ", a failure turns at " + Math.round(far) + " (mid span " + T.MID + "), a car " + (carBox[2] - carBox[0]).toFixed(2) + " px wide stands on the deck " + onDeck);
                // the real button: no device -- raised, in the faint ink
                win.park();
                win.check("bridge_none", Qt.colorEqual(bBridge.ink, Theme.textFaint) && bBridge.posing && bBridge.parts.length === 2 && bBridge.liftL === 1 && bBridge.liftR === 1
                          && bBridge.glyph.codePointAt(0) === 0xF0618 && bBridge.carXs.length === 0,
                          "no phone: lifts " + bBridge.liftL + " / " + bBridge.liftR + ", ink " + bBridge.ink + " (faint " + Theme.textFaint + ")");
                const p = win.centre(bBridge);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 260;
            },
            () => {
                const fl = bBridge.flourish;
                win.check("bridge_hover", win.plays.bridge.length === 1 && win.plays.bridge[0] === "hover" && fl.playing && fl.t > 0 && bBridge.liftL < 1 && bBridge.liftL > 0.5
                          && bBridge.carXs.length === 0 && fl.play("again") === false && fl.decorative && fl.group === "bridge",
                          "plays=" + JSON.stringify(win.plays.bridge) + " t " + Math.round(fl.t) + ": a raised bridge dips to " + bBridge.liftL.toFixed(2) + ", no car");
                win.park();
                return fl.ms + 400;
            },
            () => {
                const fl = bBridge.flourish;
                win.check("bridge_ends", !fl.playing && !fl._run.running && bBridge.liftL === 1 && win.plays.bridge.length === 1, "playing=" + fl.playing + " lift " + bBridge.liftL);
                // the first line a service delivers is the state the shell starts in: a phone already there is no news and no motion
                win.phoneLine(win.phoneDevice("kdc:a", "wifi"));
                return 60;
            },
            () => {
                win.check("bridge_seed", win.plays.bridge.length === 1 && bBridge.liftL === 0 && bBridge.liftR === 0 && !bBridge.posing,
                          "the first line: lifts " + bBridge.liftL + " / " + bBridge.liftR + " at once, posing " + bBridge.posing);
                // it goes: the leaves lift
                win.phoneLine(win.phoneDevice("kdc:a", "none"));
                return 900;
            },
            () => {
                win.check("bridge_gone", win.plays.bridge.length === 1 && bBridge.liftL === 1 && bBridge.liftR === 1 && Qt.colorEqual(bBridge.ink, Theme.textFaint), "lifts " + bBridge.liftL + " ink " + bBridge.ink);
                win.phoneLine(win.phoneDevice("kdc:a", "wifi"));
                return 90;
            },
            () => {
                win.mid = bBridge.liftL;
                return 1100;
            },
            () => {
                win.check("bridge_arrive", win.mid > 0 && win.mid < 1 && bBridge.liftL === 0 && bBridge.liftR === 0 && !bBridge.posing && Qt.colorEqual(bBridge.ink, Theme.textMuted) && win.plays.bridge.length === 1,
                          "the leaves come down (" + win.mid.toFixed(2) + " on the way) to the font's glyph, in the plain ink " + Qt.colorEqual(bBridge.ink, Theme.textMuted));
                // the pointer on a bridge that is down: it lifts a little, and no car shows
                const p = win.centre(bBridge);
                win.move(p.x, p.y);
                win.move(p.x + 2, p.y);
                return 260;
            },
            () => {
                win.check("bridge_salute_down", win.plays.bridge.length === 2 && win.plays.bridge[1] === "hover" && bBridge.liftL > 0 && bBridge.liftL < 0.7 && bBridge.jumpPx > 1 && bBridge.carXs.length === 0,
                          "plays=" + JSON.stringify(win.plays.bridge) + " lift " + bBridge.liftL.toFixed(2) + " hop " + bBridge.jumpPx.toFixed(2) + " px, cars " + bBridge.carXs.length);
                win.park();
                return bBridge.flourish.ms + 400;
            },
            () => {
                // onto the cable: the deck sags once, and the ink stays the plain one (connected takes no colour)
                win.phoneLine(win.phoneDevice("kdc:a", "usb"));
                return 200;
            },
            () => {
                win.check("bridge_cable", win.plays.bridge.length === 3 && win.plays.bridge[2] === "cable" && bBridge.liftL !== 0 && Math.abs(bBridge.liftL) < 0.25 && Qt.colorEqual(bBridge.ink, Theme.textMuted),
                          "plays=" + JSON.stringify(win.plays.bridge) + " lift " + bBridge.liftL.toFixed(3) + " ink " + bBridge.ink);
                return bBridge.flourish.ms + 400;
            },
            () => {
                // a cast: one car at a time from the phone, in the accent, a whole step at a time; the bridge keeps its ink
                win.pathChanges = 0;
                win.stepChanges = 0;
                win.phoneLine(win.phoneDevice("kdc:a", "usb"), [{ id: "m1", kind: "mirror", device: "kdc:a", phase: "running" }]);
                return 1500;
            },
            () => {
                const steps = bBridge._castSteps;
                win.check("bridge_cast", bBridge.casting && bBridge.carXs.length <= 1 && win.stepChanges > 3 && Qt.colorEqual(bBridge.traffic.color, Theme.accent)
                          && Qt.colorEqual(bBridge.ink, Theme.textMuted) && !bBridge.posing,
                          "casting " + bBridge.casting + ", cars " + bBridge.carXs.length + ", their ink " + bBridge.traffic.color + " (accent " + Theme.accent + "), the bridge's " + bBridge.ink);
                win.check("bridge_longstep", win.pathChanges <= win.stepChanges + 1 && bBridge.castStepMs >= 90 && steps >= 8 && steps <= 40,
                          "the cast's car is drawn anew " + win.pathChanges + " times for " + win.stepChanges + " steps (" + steps + " device px a crossing, one every " + bBridge.castStepMs + " ms)");
                win.phoneLine(win.phoneDevice("kdc:a", "usb"));
                return 200;
            },
            () => {
                win.check("bridge_cast_ends", !bBridge.casting && bBridge.carXs.length === 0, "cars " + bBridge.carXs.length);
                // a send: a convoy to the phone, in the bridge's own ink
                win.phoneLine(win.phoneDevice("kdc:a", "usb"), [{ id: "s1", kind: "send", device: "kdc:a", phase: "running" }]);
                return 500;
            },
            () => {
                win.mid = bBridge.carXs.length > 0 ? bBridge.carXs[0] : -1;
                return 120;
            },
            () => {
                const x = bBridge.carXs.length > 0 ? bBridge.carXs[0] : -1;
                win.check("bridge_send", bBridge.sending && win.mid > 0 && x > win.mid && Qt.colorEqual(bBridge.traffic.color, bBridge.glyphItem.color),
                          "a car at " + Math.round(win.mid) + " then " + Math.round(x) + " (to the phone: rightwards), in the bridge's ink " + Qt.colorEqual(bBridge.traffic.color, bBridge.glyphItem.color));
                // it fails: the car stops short in the error red and backs off
                win.far = 0;
                win.phoneLine(win.phoneDevice("kdc:a", "usb"), [{ id: "s1", kind: "send", device: "kdc:a", phase: "failed" }]);
                return 450;
            },
            () => {
                win.check("bridge_fail", bBridge.carXs.length === 1 && bBridge.carXs[0] <= BridgeTraffic.MID + 1 && Qt.colorEqual(bBridge.traffic.color, Theme.error),
                          "cars " + bBridge.carXs.length + " at " + (bBridge.carXs.length ? Math.round(bBridge.carXs[0]) : -1) + " (mid span " + BridgeTraffic.MID + "), ink " + bBridge.traffic.color + " (error " + Theme.error + ")");
                return BridgeTraffic.FAIL_MS + 300;
            },
            () => {
                // the same failed job on the next line is no second failure; storage mounted: a car parked at the phone's tower
                win.phoneLine(win.phoneDevice("kdc:a", "usb", true), [{ id: "s1", kind: "send", device: "kdc:a", phase: "failed" }]);
                return 800;
            },
            () => {
                win.check("bridge_parked", bBridge.carXs.length === 1 && Math.abs(bBridge.carXs[0] - BridgeTraffic.PARK) < 1 && Qt.colorEqual(bBridge.traffic.color, bBridge.glyphItem.color),
                          "cars " + JSON.stringify(bBridge.carXs.map(Math.round)) + " (parked at " + BridgeTraffic.PARK + ")");
                // the phone goes; another one ASKS TO PAIR: its leaf comes down alone, in the warn hue
                win.phoneLine(win.phoneDevice("kdc:a", "none"), [], [{ key: "kdc:n", byPeer: true }]);
                return 1100;
            },
            () => {
                win.check("bridge_pair", bBridge.liftR === 0 && bBridge.liftL === 1 && Qt.colorEqual(bBridge.ink, Theme.warn) && bBridge.carXs.length === 0,
                          "lifts " + bBridge.liftL + " (ours) / " + bBridge.liftR + " (the phone's), ink " + bBridge.ink + " (warn " + Theme.warn + ")");
                win.phoneLine(win.phoneDevice("kdc:a", "none"));
                return 900;
            },
            () => {
                // another phone becomes current, already there: the leaves come down, and nothing plays
                win.phoneLine(win.phoneDevice("kdc:b", "wifi"));
                return 1100;
            },
            () => {
                win.check("bridge_switch", win.plays.bridge.length === 3 && !bBridge.flourish.playing && bBridge.liftL === 0, "plays=" + JSON.stringify(win.plays.bridge));
                win.phoneLine(win.phoneDevice("kdc:b", "usb"));
                return 200;
            },
            () => {
                // that phone then comes onto the cable: the sag
                win.check("bridge_news_only", win.plays.bridge.length === 4 && win.plays.bridge[3] === "cable", "plays=" + JSON.stringify(win.plays.bridge));
                return bBridge.flourish.ms + 300;
            },
            () => {
                bBell.flourish.play("hold");
                return 120;
            },
            () => {
                Theme._hosted = true;
                Theme._switching = true;
                win.held.t = bBell.flourish.t;
                return 300;
            },
            () => {
                const t1 = bBell.flourish.t;
                win.check("theme_hold", Theme.crossfading && bBell.flourish.playing && Math.abs(t1 - win.held.t) < 1 && win.held.t > 0,
                          "crossfading=" + Theme.crossfading + " t " + Math.round(win.held.t) + " -> " + Math.round(t1));
                Theme._switching = false;
                Theme._hosted = false;
                return bBell.flourishMs + 600;
            },
            () => {
                win.check("theme_resume", !bBell.flourish.playing && !bBell.flourish._run.running, "playing=" + bBell.flourish.playing);
                return 10;
            },
            () => {
                // the last thing the script does (it changes the mode): the theme button's glyph is the filled swatch in dark too
                Theme.setMode("dark");
                win.held.swatchKey = bTheme.glyphKey;
                return 700;
            },
            () => {
                win.check("swatch_dark", Theme.mode === "dark" && win.held.swatchKey === "f08b5" && bTheme.glyphKey === "f08b5" && bTheme.glyph.codePointAt(0) === 0xF08B5,
                          Theme.mode + " at once " + win.held.swatchKey + " now " + bTheme.glyphKey + " (the filled swatch in both modes)");
                return 10;
            }
        ]

        Timer {
            id: quitTimer
            interval: 50
            onTriggered: Qt.quit()
        }
        Timer {
            running: true
            interval: 1200
            onTriggered: win.run(win.script)
        }
    }
}
