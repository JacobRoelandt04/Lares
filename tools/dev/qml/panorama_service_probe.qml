import QtQuick
import Quickshell

import "modules/common/system"
import "modules/panorama/data"

// =============================================================================
// panorama_service_probe.qml -- the REAL PanoramaService (not live: no process, no file) on a fake FocusedScreen and fake DRM facts.
// The engine's answers are written into its EngineLink's `state` the way the state file would carry them. Run by
// tools/dev/panorama_service_probe.sh (offscreen, sandboxed); prints `PS ok|FAIL <check>` and `PS RESULT PASS|FAIL`.
//
//   s1 laptop alone, engine missing: one display "Laptop", panes 1, Apply refused
//   s2 the ultrawide plugged (never seen): above and centred, unknown, takes 3-4; the glyph counts 2
//   s3 staged: a move makes it dirty; a scale change re-lays the tile out (it still touches, no overlap)
//   s4 the trial: apply -> applying; the engine says trying -> awaiting; markShown sets a 15 s deadline; keep -> the store
//      holds the setup under the set key, idle, nothing staged
//   s5 a trial the engine fails -> idle, NOTHING staged (every revert clears the edit), the diagnostic says the settings did not take;
//      the same after a revert from the toast (revert()) and after the engine's own "reverted" (the guard)
//   s6 a mirror is of the laptop only: stageSpec(mirror) on the laptop is ignored
//   s7 brightness: an external without DDC falls back to the panel (decision 28)
//   s9 the workspace chips: stage seeds the RESOLVED split (complete, not dirty), stageSplit toggles one workspace, a kept chip stores
//      only what differs from the defaults; stageReset stages the default arrangement; zero-net edits restore the layout
//   s10 the brightness surface: brightnessOf / setBrightness / brightnessRev
//   g  an output that drops out of ONE read is no "disconnected" toast; one gone for 400 ms is
//   s8 a DisplayLink dock with no service, 8 s on: the dl-service hint with its command
//   k  the MOCK, the same checks on PanoramaMock (it must follow the service where the edit is staged, applied, reverted, renamed)
// =============================================================================
ShellRoot {
    id: root

    property int fails: 0
    function check(name, ok, detail) {
        console.log("PS " + (ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  -- " + detail));
        if (!ok)
            root.fails++;
    }

    readonly property var edp: ({ name: "eDP-1", description: "Samsung Display Corp. 0x4180", make: "Samsung Display Corp.", model: "0x4180",
        serial: "", id: 0, enabled: true, width: 2880, height: 1620, refresh: 120.0, x: 0, y: 0, scale: 1.25, transform: 0,
        mirrorOf: "", physW: 340, physH: 190, modes: [{ w: 2880, h: 1620, r: 120, preferred: true }], backend: "drm",
        hdr: true, bt2020: true, vrrCapable: false, vrr: 0, bitdepth: 10, cm: "srgb", sdrbrightness: 1, sdrsaturation: 1, driver: "" })
    readonly property var lg: ({ name: "DVI-I-1", description: "Acme Displays ACME ULTRAWIDE 0x0000C0DE", make: "Acme Displays",
        model: "ACME ULTRAWIDE", serial: "0x0000C0DE", id: 1, enabled: true, width: 3440, height: 1440, refresh: 59.973,
        x: 2304, y: 0, scale: 1, transform: 0, mirrorOf: "", physW: 800, physH: 335,
        modes: [{ w: 3440, h: 1440, r: 59.973, preferred: true }, { w: 2560, h: 1080, r: 60, preferred: false }], backend: "drm",
        hdr: false, bt2020: false, vrrCapable: false, vrr: 0, bitdepth: 8, cm: "srgb", sdrbrightness: 1, sdrsaturation: 1, driver: "" })

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
    // the notifier: the shell hands the service one; this one records what it was asked to post
    QtObject {
        id: notif
        property var told: []
        signal action(string key, string id)
        function notify(key, rec) {
            const t = told.slice();
            t.push(rec.title);
            told = t;
        }
        function withdraw(key) {
        }
    }
    PanoramaService {
        id: svc
        live: false
        focusSource: focus
        drm: drm
        notifier: notif
    }
    PanoramaMock {
        id: mock
        scenario: "desk"
        timeScale: 10          // the verify at 150 ms, the guard at 1.7 s: a step (200 ms) sees awaiting
    }
    property int waits: 0

    function setOutputs(list) {
        focus.setOutputs(JSON.parse(JSON.stringify(list)));
    }
    function engineSays(trial) {
        const link = svc.engineLink;
        link.state = { v: 1, session: "probe", serial: Date.now(), trial: trial, bound: [], unknown: [] };
    }
    function touches(a, b) {
        const ox = Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x);
        const oy = Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y);
        return (ox === 0 && oy > 0) || (oy === 0 && ox > 0);
    }
    function overlaps(a, b) {
        return Math.min(a.x + a.w, b.x + b.w) - Math.max(a.x, b.x) > 0 && Math.min(a.y + a.h, b.y + b.h) - Math.max(a.y, b.y) > 0;
    }
    function rectOf(name, spec, out) {
        const m = spec.mode === "preferred" ? { w: out.width, h: out.height } : { w: +spec.mode.split("x")[0], h: +spec.mode.split("x")[1].split("@")[0] };
        const sc = spec.scale === "auto" ? out.scale : spec.scale;
        return { x: spec.position[0], y: spec.position[1], w: Math.floor(m.w / sc + 0.5), h: Math.floor(m.h / sc + 0.5) };
    }

    property int step: 0
    property var steps: [
        () => {
            root.setOutputs([root.edp]);
        },
        () => {
            root.check("s1 one display, the laptop", svc.displays.length === 1 && svc.displays[0].label === "Laptop", JSON.stringify(svc.displays.map(d => d.label)));
            root.check("s1 panes 1", svc.panes === 1, svc.panes);
            root.check("s1 engine missing", svc.engineState !== "active", svc.engineState);
            svc.stage();
            root.check("s1 apply refused while the engine is missing", svc.apply() === false, svc.phase);
            svc.discard();
            svc.engineLink.stateName = "active";
            root.setOutputs([root.edp, root.lg]);
        },
        () => {
            const p = svc.plan;
            root.check("s2 the ultrawide above, centred", JSON.stringify(p.specs["DVI-I-1"].position) === "[-568,-1440]", JSON.stringify(p.specs["DVI-I-1"]));
            root.check("s2 never seen", p.unknown.indexOf("Acme Displays ACME ULTRAWIDE 0x0000C0DE") >= 0, JSON.stringify(p.unknown));
            root.check("s2 takes workspaces 3-4", p.split["3"] === "DVI-I-1" && p.split["4"] === "DVI-I-1", JSON.stringify(p.split));
            root.check("s2 panes 2", svc.panes === 2, svc.panes);
            root.check("s2 the name is port + model", svc.displays.some(d => d.label === "DisplayLink · ACME ULTRAWIDE"), JSON.stringify(svc.displays.map(d => d.label)));
            root.setOutputs([root.edp, Object.assign({}, root.lg, { x: -568, y: -1440 })]);
        },
        () => {
            svc.stage();
            root.check("s3 nothing staged is not dirty", svc.dirty === false, svc.dirty);
            // above the laptop, its foot on the laptop's top: a smaller scale shrinks it and opens a gap only the relayout closes
            svc.stageMove("DVI-I-1", -500, -1440);
            root.check("s3 a move is dirty", svc.dirty === true, svc.dirty);
            svc.stageSpec("DVI-I-1", { scale: 1.25 });
            const a = root.rectOf("eDP-1", svc.staged["eDP-1"], root.edp), b = root.rectOf("DVI-I-1", svc.staged["DVI-I-1"], root.lg);
            root.check("s3 a size change re-lays out: touching, no overlap", root.touches(a, b) && !root.overlaps(a, b),
                       JSON.stringify([a, b]));
            root.check("s3 the laptop stays at 0,0", JSON.stringify(svc.staged["eDP-1"].position) === "[0,0]", JSON.stringify(svc.staged["eDP-1"].position));
            root.check("s3 apply starts a trial", svc.apply() === true && svc.phase === "applying", svc.phase);
            root.engineSays({ token: svc.trial.token, phase: "trying", verdict: "" });
        },
        () => {
            root.check("s4 the engine trying -> awaiting", svc.phase === "awaiting", svc.phase);
            svc.markShown();
            const left = svc.trial.deadlineMs - Date.now();
            root.check("s4 the countdown starts on the glass: 15 s", left > 14000 && left <= 15000, left);
            svc.keep();
            const st = svc.store.doc.setups[svc.setKey];
            root.check("s4 keep: the store holds the setup under the set key", !!st && !!st.outputs["Acme Displays ACME ULTRAWIDE 0x0000C0DE"], JSON.stringify(Object.keys(svc.store.doc.setups)));
            root.check("s4 keep: idle, nothing staged", svc.phase === "idle" && svc.staged === null, svc.phase);
            root.check("s4 keep: the split keeps only what differs from the defaults (here nothing)", Object.keys(svc.store.doc.split || {}).length === 0, JSON.stringify(svc.store.doc.split));
            svc.stage();
            svc.stageMove("DVI-I-1", -280, -1440);
            svc.apply();
            root.engineSays({ token: svc.trial.token, phase: "failed", verdict: "failed:DVI-I-1:refresh" });
        },
        () => {
            root.check("s5 a failed trial: idle, nothing staged (the revert took the edit with it)",
                       svc.phase === "idle" && svc.staged === null && svc.stagedSplit === null && !svc.dirty, svc.phase + " " + JSON.stringify(svc.staged));
            root.check("s5 the diagnostic says so", svc.diagnostics.some(d => d.id === "mode-failed"), JSON.stringify(svc.diagnostics.map(d => d.id)));
            // the revert from the toast
            svc.stage();
            svc.stageMove("DVI-I-1", -300, -1440);
            svc.apply();
            root.engineSays({ token: svc.trial.token, phase: "trying", verdict: "" });
        },
        () => {
            root.check("s5 the toast's Revert: awaiting first", svc.phase === "awaiting", svc.phase);
            svc.revert();
            root.check("s5 ... idle at once, nothing staged", svc.phase === "idle" && svc.staged === null && svc.stagedSplit === null, svc.phase + " " + JSON.stringify(svc.staged));
            // the engine's own revert (its guard, or an output pulled): the same
            svc.stage();
            svc.stageMove("DVI-I-1", -300, -1440);
            svc.apply();
            root.engineSays({ token: svc.trial.token, phase: "trying", verdict: "" });
        },
        () => {
            root.engineSays({ token: svc.trial.token, phase: "reverted", verdict: "" });
        },
        () => {
            root.check("s5 the engine's own revert: idle, nothing staged", svc.phase === "idle" && svc.staged === null && svc.stagedSplit === null, svc.phase);
            svc.stage();
            svc.stageSpec("eDP-1", { mirror: true });
            root.check("s6 the laptop never mirrors", svc.staged["eDP-1"].mirror === false, JSON.stringify(svc.staged["eDP-1"]));
            svc.stageSpec("DVI-I-1", { mirror: true });
            root.check("s6 an external mirrors the laptop", svc.staged["DVI-I-1"].mirror === true, JSON.stringify(svc.staged["DVI-I-1"]));
            svc.discard();
            const t = svc.brightnessTarget("DVI-I-1");
            root.check("s7 an external is the keys' target even with no DDC (never the laptop's panel)", t.kind === "ddc" && t.connector === "DVI-I-1", JSON.stringify(t));
            root.check("s7 the laptop's own keys reach its panel", svc.brightnessTarget("eDP-1").kind === "panel", JSON.stringify(svc.brightnessTarget("eDP-1")));
        },
        // ---- s9 the chips, reset, zero-net edits
        () => {
            const lap = svc.plan.ids["eDP-1"], ext = svc.plan.ids["DVI-I-1"];
            const want = JSON.stringify({ "1": lap, "2": lap, "3": ext, "4": ext });
            root.check("s9 the chips read the split in force: complete, by identity", JSON.stringify(svc.splitIdents) === want, JSON.stringify(svc.splitIdents));
            svc.stage();
            root.check("s9 stage seeds that resolved split, and it is not dirty", JSON.stringify(svc.stagedSplit) === want && !svc.dirty, JSON.stringify(svc.stagedSplit) + " " + svc.dirty);
            svc.stageSplit("3", ext);
            root.check("s9 a click on the chip a workspace is on gives it back to the laptop", svc.splitIdents["3"] === lap && svc.dirty, JSON.stringify(svc.splitIdents));
            svc.stageSplit("3", ext);
            root.check("s9 ... and the next click puts it on the external again: no change", svc.splitIdents["3"] === ext && !svc.dirty, JSON.stringify(svc.splitIdents));
            svc.stageSplit("1", ext);
            root.check("s9 workspace 1 on the external is a change", svc.splitIdents["1"] === ext && svc.dirty, JSON.stringify(svc.splitIdents));
            svc.discard();
            root.check("s9 discard: the chips read what is in force again", JSON.stringify(svc.splitIdents) === want && svc.stagedSplit === null, JSON.stringify(svc.splitIdents));
            // EVERY DISPLAY KEEPS ONE WORKSPACE (a display left with none shows a fifth of Hyprland's own): the last chip does not come off
            svc.stage();
            svc.stageSplit("3", ext);
            svc.stageSplit("4", ext);
            root.check("s9 the external's last workspace stays on it (ARM lastchip)", svc.splitIdents["3"] === lap && svc.splitIdents["4"] === ext, JSON.stringify(svc.splitIdents));
            svc.stageSplit("1", ext);
            svc.stageSplit("2", ext);
            svc.stageSplit("3", ext);
            root.check("s9 ... and so does the laptop's last", svc.splitIdents["1"] === ext && svc.splitIdents["2"] === ext && svc.splitIdents["3"] === lap, JSON.stringify(svc.splitIdents));
            svc.discard();
            svc.stage();
            svc.stageSplit("1", ext);
            root.check("s9 apply with a chip starts", svc.apply() === true, svc.phase);
            root.engineSays({ token: svc.trial.token, phase: "trying", verdict: "" });
        },
        () => {
            svc.markShown();
            svc.keep();
            const ext = svc.plan.ids["DVI-I-1"];
            root.check("s9 keep: the split holds only workspace 1 (the rest is the default)", JSON.stringify(svc.store.doc.split) === JSON.stringify({ "1": ext }), JSON.stringify(svc.store.doc.split));
            // reset: the default arrangement of this set as if it had never been seen
            svc.stage();
            svc.stageMove("DVI-I-1", -900, -1440);
            svc.stageReset();
            root.check("s9 stageReset: the default place again (above, centred), the default split, staged", JSON.stringify(svc.staged["DVI-I-1"].position) === "[-568,-1440]"
                       && svc.phase === "staged" && svc.splitIdents["1"] === svc.plan.ids["eDP-1"], JSON.stringify(svc.staged["DVI-I-1"].position) + " " + svc.phase + " " + JSON.stringify(svc.splitIdents));
            root.check("s9 ... and it is a change to apply (the stored setup differs)", svc.dirty, svc.dirty);
            svc.discard();
            // zero-net: a size change and its undo leave the layout where it was
            svc.stage();
            const sc0 = svc.staged["DVI-I-1"].scale;
            svc.stageMove("DVI-I-1", -300, -Math.round(1440 / sc0));         // its foot on the laptop's top: it hangs on the laptop
            const before = JSON.stringify([svc.staged["eDP-1"].position, svc.staged["DVI-I-1"].position]);
            svc.stageSpec("DVI-I-1", { scale: 1.5 });
            svc.stageSpec("DVI-I-1", { scale: sc0 });
            const after = JSON.stringify([svc.staged["eDP-1"].position, svc.staged["DVI-I-1"].position]);
            root.check("s9 zero-net: a scale and its undo restore the layout", before === after, before + " -> " + after);
            // a quarter turn makes the tile overlap the laptop, so the layout must move it; the turn back must put everything back
            svc.stageSpec("DVI-I-1", { transform: 1 });
            const turned = JSON.stringify([svc.staged["eDP-1"].position, svc.staged["DVI-I-1"].position]);
            svc.stageSpec("DVI-I-1", { transform: 0 });
            root.check("s9 zero-net: a quarter turn moved it (the picture was not trivial) and the turn back restores the layout", turned !== before
                       && before === JSON.stringify([svc.staged["eDP-1"].position, svc.staged["DVI-I-1"].position]), before + " -> " + turned + " -> " + JSON.stringify(svc.staged["DVI-I-1"].position));
            svc.stageSpec("DVI-I-1", { enabled: false });
            svc.stageSpec("DVI-I-1", { enabled: true });
            root.check("s9 zero-net: off and on restore it", before === JSON.stringify([svc.staged["eDP-1"].position, svc.staged["DVI-I-1"].position]), JSON.stringify(svc.staged["DVI-I-1"].position));
            svc.discard();
        },
        // ---- s10 the brightness surface
        () => {
            const a = svc.brightnessOf("eDP-1"), b = svc.brightnessOf("DVI-I-1");
            root.check("s10 the internal panel: not capable here (stream A3), no value, a reason", a.capable === false && a.value === -1 && a.pending === false && a.reason !== "", JSON.stringify(a));
            root.check("s10 an external without DDC: not capable, a reason, not pending (not live)", b.capable === false && b.value === -1 && b.pending === false && b.reason !== "", JSON.stringify(b));
            svc.setBrightness("DVI-I-1", 0.5);
            root.check("s10 brightnessRev is an int and setBrightness on a display without DDC does nothing", Number.isInteger(svc.brightnessRev), svc.brightnessRev);
        },
        // ---- g an output that drops out of one read
        () => {
            root.setOutputs([root.edp]);
        },
        () => {
            root.setOutputs([root.edp, Object.assign({}, root.lg, { x: -568, y: -1440 })]);
        },
        () => {
            root.check("g one read without the external: no \"disconnected\" toast once it is back", !notif.told.some(t => t.indexOf("disconnected") >= 0), JSON.stringify(notif.told));
            root.setOutputs([root.edp]);
        },
        () => {
            root.check("g gone for under 400 ms: nothing told yet", !notif.told.some(t => t.indexOf("disconnected") >= 0), JSON.stringify(notif.told));
        },
        () => {
            return notif.told.some(t => t.indexOf("disconnected") >= 0) ? "" : "wait";
        },
        () => {
            root.check("g gone for good: told once", notif.told.filter(t => t.indexOf("disconnected") >= 0).length === 1, JSON.stringify(notif.told));
            drm.displayLinkActive = false;
            drm.displayLinkSince = Date.now() - 20000;
            drm.displayLinkUsb = true;
        },
        () => {
            const d = svc.diagnostics.find(x => x.id === "dl-service");
            root.check("s8 a dock with no service: the hint and its command", !!d && d.command === "sudo systemctl enable --now displaylink.service",
                       JSON.stringify(svc.diagnostics));
        },
        // ---- k the mock: the same facts on PanoramaMock
        () => {
            const lap = mock.plan.ids["eDP-1"], ext = mock.plan.ids["DVI-I-1"];
            root.mockIds = { lap: lap, ext: ext, all: mock.splitIdents };
            const keys = Object.keys(mock.splitIdents).sort().join();
            root.check("k the chips read the split in force: complete, by identity", keys === "1,2,3,4" && mock.splitIdents["1"] === lap && mock.splitIdents["3"] === ext, JSON.stringify(mock.splitIdents));
            mock.stage();
            root.check("k stage seeds the resolved split; not dirty", JSON.stringify(mock.stagedSplit) === JSON.stringify(root.mockIds.all) && !mock.dirty, JSON.stringify(mock.stagedSplit) + " " + mock.dirty);
            mock.stageSplit("3", ext);
            root.check("k a click on the chip a workspace is on gives it back to the laptop", mock.splitIdents["3"] === lap && mock.dirty, JSON.stringify(mock.splitIdents));
            mock.stageSplit("3", ext);
            root.check("k ... and the next click is no change", mock.splitIdents["3"] === ext && !mock.dirty, JSON.stringify(mock.splitIdents));
            mock.stageSplit("1", ext);
            root.check("k apply with a chip: the staged edit LIVES through the trial", mock.apply() === true && mock.staged !== null && mock.phase === "applying", mock.phase);
        },
        () => {
            return mock.phase === "awaiting" ? "" : "wait";
        },
        () => {
            root.check("k awaiting: the edit is still staged", mock.staged !== null, "");
            mock.revert();
            root.check("k revert: idle, nothing staged, nothing in the split", mock.phase === "idle" && mock.staged === null && mock.stagedSplit === null, mock.phase);
            root.check("k ... the chips read what is in force (workspace 1 on the laptop)", mock.splitIdents["1"] === root.mockIds.lap, JSON.stringify(mock.splitIdents));
            mock.failNextTrial = true;
            mock.stage();
            mock.stageMove("DVI-I-1", -300, -1440);
            mock.apply();
        },
        () => {
            return mock.phase === "idle" && mock.trial.verdict !== "" ? "" : "wait";
        },
        () => {
            root.check("k a trial the hardware refuses: idle, nothing staged, a verdict", mock.staged === null && mock.trial.verdict.indexOf("failed:") === 0, mock.phase + " " + mock.trial.verdict);
            mock.stage();
            mock.stageSplit("1", root.mockIds.ext);
            mock.apply();
        },
        () => {
            return mock.phase === "awaiting" ? "" : "wait";
        },
        () => {
            mock.keep();
            root.check("k keep: idle, nothing staged, the split holds only workspace 1", mock.phase === "idle" && mock.staged === null
                       && JSON.stringify(mock._S.data.split) === JSON.stringify({ "1": root.mockIds.ext }), mock.phase + " " + JSON.stringify(mock._S.data.split));
            mock.renameSetup(mock.setKey, "Mine");
            const named = mock.setupName;
            mock.renameSetup(mock.setKey, "");
            root.check("k rename to \"\" gives the automatic name back (as the service does)", named === "Mine" && mock.setupName !== "" && mock.setupName !== "Mine"
                       && mock.setups.find(x => x.live).custom === false, named + " / " + mock.setupName);
            mock.stage();
            mock.stageMove("DVI-I-1", -900, -1440);
            mock.stageReset();
            root.check("k stageReset: staged, the default place, a change to apply", mock.phase === "staged" && mock.dirty
                       && JSON.stringify(mock.staged["DVI-I-1"].position) !== "[-900,-1440]", mock.phase + " " + JSON.stringify(mock.staged["DVI-I-1"].position));
            mock.discard();
            mock.stage();
            const before = JSON.stringify(Object.keys(mock.staged).sort().map(n => mock.staged[n].position));
            mock.stageSpec("DVI-I-1", { scale: 1.5 });
            mock.stageSpec("DVI-I-1", { scale: mock.plan.specs["DVI-I-1"].scale });
            root.check("k zero-net: a scale and its undo restore the layout", before === JSON.stringify(Object.keys(mock.staged).sort().map(n => mock.staged[n].position)), before);
            mock.stageSpec("DVI-I-1", { transform: 1 });
            const turned = JSON.stringify(Object.keys(mock.staged).sort().map(n => mock.staged[n].position));
            mock.stageSpec("DVI-I-1", { transform: 0 });
            root.check("k zero-net: a quarter turn and the turn back restore the layout", turned !== before && before === JSON.stringify(Object.keys(mock.staged).sort().map(n => mock.staged[n].position)), before + " -> " + turned);
            mock.discard();
        },
        () => {
            mock.scenario = "three";
        },
        () => {
            const ddc = mock.displays.find(d => d.ddc.capable);
            const b = mock.brightnessOf("eDP-1"), c = ddc ? mock.brightnessOf(ddc.name) : null;
            root.check("k brightness: the internal panel is not capable, a DDC display is, 0..1", b.capable === false && !!c && c.capable === true && c.value >= 0 && c.value <= 1, JSON.stringify([b, c]));
            const rev = mock.brightnessRev;
            if (ddc)
                mock.setBrightness(ddc.name, 0.25);
            root.check("k setBrightness moves the answer and brightnessRev", !!ddc && Math.abs(mock.brightnessOf(ddc.name).value - 0.25) < 0.011 && mock.brightnessRev > rev, ddc ? JSON.stringify(mock.brightnessOf(ddc.name)) : "no DDC display");
        }
    ]
    property var mockIds: ({})
    Timer {
        interval: 200
        running: true
        repeat: true
        onTriggered: {
            if (root.step < root.steps.length) {
                try {
                    const r = root.steps[root.step]();
                    if (r === "wait" && root.waits++ < 50)
                        return;
                    if (r === "wait")
                        root.check("step " + root.step + " waited too long", false, "");
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
