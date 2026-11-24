import QtQuick
import Quickshell

import "modules/common/system"
import "modules/panorama/data"

// =============================================================================
// panorama_mirror_env.qml -- the LIVE PanoramaService on a nested Hyprland (tools/dev/lock_env.sh), a REAL mirror trial and its revert.
// Run by tools/dev/panorama_shell_env_probe.sh (PHASE=mirror) after tools/dev/panorama_engine/shell_probe.py mirror has made the outputs
// (a headless eDP-1 stands in for the laptop panel; LOCK-1 is the external that mirrors it) and loaded the engine. Prints
// `PM ok|FAIL <check>` and `PM RESULT PASS|FAIL`. No Keep toast host here: the harness stands in for the toast (markShown).
//
//   m1 up: the engine active, eDP-1 and LOCK-1 listed, nobody mirrors
//   m2 stage + mirror + apply: the engine tries, the compositor really mirrors (LOCK-1.mirrorOf == eDP-1), phase awaiting
//   m3 revert: AT ONCE phase idle, nothing staged, then the compositor un-mirrors, the engine is still active (the popup is not read
//      only), the displays are back with mirrorOf none and no "disconnected" toast was asked for
//   m4 a second ordinary trial works: stage, move, apply, awaiting, keep -> idle and the store holds it
// =============================================================================
ShellRoot {
    id: root

    // smoked bare (no runner, no nested Hyprland): nothing live, quit at once
    readonly property bool bare: !Quickshell.env("PM_ENGINE")
    property int fails: 0
    property int step: 0
    property int waited: 0
    property var told: []
    function check(name, ok, detail) {
        console.log("PM " + (ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  -- " + detail));
        if (!ok)
            root.fails++;
    }
    function j(x) {
        return JSON.stringify(x);
    }

    FocusedScreen {
        id: focus
        live: !root.bare
    }
    QtObject {
        id: notifier
        signal action(string key, string id)
        function notify(key, rec) {
            root.told.push(rec.title);
        }
        function withdraw(key) {
        }
    }
    PanoramaService {
        id: svc
        live: !root.bare
        focusSource: focus
        notifier: notifier
        engineSource: Quickshell.env("PM_ENGINE")
    }

    function mirrorOf(name) {
        const d = svc.displays.find(x => x.name === name);
        return d ? d.mirrorOf : "?";
    }
    property real t0: 0
    function until(cond, ms) {
        if (cond())
            return true;
        if (root.t0 === 0)
            root.t0 = Date.now();
        if (Date.now() - root.t0 > ms) {
            root.t0 = 0;
            return null;
        }
        return false;
    }
    function done() {
        root.t0 = 0;
        root.step++;
    }

    property var steps: [
        () => {
            const r = root.until(() => svc.engineState === "active" && svc.displays.length === 2 && svc.plan.specs["eDP-1"] !== undefined, 20000);
            if (r === false)
                return;
            root.check("m1 up: engine active, eDP-1 and LOCK-1 listed", r === true, root.j([svc.engineState, svc.engineWhy, svc.displays.map(d => d.name)]));
            root.check("m1 nobody mirrors", !svc.mirroring && root.mirrorOf("LOCK-1") === "", root.mirrorOf("LOCK-1"));
            root.done();
        },
        () => {
            svc.stage();
            svc.stageSpec("LOCK-1", { mirror: true });
            root.check("m2 staged: LOCK-1 mirrors the laptop", svc.staged["LOCK-1"].mirror === true, root.j(svc.staged["LOCK-1"]));
            root.check("m2 apply starts the trial", svc.apply() === true && svc.phase === "applying", svc.phase);
            root.done();
        },
        () => {
            const r = root.until(() => svc.phase === "awaiting" && root.mirrorOf("LOCK-1") === "eDP-1", 15000);
            if (r === false)
                return;
            root.check("m2 the engine tried it, the compositor mirrors (phase " + svc.phase + ")", r === true, root.j([svc.phase, root.mirrorOf("LOCK-1"), svc.engineState]));
            svc.markShown();
            root.check("m2 the staged edit lives through the trial", svc.staged !== null, "");
            root.done();
        },
        () => {
            svc.revert();
            root.check("m3 revert: at once idle, nothing staged, nothing related left", svc.phase === "idle" && svc.staged === null && svc.stagedSplit === null,
                       root.j([svc.phase, svc.staged]));
            root.done();
        },
        () => {
            const r = root.until(() => !svc.mirroring && root.mirrorOf("LOCK-1") === "" && svc.displays.length === 2, 15000);
            if (r === false)
                return;
            root.check("m3 the compositor un-mirrors: LOCK-1 is back with mirrorOf none", r === true, root.j(svc.displays.map(d => [d.name, d.mirrorOf])));
            root.check("m3 the engine is still active (the popup is not read only)", svc.engineState === "active" && svc.engineLink.lastError === "",
                       root.j([svc.engineState, svc.engineWhy, svc.engineLink.lastError]));
            root.check("m3 idle, not dirty, the plan has no mirror", svc.phase === "idle" && !svc.dirty && svc.plan.specs["LOCK-1"].mirror === "", root.j([svc.phase, svc.dirty]));
            root.check("m3 no \"disconnected\" toast over the mirror's coming and going", !root.told.some(t => t.indexOf("disconnected") >= 0), root.j(root.told));
            root.done();
        },
        () => {
            // a second, ordinary trial
            const p = svc.plan.specs["LOCK-1"].position;
            svc.stage();
            svc.stageMove("LOCK-1", p[0] + 120, p[1]);
            root.check("m4 a second trial starts", svc.dirty && svc.apply() === true, root.j([svc.dirty, svc.phase]));
            root.done();
        },
        () => {
            const r = root.until(() => svc.phase === "awaiting", 15000);
            if (r === false)
                return;
            root.check("m4 the second trial reaches the toast (awaiting)", r === true, svc.phase);
            svc.markShown();
            svc.keep();
            root.check("m4 keep: idle, nothing staged", svc.phase === "idle" && svc.staged === null, svc.phase);
            root.done();
        },
        () => {
            root.waited++;
            if (root.waited < 8)
                return;
            const st = svc.store.doc.setups[svc.setKey];
            root.check("m4 the store holds the kept layout", !!st, root.j(Object.keys(svc.store.doc.setups || {})));
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
    // a hard ceiling: an env that never answers must not hang the runner
    Timer {
        interval: 120000
        running: true
        onTriggered: {
            console.log("PM FAIL the run ran out of time at step " + root.step);
            console.log("PM RESULT FAIL (timeout)");
            Qt.quit();
        }
    }
}
