pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "modules/silicon/data"
import "modules/silicon/data/SiliconModel.js" as Model
import "modules/common/power"
import "modules/common/osd"
import "modules/common/system"

// =============================================================================
// test_silicon_service_probe.qml -- silicon's data layer end to end, headless, on a FAKE machine.
// Run by tools/dev/silicon_service_probe.sh (sandbox, private XDG dirs, a private D-Bus with the cardwire
// stand-in on it, stub pkexec / systemctl / nvidia-smi / pw-play / notify-send / busctl / gdbus first
// on PATH, the helper stand-in -- or stage 2's real binary in test mode -- over a COPY of the fixture
// tree). SSP_PHASE picks the launch:
//
//   main      the service against the fake machine: the facts at start, the stats (per-core loads,
//             clock, temperature, the iGPU's busy share), the battery (unplug, replug, low, full,
//             events, time left / to full), a profile step (settle, one write, read-back), the burst
//             that makes ONE write, a refused write that animates back with its reason (local, the
//             helper's refusal, a read-back mismatch, a helper that does not answer), tuning and its
//             reset, an external profile change (applied + OSD, through OsdBus and through the
//             notification fallback), the charge limit, cardwire (a mode change, an external one, the
//             D-state, holders appearing -> nvidia-smi ALLOWED, holders gone -> it STOPS, never while
//             the card sleeps, blocked apps, ignore, policies, config), a hot reload of silicon.jsonc
//             (and its warnings, once each), holds (PowerBus; the system update's marker; a manual
//             change wins), resume (nothing re-applied; a firmware reset put back), the MUX
//             (request / restart / cancel), and the state file.
//             (round 3 T2) UPower's charge history: the service asks it ONCE at start, with the one read-only call, and the
//             moment it gives (the captured week's newest full point) is the since-full figure; a full event asks again, soon;
//             a pack that stops being full is the last moment it was; UpowerHistory on its own against the stand-in
//             (tools/dev/stubs/silicon/upower_gdbus, which answers the captured real answers byte for byte): the throttle, the
//             popup-driven asks, the order of the answer, every failure a stated reason, a missing gdbus quiet.
//   nohelper  no helper, no cardwire: the battery strip still reads, the CPU and GPU zones are absent,
//             every intent says why, nothing warns.
//   hidden    a kernel without rc6, coretemp, the charge limit, max_perf_pct and the MUX file.
//   mock      SiliconMock has the service's members and fires its events.
//   mux       the MUX END TO END against the REAL helper in test mode (the runner builds it from the tree): request
//             -> queued -> restart now (systemctl is a stub; the marker REBOOT_REQUESTED) -> the machine goes down
//             (the shell is destroyed, the shutdown unit's `mux-apply` runs) -> boots (a new boot id, the panel wired
//             as the firmware says, the boot guard runs) -> a NEW shell finds the record awaiting a keep -> the prompt
//             is shown (two minutes from now) -> a click keeps; and with no click the guard reverts at the deadline,
//             the next shell tells the user once and marks the outcome seen, the one after says nothing. Also the
//             way back with the NVIDIA stack up, and a dGPU request with the stack up (not written).
//   update    the system update's hold under the REAL supervisor (helpers/update-run.sh, a `sleep` for yay): a run
//             holds Performance, a manual change wins, the hold ends with the run.
//   fan       the FAN GUARD (round 8; FanGuard.qml): the CPU temperature judged against what the load normally produces, on a baseline
//             the runner seeds (thermal-baseline.json), with the guard's times shortened to seconds. Heavy load at 95 degrees does NOT fire; 92
//             at a light load fires -> a silent re-kick (two `apply profile=`, the kick's profile never shown, no OSD, no hold dropped) ->
//             cured within the recheck gives NO notice; still hot -> a critical notice + a Performance hold -> cooled below 75 -> released;
//             a resume makes ONE kick; a profile with no baseline fires only on the extreme case; a steady load teaches the baseline.
//   boot      the boot profile (Q16) against the REAL helper in test mode: silicon.jsonc's `defaultProfile` is STORED as the
//             helper's boot set (ONE set-boot with that profile's linked values; the fake state dir's boot.json holds them),
//             a second shell writes nothing, another profile and an edit of the named row write again (hot), no key writes
//             and clears nothing, a refusal is the boot profile's why and is not asked again (no storm) until the boot set
//             changes -- and nothing in the phase is ever APPLIED (no `apply`, the fake platform_profile unmoved).
//
// One `SILP <check> PASS|FAIL  detail` line per check, then `SILP DONE <phase> PASS|FAIL` and a quit
// from a 0 ms Timer (Qt.quit in onCompleted is lost).
// =============================================================================
ShellRoot {
    id: root

    readonly property string phase: Quickshell.env("SSP_PHASE") || "main"
    readonly property string out: Quickshell.env("SSP_OUT") || "/nonexistent"
    readonly property string fx: Quickshell.env("SSP_FX") || "/nonexistent"
    readonly property string logs: Quickshell.env("SSP_LOGS") || "/nonexistent"
    readonly property string helperBin: Quickshell.env("SSP_HELPER") || "/nonexistent"
    // the gdbus stand-in for UPower (tools/dev/stubs/silicon/upower_gdbus): the service's one call to UPower goes to it, never to a bus
    readonly property string upowerBin: Quickshell.env("SSP_UPOWER") || "/nonexistent/upower_gdbus"
    // the newest fully-charged point of the week the stand-in answers (ms): the runner reads it from the fixture's first tuple, so the same checks replay
    // the synthetic week and the user's real one (NaN, and every check on it red, when the runner did not say)
    readonly property real weekMs: Number(Quickshell.env("SSP_WEEK"))
    readonly property string xdgConfig: Quickshell.env("XDG_CONFIG_HOME")
    readonly property string xdgState: Quickshell.env("XDG_STATE_HOME")
    readonly property string tree: root.fx + "/tree"
    // --run-root: where systemd keeps one `invocation:<unit>` link per ACTIVE unit (the runner makes it: silicon-mux.service
    // active, and another unit so that taking this one away is not mistaken for "systemd exports no such links")
    readonly property var helperFlags: ["--sysfs-root", root.tree, "--proc-root", root.tree + "/proc", "--state-dir", root.fx + "/state",
                                        "--modules-root", root.tree + "/usr/lib/modules", "--run-root", root.fx + "/runroot"]
    readonly property string unitLink: root.fx + "/runroot/run/systemd/units/invocation:silicon-mux.service"
    readonly property var statusCmd: (root.phase === "nohelper" || root.phase === "mock") ? ["/nonexistent/silicon-helper"] : [root.helperBin].concat(root.helperFlags)
    readonly property var writeCmd: ["pkexec", root.helperBin].concat(root.helperFlags)
    // Armed only by the runner (tools/dev/silicon_service_probe.sh: private bus, stubs first on PATH). Anything
    // else -- tools/dev/smoke.sh loading this file to read its warnings -- must not ask the machine or the
    // user's buses a thing: no cardwire, no helper, and the scenario does not run.
    readonly property bool armed: Quickshell.env("SSP_OUT") !== null && Quickshell.env("SSP_OUT") !== undefined && Quickshell.env("SSP_OUT") !== ""
    property bool ok: true

    // ---- reporting -----------------------------------------------------------------------
    function check(name, cond, detail) {
        console.log("SILP " + name + " " + (cond ? "PASS" : "FAIL") + (detail !== undefined && detail !== "" ? "  " + detail : ""));
        if (!cond)
            root.ok = false;
        return cond;
    }
    function info(text) { console.log("SILP info " + text); }
    // The shells the phase started (the MUX phase restarts the shell with the machine; each has its own gdbus monitor).
    property int instances: root.phase === "mux" ? 0 : 1
    function finish() {
        console.log("SILP info instances " + root.instances);
        console.log("SILP DONE " + root.phase + " " + (root.ok ? "PASS" : "FAIL"));
        quitTimer.start();
    }
    Timer { id: quitTimer; interval: 0; onTriggered: Qt.quit() }

    // ---- the service under test ------------------------------------------------------------------
    SiliconService {
        id: svc
        configPath: root.xdgConfig + "/quickshell/silicon.json"
        statePath: root.xdgState + "/lares/silicon/state.json"
        persist: root.armed && root.phase !== "mux"
        // the guard is the fan phase's subject alone: elsewhere a resume's kick would be a write nobody counts
        fanGuardEnabled: root.phase === "fan"
        fanSampleMs: root.phase === "fan" ? 1000 : 5000
        oldLastFullPath: root.phase === "hidden" ? root.out + "/oldlast/last-full" : root.out + "/none/last-full"
        updateMarkerPath: root.xdgState + "/lares/system-update/last-run.json"
        // (the MUX and boot phases start their own shells, and restart them: this one stays out of it)
        helperStatusCommand: root.phase === "mux" || root.phase === "boot" ? ["/nonexistent/silicon-helper"] : root.statusCmd
        helperWriteCommand: root.writeCmd
        cardwireBus: "session"
        cardwireEnabled: root.armed && root.phase !== "mock" && root.phase !== "mux" && root.phase !== "update" && root.phase !== "boot" && root.phase !== "fan"
        // the helper's boot set is the fake machine's (never /var/lib/silicon), in every phase
        bootFile: root.bootJsonFile
        // (the update phase's hold reads the REAL /proc: the supervisor's cmdline is there, not in the fake one)
        procRoot: root.phase === "update" ? "/proc" : root.tree + "/proc"
        defaultPaths: ({ battery: root.tree + "/sys/class/power_supply/BAT0", ac: root.tree + "/sys/class/power_supply/AC0" })
        helperTimeoutMs: 2500
        upowerGdbus: root.upowerBin
        upowerEnabled: root.phase === "main"
        // the display connectors are the fake machine's (its card0 is the NVIDIA card, vendor 0x10de, with an HDMI-A); the udev monitor is the shim on PATH
        drmRoot: root.tree + "/sys/class/drm"
        usbRoot: root.tree + "/sys/bus/usb/devices"
        evdiModule: root.tree + "/sys/module/evdi"
        // (the MUX phase starts its own shells, each counted with its monitors: this one stays out of it, as it does for cardwire)
        displayEnabled: root.phase !== "mux" && root.phase !== "boot"
        // the power_supply udev monitor is the shim's too (its own feed); only the main phase makes the plug events its steps feed
        powerEventsEnabled: root.phase === "main"
    }
    // UPower's reader on its own, against the stand-in, for the checks the service's single instance cannot make (main phase only)
    UpowerHistory {
        id: upT
        gdbus: root.phase === "main" ? root.upowerBin : "/nonexistent/upower_gdbus"
        batteryPath: "/sys/class/power_supply/BAT7"
        minGapMs: 2000
        eventDelayMs: 300
        timeoutMs: 1500
    }

    // The mock phase's subject: the same members, no machine (it starts, and stays, still).
    SiliconMock {
        id: mock
        playing: false
        settleMs: 100
        writeMs: 60
    }

    // ---- stimulus: files on the fake machine, the cardwire stand-in, the logs ----------------
    ProcLane { id: stim; timeoutMs: 8000 }
    property int ops: 0
    // Replace a file atomically (a reader never sees half of it).
    function put(path, text) {
        root.ops++;
        stim.run(["sh", "-c", "printf '%s' \"$2\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"", "sh", path, text], function (res) {
            root.ops--;
            if (res.code !== 0)
                root.check("stimulus " + path, false, res.err);
        });
    }
    // Rewrite a file IN PLACE (an editor that saves into the same inode).
    function putInPlace(path, text) {
        root.ops++;
        stim.run(["sh", "-c", "printf '%s' \"$2\" > \"$1\"", "sh", path, text], function (res) {
            root.ops--;
            if (res.code !== 0)
                root.check("stimulus " + path, false, res.err);
        });
    }
    // Ask the service to read the machine AFTER the stimuli before it: they are spawned one after another, but a refresh made in the
    // same breath starts its own process at once, and against the real helper (a status in 4 ms; the stand-in's python takes
    // 30) it read the machine as it was and the next read waited for the minute's backstop.
    function refreshAfter() {
        root.ops++;
        stim.run(["true"], function () { root.ops--; svc.refresh(); });
    }
    function sh(script) {
        root.ops++;
        stim.run(["sh", "-c", script], function (res) {
            root.ops--;
            if (res.code !== 0)
                root.check("stimulus sh", false, res.err);
        });
    }
    function ctl(method, arg) {
        root.ops++;
        const argv = ["gdbus", "call", "--session", "--dest", "org.lares.CardwireStub", "--object-path", "/org/lares/cardwire_stub",
                      "--method", "org.lares.CardwireStub.Control." + method];
        stim.run(arg === undefined ? argv : argv.concat(arg instanceof Array ? arg : [arg]), function (res) {
            root.ops--;
            if (res.code !== 0)
                root.check("control " + method, false, res.err);
        });
    }

    property var _logViews: ({})
    Component { id: viewComp; FileView { blockLoading: true; blockAllReads: true; printErrors: false } }
    function logLines(name) {
        let v = root._logViews[name];
        if (!v) {
            v = viewComp.createObject(root, { path: root.logs + "/" + name });
            root._logViews[name] = v;
        }
        v.reload();
        return v.text().split("\n").filter(function (l) { return l !== ""; });
    }
    // The calls of a stub log: [{ at, text }].
    function calls(name) {
        return root.logLines(name).map(function (l) {
            const i = l.indexOf(" ");
            return { at: Number(l.substring(0, i)), text: l.substring(i + 1) };
        });
    }
    // the calls the UPower stand-in logged for one device (BAT0 is the service's, BAT7 the reader's own)
    function upCalls(dev) {
        return root.calls("upower.log").filter(function (c) { return c.text.indexOf("battery_" + dev + " ") > 0; });
    }
    function upMode(m) {
        root.put(root.logs + "/upower_mode", m);
    }
    function writes() {
        return root.calls("pkexec.log").filter(function (c) { return c.text.indexOf(" apply") >= 0 || c.text.indexOf(" set-charge-limit") >= 0 || c.text.indexOf(" mux-") >= 0; });
    }
    function applies() {
        return root.calls("pkexec.log").filter(function (c) { return /\sapply(\s|$)/.test(c.text); });
    }

    // ---- the step engine ---------------------------------------------------------------------------
    property var steps: []
    property int stepIndex: -1
    property var cur: null
    property real curStart: 0
    property string detail: ""
    function step(name, fn, until, timeoutMs) {
        root.steps.push({ name: name, fn: fn, until: until, timeoutMs: timeoutMs || 6000 });
    }
    // A pause (ms).
    function pause(ms) {
        let mark = 0;
        root.step("wait " + ms + " ms", function () { mark = Date.now(); }, function () { return Date.now() - mark >= ms; }, ms + 3000);
    }
    // The long phases are one story: a step that came out red leaves the machine somewhere the next steps do not
    // expect, so they would only time out one after the other. They stop at the first red check.
    readonly property bool failFast: root.phase === "mux" || root.phase === "update" || root.phase === "boot"
    function advance() {
        root.stepIndex++;
        if (root.stepIndex >= root.steps.length || (root.failFast && !root.ok)) {
            ticker.stop();
            root.finish();
            return;
        }
        root.cur = root.steps[root.stepIndex];
        root.curStart = Date.now();
        root.detail = "";
        try {
            if (root.cur.fn)
                root.cur.fn();
        } catch (e) {
            root.check(root.cur.name, false, "threw: " + e);
            root.cur = null;
            Qt.callLater(root.advance);
        }
    }
    function tick() {
        if (root.cur === null)
            return;
        let done = true;
        if (root.cur.until) {
            try {
                done = root.ops === 0 && !!root.cur.until();
            } catch (e) {
                done = false;
                root.detail = "threw: " + e;
            }
        }
        if (done) {
            if (root.cur.until)
                root.check(root.cur.name, true);
            root.cur = null;
            root.advance();
        } else if (Date.now() - root.curStart > root.cur.timeoutMs) {
            root.check(root.cur.name, false, "timed out" + (root.detail !== "" ? ": " + root.detail : ""));
            root.cur = null;
            root.advance();
        }
    }
    Timer { id: ticker; interval: 40; repeat: true; onTriggered: root.tick() }

    // ======================================================================================
    // the scenario
    // ======================================================================================
    function j(v) { return JSON.stringify(v); }

    Component.onCompleted: {
        if (!root.armed) {
            // run on its own (a smoke test, a stray `quickshell -p`): it loads, checks nothing and says so
            console.log("SILP DONE " + root.phase + " SKIPPED (not armed: no SSP_OUT; this file is run by tools/dev/silicon_service_probe.sh)");
            quitTimer.start();
            return;
        }
        if (root.phase === "nohelper")
            root.buildNoHelper();
        else if (root.phase === "hidden")
            root.buildHidden();
        else if (root.phase === "mock")
            root.buildMock();
        else if (root.phase === "mux")
            root.buildMux();
        else if (root.phase === "update")
            root.buildUpdate();
        else if (root.phase === "boot")
            root.buildBoot();
        else if (root.phase === "fan")
            root.buildFan();
        else
            root.buildMain();
        ticker.start();
        Qt.callLater(root.advance);
    }


    // ======================================================================================
    // the fan guard (phase fan): the CPU's temperature against what its load normally gives
    // ======================================================================================
    // The popup stays CLOSED (the guard runs on the closed beat, which is what it does at rest): that beat is one second here.
    Binding { target: svc.idleLadder; property: "batteryHaltedMs"; value: 1000; when: root.phase === "fan" }
    readonly property string tempFile: root.tree + "/sys/devices/platform/coretemp.0/hwmon/hwmon4/temp1_input"
    readonly property string baselineFile: root.xdgState + "/lares/silicon/thermal-baseline.json"
    // The fake machine's load: every CPU is `loadShare` busy, forever (the counters of /proc/stat grow by 40 jiffies a tick).
    property real loadShare: 0.1
    property var _cumBusy: []
    property var _cumIdle: []
    ProcLane { id: loadLane; timeoutMs: 4000 }
    Timer {
        interval: 400
        repeat: true
        running: root.armed && root.phase === "fan"
        onTriggered: {
            if (root._cumBusy.length === 0) {
                root._cumBusy = new Array(22).fill(0);
                root._cumIdle = new Array(22).fill(0);
            }
            const busy = Math.round(40 * root.loadShare);
            root._cumBusy = root._cumBusy.map(v => v + busy);
            root._cumIdle = root._cumIdle.map(v => v + 40 - busy);
            loadLane.run(["sh", "-c", "printf '%s' \"$2\" > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"", "sh", root.statFile, root.statText(root._cumBusy, root._cumIdle)], function () {});
        }
    }
    function temp(c) { root.put(root.tempFile, Math.round(c * 1000) + "\n"); }
    property var profileTrail: []
    Connections {
        target: svc
        function onCpuChanged() {
            if (svc.cpu.profile !== "" && (root.profileTrail.length === 0 || root.profileTrail[root.profileTrail.length - 1] !== svc.cpu.profile))
                root.profileTrail = root.profileTrail.concat([svc.cpu.profile]);
        }
    }
    function buildFan() {
        const fg = svc.fanGuard;
        const sleepLine = function (on) { return "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (" + on + ",)\n"; };
        const stuckNotices = function () { return root.calls("notify-send.log").filter(function (c) { return c.text.indexOf("fans look stuck") >= 0; }); };
        const hold = function () { return PowerBus.holds["fan-guard"]; };
        let n0 = 0, k0 = 0, o0 = 0, nn0 = 0, ln0 = 0;

        root.step("fan: the machine is read, the guard is ready, and its times are seconds", function () {
            // every CPU runs at half the top clock: a busy share s is a load index of s * 50
            root.sh("for f in '" + root.polDir + "'/policy*/scaling_cur_freq; do echo 2400000 > \"$f\"; done");
            root.temp(55);
            fg.confirmMs = 3000;
            fg.recheckMs = 5000;
            fg.graceMs = 4000;
            fg.peakMs = 4000;
            fg.learnStableMs = 3000;
            fg.resumeKickMs = 1000;
        }, function () { root.detail = j([svc.helper.ok, svc.cpu.profile, fg.ready]); return svc.helper.ok && svc.cpu.profile === "balanced" && fg.ready && svc.cadence.guard === 1 && svc.cadence.baseMs === 1000; }, 20000);
        root.step("fan-learns: a steady light load at 55 degrees teaches the baseline (bucket 1 had 500 samples)", null, function () {
            const b = fg.thermalBase.balanced;
            root.detail = j([fg.learned, b ? b["1"] : null]);
            return fg.learned >= 2 && b && b["1"] && b["1"].n > 500;
        }, 25000);
        root.step("fan-rest: and nothing was kicked, said or held", function () {
            root.check("fan-rest", fg.stage === "idle" && svc.profileKicks === 0 && stuckNotices().length === 0 && hold() === undefined && root.applies().length === 0, j([fg.stage, svc.profileKicks, root.applies().length]));
            root.check("fan-closed-popup", svc.popupOpen === false && svc.idleState === "halt", j([svc.popupOpen, svc.idleState]));
        });

        // ---- the same temperature at a heavy load is work ---------------------------------------------------------------------
        root.step("fan: a heavy load (index 50) at 95 degrees, which this profile reads at that load", function () { root.loadShare = 1.0; root.temp(95); }, function () { return fg.last !== null && fg.last.peak >= 49; }, 15000);
        root.pause(9000);
        root.step("fan-heavy-no-fire: 9 s hot at a heavy load (three times the confirm time): no kick, no notice, nothing suspected", function () {
            root.check("fan-heavy-no-fire", svc.profileKicks === 0 && stuckNotices().length === 0 && fg.stage === "idle" && root.applies().length === 0, j([fg.stage, svc.profileKicks, fg.last]));
            root.check("fan-heavy-expected", fg.last.expectedC >= 95 && fg.last.suspicious === false, j(fg.last));
        });

        // ---- 92 at a light load is not: a silent re-kick, no hold dropped, no profile shown -----------------------------------------
        root.step("fan: the load falls to a light one while the package stays at 92 degrees (a hold of another module is up)", function () {
            n0 = root.applies().length;
            k0 = svc.profileKicks;
            o0 = root.evOsd.length;
            root.profileTrail = [];
            PowerBus.hold("probe", "balanced", "the probe's hold");
            root.loadShare = 0.1;
            root.temp(92);
        }, function () { root.detail = j([fg.stage, fg.last]); return svc.profileKicks === k0 + 1; }, 30000);
        root.step("fan: ... the two writes of the kick go out", null, function () { return root.applies().length === n0 + 2; }, 8000);
        root.step("fan-kick-pair: another profile, a pause, this one back -- and nothing else was written", function () {
            const a = root.applies();
            root.check("fan-kick-via", a[n0].text === root.base("apply profile=quiet"), a[n0].text);
            root.check("fan-kick-back", a[n0 + 1].text === root.base("apply profile=balanced"), a[n0 + 1].text);
            root.check("fan-kick-gap", a[n0 + 1].at - a[n0].at >= 1200, String(a[n0 + 1].at - a[n0].at) + " ms between the writes");
        });
        root.step("fan-kick-quiet: it is not a manual change: the hold stays, no OSD, the target never moved, and the kick's profile was never shown", function () {
            root.check("fan-kick-keeps-hold", PowerBus.holds.probe !== undefined && PowerBus.heldProfile === "balanced", j(PowerBus.holds));
            root.check("fan-kick-no-osd", root.evOsd.length === o0 && svc.profileTarget === 1, j([root.evOsd.length - o0, svc.profileTarget]));
            root.check("fan-kick-never-shown", root.profileTrail.every(function (x) { return x === "balanced"; }) && svc.cpu.profile === "balanced", j(root.profileTrail));
            root.check("fan-kick-state", fg.stage === "kicked", fg.stage);
            PowerBus.release("probe");
        });

        // ---- the kick cured it: no notice -------------------------------------------------------------------------------------------
        root.step("fan: the kick worked: the package falls to 60", function () { root.temp(60); }, function () { return fg.stage === "idle"; }, 15000);
        root.pause(2000);
        root.step("fan-cured-silent: no notice, no hold, no second kick", function () {
            root.check("fan-cured-silent", stuckNotices().length === 0 && hold() === undefined && svc.profileKicks === k0 + 1 && root.applies().length === n0 + 2, j([stuckNotices().length, svc.profileKicks - k0, root.applies().length - n0]));
        });

        // ---- the kick did not: the notice and the Performance hold, then the release --------------------------------------------------
        root.step("fan: the package is at 92 again, and stays there through the kick", function () { k0 = svc.profileKicks; n0 = root.applies().length; nn0 = root.calls("notify-send.log").length; root.temp(92); },
                  function () { root.detail = j([fg.stage, fg.last, svc.profileKicks - k0]); return stuckNotices().length === 1; }, 45000);
        root.step("fan-alarm: one kick first, then the critical notice with the figures, and Performance held", function () {
            const n = stuckNotices()[0].text;
            root.check("fan-kick-first", svc.profileKicks === k0 + 1, String(svc.profileKicks - k0));
            root.check("fan-alarm-critical", n.indexOf("-a Silicon") >= 0 && n.indexOf("-u critical") >= 0, n);
            root.check("fan-alarm-words", n.indexOf("The CPU is at 92 °C") >= 0 && /usually reads 5[789] °C/.test(n) && n.indexOf("% of full speed") >= 0 && n.indexOf("balanced profile comes back") >= 0, n);
            root.check("fan-alarm-hold", hold() !== undefined && hold().profile === "performance" && fg.stage === "held" && fg.alarms === 1, j([hold(), fg.stage]));
        });
        root.step("fan: ... and the machine really goes to Performance (HoldFollower)", null, function () { return svc.cpu.profile === "performance"; }, 10000);
        root.step("fan: the fans spin up: the package falls to 70", function () { root.temp(70); }, function () { return hold() === undefined; }, 15000);
        root.step("fan-release: the hold is released below 75 and the user's profile is back", null, function () { return svc.cpu.profile === "balanced"; }, 12000);
        root.step("fan-release-state: the guard is idle, and there was exactly one notice", function () {
            root.check("fan-release", fg.stage === "idle" && hold() === undefined && svc.cpu.profile === "balanced" && stuckNotices().length === 1, j([fg.stage, svc.cpu.profile, stuckNotices().length]));
        });

        // ---- a resume: ONE kick ----------------------------------------------------------------------------------------------------------
        root.step("fan: a suspend and a resume", function () {
            root.temp(55);
            n0 = root.applies().length;
            k0 = svc.profileKicks;
            Sleep.watcher.feed(sleepLine(true));
            Sleep.watcher.feed(sleepLine(false));
        }, function () { return svc.profileKicks === k0 + 1 && root.applies().length === n0 + 2; }, 15000);
        root.pause(4500);
        root.step("fan-resume-kick: once, as the same two writes, and the firmware-reset check had nothing to put back", function () {
            const a = root.applies();
            root.check("fan-resume-one-kick", svc.profileKicks === k0 + 1 && a.length === n0 + 2 && a[n0].text === root.base("apply profile=quiet") && a[n0 + 1].text === root.base("apply profile=balanced"), j([svc.profileKicks - k0, a.length - n0]));
            root.check("fan-resume-not-external", svc.profileTarget === 1 && svc.cpu.profile === "balanced", j([svc.profileTarget, svc.cpu.profile]));
        });

        // ---- a profile with no baseline: only the extreme case --------------------------------------------------------------------------
        root.step("fan: Quiet (a profile the baseline knows nothing about)", function () { svc.setProfile(0); }, function () { return svc.cpu.profile === "quiet" && fg.stage === "idle"; }, 10000);
        root.step("fan: 92 degrees at a light load, with nothing learned for Quiet", function () { k0 = svc.profileKicks; root.temp(92); }, function () { return fg.last !== null && fg.last.tempC === 92 && fg.last.peak <= 6; }, 12000);
        root.pause(12000);
        root.step("fan-nobaseline-quiet: 12 s at 92 is not enough without a baseline (the line is 95)", function () {
            root.check("fan-nobaseline-quiet", svc.profileKicks === k0 && stuckNotices().length === 1 && fg.last.expectedC === null && fg.last.suspicious === false, j([svc.profileKicks - k0, fg.last]));
        });
        root.step("fan: 96 degrees at a light load: the extreme case", function () { root.temp(96); }, function () { return svc.profileKicks === k0 + 1; }, 25000);
        root.step("fan-nobaseline-extreme: it kicked (Quiet via Balanced, and back)", null, function () { return root.applies().length >= 0 && root.calls("pkexec.log").filter(function (c) { return /\sapply profile=quiet$/.test(c.text); }).length >= 2; }, 8000);
        root.step("fan: the package falls at once", function () { root.temp(55); }, function () { return fg.stage === "idle"; }, 15000);

        // ---- the baseline is kept ---------------------------------------------------------------------------------------------------------------
        root.step("fan-baseline-file: written (the hand-seeded rows and what was learned)", function () {
            fg.flush();
        }, function () {
            const t = root.fileText(root.baselineFile);
            root.detail = t;
            try { return JSON.parse(t).profiles.balanced["1"].n > 500; } catch (e) { return false; }
        }, 5000);
        root.step("fan-baseline-parse: it reads back to the same rows", function () {
            let o = null;
            try { o = JSON.parse(root.fileText(root.baselineFile)); } catch (e) { o = null; }
            root.check("fan-baseline-parse", o !== null && o.version === 1 && o.profiles.balanced["10"].n >= 500 && o.profiles.balanced["1"].n > 500, root.fileText(root.baselineFile).slice(0, 200));
            root.check("fan-no-firmware-poll", root.calls("busctl.log").length === 0, j(root.calls("busctl.log").slice(0, 2)));
        });
    }

    // A feature the kernel does not have is hidden, never an error: the fixture copy has no rc6 file, no
    // coretemp, no charge-limit file, no max_perf_pct and no MUX file.
    function buildHidden() {
        root.step("hidden: the machine is read without those files", function () { svc.popupOpen = true; }, function () {
            root.detail = j([svc.helper.ok, svc.battery.present]);
            return svc.helper.ok && svc.battery.present && svc.cpu.present && svc.cores.length === 16;
        }, 20000);
        root.step("hidden: the old battery module's last-full file seeds the figure, once, and is not written", function () {
            root.check("hidden-last-full-seeded", svc.battery.lastFullMs === 1700000000000, String(svc.battery.lastFullMs));
        });
        root.step("hidden: the features are false and the figures are absent, not wrong", function () {
            const f = svc.helper.features;
            root.check("hidden-features", f.chargeLimit === false && f.maxPerfPct === false && f.mux === false && f.profile === true && f.epp === true, j(f));
            root.check("hidden-figures", svc.igpu.busy === null && svc.cpu.tempC === null && svc.cpu.maxPerfPct === null && svc.battery.limitAvailable === false && svc.battery.limitOn === false, j([svc.igpu, svc.cpu.tempC, svc.cpu.maxPerfPct, svc.battery.limitAvailable]));
            root.check("hidden-gpu", svc.gpu.mux.available === false && j(svc.gpu.steps) === "[0,1,2]" && svc.gpu.dState === "D3cold", j([svc.gpu.mux, svc.gpu.steps, svc.gpu.dState]));
            root.check("hidden-clock", svc.cpu.clockMHz === 925, String(svc.cpu.clockMHz));
        });
        root.step("hidden: what is hidden refuses, with words, and writes nothing", function () {
            root.check("hidden-limit-refused", svc.setChargeLimit(true) === false && svc.caption.batteryError.indexOf("not available") > 0, svc.caption.batteryError);
            root.check("hidden-mux-refused", svc.muxRequest("dgpu") === false, "");
            root.check("hidden-dgpu-step-refused", svc.setGpuMode(3, {}) === false, "");
            root.check("hidden-maxperf-refused", svc.setTuning({ maxPerfPct: 80 }) === false, "");
        });
        root.pause(1500);
        root.step("hidden: nothing was written", function () {
            root.check("hidden-no-write", root.writes().length === 0, j(root.writes()));
        });
    }

    // ---- the mock: the same members as the service, driven by a timeline --------------------------------------
    function buildMock() {
        const rec = { ac: [], battery: [], power: [], refused: [], blocked: [], osd: [], profiles: [] };
        let t0 = 0;
        mock.acChanged.connect(function (on) { rec.ac.push(on); });
        mock.batteryEvent.connect(function (k) { rec.battery.push(k); });
        mock.gpuPowerChanged.connect(function (d) { rec.power.push(d); });
        mock.writeRefused.connect(function (z, why) { rec.refused.push({ zone: z, why: why }); });
        mock.appBlocked.connect(function (a) { rec.blocked.push(a); });
        mock.osd.connect(function (r) { rec.osd.push(r); });
        mock.cpuChanged.connect(function () { if (rec.profiles.length === 0 || rec.profiles[rec.profiles.length - 1] !== mock.cpu.profile) rec.profiles.push(mock.cpu.profile); });

        root.step("mock: it has every member the service has", function () {
            const miss = [];
            Model.MEMBERS.props.forEach(function (n) { if (mock[n] === undefined || svc[n] === undefined) miss.push(n); });
            Model.MEMBERS.signals.forEach(function (n) { if (typeof mock[n].connect !== "function" || typeof svc[n].connect !== "function") miss.push(n); });
            Model.MEMBERS.intents.forEach(function (n) { if (typeof mock[n] !== "function" || typeof svc[n] !== "function") miss.push(n); });
            root.check("mock-members", miss.length === 0, j(miss));
            const keys = function (o) { return j(Object.keys(o)); };
            root.check("mock-fact-shapes", keys(mock.cpu) === keys(svc.cpu) && keys(mock.gpu) === keys(svc.gpu) && keys(mock.gpu.mux) === keys(svc.gpu.mux) && keys(mock.battery) === keys(svc.battery)
                       && keys(mock.helper) === keys(svc.helper) && keys(mock.caption) === keys(svc.caption) && keys(mock.igpu) === keys(svc.igpu)
                       && keys(mock.bootProfile) === keys(svc.bootProfile), "");
            root.check("mock-has-no-colours", !/#[0-9a-fA-F]{3,8}\b/.test(j([mock.cpu, mock.gpu, mock.battery, mock.caption])), "");
        });
        root.step("mock: at rest it is a laptop on its desk", function () {
            root.check("mock-desk", mock.cpu.profile === "balanced" && mock.cpu.present && mock.cores.length === 16 && mock.gpu.step === 2 && mock.gpu.dState === "D3cold" && mock.battery.pct === 100 && mock.battery.ac === true
                       && mock.profileTarget === 1 && mock.gpuModeTarget === 2 && mock.chargeLimitTarget === 100 && mock.helper.ok === true, j([mock.cpu.profile, mock.gpu.step, mock.battery.pct]));
        });
        // the timeline: events fire on a forward step, never on a scrub
        root.step("mock: the unplug scenario, scrubbed to 4 s: no event for the jump", function () {
            mock.scenario = "unplug";
            mock.timeMs = 4000;
        }, function () { return mock.battery.ac === true && rec.ac.length === 0 && rec.battery.length === 0; });
        root.step("mock: ... and played across 5 s: the charger comes out (acChanged), once", function () {
            mock.speed = 4;
            mock.playing = true;
        }, function () { return rec.ac.length === 1 && mock.battery.status === "Discharging"; }, 6000);
        root.step("mock-timeline-ac: acChanged(false) once, the battery drains", function () {
            root.check("mock-timeline-ac", j(rec.ac) === "[false]" && mock.battery.ac === false && mock.battery.wattsReal < 0 && mock.battery.minutesLeft > 0, j([rec.ac, mock.battery.wattsReal]));
            mock.playing = false;
            mock.timeMs = 43000;
            rec.battery.length = 0;
        });
        root.step("mock: played across the 15 % mark: low, once", function () {
            mock.playing = true;
        }, function () { return rec.battery.length >= 1; }, 8000);
        root.step("mock-timeline-low: the event is the service's", function () {
            mock.playing = false;
            root.check("mock-timeline-low", j(rec.battery) === '["low"]', j(rec.battery));
            // a scrub BACK does not replay anything
            mock.timeMs = 1000;
        }, function () { return mock.battery.ac === true; });
        root.step("mock-scrub-silent: scrubbing back fired nothing", function () {
            root.check("mock-scrub-silent", j(rec.ac) === "[false]" && j(rec.battery) === '["low"]', j([rec.ac, rec.battery]));
            mock.scenario = "charge";
            mock.timeMs = 53500;
            rec.battery.length = 0;
            rec.ac.length = 0;
        });
        root.step("mock: the charge scenario fills the pack: chargeDone and full, once; the moment is remembered", function () { mock.playing = true; }, function () { return rec.battery.indexOf("full") >= 0; }, 8000);
        root.step("mock-timeline-full: full", function () {
            mock.playing = false;
            root.check("mock-timeline-full", j(rec.battery) === '["chargeDone","full"]' && mock.battery.lastFullMs > 0, j(rec.battery));
            mock.scenario = "game";
            mock.timeMs = 2000;
            rec.power.length = 0;
            rec.blocked.length = 0;
        });
        root.step("mock: the game scenario wakes the dGPU: the signal, its users, its own readings, the blocked app", function () {
            mock.speed = 2;
            mock.playing = true;
        }, function () { return rec.power.length === 1 && mock.gpu.holders.length >= 1 && mock.gpu.util !== null && rec.blocked.length === 1; }, 8000);
        root.step("mock-timeline-gpu: D0, holders, readings, one blocked app", function () {
            mock.playing = false;
            mock.timeMs = 6000;
            root.check("mock-timeline-gpu", j(rec.power) === '["D0"]' && mock.gpu.awake === true && rec.blocked[0].id === "steam_app_1295660" && rec.blocked[0].pid === 4301, j([rec.power, rec.blocked]));
        }, function () { return mock.gpu.holders.length === 2 && mock.gpu.util > 0 && mock.gpu.vramTotalMB === 8188; });
        // the intents: with a settle and a write
        root.step("mock: the user ignores an app: its row and the list say so, as the service's do", function () {
            mock.ignoreApp("kitty");
        }, function () { return mock.gpu.ignoredApps.length === 1; });
        root.step("mock-ignored-facts: one row flagged, the list has the id, the others are false", function () {
            root.check("mock-ignored-facts", j(mock.gpu.ignoredApps) === '["kitty"]' && mock.gpu.policies.length > 0
                       && mock.gpu.policies.filter(function (p) { return p.ignored; }).map(function (p) { return p.id; }).join() === "kitty"
                       && mock.gpu.policies.every(function (p) { return typeof p.ignored === "boolean"; }), j(mock.gpu.policies.map(function (p) { return p.id + ":" + p.ignored; })));
        });
        root.step("mock: with users on the card, Smart asks first", function () {
            rec.refused.length = 0;
            root.check("mock-gpu-holders-refused", mock.setGpuMode(1, {}) === false && rec.refused.length === 1 && rec.refused[0].zone === "gpu" && rec.refused[0].why.indexOf("steam") >= 0, j(rec.refused));
            root.check("mock-gpu-confirmed", mock.setGpuMode(1, { confirmHolders: true }) === true && mock.gpuModeTarget === 1 && mock.gpu.step === 2);
        }, function () { return mock.gpu.step === 1 && mock.gpu.mode === 3; }, 3000);
        root.step("mock: back to the desk, a profile step: aimed at once, written after a settle and a write", function () {
            mock.scenario = "desk";
            mock.timeMs = 1000;
            mock.setGpuMode(2, {});
            t0 = Date.now();
            root.check("mock-profile-step", mock.stepProfile(1) === true && mock.profileTarget === 2 && mock.cpu.profile === "balanced");
        }, function () { return mock.cpu.profile === "performance" && mock.gpu.step === 2; }, 3000);
        root.step("mock-profile: the facts followed after settle + write", function () {
            const dt = Date.now() - t0;
            root.check("mock-profile-timing", dt >= 150 && dt < 1500, String(dt) + " ms (settle 100 + write 60)");
            root.check("mock-profile-facts", mock.cpu.epp === "performance" && mock.cpu.tweaked === false && mock.caption.cpu === "Performance" && mock.profileTarget === 2, j([mock.cpu.epp, mock.caption.cpu]));
            rec.profiles.length = 0;
            rec.profiles.push(mock.cpu.profile);
            // a burst of two steps down is one write
            mock.stepProfile(-1);
            mock.stepProfile(-1);
        }, function () { return mock.cpu.profile === "quiet"; }, 3000);
        root.pause(500);
        root.step("mock-burst: balanced was never written", function () {
            root.check("mock-burst", j(rec.profiles) === '["performance","quiet"]', j(rec.profiles));
        });
        root.step("mock: a refused write animates back and says why", function () {
            rec.refused.length = 0;
            mock.refuseNext = "cpu";
            root.check("mock-refuse-aim", mock.stepProfile(1) === true && mock.profileTarget === 1);
        }, function () { return rec.refused.length === 1; }, 3000);
        root.step("mock-refused: the target is back, the caption has the reason, the arm is spent", function () {
            root.check("mock-refused", rec.refused[0].zone === "cpu" && mock.profileTarget === 0 && mock.cpu.profile === "quiet" && mock.caption.cpuError === rec.refused[0].why && mock.refuseNext === "", j([rec.refused, mock.profileTarget]));
        });
        root.step("mock: tuning, merged, then reset; a local refusal for a cap above the ceiling", function () {
            root.check("mock-tuning-local-refusal", mock.setTuning({ pl1W: 60 }) === false && mock.caption.cpuError === "Above the firmware's 45 W", mock.caption.cpuError);
            root.check("mock-tuning", mock.setTuning({ epp: "balance_performance" }) === true && mock.setTuning({ pl1W: 30, pl2W: 90 }) === true && j(mock.tuningTarget) === '{"epp":"balance_performance","pl1W":30,"pl2W":90}', j(mock.tuningTarget));
        }, function () { return mock.cpu.pl1W === 30; }, 3000);
        root.step("mock-tuning: a tweak, then reset", function () {
            root.check("mock-tuning-state", mock.cpu.tweaked === true && mock.cpu.epp === "balance_performance" && mock.caption.cpu === "Quiet · tweaked", j([mock.cpu.tweaked, mock.caption.cpu]));
            mock.resetTuning();
        }, function () { return mock.cpu.tweaked === false && mock.cpu.pl1W === 45 && mock.cpu.epp === "power"; }, 3000);
        root.step("mock: the charge limit", function () {
            root.check("mock-limit-aim", mock.setChargeLimit(true) === true && mock.chargeLimitTarget === 80);
        }, function () { return mock.battery.limitOn === true; }, 3000);
        root.step("mock: the MUX: request, restart now (the new wiring awaits a keep), keep", function () {
            root.check("mock-mux-aim", mock.muxRequest("dgpu") === true && mock.gpuModeTarget === 3);
        }, function () { return mock.gpu.mux.state === "queued"; }, 3000);
        root.step("mock-mux: queued is pending; restart now puts the wiring in; keep keeps it", function () {
            root.check("mock-mux-queued", mock.gpu.mux.pending === true && mock.gpuModeTarget === 3 && mock.gpuMode === 2, j(mock.gpu.mux));
            root.check("mock-mux-windows", mock.gpu.mux.bootWindowS === 300 && mock.gpu.mux.promptWindowS === 120, j([mock.gpu.mux.bootWindowS, mock.gpu.mux.promptWindowS]));
            root.check("mock-mux-reboot", mock.muxRebootNow() === true);
        }, function () { return mock.gpu.mux.state === "awaiting-keep" && mock.gpu.step === 3; }, 3000);
        root.step("mock-mux-keep: kept", function () {
            root.check("mock-mux-keep-call", mock.muxKeep() === true);
        }, function () { return mock.gpu.mux.state === "kept"; }, 3000);
        // silicon-mux.service not running: what the helper would say, in both directions
        root.step("mock: silicon-mux.service is not running (the wiring is dGPU only after the keep): the way back is asked for", function () {
            mock.muxUnitActive = false;
            rec.refused.length = 0;
            root.check("mock-mux-unit-precheck", mock.gpu.mux.prechecks.ok === false && mock.gpu.mux.prechecks.why.indexOf("silicon-mux.service is not active") === 0, j(mock.gpu.mux.prechecks));
            root.check("mock-mux-unit-aim", mock.stepGpuMode(-1) === true && mock.gpuModeTarget === 2);
        }, function () { return rec.refused.length === 1; }, 3000);
        root.step("mock-mux-unit-refused: refused with the helper's words, the scene is back on dGPU only, nothing queued", function () {
            root.check("mock-mux-unit-refused", rec.refused[0].zone === "mux" && rec.refused[0].why === mock.gpu.mux.prechecks.why && mock.caption.gpuError === rec.refused[0].why
                       && mock.gpuModeTarget === 3 && mock.gpu.mux.pending === false && mock.gpu.mux.state === "kept", j([rec.refused, mock.gpuModeTarget, mock.gpu.mux.state]));
            mock.muxUnitActive = true;
        });
        root.step("mock: the unit is back: the way back queues, and is cancelled (a cancel needs no unit either)", function () {
            root.check("mock-mux-unit-back-precheck", mock.gpu.mux.prechecks.ok === true, j(mock.gpu.mux.prechecks));
            mock.stepGpuMode(-1);
        }, function () { return mock.gpu.mux.state === "queued" && mock.gpu.mux.want === "hybrid"; }, 3000);
        root.step("mock: ... cancelled with the unit down again", function () {
            mock.muxUnitActive = false;
            mock.muxCancel();
        }, function () { return mock.gpu.mux.state === "cancelled"; }, 3000);
        root.step("mock-mux-unit-restored: the unit is up again and the machine is as it was (dGPU only, nothing queued)", function () {
            mock.muxUnitActive = true;
            root.check("mock-mux-unit-restored", mock.gpu.mux.prechecks.ok === true && mock.gpu.mux.pending === false && mock.gpu.step === 3, j(mock.gpu.mux));
        });
        // (R5 X1) the way back walked FASTER THAN THE HELPER ANSWERS, on the mock: its asks are answered one at a time, in order, writeMs apart
        // (the service's write lane), so Hybrid at 0 ms, Smart at 200 and Integrated at ~700 -- after the first answer, before the second's --
        // is the walk the user made. The wish at the end is the LAST step asked for, and the restart lands the laptop there.
        root.step("mock: the way back walked faster than the helper answers (500 ms an ask): Hybrid ...", function () {
            mock.writeMs = 500;
            root.check("mock-walk-hybrid", mock.gpu.step === 3 && mock.stepGpuMode(-1) === true && mock.gpuModeTarget === 2);
        });
        root.pause(200);
        root.step("mock: ... Smart, before the first answer", function () {
            root.check("mock-walk-smart", mock.gpu.mux.pending === false && mock.stepGpuMode(-1) === true && mock.gpuModeTarget === 1);
        }, function () { return mock.gpu.mux.state === "queued"; }, 3000);
        root.step("mock: ... Integrated, once the first answer is in and the second is still on its way", function () {
            root.check("mock-walk-integrated", mock._muxOp !== null && mock.gpu.mux.afterMode === 1 && mock.stepGpuMode(-1) === true && mock.gpu.mux.afterMode === 0 && mock.gpuModeTarget === 0,
                       j([mock._muxOp, mock.gpu.mux.afterMode, mock.gpuModeTarget]));
        }, function () { return mock._muxOp === null; }, 3000);
        root.pause(300);
        root.step("mock-after-last-ask-wins: every answer is in: the wish is INTEGRATED, the target and the caption with it", function () {
            root.check("mock-after-last-ask-wins", mock._afterMuxMode === 0 && mock.gpu.mux.afterMode === 0 && mock.gpuModeTarget === 0 && mock.gpu.mux.state === "queued" && mock.caption.gpu.indexOf("Integrated after the next restart") >= 0,
                       j([mock._afterMuxMode, mock.gpu.mux.afterMode, mock.gpuModeTarget, mock.caption.gpu]));
            mock.writeMs = 60;
            mock.muxRebootNow();
        }, function () { return mock.gpu.step === 0 && mock.gpu.mode === 0 && mock.gpu.mux.state === "kept"; }, 3000);
        root.step("mock-walk-landed: the restart lands the laptop in Integrated -- set once, forgotten", function () {
            root.check("mock-walk-landed", mock.gpu.wiring === "hybrid" && mock.gpu.mux.afterMode === null && mock._afterMuxMode === null && mock.gpuModeTarget === 0, j([mock.gpu.wiring, mock.gpu.mux.afterMode, mock.gpuModeTarget]));
            mock.setGpuMode(2, {});
        }, function () { return mock.gpu.step === 2 && mock.gpu.mode === 1; }, 3000);
        root.step("mock: a hold from another module, then released", function () {
            PowerBus.hold("m", "performance", "t");
        }, function () { return mock.cpu.profile === "performance" && mock.cpu.heldBy === "m"; }, 3000);
        root.step("mock-hold: held, then put back", function () {
            root.check("mock-hold", mock.caption.cpu === "Performance · held by m", mock.caption.cpu);
            PowerBus.release("m");
        }, function () { return mock.cpu.profile === "quiet" && mock.cpu.heldBy === ""; }, 3000);
        root.step("mock: changes made outside the popup", function () {
            rec.osd.length = 0;
            mock.externalProfile("performance");
            mock.externalGpuMode(1);
            mock.externalLimit(false);
            root.check("mock-external-osd", rec.osd.map(function (r) { return r.title; }).join("|") === "Performance|Smart|Charge limit off" && rec.osd.every(function (r) { return r.kind === "power" && r.source === "silicon"; }), j(rec.osd.map(function (r) { return r.kind + ":" + r.title; })));
        }, function () { return mock.cpu.profile === "performance" && mock.gpu.mode === 3 && mock.battery.limitOn === false; }, 3000);
        root.step("mock: no helper, no cardwire: the zones grey and every intent says why", function () {
            mock.helperPresent = false;
            mock.cardwirePresent = false;
            rec.refused.length = 0;
            root.check("mock-greyed", mock.cpu.present === false && mock.helper.ok === false && mock.gpu.present === false, j([mock.cpu.present, mock.gpu.present]));
        }, function () { return mock.helper.ok === false && mock.gpu.present === false; });
        root.step("mock-greyed-intents: refused with words", function () {
            root.check("mock-greyed-intents", mock.stepProfile(1) === false && mock.stepGpuMode(1) === false && mock.setChargeLimit(true) === false && rec.refused.length === 3 && rec.refused.every(function (r) { return r.why.length > 8; }), j(rec.refused));
            mock.helperPresent = true;
            mock.cardwirePresent = true;
        });
        // the boot profile (Q16): the service's rule over a pretend boot set -- stored one write later, never applied
        root.step("mock: silicon.jsonc names balanced: stored as the boot set", function () {
            root.check("mock-boot-off", mock.bootProfile.state === "off" && mock.bootProfile.want === null && mock.bootProfile.why === "", j(mock.bootProfile));
            mock.config = Model.normalizeConfig({ defaultProfile: "balanced" }).config;
        }, function () { return mock.bootProfile.state === "stored"; }, 3000);
        root.step("mock-boot-stored: balanced's linked values are the boot set, and the profile in use did not move", function () {
            const a = mock._bootApply;
            root.check("mock-boot-stored", mock.bootProfile.want === "balanced" && a.profile === "balanced" && a.epp === "balance_power" && a.turbo === "1"
                       && mock.cpu.profile === "performance" && mock.profileTarget === 2, j([mock.bootProfile, a, mock.cpu.profile]));
            mock.refuseNext = "boot";
            mock.config = Model.normalizeConfig({ defaultProfile: "quiet" }).config;
        }, function () { return mock.bootProfile.state === "failed"; }, 3000);
        root.step("mock: a refused boot set ...", function () { mock.refresh(); });
        root.pause(300);
        root.step("mock-boot-refused: ... is its why, and is not asked again (the next ask would have been accepted)", function () {
            root.check("mock-boot-refused", mock.bootProfile.state === "failed" && mock.bootProfile.want === "quiet" && /refused/.test(mock.bootProfile.why)
                       && mock._bootApply.profile === "balanced" && mock.refuseNext === "" && mock.cpu.profile === "performance", j([mock.bootProfile, mock._bootApply.profile]));
            mock.config = Model.defaultConfig();
        }, function () { return mock.bootProfile.state === "off"; }, 3000);
        root.step("mock: idle ladder and touch", function () {
            mock.popupOpen = true;
            root.check("mock-ladder-open", mock.idleState === "alive", mock.idleState);
            mock.popupOpen = false;
            root.check("mock-ladder-closed", mock.idleState === "halt", mock.idleState);
        });
        root.pause(500);
        root.step("mock: it touched nothing (no helper, no pkexec, no notification: the runner checks the logs)", function () {
            root.check("mock-no-pkexec", root.logLines("pkexec.log").length === 0 && root.logLines("notify-send.log").length === 0, "");
        });
    }

    function buildNoHelper() {
        root.step("nh: the helper is found missing, and nothing else is", null, function () {
            root.detail = j([svc.helper, svc.gpu.present, svc.gpu.why, svc.battery.present]);
            return !svc.helper.ok && !svc.helper.installed && svc.battery.present && !svc.gpu.present;
        }, 12000);
        root.step("nh: the CPU zone is absent and says why", function () {
            root.check("nh: cpu absent", svc.cpu.present === false && svc.cpu.profiles.length === 0 && svc.cpu.capCeilW.pl1 === null, j(svc.cpu));
            root.check("nh: caption names the helper", svc.caption.cpu === "Profile unknown · silicon-helper is not installed", svc.caption.cpu);
        });
        root.step("nh: the GPU zone is absent and says why", function () {
            root.check("nh: gpu absent", svc.gpu.present === false && svc.gpu.steps.length === 0, j(svc.gpu.steps));
            root.check("nh: caption names cardwire", svc.caption.gpu.indexOf("Mode unknown · ") === 0, svc.caption.gpu);
        });
        root.step("nh: the battery strip reads with no helper (default paths)", function () {
            root.check("nh: battery", svc.battery.pct === 100 && svc.battery.status === "Full" && svc.battery.cycles === 197, j(svc.battery));
        });
        root.step("nh: intents refuse and say why", function () {
            let refused = [];
            svc.writeRefused.connect(function (zone, why) { refused.push(zone + ": " + why); });
            root.check("nh: stepProfile refused", svc.stepProfile(1) === false);
            root.check("nh: setTuning refused", svc.setTuning({ epp: "power" }) === false);
            root.check("nh: setChargeLimit refused", svc.setChargeLimit(true) === false);
            root.check("nh: setGpuMode refused", svc.setGpuMode(1, {}) === false);
            root.check("nh: muxRequest refused", svc.muxRequest("dgpu") === false);
            root.check("nh: muxRebootNow refused (nothing is waiting)", svc.muxRebootNow() === false);
            root.check("nh: six refusals, each with words", refused.length === 6 && refused.every(function (r) { return r.length > 8; }), j(refused));
        });
        root.pause(1500);
        root.step("nh: no write, no reboot, no sound", function () {
            root.check("nh: no pkexec call", root.logLines("pkexec.log").length === 0, j(root.logLines("pkexec.log")));
            root.check("nh: no systemctl call", root.logLines("systemctl.log").length === 0);
        });
    }

    // ---- the fake machine ------------------------------------------------------------------------
    readonly property string bat: root.tree + "/sys/class/power_supply/BAT0"
    readonly property string acOnline: root.tree + "/sys/class/power_supply/AC0/online"
    readonly property string profileFile: root.tree + "/sys/firmware/acpi/platform_profile"
    readonly property string profileClassFile: root.tree + "/sys/class/platform-profile/platform-profile-0/profile"
    readonly property string limitFile: root.bat + "/charge_control_end_threshold"
    readonly property string rc6File: root.tree + "/sys/class/drm/card1/gt/gt0/rc6_residency_ms"
    readonly property string statFile: root.tree + "/proc/stat"
    readonly property string memFile: root.tree + "/proc/meminfo"
    readonly property string polDir: root.tree + "/sys/devices/system/cpu/cpufreq"
    readonly property string helperBase: root.helperBin + " " + root.helperFlags.join(" ")
    readonly property bool standIn: Quickshell.env("SSP_STANDIN") === "1"
    property real t0: Date.now()
    property var nodes: []

    function uevent(o) {
        return "DEVTYPE=power_supply\nPOWER_SUPPLY_NAME=BAT0\nPOWER_SUPPLY_TYPE=Battery\nPOWER_SUPPLY_STATUS=" + o.status
            + "\nPOWER_SUPPLY_PRESENT=1\nPOWER_SUPPLY_TECHNOLOGY=Unknown\nPOWER_SUPPLY_CYCLE_COUNT=197\nPOWER_SUPPLY_VOLTAGE_MIN_DESIGN=15944000\n"
            + "POWER_SUPPLY_VOLTAGE_NOW=16854000\nPOWER_SUPPLY_POWER_NOW=" + o.powerUW + "\nPOWER_SUPPLY_ENERGY_FULL_DESIGN=75000000\n"
            + "POWER_SUPPLY_ENERGY_FULL=59455000\nPOWER_SUPPLY_ENERGY_NOW=" + o.energyUWh + "\nPOWER_SUPPLY_CAPACITY=" + o.pct
            + "\nPOWER_SUPPLY_CAPACITY_LEVEL=Normal\nPOWER_SUPPLY_MODEL_NAME=S560647\nPOWER_SUPPLY_MANUFACTURER=OEM\n";
    }

    // /proc/stat: the fixture's counters plus `busy` / `idle` extra jiffies per CPU (the total line is their sum).
    function statText(busy, idle) {
        const tot = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        const per = [];
        for (let i = 0; i < 22; i++) {
            const f = [1000 + 10 * i + (busy ? busy[i] : 0), 0, 500 + 5 * i, 100000 + 100 * i + (idle ? idle[i] : 0), 200, 0, 50, 0, 0, 0];
            per.push(f);
            for (let k = 0; k < 10; k++)
                tot[k] += f[k];
        }
        const lines = ["cpu  " + tot.join(" ")];
        for (let i = 0; i < 22; i++)
            lines.push("cpu" + i + " " + per[i].join(" "));
        return lines.concat(["intr 1000 0 0", "ctxt 5000", "btime 1790000000", "processes 4000", "procs_running 1", "procs_blocked 0"]).join("\n") + "\n";
    }

    // The platform profile is ONE state the kernel shows twice (the legacy file is a proxy of the class
    // device's): a change made outside is made in both, whichever one a helper reads.
    function putProfile(name) {
        root.put(root.profileFile, name + "\n");
        root.put(root.profileClassFile, name + "\n");
    }
    // The card changes state: sysfs and cardwire's signal agree, as they do on the machine.
    function power(state) {
        root.put(root.tree + "/sys/bus/pci/devices/0000:01:00.0/power_state", state + "\n");
        root.ctl("EmitPowerState", state);
    }
    function near(a, b, tol) { return typeof a === "number" && Math.abs(a - b) <= tol; }
    // silicon-mux.service starts or stops: systemd keeps (or removes) the link of an active unit.
    function muxUnit(active) {
        root.sh(active ? "ln -sfn 0123456789abcdef0123456789abcdef '" + root.unitLink + "'" : "rm -f '" + root.unitLink + "'");
    }
    // The panel is wired to the NVIDIA card (and the firmware says dGPU only) or to the Intel card.
    function wiring(which) {
        root.put(root.tree + "/sys/devices/platform/asus-nb-wmi/gpu_mux_mode", which === "dgpu" ? "0\n" : "1\n");
        root.put(root.tree + "/sys/class/drm/card0-eDP-2/status", which === "dgpu" ? "connected\n" : "disconnected\n");
        root.put(root.tree + "/sys/class/drm/card1-eDP-1/status", which === "dgpu" ? "disconnected\n" : "connected\n");
    }
    function base(arg) { return root.helperBase + " " + arg; }
    // The apply a profile's linked values make (CONTRACT section 4's seeds, the fixture's limits).
    readonly property var linked: ({
        quiet: "apply profile=quiet governor=powersave epp=power turbo=0 max_perf_pct=100 pl1_w=firmware pl2_w=firmware",
        balanced: "apply profile=balanced governor=powersave epp=balance_power turbo=1 max_perf_pct=100 pl1_w=firmware pl2_w=firmware",
        performance: "apply profile=performance governor=powersave epp=performance turbo=1 max_perf_pct=100 pl1_w=firmware pl2_w=firmware"
    })

    // ---- what the service said ---------------------------------------------------------------------
    property var evBattery: []
    // The shell's one battery reader, fed by the service under test (what the notifier and the lock are handed).
    SiliconBatteryAdapter {
        id: batteryAdapter
        silicon: svc
    }
    property var evAc: []
    property var evPower: []
    property var evRefused: []
    property var evBlocked: []
    property var evOsd: []
    property var limitTrail: []           // the switch's target as it changed, after the facts were rebuilt
    function sampleLimit() {
        const t = svc.chargeLimitTarget;
        if (root.limitTrail.length === 0 || root.limitTrail[root.limitTrail.length - 1] !== t)
            root.limitTrail = root.limitTrail.concat([t]);
    }
    property var holdTrail: []            // [{ at, key: "none" | "asleep" | "awake" }]: holders and the card's state
    property string _holdKey: "none"
    property bool keepAlive: true
    // R8 C1: what the readers did in the quiet window -- every beat, every reading a reader took, every status run, each with its time
    readonly property var beatRec: ({ on: false, beats: [], polls: [], status: [] })
    Connections {
        target: svc.readingBeat
        function onBeat(serial) {
            if (root.beatRec.on)
                root.beatRec.beats.push({ serial: serial, t: Date.now() });
        }
    }
    Connections {
        target: svc
        function onPolled(kind) {
            if (root.beatRec.on)
                root.beatRec.polls.push({ kind: kind, serial: svc.readingBeat.serial, t: Date.now() });
        }
        function onStatusRunsChanged() {
            if (root.beatRec.on)
                root.beatRec.status.push({ serial: svc.readingBeat.serial, t: Date.now() });
        }
    }
    Connections {
        target: svc
        function onBatteryEvent(kind) { root.evBattery = root.evBattery.concat([kind]); }
        function onChargeLimitTargetChanged() { Qt.callLater(root.sampleLimit); }
        function onAcChanged(on) { root.evAc = root.evAc.concat([on]); }
        function onGpuPowerChanged(d) { root.evPower = root.evPower.concat([d]); }
        function onWriteRefused(zone, why) { root.evRefused = root.evRefused.concat([{ zone: zone, why: why }]); }
        function onAppBlocked(app) { root.evBlocked = root.evBlocked.concat([app]); }
        function onOsd(request) { root.evOsd = root.evOsd.concat([request]); }
        function onGpuChanged() {
            const key = svc.gpu.holders.length === 0 ? "none" : (svc.gpu.awake ? "awake" : "asleep");
            if (key !== root._holdKey) {
                root._holdKey = key;
                root.holdTrail = root.holdTrail.concat([{ at: Date.now(), key: key }]);
            }
        }
    }
    QtObject {
        id: fakeOsd
        property var shown: []
        function show(req) {
            fakeOsd.shown = fakeOsd.shown.concat([req]);
            return true;
        }
    }
    function keyAt(t) {
        let k = "none";
        for (let i = 0; i < root.holdTrail.length; i++) {
            if (root.holdTrail[i].at <= t)
                k = root.holdTrail[i].key;
        }
        return k;
    }
    // Keep the popup alive (the ladder is tested on its own).
    Timer {
        interval: 1000
        repeat: true
        running: root.phase === "main"
        onTriggered: {
            if (root.keepAlive)
                svc.touch();
        }
    }

    // ======================================================================================
    // the scenario
    // ======================================================================================
    function buildMain() {
        root.secStart();
        root.secStats();
        root.secBattery();
        root.secUpower();
        root.secDisplay();
        root.secPower();
        root.secProfile();
        root.secRefusals();
        root.secExternal();
        root.secLimit();
        root.secGpu();
        root.secConfig();
        root.secOnPower();
        root.secHolds();
        root.secResume();
        root.secMux();
        root.secEnd();
    }

    // ---- 1. the machine at start ---------------------------------------------------------------------
    function secStart() {
        root.step("start: the popup opens and the machine is read", function () { svc.popupOpen = true; }, function () {
            root.detail = j([svc.helper.ok, svc.cpu.present, svc.gpu.present, svc.battery.present]);
            return svc.helper.ok && svc.cpu.present && svc.gpu.present && svc.battery.present;
        }, 20000);
        root.step("start: UPower's charge history was asked ONCE, by the one read-only call, and its last full is the since-full moment (the service has none of its own yet)", null, function () {
            const c = root.upCalls("BAT0");
            root.detail = j([c.length, svc.battery.lastFullMs, svc.battery.lastFullSource, svc.battery.upowerWhy]);
            return c.length >= 1 && svc.battery.lastFullMs !== 0;
        }, 8000);
        root.step("start-upower: the call, the moment, whose it is, and what the board says (the fake pack is full: 0.0h)", function () {
            const c = root.upCalls("BAT0");
            root.check("start-upower-once", c.length === 1 && c[0].text === "call --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower/devices/battery_BAT0 --method org.freedesktop.UPower.Device.GetHistory charge 604800 5000",
                       j(c.map(function (x) { return x.text; })));
            root.check("start-upower-moment", svc.battery.lastFullMs === root.weekMs && svc.battery.lastFullSource === "upower" && svc.battery.upowerWhy === "", j([svc.battery.lastFullMs, svc.battery.lastFullSource, svc.battery.upowerWhy]));
            root.check("start-at-target", svc.battery.atTarget === true && Model.buildFigures(svc.battery, svc.memory, Date.now()).sinceFull === "0.0h", j([svc.battery.atTarget, Model.buildFigures(svc.battery, svc.memory, Date.now()).sinceFull]));
        });
        root.step("start: one signal monitor and no more (cardwire is watched by ONE gdbus)", null, function () {
            const mon = root.calls("gdbus.log").filter(function (c) { return c.text.indexOf("monitor ") === 0; });
            return mon.length === 1 && mon[0].text === "monitor --session --dest org.opengamingcollective.cardwire";
        }, 6000);
        root.step("start: the dGPU's own nodes, asked of the helper", function () {
            root.ops++;
            stim.run(root.statusCmd.concat(["status"]), function (res) {
                root.ops--;
                try {
                    const d = JSON.parse(res.out).status.paths.dgpu;
                    root.nodes = [d.card, d.render, d.nvidia].filter(function (x) { return typeof x === "string"; });
                } catch (e) {
                    root.check("start: the helper's status parses", false, String(e));
                }
            });
        }, function () { return root.nodes.length === 3; });
        root.step("start: the CPU facts", function () {
            const c = svc.cpu;
            root.check("facts-cpu-profile", c.profile === "balanced" && j(c.profiles) === '["quiet","balanced","performance"]' && svc.profileIndex === 1 && svc.profileTarget === 1, j([c.profile, c.profiles]));
            root.check("facts-cpu-knobs", c.epp === "balance_power" && c.turbo === true && c.governor === "powersave" && c.maxPerfPct === 100 && c.pl1W === 45 && c.pl2W === 115,
                       j([c.epp, c.turbo, c.governor, c.maxPerfPct, c.pl1W, c.pl2W]));
            root.check("facts-cpu-lists", j(c.eppChoices) === '["power","balance_power","balance_performance","performance"]' && j(c.governors) === '["performance","powersave"]', j([c.eppChoices, c.governors]));
            root.check("facts-cpu-limits", c.capFloorW === 8 && j(c.capCeilW) === '{"pl1":45,"pl2":115}' && c.capsWritable === true && j(c.maxPerfRange) === '{"min":50,"max":100}', j([c.capFloorW, c.capCeilW, c.maxPerfRange]));
            root.check("facts-cpu-not-tweaked", c.tweaked === false && c.heldBy === "", j([c.tweaked, c.heldBy]));
            root.check("facts-caption-cpu", svc.caption.cpu === "Balanced" && svc.caption.cpuError === "", j(svc.caption));
            root.check("facts-helper", svc.helper.ok && svc.helper.installed && svc.helper.features.mux && svc.helper.features.caps && svc.helper.why === "", j(svc.helper));
        });
        root.step("start: the GPU facts (cardwire)", function () {
            const g = svc.gpu;
            root.check("facts-gpu-mode", g.mode === 1 && j(g.modes) === "[0,1,3]" && g.step === 2 && svc.gpuMode === 2 && svc.gpuModeTarget === 2 && j(g.steps) === "[0,1,2,3]" && g.wiring === "hybrid",
                       j([g.mode, g.modes, g.step, g.steps, g.wiring]));
            root.check("facts-gpu-asleep", g.dState === "D3cold" && g.awake === false && g.holders.length === 0 && g.util === null && g.watts === null, j([g.dState, g.awake, g.holders, g.util]));
            root.check("facts-gpu-config", j(g.config) === '{"batteryAutoSwitch":false,"batteryAutoSwitchMode":1,"externalDisplayAutoSwitch":false,"nvidiaBlock":false}', j(g.config));
            const steam = g.policies.filter(function (p) { return p.id === "steam_app_1295660"; })[0];
            root.check("facts-gpu-policies", g.policies.length === 9 && steam && steam.policy === 1 && steam.name === "Sid Meier's Civilization VII"
                       && g.policies.every(function (p, i, a) { return i === 0 || a[i - 1].name.toLowerCase() <= p.name.toLowerCase(); }), j(g.policies.map(function (p) { return p.id + ":" + p.policy; })));
            root.check("facts-gpu-blocked", g.blockedApps.indexOf("quickshell") >= 0 && g.blockedApps.indexOf("kitty") >= 0 && g.blockedApps.length === 21, j(g.blockedApps.length));
            root.check("facts-gpu-mux", g.mux.state === "" && g.mux.pending === false && g.mux.available === true && g.mux.prechecks.ok === true && g.mux.outcomeSeen === true, j(g.mux));
            root.check("facts-caption-gpu", svc.caption.gpu === "Hybrid · dGPU asleep" && svc.caption.gpuError === "", svc.caption.gpu);
        });
        root.step("start: the battery facts", function () {
            const b = svc.battery;
            root.check("facts-battery", b.pct === 100 && b.status === "Full" && b.ac === true && b.cycles === 197 && b.limitOn === false && b.limitPct === 100 && b.limitAvailable === true
                       && b.conditionPct === 79.3 && b.minutesLeft === null && b.minutesToFull === null && b.wattsReal === 0, j(b));
            root.check("facts-caption-battery", svc.caption.battery === "Full", svc.caption.battery);
            root.check("facts-config", svc.config.look.family === "material" && svc.configWarnings.length === 0 && svc.configError === "", j([svc.config.look, svc.configWarnings, svc.configError]));
            root.check("facts-idle", svc.idleState === "alive", svc.idleState);
        });
    }

    // ---- 2. the stats --------------------------------------------------------------------------------------
    function secStats() {
        root.step("stats: the clock and the package temperature (fixture: 925 MHz, 54 C)", null, function () {
            root.detail = j([svc.cpu.clockMHz, svc.cpu.tempC, svc.cores.length]);
            return svc.cpu.clockMHz === 925 && svc.cpu.tempC === 54 && svc.cores.length === 16;
        }, 6000);
        root.step("stats: sixteen cores, in the scene's order", function () {
            const kinds = svc.cores.map(function (c) { return c.kind; }).join("");
            root.check("stats-core-kinds", kinds === "PPPPPPEEEEEEEELPELPE", kinds);
        });
        // /proc/meminfo, read at the stats cadence (R2 D5): the fixture is this laptop's own
        root.step("stats: the memory from /proc/meminfo (fixture: 24007296 kB, 7707952 available)", null, function () {
            root.detail = j(svc.memory);
            return svc.memory.totalKiB === 24007296 && svc.memory.availableKiB === 7707952
                   && root.near(svc.memory.usedFraction, (24007296 - 7707952) / 24007296, 1e-9);
        }, 6000);
        root.step("stats: the file moves (RAM nearly full)", function () {
            root.put(root.memFile, "MemTotal: 24007296 kB\nMemFree: 90000 kB\nMemAvailable: 1200000 kB\nSwapTotal: 26214396 kB\nSwapFree: 25165820 kB\n");
        }, function () {
            root.detail = j(svc.memory);
            return svc.memory.availableKiB === 1200000 && root.near(svc.memory.usedFraction, (24007296 - 1200000) / 24007296, 1e-9);
        }, 6000);
        root.step("stats: a file that is no reading (junk) changes nothing", function () { root.put(root.memFile, "garbage\n"); }, function () { return true; });
        root.pause(2300);
        root.step("stats-memory: ... the last reading stands, as a fact (never a zero)", function () {
            root.check("stats-memory", svc.memory.availableKiB === 1200000 && svc.memory.totalKiB === 24007296, j(svc.memory));
        });
        // every CPU 30 % busy, cpu0 90 %, cpu5 10 %: the P core of {0,5} is their mean, 50 %
        root.step("stats: load (per core and total) from /proc/stat", function () {
            const busy = [], idle = [];
            for (let i = 0; i < 22; i++) { busy.push(30); idle.push(70); }
            busy[0] = 90; idle[0] = 10; busy[5] = 10; idle[5] = 90;
            root.put(root.statFile, root.statText(busy, idle));
        }, function () {
            root.detail = j([svc.cores.length > 0 ? svc.cores[0].load : null, svc.cpu.loadPct]);
            return svc.cores.length === 16 && root.near(svc.cores[0].load, 0.5, 1e-9) && root.near(svc.cpu.loadPct, 31.8, 0.05);
        }, 6000);
        root.step("stats: the other cores", function () {
            root.check("stats-core-loads", root.near(svc.cores[1].load, 0.3, 1e-9) && root.near(svc.cores[6].load, 0.3, 1e-9) && root.near(svc.cores[14].load, 0.3, 1e-9) && root.near(svc.cores[15].load, 0.3, 1e-9),
                       j(svc.cores.map(function (c) { return Math.round(c.load * 100) / 100; })));
        });
        // the render engine slept 950 ms of the ~1000 since the last read: 5 % busy
        root.step("stats: the iGPU's busy share from rc6 (950 ms asleep per second: ~5 %)", function () {
            root.ops++;
            stim.run(["sh", "-c", "v=$(cat \"$1\"); printf '%s' $((v + 950)) > \"$1.tmp\" && mv \"$1.tmp\" \"$1\"", "sh", root.rc6File], function () { root.ops--; });
        }, function () {
            root.detail = j(svc.igpu);
            return svc.igpu.busy !== null && svc.igpu.busy >= 0 && svc.igpu.busy < 0.3;
        }, 6000);
    }

    // ---- 3. the battery ------------------------------------------------------------------------------------------
    function secBattery() {
        let u0 = 0, tLeave = 0;
        root.step("battery: unplugged and discharging 15 W (mains flag, status, watts)", function () {
            root.put(root.acOnline, "0\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Discharging", pct: 99, powerUW: 15000000, energyUWh: 58900000 }));
        }, function () {
            root.detail = j([svc.battery.status, svc.battery.ac, svc.battery.wattsReal, root.evAc]);
            return svc.battery.status === "Discharging" && svc.battery.ac === false && svc.battery.wattsReal === -15;
        }, 6000);
        root.step("battery-unplug: acChanged(false) once, no charge event", function () {
            root.check("battery-unplug", j(root.evAc) === "[false]" && root.evBattery.length === 0, j([root.evAc, root.evBattery]));
            // 58.9 Wh at a smoothed 15 W = 235.6 min (the average starts afresh with the regime)
            root.check("battery-time-left", root.near(svc.battery.minutesLeft, 58.9 * 60 / 15, 0.5), String(svc.battery.minutesLeft));
            root.check("battery-flow", svc.battery.minutesToFull === null && svc.battery.toLimit === false && root.near(svc.battery.wattsAvg, -15, 1e-9), j([svc.battery.minutesToFull, svc.battery.wattsAvg]));
            root.check("battery-normalised", svc.battery.overheadW >= 0 && svc.battery.wattsNormalised >= svc.battery.wattsReal && svc.battery.wattsNormalised <= 0
                       && root.near(svc.battery.wattsNormalised, svc.battery.wattsReal + svc.battery.overheadW, 1e-9), j([svc.battery.wattsReal, svc.battery.wattsNormalised, svc.battery.overheadW]));
            root.check("battery-caption-discharging", svc.caption.battery === "On battery · 3h 56m left", svc.caption.battery);
        });
        // low: crossing down through 15 %, once
        root.step("battery: 17 %", function () { root.put(root.bat + "/uevent", root.uevent({ status: "Discharging", pct: 17, powerUW: 15000000, energyUWh: 10000000 })); }, function () { return svc.battery.pct === 17; });
        root.step("battery: 15 % -> low", function () { root.put(root.bat + "/uevent", root.uevent({ status: "Discharging", pct: 15, powerUW: 15000000, energyUWh: 9000000 })); }, function () { return svc.battery.pct === 15; });
        root.step("battery: 14 %", function () { root.put(root.bat + "/uevent", root.uevent({ status: "Discharging", pct: 14, powerUW: 15000000, energyUWh: 8000000 })); }, function () { return svc.battery.pct === 14; });
        root.step("battery-low: the event fired once", function () {
            root.check("battery-low", j(root.evBattery) === '["low"]', j(root.evBattery));
        });
        root.step("battery: replugged and charging 30 W", function () {
            root.put(root.acOnline, "1\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 50, powerUW: 30000000, energyUWh: 30000000 }));
        }, function () { return svc.battery.status === "Charging" && svc.battery.ac === true; }, 6000);
        root.step("battery-replug: acChanged(true), chargeStart; time to full", function () {
            root.check("battery-replug", j(root.evAc) === "[false,true]" && j(root.evBattery) === '["low","chargeStart"]', j([root.evAc, root.evBattery]));
            // 59.455 Wh full, 30 Wh in, 30 W: 29.455 Wh = 58.91 min
            root.check("battery-time-to-full", root.near(svc.battery.minutesToFull, 58.91, 0.2) && svc.battery.toLimit === false && svc.battery.minutesLeft === null && svc.battery.wattsReal === 30,
                       j([svc.battery.minutesToFull, svc.battery.toLimit, svc.battery.wattsReal]));
            root.check("battery-normalised-charging", svc.battery.wattsNormalised >= 30 && root.near(svc.battery.wattsNormalised, 30 + svc.battery.overheadW, 1e-9), String(svc.battery.wattsNormalised));
            root.check("battery-caption-charging", svc.caption.battery === "Charging · 59m to full", svc.caption.battery);
        });
        root.step("battery: reaches 100 % with nothing flowing -> full", function () {
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 99, powerUW: 12000000, energyUWh: 59000000 }));
        }, function () { return svc.battery.pct === 99; });
        root.step("battery: 100 %, Full, 0 W", function () {
            u0 = root.upCalls("BAT0").length;
            root.put(root.bat + "/uevent", root.uevent({ status: "Full", pct: 100, powerUW: 0, energyUWh: 59455000 }));
        }, function () { return svc.battery.status === "Full" && svc.battery.pct === 100; });
        root.step("battery-full: chargeDone and full, once; the moment is remembered", function () {
            root.check("battery-full", j(root.evBattery) === '["low","chargeStart","chargeDone","full"]', j(root.evBattery));
            root.check("battery-last-full", svc.battery.lastFullMs >= root.t0 && svc.battery.lastFullMs <= Date.now(), String(svc.battery.lastFullMs));
        });
        // the limit's Full <-> Not charging flap does not replay it
        root.step("battery: Not charging at 100 %", function () { root.put(root.bat + "/uevent", root.uevent({ status: "Not charging", pct: 100, powerUW: 0, energyUWh: 59455000 })); }, function () { return svc.battery.status === "Not charging"; });
        root.step("battery: Full again", function () { root.put(root.bat + "/uevent", root.uevent({ status: "Full", pct: 100, powerUW: 0, energyUWh: 59455000 })); }, function () { return svc.battery.status === "Full"; });
        root.step("battery-no-replay: the flap fired nothing", function () {
            root.check("battery-no-replay", j(root.evBattery) === '["low","chargeStart","chargeDone","full"]', j(root.evBattery));
        });
        root.step("battery-full-upower: the full event asked UPower again, once, a moment later (the point is written by then)", null, function () {
            root.detail = String(root.upCalls("BAT0").length - u0);
            return root.upCalls("BAT0").length === u0 + 1;
        }, 6000);
        root.step("battery-full-upower: ... and the moment counted is the service's own now (it is later than UPower's old one)", function () {
            root.check("battery-full-own", svc.battery.lastFullSource === "own" && svc.battery.lastFullMs >= root.t0 && svc.battery.atTarget === true, j([svc.battery.lastFullSource, svc.battery.lastFullMs, svc.battery.atTarget]));
        });
        // the pack stops being full: that is the last moment it was
        root.step("battery: unplugged from a full pack (the kernel says Discharging, 100 %)", function () {
            tLeave = Date.now();
            root.put(root.acOnline, "0\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Discharging", pct: 100, powerUW: 12000000, energyUWh: 59455000 }));
        }, function () { return svc.battery.status === "Discharging" && svc.battery.ac === false; }, 6000);
        root.step("battery-leave: the last moment it was full is the moment it stopped (the since-full display counts from there, from 0.0h)", function () {
            root.check("battery-leave", svc.battery.atTarget === false && svc.battery.lastFullMs >= tLeave && svc.battery.lastFullMs <= Date.now() && svc.battery.lastFullSource === "own",
                       j([svc.battery.atTarget, svc.battery.lastFullMs - tLeave, svc.battery.lastFullSource]));
            root.check("battery-leave-display", Model.buildFigures(svc.battery, svc.memory, Date.now()).sinceFull === "0.0h", Model.buildFigures(svc.battery, svc.memory, Date.now()).sinceFull);
            root.check("battery-leave-time", Model.buildFigures(svc.battery, svc.memory, Date.now()).timeMode === "left" && /^[0-9]+:[0-9][0-9]$/.test(Model.buildFigures(svc.battery, svc.memory, Date.now()).time),
                       j(Model.buildFigures(svc.battery, svc.memory, Date.now())));
        });
        root.step("battery: plugged in again and full (the pack the rest of the run expects)", function () {
            root.put(root.acOnline, "1\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Full", pct: 100, powerUW: 0, energyUWh: 59455000 }));
        }, function () { return svc.battery.status === "Full" && svc.battery.ac === true && svc.battery.atTarget === true; }, 6000);
        // "Charging at zero rate" (acpi's words; 2026-11-04): the kernel says Charging, nothing reaches a drained pack, the percentage falls.
        // The status alone is not the fact: after the stall time the caption says so, a flow that returns clears it at once, and a
        // dip that does not last never raises it.
        root.step("battery-stall: a drained pack on the mains, 'Charging', 0 W (the stall time is 2.5 s here)", function () {
            svc.stallMs = 2500;
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 1, powerUW: 0, energyUWh: 900000 }));
        }, function () { return svc.battery.status === "Charging" && svc.battery.pct === 1; }, 6000);
        root.step("battery-stall: ... not yet a stall (the caption is still the kernel's word)", function () {
            root.check("battery-stall-not-yet", svc.battery.stalled === false && svc.caption.battery === "Charging", j([svc.battery.stalled, svc.caption.battery]));
        });
        root.step("battery-stall: ... 0 W for the stall time -> stalled, and the caption says nothing reaches the pack", null, function () {
            root.detail = j([svc.battery.stalled, svc.caption.battery]);
            return svc.battery.stalled === true && svc.caption.battery === "Plugged in · no charge is reaching the pack";
        }, 9000);
        root.step("battery-stall: ... the shell's one reader says it too (the adapter the notifier is handed)", function () {
            const ad = batteryAdapter;
            root.check("battery-stall-adapter", ad.chargeStalled === true && ad.isCharging === true, j([ad.chargeStalled, ad.isCharging]));
        });
        root.step("battery-stall: the flow returns (30 W): cleared at once, the caption is the kernel's word again", function () {
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 1, powerUW: 30000000, energyUWh: 900000 }));
        }, function () { return svc.battery.wattsReal === 30; }, 6000);
        root.step("battery-stall-clears: not stalled, and the adapter agrees", function () {
            const ad = batteryAdapter;
            root.check("battery-stall-clears", svc.battery.stalled === false && /^Charging/.test(svc.caption.battery) && ad.chargeStalled === false, j([svc.battery.stalled, svc.caption.battery]));
        });
        root.step("battery-stall: a dip to 0 W that comes back inside the stall time is no stall", function () {
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 2, powerUW: 0, energyUWh: 1000000 }));
        }, function () { return svc.battery.wattsReal === 0 && svc.battery.pct === 2; }, 6000);
        root.step("battery-stall: ... (flow back)", function () {
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 2, powerUW: 40000000, energyUWh: 1000000 }));
        }, function () { return svc.battery.wattsReal === 40; }, 6000);
        root.pause(3200);
        root.step("battery-stall-dip: ... and past the stall time it is still none", function () {
            root.check("battery-stall-dip", svc.battery.stalled === false, String(svc.battery.stalled));
        });
        root.step("battery: full again (the pack the rest of the run expects)", function () {
            svc.stallMs = null;
            root.put(root.acOnline, "1\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Full", pct: 100, powerUW: 0, energyUWh: 59455000 }));
        }, function () { return svc.battery.status === "Full" && svc.battery.ac === true && svc.battery.atTarget === true; }, 6000);
    }

    // ---- 3b. UPower's charge history on its own: the reader against the stand-in --------------------------------------------------------
    function secUpower() {
        let n0 = 0, a0 = 0, t0 = 0, n1 = 0;
        const READ7 = "call --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower/devices/battery_BAT7 --method org.freedesktop.UPower.Device.GetHistory charge 604800 5000";
        const settled = function () { return upT.asks === a0 + 1 && !upT.busy; };
        const WEEK = root.weekMs;      // the newest fully-charged point of the week, nothing after it
        root.step("upower: asked, it answers: the pack was last full at the newest fully-charged point of the captured week", function () {
            root.upMode("ok");
            a0 = upT.asks;
            upT.refresh(true);
        }, function () { root.detail = j([upT.ok, upT.lastFullMs, upT.why]); return settled(); }, 6000);
        root.step("upower-read: one call, exactly the read-only history call, and the moment", function () {
            const c = root.upCalls("BAT7");
            root.check("upower-call", c.length === 1 && c[0].text === READ7, j(c.map(function (x) { return x.text; })));
            root.check("upower-moment", upT.ok === true && upT.lastFullMs === WEEK && upT.why === "", j([upT.ok, upT.lastFullMs, upT.why]));
        });
        // the throttle (a 2 s gap here; 10 minutes for real)
        root.step("upower: asked again at once, not forced: nothing is asked", function () {
            n0 = root.upCalls("BAT7").length;
            root.check("upower-throttle-answer", upT.refresh(false) === false);
        });
        root.pause(400);
        root.step("upower-throttle: ... and no call was made inside the gap", function () {
            root.check("upower-throttle", root.upCalls("BAT7").length === n0, j([root.upCalls("BAT7").length, n0]));
        });
        root.pause(1800);
        root.step("upower: past the gap an unforced ask is made", function () {
            a0 = upT.asks;
            root.check("upower-after-gap", upT.refresh(false) === true);
        }, settled, 6000);
        // the popup open: asked while it is, never closer than the gap, silent when it is closed
        root.step("upower: the popup is open for 5 s", function () {
            n0 = root.upCalls("BAT7").length;
            upT.popupOpen = true;
        });
        root.pause(5000);
        root.step("upower-open: it asked while the popup was open, and never closer than the gap", function () {
            upT.popupOpen = false;
            const c = root.upCalls("BAT7").slice(n0);
            let minGap = 1e9;
            for (let i = 1; i < c.length; i++)
                minGap = Math.min(minGap, c[i].at - c[i - 1].at);
            root.check("upower-open-periodic", c.length >= 1 && c.length <= 3 && minGap >= 1700, j([c.length, minGap]));
            n1 = root.upCalls("BAT7").length;
        });
        root.pause(2600);
        root.step("upower-closed: the popup closed, it asks nothing more", function () {
            root.check("upower-closed", root.upCalls("BAT7").length === n1, j([root.upCalls("BAT7").length, n1]));
        });
        // the order of the answer is not trusted
        root.step("upower: a span of 0 is answered OLDEST first by the real UPower: the same moment", function () {
            root.upMode("oldest");
            a0 = upT.asks;
            upT.refresh(true);
        }, settled, 6000);
        root.step("upower-order: the same last full from the other order", function () {
            root.check("upower-order", upT.ok && upT.lastFullMs === WEEK, j([upT.ok, upT.lastFullMs]));
        });
        // what the failures say (and keep)
        root.step("upower: not running", function () { root.upMode("notrunning"); a0 = upT.asks; upT.refresh(true); }, settled, 6000);
        root.step("upower-notrunning: a stated reason, the last good moment kept", function () {
            root.check("upower-notrunning", upT.ok === false && upT.why === "UPower is not running (The name is not activatable)" && upT.lastFullMs === WEEK, j([upT.ok, upT.why, upT.lastFullMs]));
        });
        root.step("upower: no history for this battery", function () { root.upMode("nohistory"); a0 = upT.asks; upT.refresh(true); }, settled, 6000);
        root.step("upower-nohistory: said so", function () {
            root.check("upower-nohistory", upT.ok === false && upT.why === "UPower keeps no charge history for this battery" && upT.lastFullMs === WEEK, j([upT.ok, upT.why]));
        });
        root.step("upower: an answer that is not a history", function () { root.upMode("garbage"); a0 = upT.asks; upT.refresh(true); }, settled, 6000);
        root.step("upower-garbage: not understood, said so", function () {
            root.check("upower-garbage", upT.ok === false && upT.why === "UPower's answer was not a history" && upT.lastFullMs === WEEK, j([upT.ok, upT.why]));
        });
        root.step("upower: gdbus is not installed", function () {
            n0 = root.calls("upower.log").length;
            upT.gdbus = "/nonexistent/gdbus";
            a0 = upT.asks;
            upT.refresh(true);
        }, settled, 6000);
        root.step("upower-missing: a stated reason; nothing was started (no call reached the stand-in; the runner checks the log for warnings)", function () {
            root.check("upower-missing", upT.ok === false && upT.why.indexOf("gdbus is not installed (/nonexistent/gdbus)") === 0 && root.calls("upower.log").length === n0, j([upT.ok, upT.why, root.calls("upower.log").length - n0]));
            upT.gdbus = root.upowerBin;
        });
        root.step("upower: an empty history", function () { root.upMode("empty"); a0 = upT.asks; upT.refresh(true); }, settled, 6000);
        root.step("upower-empty: an answer (ok, no reason) that has no full point: 0", function () {
            root.check("upower-empty", upT.ok === true && upT.why === "" && upT.lastFullMs === 0, j([upT.ok, upT.why, upT.lastFullMs]));
        });
        // no answer in time: one watchdog, the forced ask that came meanwhile is made once the first has ended
        root.step("upower: no answer (the stand-in sleeps), asked twice, forced, in the same breath", function () {
            root.upMode("slow");
            n0 = root.upCalls("BAT7").length;
            a0 = upT.asks;
            upT.refresh(true);
            upT.refresh(true);
        }, function () { root.detail = j([upT.asks - a0, upT.busy, upT._inFlight]); return upT.asks === a0 + 2 && !upT.busy && !upT._inFlight; }, 9000);
        root.step("upower-timeout: the watchdog ended it with a stated reason; the second ask waited for the first, so two calls and not three", function () {
            root.check("upower-timeout", upT.ok === false && upT.why === "UPower did not answer in 1.5 s", j([upT.ok, upT.why]));
            root.check("upower-in-flight", root.upCalls("BAT7").length === n0 + 2, String(root.upCalls("BAT7").length - n0));
        });
        // a battery event asks soon, not at once
        root.step("upower: a battery event asks soon", function () {
            root.upMode("ok");
            a0 = upT.asks;
            t0 = Date.now();
            upT.refreshSoon();
        }, settled, 6000);
        root.step("upower-soon: ... after the delay (300 ms here), and the moment is back", function () {
            const c = root.upCalls("BAT7");
            root.check("upower-soon", c[c.length - 1].at - t0 >= 250 && upT.ok === true && upT.lastFullMs === WEEK, j([c[c.length - 1].at - t0, upT.ok, upT.lastFullMs]));
        });
    }

    // ---- 3c. the HDMI fact (R4 D1): an external display on the NVIDIA card's HDMI-A connector, and only that one ---------------------------------
    // The fake machine's card0 is the NVIDIA card (vendor 0x10de) with an HDMI-A and an eDP; card1 is the iGPU. The watcher reads the connectors at start, on a udev
    // drm event (the shim on PATH feeds the lines the probe appends to udev_feed), and when asked: never on a timer.
    readonly property string drmDir: root.tree + "/sys/class/drm"
    readonly property string udevFeed: root.logs + "/udev_feed"
    function udevEvents(n) {       // n event lines of the real monitor's shape, a separate write 100 ms apart each
        root.sh("for i in $(seq 1 " + n + "); do printf 'UDEV  [%s.123456] change   /devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/card0 (drm)\\n' \"$i\" >> '" + root.udevFeed + "'; sleep 0.1; done");
    }
    // ---- 4b. the mains and the pack, by udev (round 3: the charge glyph answered a plug after the beat's period) ----------------
    readonly property string powerFeed: root.logs + "/power_feed"
    function powerEvents(n, gapS) {       // n event lines of the real monitor's shape (the adapter's), `gapS` seconds apart
        root.sh("for i in $(seq 1 " + n + "); do printf 'UDEV  [%s.123456] change   /devices/LNXSYSTM:00/LNXSYBUS:00/ACPI0003:00/power_supply/AC0 (power_supply)\\n' \"$i\" >> '" + root.powerFeed + "'; sleep " + (gapS === undefined ? 0.1 : gapS) + "; done");
    }
    function secPower() {
        let n0 = 0, t0 = 0, t1 = 0;
        root.step("power: the power_supply udev monitor is up (the service waits for its first status, then starts it)", null, function () {
            root.detail = j([svc.powerWatching, svc.powerEventPolls]);
            return svc.powerWatching === true;
        }, 12000);
        root.step("power-start: ONE call started it, and nothing was read for an event yet", function () {
            const c = root.calls("udevadm.log").filter(function (x) { return x.text === "monitor --udev --subsystem-match=power_supply"; });
            root.check("power-start", c.length === 1 && svc.powerEventPolls === 0, j([c.length, svc.powerEventPolls]));
            // let the gap rule be clear of anything the beat or the steps before did: the first event reads at once
        });
        root.pause(1700);
        root.step("power: the charger is pulled and udev says so", function () {
            n0 = svc.powerEventPolls;
            t0 = Date.now();
            root.put(root.acOnline, "0\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Discharging", pct: 100, powerUW: 12000000, energyUWh: 59455000 }));
            root.powerEvents(1);
        }, function () { return svc.powerEventPolls > n0; }, 3000);
        root.step("power-unplug: ONE event is ONE read, a moment after it (the debounce), not a beat's period later", function () {
            const dt = Date.now() - t0;
            root.check("power-unplug-one-read", svc.powerEventPolls === n0 + 1 && dt < 900, j([svc.powerEventPolls - n0, dt]));
        }, function () { return svc.battery.ac === false && svc.battery.status === "Discharging"; }, 3000);
        root.step("power-unplug-fact: ... and the reading it took is the pack as it is now", function () {
            root.check("power-unplug-fact", svc.battery.ac === false && svc.battery.status === "Discharging", j([svc.battery.ac, svc.battery.status]));
        });
        root.pause(1700);
        root.step("power: a burst of five events, 100 ms apart", function () {
            n0 = svc.powerEventPolls;
            t0 = Date.now();
            root.powerEvents(5);
        }, function () { return Date.now() - t0 >= 2400; }, 6000);
        root.step("power-burst-one-read: ... was one read (the events are debounced)", function () {
            root.check("power-burst-one-read", svc.powerEventPolls === n0 + 1, j([svc.powerEventPolls, n0]));
        });
        root.pause(1700);
        root.step("power: two events 400 ms apart (the adapter's, then the pack's status)", function () {
            n0 = svc.powerEventPolls;
            t0 = Date.now();
            root.powerEvents(2, 0.4);
        }, function () { return svc.powerEventPolls > n0; }, 3000);
        root.step("power-gap: the first was read at once; the second waits for the gap, then is read", function () {
            t1 = Date.now();
            root.check("power-gap-first", svc.powerEventPolls === n0 + 1, j([svc.powerEventPolls - n0, t1 - t0]));
        }, function () { return Date.now() - t0 >= 1100; }, 3000);
        root.step("power-gap: ... and it is still waiting inside the gap", function () {
            root.check("power-gap-waits", svc.powerEventPolls === n0 + 1, j([svc.powerEventPolls - n0, Date.now() - t0]));
        }, function () { return svc.powerEventPolls >= n0 + 2; }, 3000);
        root.step("power-gap: ... and read once the gap ended (a chatty driver is never a 1 Hz poll)", function () {
            root.check("power-gap-then-read", svc.powerEventPolls === n0 + 2 && Date.now() - t0 >= 1450, j([svc.powerEventPolls - n0, Date.now() - t0]));
        });
        root.step("power: plugged in again and full (the pack the rest of the run expects), read by the beat as before", function () {
            root.put(root.acOnline, "1\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Full", pct: 100, powerUW: 0, energyUWh: 59455000 }));
        }, function () { return svc.battery.status === "Full" && svc.battery.ac === true && svc.battery.atTarget === true; }, 8000);
    }

    function secDisplay() {
        let s0 = 0, s1 = 0, mark = 0;
        const hdmiStatus = root.drmDir + "/card0-HDMI-A-1/status";
        root.step("display: the connectors were read at start, and ONE udev monitor is up", null, function () {
            root.detail = j([svc.displayScans, svc.displayWatching]);
            return svc.displayScans >= 1 && svc.displayWatching === true;
        }, 12000);
        root.step("display-start: the NVIDIA card's HDMI-A is disconnected, so the fact is false; the monitor was started once, by the one call", function () {
            const c = root.calls("udevadm.log");
            const drm = c.filter(function (x) { return /subsystem-match=usb$/.test(x.text); });
            root.check("display-start", svc.display.hdmi === false && svc.displayScans === 1 && drm.length === 1 && drm[0].text === "monitor --udev --subsystem-match=drm --subsystem-match=usb", j([svc.display.hdmi, svc.displayScans, c.map(function (x) { return x.text; })]));
        });
        root.step("display: a display is plugged into the NVIDIA card's HDMI port and udev says so", function () {
            s0 = svc.displayScans;
            root.put(hdmiStatus, "connected\n");
            root.udevEvents(1);
        }, function () { return svc.display.hdmi === true; }, 8000);
        root.step("display-plug: ONE event is ONE scan", function () {
            root.check("display-plug-one-scan", svc.displayScans === s0 + 1, j([svc.displayScans, s0]));
        });
        root.step("display: a burst of five events, 100 ms apart", function () {
            s1 = svc.displayScans;
            mark = Date.now();
            root.udevEvents(5);
        }, function () { return Date.now() - mark >= 2200; }, 6000);
        root.step("display-burst: ... was one scan (the events are debounced), and the fact stands", function () {
            root.check("display-burst-one-scan", svc.displayScans === s1 + 1 && svc.display.hdmi === true, j([svc.displayScans, s1]));
            s1 = svc.displayScans;
            mark = Date.now();
        });
        root.step("display: nothing happens for two seconds", null, function () { return Date.now() - mark >= 2000; }, 5000);
        root.step("display-no-poll: ... and nothing was read (the watcher never polls)", function () {
            root.check("display-no-poll", svc.displayScans === s1, j([svc.displayScans, s1]));
        });
        root.step("display: a DisplayLink dock (its own DRM card, DVI-I connectors connected, no PCI vendor) and the HDMI port empty", function () {
            root.sh("mkdir -p '" + root.drmDir + "/card2/device' '" + root.drmDir + "/card2-DVI-I-1' '" + root.drmDir + "/card2-DVI-I-2'; printf 'connected\\n' > '" + root.drmDir + "/card2-DVI-I-1/status'; printf 'connected\\n' > '" + root.drmDir + "/card2-DVI-I-2/status'; ln -sfn /sys/bus/platform/drivers/evdi '" + root.drmDir + "/card2/device/driver'; ln -sfn /sys/bus/pci/drivers/nvidia '" + root.drmDir + "/card0/device/driver'");
            root.put(hdmiStatus, "disconnected\n");
            root.udevEvents(1);
        }, function () { return svc.display.hdmi === false && svc.displayConnectors.some(function (c) { return c.dir === "card2-DVI-I-1" && c.name === "DVI-I-1" && c.status === "connected"; }); }, 8000);
        root.step("display-dock: the dock's connected connectors are listed and are NOT the fact", function () {
            root.check("display-dock", svc.display.hdmi === false && svc.displayConnectors.filter(function (c) { return c.status === "connected" && !c.nvidia; }).length >= 3, j(svc.displayConnectors.map(function (c) { return c.dir + ":" + c.status; })));
        });
        root.step("display-drivers: the dock's card reads driver evdi with no PCI vendor, the NVIDIA card's HDMI-A reads nvidia (the same fact as before: 0x10de only)", function () {
            const dock = svc.displayConnectors.filter(function (c) { return c.card === "card2"; });
            const hd = svc.displayConnectors.filter(function (c) { return c.card === "card0" && c.type === "HDMI-A"; });
            root.check("display-driver-evdi", dock.length === 2 && dock.every(function (c) { return c.driver === "evdi" && c.vendor === "" && c.nvidia === false; }), j(dock));
            root.check("display-driver-nvidia", hd.length === 1 && hd[0].driver === "nvidia" && hd[0].nvidia === true && svc.display.hdmi === false, j(hd));
        });
        root.step("display: the dock stays and a display is plugged into the HDMI port too", function () {
            root.put(hdmiStatus, "connected\n");
            root.udevEvents(1);
        }, function () { return svc.display.hdmi === true; }, 8000);
        root.step("display: the card releases its connectors (nvidia_drm lets go: the HDMI-A connector is gone)", function () {
            root.sh("rm -f '" + root.drmDir + "/card0-HDMI-A-1'");
            root.udevEvents(1);
        }, function () { return svc.display.hdmi === false; }, 8000);
        root.step("display: it comes back, connected, and NO event arrives -- a refresh (a resume) reads it", function () {
            s0 = svc.displayScans;
            root.sh("ln -s ../../devices/pci0000:00/0000:00:01.0/0000:01:00.0/drm/card0/card0-HDMI-A-1 '" + root.drmDir + "/card0-HDMI-A-1'");
        }, null, 3000);
        root.step("display: refresh()", function () { svc.refresh(); }, function () { return svc.display.hdmi === true && svc.displayScans > s0; }, 8000);
        root.step("display: unplugged again, refresh", function () {
            root.put(hdmiStatus, "disconnected\n");
            root.refreshAfter();
        }, function () { return svc.display.hdmi === false; }, 8000);
        root.step("display-end: the fake machine is as it was (the dock is gone), read again", function () {
            root.sh("rm -f '" + root.drmDir + "/card0/device/driver'; rm -rf '" + root.drmDir + "/card2' '" + root.drmDir + "/card2-DVI-I-1' '" + root.drmDir + "/card2-DVI-I-2'");
            root.refreshAfter();
        }, function () { return !svc.displayConnectors.some(function (c) { return c.card === "card2"; }); }, 8000);
    }

    // ---- 4. a profile step: settle, ONE write, read-back --------------------------------------------------
    function secProfile() {
        let n0 = 0, tCall = 0;
        root.step("profile: the arrows step up (balanced -> performance)", function () {
            n0 = root.applies().length;
            tCall = Date.now();
            root.check("profile-step-accepted", svc.stepProfile(1) === true);
            root.check("profile-target-at-once", svc.profileTarget === 2 && svc.cpu.profile === "balanced" && svc.profileIndex === 1, j([svc.profileTarget, svc.cpu.profile]));
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "performance"; }, 6000);
        root.step("profile: the write was settled, exact, and read back", function () {
            const a = root.applies()[n0];
            root.check("profile-settle", a.at - tCall >= 280, String(a.at - tCall) + " ms");
            root.check("profile-write-linked-values", a.text === root.base(root.linked.performance), a.text);
            root.check("profile-readback", svc.cpu.epp === "performance" && svc.cpu.turbo === true && svc.cpu.tweaked === false && svc.profileTarget === 2 && svc.profileIndex === 2, j(svc.cpu));
            root.check("profile-caption", svc.caption.cpu === "Performance" && svc.caption.cpuError === "", svc.caption.cpu);
            root.check("profile-no-refusal", root.evRefused.length === 0 && j(svc.tuningTarget) === "{}", j([root.evRefused, svc.tuningTarget]));
        });
        // two steps in a burst are one write
        root.step("profile: two steps down in a burst (performance -> quiet)", function () {
            n0 = root.applies().length;
            root.check("burst-first", svc.stepProfile(-1) === true && svc.profileTarget === 1);
            root.check("burst-second", svc.stepProfile(-1) === true && svc.profileTarget === 0);
        }, function () { return svc.cpu.profile === "quiet"; }, 6000);
        root.pause(1200);
        root.step("burst-one-write: exactly one apply, the last intent's linked values", function () {
            const a = root.applies().slice(n0);
            root.check("burst-one-write", a.length === 1 && a[0].text === root.base(root.linked.quiet), j(a.map(function (x) { return x.text; })));
            // the profiles are a cycle: below Quiet is Performance, and one step back round is Quiet again (a burst: one write)
            root.check("profile-cycle", svc.stepProfile(-1) === true && svc.profileTarget === 2 && svc.stepProfile(1) === true && svc.profileTarget === 0, "below Quiet is Performance, and on round it is Quiet");
        });
        root.pause(1500);       // the burst's one write lands before the next section counts writes
    }

    // ---- 5. refused writes animate back, with their reason ----------------------------------------------------
    function secRefusals() {
        let n0 = 0, r0 = 0, tCall = 0;
        root.step("refused (local): PL1 above the firmware's ceiling is refused before anything is sent", function () {
            n0 = root.applies().length;
            r0 = root.evRefused.length;
            root.check("refused-local-returns", svc.setTuning({ pl1W: 60 }) === false);
            root.check("refused-local-signal", root.evRefused.length === r0 + 1 && root.evRefused[r0].zone === "cpu" && root.evRefused[r0].why === "Above the firmware's 45 W", j(root.evRefused));
            root.check("refused-local-caption", svc.caption.cpuError === "Above the firmware's 45 W", svc.caption.cpuError);
        });
        root.pause(800);
        root.step("refused-local: nothing was written", function () {
            root.check("refused-local-no-write", root.applies().length === n0, String(root.applies().length - n0));
        });
        root.step("refused (helper): the helper's write of the profile fails (EIO)", function () { root.put(root.logs + "/faults", "profile:eio"); }, function () { return true; });
        root.step("refused (helper): quiet -> balanced is aimed at once ...", function () {
            n0 = root.applies().length;
            r0 = root.evRefused.length;
            root.check("refused-helper-aim", svc.stepProfile(1) === true && svc.profileTarget === 1);
        }, function () { return root.evRefused.length === r0 + 1; }, 6000);
        root.step("refused (helper): ... and the target animates BACK, the reason is in the caption", function () {
            const e = root.evRefused[r0];
            root.check("refused-helper-signal", e.zone === "cpu" && (root.standIn ? /write failed/i.test(e.why) : e.why.length > 5), j(e));
            root.check("refused-helper-target-back", svc.profileTarget === 0 && svc.cpu.profile === "quiet", j([svc.profileTarget, svc.cpu.profile]));
            root.check("refused-helper-caption", svc.caption.cpuError === e.why && svc.caption.cpuError.length > 0, svc.caption.cpuError);
            root.check("refused-helper-one-attempt", root.applies().length === n0 + 1, String(root.applies().length - n0));
        });
        root.step("refused: the faults are cleared", function () { root.put(root.logs + "/faults", ""); }, function () { return true; });
        // the other knobs of that apply WERE written (a failed write does not stop the later ones): a tweak, which a reset undoes
        root.step("reset: the half-applied profile shows as a tweak; resetTuning() applies the profile's own values", function () {
            root.check("refused-partial-is-a-tweak", svc.cpu.tweaked === true && svc.caption.cpu === "Quiet · tweaked", j([svc.cpu.tweaked, svc.caption.cpu, svc.cpu.epp, svc.cpu.turbo]));
            n0 = root.applies().length;
            root.check("reset-accepted", svc.resetTuning() === true && svc.caption.cpuError === "");
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.tweaked === false; }, 6000);
        root.step("reset: the apply is the profile's linked values; the tweak and the error are gone", function () {
            root.check("reset-write", root.applies()[n0].text === root.base(root.linked.quiet), root.applies()[n0].text);
            root.check("reset-state", svc.cpu.epp === "power" && svc.cpu.turbo === false && svc.caption.cpu === "Quiet" && svc.caption.cpuError === "", j([svc.cpu.epp, svc.cpu.turbo, svc.caption]));
        });
        // a write the kernel accepts but holds differently
        root.step("refused (mismatch): the kernel clamps the EPP to balance_power", function () { root.put(root.logs + "/faults", "epp:clamp:balance_power"); }, function () { return true; });
        root.step("mismatch: setTuning({ epp: performance }) is written and reads back DIFFERENT", function () {
            n0 = root.applies().length;
            r0 = root.evRefused.length;
            root.check("mismatch-accepted", svc.setTuning({ epp: "performance" }) === true && j(svc.tuningTarget) === '{"epp":"performance"}', j(svc.tuningTarget));
        }, function () { return root.evRefused.length === r0 + 1; }, 6000);
        root.step("mismatch: refused with the helper's words; the true value shows; the tuning target is gone", function () {
            const e = root.evRefused[r0];
            root.check("mismatch-signal", e.zone === "cpu" && e.why.indexOf("balance_power") >= 0 && /kernel/i.test(e.why), j(e));
            root.check("mismatch-truth", svc.cpu.epp === "balance_power" && svc.cpu.tweaked === true && j(svc.tuningTarget) === "{}", j([svc.cpu.epp, svc.cpu.tweaked, svc.tuningTarget]));
            root.check("mismatch-write", root.applies()[n0].text === root.base("apply epp=performance"), root.applies()[n0].text);
        });
        root.step("refused: the faults are cleared", function () { root.put(root.logs + "/faults", ""); }, function () { return true; });
        // tuning: a burst of setTuning calls is one write, the latest value of each knob
        root.step("tuning: two setTuning calls in a burst merge into ONE write (the latest value per knob)", function () {
            n0 = root.applies().length;
            root.check("tuning-first", svc.setTuning({ epp: "balance_performance", pl2W: 90 }) === true);
            root.check("tuning-second", svc.setTuning({ epp: "balance_power", pl1W: 30 }) === true);
            root.check("tuning-target", j(svc.tuningTarget) === '{"epp":"balance_power","pl2W":90,"pl1W":30}', j(svc.tuningTarget));
        }, function () { return svc.cpu.pl1W === 30 && svc.cpu.pl2W === 90; }, 6000);
        root.step("tuning: one apply, the caps on both zones, a tweak", function () {
            root.check("tuning-one-write", root.applies().length === n0 + 1 && root.applies()[n0].text === root.base("apply epp=balance_power pl1_w=30 pl2_w=90"), j(root.applies().slice(n0).map(function (x) { return x.text; })));
            root.check("tuning-state", svc.cpu.epp === "balance_power" && svc.cpu.tweaked === true && svc.caption.cpu === "Quiet · tweaked" && j(svc.tuningTarget) === "{}", j([svc.cpu.epp, svc.caption.cpu, svc.tuningTarget]));
        });
        root.step("reset: resetTuning() puts the firmware's caps back too", function () {
            n0 = root.applies().length;
            svc.resetTuning();
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.tweaked === false && svc.cpu.pl1W === 45 && svc.cpu.pl2W === 115; }, 6000);
        root.step("reset-caps: the quiet profile, whole", function () {
            root.check("reset-caps-write", root.applies()[n0].text === root.base(root.linked.quiet), root.applies()[n0].text);
        });
        // a helper that never answers
        root.step("watchdog: pkexec waits for an authorisation nobody gives", function () { root.put(root.logs + "/hang", "1"); }, function () { return true; });
        root.step("watchdog: a profile step is aimed", function () {
            r0 = root.evRefused.length;
            tCall = Date.now();
            root.check("watchdog-aim", svc.stepProfile(1) === true && svc.profileTarget === 1);
        }, function () { return root.evRefused.length === r0 + 1; }, 9000);
        root.step("watchdog: refused after the 10 s watchdog (2.5 s here) with its reason; the target is back", function () {
            const e = root.evRefused[r0], dt = Date.now() - tCall;
            root.check("watchdog-refused", e.zone === "cpu" && e.why.indexOf("did not answer") >= 0, j(e));
            root.check("watchdog-time", dt >= 2700 && dt < 6000, String(dt) + " ms (settle 300 + watchdog 2500)");
            root.check("watchdog-target-back", svc.profileTarget === 0 && svc.cpu.profile === "quiet" && svc.caption.cpuError === e.why, j([svc.profileTarget, svc.cpu.profile]));
        });
        root.step("watchdog: the switch is off again", function () { root.sh("rm -f '" + root.logs + "/hang'"); }, function () { return true; });
        root.pause(4500);      // the hung stand-in ends by itself
    }

    // ---- 6. a change made outside the popup ---------------------------------------------------------------------------
    function secExternal() {
        let n0 = 0, o0 = 0, nt0 = 0, s0 = 0, q0 = 0, t0 = 0;
        // The helper's status walks the machine and reads the GPU MUX through the ASUS firmware (an ACPI call into the EC):
        // an open popup with nothing changing asks for none (it was every 2 s until 2026-10-12, when the EC wedged).
        root.step("status-quiet: an open, alive popup where nothing changes for 8 s", function () {
            q0 = svc.statusRuns;
            t0 = Date.now();
            root.beatRec.on = true;
            svc.touch();
        }, function () { svc.touch(); return Date.now() - t0 >= 8000; }, 12000);
        root.step("beat: every reader read ON a beat, stats and battery on the SAME one, the status only on the Nth", function () {
            const r = root.beatRec, c = svc.cadence;
            r.on = false;
            const at = {};
            r.beats.forEach(b => { at[b.serial] = b.t; });
            const per = {};
            r.polls.forEach(p => { per[p.serial] = per[p.serial] || { stats: 0, battery: 0, smi: 0, overhead: 0 }; per[p.serial][p.kind]++; });
            const late = r.polls.filter(p => at[p.serial] === undefined || Math.abs(p.t - at[p.serial]) > 30);
            const serials = r.beats.map(b => b.serial);
            root.check("beat-cadence: the alive popup beats every second with every reader on every beat (the cadence table)",
                       c.baseMs === 1000 && c.stats === 1 && c.battery === 1 && c.status === 60 && c.overhead === 1 && serials.length >= 6 && svc.readingBeat.baseMs === 1000, j([c, serials.length]));
            root.check("beat-sequence: the beats are consecutive serials, a second apart",
                       serials.every((n, i) => i === 0 || n === serials[i - 1] + 1) && r.beats.every((b, i) => i === 0 || Math.abs(b.t - r.beats[i - 1].t - 1000) < 150), j(r.beats.map(b => [b.serial, b.t - r.beats[0].t])));
            root.check("beat-on-beat: every reading was taken in the event of a beat (none on a timer of its own)", r.polls.length >= 12 && late.length === 0, j([r.polls.length, late.slice(0, 3)]));
            root.check("beat-same-beat: stats and battery are read exactly once on every beat, together",
                       serials.every(n => per[n] && per[n].stats === 1 && per[n].battery === 1), j(per));
            root.check("beat-status-nth: a status run only on a beat whose serial is a multiple of the status count", r.status.every(x => x.serial % c.status === 0), j(r.status.map(x => x.serial)));
            root.check("reading-serial: the facts carry the beat's serial and period", svc.readingMs === 1000 && svc.readingSerial === svc.readingBeat.serial, j([svc.readingMs, svc.readingSerial, svc.readingBeat.serial]));
        });
        root.step("status-quiet: no status was asked of the helper (at most the minute's backstop, if it fell in the window)", function () {
            root.check("status-quiet", svc.statusRuns - q0 <= 1 && svc.idleState === "alive", j([svc.statusRuns - q0, svc.idleState]));
        });
        root.step("external: the profile file says performance (asusctl, a key, a script)", function () {
            n0 = root.applies().length;
            o0 = root.evOsd.length;
            nt0 = root.calls("notify-send.log").length;
            s0 = svc.statusRuns;
            t0 = Date.now();
            root.putProfile("performance");
        }, function () { return root.evOsd.length === o0 + 1 && root.applies().length === n0 + 1 && svc.cpu.epp === "performance"; }, 9000);
        // ... and it is seen through the kernel's own copy (a battery poll: 1 s alive), which asks for the status once
        root.step("status-on-knob: the outside profile was noticed and applied within 5 s (the backstop would take a minute)", function () {
            root.check("status-on-knob", Date.now() - t0 < 5000 && svc.statusRuns >= s0 + 1, j([Date.now() - t0, svc.statusRuns - s0]));
        });
        root.step("external: noticed, its linked values applied (only what differs), the OSD asked for", function () {
            const o = root.evOsd[o0];
            root.check("external-osd-request", o.kind === "power" && o.title === "Performance" && o.colorToken === "profilePerformance" && o.detail === "Power profile" && o.source === "silicon" && o.glyph === "\u{F140B}", j(o));
            root.check("external-applied", root.applies()[n0].text === root.base("apply epp=performance turbo=1"), root.applies()[n0].text);
            root.check("external-target", svc.profileTarget === 2 && svc.cpu.profile === "performance" && svc.cpu.tweaked === false, j([svc.profileTarget, svc.cpu.profile, svc.cpu.tweaked]));
            const n = root.calls("notify-send.log");
            root.check("external-osd-fallback", n.length === nt0 + 1 && n[nt0].text.indexOf("-a Silicon") >= 0 && n[nt0].text.indexOf("Performance Power profile") >= 0, j(n.slice(nt0)));
        });
        root.step("external, with an OSD service: the profile file says balanced", function () {
            OsdBus.service = fakeOsd;
            n0 = root.applies().length;
            nt0 = root.calls("notify-send.log").length;
            root.putProfile("balanced");
        }, function () { return fakeOsd.shown.length === 1 && root.applies().length === n0 + 1 && svc.cpu.epp === "balance_power"; }, 9000);
        root.step("external-osd-service: asked through OsdBus (kind power), nothing on the desktop", function () {
            const r = fakeOsd.shown[0];
            root.check("external-osd-bus", r.kind === "power" && r.source === "bus:silicon" && r.title === "Balanced" && r.colorToken === "profileBalanced" && r.key === "silicon-profile", j(r));
            root.check("external-osd-no-notification", root.calls("notify-send.log").length === nt0, String(root.calls("notify-send.log").length - nt0));
            root.check("external-balanced-applied", root.applies()[n0].text === root.base("apply epp=balance_power"), root.applies()[n0].text);
            OsdBus.service = null;
        });
        // The EPP alone moves outside (round 7: the user read "balance performance" on the glyph's dot and the CPU detail while the boot unit had
        // applied "power"): the figure shown is the machine's, seen through the kernel's own copy within a battery poll, shown as a tweak, and
        // nothing is written back by the shell (an outside change of EPP alone is the user's / the system's; it is neither news nor undone).
        root.step("outside EPP: the policies' energy preference alone is set to balance_performance (nothing else moves)", function () {
            n0 = root.applies().length;
            s0 = svc.statusRuns;
            t0 = Date.now();
            stim.run(["sh", "-c", "for f in '" + root.polDir + "'/policy*/energy_performance_preference; do echo balance_performance > \"$f\"; done"], function () {});
        }, function () { return svc.cpu.epp === "balance_performance"; }, 9000);
        root.step("outside EPP: shown within 5 s, as a tweak of the profile; the shell wrote nothing", function () {
            root.check("epp-outside-seen", Date.now() - t0 < 5000 && svc.statusRuns >= s0 + 1 && svc.cpu.profile === "balanced" && svc.cpu.tweaked === true,
                       j([Date.now() - t0, svc.statusRuns - s0, svc.cpu.profile, svc.cpu.tweaked]));
            root.check("epp-outside-no-write", root.applies().length === n0, String(root.applies().length - n0));
            n0 = root.applies().length;
            t0 = Date.now();
            stim.run(["sh", "-c", "for f in '" + root.polDir + "'/policy*/energy_performance_preference; do echo balance_power > \"$f\"; done"], function () {});
        }, function () { return svc.cpu.epp === "balance_power"; }, 9000);
        root.step("outside EPP: back to the profile's own value, the tweak is gone", function () {
            root.check("epp-outside-back", Date.now() - t0 < 5000 && svc.cpu.tweaked === false && root.applies().length === n0, j([Date.now() - t0, svc.cpu.tweaked]));
        });
    }

    // ---- 7. the charge limit ------------------------------------------------------------------------------------------------
    function secLimit() {
        let n0 = 0, o0 = 0, e0 = 0;
        // a profile step and the DIP switch in one breath: two writes, and neither's target is left standing
        // when the other's write ends. The profile's authorisation is slow (0.8 s) and the switch is flipped
        // while that write is on the wire, so the CPU's write ends with the limit's still waiting.
        root.step("limit: a profile step, its authorisation slow", function () {
            n0 = root.writes().length;
            o0 = root.evOsd.length;
            root.sh("printf 0.8 > '" + root.logs + "/delay'");
            root.check("limit-profile-accepted", svc.stepProfile(1) === true && svc.profileTarget === 2);
        }, function () { return root.writes().length === n0 + 1; }, 6000);
        root.step("limit: the DIP switch to 80 % while that write is on the wire", function () {
            root.check("limit-accepted", svc.setChargeLimit(true) === true && svc.chargeLimitTarget === 80 && svc.battery.limitOn === false, j([svc.chargeLimitTarget, svc.battery.limitOn]));
        }, function () { return svc.battery.limitOn === true && svc.cpu.profile === "performance" && root.writes().length === n0 + 2; }, 9000);
        root.step("limit: two writes, the helper's; no OSD for our own changes", function () {
            const w = root.writes().slice(n0).map(function (x) { return x.text; });
            root.check("limit-write", w.indexOf(root.base("set-charge-limit 80")) >= 0 && w.indexOf(root.base(root.linked.performance)) >= 0, j(w));
            root.check("limit-state", svc.battery.limitPct === 80 && svc.chargeLimitTarget === 80 && svc.battery.toLimit === false, j([svc.battery.limitPct, svc.chargeLimitTarget]));
            root.check("limit-no-own-osd", root.evOsd.length === o0, String(root.evOsd.length - o0));
            // the CPU's write ended while the limit's still waited: its intent is settled (the pending tuning
            // the panel shows is gone), not left standing until some later write happens to end
            root.check("limit-no-stranded-target", j(svc.tuningTarget) === "{}", j(svc.tuningTarget));
            root.putProfile("balanced");
        }, function () { return svc.cpu.profile === "balanced" && svc.cpu.epp === "balance_power"; }, 9000);
        root.step("limit-target-follows-facts: the profile moved outside, and the target moved with it", function () {
            root.check("limit-target-follows-facts", svc.profileTarget === 1 && svc.profileIndex === 1 && j(svc.tuningTarget) === "{}", j([svc.profileTarget, svc.profileIndex, svc.tuningTarget]));
        });
        root.step("limit: charging again shows the time to the LIMIT", function () {
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 50, powerUW: 30000000, energyUWh: 30000000 }));
        }, function () { return svc.battery.status === "Charging" && svc.battery.toLimit === true; }, 6000);
        root.step("limit-to-limit: 80 % of 59.455 Wh is 47.564; 17.564 Wh at 30 W = 35.1 min", function () {
            root.check("limit-time-to-limit", root.near(svc.battery.minutesToFull, 35.128, 0.3) && svc.battery.toLimit === true, j([svc.battery.minutesToFull, svc.battery.toLimit]));
            root.check("limit-caption", svc.caption.battery === "Charging · 35m to 80 %", svc.caption.battery);
        });
        root.step("limit: 79 %", function () { root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 79, powerUW: 20000000, energyUWh: 46900000 })); }, function () { return svc.battery.pct === 79; });
        root.step("limit: 80 %, Not charging, nothing flowing -> full (the limit is the target)", function () {
            e0 = root.evBattery.length;
            root.put(root.bat + "/uevent", root.uevent({ status: "Not charging", pct: 80, powerUW: 0, energyUWh: 47564000 }));
        }, function () { return svc.battery.status === "Not charging" && svc.battery.pct === 80; });
        root.step("limit-full-at-target: chargeDone and full", function () {
            root.check("limit-full-at-target", j(root.evBattery.slice(e0)) === '["chargeDone","full"]', j(root.evBattery.slice(e0)));
            root.check("limit-caption-held", svc.caption.battery === "Plugged in · limited to 80 %", svc.caption.battery);
        });
        root.step("limit: the limit file says 100 (asusctl, the old battery module)", function () {
            o0 = root.evOsd.length;
            root.put(root.limitFile, "100\n");
        }, function () { return svc.battery.limitOn === false && root.evOsd.length === o0 + 1; }, 6000);
        root.step("limit-external: noticed, the OSD says so", function () {
            root.check("limit-external-osd", root.evOsd[o0].key === "silicon-limit" && root.evOsd[o0].title === "Charge limit off", j(root.evOsd[o0]));
            root.check("limit-external-target", svc.chargeLimitTarget === 100, String(svc.chargeLimitTarget));
        });
        // the switch flipped twice while the first write is on the wire (an authorisation slow to answer, 0.8 s):
        // neither landing is news, and the switch does not go back to the first value between the two writes
        root.step("limit: the switch goes on, the authorisation is slow", function () {
            n0 = root.writes().length;
            o0 = root.evOsd.length;
            root.limitTrail = [svc.chargeLimitTarget];
            root.sh("printf 0.8 > '" + root.logs + "/delay'");
            root.check("limit-flip-1", svc.setChargeLimit(true) === true && svc.chargeLimitTarget === 80);
        }, function () { return root.writes().length === n0 + 1; }, 6000);
        root.step("limit: and off again while that write is on the wire", function () {
            root.check("limit-flip-2", svc.setChargeLimit(false) === true && svc.chargeLimitTarget === 100);
        }, function () { return root.writes().length === n0 + 2; }, 9000);     // the second write has started: the first has landed
        root.pause(600);
        root.step("limit-flip: the target went 100, 80, 100 and no further; both landings were ours", function () {
            root.check("limit-flip-target", j(root.limitTrail) === "[100,80,100]", j(root.limitTrail));
            root.check("limit-flip-not-news", root.evOsd.length === o0, String(root.evOsd.length - o0));
            root.check("limit-flip-writes", root.writes()[n0].text === root.base("set-charge-limit 80") && root.writes()[n0 + 1].text === root.base("set-charge-limit 100"), j(root.writes().slice(n0).map(function (x) { return x.text; })));
        });
    }

    // ---- 8. cardwire and the dGPU ---------------------------------------------------------------------------------------
    function cwSets() {
        return root.calls("cardwire.log").filter(function (c) { return c.text.indexOf("SET ") === 0; });
    }
    function cwCalls(method) {
        return root.calls("cardwire.log").filter(function (c) { return c.text.indexOf("CALL ") === 0 && c.text.indexOf("." + method + " ") > 0; });
    }
    // The card's three nodes as the machine itself reports them with the dGPU asleep (cardwire's Gpu Lsof, measured 2026-10-11, R5 W1):
    // the daemons AND the session -- Hyprland, Xwayland, Xorg, systemd, systemd-logind -- hold them, and none of those is a user, so
    // `name` (a game, blender) is the only holder there is, and "" is no holder at all.
    function lsofWith(name) {
        const d = {};
        d[root.nodes[0]] = ["Hyprland", "Xwayland", "systemd", "systemd-logind"];
        d[root.nodes[1]] = name === "" ? ["Hyprland", "Xorg", "cardwired"] : ["Hyprland", "Xorg", "cardwired", name];
        d[root.nodes[2]] = ["Hyprland", "Xorg", "cardwired", "nvidia-persiste"];
        d["/dev/nvidiactl"] = ["cardwired", "nvidia-persiste", "Hyprland", "code"];
        return "'" + JSON.stringify(d) + "'";
    }

    function secGpu() {
        let n0 = 0, o0 = 0, smi0 = 0, tEmpty = 0, p0 = 0, b0 = 0;
        root.step("gpu: Smart is one step down from Hybrid; the target moves at once, cardwire is asked", function () {
            n0 = root.cwSets().length;
            o0 = root.evOsd.length;
            root.check("gpu-step-accepted", svc.stepGpuMode(-1) === true && svc.gpuModeTarget === 1 && svc.gpu.step === 2, j([svc.gpuModeTarget, svc.gpu.step]));
        }, function () { return svc.gpu.mode === 3 && svc.gpu.step === 1; }, 6000);
        root.step("gpu: written as Mode 3, read back; our own change is silent", function () {
            const sets = root.cwSets();
            root.check("gpu-mode-write", sets.length === n0 + 1 && sets[n0].text === "SET org.opengamingcollective.cardwire.Mode.Mode 3", j(sets.slice(n0)));
            root.check("gpu-step-state", svc.gpuMode === 1 && svc.gpuModeTarget === 1 && svc.caption.gpu === "Smart · dGPU asleep" && svc.caption.gpuError === "", j([svc.gpuMode, svc.caption.gpu]));
            root.check("gpu-own-change-silent", root.evOsd.length === o0 && root.evRefused.filter(function (e) { return e.zone === "gpu"; }).length === 0, String(root.evOsd.length - o0));
        });
        root.step("gpu: Integrated", function () { svc.stepGpuMode(-1); }, function () { return svc.gpu.mode === 0 && svc.gpu.step === 0; }, 6000);
        root.step("gpu: Integrated shows as such; there is no step further down", function () {
            root.check("gpu-integrated", svc.caption.gpu === "Integrated · dGPU off" && svc.gpuMode === 0 && svc.stepGpuMode(-1) === false, svc.caption.gpu);
        });
        root.step("gpu: back to Hybrid in one go", function () { svc.setGpuMode(2, {}); }, function () { return svc.gpu.mode === 1 && svc.gpu.step === 2; }, 6000);
        root.step("gpu: an EXTERNAL mode change (cardwire set smart, its battery auto-switch) is noticed and shown", function () {
            o0 = root.evOsd.length;
            n0 = root.cwSets().length;
            root.ctl("SetMode", "3");
        }, function () { return svc.gpu.mode === 3 && root.evOsd.length === o0 + 1; }, 6000);
        root.step("gpu-external: the OSD names the new mode, and the zone follows", function () {
            root.check("gpu-external-osd", root.evOsd[o0].key === "silicon-gpu" && root.evOsd[o0].title === "Smart" && root.evOsd[o0].colorToken === "gpuSmart", j(root.evOsd[o0]));
            root.check("gpu-external-state", svc.gpuMode === 1 && svc.gpuModeTarget === 1 && root.cwSets().length === n0, j([svc.gpuMode, svc.gpuModeTarget]));
        });
        root.step("gpu: and back to Hybrid by the same external route (the last value WE wrote must not hide it)", function () {
            o0 = root.evOsd.length;
            root.ctl("SetMode", "1");
        }, function () { return svc.gpu.mode === 1 && root.evOsd.length === o0 + 1; }, 6000);
        root.step("gpu-external-again: noticed too", function () {
            root.check("gpu-external-again", root.evOsd[o0].title === "Hybrid", j(root.evOsd[o0]));
        });
        // cardwire's own settings
        root.step("gpu: cardwire's battery auto-switch is turned on", function () {
            n0 = root.cwSets().length;
            root.check("gpu-config-accepted", svc.setCardwireConfig("batteryAutoSwitch", true) === true);
        }, function () { return svc.gpu.config.batteryAutoSwitch === true; }, 6000);
        root.step("gpu-config: the property was set on cardwire", function () {
            const sets = root.cwSets();
            root.check("gpu-config-write", sets.length === n0 + 1 && sets[n0].text === "SET org.opengamingcollective.cardwire.Config.BatteryAutoSwitch true", j(sets.slice(n0)));
        });
        root.step("gpu: the auto-switch mode is changed from outside (cardwire's own GUI)", function () { root.ctl("SetConfig", ["BatteryAutoSwitchMode", "0"]); }, function () { return svc.gpu.config.batteryAutoSwitchMode === 0; }, 6000);
        root.step("gpu: a Smart-mode app policy is set (kitty: allowed)", function () {
            n0 = root.cwCalls("SetAppPolicy").length;
            root.check("gpu-policy-accepted", svc.setAppPolicy("kitty", true) === true);
        }, function () {
            const k = svc.gpu.policies.filter(function (p) { return p.id === "kitty"; })[0];
            return k && k.policy === 1;
        }, 6000);
        root.step("gpu-policy: SetAppPolicy(kitty, 1) reached cardwire", function () {
            const c = root.cwCalls("SetAppPolicy");
            root.check("gpu-policy-write", c.length === n0 + 1 && c[n0].text.indexOf('["kitty",1]') > 0, j(c.slice(n0)));
        });
        // a blocked app: signalled, ignorable, remembered
        root.step("gpu: Smart blocks an app (blender)", function () {
            b0 = root.evBlocked.length;
            root.ctl("EmitBlocked", ["4242", "'blender'", "1", "'org.blender.Blender'"]);
        }, function () { return root.evBlocked.length === b0 + 1; }, 6000);
        root.step("gpu-blocked: the signal carries the app; it is in the blocked list; the user ignores it", function () {
            const a = root.evBlocked[b0];
            root.check("gpu-blocked-signal", a.id === "org.blender.Blender" && a.comm === "blender" && a.pid === 4242 && a.gpuId === 1, j(a));
            root.check("gpu-blocked-list", svc.gpu.blockedApps.indexOf("org.blender.Blender") >= 0, j(svc.gpu.blockedApps.length));
            svc.ignoreApp("org.blender.Blender");
            root.ctl("EmitBlocked", ["4243", "'blender'", "1", "'org.blender.Blender'"]);
        });
        root.pause(1200);
        root.step("gpu-ignored: an ignored app is not announced again", function () {
            root.check("gpu-ignored", root.evBlocked.length === b0 + 1, String(root.evBlocked.length - b0));
        });
        // ignored apps are FACTS: a flag on the policy rows (the GPU panel's "Ignored") and the persisted ids (the notifier's)
        root.step("gpu: the user ignores kitty too (a listed app: its row must say so)", function () { svc.ignoreApp("kitty"); }, function () {
            const k = svc.gpu.policies.filter(function (p) { return p.id === "kitty"; })[0];
            return !!k && k.ignored === true;
        }, 6000);
        root.step("gpu-ignored-facts: the rows say who is ignored, the list has the ids, nobody else is", function () {
            const rows = svc.gpu.policies.map(function (p) { return p.id + ":" + p.ignored; });
            root.check("gpu-ignored-facts", j(svc.gpu.ignoredApps) === '["org.blender.Blender","kitty"]'
                       && svc.gpu.policies.every(function (p) { return typeof p.ignored === "boolean"; })
                       && svc.gpu.policies.filter(function (p) { return p.ignored; }).map(function (p) { return p.id; }).join() === "kitty", j([svc.gpu.ignoredApps, rows]));
        });

        // ---- holders, and the one rule about nvidia-smi ----
        root.step("gpu: someone opens the dGPU while it SLEEPS (Lsof: blender, beside the session's own holders)", function () {
            smi0 = root.calls("nvidia-smi.log").length;
            root.ctl("SetLsof", [root.lsofWith("blender")]);
        }, function () { return svc.gpu.holders.length === 1 && svc.gpu.holders[0] === "blender"; }, 6000);
        root.pause(3500);
        root.step("smi-never-asleep: a user, but the card sleeps: nvidia-smi was NOT asked (asking would wake it)", function () {
            root.check("smi-never-asleep", root.calls("nvidia-smi.log").length === smi0 && svc.gpu.awake === false && svc.gpu.util === null, String(root.calls("nvidia-smi.log").length - smi0) + " call(s)");
            root.check("gpu-holders-asleep", svc.caption.gpu === "Hybrid · in use by blender", svc.caption.gpu);
        });
        root.step("gpu: the card wakes (PowerStateChanged 'D0')", function () {
            p0 = root.evPower.length;
            root.power("D0");
        }, function () { return svc.gpu.awake === true && svc.gpu.util === 37; }, 9000);
        root.step("gpu-awake: the signal, the D-state, the readings of nvidia-smi", function () {
            root.check("gpu-power-signal", j(root.evPower.slice(p0)) === '["D0"]' && svc.gpu.dState === "D0", j(root.evPower.slice(p0)));
            root.check("gpu-readings", svc.gpu.util === 37 && svc.gpu.tempC === 52 && svc.gpu.watts === 28.4 && svc.gpu.vramUsedMB === 2048 && svc.gpu.vramTotalMB === 8188, j([svc.gpu.util, svc.gpu.tempC, svc.gpu.watts, svc.gpu.vramUsedMB, svc.gpu.vramTotalMB]));
            root.check("gpu-caption-awake", svc.caption.gpu === "Hybrid · in use by blender", svc.caption.gpu);
        });
        root.step("gpu: the load changes (the stub's answer)", function () { root.put(root.logs + "/smi.csv", "88, 61, 55.10, 4096, 8188\n"); }, function () { return svc.gpu.util === 88 && svc.gpu.watts === 55.1; }, 6000);
        root.pause(2000);
        root.step("gpu: Smart with an app on the card asks first (refused without the confirmation)", function () {
            n0 = root.cwSets().length;
            const r0 = root.evRefused.length;
            root.check("gpu-holders-refused", svc.setGpuMode(1, {}) === false && root.evRefused.length === r0 + 1 && root.evRefused[r0].zone === "gpu" && root.evRefused[r0].why.indexOf("blender") >= 0, j(root.evRefused.slice(r0)));
            root.check("gpu-holders-no-write", root.cwSets().length === n0 && svc.gpuModeTarget === 2, j([svc.gpuModeTarget]));
            root.check("gpu-holders-confirmed", svc.setGpuMode(1, { confirmHolders: true }) === true && svc.gpuModeTarget === 1);
        }, function () { return svc.gpu.mode === 3; }, 6000);
        root.step("gpu: and Hybrid again (needs no confirmation)", function () { root.check("gpu-hybrid-without-confirm", svc.setGpuMode(2, {}) === true); }, function () { return svc.gpu.mode === 1; }, 6000);
        root.step("gpu: the app exits (Lsof: nobody)", function () {
            tEmpty = Date.now();
            root.ctl("SetLsof", [root.lsofWith("")]);
        }, function () { return svc.gpu.holders.length === 0 && svc.gpu.util === null; }, 6000);
        root.step("gpu-session-plumbing: only the session holds the card's nodes (Hyprland, Xwayland, Xorg, systemd, systemd-logind): no holder, no \"in use by\", and Integrated needs no confirmation (R5 W1)", function () {
            const plan = Model.planGpuMode(0, {}, svc.gpu, svc.gpuModeTarget);
            root.check("gpu-session-not-users", svc.gpu.holders.length === 0 && svc.caption.gpu.indexOf("in use by") < 0, j([svc.gpu.holders, svc.caption.gpu]));
            root.check("gpu-session-no-warning", plan.action === "cardwire", j(plan));
        });
        root.step("gpu: the card sleeps again", function () { root.power("D3cold"); }, function () { return svc.gpu.dState === "D3cold" && svc.gpu.awake === false; }, 6000);
        // the bar's card: who is on the dGPU has to be known with the popup shut, and asking must cost nothing while the card sleeps
        root.step("gpu (popup shut): the card wakes with nobody on it", function () {
            svc.popupOpen = false;
            root.power("D0");
        }, function () { return svc.gpu.awake === true && svc.gpu.inUse === false; }, 6000);
        root.step("gpu (popup shut): something opens the card: the beat reads it, the card is in use", function () {
            root.ctl("SetLsof", [root.lsofWith("blender")]);
        }, function () { return svc.gpu.inUse === true; }, 14000);
        root.step("gpu (popup shut): it exits: idle again", function () {
            root.ctl("SetLsof", [root.lsofWith("")]);
        }, function () { return svc.gpu.inUse === false && svc.gpu.holders.length === 0; }, 14000);
        root.step("gpu (popup shut): the card sleeps; the popup again", function () {
            root.power("D3cold");
            svc.popupOpen = true;
        }, function () { return svc.gpu.dState === "D3cold" && svc.gpu.inUse === false; }, 6000);
        // round 3 (the user: the list of holders that are harmless is silicon.jsonc's, `gpu.ignoredHolders`): a program the default list does not know
        // is a holder; the file names it and it is none, as soon as the file is read (no new Lsof is asked); the file goes and it is one again
        root.step("gpu: btop is on the card (the default list knows it); the card sleeps, so nvidia-smi is not in this", function () { root.ctl("SetLsof", [root.lsofWith("btop")]); }, function () {
            return svc.gpu.holders.length === 0;
        }, 6000);
        root.step("gpu-btop-ignored: btop alone is no holder, by the default list", function () {
            root.check("gpu-btop-ignored", svc.gpu.holders.length === 0 && svc.caption.gpu.indexOf("in use by") < 0, j([svc.gpu.holders, svc.caption.gpu]));
            root.ctl("SetLsof", [root.lsofWith("blender")]);
        }, function () { return svc.gpu.holders.length === 1 && svc.gpu.holders[0] === "blender"; }, 6000);
        root.step("gpu: the shell's own nvidia-smi query is caught by the Lsof (it holds the card's nodes while it runs)", function () { root.ctl("SetLsof", [root.lsofWith("nvidia-smi")]); }, function () {
            return svc.gpu.holders.length === 0;
        }, 6000);
        root.pause(2600);
        root.step("gpu-own-smi-not-a-user: ... and it is no holder: it cannot keep its own gate open (the GPU bug's loop)", function () {
            root.check("gpu-own-smi-not-a-user", svc.gpu.holders.length === 0 && svc.caption.gpu.indexOf("in use by") < 0, j([svc.gpu.holders, svc.caption.gpu]));
            root.ctl("SetLsof", [root.lsofWith("blender")]);
        }, function () { return svc.gpu.holders.length === 1 && svc.gpu.holders[0] === "blender"; }, 6000);
        root.step("gpu: silicon.json lists blender among the ignored holders (a file read hot)", function () {
            root.putInPlace(root.cfgPath, '{ "gpu": { "ignoredHolders": ["cardwired", "nvidia-persiste", "hyprland", "xwayland", "xorg", "systemd", "systemd-logind", "Blender"] } }\n');
        }, function () { return svc.gpu.holders.length === 0; }, 6000);
        root.step("gpu-ignored-holders-config: ... and the card has no holder, no \"in use by\", no question for Integrated", function () {
            root.check("gpu-ignored-holders-config", svc.gpu.holders.length === 0 && svc.caption.gpu.indexOf("in use by") < 0
                       && Model.planGpuMode(0, {}, svc.gpu, svc.gpuModeTarget).action === "cardwire", j([svc.gpu.holders, svc.caption.gpu]));
            root.putInPlace(root.cfgPath, "{}\n");
        }, function () { return svc.gpu.holders.length === 1 && svc.gpu.holders[0] === "blender"; }, 6000);
        root.step("gpu: the file's list is gone: blender is a holder again; then it exits", function () {
            root.check("gpu-ignored-holders-undone", svc.gpu.holders.join() === "blender", j(svc.gpu.holders));
            root.ctl("SetLsof", [root.lsofWith("")]);
        }, function () { return svc.gpu.holders.length === 0; }, 6000);
        // the D-state from sysfs ALONE (no signal): a change of the file is an event too; first one
        // poll must have seen the file say D3cold (a change that no poll sees is no change)
        root.pause(1500);
        root.step("gpu: the power_state file says D0 and cardwire is silent (sysfs alone)", function () {
            p0 = root.evPower.length;
            root.put(root.tree + "/sys/bus/pci/devices/0000:01:00.0/power_state", "D0\n");
        }, function () {
            root.detail = j([svc.gpu.dState, root.evPower.slice(p0)]);
            return svc.gpu.dState === "D0" && j(root.evPower.slice(p0)) === '["D0"]';
        }, 6000);
        root.step("gpu: ... and D3cold again", function () { root.put(root.tree + "/sys/bus/pci/devices/0000:01:00.0/power_state", "D3cold\n"); }, function () { return svc.gpu.dState === "D3cold"; }, 6000);
        root.pause(2500);
        root.step("smi-only-with-holders: every query came while the dGPU had a user; they stopped with the user", function () {
            const calls = root.calls("nvidia-smi.log");
            const bad = calls.filter(function (c) {
                return root.keyAt(c.at - 400) !== "awake" && root.keyAt(c.at) !== "awake" && root.keyAt(c.at + 400) !== "awake";
            });
            root.check("smi-only-with-holders", calls.length >= 3 && bad.length === 0, j([calls.length + " calls", bad.map(function (c) { return c.at - root.t0; })]));
            const late = calls.filter(function (c) { return c.at > tEmpty + 1500; });
            root.check("smi-stops-with-the-last-user", late.length === 0, String(late.length) + " late call(s)");
            root.check("smi-arguments", calls.every(function (c) { return c.text === "--query-gpu=utilization.gpu,temperature.gpu,power.draw,memory.used,memory.total --format=csv,noheader,nounits"; }), calls.length > 0 ? calls[0].text : "");
            root.info("gpu-holder-trail " + j(root.holdTrail.map(function (t) { return [t.at - root.t0, t.key]; })));
        });
    }


    // ---- 9. silicon.jsonc: hot reload, warnings once each, the idle ladder ---------------------------------------------------------
    readonly property string cfgPath: root.xdgConfig + "/quickshell/silicon.json"

    function secConfig() {
        let n0 = 0, tTouch = 0, tCalm = 0, tHalt = 0;
        root.step("config: silicon.json is edited IN PLACE (a comment, good values, two bad ones, an older file's mux group)", function () {
            root.info("config-warnings 3");
            root.putInPlace(root.cfgPath, '// the probe\n{\n  "profiles": {\n    "quiet": { "epp": "balance_power" },   // quiet keeps balance_power\n    "balanced": { "pl1W": 9000, "maxPerfPct": 150 }\n  },\n  "overhead": { "wPerCpuSec": 1.5 },\n  "mux": { "guardWindowS": 60, "keepPromptS": 30 },\n  "look": { "family": "blueprint" }\n}\n');
        }, function () { return svc.config.look.family === "blueprint"; }, 6000);
        root.step("config-reload: the good values stand, the bad ones are ignored (one warning each)", function () {
            const c = svc.config;
            root.check("config-reload-values", c.profiles.quiet.epp === "balance_power" && c.overhead.wPerCpuSec === 1.5 && c.profiles.balanced.pl1W === null && c.profiles.balanced.maxPerfPct === null
                       && c.profiles.performance.epp === "performance", j([c.profiles.quiet.epp, c.overhead, c.profiles.balanced]));
            root.check("config-reload-no-mux", svc.config.mux === undefined && svc.gpu.mux.bootWindowS === 300 && svc.gpu.mux.promptWindowS === 120, j([svc.config.mux, svc.gpu.mux.bootWindowS, svc.gpu.mux.promptWindowS]));
            root.check("config-reload-warnings", svc.configWarnings.length === 3 && svc.configWarnings[0].indexOf("profiles.balanced.pl1W") === 0 && svc.configWarnings[1].indexOf("profiles.balanced.maxPerfPct") === 0 && svc.configWarnings[2].indexOf("mux: removed") === 0 && svc.configError === "", j(svc.configWarnings));
        });
        root.step("config: the reloaded values are live: the next switch to Quiet applies the NEW epp", function () {
            n0 = root.applies().length;
            root.check("config-live-switch", svc.stepProfile(-1) === true);
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "quiet"; }, 6000);
        root.step("config-live: the apply carries balance_power, not the seed's power", function () {
            root.check("config-live-write", root.applies()[n0].text === root.base("apply profile=quiet governor=powersave epp=balance_power turbo=0 max_perf_pct=100 pl1_w=firmware pl2_w=firmware"), root.applies()[n0].text);
            root.check("config-live-not-tweaked", svc.cpu.epp === "balance_power" && svc.cpu.tweaked === false, j([svc.cpu.epp, svc.cpu.tweaked]));
        });
        // the idle ladder, on short times (its constants, set on the service's ladder: alive -> calm after 1.5 s -> halt after 4 s)
        root.step("idle: the pointer goes still", function () {
            svc.idleLadder.calmAfterMs = 1500;
            svc.idleLadder.haltAfterMs = 4000;
            root.keepAlive = false;
            svc.touch();
            tTouch = Date.now();
            tCalm = 0;
            tHalt = 0;
        }, function () {
            if (tCalm === 0 && svc.idleState === "calm")
                tCalm = Date.now();
            if (tHalt === 0 && svc.idleState === "halt")
                tHalt = Date.now();
            return tHalt !== 0;
        }, 9000);
        root.step("idle-ladder: alive -> calm -> halt on the ladder's times", function () {
            root.check("idle-ladder-calm", tCalm - tTouch >= 1400 && tCalm - tTouch <= 2400, String(tCalm - tTouch) + " ms (calmAfterMs 1500)");
            root.check("idle-ladder-halt", tHalt - tTouch >= 3900 && tHalt - tTouch <= 5400, String(tHalt - tTouch) + " ms (haltAfterMs 4000)");
        });
        root.step("idle: a touch brings it back; closing the popup halts it; opening it wakes it", function () {
            svc.touch();
            root.check("idle-touch-wakes", svc.idleState === "alive", svc.idleState);
            svc.popupOpen = false;
            root.check("idle-closed-is-halt", svc.idleState === "halt", svc.idleState);
            svc.touch();
            // only a live popup touches, so a touch wins over the flag (IdleLadder: a flag left behind must not hold a popup still)
            root.check("idle-touch-wins-over-the-flag", svc.idleState === "alive", svc.idleState);
            svc.popupOpen = true;
            root.check("idle-open-is-alive", svc.idleState === "alive", svc.idleState);
            root.keepAlive = true;
            svc.idleLadder.calmAfterMs = 10000;
            svc.idleLadder.haltAfterMs = 30000;
        });
        // a file that does not parse keeps the last good config
        root.step("config: the file is broken mid-edit", function () {
            root.info("config-warnings 1");
            root.putInPlace(root.cfgPath, '{ "look": { "family": "material" ');
        }, function () { return svc.configError !== ""; }, 6000);
        root.step("config-broken: the last good config is kept, the error says where", function () {
            root.check("config-broken-kept", svc.config.look.family === "blueprint" && svc.config.profiles.quiet.epp === "balance_power" && svc.configError.indexOf("silicon.jsonc line") === 0 && svc.configError.indexOf("last good version is kept") > 0, svc.configError);
        });
        root.step("config: fixed (an empty object: every value its seed)", function () {
            root.putInPlace(root.cfgPath, '// fixed\n{}\n');
        }, function () { return svc.config.look.family === "material" && svc.configError === "" && svc.configWarnings.length === 0; }, 6000);
        root.step("config-fixed: the seeds are back", function () {
            root.check("config-fixed", svc.config.profiles.quiet.epp === "power" && svc.config.overhead.wPerCpuSec === 2, j([svc.config.profiles.quiet.epp, svc.config.overhead.wPerCpuSec]));
        });
        // an editor that saves by renaming a new file over the old one
        root.step("config: an editor replaces the file (write + rename)", function () {
            root.put(root.cfgPath, '{ "look": { "family": "blueprint" } }\n');
        }, function () { return svc.config.look.family === "blueprint"; }, 6000);
        root.step("config-rename: the replaced file is followed too", function () {
            root.check("config-rename-followed", svc.config.look.family === "blueprint" && svc.configWarnings.length === 0, svc.config.look.family);
            root.putInPlace(root.cfgPath, '{ "look": { "family": "eva" } }\n');
        }, function () { return svc.config.look.family === "material"; }, 6000);
        root.step("config-old-name: \"eva\" is the old spelling of material, read with no warning", function () {
            root.check("config-eva-is-material", svc.config.look.family === "material" && svc.configWarnings.length === 0 && svc.configError === "", j([svc.config.look, svc.configWarnings]));
            root.putInPlace(root.cfgPath, '{}\n');
        }, function () { return svc.config.look.family === "material"; }, 6000);
        // the quiet profile's switch again with the seeds back, so the next sections know what a profile writes
        root.step("config: back to the seeds; Quiet is re-applied by hand to reset the epp", function () {
            n0 = root.applies().length;
            svc.resetTuning();
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.epp === "power"; }, 6000);
    }

    // ---- 9b. silicon.jsonc onPower: the plug switches the profile, and a hold in the way keeps it for its end ----------------------
    function secOnPower() {
        let n0 = 0;
        root.step("onpower: the file names a profile for both", function () {
            n0 = root.applies().length;
            root.put(root.acOnline, "1\n");
            root.putInPlace(root.cfgPath, '{ "onPower": { "ac": "quiet", "battery": "balanced" }, "battery": { "lowAt": 30 }, "holds": { "systemUpdate": null }, "sounds": false }\n');
        }, function () { return svc.config.onPower.battery === "balanced" && svc.battery.ac === true; }, 6000);
        root.step("onpower: naming them switches nothing", function () {
            root.check("onpower-no-start", root.applies().length === n0 && svc.cpu.profile === "quiet", j([root.applies().length - n0, svc.cpu.profile]));
            root.check("onpower-config", svc.config.battery.lowAt === 30 && svc.config.holds.systemUpdate === null && svc.config.sounds === false && svc.configWarnings.length === 0, j(svc.configWarnings));
            root.put(root.acOnline, "0\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Discharging", pct: 90, powerUW: 15000000, energyUWh: 50000000 }));
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "balanced"; }, 6000);
        root.step("onpower: the charger out switches to its profile, with the linked values; a hold takes Performance", function () {
            root.check("onpower-battery", root.applies()[n0].text === root.base(root.linked.balanced), root.applies()[n0].text);
            PowerBus.hold("probe", "performance", "test");
        }, function () { return root.applies().length === n0 + 2 && svc.cpu.profile === "performance"; }, 6000);
        root.step("onpower: the charger in while it is held", function () {
            root.put(root.acOnline, "1\n");
            root.put(root.bat + "/uevent", root.uevent({ status: "Charging", pct: 91, powerUW: 30000000, energyUWh: 51000000 }));
        }, function () { return svc.battery.ac === true; }, 6000);
        root.step("onpower: the hold stands; released, the plug's profile is what comes back", function () {
            root.check("onpower-held", root.applies().length === n0 + 2 && svc.cpu.profile === "performance", j([root.applies().length - n0, svc.cpu.profile]));
            PowerBus.release("probe");
        }, function () { return root.applies().length === n0 + 3; }, 6000);
        root.step("onpower: back to no file", function () {
            root.check("onpower-rebase", root.applies()[n0 + 2].text === root.base(root.linked.quiet), root.applies()[n0 + 2].text);
            root.putInPlace(root.cfgPath, "{}\n");
        }, function () { return svc.config.onPower.battery === null && svc.cpu.profile === "quiet"; }, 6000);
    }

    // ---- 10. holds: PowerBus, the system update's marker, a manual change wins ----------------------------------------------------
    function secHolds() {
        let n0 = 0;
        root.step("hold: a module holds Performance (PowerBus.hold)", function () {
            n0 = root.applies().length;
            root.check("hold-accepted", PowerBus.hold("probe", "performance", "test") === true);
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "performance"; }, 6000);
        root.step("hold: the switch is the profile's linked values; the zone says who holds it", function () {
            root.check("hold-write", root.applies()[n0].text === root.base(root.linked.performance), root.applies()[n0].text);
            root.check("hold-facts", svc.cpu.heldBy === "probe" && svc.caption.cpu === "Performance · held by probe" && svc.profileTarget === 2 && PowerBus.heldProfile === "performance" && PowerBus.heldBy === "probe",
                       j([svc.cpu.heldBy, svc.caption.cpu]));
        });
        root.step("hold: released: the profile it left is put back", function () {
            n0 = root.applies().length;
            PowerBus.release("probe");
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "quiet"; }, 6000);
        root.step("hold-restore: back to Quiet, nothing held", function () {
            root.check("hold-restore", root.applies()[n0].text === root.base(root.linked.quiet) && svc.cpu.heldBy === "" && svc.caption.cpu === "Quiet", root.applies()[n0].text);
        });
        root.step("hold: held again", function () {
            n0 = root.applies().length;
            PowerBus.hold("probe", "performance", "test");
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "performance"; }, 6000);
        root.step("hold: the user steps down by hand: the hold is DROPPED, the user's choice stands, nothing is restored", function () {
            n0 = root.applies().length;
            root.check("hold-manual-step", svc.stepProfile(-1) === true);
            root.check("hold-manual-wins", Object.keys(PowerBus.holds).length === 0 && PowerBus.heldProfile === "" && PowerBus.heldBy === "", j(PowerBus.holds));
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "balanced" && svc.cpu.heldBy === ""; }, 6000);
        root.pause(1500);
        root.step("hold-manual-stays: balanced, one write, no restore", function () {
            root.check("hold-manual-stays", svc.cpu.profile === "balanced" && root.applies().length === n0 + 1 && svc.caption.cpu === "Balanced", j([svc.cpu.profile, root.applies().length - n0]));
        });
        // the system update: its own marker
        root.step("hold: a system update starts RUNNING (the supervisor's marker, its pid alive)", function () {
            n0 = root.applies().length;
            root.sh("mkdir -p '" + root.tree + "/proc/4242' && printf 'sh\\000/x/helpers/update-run.sh\\000/x/runs/run-A\\000yay -Syu\\000' > '" + root.tree + "/proc/4242/cmdline'");
            root.putInPlace(root.xdgState + "/lares/system-update/last-run.json", '{ "runId": "run-A", "runDir": "/x/runs/run-A", "command": "yay -Syu", "pid": 4242, "startedAt": 1, "state": "running" }\n');
        }, function () { return PowerBus.holds["system-update"] !== undefined && root.applies().length === n0 + 1 && svc.cpu.profile === "performance"; }, 9000);
        root.step("hold-update: Performance while it runs, the zone names it", function () {
            root.check("hold-update", PowerBus.holds["system-update"].profile === "performance" && svc.cpu.heldBy === "system-update" && svc.caption.cpu === "Performance · held by the system update", j([PowerBus.holds, svc.caption.cpu]));
        });
        root.step("hold: the update FINISHES (marker state: finished)", function () {
            n0 = root.applies().length;
            root.putInPlace(root.xdgState + "/lares/system-update/last-run.json", '{ "runId": "run-A", "runDir": "/x/runs/run-A", "command": "yay -Syu", "pid": 4242, "startedAt": 1, "state": "finished", "exit": 0, "endedAt": 2 }\n');
        }, function () { return PowerBus.holds["system-update"] === undefined && root.applies().length === n0 + 1 && svc.cpu.profile === "balanced"; }, 9000);
        root.step("hold-update-restore: released, and the profile it left is back", function () {
            root.check("hold-update-restore", svc.cpu.heldBy === "" && svc.caption.cpu === "Balanced", svc.caption.cpu);
        });
        root.step("hold: a STALE marker (running, but its supervisor is gone) holds nothing", function () {
            n0 = root.applies().length;
            root.putInPlace(root.xdgState + "/lares/system-update/last-run.json", '{ "runId": "run-B", "runDir": "/x/runs/run-B", "command": "yay -Syu", "pid": 4343, "startedAt": 3, "state": "running" }\n');
        }, function () { return true; });
        root.pause(2500);
        root.step("hold-stale-marker: no hold, no write", function () {
            root.check("hold-stale-marker", PowerBus.holds["system-update"] === undefined && root.applies().length === n0, j(PowerBus.holds));
        });
        root.step("hold: another update runs; the user takes the profile back; the hold is not taken again for that run", function () {
            n0 = root.applies().length;
            root.sh("printf 'sh\\000/x/helpers/update-run.sh\\000/x/runs/run-C\\000yay -Syu\\000' > '" + root.tree + "/proc/4242/cmdline'");
            root.putInPlace(root.xdgState + "/lares/system-update/last-run.json", '{ "runId": "run-C", "runDir": "/x/runs/run-C", "command": "yay -Syu", "pid": 4242, "startedAt": 5, "state": "running" }\n');
        }, function () { return PowerBus.holds["system-update"] !== undefined && svc.cpu.profile === "performance" && root.applies().length === n0 + 1; }, 9000);
        root.step("hold: the manual step down", function () {
            n0 = root.applies().length;
            svc.stepProfile(-1);
        }, function () { return root.applies().length === n0 + 1 && svc.cpu.profile === "balanced"; }, 6000);
        root.step("hold: the marker is rewritten (still running): the latch holds", function () {
            root.putInPlace(root.xdgState + "/lares/system-update/last-run.json", '{ "runId": "run-C", "runDir": "/x/runs/run-C", "command": "yay -Syu", "pid": 4242, "startedAt": 6, "state": "running" }\n');
        }, function () { return true; });
        root.pause(2500);
        root.step("hold-manual-latch: not held again, nothing written", function () {
            root.check("hold-manual-latch", Object.keys(PowerBus.holds).length === 0 && svc.cpu.profile === "balanced" && root.applies().length === n0 + 1, j([PowerBus.holds, root.applies().length - n0]));
            root.putInPlace(root.xdgState + "/lares/system-update/last-run.json", '{ "runId": "run-C", "runDir": "/x/runs/run-C", "command": "yay -Syu", "pid": 4242, "startedAt": 5, "state": "finished", "exit": 0 }\n');
        });
    }

    // ---- 11. resume: refresh everything, re-apply nothing unless the firmware changed something -----------------------------------------
    function secResume() {
        let n0 = 0, o0 = 0, m0 = 0, l0 = 0, a0 = 0;
        function availCalls() { return root.calls("busctl.log").filter(function (c) { return c.text.indexOf("AvailableModes") >= 0; }).length; }
        function limitWrites() { return root.writes().filter(function (c) { return c.text.indexOf(" set-charge-limit") >= 0; }).length; }
        const sleepLine = function (on) { return "/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (" + on + ",)\n"; };
        function modeReads() { return root.calls("busctl.log").filter(function (c) { return c.text.indexOf("get-property") >= 0 && c.text.indexOf("Mode Mode") > 0; }).length; }
        root.step("resume: the charge limit is on (80 %), as the user left it", function () {
            l0 = limitWrites();
            root.check("resume-limit-on", svc.setChargeLimit(true) === true);
        }, function () { return svc.battery.limitPct === 80 && limitWrites() === l0 + 1 && svc.chargeLimitTarget === 80; }, 6000);
        root.pause(500);
        root.step("resume: the lid is closed (the popup is closed, the status poll slows to 10 s)", function () { svc.popupOpen = false; }, function () { return svc.idleState === "halt"; });
        root.pause(500);
        let u0 = 0;
        root.step("resume: a suspend and a resume, nothing changed (UPower is not running now)", function () {
            root.upMode("notrunning");
            u0 = root.upCalls("BAT0").length;
            n0 = root.applies().length;
            l0 = limitWrites();
            m0 = modeReads();
            Sleep.watcher.feed(sleepLine(true));
            Sleep.watcher.feed(sleepLine(false));
        }, function () { return modeReads() > m0; }, 6000);
        root.pause(2500);
        root.step("resume-refresh: cardwire was read again; resume-nothing: nothing was re-applied", function () {
            root.check("resume-refresh", modeReads() > m0, String(modeReads() - m0));
            root.check("resume-nothing", root.applies().length === n0 && limitWrites() === l0 && svc.cpu.profile === "balanced" && svc.cpu.tweaked === false, j([root.applies().length - n0, limitWrites() - l0, svc.cpu.profile]));
            root.check("resume-upower", root.upCalls("BAT0").length > u0 && svc.battery.upowerWhy === "UPower is not running (The name is not activatable)" && svc.battery.lastFullSource === "own",
                       j([root.upCalls("BAT0").length - u0, svc.battery.upowerWhy, svc.battery.lastFullSource]));
            root.upMode("ok");
        });
        // the firmware resets the profile and the EPP during the suspend
        root.step("resume: the firmware resets the profile, the EPP and the charge limit while the machine sleeps", function () {
            n0 = root.applies().length;
            l0 = limitWrites();
            o0 = root.evOsd.length;
            Sleep.watcher.feed(sleepLine(true));
            root.ops++;
            stim.run(["sh", "-c", "printf '100\\n' > '" + root.limitFile + "'; printf 'quiet\\n' > '" + root.profileFile + "'; printf 'quiet\\n' > '" + root.profileClassFile + "'; for f in '" + root.polDir + "'/policy*/energy_performance_preference; do echo power > \"$f\"; done"], function () {
                root.ops--;
                Sleep.watcher.feed(sleepLine(false));
            });
        }, function () { return root.applies().length === n0 + 1 && limitWrites() === l0 + 1 && svc.cpu.profile === "balanced" && svc.cpu.epp === "balance_power" && svc.battery.limitPct === 80; }, 9000);
        root.step("resume-reapply: exactly the knobs the firmware moved are put back; not shown as an external change", function () {
            root.check("resume-reapply", root.applies()[n0].text === root.base("apply profile=balanced epp=balance_power"), root.applies()[n0].text);
            root.check("resume-limit-reapplied", root.writes().filter(function (c) { return c.text.indexOf(" set-charge-limit") >= 0; })[l0].text === root.base("set-charge-limit 80") && svc.chargeLimitTarget === 80, String(svc.chargeLimitTarget));
            root.check("resume-not-external", root.evOsd.length === o0 && svc.cpu.tweaked === false && svc.profileTarget === 1, j([root.evOsd.length - o0, svc.cpu.tweaked]));
        });
        root.step("resume: the lid opens (the popup opens)", function () {
            a0 = availCalls();
            m0 = modeReads();
            svc.popupOpen = true;
        }, function () { return svc.idleState === "alive" && modeReads() > m0; }, 6000);
        root.pause(800);
        root.step("popup-open-light: the card's mode was read again; the full chain (modes, config, devices) was not", function () {
            root.check("popup-open-light", modeReads() > m0 && availCalls() === a0, j([modeReads() - m0, availCalls() - a0]));
        });
    }

    // ---- 12. the MUX -------------------------------------------------------------------------------------------------------------------
    function secMux() {
        let n0 = 0, s0 = 0, r0 = 0, o0 = 0;
        root.step("mux: dGPU-only is requested (nothing is written to the firmware: a restart applies it)", function () {
            n0 = root.writes().length;
            o0 = root.evOsd.length;
            root.check("mux-accepted", svc.muxRequest("dgpu") === true && svc.gpuModeTarget === 3);
        }, function () { return svc.gpu.mux.state === "queued"; }, 6000);
        root.step("mux-queued: one helper call, the request is pending, the scene's target holds at dGPU-only", function () {
            root.check("mux-request-write", root.writes().length === n0 + 1 && root.writes()[n0].text === root.base("mux-request dgpu"), j(root.writes().slice(n0).map(function (x) { return x.text; })));
            root.check("mux-pending", svc.gpu.mux.pending === true && svc.gpu.mux.want === "dgpu" && svc.gpu.mux.from === "hybrid" && svc.gpuModeTarget === 3 && svc.gpuMode === 2, j(svc.gpu.mux));
            root.check("mux-caption", svc.caption.gpu === "Hybrid · dGPU asleep · dGPU only after the next restart", svc.caption.gpu);
            root.check("mux-no-osd", root.evOsd.length === o0, String(root.evOsd.length - o0));
        });
        root.step("mux: the user clicks 'restart now'", function () {
            s0 = root.calls("systemctl.log").length;
            root.check("mux-reboot-accepted", svc.muxRebootNow() === true);
        }, function () { return root.calls("systemctl.log").length === s0 + 1; }, 6000);
        root.step("mux-reboot: systemctl was asked to reboot, once (the stub: nothing restarted)", function () {
            root.check("mux-reboot", root.calls("systemctl.log")[s0].text === "reboot", root.calls("systemctl.log")[s0].text);
        });
        root.step("mux: ... and changes their mind: cancelled", function () {
            n0 = root.writes().length;
            svc.muxCancel();
        }, function () { return svc.gpu.mux.state === "cancelled"; }, 6000);
        root.step("mux-cancelled: not pending, the target is back to where the GPU is", function () {
            root.check("mux-cancel-write", root.writes()[n0].text === root.base("mux-cancel"), root.writes()[n0].text);
            root.check("mux-cancelled", svc.gpu.mux.pending === false && svc.gpuModeTarget === 2 && svc.caption.gpu === "Hybrid · dGPU asleep", j([svc.gpu.mux.pending, svc.gpuModeTarget, svc.caption.gpu]));
        });
        root.step("mux: nothing is waiting for a restart: 'restart now' is refused and runs nothing", function () {
            s0 = root.calls("systemctl.log").length;
            r0 = root.evRefused.length;
            root.check("mux-reboot-refused", svc.muxRebootNow() === false && root.evRefused.length === r0 + 1 && root.evRefused[r0].zone === "mux" && root.calls("systemctl.log").length === s0, j(root.evRefused.slice(r0)));
        });
        root.step("mux: the cancelled request's outcome has not been seen; the user sees it", function () {
            root.check("mux-outcome-unseen", svc.gpu.mux.outcomeSeen === false && svc.gpu.mux.state === "cancelled", j(svc.gpu.mux));
            svc.markMuxOutcomeSeen();
        }, function () { return svc.gpu.mux.outcomeSeen === true; });
        // A step away from a QUEUED dGPU-only request withdraws it (cancel first, on the helper's answer), then goes through cardwire.
        let c0 = 0, b0 = 0;
        root.step("mux-away: dGPU-only is queued again", function () {
            n0 = root.writes().length;
            svc.muxRequest("dgpu");
        }, function () { return svc.gpu.mux.state === "queued"; }, 6000);
        root.step("mux-away: a step to Hybrid is asked", function () {
            n0 = root.writes().length;
            o0 = root.evOsd.length;
            b0 = root.calls("busctl.log").length;
            root.check("mux-away-accepted", svc.setGpuMode(2, {}) === true && svc.gpuModeTarget === 2, String(svc.gpuModeTarget));
        }, function () { return svc.gpu.mux.state === "cancelled"; }, 6000);
        root.pause(1500);
        root.step("mux-away-hybrid: cancel sent, the request is gone, the target stays on the step (no snap back to dGPU only), one OSD says so", function () {
            const w = root.writes().slice(n0).map(function (x) { return x.text; });
            root.check("mux-away-cancel", w.length === 1 && w[0] === root.base("mux-cancel"), j(w));
            root.check("mux-away-not-pending", svc.gpu.mux.pending === false && svc.gpuModeTarget === 2 && svc.gpuMode === 2, j([svc.gpu.mux.pending, svc.gpuModeTarget, svc.gpuMode]));
            root.check("mux-away-no-snapback", svc.gpuModeTarget !== 3, String(svc.gpuModeTarget));
            root.check("mux-away-osd", root.evOsd.length === o0 + 1 && root.evOsd[o0].detail === "dGPU-only switch cancelled", j(root.evOsd.slice(o0)));
        });
        root.step("mux-away: dGPU-only is queued once more, then Integrated is asked (apps confirmed)", function () {
            svc.muxRequest("dgpu");
        }, function () { return svc.gpu.mux.state === "queued"; }, 6000);
        root.step("mux-away: Integrated", function () {
            n0 = root.writes().length;
            b0 = root.calls("busctl.log").length;
            c0 = cardwireSets(0);
            root.check("mux-away-int-accepted", svc.setGpuMode(0, { confirmHolders: true }) === true && svc.gpuModeTarget === 0, String(svc.gpuModeTarget));
        }, function () { return cardwireSets(0) === c0 + 1; }, 9000);
        root.pause(1200);
        root.step("mux-away-integrated: the cancel went through pkexec BEFORE cardwire's Mode was set, the target follows", function () {
            const cancel = root.calls("pkexec.log").slice().reverse().filter(function (c) { return c.text.indexOf(" mux-cancel") >= 0; })[0];
            const set = root.calls("busctl.log").filter(function (c) { return /set-property .*\.Mode Mode u 0$/.test(c.text); }).slice(-1)[0];
            root.check("mux-away-order", !!cancel && !!set && cancel.at <= set.at, j([cancel, set]));
            root.check("mux-away-int-state", svc.gpu.mux.pending === false && svc.gpuModeTarget === 0 && svc.gpu.mode === 0, j([svc.gpu.mux.pending, svc.gpuModeTarget, svc.gpu.mode]));
        });
        root.step("mux-away: back to Hybrid (the machine as it was)", function () {
            svc.setGpuMode(2, {});
        }, function () { return svc.gpu.mode === 1 && svc.gpuModeTarget === 2; }, 9000);
        root.step("mux-away: an APPLIED request (written at shutdown already) is refused with a plain reason, by the plan", function () {
            const g = JSON.parse(JSON.stringify(svc.gpu));
            g.mux.pending = true; g.mux.state = "applied"; g.mux.want = "dgpu"; g.wiring = "hybrid";
            const p = Model.planGpuMode(2, {}, g, 3);
            root.check("mux-away-applied-refused", p.action === "refuse" && p.why.indexOf("already written") >= 0, j(p));
            g.mux.state = "queued";
            root.check("mux-away-queued-plan", Model.planGpuMode(2, {}, g, 3).action === "cancelmux", j(Model.planGpuMode(2, {}, g, 3)));
        });
        // the restart: the host's argv (the session saved first) when it has one, the bare systemctl reboot otherwise
        root.step("mux-argv: dGPU-only is queued; the host gives the restart its own argv", function () {
            svc.muxRequest("dgpu");
        }, function () { return svc.gpu.mux.state === "queued"; }, 6000);
        root.step("mux-argv: restart now runs that argv and not systemctl", function () {
            s0 = root.calls("systemctl.log").length;
            svc.rebootArgv = ["sh", "-c", "printf '%s\\n' \"$*\" >> '" + root.logs + "/rebootargv.log'", "sh", "lares-session", "end", "reboot"];
            root.check("mux-argv-accepted", svc.muxRebootNow() === true);
        }, function () { return root.logLines("rebootargv.log").length === 1; }, 6000);
        root.step("mux-argv: the argv ran once with its words, systemctl was not asked; then the property is cleared and the request withdrawn", function () {
            root.check("mux-argv", root.logLines("rebootargv.log")[0] === "lares-session end reboot" && root.calls("systemctl.log").length === s0, j([root.logLines("rebootargv.log"), root.calls("systemctl.log").length - s0]));
            svc.rebootArgv = null;
            svc.muxCancel();
        }, function () { return svc.gpu.mux.state === "cancelled"; }, 6000);
        // the pre-check: nvidia built for EVERY installed kernel; one has no module. What only the helper's status reports (the
        // pre-checks, the firmware's MUX, the unit) is read at an opening, a resume or the minute's backstop -- no longer every
        // 2 s (the status reads the MUX through the ASUS firmware, into the EC): each change below asks as a resume does.
        root.step("mux: a kernel loses its nvidia module (the pre-check's second condition)", function () {
            root.sh("rm -f '" + root.tree + "/usr/lib/modules/7.2.7-arch1-1/updates/dkms/nvidia.ko.zst'");
            root.refreshAfter();
        }, function () { return svc.gpu.mux.prechecks.ok === false; }, 6000);
        root.step("mux-precheck-status: the facts say which kernel", function () {
            root.check("mux-precheck-status", svc.gpu.mux.prechecks.why.indexOf("7.2.7") >= 0, j(svc.gpu.mux.prechecks));
        });
        root.step("mux: a request is refused with the pre-check's words, and the target goes back", function () {
            r0 = root.evRefused.length;
            n0 = root.writes().length;
            root.check("mux-precheck-aim", svc.muxRequest("dgpu") === true && svc.gpuModeTarget === 3);
        }, function () { return root.evRefused.length === r0 + 1; }, 6000);
        root.step("mux-precheck: refused naming the kernel, the reason in the GPU caption, nothing queued", function () {
            root.check("mux-precheck", root.evRefused[r0].zone === "mux" && root.evRefused[r0].why.indexOf("7.2.7") >= 0 && svc.gpuModeTarget === 2 && svc.caption.gpuError === root.evRefused[r0].why && svc.gpu.mux.pending === false,
                       j([root.evRefused[r0], svc.gpuModeTarget, svc.caption.gpuError]));
            root.sh("printf '' > '" + root.tree + "/usr/lib/modules/7.2.7-arch1-1/updates/dkms/nvidia.ko.zst'");
            root.refreshAfter();
        }, function () { return svc.gpu.mux.prechecks.ok === true; }, 6000);
        // silicon-mux.service not running: nothing queued now would ever be written, so NO new request is taken, either way
        root.step("mux: silicon-mux.service stops (systemd removes the link of an active unit)", function () { root.muxUnit(false); root.refreshAfter(); }, function () { return svc.gpu.mux.prechecks.ok === false; }, 9000);
        root.step("mux-unit-status: the pre-check names the unit, in the helper's words", function () {
            root.check("mux-unit-status", svc.gpu.mux.prechecks.why.indexOf("silicon-mux.service is not active") === 0, j(svc.gpu.mux.prechecks));
        });
        root.step("mux: a dGPU request is refused with those words", function () {
            r0 = root.evRefused.length;
            root.check("mux-unit-aim", svc.muxRequest("dgpu") === true && svc.gpuModeTarget === 3);
        }, function () { return root.evRefused.length === r0 + 1; }, 9000);
        root.step("mux-unit-refused: the words are the GPU caption's error, the scene is back, nothing queued", function () {
            root.check("mux-unit-refused", root.evRefused[r0].zone === "mux" && root.evRefused[r0].why.indexOf("silicon-mux.service is not active") === 0 && svc.gpuModeTarget === 2 && svc.caption.gpuError === root.evRefused[r0].why && svc.gpu.mux.pending === false,
                       j([root.evRefused[r0], svc.gpuModeTarget, svc.caption.gpuError]));
        });
        root.step("mux: the panel is on the NVIDIA card (the firmware says dGPU only)", function () { root.wiring("dgpu"); root.refreshAfter(); }, function () { return svc.gpu.wiring === "dgpu" && svc.gpu.step === 3; }, 9000);
        root.step("mux: ... and the way back is asked for", function () {
            r0 = root.evRefused.length;
            root.check("mux-unit-wayback-aim", svc.stepGpuMode(-1) === true && svc.gpuModeTarget === 2);
        }, function () { return root.evRefused.length === r0 + 1; }, 9000);
        root.step("mux-unit-wayback-refused: the other direction is refused with the same words; the scene stays on dGPU only", function () {
            root.check("mux-unit-wayback-refused", root.evRefused[r0].zone === "mux" && root.evRefused[r0].why.indexOf("silicon-mux.service is not active") === 0 && svc.gpuModeTarget === 3 && svc.caption.gpuError === root.evRefused[r0].why && svc.gpu.mux.pending === false,
                       j([root.evRefused[r0], svc.gpuModeTarget]));
        });
        root.step("mux: the unit is back and the panel is on the Intel card again: the machine is as it was", function () { root.muxUnit(true); root.wiring("hybrid"); root.refreshAfter(); },
                  function () { return svc.gpu.mux.prechecks.ok === true && svc.gpu.wiring === "hybrid" && svc.gpu.step === 2; }, 9000);
    }

    // ---- 13. what was learned is remembered ------------------------------------------------------------------------------------------------
    FileView {
        id: stateView
        path: root.xdgState + "/lares/silicon/state.json"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    function secEnd() {
        root.pause(800);
        root.step("state: the state file holds the last full charge and the ignored app", function () {
            stateView.reload();
            let st = null;
            try { st = JSON.parse(stateView.text()); } catch (e) { st = null; }
            root.check("state-file", st !== null && st.version === 1 && st.lastFullMs >= root.t0 && st.lastFullMs === svc.battery.lastFullMs && j(st.ignoredApps) === '["org.blender.Blender","kitty"]' && st.muxOutcomeSeenAt > 0, stateView.text());
        });
        root.step("end: the machine ended where the probe left it (nothing stuck pending)", function () {
            root.check("end-no-pending-error", svc.caption.cpuError === "" || svc.caption.cpuError.length > 0, "");
            root.check("end-profile", svc.cpu.profile === "balanced" && svc.profileTarget === 1, j([svc.cpu.profile, svc.profileTarget]));
            root.info("done: " + root.writes().length + " writes through pkexec, " + root.calls("nvidia-smi.log").length + " nvidia-smi calls, " + root.calls("notify-send.log").length + " notifications");
        });
    }

    // ======================================================================================
    // the MUX end to end (phase mux): the service against the REAL helper in test mode, with the machine
    // going down and coming back between the steps
    // ======================================================================================
    readonly property string firmwareFile: root.tree + "/sys/devices/platform/asus-nb-wmi/gpu_mux_mode"
    readonly property string modulesFile: root.tree + "/proc/modules"
    readonly property string bootIdFile: root.tree + "/proc/sys/kernel/random/boot_id"
    readonly property string uptimeFile: root.tree + "/proc/uptime"
    readonly property string recFile: root.fx + "/state/mux.json"
    readonly property string stateFile: root.xdgState + "/lares/silicon/state.json"
    readonly property string holderDir: root.tree + "/proc/777"
    readonly property string edpNvidia: root.tree + "/sys/class/drm/card0-eDP-2/status"
    readonly property string edpIntel: root.tree + "/sys/class/drm/card1-eDP-1/status"
    // One id per boot of the story (the helper tells a boot from the one before by this alone).
    readonly property var bootIds: ["b1000000-0000-4000-8000-000000000001", "b2000000-0000-4000-8000-000000000002", "b3000000-0000-4000-8000-000000000003",
                                    "b4000000-0000-4000-8000-000000000004", "b5000000-0000-4000-8000-000000000005", "b6000000-0000-4000-8000-000000000006",
                                    "b7000000-0000-4000-8000-000000000007"]
    property string dgpuCard: "/dev/dri/card0"
    property var unitRes: null
    property var notices: []

    // The shell, started and restarted with the machine (a real shell dies at the shutdown and starts again at login).
    Component {
        id: shellC
        SiliconService {
            bootFile: root.bootJsonFile
            configPath: root.xdgConfig + "/quickshell/silicon.json"
            statePath: root.xdgState + "/lares/silicon/state.json"
            persist: true
            oldLastFullPath: root.out + "/none/last-full"
            updateMarkerPath: root.xdgState + "/lares/system-update/last-run.json"
            helperStatusCommand: root.statusCmd
            helperWriteCommand: root.writeCmd
            cardwireBus: "session"
            cardwireEnabled: true
            procRoot: root.tree + "/proc"
            defaultPaths: ({ battery: root.tree + "/sys/class/power_supply/BAT0", ac: root.tree + "/sys/class/power_supply/AC0" })
            drmRoot: root.tree + "/sys/class/drm"
            usbRoot: root.tree + "/sys/bus/usb/devices"
            evdiModule: root.tree + "/sys/module/evdi"
            helperTimeoutMs: 8000
            popupOpen: true
            holdSystemUpdate: false
            upowerEnabled: false
        }
    }
    Loader {
        id: shellL
        active: false
        sourceComponent: shellC
    }
    // What the current shell says about a write it could not make (each shell is a new target).
    property var muxRefused: []
    Connections {
        target: shellL.item
        ignoreUnknownSignals: true
        function onWriteRefused(zone, why) { root.muxRefused = root.muxRefused.concat([{ zone: zone, why: why }]); }
    }
    function theShell() { return shellL.item; }
    function startShell() {
        root.instances++;
        shellL.active = true;
    }

    // A file, read as it is now (one FileView per path: a FileView is never repointed).
    property var _fileViews: ({})
    function fileText(path) {
        let v = root._fileViews[path];
        if (!v) {
            v = viewComp.createObject(root, { path: path });
            root._fileViews[path] = v;
        }
        v.reload();
        return v.text();
    }
    function rec() {
        try { return JSON.parse(root.fileText(root.recFile)); } catch (e) { return null; }
    }
    function firmware() { return root.fileText(root.firmwareFile).trim(); }
    function unitJson() {
        const lines = String(root.unitRes ? root.unitRes.out : "").split("\n").filter(function (l) { return l.trim() !== ""; });
        try { return JSON.parse(lines[lines.length - 1]); } catch (e) { return null; }
    }
    function rebootAsks() { return root.logLines("REBOOT_REQUESTED").length; }
    // the shell's state file, as it is now (null when it is not there yet)
    function stateJson() {
        try { return JSON.parse(root.fileText(root.stateFile)); } catch (e) { return null; }
    }
    // how many MUX requests went through pkexec, and how many times cardwire's Mode was SET to `mode` (the stub's busctl log)
    function muxRequests() { return root.calls("pkexec.log").filter(function (c) { return / mux-request /.test(c.text + " "); }).length; }
    function cardwireSets(mode) {
        return root.calls("busctl.log").filter(function (c) { return /set-property .*\.Mode Mode u (\d+)/.test(c.text) && new RegExp("\\.Mode Mode u " + mode + "$").test(c.text); }).length;
    }

    // The NVIDIA stack: down (the three modules free, nobody on the card) or up (a module held from outside, and the
    // compositor on the card -- what a dGPU-only boot leaves behind).
    function stack(up) {
        root.put(root.modulesFile, "nvidia_drm 1000 " + (up ? 2 : 0) + " - Live 0x0000000000000000\nnvidia_modeset 1000 1 nvidia_drm, Live 0x0000000000000000\n"
                 + "nvidia 1000 1 nvidia_modeset, Live 0x0000000000000000\n");
        if (up)
            root.sh("mkdir -p '" + root.holderDir + "/fd' && printf Hyprland > '" + root.holderDir + "/comm' && ln -sfn '" + root.dgpuCard + "' '" + root.holderDir + "/fd/9'");
        else
            root.sh("rm -rf '" + root.holderDir + "'");
    }
    function uptime(secs) { root.put(root.uptimeFile, secs + " 100.00\n"); }
    // The machine boots: a new boot id, time since boot, and the panel wired as the FIRMWARE says (gpu_mux_mode: 1 hybrid,
    // 0 dGPU only) -- which is the whole point of the switch.
    function boot(n, secs) {
        root.put(root.bootIdFile, root.bootIds[n] + "\n");
        root.uptime(secs);
        root.sh("if [ \"$(tr -d '\\n ' < '" + root.firmwareFile + "')\" = 0 ]; then n=connected; i=disconnected; else n=disconnected; i=connected; fi; "
                + "printf '%s\\n' $n > '" + root.edpNvidia + "'; printf '%s\\n' $i > '" + root.edpIntel + "'");
    }
    // The machine goes down: the shell is gone, and the shutdown unit (silicon-mux.service's ExecStop) runs.
    function shutdown() {
        shellL.active = false;
        root.unitRes = null;
        root.ops++;
        stim.run(["silicon-unit", "mux-apply", root.helperBin].concat(root.helperFlags), function (res) {
            root.ops--;
            root.unitRes = res;
        });
    }

    // The boot guard (silicon-mux-guard.service): it stays while a keep is awaited, so it is a Process of its own.
    Process {
        id: guardP
        property bool alive: false
        property int code: -2
        property string out: ""
        stdout: StdioCollector { onStreamFinished: guardP.out = this.text }
    }
    Connections {
        target: guardP
        function onExited(code, status) {
            guardP.alive = false;
            guardP.code = code;
        }
    }
    function startGuard() {
        guardP.alive = true;
        guardP.code = -2;
        guardP.out = "";
        guardP.command = ["silicon-unit", "mux-guard", root.helperBin].concat(root.helperFlags);
        guardP.running = true;
    }

    // What the shell's watcher does with the facts (SiliconMuxWatcher is stream W3's; this is the rule it needs, and all the
    // data layer has to make possible): a revert that is not yet seen is told ONCE and marked seen. A shell that WATCHED the
    // record go from awaiting a keep to reverted is about to be restarted by the guard's reboot -- telling it would flash a
    // notice on a screen that is going away and use up the mark -- so only a shell that STARTS with the record already
    // reverted tells. A latch per shell stops the same shell telling twice while its facts catch up; across shells only the
    // persisted mark can silence it.
    property int _toldIn: -1
    property int _sawKeepIn: -1
    Timer {
        interval: 120
        repeat: true
        running: root.phase === "mux" && shellL.active
        onTriggered: {
            const s = shellL.item;
            if (!s || root._toldIn === root.instances)
                return;
            const m = s.gpu.mux;
            if (m.state === "awaiting-keep")
                root._sawKeepIn = root.instances;
            if (m.state === "reverted" && m.outcomeSeen === false && root._sawKeepIn !== root.instances) {
                root._toldIn = root.instances;
                root.notices = root.notices.concat([{ shell: root.instances, why: m.why }]);
                s.markMuxOutcomeSeen();
            }
        }
    }
    // The status is polled every 2 s; a step that has just changed the machine does not wait for it.
    Timer {
        interval: 400
        repeat: true
        running: root.phase === "mux" && shellL.active
        onTriggered: if (shellL.item) shellL.item.refresh()
    }

    function buildMux() {
        let n0 = 0, n0r = 0, n1 = 0;
        const A = function () { return root.theShell(); };
        const up = function (c) { return function () { const s = A(); return !!s && c(s); }; };

        // ---- 1. the machine, and the shell on it ----
        root.step("mux: the fake machine -- boot 1, up for 400 s, the NVIDIA stack down, nobody on the card", function () {
            root.put(root.bootIdFile, root.bootIds[0] + "\n");
            root.uptime("400.00");
            root.stack(false);
            root.ops++;
            stim.run(root.statusCmd.concat(["status"]), function (res) {
                root.ops--;
                try {
                    const d = JSON.parse(res.out).status.paths.dgpu;
                    if (d && typeof d.card === "string")
                        root.dgpuCard = d.card;
                    // The machine as it really is with the card asleep: the SESSION (Hyprland, Xwayland, Xorg, systemd, systemd-logind) holds the
                    // card's own nodes all the time (R5 W1). The mode wanted after a way back from dGPU-only is set at the next login, with all of
                    // them there -- the holders rule used to refuse it ("Apps are using the dGPU (Hyprland, ...)") and the laptop stayed on Hybrid.
                    root.nodes = [d.card, d.render, d.nvidia].filter(function (x) { return typeof x === "string"; });
                    root.ctl("SetLsof", [root.lsofWith("")]);
                } catch (e) {
                }
            });
        }, function () { return true; });
        root.step("mux: the shell starts (the helper is the real one, in test mode)", function () { root.startShell(); },
                  up(function (s) { return s.helper.ok && s.gpu.present && s.gpu.steps.length > 0; }), 25000);
        root.step("mux-start-facts: nothing queued, the MUX is there, wiring is hybrid, four steps, this boot's id is a fact", function () {
            const g = A().gpu;
            root.check("mux-start-facts", g.mux.available === true && g.mux.state === "" && g.mux.prechecks.ok === true && g.wiring === "hybrid" && j(g.steps) === "[0,1,2,3]" && g.mux.bootId === root.bootIds[0], j([g.mux, g.wiring, g.steps, root.bootIds[0]]));
        });

        // ---- 1b. silicon-mux.service is not running: nothing queued now would ever be written, so no request is taken ----
        root.step("mux: silicon-mux.service stops", function () { root.muxUnit(false); }, up(function (s) { return s.gpu.mux.prechecks.ok === false; }), 15000);
        root.step("mux: a dGPU request is made while it is down", function () {
            n0 = root.muxRefused.length;
            root.check("mux-unit-precheck", /^silicon-mux\.service is not active/.test(A().gpu.mux.prechecks.why), j(A().gpu.mux.prechecks));
            root.check("mux-unit-aim", A().muxRequest("dgpu") === true && A().gpuModeTarget === 3);
        }, function () { return root.muxRefused.length === n0 + 1; }, 15000);
        root.step("mux-unit-refused-dgpu: refused with the unit's words (the GPU caption), the scene is back, no record was made", function () {
            const s = A(), f = root.muxRefused[n0];
            root.check("mux-unit-refused-dgpu", f.zone === "mux" && /^silicon-mux\.service is not active/.test(f.why) && s.caption.gpuError === f.why && s.gpuModeTarget === 2 && s.gpu.mux.state === "" && root.rec() === null, j([f, s.gpuModeTarget, s.gpu.mux.state, root.rec()]));
        });
        root.step("mux: silicon-mux.service is up again", function () { root.muxUnit(true); }, up(function (s) { return s.gpu.mux.prechecks.ok === true; }), 15000);

        // ---- 2. dGPU only is requested and waits for a restart ----
        root.step("mux: dGPU only is requested", function () { root.check("mux-accepted", A().muxRequest("dgpu") === true); },
                  up(function (s) { return s.gpu.mux.state === "queued"; }), 15000);
        root.step("mux-queued: the record is queued, the firmware is NOT written, the scene aims at dGPU only and stays on Hybrid until the restart", function () {
            const r = root.rec(), s = A();
            root.check("mux-queued-record", !!r && r.state === "queued" && r.want === "dgpu" && r.from === "hybrid" && r.bootId === root.bootIds[0], j(r));
            root.check("mux-queued-nothing-written", root.firmware() === "1", root.firmware());
            root.check("mux-queued-facts", s.gpu.mux.pending === true && s.gpu.mux.want === "dgpu" && s.gpuModeTarget === 3 && s.gpuMode === 2 && s.caption.gpu.indexOf("dGPU only after the next restart") >= 0, j([s.gpu.mux, s.gpuModeTarget, s.gpuMode, s.caption.gpu]));
        });

        // ---- 3. "Restart now": a marker stands for the restart, then the machine goes down and writes the firmware ----
        root.step("mux: the user clicks 'Restart now'", function () {
            n0 = root.rebootAsks();
            root.check("mux-restart-accepted", A().muxRebootNow() === true);
        }, function () { return root.rebootAsks() === n0 + 1; }, 15000);
        root.step("mux-restart: one restart asked for; the request alone changed nothing on the machine", function () {
            root.check("mux-restart-once", root.rebootAsks() === n0 + 1, String(root.rebootAsks() - n0));
            root.check("mux-restart-writes-nothing", root.rec().state === "queued" && root.firmware() === "1", j([root.rec().state, root.firmware()]));
        });
        root.step("mux: the machine goes down (the shell with it); the shutdown unit writes the firmware, the NVIDIA stack down", function () { root.shutdown(); },
                  function () { return root.unitRes !== null; }, 20000);
        root.step("mux-shutdown: written at shutdown, read back, the record says applied", function () {
            const o = root.unitJson();
            root.check("mux-shutdown-written", root.unitRes.code === 0 && !!o && o.ok === true && root.rec().state === "applied" && root.firmware() === "0", j([root.unitRes.code, root.rec().state, root.firmware(), root.unitRes.err.slice(0, 120)]));
        });

        // ---- 4. the next boot: the panel is on the NVIDIA card, the guard waits for a keep ----
        root.step("mux: the machine boots (a new boot id, the panel wired to the NVIDIA card)", function () { root.boot(1, "5.00"); }, function () { return true; });
        root.step("mux: the boot guard runs and starts the clock", function () { root.startGuard(); },
                  function () { const r = root.rec(); return !!r && r.state === "awaiting-keep"; }, 20000);
        root.step("mux-guard-armed: the deadline is 300 s since boot, on the guard's own clock, and the guard stays", function () {
            const r = root.rec();
            root.check("mux-guard-armed", r.deadlineBootId === root.bootIds[1] && r.deadlineUptimeMs === 300000 && typeof r.deadlineMs === "number" && guardP.alive === true, j(r));
        });
        root.step("mux: the shell starts at login and finds the record awaiting a keep", function () { root.startShell(); },
                  up(function (s) { return s.gpu.mux.state === "awaiting-keep" && s.helper.ok; }), 25000);
        root.step("mux-awaiting-facts: not pending (the keep prompt, not the restart card), wired to dGPU only, every step offered (the way out of dGPU-only is one MUX request, whichever mode comes after it); the countdown follows the guard's clock", function () {
            const s = A(), g = s.gpu, m = g.mux;
            root.check("mux-awaiting-facts", m.pending === false && g.wiring === "dgpu" && g.step === 3 && j(g.steps) === "[0,1,2,3]" && s.gpuModeTarget === 3 && m.bootId === root.bootIds[1] && m.deadlineBootId === m.bootId && m.deadlineUptimeMs === 300000, j(m));
            // 5 s since boot, a 300 s window: 295 s left, whatever the wall clock says (it steps early in a boot)
            root.check("mux-countdown-by-the-guards-clock", Model.muxRemainingMs(m, 0, 5000) === 295000 && Model.muxRemainingMs(m, 9e15, 5000) === 295000 && Model.muxRemainingMs(m, Date.now(), null) !== null, j([m.deadlineMs, Model.muxRemainingMs(m, 0, 5000)]));
            root.check("mux-awaiting-caption", s.caption.gpu === "dGPU only · always on", s.caption.gpu);
        });

        // ---- 5. the keep prompt: two minutes from the moment it is shown ----
        root.step("mux: the keep prompt is shown (once)", function () { root.check("mux-prompt-accepted", A().muxPromptShown() === true); },
                  up(function (s) { return s.gpu.mux.deadlineUptimeMs === 125000; }), 15000);
        root.step("mux-prompt-two-minutes: 5 s since boot + 120 s on the guard's clock, about 120 s ahead on the wall's", function () {
            const m = A().gpu.mux, r = root.rec();
            const wallLeft = m.deadlineMs - Date.now();
            root.check("mux-prompt-two-minutes", m.deadlineUptimeMs === 125000 && !!r && r.deadlineUptimeMs === 125000 && wallLeft > 100000 && wallLeft <= 121000 && Model.muxRemainingMs(m, Date.now(), 5000) === 120000, j([m.deadlineUptimeMs, wallLeft]));
        });
        // the arrow instead of Keep: the helper refuses a request while a keep is awaited, and the words reach the zone's caption
        root.step("mux: the user presses the arrow instead of Keep (the way back, asked while the keep is awaited)", function () {
            n0 = root.muxRefused.length;
            root.check("mux-arrow-asked", A().stepGpuMode(-1) === true && A().gpuModeTarget === 2);
        }, function () { return root.muxRefused.length === n0 + 1; }, 15000);
        root.step("mux-arrow-refused: refused with the helper's words, the scene is back on dGPU only, the prompt is still up", function () {
            const s = A(), f = root.muxRefused[n0];
            root.check("mux-arrow-refused", f.zone === "mux" && /waiting for your confirmation/.test(f.why) && s.caption.gpuError === f.why && s.gpuModeTarget === 3 && s.gpu.mux.state === "awaiting-keep" && root.rec().state === "awaiting-keep", j([f, s.caption.gpuError, s.gpuModeTarget]));
        });
        root.step("mux: time passes, short of the two minutes (90 s since boot), and nobody clicks", function () { root.uptime("90.00"); }, function () { return true; });
        root.pause(900);
        root.step("mux-no-click-yet: still waiting for the click: awaiting a keep, the guard on watch, nothing reverted, the firmware still dGPU only", function () {
            const r = root.rec();
            root.check("mux-no-click-yet", !!r && r.state === "awaiting-keep" && guardP.alive === true && root.logLines("guard-reboot.log").length === 0 && root.firmware() === "0", j([r && r.state, guardP.alive, root.logLines("guard-reboot.log").length, root.firmware()]));
        });

        // ---- 6. a CLICK keeps it ----
        root.step("mux: the user clicks Keep", function () { root.check("mux-click-accepted", A().muxKeep() === true); },
                  up(function (s) { return s.gpu.mux.state === "kept"; }), 15000);
        root.step("mux: ... and the guard, seeing it kept, has nothing left to guard", null, function () { return guardP.alive === false; }, 15000);
        root.step("mux-click-keeps: kept, the clock gone, dGPU only stays, no revert, no restart asked for, nobody told anything", function () {
            const r = root.rec(), s = A();
            root.check("mux-click-keeps", !!r && r.state === "kept" && !r.deadlineUptimeMs && !r.deadlineBootId && guardP.code === 0 && root.logLines("guard-reboot.log").length === 0 && root.firmware() === "0"
                       && s.gpu.mux.pending === false && s.gpuModeTarget === 3 && s.gpu.wiring === "dgpu" && root.notices.length === 0, j([r, guardP.code, root.notices.length]));
        });

        // ---- 6b. the unit stops while the panel is on the NVIDIA card: the way back is refused too ----
        root.step("mux: silicon-mux.service stops again; the user presses the arrow back", function () { root.muxUnit(false); }, up(function (s) { return s.gpu.mux.prechecks.ok === false; }), 15000);
        root.step("mux: ... the way back is asked for", function () {
            n0 = root.muxRefused.length;
            root.check("mux-unit-wayback-aim", A().stepGpuMode(-1) === true && A().gpuModeTarget === 2);
        }, function () { return root.muxRefused.length === n0 + 1; }, 15000);
        root.step("mux-unit-refused-wayback: refused with the unit's words, the scene stays on dGPU only, the record is as it was", function () {
            const s = A(), f = root.muxRefused[n0];
            root.check("mux-unit-refused-wayback", f.zone === "mux" && /^silicon-mux\.service is not active/.test(f.why) && s.caption.gpuError === f.why && s.gpuModeTarget === 3 && s.gpu.mux.pending === false && root.rec().state === "kept", j([f, s.gpuModeTarget, root.rec().state]));
        });
        root.step("mux: silicon-mux.service is up again", function () { root.muxUnit(true); }, up(function (s) { return s.gpu.mux.prechecks.ok === true; }), 15000);

        // ---- 7. the way back, with the NVIDIA stack UP (the compositor is on the NVIDIA card) -- walked FASTER THAN THE HELPER ANSWERS ----
        // (R2 I1) The arrow asks for Hybrid (a MUX request for the helper); a step taken once the helper has TAKEN it is a RE-AIM under it
        // (nothing more is asked of the helper, only the mode wanted after the restart changes); and that wish must outlive the restart that
        // ends this shell (SiliconState), to be set through cardwire at the next login, once.
        // (R5 X1) The user stepped Hybrid -> Smart -> Integrated and the laptop came back on Hybrid. Here every authorisation takes a second
        // (the pkexec stand-in's `delay_each`), so the walk is Hybrid at 0 s, Smart at 0.3 s -- BEFORE the helper has answered the first ask,
        // so a second request, queued behind -- and Integrated at ~1.3 s, after the first answer (a re-aim) and before the second's. The late
        // answer used to write the step its OWN request carried (Smart) over the newer one (Integrated): the wish is the LAST step asked for,
        // whatever the order of the answers.
        root.step("mux: the compositor sits on the NVIDIA card (the stack is up) and the helper answers slowly (1 s an ask)", function () {
            root.stack(true);
            root.put(root.logs + "/delay_each", "1");
        }, function () { return true; });
        root.step("mux: the user steps back, Hybrid ...", function () {
            n0r = root.rebootAsks();
            n0 = root.muxRequests();
            root.check("mux-wayback-accepted", A().stepGpuMode(-1) === true && A().gpuModeTarget === 2);
        }, function () { return true; });
        root.pause(300);
        root.step("mux: ... and on to Smart, 0.3 s later, before the helper has answered", function () {
            root.check("mux-walk-smart", A().gpu.mux.state === "kept" && A().gpu.mux.pending === false && A().stepGpuMode(-1) === true && A().gpuModeTarget === 1,
                       j([A().gpu.mux.state, A().gpuModeTarget]));
        }, up(function (s) { return s.gpu.mux.state === "queued" && s.gpu.mux.want === "hybrid"; }), 15000);
        root.step("mux-wayback-queued: the first answer is in: a request for hybrid from dGPU only, nothing written; the scene aims where the LATEST ask said (Smart) and is still on dGPU only", function () {
            const r = root.rec(), s = A();
            root.check("mux-wayback-queued", !!r && r.state === "queued" && r.want === "hybrid" && r.from === "dgpu" && s.gpu.mux.pending === true && s.gpuModeTarget === 1 && s.gpuMode === 3 && s.caption.gpu.indexOf("Smart after the next restart") >= 0,
                       j([r, s.gpuModeTarget, s.gpuMode, s.caption.gpu]));
            root.check("mux-wayback-nothing-written", root.firmware() === "0", root.firmware());
            root.check("mux-wayback-step-offered", j(s.gpu.steps) === "[0,1,2,3]" && s.gpu.mux.afterMode === 1, j([s.gpu.steps, s.gpu.mux.afterMode]));
        });
        root.step("mux-after-remembered: the state file holds the latest ask (Smart, 1), not the first one's Hybrid", null, function () { const st = root.stateJson(); return !!st && st.afterMuxMode === 1; }, 8000);
        root.step("mux: the user steps once more (Integrated): the same request, re-aimed -- the second ask is still on its way", function () {
            n1 = root.muxRequests();
            root.check("mux-reaim-accepted", A().stepGpuMode(-1) === true);
        }, up(function (s) { return s.gpuModeTarget === 0 && s.gpu.mux.afterMode === 0; }), 8000);
        // (the second ask started when the first was answered, 1 s ago at most; it is answered 1 s after that)
        root.pause(2200);
        root.step("mux-after-last-ask-wins: every answer is in -- and the wish is still INTEGRATED, the target, the caption and the state file with it; the re-aim asked nothing", function () {
            const s = A(), r = root.rec();
            root.check("mux-after-last-ask-wins", s.gpu.mux.afterMode === 0 && s.gpuModeTarget === 0 && s.gpuMode === 3 && s.caption.gpu.indexOf("Integrated after the next restart") >= 0 && !!r && r.state === "queued" && r.want === "hybrid",
                       j([s.gpu.mux.afterMode, s.gpuModeTarget, s.caption.gpu, r && r.state]));
            root.check("mux-after-state-file-last-ask", (root.stateJson() || {}).afterMuxMode === 0, j(root.stateJson()));
            root.check("mux-reaim-asks-nothing", root.muxRequests() === n1 && n1 - n0 <= 2, j([n0, n1, root.muxRequests()]));
            root.sh("rm -f '" + root.logs + "/delay_each'");
        });
        root.step("mux: the restart is asked for", function () { root.check("mux-wayback-restart-accepted", A().muxRebootNow() === true); }, function () { return root.rebootAsks() === n0r + 1; }, 15000);
        root.step("mux: the machine goes down; the shutdown unit writes the way back", function () { root.shutdown(); },
                  function () { return root.unitRes !== null; }, 25000);
        root.step("mux-wayback-written: hybrid is written EVEN WITH THE STACK UP (the user's way out waits for nothing)", function () {
            const o = root.unitJson();
            root.check("mux-wayback-written", root.unitRes.code === 0 && !!o && o.ok === true && root.rec().state === "applied" && root.firmware() === "1", j([root.unitRes.code, root.rec().state, root.firmware(), root.unitRes.err.slice(0, 160)]));
            root.info("way-back record: " + root.rec().why);
            root.check("mux-after-survives-the-shutdown", (root.stateJson() || {}).afterMuxMode === 0, j(root.stateJson()));
        });
        root.step("mux: the machine boots (the panel on the Intel card again)", function () { root.boot(2, "5.00"); }, function () { return true; });
        // The shell can start before the boot guard has looked at the way back (the record still says `applied`): the mode wanted is
        // then judged by what is true when the guard has kept it -- the card's holders are known by then (R5 W1: the session holds
        // its nodes, and is not a user of it), and it is not applied one moment sooner.
        root.step("mux: the shell starts at login, before the boot guard has run (the mode wanted is remembered from before the restart; the session holds the card's nodes)", function () { n0 = root.cardwireSets(0); root.startShell(); },
                  up(function (s) { return s.gpu.mux.state === "applied" && s.helper.ok && s.gpu.present && s.gpu.steps.length > 0; }), 25000);
        root.pause(1500);
        root.step("mux-login-waits: the record is only `applied`: nothing is applied yet, the laptop is where cardwire had it, and the wish is still remembered", function () {
            const s = A(), g = s.gpu;
            root.check("mux-login-waits", g.mux.state === "applied" && g.mux.pending === true && g.step === 2 && root.cardwireSets(0) === n0 && g.mux.afterMode === 0 && (root.stateJson() || {}).afterMuxMode === 0,
                       j([g.mux.state, g.step, root.cardwireSets(0) - n0, g.mux.afterMode]));
        });
        root.step("mux: the boot guard runs", function () { root.startGuard(); }, function () { return guardP.alive === false && guardP.code !== -2; }, 20000);
        root.step("mux-wayback-kept: the guard keeps the way back at once (no window to confirm), and asks for nothing", function () {
            const r = root.rec();
            root.check("mux-wayback-kept", !!r && r.state === "kept" && !r.deadlineUptimeMs && guardP.code === 0 && root.logLines("guard-reboot.log").length === 0, j([r, guardP.code]));
        });
        root.step("mux: the shell sees the way back kept, and sets the mode wanted", null,
                  up(function (s) { return s.gpu.mux.state === "kept" && s.helper.ok && s.gpu.present && s.gpu.steps.length > 0 && s.gpu.step === 0; }), 25000);
        root.step("mux-after-landed: the laptop is in INTEGRATED -- the LAST step asked for before the restart, not the first (Hybrid) nor the second (Smart) -- set through cardwire (Mode 0), once, asking for no confirmation, and forgotten", function () {
            const s = A(), g = s.gpu;
            root.check("mux-after-landed", g.wiring === "hybrid" && g.mux.state === "kept" && g.mode === 0 && g.step === 0 && g.mux.afterMode === null && s.gpuModeTarget === 0 && s.gpuMode === 0 && j(g.steps) === "[0,1,2,3]" && g.mux.pending === false,
                       j([g.wiring, g.mux.state, g.mode, g.step, g.mux.afterMode, s.gpuModeTarget]));
            root.check("mux-after-set-once", root.cardwireSets(0) === n0 + 1, String(root.cardwireSets(0) - n0));
        });
        root.step("mux-after-forgotten: ... the state file no longer holds it", null, function () { const st = root.stateJson(); return !!st && st.afterMuxMode === null; }, 8000);
        root.pause(2500);
        root.step("mux-after-not-again: nothing sets it a second time (the polls and the status refreshes since)", function () {
            root.check("mux-after-not-again", root.cardwireSets(0) === n0 + 1 && A().gpu.mode === 0 && j(root.stateJson().afterMuxMode) === "null", String(root.cardwireSets(0) - n0));
            root.check("mux-after-no-osd", root.calls("notify-send.log").filter(function (c) { return /was not set/.test(c.text); }).length === 0, "");
        });
        root.step("mux: the user puts the laptop back to Hybrid (cardwire's)", function () { root.check("mux-hybrid-again-accepted", A().setGpuMode(2, {}) === true); },
                  up(function (s) { return s.gpu.step === 2 && s.gpu.mode === 1 && s.gpuModeTarget === 2; }), 15000);
        root.step("mux-wayback-facts: Hybrid, all four steps again, nothing pending", function () {
            const s = A(), g = s.gpu;
            root.check("mux-wayback-facts", g.wiring === "hybrid" && g.step === 2 && j(g.steps) === "[0,1,2,3]" && g.mux.pending === false && s.gpuModeTarget === 2 && s.caption.gpu.indexOf("Hybrid") === 0, j([g.wiring, g.step, g.steps, s.caption.gpu]));
        });

        // ---- 8. dGPU only again while the stack is STILL up: not written ----
        root.step("mux: the stack is still up; dGPU only is requested", function () { root.check("mux-again-accepted", A().muxRequest("dgpu") === true); },
                  up(function (s) { return s.gpu.mux.state === "queued"; }), 15000);
        root.step("mux: the restart is asked for", function () {
            n0 = root.rebootAsks();
            root.check("mux-again-restart", A().muxRebootNow() === true);
        }, function () { return root.rebootAsks() === n0 + 1; }, 15000);
        root.step("mux: the machine goes down; the shutdown unit cannot bring the stack down", function () { root.shutdown(); },
                  function () { return root.unitRes !== null; }, 25000);
        root.step("mux-stack-up-refused: the firmware is NOT written, the record says failed and why", function () {
            const r = root.rec();
            root.check("mux-stack-up-refused", root.unitRes.code !== 0 && root.firmware() === "1" && !!r && r.state === "failed" && /stack|driver|NVIDIA|in use/i.test(r.why), j([root.unitRes.code, root.firmware(), r && r.state, r && r.why]));
        });
        root.step("mux: the machine boots (still Hybrid)", function () { root.boot(3, "5.00"); }, function () { return true; });
        root.step("mux: the shell starts at login", function () { root.startShell(); }, up(function (s) { return s.helper.ok && s.gpu.present && s.gpu.steps.length > 0 && s.gpu.mux.state === "failed"; }), 25000);
        root.step("mux-failed-facts: nothing pending, the scene back on Hybrid, the helper's words are a fact, and a failure is not a revert (no notice)", function () {
            const s = A(), g = s.gpu;
            root.check("mux-failed-facts", g.mux.pending === false && g.mux.why !== "" && s.gpuModeTarget === 2 && g.wiring === "hybrid" && g.step === 2 && root.notices.length === 0, j([g.mux.pending, g.mux.why, s.gpuModeTarget, g.wiring, root.notices.length]));
        });

        // ---- 9. dGPU only, the stack down, and NO click: the guard puts Hybrid back ----
        root.step("mux: the stack is down again; dGPU only is requested", function () { root.stack(false); }, function () { return true; });
        root.step("mux: ... requested", function () { root.check("mux-unkept-accepted", A().muxRequest("dgpu") === true); },
                  up(function (s) { return s.gpu.mux.state === "queued"; }), 15000);
        root.step("mux: the restart is asked for", function () {
            n0 = root.rebootAsks();
            root.check("mux-unkept-restart", A().muxRebootNow() === true);
        }, function () { return root.rebootAsks() === n0 + 1; }, 15000);
        root.step("mux: the machine goes down; the stack comes down; the firmware is written", function () { root.shutdown(); }, function () { return root.unitRes !== null; }, 25000);
        root.step("mux: ... written", function () {
            root.check("mux-unkept-written", root.unitRes.code === 0 && root.rec().state === "applied" && root.firmware() === "0", j([root.unitRes.code, root.rec().state, root.firmware()]));
        });
        root.step("mux: the machine boots (the panel on the NVIDIA card); the guard runs", function () { root.boot(4, "5.00"); }, function () { return true; });
        root.step("mux: ... the guard starts the clock", function () { root.startGuard(); }, function () { const r = root.rec(); return !!r && r.state === "awaiting-keep"; }, 20000);
        root.step("mux: the shell starts at login", function () { root.startShell(); }, up(function (s) { return s.gpu.mux.state === "awaiting-keep" && s.helper.ok && s.gpu.present && s.gpu.steps.length > 0; }), 25000);
        root.step("mux: the keep prompt is shown (once) -- and nobody clicks", function () { A().muxPromptShown(); }, up(function (s) { return s.gpu.mux.deadlineUptimeMs === 125000; }), 15000);
        root.step("mux: the two minutes run out (126 s since boot)", function () { root.uptime("126.00"); }, function () { const r = root.rec(); return !!r && r.state === "reverted"; }, 20000);
        root.step("mux: ... and the guard is done", null, function () { return guardP.alive === false; }, 15000);
        root.step("mux-unkept-reverts: hybrid was written back, the record says reverted, ONE restart was asked for, the clock is gone", function () {
            const r = root.rec();
            root.check("mux-unkept-reverts", !!r && r.state === "reverted" && r.why !== "" && root.firmware() === "1" && root.logLines("guard-reboot.log").length === 1 && guardP.code === 0 && !r.deadlineUptimeMs, j([r, root.firmware(), root.logLines("guard-reboot.log").length, guardP.code]));
        });

        // ---- 10. the restart the guard asked for: the user is told ONCE ----
        root.step("mux: the machine goes down for the guard's restart and comes back on the Intel card", function () { shellL.active = false; root.boot(5, "5.00"); }, function () { return true; });
        root.step("mux: the shell starts at login", function () { root.startShell(); }, up(function (s) { return s.gpu.mux.state === "reverted" && s.helper.ok && s.gpu.present && s.gpu.steps.length > 0; }), 25000);
        root.step("mux: the watcher tells the user and marks the outcome seen", null, up(function (s) { return root.notices.length === 1 && s.gpu.mux.outcomeSeen === true; }), 15000);
        root.step("mux-reverted-facts: Hybrid is where the machine is, nothing pending, the words are a fact; told once", function () {
            const s = A(), g = s.gpu;
            root.check("mux-reverted-facts", g.mux.state === "reverted" && g.mux.pending === false && g.wiring === "hybrid" && g.step === 2 && s.gpuModeTarget === 2 && g.mux.why !== "", j(g.mux));
            root.check("mux-told-once", root.notices.length === 1 && /not confirmed/.test(root.notices[0].why), j(root.notices));
        });
        root.step("mux-outcome-mark-on-disk: the mark is the record's request time, written to the state file", null, function () {
            let st = null;
            try { st = JSON.parse(root.fileText(root.stateFile)); } catch (e) { st = null; }
            return !!st && st.muxOutcomeSeenAt === root.rec().requestedAtMs;
        }, 6000);
        root.step("mux: the shell is restarted again (another login)", function () { shellL.active = false; }, function () { return true; });
        root.pause(300);
        root.step("mux: ... it starts", function () { root.startShell(); }, up(function (s) { return s.gpu.mux.state === "reverted" && s.helper.ok && s.gpu.present && s.gpu.steps.length > 0; }), 25000);
        root.pause(1200);
        root.step("mux-silenced: the same outcome is a fact again but is not told again: the mark survived the restart", function () {
            const m = A().gpu.mux;
            root.check("mux-silenced", m.state === "reverted" && m.outcomeSeen === true && root.notices.length === 1, j([m.state, m.outcomeSeen, root.notices.length]));
            root.check("mux-no-guard-left", guardP.alive === false, "");
        });
    }

    // ======================================================================================
    // the system update's hold under the REAL supervisor (phase update)
    // ======================================================================================
    readonly property string updateRun: Quickshell.env("SSP_UPDATE_RUN") || "/nonexistent"
    readonly property string markerFile: root.xdgState + "/lares/system-update/last-run.json"
    property string runCmdline: ""
    // helpers/update-run.sh <run-dir> <command...>, detached (setsid, its output off the lane's pipes), the way the shell's
    // popup starts one -- with `sleep` for yay.
    function startRun(id, secs) {
        root.ops++;
        stim.run(["sh", "-c", "setsid -f sh \"$1\" \"$2\" \"$3\" > /dev/null 2>&1 < /dev/null", "sh", root.updateRun, root.out + "/runs/" + id, "sleep " + secs], function (res) {
            root.ops--;
            if (res.code !== 0)
                root.check("update-run-start " + id, false, res.err);
        });
    }
    function marker() {
        try { return JSON.parse(root.fileText(root.markerFile)); } catch (e) { return null; }
    }
    function readCmdline(pid) {
        root.ops++;
        stim.run(["sh", "-c", "tr '\\000' ' ' < /proc/$1/cmdline", "sh", String(pid)], function (res) {
            root.ops--;
            root.runCmdline = res.out;
        });
    }

    function buildUpdate() {
        let n0 = 0, left = "";
        root.step("update: the shell reads the machine (the profile it will leave and come back to)", function () { svc.popupOpen = true; }, function () { return svc.helper.ok && svc.cpu.profile !== ""; }, 20000);
        root.step("update: a real run starts (helpers/update-run.sh, `sleep 5` for yay)", function () {
            left = svc.cpu.profile;
            n0 = root.applies().length;
            root.startRun("run-real-A", 5);
        }, function () { return PowerBus.holds["system-update"] !== undefined && svc.cpu.profile === "performance"; }, 25000);
        root.step("update-real-holds: the supervisor's marker is what the hold reads: Performance while it runs, and the zone says who holds it", function () {
            const m = root.marker();
            root.check("update-real-marker", !!m && m.state === "running" && m.runId === "run-real-A" && typeof m.pid === "number" && m.pid > 0 && m.command === "sleep 5", j(m));
            if (m)
                root.readCmdline(m.pid);
            root.check("update-real-holds", PowerBus.holds["system-update"].profile === "performance" && svc.cpu.heldBy === "system-update" && svc.caption.cpu === "Performance · held by the system update" && left !== "performance", j([PowerBus.holds, svc.caption.cpu, left]));
        });
        root.step("update-real-liveness: the supervisor's own cmdline names the run (what the liveness test greps for)", function () {
            root.check("update-real-liveness", root.runCmdline.indexOf("run-real-A") >= 0 && root.runCmdline.indexOf("update-run.sh") >= 0, root.runCmdline);
        });
        root.step("update: the run ends (the supervisor writes the marker finished)", null, function () { return PowerBus.holds["system-update"] === undefined && svc.cpu.heldBy === "" && svc.cpu.profile === left; }, 30000);
        root.step("update-real-ends: the hold ended WITH the run, and the profile it left is back", function () {
            const m = root.marker();
            root.check("update-real-ends", !!m && m.state === "finished" && m.exit === 0 && svc.cpu.profile === left && svc.caption.cpu.indexOf("held") < 0, j([m, svc.cpu.profile, left]));
        });
        // a manual change wins -- with the real run still going
        root.step("update: another real run starts", function () {
            n0 = root.applies().length;
            root.startRun("run-real-B", 6);
        }, function () { return PowerBus.holds["system-update"] !== undefined && svc.cpu.profile === "performance"; }, 25000);
        root.step("update: the user steps down by hand while it runs", function () {
            n0 = root.applies().length;
            root.check("update-real-manual-step", svc.stepProfile(-1) === true);
        }, function () { return svc.cpu.profile === "balanced" && Object.keys(PowerBus.holds).length === 0; }, 15000);
        root.pause(2000);
        root.step("update-real-manual-wins: the hold is dropped and not taken again while the same run goes on; nothing was restored", function () {
            const m = root.marker();
            root.check("update-real-manual-wins", !!m && m.state === "running" && svc.cpu.profile === "balanced" && Object.keys(PowerBus.holds).length === 0 && svc.cpu.heldBy === "" && root.applies().length === n0 + 1, j([m && m.state, svc.cpu.profile, PowerBus.holds, root.applies().length - n0]));
        });
        root.step("update: that run ends too", null, function () { const m = root.marker(); return !!m && m.state === "finished"; }, 30000);
        root.pause(1500);
        root.step("update-real-manual-stays: the user's profile stands after the run, nothing was written", function () {
            root.check("update-real-manual-stays", svc.cpu.profile === "balanced" && Object.keys(PowerBus.holds).length === 0 && root.applies().length === n0 + 1, j([svc.cpu.profile, root.applies().length - n0]));
        });
    }

    // ======================================================================================
    // the boot profile (phase boot, Q16): silicon.jsonc's `defaultProfile` is STORED as the helper's boot set -- the REAL
    // helper in test mode, its state dir the fake machine's -- and never applied
    // ======================================================================================
    readonly property string bootJsonFile: root.fx + "/state/boot.json"
    Component {
        id: bootShellC
        SiliconService {
            bootFile: root.bootJsonFile
            configPath: root.xdgConfig + "/quickshell/silicon.json"
            statePath: root.xdgState + "/lares/silicon/state.json"
            persist: false
            oldLastFullPath: root.out + "/none/last-full"
            updateMarkerPath: root.xdgState + "/lares/system-update/last-run.json"
            helperStatusCommand: root.statusCmd
            helperWriteCommand: root.writeCmd
            cardwireEnabled: false
            procRoot: root.tree + "/proc"
            defaultPaths: ({ battery: root.tree + "/sys/class/power_supply/BAT0", ac: root.tree + "/sys/class/power_supply/AC0" })
            drmRoot: root.tree + "/sys/class/drm"
            usbRoot: root.tree + "/sys/bus/usb/devices"
            evdiModule: root.tree + "/sys/module/evdi"
            displayEnabled: false
            powerEventsEnabled: false
            upowerEnabled: false
            holdSystemUpdate: false
            helperTimeoutMs: 8000
        }
    }
    Loader {
        id: bootL
        active: false
        sourceComponent: bootShellC
    }

    function buildBoot() {
        const S = function () { return bootL.item; };
        const sets = function () { return root.calls("pkexec.log").filter(function (c) { return / set-boot( |$)/.test(c.text); }); };
        const argsOf = function (line) {
            const o = {};
            line.split(" ").filter(function (w) { return w.indexOf("=") > 0; }).forEach(function (w) { const at = w.indexOf("="); o[w.substring(0, at)] = w.substring(at + 1); });
            return o;
        };
        // a profile's linked values (CONTRACT section 4's seeds on the fixture's limits), as `apply` arguments
        const want = function (name, over) { return Object.assign(argsOf(root.linked[name].substring("apply ".length)), over || {}); };
        const same = function (a, b) {
            const ka = Object.keys(a || {}).sort(), kb = Object.keys(b || {}).sort();
            return j(ka) === j(kb) && ka.every(function (k) { return a[k] === b[k]; });
        };
        const lastSet = function () { const s = sets(); return s.length > 0 ? argsOf(s[s.length - 1].text.substring(root.helperBase.length)) : null; };
        const stored = function () { try { return JSON.parse(root.fileText(root.bootJsonFile)); } catch (e) { return null; } };
        const cfg = function (o) { root.put(root.cfgPath, "// the probe (phase boot)\n" + JSON.stringify(o, null, 2) + "\n"); };
        const isState = function (state, w) {
            return function () { const s = S(); if (s) root.detail = j(s.bootProfile); return !!s && s.bootProfile.state === state && s.bootProfile.want === w; };
        };
        // the shell's own status read, asked now (a read after every stimulus before it: see refreshAfter)
        let runs = 0;
        const reread = function (label) {
            root.step("boot: " + label + " (a status read)", function () {
                runs = S().statusRuns;
                root.ops++;
                stim.run(["true"], function () { root.ops--; S().refresh(); });
            }, function () { return S().statusRuns > runs && !S().helper.why; }, 8000);
            root.pause(400);
        };
        let profile0 = "";
        // NOTHING IS APPLIED: no `apply` went through pkexec in the whole phase, and the fake machine's profile has not moved. Each store is
        // followed by a pause longer than the CPU write's settle (300 ms) and its write, so an apply asked with the store has gone out by
        // the time this looks (ARM bootapply).
        const noApply = function (tag) {
            root.check("boot-no-apply-" + tag, root.applies().length === 0 && root.fileText(root.profileFile).trim() === profile0,
                       j([root.applies().map(function (c) { return c.text.substring(root.helperBase.length); }), root.fileText(root.profileFile).trim()]));
        };

        root.step("boot: nothing is stored on the fake machine; silicon.jsonc names balanced", function () {
            profile0 = root.fileText(root.profileFile).trim();
            root.check("boot-nothing-stored", root.fileText(root.bootJsonFile) === "" && profile0 === "balanced", j([root.fileText(root.bootJsonFile), profile0]));
            cfg({ defaultProfile: "balanced" });
        }, function () { return true; });
        root.step("boot: the shell starts and stores balanced as the boot set", function () {
            bootL.active = true;
        }, isState("stored", "balanced"), 15000);
        root.pause(1200);
        root.step("boot-stored-once: ONE set-boot with balanced's linked values; the boot set holds them; nothing applied", function () {
            const st = stored();
            root.check("boot-stored-once", sets().length === 1 && same(lastSet(), want("balanced")), j(sets().map(function (c) { return c.text.substring(root.helperBase.length); })));
            root.check("boot-file", st !== null && st.version === 1 && same(st.apply, want("balanced")) && st.chargeLimit === null, j(st));
            noApply("start");
        });
        // a second load: the shell restarts and finds the boot set as asked
        root.step("boot: the shell stops", function () { bootL.active = false; }, function () { return bootL.item === null; });
        root.step("boot: a new shell starts (the second load)", function () { bootL.active = true; }, isState("stored", "balanced"), 15000);
        reread("the second shell reads the machine again");
        reread("and again");
        root.step("boot-second-load: the second load writes nothing", function () {
            root.check("boot-second-load", sets().length === 1 && S().bootProfile.state === "stored", j([sets().length, S().bootProfile]));
            noApply("second-load");
            cfg({ defaultProfile: "quiet" });
        }, isState("stored", "quiet"), 15000);
        root.pause(1200);
        root.step("boot-quiet: quiet writes again (the config is read hot), and only quiet's values are stored", function () {
            const st = stored();
            root.check("boot-quiet", sets().length === 2 && same(lastSet(), want("quiet")) && st !== null && same(st.apply, want("quiet")), j([sets().length, lastSet(), st]));
            noApply("quiet");
            cfg({ defaultProfile: "quiet", profiles: { quiet: { maxPerfPct: 60 } } });
        }, function () { return sets().length === 3 && isState("stored", "quiet")(); }, 15000);
        root.pause(1200);
        root.step("boot-row-edited: the named profile's row edited: its new values are stored", function () {
            const st = stored();
            const w = want("quiet", { max_perf_pct: "60" });
            root.check("boot-row-edited", sets().length === 3 && same(lastSet(), w) && st !== null && same(st.apply, w), j([lastSet(), st]));
            noApply("row-edited");
            cfg({ profiles: { quiet: { maxPerfPct: 60 } } });
        }, isState("off", null), 15000);
        reread("no key: the shell reads the machine");
        reread("and again");
        root.step("boot-absent: no key writes nothing, and clears nothing", function () {
            const st = stored();
            root.check("boot-absent", sets().length === 3 && S().bootProfile.why === "" && st !== null && same(st.apply, want("quiet", { max_perf_pct: "60" })), j([sets().length, S().bootProfile, st]));
            noApply("absent");
            // a boot set the helper cannot read: it refuses to store over it
            root.put(root.bootJsonFile, "{ not json\n");
            cfg({ defaultProfile: "balanced" });
        }, isState("failed", "balanced"), 15000);
        root.step("boot-failed: the helper's refusal is the boot profile's why (one log line)", function () {
            root.check("boot-failed", sets().length === 4 && /not understood/.test(S().bootProfile.why), j([sets().length, S().bootProfile]));
            root.info("boot-warnings 1");
        });
        reread("the refused shell reads the machine");
        reread("again");
        reread("and again");
        root.step("boot-no-storm: three status reads later nothing more was asked", function () {
            root.check("boot-no-storm", sets().length === 4 && S().bootProfile.state === "failed", j([sets().length, S().bootProfile]));
            noApply("failed");
            // the boot set is put right (gone: nothing stored), and the shell reads the machine
            root.sh("rm -f '" + root.bootJsonFile + "'");
            root.ops++;
            stim.run(["true"], function () { root.ops--; S().refresh(); });
        }, isState("stored", "balanced"), 15000);
        root.pause(1200);
        root.step("boot-recovered: a boot set that changed is asked for once more, and stored", function () {
            const st = stored();
            root.check("boot-recovered", sets().length === 5 && same(lastSet(), want("balanced")) && st !== null && same(st.apply, want("balanced")), j([sets().length, st]));
            noApply("end");
            bootL.active = false;
        }, function () { return bootL.item === null; });
    }

}
