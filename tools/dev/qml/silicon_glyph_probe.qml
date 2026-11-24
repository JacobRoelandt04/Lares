import QtQuick
import "modules/silicon"
import "modules/silicon/data"
import "modules/silicon/data/SiliconModel.js" as Model

// The bar's GPU glyph shows the true mode from its first frame, or nothing (round 7, 2026-11-10: after the boot back from dGPU-only the
// glyph drew Hybrid until the popup opened and forced a read). Three parts, one verdict line `SGLYPH RESULT PASS|FAIL`:
//   model   the step is `known` only once cardwire and the helper have answered (a source that says nothing is known);
//   client  a CardwireClient whose first read fails (the daemon is up but busy: a shim fails the first read of Mode) asks again soon
//           (not a minute later) and is `settled` only once it has an answer (or `failsToSettle` silent asks);
//   button  the GPU's glyph is not drawn and does not move while `gpuKnown` is false; the first mode lands with no flourish, then it
//           fades in; a mode that changes AFTER that plays its glyph's flourish (so "no flourish" above is not a dead clock).
// Runner: tools/dev/silicon_glyph_probe.sh (a private session bus; the stand-in is started from here).
Item {
    id: root
    width: 400
    height: 120

    property var fails: []
    property int checks: 0
    function check(id, ok, detail) {
        root.checks++;
        console.log("SGLYPH " + id + ": " + (ok ? "ok" : "FAIL") + (detail ? "  " + detail : ""));
        if (!ok)
            root.fails.push(id);
    }
    function j(x) { return JSON.stringify(x); }

    // ---- model ----
    function facts(cw, helper, display) {
        return Model.buildFacts({
            config: Model.defaultConfig(), helper: helper, status: null, sensors: null, cardwire: cw,
            smi: null, battery: null, overheadW: 0, lastFullMs: 0, hold: null, muxOutcomeSeenAt: 0, display: display
        }).gpu;
    }
    function modelChecks() {
        const quiet = { installed: true, ok: true, why: "", answered: true };
        const a = root.facts({ present: false, asked: false, why: "not asked" }, { installed: false, ok: false, why: "not asked", answered: false });
        root.check("model-unasked", a.known === false, j([a.known, a.step]));
        const b = root.facts({ present: true, asked: true, mode: 0, modes: [0, 1, 3] }, { installed: false, ok: false, why: "not asked", answered: false });
        root.check("model-helper-unasked", b.known === false, j([b.known, b.step]));
        const c = root.facts({ present: true, asked: false, mode: 0, modes: [0, 1, 3] }, quiet);
        root.check("model-cardwire-unasked", c.known === false, j([c.known, c.step]));
        const d = root.facts({ present: true, asked: true, mode: 0, modes: [0, 1, 3] }, quiet);
        root.check("model-answered", d.known === true && d.step === 0, j([d.known, d.step]));
        const e = root.facts({ present: false, asked: true, why: "no cardwire" }, { installed: false, ok: false, why: "not installed", answered: true });
        root.check("model-answered-absent", e.known === true, j([e.known, e.step]));
        const f = root.facts({ present: true, mode: 1, modes: [0, 1, 3] }, { installed: true, ok: true, why: "" });
        root.check("model-silent-source-known", f.known === true && f.step === 2, j([f.known, f.step]));
        // IN USE (feedback/silicon.md "Gpu glyph faint when dgpu awake"): Hybrid, the card awake and nobody on it but the compositor
        // that draws an external display on its HDMI connector -- the glyph is lit, not faint; without the display it is idle, and
        // asleep it is never in use
        const awake = { present: true, asked: true, mode: 1, modes: [0, 1, 3], dState: "D0", holders: [] };
        const g = root.facts(awake, quiet, { hdmi: true });
        root.check("model-hdmi-in-use", g.awake === true && g.inUse === true, j([g.step, g.awake, g.inUse]));
        const h = root.facts(awake, quiet, { hdmi: false });
        root.check("model-awake-idle", h.awake === true && h.inUse === false, j([h.step, h.awake, h.inUse]));
        const k = root.facts(Object.assign({}, awake, { dState: "D3cold" }), quiet, { hdmi: true });
        root.check("model-asleep-not-in-use", k.inUse === false, j([k.step, k.awake, k.inUse]));
    }

    // ---- client: started before the daemon exists ----
    CardwireClient {
        id: cw
        bus: "session"
    }

    // ---- button ----
    SiliconBarButton {
        id: btn
        x: 20
        y: 20
        fontFamily: "Inter"
        gpuMode: 2
        gpuKnown: false
    }

    property int plays: 0
    Connections {
        target: btn.face.gpuItem.flourishClock
        function onPlayed(why) {
            root.plays++;
        }
    }

    property int phase: 0
    property real t0: 0
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: root.tick()
    }
    function tick() {
        const now = Date.now();
        const gpu = btn.face.gpuItem;
        if (root.phase === 0) {
            root.t0 = now;
            root.modelChecks();
            cw.start();
            root.check("button-hidden-unknown", gpu.opacity === 0 && gpu.live === false && gpu.flourishClock.armed === false, j([gpu.opacity, gpu.live, gpu.flourishClock.armed]));
            root.phase = 1;
        } else if (root.phase === 1 && now - root.t0 > 400) {
            root.check("client-not-yet", cw.present === false && cw.settled === false, j([cw.present, cw.settled, cw.why]));
            root.phase = 2;
        } else if (root.phase === 2) {
            root.phase = 3;
        } else if (root.phase === 3) {
            if (cw.present && cw.mode >= 0) {
                const dt = now - root.t0;
                root.check("client-reads-soon", dt < 6000 && cw.settled === true, "read " + dt + " ms after the start, mode " + cw.mode);
                root.phase = 4;
                // the button: the mode arrives while the card is not live, snaps, then the card shows
                btn.gpuMode = 0;
                root.t0 = now;
            } else if (now - root.t0 > 12000) {
                root.check("client-reads-soon", false, "cardwire still not read 12 s after the start; why: " + cw.why);
                root.finish();
            }
        } else if (root.phase === 4) {
            root.check("button-mode-silent", gpu.opacity === 0 && gpu.mode === 0 && gpu.shownMode === 0 && gpu.moving === false && root.plays === 0, j([gpu.opacity, gpu.mode, gpu.shownMode, gpu.moving, root.plays]));
            btn.gpuKnown = true;
            root.phase = 5;
        } else if (root.phase === 5 && now - root.t0 > 700) {
            root.check("button-shows-known", gpu.opacity === 1 && gpu.live === true && gpu.mode === 0 && gpu.moving === false && root.plays === 0, j([gpu.opacity, gpu.live, gpu.mode, gpu.moving, root.plays]));
            // now a mode is an event
            btn.gpuMode = 2;
            root.t0 = now;
            root.phase = 6;
        } else if (root.phase === 6 && now - root.t0 > 150) {
            root.check("button-mode-plays", root.plays === 1 && gpu.shownMode === 2 && gpu.moving === true, j([root.plays, gpu.shownMode, gpu.moving]));
            root.finish();
        }
    }
    function finish() {
        root.phase = 99;
        console.log("SGLYPH RESULT " + (root.fails.length === 0 && root.checks > 0 ? "PASS" : "FAIL") + " (" + root.checks + " checks" + (root.fails.length ? "; failed: " + root.fails.join(", ") : "") + ")");
        quit.start();
    }
    Timer { id: quit; interval: 200; onTriggered: Qt.quit() }
    Timer { interval: 40000; running: true; onTriggered: { console.log("SGLYPH RESULT FAIL (deadline)"); Qt.quit(); } }
}
