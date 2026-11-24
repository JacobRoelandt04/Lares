pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "modules/bar/system_update/components"

// Replays a REAL captured run and records the rail's step sequence and the
// categories each "proceed?" prompt covers.
//
// This is how a real run is reproduced without waiting for one. Mock data and
// the synthetic run agree with whatever the code already believes; a captured
// log does not — it is the only source that can contradict an assumption. Every
// fault found in the 2026-08-27 run showed up here on the first replay.
//
// Expected for that capture:
//   steps   sync -> resolve -> sources -> download -> install -> hooks -> aur
//           (strictly forward: yay revisits earlier phases, the rail must not)
//   prompts OFFICIAL_INSTALL -> [extra]   AUR_INSTALL -> [aur]
//
// Run from the repo root: PROBE_LOG=<a captured log> quickshell -p tools/dev/qml/reallog.qml
Window {
    id: win; width: 900; height: 760; visible: true; color: "#EAEDF5"
    TerminalBackend {
        id: be
        // Paced, so the phase sequence can actually be observed: dumping the
        // whole log at once lands every line before the first sample.
        // RL_DELAY: seconds per replayed line (default 0.012); RL_MS: when
        // to print the summary and quit (default 16000).
        command: "bash " + Quickshell.env("PWD") + "/tools/system_update/replay_yay_log.sh '"
                 + Quickshell.env("PROBE_LOG") + "' " + (Quickshell.env("RL_DELAY") || "0.012")
        useTTY: false
        scrollbackMax: 600
    }
    PackageUpdateParser { id: pp; backend: be }
    SystemUpdatePopup { id: popup; anchors.fill: parent; backend: be; parser: pp; railParticles: false }

    // The replay script blocks at each interactive prompt; answer them so the
    // run proceeds exactly as it did for real.
    Timer {
        interval: 400; repeat: true; running: true
        onTriggered: if (pp.awaitingUserInput || be.awaitingInput) be.submit("")
    }

    property var steps: []
    property var phases: []
    Timer {
        interval: 30; repeat: true; running: true
        onTriggered: {
            const st = popup._currentStep;
            if (st && (win.steps.length === 0 || win.steps[win.steps.length-1] !== st))
                win.steps.push(st);
            const ph = pp.phase;
            if (ph && (win.phases.length === 0 || win.phases[win.phases.length-1] !== ph))
                win.phases.push(ph);
        }
    }
    property var promptMarks: []
    property var titles: []
    property var notchCounts: []
    property string skipContext: ""
    property int skipPkgsBefore: -1
    property int skipPkgsAfter: -1
    property int maxSourcePct: -1
    property string sourceSample: ""
    property var aurStates: []
    Timer {
        interval: 60; repeat: true; running: true
        onTriggered: {
            const t = popup._cardTitle;
            if (t && (win.titles.length === 0 || win.titles[win.titles.length-1] !== t)) win.titles.push(t);
            const n = popup._phaseSteps.length;
            if (win.notchCounts.length === 0 || win.notchCounts[win.notchCounts.length-1] !== n) win.notchCounts.push(n);
            if (pp.sourceFetchPct > win.maxSourcePct) {
                win.maxSourcePct = pp.sourceFetchPct;
                win.sourceSample = pp.sourceFetchFile + " " + pp.sourceFetchBytesDone.toFixed(0) + "/" + pp.sourceFetchBytesTotal.toFixed(0) + " " + pp.sourceFetchRate + " eta " + pp.sourceFetchEta;
            }
            for (let i = 0; i < pp.packages.count; i++) {
                const pk = pp.packages.get(i);
                if (pk.isAur) {
                    const st = pk.name + ":" + pk.state;
                    if (win.aurStates.length === 0 || win.aurStates[win.aurStates.length-1] !== st) win.aurStates.push(st);
                }
            }
            if (popup._promptKind === "yay_skip_dep" && win.skipContext.length === 0) {
                win.skipContext = (pp.currentPromptContext || []).join(" | ");
                win.skipPkgsBefore = pp.packages.count;
            }
            if (win.skipPkgsBefore >= 0 && win.skipPkgsAfter < 0 && popup._promptKind !== "yay_skip_dep" && pp.phase === "OFFICIAL_INSTALL" && pp.subPhase === "L2_DOWNLOAD")
                win.skipPkgsAfter = pp.packages.count;
            if (popup._promptKind !== "pacman_proceed") return;
            const line = pp.phase + " -> [" + popup._promptCategories.join(" ") + "]";
            if (win.promptMarks.indexOf(line) < 0) win.promptMarks.push(line);
        }
    }
    Timer { interval: Number(Quickshell.env("RL_MS") || 16000); running: true; onTriggered: {
        console.log("RL proceedPrompts: " + win.promptMarks.join("   |   "));
        console.log("RL steps  : " + win.steps.join(" -> "));
        console.log("RL phases : " + win.phases.join(" -> "));
        console.log("RL titles : " + win.titles.join(" -> "));
        console.log("RL notches: " + win.notchCounts.join(" -> "));
        console.log("RL skipCtx: '" + win.skipContext + "' pkgs " + win.skipPkgsBefore + " -> " + win.skipPkgsAfter);
        console.log("RL sources: maxPct=" + win.maxSourcePct + " sample='" + win.sourceSample + "' aurSourcesDone=" + pp.aurSourcesDone);
        console.log("RL aur    : " + win.aurStates.join(" -> "));
        console.log("RL packages=" + pp.packages.count
            + " dlTotal=" + pp.downloadsTotal + " instTotal=" + pp.installsTotal);
        Qt.quit();
    } }
    Component.onCompleted: be.start()
}
