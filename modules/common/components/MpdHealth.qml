pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

import "MpdHealth.js" as H

// =============================================================================
// MpdHealth.qml -- "is the music actually playing", and when it is not, which layer is broken.
//
// The case it exists for: mpd's animations all play, the queue is full, and no sound comes --
// pause and play reset the time to 0:00. The cause is a USB DAC locked at the hardware level
// (PipeWire: `suspended -> error`; wireplumber in uninterruptible sleep on usb_start_wait_urb), and
// nothing else in the player says so. This reads the signs, names the broken layer in plain words
// (MpdHealth.js decides) and offers ONE button where a button can work.
//
// NOTHING RESTARTS ON ITS OWN. Everything this does without a click is a READ: a `status` every
// `pollMs` while the song plays and somebody looks (the daemon's own position -- the interpolated one
// would hide the stall), and, only while a problem is shown, `tools/player/audio_diagnose.py` (the
// kernel's process states and `pw-dump`, both read-only) every `reprobeMs`. A restart, a `clearerror`,
// an output cycle happens only from `run(id)`, which the banner's button calls.
//
// EVERY STEP HAS A DEADLINE. A process in D state cannot be killed, and `systemctl restart` waits on it
// for the unit's stop timeout (90 s): each external command runs under `timeout -k`, the whole action
// under `actionMs`, and the outcome of a step that did not finish is said in words ("the audio session
// manager did not stop within 12 s: it is waiting on the hardware") before the probe looks again. The GUI
// thread is never waited on: everything is a Process or a socket callback.
//
// GATED ON VIEWERS. Nothing here runs unless `service.tickHolds > 0` (the popup is open): a closed popup
// polls nothing, forks nothing and keeps no timer awake (the bar is free of wakes).
//
// `snapshot` is the one object the banner reads; `currentSignals()` is the four inputs, for a probe.
// =============================================================================
Item {
    id: root

    // The player service (MpdService) and its transport.
    property var service: null
    property var client: null

    // ---- tuning (all of it the file's own defaults) ----
    property int pollMs: 2000          // raw `status` reads while playing and watched
    property int stallMs: 6000         // the daemon's own position unmoved this long = stalled
    property int downGraceMs: 3000     // a dropped socket is a problem only after this
    property int reprobeMs: 4000       // while a problem is shown: look again
    property int probeDeadlineMs: 6000
    property int errorFreshMs: 60000   // an mpd error older than this raises nothing by itself
    property int actionMs: 40000       // the whole of one recovery
    property int stepMs: 12000         // one external command (the unit's stop timeout is 90 s)
    property string script: ""         // tools/player/audio_diagnose.py, absolute
    property string systemctl: "systemctl"
    property string python: "python3"
    property bool debug: false

    // ---- the four signals ----
    readonly property bool watched: root.service ? root.service.tickHolds > 0 : false
    property bool down: false
    readonly property bool stuck: root.client ? root.client.stuck === true : false
    property bool stalled: false
    readonly property string errorText: root.service ? root.service.statusError : ""
    // READ THROUGH A FUNCTION, never a binding: a change handler runs before the bindings on the same
    // property have followed it (CLAUDE.md), and `_evaluate` is called from those handlers.
    function currentSignals() {
        return { down: root.down, stuck: root.client ? root.client.stuck === true : false,
                 error: root._errorNow(), stalled: root.stalled };
    }

    // ---- what the banner reads ----
    property var _diag: H.OK
    property bool busy: false
    property string busyWords: ""
    property string outcome: ""        // "" | "ok" | "failed"
    property string outcomeWords: ""
    property string dismissedKind: ""
    readonly property var snapshot: ({
        kind: root._diag.kind, severity: root._diag.severity, title: root._diag.title,
        words: root._diag.words, hint: root._diag.hint, action: root._diag.action, device: root._diag.device,
        busy: root.busy, busyWords: root.busyWords, outcome: root.outcome, outcomeWords: root.outcomeWords,
        shown: root.watched && (root._diag.kind !== "ok" || root.busy || root.outcome !== "")
               && !(root.dismissedKind !== "" && root.dismissedKind === root._diag.kind && !root.busy && root.outcome === "")
    })
    readonly property bool problem: root._diag.kind !== "ok"

    property var _probe: null
    property bool _probing: false
    property bool _latched: false
    property var _win: null
    property double _errorAt: 0

    // ---------------------------------------------------------------- signals
    function _errorNow() {
        const text = root.service ? root.service.statusError : "";
        if (text === "" || root.down || !root.service)
            return false;
        if (root.stalled) return true;
        if (root.service.playState === "play") return false;
        return root._latched || (Date.now() - root._errorAt) < root.errorFreshMs;
    }
    onErrorTextChanged: {
        if (root.errorText !== "") root._errorAt = Date.now();
        root._evaluate();
    }
    onStuckChanged: root._evaluate()
    onDownChanged: root._evaluate()
    onStalledChanged: root._evaluate()
    onWatchedChanged: {
        if (root.watched && root.client && !root.client.connected)
            _grace.restart();
        if (!root.watched) {
            _grace.stop();
            _poll.stop();
            _reprobe.stop();
            root._win = null;
            root.stalled = false;
            root.dismissedKind = "";
        }
        root._evaluate();
    }

    Connections {
        target: root.service
        function onPlayStateChanged() {
            // A new state is a new window: a pause must not read as a stall, a play must not inherit one.
            root._win = null;
            root.stalled = false;
            root._evaluate();
        }
        function onSongIdChanged() {
            root._win = null;
            root.stalled = false;
        }
    }
    Connections {
        target: root.client
        function onConnectedChanged() {
            if (root.client.connected) {
                _grace.stop();
                root.down = false;
            } else if (root.watched) {
                _grace.restart();
            }
        }
    }
    // The socket stays down for the grace before it is called down: a reconnect after a short drop
    // (the backoff is 1.5 s) must not flash a banner.
    Timer {
        id: _grace
        interval: root.downGraceMs
        repeat: false
        onTriggered: root.down = !!root.client && !root.client.connected
    }

    // ------------------------------------------------------ the stall poll
    Timer {
        id: _poll
        interval: root.pollMs
        repeat: true
        running: root.watched && !!root.service && root.service.playState === "play" && !!root.client
                 && root.client.connected && !root.client.stuck && !root.busy
        onTriggered: root._sample()
    }
    function _sample() {
        root.client.send("status", (ok, lines) => {
            if (!ok) return;
            const kv = root.client.parseKV(lines);
            root.ingest({ t: Date.now(), elapsed: parseFloat(kv.elapsed || "0") || 0,
                          songid: parseInt(kv.songid || "-1", 10), state: kv.state || "stop" });
        });
    }
    // One reading of the daemon's own position (public: a probe feeds it directly).
    function ingest(sample) {
        root._win = H.stallStep(root._win, sample);
        root.stalled = H.isStalled(root._win, root.stallMs);
        root._evaluate();
    }

    // ------------------------------------------------------------ deciding
    function _evaluate() {
        const s = root.currentSignals();
        if (!root.watched || (!s.down && !s.stuck && !s.error && !s.stalled)) {
            if (root.busy) return;                       // an action in progress owns the picture
            if (root._latched || root._diag.kind !== "ok") {
                root._latched = false;
                root._probe = null;
                _reprobe.stop();
                root._diag = H.OK;
                if (root.dismissedKind !== "") root.dismissedKind = "";
            }
            return;
        }
        if (!root._latched) {
            root._latched = true;
            _reprobe.restart();
        }
        if (root._probe === null && !root._probing && !root.busy)
            root._startProbe();
        const d = H.diagnose({ down: s.down, stuck: s.stuck, error: s.error, stalled: s.stalled,
                               errorText: root.errorText, probe: root._probe });
        if (d.kind !== root._diag.kind && root.dismissedKind !== "" && root.dismissedKind !== d.kind)
            root.dismissedKind = "";
        root._diag = d;
    }

    // -------------------------------------------------------------- probing
    Timer {
        id: _reprobe
        interval: root.reprobeMs
        repeat: true
        running: false
        onTriggered: if (root.watched && root._latched && !root._probing && !root.busy) root._startProbe()
    }
    function _startProbe() {
        if (root.script === "" || root._probing)
            return;
        root._probing = true;
        _probeProc.command = [root.python, "-I", root.script];
        _probeProc.running = true;
        _probeDeadline.restart();
    }
    function checkAgain() {
        if (root._probing || root.busy) return;
        root._probe = null;
        root._evaluate();
    }
    function _probeDone(text) {
        _probeDeadline.stop();
        root._probing = false;
        root._probe = H.parseProbe(text);
        if (root.debug) console.log("MpdHealth: probe " + JSON.stringify(root._probe));
        root._evaluate();
        if (root._waitPath) root._pathStep();
    }
    Timer {
        id: _probeDeadline
        interval: root.probeDeadlineMs
        repeat: false
        onTriggered: {
            _probeProc.running = false;
            root._probeDone("");
        }
    }
    Process {
        id: _probeProc
        running: false
        stdout: StdioCollector { id: _probeOut }
        onExited: root._probeDone(_probeOut.text)
    }

    function dismiss() {
        if (root._diag.kind !== "ok") root.dismissedKind = root._diag.kind;
    }

    // ------------------------------------------------------------- recovery
    // The player's own state at the click, for the resume: where the daemon's position really was.
    property bool _resumePlay: false
    property real _resumeAt: 0
    property string _doing: ""
    property bool _waitPath: false
    property int _pathTries: 0

    function _log(m) { if (root.debug) console.log("MpdHealth: " + (Date.now() % 100000) + " " + m); }
    function run(id) {
        root._log("run " + id + " busy " + root.busy);
        if (root.busy || !root.service || !root.client) return;
        root.busy = true;
        root.outcome = "";
        root.outcomeWords = "";
        root._doing = id;
        const st = root.service.playState;
        root._resumePlay = st === "play" || root._errorNow() || root.stalled;
        root._resumeAt = root._win && root.stalled ? root._win.el : root.service.elapsed;
        _action.restart();
        switch (id) {
        case "start-mpd":
            root.busyWords = "Starting mpd…";
            root._unit(["start", "mpd.socket", "mpd.service"], () => root._awaitConnect(8000));
            break;
        case "restart-mpd":
            root.busyWords = "Restarting mpd…";
            root._unit(["restart", "mpd.service"], () => root._awaitConnect(10000));
            break;
        case "restart-audio":
            root.busyWords = "Restarting the audio session…";
            root._unit(["restart", "wireplumber.service"], () => root._awaitPath());
            break;
        case "restart-audio-server":
            root.busyWords = "Restarting the audio server…";
            root._unit(["restart", "pipewire.service", "pipewire-pulse.service", "wireplumber.service"], () => root._awaitPath());
            break;
        case "retry-output":
            root.busyWords = "Reopening the output…";
            root._reopen();
            break;
        default:
            root._fail("Unknown action " + id);
        }
    }

    // `systemctl --user <args>` under a hard deadline; `then` runs when it exited 0.
    property var _unitThen: null
    function _unit(args, then) {
        root._unitThen = then;
        _unitProc.command = ["timeout", "-k", "2", String(Math.round(root.stepMs / 1000)), root.systemctl, "--user"].concat(args);
        _unitProc.running = true;
    }
    Process {
        id: _unitProc
        running: false
        stderr: StdioCollector { id: _unitErr }
        onExited: code => {
            if (!root.busy) return;
            if (code === 0) {
                const t = root._unitThen;
                root._unitThen = null;
                if (t) t();
                return;
            }
            const what = root._doing.indexOf("audio") >= 0
                ? "The audio session manager" : "mpd";
            root._fail(code === 124 || code === 137
                       ? what + " did not stop within " + Math.round(root.stepMs / 1000) + " s: it is waiting on the hardware."
                       : "systemctl could not do it (" + (String(_unitErr.text).trim().split("\n")[0] || "exit " + code) + ").");
        }
    }

    // wait for the command socket
    property real _connectBy: 0
    function _awaitConnect(ms) {
        root.busyWords = "Waiting for mpd…";
        root._connectBy = Date.now() + ms;
        root.client.reconnect();
        _connectWait.restart();
    }
    Timer {
        id: _connectWait
        interval: 250
        repeat: true
        onTriggered: {
            if (root.client.connected) {
                _connectWait.stop();
                // mpd is back; its state is its own (restore_paused): resume what was playing.
                root._resume();
            } else if (Date.now() > root._connectBy) {
                _connectWait.stop();
                root._fail("mpd did not come up within a few seconds.");
            }
        }
    }

    // wait for the audio path to come back after a restart: the probe, until a default sink is up
    function _awaitPath() {
        root.busyWords = "Waiting for the audio device…";
        root._pathTries = 0;
        root._waitPath = true;
        root._probe = null;
        root._startProbeForce();
    }
    function _startProbeForce() {
        root._probing = false;
        root._startProbe();
    }
    function _pathStep() {
        if (H.audioPathUp(root._probe)) {
            root._waitPath = false;
            root._reopen();
            return;
        }
        root._pathTries++;
        if (root._pathTries >= 6) {
            root._waitPath = false;
            root._fail("The device did not come back after the restart.");
            return;
        }
        _pathRetry.restart();
    }
    Timer {
        id: _pathRetry
        interval: 1500
        repeat: false
        onTriggered: root._startProbeForce()
    }

    // clearerror, cycle every output, then play from the saved position
    function _reopen() {
        root.busyWords = "Reopening the output…";
        root.client.send("clearerror", () => {
            root.client.send("outputs", (ok, lines) => {
                const outs = ok ? root.client.parseObjects(lines, "outputid") : [];
                const cmds = [];
                for (let i = 0; i < outs.length; i++) {
                    const id = parseInt(root.client.first(outs[i].outputid), 10);
                    if (isFinite(id)) {
                        cmds.push("disableoutput " + id);
                        cmds.push("enableoutput " + id);
                    }
                }
                if (cmds.length === 0) {
                    root._resume();
                    return;
                }
                // The outputs close and reopen on their own threads: a `play` sent in the same breath
                // finds the output half-open and stops with "Failed to open audio output" (measured, a
                // pipe output). A short settle between the cycle and the play.
                root.client.sendAll(cmds, () => _cycleSettle.restart());
            });
        });
    }
    Timer {
        id: _cycleSettle
        interval: 600
        repeat: false
        onTriggered: root._resume()
    }

    function _resume() {
        if (!root.busy) return;
        if (!root._resumePlay) {
            root._succeed("Done.");
            return;
        }
        root.busyWords = "Starting playback…";
        const at = root._resumeAt;
        root.client.send("play", (ok) => {
            if (!ok) { root._fail("mpd refused to play: " + (root.client.lastError || "").replace(/^ACK \[[^\]]*\] \{[^}]*\} /, "")); return; }
            if (at > 2) root.client.send("seekcur " + at.toFixed(2), () => root._verify());
            else root._verify();
        });
    }

    // After the play: the daemon's OWN position has to move
    property real _verifyBase: -1
    property int _verifyTries: 0
    property int _replays: 0
    property string _verifyError: ""
    function _verify() {
        root.busyWords = "Checking that it plays…";
        root._verifyBase = -1;
        root._verifyTries = 0;
        root._replays = 0;
        root._verifyError = "";
        _verifyTimer.restart();
    }
    Timer {
        id: _verifyTimer
        interval: 1000
        repeat: true
        onTriggered: {
            root.client.send("status", (ok, lines) => {
                if (!ok || !root.busy) return;
                const kv = root.client.parseKV(lines);
                const el = parseFloat(kv.elapsed || "0") || 0;
                if (kv.error) root._verifyError = kv.error;
                if (kv.state !== "play") {
                    // Stopped with the output still settling: ask once more, twice at most.
                    root._verifyBase = -1;
                    if (root._replays < 2) { root._replays++; root.client.send("play", null); }
                    return;
                }
                if (root._verifyBase < 0) { root._verifyBase = el; return; }
                if (el - root._verifyBase >= 0.8) {
                    _verifyTimer.stop();
                    root._succeed("Playing again.");
                }
            });
            root._verifyTries++;
            if (root._verifyTries >= 9) {
                _verifyTimer.stop();
                root._fail(root._verifyError !== "" ? root._verifyError : "mpd plays but the position does not move.");
            }
        }
    }

    function _stopAll() {
        _action.stop();
        _cycleSettle.stop();
        _connectWait.stop();
        _pathRetry.stop();
        _verifyTimer.stop();
        root._waitPath = false;
        root._unitThen = null;
        root.busy = false;
        root.busyWords = "";
    }
    function _succeed(words) {
        root._log("succeed " + words);
        root._stopAll();
        root._win = null;
        root.stalled = false;
        root.outcome = "ok";
        root.outcomeWords = words;
        root._probe = null;
        root._latched = false;
        root._diag = H.OK;
        _outcomeHold.restart();
        root._evaluate();
    }
    function _fail(words) {
        root._log("fail " + words);
        root._stopAll();
        root.outcome = "failed";
        root.outcomeWords = words;
        // Look again at once: what it says now is what the user should do next.
        root._probe = null;
        root._latched = true;
        root._startProbeForce();
        _outcomeHold.restart();
        root._evaluate();
    }
    Timer {
        id: _outcomeHold
        interval: 5000
        repeat: false
        onTriggered: {
            root.outcome = "";
            root.outcomeWords = "";
            root._evaluate();
        }
    }
    Timer {
        id: _action
        interval: root.actionMs
        repeat: false
        onTriggered: if (root.busy) root._fail("That took too long and was given up.")
    }
}
