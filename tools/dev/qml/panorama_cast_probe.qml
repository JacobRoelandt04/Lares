import QtQuick
import Quickshell

import "modules/common/system"
import "modules/panorama/data"

// =============================================================================
// panorama_cast_probe.qml -- the cast glue (CastKeeper) on the REAL PanoramaService (not live) and on PanoramaMock, with a CastMock for the
// cast and a stand-in for the engine (it answers the keeper's openOutput after a beat: the name in its state, the output LISTED at once and the
// resolved rule LANDED a beat later). Run by tools/dev/panorama_service_probe.sh (offscreen, sandboxed); prints `PS ok|FAIL <check>` and
// `PS RESULT PASS|FAIL`.
//
//   c1  scan on open, throttled; the shell's start tells the engine nothing is live
//   c2  the order: open -> output listed -> setup landed -> keep -> start; no toast, no keep prompt; the default setup (1080p60, above, centred)
//   c3  a scan never runs while casting; Stop: ONE close, then keep []
//   c4  every script: failure texts, ONE close each, the notice for noticeMs then the failure cleared, the chip's words
//   c5  stop before streaming, an output that never shows, a restart for new quality (ONE restart, the setup saved)
//   c6  OFF (config cast false): no chip data, no scan, no start, no engine call
//   c7  the MOCK: the same order, the mirror moves the stream to the internal output and back, one close
// =============================================================================
ShellRoot {
    id: root

    property int fails: 0
    function check(name, ok, detail) {
        console.log("PS " + (ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  -- " + detail));
        if (!ok)
            root.fails++;
    }

    readonly property string tv: "wfd:02:AE:00:00:0A:01"
    readonly property var edp: ({ name: "eDP-1", description: "Samsung Display Corp. 0x4180", make: "Samsung Display Corp.", model: "0x4180",
        serial: "", id: 0, enabled: true, width: 2880, height: 1620, refresh: 120.0, x: 0, y: 0, scale: 1.25, transform: 0,
        mirrorOf: "", physW: 340, physH: 190, modes: [{ w: 2880, h: 1620, r: 120, preferred: true }], backend: "drm",
        hdr: true, bt2020: true, vrrCapable: false, vrr: 0, bitdepth: 10, cm: "srgb", sdrbrightness: 1, sdrsaturation: 1, driver: "" })

    FocusedScreen {
        id: focus
        live: false
    }
    QtObject {
        id: drm
        property var connectors: []
        property bool displayLinkUsb: false
        property real displayLinkSince: 0
        property bool evdiLoaded: true
        property bool displayLinkActive: true
        property var connectedSince: ({})
        property bool nvidiaHdmi: false
        signal changed
    }
    QtObject {
        id: notif
        property int told: 0
        signal action(string key, string id)
        function notify(key, rec) {
            told++;
        }
        function withdraw(key) {
        }
    }
    CastMock {
        id: cm
        stepMs: 30
        beatMs: 60
        stopMs: 30
        scanMs: 40
    }
    CastMock {
        id: cmMock
        stepMs: 30
        beatMs: 60
        stopMs: 30
        scanMs: 40
    }
    PanoramaService {
        id: svc
        live: false
        focusSource: focus
        drm: drm
        notifier: notif
        cast: cm
    }
    // the same service with the config left at its default: cast is OFF
    PanoramaService {
        id: svcOff
        live: false
        focusSource: focus
        drm: drm
        notifier: notif
        cast: cm
    }
    PanoramaMock {
        id: mock
        scenario: "laptop"
        timeScale: 20
        castConfig: true
        cast: cmMock
    }

    // ---- the engine's stand-in and the counters ----
    property var log: []
    property string engineMode: "ok"             // "ok" | "never" (the output never shows)
    property int scans: 0
    property int starts: 0
    property var seen: ({})                       // every status text the chip showed
    property var offSignals: 0
    function note(s) {
        const l = root.log.slice();
        l.push(s);
        root.log = l;
    }
    function count(prefix) {
        return root.log.filter(l => l.indexOf(prefix) === 0).length;
    }
    function at(prefix) {
        return root.log.findIndex(l => l.indexOf(prefix) === 0);
    }
    Connections {
        target: svc.castKeeper
        function onOpenOutput(identity) {
            root.note("open " + identity);
            eng.restart();
        }
        function onCloseOutput(name) {
            root.note("close " + name);
            root.engineSetCast(false, name);
        }
        function onKeepNames(names) {
            root.note("keep " + JSON.stringify(names));
        }
    }
    Connections {
        target: svcOff.castKeeper
        function onOpenOutput(identity) {
            root.offSignals++;
        }
        function onCloseOutput(name) {
            root.offSignals++;
        }
        function onKeepNames(names) {
            root.offSignals++;
        }
    }
    Connections {
        target: cm
        function onMonitorChanged() {
            if (cm.monitor !== "")
                root.note("start " + cm.device + " " + cm.monitor);
        }
        function onStarted(deviceId, monitorName) {
            root.starts++;
            root.note("up " + monitorName);
        }
        function onScanningChanged() {
            if (cm.scanning)
                root.scans++;
        }
    }
    Timer {
        interval: 10
        running: true
        repeat: true
        onTriggered: {
            const t = svc.castStatusText(root.tv);
            if (t !== "" && !root.seen[t]) {
                const s = Object.assign({}, root.seen);
                s[t] = true;
                root.seen = s;
            }
        }
    }
    // the engine: the name appears in its state, the output is listed unruled, then the resolved rule lands
    property bool castListed: false
    function outputsWith(applied) {
        const list = [root.edp];
        const sp = svc.plan.specs["LARES-CAST-1"];
        const o = { name: "LARES-CAST-1", backend: "headless", width: 1920, height: 1080, refresh: 60, scale: 1, x: 0, y: 0,
            modes: [{ w: 1920, h: 1080, r: 60, preferred: true }] };
        if (applied && sp) {
            o.x = sp.position[0];
            o.y = sp.position[1];
        }
        list.push(o);
        return list;
    }
    function engineSetCast(on, name) {
        const link = svc.engineLink;
        link.state = { v: 1, session: "probe", serial: Date.now(), trial: { token: "", phase: "none", verdict: "" }, bound: [], unknown: [],
            cast: { outputs: on ? { "LARES-CAST-1": "cast:" + root.tv } : {}, keep: [] } };
        if (!on) {
            root.castListed = false;
            focus.setOutputs([root.edp]);
        }
    }
    Timer {
        id: eng
        interval: 60
        onTriggered: {
            root.engineSetCast(true, "LARES-CAST-1");
            if (root.engineMode === "never")
                return;
            root.castListed = true;
            focus.setOutputs(root.outputsWith(false));
            land.restart();
        }
    }
    Timer {
        id: land
        interval: 120
        onTriggered: {
            if (!root.castListed)
                return;
            root.note("landed");
            focus.setOutputs(root.outputsWith(true));
        }
    }
    function waitIdle() {
        return svc.castPhase === "idle" ? undefined : "wait";
    }
    function startRun(script) {
        root.log = [];
        root.engineMode = "ok";
        cm.script(script);
        return svc.castStart(root.tv);
    }

    property int step: 0
    property int waits: 0
    property var steps: [
        // ---- c1
        () => {
            focus.setOutputs([root.edp]);
            svc.configObject.apply({ cast: true });
            svc.engineLink.stateName = "active";
            svc.popupOpen = true;
        },
        () => cm.devices.length === 2 ? undefined : "wait",
        () => {
            root.check("c1 the scan runs when the view opens", root.scans === 1, root.scans);
            root.check("c1 the engine is told at the start that no cast is live", root.log.indexOf("keep []") >= 0, JSON.stringify(root.log));
            root.check("c1 the capable device is listed, the phone is flagged", svc.castDevices.length === 2 && svc.castDevices.filter(d => d.capable).length === 1, JSON.stringify(svc.castDevices));
            svc.popupOpen = false;
            svc.popupOpen = true;
        },
        () => {
            root.check("c1 a second open inside 30 s scans nothing", root.scans === 1, root.scans);
            root.check("c1 cast is enabled with the config, a service and the engine", svc.castEnabled === true, svc.castEnabled);
        },
        // ---- c2
        () => {
            const ok = root.startRun("ok");
            root.check("c2 castStart accepted", ok === true, ok);
            root.check("c2 the phase is opening and the chip says so", svc.castPhase === "opening" && svc.castStatusText(root.tv) === "Preparing…", svc.castPhase + " " + svc.castStatusText(root.tv));
            root.check("c2 a second start is refused", svc.castStart(root.tv) === false, "");
        },
        () => svc.castPhase === "streaming" ? undefined : "wait",
        () => {
            const iOpen = root.at("open "), iKeep = root.at('keep ["LARES-CAST-1"]'), iLand = root.at("landed"), iStart = root.at("start ");
            root.check("c2 the order: open, keep, landed, start", iOpen === 0 && iKeep > iOpen && iLand >= 0 && iStart > iLand && iStart > iKeep, JSON.stringify(root.log));
            root.check("c2 the stream goes to the cast output", cm.monitor === "LARES-CAST-1" && svc.castOutput === "LARES-CAST-1", cm.monitor);
            const sp = svc.plan.specs["LARES-CAST-1"];
            root.check("c2 the default setup: 1080p60, scale 1, centred above the laptop, not mirrored", sp.mode === "1920x1080@60" && sp.scale === 1
                       && JSON.stringify(sp.position) === "[192,-1080]" && sp.mirror === "", JSON.stringify(sp));
            root.check("c2 no toast, no keep prompt, nothing staged", notif.told === 0 && svc.phase === "idle" && svc.staged === null, notif.told + " " + svc.phase);
            root.check("c2 the TV's display is its device's identity, labelled with its name", svc.displays.some(d => d.cast === true && d.ident === "cast:" + root.tv
                       && d.label === "[TV] Living Room OLED 65"), JSON.stringify(svc.displays.map(d => [d.name, d.ident, d.label])));
            root.check("c2 the panes count it (a real display)", svc.panes === 2, svc.panes);
            root.check("c2 it takes no brightness", svc.brightnessTarget("LARES-CAST-1").kind === "none" && !svc.brightnessOf("LARES-CAST-1").capable, "");
        },
        // ---- c3
        () => {
            svc.castKeeper.scanEveryMs = 1;
            svc.popupOpen = false;
            svc.popupOpen = true;
        },
        () => {
            root.check("c3 never a scan while casting (even with no throttle)", root.scans === 1, root.scans);
            svc.castStop();
            root.check("c3 stopping says so", svc.castPhase === "stopping" && svc.castStatusText(root.tv) === "Stopping…", svc.castPhase);
        },
        () => root.waitIdle(),
        () => {
            root.check("c3 ONE close, then keep []", root.count("close ") === 1 && root.at("keep []") > root.at("close "), JSON.stringify(root.log));
            root.check("c3 a stop is no failure: no notice", svc.castNotice === null, JSON.stringify(svc.castNotice));
            root.check("c3 the layout falls back to the laptop", svc.displays.length === 1 && svc.panes === 1, svc.displays.length);
            svc.castKeeper.scanEveryMs = 30000;
            svc.castKeeper.noticeMs = 300;
            svc.castKeeper.openWaitMs = 400;
        },
        // ---- c4: every script
        () => { root.startRun("activation-twice"); },
        () => root.waitIdle(),
        () => {
            root.check("c4 activation: the TV did not answer", svc.castNoticeFor(root.tv) === "The TV did not answer", JSON.stringify(svc.castNotice));
            root.check("c4 activation: ONE close, no leftover output", root.count("close ") === 1 && svc.displays.length === 1, JSON.stringify(root.log));
            root.check("c4 the failed cast closed the output at once (before the notice ran out)", svc.castNotice !== null, "");
        },
        () => svc.castNotice === null ? undefined : "wait",
        () => {
            root.check("c4 the notice goes after its time and the failure is cleared", svc.castState === "idle", svc.castState);
        },
        () => { root.startRun("cancelled"); },
        () => root.waitIdle(),
        () => {
            root.check("c4 cancelled on the TV", svc.castNoticeFor(root.tv) === "Cancelled on the TV" && root.count("close ") === 1, JSON.stringify(svc.castNotice) + JSON.stringify(root.log));
        },
        () => svc.castNotice === null ? undefined : "wait",
        () => { root.startRun("peer-gone-midstream"); },
        () => svc.castPhase === "streaming" ? undefined : "wait",
        () => root.waitIdle(),
        () => {
            root.check("c4 peer gone mid-stream: the TV ended it, ONE close", svc.castNoticeFor(root.tv) === "The TV ended the stream" && root.count("close ") === 1, JSON.stringify(svc.castNotice) + JSON.stringify(root.log));
        },
        () => svc.castNotice === null ? undefined : "wait",
        () => { root.seen = ({}); root.startRun("activation-then-ok"); },
        () => svc.castPhase === "streaming" ? undefined : "wait",
        () => {
            root.check("c4 a retry is shown as one, with the other states in words", !!root.seen["Retrying…"] && !!root.seen["Connecting…"] && !!root.seen["Negotiating…"], JSON.stringify(Object.keys(root.seen)));
            root.check("c4 the retry opened ONE output and started ONE stream per attempt of the tool", root.count("open ") === 1 && root.count("up ") === 1, JSON.stringify(root.log));
            svc.castStop();
        },
        () => root.waitIdle(),
        // ---- c5
        () => {
            root.startRun("ok");
        },
        () => svc.castPhase === "starting" ? undefined : "wait",
        () => {
            svc.castStop();
        },
        () => root.waitIdle(),
        () => {
            root.check("c5 a stop before the stream is up: ONE close, no failure", root.count("close ") === 1 && svc.castNotice === null && cm.state === "idle", JSON.stringify(root.log));
            root.log = [];
            root.engineMode = "never";
            svc.castStart(root.tv);
        },
        () => root.waitIdle(),
        () => {
            root.check("c5 an output that never shows: the notice, ONE close, no stream", svc.castNoticeFor(root.tv) === "The display could not be made"
                       && root.count("close ") === 1 && root.count("start ") === 0, JSON.stringify(svc.castNotice) + JSON.stringify(root.log));
        },
        () => svc.castNotice === null ? undefined : "wait",
        () => {
            root.startRun("ok");
        },
        () => svc.castPhase === "streaming" ? undefined : "wait",
        () => {
            root.startsBefore = root.starts;
            root.check("c5 the stored quality is the default", JSON.stringify(svc.castQualityOf("LARES-CAST-1")) === JSON.stringify({ res: "1920x1080", fps: 30, bitrate: "8M", audio: true }), JSON.stringify(svc.castQualityOf("LARES-CAST-1")));
            // panorama.jsonc castQuality: what a TV not set up yet gets, a stored field's gap filled from it
            const was = JSON.parse(JSON.stringify(svc.settings));
            svc.configObject.apply(Object.assign({}, was, { castQuality: { res: "2560x1440", fps: 25 } }));
            root.check("c5 panorama.jsonc castQuality is the quality of a TV not set up yet (the stream it starts too)",
                       JSON.stringify(svc.castQualityOf("LARES-CAST-1")) === JSON.stringify({ res: "2560x1440", fps: 25, bitrate: "8M", audio: true })
                       && JSON.stringify(svc.castKeeper._opts()) === JSON.stringify({ res: "2560x1440", fps: 25, bitrate: "8M" }),
                       JSON.stringify(svc.castQualityOf("LARES-CAST-1")) + " " + JSON.stringify(svc.castKeeper._opts()));
            svc.configObject.apply(was);
            svc.castApplyQuality({ res: "1280x720", fps: 60, bitrate: "16M", audio: false });
            root.check("c5 apply: the quality is saved in the setup (the spec's cast extras)", JSON.stringify(svc.store.doc.setups[svc.setKey].outputs["cast:" + root.tv].cast) === JSON.stringify({ res: "1280x720", fps: 60, bitrate: "16M", audio: false }),
                       JSON.stringify(svc.store.doc.setups[svc.setKey]));
            root.check("c5 apply: the stream restarts (one stop), the phase says so", svc.castPhase === "restarting", svc.castPhase);
        },
        () => svc.castPhase === "streaming" ? undefined : "wait",
        () => {
            root.check("c5 apply: ONE restart, the output kept (no close)", root.starts === root.startsBefore + 1 && root.count("close ") === 0, root.starts + " " + JSON.stringify(root.log));
            root.check("c5 the new run reads the saved quality", JSON.stringify(svc.castKeeper._opts()) === JSON.stringify({ res: "1280x720", fps: 60, bitrate: "16M", audio: false }), JSON.stringify(svc.castKeeper._opts()));
            svc.castStop();
        },
        () => root.waitIdle(),
        () => {
            root.check("c5 ... and the stop closes it ONCE", root.count("close ") === 1, JSON.stringify(root.log));
        },
        // ---- c6
        () => {
            const scans0 = root.scans, starts0 = root.starts;
            root.check("c6 off: castEnabled is false, no devices handed out", svcOff.castEnabled === false && svcOff.castDevices.length === 0, svcOff.castEnabled);
            root.check("c6 off: a start is refused", svcOff.castStart(root.tv) === false, "");
            svcOff.popupOpen = true;
            svcOff.popupOpen = false;
            root.check("c6 off: no scan, no start, no engine call", root.scans === scans0 && root.starts === starts0 && root.offSignals === 0 && svcOff.castPhase === "idle",
                       root.scans + " " + root.starts + " " + root.offSignals);
        },
        // ---- c7: the mock
        () => {
            mock.popupOpen = true;
        },
        () => cmMock.devices.length === 2 ? undefined : "wait",
        () => {
            root.check("c7 mock: the scan on open, the capable device", mock.castDevices.filter(d => d.capable).length === 1, JSON.stringify(mock.castDevices));
            cmMock.script("ok");
            root.check("c7 mock: castStart accepted", mock.castStart(root.tv) === true, "");
        },
        () => mock.castPhase === "streaming" ? undefined : "wait",
        () => {
            root.check("c7 mock: open, keep, then the stream on the cast output", mock.castLog[0] === "open cast:" + root.tv && mock.castLog[1] === 'keep ["LARES-CAST-1"]' && cmMock.monitor === "LARES-CAST-1",
                       JSON.stringify(mock.castLog) + cmMock.monitor);
            root.check("c7 mock: no toast, no trial", mock.postedToasts.length === 0 && mock.phase === "idle", JSON.stringify(mock.postedToasts));
            root.check("c7 mock: the TV is a display labelled with its name", mock.displays.some(d => d.cast && d.label === "[TV] Living Room OLED 65"), JSON.stringify(mock.displays.map(d => d.label)));
            root.mstarts = 1;
            // MIRROR: no trial, no toast -- the stream is restarted on the laptop's output and the cast's own output is CLOSED (a mirroring
            // or disabled output cannot be removed, and one disabled as it is born killed the session's clients on 2026-11-23)
            mock.castSetMirror(true);
            root.check("c7 mock: mirror is no trial", mock.phase === "idle" && mock.postedToasts.length === 0, mock.phase);
        },
        () => cmMock.monitor === "eDP-1" && cmMock.state === "streaming" ? undefined : "wait",
        () => {
            const o = mock._S.outs.find(x => x.name === "LARES-CAST-1");
            root.check("c7 mock: a mirrored cast has NO output; the stream takes the internal one (ARM mirrortarget)", !o && cmMock.monitor === "eDP-1" && mock.castMirrored === true,
                       JSON.stringify(o) + cmMock.monitor);
            root.check("c7 mock: its output was closed ONCE for it", mock.castLog.filter(l => l.indexOf("close") === 0).length === 1, JSON.stringify(mock.castLog));
            const d = mock.displays.find(x => x.cast);
            root.check("c7 mock: the TV is still a display (the stand-in), labelled, mirroring the laptop",
                       !!d && d.name === mock.castDisplayName && d.label === "[TV] Living Room OLED 65" && mock.plan.specs[d.name].mirror === "eDP-1" && mock.mirroring === true,
                       JSON.stringify(mock.displays.map(x => x.name + ":" + x.label)));
            root.check("c7 mock: workspaces stay with the laptop", ["1", "2", "3", "4"].every(w => mock.plan.split[w] === "eDP-1"), JSON.stringify(mock.plan.split));
            mock.castSetMirror(false);
        },
        () => cmMock.monitor === "LARES-CAST-1" && cmMock.state === "streaming" ? undefined : "wait",
        () => {
            root.check("c7 mock: un-mirror: the cast output is made again and streamed", cmMock.monitor === "LARES-CAST-1" && mock._S.outs.find(x => x.name === "LARES-CAST-1").enabled === true
                       && !mock._S.outs.some(x => x.standIn === true) && mock.castMirrored === false, cmMock.monitor);
            mock.castSetMirror(true);
        },
        () => cmMock.monitor === "eDP-1" && cmMock.state === "streaming" ? undefined : "wait",
        () => {
            mock.castStop();
        },
        () => mock.castPhase === "idle" ? undefined : "wait",
        () => {
            root.check("c7 mock: after the stop the laptop is alone again; no 'connected' toast ever", mock.displays.length === 1 && !mock._S.outs.some(x => x.standIn === true)
                       && !mock.postedToasts.some(t => t.key.indexOf("seen:") === 0), JSON.stringify(mock.displays.map(x => x.name)) + JSON.stringify(mock.postedToasts.map(t => t.key)));
            // THE NEXT CAST OF A TV STORED AS A MIRROR MAKES NO OUTPUT AT ALL (ARM mirroroutput)
            root.mark = mock.castLog.length;
            root.check("c7 mock: a cast of a TV stored as a mirror is accepted", mock.castStart(root.tv) === true, "");
        },
        () => cmMock.state === "streaming" ? undefined : "wait",
        () => {
            const since = mock.castLog.slice(root.mark);
            root.check("c7 mock: it streams the laptop and asks the engine for NO output (ARM mirroroutput)", cmMock.monitor === "eDP-1" && !since.some(l => l.indexOf("open") === 0)
                       && !mock._S.outs.some(x => x.name === "LARES-CAST-1"), JSON.stringify(since) + cmMock.monitor);
            // a refusal is said (ARM silentrefuse)
            const other = "wfd:00:11:22:33:44:55";
            const again = mock.castStart(other);
            root.check("c7 mock: a start of another TV while one runs is refused WITH a notice on its chip (ARM silentrefuse)", again === false && mock.castNoticeFor(other) !== "", mock.castNoticeFor(other));
            mock.castDismissNotice();
            root.check("c7 mock: a click on the notice takes it away", mock.castNoticeFor(other) === "", mock.castNoticeFor(other));
            mock.castStop();
        },
        () => mock.castPhase === "idle" && cmMock.state === "idle" ? undefined : "wait",
        () => {
            // A CAST CLICK DURING THE POPUP'S SCAN IS KEPT (ARM scanswallows): prepared now, started when the scan has ended
            root.check("c7 mock: a scan is running", cmMock.scan() === true && cmMock.scanning === true, "");
            root.mark = cmMock.startCalls;
            root.check("c7 mock: a start during the scan is ACCEPTED", mock.castStart(root.tv) === true && mock.castPhase === "opening", mock.castPhase + " " + mock.castNoticeFor(root.tv));
            root.check("c7 mock: ... and held: nothing is asked of the cast service yet", cmMock.startCalls === root.mark && mock.castStatusText(root.tv) === "Waiting for the scan…", mock.castStatusText(root.tv));
        },
        () => cmMock.state === "streaming" ? undefined : "wait",
        () => {
            root.check("c7 mock: it started by itself once the scan had ended", cmMock.scanning === false && cmMock.startCalls === root.mark + 1, String(cmMock.startCalls));
            mock.castStop();
        },
        () => mock.castPhase === "idle" ? undefined : "wait",
        () => {
            root.check("c7 mock: idle at the end", mock.castPhase === "idle" && mock.displays.length === 1, mock.castPhase);
        }
    ]
    property int startsBefore: 0
    property int mstarts: 0
    property int mark: 0
    Timer {
        interval: 120
        running: true
        repeat: true
        onTriggered: {
            if (root.step < root.steps.length) {
                try {
                    const r = root.steps[root.step]();
                    if (r === "wait" && root.waits++ < 80)
                        return;
                    if (r === "wait")
                        root.check("step " + root.step + " waited too long", false, JSON.stringify(root.log) + " " + svc.castPhase + " " + cm.state);
                    root.waits = 0;
                } catch (e) {
                    root.check("step " + root.step + " threw", false, String(e));
                }
                root.step++;
                return;
            }
            stop();
            console.log("PS RESULT " + (root.fails === 0 ? "PASS" : "FAIL (" + root.fails + " checks)"));
            quit.start();
        }
    }
    Timer {
        id: quit
        interval: 0
        onTriggered: Qt.quit()
    }
}
