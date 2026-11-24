// mux_pacing.qml -- tools/dev/mux_bench.sh's pacing window: a small FloatingWindow on the real desktop that animates for
// PACE_SECS seconds and records the interval between its presented frames (frameSwapped), then prints one MUXPACE line (JSON)
// and quits. A steady compositor and GPU give one refresh period between frames (8.33 ms at 120 Hz); a frame that took two or more
// periods is a miss. The motion is a block crossing the window, so every frame changes and asks the next.
import QtQuick
import Quickshell

ShellRoot {
    id: root
    // smoked bare (no runner, no PACE_SECS) it quits at once and opens nothing that stays
    readonly property real secs: Number(Quickshell.env("PACE_SECS") || 0)
    property var gaps: []
    property real last: 0
    property real started: 0

    FloatingWindow {
        id: win
        implicitWidth: 360
        implicitHeight: 200
        title: "lares-bench-pacing"
        color: "#20242c"
        Rectangle {
            id: block
            width: 40; height: 40; radius: 8; color: "#4480F4"; y: 80
            NumberAnimation on x { from: 0; to: 320; duration: 700; loops: Animation.Infinite }
        }
        // the QQuickWindow behind the FloatingWindow (Quickshell's window type has no frameSwapped of its own)
        Connections {
            target: block.Window.window
            function onFrameSwapped() {
                const now = Date.now();
                if (root.started === 0) { root.started = now; root.last = now; return; }
                root.gaps.push(now - root.last);
                root.last = now;
                if (now - root.started > root.secs * 1000)
                    root.finish();
            }
        }
    }
    function finish(): void {
        const g = root.gaps.slice().sort((a, b) => a - b);
        const q = p => g.length ? g[Math.min(g.length - 1, Math.floor(p * g.length))] : -1;
        const med = q(0.5);
        const miss = g.filter(x => x > 1.5 * med).length;
        console.log("MUXPACE " + JSON.stringify({ frames: g.length, secs: (root.last - root.started) / 1000, p50: med, p95: q(0.95),
            p99: q(0.99), max: g.length ? g[g.length - 1] : -1, miss: miss, missShare: g.length ? miss / g.length : 0 }));
        quit.start();
    }
    Timer { id: quit; interval: 0; running: root.secs <= 0; onTriggered: Qt.quit() }
    Timer { interval: (root.secs + 20) * 1000; running: true; onTriggered: { console.log("MUXPACE {\"error\":\"no frames\"}"); Qt.quit(); } }
}
