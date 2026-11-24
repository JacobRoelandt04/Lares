pragma ComponentBehavior: Bound

import QtQuick
import QtTest
import Quickshell

import "modules/common/theme"
import "modules/common/flourish"
import "modules/panorama"
import "modules/panorama/bar"
import "modules/panorama/bar/PanoramaPanes.js" as Pose
import "modules/panorama/data"

// panorama_castglyph_probe.qml -- the panorama button while a cast is being made: the hover hue and the flourish turn after turn, from the SERVICE's
// state (two owners and two buttons, as two screens have them), on live clocks, driven by real pointer events. Every rendered frame is recorded.
//
//   off      casting off: whatever the cast service does, the buttons say nothing and no clock runs
//   loop     a cast that connects: both buttons take the hover hue and play whole turns, a rest between two
//   alone    a pointer, the OLED care's demo() and the preset's deal() start nothing meanwhile, in a turn or in the rest
//   theme    a turn holds through a theme crossfade
//   up       the stream comes up mid-turn: the turn in the air ends, none follows, the hue eases back after it, no clock runs
//   lost     the link of a stream that was up is lost: the turns go on from that moment until it is up again
//   ends     a failure, a stop, a cast that something else started (no keeper): the same
//   single   with no cast, the registry's demo() is one turn
// `PG ok|FAIL <check>`, `PG RESULT PASS|FAIL`. FILM=<dir>: no checks, the filmstrip's frames (tools/dev/panorama_castglyph_probe.sh film).
Window {
    id: win
    width: 420
    height: 120
    visible: true
    color: Theme.surface

    CastMock {
        id: cm
        stepMs: 60000
        stopMs: 200
        scanMs: 20
        beatMs: 100
    }
    PanoramaMock {
        id: desk
        scenario: "laptop"
        timeScale: 20
        castConfig: false
        cast: cm
    }
    PanoramaBarButton {
        id: a
        x: 20
        y: 20
    }
    PanoramaBarButton {
        id: b
        x: 120
        y: 20
    }
    // (an owner with no engine: what it writes on its button needs none)
    PanoramaBarOwner {
        anchorItem: a
        shellHosted: true
        service: desk
    }
    PanoramaBarOwner {
        anchorItem: b
        shellHosted: true
        service: desk
    }
    // a screen that comes while a cast is being made: its button and owner are built then
    Loader {
        id: late
        x: 220
        y: 20
        active: false
        sourceComponent: Item {
            readonly property alias button: lb
            PanoramaBarButton {
                id: lb
            }
            PanoramaBarOwner {
                anchorItem: lb
                shellHosted: true
                service: desk
            }
        }
    }
    TestCase { id: tc; name: "panocastglyph"; when: false; windowShown: true }

    readonly property string tv: "wfd:02:AE:00:00:0A:01"
    property int total: 0
    property int bad: 0
    function check(ok: bool, what: string): void {
        win.total++;
        if (!ok)
            win.bad++;
        console.log("PG " + (ok ? "ok   " : "FAIL ") + what);
    }
    function until(fn: var, ms: int): bool {
        for (let t = 0; t < ms; t += 20) {
            if (fn())
                return true;
            tc.wait(20);
        }
        return fn();
    }
    function timersOn(it: var): int {                    // the running Timers under an item (a button's own children stand in its glyph's square)
        let n = 0;
        for (let i = 0; i < it.data.length; i++) {
            const o = it.data[i];
            if (String(o).indexOf("QQmlTimer") === 0)
                n += o.running ? 1 : 0;
            else if (o && o.data !== undefined)
                n += win.timersOn(o);
        }
        return n;
    }
    function timers(it: var): int {                      // how many there are at all (the census must see the one it judges)
        let n = 0;
        for (let i = 0; i < it.data.length; i++)
            n += String(it.data[i]).indexOf("QQmlTimer") === 0 ? 1 : (it.data[i] && it.data[i].data !== undefined ? win.timers(it.data[i]) : 0);
        return n;
    }
    function still(it: var): bool {
        return !it.flourish.playing && !it.flourish._run.running && win.timersOn(it) === 0;
    }

    // ---- the record: every frame of button a -------------------------------------------------------------------------------------------------
    property var rec: []
    property var plays: []
    property var playsB: []
    property int ends: 0
    property real mono: 0
    FrameAnimation {
        id: frames
        running: true
        onTriggered: {
            win.mono += frames.frameTime * 1000;
            win.rec.push({ on: a.flourish.playing, t: a.flourish.t, work: a._work, parts: a.parts.join("|") });
        }
    }
    Connections {
        target: a.flourish
        function onPlayed(why) {
            win.plays.push(why);
        }
        function onFinished() {
            win.ends++;
        }
    }
    Connections {
        target: b.flourish
        function onPlayed(why) {
            win.playsB.push(why);
        }
    }
    function clear(): void {
        win.rec = [];
        win.plays = [];
        win.playsB = [];
        win.ends = 0;
    }
    // the runs of the record: [{ from, to (the t of its first and last frame), back (its clock went back), n }], and the rests between two
    function runs(): var {
        const out = [];
        let cur = null, rest = 0;
        for (const f of win.rec) {
            if (f.on) {
                // a clock that goes back is a new turn with no rest (or a run cut and started again)
                if (cur !== null && f.t < cur.to - 0.01) {
                    cur.next = 0;
                    out.push(cur);
                    cur = null;
                    rest = 0;
                }
                if (cur === null)
                    cur = { from: f.t, to: f.t, n: 0, rest: rest };
                cur.to = f.t;
                cur.n++;
                rest = 0;
            } else {
                if (cur !== null)
                    out.push(cur);
                cur = null;
                rest++;
            }
        }
        if (cur !== null)
            out.push(cur);
        return out;
    }
    readonly property var restParts: Pose.rest({ count: 1, plus: 0, mirror: 0 }, a.glyphSize, a.glyphOrigin.x, a.glyphOrigin.y).parts.join("|")

    function connect(): void {
        cm.stepMs = 60000;
        cm.script("ok");
        desk.castStart(win.tv);
        win.until(() => desk.castPhase === "starting", 3000);
    }
    // the next step of the script now (a timer that is told a new interval starts over)
    function play(): void {
        cm.stepMs = 40;
    }
    function settled(ms: int): bool {
        return win.until(() => win.still(a) && a._work === 0, ms);
    }

    function run(): void {
        const L = a.flourish.ms;
        tc.wait(300);
        win.check(win.timers(a) >= 1, "off: the census sees the button's timer (" + win.timers(a) + ")");
        // ---- off
        win.clear();
        cm.start(win.tv, "eDP-1", {});
        tc.wait(400);
        win.check(cm.state === "connecting" && desk.castWorking === false && !a.working && win.plays.length === 0 && a._work === 0 && win.still(a) && win.still(b),
                  "off: casting off, a cast service that connects moves nothing on the bar (" + cm.state + ", plays " + win.plays.length + ")");
        cm.stop();
        win.until(() => cm.state === "idle", 2000);

        // ---- loop
        desk.castConfig = true;
        win.until(() => desk.castDevices.length > 0, 2000);
        win.clear();
        win.connect();
        win.check(desk.castWorking && a.working && b.working && win.plays.length === 1 && win.playsB.length === 1, "loop: from the first moment, on both screens' buttons (" + win.plays.length + ", " + win.playsB.length + ")");
        win.until(() => win.ends >= 3, 12000);
        win.until(() => a.flourish.t > 100, 3000);
        let rs = win.runs();
        win.check(win.plays.length >= 4 && win.plays.every(w => w === "cast") && win.playsB.length >= 3, "loop: turn after turn while it connects: " + win.plays.length + " on one, " + win.playsB.length + " on the other, all the cast's");
        const whole = rs.slice(0, 3);
        win.check(whole.length === 3 && whole.every(r => r.from < 60 && r.to > L - 60), "loop: every turn is whole, 0 .. " + L + " ms: " + whole.map(r => Math.round(r.from) + ".." + Math.round(r.to)).join(" "));
        win.check(rs.slice(1, 3).every(r => r.rest >= 5) && win.rec.filter(f => !f.on && f.parts !== win.restParts).length === 0, "loop: the glyph rests between two turns, as the rest picture (frames " + rs.slice(1).map(r => r.rest).join(" ") + ")");
        win.check(Math.abs(a._work - 1) < 0.001 && Qt.colorEqual(a.ink, a.hueHover) && Qt.colorEqual(b.ink, b.hueHover), "loop: the ink is the hover hue (" + a.ink + " of " + a.hueHover + ")");
        const w = win.rec.map(f => f.work);
        win.check(w.every((v, i) => i === 0 || v >= w[i - 1] - 1e-6) && w.filter(v => v > 0.02 && v < 0.98).length >= 3, "loop: it came in as a fraction that eases (" + w.filter(v => v > 0.02 && v < 0.98).length + " frames between)");

        late.active = true;
        tc.wait(60);
        win.check(!!late.item && late.item.button.working && late.item.button.flourish.playing && late.item.button.flourish.why === "cast", "loop: a screen that comes meanwhile shows it too");
        late.active = false;

        // ---- alone: in a turn, then in the rest
        const n0 = win.plays.length;
        tc.mouseMove(win.contentItem, a.x + 10, a.y + 10);
        tc.mouseMove(win.contentItem, a.x + 14, a.y + 12);
        const d1 = a.flourish.demo(), d2 = a.deal();
        const t0 = a.flourish.t;
        tc.wait(60);
        win.check(!d1 && !d2 && a.flourish.t >= t0 && win.plays.length === n0, "alone: in a turn a pointer, demo() and deal() start nothing (t " + Math.round(t0) + " -> " + Math.round(a.flourish.t) + ")");
        tc.mouseMove(win.contentItem, 400, 100);
        win.until(() => !a.flourish.playing, 4000);
        const n1 = win.plays.length, e1 = win.ends;
        tc.mouseMove(win.contentItem, a.x + 10, a.y + 10);
        tc.mouseMove(win.contentItem, a.x + 14, a.y + 12);
        const d3 = a.flourish.demo(), d4 = a.deal();
        win.check(!d3 && !d4 && win.plays.length === n1 && !a.flourish.playing, "alone: in the rest they start nothing either (plays " + win.plays.slice(n1 - 1).join(" ") + ")");
        win.until(() => win.plays.length > n1, 3000);
        win.check(win.ends === e1 && win.plays[win.plays.length - 1] === "cast", "alone: the next turn is the cast's own");
        tc.mouseMove(win.contentItem, 400, 100);

        // ---- theme: the turn in the air holds
        win.until(() => a.flourish.t > 150, 3000);
        Theme._hosted = true;
        Theme._switching = true;
        tc.wait(40);
        const th0 = a.flourish.t;
        tc.wait(300);
        const th1 = a.flourish.t, held = Theme.crossfading;
        Theme._switching = false;
        tc.wait(80);
        win.check(held && Math.abs(th1 - th0) < 1 && a.flourish.t > th1, "theme: a turn holds through a crossfade and goes on (t " + Math.round(th0) + " -> " + Math.round(th1) + " -> " + Math.round(a.flourish.t) + ")");

        // ---- up: the stream is there in the middle of a turn
        win.until(() => !a.flourish.playing, 4000);
        win.until(() => a.flourish.t > 100 && a.flourish.t < 400, 4000);
        win.clear();
        win.play();
        win.until(() => desk.castPhase === "streaming", 4000);
        const tUp = a.flourish.t, on = a.flourish.playing;
        win.check(on && !a.working && !desk.castWorking, "up: the stream came up in the middle of a turn (t " + Math.round(tUp) + ")");
        win.settled(4000);
        tc.wait(60);
        rs = win.runs();
        win.check(rs.length === 1 && rs[0].to > L - 60 && win.ends === 1 && win.plays.length === 0, "up: that turn ended whole and none followed (" + rs.map(r => Math.round(r.from) + ".." + Math.round(r.to)).join(" ") + ", plays " + win.plays.length + ")");
        win.check(win.rec.filter(f => f.on && f.work < 0.999).length === 0, "up: the hue stays until the turn has landed");
        // THE INK STAYS WHILE THE CAST IS UP (the user's call, 2026-11-23): no turn, no clock, the hover hue
        tc.wait(400);
        win.check(a.casting && b.casting && a._work === 1 && Qt.colorEqual(a.ink, a.hueHover) && !a.flourish.playing,
                  "up: the hover hue stays while the cast is up (work " + a._work + ", " + a.ink + " of " + a.hueHover + ")");
        tc.wait(700);
        win.check(win.still(a) && win.still(b) && win.plays.length === 0, "up: at rest no clock and no timer runs");

        // ---- lost: the link dies under the stream, and is made again
        win.clear();
        cm.stop();
        win.until(() => desk.castPhase === "idle", 3000);
        win.until(() => a._work === 0, 3000);
        const back = win.rec.map(f => f.work);
        win.check(!a.casting && back.filter(v => v > 0.02 && v < 0.98).length >= 3 && Qt.colorEqual(a.ink, Theme.textMuted) && win.plays.length === 0,
                  "ends: the cast over, the ink eases back to the muted one, no turn (" + back.filter(v => v > 0.02 && v < 0.98).length + " frames between, " + a.ink + " of " + Theme.textMuted + ")");
        cm.script("link-then-ok");
        cm.stepMs = 40;
        desk.castStart(win.tv);
        win.until(() => desk.castPhase === "streaming" && desk.castState === "streaming", 4000);
        const up1 = a.working;
        cm.stepMs = 250;
        win.clear();
        win.until(() => desk.castState === "connecting", 6000);
        win.check(!up1 && a.working && !cm.retried && desk.castPhase === "streaming" && desk.castStatusText(win.tv) === "Reconnecting…", "lost: a lost link is told at once, before the retry: the button works from that moment (" + desk.castStatusText(win.tv) + ", retried " + cm.retried + ")");
        win.until(() => desk.castState === "streaming", 8000);
        win.check(!a.working && win.plays.filter(p => p === "cast").length >= 1, "lost: until the stream is up again (turns " + win.plays.length + ")");
        win.settled(4000);
        cm.stop();
        win.until(() => desk.castPhase === "idle", 3000);

        // ---- ends: a failure, a stop, a cast something else started
        cm.script("cancelled");
        cm.stepMs = 60000;
        desk.castStart(win.tv);
        win.until(() => a.flourish.t > 100, 3000);
        cm.stepMs = 40;
        win.until(() => desk.castPhase === "idle", 3000);
        win.check(!a.working && win.settled(4000), "ends: a failure ends it, after the turn");
        win.connect();
        win.until(() => a.flourish.t > 100, 3000);
        desk.castStop();
        win.check(!a.working, "ends: a stop while it connects ends it at once");
        win.check(win.settled(4000), "ends: ... and the turn lands");
        win.until(() => desk.castPhase === "idle", 3000);
        cm.stepMs = 60000;
        cm.script("ok");
        cm.start(win.tv, "eDP-1", {});
        win.check(desk.castPhase === "idle" && desk.castWorking && a.working && b.working, "ends: a cast that something else started is shown just the same (keeper " + desk.castPhase + ")");
        cm.stop();
        win.until(() => cm.state === "idle", 2000);
        win.check(win.settled(4000), "ends: ... and over with it");

        // ---- single
        win.clear();
        const one = a.flourish.demo();
        win.until(() => win.ends === 1, 4000);
        tc.wait(900);
        win.check(one && win.plays.join(" ") === "random" && win.ends === 1 && win.still(a) && a._work === 0, "single: with no cast the registry's demo is one turn (" + win.plays.join(" ") + ")");
        console.log("PG RESULT " + (win.bad === 0 ? "PASS" : "FAIL") + " (" + (win.total - win.bad) + " of " + win.total + ")");
        Qt.quit();
    }

    // ---- the filmstrip: one button at the bar's size and one six times it, the flourish's clock written by hand -------------------------------
    readonly property string film: Quickshell.env("FILM") || ""
    Item {
        id: stage
        visible: win.film !== ""
        width: 240
        height: 120
        Rectangle {
            anchors.fill: parent
            color: Theme.surface
        }
        PanoramaBarButton {
            id: f1
            x: 8
            y: 46
        }
        PanoramaBarButton {
            id: f6
            x: 60
            y: 4
            glyphSize: 108
        }
    }
    property int _shot: 0
    function shoot(): void {
        const step = 60, n = Math.ceil(2 * (f1.flourish.ms + f1.breathMs) / step) + 8;
        if (win._shot >= n) {
            console.log("PG RESULT PASS (film " + n + ", a turn " + f1.flourish.ms + " ms, the rest " + f1.breathMs + " ms)");
            Qt.quit();
            return;
        }
        const ms = win._shot * step, cycle = f1.flourish.ms + f1.breathMs, t = ms % cycle;
        for (const g of [f1, f6]) {
            g.flourish.held = true;
            g.working = ms < 2 * cycle;
            if (!g.flourish.playing && t < g.flourish.ms && g.working)
                g.flourish.play("cast");
            if (t >= g.flourish.ms && g.flourish.playing)
                g.flourish.stop();
            if (g.flourish.playing)
                g.flourish.t = t;
        }
        tc.wait(60);
        stage.grabToImage(r => {
            r.saveToFile(win.film + "/f_" + String(10000 + ms) + ".png");
            win._shot++;
            Qt.callLater(win.shoot);
        });
    }
    Timer {
        interval: 200
        running: true
        onTriggered: {
            if (win.film !== "")
                win.shoot();
            else if (Quickshell.env("PANORAMA_CASTGLYPH") === "1")
                win.run();
            else
                Qt.quit();                                  // (smoked bare: nothing is driven)
        }
    }
}
