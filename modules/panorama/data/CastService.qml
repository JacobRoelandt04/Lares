pragma ComponentBehavior: Bound

import QtQuick
import QtQml
import Quickshell.Io

import "../../common/system"
import "CastParse.js" as CP

// =============================================================================
// CastService -- the cast to a display (Miracast through fluxcast): the tool's `scan` and `start` as a service. Contract: docs/contracts/panorama.md
// "Cast"; the tool: tools/panorama/lares-cast (JSON lines); the rules of reading its lines: CastParse.js.
//
// The service never creates or removes a Hyprland output: the Panorama engine owns it, and `start()` is told its name.
// `live` is false until a host says so (a host that forgets cannot reach the machine). A cast is NEVER restarted by backoff
// (SupervisedStream would): one `start()` is one run of the tool, with its own bounded retries inside the tool.
// At its start the service has the tool give back a Wi-Fi profile a dead cast still holds (`lares-cast restore`).
//
// Surface:  live, enabled, toolPath | devices, scanning, scanError, scanInfo, function scan() |
//           state "idle"|"connecting"|"negotiating"|"streaming"|"stopping"|"failed", device, monitor, mode, failure, retried |
//           stats (the stream's figures, CastStats: null unless held), function holdStats(), function releaseStats() |
//           function start(deviceId, monitorName, opts): bool, function stop(), function clearFailure() |
//           signals started(deviceId, monitorName) (the stream is up), ended(reason) (exactly once per accepted start:
//           "stopped" | "failed" | "peer-gone"), and the automatic stateChanged.
// =============================================================================
QtObject {
    id: root

    property bool live: false
    property bool enabled: true
    property string toolPath: RepoRoot.dir + "/tools/panorama/lares-cast"
    // Seconds the tool scans for (its --seconds).
    property int scanSeconds: 8
    // The tool stops fluxcast itself (INT, 5 s, KILL of its group) and gives the Wi-Fi profile back; this is the last resort on the tool.
    property int killAfterMs: 15000
    // A process's exit can be heard before the last bytes of its stdout: an end is judged this long after the exit.
    property int exitGraceMs: 80

    property var devices: []
    readonly property bool scanning: root._scanning
    property string scanError: ""
    property var scanInfo: ({ fluxcast: "", shim: false, protocols: [] })

    property var _m: CP.initial()
    readonly property string state: root._m.state
    readonly property string device: root._m.device
    readonly property string monitor: root._m.monitor
    readonly property var mode: root._m.mode
    readonly property var failure: root._m.failure
    readonly property bool retried: root._m.retried
    // the stream's figures, once a beat while something shows them (CastStats)
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
    property var _argv: []
    property string _probeFor: ""

    function _tool(args: var): var {
        return ["setpriv", "--pdeathsig", "TERM", "--", root.toolPath].concat(args);
    }

    function scan(): bool {
        if (!root.live || !root.enabled || root._scanning || CP.active(root._m))
            return false;
        root._scanning = true;
        root.scanError = "";
        root._probeFor = "scan";
        root._probe.command = ["test", "-x", root.toolPath];
        root._probe.running = true;
        return true;
    }

    function start(deviceId: string, monitorName: string, opts: var): bool {
        if (!root.live || !root.enabled || root._scanning || CP.active(root._m) || deviceId === "" || monitorName === "")
            return false;
        const o = opts || {};
        let a = ["start", "--device", deviceId, "--monitor", monitorName];
        if (o.res)
            a = a.concat(["--res", String(o.res)]);
        if (o.fps)
            a = a.concat(["--fps", String(o.fps)]);
        if (o.bitrate)
            a = a.concat(["--bitrate", String(o.bitrate)]);
        if (o.audio === false)
            a.push("--no-audio");
        if (o.audioDevice)
            a = a.concat(["--audio-device", String(o.audioDevice)]);
        root._gen++;
        root._exitTimer.stop();
        root._endedSent = false;
        root._argv = a;
        root.figures.take({ event: "begin", same: root._m.device === deviceId });
        root._m = CP.begin(deviceId, monitorName);
        root._probeFor = "start";
        root._probe.command = ["test", "-x", root.toolPath];
        root._probe.running = true;
        return true;
    }

    // keepHold: the stop of a restart -- the tool leaves the Wi-Fi profile locked for the start that follows (SIGUSR1; lares-cast)
    function stop(keepHold: bool): void {
        if (!CP.active(root._m) || root._m.state === "stopping")
            return;
        root._m = CP.requestStop(root._m);
        if (root._castProc !== null && root._castProc.running) {
            root._castProc.signal(keepHold ? 10 : 15);
            root._killTimer.restart();
        } else {
            // not started yet (the executable test is out): there is nothing to wait for
            root._finish({ event: "ended", code: 0 });
        }
    }

    // a cast has ended for good: a hold a restart handed over and nobody took is given back now
    function restore(): void {
        if (!root.live || !root.enabled || CP.active(root._m) || root._restoreNow.running)
            return;
        root._restoreNow.running = true;
    }

    function clearFailure(): void {
        if (root._m.state === "failed")
            root._m = CP.initial();
    }

    // One reducer step; the signals follow the model's own latches.
    function _finish(ev: var): void {
        root.figures.take(ev);
        if (ev.event === "stats")
            return;
        const before = root._m;
        const next = CP.reduce(before, ev);
        root._m = next;
        if (!before.started && next.started)
            root.started(next.device, next.monitor);
        if (next.ended !== "" && !root._endedSent) {
            root._endedSent = true;
            root._killTimer.stop();
            root.ended(next.ended);
        }
    }

    function _onCastData(data: string): void {
        const parts = String(data).split("\n");
        for (let i = 0; i < parts.length; i++) {
            const ev = CP.parseLine(parts[i]);
            if (ev !== null)
                root._finish(ev);
        }
    }

    function _probed(code: int): void {
        if (root._probeFor === "scan") {
            if (code !== 0) {
                root._scanning = false;
                root.scanError = "tool: " + root.toolPath + " is not executable";
                return;
            }
            root._scan.command = root._tool(["scan", "--json", "--seconds", String(root.scanSeconds)]);
            root._scan.running = true;
            return;
        }
        if (root._m.state !== "connecting" || root._endedSent)
            return;
        if (code !== 0) {
            root._finish({ event: "failed", reason: "tool", detail: root.toolPath + " is not executable" });
            root._finish({ event: "ended", code: 1 });
            return;
        }
        // One Process per cast: a run's late exit or last bytes belong to its generation, never to the next cast.
        if (root._castProc !== null) {
            if (root._castProc.running)
                root._castProc.signal(9);
            root._castProc.destroy(2000);
        }
        root._castProc = root._castComp.createObject(root, { gen: root._gen, command: root._tool(root._argv) });
        root._castProc.running = true;
    }

    function _scanDone(text: string): void {
        if (!root._scanning)
            return;
        root._scanning = false;
        const r = CP.parseScan(text);
        if (r.error !== undefined) {
            root.scanError = r.error;
            return;
        }
        root.devices = r.devices;
        root.scanInfo = r.info;
    }

    property Process _restore: Process {
        command: root._tool(["restore"])
        running: root.live && root.enabled
    }
    property Process _restoreNow: Process {
        command: root._tool(["restore", "--now"])
    }
    property Process _probe: Process {
        onExited: code => root._probed(code)
    }
    property Process _scan: Process {
        stdout: StdioCollector {
            id: scanCollector
            onStreamFinished: root._scanDone(scanCollector.text)
        }
        onExited: code => {
            if (code !== 0 && root._scanning)
                scanFallback.restart();
        }
    }
    // an error line on stdout arrives with the stream's end; this only covers a tool that died without one
    property Timer _scanFallback: Timer {
        id: scanFallback
        interval: 300
        onTriggered: root._scanDone("")
    }
    property int _gen: 0
    property var _castProc: null
    property Component _castComp: Component {
        Process {
            id: castProc
            property int gen: 0
            stdout: SplitParser {
                onRead: data => {
                    if (castProc.gen === root._gen)
                        root._onCastData(data);
                }
            }
            onExited: code => {
                if (castProc.gen === root._gen) {
                    root._exitCode = code;
                    root._exitTimer.restart();
                }
            }
        }
    }
    property int _exitCode: 0
    property Timer _exitTimer: Timer {
        interval: root.exitGraceMs
        onTriggered: {
            if (!root._endedSent)
                root._finish({ event: "ended", code: root._exitCode });
        }
    }
    property Timer _killTimer: Timer {
        interval: root.killAfterMs
        onTriggered: if (root._castProc !== null && root._castProc.running)
            root._castProc.signal(9)
    }
}
