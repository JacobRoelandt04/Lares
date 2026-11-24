pragma ComponentBehavior: Bound

import QtQuick
import "../../common/system"
import "DdcParse.js" as P

// =============================================================================
// DdcClient.qml -- the brightness of the external displays over DDC/CI (`ddcutil`, VCP 10), ONE lane.
//
//   live                false: nothing is ever run (a mockup, a probe that did not arm it)
//   program             "ddcutil" (a probe's stub)
//   outputs             [{ name, description, make, model, serial }]: the outputs Hyprland has (the service binds its own). A change of the
//                       NAMES runs a detect by itself (ensureDetected), so a display is known before the first key, and again on a plug
//   sysRoot             "/sys" (a probe's fake): where a block with no "DRM connector" line finds its connector by I2C bus
//   ensureDetected()    detect when this output set has not been looked at (or the last look failed and `retryMs` passed). Cheap to call
//   detectedFor         the output signature the last detect answered for ("" none)
//   detect()            `ddcutil detect --terse` NOW, then every capable display's brightness is read
//   stateOf(name)        "unknown" (not looked for yet) | "probing" (a read is out) | "ok" | "unsupported" (detect ran, no DDC for
//                       it) | "failing" (a read or write failed; reasonOf(name) has ddcutil's words). A failing display is not asked
//                       again for `retryMs` (60 s) or until the output set changes: a refused call returns false
//   reasonOf(name)       the words of "failing" / "unsupported"
//   capable(name)       a display with a DDC channel, and not an internal panel. A DisplayLink (evdi) output is one by its connector's own
//                       I2C bus, spoken to by `directProgram` (ddcutil refuses that bus: see `directProgram`)
//   value(name)         the last brightness read or set (0..max), -1 when unknown. A getter: it asks for nothing
//   goal(name)          the newest figure asked for (what the hand wants), else value(name)
//   pending(name)       a goal is out: waiting for its write or for the read an unknown value needs
//   max(name)           the display's real maximum (`getvcp` answers it), 100 until read
//   busy(name), error(name)
//   read(name, force)   ask the display (skipped while the cached reading is younger than `cacheMs`, 60 s)
//   set(name, v)        COALESCED: while a call for that display runs, only the newest target waits (a burst of five is the
//                       first call and the newest). false = refused (no DDC for it, failing)
//   adjust(name, d)     set(name, goal + d). With the value not known yet the step is KEPT and applied when the read lands (no press is
//                       dropped); false only when the display cannot take it (unsupported, failing)
//   scrub(name, v)      a slider being dragged: the goal and the figure follow the hand, the write goes out `restMs` (250) after the
//                       last motion, or at once on commit(name) (the release)
//   forgive(name)       a remembered failure is dropped for one more try now (a read, or a detect when the last one failed)
//   names(), keyOf(name)   the outputs a detect found a channel for; the display's identity (make | model | serial)
//   valueChanged(name)  the cached figure, busy, pending or state of that output moved
//
// `name` is the Hyprland output name ("DP-1"): ddcutil's DRM connector with the card stripped. Every call names its bus
// (`--bus N`: no probing of every bus). A write goes with `--noverify` (the read-back doubles the time on a slow panel) EXCEPT the first
// write to a display after a detect: it is verified (ddcutil's own check, then a read of the figure) and a display whose figure did not
// move is "failing", "the display ignored the request". The calls share ONE lane (I2C does not like two at once) with a watchdog
// (`timeoutMs`); a timeout is an error on that display, not a stuck lane.
// =============================================================================

Item {
    id: root

    property bool live: false
    property string program: "ddcutil"
    property var drm: null                  // DrmWatch (optional): its driver of a connector tells an evdi output
    property var outputs: []
    property string sysRoot: "/sys"
    // EVERY CALL THAT NAMES ITS BUS SKIPS ddcutil's OWN START-UP CHECKS (3.0.2): on the laptop's NVIDIA HDMI those checks retry and sleep for
    // six seconds before a 0.1 s read or write (`--stats`: 5.7 s of sleeps, 4 of 8 attempts failed), so a key's step took ~13 s with its
    // verification or ran into the timeout, and the level read 0. The detect has proved the display speaks DDC; a write is still verified.
    property var fastArgs: ["--skip-ddc-checks"]
    // A DISPLAYLINK OUTPUT IS NOT IN ddcutil's LIST AT ALL (3.0.2, the user's dock, 2026-11-23): evdi's "DisplayLink I2C Adapter" answers
    // DDC/CI at 0x37 and gives no EDID at 0x50, and ddcutil gates every bus on that EDID ("cannot be used for DDC/CI communication").
    // Such an output is found by its connector's `ddc` link in sysfs and spoken to by our own tool (same `VCP 10 C cur max` answer, 0.08 s).
    // Its device node is root's until the udev rule of `lares setup` is in (tools/shell/root/61-lares-displaylink-ddc.rules).
    property string directProgram: RepoRoot.dir + "/tools/panorama/lares-ddc"
    property int timeoutMs: 8000
    property int cacheMs: 60000
    property int retryMs: 60000
    property int restMs: 250

    readonly property bool detecting: root._detecting
    readonly property bool detected: root._detected
    readonly property string detectedFor: root._detectedFor
    readonly property var displays: root._displays
    signal valueChanged(string connector)

    function capable(connector: string): bool {
        const d = root._displays[connector];
        return d !== undefined && d.valid && !root._blocked(d);
    }

    function stateOf(connector: string): string {
        const s = root._st[connector];
        if (s !== undefined)
            return s.state;
        if (P.neverDdc(connector))
            return "unsupported";
        return root._detected ? "unsupported" : "unknown";
    }

    function reasonOf(connector: string): string {
        const s = root._st[connector];
        if (s !== undefined)
            return s.reason || "";
        return root.stateOf(connector) === "unsupported" ? (P.neverDdc(connector) ? "The laptop panel is not a DDC display." : "No DDC channel found for this display.") : "";
    }

    function value(connector: string): int {
        const c = root._cache[connector];
        return c !== undefined && c.v >= 0 ? c.v : -1;
    }

    function goal(connector: string): int {
        const g = root._goal[connector];
        return g !== undefined ? g : root.value(connector);
    }

    function pending(connector: string): bool {
        return root._goal[connector] !== undefined || (root._delta[connector] || 0) !== 0;
    }

    function max(connector: string): int {
        const c = root._cache[connector];
        return c !== undefined && c.max > 0 ? c.max : 100;
    }

    function busy(connector: string): bool {
        return root._busyOf[connector] === true;
    }

    function error(connector: string): string {
        return root.stateOf(connector) === "failing" ? root.reasonOf(connector) : "";
    }

    function ensureDetected(): void {
        if (!root.live)
            return;
        const key = P.signature(root.outputs);
        if (key === "")
            return;
        if (root._detecting) {
            if (key !== root._detectKey)
                root._detectAgain = true;
            return;
        }
        if (key === root._detectedFor && (root._detected || Date.now() - root._detectFailAt < root.retryMs))
            return;
        root.detect();
    }

    function detect(): void {
        if (!root.live)
            return;
        if (root._detecting) {
            root._detectAgain = true;
            return;
        }
        root._detecting = true;
        root._detectKey = P.signature(root.outputs);
        lane.run([root.program, "detect", "--terse"], function (r) {
            if (r.code !== 0 || r.timedOut) {
                root._detectDone(r, [], {});
                return;
            }
            const list = P.parseDetect(r.out);
            if (!list.some(d => d.valid && d.connector === "") && root._directNames().length === 0) {
                root._detectDone(r, list, {});
                return;
            }
            // a block with no connector line (the NVIDIA driver), or a DisplayLink output: the bus names it through sysfs
            lane.run(["sh", "-c", root._busScript, "sh", root.sysRoot], function (r2) {
                root._detectDone(r, list, P.parseBusMap(r2.out));
            });
        });
    }

    function read(connector: string, force: bool): void {
        const d = root._displays[connector];
        if (!root.live || d === undefined || !root.capable(connector) || root._refused(connector))
            return;
        const c = root._cache[connector];
        if (force !== true) {
            if (c && Date.now() - c.at < root.cacheMs)
                return;
        }
        if (root._busyOf[connector] === true)
            return;
        root._setBusy(connector, true);
        if (root.stateOf(connector) !== "ok")
            root._mark(connector, "probing", "");
        lane.run(root._getArgv(d), function (r) {
            root._setBusy(connector, false);
            const p = r.timedOut ? { ok: false, error: "no answer in " + root.timeoutMs + " ms" } : P.parseGetvcp(r.out + "\n" + r.err);
            if (p.ok) {
                root._put(connector, p.cur, p.max);
            } else {
                root._fail(connector, root._why(p.error), /not supported/.test(p.error) ? "unsupported" : "failing");
            }
        });
    }

    function set(connector: string, v: real): bool {
        if (!root._canWrite(connector))
            return false;
        const target = Math.max(0, Math.min(root.max(connector), Math.round(v)));
        root._take(connector, target);
        delete root._scrubAt[connector];
        root._dispatch(connector, target);
        return true;
    }

    function adjust(connector: string, delta: real): bool {
        if (!root.live)
            return false;
        root.ensureDetected();
        const st = root.stateOf(connector);
        if (st === "unsupported" || root._refused(connector))
            return false;
        const g = root._goal[connector];
        const base = g !== undefined ? g : root.value(connector);
        if (base >= 0)
            return root.set(connector, base + delta);
        if (root._displays[connector] !== undefined && !root.capable(connector))
            return false;
        // the value is not known yet: keep the step, apply it when the read lands
        root._delta[connector] = (root._delta[connector] || 0) + delta;
        if (root.capable(connector))
            root.read(connector, false);
        root.valueChanged(connector);
        return true;
    }

    function scrub(connector: string, v: real): bool {
        if (!root._canWrite(connector))
            return false;
        const target = Math.max(0, Math.min(root.max(connector), Math.round(v)));
        root._take(connector, target);
        root._scrubAt[connector] = Date.now();
        rest.restart();
        return true;
    }

    // A remembered failure is dropped for one more try NOW (the idle dim's give-back must not wait out `retryMs`): the display is read, and
    // answers as "ok" or "failing" again. With no answer from the last detect, detect again.
    function forgive(connector: string): void {
        if (!root.live || root.stateOf(connector) !== "failing")
            return;
        if (!root._detected || root._displays[connector] === undefined) {
            root.detect();
            return;
        }
        root._mark(connector, "probing", "");
        root.read(connector, true);
    }

    // The outputs a brightness can be asked of (a detect found a channel; a failing one is still listed).
    function names(): var {
        return (root.outputs || []).map(o => o.name).filter(n => n && root.capable(n));
    }

    // Who the display on that output is, whatever the connector: make | model | serial.
    function keyOf(connector: string): string {
        const l = root.outputs || [];
        for (let i = 0; i < l.length; i++)
            if (l[i].name === connector)
                return [l[i].make || "", l[i].model || "", l[i].serial || ""].join("|") === "||" ? connector : [l[i].make || "", l[i].model || "", l[i].serial || ""].join("|");
        return connector;
    }

    function commit(connector: string): void {
        if (root._scrubAt[connector] === undefined)
            return;
        delete root._scrubAt[connector];
        const g = root._goal[connector];
        if (g !== undefined)
            root._dispatch(connector, g);
    }

    // ---- Private ---------------------------------------------------------------
    property bool _detecting: false
    property bool _detectAgain: false
    property bool _detected: false
    property string _detectedFor: ""
    property string _detectKey: ""
    property real _detectFailAt: 0
    property var _displays: ({})
    property var _st: ({})          // name -> { state, reason, at }
    property var _cache: ({})       // name -> { v, max, at }
    property var _good: ({})        // name -> the last figure the display confirmed
    property var _goal: ({})        // name -> the newest figure asked for, until its write is done
    property var _delta: ({})       // name -> key steps kept while the value is unknown
    property var _verified: ({})    // name -> the first write after a detect was checked
    property var _scrubAt: ({})     // name -> the instant of the last slider motion
    property var _busyOf: ({})
    property var _setting: ({})     // name -> a setvcp is out
    property var _next: ({})        // name -> the newest target waiting behind it

    readonly property string _busScript: 'for c in "$1"/class/drm/card*-*; do [ -e "$c/ddc" ] && echo "$(basename "$c") $(basename "$(readlink -f "$c/ddc")")"; done; for i in "$1"/bus/i2c/devices/i2c-*; do b=$(basename "$(readlink -f "$i/device" 2>/dev/null)"); case "$b" in card*-*) echo "$b $(basename "$i")";; esac; done; true'

    ProcLane { id: lane; timeoutMs: root.timeoutMs }

    Timer {
        id: rest
        interval: root.restMs
        onTriggered: {
            const now = Date.now();
            let left = false;
            for (const n in root._scrubAt) {
                if (now - root._scrubAt[n] >= root.restMs - 15)
                    root.commit(n);
                else
                    left = true;
            }
            if (left)
                rest.restart();
        }
    }

    onOutputsChanged: root.ensureDetected()
    Component.onCompleted: root.ensureDetected()

    function _blocked(d) {
        return P.neverDdc(d.connector);
    }

    function _mark(name, state, reason) {
        const was = root._st[name];
        root._st[name] = { state: state, reason: reason, at: Date.now() };
        if (!was || was.state !== state)
            root.valueChanged(name);
    }

    // a failing display is left alone for retryMs
    function _refused(name) {
        const s = root._st[name];
        return s !== undefined && s.state === "failing" && Date.now() - s.at < root.retryMs;
    }

    function _canWrite(name) {
        return root.live && root.capable(name) && !root._refused(name);
    }

    function _fail(name, why, state) {
        root._st[name] = { state: state, reason: why, at: Date.now() };
        delete root._goal[name];
        delete root._next[name];
        delete root._delta[name];
        delete root._scrubAt[name];
        root._setting[name] = false;
        const c = root._cache[name];
        root._cache[name] = { v: root._good[name] !== undefined ? root._good[name] : -1, max: c ? c.max : 100, at: 0 };
        root._busyOf[name] = false;
        root.valueChanged(name);
    }

    function _detectDone(r, list, busMap) {
        root._detecting = false;
        root._detectedFor = root._detectKey;
        root._verified = {};
        root._st = {};
        const names = (root.outputs || []).map(o => o.name).filter(n => n && !P.neverDdc(n));
        if (r.code !== 0 || r.timedOut) {
            root._detected = false;
            root._detectFailAt = Date.now();
            const why = r.timedOut ? "ddcutil did not answer" : (String(r.err).trim().split("\n")[0] || "ddcutil detect failed");
            names.forEach(n => { root._st[n] = { state: "failing", reason: why, at: Date.now() }; });
        } else {
            const res = P.resolveDisplays(list, root.outputs, busMap);
            // a DisplayLink output: its connector's own bus, ours to speak to
            root._directNames().forEach(n => {
                delete res.map[n];
                for (const b in busMap)
                    if (busMap[b] === n)
                        res.map[n] = { valid: true, bus: parseInt(b, 10), connector: n, direct: true, model: "", serial: "" };
            });
            root._displays = res.map;
            root._detected = true;
            names.concat(Object.keys(res.map)).forEach(n => {
                if (root.capable(n))
                    root._st[n] = { state: "probing", reason: "", at: Date.now() };
                else
                    root._st[n] = { state: "unsupported", reason: root._blockedWhy(n), at: Date.now() };
            });
        }
        for (const n in root._delta)
            if (root.stateOf(n) === "unsupported" || root.stateOf(n) === "failing")
                delete root._delta[n];
        const all = Object.keys(root._st);
        all.forEach(n => root.valueChanged(n));
        root.valueChanged("");
        // Read every one NOW, whatever a cached figure's age: it is the figure of what was on that connector before (a display switched off
        // and on within `cacheMs` stayed "probing" for ever, on the figure of before). One with a call out is read when the call ends.
        if (root._detected)
            for (const name in root._displays)
                if (root.capable(name))
                    root.read(name, true);
        if (root._detectAgain) {
            root._detectAgain = false;
            Qt.callLater(root.ensureDetected);
        }
    }

    function _blockedWhy(name) {
        return root._directNames().indexOf(name) >= 0 ? "The dock gives this display no DDC bus." : "This display takes no brightness over DDC.";
    }

    // the outputs on an evdi (DisplayLink) connector
    function _directNames() {
        const list = root.drm ? root.drm.connectors : null;
        const res = [];
        if (list)
            for (let i = 0; i < list.length; i++)
                if (list[i].driver === "evdi" && list[i].status === "connected" && !P.neverDdc(list[i].name))
                    res.push(list[i].name);
        return res;
    }

    function _getArgv(d) {
        return d.direct ? [root.directProgram, "get", String(d.bus)] : [root.program, "getvcp", "10", "--brief", "--bus", String(d.bus)].concat(root.fastArgs);
    }

    // a refusal's words: our tool's "cannot open ...: Permission denied" is the missing udev rule
    function _why(e) {
        return /Permission denied/.test(e) ? "the dock's brightness bus is not open to you (lares setup)" : e;
    }

    function _setBusy(connector, on) {
        if ((root._busyOf[connector] === true) === on)
            return;
        root._busyOf[connector] = on;
        root.valueChanged(connector);
        if (!on)
            Qt.callLater(root._settleProbe, connector);
    }
    function _settleProbe(connector) {
        const s = root._st[connector];
        if (!root._detecting && s !== undefined && s.state === "probing" && root._busyOf[connector] !== true)
            root.read(connector, true);
    }

    // the figure the popup shows follows the hand at once; a failed call takes it back
    function _take(connector, target) {
        const c = root._cache[connector] || { v: -1, max: 100, at: 0 };
        root._cache[connector] = { v: target, max: c.max, at: Date.now() };
        root._goal[connector] = target;
        delete root._delta[connector];
        root.valueChanged(connector);
    }

    function _dispatch(connector, target) {
        if (root._setting[connector] === true) {
            root._next[connector] = target;
            return;
        }
        root._send(connector, target);
    }

    function _put(connector, cur, max) {
        const c = root._cache[connector];
        const was = c ? c.v : -2;
        const hadGoal = root._goal[connector] !== undefined;
        root._good[connector] = cur;
        root._cache[connector] = { v: hadGoal ? c.v : cur, max: max, at: Date.now() };
        const st = root._st[connector];
        if (!st || st.state !== "ok")
            root._st[connector] = { state: "ok", reason: "", at: Date.now() };
        const kept = root._delta[connector] || 0;
        if (kept !== 0) {
            delete root._delta[connector];
            root.set(connector, cur + kept);
            return;
        }
        if (was !== cur || !c || c.max !== max || !st || st.state !== "ok")
            root.valueChanged(connector);
    }

    function _send(connector, target) {
        const d = root._displays[connector];
        const first = root._verified[connector] !== true;
        const argv = d.direct ? [root.directProgram, "set", String(d.bus), String(target)]
                              : [root.program, "setvcp", "10", String(target), "--bus", String(d.bus)].concat(root.fastArgs);
        if (!first && !d.direct)
            argv.push("--noverify");
        root._setting[connector] = true;
        root._setBusy(connector, true);
        lane.run(argv, function (r) {
            if (r.code !== 0 || r.timedOut) {
                const e = String(r.err).trim().split("\n")[0];
                root._fail(connector, r.timedOut ? "no answer in " + root.timeoutMs + " ms" : (/verif/i.test(e) ? "the display ignored the request" : (root._why(e) || "the display refused")), "failing");
                return;
            }
            if (!first) {
                root._written(connector);
                return;
            }
            lane.run(root._getArgv(d), function (r2) {
                const p = r2.timedOut ? { ok: false, error: "no answer in " + root.timeoutMs + " ms" } : P.parseGetvcp(r2.out + "\n" + r2.err);
                if (!p.ok)
                    root._fail(connector, p.error, "failing");
                else if (Math.abs(p.cur - target) > 1)
                    root._fail(connector, "the display ignored the request", "failing");
                else {
                    root._verified[connector] = true;
                    root._written(connector);
                }
            });
        });
    }

    function _written(connector) {
        const next = root._next[connector];
        if (next !== undefined) {
            delete root._next[connector];
            root._send(connector, next);
            return;
        }
        delete root._goal[connector];
        root._good[connector] = root.value(connector);
        root._setting[connector] = false;
        root._setBusy(connector, false);
        root.valueChanged(connector);
    }

    Connections {
        target: root.drm
        enabled: root.drm !== null
        function onChanged() {
            if (root._detected || root._detecting)
                root.detect();
        }
    }
}
