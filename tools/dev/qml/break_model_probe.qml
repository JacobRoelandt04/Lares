pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/bar/workspaces"

// break_model_probe.qml -- the break nudge's rules (BreakModel) on a MANUAL clock (the model's own beat is called by hand, so a rule is
// proved at an exact instant), then the rail in real time: the head eases (no snap), nothing repaints between beats, the nudge's canvas
// sits under the timers'. One RESULT line: BREAKS RESULT PASS|FAIL.
Window {
    id: win
    width: 400
    height: 100
    visible: true

    property int fails: 0
    property int checks: 0
    function ok(name, cond, extra) {
        win.checks++;
        if (!cond)
            win.fails++;
        console.log("BREAKS " + (cond ? "ok  " : "FAIL") + " " + name + (extra ? "  (" + extra + ")" : ""));
    }
    function near(a, b, tol) { return Math.abs(a - b) <= tol; }

    // ---- the manual clock and a model per scenario ----
    QtObject {
        id: mc
        property real t: 1e12
        readonly property real scale: 1
        function now() { return mc.t; }
    }
    Component {
        id: mkC
        BreakModel {
            clock: mc
            durationS: 3000
            pauseS: 300
            graceS: 30
            rewindPower: 2
            stepS: 60
            easeMs: 700
            hiddenS: 600
            property int filledN: 0
            onFilled: filledN++
        }
    }
    function mk() { mc.t = 1e12; return mkC.createObject(win); }
    function adv(s) { mc.t += s * 1000; }
    function cr(m) { return m.creditAt(mc.t); }
    readonly property real curve180: 3000 * (1 - Math.pow((180 - 30) / (300 - 30), 2))   // 3 min of a 5 min pause, power 2: 0.3086 rewound

    function modelChecks() {
        let m = win.mk();
        // hidden zone: in, eased from the rail's start
        win.adv(540); m._onBeat();
        win.ok("hidden: 9 min of use draws nothing", m.fills.length === 0);
        win.adv(120); m._onBeat();
        const f = m.fills[0];
        win.ok("hidden: the beat that crosses it eases the fill in from the start", m.fills.length === 1 && f.to0 === 0 && win.near(f.to1, 660 / 3000, 1e-6) && f.ease === "outCubic" && f.t1 - f.t0 === 700);
        win.ok("hidden: no snap (start 0, mid between, end at place)", m.drawnAt(f.t0) === 0 && m.drawnAt(f.t0 + 350) > 0.01 && m.drawnAt(f.t0 + 350) < f.to1 - 0.01 && win.near(m.drawnAt(f.t0 + 700), f.to1, 1e-9),
               m.drawnAt(f.t0 + 350).toFixed(3));
        // the beat
        win.ok("beat: one timer, one beat away", m.nextWakeMs === 60000, "" + m.nextWakeMs);
        const b0 = m.stats.beats, f0 = m.fills[0];
        win.adv(30);
        win.ok("beat: between beats the drawn fill does not move", m.fills[0] === f0 && win.near(m.drawnAt(mc.t), f0.to1, 1e-9) && m.stats.beats === b0);
        win.adv(30); m._onBeat();
        win.ok("beat: the beat moves it to the progress and eases there", m.fills[0] !== f0 && win.near(m.fills[0].to1, 720 / 3000, 1e-6) && win.near(m.fills[0].to0, 660 / 3000, 1e-6));
        m.destroy();

        // grace: an idle shorter than the grace is use; at the grace the span's credit is taken back
        m = win.mk();
        win.adv(300); m._onBeat();
        win.adv(20);
        win.ok("grace: 20 s without the monitor firing is use", win.near(win.cr(m), 320, 0.01), win.cr(m).toFixed(1));
        win.adv(10); m.idle = true; m.idle = false;
        win.ok("grace: an idle that ends at the grace rewinds nothing and gives its 30 s back", win.near(win.cr(m), 300, 0.01), win.cr(m).toFixed(1));
        m.destroy();

        // the curve (power 2), from a full rail, for each cause
        m = win.mk(); m.seek(1); win.adv(100); m.idle = true;
        win.ok("span: no accruing and no timer while idle", m.nextWakeMs === 0);
        win.adv(150); m.idle = false;
        win.ok("curve: 3 min of a 5 min pause rewinds 0.3086 of the full rail", win.near(win.cr(m), win.curve180, 0.5), win.cr(m).toFixed(1) + " vs " + win.curve180.toFixed(1));
        m.destroy();
        m = win.mk(); m.seek(1); win.adv(100); m.idle = true; win.adv(270); m.idle = false;
        win.ok("reset: a span of the pause empties even a full rail", win.cr(m) === 0 && !m.full);
        win.adv(2);
        win.ok("reset: and the head eases back to the start", m.drawnAt(mc.t) === 0 && m.fills.length === 1 && m.fills[0].to1 === 0);
        m.destroy();
        m = win.mk(); m.seek(1); win.adv(10); m.sleepBegan();
        win.ok("suspend: a span, no timer", m.nextWakeMs === 0);
        win.adv(180); m.resume();
        win.ok("suspend: sleep start to resume is one idle span", win.near(win.cr(m), win.curve180, 0.5), win.cr(m).toFixed(1));
        m.destroy();
        m = win.mk(); m.seek(1); win.adv(180); m.resume();
        win.ok("suspend without 'about to sleep': the gap since the last accounting", win.near(win.cr(m), win.curve180, 0.5), win.cr(m).toFixed(1));
        m.destroy();
        m = win.mk(); m.seek(1); win.adv(10); m.locked = true; win.adv(180); m.locked = false;
        win.ok("lock: lock to unlock is one idle span (no longer a reset)", win.near(win.cr(m), win.curve180, 0.5), win.cr(m).toFixed(1));
        m.destroy();
        // overlapping causes: idle from +70, lock +110, sleep +120..+170, idle ends +200, unlock +220 = ONE span of 150 s
        m = win.mk(); m.seek(1); win.adv(100); m.idle = true; win.adv(10); m.locked = true; win.adv(10); m.sleepBegan();
        win.adv(50); m.resume(); win.adv(30); m.idle = false; win.adv(20); m.locked = false;
        const one = 3000 * (1 - Math.pow((150 - 30) / 270, 2));
        win.ok("overlap: idle + lock + suspend are one span, counted once", win.near(win.cr(m), one, 0.5), win.cr(m).toFixed(1) + " vs " + one.toFixed(1));
        m.destroy();

        // hidden zone out: a rewind under the minimum eases the head back to the start
        m = win.mk(); win.adv(660); m._onBeat(); win.adv(5); win.adv(60); m.idle = true; win.adv(150); m.idle = false;
        const g = m.fills[0];
        win.ok("hidden out: a rewind under it eases back to the start, then gone", win.cr(m) < 600 && g.to1 === 0 && g.to0 > 0.1 && m.drawnAt(g.t0 + 350) > 0.01 && m.drawnAt(g.t0 + 350) < g.to0 - 0.01 && m.drawnAt(g.t0 + 800) === 0);
        m.destroy();

        // the burst: once per crossing, when the DRAWN fill lands
        m = win.mk(); m.seek(1);
        win.ok("burst: not before the head has landed", m.filledN === 0 && m.nextWakeMs === 700, "" + m.nextWakeMs);
        win.adv(0.7); m._onBeat();
        win.ok("burst: once when it lands on full", m.filledN === 1 && m.full && m.nextWakeMs === 0);
        m.seek(1); m.seek(0.95); m.seek(1); win.adv(1); if (m.nextWakeMs > 0) m._onBeat();
        win.ok("burst: not again for a dip that stayed above 90 %", m.filledN === 1, "" + m.filledN);
        m.seek(0.5); m.seek(1); win.adv(0.7); m._onBeat();
        win.ok("burst: again after it went below and came back", m.filledN === 2, "" + m.filledN);
        m.destroy();

        m = win.mk(); win.adv(700); m._onBeat();
        m.armed = false;
        win.ok("disarmed: nothing drawn, nothing armed", m.fills.length === 0 && m.nextWakeMs === 0);
        m.destroy();
    }

    // ---- the rail in real time ----
    QtObject {
        id: rc
        readonly property real scale: 1
        function now() { return Date.now(); }
    }
    BreakModel {
        id: bm
        clock: rc
        durationS: 3000
        hiddenS: 600
    }
    Workspaces {
        id: ws
        width: 400
        height: 40
        breakSource: bm
        fillClock: rc
        fills: [{ piece: -1, tone: 0, from: 0, to0: 0.3, to1: 0.3, t0: 1, t1: 1 }]
    }
    function walk(it, out) {
        for (let i = 0; i < it.children.length; i++) {
            out.push(it.children[i]);
            win.walk(it.children[i], out);
        }
        return out;
    }

    property int step: 0
    property real t0: 0
    property int paints0: 0
    property int paintsEase: 0
    property int wakes0: 0
    property real midXe: -1
    function stepRail() {
        const el = Date.now() - win.t0;
        if (win.step === 0) {
            win.modelChecks();
            win.paints0 = ws.fillStats.paints;
            win.wakes0 = ws.fillStats.wakes;
            win.t0 = Date.now();
            bm.seek(0.5);
            win.step = 1;
        } else if (win.step === 1 && el > 350) {
            const frame = ws._fillFrame(rc.now());
            const e = frame.find(x => x.tone === 3);
            win.midXe = e ? e.xe - e.xs : -1;
            win.ok("rail draws timer and nudge", frame.some(x => x.tone === 0) && !!e, JSON.stringify(frame.map(x => x.tone)));
            const cs = win.walk(ws, []).filter(i => typeof i.requestPaint === "function" && (i.z === 0.9 || i.z === 1));
            const under = cs.filter(i => i.z === 0.9).length, over = cs.filter(i => i.z === 1).length;
            win.ok("nudge canvas under the timers'", under === 1 && over === 3, "under " + under + " over " + over);
            win.step = 2;
        } else if (win.step === 2 && el > 1300) {
            const e = ws._fillFrame(rc.now()).find(x => x.tone === 3);
            const total = e ? e.xe - e.xs : 1;
            win.ok("rail: OutCubic -- most of the way at 350 ms (0.875 of it), not yet landed, then landed", win.midXe > 0.78 * total && win.midXe < 0.97 * total, (win.midXe / total).toFixed(3));
            win.paintsEase = ws.fillStats.paints - win.paints0;
            win.ok("paint budget: a beat's ease repaints a few times, not once and not per frame", win.paintsEase >= 4 && win.paintsEase <= 26, "" + win.paintsEase);
            win.paints0 = ws.fillStats.paints;
            win.wakes0 = ws.fillStats.wakes;
            win.step = 3;
        } else if (win.step === 3 && el > 3000) {
            win.ok("paint budget: between beats ZERO repaints and ZERO wake-ups", ws.fillStats.paints === win.paints0 && ws.fillStats.wakes === win.wakes0,
                   (ws.fillStats.paints - win.paints0) + " paints, " + (ws.fillStats.wakes - win.wakes0) + " wakes");
            console.log("BREAKS RESULT " + (win.fails === 0 ? "PASS" : "FAIL") + " (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            Qt.quit();
        } else if (el > 12000) {
            win.ok("step " + win.step + " timed out", false);
            console.log("BREAKS RESULT FAIL (" + (win.checks - win.fails) + "/" + win.checks + " checks)");
            Qt.quit();
        }
    }
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: win.stepRail()
    }
}
