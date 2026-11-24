pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

// =============================================================================
// OllamaGpu.qml -- the GPU for whoever runs a local model, without the user. ONE per shell.
//
// The wiki and the LLM chat want the same card: when ollama has no dGPU to use, this enables it and restarts the service
// (so that it knows a dGPU exists) instead of telling the user that there is no GPU. Switching to Hybrid is not enough:
// after a model loads `ollama ps` must say GPU, else the service is restarted and the model reloaded -- one helper shared
// by the LLM and the wiki. It lives HERE, not in a module, because two modules hold the card and the shell builds one: two
// helpers would each put the mode back over the other's work.
//
// HOLDERS, REFERENCE-COUNTED. A holder is a name ("wiki", "llm"); acquire(name) is idempotent per name, release(name) lets
// go. The mode is changed once, by the first holder, and put back once, by the last to let go -- unless the user moved it
// meanwhile (silicon.gpuMode or its target no longer Hybrid): their choice stands.
//
//   acquire(h)   1. the dGPU must be reachable: silicon.gpuMode below Hybrid -> silicon.setGpuMode(2); wait for it
//                   (`switching`), then for nvidia-smi to answer, the card wakes in 20-60 s (`waking`)
//                2. ollama must have STARTED with it: its journal's last "inference compute" line says library=cpu when it
//                   came up with the card blocked (`checking`); then `systemctl restart --no-ask-password ollama.service`
//                   (`restarting`) and the same line must say something else afterwards. The restart needs the polkit rule
//                   of tools/wiki/polkit/ (a FILE the user installs once; nothing here installs it): without it systemd
//                   refuses at once and the reason says so -- never a password prompt out of a background job.
//                -> readyFor(h), or failedFor(h, reason) for EVERY holder still waiting; the mode is put back at once when
//                   that leaves nobody holding. A holder that joins a ready card is told at once; one that joins a cycle in
//                   progress waits with the others.
//   release(h)   the last one out puts the mode back (`{ confirmHolders: true }`: Integrated and Smart block the card for
//                NEW opens only, and ollama is the app that holds it, put there by this very work).
//   verifyLoad(model)   THE CHECK AFTER A LOAD. `ollama ps` (/api/ps) must say the model is in VRAM
//                (size_vram > 0). On the CPU with the card up: ONE restart (the same polkit path), then reloadNeeded(model)
//                -- the caller loads the model again and calls verifyLoad once more; a second CPU answer, or a refused
//                restart, is verifyFailed(model, reason). Never a restart under a running answer: the CALLER decides when
//                (the LLM asks only when nothing streams). One restart per hold of the card: it is forgotten when the card is
//                let go and when a load is seen on the GPU.
//
// Nothing to drive (no silicon injected, cardwire absent: `silicon.gpu.present` false) = readyFor() at once, verified at
// once, and the tool's own guard decides.
//
// LIVE OR NOT. `live` false (the default: a host that forgets cannot reach the machine) runs NO process: the silicon it was
// handed (the mock) still moves, the waits are timers (`simMs`), and a verify answers from `simCpu` (the mockup's knob: the
// first read of a hold says CPU, so the restart path can be watched). The commands are arrays a probe points at stubs; the
// defaults are the machine's.
//
//   phase    "idle" | "switching" | "waking" | "checking" | "restarting" | "ready" | "failed"
//   reason   why the last acquire failed ("" otherwise)
//   holders  the names holding now
// =============================================================================
Item {
    id: root

    property var silicon: null
    property bool live: false
    property string ollamaUrl: "http://localhost:11434"

    // How long each wait may take (ms), and the poll between asks.
    property int switchMs: 30000
    property int wakeMs: 90000
    property int restartWaitMs: 40000
    property int verifyWaitMs: 30000
    property int pollMs: 2000
    // Not live: how long a wake / a restart takes (the mockup shows the states in between).
    property int simMs: 1600
    // Not live: the first verify of a hold finds the model on the CPU.
    property bool simCpu: false

    // The machine's commands. `timeout 10` first: nvidia-smi on a blocked card can hang.
    property var smiCommand: ["timeout", "10", "nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"]
    property var journalCommand: ["sh", "-c", "journalctl -u ollama.service -b --no-pager -o cat 2>/dev/null | grep 'inference compute' | tail -n 1"]
    property var restartCommand: ["systemctl", "restart", "--no-ask-password", "ollama.service"]
    readonly property var versionCommand: ["curl", "-sf", "--max-time", "3", root.ollamaUrl.replace(/\/+$/, "") + "/api/version"]
    readonly property var psCommand: ["curl", "-sf", "--max-time", "3", root.ollamaUrl.replace(/\/+$/, "") + "/api/ps"]

    readonly property bool drivable: !!root.silicon && !!root.silicon.gpu && root.silicon.gpu.present === true
    readonly property string phase: root._phase
    readonly property string reason: root._reason
    readonly property var holders: root._names
    // Somebody holds (or is getting) the card.
    readonly property bool busy: root._names.length > 0
    // What the user is told while it works (a function of the phase: a change handler asks it with the phase it was given).
    function sayOf(p) {
        switch (p) {
        case "switching": return "switching the GPU on";
        case "waking": return "waiting for the GPU to wake";
        case "checking": return "checking that ollama sees the GPU";
        case "restarting": return "restarting ollama";
        default: return "";
        }
    }

    signal readyFor(string holder)
    signal failedFor(string holder, string reason)
    signal verified(string model)
    signal reloadNeeded(string model)
    signal verifyFailed(string model, string reason)

    property string _phase: "idle"
    property string _reason: ""
    property var _h: ({})                // holder -> told ready
    property var _names: []
    property int _restore: -1            // the mode to put back; -1 none
    property real _since: 0
    property bool _restarted: false     // the restart command has succeeded
    property bool _answered: false      // and ollama answers again
    property string _refusal: ""
    property string _vModel: ""         // a verify in flight (its restart is the "restarting" phase)
    property real _vSince: 0
    property bool _vRestarted: false    // this hold has used its one restart
    property bool _simSeen: false       // not live: the CPU answer was given

    function isReady(holder) {
        return root._h[holder] === true;
    }

    function _go(p) {
        root._phase = p;
        root._since = Date.now();
    }
    function _sync() {
        root._names = Object.keys(root._h);
    }

    function acquire(holder) {
        if (typeof holder !== "string" || holder === "")
            return;
        if (root._h[holder] !== undefined) {
            if (root._h[holder] === true)
                root.readyFor(holder);
            return;
        }
        const first = root._names.length === 0;
        const h = Object.assign({}, root._h);
        h[holder] = false;
        root._h = h;
        root._sync();
        if (first) {
            root._begin();
        } else if (root._phase === "ready") {
            root._finish();
        }
        // else: a cycle is in progress, the holder waits with the others
    }

    function _begin() {
        root._reason = "";
        root._refusal = "";
        root._restarted = false;
        root._answered = false;
        root._restore = -1;
        root._vModel = "";
        root._vRestarted = false;
        root._simSeen = false;
        if (!root.drivable) {
            root._go("ready");
            root._finish();
            return;
        }
        const was = root.silicon.gpuMode;
        if (was < 2) {
            root._restore = was;
            const ok = root.silicon.setGpuMode(2, {});
            if (!ok && root.silicon.gpuModeTarget !== 2) {
                root._fail("the GPU cannot be switched on" + (root._refusal ? ": " + root._refusal : ""));
                return;
            }
            root._go("switching");
        } else {
            root._go("waking");
        }
        tick.restart();
        root._step();
    }

    // Everyone waiting is told: the card is theirs.
    function _finish() {
        root._go("ready");
        tick.stop();
        const told = [];
        const h = Object.assign({}, root._h);
        Object.keys(h).forEach(function (k) {
            if (h[k] !== true) {
                h[k] = true;
                told.push(k);
            }
        });
        root._h = h;
        // a verify that was waiting for the card reads as soon as it is up
        if (root._vModel !== "")
            tick.restart();
        told.forEach(function (k) { root.readyFor(k); });
    }

    function _fail(why) {
        const waiting = root._names.slice();
        root._reason = why;
        root._go("failed");
        tick.stop();
        root._h = ({});
        root._sync();
        root._putBack();
        waiting.forEach(function (k) { root.failedFor(k, why); });
    }

    // The mode before the work back in place, once, unless the user moved it.
    function _putBack() {
        const to = root._restore;
        root._restore = -1;
        if (to < 0 || !root.drivable)
            return;
        if (root.silicon.gpuMode !== 2 || root.silicon.gpuModeTarget !== 2)
            return;
        root.silicon.setGpuMode(to, { confirmHolders: true });
    }

    function release(holder) {
        if (root._h[holder] === undefined)
            return;
        const h = Object.assign({}, root._h);
        delete h[holder];
        root._h = h;
        root._sync();
        if (root._names.length > 0)
            return;
        tick.stop();
        root._vModel = "";
        root._vRestarted = false;
        root._putBack();
        if (root._phase !== "failed")
            root._phase = "idle";
    }

    Connections {
        target: root.silicon
        ignoreUnknownSignals: true
        function onWriteRefused(zone, why) { root._refusal = String(why); }
    }

    // One poll clock for every wait.
    Timer {
        id: tick
        interval: root.pollMs
        repeat: true
        onTriggered: root._step()
    }

    function _step() {
        if (root._phase === "switching") {
            if (root.silicon.gpuMode === 2)
                root._go("waking");
            else if (Date.now() - root._since > root.switchMs)
                root._fail("silicon did not reach Hybrid within " + Math.round(root.switchMs / 1000) + " s");
        }
        const waited = Date.now() - root._since;
        if (root._phase === "waking") {
            if (!root.live) {
                if (waited >= root.simMs)
                    root._finish();
                return;
            }
            if (smi.running)
                return;
            if (waited > root.wakeMs) {
                root._fail("the GPU did not answer within " + Math.round(root.wakeMs / 1000) + " s");
                return;
            }
            smi.command = root.smiCommand;
            smi.running = true;
        } else if (root._phase === "restarting" && (root._restarted || !root.live)) {
            if (!root.live) {
                if (waited >= root.simMs) {
                    if (root._vModel !== "")
                        root._restartedForVerify();
                    else
                        root._finish();
                }
                return;
            }
            if (waited > root.restartWaitMs) {
                const why = root._answered ? "ollama was restarted but still sees no GPU"
                                           : "ollama did not come back within " + Math.round(root.restartWaitMs / 1000) + " s of its restart";
                root._restartFailed(why);
                return;
            }
            if (versionProc.running || journal.running)
                return;
            if (root._answered && root._vModel !== "") {
                root._restartedForVerify();
            } else if (root._answered) {
                // up: its first lines about the card may not be written yet -- read them again
                journal.command = root.journalCommand;
                journal.running = true;
            } else {
                versionProc.command = root.versionCommand;
                versionProc.running = true;
            }
        }
        if (root._vModel !== "" && root._phase === "ready")
            root._verifyStep();
    }

    // A restart that did not come to anything: the acquire fails the holders; a verify's restart fails that verify only.
    function _restartFailed(why) {
        if (root._vModel !== "") {
            const m = root._vModel;
            root._vModel = "";
            root._finish();
            root.verifyFailed(m, why);
        } else {
            root._fail(why);
        }
    }

    Process {
        id: smi
        running: false
        stdout: StdioCollector { id: smiOut }
        stderr: StdioCollector {}
    }
    Connections {
        target: smi
        function onExited(code) {
            if (root._phase !== "waking")
                return;
            // A number of MiB is the card answering.
            if (code === 0 && /^\s*\d+/.test(smiOut.text)) {
                root._go("checking");
                journal.command = root.journalCommand;
                journal.running = true;
            }
        }
    }

    // ollama's own record of what it found at its start.
    Process {
        id: journal
        running: false
        stdout: StdioCollector { id: journalOut }
        stderr: StdioCollector {}
    }
    Connections {
        target: journal
        function onExited() {
            if (root._phase !== "checking" && root._phase !== "restarting")
                return;
            const m = /library=(\w+)/.exec(journalOut.text);
            const lib = m ? m[1] : "";
            if (root._phase === "checking") {
                // cpu = it came up with the card blocked and has never seen it. No line (a journal the user cannot read, a
                // log rotated away) is not evidence of anything: it is left alone.
                if (lib === "cpu") {
                    root._go("restarting");
                    restartProc.command = root.restartCommand;
                    restartProc.running = true;
                } else {
                    root._finish();
                }
            } else if (lib !== "cpu") {
                root._finish();
            }
            // still cpu after the restart: the next poll reads again; the step fails it when the wait is over
        }
    }

    Process {
        id: restartProc
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector { id: restartErr }
    }
    Connections {
        target: restartProc
        function onExited(code) {
            if (root._phase !== "restarting")
                return;
            if (code !== 0) {
                const first = restartErr.text.trim().split("\n")[0];
                root._restartFailed("ollama started without the GPU and the shell may not restart it: install the polkit rule"
                                    + " (tools/wiki/polkit/49-wiki-ollama-restart.rules.in)" + (first ? " [" + first + "]" : ""));
                return;
            }
            root._restarted = true;
            root._since = Date.now();
            root._step();
        }
    }
    Process {
        id: versionProc
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector {}
    }
    Connections {
        target: versionProc
        function onExited(code) {
            if (root._phase !== "restarting" || !root._restarted || code !== 0)
                return;
            root._answered = true;
            if (root._vModel !== "") {
                root._restartedForVerify();
                return;
            }
            journal.command = root.journalCommand;
            journal.running = true;
        }
    }

    // ---- the check after a load -----------------------------------------------------------------------------------
    // Call it when `model` has been loaded (or is about to be: the read waits up to verifyWaitMs for it to show). Exactly one of
    // verified / reloadNeeded / verifyFailed answers.
    function verifyLoad(model) {
        if (typeof model !== "string" || model === "")
            return;
        root._vModel = model;
        root._vSince = Date.now();
        if (!root.drivable || root._names.length === 0) {
            root._vDone(true);        // nothing of ours is on the card: nothing to say
            return;
        }
        if (root._phase !== "ready") {
            // the card is still being got; the read happens when it is up
            tick.restart();
            return;
        }
        tick.restart();
        root._verifyStep();
    }

    function _verifyStep() {
        if (root._vModel === "" || root._phase !== "ready")
            return;
        if (!root.live) {
            if (Date.now() - root._vSince < 200)
                return;
            const cpu = root.simCpu && !root._simSeen;
            root._simSeen = true;
            root._vAnswer(cpu);
            return;
        }
        if (psProc.running)
            return;
        if (Date.now() - root._vSince > root.verifyWaitMs) {
            const m = root._vModel;
            root._vModel = "";
            tick.stop();
            root.verifyFailed(m, "ollama does not list " + m + " as loaded");
            return;
        }
        psProc.command = root.psCommand;
        psProc.running = true;
    }

    Process {
        id: psProc
        running: false
        stdout: StdioCollector { id: psOut }
        stderr: StdioCollector {}
    }
    Connections {
        target: psProc
        function onExited(code) {
            if (root._vModel === "" || root._phase !== "ready")
                return;
            let list = null;
            try {
                list = JSON.parse(psOut.text).models;
            } catch (e) {
                list = null;
            }
            if (code !== 0 || !Array.isArray(list))
                return;               // not answering yet: the next poll asks again
            let row = null;
            for (let i = 0; i < list.length; i++) {
                if (list[i] && (list[i].name === root._vModel || list[i].model === root._vModel))
                    row = list[i];
            }
            if (!row || !(row.size > 0))
                return;               // not loaded yet
            root._vAnswer(!(row.size_vram > 0));
        }
    }

    // `cpu`: the model is loaded and none of it is on the card.
    function _vAnswer(cpu) {
        if (!cpu) {
            root._vDone(true);
            return;
        }
        const m = root._vModel;
        if (root._vRestarted) {
            root._vModel = "";
            tick.stop();
            root.verifyFailed(m, m + " still runs on the CPU after ollama was restarted");
            return;
        }
        root._vRestarted = true;
        root._restarted = false;
        root._answered = false;
        root._go("restarting");
        if (root.live) {
            restartProc.command = root.restartCommand;
            restartProc.running = true;
        }
        tick.restart();
    }

    function _restartedForVerify() {
        const m = root._vModel;
        root._vModel = "";
        root._finish();
        root.reloadNeeded(m);
    }

    function _vDone(ok) {
        const m = root._vModel;
        root._vModel = "";
        if (ok) {
            root._vRestarted = false;
            if (root._names.length === 0 || root._phase === "ready")
                tick.stop();
            root.verified(m);
        }
    }
}
