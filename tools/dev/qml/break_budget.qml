pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell

import "modules/bar/workspaces"

// break_budget.qml -- what the break nudge costs in repaints and wake-ups, on the OLD model (no `stats`) or the NEW one. One line:
//   BREAKBUDGET <old|new> ... paints_per_hour=<n> wakes_per_hour=<n>
// OLD: the fill runs 20 s in real time on a 400 px rail (it moves ~0.13 px/s: a paint per half pixel); scaled to its 50 minutes.
// NEW: a simulated hour on a 600x clock counts the model's beats; one beat's ease is measured in real time (paints and the rail's
// wake-ups through it) and multiplied by the beats; the model's own timer wake-ups are added (one per beat, one for the landing).
Window {
    id: win
    width: 400
    height: 100
    visible: true

    QtObject {
        id: rc
        readonly property real scale: 1
        function now() { return Date.now(); }
    }
    QtObject {
        id: fast
        property real scale: 600
        property real base: Date.now()
        property real real0: Date.now()
        function now() { return fast.base + (Date.now() - fast.real0) * fast.scale; }
    }
    BreakModel {
        id: bm
        clock: rc
        durationS: 3000
    }
    // The simulated hour (NEW only): its own model on the fast clock, no rail.
    BreakModel {
        id: hour
        clock: fast
        durationS: 3000
        armed: bm.stats !== undefined
    }
    Workspaces {
        id: ws
        width: 400
        height: 40
        breakSource: bm
        fillClock: rc
    }
    // The old rail counted no wake-ups: its `refreshes` (a wake that moved the head) is the closest, and a lower bound.
    function wakes() { return ws.fillStats.wakes !== undefined ? ws.fillStats.wakes : ws.fillStats.refreshes; }
    property real t0: Date.now()
    property int step: 0
    property int p0: 0
    property int w0: 0
    property int stepPaints: 0
    property int stepWakes: 0
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            const el = Date.now() - win.t0;
            const isNew = bm.stats !== undefined;
            if (win.step === 0 && el > 600) {
                win.p0 = ws.fillStats.paints; win.w0 = win.wakes(); win.t0 = Date.now();
                if (isNew) bm.seek(0.5);
                win.step = 1;
            } else if (win.step === 1 && !isNew && el > 20000) {
                const p = ws.fillStats.paints - win.p0, w = win.wakes() - win.w0;
                const k = 3000 / (el / 1000);
                console.log("BREAKBUDGET old window=" + (el / 1000).toFixed(1) + "s paints=" + p + " wakes=" + w + " paints_per_hour=" + Math.round(p * k) + " wakes_per_hour=" + Math.round(w * k));
                Qt.quit();
            } else if (win.step === 1 && isNew && el > 1500) {
                win.p0 = ws.fillStats.paints; win.w0 = win.wakes(); win.t0 = Date.now();
                bm.seek(0.52);
                win.step = 2;
            } else if (win.step === 2 && el > 1500) {
                win.stepPaints = ws.fillStats.paints - win.p0;
                win.stepWakes = win.wakes() - win.w0;
                win.t0 = Date.now();
                win.step = 3;
            } else if (win.step === 3 && el > 6500) {
                const st = hour.stats;
                const beats = st.beats, pubs = st.publishes, lands = st.lands;
                console.log("BREAKBUDGET new beats=" + beats + " publishes=" + pubs + " lands=" + lands + " per_ease_paints=" + win.stepPaints + " per_ease_rail_wakes=" + win.stepWakes
                    + " paints_per_hour=" + (pubs * win.stepPaints) + " wakes_per_hour=" + (beats + lands + pubs * win.stepWakes));
                Qt.quit();
            }
        }
    }
}
