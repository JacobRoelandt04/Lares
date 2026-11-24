pragma ComponentBehavior: Bound

import QtQuick
import "HelperProto.js" as Proto
import "../../common/system"

// =============================================================================
// HelperClient.qml -- silicon's one conversation with the root helper
// (docs/contracts/silicon_helper_protocol.md, v1).
//
//   READS   `silicon-helper status`, unprivileged, run directly: the machine's knobs, lists,
//           limits and the paths the shell's own readers use. `refreshStatus()`; the answer is
//           `status` (HelperProto.normaliseStatus) and `statusRead(status, false)`.
//   WRITES  `pkexec silicon-helper apply|set-charge-limit|set-boot|mux-...`: one Process at a time (a
//           ProcLane), a 10 s watchdog, the helper's own read-back checked against what was
//           asked. A write's answer carries a fresh `status`, which is taken at once
//           (`statusRead(status, true)`: it is not an external change).
//
//   queueApply(patch)      merge a CPU patch into the pending one (the latest value per knob
//                          wins) and (re)start the settle; the write goes out `settleMs` (300) after
//                          the LAST such call
//   replaceApply(patch)    the same, but the pending patch is dropped first: a profile switch
//                          ends whatever tuning was waiting
//   queueChargeLimit(pct)  80 | 100, same settle, latest wins
//   queueMux(op, want)     op: "request" (want "dgpu" | "hybrid") | "cancel" | "promptShown" |
//                          "confirm" -- no settle, in order
//   queueKick(from, via)   RE-KICK the firmware's fan logic: write the platform profile `via`, wait `kickGapMs`, write `from` back --
//                          two plain `apply profile=` writes (the polkit rule already allows them), never a manual change: the
//                          intermediate answer is NOT published (the popup never shows `via`), a status started meanwhile is thrown
//                          away, and `pending` holds until the profile is back. The result is `wrote({ kind: "kick", step: "via" |
//                          "back", ... })`; a failed `via` writes nothing more, a failed `back` is the host's to put right
//   queueBoot(patch)       `set-boot`: store a CPU patch as the boot set silicon-boot.service applies early in
//                          every boot (nothing is written to the machine now) -- no settle; `bootPending` until
//                          its answer
//   wrote({ kind, zone, patch, ok, why, results, refusals, status, exit, timedOut })
//                          every write ends in exactly one of these; ok means the helper said
//                          ok for every knob AND the read-back is what was asked
//
// The command lines are configuration: `statusCommand` is the bare binary (+ test-mode flags in a
// probe), `writeCommand` is `["pkexec", binary]` (+ the same flags). A probe puts a stub `pkexec`
// first on PATH that execs its arguments unprivileged. NOTHING else ever reaches the helper: no
// stdin, no environment, no config of the user's.
//
// A binary that is not there is found out ONCE with `test -x` and then every 60 s, never by
// starting it: Quickshell warns on a failed start and never reports an exit. `installed` is
// false until a status has come back.
// =============================================================================
Item {
    id: root

    property var statusCommand: ["/usr/local/libexec/silicon-helper"]
    property var writeCommand: ["pkexec", "/usr/local/libexec/silicon-helper"]
    property int settleMs: 300
    property int timeoutMs: 10000
    property int kickGapMs: 1500            // between the two writes of a kick: the firmware's fan logic latches the first before the second

    readonly property bool installed: root._installed
    readonly property bool ok: root._ok
    // The helper has been ASKED and has answered once, well or ill: `ok` false before that is "not yet", not "no".
    readonly property bool answered: root._answered
    readonly property string why: root._why
    readonly property var status: root._status
    // What waits to be sent, per zone: the merged CPU patch and the charge limit. The service validates a
    // tuning against the first, and settles a zone's target only when nothing NEWER of that zone waits.
    readonly property bool applyPending: root._applyPending !== null
    readonly property var applyPatch: root._applyPending || ({})
    readonly property bool limitPending: root._limitPending !== null
    // A set-boot is queued or on its way (the boot profile waits for its answer before it asks again).
    readonly property bool bootPending: root._bootJobs > 0
    // From the first intent to the end of its write: external-change detection pauses meanwhile.
    readonly property bool pending: writeLane.busy || writeLane.queued > 0 || root.applyPending || root.limitPending
                                    || root._immediate.length > 0 || root._kickBack !== null
    // A status poll is worth asking again at this distance when the helper is not there.
    readonly property int missingRetryMs: 60000

    signal statusRead(var status, bool fromWrite)
    signal statusFailed(string why)
    signal wrote(var result)

    function refreshStatus() {
        if (root._statusBusy)
            return;
        if (root._missingUntil > Date.now())
            return;
        root._statusBusy = true;
        if (root._known)
            root._runStatus();
        else
            root._probeBinary();
    }

    function queueApply(patch) {
        root._applyPending = Object.assign({}, root._applyPending || {}, patch);
        applySettle.restart();
    }

    function replaceApply(patch) {
        root._applyPending = Object.assign({}, patch);
        applySettle.restart();
    }

    function dropApply() {
        root._applyPending = null;
        applySettle.stop();
    }

    function queueChargeLimit(pct) {
        root._limitPending = pct;
        limitSettle.restart();
    }

    function queueMux(op, want) {
        const prefix = root.writeCommand;
        let argv = null;
        if (op === "request")
            argv = Proto.muxRequestArgv(prefix, want);
        else if (op === "cancel")
            argv = Proto.muxCancelArgv(prefix);
        else if (op === "promptShown")
            argv = Proto.muxPromptShownArgv(prefix);
        else if (op === "confirm")
            argv = Proto.muxConfirmArgv(prefix);
        if (argv === null)
            return false;
        root._immediate = root._immediate.concat([{ kind: "mux", zone: "mux", op: op, want: want || "", argv: argv }]);
        Qt.callLater(root._pump);
        return true;
    }

    function queueKick(from, via) {
        if (root._kickBack !== null || from === via || typeof from !== "string" || typeof via !== "string" || from === "" || via === "")
            return false;
        root._kickBack = from;
        root._kickEpoch++;
        root._immediate = root._immediate.concat([{ kind: "kick", step: "via", zone: "cpu", patch: { profile: via }, argv: Proto.applyArgv(root.writeCommand, { profile: via }) }]);
        Qt.callLater(root._pump);
        return true;
    }

    function queueBoot(patch) {
        root._bootJobs++;
        root._immediate = root._immediate.concat([{ kind: "boot", zone: "boot", patch: Object.assign({}, patch), argv: Proto.setBootArgv(root.writeCommand, patch) }]);
        Qt.callLater(root._pump);
        return true;
    }

    // ---- Private ---------------------------------------------------------------
    property int _bootJobs: 0
    property bool _installed: false
    property bool _ok: false
    property bool _answered: false
    property string _why: "the silicon helper has not been asked yet"
    property var _status: null
    property bool _known: false
    property bool _statusBusy: false
    property real _missingUntil: 0
    property var _applyPending: null
    property var _limitPending: null
    property var _immediate: []
    property var _kickBack: null            // the profile a kick is to put back (null: no kick is on its way)
    property int _kickEpoch: 0              // moves when a kick starts and when it ends: a status started before either is stale

    ProcLane { id: statusLane; timeoutMs: root.timeoutMs }
    ProcLane { id: writeLane; timeoutMs: root.timeoutMs }

    Timer { id: applySettle; interval: root.settleMs; onTriggered: root._pump() }
    Timer { id: limitSettle; interval: root.settleMs; onTriggered: root._pump() }
    Timer {
        id: kickGap
        interval: root.kickGapMs
        onTriggered: {
            const from = root._kickBack;
            root._immediate = root._immediate.concat([{ kind: "kick", step: "back", zone: "cpu", patch: { profile: from }, argv: Proto.applyArgv(root.writeCommand, { profile: from }) }]);
            root._pump();
        }
    }

    function _fail(why, missing) {
        root._answered = true;
        root._ok = false;
        root._why = why;
        root._statusBusy = false;
        if (missing) {
            root._installed = false;
            root._known = false;
            root._missingUntil = Date.now() + root.missingRetryMs;
        }
        root.statusFailed(why);
    }

    function _probeBinary() {
        const bin = root.statusCommand[0];
        statusLane.run(["test", "-x", bin], function (res) {
            if (res.code === 0) {
                root._known = true;
                root._runStatus();
            } else {
                root._fail("The silicon helper is not installed (" + bin + ")", true);
            }
        });
    }

    // How many status runs this client started (the service's probe proves the quiet case with it: an open popup
    // with nothing changing asks for none). An instrument nothing binds to.
    property int statusRuns: 0
    function _runStatus() {
        root.statusRuns++;
        const epoch = root._kickEpoch;
        statusLane.run(Proto.statusArgv(root.statusCommand), function (res) {
            root._statusBusy = false;
            // a kick began or ended while this ran: it may have read the profile in between
            if (epoch !== root._kickEpoch)
                return;
            if (res.timedOut) {
                root._fail("The silicon helper did not answer", true);
                return;
            }
            const p = Proto.parseStatus(res.out);
            if (!p.ok) {
                root._fail(res.code === 0 || res.out.trim() !== "" ? p.why : Proto.describeExit(res.code, res.err), res.code === 127);
                return;
            }
            // A write is waiting or running: its own answer carries a newer status, and this
            // one would show the old values between the intent and the write.
            if (root.pending)
                return;
            root._installed = true;
            root._answered = true;
            root._ok = true;
            root._why = "";
            root._status = p.status;
            root.statusRead(p.status, false);
        });
    }

    function _pump() {
        if (writeLane.busy)
            return;
        if (root._immediate.length > 0) {
            const j = root._immediate[0];
            root._immediate = root._immediate.slice(1);
            root._start(j);
            return;
        }
        // (a kick's two writes are one change of the firmware's fan logic: a user's apply waits for the profile to be back, and then wins)
        if (root._applyPending !== null && !applySettle.running && root._kickBack === null) {
            const patch = root._applyPending;
            root._applyPending = null;
            root._start({ kind: "apply", zone: "cpu", patch: patch, argv: Proto.applyArgv(root.writeCommand, patch) });
            return;
        }
        if (root._limitPending !== null && !limitSettle.running) {
            const pct = root._limitPending;
            root._limitPending = null;
            root._start({ kind: "chargeLimit", zone: "battery", patch: { chargeLimit: pct }, argv: Proto.chargeLimitArgv(root.writeCommand, pct) });
        }
    }

    function _start(job) {
        writeLane.run(job.argv, function (res) { root._written(job, res); });
    }

    function _written(job, res) {
        if (job.kind === "boot")
            root._bootJobs--;
        const parsed = Proto.parseWrite(res.out, res.code, res.err);
        let ok = parsed.ok;
        let why = parsed.why;
        let bad = Proto.refusals(parsed.results);
        if (res.timedOut) {
            ok = false;
            why = "The helper did not answer in " + (root.timeoutMs / 1000) + " s";
        } else if (ok && job.kind !== "mux") {
            const mm = Proto.mismatches(job.patch, parsed.results);
            if (mm.length > 0) {
                ok = false;
                bad = mm.map(function (m) { return { knob: m.knob, want: m.want, got: m.got, code: "mismatch", why: m.why }; });
                why = Proto.refusalText(bad);
            }
        }
        const via = job.kind === "kick" && job.step === "via";
        if (parsed.status && !via) {
            root._status = parsed.status;
            root._installed = true;
            root._answered = true;
            root._ok = true;
            root._why = "";
        } else if (!parsed.status && res.code === 127) {
            root._installed = false;
            root._known = false;
        }
        const result = {
            kind: job.kind, zone: job.zone, patch: job.patch || {}, op: job.op || "", want: job.want || "",
            ok: ok, why: why, results: parsed.results, refusals: bad, status: parsed.status,
            exit: res.code, timedOut: res.timedOut
        };
        result.step = job.step || "";
        if (job.kind === "kick") {
            if (via && ok) {
                kickGap.restart();                  // the way back is queued when the gap ends (`pending` holds meanwhile)
            } else {
                root._kickBack = null;
                root._kickEpoch++;
            }
        }
        if (parsed.status && !via)
            root.statusRead(parsed.status, true);
        root.wrote(result);
        Qt.callLater(root._pump);
    }
}
