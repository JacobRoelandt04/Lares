pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/common/components"
import "modules/shell"

// =============================================================================
// oled_shift_probe.qml -- the OLED care (OledShift + ShellFrame's zone rows) on the MOCK shell: ONE ShellFrame over mock services in a
// hidden-from-the-desktop offscreen window (tools/dev/oled_shift_probe.sh runs it, at SCALE 1 and 1.25).
//
// What it holds the shell to:
//   nine    the orbit visits all nine places of the 3 x 3 square; at each the bar's modules stand off their centre place by EXACTLY the
//           orbit's step in DEVICE px (a whole number: measured in the window, whose pixel ratio is 1 here, so a device px is a window px)
//   ends    at each place the islands' FREE ends (the left island's right end, both ends of the centre island, the right island's left
//           end) stand off their centre place by exactly the step's x, and nothing else of the bars moves: the ends on the screen's corners,
//           the islands' thickness (their bottom edge), the slim bars and the reserve
//   margins at each place the room between each free end and the module beside it is the one at the centre (the ink gap kept)
//   drawn   at each place the engine's field draws each island on its bar's rect and the island's input rect is that rect
//   hold    a step taken while the island lengths move keeps every island inside the input rect held for the move
//   lane    a toast out on the top-right corner (the notifications' default spot, which the right island's corner end holds) does not
//           move by a hair while a step moves the right island's start under its owner's spot (the spot is asked again: a new key)
//   defer   a popup out holds the step: `shift()` says it waits, nothing moves; the popup closes and the step is taken at once
//   strip   the power reel's strip stays level with its cell at every one of the nine places; a step asked while the strip is OUT waits
//   state   the state file holds {step} (an old file's "on" is ignored); a second OledShift on the same file starts where the first stood
//           (a restart)
//   off     shell.jsonc's `oled.enabled` false (the ONE switch, read hot through ShellConfig) puts the content back at the centre, true
//           resumes the step it had
//   ipc     the two verbs the shell's IPC target calls (shift / status) answer in words and one line of JSON
// Prints `OLEDSHIFT ok|FAIL <check>` and `OLEDSHIFT RESULT PASS|FAIL (<n>/<n> checks)`. With OLEDSHIFT_GRABS=<dir> it also saves the window
// at the places 0 (0,0), 1 (1,0) and 5 (-1,0), and at (0,0) again after the ring as p9, as s<scale>-p<k>.png, on an opaque ground, and prints `OLEDSHIFT geom <json>` (the islands' ends
// at the centre, window px): tools/dev/oled_shift_pixels.py judges the pictures (the runner always does).
//
// THE WAIT. The script starts when the shell says it has SETTLED (ShellServices.settled, `LARES settled`: every frame's prewarm is
// done), never at `ready` plus a pause: the prewarm builds each parked popup in one event (a 3 500-item weather, the LLM) between the
// script's steps -- the engine does not count the reel's strip as a popup, so the builds land while the strip opens and closes -- and
// each build is a GUI-thread stall of 0.2-0.8 s on a quiet machine and up to 5 s on a loaded one. A step waits for the thing's own
// state (polled every tick), and its deadline counts LIVE time: a tick spends at most four intervals of it, because a stalled GUI
// thread moves nothing (an animation advances only when the thread runs), so a stall must not spend the wait; a wall ceiling of four
// budgets still ends a run that stalls for good. A wait that runs out says what is still out (every slot not closed, the flourishes,
// the holders) and both clocks.
// =============================================================================
ShellRoot {
    id: root

    readonly property real scale: Number(Quickshell.env("SCALE") || 1)
    property int checks: 0
    property int fails: 0

    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("OLEDSHIFT " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    // 2880 px wide: the user's panel, so at SCALE 1.25 the frame is their 2304 design px and the islands stand at their own lengths
    // (a narrower window squeezes the title's slot past the left island's end)
    FloatingWindow {
        id: win
        implicitWidth: 2880
        implicitHeight: 700
        visible: true
        color: "#808080"

        ShellServices {
            id: mockServices
            mode: "mock"
            windowless: true
        }
        // the scene on an opaque ground (a grab over nothing reads the halo's alpha, not its colour): what `grab` saves
        Rectangle {
            id: scene
            anchors.fill: parent
            color: "#808080"
        }
        ScaleRoot {
            parent: scene
            factor: root.scale
            hostWidth: win.width
            hostHeight: win.height
            Loader {
                id: frameLoader
                anchors.fill: parent
                active: mockServices.ready
                sourceComponent: Component {
                    ShellFrame {
                        services: mockServices
                        screenName: "eDP-1"
                        renderScale: root.scale
                        frameScale: root.scale
                    }
                }
            }
        }
    }

    readonly property var frame: frameLoader.item
    readonly property var oled: mockServices.oled
    Component {
        id: oledComp
        OledShift {}
    }
    FileView {
        id: oldFile
        blockWrites: true
        atomicWrites: false
        printErrors: false
    }

    // ---- measuring: window px; a device px is a window px here ----
    function at(item: Item): point {
        return item.mapToItem(null, 0, 0);
    }
    // an item's box in the window
    function boxOf(item: Item): var {
        const a = item.mapToItem(null, 0, 0);
        const b = item.mapToItem(null, item.width, item.height);
        return { x0: a.x, y0: a.y, x1: b.x, y1: b.y };
    }
    function barById(id: string): var {
        for (const b of root.frame.engine.barsList)
            if (b && b.barId === id)
                return b;
        return null;
    }
    readonly property var islandIds: ["topL", "topC", "topR"]
    // the islands and the slim bars, and the slots of the modules beside the islands' ends (ModuleSlot: a button's parent)
    function placeOf(): var {
        const f = root.frame;
        const bars = {};
        for (const id of root.islandIds.concat(["right", "bottom", "left"]))
            bars[id] = root.boxOf(root.barById(id));
        const slots = {};
        for (const id of ["windowtray", "weather", "stocks", "player"])
            slots[id] = root.boxOf(f.buttons[id].parent);
        return {
            theme: root.at(f.buttons.theme), power: root.at(f.buttons.power),
            bars: bars, slots: slots, reserve: JSON.stringify(f.engine.edgeReserve)
        };
    }
    // the room between each free end and the module beside it, window px
    function marginsOf(p: var): var {
        return {
            "left island's right end": p.bars.topL.x1 - p.slots.windowtray.x1,
            "centre island's left end": p.slots.weather.x0 - p.bars.topC.x0,
            "centre island's right end": p.bars.topC.x1 - p.slots.stocks.x1,
            "right island's left end": p.slots.player.x0 - p.bars.topR.x0
        };
    }
    // the engine's field (the one child that counts bodies), found once
    property var _field: null
    function fieldOf(): var {
        if (root._field)
            return root._field;
        const walk = it => {
            if (it.maxBodies !== undefined && it.bodies !== undefined)
                return it;
            for (const c of it.children) {
                const r = walk(c);
                if (r)
                    return r;
            }
            return null;
        };
        root._field = walk(root.frame.engine);
        return root._field;
    }
    // what the field draws and what takes input differ from the islands' bars, in words ("" = nothing): the field's body of each island is
    // its bar's rect along the edge, and one input rect is that rect whole-pixelled (GooeyEngine.layout: floor / ceil)
    function drawnOff(): string {
        const e = root.frame.engine;
        const fld = root.fieldOf();
        let why = "";
        for (const id of root.islandIds) {
            const b = root.barById(id);
            const x0 = b.absX, x1 = b.absX + b.absW;
            const body = fld ? (fld.bodies || []).find(q => q.id === "bar:" + id) : null;
            if (!body || !root.near(body.x0, x0) || !root.near(body.x1, x1))
                why += id + " drawn at " + (body ? body.x0.toFixed(3) + ".." + body.x1.toFixed(3) : "nothing") + " not " + x0.toFixed(3) + ".." + x1.toFixed(3) + "; ";
            const m0 = Math.floor(x0), m1 = Math.ceil(x1);
            if (!e.maskItems.some(m => m && m.width > 0 && m.x === m0 && m.x + m.width === m1))
                why += id + " has no input rect " + m0 + ".." + m1 + "; ";
        }
        return why;
    }
    // the strip's centre minus the cell's centre, along the bar (window x)
    function stripOffset(): var {
        const m = root.frame.buttons.power;
        const pv = m.popupView;
        if (!pv)
            return null;
        const c = root.at(m.cellItem);
        const s = root.at(pv);
        return (s.x + pv.width / 2) - (c.x + m.cellItem.width / 2);
    }

    // ---- the sequencer: wait for a condition (polled), with a deadline; every step is guarded ----
    property var _q: []
    property var _cur: null
    property real _since: 0
    // THE WAIT (header): the live ms the current step has spent, and the last tick's wall time
    property real _spent: 0
    property real _lastTick: 0
    function step(label: string, run: var, until: var, ms: int): void {
        root._q = root._q.concat([{ label: label, run: run, until: until, ms: ms || 6000 }]);
    }
    Timer {
        id: seqTick
        interval: 25
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            const dt = root._lastTick > 0 ? Math.min(now - root._lastTick, 4 * seqTick.interval) : 0;
            root._lastTick = now;
            if (!root._cur) {
                if (root._q.length === 0)
                    return;
                root._cur = root._q[0];
                root._q = root._q.slice(1);
                root._since = now;
                root._spent = 0;
                try {
                    root._cur.run();
                } catch (e) {
                    root.check(root._cur.label + " (threw)", false, String(e));
                    root._cur = null;
                }
                return;
            }
            root._spent += dt;
            let done = false;
            try {
                done = !root._cur.until || root._cur.until();
            } catch (e) {
                done = false;
            }
            if (done) {
                root._cur = null;
            } else if (root._spent > root._cur.ms || now - root._since > 4 * root._cur.ms) {
                root.check(root._cur.label + " (waited)", false, "timed out after " + Math.round(root._spent) + " live ms, " + (now - root._since) + " wall ms; out: " + root.outNow());
                root._cur = null;
            }
        }
    }
    // What is out right now, in words (a wait that runs out prints it): every slot not closed, every power-reel flourish that plays, the
    // bell's and the player's, and the OLED's holders.
    function outNow(): string {
        const f = root.frame;
        if (!f)
            return "no frame";
        const e = f.engine;
        const parts = [];
        const slots = { popup: e.thePopup, child0: e.childPopups[0], child1: e.childPopups[1], child2: e.childPopups[2], reel: e.theReel, reelChild: e.reelChildPopups[0], reelChild2: e.reelChildPopups[1], reelChild3: e.reelChildPopups[2] };
        for (const k in slots)
            if (slots[k] && slots[k].phase !== "closed")
                parts.push(k + "=" + slots[k].phase);
        const pf = f.buttons.power.flourishes;
        if (pf)
            for (const id of ["sleep", "poweroff", "reboot", "hibernate", "logout", "lock"])
                if (pf[id].playing)
                    parts.push("flourish " + id + " " + pf[id].kind + " t=" + pf[id].t.toFixed(3));
        if (f.buttons.notifications.flourish.playing)
            parts.push("bell flourish");
        if (f.buttons.player.flourishing)
            parts.push("player flourish");
        parts.push("pinnedOpen=" + f.owners.power.pinnedOpen + " oledHeld=" + f.oledHeld + " settled=" + mockServices.settled);
        parts.push("oled " + root.oled.status());
        return parts.join("; ");
    }
    function allClosed(): bool {
        const e = root.frame.engine;
        return e.thePopup.phase === "closed" && e.theReel.phase === "closed" && e.theReelChild.phase === "closed" && !root.oled.busy;
    }

    // ---- the script ----
    property var base: null
    property real strip0: 0
    property var seen: ({})
    readonly property var orbit: [[0, 0], [1, 0], [1, 1], [0, 1], [-1, 1], [-1, 0], [-1, -1], [0, -1], [1, -1]]

    function near(a: real, b: real): bool {
        return Math.abs(a - b) < 0.01;
    }
    function judgePlace(k: int, tag: string): void {
        const p = root.placeOf();
        const o = root.orbit[k];
        const b = root.base;
        let ok = true;
        let why = "";
        for (const m of ["theme", "power"]) {
            const dx = p[m].x - b[m].x;
            const dy = p[m].y - b[m].y;
            if (!root.near(dx, o[0]) || !root.near(dy, o[1])) {
                ok = false;
                why += m + " moved (" + dx.toFixed(3) + "," + dy.toFixed(3) + ") not (" + o[0] + "," + o[1] + "); ";
            }
        }
        root.check("nine: " + tag + " step " + k + " stands at (" + o[0] + "," + o[1] + ") device px", ok, why);

        // the ends: [left, right] of each island moves by the step's x where it is free, by nothing on a corner
        const want = { topL: [0, o[0]], topC: [o[0], o[0]], topR: [o[0], 0] };
        let ends = "";
        for (const id of root.islandIds) {
            const d = [p.bars[id].x0 - b.bars[id].x0, p.bars[id].x1 - b.bars[id].x1];
            const free = [id !== "topL", id !== "topR"];
            for (const i of [0, 1])
                if (!root.near(d[i], want[id][i]))
                    ends += id + " " + (i === 0 ? "left" : "right") + " (" + (free[i] ? "free" : "corner") + ") end moved " + d[i].toFixed(3) + " not " + want[id][i] + "; ";
            if (!root.near(p.bars[id].y0, b.bars[id].y0) || !root.near(p.bars[id].y1, b.bars[id].y1))
                ends += id + " thickness moved; ";
        }
        for (const id of ["right", "bottom", "left"])
            for (const q of ["x0", "y0", "x1", "y1"])
                if (!root.near(p.bars[id][q], b.bars[id][q]))
                    ends += "the slim bar " + id + " moved (" + q + "); ";
        if (p.reserve !== b.reserve)
            ends += "the reserve moved " + p.reserve + " vs " + b.reserve + "; ";
        root.check("ends: " + tag + " step " + k + " the free ends stand " + o[0] + " device px off the centre's; the corner ends, the thickness, the slim bars and the reserve still", ends === "", ends);

        // the room between each free end and its module
        const mp = root.marginsOf(p), mb = root.marginsOf(b);
        let room = "";
        for (const key in mb)
            if (!root.near(mp[key], mb[key]))
                room += key + " " + mp[key].toFixed(3) + " not " + mb[key].toFixed(3) + "; ";
        root.check("margins: " + tag + " step " + k + " the room between each free end and its module is the centre's", room === "", room);

        const drawn = root.drawnOff();
        root.check("drawn: " + tag + " step " + k + " the field draws each island on its bar, and its input rect is the bar's", drawn === "", drawn);
    }

    // ---- the pictures (OLEDSHIFT_GRABS): the window at three places (and the centre again after the ring: 9), for tools/dev/oled_shift_pixels.py ----
    readonly property string grabDir: Quickshell.env("OLEDSHIFT_GRABS") || ""
    readonly property var grabPlaces: [0, 1, 5]
    property int _grabbed: -1
    function grab(k: int): void {
        root._grabbed = -1;
        const ok = scene.grabToImage(r => {
            r.saveToFile(root.grabDir + "/s" + root.scale + "-p" + k + ".png");
            root._grabbed = k;
        });
        if (!ok)
            root.check("grab " + k + " could be asked", false, "grabToImage refused");
    }
    function geomLine(): string {
        const p = root.base;
        const r = id => [p.bars[id].x0, p.bars[id].x1];
        return "OLEDSHIFT geom " + JSON.stringify({ scale: root.scale, w: win.width, h: win.height, top: p.bars.topL.y1, topL: r("topL"), topC: r("topC"), topR: r("topR"), slim: p.bars.left.x1 });
    }

    // ---- the hold: a step while the island lengths move ----
    property string _holdBad: ""
    property int _holdSamples: 0
    function sampleHold(): void {
        const f = root.frame;
        const held = f.maskHold;
        if (!held)
            return;
        root._holdSamples++;
        for (const id of root.islandIds) {
            const b = root.barById(id);
            const h = held[id];
            if (!h || h.x0 > b.rawPos + 1e-6 || h.x1 < b.rawPos + b.rawLen - 1e-6)
                root._holdBad = id + " stands at " + b.rawPos.toFixed(3) + ".." + (b.rawPos + b.rawLen).toFixed(3) + " outside its held rect " + (h ? h.x0.toFixed(3) + ".." + h.x1.toFixed(3) : "none") + " (lenT " + f.lenT.toFixed(3) + ")";
        }
    }

    Component.onCompleted: {
        // start: the frame exists; the state file starts absent (the runner makes a fresh dir)
        root.step("frame up", () => {}, () => !!root.frame && root.frame.ready && root.frame.buttons.theme.width > 0 && root.allClosed(), 20000);
        // THE WAIT: after the prewarm, never inside it
        root.step("settled", () => {}, () => mockServices.settled && root.allClosed(), 60000);
        root.step("baseline", () => {
            root.check("state: a fresh start is on at the centre", root.oled.on && root.oled.dx === 0 && root.oled.dy === 0 && root.oled.step === 0, root.oled.status());
            root.base = root.placeOf();
            if (root.grabDir !== "")
                console.log(root.geomLine());
        });

        // nine places, each with the strip level with its cell
        for (let k = 0; k < 9; k++) {
            ((kk) => {
                root.step("place " + kk, () => {
                    if (kk > 0) {
                        const r = root.oled.shift();
                        root.check("nine: shift " + kk + " answers a step", r.indexOf("stepped to") === 0, r);
                    }
                }, () => root.near(root.at(root.frame.buttons.theme).x - root.base.theme.x, root.orbit[kk][0]), 3000);
                // the engine lays the bars out on the next frame's polish: wait for the field (a wait that runs out is a failure of its own)
                root.step("drawn " + kk, () => {}, () => root.drawnOff() === "", 3000);
                root.step("judge " + kk, () => root.judgePlace(kk, "scale " + root.scale), () => true);
                if (root.grabDir !== "" && root.grabPlaces.indexOf(kk) >= 0)
                    root.step("grab " + kk, () => root.grab(kk), () => root._grabbed === kk, 8000);
                root.step("open strip " + kk, () => { root.frame.owners.power.pinnedOpen = true; },
                    () => root.frame.engine.theReel.phase === "open" && !!root.frame.buttons.power.popupView, 8000);
                root.step("strip level " + kk, () => {
                    const off = root.stripOffset();
                    if (kk === 0)
                        root.strip0 = off;
                    root.check("strip: at step " + kk + " the strip is level with its cell (offset " + off.toFixed(3) + " vs " + root.strip0.toFixed(3) + " at the centre)", root.near(off, root.strip0), "off by " + (off - root.strip0).toFixed(3));
                }, () => true);
                root.step("close strip " + kk, () => { root.frame.owners.power.pinnedOpen = false; }, () => root.allClosed(), 8000);
            })(k);
        }
        // the 10th shift closes the ring: back at the centre
        root.step("ring closes", () => {
            root.oled.shift();
        }, () => root.near(root.oled.dx, 0) && root.near(root.oled.dy, 0) && root.oled.step === 0, 3000);
        root.step("ring drawn", () => {}, () => root.drawnOff() === "", 3000);
        root.step("ring judged", () => root.judgePlace(0, "after the ring"), () => true);
        if (root.grabDir !== "")
            root.step("grab 9", () => root.grab(9), () => root._grabbed === 9, 8000);

        // the step waits for a popup
        root.step("popup open", () => { root.frame.owners.theme.toggle(); }, () => root.frame.engine.thePopup.phase === "open", 10000);
        root.step("shift under a popup", () => {
            root._before = root.placeOf();
            root._ans = root.oled.shift();
        }, () => true);
        root.step("defer: judged", () => {
            const a = root.placeOf();
            root.check("defer: with a popup out the step waits, says so, and nothing moves", root._ans.indexOf("waiting") === 0 && root.oled.pending && root.oled.dx === 0 && root.oled.dy === 0 && root.near(a.theme.x, root._before.theme.x) && root.near(a.theme.y, root._before.theme.y), root._ans + " | " + root.oled.status());
            const again = root.oled.shift();
            root.check("defer: a second ask while one waits adds no step", again.indexOf("waiting") === 0 && root.oled.step === 1, again + " step=" + root.oled.step);
            root.check("defer: the status names the holder", root.oled.status().indexOf("eDP-1") >= 0 && JSON.parse(root.oled.status()).pending === true, root.oled.status());
        });
        root.step("popup close", () => { root.frame.owners.theme.toggle(); }, () => root.frame.engine.thePopup.phase === "closed", 10000);
        root.step("defer: taken", () => {}, () => root.oled.dx === 1 && root.oled.dy === 0 && root.drawnOff() === "", 3000);
        root.step("defer: taken judged", () => {
            root.check("defer: closing the popup takes the step at once (nothing pending, one step taken)", !root.oled.pending && root.oled.taken >= 1, root.oled.status());
            root.judgePlace(1, "after the wait");
        });

        // a step asked while the strip is out waits, and the strip stays level
        root.step("strip open for the wait", () => { root.frame.owners.power.pinnedOpen = true; }, () => root.frame.engine.theReel.phase === "open" && !!root.frame.buttons.power.popupView, 8000);
        root.step("shift under the strip", () => {
            root._s0 = root.stripOffset();
            root._ans = root.oled.shift();
        }, () => true);
        root.step("strip wait: judged", () => {
            root.check("strip: a step asked while the strip is out waits (the strip is not left behind)", root._ans.indexOf("waiting") === 0 && root.near(root.stripOffset(), root._s0) && root.near(root.stripOffset(), root.strip0), root._ans + " offset " + root.stripOffset() + " vs " + root.strip0);
        });
        root.step("strip close", () => { root.frame.owners.power.pinnedOpen = false; }, () => root.allClosed() && !root.oled.pending, 8000);
        root.step("strip reopen", () => { root.frame.owners.power.pinnedOpen = true; }, () => root.frame.engine.theReel.phase === "open" && !!root.frame.buttons.power.popupView, 8000);
        root.step("strip reopen: judged", () => {
            root.check("strip: reopened after the step it is level with its cell at (" + root.oled.dx + "," + root.oled.dy + ")", root.near(root.stripOffset(), root.strip0), root.stripOffset() + " vs " + root.strip0);
        });
        root.step("strip close 2", () => { root.frame.owners.power.pinnedOpen = false; }, () => root.allClosed(), 8000);

        // the state survives a restart
        root.step("state read back", () => {
            const mine = root.oled.step;
            const o = oledComp.createObject(win.contentItem, { statePath: root.oled.statePath });
            root.check("state: a second OledShift on the same file starts where the first stood (step " + mine + ")", !!o && o.step === mine && o.on && o.dx === root.oled.dx && o.dy === root.oled.dy, o ? o.status() : "no object");
            if (o)
                o.destroy();
            const none = oledComp.createObject(win.contentItem, { statePath: "" });
            root.check("state: with no file it starts on at the centre", !!none && none.on && none.dx === 0 && none.dy === 0, none ? none.status() : "no object");
            if (none)
                none.destroy();
            // a file from before the switch moved to the config still holds the saved "on": it loads, the step is kept, the "on" is ignored
            oldFile.path = root.oled.statePath + ".old";
            oldFile.setText('{"on": false, "step": 4}\n');
            const old = oledComp.createObject(win.contentItem, { statePath: root.oled.statePath + ".old" });
            root.check("state: a file that still holds the old \"on\" loads: the step is kept, the switch is the config's", !!old && old.step === 4 && old.on, old ? old.status() : "no object");
            if (old)
                old.destroy();
            const junk = oledComp.createObject(win.contentItem, { statePath: "/etc/hostname" });
            root.check("state: a file that is not ours starts it on at the centre", !!junk && junk.on && junk.dx === 0, junk ? junk.status() : "");
            if (junk)
                junk.destroy();
        });

        // off and on, and the words the IPC returns
        root.step("off", () => {
            mockServices.shellConfig.apply({ oled: { enabled: false } });
            root.check("off: the config switch puts the content back at the centre at once", !root.oled.on && root.oled.dx === 0 && root.oled.dy === 0, root.oled.status());
            const s = JSON.parse(root.oled.status());
            root.check("ipc: status is one line of JSON (on=false, nextInS=null)", s.on === false && s.nextInS === null && s.x === 0 && s.y === 0, root.oled.status());
            root.check("ipc: shift while off moves nothing and says so", root.oled.shift().indexOf("off") === 0 && root.oled.dx === 0, "");
        }, () => root.near(root.at(root.frame.buttons.theme).x, root.base.theme.x) && root.near(root.at(root.frame.buttons.theme).y, root.base.theme.y), 3000);
        root.step("shift off alone", () => {
            mockServices.shellConfig.apply({ oled: { shift: false, shiftEveryS: 60 } });
            root.check("shift: its own switch leaves the content at the centre and the flourishes on", !root.oled.on && root.oled.dx === 0
                && root.frame.flourishScheduler.on === true, root.oled.status() + " " + root.frame.flourishScheduler.on);
            root.check("shift: the seconds between two steps are the config's", root.oled.intervalMs === 60000, String(root.oled.intervalMs));
        }, () => true);
        root.step("on", () => {
            mockServices.shellConfig.apply({ oled: { enabled: true } });
            root.check("on: the config switch resumes the step it had", root.oled.on && root.oled.step === 2, root.oled.status());
            const s = JSON.parse(root.oled.status());
            root.check("ipc: status carries the place, the target and the next step's time", s.on === true && s.step === 2 && s.x === 1 && s.y === 1 && s.target.x === 1 && s.nextInS > 0, root.oled.status());
        }, () => true);

        // the hold: the island lengths move slowly (a title that grows the left island), and a step that changes x is taken in the
        // middle of the move (from (1,1) to (0,1): the centre island and the right island's left end move a device px left); every
        // island must stay inside the input rect held for the move on every tick until the move ends
        root.step("hold: a short title", () => {
            root.frame.lengthsMs = 3000;
            root.frame.buttons.windowtray.window.setWindow({ cls: "kitty", title: "~" });
        }, () => root.frame.lenT >= 1 && !root.frame.maskHold, 10000);
        root.step("hold: a long title", () => {
            root.frame.buttons.windowtray.window.setWindow({ title: "a title long enough to grow the left island by a good many pixels" });
        }, () => root.frame.lenT > 0 && root.frame.lenT < 0.4 && !!root.frame.maskHold, 5000);
        root.step("hold: a step in the move", () => {
            root._holdBad = "";
            root._holdSamples = 0;
            const r = root.oled.shift();
            root.check("hold: the step is taken while the lengths move (" + r + ")", r.indexOf("stepped to") === 0 && root.oled.dx === 0, r);
            root.sampleHold();
        }, () => {
            root.sampleHold();
            return root.frame.lenT >= 1;
        }, 10000);
        root.step("hold: judged", () => {
            root.check("hold: a step taken while the island lengths move keeps every island inside its held input rect (" + root._holdSamples + " samples)", root._holdBad === "" && root._holdSamples > 5, root._holdBad || "too few samples");
            root.frame.lengthsMs = 180;
        });

        // the lane: a toast on the top-right corner, then a step from (0,1) to (-1,1) -- the right island's start moves, its length with it,
        // so the spot's key changes and the owner asks the engine again; the stack stands on the corner, which never moves
        root.step("lane: a toast", () => {
            root.frame.owners.notifications.service.post({ source: "oledprobe", key: "oled", appName: "Shell test", title: "Backup",
                                                           body: "Backup completed in 41 s.", urgency: "normal", timeoutMs: 60000 });
        }, () => root.frame.engine.laneOpen && root.frame.engine.theLane.phase === "open", 10000);
        // (the bell plays its flourish for a new notification, and a flourish holds the step: the step is taken once it has played)
        root.step("lane: the bell has played", () => {}, () => !root.oled.busy, 10000);
        root.step("lane: a step beside it", () => {
            const L = root.frame.engine.theLane;
            root._laneBox = [L.popX, L.popY, L.popW, L.popH];
            root._laneKey = root.frame.owners.notifications._askedKey;
            root._laneWorst = 0;
            root._laneTicks = 0;
            root._ans = root.oled.shift();
        }, () => {
            const L = root.frame.engine.theLane;
            const now = [L.popX, L.popY, L.popW, L.popH];
            for (let i = 0; i < 4; i++)
                root._laneWorst = Math.max(root._laneWorst, Math.abs(now[i] - root._laneBox[i]));
            return ++root._laneTicks >= 30;
        }, 5000);
        root.step("lane: judged", () => {
            const asked = root.frame.owners.notifications._askedKey !== root._laneKey;
            root.check("lane: a toast on the top-right corner stays put while a step moves the right island's start (worst " + root._laneWorst.toFixed(4) + " px over " + root._laneTicks + " ticks; asked again: " + asked + ")",
                       root._ans.indexOf("stepped to") === 0 && root.oled.dx === -1 && root._laneWorst < 0.01 && root.frame.engine.theLane.phase === "open", root._ans + " | box " + root._laneBox);
            root.frame.owners.notifications.service.withdraw("oledprobe", "oled");
        });
        root.step("end", () => {
            console.log("OLEDSHIFT RESULT " + (root.fails === 0 && root.checks > 70 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks, scale " + root.scale + ")");
            Qt.quit();
        });
    }
    property var _before: null
    property string _ans: ""
    property real _s0: 0
    property var _laneBox: []
    property string _laneKey: ""
    property real _laneWorst: 0
    property int _laneTicks: 0
}
