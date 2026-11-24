pragma ComponentBehavior: Bound

import QtQuick
import QtQml

import "CastParse.js" as CP

// =============================================================================
// CastMock -- CastService's twin with no process: the same surface, scripted. The tool's own JSON events (what tools/panorama/lares-cast
// prints) are played through CastParse's reducer, so the mock cannot drift from the service's rules.
//
//   script(name): "ok" | "activation-then-ok" | "activation-twice" | "cancelled" | "peer-gone-midstream" | "link-then-ok"   (read at start())
//   stepMs:       one script step; beatMs the beat of the figures; stopMs the way down; scanMs a scan
//   pinned:       figures that stand in the place of the mock's own ones (a grab, a probe): { fps: 30, ... }, a key left out has no source
// =============================================================================
QtObject {
    id: root

    property bool live: false
    property bool enabled: true
    property string toolPath: ""
    property int scanSeconds: 8

    property int stepMs: 500
    property int beatMs: 1000
    property var pinned: null
    property int stopMs: 400
    property int scanMs: 1500
    property string scriptName: "ok"
    function script(name: string): void {
        root.scriptName = name;
    }

    property var devices: []
    readonly property bool scanning: root._scanning
    property string scanError: ""
    property var scanInfo: ({ fluxcast: "0.3.0", shim: true, protocols: ["wfd"] })

    property var _m: CP.initial()
    readonly property string state: root._m.state
    readonly property string device: root._m.device
    readonly property string monitor: root._m.monitor
    readonly property var mode: root._m.mode
    readonly property var failure: root._m.failure
    readonly property bool retried: root._m.retried
    readonly property CastStats figures: CastStats {}
    readonly property var stats: root.figures.value
    function holdStats(): void {
        root.figures.hold();
    }
    function releaseStats(): void {
        root.figures.release();
    }

    signal started(string deviceId, string monitorName)
    signal ended(string reason)

    property bool _scanning: false
    property bool _endedSent: true
    property var _steps: []
    property int _at: 0
    // the mock's stream: seconds up, how often it came up, its totals
    readonly property var _run: ({ beats: 0, links: 0, dropped: 0, repeated: 0 })

    readonly property var _scripts: ({
        "ok": [{ event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "state", state: "negotiating" },
            { event: "mode", width: 1920, height: 1080, fps: 30 }, { event: "state", state: "streaming" }],
        "activation-then-ok": [{ event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "retry", n: 1 },
            { event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "state", state: "negotiating" },
            { event: "mode", width: 1920, height: 1080, fps: 30 }, { event: "state", state: "streaming" }],
        "activation-twice": [{ event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "retry", n: 1 },
            { event: "state", state: "scanning" }, { event: "state", state: "connecting" },
            { event: "failed", reason: "activation", detail: "Timed out waiting for NetworkManager Wi-Fi Direct activation. Last status: unknown" },
            { event: "state", state: "ended" }, { event: "ended", code: 1 }],
        "cancelled": [{ event: "state", state: "scanning" }, { event: "state", state: "connecting" },
            { event: "failed", reason: "cancelled", detail: "the display cancelled the connection" }, { event: "state", state: "ended" }, { event: "ended", code: 1 }],
        "peer-gone-midstream": [{ event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "state", state: "negotiating" },
            { event: "mode", width: 1920, height: 1080, fps: 30 }, { event: "state", state: "streaming" }, { event: "wait", n: 4 },
            { event: "failed", reason: "peer-gone", detail: "the display ended the session" }, { event: "state", state: "ended" }, { event: "ended", code: 1 }],
        "link-then-ok": [{ event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "state", state: "negotiating" },
            { event: "mode", width: 1920, height: 1080, fps: 30 }, { event: "state", state: "streaming" }, { event: "wait", n: 6 }, { event: "lost" }, { event: "wait", n: 4 },
            { event: "retry", n: 1 }, { event: "state", state: "scanning" }, { event: "state", state: "connecting" }, { event: "state", state: "negotiating" },
            { event: "mode", width: 1920, height: 1080, fps: 30 }, { event: "state", state: "streaming" }]
    })

    function scan(): bool {
        if (!root.enabled || root._scanning || CP.active(root._m))
            return false;
        root._scanning = true;
        root.scanError = "";
        root._scanTimer.restart();
        return true;
    }

    // how often start() was let through (a probe counts them)
    property int startCalls: 0
    function start(deviceId: string, monitorName: string, opts: var): bool {
        if (!root.enabled || root._scanning || CP.active(root._m) || deviceId === "" || monitorName === "")
            return false;
        root.startCalls++;
        root._endedSent = false;
        root.figures.take({ event: "begin", same: root._m.device === deviceId });
        root._m = CP.begin(deviceId, monitorName);
        root._steps = root._scripts[root.scriptName] || root._scripts["ok"];
        root._at = 0;
        root._run.beats = root._run.links = root._run.dropped = root._run.repeated = 0;
        root._stepTimer.restart();
        return true;
    }

    function stop(): void {
        if (!CP.active(root._m) || root._m.state === "stopping")
            return;
        root._stepTimer.stop();
        root._m = CP.requestStop(root._m);
        root._stopTimer.restart();
    }

    function clearFailure(): void {
        if (root._m.state === "failed")
            root._m = CP.initial();
    }

    function _apply(ev: var): void {
        root.figures.take(ev);
        if (ev.event === "stats")
            return;
        const before = root._m;
        const next = CP.reduce(before, ev);
        root._m = next;
        if (before.state !== "streaming" && next.state === "streaming")
            root._run.links++;
        if (!before.started && next.started)
            root.started(next.device, next.monitor);
        if (next.ended !== "" && !root._endedSent) {
            root._endedSent = true;
            root._stepTimer.stop();
            root.ended(next.ended);
        }
    }

    property Timer _stepTimer: Timer {
        interval: root.stepMs
        repeat: true
        onTriggered: {
            if (root._at >= root._steps.length) {
                root._stepTimer.stop();
                return;
            }
            const ev = root._steps[root._at];
            if (ev.event === "wait" && root._waited < ev.n) {
                root._waited++;
                return;
            }
            root._waited = 0;
            root._at++;
            if (ev.event !== "wait")
                root._apply(ev);
        }
    }
    property int _waited: 0
    property Timer _beatTimer: Timer {
        interval: root.beatMs
        repeat: true
        running: root.state === "streaming"
        onTriggered: {
            const r = root._run;
            r.beats++;
            r.dropped += Math.random() < 0.1 ? 1 : 0;
            r.repeated += Math.random() < 0.3 ? 1 : 0;
            root._apply(Object.assign({ event: "stats", age: r.beats, reconnects: r.links - 1 }, root.pinned !== null ? root.pinned : {
                fps: 29.8 + Math.random() * 0.4, dropped: r.dropped, repeated: r.repeated, behindMs: Math.round(Math.random() * 40),
                kbps: Math.round(8100 + Math.random() * 500), rttMs: 3 + Math.random() * 4, signalDbm: -52 + Math.round(Math.random()), linkMbps: 866.7
            }));
        }
    }
    property Timer _stopTimer: Timer {
        interval: root.stopMs
        onTriggered: root._apply({ event: "ended", code: 0 })
    }
    property Timer _scanTimer: Timer {
        interval: root.scanMs
        onTriggered: {
            root._scanning = false;
            root.devices = [{ id: "wfd:02:AE:00:00:0A:01", name: "[TV] Living Room OLED 65", protocol: "wfd", capable: true, note: "" },
                { id: "wfd:6E:11:22:33:44:55", name: "Pixel 9", protocol: "wfd", capable: false, note: "not advertising Wi-Fi Display; if this is a TV, put it into Screen Share mode first" }];
        }
    }
}
