pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import QtTest
import Quickshell
import Quickshell.Io

import "modules/common/theme"
import "modules/common/components"
import "modules/common/float"
import "modules/notes"
import "modules/weather"
import "modules/weather/data"

// =============================================================================
// float_probe.qml -- the card float (modules/common/float) where it is mounted: the notes tiles and the weather popup. Run by
// tools/dev/float_probe.sh, which gives it a private config / state (the crossfade check switches the mode) and a copy of the notes fixtures.
//
//   FLOAT_SUBJECT=notes|weather   what is hosted (nothing: the file loads and quits, as a bare smoke run does)
//   FLOAT_NOTES=<dir>             the notes the store reads (a copy)
//   FLOAT_STRIP=<dir>             no checks: the HELD-clock strip -- the deal and three seconds of sway at fixed times, then (notes) a tile
//                                 leaned on and picked up -- one PNG a frame, <t ms>.png
//   FLOAT_MEASURE=1               no checks: the clock RUNNING at rest (no pointer), then `FM` lines -- where 3 s of ticks came from (frames,
//                                 its own rest timer, the host's beat), and the JS cost of one tick (600 ticks timed). FLOAT_OFF=1: the weather
//                                 popup with cardFloat false, the A/B. Offscreen: a frame is not a clock here, so the rates are the clock's own
//                                 counts; QSG_RENDER_TIMING=1 in the environment prints Qt's per-frame polish/sync/render beside them.
//
// The checks run on a HELD clock (the host's `running` false, the clock stepped by hand at 1/60 s: exact, repeatable times) except where
// the clock's own running is the subject (the rest beat, the crossfade, the gate). Each prints `FP ok|FAIL <what>`; the last line is
// `FP RESULT PASS|FAIL (<n>/<n> checks)`.
//   notes   the deal (a tile starts below its place, every tile lands), the sway (moves, bounded; the + slot never sways), a press on a lifted
//           tile's corner past its cell opens that tile, the ghost leaves from the tile's pose, a drag calms every tile to rest and stops
//           the clock, the release brings the sway back, the rest beat (slow at rest, every frame the moment the pointer is on a tile),
//           the faces held as textures while the clock runs and plain when it stops, the hold under a theme crossfade, the gate
//   weather the deal (the wide cards and the tiles), the sway (the tiles move, the wide cards do not), the layers (the strip held, the
//           tiles' host not; each tile's face held), the rest beat is the backdrop's, a click on a lifted tile's corner opens its detail,
//           parked: no tick, shown again: dealt again
// =============================================================================
ShellRoot {
    id: probe
    settings.watchFiles: false

    readonly property string subject: Quickshell.env("FLOAT_SUBJECT") || ""
    readonly property string stripDir: Quickshell.env("FLOAT_STRIP") || ""
    readonly property string notesDir: Quickshell.env("FLOAT_NOTES") || ""
    readonly property string stateDir: Quickshell.env("XDG_STATE_HOME") || "/tmp"
    readonly property bool measure: Quickshell.env("FLOAT_MEASURE") === "1"
    readonly property bool floatOff: Quickshell.env("FLOAT_OFF") === "1"

    property int checks: 0
    property int fails: 0
    function check(ok: bool, what: string): void {
        probe.checks++;
        if (!ok)
            probe.fails++;
        console.log("FP " + (ok ? "ok " : "FAIL ") + what);
    }
    function finish(): void {
        console.log("FP RESULT " + (probe.fails === 0 && probe.checks > 0 ? "PASS" : "FAIL") + " (" + (probe.checks - probe.fails) + "/" + probe.checks + " checks)");
        Qt.quit();
    }

    Window {
        id: win
        visible: probe.subject !== ""
        width: probe.subject === "weather" ? 1220 : 700
        height: probe.subject === "weather" ? 760 : 600
        color: Theme.surface

        Item {
            id: body
            anchors.fill: parent

            // An opaque ground: a grab of a transparent item lies about its fading pixels (CLAUDE.md).
            Rectangle {
                anchors.fill: parent
                color: Theme.surface
            }

            Loader {
                id: notesHost
                x: 30
                y: 20
                active: probe.subject === "notes" && probe.notesDir !== ""
                sourceComponent: Component {
                    Item {
                        id: nh
                        readonly property alias store: notesStore
                        readonly property alias popup: notesPopup
                        NotesStore {
                            id: notesStore
                            root: probe.notesDir
                            statePath: probe.stateDir + "/float-probe-notes.json"
                            defaultBrowseSize: ({
                                    w: 640,
                                    h: 540,
                                    shift: 0
                                })
                        }
                        NotesPopup {
                            id: notesPopup
                            store: notesStore
                            fontFamily: "Inter"
                            motionRunning: false
                            width: implicitWidth
                            height: implicitHeight
                        }
                    }
                }
            }

            Loader {
                id: weatherHost
                x: 20
                y: 20
                active: probe.subject === "weather"
                sourceComponent: Component {
                    Item {
                        readonly property alias popup: weatherPopup
                        WeatherMock {
                            id: weatherMock
                        }
                        WeatherPopup {
                            id: weatherPopup
                            service: weatherMock
                            viewMode: "detailed"
                            eagerCards: true
                            fontFamily: "Inter"
                            backdropRunning: false
                            cardFloat: !probe.floatOff
                            width: implicitWidth
                            height: implicitHeight
                        }
                    }
                }
            }
        }
        ThemeCrossfade {
            target: body
            anchors.fill: parent
        }
    }

    // The process's CPU time (utime + stime, clock ticks of 10 ms) for the measure: all its threads, the render thread too.
    FileView {
        id: selfStat
        path: probe.measure ? "/proc/self/stat" : ""
        blockAllReads: true
        printErrors: false
    }
    function cpuMs(): real {
        selfStat.reload();
        const t = selfStat.text();
        const f = t.substring(t.lastIndexOf(")") + 2).split(" ");
        return (Number(f[11]) + Number(f[12])) * 10;
    }

    TestCase {
        id: tc
        name: "float"
        when: false
    }

    // ---- helpers ----------------------------------------------------------------------------------------------------------------------------
    function find(item: Item, name: string): var {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (let i = 0; i < item.children.length; i++) {
            const r = probe.find(item.children[i], name);
            if (r)
                return r;
        }
        return null;
    }
    function step(clock: FloatClock, secs: real): void {
        const n = Math.round(secs * 60);
        for (let i = 0; i < n; i++)
            clock._tick(1 / 60);
    }
    function poseOf(c: FloatCard): var {
        return {
            x: c.poseX,
            y: c.poseY,
            rot: c.poseRot,
            lift: c.poseLift
        };
    }
    function moved(a: var, b: var): real {
        return Math.max(Math.abs(a.x - b.x), Math.abs(a.y - b.y), Math.abs(a.rot - b.rot) * 50);
    }
    // A point of an item in the window, and the resting rect of a card (its parent's place: the card's transform is its own).
    function at(item: Item, x: real, y: real): point {
        return item.mapToItem(win.contentItem, x, y);
    }
    // The pointer to (x, y) in the window, arriving from a pixel to the left: a motion, as a hand makes one.
    function moveTo(x: real, y: real): void {
        tc.mouseMove(win.contentItem, x - 1, y);
        tc.mouseMove(win.contentItem, x, y);
    }
    // The drawn corner of a card that reaches farthest past its resting rect r (window px), 1.5 px inside the card: where a click must
    // still land on it. `past` is how far that corner stands outside r.
    function farCorner(c: FloatCard, r: var): var {
        let best = null;
        const ins = [[1.5, 1.5], [c.width - 1.5, 1.5], [1.5, c.height - 1.5], [c.width - 1.5, c.height - 1.5]];
        for (const q of ins) {
            const p = probe.at(c, q[0], q[1]);
            const past = Math.max(r.x - p.x, p.x - (r.x + r.w), r.y - p.y, p.y - (r.y + r.h));
            if (!best || past > best.past)
                best = {
                    p: p,
                    past: past
                };
        }
        return best;
    }
    function grab(name: string, then: var): void {
        win.contentItem.grabToImage(r => {
            r.saveToFile(probe.stripDir + "/" + name + ".png");
            then();
        });
    }

    // ---- the run: a list of steps, each polled every 20 ms until it says it is done ------------------------------------------------------
    property var steps: []
    property int stepAt: 0
    property real stepStarted: 0
    property var mem: ({})
    Timer {
        id: driver
        interval: 20
        repeat: true
        onTriggered: {
            if (probe.stepAt >= probe.steps.length) {
                driver.stop();
                probe.finish();
                return;
            }
            const waited = Date.now() - probe.stepStarted;
            let r = false;
            try {
                r = probe.steps[probe.stepAt](waited);
            } catch (e) {
                probe.check(false, "step " + probe.stepAt + " threw: " + e);
                r = true;
            }
            if (r === "wait")
                return;
            if (r === true || waited > 15000) {
                if (r !== true)
                    probe.check(false, "step " + probe.stepAt + " timed out");
                probe.stepAt++;
                probe.stepStarted = Date.now();
            }
        }
    }
    function start(list: var): void {
        probe.steps = list;
        probe.stepAt = 0;
        probe.stepStarted = Date.now();
        driver.start();
    }

    // ---- notes ------------------------------------------------------------------------------------------------------------------------------
    readonly property var np: notesHost.item ? notesHost.item.popup : null
    readonly property var ns: notesHost.item ? notesHost.item.store : null
    readonly property var ng: probe.np ? probe.find(probe.np, "notesGrid") : null

    function notesSteps(): var {
        const m = probe.mem;
        const ready = () => probe.ng && probe.ns && probe.ns.service.ready && probe.ng.order.length >= 5 && probe.ng._cardOf(probe.ng.order[2]) !== null;
        const clock = () => probe.np.floatClock;
        const card = i => probe.ng._cardOf(probe.ng.order[i]);
        return [
            () => ready(),
            // the deal
            () => {
                probe.step(clock(), 1 / 60);
                probe.check(card(2).poseY > 10, "deal: the third tile starts below its place (" + card(2).poseY.toFixed(2) + " px)");
                probe.check(probe.ng._cardOf("+").poseY > 10, "deal: the + slot is dealt too (" + probe.ng._cardOf("+").poseY.toFixed(2) + " px)");
                probe.step(clock(), 1.4);
                const amp = probe.np.floatStyle.moveAmpMax;
                let worst = 0;
                for (let i = 0; i < probe.ng.order.length; i++) {
                    const c = probe.ng._cardOf(probe.ng.order[i]);
                    if (c && c.visible)
                        worst = Math.max(worst, Math.abs(c.poseY), Math.abs(c.poseX));
                }
                probe.check(worst <= amp + 0.01, "deal: every shown tile has landed (worst offset " + worst.toFixed(2) + " px, sway max " + amp + ")");
                return true;
            },
            // the sway
            () => {
                const a = probe.poseOf(card(1)), b0 = probe.poseOf(card(3));
                probe.step(clock(), 1.5);
                const da = probe.moved(a, probe.poseOf(card(1))), db = probe.moved(b0, probe.poseOf(card(3)));
                probe.check(da > 0.05 && db > 0.05, "sway: tiles move (" + da.toFixed(2) + ", " + db.toFixed(2) + ")");
                probe.check(Math.abs(card(1).poseY - card(3).poseY) > 0.01 || Math.abs(card(1).poseX - card(3).poseX) > 0.01, "sway: two tiles are not in step");
                const p = probe.ng._cardOf("+");
                probe.check(p.poseX === 0 && p.poseY === 0 && p.poseRot === 0, "sway: the + slot never sways");
                return true;
            },
            // a press on a lifted tile's corner, past its cell
            () => {
                const c = card(1);
                const slot = c.parent;
                const r0 = probe.at(slot, 0, 0);
                m.hitKey = probe.ng.order[1];
                m.rest = {
                    x: r0.x,
                    y: r0.y,
                    w: slot.width,
                    h: slot.height
                };
                // well inside the card (a point near its edge is one the sway can carry the card off)
                probe.moveTo(r0.x + slot.width * 0.8, r0.y + slot.height * 0.75);
                return true;
            },
            w => {
                if (w < 60)
                    return "wait";
                probe.step(clock(), 0.8);
                const c = card(1);
                const k = probe.farCorner(c, m.rest);
                const p = k.p;
                probe.check(c.poseLift > 0.9, "lean: the tile under the pointer lifts (" + c.poseLift.toFixed(2) + ")");
                probe.check(k.past >= 1, "hit: a corner of the lifted, leaning tile reaches past its cell (" + k.past.toFixed(1) + " px)");
                probe.moveTo(p.x, p.y);
                tc.mouseClick(win.contentItem, p.x, p.y);
                probe.check(probe.ns.view === "editor" && probe.ns.noteKey === m.hitKey, "hit: a press on the drawn corner opens that tile (view " + probe.ns.view + ")");
                return true;
            },
            w => {
                if (probe.np._m)
                    probe.np._finishNow();
                if (probe.ns.view === "editor") {
                    probe.np.goBack();
                    if (probe.np._m)
                        probe.np._finishNow();
                }
                probe.moveTo(3, win.height - 3);
                return probe.ns.view === "browse";
            },
            w => {
                if (w < 200)
                    return "wait";
                probe.step(clock(), 1.0);
                return true;
            },
            // a drag: the ghost leaves from the tile's pose, every tile calms to rest and the clock stops
            () => {
                const c = card(2);
                const slot = c.parent;
                const mid = probe.at(slot, slot.width / 2, slot.height / 2);
                m.dragKey = probe.ng.order[2];
                m.before = probe.ng.poseOf(m.dragKey);
                m.mid = mid;
                probe.moveTo(mid.x, mid.y);
                tc.mousePress(win.contentItem, mid.x, mid.y);
                probe.moveTo(mid.x + 4, mid.y + 3);
                probe.moveTo(mid.x + 12, mid.y + 8);
                return true;
            },
            w => {
                if (probe.ng.dragKey === "")
                    return w > 2000;
                const ghost = probe.find(win.contentItem, "dragGhost");
                const gi = ghost ? ghost.item : null;
                probe.check(probe.ng._liftPose !== null && Math.abs(probe.ng._liftPose.x - m.before.x) < 1e-9 && Math.abs(probe.ng._liftPose.rot - m.before.rot) < 1e-9, "drag: the ghost holds the pose the tile was drawn at");
                probe.check(!!gi && Math.abs(gi.poseX - m.before.x * (1 - ghost.liftF)) < 1e-6, "drag: the ghost lets go of it as it lifts");
                probe.check(clock().calm === true, "drag: the grid asks for calm");
                probe.step(clock(), 0.4);
                let worst = 0;
                for (let i = 0; i < probe.ng.order.length; i++) {
                    const c = probe.ng._cardOf(probe.ng.order[i]);
                    if (c && c.visible && probe.ng.order[i] !== m.dragKey)
                        worst = Math.max(worst, Math.abs(c.poseX), Math.abs(c.poseY), Math.abs(c.poseRot));
                }
                probe.check(clock().sway === 0 && worst < 1e-9, "calm: the sway eased to rest during the drag (sway " + clock().sway.toFixed(3) + ", worst " + worst.toExponential(1) + ")");
                probe.check(clock()._idle === true, "calm: at rest the clock stops (idle)");
                tc.mouseRelease(win.contentItem, m.mid.x + 12, m.mid.y + 8);
                return true;
            },
            w => {
                if (w < 400 || probe.ng.floatCalm)
                    return w > 3000 ? true : "wait";
                probe.check(!probe.ng.floatCalm, "calm: let go once the drop has settled");
                probe.step(clock(), 0.15);
                const mid = clock().sway;
                probe.step(clock(), 0.7);
                probe.check(mid > 0 && mid < 1 && clock().sway === 1, "calm: the sway comes back on its ease (" + mid.toFixed(2) + " after 150 ms, " + clock().sway + " after 850)");
                return true;
            },
            // the clock's own running: the rest beat
            () => {
                probe.moveTo(3, win.height - 3);
                probe.np.motionRunning = true;
                return true;
            },
            w => {
                if (w < 300 || (clock().everyFrame && w < 5000))
                    return "wait";
                m.st = {
                    own: clock().stats.own,
                    frames: clock().stats.frames
                };
                return true;
            },
            w => {
                if (w < 600)
                    return "wait";
                const nt = card(1).children[0].item;
                probe.check(!!nt && nt.faceLayered === true, "layers: a floating tile's face is one held texture while the clock runs");
                probe.check(clock().ticking && !clock().everyFrame && clock().stats.frames === m.st.frames && clock().stats.own - m.st.own >= 5, "beat: at rest the sway ticks on the slow beat, not every frame (" + (clock().stats.own - m.st.own) + " slow ticks, " + (clock().stats.frames - m.st.frames) + " frame ticks in 600 ms)");
                const c = card(1);
                const mid = probe.at(c.parent, c.parent.width / 2, c.parent.height / 2);
                probe.moveTo(mid.x, mid.y);
                probe.check(clock().everyFrame, "beat: every frame the moment the pointer is on a tile");
                probe.moveTo(3, win.height - 3);
                return true;
            },
            w => {
                if (w < 1500)
                    return "wait";
                probe.check(clock().ticking && !clock().everyFrame, "beat: slow again once the tile has settled");
                m.mode = Theme.mode;
                Theme.setMode(Theme.mode === "light" ? "dark" : "light");
                return true;
            },
            // the theme crossfade: held
            w => {
                if (!Theme.crossfading)
                    return w > 3000 ? true : "wait";
                m.xf = probe.poseOf(card(1));
                m.xfTicking = clock().ticking;
                return true;
            },
            w => {
                if (w < 120 && Theme.crossfading)
                    return "wait";
                probe.check(m.xf !== undefined, "crossfade: one ran");
                if (m.xf !== undefined)
                    probe.check(!m.xfTicking && probe.moved(m.xf, probe.poseOf(card(1))) === 0, "crossfade: the tiles stand still under it");
                return true;
            },
            w => {
                if (Theme.crossfading || w < 400)
                    return "wait";
                probe.check(clock().ticking, "crossfade: the clock runs again after it");
                Theme.setMode(m.mode);
                return true;
            },
            w => {
                if (Theme.crossfading || w < 300)
                    return "wait";
                probe.np.motionRunning = false;
                probe.check(!clock().ticking, "gate: not on screen, no tick");
                return true;
            },
            w => {
                if (w < 100)
                    return "wait";
                const nt = card(1).children[0].item;
                probe.check(!!nt && nt.faceLayered === false, "layers: the faces are the plain scene graph again when the clock stops");
                return true;
            }
        ];
    }

    // ---- weather ----------------------------------------------------------------------------------------------------------------------------
    readonly property var wp: weatherHost.item ? weatherHost.item.popup : null
    function tiles(): var {
        const g = probe.wp ? probe.wp.tileGrid : null;
        const out = [];
        if (!g)
            return out;
        for (let i = 0; i < g.children.length; i++) {
            const t = g.children[i];
            if (t && t.metric !== undefined && t.card !== undefined)
                out.push(t);
        }
        out.sort((a, b) => a.cell - b.cell);
        return out;
    }
    function weatherSteps(): var {
        const m = probe.mem;
        const clock = () => probe.wp.floatClock;
        return [
            () => probe.wp && probe.wp.model && probe.tiles().length === 10,
            () => {
                const t = probe.tiles();
                probe.step(clock(), 1 / 60);
                probe.check(probe.wp._heroDeal > 0.8 && probe.wp._listDeal > 0.95, "deal: the hero and the list start below their places (" + probe.wp._heroDeal.toFixed(2) + ", " + probe.wp._listDeal.toFixed(2) + ")");
                probe.check(t[0].card.poseY > 10, "deal: the first tile starts below its place (" + t[0].card.poseY.toFixed(2) + " px)");
                probe.step(clock(), 1.6);
                probe.check(probe.wp._heroDeal === 0 && probe.wp._stripDeal === 0 && probe.wp._listDeal === 0, "deal: the hero, the strip and the list have landed, exactly");
                let worst = 0;
                for (const x of t)
                    worst = Math.max(worst, Math.abs(x.card.poseY), Math.abs(x.card.poseX));
                probe.check(worst <= probe.wp.floatStyle.moveAmpMax + 0.01, "deal: every tile has landed (worst " + worst.toFixed(2) + " px)");
                return true;
            },
            () => {
                const t = probe.tiles();
                const a = probe.poseOf(t[0].card), b = probe.poseOf(t[7].card);
                probe.step(clock(), 1.5);
                probe.check(probe.moved(a, probe.poseOf(t[0].card)) > 0.05 && probe.moved(b, probe.poseOf(t[7].card)) > 0.05, "sway: the tiles move");
                probe.check(probe.wp._heroDeal === 0 && probe.wp._stripDeal === 0 && probe.wp._listDeal === 0, "sway: the hero, the strip and the list do not");
                return true;
            },
            // a click on a lifted tile's corner, past its resting rect
            () => {
                const t = probe.tiles()[4];
                const r0 = probe.at(t, 0, 0);
                m.tile = t;
                m.rest = {
                    x: r0.x,
                    y: r0.y,
                    w: t.width,
                    h: t.height
                };
                probe.moveTo(r0.x + t.width * 0.8, r0.y + t.height * 0.75);
                return true;
            },
            w => {
                if (w < 60)
                    return "wait";
                probe.step(clock(), 0.8);
                const c = m.tile.card;
                const k = probe.farCorner(c, m.rest);
                const p = k.p;
                probe.check(c.poseLift > 0.9, "lean: the tile under the pointer lifts (" + c.poseLift.toFixed(2) + ")");
                probe.check(k.past >= 1, "hit: a corner of the lifted, leaning tile reaches past its rest (" + k.past.toFixed(1) + " px)");
                probe.moveTo(p.x, p.y);
                tc.mouseClick(win.contentItem, p.x, p.y);
                const sk = probe.wp.secondaryKey;
                probe.check(probe.wp.secondaryOpen && !!sk && sk.metric === m.tile.metric, "hit: a click on the drawn corner opens that tile's detail (" + (sk ? sk.metric : "none") + ")");
                probe.wp.secondaryOpen = false;
                probe.moveTo(3, win.height - 3);
                return true;
            },
            // shown: the layers, the beat
            () => {
                probe.wp.backdropRunning = true;
                return true;
            },
            w => {
                if (w < 1200)
                    return "wait";
                probe.check(probe.wp._layered && probe.wp.hourlyStrip.parent.layer.enabled && probe.wp.dailyList.parent.layer.enabled, "layers: the strip and the list are held as layers while the float runs");
                probe.check(!probe.wp.tileGrid.parent.layer.enabled, "layers: the tiles' host is not (its tiles move every tick)");
                probe.check(probe.tiles().every(t => t.faceHeld), "layers: each tile's face is one held texture instead");
                probe.check(clock().ticking && !clock().everyFrame, "beat: at rest the sway is not on every frame");
                m.st = {
                    own: clock().stats.own,
                    beats: clock().stats.beats
                };
                return true;
            },
            w => {
                if (w < 1000)
                    return "wait";
                const own = clock().stats.own - m.st.own, beats = clock().stats.beats - m.st.beats;
                probe.check(beats >= 8 && own <= 1, "beat: the rest ticks are the backdrop's (" + beats + " beats, " + own + " of its own in 1 s)");
                probe.wp.parked = true;
                return true;
            },
            w => {
                if (w < 100)
                    return "wait";
                probe.check(!clock().ticking, "gate: parked, no tick");
                probe.wp.parked = false;
                probe.check(clock().dealAge < 0.05 && clock().ticking, "gate: shown again, it deals again");
                probe.wp.backdropRunning = false;
                return true;
            }
        ];
    }

    // ---- the strip --------------------------------------------------------------------------------------------------------------------------
    readonly property var stripTimes: [0, 33, 67, 100, 150, 200, 267, 350, 450, 550, 700, 900, 1200, 1700, 2200, 2700, 3200, 3700]
    function stripSteps(): var {
        const m = probe.mem;
        const notes = probe.subject === "notes";
        const clock = () => notes ? probe.np.floatClock : probe.wp.floatClock;
        const ready = () => notes ? (probe.ng && probe.ns && probe.ns.service.ready && probe.ng.order.length >= 5 && probe.ng._cardOf(probe.ng.order[2]) !== null) : (probe.wp && probe.wp.model && probe.tiles().length === 10);
        // the faces held as textures, as they are while the clock runs (it is held here and stepped by hand)
        const list = [w => {
                if (!ready() || w < 300)
                    return "wait";
                clock().layers = true;
                return true;
            }, w => w > 100];
        m.t = 0;
        m.fi = 0;
        for (let i = 0; i < probe.stripTimes.length; i++) {
            const t = probe.stripTimes[i];
            list.push(() => {
                const n = Math.round((t - m.t) / 1000 * 60);
                for (let k = 0; k < n; k++)
                    clock()._tick(1 / 60);
                m.t += n * 1000 / 60;
                m.shot = false;
                probe.grab(("0000" + t).slice(-4) + "ms", () => m.shot = true);
                return true;
            });
            list.push(() => m.shot === true);
        }
        // a tile leaned on, then picked up
        const target = () => notes ? probe.ng._cardOf(probe.ng.order[1]).parent : probe.tiles()[4];
        list.push(() => {
            const s = target();
            const p = probe.at(s, s.width * 0.82, s.height * 0.78);
            probe.moveTo(p.x, p.y);
            return true;
        });
        list.push(w => {
            if (w < 60)
                return "wait";
            clock()._tick(1 / 60);
            for (let k = 0; k < 35; k++)
                clock()._tick(1 / 60);
            m.shot = false;
            probe.grab("lean", () => m.shot = true);
            return true;
        });
        list.push(() => m.shot === true);
        if (notes) {
            list.push(() => {
                const s = target();
                const p = probe.at(s, s.width * 0.82, s.height * 0.78);
                m.p = p;
                tc.mousePress(win.contentItem, p.x, p.y);
                probe.moveTo(p.x + 4, p.y + 4);
                probe.moveTo(p.x + 9, p.y + 7);
                m.shot = false;
                probe.grab("pickup", () => m.shot = true);
                return true;
            });
            list.push(() => m.shot === true);
            list.push(w => {
                if (w < 250)
                    return "wait";
                for (let k = 0; k < 15; k++)
                    clock()._tick(1 / 60);
                probe.moveTo(m.p.x + 60, m.p.y + 30);
                m.shot = false;
                probe.grab("carried", () => m.shot = true);
                return true;
            });
            list.push(() => m.shot === true);
            list.push(() => {
                tc.mouseRelease(win.contentItem, m.p.x + 60, m.p.y + 30);
                return true;
            });
        }
        return list;
    }

    // ---- the measure ------------------------------------------------------------------------------------------------------------------------
    function measureSteps(): var {
        const m = probe.mem;
        const notes = probe.subject === "notes";
        const clock = () => notes ? probe.np.floatClock : probe.wp.floatClock;
        const ready = () => notes ? (probe.ng && probe.ns && probe.ns.service.ready && probe.ng.order.length >= 5 && probe.ng._cardOf(probe.ng.order[2]) !== null) : (probe.wp && probe.wp.model && probe.tiles().length === 10);
        return [
            w => {
                if (!ready())
                    return "wait";
                tc.mouseMove(win.contentItem, 2, win.height - 2);
                if (notes)
                    probe.np.motionRunning = !probe.floatOff;
                else
                    probe.wp.backdropRunning = true;
                return true;
            },
            // the deal lands and the clock slows; then three seconds at rest
            w => {
                if (w < 2500)
                    return "wait";
                const st = clock().stats;
                m.st = {
                    frames: st.frames,
                    own: st.own,
                    beats: st.beats,
                    at: Date.now(),
                    cpu: probe.cpuMs()
                };
                console.log("FM rest begins");
                return true;
            },
            w => {
                if (w < 3000)
                    return "wait";
                const st = clock().stats, secs = (Date.now() - m.st.at) / 1000;
                console.log("FM rest " + probe.subject + (probe.floatOff ? " float off" : "") + ": in " + secs.toFixed(2) + " s of wall " + (st.frames - m.st.frames) + " frame ticks, "
                            + (st.own - m.st.own) + " own rest ticks, " + (st.beats - m.st.beats) + " host beats; every frame: " + clock().everyFrame + ", cards " + clock().cardCount);
                const cpu = probe.cpuMs() - m.st.cpu;
                console.log("FM cpu " + probe.subject + (probe.floatOff ? " float off" : "") + ": " + cpu + " ms of the process's CPU in " + secs.toFixed(2) + " s at rest (" + (cpu / secs / 10).toFixed(1) + " % of a core, 10 ms ticks)");
                console.log("FM rest ends");
                const c = clock();
                const t0 = Date.now();
                for (let i = 0; i < 600; i++)
                    c._tick(1 / 60);
                const t1 = Date.now();
                console.log("FM tick " + probe.subject + ": " + ((t1 - t0) * 1000 / 600).toFixed(1) + " us of JS a tick (600 ticks, " + c.cardCount + " cards registered)");
                return true;
            }
        ];
    }

    Timer {
        interval: 0
        running: true
        onTriggered: {
            if (probe.subject === "") {
                Qt.quit();
                return;
            }
            if (probe.measure)
                probe.start(probe.measureSteps());
            else if (probe.stripDir !== "")
                probe.start(probe.stripSteps());
            else
                probe.start(probe.subject === "notes" ? probe.notesSteps() : probe.weatherSteps());
        }
    }
}
