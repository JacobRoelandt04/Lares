pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import "../../common/power"
import "../../common/system"

// =============================================================================
// SystemUpdateHold.qml -- holds the Performance profile while a system update RUNS, through
// PowerBus (modules/common/power): `hold("system-update", "performance", ...)` for as long as the
// run lives, `release("system-update")` when it ends. Silicon, which owns the profile, does the
// switching and, on a plain release, puts back the profile it left.
//
// WHERE THE RUN IS KNOWN FROM. The system-update module (read, never edited) hands its runs to
// helpers/update-run.sh, a detached supervisor, which keeps ONE durable marker,
//     $XDG_STATE_HOME/lares/system-update/last-run.json
//     { runId, runDir, command, pid, startedAt, state: "running" | "finished", exit?, endedAt? }
// written `running` before the command starts and `finished` after it ends -- and not at all when
// the machine is rebooted or the supervisor killed mid-run, which leaves "running" for ever. So
// "running" alone is not a run: the supervisor must also still be alive. Its pid is in the marker;
// pids are reused, so liveness is "/proc/<pid>/cmdline names this runId" (the run id is the run
// directory's name, and the supervisor was started with that directory in its argv).
//
// FOLLOWING THE MARKER. ONE static FileView on the marker, `watchChanges`, re-read on every
// change (never repointed: CLAUDE.md); a slow `pollMs` re-check while a run is live catches a
// supervisor that died without a final write.
//
// A MANUAL CHANGE WINS. PowerBus emits `dropped(sources)` when the user changes the profile by
// hand; if this hold was among them, it is not taken again for the same run (`runId`): the
// marker still says "running", and holding again would take the profile back from the user.
//
//   running   a live run is holding; runId, command   what the marker says
//   markerPath / procRoot / source / profile   overridable (a probe's fake state)
// =============================================================================
Item {
    id: root

    property string markerPath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/system-update/last-run.json"
    property string procRoot: "/proc"
    property string source: "system-update"
    property string profile: "performance"
    // silicon.jsonc holds.systemUpdate null: a run holds nothing (one that is holding lets go).
    property bool on: true
    onOnChanged: root.check()
    property int pollMs: 15000

    readonly property bool running: root._holding
    readonly property string runId: root._runId

    // Read the marker and decide now (a probe; the popup opening).
    function check() {
        marker.reload();
        root._apply(marker.text());
    }

    // ---- Private ---------------------------------------------------------------
    property bool _holding: false
    property string _runId: ""
    property string _droppedRun: ""
    property int _gen: 0

    FileView {
        id: marker
        path: root.markerPath
        watchChanges: true
        blockLoading: true
        blockAllReads: true         // reload() then text() must read the file as it is now
        printErrors: false
        blockWrites: true
        onFileChanged: marker.reload()
        onLoaded: root._apply(marker.text())
    }

    Connections {
        target: PowerBus
        function onDropped(sources) {
            if (sources.indexOf(root.source) >= 0 && root._runId !== "")
                root._droppedRun = root._runId;
            root._holding = false;
            recheck.stop();
        }
    }

    function _apply(text) {
        let m = null;
        try {
            m = JSON.parse(text || "null");
        } catch (e) {
            m = null;
        }
        root._gen++;
        const gen = root._gen;
        if (!root.on || !m || typeof m !== "object" || m.state !== "running" || typeof m.runId !== "string" || m.runId === ""
                || !(typeof m.pid === "number" && m.pid > 0)) {
            root._end();
            return;
        }
        root._runId = m.runId;
        if (m.runId === root._droppedRun)
            return;
        lane.run(["sh", "-c", "grep -aqF -- \"$1\" \"$2/$3/cmdline\"", "sh", m.runId, root.procRoot, String(m.pid)], function (res) {
            if (gen !== root._gen)
                return;
            if (res.code === 0)
                root._begin(m);
            else
                root._end();
        });
    }

    function _begin(m) {
        const why = "System update running";
        if (PowerBus.hold(root.source, root.profile, why))
            root._holding = true;
        recheck.restart();
    }

    function _end() {
        recheck.stop();
        if (root._holding || PowerBus.holds[root.source] !== undefined)
            PowerBus.release(root.source);
        root._holding = false;
    }

    // While a run is live: is its supervisor still there?
    Timer {
        id: recheck
        interval: root.pollMs
        repeat: true
        onTriggered: root.check()
    }

    ProcLane { id: lane; timeoutMs: 5000 }

    Component.onCompleted: root.check()
}
