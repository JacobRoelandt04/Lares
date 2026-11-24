pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// Every directory mockups/shell.qml takes types from: a file built by URL finds a directory's types only while a file
// quickshell scanned imports it (CLAUDE.md, Quickshell).
import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"
import "modules/osd"
import "modules/shell"

// =============================================================================
// tools/dev/qml/gooey_aura_probe.qml -- THE AURA of the REAL shell frame, frame by frame (tools/dev/gooey_aura_probe.sh;
// GooeyEngine: THE AURA, gooey_field.frag: THE AURA).
//
// mockups/shell.qml (the shell's own ShellFrame on its mock services, one 2880 x 1620 output at zoom 1) is built here as a
// component -- the runner copies this file into the sandbox copy's mockups/ to run it. The aura is asked the way the user's
// dictation asks it (ShellServices.playAura("siri", "all", 600000), then ShellServices.releaseAura()), and its ONE clock is
// HELD: the clock's animation is paused and the clock written by hand, a frame's worth (1000 / 60 ms) at a time, so every
// frame is a grab of a known moment and the engine's own release / play runs between two of them exactly as it would.
//
// Env:  AU_OUT=<dir>   AU_STEPS=<step>;<step>...
//   pose:<tag>:<seed>:<clock ms>[:mono][:g=<group>]   the aura held at that seed and clock (level 1 inside its life); `mono` lays one
//                                         colour (the palette's first) round the whole cycle, so the ink is the level and the reach alone;
//                                         `g=` plays that group (all, island, side) instead of all
//   off:<tag>                             the same stage with no aura (the surface and the border alone)
//   seq:<tag>:<how>                       frames across a way out or a hand-over: 8 frames held on, then <how>, then 8 frames:
//                                         release   ShellServices.releaseAura() (the dictation's end)
//                                         replay    ShellServices.playAura("siri", "all", 600000) again (the take's renewal)
//                                         palette   ShellServices.playAura("ok", "all", 600000) (a play replaced by another)
//                                         group     the first play in the island group, then ShellServices.playAura("siri", "all",
//                                                   600000): the dictation take's press and its model running (a group handed over)
//                                         life      a play of 300 ms life whose clock runs into its own way out (no call)
//                                         back      the way out begun before the first frame, then a play again (the level turns
//                                                   round where it is: a play over a play in its way out)
//   do:<tag>:<what>                       a SCENE for the steps after it, left up until the next `do`: what the shell shows round a popup
//                                         osd       the mic card, unmuted (the dictation take's unmute), held up for the run
//                                         osdat=<bar>,<along>   the same card at another spot (osd.jsonc `spot`)
//                                         toast     one notification in the lane
//                                         open=<k>  a primary from its owner (mockups/shell.qml openOwner: notes, player, weather, ...)
//                                         wiki      the clock popup with the wiki card hanging from it (its secondary)
//                                         close     the popup closed, the OSD let go, the toasts gone
//                                         Then it prints AUSCENE <tag> body <i> id=<id> box=<x0,y0,x1,y1> host=<id> parent=<id> mobile=<0|1>,
//                                         AUSCENE <tag> fillet <i> key=<key> v=<x,y> e=<x,y> and AUSCENE <tag> seam <i> box=<...> (stage px).
// Prints AUFRAME <tag> <k> time=<the field's auraTime> level=<auraLevel> colors=<hex,...> mode=<m> cycles=<a,b,c> png=<file> for
// every frame of a seq, AUPOSE <tag> png=<file> for a pose, AUBODY lines (the bodies' boxes in stage px) once, then AUPROBE DONE.
// Nothing here is a verdict: the runner's judge reads the PNGs and the lines.
// =============================================================================
Scope {
    id: rig

    readonly property string out: Quickshell.env("AU_OUT") || ""
    readonly property var steps: (Quickshell.env("AU_STEPS") || "").split(";").filter(x => x !== "")
    property var win: null
    readonly property var engine: rig.win && rig.win.frame ? rig.win.frame.engine : null
    readonly property var services: rig.win && rig.win.frame ? rig.win.frame.services : null
    readonly property real frameMs: 1000 / 60

    Component.onCompleted: {
        if (rig.out === "") {
            console.log("AUPROBE no AU_OUT: nothing to do");
            quitLater.start();
            return;
        }
        const c = Qt.createComponent(Qt.resolvedUrl("shell.qml"));
        if (c.status !== Component.Ready) {
            console.log("AUPROBE the shell mockup did not build: " + c.errorString());
            quitLater.start();
            return;
        }
        rig.win = c.createObject(null, {});
        tick.interval = 4000;
        tick.start();
    }
    Timer {
        id: quitLater
        interval: 0
        onTriggered: Qt.quit()
    }

    // ---- the schedule: one action at a time; an action that grabs goes on when its grab has landed -------------------------
    property var queue: []
    property bool _built: false
    property int _settleWaits: 0
    Timer {
        id: tick
        repeat: false
        onTriggered: rig.next()
    }
    function push(ms, fn) {
        rig.queue.push({ ms: ms, fn: fn });
    }
    function next() {
        if (!rig._built) {
            const sv = rig.services;
            if (sv && sv.settled === false && rig._settleWaits++ < 120) {
                tick.interval = 500;
                tick.start();
                return;
            }
            rig._built = true;
            rig.bodies();
            for (const s of rig.steps)
                rig.plan(s.split(":"));
        }
        if (rig.queue.length === 0) {
            console.log("AUPROBE DONE");
            quitLater.start();
            return;
        }
        const a = rig.queue.shift();
        const wait = a.fn();
        // a grab answers by calling next() itself
        if (wait === true)
            return;
        tick.interval = Math.max(1, a.ms);
        tick.start();
    }

    // ---- the clock, held --------------------------------------------------------------------------------------------------
    // The engine's aura clock is one NumberAnimation on `_auraClock`; it is paused (not stopped: a stop runs its end) after every
    // call that (re)starts it, and the clock written by hand.
    function clockAnim() {
        const list = rig.engine.resources;
        for (let i = 0; i < list.length; i++) {
            const o = list[i];
            if (o && o.property === "_auraClock")
                return o;
        }
        return null;
    }
    function hold() {
        const a = rig.clockAnim();
        if (a && a.running && !a.paused)
            a.pause();
        return a !== null;
    }
    // The engine's GooeyField (no alias: found among its children by what only it has).
    function field() {
        const list = rig.engine.children;
        for (let i = 0; i < list.length; i++)
            if (list[i] && ("auraCycles" in list[i]))
                return list[i];
        return null;
    }
    function bodies() {
        const E = rig.engine;
        const scene = rig.win.sheetGrabItem;
        const F = rig.field();
        const bs = F ? F.bodies : [];
        for (let i = 0; i < (bs ? bs.length : 0); i++) {
            const b = bs[i];
            const p0 = E.mapToItem(scene, b.x0, b.y0), p1 = E.mapToItem(scene, b.x1, b.y1);
            console.log("AUBODY " + i + " id=" + b.id + " box=" + [p0.x, p0.y, p1.x, p1.y].map(v => v.toFixed(2)).join(","));
        }
    }

    // ---- the scenes (`do:`) ---------------------------------------------------------------------------------------------------
    function scene(whatAsked) {
        let what = whatAsked;
        const fr = rig.win.frame;
        if (what.indexOf("osdat=") === 0) {
            // the OSD's spot moved first (osd.jsonc `spot`: a bar and where along it), then the card: beside a stack on the same bar
            // it melts with it (the field's PEERS)
            const w = what.slice(6).split(",");
            fr.owners.osd.spot = { bar: w[0], along: Number(w[1]) };
            what = "osd";
        }
        if (what === "osd") {
            // the card a take's unmute shows (OsdKinds.sampleRequest("mic"), unmuted), held up for the run
            const ok = rig.services.osd.show({ kind: "mic", key: "in", value: 0.6, max: 1, muted: false, boost: false,
                                               device: { type: "mic", name: "Built-in Microphone" }, ms: 600000 });
            console.log("AUPROBE scene osd: " + ok);
        } else if (what === "toast") {
            rig.win.post(1, "normal");
        } else if (what.indexOf("open=") === 0) {
            rig.win.openOwner(what.slice(5));
        } else if (what === "wiki") {
            fr.owners.clock.openWiki("discover");
        } else if (what === "close") {
            if (rig.engine.thePopup.live)
                rig.engine.close();
            rig.services.osd.dismiss();
        } else {
            console.log("AUPROBE unknown scene " + what);
        }
    }
    function sceneLines(tag) {
        const E = rig.engine;
        const scene = rig.win.sheetGrabItem;
        const F = rig.field();
        const at = (x, y) => {
            const q = E.mapToItem(scene, x, y);
            return q.x.toFixed(2) + "," + q.y.toFixed(2);
        };
        const bs = F ? F.bodies : [];
        for (let i = 0; i < (bs ? bs.length : 0); i++) {
            const b = bs[i];
            console.log("AUSCENE " + tag + " body " + i + " id=" + b.id + " box=" + at(b.x0, b.y0) + "," + at(b.x1, b.y1)
                        + " host=" + (b.host || "-") + " parent=" + (b.parent || "-") + " mobile=" + (b.mobile ? 1 : 0));
        }
        const fl = F ? F.fillets : [];
        for (let i = 0; i < (fl ? fl.length : 0); i++) {
            const f = fl[i];
            console.log("AUSCENE " + tag + " fillet " + i + " key=" + f.key + " v=" + at(f.vx, f.vy) + " e=" + at(f.vx + f.ex, f.vy + f.ey)
                        + " k=" + at(f.kx, f.ky) + " r=" + f.krx.toFixed(2) + "," + f.kry.toFixed(2) + " (field px)");
        }
        const sm = F ? F.seams : [];
        for (let i = 0; i < (sm ? sm.length : 0); i++)
            console.log("AUSCENE " + tag + " seam " + i + " box=" + at(sm[i].x0, sm[i].y0) + "," + at(sm[i].x1, sm[i].y1));
    }

    function hex(c) {
        const h = v => ("0" + Math.round(255 * v).toString(16)).slice(-2);
        return "#" + h(c.r) + h(c.g) + h(c.b);
    }
    function record(tag, k, png) {
        const F = rig.field();
        const cs = (F.auraColors || []).map(c => rig.hex(c)).join(",");
        console.log("AUFRAME " + tag + " " + k + " time=" + F.auraTime.toFixed(5) + " level=" + F.auraLevel.toFixed(5) + " colors=" + cs
                    + " mode=" + (F.auraGroups || []).map(v => Number(v).toFixed(4)).join(",") + " cycles=" + (F.auraCycles || []).join(",")
                    + " joins=" + (F.auraJoins || []).map(j => j.map(v => Number(v).toFixed(4)).join(",")).join("/") + " png=" + png);
    }
    function grab(name) {
        rig.win.sheetGrabItem.grabToImage(r => {
            r.saveToFile(rig.out + "/" + name);
            tick.interval = 1;
            tick.start();
        });
        return true;
    }

    function plan(a) {
        const kind = a[0], tag = a[1];
        if (kind === "off") {
            rig.push(300, () => {
                rig.services.stopAura();
            });
            rig.push(1, () => {
                console.log("AUPOSE " + tag + " png=" + tag + ".png");
                return rig.grab(tag + ".png");
            });
            return;
        }
        if (kind === "do") {
            const what = a[2] || "";
            rig.push(300, () => rig.scene(what));
            // settled: the opens and the OSD's way in run on the Timer clock, ~3x fast offscreen
            rig.push(what === "wiki" ? 4000 : 2500, () => rig.sceneLines(tag));
            return;
        }
        if (kind === "pose") {
            const flags = a.slice(4);
            const g = (flags.find(x => x.indexOf("g=") === 0) || "g=all").slice(2);
            rig.push(300, () => {
                rig.services.stopAura();
                const ans = rig.services.playAura("siri", g, 600000);
                console.log("AUPROBE " + tag + " play: " + ans);
            });
            rig.push(500, () => {
                if (!rig.hold())
                    console.log("AUPROBE " + tag + " no clock to hold");
                rig.engine._auraSeed = Number(a[2]);
                rig.engine._auraClock = Number(a[3]);
                if (flags.indexOf("mono") >= 0) {
                    const c = rig.engine._auraColors[0];
                    rig.engine._auraColors = [c, c, c, c];
                }
            });
            rig.push(1, () => {
                console.log("AUPOSE " + tag + " png=" + tag + ".png");
                rig.record(tag, 0, tag + ".png");
                return rig.grab(tag + ".png");
            });
            return;
        }
        if (kind === "seq") {
            const how = a[2];
            rig.push(300, () => {
                rig.services.stopAura();
                const ans = rig.services.playAura("siri", how === "group" ? "island" : "all", how === "life" ? 300 : 600000);
                console.log("AUPROBE " + tag + " play: " + ans);
            });
            // the way in done (and, for `life`, the clock 8 frames short of the life's end)
            rig.push(how === "life" ? 1 : 900, () => {
                rig.hold();
                if (how === "life")
                    rig.engine._auraClock = rig.engine.auraAttackMs + 300 - 8 * rig.frameMs;
                if (how === "back") {
                    rig.services.releaseAura();
                    rig.hold();
                    // a third of the way out: the level well under its top, still falling
                    rig.engine._auraClock = rig.engine._auraClock + 200;
                }
            });
            let k = 0;
            const frame = () => {
                const kk = k++;
                rig.push(1, () => {
                    if (kk > 0)
                        rig.engine._auraClock = rig.engine._auraClock + rig.frameMs;
                    const png = tag + "_" + ("0" + kk).slice(-2) + ".png";
                    rig.record(tag, kk, png);
                    return rig.grab(png);
                });
            };
            for (let i = 0; i < 8; i++)
                frame();
            const before = k - 1;
            rig.push(1, () => {
                // the hand-over, between two frames, exactly as the take's end or the event calls it; the clock held again after it
                if (how === "release")
                    rig.services.releaseAura();
                else if (how === "replay")
                    console.log("AUPROBE " + tag + " replay: " + rig.services.playAura("siri", "all", 600000));
                else if (how === "palette")
                    console.log("AUPROBE " + tag + " palette: " + rig.services.playAura("ok", "all", 600000));
                else if (how === "back")
                    console.log("AUPROBE " + tag + " replay: " + rig.services.playAura("siri", "all", 600000));
                else if (how === "group")
                    console.log("AUPROBE " + tag + " group: " + rig.services.playAura("siri", "all", 600000));
                rig.hold();
                console.log("AUPROBE " + tag + " handover after frame " + before);
            });
            for (let i = 0; i < 8; i++)
                frame();
            return;
        }
        console.log("AUPROBE unknown step " + a.join(":"));
    }
}
