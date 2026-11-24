import QtQuick
import Quickshell

import "modules/panorama/data"

// =============================================================================
// cast_service_probe.qml -- the REAL CastService (live) on a STUB tool (tools/dev/fixtures/cast/cast_stub_tool: canned JSON lines, the scenario
// chosen by the device id's last octet) and CastMock. Run by tools/dev/cast_service_probe.sh (offscreen, sandboxed); prints `CS ok|FAIL <check>`
// and `CS RESULT PASS|FAIL`.
// =============================================================================
ShellRoot {
    id: root

    property int fails: 0
    property var log: []
    property int startedN: 0
    property int endedN: 0
    property var endedReasons: []
    property var seen: []
    property int beats: 0
    property var modelBefore: null

    function check(name, ok, detail) {
        console.log("CS " + (ok ? "ok   " : "FAIL ") + name + (ok ? "" : "  -- " + detail));
        if (!ok)
            root.fails++;
    }

    CastService {
        id: blank
    }

    CastService {
        id: svc
        live: true
        toolPath: Quickshell.env("CAST_STUB")
        killAfterMs: 4000
        onStarted: (d, m) => {
            root.startedN++;
            root.log = root.log.concat(["started:" + d + "@" + m]);
        }
        onEnded: reason => {
            root.endedN++;
            root.endedReasons = root.endedReasons.concat([reason]);
            root.log = root.log.concat(["ended:" + reason]);
        }
        onStatsChanged: {
            if (svc.stats !== null)
                root.beats++;
        }
        onStateChanged: {
            if (root.seen[root.seen.length - 1] !== svc.state)
                root.seen = root.seen.concat([svc.state]);
        }
    }

    CastMock {
        id: mock
        stepMs: 25
        beatMs: 25
        stopMs: 25
        scanMs: 50
        property int startedN: 0
        property var endedList: []
        onStarted: startedN++
        onEnded: reason => endedList = endedList.concat([reason])
    }

    function dev(n) {
        return "wfd:00:00:00:00:00:0" + n;
    }
    function reset() {
        root.startedN = 0;
        root.endedN = 0;
        root.endedReasons = [];
        root.log = [];
        root.seen = [];
    }

    // The sequence: each step runs `go`, then waits for `until` (polled), then `then` judges. `ms` is the wall budget.
    property int idx: 0
    property real stepAt: 0
    property bool entered: false
    readonly property var steps: [
        {
            go: () => {
                root.check("s0 a service nobody made live reaches nothing", blank.start(root.dev(1), "X", {}) === false && blank.scan() === false && blank.state === "idle", blank.state);
            },
            until: () => true,
            then: () => {}
        },
        {
            go: () => {
                root.check("s1 scan accepted, scanning true", svc.scan() === true && svc.scanning === true, svc.scanning);
                root.check("s1 a second scan while scanning is refused", svc.scan() === false, "");
                root.check("s1 a cast while scanning is refused", svc.start(root.dev(1), "X", {}) === false, "");
            },
            until: () => !svc.scanning,
            then: () => {
                root.check("s1 two devices with facts", svc.devices.length === 2 && svc.devices[0].id === "wfd:02:AE:00:00:0A:01" && svc.devices[0].capable === true && svc.devices[1].capable === false && svc.devices[1].note !== "", JSON.stringify(svc.devices));
                root.check("s1 scanInfo", svc.scanInfo.fluxcast === "0.3.0" && svc.scanInfo.shim === true, JSON.stringify(svc.scanInfo));
            }
        },
        {
            go: () => {
                svc.scanSeconds = 7;
                svc.scan();
            },
            until: () => !svc.scanning,
            then: () => {
                svc.scanSeconds = 8;
                root.check("s2 a failed scan says why and keeps the list", svc.scanError.indexOf("scan: NetworkManager has no Wi-Fi Direct device") === 0 && svc.devices.length === 2, svc.scanError);
            }
        },
        {
            go: () => {
                root.reset();
                root.check("s3 start accepted: connecting at once", svc.start(root.dev(1), "LARES-CAST-1", { res: "1920x1080" }) === true && svc.state === "connecting" && svc.device === root.dev(1) && svc.monitor === "LARES-CAST-1", svc.state);
                root.check("s3 a second start while casting is refused", svc.start(root.dev(2), "Y", {}) === false, "");
            },
            until: () => svc.state === "streaming" && svc.figures._known.figures !== null && svc.figures._known.figures.dropped >= 2,
            then: () => {
                // the figures: kept quietly while nobody shows them, published with the hold, every beat, taken back with the last release
                root.check("s3 nobody shows the figures: none are published", svc.stats === null && root.beats === 0, JSON.stringify(svc.stats));
                svc.holdStats();
                root.check("s3 the first hold publishes what is known at once", svc.stats !== null && svc.stats.dropped >= 2 && svc.stats.fps === 30 && root.beats === 1, JSON.stringify(svc.stats));
                svc.holdStats();
                svc.releaseStats();
                root.check("s3 one of two showers leaves: the figures stay", svc.stats !== null, "");
                root.modelBefore = svc._m;
            },
            tail: () => svc.stats !== null && svc.stats.dropped >= 4,
            after: () => {
                root.check("s3 every beat is published while held, and touches nothing else of the cast", root.beats >= 3 && svc._m === root.modelBefore, root.beats);
                svc.releaseStats();
                root.check("s3 the last release takes them back", svc.stats === null && svc.figures.holds === 0, JSON.stringify(svc.stats));
            }
        },
        {
            go: () => {},
            until: () => true,
            then: () => {
                root.check("s3 the states came in order, none back", JSON.stringify(root.seen) === JSON.stringify(["connecting", "negotiating", "streaming"]), JSON.stringify(root.seen));
                root.check("s3 mode, started once with its arguments, flow", JSON.stringify(svc.mode) === JSON.stringify({ width: 1920, height: 1080, fps: 30 }) && root.startedN === 1 && root.log[0] === "started:" + root.dev(1) + "@LARES-CAST-1", JSON.stringify([svc.mode, root.log]));
                root.check("s3 a scan while casting is refused", svc.scan() === false && svc.scanning === false, svc.scanning);
                svc.stop();
                root.check("s3 stop: stopping at once", svc.state === "stopping", svc.state);
            },
            tail: () => svc.state === "idle",
            after: () => {
                root.check("s3 ended exactly once, \"stopped\", after started", root.endedN === 1 && root.endedReasons[0] === "stopped" && JSON.stringify(root.log) === JSON.stringify(["started:" + root.dev(1) + "@LARES-CAST-1", "ended:stopped"]), JSON.stringify(root.log));
            }
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(2), "LARES-CAST-1", {});
            },
            until: () => svc.state === "streaming",
            then: () => {
                root.check("s4 a line split across two reads arrives whole", JSON.stringify(svc.mode) === JSON.stringify({ width: 1920, height: 1080, fps: 30 }), JSON.stringify(svc.mode));
                svc.stop();
            },
            tail: () => svc.state === "idle",
            after: () => {}
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(3), "LARES-CAST-1", {});
            },
            until: () => svc.state === "failed",
            then: () => {
                root.check("s5 a failure: reason and detail, ended \"failed\" once, never started", svc.failure.reason === "activation" && svc.failure.detail.indexOf("Timed out") === 0 && root.endedN === 1 && root.endedReasons[0] === "failed" && root.startedN === 0, JSON.stringify([svc.failure, root.log]));
                svc.clearFailure();
                root.check("s5 clearFailure goes idle", svc.state === "idle" && svc.failure === null, svc.state);
            }
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(4), "LARES-CAST-1", {});
            },
            until: () => svc.state === "connecting" && root.stepAge() > 600,
            then: () => {
                svc.stop();
                root.check("s6 stop mid-connect: stopping", svc.state === "stopping", svc.state);
            },
            tail: () => svc.state === "idle",
            after: () => {
                root.check("s6 ended \"stopped\" once, never started", root.endedN === 1 && root.endedReasons[0] === "stopped" && root.startedN === 0, JSON.stringify(root.log));
            }
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(5), "LARES-CAST-1", {});
            },
            until: () => svc.state === "failed",
            then: () => {
                root.check("s7 a tool that dies without a word: failed, reason tool, ended once", svc.failure.reason === "tool" && root.endedN === 1 && root.endedReasons[0] === "failed", JSON.stringify([svc.failure, root.log]));
                svc.clearFailure();
            }
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(6), "LARES-CAST-1", {});
            },
            until: () => svc.state === "failed",
            then: () => {
                root.check("s8 the display going mid-stream is \"peer-gone\", after started", root.endedReasons[0] === "peer-gone" && root.startedN === 1 && root.endedN === 1 && svc.failure.reason === "peer-gone", JSON.stringify(root.log));
                svc.clearFailure();
            }
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(7), "LARES-CAST-1", {});
            },
            until: () => svc.state === "streaming",
            then: () => {
                root.check("s9 a retry is known, the cast goes on", svc.retried === true && svc.state === "streaming", "");
                svc.stop();
            },
            tail: () => svc.state === "idle",
            after: () => {}
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(8), "LARES-CAST-1", {});
            },
            until: () => svc.state === "failed" && root.stepAge() > 800,
            then: () => {
                root.check("s10 two `ended` lines make ONE ended signal", root.endedN === 1 && root.endedReasons[0] === "failed" && svc.failure.reason === "capture", JSON.stringify(root.log));
                svc.clearFailure();
            }
        },
        {
            go: () => {
                root.reset();
                svc.toolPath = "/nonexistent/lares-cast";
                svc.start(root.dev(1), "LARES-CAST-1", {});
            },
            until: () => svc.state === "failed",
            then: () => {
                svc.toolPath = Quickshell.env("CAST_STUB");
                root.check("s11 a tool that is not there: failed (tool), ended once, nothing run", svc.failure.reason === "tool" && root.endedN === 1 && root.startedN === 0, JSON.stringify(root.log));
                svc.clearFailure();
            }
        },
        {
            go: () => {
                root.reset();
                svc.start(root.dev(1), "LARES-CAST-1", {});
                svc.stop();
            },
            until: () => root.stepAge() > 700,
            then: () => {
                root.check("s12 a stop before the tool was even asked: idle, ended \"stopped\" once, nothing started", svc.state === "idle" && root.endedN === 1 && root.endedReasons[0] === "stopped" && root.startedN === 0, JSON.stringify([svc.state, root.log]));
            }
        },
        {
            go: () => {
                const names = ["devices", "scanning", "state", "device", "monitor", "mode", "failure", "retried", "stats", "live", "enabled", "toolPath", "scanError", "scanInfo"];
                let miss = [];
                for (let i = 0; i < names.length; i++)
                    if (!(names[i] in mock) || !(names[i] in svc))
                        miss.push(names[i]);
                const fns = ["scan", "start", "stop", "clearFailure", "holdStats", "releaseStats"];
                for (let j = 0; j < fns.length; j++)
                    if (typeof mock[fns[j]] !== "function" || typeof svc[fns[j]] !== "function")
                        miss.push(fns[j] + "()");
                root.check("s13 the mock has the service's surface", miss.length === 0, miss.join(","));
                mock.script("activation-then-ok");
                mock.start(root.dev(1), "LARES-CAST-1", {});
            },
            until: () => mock.state === "streaming",
            then: () => {
                root.check("s13 mock activation-then-ok: retried, started once", mock.retried === true && mock.startedN === 1, mock.startedN);
                mock.stop();
            },
            tail: () => mock.state === "idle",
            after: () => {
                root.check("s13 mock stop: ended \"stopped\" once", JSON.stringify(mock.endedList) === JSON.stringify(["stopped"]), JSON.stringify(mock.endedList));
                mock.endedList = [];
                mock.script("activation-twice");
                mock.start(root.dev(1), "LARES-CAST-1", {});
            },
            tail2: () => mock.state === "failed",
            after2: () => {
                root.check("s13 mock activation-twice: failed, activation, one ended", mock.failure.reason === "activation" && mock.retried === true && JSON.stringify(mock.endedList) === JSON.stringify(["failed"]), JSON.stringify([mock.failure, mock.endedList]));
                mock.clearFailure();
                mock.endedList = [];
                mock.script("peer-gone-midstream");
                mock.start(root.dev(1), "LARES-CAST-1", {});
            },
            tail3: () => mock.state === "failed",
            after3: () => {
                root.check("s13 mock peer-gone-midstream: ended peer-gone after started", JSON.stringify(mock.endedList) === JSON.stringify(["peer-gone"]) && mock.startedN === 2, JSON.stringify([mock.endedList, mock.startedN]));
                mock.clearFailure();
                mock.endedList = [];
                mock.script("cancelled");
                mock.start(root.dev(1), "LARES-CAST-1", {});
            },
            tail4: () => mock.state === "failed",
            after4: () => {
                root.check("s13 mock cancelled: failure cancelled, ended failed", mock.failure.reason === "cancelled" && JSON.stringify(mock.endedList) === JSON.stringify(["failed"]), JSON.stringify([mock.failure, mock.endedList]));
                mock.clearFailure();
                mock.scan();
            },
            tail5: () => !mock.scanning,
            after5: () => {
                root.check("s13 mock scan gives devices", mock.devices.length === 2, mock.devices.length);
            }
        }
    ]
    function stepAge() {
        return Date.now() - root.stepAt;
    }

    // phase per step: 0 go, 1 until, 2 then, then tails (tail/after, tail2/after2 ...)
    property int phase: 0
    property int tailN: 0
    Timer {
        interval: 30
        running: true
        repeat: true
        onTriggered: {
            if (root.idx >= root.steps.length) {
                console.log("CS RESULT " + (root.fails === 0 ? "PASS" : "FAIL (" + root.fails + ")"));
                Qt.quit();
                running = false;
                return;
            }
            const s = root.steps[root.idx];
            if (root.stepAt === 0)
                root.stepAt = Date.now();
            if (root.stepAge() > 15000) {
                root.check("step " + root.idx + " finishes in time", false, "phase " + root.phase + " seen " + JSON.stringify(root.seen) + " " + svc.state + " " + mock.state);
                root.idx++;
                root.phase = 0;
                root.tailN = 0;
                root.stepAt = 0;
                return;
            }
            const sfx = root.tailN === 0 ? "" : String(root.tailN + 1);
            if (root.phase === 0) {
                s.go();
                root.phase = 1;
            } else if (root.phase === 1) {
                if (s.until()) {
                    s.then();
                    root.phase = 2;
                }
            } else {
                const t = s["tail" + sfx];
                if (t === undefined) {
                    root.idx++;
                    root.phase = 0;
                    root.tailN = 0;
                    root.stepAt = 0;
                } else if (t()) {
                    s["after" + sfx]();
                    root.tailN++;
                }
            }
        }
    }
}
