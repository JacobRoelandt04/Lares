pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/system"

// =============================================================================
// CastSession.qml -- the phone's screen as a stream: owns ONE `lares-cast` Process (tools/bridge/lares-cast) and speaks its two
// line protocols (docs/contracts/bridge.md, "The cast"). Non-visual; ONE per shell (it lives in the bridge service, a popup's
// content is per screen and destroyed on close). A CastView plays `url` once `state` is "live" and turns the pointer and the keys
// into touch(), scroll(), key() and text().
//
//   state   "idle" (nothing asked) | "starting" | "live" | "failed" (`reason`) | "ended" (`reason`, the phone or the tool stopped)
//   stop()  asks the tool to quit (stdin `quit`), kills it after `killAfterMs`; the state is "idle" at once.
//   restart()  stop, then start again once the old tool is gone (never two at a time).
//   newDisplay "WxH": a second, virtual screen of the phone's at that size (Desktop) instead of its own screen ("")
//   flowing    the phone is sending pictures (the tool's `flow` events: false after 1.5 s without one -- an asleep or dark
//              screen); flowKnown: the tool has said either
//   keyguard / awake / lockKnown   the phone's lock screen shows / its screen is on, from the tool's `lock` events (the first one
//              right after `ready`, then each change); lockKnown: the tool has said
//   wake()     the phone's screen on (KEYCODE_WAKEUP); resize(w, h)  a `flex` virtual display's new size (a desktop; never a restart)
//   record     a file the tool also writes the stream to (--record; "" none); `recorded(ev)` is the tool's `record` event at its end
//              ({path} | {error, kept} | {error} | {empty}, docs/contracts/bridge.md), told even after a stop: a tool that records is
//              given `recordKillAfterMs` to finish the file before it is killed
// =============================================================================
Item {
    id: root
    visible: false
    width: 0
    height: 0

    property string toolPath: RepoRoot.dir + "/tools/bridge/lares-cast"
    property var launcher: ["setpriv", "--pdeathsig", "TERM", "--"]
    property string python: "python3"
    property string serial: ""
    property int maxSize: 0
    property string bitRate: ""
    property int maxFps: 0
    property bool audio: false
    // "WxH" or "WxH/DPI"
    property string newDisplay: ""
    // the virtual display can be resized live (--flex; only with newDisplay)
    property bool flex: false
    // the file the stream is also recorded into (--record PATH; a restart's tool takes PATH-2, -3: lares-cast never writes over a file)
    property string record: ""
    // How long a tool that was asked to quit may take before it is killed; one that records remuxes its file first.
    property int killAfterMs: 3000
    property int recordKillAfterMs: 60000

    readonly property string state: root._state
    readonly property string url: root._url
    readonly property int videoWidth: root._w
    readonly property int videoHeight: root._h
    readonly property string reason: root._reason
    readonly property string deviceName: root._name
    readonly property bool flowing: root._flowing
    readonly property bool flowKnown: root._flowKnown
    readonly property bool keyguard: root._keyguard
    readonly property bool awake: root._awake
    readonly property bool lockKnown: root._lockKnown

    // The tool's events, for a host that wants them (a size change, a player connecting).
    signal sizeChanged2(int width, int height)
    signal clientChanged(bool connected)
    signal recorded(var ev)

    property string _state: "idle"
    property string _url: ""
    property int _w: 0
    property int _h: 0
    property string _reason: ""
    property string _name: ""
    property bool _flowing: false
    property bool _flowKnown: false
    property bool _keyguard: false
    property bool _awake: true
    property bool _lockKnown: false
    property bool _restartWanted: false
    property bool _quitSent: false
    // the tool that runs records (taken at its start: `record` may be written for the next one meanwhile)
    property bool _recording: false

    function start(): bool {
        if (root.serial === "") {
            root._fail("no phone to cast");
            return false;
        }
        if (cast.running) {
            // a tool that is still going down: start when it is gone
            root._restartWanted = true;
            return true;
        }
        root._state = "starting";
        root._url = "";
        root._reason = "";
        root._w = 0;
        root._h = 0;
        root._name = "";
        root._flowing = false;
        root._flowKnown = false;
        root._keyguard = false;
        root._awake = true;
        root._lockKnown = false;
        root._quitSent = false;
        const a = root.launcher.concat([root.python, root.toolPath, root.serial]);
        if (root.newDisplay !== "") {
            a.push("--new-display", root.newDisplay);
            if (root.flex)
                a.push("--flex");
        } else if (root.maxSize > 0)
            a.push("--max-size", String(root.maxSize));
        if (root.bitRate !== "")
            a.push("--bit-rate", root.bitRate);
        if (root.maxFps > 0)
            a.push("--max-fps", String(root.maxFps));
        if (root.audio)
            a.push("--audio");
        if (root.record !== "")
            a.push("--record", root.record);
        root._recording = root.record !== "";
        cast.command = a;
        cast.running = true;
        return true;
    }

    function stop(): void {
        root._restartWanted = false;
        root._stopTool();
        root._state = "idle";
        root._url = "";
    }

    function restart(): void {
        root._stopTool();
        root._state = "idle";
        root._url = "";
        root._restartWanted = true;
        if (!cast.running)
            root.start();
    }

    function touch(kind: string, x: real, y: real): void {
        root._send({ touch: kind, x: Math.round(x), y: Math.round(y) });
    }
    function scroll(x: real, y: real, h: real, v: real): void {
        root._send({ scroll: { x: Math.round(x), y: Math.round(y), h: h, v: v } });
    }
    function key(name: string): void {
        root._send({ key: name });
    }
    function text(t: string): void {
        root._send({ text: t });
    }
    // Ask the phone for a key frame now (a player that has just opened the stream throws away what it probed with and waits for one).
    function keyframe(): void {
        root._send({ keyframe: true });
    }
    // The phone's screen on (a dark one shows nothing and takes no touch).
    function wake(): void {
        root._send({ wake: true });
    }
    // A flex display's new size, in the display's own pixels.
    function resize(w: int, h: int): void {
        root._send({ resize: { w: Math.round(w), h: Math.round(h) } });
    }
    function screen(on: bool): void {
        root._send({ screen: on ? "on" : "off" });
    }

    function _send(o: var): void {
        if (cast.running && !root._quitSent)
            cast.write(JSON.stringify(o) + "\n");
    }

    function _stopTool(): void {
        if (!cast.running)
            return;
        if (!root._quitSent) {
            root._quitSent = true;
            cast.write("{\"quit\":true}\n");
            killTimer.restart();
        }
    }

    function _fail(why: string): void {
        root._reason = why;
        root._url = "";
        root._state = "failed";
    }

    function _onLine(line: string): void {
        const t = line.trim();
        if (t === "")
            return;
        let ev = null;
        try {
            ev = JSON.parse(t);
        } catch (e) {
            return;
        }
        // the file's word comes at the tool's very end, after a quit too
        if (ev && ev.event === "record") {
            root.recorded(ev);
            return;
        }
        if (!ev || root._quitSent)
            return;
        if (ev.event === "ready") {
            root._w = ev.width;
            root._h = ev.height;
            root._name = ev.name || "";
            root._url = ev.url;
            root._state = "live";
        } else if (ev.event === "size") {
            root._w = ev.width;
            root._h = ev.height;
            root.sizeChanged2(ev.width, ev.height);
        } else if (ev.event === "flow") {
            root._flowKnown = true;
            root._flowing = ev.on === true;
        } else if (ev.event === "lock") {
            root._lockKnown = true;
            root._keyguard = ev.keyguard === true;
            root._awake = ev.awake !== false;
        } else if (ev.event === "client") {
            root.clientChanged(!!ev.connected);
        } else if (ev.event === "ended") {
            // the reason first: a handler of the state's change reads it
            root._reason = ev.reason || "";
            root._url = "";
            root._state = "ended";
        } else if (ev.event === "error") {
            root._fail(ev.reason || "the cast failed");
        }
    }

    Process {
        id: cast
        stdinEnabled: true
        stdout: SplitParser {
            // a slice is not always a line (CLAUDE.md, SplitParser): split it again
            onRead: data => {
                const p = String(data).split("\n");
                for (let i = 0; i < p.length; i++)
                    root._onLine(p[i]);
            }
        }
        onExited: (code, status) => {
            killTimer.stop();
            if (!root._quitSent && (root._state === "starting" || root._state === "live"))
                root._fail("the cast tool ended (exit " + code + ")");
            else if (root._state === "ended" && root._reason === "")
                root._reason = "stopped";
            root._url = root._state === "live" ? "" : root._url;
            if (root._restartWanted) {
                root._restartWanted = false;
                Qt.callLater(root.start);
            }
        }
    }

    Timer {
        id: killTimer
        interval: root._recording ? root.recordKillAfterMs : root.killAfterMs
        onTriggered: {
            if (cast.running)
                cast.running = false;
        }
    }
}
