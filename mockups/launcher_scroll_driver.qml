pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

// =============================================================================
// mockups/launcher_scroll_driver.qml -- scrolls the launcher's list without a
// pause and says what every frame of it cost. Loaded by
// test_launcher_scroll_perf.qml (the popup on the real engine, nothing else in
// the window) and by mockups/launcher.qml under LAUNCHER_SCROLL_PERF=1 (the
// mockup as the user runs it, control panel and all: Qt Quick has no damage
// regions, so every scrolled frame redraws the whole window). Run by
// tools/dev/perf/launcher_scroll.sh.
//
// The list is moved by writing the grid's contentY once per frame at SPEED
// px/s of the frame's own time, top to bottom and back, for DUR_S seconds --
// what a steady two-finger scroll does to the grid (ScrollDressing writes
// contentY from the wheel, and everything downstream hears contentY).
//
// Per frame it records the interval since the last (FrameAnimation.frameTime:
// on the desktop the vsync'd presentation cadence, offscreen the basic loop's
// timer) and the STEP: the synchronous cost of the contentY write, which is
// where the grid's window, the slots' visibility and every face built or torn
// down for rows crossing the edge are paid. The frame's render split comes
// from QSG_RENDER_TIMING in the log (the shell script reads it).
//
//   SPEED=1200 DUR_S=10 WARM_MS=2500
//   SCROLL_LAYOUT=columns | list   set on the service before the warm-up
//                                  (columns: launcher.jsonc's default of 2)
// Prints SCROLLPERF <json> and SCROLLPERF DONE, then quits.
// =============================================================================
Item {
    id: drv

    // The engine hosting the launcher's popup.
    property var engine: null

    readonly property real speed: parseFloat(Quickshell.env("SPEED") || "1200")
    readonly property real durS: parseFloat(Quickshell.env("DUR_S") || "10")
    readonly property int warmMs: parseInt(Quickshell.env("WARM_MS") || "2500", 10)

    readonly property var popup: drv.engine && drv.engine.thePopup && drv.engine.popupOwnerId === "launcher" ? drv.engine.thePopup.contentItem : null

    function findNamed(item, name) {
        if (!item)
            return null;
        for (let i = 0; i < item.children.length; i++) {
            const c = item.children[i];
            if (c.objectName === name)
                return c;
            const f = drv.findNamed(c, name);
            if (f)
                return f;
        }
        return null;
    }

    property var grid: null
    property string phase: "wait"
    property real dir: 1
    property real elapsed: 0
    property var dts: []
    property var steps: []
    property int crossings: 0
    property int _lastRow: -1

    // Wait for the popup and its list, let the open settle, then scroll.
    Timer {
        id: poll
        interval: 100
        repeat: true
        running: drv.phase === "wait"
        onTriggered: {
            const g = drv.findNamed(drv.popup, "launcherGrid");
            if (!g || !g.flick || g.order.length < 20)
                return;
            drv.grid = g;
            if (g.service && g.service.setLayout)
                g.service.setLayout(Quickshell.env("SCROLL_LAYOUT") || "columns");
            drv.phase = "warm";
            warm.start();
        }
    }
    Timer {
        id: warm
        interval: drv.warmMs
        onTriggered: {
            console.log("SCROLLPERF START rows=" + drv.grid.order.length + " cols=" + drv.grid.cols
                + " content=" + Math.round(drv.grid.flick.contentHeight) + " view=" + Math.round(drv.grid.flick.height));
            drv.phase = "scroll";
        }
    }

    FrameAnimation {
        running: drv.phase === "scroll"
        onTriggered: {
            const f = drv.grid.flick;
            const dt = frameTime;
            if (drv.elapsed > 0)
                drv.dts.push(dt * 1000);
            drv.elapsed += dt;
            const max = Math.max(0, f.contentHeight - f.height);
            let y = f.contentY + drv.dir * drv.speed * Math.min(dt, 0.05);
            if (y >= max) {
                y = max;
                drv.dir = -1;
            } else if (y <= 0) {
                y = 0;
                drv.dir = 1;
            }
            const t0 = Date.now();
            f.contentY = y;
            drv.steps.push(Date.now() - t0);
            const row = Math.floor(y / drv.grid.rowH);
            if (row !== drv._lastRow)
                drv.crossings++;
            drv._lastRow = row;
            if (drv.elapsed >= drv.durS) {
                drv.phase = "done";
                drv.report();
            }
        }
    }

    function pct(a, p) {
        if (!a.length)
            return -1;
        const s = a.slice().sort((x, y) => x - y);
        return s[Math.min(s.length - 1, Math.floor(p * s.length))];
    }
    function report() {
        const d = drv.dts, s = drv.steps;
        const sum = d.reduce((a, b) => a + b, 0);
        const out = {
            frames: d.length,
            fps: d.length ? +(1000 * d.length / sum).toFixed(1) : 0,
            dt_p50: +drv.pct(d, 0.5).toFixed(2),
            dt_p95: +drv.pct(d, 0.95).toFixed(2),
            dt_p99: +drv.pct(d, 0.99).toFixed(2),
            dt_max: +Math.max.apply(null, d).toFixed(2),
            over8: d.filter(x => x > 8.4).length,
            over16: d.filter(x => x > 16.7).length,
            over33: d.filter(x => x > 33.4).length,
            step_mean: +(s.reduce((a, b) => a + b, 0) / Math.max(1, s.length)).toFixed(3),
            step_p95: drv.pct(s, 0.95),
            step_p99: drv.pct(s, 0.99),
            step_max: Math.max.apply(null, s),
            crossings: drv.crossings
        };
        console.log("SCROLLPERF " + JSON.stringify(out));
        console.log("SCROLLPERF DONE");
        quit.start();
    }
    Timer {
        id: quit
        interval: 200
        onTriggered: Qt.quit()
    }
}
