pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import "EngineGenerate.js" as Gen

// =============================================================================
// EngineLink.qml -- the shell's end of Panorama's engine (docs/contracts/panorama.md sections 2-4).
//
// The engine is Lua inside Hyprland (tools/panorama/engine.lua, in the generated ~/.config/hypr/config/panorama.lua). This object
//   - writes that file (writeFile: EngineGenerate.js, the twin of tools/panorama/generate.py, atomically) and loads it (evalLoad),
//   - sends the engine its calls through `hyprctl eval` (tryCandidate / shown / keep / revert / reloadData), ONE AT A TIME, in the
//     order asked: the answer of an eval is the text `ok` or `error: ...` (hyprctl exits 0 on a Lua warning, so the text is read),
//   - reads the engine's state file ($XDG_RUNTIME_DIR/lares/panorama.json), re-read when the file changes and on the engine's
//     nudge (socket2 `custom>>lares-panorama,<serial>`), and judges it by the SESSION it names.
//
// OUTPUTS
//   state      the parsed state file of THIS session (null when none); a new object at every read, so stateChanged fires
//   stateName  active | missing | stale | error
//     missing  no config/panorama.lua, or no `require` of config/panorama in the hypr config (the user's one-time step)
//   fresh      the hypr config loads config/panorama and the file is not there: a fresh machine (the file is generated and git-ignored, so a
//              clone of the user's config never has it). The service writes it: the line in the config is the user's word for it
//     stale    the engine that answered is older than the tree's engine.lua (the service rewrites the file at once)
//     error    the engine has not answered this session, or the last call failed
//   why        words for the popup when not active;  version  the answering engine's version (0 none)
//
// WHAT AN EVAL ANSWERS. `ok` is a call that ran. A Lua WARNING (`warning: =[C]:-1: Monitor not found`, exit 0) is a call that ran and
// complained: it is logged and NEVER an error (round 2: one such warning from the revert of a mirror trial latched `error` for ever --
// the popup went read-only and no detail could be opened until the shell restarted). An `error:` text or a non-zero exit is a call that
// failed; it holds `error` only until something answers: the next call that works, or the engine publishing a state NEWER than the
// one the failure was met on (an engine that speaks is an engine that runs).
//
// `hyprctl` is the program name, so a test can stub it. A Process whose program does not exist emits neither started nor exited,
// so every call goes through `sh`, which tests for the program first.
// =============================================================================
Scope {
    id: root

    property bool live: false
    property string hyprDir: ""
    property string runtimeDir: ""
    property string engineSource: ""
    property string hyprctl: "hyprctl"

    property var state: null
    property string stateName: "missing"
    property string why: ""
    property int version: 0
    property string lastError: ""
    property real _errorSerial: -1      // the engine's state serial when `lastError` was set (-1: none seen)

    readonly property string _statePath: root.runtimeDir + "/panorama.json"
    readonly property string _luaPath: root.hyprDir + "/config/panorama.lua"
    property int _treeVersion: 0
    property int _probe: -1             // the exit status of the hypr-config probe: 0 found, 1 no line, 3 neither, 4 the line and no file, -1 not asked yet
    readonly property bool fresh: root.live && root._probe === 4
    property string _session: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""
    property var _queue: []
    property bool _busy: false
    property string _evalText: ""

    // ---- the calls ---------------------------------------------------------------------------------------------------------------
    function _lit(s: string): string {
        return Gen.bracketed(String(s));
    }

    // Lua source for a call into the engine's global table.
    function _call(fn: string, args: var): string {
        // a number goes as a Lua number (whole), every other argument as a long-bracketed string
        const a = args.map(x => typeof x === "number" && isFinite(x) ? String(Math.round(x)) : root._lit(x)).join(", ");
        return "assert(panorama, 'the Panorama engine is not loaded'); panorama." + fn + "(" + a + ")";
    }

    function writeFile(data: var): void {
        root._enqueue({ kind: "write", text: JSON.stringify(data) });
    }

    function evalLoad(): void {
        root._enqueue({ kind: "eval", lua: "dofile(" + root._lit(root._luaPath) + ")" });
    }

    function tryCandidate(data: var, token: string): void {
        root._enqueue({ kind: "eval", lua: root._call("try", [JSON.stringify(data), token]) });
    }

    // the keep toast is on the glass: the engine's guard runs `guardMs` from now (the toast's countdown and a grace; 0: the engine's own 17 s)
    function shown(token: string, guardMs: int): void {
        root._enqueue({ kind: "eval", lua: root._call("shown", guardMs > 0 ? [token, guardMs] : [token]) });
    }

    function keep(token: string): void {
        root._enqueue({ kind: "eval", lua: root._call("keep", [token]) });
    }

    function revert(token: string): void {
        root._enqueue({ kind: "eval", lua: root._call("revert", [token]) });
    }

    // a cast display (tools/panorama/engine.lua "Cast displays"): the engine makes / removes the headless output of a TV, and keeps only
    // the names a live cast holds (the rest are swept after a grace)
    function castOpen(identity: string): void {
        root._enqueue({ kind: "eval", lua: root._call("cast_open", [identity]) });
    }

    function castClose(name: string): void {
        root._enqueue({ kind: "eval", lua: root._call("cast_close", [name]) });
    }

    function castKeep(names: var): void {
        root._enqueue({ kind: "eval", lua: root._call("cast_keep", [JSON.stringify(names)]) });
    }

    function reloadData(data: var): void {
        root._enqueue({ kind: "eval", lua: root._call("reload_data", [JSON.stringify(data)]) });
    }

    // Re-read everything (the hypr config probe and the state file).
    function refresh(): void {
        root._readState();
        root._askProbe();
    }

    function _enqueue(job: var): void {
        if (!root.live)
            return;
        const q = root._queue.slice();
        q.push(job);
        root._queue = q;
        root._next();
    }

    function _next(): void {
        if (root._busy || root._queue.length === 0)
            return;
        root._busy = true;
        const q = root._queue.slice();
        const job = q.shift();
        root._queue = q;
        if (job.kind === "write")
            root._doWrite(job.text);
        else
            root._doEval(job.lua);
    }

    function _done(err: string): void {
        if (err !== "") {
            root.lastError = err;
            root._errorSerial = root.state ? (root.state.serial || 0) : 0;
            console.warn("LARES panorama engine:", err);
        } else {
            root.lastError = "";
        }
        root._busy = false;
        root._judge();
        root._next();
    }

    function _doWrite(setupsText: string): void {
        const engineText = engineFile.text();
        if (engineText === "") {
            root._done("no engine source at " + root.engineSource);
            return;
        }
        try {
            root._pendingFile = Gen.generate(setupsText, engineText);
        } catch (e) {
            root._done("cannot generate panorama.lua: " + e);
            return;
        }
        mkdir.command = ["mkdir", "-p", root.hyprDir + "/config"];
        mkdir.running = true;
    }
    property string _pendingFile: ""

    function _doEval(lua: string): void {
        root._evalText = "";
        evalProc.command = ["sh", "-c", 'command -v "$1" >/dev/null 2>&1 || { echo "error: $1 not found"; exit 0; }; exec "$1" eval "$2"',
                            "sh", root.hyprctl, lua];
        evalProc.running = true;
    }

    Process {
        id: mkdir
        onExited: (code, status) => {
            if (code !== 0) {
                root._done("mkdir " + root.hyprDir + "/config failed");
                return;
            }
            luaFile.setText(root._pendingFile);
            root._pendingFile = "";
            root._askProbe();
            root._done("");
        }
    }

    Process {
        id: evalProc
        stdout: StdioCollector {
            id: evalOut
        }
        stderr: StdioCollector {
            id: evalErr
        }
        onExited: (code, status) => {
            const out = (evalOut.text + " " + evalErr.text).trim();
            const warned = code === 0 && out !== "" && out.split("\n").every(l => /^(ok\b|warning:)/.test(l.trim()) || l.trim() === "");
            if (code !== 0 || (out.indexOf("ok") !== 0 && !warned)) {
                root._done(out === "" ? ("hyprctl eval exited " + code) : out);
            } else {
                if (warned && out.indexOf("warning:") >= 0)
                    console.warn("LARES panorama engine warned:", out.replace(/\s+/g, " "));
                root._done("");
                root._readState();
            }
        }
    }

    // ---- the generated file, the engine source, the state file -----------------------------------------------------------------
    FileView {
        id: luaFile
        path: root._luaPath
        atomicWrites: true
        blockWrites: true
        printErrors: false
    }

    FileView {
        id: engineFile
        path: root.engineSource
        blockLoading: true
        printErrors: false
    }

    FileView {
        id: stateFile
        path: root._statePath
        blockLoading: true
        blockAllReads: true
        watchChanges: true
        printErrors: false
        onFileChanged: root._readState()
    }

    function _readState(): void {
        if (!root.live)
            return;
        let text = "";
        try {
            stateFile.reload();
            text = stateFile.text();
        } catch (e) {
            text = "";
        }
        let parsed = null;
        try {
            parsed = text.trim() === "" ? null : JSON.parse(text);
        } catch (e) {
            parsed = null;
        }
        if (parsed !== null && root._session !== "" && parsed.session !== root._session)
            parsed = null;               // an earlier session's file: nobody answered in this one
        root.state = parsed;
        root.version = parsed ? (parsed.engine || 0) : 0;
        // the engine spoke after the failure: whatever failed, it is running
        if (root.lastError !== "" && parsed !== null && (parsed.serial || 0) > root._errorSerial)
            root.lastError = "";
        root._judge();
    }

    function _judge(): void {
        let name = root.stateName, why = root.why;
        if (!root.live) {
            name = "missing";
            why = "The display engine is not running here.";
        } else if (root._probe === 3) {
            name = "missing";
            why = "Panorama is not set up yet: run lares panorama-import.";
        } else if (root._probe === 4) {
            name = "missing";
            why = "The display engine's file is being written.";
        } else if (root._probe === 1) {
            name = "missing";
            why = "The Hyprland config does not load config/panorama: run lares panorama-import.";
        } else if (root._probe === 0) {
            if (root.lastError !== "") {
                name = "error";
                why = root.lastError;
            } else if (root.state === null) {
                name = "error";
                why = "The display engine has not answered in this session: reload the Hyprland config.";
            } else if (root._treeVersion > 0 && root.version < root._treeVersion) {
                name = "stale";
                why = "The display engine is older than this shell's.";
            } else {
                name = "active";
                why = "";
            }
        }
        if (name !== root.stateName)
            root.stateName = name;
        if (why !== root.why)
            root.why = why;
    }

    // ---- whether the user's hypr config loads the file ---------------------------------------------------------------------------
    function _askProbe(): void {
        if (!root.live || probe.running)
            return;
        probe.command = ["sh", "-c", 'grep -rqsE "require[^\\n]*config/panorama" "$1" --include=*.lua --exclude=panorama.lua; line=$?; '
                         + 'if [ -f "$1/config/panorama.lua" ]; then [ $line -eq 0 ] || exit 1; else [ $line -eq 0 ] && exit 4; exit 3; fi',
                         "sh", root.hyprDir];
        probe.running = true;
    }

    Process {
        id: probe
        onExited: (code, status) => {
            root._probe = code;
            root._judge();
        }
    }

    // ---- the engine's nudge ----------------------------------------------------------------------------------------------------------
    Connections {
        target: root.live ? Hyprland : null
        function onRawEvent(ev) {
            if (ev.name === "custom" && String(ev.data).indexOf("lares-panorama") === 0) {
                root._readState();
                // the engine speaks while the file / the require line was not seen: `lares panorama-import` has just loaded it
                // (by eval, no reload), so look again -- or the popup stays read-only until Hyprland's next reload
                if (root._probe !== 0)
                    root._askProbe();
            } else if (ev.name === "configreloaded")
                root._askProbe();
        }
    }

    onLiveChanged: {
        if (root.live)
            root.refresh();
        else
            root._judge();
    }

    Component.onCompleted: {
        root._treeVersion = Gen.engineVersion(engineFile.text());
        if (root.live)
            root.refresh();
    }
}
