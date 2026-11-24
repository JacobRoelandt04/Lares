pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import "CardwireParse.js" as CW
import "../../common/system"

// =============================================================================
// CardwireClient.qml -- silicon's view of the cardwire daemon (GPU modes, Smart-mode policies,
// the dGPU's power state and its users).
//
//   READS    `busctl --json=short` calls and property reads, ONE ProcLane (one at a time); the
//            argv lists come from CardwireParse.js and are the only ones ever started.
//   SIGNALS  ONE `gdbus monitor` (`busctl monitor` is denied on this machine) under `setpriv
//            --pdeathsig TERM`, restarted with a back-off like SleepWatcher's: PowerStateChanged,
//            PropertiesChanged on Mode and Config, ProcessBlockedChanged, NewAppAdded.
//   WRITES   `set-property` on Mode and Config, `SetAppPolicy`: each read back, each answered by
//            ONE `wrote({ kind, ok, why, ... })`. Config setters persist by themselves.
//
// `bus` is "system" (the shell) or "session" (a probe's PRIVATE bus: busctl --user, gdbus
// --session) and nothing else; `nodes` and `pci` are the dGPU's own device nodes and PCI address
// from the helper's status, which is how the daemon's Gpu object for the NVIDIA card is found
// and who counts as using it (CardwireParse.lsofHolders).
//
// FACTS (all plain values, no colours):
//   present / why   cardwire answered / why it did not
//   settled         cardwire has been ASKED and the answer is a fact: it answered, or it did not answer `failsToSettle` asks in a row
//                   (about seven seconds), or it is switched off. Until then "no answer" is only "not yet" -- the daemon of a
//                   boot is busy, and the first read can fall in its start -- and a host draws nothing of its mode.
//   mode / modes    its Mode u (0 Integrated, 1 Hybrid, 2 Manual, 3 Smart; -1 unknown) and AvailableModes
//   config          { batteryAutoSwitch, batteryAutoSwitchMode, externalDisplayAutoSwitch, nvidiaBlock }
//   dState          D0 | D1 | D2 | D3hot | D3cold, "" until read; from the signal or PowerState()
//   holders         who uses the dGPU (the `Lsof` of ITS nodes minus the plumbing); [] when
//                   no nodes are known -- never a guess
//   blocked         ids of apps blocked at least once (the daemon's log, then the live signal)
//   policies        the apps worth listing: allowed by choice or blocked once, by name (the daemon has seen
//                   every app, kitty and quickshell among them)
//
// Nothing here wakes the dGPU: none of these calls does (measured: 36 of 36 samples asleep).
// =============================================================================
Item {
    id: root

    property string bus: "system"
    property bool active: true
    property var nodes: []
    // The process names that never count as users of the dGPU (silicon.jsonc `gpu.ignoredHolders`); null = CardwireParse's own list.
    property var ignoredHolders: null
    property string pci: ""
    property int timeoutMs: 6000
    // When cardwire is not there, ask again at this distance (a new owner on the bus asks at once). The asks start close
    // together (`firstRetryMs`, doubling) -- a daemon that is not up YET at the shell's start must not leave the bar's
    // GPU card on a guess for a minute -- and settle at `retryMs`.
    property int retryMs: 60000
    property int firstRetryMs: 1000
    property int failsToSettle: 4

    readonly property bool present: root._present
    readonly property bool settled: root._settled
    readonly property string why: root._whyText
    readonly property int mode: root._mode
    readonly property var modes: root._modes
    readonly property var config: root._config
    readonly property string dState: root._dState
    readonly property var holders: root._holders
    readonly property var blocked: root._blocked
    readonly property var policies: root._policies

    signal changed
    signal powerChanged(string dState)
    signal appBlocked(var entry)
    signal wrote(var result)

    // ---- control -----------------------------------------------------------
    function start() {
        if (root._started)
            return;
        root._started = true;
        root.refresh();
        root._startMonitor();
    }

    // Everything again: Mode, AvailableModes, Config, the Gpu object, policies, the blocked log,
    // power state, holders.
    function refresh() {
        if (!root.active) {
            root._absent("cardwire is switched off", true);
            return;
        }
        root._full();
    }

    // What a popup opening wants: the mode, the card's state and its users (3 calls); a daemon that
    // was not there is asked in full. The rest is kept current by the signals.
    function refreshLive() {
        if (!root.active || !root._present) {
            root.refresh();
            return;
        }
        const steps = [root._stepMode(), root._stepPower(), root._stepLsof()];
        root._runSteps(steps, root._gen);
    }

    function refreshHolders() {
        if (root._present && root._gpu >= 0)
            root._runSteps([root._stepLsof()], root._gen);
    }

    function refreshPower() {
        if (root._present && root._gpu >= 0)
            root._runSteps([root._stepPower()], root._gen);
    }

    // `mode` is cardwire's own number.
    function setMode(mode) {
        const argv = CW.setModeArgv(root.bus, mode);
        if (argv === null) {
            root.wrote({ kind: "mode", ok: false, why: "That is not a cardwire mode", want: mode });
            return;
        }
        lane.run(argv, function (res) {
            if (res.code !== 0) {
                root.wrote({ kind: "mode", ok: false, why: root._errOf(res), want: mode });
                return;
            }
            lane.run(CW.modeArgv(root.bus), function (r2) {
                const m = CW.readMode(root._reply(r2));
                if (m.ok)
                    root._set("_mode", m.mode);
                const ok = m.ok && m.mode === mode;
                root.wrote({ kind: "mode", ok: ok, why: ok ? "" : "cardwire reads back mode " + (m.ok ? m.mode : "?") + ", not " + mode, want: mode, got: m.ok ? m.mode : -1 });
            }, true);
        }, true);
    }

    // `key` is silicon's name for the property (batteryAutoSwitch, batteryAutoSwitchMode,
    // externalDisplayAutoSwitch, nvidiaBlock); a boolean for the first, third and fourth, a Mode
    // number for the second.
    function setConfig(key, value) {
        const argv = CW.setConfigArgv(root.bus, key, value);
        if (argv === null) {
            root.wrote({ kind: "config", ok: false, why: "That setting is not available", key: key, want: value });
            return;
        }
        lane.run(argv, function (res) {
            if (res.code !== 0) {
                root.wrote({ kind: "config", ok: false, why: root._errOf(res), key: key, want: value });
                return;
            }
            lane.run(CW.configArgv(root.bus, CW.CONFIG_KEYS[key]), function (r2) {
                const c = CW.readConfig(CW.CONFIG_KEYS[key], root._reply(r2));
                if (c.ok)
                    root._setConfigKey(key, c.value);
                const ok = c.ok && c.value === value;
                root.wrote({ kind: "config", ok: ok, why: ok ? "" : "cardwire reads back " + (c.ok ? c.value : "nothing") + " for " + key, key: key, want: value });
            }, true);
        }, true);
    }

    // `allowed` true = Allowed (policy 1), false = Blocked (0).
    function setPolicy(app, allowed) {
        const argv = CW.setPolicyArgv(root.bus, app, allowed);
        if (argv === null) {
            root.wrote({ kind: "policy", ok: false, why: "That is not an app", app: app });
            return;
        }
        lane.run(argv, function (res) {
            if (res.code !== 0) {
                root.wrote({ kind: "policy", ok: false, why: root._errOf(res), app: app, want: allowed });
                return;
            }
            lane.run(CW.policiesArgv(root.bus), function (r2) {
                const p = CW.readAppPolicies(root._reply(r2));
                if (p.ok)
                    root._setPolicies(p.apps);
                let got = null;
                if (p.ok) {
                    for (let i = 0; i < p.apps.length; i++) {
                        if (p.apps[i].id === app)
                            got = p.apps[i].policy;
                    }
                }
                const ok = got === (allowed ? 1 : 0);
                root.wrote({ kind: "policy", ok: ok, why: ok ? "" : "cardwire did not keep the policy", app: app, want: allowed });
            }, true);
        }, true);
    }

    // ---- Private -----------------------------------------------------------
    property bool _started: false
    property int _gen: 0
    property bool _present: false
    property bool _settled: false
    property int _fails: 0
    property int _backoffMs: 0
    property string _whyText: "cardwire has not been asked yet"
    property int _mode: -1
    property var _modes: []
    property var _config: ({ batteryAutoSwitch: false, batteryAutoSwitchMode: 0, externalDisplayAutoSwitch: false, nvidiaBlock: false })
    property int _gpu: -1
    property string _dState: ""
    property var _holders: []
    property var _blocked: []
    property var _allPolicies: []
    property var _policies: []
    property bool _notifyQueued: false
    property string _owner: ""
    property bool _ownerLost: false

    function _set(prop, v) {
        if (JSON.stringify(root[prop]) === JSON.stringify(v))
            return;
        root[prop] = v;
        root._notify();
    }

    function _notify() {
        if (root._notifyQueued)
            return;
        root._notifyQueued = true;
        Qt.callLater(function () {
            root._notifyQueued = false;
            root.changed();
        });
    }

    function _setConfigKey(key, v) {
        if (root._config[key] === v)
            return;
        const c = Object.assign({}, root._config);
        c[key] = v;
        root._config = c;
        root._notify();
    }

    function _setPolicies(apps) {
        root._set("_allPolicies", apps);
        root._set("_policies", CW.filterPolicies(apps, root._blocked));
    }

    function _setBlocked(ids) {
        const u = Array.from(new Set(ids)).sort();
        root._set("_blocked", u);
        root._set("_policies", CW.filterPolicies(root._allPolicies, u));
    }

    function _reply(res) {
        if (res.timedOut || res.code !== 0)
            return { ok: false, why: root._errOf(res) };
        return CW.parseReply(res.out);
    }

    function _errOf(res) {
        if (res.timedOut)
            return "cardwire did not answer";
        return CW.errorText(res.err, res.code);
    }

    // `settleNow`: nothing is going to change it (switched off): settled at once and no retry.
    function _absent(why, settleNow) {
        root._gen++;
        root._set("_present", false);
        root._set("_whyText", why);
        root._fails++;
        if (settleNow === true || root._fails >= root.failsToSettle)
            root._set("_settled", true);
        if (root.active && settleNow !== true) {
            const wait = root._backoffMs > 0 ? root._backoffMs : root.firstRetryMs;
            retry.interval = Math.min(root.retryMs, wait);
            root._backoffMs = Math.min(root.retryMs, wait * 2);
            retry.restart();
        }
    }

    ProcLane { id: lane; timeoutMs: root.timeoutMs }

    Timer {
        id: retry
        interval: root.firstRetryMs
        onTriggered: root.refresh()
    }

    // A sequence of reads, in order; a stale generation (a newer refresh, or cardwire lost)
    // stops it where it stands.
    function _runSteps(steps, gen) {
        let i = 0;
        const next = function () {
            if (gen !== root._gen || i >= steps.length)
                return;
            const s = steps[i++];
            const argv = s.argv();
            if (argv === null) {
                next();
                return;
            }
            lane.run(argv, function (res) {
                if (gen !== root._gen)
                    return;
                if (s.done(res) === false)
                    return;
                next();
            });
        };
        next();
    }

    // The mode read decides presence: a daemon that does not answer it is not there.
    function _stepMode() {
        return {
            argv: function () { return CW.modeArgv(root.bus); },
            done: function (res) {
                const m = CW.readMode(root._reply(res));
                if (!m.ok) {
                    root._absent(m.why !== undefined ? m.why : "cardwire did not answer");
                    return false;
                }
                retry.stop();
                root._fails = 0;
                root._backoffMs = 0;
                root._set("_settled", true);
                root._set("_present", true);
                root._set("_whyText", "");
                root._set("_mode", m.mode);
            }
        };
    }

    // The last `Lsof` as the daemon answered, so a change of the list (the file is read hot) re-derives who counts without asking again.
    property var _lsofDevices: null
    onIgnoredHoldersChanged: {
        if (root._lsofDevices !== null)
            root._set("_holders", CW.lsofHolders(root._lsofDevices, root.nodes, root.ignoredHolders));
    }

    function _stepLsof() {
        return {
            argv: function () { return root._gpu >= 0 ? CW.lsofArgv(root.bus, root._gpu) : null; },
            done: function (res) {
                const l = CW.readLsof(root._reply(res), root.nodes, root.ignoredHolders);
                if (l.ok) {
                    root._lsofDevices = l.devices;
                    root._set("_holders", l.holders);
                }
            }
        };
    }

    function _stepPower() {
        return {
            argv: function () { return root._gpu >= 0 ? CW.powerArgv(root.bus, root._gpu) : null; },
            done: function (res) {
                const p = CW.readPowerState(root._reply(res));
                if (p.ok)
                    root._setDState(p.state);
            }
        };
    }

    function _setDState(state) {
        if (root._dState === state)
            return;
        root._dState = state;
        root._notify();
        root.powerChanged(state);
    }

    function _full() {
        root._gen++;
        const gen = root._gen;
        const devs = [null, null];
        const steps = [
            root._stepMode(),
            {
                argv: function () { return CW.availableModesArgv(root.bus); },
                done: function (res) {
                    const a = CW.readAvailableModes(root._reply(res));
                    if (a.ok)
                        root._set("_modes", a.modes);
                }
            }
        ];
        ["batteryAutoSwitch", "batteryAutoSwitchMode", "externalDisplayAutoSwitch", "nvidiaBlock"].forEach(function (key) {
            steps.push({
                argv: function () { return CW.configArgv(root.bus, CW.CONFIG_KEYS[key]); },
                done: function (res) {
                    const c = CW.readConfig(CW.CONFIG_KEYS[key], root._reply(res));
                    if (c.ok)
                        root._setConfigKey(key, c.value);
                }
            });
        });
        [0, 1].forEach(function (i) {
            steps.push({
                argv: function () { return CW.deviceArgv(root.bus, i); },
                done: function (res) { devs[i] = CW.readGetDevice(root._reply(res)); }
            });
        });
        steps.push({
            argv: function () {
                // The Gpu object of the NVIDIA card: its PCI address from the helper, else the
                // one the daemon calls discrete.
                let at = -1;
                for (let i = 0; i < 2; i++) {
                    if (devs[i] && devs[i].ok && root.pci !== "" && devs[i].pci.toLowerCase() === root.pci.toLowerCase())
                        at = i;
                }
                if (at < 0) {
                    for (let j = 0; j < 2; j++) {
                        if (at < 0 && devs[j] && devs[j].ok && devs[j].isDiscrete)
                            at = j;
                    }
                }
                root._set("_gpu", at);
                return null;
            },
            done: function () {}
        });
        steps.push({
            argv: function () { return CW.policiesArgv(root.bus); },
            done: function (res) {
                const p = CW.readAppPolicies(root._reply(res));
                if (p.ok)
                    root._setPolicies(p.apps);
            }
        });
        steps.push({
            argv: function () { return CW.blockedLogArgv(root.bus); },
            done: function (res) {
                const b = CW.readBlockedLog(root._reply(res));
                if (!b.ok)
                    return;
                const ids = root._blocked.slice();
                b.log.forEach(function (e) {
                    if (root._gpu < 0 || e.gpuId === root._gpu)
                        ids.push(CW.blockedId(e));
                });
                root._setBlocked(ids);
            }
        });
        steps.push(root._stepPower());
        steps.push(root._stepLsof());
        root._runSteps(steps, gen);
    }

    // ---- the monitor ------------------------------------------------------------
    property Process _mon: Process {
        running: false
        stdout: SplitParser {
            onRead: data => root._feed(data)
        }
        stderr: SplitParser {
            onRead: data => root._monError = data
        }
    }
    property Connections _monExit: Connections {
        target: root._mon
        function onExited(code) {
            root._monExited(code);
        }
    }
    property string _monError: ""
    property int _monRetryMs: 1000
    property int _monFailStreak: 0
    property double _monStartedAt: 0
    property bool _monStopping: false
    property Timer _monRetry: Timer {
        onTriggered: root._startMonitor()
    }

    function _startMonitor() {
        if (!root.active || root._mon.running || root._monRetry.running)
            return;
        root._monError = "";
        root._monStartedAt = Date.now();
        root._mon.command = CW.monitorArgv(root.bus);
        root._mon.running = true;
    }

    function _monExited(code) {
        if (root._monStopping) {
            root._monStopping = false;
            return;
        }
        if (!root.active)
            return;
        // A monitor that ran for a minute was working: this is a new streak.
        if (Date.now() - root._monStartedAt >= 60000) {
            root._monRetryMs = 1000;
            root._monFailStreak = 0;
        }
        if (root._monFailStreak++ === 0)
            console.warn("CardwireClient: the signal monitor exited (" + code + ")"
                         + (root._monError !== "" ? ": " + root._monError : "")
                         + "; restarting it, backing off to 60 s while it fails");
        root._monRetry.interval = root._monRetryMs;
        root._monRetryMs = Math.min(60000, root._monRetryMs * 2);
        root._monRetry.start();
    }

    // Quickshell 0.3.1's SplitParser can hand over two lines in one slice (an empty line after
    // another in the SAME read is not emitted and the next slice starts with its newline), so
    // every slice is split again.
    function _feed(text) {
        const lines = String(text).split("\n");
        for (let i = 0; i < lines.length; i++) {
            if (lines[i].trim() !== "")
                root._event(CW.monitorEvent(lines[i]));
        }
    }

    function _event(ev) {
        if (ev.kind === "owner") {
            const back = root._ownerLost;
            root._owner = ev.owner;
            root._ownerLost = false;
            if (back)
                root.refresh();
        } else if (ev.kind === "ownerLost") {
            root._ownerLost = true;
            root._owner = "";
            root._absent("cardwire is not running");
        } else if (ev.kind === "gpuPower") {
            if (ev.gpu === root._gpu)
                root._setDState(ev.state);
        } else if (ev.kind === "mode") {
            if (ev.mode !== null)
                root._set("_mode", ev.mode);
            else
                root._runSteps([{
                    argv: function () { return CW.modeArgv(root.bus); },
                    done: function (res) {
                        const m = CW.readMode(root._reply(res));
                        if (m.ok)
                            root._set("_mode", m.mode);
                    }
                }], root._gen);
        } else if (ev.kind === "config") {
            const props = Object.keys(CW.CONFIG_KEYS);
            props.forEach(function (key) {
                const prop = CW.CONFIG_KEYS[key];
                if (ev.changes[prop] !== undefined && typeof ev.changes[prop] === (CW.CONFIG_TYPES[prop] === "b" ? "boolean" : "number"))
                    root._setConfigKey(key, ev.changes[prop]);
                else if (ev.invalidated.indexOf(prop) >= 0)
                    root._runSteps([{
                        argv: function () { return CW.configArgv(root.bus, prop); },
                        done: function (res) {
                            const c = CW.readConfig(prop, root._reply(res));
                            if (c.ok)
                                root._setConfigKey(key, c.value);
                        }
                    }], root._gen);
            });
        } else if (ev.kind === "processBlocked") {
            const e = ev.log;
            if (root._gpu >= 0 && e.gpuId !== root._gpu)
                return;
            root._setBlocked(root._blocked.concat([CW.blockedId(e)]));
            root.appBlocked({ id: CW.blockedId(e), comm: e.comm, appId: e.appId, pid: e.pid, gpuId: e.gpuId,
                              atMs: e.secs * 1000 + Math.floor(e.nanos / 1e6) });
        } else if (ev.kind === "newApp") {
            root._runSteps([{
                argv: function () { return CW.policiesArgv(root.bus); },
                done: function (res) {
                    const p = CW.readAppPolicies(root._reply(res));
                    if (p.ok)
                        root._setPolicies(p.apps);
                }
            }], root._gen);
        }
    }
}
