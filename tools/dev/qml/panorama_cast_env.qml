import QtQuick
import Quickshell

import "modules/common/system"
import "modules/panorama/data"

// =============================================================================
// panorama_cast_env.qml -- a whole cast on the LIVE PanoramaService + CastService and the REAL engine in a nested Hyprland
// (tools/dev/lock_env.sh); only the tool is a stub (tools/dev/fixtures/cast/cast_stub_tool: no fluxcast, no Wi-Fi). Run by
// tools/dev/panorama_shell_env_probe.sh (PHASE=cast). The seam every other cast gate stubs: the service's own words reaching the engine
// (2026-11-22: `cast_keep` of an empty list was no Lua, the link went `error` the moment casting armed, and no TV ever showed).
//
//   c1 up: the engine active, "cast": true arms it, and the link is STILL active once the engine has answered
//   c2 the Displays view opens: the scan lists the TV, capable
//   c3 a cast: LARES-CAST-1 is made and listed, the stream runs on it, the engine keeps it past its sweep's grace
//   m  mirror (2026-11-23): switched on while it streams the output is REMOVED and the stream takes the laptop's; off, it is made again;
//      a cast of a TV stored as a mirror asks the engine for no output at all (none is ever listed: an output switched off as it was born
//      took the session's clients down)
//   c4 stop: the output goes, idle, the link active
// =============================================================================
ShellRoot {
    id: root

    readonly property bool bare: !Quickshell.env("PM_ENGINE")
    readonly property string tv: "wfd:02:AE:00:00:0A:01"
    readonly property string streams: "wfd:00:00:00:00:00:01"     // the stub's "stream until TERM" device
    property int fails: 0
    property int step: 0
    property real t0: 0
    function check(name, ok, detail) {
        console.log("PM " + (ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  -- " + detail));
        if (!ok)
            root.fails++;
    }
    function j(x) {
        return JSON.stringify(x);
    }
    function link() {
        return root.j([svc.engineState, svc.engineWhy, svc.engineLink.lastError]);
    }

    FocusedScreen {
        id: focus
        live: !root.bare
    }
    QtObject {
        id: notifier
        signal action(string key, string id)
        function notify(key, rec) {
        }
        function withdraw(key) {
        }
    }
    CastService {
        id: castSvc
        live: !root.bare
        toolPath: Quickshell.env("PM_CASTTOOL") || "/nonexistent"
    }
    PanoramaService {
        id: svc
        live: !root.bare
        focusSource: focus
        notifier: notifier
        engineSource: Quickshell.env("PM_ENGINE")
        cast: castSvc
    }

    function has(name) {
        return svc.displays.some(d => d.name === name);
    }
    readonly property string lap: {
        const d = svc.displays.find(x => x.internal);
        return d ? d.name : "";
    }
    // every cast output the compositor listed, in order (a born-and-gone one is caught here)
    property var seenCast: []
    Connections {
        target: focus
        function onOutputsChanged() {
            for (const o of focus.outputs)
                if (/^LARES-CAST-/.test(o.name) && root.seenCast.indexOf(o.name) < 0)
                    root.seenCast = root.seenCast.concat([o.name]);
        }
    }
    function creates() {
        return ((svc.engineLink.state || {}).log || []).filter(l => l.indexOf("cast: create") >= 0).length;
    }
    property int mark: 0
    // true | false (not yet) | null (out of time)
    function until(cond, ms) {
        if (cond())
            return true;
        if (root.t0 === 0)
            root.t0 = Date.now();
        return Date.now() - root.t0 > ms ? null : false;
    }
    function held(ms) {
        if (root.t0 === 0)
            root.t0 = Date.now();
        return Date.now() - root.t0 >= ms;
    }
    function done() {
        root.t0 = 0;
        root.step++;
    }

    property var steps: [
        () => {
            const r = root.until(() => svc.engineState === "active" && svc.displays.length === 2, 20000);
            if (r === false)
                return;
            root.check("c1 up: engine active, two displays", r === true, root.link() + root.j(svc.displays.map(d => d.name)));
            root.check("c1 casting is off until the config says so", !svc.castEnabled, "");
            svc.configObject.apply({ cast: true });
            root.done();
        },
        () => {
            if (!root.held(2500))
                return;
            root.check("c1 armed: the link is still active once the engine has answered", svc.castEnabled && svc.engineState === "active" && svc.engineLink.lastError === "", root.link());
            svc.popupOpen = true;
            root.done();
        },
        () => {
            const r = root.until(() => svc.castDevices.length > 0, 8000);
            if (r === false)
                return;
            const d = svc.castDevices.find(x => x.id === root.tv);
            root.check("c2 the Displays view on show: the scan lists the TV, capable", r === true && !!d && d.capable, root.j(svc.castDevices) + root.link());
            root.check("c3 a cast starts", svc.castStart(root.streams), svc.castPhase);
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "streaming" && root.has("LARES-CAST-1"), 20000);
            if (r === false)
                return;
            root.check("c3 LARES-CAST-1 is listed and the stream runs on it", r === true && castSvc.monitor === "LARES-CAST-1", root.j([svc.castPhase, castSvc.monitor, svc.castNotice]) + root.link());
            root.done();
        },
        () => {
            if (!root.held(7000))
                return;
            root.check("c3 kept past the sweep's grace: still there, still streaming", svc.castPhase === "streaming" && root.has("LARES-CAST-1") && svc.engineState === "active",
                       root.j([svc.castPhase, svc.displays.map(d => d.name)]) + root.link());
            root.check("m0 there is a laptop panel to mirror", root.lap !== "", root.j(svc.displays.map(d => d.name)));
            svc.castSetMirror(true);
            root.check("m1 mirror is no trial", svc.phase === "idle", svc.phase);
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "streaming" && castSvc.state === "streaming" && castSvc.monitor === root.lap && !focus.outputs.some(o => o.name === "LARES-CAST-1"), 20000);
            if (r === false)
                return;
            root.check("m1 mirror on: the stream is on the laptop's output and the cast's own output is GONE from the compositor", r === true,
                       root.j([svc.castPhase, castSvc.state, castSvc.monitor, focus.outputs.map(o => o.name + (o.enabled === false ? ":off" : ""))]) + root.link());
            root.check("m1 the TV is still a display: the stand-in, mirroring", svc.castMirrored && root.has(svc.castDisplayName) && svc.plan.specs[svc.castDisplayName].mirror === root.lap && svc.mirroring,
                       root.j([svc.castDisplayName, svc.displays.map(d => d.name)]));
            root.check("m1 the link is active, nothing latched", svc.engineState === "active" && svc.engineLink.lastError === "", root.link());
            svc.castSetMirror(false);
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "streaming" && castSvc.state === "streaming" && castSvc.monitor === "LARES-CAST-1" && root.has("LARES-CAST-1"), 20000);
            if (r === false)
                return;
            root.check("m2 mirror off: the output is made again and streamed, the stand-in is gone", r === true && !svc.castMirrored && !root.has("LARES-CAST-0"),
                       root.j([svc.castPhase, castSvc.monitor, svc.displays.map(d => d.name)]) + root.link());
            svc.castSetMirror(true);
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "streaming" && castSvc.state === "streaming" && castSvc.monitor === root.lap && !focus.outputs.some(o => o.name === "LARES-CAST-1"), 20000);
            if (r === false)
                return;
            root.check("m3 mirror on again", r === true, root.j([svc.castPhase, castSvc.monitor]));
            svc.castStop();
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "idle" && castSvc.state === "idle" && svc.displays.length === 2, 12000);
            if (r === false)
                return;
            root.check("m3 stop: idle, the two displays", r === true, root.j([svc.castPhase, svc.displays.map(d => d.name)]));
            // the cast of a TV STORED as a mirror
            root.seenCast = [];
            root.mark = root.creates();
            root.check("m4 a cast of a TV stored as a mirror starts", svc.castStart(root.streams), svc.castPhase + root.j(svc.castNotice));
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "streaming" && castSvc.state === "streaming", 20000);
            if (r === false)
                return;
            root.check("m4 it streams the laptop's output", r === true && castSvc.monitor === root.lap, root.j([svc.castPhase, castSvc.monitor]));
            root.done();
        },
        () => {
            if (!root.held(2500))
                return;
            root.check("m4 NO cast output was ever made or listed for it (ARM mirroroutput)", root.seenCast.length === 0 && root.creates() === root.mark,
                       root.j([root.seenCast, root.creates(), root.mark, ((svc.engineLink.state || {}).log || []).slice(-4)]));
            svc.castSetMirror(false);
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "streaming" && castSvc.monitor === "LARES-CAST-1" && root.has("LARES-CAST-1"), 20000);
            if (r === false)
                return;
            root.check("m5 back to a display of its own (the stored setup is extended again for the checks below)", r === true, root.j([svc.castPhase, castSvc.monitor]));
            svc.castStop();
            root.done();
        },
        () => {
            const r = root.until(() => svc.castPhase === "idle" && !root.has("LARES-CAST-1"), 12000);
            if (r === false)
                return;
            root.check("c4 stop: the output is gone, idle", r === true, root.j([svc.castPhase, svc.displays.map(d => d.name)]));
            root.done();
        },
        () => {
            if (!root.held(1500))
                return;
            root.check("c4 the link is active, the TV can be cast to again", svc.castEnabled && svc.engineLink.lastError === "" && svc.castDevices.length > 0, root.link());
            root.done();
        }
    ]

    Timer {
        interval: 150
        running: true
        repeat: true
        onTriggered: {
            if (root.bare) {
                stop();
                console.log("PM RESULT PASS (bare: nothing driven)");
                Qt.quit();
                return;
            }
            if (root.step < root.steps.length) {
                try {
                    root.steps[root.step]();
                } catch (e) {
                    root.check("step " + root.step + " threw", false, String(e));
                    root.step = root.steps.length;
                }
                return;
            }
            stop();
            console.log("PM RESULT " + (root.fails === 0 ? "PASS" : "FAIL (" + root.fails + " checks)"));
            quit.start();
        }
    }
    Timer {
        id: quit
        interval: 0
        onTriggered: Qt.quit()
    }
    Timer {
        interval: 240000
        running: true
        onTriggered: {
            console.log("PM FAIL the run ran out of time at step " + root.step);
            console.log("PM RESULT FAIL (timeout)");
            Qt.quit();
        }
    }
}
