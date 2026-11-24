pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import "modules/bar/system_update/components"

// su_reopen_probe -- a system update popup REOPENED mid-run (the run lives in the service, the content is new).
//
// A real captured run is replayed through TerminalBackend + PackageUpdateParser (the service's part, which outlives the popup).
// The popup sits in a Loader that is switched off and on again at three points of the run (mid-download, mid-install, mid-hooks).
// For each reopen the NEW content's rail is watched for 1.2 s: where the ball was at its first sample, and -- only while the run's
// target has NOT moved since the content was born -- how far the ball ever strayed from it and how many spark bursts it threw. A
// ball that moves while its target stands still is flying to where the run already was: a flight from notch 0. (Once the run
// moves the target, the ball follows and sparks as it always did; that is live progress and not counted.)
//
// SU_MODE=seat  (default) : the content seats its ball (PASS when every reopen starts at the target and throws nothing)
// RL_LOG=<transcript>  RL_DELAY=<s per line>  RL_MS=<ms before giving up>
Window {
    id: win; width: 900; height: 760; visible: true; color: "#EAEDF5"

    TerminalBackend {
        id: be
        command: "bash " + Quickshell.env("PWD") + "/tools/system_update/replay_yay_log.sh '"
                 + Quickshell.env("PROBE_LOG") + "' " + (Quickshell.env("RL_DELAY") || "0.004")
        useTTY: false
        scrollbackMax: 600
    }
    PackageUpdateParser { id: pp; backend: be }

    property bool shown: true
    Loader {
        id: host
        anchors.fill: parent
        active: win.shown
        sourceComponent: SystemUpdatePopup {
            backend: be; parser: pp; railParticles: true
        }
    }

    Timer {
        interval: 400; repeat: true; running: true
        onTriggered: if (pp.awaitingUserInput || be.awaitingInput) be.submit("")
    }

    function findRail(it) {
        if (!it) return null;
        if (it.objectName === "phaseRail") return it;
        const kids = it.children;
        for (let i = 0; i < kids.length; i++) {
            const r = win.findRail(kids[i]);
            if (r) return r;
        }
        return null;
    }

    // ---- what a reopen records (a var object: a counter property would be a dependency) ----
    property var rec: ({})
    property var reopens: []
    property var rail: null
    property real railBorn: 0

    function watchRail() {
        const r = win.findRail(host.item);
        win.rail = r;
        win.railBorn = Date.now();
        win.rec = { first: r ? r.ballPos : -1, target: r ? r._targetPos : -1, maxLag: 0, sparks: 0, sparksEarly: 0, moves: 0 };
        win.collecting = true;
        collectEnd.restart();
    }
    property bool collecting: false
    Connections {
        target: win.rail
        ignoreUnknownSignals: true
        function onBallPosChanged() {
            if (!win.collecting || !win.rail) return;
            win.rec.moves++;
            win.sampleLag();
        }
        function on_LastSparkMsChanged() {
            if (!win.collecting) return;
            win.rec.sparks++;
            if (Math.abs(win.rail._targetPos - win.rec.target) < 1e-6) win.rec.sparksEarly++;
        }
    }
    Timer {      // the lag is also read on a clock: a flight that has not moved yet would otherwise show nothing
        interval: 16; repeat: true; running: win.collecting
        onTriggered: if (win.rail) win.sampleLag()
    }
    function sampleLag() {
        if (Math.abs(win.rail._targetPos - win.rec.target) < 1e-6)
            win.rec.maxLag = Math.max(win.rec.maxLag, Math.abs(win.rail.ballPos - win.rec.target));
    }
    Timer {
        id: collectEnd
        interval: 1200
        onTriggered: {
            win.collecting = false;
            const r = win.rec;
            win.reopens.push({ at: win.stage, first: r.first, target: r.target, maxLag: r.maxLag, sparks: r.sparks, early: r.sparksEarly });
            console.log("SURE reopen " + win.stage + ": ballAtBirth=" + r.first.toFixed(3) + " targetAtBirth=" + r.target.toFixed(3)
                        + " strayWhileTargetStill=" + r.maxLag.toFixed(3) + " sparksAll=" + r.sparks + " sparksWhileTargetStill=" + r.sparksEarly);
            win.stage = "";
        }
    }

    // GRAB_DIR=<dir>: the first reopen is photographed at 40 / 160 / 320 / 640 ms after the content's birth (a before/after sheet)
    property var grabAt: [40, 160, 320, 640]
    property int grabIdx: 0
    property string grabDir: Quickshell.env("GRAB_DIR") || ""
    Timer {
        id: grabTimer
        repeat: false
        onTriggered: {
            const idx = win.grabIdx, ms = win.grabAt[idx];
            win.grabIdx++;
            host.grabToImage(function (res) { res.saveToFile(win.grabDir + "/reopen_" + ms + ".png"); });
            win.armGrab();
        }
    }
    function armGrab() {
        if (win.grabDir === "" || win.done !== 1 || win.grabIdx >= win.grabAt.length) return;
        const prev = win.grabIdx === 0 ? 0 : win.grabAt[win.grabIdx - 1];
        grabTimer.interval = win.grabAt[win.grabIdx] - prev;
        grabTimer.restart();
    }

    property string stage: ""
    property int done: 0          // reopens finished
    // ---- when to reopen ----
    function wanted() {
        if (win.stage !== "" || win.collecting) return "";
        if (win.done === 0 && pp.downloadPct >= 30 && pp.downloadPct < 90) return "download";
        if (win.done === 1 && pp.subPhase === "L5_CHANGES" && pp.installsTotal > 0 && pp.installsDone / pp.installsTotal >= 0.4) return "install";
        if (win.done === 2 && pp.hooksTotal > 0 && pp.hooksDone / pp.hooksTotal >= 0.4 && pp.subPhase !== "L4_PREHOOKS" && pp.subPhase !== "L5_CHANGES") return "hooks";
        return "";
    }
    Timer {
        interval: 40; repeat: true; running: true
        onTriggered: {
            const w = win.wanted();
            if (w === "") return;
            win.stage = w;
            win.done++;
            win.shown = false;           // the content goes
            reopenTimer.restart();
        }
    }
    Timer {
        id: reopenTimer
        interval: 250
        onTriggered: { win.shown = true; win.watchRail(); win.armGrab(); }
    }

    Timer {
        interval: Number(Quickshell.env("RL_MS") || 90000); running: true
        onTriggered: win.finish()
    }
    Timer {      // all three reopens recorded
        interval: 200; repeat: true; running: true
        onTriggered: if (win.done >= 3 && !win.collecting && win.stage === "") win.finish()
    }
    property bool finished: false
    function finish() {
        if (win.finished) return;
        win.finished = true;
        const need = (Quickshell.env("SU_EXPECT") || "seat");
        let bad = [];
        if (win.reopens.length < 3) bad.push("only " + win.reopens.length + " reopens happened");
        for (const r of win.reopens) {
            if (need === "seat") {
                if (Math.abs(r.first - r.target) > 0.02) bad.push(r.at + ": ball not seated at birth (" + r.first.toFixed(3) + " vs " + r.target.toFixed(3) + ")");
                if (r.maxLag > 0.15) bad.push(r.at + ": lag " + r.maxLag.toFixed(3));
                if (r.early > 0) bad.push(r.at + ": " + r.early + " spark bursts while the run had not moved");
            } else {   // the armed copy must show the flight
                if (r.maxLag > 0.15 || r.early > 0) bad.push(r.at + ": flight seen");
            }
        }
        if (need === "seat") console.log("SURE RESULT " + (bad.length ? "FAIL (" + bad.join("; ") + ")" : "PASS (" + win.reopens.length + " reopens seated, no early sparks)"));
        else console.log("SURE " + (bad.length ? "FAIL flight seen: " + bad.join("; ") : "PASS no flight") + " (armed copy)");
        Qt.quit();
    }
    Component.onCompleted: be.start()
}
