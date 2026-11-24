pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io

import "../../../common/components"
import "../../../common/components/JsonComments.js" as JsonComments
import "../../../common/config/ConfigCheck.js" as Check
import "../../../common/config/ConfigSpecs.js" as Specs
import "../../../common/system"
import "SnapshotRules.js" as Rules
import "SnapshotWords.js" as Words
import "SnapshotFixtures.js" as Fixtures

// =============================================================================
// SnapshotService.qml -- the system snapshots, the shell's part (docs/contracts/snapshots.md section 11; page docs/snapshots.md).
// ONE per shell. It holds no rule of its own but SnapshotRules.js: everything that knows a snapshot is the root tool's
// (`lares-snapshot-root`: restic, the records, the retention) and the user's (`tools/snapshot/lares-snapshot undo-plan`), and this
// only asks them and keeps what they answered.
//
//   live            false (the default) = a MOCK: it starts no process, serves SnapshotFixtures.js and answers every verb in memory
//   ready           the tool is installed and has a repository (the popup shows the page and the notch only then)
//   phase           "unknown" | "missing" (no root tool there: quiet, re-checked rarely) | "norepo" | "ready"
//   status          the root tool's `status` object ({} until read);  rows  newest first, section 11's row
//   model           a ListModel of { short } kept by identity through every refresh: a delegate reads its row with rowOf(short, rowsSerial)
//   busy / busyKind an action of ours is out, or the tool says one is ("create" | "keep" | "delete" | "tidy" | "")
//   createProgress  0..1 while a `create` runs (the tool's progress lines), -1 unknown
//   lastError       the last failure's words, cleared by the next action
//   undoPlans       { <short>: { state: "loading" | "ok" | "failed", plan, text } }, kept HERE: the page is destroyed on close
//   offsite         offsite.json as read; offsiteEnabled from config/snapshots.jsonc; onBattery (the host binds it): the charger going in
//                   starts a copy that waits for it, and the page says what it waits for NOW
//
//   wantsFor(names)   the rule's answer { want, count, critical[] }
//   refresh()         read again (coalesced; on start, on a popup open, after a run, after every verb, on /.lares-snapshots/state.json)
//   look()            the page was opened: a copy that waits or failed is asked again
//   create() keep(short, on) remove(short) planUndo(short)       verbs; failed(text) says why one did not happen
//   runActive         an update run is on (the host binds it): no create, no off-site copy; a run's end re-reads and arms the copy
//
// pkexec is asked only after pkcheck says the action can be had (exit 0 yes, 2 a challenge the shell's own agent answers): a missing
// rule then never opens a dialog.
// =============================================================================
Item {
    id: root

    property bool live: false
    property bool runActive: false

    property string rootTool: "/usr/local/lib/lares/snapshot/lares-snapshot-root"
    property string userTool: RepoRoot.dir + "/tools/snapshot/lares-snapshot"
    property string offsiteTool: RepoRoot.dir + "/tools/snapshot/lares-offsite"
    property string python: "python3"
    property string pkexec: "pkexec"
    property string pkcheck: "pkcheck"
    property string systemdRun: "systemd-run"
    property string testBin: "test"
    property string statePath: "/.lares-snapshots/state.json"
    property string offsitePath: ""      // $XDG_STATE_HOME/lares/snapshots/offsite.json
    property string configPath: ""       // .../config/snapshots.jsonc
    property int missingRecheckMs: 600000
    property int offsiteAfterRunMs: 120000
    property int offsiteCheckMs: 300000
    property int offsitePlugMs: 5000
    // the machine runs on its battery (the host binds it): a copy that waits for the charger starts when it goes in
    property bool onBattery: false

    readonly property bool ready: root._state === "ready"
    readonly property string phase: root._state
    readonly property var status: root._status
    readonly property var rows: root._rows
    readonly property alias model: rowModel
    readonly property int rowsSerial: root._rowsSerial
    readonly property bool busy: root._acting > 0 || root._status.busy === "create" || root._status.busy === "delete" || root._status.busy === "tidy"
    readonly property string busyKind: root._acting > 0 ? root._actKind : (root._status.busy ? String(root._status.busy) : "")
    readonly property real createProgress: root._createProgress
    readonly property string lastError: root._lastError
    readonly property var undoPlans: root._plans
    readonly property var offsite: root._offsite
    readonly property bool offsiteEnabled: root._offsiteEnabled
    readonly property var settings: root._status.settings ? root._status.settings : ({})
    readonly property var calls: root._calls
    readonly property int refreshCount: root._refreshes
    readonly property real repoBytes: root._status.repoBytes ? Number(root._status.repoBytes) : 0

    signal failed(string text)

    // ---- the mock's memory -------------------------------------------------------------------------------
    property var mockRecords: Fixtures.records(Date.now())
    property string mockState: "ready"        // "ready" | "missing" | "norepo"
    property var mockOffsite: ({ state: "idle", reason: "", lastOk: Math.floor(Date.now() / 1000) - 86400, pending: { files: 0, bytes: 0 }, done: { files: 0, bytes: 0 }, snapshots: ["6a493314", "b01c7e22"], pid: 0 })
    property bool mockOffsiteEnabled: true
    property int mockCreateMs: 2400
    property int mockPlanMs: 300
    property int mockBusyEnds: 0

    property string _state: "unknown"
    property var _status: ({})
    property var _rows: []
    property var _records: []
    property int _rowsSerial: 0
    property var _plans: ({})
    property var _offsite: ({ state: "off" })
    property bool _offsiteEnabled: false
    property real _offsiteEveryMs: 86400000
    property bool _offsiteAfterUpdate: true
    property var _calls: []
    property int _refreshes: 0
    property int _acting: 0
    property string _actKind: ""
    property real _createProgress: -1
    property string _lastError: ""
    property bool _refreshing: false
    property bool _again: false
    property real _lastToolCheck: 0
    property real _runEndedMs: 0
    property string _shortAtRunStart: ""
    property bool _runStartKnown: false
    property bool _newSinceRun: false
    property real _lastTriggerMs: 0
    property real _now: Date.now()

    function _record(what: string): void {
        const c = root._calls.slice();
        c.push(what);
        root._calls = c.length > 300 ? c.slice(c.length - 300) : c;
    }

    // ---- the rule ------------------------------------------------------------------------------------------
    function wantsFor(names: var): var {
        const n = [];
        for (let i = 0; i < names.length; i++)
            n.push(String(names[i]));
        if (!root.ready)
            return { want: false, count: n.length, critical: [] };
        return Rules.wants(n, root.settings);
    }
    function rowOf(short: string, serial: int): var {
        for (let i = 0; i < root._rows.length; i++)
            if (root._rows[i].short === short)
                return root._rows[i];
        return null;
    }

    // ---- reading -------------------------------------------------------------------------------------------
    Component.onCompleted: {
        root._readOffsiteEnabled(null);
        root.refresh();
    }
    onRunActiveChanged: {
        if (root.runActive) {
            root._shortAtRunStart = root._rows.length > 0 ? root._rows[0].short : "";
            root._runStartKnown = true;
            root._newSinceRun = false;
            root._runEndedMs = 0;
        } else {
            // the run's end: what it did to the packages changes every undo plan; the records may have a new snapshot
            root._plans = ({});
            root._runEndedMs = Date.now();
            root._record("runEnded");
            root.refresh();
        }
    }
    function refresh(): void {
        root._record("refresh");
        root._refreshes++;
        if (!root.live) {
            root._mockRead();
            return;
        }
        if (root._refreshing) {
            root._again = true;
            return;
        }
        // a tool that is missing is looked for rarely, not on every popup open
        if (root._state === "missing" && Date.now() - root._lastToolCheck < 60000)
            return;
        root._refreshing = true;
        root._lastToolCheck = Date.now();
        root._job([root.testBin, "-x", root.rootTool], null, (code, lines) => {
            if (code !== 0) {
                root._finishRead("missing", {}, null);
                return;
            }
            root._job([root.rootTool, "status"], null, (c1, l1) => {
                const st = root._json(l1);
                if (c1 !== 0 || !st) {
                    root._finishRead("unknown", {}, null);
                    return;
                }
                if (st.installed !== true || st.repo !== true) {
                    root._finishRead("norepo", st, []);
                    return;
                }
                root._job([root.rootTool, "list"], null, (c2, l2) => {
                    const ls = root._json(l2);
                    root._finishRead("ready", st, ls && ls.records ? ls.records : []);
                });
            });
        });
    }
    function _finishRead(state: string, st: var, records: var): void {
        root._status = st;
        if (records !== null)
            root._publish(records);
        else if (state === "missing")
            root._publish([]);
        root._state = state;
        root._refreshing = false;
        root._noteNewSnapshot();
        if (root._again) {
            root._again = false;
            root.refresh();
        }
    }
    function _publish(records: var): void {
        root._records = records;
        const offs = root._offsite && root._offsite.snapshots ? root._offsite.snapshots : [];
        const rows = Words.rowsFromList(records, { offsite: offs, runActive: root.runActive, nowMs: Date.now() });
        root._rows = rows;
        root._syncModel(rows);
        root._rowsSerial++;
    }
    // The model keeps one entry per snapshot for as long as it exists: a refresh inserts, removes and moves, and never rebuilds a row.
    function _syncModel(rows: var): void {
        const want = rows.map(r => r.short);
        for (let i = rowModel.count - 1; i >= 0; i--)
            if (want.indexOf(rowModel.get(i).short) < 0)
                rowModel.remove(i);
        for (let i = 0; i < want.length; i++) {
            if (i < rowModel.count && rowModel.get(i).short === want[i])
                continue;
            let at = -1;
            for (let j = i + 1; j < rowModel.count; j++)
                if (rowModel.get(j).short === want[i]) {
                    at = j;
                    break;
                }
            if (at >= 0)
                rowModel.move(at, i, 1);
            else
                rowModel.insert(i, { short: want[i] });
        }
    }
    ListModel {
        id: rowModel
    }
    function _json(lines: var): var {
        const t = lines.join("\n").trim();
        try {
            return JSON.parse(t);
        } catch (e) {
            for (let i = lines.length - 1; i >= 0; i--) {
                try {
                    const d = JSON.parse(lines[i]);
                    if (d && typeof d === "object")
                        return d;
                } catch (e2) {
                }
            }
        }
        return null;
    }
    // a new newest snapshot while/after a run: the copy off site follows it
    function _noteNewSnapshot(): void {
        const top = root._rows.length > 0 ? root._rows[0].short : "";
        if (root._runStartKnown && root._runEndedMs > 0 && top !== "" && top !== root._shortAtRunStart && !root._newSinceRun) {
            root._newSinceRun = true;
            offsiteTimer.restart();
        }
    }

    // The root tool's state file changes with every snapshot, keep and delete (also one made in a terminal): read again.
    FileView {
        id: stateWatch
        path: root.live ? root.statePath : ""
        watchChanges: path.length > 0
        printErrors: false
        onFileChanged: root.refresh()
    }
    Timer {
        interval: root.missingRecheckMs
        running: root.live && root._state === "missing"
        repeat: true
        onTriggered: root.refresh()
    }

    // ---- the verbs -------------------------------------------------------------------------------------------
    function _refuse(text: string): void {
        root._lastError = text;
        root._record("failed " + text);
        root.failed(text);
    }
    function _begin(kind: string): bool {
        if (!root.ready) {
            root._refuse("Snapshots are not set up.");
            return false;
        }
        if (root.busy) {
            root._refuse("A snapshot job is already running.");
            return false;
        }
        root._lastError = "";
        root._acting++;
        root._actKind = kind;
        return true;
    }
    function _end(): void {
        root._acting = Math.max(0, root._acting - 1);
        root._createProgress = -1;
    }
    function create(): void {
        root._record("create");
        if (root.runActive) {
            root._refuse("An update is running; it takes its own snapshot.");
            return;
        }
        if (!root._begin("create"))
            return;
        root._createProgress = -1;
        if (!root.live) {
            mockCreate.start();
            return;
        }
        root._privileged("create", ["create"], "create", line => {
            const m = /^lares-snapshot: progress (\d+)/.exec(line);
            if (m)
                root._createProgress = Math.max(0, Math.min(1, Number(m[1]) / 100));
        }, ok => {
            root._end();
            root.refresh();
        });
    }
    function keep(short: string, on: bool): void {
        root._record("keep " + short + " " + (on ? "on" : "off"));
        if (!root._begin("keep"))
            return;
        if (!root.live) {
            root._mockSet(short, r => { r.keep = on; });
            root._end();
            return;
        }
        root._privileged("keep", ["keep", short, on ? "on" : "off"], "keep", null, ok => {
            root._end();
            root.refresh();
        });
    }
    function remove(short: string): void {
        root._record("remove " + short);
        if (!root._begin("delete"))
            return;
        if (!root.live) {
            root.mockRecords = root.mockRecords.filter(r => r.short !== short);
            root._mockRead();
            root._end();
            return;
        }
        root._privileged("delete", ["delete", short], "delete", null, ok => {
            root._end();
            root.refresh();
        });
    }
    // pkcheck first (0: allowed, 2: a challenge the shell's own polkit agent answers, anything else: refused), then pkexec of the root tool.
    function _privileged(action: string, args: var, verb: string, onLine: var, done: var): void {
        const id = "org.lares.snapshot." + action;
        root._job([root.pkcheck, "--action-id", id, "--process", String(root._pid)], null, (code, lines) => {
            if (code !== 0 && code !== 2) {
                root._refuse(code === 1 ? "Not allowed." : "The check for permission failed.");
                done(false);
                return;
            }
            root._job([root.pkexec, root.rootTool].concat(args), onLine, (c2, l2) => {
                const d = root._json(l2);
                const ok = c2 === 0 && (!d || d.ok !== false);
                if (!ok)
                    root._refuse(c2 === 126 || c2 === 127 ? "Not authorised." : (d && d.error ? String(d.error) : "The " + verb + " did not work."));
                done(ok);
            });
        });
    }
    readonly property int _pid: root.live ? Number(Quickshell.processId) : 0

    function planUndo(short: string): void {
        const have = root._plans[short];
        if (have && (have.state === "ok" || have.state === "loading"))
            return;
        root._record("plan " + short);
        root._setPlan(short, { state: "loading", plan: null, text: "" });
        if (!root.live) {
            mockPlan.short = short;
            mockPlan.restart();
            return;
        }
        root._job([root.python, root.userTool, "undo-plan", short, "--json"], null, (code, lines) => {
            const d = root._json(lines);
            // a plan that says no (nothing to put back, or a critical package is gone) is still an answer: the page words it
            if (code === 0 && d && Array.isArray(d.files))
                root._setPlan(short, { state: "ok", plan: d, text: "" });
            else
                root._setPlan(short, { state: "failed", plan: null, text: d && d.error ? String(d.error) : "This cannot be worked out now." });
        });
    }
    function _setPlan(short: string, entry: var): void {
        const p = Object.assign({}, root._plans);
        p[short] = entry;
        root._plans = p;
    }

    // ---- processes: one per ask, destroyed when it ends ----------------------------------------------------------
    // A program that is not there starts nothing and exits nothing (a Process law): every argv's first word is checked by the caller
    // (`test -x` for the root tool) or is a system binary; a failed start answers -1.
    function _job(argv: var, onLine: var, cb: var): void {
        // the ONE gate to the machine: a mock never starts anything
        if (!root.live) {
            root._record("refused " + argv.join(" "));
            return;
        }
        root._record("run " + argv.join(" "));
        const p = jobComp.createObject(root, { command: argv });
        p.lineIn.connect(line => { if (onLine) onLine(line); });
        p.finished.connect((code, lines) => {
            cb(code, lines);
            p.destroy();
        });
        p.running = true;
    }
    Component {
        id: jobComp
        Process {
            id: p
            signal lineIn(string line)
            signal finished(int code, var lines)
            property var got: []
            stdout: SplitParser {
                onRead: data => {
                    const parts = String(data).split("\n");
                    for (const s of parts) {
                        if (s.length === 0)
                            continue;
                        p.got.push(s);
                        p.lineIn(s);
                    }
                }
            }
            onExited: code => Qt.callLater(() => p.finished(code, p.got))
        }
    }

    // ---- off site --------------------------------------------------------------------------------------------
    // offsite.json: written by `lares-offsite`; one FileView on a static path.
    FileView {
        id: offsiteFile
        path: root.live ? root.offsitePath : ""
        watchChanges: path.length > 0
        printErrors: false
        onLoaded: root._readOffsiteFile(offsiteFile.text())
        onFileChanged: offsiteFile.reload()
        onLoadFailed: root._readOffsiteFile("")
    }
    function _readOffsiteFile(text: string): void {
        let d = null;
        try {
            d = JSON.parse(text);
        } catch (e) {
            d = null;
        }
        root._offsite = d && typeof d === "object" ? d : { state: "off" };
        // the marks "copied off site" are part of the rows
        if (root._records.length > 0)
            root._publish(root._records);
    }
    ConfigFile {
        id: configFile
        path: root.live && root.configPath.length > 0 ? root.configPath : ""
        watchChanges: path.length > 0
        onLoaded: root._readOffsiteEnabled(configFile.text())
        onLoadFailed: root._readOffsiteEnabled("")
    }
    function _readOffsiteEnabled(text: string): void {
        if (!root.live) {
            root._offsiteEnabled = root.mockOffsiteEnabled;
            root._offsite = root.mockOffsite;
            return;
        }
        let on = false;
        try {
            const d = JSON.parse(JsonComments.strip(text || ""));
            on = !!d && !!d.offsite && d.offsite.enabled === true;
            // the rest of the copy's own keys (the spec's: every one at its default when the file says nothing or something wrong)
            const o = Check.read(Specs.specOf("snapshots"), d && typeof d === "object" ? d : {}).settings.offsite;
            root._offsiteEveryMs = o.everyHours * 3600000;
            root._offsiteAfterUpdate = o.afterUpdate;
        } catch (e) {
            on = false;
        }
        root._offsiteEnabled = on;
    }
    onMockOffsiteChanged: if (!root.live) root._offsite = root.mockOffsite
    onMockOffsiteEnabledChanged: if (!root.live) root._offsiteEnabled = root.mockOffsiteEnabled

    // Two minutes after a run that made a snapshot, and at most once a day otherwise; never in a run, never while a job of ours is out.
    Timer {
        id: offsiteTimer
        interval: root.offsiteAfterRunMs
        onTriggered: root._offsiteCheck(false)
    }
    Timer {
        interval: root.offsiteCheckMs
        running: root._offsiteEnabled
        repeat: true
        onTriggered: root._offsiteCheck(false)
    }
    // turned on (or the shell has just read that it is): the first look comes in two minutes, not at the half-hour's tick
    on_OffsiteEnabledChanged: if (root._offsiteEnabled && root.live) offsiteTimer.restart()
    onOnBatteryChanged: if (!root.onBattery && root._offsiteEnabled && root.live) plugTimer.restart()
    Timer {
        id: plugTimer
        interval: root.offsitePlugMs
        onTriggered: root._offsiteCheck(false)
    }
    // the page was opened: what waits or failed is asked again (a sign-in or an open keyring gives no signal)
    function look(): void {
        root._offsiteCheck(true);
    }
    function _offsiteCheck(looked: bool): void {
        const why = Words.offsiteDue({ enabled: root._offsiteEnabled, live: root.live, runActive: root.runActive, busy: root.busy,
            offsiteState: root._offsite ? root._offsite.state : "", cause: root._offsite && root._offsite.cause ? root._offsite.cause : "",
            onBattery: root.onBattery, looked: looked === true, lastOkMs: (root._offsite && root._offsite.lastOk ? root._offsite.lastOk : 0) * 1000,
            lastTriggerMs: root._lastTriggerMs, nowMs: Date.now(), runEndedMs: root._runEndedMs, newSinceRun: root._newSinceRun,
            afterMs: root.offsiteAfterRunMs, everyMs: root._offsiteEveryMs, afterUpdate: root._offsiteAfterUpdate });
        if (why === "") {
            // a run that was still on when the two minutes ran out: ask again when it is over (the run's end restarts nothing by itself)
            if (root._newSinceRun && root.runActive)
                offsiteTimer.restart();
            return;
        }
        root.startOffsite(why);
    }
    // `systemd-run --user`: the copy outlives the shell and shows in `systemctl --user status lares-offsite`.
    function startOffsite(why: string): void {
        root._lastTriggerMs = Date.now();
        root._newSinceRun = false;
        root._record("offsite " + why);
        root._job([root.systemdRun, "--user", "--unit=lares-offsite", "--collect", "--nice=10", "--quiet", "--expand-environment=no",
                   // "it waits" (exit 3) is an answer, not a failed unit
                   "--property=SuccessExitStatus=3", root.offsiteTool, "sync"],
                  null, (code, lines) => root._record("offsite exit " + code));
    }

    // ---- the mock ----------------------------------------------------------------------------------------------
    function _mockRead(): void {
        root._readOffsiteEnabled(null);
        if (root.mockState !== "ready") {
            root._status = {};
            root._publish([]);
            root._state = root.mockState;
            return;
        }
        root._status = { version: 1, installed: true, repo: true, off: false, enabled: true, count: root.mockRecords.length,
            repoBytes: root.mockRecords.reduce((a, r) => a + r.added, 0), busy: "", settings: {}, problems: [] };
        root._publish(root.mockRecords);
        root._state = "ready";
    }
    function _mockSet(short: string, fn: var): void {
        root.mockRecords = root.mockRecords.map(r => {
            if (r.short !== short)
                return r;
            const c = Object.assign({}, r);
            fn(c);
            return c;
        });
        root._mockRead();
    }
    onMockRecordsChanged: if (!root.live && root._state !== "unknown") root._mockRead()
    onMockStateChanged: if (!root.live) root._mockRead()
    Timer {
        id: mockCreate
        interval: 100
        repeat: true
        property int step: 0
        onTriggered: {
            mockCreate.step++;
            root._createProgress = Math.min(1, mockCreate.step * mockCreate.interval / Math.max(1, root.mockCreateMs));
            if (root._createProgress >= 1) {
                mockCreate.stop();
                mockCreate.step = 0;
                const short = ("0123456789abcdef" + Math.random().toString(16).slice(2)).slice(-8);
                const rec = { version: 1, id: short + "0".repeat(56), short: short, time: Math.floor(Date.now() / 1000), reason: "manual", critical: [], changed: [],
                    count: 0, state: "done", keep: false, note: "", added: 0.4 * 1000000000 };
                root.mockRecords = [rec].concat(root.mockRecords);
                root._end();
            }
        }
    }
    Timer {
        id: mockPlan
        property string short: ""
        interval: root.mockPlanMs
        onTriggered: root._setPlan(mockPlan.short, { state: "ok", plan: Fixtures.plan(mockPlan.short, root._records.find(r => r.short === mockPlan.short)), text: "" })
    }
}
