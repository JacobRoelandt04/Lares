pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "modules/common/theme"
import "modules/bar/workspaces"

// =============================================================================
// tools/dev/qml/workspaces_swipe_probe.qml -- the workspaces ball through a two-finger swipe
// (tools/dev/workspaces_swipe_probe.sh runs it). Prints WSW lines and "WSW RESULT PASS|FAIL".
//
// The ball is drawn at `ballDrawPos` (its place plus the fingers' lean). A swipe that steps from one slot to the next must
// carry it one way only: the step across the clock (slot 2 <-> 3) once dropped the lean in one frame and the ball jumped back to
// the slot it had left. Each case feeds touchpad deltas (a pixel-delta-free angle stream, 37 units a 10 ms) until the stand-in
// compositor has moved, lifts, and watches every frame for 800 ms; `back` is the largest step AGAINST the travel.
// `lat` is how late the compositor answers (0: at once, as the mockup's stand-in; 8: the real one's few milliseconds).
// =============================================================================
Scope {
    id: root
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("WSW " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    QtObject {
        id: stand
        property int active: 1
        property int lat: 0
        property int pending: -1
        function send(lua: string): void {
            const m = /workspace = (\d+)/.exec(lua);
            if (!m)
                return;
            if (stand.lat <= 0) {
                stand.active = Number(m[1]);
            } else {
                stand.pending = Number(m[1]);
                answer.interval = stand.lat;
                answer.restart();
            }
        }
    }
    Timer {
        id: answer
        onTriggered: stand.active = stand.pending
    }

    FloatingWindow {
        id: win
        visible: true
        implicitWidth: 300
        implicitHeight: 40
        color: Theme.surface
        Workspaces {
            id: ws
            x: 12
            y: 0
            width: 276
            height: 40
            sizeScale: 0.9
            trackSeparation: (10 + 5 * 0.9) / 0.9
            clockSize: 80 / 0.9
            clockCross: 18 / 0.9
            clockGap: 16 / 0.9
            edgePadding: 10
            showClock: true
            allWorkspaces: []
            activeWorkspaceId: stand.active
            dispatcher: lua => stand.send(lua)
        }
    }

    // ---- the recorder: one sample per frame -------------------------------------------------------------
    property var xs: []
    property bool rec: false
    FrameAnimation {
        running: true
        onTriggered: {
            if (root.rec)
                root.xs.push(ws.ballDrawPos);
        }
    }

    // ---- the cases ---------------------------------------------------------------------------------------
    // from / to are workspace ids; `cross` says the step crosses the clock (slots 2 and 3)
    property var cases: [
        { name: "1->2 late answer", from: 1, to: 2, lat: 8, cross: false },
        { name: "2->3 (across the clock)", from: 2, to: 3, lat: 0, cross: true },
        { name: "3->2 (across the clock)", from: 3, to: 2, lat: 0, cross: true },
        { name: "2->3 late answer", from: 2, to: 3, lat: 8, cross: true },
        { name: "3->2 late answer", from: 3, to: 2, lat: 8, cross: true },
        { name: "1->2 (neighbours)", from: 1, to: 2, lat: 0, cross: false },
        { name: "3->4 (neighbours)", from: 3, to: 4, lat: 0, cross: false }
    ]
    property var backs: ({})
    property int ci: -1
    property int phase: 0           // 0 settle, 1 swipe, 2 watch
    property int phaseTicks: 0
    property real startX: 0

    function analyse(c): void {
        const xs = root.xs;
        const dir = c.to > c.from ? 1 : -1;
        let back = 0, maxJump = 0;
        for (let i = 1; i < xs.length; i++) {
            back = Math.max(back, (xs[i - 1] - xs[i]) * dir);
            maxJump = Math.max(maxJump, Math.abs(xs[i] - xs[i - 1]));
        }
        const end = xs.length ? xs[xs.length - 1] : -1;
        const landed = Math.abs(end - ws._posOf(ws._lookupIndexFor(c.to))) < 0.5;
        const note = c.name + ": frames " + xs.length + " back " + back.toFixed(2) + " px maxJump " + maxJump.toFixed(2) + " px";
        root.check(c.name + " lands on its slot", landed && stand.active === c.to, "end " + end + " active " + stand.active);
        root.backs[c.name] = back;
        // a late answer leaves the ball drawn at its slot plus the pull for the turn, and the pull is already springing home: a
        // neighbour step steps back by that too, so a crossing answered as late may step back no further than it does
        const allowed = c.lat > 0 ? (root.backs["1->2 late answer"] || 0) + 0.5 : 0.5;
        root.check(c.name + " never steps back", back <= allowed, note + " (allowed " + Number(allowed).toFixed(2) + ")");
        console.log("WSW     " + note);
    }

    Timer {
        id: tick
        interval: 10
        repeat: true
        running: true
        onTriggered: {
            if (root.ci < 0) {
                root.ci = 0;
                root.phase = 0;
                root.phaseTicks = 0;
                const c0 = root.cases[0];
                stand.lat = c0.lat;
                stand.active = c0.from;
                return;
            }
            const c = root.cases[root.ci];
            root.phaseTicks++;
            if (root.phase === 0) {
                // settled on the case's start slot: landed, no lean, nothing moving
                if (root.phaseTicks > 50 && ws.progress >= 1 && ws.swipePull === 0 && !ws.swiping && stand.active === c.from) {
                    root.xs = [];
                    root.rec = true;
                    root.phase = 1;
                    root.phaseTicks = 0;
                }
                if (root.phaseTicks > 600) {
                    root.check(c.name + " settles", false, "never settled: progress " + ws.progress + " pull " + ws.swipePull);
                    root.finish();
                }
            } else if (root.phase === 1) {
                const dir = c.to > c.from ? 1 : -1;
                if (stand.active === c.to || root.phaseTicks > 400) {
                    ws._swipeWheel({ angleDelta: Qt.point(0, 0), pixelDelta: Qt.point(0, 0), device: "touch", steps: 0 });     // the fingers lift
                    root.phase = 2;
                    root.phaseTicks = 0;
                } else {
                    ws._swipeWheel({ angleDelta: Qt.point(dir * 37, 0), pixelDelta: Qt.point(0, 0), device: "touch", steps: 0 });
                }
            } else if (root.phaseTicks > 80) {
                root.rec = false;
                root.analyse(c);
                root.ci++;
                if (root.ci >= root.cases.length) {
                    root.finish();
                    return;
                }
                const n = root.cases[root.ci];
                stand.lat = n.lat;
                stand.active = n.from;
                root.phase = 0;
                root.phaseTicks = 0;
            }
        }
    }

    function finish(): void {
        tick.stop();
        console.log("WSW RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
        Qt.quit();
    }
}
