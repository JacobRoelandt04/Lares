pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/bar/reel"
import "modules/shell/ReelItems.js" as ReelItems
import "modules/bar/reel/ReelFlourish.js" as F

// =============================================================================
// reel_flourish_strip.qml -- the reels' flourishes (the power reel's and the idle reel's) as strips of frames, and every reel glyph at
// rest, one PNG per cell
// (tools/dev/reel_flourish_strip.sh runs it on an old tree and on this one and composes the sheets).
//
// The cell is the bar's own: an IconReelView over a ring of the reel's items, 40 x 41 like the bar's cell, on the bar's surface.
// A rest cell is the item snapped into the cell with nothing playing; a strip holds the item's clock at N evenly spaced t
// (FlourishClock.hold: the frame is the pose, not a moment of a running animation) and grabs each. Written for both trees: an
// old tree has no flourishes (the reel lacks the property, and ReelFlourishes does not load), and grabs the rest cells only; a tree
// before the idle reel's flourishes (IdleFlourishes does not load) grabs the power reel's strips alone.
//
//   OUT_DIR   where the cells go -- required
//   N         frames per strip (default 12)
//   SCALE     the cell drawn at this scale (default 1; 1.25 is the user's frame), grabbed at its scaled size
//
// Cells: rest_<reel>_<id>.png; strip_<id>[_<kind>]_<i>.png (the idle reel's: strip_idle_<id>_<i>.png); knock_lock_{dip,rebound}.png (the padlock's engage held where its knock is
// deepest down and up: F.lockPose sampled every 0.5 ms). Prints `REELSTRIP cell <name>` per grab, `REELSTRIP knock ...` (the knock's
// two extremes by the clock) and REELSTRIP RESULT PASS|FAIL.
// =============================================================================
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 200
        implicitHeight: 100
        visible: true
        color: Theme.surface

        readonly property string outDir: Quickshell.env("OUT_DIR") || ""
        readonly property int frames: Math.max(2, Number(Quickshell.env("N") || 12))
        readonly property real zoom: Math.max(0.5, Number(Quickshell.env("SCALE") || 1))

        // the flourishes, where this tree has them
        property var flourishes: null
        property var idleFlourishes: null
        property var shownRing: powerRing
        Component.onCompleted: {
            const comp = Qt.createComponent(Qt.resolvedUrl("modules/bar/reel/ReelFlourishes.qml"));
            if (comp.status === Component.Ready) {
                win.flourishes = comp.createObject(win);
                if ("flourishes" in powerRing)
                    powerRing.flourishes = win.flourishes;
            }
            const idleComp = Qt.createComponent(Qt.resolvedUrl("modules/bar/reel/IdleFlourishes.qml"));
            if (idleComp.status === Component.Ready && "flourishes" in idleRing) {
                win.idleFlourishes = idleComp.createObject(win);
                idleRing.flourishes = win.idleFlourishes;
            }
            win.plan = win._plan();
            stepTimer.start();
        }

        IconReel {
            id: powerRing
            items: ReelItems.POWER
        }
        IconReel {
            id: idleRing
            items: ReelItems.IDLE
        }

        // the grab: the cell at `zoom`, on the bar's surface
        Rectangle {
            id: frame
            width: Math.ceil(40 * win.zoom)
            height: Math.ceil(41 * win.zoom)
            color: Theme.surface
            Rectangle {
                id: cell
                width: 40
                height: 41
                scale: win.zoom
                transformOrigin: Item.TopLeft
                color: Theme.surface
                IconReelView {
                    id: view
                    anchors.fill: parent
                    // through a var: the harness's import path (tools/dev/qml/modules) and the view's own name one type twice to qmllint
                    reel: win.shownRing
                    edge: "top"
                    aFrom: 0
                }
            }
        }

        // ---- the plan: [{ name, reel, id, kind, t, from }] ---------------------------------------------------------------------
        property var plan: []
        property int at: -1
        property int fails: 0

        function _plan(): var {
            const p = [];
            for (const it of ReelItems.POWER)
                p.push({ name: "rest_power_" + it.id, reel: "power", id: it.id });
            for (const it of ReelItems.IDLE)
                p.push({ name: "rest_idle_" + it.id, reel: "idle", id: it.id });
            if (!win.flourishes)
                return p;
            const strips = [
                { id: "sleep", kind: "fire" }, { id: "poweroff", kind: "fire" }, { id: "reboot", kind: "fire" },
                { id: "hibernate", kind: "fire" }, { id: "logout", kind: "fire" },
                { id: "lock", kind: "engage", from: 1 }, { id: "lock", kind: "release", from: 0 }, { id: "lock", kind: "cycle", from: 1 }
            ];
            for (const s of strips)
                for (let i = 0; i < win.frames; i++)
                    p.push({ name: "strip_" + s.id + (s.id === "lock" ? "_" + s.kind : "") + "_" + String(i).padStart(2, "0"), reel: "power",
                             id: s.id, kind: s.kind, t: i / (win.frames - 1), from: s.from === undefined ? 1 : s.from });
            if (win.idleFlourishes)
                for (const it of ReelItems.IDLE)
                    for (let i = 0; i < win.frames; i++)
                        p.push({ name: "strip_idle_" + it.id + "_" + String(i).padStart(2, "0"), reel: "idle", id: it.id, kind: "hover",
                                 t: i / (win.frames - 1), from: 1 });
            p.push({ name: "rest_power_lock_shut", reel: "power", id: "lock", shut: true });
            // the knock's deepest dip and rebound, held where the clock puts them (the shackle is shut by then: the rest is the shut cell)
            const k = win._knockExtremes();
            console.log("REELSTRIP knock dip " + k.dip.toFixed(3) + " px at " + k.dipMs + " ms, rebound " + (-k.up).toFixed(3) + " px at " + k.upMs
                        + " ms (of " + F.lockMs("engage") + ")");
            p.push({ name: "knock_lock_dip", reel: "power", id: "lock", kind: "engage", t: k.dipMs / F.lockMs("engage"), from: 1 });
            p.push({ name: "knock_lock_rebound", reel: "power", id: "lock", kind: "engage", t: k.upMs / F.lockMs("engage"), from: 1 });
            return p;
        }

        function _knockExtremes(): var {
            const ms = F.lockMs("engage");
            const r = { dip: 0, dipMs: 0, up: 0, upMs: 0 };
            for (let i = 0; i <= ms * 2; i++) {
                const kn = F.lockPose("engage", i / 2 / ms, 1).knock;
                if (kn > r.dip) {
                    r.dip = kn;
                    r.dipMs = i / 2;
                }
                if (kn < r.up) {
                    r.up = kn;
                    r.upMs = i / 2;
                }
            }
            return r;
        }

        function _apply(step: var): void {
            const ring = step.reel === "idle" ? idleRing : powerRing;
            win.shownRing = ring;
            ring.snapTo(ReelItems.indexOf(step.reel === "idle" ? ReelItems.IDLE : ReelItems.POWER, step.id));
            if (!win.flourishes)
                return;
            for (const it of ReelItems.POWER)
                win.flourishes.clockOf(it.id).stop();
            if (win.idleFlourishes)
                for (const it of ReelItems.IDLE)
                    win.idleFlourishes.clockOf(it.id).stop();
            win.flourishes.shut = step.shut === true;
            const set = step.reel === "idle" ? win.idleFlourishes : win.flourishes;
            if (step.kind && set)
                set.clockOf(step.id).hold(step.kind, step.t, step.from);
        }

        Timer {
            id: stepTimer
            interval: 80
            onTriggered: {
                win.at += 1;
                if (win.at >= win.plan.length) {
                    console.log("REELSTRIP RESULT " + (win.fails === 0 && win.outDir !== "" ? "PASS" : "FAIL") + " (" + win.plan.length + " cells, " + win.fails + " failed)");
                    quitTimer.start();
                    return;
                }
                win._apply(win.plan[win.at]);
                grabTimer.start();
            }
        }
        // one more beat for the pose's bindings and a frame, then the grab
        Timer {
            id: grabTimer
            interval: 60
            onTriggered: {
                const step = win.plan[win.at];
                const ok = frame.grabToImage(r => {
                    if (!r.saveToFile(win.outDir + "/" + step.name + ".png"))
                        win.fails += 1;
                    console.log("REELSTRIP cell " + step.name);
                    stepTimer.start();
                });
                if (!ok) {
                    win.fails += 1;
                    stepTimer.start();
                }
            }
        }
        Timer {
            id: quitTimer
            interval: 0
            onTriggered: Qt.quit()
        }
    }
}
