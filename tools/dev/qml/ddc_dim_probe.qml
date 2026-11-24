pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "modules/idle"
import "modules/panorama/data"

// tools/dev/qml/ddc_dim_probe.qml -- the idle dimming of external displays (modules/idle/DdcDim.qml) on a real DdcClient and a stub ddcutil
// (DDP_PROGRAM; its figures are files, DDP_W/val.<bus>), behind PanoramaService's DDC surface. tools/dev/ddc_dim_probe.sh runs it.
// DDP_REAL=1: the one scenario a person runs on a real monitor (dim, deep, give back; the figure is read back by the client each time).
// Prints "DDP ok|FAIL <name>" and "DDP RESULT PASS|FAIL (<n>/<n>)".
Scope {
    id: root

    readonly property string dir: Quickshell.env("DDP_W") || ""
    readonly property bool real: Quickshell.env("DDP_REAL") === "1"
    property int fails: 0
    property int checks: 0
    function check(name: string, ok: bool, detail: string): void {
        root.checks++;
        if (!ok)
            root.fails++;
        console.log("DDP " + (ok ? "ok  " : "FAIL") + " " + name + (ok ? "" : "  [" + detail + "]"));
    }

    property var outs: root.real ? [{ name: "DP-1", make: "Acme", model: "UW34", serial: "real" }]
        : [{ name: "DP-1", make: "Dell", model: "U2723QE", serial: "7ZQ4PX3" }]
    DdcClient {
        id: ddc
        live: root.dir !== ""
        program: Quickshell.env("DDP_PROGRAM") || "false"
        outputs: root.outs
        timeoutMs: 8000
        cacheMs: 60000
        onValueChanged: n => be.ddcChanged(n)
    }
    QtObject {
        id: be
        signal ddcChanged(string name)
        readonly property bool ddcDetected: ddc.detected
        function ddcEnsure(): void { ddc.ensureDetected(); }
        function ddcNames(): var { return ddc.names(); }
        function ddcKey(n: string): string { return ddc.keyOf(n); }
        function ddcBusy(n: string): bool { return ddc.busy(n); }
        function ddcPending(n: string): bool { return ddc.pending(n); }
        function ddcState(n: string): string { return ddc.stateOf(n); }
        function ddcGoal(n: string): int { return ddc.goal(n); }
        function ddcMax(n: string): int { return ddc.max(n); }
        function ddcRead(n: string): void { ddc.read(n, true); }
        function ddcSet(n: string, v: int): void { ddc.set(n, v); }
        function ddcAdjust(n: string, d: int): bool { return ddc.adjust(n, d); }
        function ddcForgive(n: string): void { ddc.forgive(n); }
    }

    Component {
        id: dimC
        DdcDim {
            live: true
            active: true
            displays: be
            settings: ({ ddcDimLevel: 0.35, ddcDeepLevel: 0 })
            statePath: root.dir + "/state/ddc-dim.json"
        }
    }
    property var dim: null
    function make(): void {
        root.dim = dimC.createObject(root);
    }

    // ---- the world: the stub's files ----
    Process {
        id: sh
        stdout: StdioCollector { id: shOut }
        onExited: root._shDone = true
    }
    property bool _shDone: false
    property string out: ""
    function run(cmd: string): void {
        root._shDone = false;
        sh.command = ["sh", "-c", "cd '" + root.dir + "'; " + cmd];
        sh.running = true;
    }

    // ---- the steps: { act, until (bool function, waited for), after } ----
    property int at: -1
    property double startedAt: 0
    property bool acted: false
    readonly property int limitMs: 12000
    property var steps: []
    function val(): int { return ddc.value(root.outs.length > 0 ? root.outs[0].name : ""); }
    function settled(): bool { return !ddc.busy("DP-1") && !ddc.pending("DP-1") && !ddc.busy("DP-2") && !ddc.pending("DP-2"); }
    function file(): string { return root.out.trim(); }

    readonly property var stubSteps: [
        { name: "the client knows the display", until: () => ddc.value("DP-1") === 100 && root.settled(), after: () => root.make() },
        // ---- dim, deep, back
        { name: "dim: 35 % of 100", act: () => { root.dim.level = 1; }, until: () => root.settled() && ddc.value("DP-1") === 35, sh: "cat val.5; cat saved_at_set",
          after: () => root.check("the display's own figure was saved before the write", root.file().indexOf("35") === 0 && root.file().indexOf("\"full\":100") > 0, root.file()) },
        { name: "deep: 0", act: () => { root.dim.level = 2; }, until: () => root.settled() && ddc.value("DP-1") === 0, sh: "cat val.5; cat state/ddc-dim.json",
          after: () => root.check("deep keeps the figure to give back", root.file().indexOf("0") === 0 && root.file().indexOf("\"full\":100") > 0, root.file()) },
        { name: "activity: 100 again", act: () => { root.dim.level = 0; }, until: () => root.settled() && ddc.value("DP-1") === 100 && Object.keys(root.dim.saved).length === 0, sh: "cat val.5; cat state/ddc-dim.json",
          after: () => root.check("the state file is empty once it has its own back", root.file() === "100\n{}", root.file()) },
        // ---- the display's own buttons moved it since the last read: the fresh figure is the one to give back
        { name: "its buttons moved it to 80", sh0: "echo 80 > val.5" },
        { name: "dim reads it fresh: 28", act: () => { root.dim.level = 1; }, until: () => root.settled() && ddc.value("DP-1") === 28 },
        { name: "and gives back 80", act: () => { root.dim.level = 0; }, until: () => root.settled() && ddc.value("DP-1") === 80 && Object.keys(root.dim.saved).length === 0 },
        // ---- a brightness key ends the idleness: its step is kept, whichever lands first
        { name: "dim: 28", act: () => { root.dim.level = 1; }, until: () => root.settled() && ddc.value("DP-1") === 28 },
        { name: "a key's step before the give-back is kept: 85", act: () => { be.ddcAdjust("DP-1", 5); root.dim.level = 0; }, until: () => root.settled() && Object.keys(root.dim.saved).length === 0,
          after: () => root.check("80 + 5", ddc.value("DP-1") === 85, ddc.value("DP-1")) },
        { name: "dim: 30", act: () => { root.dim.level = 1; }, until: () => root.settled() && ddc.value("DP-1") === 30 },
        { name: "a key's step after it too: 80", act: () => { root.dim.level = 0; Qt.callLater(() => be.ddcAdjust("DP-1", -5)); }, until: () => root.settled() && Object.keys(root.dim.saved).length === 0,
          after: () => root.check("85 - 5", ddc.value("DP-1") === 80, ddc.value("DP-1")) },
        // ---- an idleness that ends before the read has landed writes nothing
        { name: "a flicker", sh0: ": > ddcutil.log", act: () => { root.dim.level = 1; Qt.callLater(() => { root.dim.level = 0; }); }, wait: 900, until: () => root.settled(), sh: "grep -c setvcp ddcutil.log || true",
          after: () => root.check("a flicker writes nothing", root.file() === "0" && Object.keys(root.dim.saved).length === 0, root.file()) },
        // ---- idle again while its own figure is on the way back
        { name: "dim: 28 (again)", act: () => { root.dim.level = 1; }, until: () => root.settled() && ddc.value("DP-1") === 28 },
        { name: "back and idle at once", act: () => { root.dim.level = 0; again.start(); }, wait: 900, until: () => root.settled() && ddc.value("DP-1") === 28,
          after: () => root.check("the figure to give back is still 80", Object.values(root.dim.saved).length === 1 && Object.values(root.dim.saved)[0].full === 80, JSON.stringify(root.dim.saved)) },
        // ---- the write back fails twice (the display is waking up)
        { name: "the give-back fails", sh0: "echo 2 > fail_sets", act: () => { root.dim.level = 0; }, until: () => ddc.stateOf("DP-1") === "failing" },
        { name: "it is tried again until it has it: 80", until: () => root.settled() && ddc.value("DP-1") === 80 && Object.keys(root.dim.saved).length === 0, limit: 20000 },
        // ---- switched off while dimmed, on again on another connector
        { name: "deep: 0 (again)", act: () => { root.dim.level = 2; }, until: () => root.settled() && ddc.value("DP-1") === 0 },
        { name: "the display goes", act: () => { root.outs = []; root.dim.level = 0; }, wait: 600, until: () => true },
        { name: "it comes back on DP-2", sh0: "touch on_dp2", act: () => { root.outs = [{ name: "DP-2", make: "Dell", model: "U2723QE", serial: "7ZQ4PX3" }]; },
          until: () => !ddc.busy("DP-2") && !ddc.pending("DP-2") && ddc.value("DP-2") === 80 && Object.keys(root.dim.saved).length === 0 },
        { name: "and is put on DP-1 again", sh0: "rm -f on_dp2", act: () => { root.outs = [{ name: "DP-1", make: "Dell", model: "U2723QE", serial: "7ZQ4PX3" }]; }, until: () => ddc.value("DP-1") === 80 && root.settled() },
        // ---- the shell ends while it is dimmed: the next one gives it back
        { name: "dim: 28 (the shell will end)", act: () => { root.dim.level = 1; }, until: () => root.settled() && ddc.value("DP-1") === 28 },
        { name: "a new shell gives it back: 80", act: () => { root.dim.destroy(); root.make(); }, until: () => root.settled() && ddc.value("DP-1") === 80 && Object.keys(root.dim.saved).length === 0 },
        // ---- not the shell's to dim
        { name: "switched off for this machine", sh0: ": > ddcutil.log", act: () => { root.dim.active = false; root.dim.level = 2; }, wait: 900, until: () => true, sh: "grep -c vcp ddcutil.log || true",
          after: () => root.check("ddcDim off asks the display for nothing", root.file() === "0", root.file()) },
        { name: "on again at level 2: 0", act: () => { root.dim.active = true; }, until: () => root.settled() && ddc.value("DP-1") === 0 },
        { name: "off while dimmed gives it back: 80", act: () => { root.dim.active = false; }, until: () => root.settled() && ddc.value("DP-1") === 80 && Object.keys(root.dim.saved).length === 0 },
        // ---- 0 is the user's
        { name: "the user's own 0", sh0: "echo 0 > val.5; : > ddcutil.log", act: () => { root.dim.level = 0; root.dim.active = true; root.dim.level = 1; }, wait: 1200, until: () => root.settled(), sh: "grep -c setvcp ddcutil.log || true",
          after: () => root.check("a display at 0 is left alone", root.file() === "0" && Object.keys(root.dim.saved).length === 0, root.file()) }
    ]
    property int realFull: -1
    readonly property var realSteps: [
        { name: "the client knows the display", until: () => ddc.value("DP-1") > 0 && root.settled(), after: () => { root.realFull = ddc.value("DP-1"); console.log("DDP figure " + root.realFull); root.make(); } },
        { name: "dim", act: () => { root.dim.level = 1; }, until: () => root.settled() && ddc.value("DP-1") === Math.round(root.realFull * 0.35), hold: 2500 },
        { name: "deep", act: () => { root.dim.level = 2; }, until: () => root.settled() && ddc.value("DP-1") === 0, hold: 2500 },
        { name: "activity", act: () => { root.dim.level = 0; }, until: () => root.settled() && ddc.value("DP-1") === root.realFull && Object.keys(root.dim.saved).length === 0 },
        { name: "read back from the display", act: () => ddc.read("DP-1", true), wait: 700, until: () => root.settled() && ddc.value("DP-1") === root.realFull }
    ]

    Timer {
        id: again
        interval: 30
        onTriggered: root.dim.level = 1
    }
    function next(): void {
        root.at++;
        root.acted = false;
        root.startedAt = Date.now();
        if (root.at >= root.steps.length) {
            console.log("DDP RESULT " + (root.fails === 0 ? "PASS" : "FAIL") + " (" + (root.checks - root.fails) + "/" + root.checks + " checks)");
            if (root.dim !== null)
                console.log("DDP log " + JSON.stringify(root.dim.log.map(e => e.act + " " + e.value)));
            quit.start();
            driver.stop();
            return;
        }
        const s = root.steps[root.at];
        if (s.sh0)
            root.run(s.sh0);
        else
            root._shDone = true;
    }
    property bool _reading: false
    property double _okAt: 0
    // a step that throws is a failed check, never a step asked again for ever
    function guarded(f: var, name: string): bool {
        try {
            return f() !== false;
        } catch (e) {
            root.check(name + " (it threw)", false, String(e));
            return true;
        }
    }
    Timer {
        id: driver
        interval: 25
        repeat: true
        running: root.dir !== ""
        onTriggered: {
            if (root.at < 0) {
                root.steps = root.real ? root.realSteps : root.stubSteps;
                root.next();
                return;
            }
            const s = root.steps[root.at];
            if (!root.acted) {
                if (!root._shDone)
                    return;
                root.acted = true;
                root._okAt = 0;
                root._reading = false;
                root.startedAt = Date.now();
                if (s.act)
                    root.guarded(s.act, s.name);
                return;
            }
            if (root._reading) {
                if (!root._shDone)
                    return;
                root.out = shOut.text;
                root._reading = false;
                if (s.after)
                    root.guarded(s.after, s.name);
                root.next();
                return;
            }
            const waited = Date.now() - root.startedAt;
            if (root._okAt === 0) {
                if (waited < (s.wait || 0))
                    return;
                const ok = s.until ? root.guarded(s.until, s.name) : true;
                if (!ok && waited < (s.limit || root.limitMs))
                    return;
                root.check(s.name, ok, "after " + waited + " ms: " + ddc.stateOf("DP-1") + " " + ddc.value("DP-1") + " " + (root.dim ? JSON.stringify(root.dim.saved) : ""));
                root._okAt = Date.now();
            }
            if (Date.now() - root._okAt < (s.hold || 0))
                return;
            if (s.sh) {
                root._reading = true;
                root.run(s.sh);
                return;
            }
            if (s.after)
                root.guarded(s.after, s.name);
            root.next();
        }
    }
    Timer {
        id: quit
        interval: 50
        running: root.dir === ""
        onTriggered: Qt.quit()
    }
}
